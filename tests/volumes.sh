#!/bin/bash
# tests/volumes.sh — archivos .parc en volúmenes (-v<tamaño>): x.parc.001, x.parc.002, ...
set -u
ROOT=$(cd "$(dirname "$0")/.." && pwd)
PARC=${PARC_BIN:-$ROOT/build/linux64/parc}
W=${VOL_WORK:-/mnt/IA_LAB/agentes/PArc/volumes}
rm -rf -- "${W:?}"; mkdir -p "$W/c/sub" && cd "$W" || exit 2
seq 1 300000 > c/texto.txt; head -c 3000000 /dev/urandom > c/azar.bin; cp c/azar.bin c/sub/copia.bin
head -c 1500000 /dev/urandom > c/sub/otro.bin; : > c/vacio
fail=0
ok() { printf '  ok    %s\n' "$1"; }
bad() { printf '  FALLA %s\n' "$1"; fail=$((fail+1)); }
check() { if eval "$2"; then ok "$1"; else bad "$1"; fi; }
sha() { (cd "$1" && find . -type f -print0 | sort -z | xargs -0 sha256sum | sha256sum | cut -c1-16); }
REF=$(sha c)
xsame() {   # xsame <archivo o primer volumen>: extrae y compara con c/
  rm -rf x; mkdir x; "$PARC" x "$1" -dpx --no-progress "${@:2}" >/dev/null 2>&1 && [ "$(sha x/c)" = "$REF" ]
}

"$PARC" a v.parc c -m4 -v1m --no-progress >/dev/null 2>&1
n=$(ls v.parc.[0-9][0-9][0-9] 2>/dev/null | wc -l)
check "crea volúmenes ($n de 1 MB, el último más chico)" '[ $n -ge 4 ] && [ ! -e v.parc ] && [ $(stat -c %s v.parc.001) = 1048576 ] && [ $(stat -c %s $(ls v.parc.[0-9]* | tail -1)) -le 1048576 ]'
check "parc t por la base (v.parc)"        '"$PARC" t v.parc --no-progress 2>&1 | tail -1 | grep -q "Errores: 0"'
check "parc t por el primero (v.parc.001)" '"$PARC" t v.parc.001 --no-progress 2>&1 | tail -1 | grep -q "Errores: 0"'
check "parc x idéntico"                    'xsame v.parc.001'
check "parc l"                             '"$PARC" l v.parc | grep -q "sub/otro.bin"'
cat v.parc.[0-9][0-9][0-9] > junto.parc
check "unidos con cat: un .parc normal"    'xsame junto.parc'
check "-v con .arc: rechazado (solo .parc)"            '! "$PARC" a v.arc c -v1m --no-progress >/dev/null 2>&1 && [ ! -e v.arc.001 ] && [ ! -e v.arc.tmp.001 ]'

# Actualizar: conserva el tamaño de volumen; borrar algo grande deja menos volúmenes y los que
# sobran se borran
cp -a c c2; echo nuevo > c/nuevo.txt; REF=$(sha c)
"$PARC" a v.parc c/nuevo.txt --no-progress >/dev/null 2>&1
check "a sobre volúmenes: sigue en volúmenes de 1 MB" '[ $(stat -c %s v.parc.001) = 1048576 ] && [ ! -e v.parc ] && xsame v.parc'
before=$(ls v.parc.[0-9]* | wc -l)
"$PARC" d v.parc c/azar.bin c/sub/copia.bin --no-progress >/dev/null 2>&1
after=$(ls v.parc.[0-9]* | wc -l)
rm -f c/azar.bin c/sub/copia.bin; REF=$(sha c)
check "d: menos volúmenes ($before -> $after) y ninguno sobrante" '[ $after -lt $before ] && [ ! -e v.parc.$(printf %03d $((after+1))) ] && xsame v.parc'
rm -rf c; mv c2 c; REF=$(sha c)

# De un archivo suelto a volúmenes y de vuelta
"$PARC" a s.parc c -m4 --no-progress >/dev/null 2>&1
"$PARC" a s.parc c/texto.txt -v1m --no-progress >/dev/null 2>&1
check "suelto -> volúmenes: el suelto desaparece" '[ ! -e s.parc ] && [ -e s.parc.001 ] && xsame s.parc'

# Recuperación: -rr con volúmenes, dañar un byte del segundo volumen y reparar
rm -f r.parc.* fixed.r.parc
"$PARC" a r.parc c -m4 -v1m -rr5% --no-progress >/dev/null 2>&1
printf 'XXXXXXXX' | dd of=r.parc.002 bs=1 seek=5000 conv=notrunc 2>/dev/null
check "t detecta el daño en el volumen 2"   '! "$PARC" t r.parc --no-progress >/dev/null 2>&1'
"$PARC" r r.parc >/dev/null 2>&1
check "r repara -> fixed.r.parc (una pieza)" '[ -e fixed.r.parc ] && xsame fixed.r.parc'

# Cifrado con -hp
"$PARC" a e.parc c -m4 -v1m -pClave -hp --no-progress >/dev/null 2>&1
check "-hp en volúmenes: sin contraseña no lista" '! "$PARC" l e.parc </dev/null >/dev/null 2>&1'
check "-hp en volúmenes: con contraseña extrae"  'xsame e.parc -pClave'

# Volumen faltante: error claro, no un cuelgue
mv v.parc.002 falta.002
check "falta un volumen: error"             '! "$PARC" t v.parc --no-progress >/dev/null 2>&1'
mv falta.002 v.parc.002

# Ctrl-C a mitad: no quedan temporales
head -c 60000000 /dev/urandom > grande.bin
"$PARC" a g.parc grande.bin -mx -v5m --no-progress >/dev/null 2>&1 & pid=$!
sleep 1.5; kill -INT $pid; wait $pid; rc=$?
check "Ctrl-C: código 130 y sin temporales" '[ $rc = 130 ] && [ -z "$(ls | grep "g.parc")" ]'

echo "== volúmenes: $fail fallas"
[ $fail -eq 0 ]
