#!/bin/bash
# tests/orep.sh — OREP (src/orep, MIT; pegamento en src/parc_orep.pas), el reemplazo de REP.
#
#  1. tests/test_orep.lpr con el núcleo en C y con la referencia en Pascal (-dOREP_NO_NATIVE):
#     ida y vuelta de las etapas con escrituras/lecturas de tamaños al azar, 12 juegos de
#     parámetros (ventana, l, a, s, b, d; ventana más chica que los datos: el anillo da la vuelta),
#     entradas vacía/1 byte/repetidas, igualdad con OrepEncodeBuf con 1, 3 y 5 hilos de OREP, y
#     streams dañados (bytes cambiados, cortados, basura al final, encabezado): solo EArcCorrupt.
#  2. parc: ida y vuelta de archivos con orep solo y en cadenas, los mismos bytes con
#     PARC_THREADS=1..8 y con un parc compilado con -dOREP_NO_NATIVE, parámetros inválidos
#     (error claro), -mrep (aviso de que ahora es orep), -mc-rep, -ld con orep y un archivo
#     dañado en el stream de orep (código 2).
#
# Uso: tests/orep.sh [parc]   (OREP_CORRUPT=<iteraciones>, default 300)
set -u
ROOT=$(cd "$(dirname "$0")/.." && pwd)
PARC=$(readlink -f "${1:-$ROOT/build/linux64/parc}")
W=${OREP_WORK:-${TMPDIR:-/tmp}/parc_orep_test}
ITERS=${OREP_CORRUPT:-300}
rm -rf -- "${W:?}"; mkdir -p "$W/nat" "$W/pas" "$W/ref" "$W/in/d" || exit 2
pass=0; fail=0
ok() { pass=$((pass+1)); echo "  ok   $*"; }
bad() { fail=$((fail+1)); echo "  FAIL $*"; }
check() { if eval "$2"; then ok "$1"; else bad "$1"; fi; }

# Objetos de C que hacen falta para enlazar (los del build de linux64)
OBJ=$ROOT/build/linux64/units
[ -f "$OBJ/orep_core.o" ] || { echo "falta $OBJ/orep_core.o: ./build.sh linux64"; exit 2; }
for v in nat pas; do
  d=""; [ $v = pas ] && d=-dOREP_NO_NATIVE
  fpc -O3 $d -Fu"$ROOT/src" -Fu"$ROOT/src/orep" -Fu"$ROOT/src/osrep" -Fo"$OBJ" -FU"$W/$v" -FE"$W/$v" \
    "$ROOT/tests/test_orep.lpr" > "$W/$v.log" 2>&1 || { echo "no compila test_orep ($v)"; tail -5 "$W/$v.log"; exit 2; }
done
# parc con la referencia en Pascal (para comparar bytes)
fpc -O3 -Xs -dOREP_NO_NATIVE -Fu"$ROOT/src" -Fu"$ROOT/src/orep" -Fu"$ROOT/src/osrep" -Fo"$OBJ" -FU"$W/ref" -FE"$W/ref" \
  "$ROOT/src/parc.lpr" > "$W/ref.log" 2>&1 || { echo "no compila parc -dOREP_NO_NATIVE"; tail -5 "$W/ref.log"; exit 2; }
REF=$W/ref/parc

