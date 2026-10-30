#!/bin/bash
# tests/block_order.sh — orden de los bloques sólidos (SortGroupsBySize): de mayor a menor
# tamaño, estable (los empates en orden gerpn), y el archivo se extrae igual. Con -s- hay un
# bloque por archivo: los tamaños crecen con el nombre (el peor caso de la vieja inserción
# cuadrática) y con empates salteados.
set -u
ROOT=$(cd "$(dirname "$0")/.." && pwd)
PARC=${PARC_BIN:-$ROOT/build/linux64/parc}
W=${BLOCK_ORDER_WORK:-${TMPDIR:-/tmp}/parc_block_order}
N=${BLOCK_ORDER_FILES:-3000}
rm -rf -- "${W:?}"; mkdir -p "$W/src/sub" && cd "$W" || exit 2
fail=0
ck() { if eval "$2"; then printf '  ok    %s\n' "$1"; else printf '  FAIL %s\n' "$1"; fail=$((fail+1)); fi; }

python3 - "$N" <<'PY'
import sys
n = int(sys.argv[1])
for i in range(n):
    size = (i // 3) * 7 + (0 if i % 5 else 1)          # creciente, con empates
    d = 'src/sub' if i % 7 == 0 else 'src'
    ext = ('txt', 'c', 'dat')[i % 3]
    open('%s/f%06d.%s' % (d, i, ext), 'wb').write(bytes((j * 31 + i % 13) % 97 + 32 for j in range(size)))
PY

# Orden de referencia: con -m0 todos los bloques pesan 0, así que quedan en orden gerpn
names() { "$PARC" l "$1" | awk '$3 ~ /^[0-9]+$/ && $4 != "<DIR>" {print $3, $5}'; }
# Los tamaños de los bloques de datos (lb) no crecen; el primero, de directorios, no cuenta
lb_desc() { awk '/^Data blocks/ {d = 1} d && $1 == "data" {sub("orig=", "", $3); v = $3 + 0
  if (n++ == 0 && $NF == "storing" && v == 0) next; if (m++ && v > p) bad = 1; p = v} END {exit bad}'; }
"$PARC" a ref.parc src -s- -m0 --no-progress >/dev/null 2>&1
names ref.parc > ref.lst
python3 -c '
import sys
rows = [l.split() for l in open("ref.lst")]
rows.sort(key=lambda r: -int(r[0]))   # sort de Python: estable
open("want.lst", "w").write("".join("%s %s\n" % (a, b) for a, b in rows))
'
for t in 1 4; do
  rm -f o$t.parc; rm -rf x$t
  ck "a -s- -m2 N=$t"              'PARC_THREADS=$t "$PARC" a o$t.parc src -s- -m2 --no-progress >/dev/null 2>&1'
  ck "orden mayor a menor, estable N=$t" 'names o$t.parc > got$t.lst; cmp -s got$t.lst want.lst'
  ck "lb tamaños no crecen N=$t"   '"$PARC" lb o$t.parc | lb_desc'
  ck "t N=$t"                      '"$PARC" t o$t.parc --no-progress | grep -q "Errors: 0"'
  ck "x + diff N=$t"               'mkdir x$t && "$PARC" x o$t.parc -dpx$t --no-progress >/dev/null 2>&1 && diff -r src x$t/src'
done
ck "mismo archivo con 1 y 4 hilos" 'cmp -s o1.parc o4.parc'
# Al actualizar no se reordena (los bloques viejos se copian): agrega y se extrae igual
printf 'nuevo\n' > src/zz_new.txt
ck "u agrega sin reordenar"      '"$PARC" u o4.parc src -s- -m2 --no-progress >/dev/null 2>&1 && rm -rf xu && mkdir xu && "$PARC" x o4.parc -dpxu --no-progress >/dev/null 2>&1 && diff -r src xu/src'

[ "$fail" -eq 0 ] && { echo "block_order: todo ok"; rm -rf -- "${W:?}"; exit 0; }
echo "block_order: $fail fallas"; exit 1
