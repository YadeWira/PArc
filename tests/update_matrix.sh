#!/bin/bash
# tests/update_matrix.sh — actualizar un archivo existente IGUAL que FreeArc 0.67.1.
#
# Base: un .arc hecho por arc.exe. Por cada escenario se aplica la misma operación con
# arc.exe y con parc sobre copias de la base, y se compara la estructura del resultado
# (qué bloques se copian enteros o se rehacen, qué archivos van en cada uno, en qué orden,
# y el método guardado). Después, arc.exe t sobre el de parc.
#
# Nota: donde el fuente de FreeArc (splitBy con oldLen/oldPos) y el binario 0.67.1 difieren
# (un archivo nuevo detrás de un bloque viejo entero del mismo grupo: el binario reempaqueta),
# parc sigue al binario.
set -u
ROOT=$(cd "$(dirname "$0")/.." && pwd)
PARC=${PARC_BIN:-$ROOT/build/linux64/parc}
ARC_EXE=${ARC_EXE:-/mnt/IA_LAB/agentes/PArc/ref/Arc.exe}
export WINEPREFIX=${WINEPREFIX:-/mnt/IA_LAB/agentes/PArc/wine} WINEDEBUG=-all
OUT=${UPDATE_WORK:-/mnt/IA_LAB/agentes/PArc/update_matrix}
rm -rf -- "${OUT:?}"; mkdir -p "$OUT/c" && cd "$OUT" || exit 2

