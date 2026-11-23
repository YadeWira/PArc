#!/bin/bash
# tests/cm_cross.sh — cm gives the same bytes on every platform: test_cm built for linux32
# (native), linuxarm64 (qemu-aarch64 with QEMU_LD_PREFIX) and win64/win32 (Wine) encodes like the
# linux64 one and reads its streams. The C core is built with each target's compiler as in
# build.sh (x86-64 uses the SSE2 mixer, the others the portable C one: same results).
# Uso: tests/cm_cross.sh   (FPC_CROSS as in build.sh; WINEPREFIX: if not given, a private copy
#      of FILTERS_WINE_TEMPLATE, or Wine's default)
set -u
ROOT=$(cd "$(dirname "$0")/.." && pwd)
FPC_CROSS=${FPC_CROSS:-/mnt/IA_LAB/compartido/parc/fpc-cross}
B=$ROOT/build/tests/cmcross
W=${CM_CROSS_WORK:-${TMPDIR:-/tmp}/parc_cm_cross}
rm -rf -- "${W:?}"; mkdir -p "$W" "$B"
fail=0; pass=0
ck() { if eval "$2"; then pass=$((pass+1)); else fail=$((fail+1)); echo "  FAIL $1"; fi; }

PCMFLAGS="-O3 -funroll-loops -fno-builtin -ffreestanding -fno-stack-protector -fno-tree-loop-distribute-patterns -w"
build() {   # build <name> <cc and its options> -- <fpc> [options]
  local n=$1; shift
  local cc=()
  while [ "$1" != "--" ]; do cc+=("$1"); shift; done; shift
  local c=$1; shift
  mkdir -p "$B/$n/units"
  "${cc[@]}" $PCMFLAGS -c "$ROOT/src/cm/pcm_core.c" -o "$B/$n/units/pcm_core.o" >"$B/$n/build.log" 2>&1 &&
  "$c" -O3 "$@" -Fu"$ROOT/src" -FU"$B/$n/units" -FE"$B/$n" "$ROOT/tests/test_cm.lpr" >>"$B/$n/build.log" 2>&1 ||
    { echo "no compila test_cm para $n (ver $B/$n/build.log)"; return 1; }
}
build linux64 gcc -fno-pie -- fpc || exit 2
build linux64_c gcc -fno-pie -DPCM_NO_SIMD -- fpc || exit 2
TARGETS="linux64_c"
if [ -x "$FPC_CROSS/bin/fpc-linux32" ] && build linux32 gcc -m32 -fno-pie -mstackrealign -- "$FPC_CROSS/bin/fpc-linux32" -Fl/usr/lib32; then TARGETS="$TARGETS linux32"; fi
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
    linuxarm64) QEMU_LD_PREFIX=/usr/aarch64-linux-gnu qemu-aarch64 "$B/$t/test_cm" "$@" ;;
    win64|win32) wine "$B/$t/test_cm.exe" "$@" ;;
    *) "$B/$t/test_cm" "$@" ;;
  esac
}

cd "$W" || exit 2
cat "$ROOT"/src/*.pas | head -c 400000 > text
head -c 200000 /dev/urandom > rnd
{ head -c 70000 rnd; cat text; head -c 150000 "$ROOT/build/linux64/parc" 2>/dev/null; head -c 30000 rnd; cat text; } > mix
CASES="6:text 6:mix 1:mix"
for c in $CASES; do
  f=${c#*:}; l=${c%%:*}
  R=ref_${f}_$l
  runt linux64 enc $l $f $R 0 >/dev/null
  for t in $TARGETS; do
    runt $t enc $l $f o.x 0 >/dev/null
    ck "$t cm:$l $f: same output" "cmp -s $R o.x"
    runt $t dec $R o.d >/dev/null
    ck "$t cm:$l $f: reads the linux64 one" "cmp -s $f o.d"
  done
done
echo "cm_cross: $pass ok, $fail fallas"
[ $fail -eq 0 ]
