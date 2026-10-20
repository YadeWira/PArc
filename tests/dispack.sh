#!/bin/bash
# tests/dispack.sh — DisPack (método dispack070) contra arc.exe.
#
#  1. arc.exe escribe -mdispack → PArc verifica, extrae y compara el árbol.
#  2. PArc escribe -mdispack (con y sin :b/:x) → arc.exe verifica y extrae.
#  3. El bloque de datos de PArc es byte a byte el de arc.exe (mismo filtro).
#  4. Un bloque dispack dañado termina con código 2, sin crash.
set -u
ROOT=$(cd "$(dirname "$0")/.." && pwd)
PARC=${PARC_BIN:-$ROOT/build/linux64/parc}
ARC_EXE=${ARC_EXE:-/mnt/IA_LAB/agentes/PArc/ref/Arc.exe}
export WINEPREFIX=${WINEPREFIX:-/mnt/IA_LAB/agentes/PArc/wine} WINEDEBUG=-all
OUT=${DISPACK_WORK:-/mnt/IA_LAB/agentes/PArc/dispack_test}
rm -rf -- "${OUT:?}"; mkdir -p "$OUT/c" && cd "$OUT" || exit 2

C=$OUT/c
cp "$ARC_EXE" "$C/arc.exe"                 # un binario real, que es donde DisPack filtra
seq 1 30000 > "$C/a.txt"
head -c 60000 /dev/urandom > "$C/r.bin"
touch -d '2020-01-01' "$C"/*
fail=0; pass=0
ok()  { pass=$((pass+1)); echo "  ok   $*"; }
bad() { fail=$((fail+1)); echo "  FAIL $*"; }
arcx() { wine "$ARC_EXE" "$@" </dev/null >/dev/null 2>&1; }

echo "== arc.exe escribe, PArc lee"
arcx a -mdispack d.arc c
"$PARC" t d.arc >/dev/null 2>&1 && ok "parc t" || bad "parc t"
rm -rf x; mkdir x
"$PARC" x d.arc -o+ -dpx >/dev/null 2>&1 && diff -r c x/c >/dev/null && ok "parc x idéntico" || bad "parc x"

echo "== PArc escribe, arc.exe lee"
for m in dispack dispack:b16mb dispack:x; do
  rm -f p.arc
  "$PARC" a -m$m p.arc c --no-progress >/dev/null 2>&1 || { bad "$m: parc no comprime"; continue; }
  arcx t p.arc && ok "$m: arc.exe t" || bad "$m: arc.exe t"
  rm -rf x; mkdir x
  if arcx x p.arc -o+ -dpx && diff -r c x/c >/dev/null; then ok "$m: arc.exe x idéntico"; else bad "$m: arc.exe x"; fi
done

echo "== mismo bloque que arc.exe"
rm -f p.arc f.arc
"$PARC" a -mdispack p.arc c --no-progress >/dev/null 2>&1
arcx a -mdispack f.arc c
python3 - "$PARC" p.arc f.arc <<'EOF'
import subprocess, sys
P, a, b = sys.argv[1:4]
def block(f):
    for line in subprocess.run([P, 'lb', f], capture_output=True, text=True).stdout.splitlines():
        if line.strip().startswith('data') and 'pos=' in line and 'orig=0' not in line:
            p = line.split()
            return int(p[1].split('=')[1]), int(p[3].split('=')[1])
    return None
pa = block(a); pb = block(b)
da = open(a, 'rb').read()[pa[0]:pa[0]+pa[1]]
db = open(b, 'rb').read()[pb[0]:pb[0]+pb[1]]
sys.exit(0 if da == db else 1)
EOF
[ $? -eq 0 ] && ok "bloque de datos byte a byte" || bad "el bloque de datos difiere"

echo "== bloque dañado"
cp d.arc bad.arc
python3 - <<'EOF'
d = bytearray(open('bad.arc', 'rb').read())
d[200] ^= 0x55
open('bad.arc', 'wb').write(d)
EOF
"$PARC" t bad.arc >/dev/null 2>&1; code=$?
[ $code = 2 ] && ok "código 2" || bad "código $code (esperado 2)"

echo "== dispack: $pass ok, $fail fallas"
[ $fail -eq 0 ]
