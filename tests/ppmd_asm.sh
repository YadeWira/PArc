#!/bin/bash
# tests/ppmd_asm.sh — los bucles de PPMd en ensamblador (x86-64) contra el Pascal.
#
# Compila tests/test_ppmd_asm.lpr con ensamblador y con -dPARC_NOASM, comprime las mismas
# entradas con varios órdenes y memorias y exige streams idénticos (cada uno además se
# decodifica con su propia compilación). Antes de este test, tres "mov [..FBList + 4], r32"
# salían como mov de 64 bits (FPC toma el tamaño del campo, un TBlkNode de 8 bytes) y pisaban
# el Stamp de la lista siguiente: con el binario de parc dos veces, ppmd:4 y ppmd:6 daban
# otro stream que FreeArc y terminaban en Access violation / SIGSEGV (Range = 0).
#
# Solo tiene sentido en x86-64. Uso: tests/ppmd_asm.sh
set -u
ROOT=$(cd "$(dirname "$0")/.." && pwd)
W=${PPMD_ASM_WORK:-${TMPDIR:-/tmp}/parc_ppmd_asm}
rm -rf -- "${W:?}"; mkdir -p "$W/asm" "$W/pas" "$W/in" && cd "$W" || exit 2
fail=0; pass=0
ok()  { pass=$((pass+1)); echo "  ok   $*"; }
bad() { fail=$((fail+1)); echo "  FAIL $*"; }

for v in asm pas; do
  d=""; [ $v = pas ] && d=-dPARC_NOASM
  fpc -O3 $d -Fu"$ROOT/src" -FU"$W/$v" -FE"$W/$v" "$ROOT/tests/test_ppmd_asm.lpr" > "$W/$v.log" 2>&1 \
    || { echo "no compila test_ppmd_asm ($v)"; tail -5 "$W/$v.log"; exit 2; }
done

# Entradas: código x86 repetido (lo que rompía), texto y bytes al azar
PARC=$ROOT/build/linux64/parc
[ -f "$PARC" ] || PARC=$W/asm/test_ppmd_asm
cat "$PARC" "$PARC" > in/bin2
cat "$ROOT"/src/*.pas > in/text
head -c $((1 << 20)) /dev/urandom > in/rnd
{ head -c 300000 in/text; head -c 300000 in/rnd; head -c 300000 in/text; } > in/mix

for f in bin2 text rnd mix; do
  for om in 2:16 4:16 4:48 6:48 8:96 16:8 12:192; do
    o=${om%:*}; m=${om#*:}
    "$W/asm/test_ppmd_asm" in/$f $o $m a.out > a.log 2>&1; ra=$?
    "$W/pas/test_ppmd_asm" in/$f $o $m p.out > p.log 2>&1; rp=$?
    if [ $ra -ne 0 ] || [ $rp -ne 0 ]; then
      bad "$f ppmd:$o:${m}mb: rc asm=$ra pascal=$rp ($(tail -1 a.log) $(tail -1 p.log))"
    elif cmp -s a.out p.out; then ok "$f ppmd:$o:${m}mb: mismo stream ($(stat -c %s a.out) bytes)"
    else bad "$f ppmd:$o:${m}mb: el ensamblador da otro stream ($(cmp a.out p.out | head -1))"; fi
  done
done

echo "ppmd_asm: $pass ok, $fail fallos"
cd / && rm -rf -- "${W:?}"
[ "$fail" -eq 0 ]
