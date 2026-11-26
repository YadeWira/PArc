#!/bin/bash
# tests/srep.sh — srep = OSREP -m6 (src/osrep, MIT; pegamento en src/parc_osrep.pas), el
# reemplazo de SREP de FreeArc.
#
#  1. tests/test_srep.lpr con el núcleo en C y con la referencia en Pascal (-dOSREP_NO_NATIVE):
#     ida y vuelta de las etapas (vacío, 1 byte, 100 bytes, al azar, repetitivo, texto, ceros)
#     con 7 juegos de parámetros, escrituras/lecturas de tamaños al azar, el byte del bloque, la
#     misma salida que OsrepM6Encode, parámetros inválidos, el texto canónico, un bloque de SREP
#     de FreeArc (error claro) y streams dañados (bytes cambiados, cortados, basura al final):
#     solo EArcCorrupt.
#  2. parc: ida y vuelta de archivos con srep solo y en cadenas, los mismos bytes con
#     PARC_THREADS=1..8 y con un parc compilado con -dOSREP_NO_NATIVE, el texto canónico, `osrep`
#     como alias, parámetros inválidos (error claro) y un archivo dañado en el stream (código 2).
#  3. Con SREP_BIG=<GiB> (aparte: minutos, ~3 veces eso en disco y ~2,5 veces en RAM): un bloque
#     sólido de ese tamaño con repeticiones que cruzan 2^31 y 2^32, ida y vuelta.
#
# Uso: tests/srep.sh [parc]   (SREP_CORRUPT=<iteraciones>, default 1000; SREP_WORK=<dir>)
set -u
ROOT=$(cd "$(dirname "$0")/.." && pwd)
PARC=$(readlink -f "${1:-$ROOT/build/linux64/parc}")
W=${SREP_WORK:-${TMPDIR:-/tmp}/parc_srep_test}
ITERS=${SREP_CORRUPT:-1000}
rm -rf -- "${W:?}"; mkdir -p "$W/nat" "$W/pas" "$W/ref" "$W/in/d" || exit 2
pass=0; fail=0
ok() { pass=$((pass+1)); echo "  ok   $*"; }
bad() { fail=$((fail+1)); echo "  FAIL $*"; }
check() { if eval "$2"; then ok "$1"; else bad "$1"; fi; }

# Objetos de C que hacen falta para enlazar (los del build de este parc)
OBJ=$(dirname "$PARC")/units
[ -f "$OBJ/osrep_lr.o" ] || { echo "falta $OBJ/osrep_lr.o: ./build.sh"; exit 2; }
U="-Fu$ROOT/src -Fu$ROOT/src/orep -Fu$ROOT/src/osrep -Fu$ROOT/src/bwt -Fu$ROOT/src/cm -Fu$ROOT/src/tta"
for v in nat pas; do
  d=""; [ $v = pas ] && d=-dOSREP_NO_NATIVE
  fpc -O3 $d $U -Fo"$OBJ" -Fl"$OBJ" -FU"$W/$v" -FE"$W/$v" "$ROOT/tests/test_srep.lpr" > "$W/$v.log" 2>&1 \
    || { echo "no compila test_srep ($v)"; tail -5 "$W/$v.log"; exit 2; }
done
# parc con la referencia en Pascal de OSREP (para comparar bytes)
fpc -O3 -Xs -dOSREP_NO_NATIVE $U -Fo"$OBJ" -Fl"$OBJ" -FU"$W/ref" -FE"$W/ref" "$ROOT/src/parc.lpr" > "$W/ref.log" 2>&1 \
  || { echo "no compila parc -dOSREP_NO_NATIVE"; tail -5 "$W/ref.log"; exit 2; }
REF=$W/ref/parc

for v in nat pas; do
  echo "== test_srep ($v)"
  "$W/$v/test_srep" suite | tail -1; [ "${PIPESTATUS[0]}" = 0 ] && ok "$v: suite" || bad "$v: suite"
  "$W/$v/test_srep" corrupt "$ITERS" 7 | tail -2; [ "${PIPESTATUS[0]}" = 0 ] && ok "$v: streams dañados" || bad "$v: streams dañados"
done

