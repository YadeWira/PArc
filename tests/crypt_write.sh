#!/bin/bash
# tests/crypt_write.sh — PArc CIFRA y FreeArc descifra.
#
# Por cada cifrado x modo, con y sin -hp: `parc a -p... -ae=...` y después
#   arc.exe t (autoridad) · arc.exe x comparado por sha256 · arc.exe t con contraseña mala
#   (tiene que fallar) · parc t · y, sin -hp, que el listado se vea sin contraseña (con -hp no).
# Además: .parc cifrado, `d` sobre un archivo cifrado sin -p (el bloque reempaquetado tiene
# que seguir cifrado) y una contraseña no ASCII (FreeArc usa el byte bajo de cada carácter).
#
# Uso: tests/crypt_write.sh   (usa el corpus de tests/compat_matrix.sh, sin el archivo grande)
set -u
ROOT=$(cd "$(dirname "$0")/.." && pwd)
PARC=${PARC_BIN:-$ROOT/build/linux64/parc}
ARC_EXE=${ARC_EXE:-/mnt/IA_LAB/agentes/PArc/ref/Arc.exe}
export WINEPREFIX=${WINEPREFIX:-/mnt/IA_LAB/agentes/PArc/wine} WINEDEBUG=-all
CORPUS=${WORK:-/mnt/IA_LAB/agentes/PArc/compat}/corpus
OUT=${CRYPT_WORK:-/mnt/IA_LAB/agentes/PArc/crypt_write}
[ -d "$CORPUS" ] || { echo "no hay corpus en $CORPUS: correr tests/compat_matrix.sh primero" >&2; exit 2; }
rm -rf -- "${OUT:?}"; mkdir -p "$OUT/c"
for d in chicos raros dir_vacio exe varios texto_grande imagenes; do
  [ -e "$CORPUS/$d" ] && cp -r "$CORPUS/$d" "$OUT/c/"
done
cd "$OUT" || exit 2

sha_tree() { (cd "$1" 2>/dev/null && find . -type f -print0 | sort -z | xargs -0 sha256sum | sha256sum | cut -c1-16); }
arc_t() { wine "$ARC_EXE" t "$@" </dev/null 2>&1 | tr '\r' '\n' | grep -a -c 'All OK'; }
REF=$(sha_tree c)
fail=0
check() { if [ "$2" = 1 ]; then printf '  ok    %s\n' "$1"; else printf '  FALLA %s\n' "$1"; fail=$((fail+1)); fi; }

for alg in aes aes-128/cfb serpent-256/ctr serpent-192/cfb blowfish-448/ctr blowfish-448/cfb twofish-256/ctr twofish-128/cfb; do
  for hp in "" "-hp"; do
    k="$alg ${hp:-   }"
    rm -rf m.arc x; mkdir x
    if ! "$PARC" a m.arc c -m2 -pClave7 $hp -ae=$alg --no-progress >/dev/null 2>&1; then check "$k: parc a" 0; continue; fi
    (cd x && wine "$ARC_EXE" x -o+ -pClave7 ../m.arc </dev/null >/dev/null 2>&1)
    ok=0
    [ "$(arc_t -pClave7 m.arc)" = 1 ] && [ "$(sha_tree x/c)" = "$REF" ] && [ "$(arc_t -pOtra m.arc)" = 0 ] &&
      "$PARC" t m.arc -pClave7 --no-progress 2>&1 | tail -1 | grep -q 'Errores: 0' &&
      ! "$PARC" t m.arc -pOtra --no-progress </dev/null >/dev/null 2>&1 && ok=1
    # Sin -hp el directorio va en claro (se lista sin contraseña); con -hp no
    listed=$(wine "$ARC_EXE" l m.arc </dev/null 2>&1 | tr '\r' '\n' | grep -a -c 'texto_grande')
    if [ -z "$hp" ]; then [ "$listed" -gt 0 ] || ok=0; else [ "$listed" = 0 ] || ok=0; fi
    check "$k: arc.exe t/x, contraseña mala rechazada, parc t, directorio" $ok
  done
done

rm -rf p.parc px; mkdir px
"$PARC" a p.parc c -m4 -hpZ9 --no-progress >/dev/null 2>&1
"$PARC" x p.parc -dppx -hpZ9 --no-progress >/dev/null 2>&1
ok=0; [ "$(sha_tree px/c)" = "$REF" ] && ! "$PARC" l p.parc </dev/null >/dev/null 2>&1 && ok=1
check ".parc con -hp: x idéntico, sin contraseña no lista" $ok

rm -f u.arc
"$PARC" a u.arc c/chicos c/exe -m4 -pK1 --no-progress >/dev/null 2>&1
(sleep 1; printf 'K1\n') | script -qc "$PARC d u.arc 'c/chicos/*2*' --no-progress" /dev/null >/dev/null 2>&1
ok=0; [ "$(arc_t -pK1 u.arc)" = 1 ] &&
  [ "$("$PARC" lb u.arc -pK1 | grep 'data .*orig=[1-9]' | grep -vc 'aes-256/ctr')" = 0 ] && ok=1
check "d sin -p (pide la contraseña): el bloque reempaquetado sigue cifrado, arc.exe t" $ok

rm -f n.arc
"$PARC" a n.arc c/raros -m4 '-pñandú日本' --no-progress >/dev/null 2>&1
ok=0; [ "$(arc_t '-pñandú日本' n.arc)" = 1 ] && ok=1
check "contraseña no ASCII: arc.exe t" $ok

echo "== cifrado: $fail fallas"
[ $fail -eq 0 ]
