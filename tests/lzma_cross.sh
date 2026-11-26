#!/bin/bash
# tests/lzma_cross.sh — the LZMA encoder writes the same bytes on every platform: test_lzmaenc
# built for linux64 without assembler, linux32 (native), linuxarm64 (qemu-aarch64 with
# QEMU_LD_PREFIX) and win64/win32 (Wine) dumps the streams of its quick set (bt2/bt3/bt4/hc4 and
# every ht4 row shape) and they must equal the linux64 ones.
# Uso: tests/lzma_cross.sh   (FPC_CROSS as in build.sh; WINEPREFIX as in filters_cross.sh)
set -u
ROOT=$(cd "$(dirname "$0")/.." && pwd)
FPC_CROSS=${FPC_CROSS:-/mnt/IA_LAB/compartido/parc/fpc-cross}
B=$ROOT/build/tests/lzcross
W=${LZMA_CROSS_WORK:-${TMPDIR:-/tmp}/parc_lzma_cross}
rm -rf -- "${W:?}"; mkdir -p "$W" "$B"
fail=0; pass=0
ck() { if eval "$2"; then pass=$((pass+1)); else fail=$((fail+1)); echo "  FAIL $1"; fi; }
build() {   # build <name> <fpc> [options]
  local n=$1 c=$2; shift 2
  mkdir -p "$B/$n/units"
  "$c" -O2 "$@" -Fu"$ROOT/src" -Fu"$ROOT/src/orep" -Fu"$ROOT/src/osrep" -Fu"$ROOT/src/bwt" -FU"$B/$n/units" -FE"$B/$n" \
    "$ROOT/tests/test_lzmaenc.lpr" >"$B/$n/build.log" 2>&1 ||
    { echo "no compila test_lzmaenc para $n (ver $B/$n/build.log)"; return 1; }
}
build linux64 fpc || exit 2
TARGETS=""
build linux64_noasm fpc -dPARC_NOASM && TARGETS="linux64_noasm"
if [ -x "$FPC_CROSS/bin/fpc-linux32" ] && build linux32 "$FPC_CROSS/bin/fpc-linux32" -Fl/usr/lib32; then
  TARGETS="$TARGETS linux32"; fi
if [ -x "$FPC_CROSS/bin/fpc-linuxarm64" ] && command -v qemu-aarch64 >/dev/null &&
   build linuxarm64 "$FPC_CROSS/bin/fpc-linuxarm64" -Fl"$(dirname "$(aarch64-linux-gnu-gcc -print-libgcc-file-name)")"; then
  TARGETS="$TARGETS linuxarm64"; fi
if command -v wine >/dev/null; then
  if [ -z "${WINEPREFIX:-}" ] && [ -n "${FILTERS_WINE_TEMPLATE:-}" ]; then
    cp -r "$FILTERS_WINE_TEMPLATE" "$W/wp"; export WINEPREFIX=$W/wp; fi
  export WINEDEBUG=-all
  for t in win64 win32; do
    [ -x "$FPC_CROSS/bin/fpc-$t" ] && build $t "$FPC_CROSS/bin/fpc-$t" && TARGETS="$TARGETS $t"
  done
fi
echo "plataformas: linux64 (referencia) $TARGETS"
runt() {   # runt <platform> args...
  local t=$1; shift
  case $t in
    linuxarm64) QEMU_LD_PREFIX=/usr/aarch64-linux-gnu qemu-aarch64 "$B/$t/test_lzmaenc" "$@" ;;
    win64|win32) wine "$B/$t/test_lzmaenc.exe" "$@" ;;
    *) "$B/$t/test_lzmaenc" "$@" ;;
  esac
}
cd "$W" || exit 2
runt linux64 -quick -dump ref > ref.log 2>&1
ck "linux64 ($(tail -1 ref.log))" "grep -q ' 0 fallos' ref.log"
n=$(ls ref/*.lz | wc -l)
for t in $TARGETS; do
  runt $t -quick -dump out_$t > $t.log 2>&1
  ck "$t: test_lzmaenc ($(tail -1 $t.log | tr -d '\r'))" "grep -q ' 0 fallos' $t.log"
  d=0; for f in ref/*.lz; do cmp -s "$f" "out_$t/${f#ref/}" || d=$((d+1)); done
  ck "$t: the same $n streams as linux64 ($d differ)" "[ $d -eq 0 ]"
done
echo "lzma_cross: $pass ok, $fail fallas"
[ $fail -eq 0 ]
