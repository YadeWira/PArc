#!/bin/bash
# tests/rs_recovery.sh — registro de recuperación Reed-Solomon de .parc ("parc-rs1"):
# repara un tramo contiguo y sectores sueltos, también con la paridad dañada, y avisa cuando
# el daño supera lo reparable.
set -u
ROOT=$(cd "$(dirname "$0")/.." && pwd)
PARC=${PARC_BIN:-$ROOT/build/linux64/parc}
W=${RS_WORK:-/mnt/IA_LAB/agentes/PArc/rs_recovery}
rm -rf -- "${W:?}"; mkdir -p "$W/d" && cd "$W" || exit 2
fail=0
check() { if eval "$2"; then printf '  ok    %s\n' "$1"; else printf '  FALLA %s\n' "$1"; fail=$((fail+1)); fi; }
for i in $(seq 1 8); do head -c 400000 /dev/urandom > "d/r$i.bin"; done; seq 1 300000 > d/t.txt

"$PARC" a a.parc d -m1 -rr5% --no-progress >/dev/null 2>&1
check ".parc: registro parc-rs1"            '"$PARC" r a.parc | grep -q "parc-rs1"'
check "sin daño: nada que reparar"          '"$PARC" r a.parc | grep -q "No hay sectores dañados"'

python3 - <<'EOF'
import random, shutil, os
random.seed(7)
def damage(src, name, ranges):
    shutil.copy(src, name)
    f = open(name, 'r+b')
    for a, b in ranges:
        f.seek(a); f.write(bytes(random.randrange(256) for _ in range(b - a)))
for ext in ('parc',):
    size = os.path.getsize('a.' + ext)
    damage('a.' + ext, 'burst.' + ext, [(200000, 350000)])
    # offsets al azar byte a byte (no múltiplos de 4096: con S=28 el paso 4096 concentra
    # los daños en 7 franjas y el caso deja de ser "sueltos")
    offs = random.sample(range(1000, size - 300000), 60)
    damage('a.' + ext, 'scatter.' + ext, [(o, o + 1) for o in offs])  # 1 byte = 1 sector (InitPos no está alineado a 512)
    damage('a.' + ext, 'heavy.' + ext, [(100000, 1000000)])
    # el final del archivo: registro de recuperación (paridad) + datos
    damage('a.' + ext, 'tail.' + ext, [(size - 60000, size - 50000), (300000, 310000)])
EOF
for f in burst scatter tail; do
  rm -f "fixed.$f.parc"; "$PARC" r "$f.parc" >/dev/null 2>&1
  check ".parc $f: reparado e íntegro"       '[ -f fixed.'"$f"'.parc ] && "$PARC" t fixed.'"$f"'.parc --no-progress | tail -1 | grep -q "Errores: 0"'
done
rm -f fixed.heavy.parc
check ".parc heavy: irrecuperable, código 2"  '{ "$PARC" r heavy.parc >/dev/null 2>&1; [ $? = 2 ]; }'

# Archivos grandes con varias franjas, y actualización
head -c 3000000 /dev/urandom > d/grande.bin
# (con 1% quedan ~2 paridades por franja: 25 daños al azar no entran; con 3%, ~6)
"$PARC" a g.parc d -m1 -rr3% --no-progress >/dev/null 2>&1
python3 - <<'EOF'
import random, shutil
random.seed(3)
shutil.copy('g.parc', 'g2.parc')
f = open('g2.parc', 'r+b')
for o in random.sample(range(0, 6000000, 512), 25):
    f.seek(o); f.write(bytes(random.randrange(256) for _ in range(64)))
EOF
rm -f fixed.g2.parc; "$PARC" r g2.parc >/dev/null 2>&1
check "3%, varias franjas, 25 daños sueltos"  '"$PARC" t fixed.g2.parc --no-progress | tail -1 | grep -q "Errores: 0"'
echo nuevo > d/nuevo.txt; "$PARC" a a.parc d/nuevo.txt --no-progress >/dev/null 2>&1
check "actualizar conserva el registro RS"    '"$PARC" r a.parc | grep -q "parc-rs1"'

echo "== recuperación RS: $fail fallas"
[ $fail -eq 0 ]
