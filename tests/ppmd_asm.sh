#!/bin/bash
# tests/ppmd_asm.sh — el paso de símbolo y el UpdateModel de PPMd en ensamblador (x86-64,
# src/parc_ppmd8_x64.inc) contra el Pascal.
#
# Compila tests/test_ppmd_asm.lpr con ensamblador y con -dPARC_NOASM, comprime las mismas
# entradas con varios órdenes, memorias y métodos de recuperación, y exige streams idénticos
# (cada uno además se decodifica con su propia compilación). Las memorias chicas llenan el
# modelo: así se ejercitan AllocUnitsRare, RestoreModel/CutOff y el estado del asignador
# (Stamps, FreeList) que el ensamblador toca directamente. Siempre con tamaño explícito en el
# ensamblador: un "mov [campo], r32" sin "dword ptr" puede salir de 64 bits (FPC toma el tamaño
# del campo) y pisar el siguiente.
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

# Entradas: código x86 repetido, texto, bytes al azar y una mezcla
PARC=$ROOT/build/linux64/parc
[ -f "$PARC" ] || PARC=$W/asm/test_ppmd_asm
cat "$PARC" "$PARC" > in/bin2
cat "$ROOT"/src/*.pas > in/text
head -c $((1 << 20)) /dev/urandom > in/rnd
{ head -c 300000 in/text; head -c 300000 in/rnd; head -c 300000 in/text; } > in/mix

# orden:memoria KB:recuperación
for f in bin2 text rnd mix; do
  for omr in 2:16384:0 4:16384:0 4:256:1 6:49152:0 6:1024:1 8:98304:0 16:8192:0 16:2048:1 \
             12:196608:0 24:4096:1 64:6144:1; do
    IFS=: read -r o m r <<< "$omr"
    "$W/asm/test_ppmd_asm" in/$f $o $m $r a.out > a.log 2>&1; ra=$?
    "$W/pas/test_ppmd_asm" in/$f $o $m $r p.out > p.log 2>&1; rp=$?
    tag="$f ppmd:$o:${m}kb:r$r"
    if [ $ra -ne 0 ] || [ $rp -ne 0 ]; then
      bad "$tag: rc asm=$ra pascal=$rp ($(tail -1 a.log) $(tail -1 p.log))"
    elif cmp -s a.out p.out; then ok "$tag: mismo stream ($(stat -c %s a.out) bytes)"
    else bad "$tag: el ensamblador da otro stream ($(cmp a.out p.out | head -1))"; fi
  done
done

echo "ppmd_asm: $pass ok, $fail fallos"
cd / && rm -rf -- "${W:?}"
if [ "$fail" -eq 0 ]; then echo "All OK"; else exit 1; fi
