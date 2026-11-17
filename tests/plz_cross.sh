#!/bin/bash
# tests/plz_cross.sh — plz da los mismos bytes en todas las plataformas: test_plz compilado para
# linux32 (corre nativo), linuxarm64 (qemu-aarch64 con QEMU_LD_PREFIX) y win64/win32 (Wine)
# comprime igual que el de linux64 (streaming y memoria, todos los niveles) y lee sus streams.
# Uso: tests/plz_cross.sh   (FPC_CROSS como en build.sh; WINEPREFIX: si no se da, una copia
#      privada de PLZ_WINE_TEMPLATE, o el default de Wine)
set -u
ROOT=$(cd "$(dirname "$0")/.." && pwd)
FPC_CROSS=${FPC_CROSS:-/mnt/IA_LAB/compartido/parc/fpc-cross}
B=$ROOT/build/tests/cross
W=${PLZ_WORK:-${TMPDIR:-/tmp}/parc_plz_cross}
rm -rf -- "${W:?}"; mkdir -p "$W" "$B"
fail=0; pass=0
ck() { if eval "$2"; then pass=$((pass+1)); else fail=$((fail+1)); echo "  FAIL $1"; fi; }

build() {   # build <nombre> <fpc> [opciones]
  local n=$1 c=$2; shift 2
  mkdir -p "$B/$n/units"
  "$c" -O3 "$@" -Fu"$ROOT/src" -FU"$B/$n/units" -FE"$B/$n" "$ROOT/tests/test_plz.lpr" >"$B/$n/build.log" 2>&1 ||
    { echo "no compila test_plz para $n (ver $B/$n/build.log)"; return 1; }
}
build linux64 fpc || exit 2
build linux64_noasm fpc -dPARC_NOASM || exit 2
TARGETS="linux64_noasm"
if [ -x "$FPC_CROSS/bin/fpc-linux32" ] && build linux32 "$FPC_CROSS/bin/fpc-linux32" -Fl/usr/lib32; then TARGETS="$TARGETS linux32"; fi
if [ -x "$FPC_CROSS/bin/fpc-linuxarm64" ] && command -v qemu-aarch64 >/dev/null &&
   build linuxarm64 "$FPC_CROSS/bin/fpc-linuxarm64" -Fl"$(dirname "$(aarch64-linux-gnu-gcc -print-libgcc-file-name)")"; then
  TARGETS="$TARGETS linuxarm64"; fi
if command -v wine >/dev/null; then
  if [ -z "${WINEPREFIX:-}" ] && [ -n "${PLZ_WINE_TEMPLATE:-}" ]; then
    cp -r "$PLZ_WINE_TEMPLATE" "$W/wp"; export WINEPREFIX=$W/wp; fi
  export WINEDEBUG=-all
  for t in win64 win32; do
    [ -x "$FPC_CROSS/bin/fpc-$t" ] && build $t "$FPC_CROSS/bin/fpc-$t" && TARGETS="$TARGETS $t"
  done
fi
echo "plataformas: linux64 (referencia) $TARGETS"

runt() {   # runt <plataforma> args...
  local t=$1; shift
  case $t in
    linuxarm64) QEMU_LD_PREFIX=/usr/aarch64-linux-gnu qemu-aarch64 "$B/$t/test_plz" "$@" ;;
    win64|win32) wine "$B/$t/test_plz.exe" "$@" ;;
    *) "$B/$t/test_plz" "$@" ;;
  esac
}

cd "$W" || exit 2
cat "$ROOT"/src/*.pas > text
head -c 400000 /dev/urandom > rnd
{ head -c 50000 rnd; head -c 900000 text; head -c 30000 rnd; head -c 600000 text; } > mix
python3 -c "
import sys
p=bytes(range(256))*3+b'PArc plz '*7
sys.stdout.buffer.write(p*(3000000//len(p)))" > pattern
METHODS="plz:1 plz:2 plz:3 plz:4 plz:5 plz:6 plz:7 plz:4:64kb plz:2:1kb plz:3:x4:k0"
for f in text mix pattern; do
  for m in $METHODS; do
    R=ref_${f}_${m//:/_}
    runt linux64 enc $m $f $R.s >/dev/null
    runt linux64 encmem $m $f $R.m >/dev/null
    for t in $TARGETS; do
      runt $t enc $m $f o.s >/dev/null
      ck "$t $m $f: streaming igual" "cmp -s $R.s o.s"
      runt $t encmem $m $f o.m >/dev/null
      ck "$t $m $f: memoria igual" "cmp -s $R.m o.m"
      runt $t dec $R.s o.d >/dev/null
      ck "$t $m $f: lee el de linux64" "cmp -s $f o.d"
    done
  done
done
echo "plz_cross: $pass ok, $fail fallas"
[ $fail -eq 0 ]
