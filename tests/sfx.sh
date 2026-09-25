#!/bin/bash
# tests/sfx.sh — autoextraíbles (parc a -sfx) con el módulo parcsfx de Linux.
# Los de Windows se arman igual con -sfx=build/win64/parcsfx.exe y se prueban en las VMs.
set -u
ROOT=$(cd "$(dirname "$0")/.." && pwd)
PARC=${PARC_BIN:-$ROOT/build/linux64/parc}
W=${SFX_WORK:-/mnt/IA_LAB/agentes/PArc/sfx}
rm -rf -- "${W:?}"; mkdir -p "$W/c/sub" && cd "$W" || exit 2
seq 1 200000 > c/texto.txt; head -c 800000 /dev/urandom > c/azar.bin; echo hola > c/sub/chico.txt
fail=0
check() { if eval "$2"; then printf '  ok    %s\n' "$1"; else printf '  FALLA %s\n' "$1"; fail=$((fail+1)); fi; }
sha() { (cd "$1" && find . -type f -print0 | sort -z | xargs -0 sha256sum | sha256sum | cut -c1-16); }
REF=$(sha c)

"$PARC" a x.parc c -m4 -sfx --no-progress >/dev/null 2>&1
check "crea x (ejecutable, sin x.parc)"  '[ -x x ] && [ ! -e x.parc ]'
check "l"                                './x l | grep -q "sub/chico.txt"'
check "t"                                './x t --no-progress | tail -1 | grep -q "Errores: 0"'
rm -rf d1; mkdir d1; (cd d1 && ../x --no-progress >/dev/null 2>&1)
check "extrae al directorio actual, idéntico" '[ "$(sha d1/c)" = "$REF" ]'
rm -rf d2; ./x -dpd2 --no-progress >/dev/null 2>&1
check "-dp"                              '[ "$(sha d2/c)" = "$REF" ]'
check "parc t sobre el autoextraíble"    '"$PARC" t x --no-progress | tail -1 | grep -q "Errores: 0"'

# Sobrescribir: sin -o, pregunta (por la terminal)
echo cambiado > d2/c/texto.txt
(sleep 0.5; printf 'n\nn\nn\n') | timeout 60 script -qc "cd $W && ./x -dpd2 --no-progress" /dev/null >/dev/null 2>&1   # 'n' para cada uno de los 3
check "pregunta y 'n' no sobrescribe"   'grep -q cambiado d2/c/texto.txt'
(sleep 0.5; printf 't\n') | timeout 60 script -qc "cd $W && ./x -dpd2 --no-progress" /dev/null >/dev/null 2>&1
check "'t' sobrescribe todos"           '[ "$(sha d2/c)" = "$REF" ]'
echo cambiado > d2/c/texto.txt
./x -dpd2 --no-progress </dev/null >/dev/null 2>&1
check "sin terminal no sobrescribe"     'grep -q cambiado d2/c/texto.txt'
./x -dpd2 -o+ --no-progress >/dev/null 2>&1
check "-o+ sobrescribe"                 '[ "$(sha d2/c)" = "$REF" ]'

# Cifrado
"$PARC" a e.parc c -m4 -pClave -hp -sfx --no-progress >/dev/null 2>&1
check "-hp: sin contraseña no lista"    '! ./e l </dev/null >/dev/null 2>&1'
rm -rf d3; ./e -dpd3 -pClave --no-progress >/dev/null 2>&1
check "-hp: con -p extrae idéntico"     '[ "$(sha d3/c)" = "$REF" ]'
check "contraseña mala: código 5"       '{ ./e t -pOtra </dev/null >/dev/null 2>&1; [ $? = 5 ]; }'

# Actualizar un autoextraíble: sigue siéndolo
echo nuevo > c/nuevo.txt; REF=$(sha c)
"$PARC" a x c/nuevo.txt --no-progress >/dev/null 2>&1
rm -rf d4; ./x -dpd4 --no-progress >/dev/null 2>&1
check "a sobre el autoextraíble: sigue andando" '[ -x x ] && [ "$(sha d4/c)" = "$REF" ]'

# Con -rr
"$PARC" a r.parc c -m4 -rr -sfx --no-progress >/dev/null 2>&1
check "-rr: t OK"                        './r t --no-progress | tail -1 | grep -q "Errores: 0"'

check "-sfx con -v: rechazado"           '! "$PARC" a v.parc c -sfx -v1m --no-progress >/dev/null 2>&1'
check "-sfx con .arc"                    '"$PARC" a a.arc c -m4 -sfx --no-progress >/dev/null 2>&1 && ./a t --no-progress | tail -1 | grep -q "Errores: 0"'

echo "== sfx: $fail fallas"
[ $fail -eq 0 ]