# Entradas: texto (fuentes), binario, al azar con repeticiones lejanas (> 1 MB y < 1 MB)
cd "$W/in" || exit 2
cat "$ROOT"/src/*.pas | head -c 2000000 > text
head -c 3000000 "$PARC" > bin
head -c 1500000 /dev/urandom > r
{ cat r text r bin; head -c 300000 r; cat r; } > mix
cp text bin mix d/

for v in nat pas; do
  echo "== test_orep ($v)"
  "$W/$v/test_orep" suite text bin mix || bad "$v: suite"
  "$W/$v/test_orep" corrupt mix "$ITERS" 7 || bad "$v: streams dañados"
done

echo "== parc"
cd "$W" || exit 2
q() { "$@" --no-progress >/dev/null 2>&1; }
for m in orep orep:96mb:l256 orep:1mb:l16:a1 orep:8mb:l512:s16 orep:4mb:b64kb:d256kb orep:16mb:l256:c1 orep:16mb:a4:c2 orep:16mb:l256:c2:r512 \
         orep:256kb:l4096:a4096 orep:2mb:l64+lzma:8mb:fast "orep:1mb+exe+delta+lzma:4mb:normal:bt4" \
         orep:16mb:l32:a1:s64+4x4:b1mb:lzma:1mb:fast; do
  rm -rf o.parc x
  PARC_THREADS=1 q "$PARC" a o.parc in/d -m"$m"
  cp o.parc t1.parc
  same=1
  for t in 2 3 4 8; do
    rm -f o.parc; PARC_THREADS=$t q "$PARC" a o.parc in/d -m"$m"
    cmp -s o.parc t1.parc || same=0
    # con los hilos propios de OREP (fichas por los ganchos de 0.0.5)
    rm -f o.parc; PARC_OREP_THREADS=$t PARC_THREADS=$t q "$PARC" a o.parc in/d -m"$m"
    cmp -s o.parc t1.parc || same=0
  done
  rm -f o.parc; PARC_THREADS=4 q "$REF" a o.parc in/d -m"$m"
  cmp -s o.parc t1.parc || same=$((same + 2))
  check "$m: ida y vuelta" 'mkdir x && (cd x && q "$PARC" x ../t1.parc) && diff -r in/d x/in/d >/dev/null'
  check "$m: mismos bytes con 1..8 hilos (y PARC_OREP_THREADS)" '[ $((same & 1)) = 1 ]'
  check "$m: mismos bytes con -dOREP_NO_NATIVE" '[ $same -lt 2 ]'
  check "$m: lo descomprime la referencia en Pascal" '"$REF" t t1.parc --no-progress 2>/dev/null | grep -q "All OK"'
done

# Método guardado: la ventana se recorta al bloque y los parámetros quedan explícitos
rm -f c.parc; q "$PARC" a c.parc in/d -morep:1gb:l128:a1:s8:c2:r300:b1mb:d64kb
check "texto canónico" '"$PARC" lb c.parc | grep -qE "orep:[0-9]+(kb|mb):l128:a1:s8:c2:r300:b1mb:d64kb"'

# Parámetros inválidos: error que lo dice, sin archivo a medias
for m in orep:l8 orep:a8:l4 orep:w5g orep:b1k orep:s0 orep:s65 orep:c0 orep:c5 orep:zz orep:l0x orep:r70000; do
  rm -f e.parc
  out=$("$PARC" a e.parc in/d -m"$m" --no-progress 2>&1); rc=$?
  check "$m: rechazado" '[ $rc != 0 ] && echo "$out" | grep -q "orep: invalid" && [ ! -e e.parc ]'
done
out=$("$PARC" a e.parc in/d -mrep:96m --no-progress 2>&1); rc=$?
check "-mrep: avisa que ahora es orep" '[ $rc = 3 ] && echo "$out" | grep -q "replaced by orep"'
rm -f mc.parc; q "$PARC" a mc.parc in/d -m5 -mc-rep
check "-mc-rep quita orep" '! "$PARC" lb mc.parc | grep -q orep && "$PARC" t mc.parc | grep -q "All OK"'

# -ld: el bloque declara la memoria del anillo (ventana + bloque)
rm -f ld.parc; q "$PARC" a ld.parc in/mix -morep:64mb:b4mb+storing
check "-ld: rechaza un bloque de orep que no entra" '[ "$("$PARC" t ld.parc -ld4m --no-progress >/dev/null 2>&1; echo $?)" = 7 ]'
check "-ld: acepta uno que entra" '"$PARC" t ld.parc -ld64m --no-progress 2>/dev/null | grep -q "All OK"'

# Archivo dañado en el stream de orep: código 2, nunca otro
rm -f dmg.parc; q "$PARC" a dmg.parc in/mix -morep:2mb:l32+storing
read -r pos comp < <("$PARC" lb dmg.parc | grep "data.*orep" | sed -E 's/.*pos=([0-9]+) +orig=[0-9]+ +comp=([0-9]+).*/\1 \2/')
bad_rc=0
for i in $(seq 1 40); do
  cp dmg.parc d2.parc
  off=$((pos + (RANDOM * 32768 + RANDOM) % comp))
  printf "\\x$(printf %02x $(( (RANDOM % 255) + 1 )))" | dd of=d2.parc bs=1 seek=$off conv=notrunc 2>/dev/null
  # (el byte puede coincidir con el original: entonces 0 está bien)
  rc=$("$PARC" t d2.parc --no-progress >/dev/null 2>&1; echo $?)
  if [ "$rc" != 2 ] && ! cmp -s d2.parc dmg.parc; then bad_rc=$((bad_rc + 1)); echo "    byte $off: código $rc"; fi
done
check "40 archivos con un byte cambiado en el stream: código 2" '[ $bad_rc = 0 ]'

rm -rf -- "${W:?}"
echo "orep: $pass ok, $fail failures"
[ $fail = 0 ]