# Árbol base: textos, binarios, un wav, y archivos que después se agregan o cambian
C=$OUT/c
seq 1 20000 > "$C/texto1.txt"; seq 5 30000 > "$C/texto2.txt"; seq 9 25000 > "$C/medio.txt"
head -c 60000 /dev/urandom > "$C/datos1.bin"; head -c 50000 /dev/urandom > "$C/datos2.bin"
head -c 150000 /dev/urandom > "$C/grande1.bin"; cp "$C/grande1.bin" "$C/grande2.bin"
python3 -c "
import struct, math
n=40000; d=b''.join(struct.pack('<h', int(8000*math.sin(i/9))) for i in range(n))
h=b'RIFF'+struct.pack('<I',36+len(d))+b'WAVEfmt '+struct.pack('<IHHIIHH',16,1,1,44100,88200,2,16)+b'data'+struct.pack('<I',len(d))
open('$C/audio1.wav','wb').write(h+d)"
touch -d '2020-01-01' "$C"/*
mkdir -p nuevos; head -c 30000 /dev/urandom > nuevos/aaa1.bin; head -c 30000 /dev/urandom > nuevos/zzz1.bin
seq 1 3000 | tr '\n' ',' > nuevos/png1.png; seq 3 9000 > nuevos/medio.txt
touch -d '2021-01-01' nuevos/*

arcx() { (cd "$1" && wine "$ARC_EXE" "${@:2}" </dev/null >/dev/null 2>&1); }
fail=0; known=0
# cmp.py: el mismo comparador de tests/order_matrix.sh
sed -n '/^cat > "\$OUT\/cmp.py"/,/^EOF$/p' "$ROOT/tests/order_matrix.sh" | sed '1d;$d' > "$OUT/cmp.py"

# escenario: nombre, -m, comando, archivos (relativos al árbol de trabajo), preparación
run() {
  local name=$1 m=$2 cmd=$3 prep=$4; shift 4
  for who in f p; do
    rm -rf "w_$who"; cp -a c "w_$who"
    arcx "w_$who" a -m$m base.arc . -x"base.arc"
    (cd "w_$who" && eval "$prep")
  done
  arcx w_f "$cmd" -m$m "$@" -xbase.arc base.arc "${FILES[@]}"
  (cd w_p && "$PARC" "$cmd" base.arc "${FILES[@]}" -m$m "$@" --no-progress >/dev/null 2>&1)
  local t; t=$(wine "$ARC_EXE" t w_p/base.arc </dev/null 2>&1 | tr '\r' '\n' | grep -a -c 'All OK')
  printf '%-10s arc.exe_t=%s  ' "$name" "$t"
  if python3 "$OUT/cmp.py" "$PARC" w_p/base.arc w_f/base.arc && [ "$t" = 1 ]; then :
  else fail=$((fail+1)); fi
}
for m in 4 5; do
  FILES=(aaa1.bin);  run add$m   $m a "cp ../nuevos/aaa1.bin ."
  FILES=(zzz1.bin);  run zzz$m   $m a "cp ../nuevos/zzz1.bin ."
  FILES=(medio.txt); run rep$m   $m a "cp -p ../nuevos/medio.txt ."
  FILES=(.);         run u$m     $m u "cp -p ../nuevos/medio.txt ."
  FILES=(.);         run f$m     $m f "cp -p ../nuevos/medio.txt .; cp ../nuevos/zzz1.bin ."
  FILES=(datos2.bin); run d$m    $m d ":"
done
FILES=(png1.png); run png4 4 a "cp ../nuevos/png1.png ."
FILES=(.);        run png8 4 a "cp ../nuevos/png1.png ."
# Copia: base hecha por PARC con ejecutables (su bloque se re-tipifica en el mismo grupo) y se
# agrega el wav, de otro grupo. Si el bloque viejo se copia, sus bytes siguen siendo los de
# parc en los dos resultados (el lzma/grzip de parc y el de arc.exe dan otros bytes): tiene
# que ser idéntico también en tamaño, e igual al de la base.
for who in f p; do
  rm -rf "w_$who"; mkdir -p "w_$who"
  # los ejecutables del corpus de compat_matrix: ahí el lzma de parc y el de arc.exe difieren
  EXE=${WORK:-/mnt/IA_LAB/agentes/PArc/compat}/corpus/exe
  if [ -d "$EXE" ]; then cp -p "$EXE"/* "w_$who/"; else cp -p c/*.txt "w_$who/"; fi
  (cd "w_$who" && "$PARC" a base.arc . -m4 --no-progress >/dev/null 2>&1)
  cp -p c/audio1.wav "w_$who/"
done
cp w_p/base.arc copia_base.arc
arcx w_f a -m4 base.arc audio1.wav
(cd w_p && "$PARC" a base.arc audio1.wav -m4 --no-progress >/dev/null 2>&1)
printf '%-10s ' copia
out=$(python3 "$OUT/cmp.py" "$PARC" w_p/base.arc w_f/base.arc); echo "$out"
b0=$("$PARC" lb copia_base.arc | grep ' data ' | head -1 | awk '{print $4}')
bp=$("$PARC" lb w_p/base.arc | grep ' data ' | grep -v tta | head -1 | awk '{print $4}')
bf=$("$PARC" lb w_f/base.arc | grep ' data ' | grep -v tta | head -1 | awk '{print $4}')
echo "           bloque viejo: base $b0, parc $bp, arc.exe $bf"
{ echo "$out" | grep -q "estructura =  métodos ="; } && [ "$b0" = "$bp" ] && [ "$b0" = "$bf" ] || fail=$((fail+1))

# --- d con -m explícito: FreeArc recompila TODOS los bloques (Cmdline.hs is_COPYING_COMMAND) ---
for who in f p; do
  rm -rf "w_$who"; cp -a c "w_$who"
  arcx "w_$who" a -m4 base.arc . -xbase.arc
done
arcx w_f d -mlzma -s- base.arc medio.txt
(cd w_p && "$PARC" d base.arc medio.txt -mlzma -s- --no-progress >/dev/null 2>&1)
printf '%-10s ' delm
out=$(python3 "$OUT/cmp.py" "$PARC" w_p/base.arc w_f/base.arc); echo "$out"
t=$(wine "$ARC_EXE" t w_p/base.arc </dev/null 2>&1 | tr '\r' '\n' | grep -a -c 'All OK')
{ echo "$out" | grep -q "estructura =  métodos ="; } && [ "$t" = 1 ] || fail=$((fail+1))

# --- sin recompresión, con -s- se conserva el bloque viejo entero y el archivo nuevo va aparte ---
for who in f p; do
  rm -rf "w_$who"; cp -a c "w_$who"
  arcx "w_$who" a -m1 -s base.arc . -xbase.arc
  cp nuevos/aaa1.bin "w_$who/"
  touch -d '2021-01-01' "w_$who/aaa1.bin"
done
arcx w_f a -m1 -s- base.arc aaa1.bin -xbase.arc
(cd w_p && "$PARC" a base.arc aaa1.bin -m1 -s- -xbase.arc --no-progress >/dev/null 2>&1)
printf '%-10s ' solidkeep
out=$(python3 "$OUT/cmp.py" "$PARC" w_p/base.arc w_f/base.arc); echo "$out"
t=$(wine "$ARC_EXE" t w_p/base.arc </dev/null 2>&1 | tr '\r' '\n' | grep -a -c 'All OK')
{ echo "$out" | grep -q "estructura =  métodos ="; } && [ "$t" = 1 ] || fail=$((fail+1))

echo "== actualización: $fail fallas"
[ $fail -eq 0 ]
