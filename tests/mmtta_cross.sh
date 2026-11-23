#!/bin/bash
# tests/mmtta_cross.sh — tta and mm give the same bytes on every platform: test_mmtta (with the C
# core src/tta/mmtta_core.c built by each target's C compiler, as build.sh does) for linux32,
# linuxarm64 (qemu-aarch64 with QEMU_LD_PREFIX) and win64/win32 (Wine) encodes like the linux64
# one and reads its streams; also linux64 with the plain-C core (-DTTAC_NO_SIMD).
# Uso: tests/mmtta_cross.sh   (FPC_CROSS as in build.sh; WINEPREFIX: if not given, a private copy
#      of FILTERS_WINE_TEMPLATE, or Wine's default)
set -u
ROOT=$(cd "$(dirname "$0")/.." && pwd)
FPC_CROSS=${FPC_CROSS:-/mnt/IA_LAB/compartido/parc/fpc-cross}
B=$ROOT/build/tests/mmcross
W=${MMTTA_WORK:-${TMPDIR:-/tmp}/parc_mmtta_cross}
rm -rf -- "${W:?}"; mkdir -p "$W" "$B"
fail=0; pass=0
ck() { if eval "$2"; then pass=$((pass+1)); else fail=$((fail+1)); echo "  FAIL $1"; fi; }
CF="-O3 -fwrapv -fno-builtin -ffreestanding -fno-stack-protector -w"

build() {   # build <name> <cc and options> -- <fpc> [options]
  local n=$1; shift
  local cc=()
  while [ "$1" != "--" ]; do cc+=("$1"); shift; done
  shift
  local c=$1; shift
  local extra=""
  case "${cc[0]}" in *clang*) ;; *) extra="-fno-tree-loop-distribute-patterns" ;; esac
  mkdir -p "$B/$n/units"
  "${cc[@]}" $CF $extra -c "$ROOT/src/tta/mmtta_core.c" -o "$B/$n/units/mmtta_core.o" >"$B/$n/cc.log" 2>&1 ||
    { echo "no compila el núcleo C para $n"; return 1; }
  "$c" -O3 "$@" -Fu"$ROOT/src" -Fo"$B/$n/units" -FU"$B/$n/units" -FE"$B/$n" "$ROOT/tests/test_mmtta.lpr" >"$B/$n/build.log" 2>&1 ||
    { echo "no compila test_mmtta para $n (ver $B/$n/build.log)"; return 1; }
}
build linux64 gcc -fno-pie -- fpc || exit 2
build linux64_nosimd gcc -fno-pie -DTTAC_NO_SIMD -- fpc || exit 2
TARGETS="linux64_nosimd"
if [ -x "$FPC_CROSS/bin/fpc-linux32" ] && build linux32 gcc -m32 -fno-pie -mstackrealign -- "$FPC_CROSS/bin/fpc-linux32" -Fl/usr/lib32; then
  TARGETS="$TARGETS linux32"; fi
if [ -x "$FPC_CROSS/bin/fpc-linuxarm64" ] && command -v qemu-aarch64 >/dev/null &&
   build linuxarm64 aarch64-linux-gnu-gcc -fno-pie -- "$FPC_CROSS/bin/fpc-linuxarm64" -Fl"$(dirname "$(aarch64-linux-gnu-gcc -print-libgcc-file-name)")"; then
  TARGETS="$TARGETS linuxarm64"; fi
if command -v wine >/dev/null; then
  if [ -z "${WINEPREFIX:-}" ] && [ -n "${FILTERS_WINE_TEMPLATE:-}" ]; then
    cp -r "$FILTERS_WINE_TEMPLATE" "$W/wp"; export WINEPREFIX=$W/wp; fi
  export WINEDEBUG=-all
  [ -x "$FPC_CROSS/bin/fpc-win64" ] && build win64 x86_64-w64-mingw32-gcc -- "$FPC_CROSS/bin/fpc-win64" && TARGETS="$TARGETS win64"
  [ -x "$FPC_CROSS/bin/fpc-win32" ] && build win32 i686-w64-mingw32-gcc -mstackrealign -- "$FPC_CROSS/bin/fpc-win32" && TARGETS="$TARGETS win32"
fi
echo "plataformas: linux64 (referencia) $TARGETS"

runt() {   # runt <platform> args...
  local t=$1; shift
  case $t in
    linuxarm64) QEMU_LD_PREFIX=/usr/aarch64-linux-gnu qemu-aarch64 "$B/$t/test_mmtta" "$@" ;;
    win64|win32) wine "$B/$t/test_mmtta.exe" "$@" ;;
    *) "$B/$t/test_mmtta" "$@" ;;
  esac
}

cd "$W" || exit 2
runt linux64 synth syn >/dev/null || exit 2
cat syn/w16s.wav syn/b24.bmp > mix
CASES="tta:syn/w16s.wav tta:m1:syn/w8m.wav tta:m2:syn/w24s.wav tta:syn/wf32s.wav tta:syn/w16c6.wav
       tta:syn/a16s.aif tta:syn/raw16s.pcm tta:m9:syn/w32s.wav tta:mix
       mm:syn/b24.bmp mm:syn/t32.tga mm:syn/p6w.ppm mm:syn/i24.tif mm:syn/w16s.wav mm:d1:syn/raw16s.pcm mm:mix"
for c in $CASES; do
  f=${c##*:}; m=${c%:*}
  R=ref_$(echo "$m$f" | tr -c 'A-Za-z0-9\n' '_')
  runt linux64 enc "$m" $f $R 0 >/dev/null
  for t in $TARGETS; do
    runt $t enc "$m" $f o.x 0 >/dev/null
    ck "$t $m $f: same output" "cmp -s $R o.x"
    runt $t dec "$m" $R o.d >/dev/null
    ck "$t $m $f: reads the linux64 one" "cmp -s $f o.d"
  done
done
echo "mmtta_cross: $pass ok, $fail fallas"
[ $fail -eq 0 ]