# Entradas: texto (fuentes), binario, al azar con repeticiones lejanas
cd "$W/in" || exit 2
cat "$ROOT"/src/*.pas | head -c 3000000 > text
head -c 2000000 "$PARC" > bin
head -c 1500000 /dev/urandom > r
{ cat r text r bin; head -c 300000 r; cat r; } > mix
: > empty; printf x > one
cp text bin mix empty one d/

echo "== parc"
cd "$W" || exit 2
q() { "$@" --no-progress >/dev/null 2>&1; }
for m in srep srep+lzma srep+plz srep:l64:a1+plz:2 srep:l32:a1:b64kb osrep:1024:a4 "srep+exe+delta+lzma:4mb:normal:bt4" \
         srep+4x4:b1mb:lzma:1mb:fast srep:l4096:a4096+lzma:8mb:fast; do
  rm -rf o.parc x
  PARC_THREADS=1 q "$PARC" a o.parc in/d -m"$m"
  cp o.parc t1.parc
  same=1
  for t in 2 4 8; do
    rm -f o.parc; PARC_THREADS=$t q "$PARC" a o.parc in/d -m"$m"
    cmp -s o.parc t1.parc || same=0
  done
  rm -f o.parc; PARC_THREADS=4 q "$REF" a o.parc in/d -m"$m"
  cmp -s o.parc t1.parc || same=$((same + 2))
  check "$m: ida y vuelta" 'mkdir x && (cd x && q "$PARC" x ../t1.parc) && diff -r in/d x/in/d >/dev/null'
  check "$m: mismos bytes con 1..8 hilos" '[ $((same & 1)) = 1 ]'
  check "$m: mismos bytes con -dOSREP_NO_NATIVE" '[ $same -lt 2 ]'
  check "$m: lo descomprime la referencia en Pascal" '"$REF" t t1.parc --no-progress 2>/dev/null | grep -q "All OK"'
done

# Método guardado: los parámetros que no son los de por defecto, `osrep` queda como srep
rm -f c.parc; q "$PARC" a c.parc in/d -mosrep:l128:a1:b1mb:m3f+lzma:4mb
check "texto canónico" '"$PARC" lb c.parc | grep -q "srep:l128:a1:b1mb+lzma"'
rm -f c.parc; q "$PARC" a c.parc in/d -msrep:512:a16:b8mb
check "texto canónico (por defecto)" '"$PARC" lb c.parc | grep -qE "[0-9] +srep( |$)"'
# Parámetros inválidos: error claro, sin archivo
for m in srep:l16 srep:a0 srep:b16mbx srep:x3 srep:b1gb; do
  rm -f e.parc
  out=$("$PARC" a e.parc in/d -m"$m" --no-progress 2>&1); rc=$?
  check "$m: rechazado ($rc)" '[ $rc != 0 ] && echo "$out" | grep -qi "srep" && [ ! -s e.parc ]'
done

# Archivo dañado dentro del stream de OSREP (srep solo: el bloque es el stream): código 2
echo "== archivo dañado"
rm -f d.parc; q "$PARC" a d.parc in/mix -msrep
read -r pos comp < <("$PARC" lb d.parc | awk '$1 == "data" && $NF ~ /^srep/ {sub("pos=", "", $2); sub("comp=", "", $4); print $2, $4}')
bad_rc=0; n=0
for i in $(seq 1 40); do
  cp d.parc d2.parc
  off=$(( pos + 1 + (RANDOM * 32768 + RANDOM) % (comp - 1) ))
  python3 -c "import sys; f=open('d2.parc','r+b'); f.seek($off); b=f.read(1); f.seek($off); f.write(bytes([b[0]^0x5a]))"
  rm -rf y; mkdir y
  (cd y && timeout 60 "$PARC" x ../d2.parc --no-progress >/dev/null 2>&1); rc=$?
  n=$((n + 1))
  if [ "$rc" != 2 ]; then bad_rc=$((bad_rc + 1)); echo "    byte $off: código $rc"; fi
done
check "40 bytes dañados en el stream: código 2" '[ $bad_rc = 0 ]'

if [ -n "${SREP_BIG:-}" ]; then
  echo "== bloque de ${SREP_BIG} GiB (repeticiones que cruzan 2^31 y 2^32)"
  mkdir -p big && cd big || exit 2
  python3 -I - "$SREP_BIG" <<'EOF'
import os, sys
G = 1 << 30
total = int(float(sys.argv[1]) * G)
chunk = os.urandom(64 << 20)          # se repite: en 0, cruzando 2^31, cruzando 2^32 y al final
marks = sorted({0, (1 << 31) - (32 << 20), (1 << 32) - (32 << 20), total - len(chunk)})
with open('f', 'wb') as f:
    pos = 0
    for m in marks:
        while pos < m:
            n = min(m - pos, 64 << 20)
            f.write(os.urandom(n)); pos += n
        f.write(chunk); pos += len(chunk)
EOF
  ls -l f | awk '{print "  entrada:", $5, "bytes"}'
  /usr/bin/time -f "  comprimir: %e s, %M KB" "$PARC" a b.parc f -msrep --no-progress >/dev/null || bad "big: a"
  "$PARC" lb b.parc | grep ' data '
  check "big: el stream es de OSREP (más chico que la entrada)" '[ $(stat -c %s b.parc) -lt $(( $(stat -c %s f) - 200000000 )) ]'
  mkdir x && (cd x && /usr/bin/time -f "  extraer: %e s, %M KB" "$PARC" x ../b.parc --no-progress >/dev/null)
  check "big: ida y vuelta" 'cmp -s f x/f'
  cd .. && rm -rf big
fi

rm -rf -- "${W:?}"
echo "== srep: $pass ok, $fail failures"
[ $fail = 0 ]
