#!/bin/bash
# tests/parc_crypt.sh — cifrado fuerte de .parc : clave bien
# decodificada (:f), etiqueta de autenticación (:m), 200000 iteraciones de PBKDF2 derivadas
# una sola vez por archivo, y lectura de los .parc cifrados con el esquema anterior.
set -u
ROOT=$(cd "$(dirname "$0")/.." && pwd)
PARC=${PARC_BIN:-$ROOT/build/linux64/parc}
OLD=${PARC_OLD_BIN:-}      # opcional: un parc anterior al cifrado fuerte, para la compatibilidad
W=${PCRYPT_WORK:-/mnt/IA_LAB/agentes/PArc/parc_crypt}
rm -rf -- "${W:?}"; mkdir -p "$W/d" && cd "$W" || exit 2
fail=0
check() { if eval "$2"; then printf '  ok    %s\n' "$1"; else printf '  FALLA %s\n' "$1"; fail=$((fail+1)); fi; }
ms() { echo $(( ($(date +%s%N) - $1) / 1000000 )); }
for i in $(seq 1 20); do seq "$i" 30000 > "d/f$i.txt"; done
head -c 200000 /dev/urandom > d/r.bin

t0=$(date +%s%N)
"$PARC" a c.parc d -s- -pClave -hp --no-progress >/dev/null 2>&1
ta=$(ms "$t0")
meth=$("$PARC" lb c.parc -pClave 2>/dev/null | grep -o 'aes-256/ctr[^ +]*' | head -1)
check "método con :f, :m y 200000 iteraciones" '[[ "$meth" == aes-256/ctr:f:m:n200000:* ]]'
check "una sola derivación al crear 21 bloques (${ta} ms)" '[ "$ta" -lt 3000 ]'
t0=$(date +%s%N)
"$PARC" t c.parc -pClave --no-progress 2>/dev/null | tail -1 | grep -q 'Errores: 0'; ok=$?
tt=$(ms "$t0")
check "t sin errores"                      '[ $ok = 0 ]'
check "una sola derivación al leer (${tt} ms)" '[ "$tt" -lt 3000 ]'
rm -rf o; "$PARC" x c.parc -dpo -pClave --no-progress >/dev/null 2>&1
check "x idéntico"                         'diff -rq d o/d >/dev/null'
check "contraseña mala: código 5"          '{ "$PARC" t c.parc -pOtra --no-progress </dev/null >/dev/null 2>&1; [ $? = 5 ]; }'
check "-hp: sin contraseña no lista"       '! "$PARC" l c.parc </dev/null >/dev/null 2>&1'

for m in -m1 -m2 -m5 -mx -mtor -mppmd -m0; do
  rm -f q.parc; "$PARC" a q.parc d -pClave -hp "$m" --no-progress >/dev/null 2>&1
  check "método $m con etiqueta"            '"$PARC" t q.parc -pClave --no-progress 2>/dev/null | tail -1 | grep -q "Errores: 0"'
done

# Un bit cambiado en los datos cifrados: lo detecta la etiqueta (CTR + CRC no alcanza)
cp c.parc alt.parc
python3 - <<'EOF'
f = open('alt.parc', 'r+b'); f.seek(1000); b = f.read(1); f.seek(1000); f.write(bytes([b[0] ^ 1]))
EOF
check "dato alterado: falla la autenticación" '"$PARC" t alt.parc -pClave --no-progress 2>&1 | grep -q "autenticación falló"'

"$PARC" a u.parc d/f1.txt -p'contraseña日本' --no-progress >/dev/null 2>&1
check "contraseña Unicode (UTF-8)"         '"$PARC" t u.parc -p"contraseña日本" --no-progress 2>/dev/null | tail -1 | grep -q "Errores: 0"'
"$PARC" a n.parc d/f1.txt -pClave -ae=serpent:n5000 --no-progress >/dev/null 2>&1
check "-ae con :n propio se respeta"       '"$PARC" lb n.parc -pClave 2>/dev/null | grep -q "serpent-256/ctr:f:m:n5000"'

# Actualizar un .parc cifrado: los bloques nuevos con el esquema nuevo, y se sigue leyendo
echo nuevo > d/nuevo.txt; "$PARC" a c.parc d/nuevo.txt -pClave -hp --no-progress >/dev/null 2>&1
check "actualizar un .parc cifrado"        '"$PARC" t c.parc -pClave --no-progress 2>/dev/null | tail -1 | grep -q "Errores: 0"'

if [ -n "$OLD" ]; then
  "$OLD" a old.parc d -pClave -hp --no-progress >/dev/null 2>&1
  check ".parc cifrado con el esquema anterior: se lee" '"$PARC" t old.parc -pClave --no-progress 2>/dev/null | tail -1 | grep -q "Errores: 0"'
  "$PARC" a old.parc d/nuevo.txt -pClave -hp --no-progress >/dev/null 2>&1
  check "y se actualiza (mezcla de esquemas)" '"$PARC" t old.parc -pClave --no-progress 2>/dev/null | tail -1 | grep -q "Errores: 0"'
fi

echo "== cifrado .parc: $fail fallas"
[ $fail -eq 0 ]
