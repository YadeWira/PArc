#!/bin/bash
# tests/filters_cross.sh — delta, lzp and dispack give the same bytes on every platform: test_filters
# built for linux32 (native), linuxarm64 (qemu-aarch64 with QEMU_LD_PREFIX) and win64/win32 (Wine)
# encodes like the linux64 one and reads its streams.
# Uso: tests/filters_cross.sh   (FPC_CROSS as in build.sh; WINEPREFIX: if not given, a private copy
#      of FILTERS_WINE_TEMPLATE, or Wine's default)
set -u
ROOT=$(cd "$(dirname "$0")/.." && pwd)
FPC_CROSS=${FPC_CROSS:-/mnt/IA_LAB/compartido/parc/fpc-cross}
B=$ROOT/build/tests/fcross
W=${FILTERS_WORK:-${TMPDIR:-/tmp}/parc_filters_cross}
rm -rf -- "${W:?}"; mkdir -p "$W" "$B"
fail=0; pass=0
ck() { if eval "$2"; then pass=$((pass+1)); else fail=$((fail+1)); echo "  FAIL $1"; fi; }

build() {   # build <name> <fpc> [options]
  local n=$1 c=$2; shift 2
  mkdir -p "$B/$n/units"
  "$c" -O3 "$@" -Fu"$ROOT/src" -FU"$B/$n/units" -FE"$B/$n" "$ROOT/tests/test_filters.lpr" >"$B/$n/build.log" 2>&1 ||
    { echo "no compila test_filters para $n (ver $B/$n/build.log)"; return 1; }
}
build linux64 fpc || exit 2
build linux64_noasm fpc -dPARC_NOASM || exit 2
TARGETS="linux64_noasm"
if [ -x "$FPC_CROSS/bin/fpc-linux32" ] && build linux32 "$FPC_CROSS/bin/fpc-linux32" -Fl/usr/lib32; then TARGETS="$TARGETS linux32"; fi
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
    linuxarm64) QEMU_LD_PREFIX=/usr/aarch64-linux-gnu qemu-aarch64 "$B/$t/test_filters" "$@" ;;
    win64|win32) wine "$B/$t/test_filters.exe" "$@" ;;
    *) "$B/$t/test_filters" "$@" ;;
  esac
}

cd "$W" || exit 2
runt linux64 synth syn >/dev/null || exit 2
cat "$ROOT"/src/*.pas > text
head -c 300000 /dev/urandom > rnd
cat syn/tables text syn/audio16le > tab
{ head -c 50000 rnd; cat text; head -c 30000 rnd; cat text; } > mix
cp "$ROOT/build/linux64/parc" exe 2>/dev/null || cp "$B/linux64/test_filters" exe
{ head -c 4096 exe; head -c 200000 rnd; tail -c +4097 exe; } > exemix
CASES="delta:tab delta:mix delta:x:tab lzp:64m:32:h20:92%:text lzp:80m:105:d1m:s32:h22:92%:mix dispack:exe dispack:b64kb:exemix"
for c in $CASES; do
  f=${c##*:}; m=${c%:*}
  R=ref_${f}_${m//[:%]/_}
  runt linux64 enc "$m" $f $R 0 >/dev/null
  for t in $TARGETS; do
    runt $t enc "$m" $f o.x 0 >/dev/null
    ck "$t $m $f: same output" "cmp -s $R o.x"
    runt $t dec "$m" $R o.d >/dev/null
    ck "$t $m $f: reads the linux64 one" "cmp -s $f o.d"
  done
done
echo "filters_cross: $pass ok, $fail fallas"
[ $fail -eq 0 ]
