#!/bin/bash
# tests/policy_cross.sh — the data-type detector, the presets and the file groups answer the same
# on every platform (they choose the chains, so archives depend on them): test_detect built for
# linux32 (native), linuxarm64 (qemu-aarch64 with QEMU_LD_PREFIX) and win64/win32 (Wine) prints
# the same statistics, types, chains and groups as the linux64 one.
# Uso: tests/policy_cross.sh   (FPC_CROSS as in build.sh; WINEPREFIX: if not given, a private copy
#      of FILTERS_WINE_TEMPLATE, or Wine's default)
set -u
ROOT=$(cd "$(dirname "$0")/.." && pwd)
FPC_CROSS=${FPC_CROSS:-/mnt/IA_LAB/compartido/parc/fpc-cross}
B=$ROOT/build/tests/pcross
W=${POLICY_CROSS_WORK:-${TMPDIR:-/tmp}/parc_policy_cross}
rm -rf -- "${W:?}"; mkdir -p "$W" "$B"
fail=0; pass=0
ck() { if eval "$2"; then pass=$((pass+1)); else fail=$((fail+1)); echo "  FAIL $1"; fi; }

build() {   # build <name> <fpc> [options]
  local n=$1 c=$2; shift 2
  mkdir -p "$B/$n/units"
  "$c" -O3 "$@" -Fu"$ROOT/src" -Fo"$B/$n/units" -FU"$B/$n/units" -FE"$B/$n" "$ROOT/tests/test_detect.lpr" >"$B/$n/build.log" 2>&1 ||
    { echo "test_detect does not compile for $n (see $B/$n/build.log)"; return 1; }
}
build linux64 fpc || exit 2
TARGETS=""
[ -x "$FPC_CROSS/bin/fpc-linux32" ] && build linux32 "$FPC_CROSS/bin/fpc-linux32" -Fl/usr/lib32 && TARGETS="$TARGETS linux32"
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
echo "platforms: linux64 (reference)$TARGETS"

runt() {   # runt <platform> args...
  local t=$1; shift
  case $t in
    linuxarm64) QEMU_LD_PREFIX=/usr/aarch64-linux-gnu qemu-aarch64 "$B/$t/test_detect" "$@" ;;
    win64|win32) wine "$B/$t/test_detect.exe" "$@" | tr -d '\r' ;;
    *) "$B/$t/test_detect" "$@" ;;
  esac
}

cd "$W" || exit 2
cat "$ROOT"/src/*.pas > text
head -c 400000 /dev/urandom > rnd
cp "$ROOT/build/linux64/parc" exe 2>/dev/null || cp "$B/linux64/test_detect" exe
{ head -c 100000 rnd; cat text; head -c 50000 exe; head -c 200000 /dev/zero; cat text; } > mix
python3 -c "
import struct, sys
sys.stdout.buffer.write(b''.join(struct.pack('<IIhh', i * 7, 100000 + i * 3, i % 50, -i % 9) for i in range(30000)))" > table
printf '%s\n' a.txt dir/B.TXT readme README.exe Makefile.am noext foo.~bak x.r01 x.ab_ 'u.ÑB_' x.doc x.exe x.wav x.jpg x.mp3 x.pak unknown.qqq > names
printf '%s\n' 0 1 2 3 4 5 9 x xx 5x ex5 5d 5t '3/$obj=2b' 'xlzma:64m' 'eplz:3' '(|x)lzma' > levels
for f in text rnd exe mix table; do
  runt linux64 detect $f > ref.$f
  runt linux64 detect $f 7777 > ref7.$f
done
runt linux64 decode levels 1 2 4 > ref.levels
runt linux64 groups names > ref.names
for t in $TARGETS; do
  for f in text rnd exe mix table; do
    runt $t detect $f > o.$f
    ck "$t detect $f" "cmp -s ref.$f o.$f"
    runt $t detect $f 7777 > o7.$f
    ck "$t detect $f (7777-byte chunks)" "cmp -s ref7.$f o7.$f"
  done
  runt $t decode levels 1 2 4 > o.levels
  ck "$t presets" "cmp -s ref.levels o.levels"
  runt $t groups names > o.names
  ck "$t file groups" "cmp -s ref.names o.names"
done
echo "policy_cross: $pass ok, $fail failed"
[ $fail -eq 0 ]
