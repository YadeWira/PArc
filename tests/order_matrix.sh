#!/bin/bash
# tests/order_matrix.sh — PArc arma los bloques sólidos IGUAL que FreeArc 0.67.1.
#
# Por cada preset: `parc a` y `arc.exe a` sobre el mismo árbol, y se compara bloque por bloque
#   estructura: cantidad de bloques, archivos de cada bloque y su orden (orden gerpn,
#               tipos por arc.groups y por contenido, cortes de dict/grzip/tta/mm)
#   método:     el texto guardado (limitDictionary + canonización, parc_canon)
#   tamaño:     comprimido idéntico (informativo: depende de que cada codificador sea
#               byte a byte el de FreeArc, y LZMA/GRZip/Tornado todavía no lo son)
# Falla si difieren la estructura o algún método.
#
# Uso: tests/order_matrix.sh [árbol]   (default: el corpus de compat_matrix sin grande/,
#      más un árbol sintético con duplicados, mayúsculas y nombres que ordenan distinto)
set -u
ROOT=$(cd "$(dirname "$0")/.." && pwd)
PARC=${PARC_BIN:-$ROOT/build/linux64/parc}
ARC_EXE=${ARC_EXE:-/mnt/IA_LAB/agentes/PArc/ref/Arc.exe}
export WINEPREFIX=${WINEPREFIX:-/mnt/IA_LAB/agentes/PArc/wine} WINEDEBUG=-all
OUT=${ORDER_WORK:-/mnt/IA_LAB/agentes/PArc/order_matrix}
CORPUS=${WORK:-/mnt/IA_LAB/agentes/PArc/compat}/corpus
rm -rf -- "${OUT:?}"; mkdir -p "$OUT/t"

if [ $# -gt 0 ]; then
  cp -r "$1" "$OUT/t/arbol"
else
  [ -d "$CORPUS" ] || { echo "no hay corpus en $CORPUS: correr tests/compat_matrix.sh primero" >&2; exit 2; }
  mkdir -p "$OUT/t/corpus"
  for d in "$CORPUS"/*; do [ "$(basename "$d")" = grande ] || cp -r "$d" "$OUT/t/corpus/"; done
  S="$OUT/t/sint"; mkdir -p "$S/a/z" "$S/a-b" "$S/a b" "$S/a.b" "$S/Mixto"
  seq 1 400000 > "$S/a/log.txt"
  for d in a-b "a b" a.b a/z; do cp "$S/a/log.txt" "$S/$d/log.txt"; done
  seq 1 400001 > "$S/a/log2.txt"
  head -c 20000 /dev/urandom > "$S/a/r.BIN"; cp "$S/a/r.BIN" "$S/a-b/R.bin"; cp "$S/a/r.BIN" "$S/a.b/r.bin"
  head -c 900 /dev/urandom > "$S/a/chico.bin"
  for i in $(seq 1 30); do seq $i 3 90000 > "$S/Mixto/serie$i.TXT"; done
  printf 'x%.0s' $(seq 1 3000) > "$S/Mixto/a_2_b.att"; cp "$S/Mixto/a_2_b.att" "$S/Mixto/atoll.att"
fi

cat > "$OUT/cmp.py" <<'EOF'
import subprocess, sys, re
P = sys.argv[1]
def blocks(a):
    l = subprocess.run([P, 'l', a], capture_output=True, text=True).stdout.splitlines()
    names = []
    for line in l[2:]:
        if line.startswith('-----'): break
        names.append(line[47:])
    out = []; cur = None
    for line in subprocess.run([P, 'lb', a], capture_output=True, text=True).stdout.splitlines():
        m = re.match(r'\s+data\s+pos=\S+\s+orig=(\d+)\s+comp=(\d+)\s+(.*)', line)
        if m: cur = (int(m.group(1)), int(m.group(2)), m.group(3).strip()); continue
        m = re.match(r'\s+(\d+) archivo\(s\) desde #(\d+)', line)
        if m and cur:
            n, f = int(m.group(1)), int(m.group(2)); out.append(cur + (names[f:f+n],)); cur = None
    return out
a, b = blocks(sys.argv[2]), blocks(sys.argv[3])
st = [x[3] for x in a] == [x[3] for x in b]
me = st and all(x[2] == y[2] for x, y in zip(a, b))
sz = sum(1 for x, y in zip(a, b) if x[:3] == y[:3])
print(f'{len(a):3} bloques  estructura {"=" if st else "DIFIERE"}  métodos {"=" if me else "DIFIEREN"}  '
      f'idénticos {sz}/{len(b)}  ({sum(x[1] for x in a)} vs {sum(x[1] for x in b)} bytes)')
if not me:
    for x, y in zip(a, b):
        if x[3] != y[3] or x[2] != y[2]:
            print(f'      parc   : {x[2][:70]} ({len(x[3])} archivos)\n      arc.exe: {y[2][:70]} ({len(y[3])} archivos)')
sys.exit(0 if me else 1)
EOF

fail=0
for tree in "$OUT"/t/*; do
  name=$(basename "$tree")
  for m in 0 1 2 3 4 5 9 x; do
    p="$OUT/p_${name}_$m.arc"; f="$OUT/f_${name}_$m.arc"
    (cd "$OUT/t" && "$PARC" a "$p" "$name" -m$m --no-progress >/dev/null 2>&1)
    (cd "$OUT/t" && wine "$ARC_EXE" a -m$m "$f" "$name" </dev/null >/dev/null 2>&1)
    printf '%-8s -m%-2s ' "$name" "$m"
    python3 "$OUT/cmp.py" "$PARC" "$p" "$f" || fail=$((fail+1))
  done
done
# Opciones -s (parseSolidOption de FreeArc) sobre el primer árbol, con -m4
first=$(ls "$OUT/t" | head -1)
for sopt in -s- -se -s10 -s1m -s50f -se20f2m -s; do
  p="$OUT/p_s$sopt.arc"; f="$OUT/f_s$sopt.arc"
  (cd "$OUT/t" && "$PARC" a "$p" "$first" -m4 $sopt --no-progress >/dev/null 2>&1)
  (cd "$OUT/t" && wine "$ARC_EXE" a -m4 $sopt "$f" "$first" </dev/null >/dev/null 2>&1)
  printf '%-8s %-8s ' "$first" "$sopt"
  python3 "$OUT/cmp.py" "$PARC" "$p" "$f" || fail=$((fail+1))
done
echo "== orden/bloques: $fail fallas"
[ $fail -eq 0 ]
