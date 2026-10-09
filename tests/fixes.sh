#!/bin/bash
# tests/fixes.sh — correcciones de docs/BUGS-FREEARC.md: máscaras (P1), archivos ilegibles (P2)
# y enlaces simbólicos (P3).
set -u
ROOT=$(cd "$(dirname "$0")/.." && pwd)
PARC=${PARC_BIN:-$ROOT/build/linux64/parc}
W=${FIXES_WORK:-/mnt/IA_LAB/agentes/PArc/fixes}
rm -rf -- "${W:?}"; mkdir -p "$W" && cd "$W" || exit 2
fail=0
check() { if eval "$2"; then printf '  ok    %s\n' "$1"; else printf '  FALLA %s\n' "$1"; fail=$((fail+1)); fi; }
names() { "$PARC" l "$1" 2>/dev/null | awk 'NR>2 && !/^---/ && !/archivo\(s\)/ {print $5}' | sort | tr '\n' ' '; }

# P1: máscaras
mkdir -p m/src/sub && echo a > m/src/a.txt && echo c > m/src/sub/c.txt && echo p > m/src/x.pas && touch m/makefile
cd m
"$PARC" a ../m1.parc 'src/*.txt' --no-progress >/dev/null 2>&1
check "máscara en un directorio"         '[ "$(names ../m1.parc)" = "src/a.txt " ]'
"$PARC" a ../m2.parc -r 'src/*.txt' --no-progress >/dev/null 2>&1
check "-r busca en subdirectorios"        '[ "$(names ../m2.parc)" = "src/a.txt src/sub/c.txt " ]'
"$PARC" a ../m3.parc '*.*' --no-progress >/dev/null 2>&1
check "*.* incluye nombres sin punto"     'names ../m3.parc | grep -q "makefile" && names ../m3.parc | grep -q "src/x.pas"'
check "nada coincide: error, sin archivo" '! "$PARC" a ../m4.parc "nada*" --no-progress >/dev/null 2>&1 && [ ! -e ../m4.parc ]'
check "comodín en un directorio: error"   '! "$PARC" a ../m5.parc "s*/x.pas" --no-progress >/dev/null 2>&1'
cd ..

# P2: archivo ilegible (como root no hay "Permission denied": se saltea la prueba)
if [ "$(id -u)" != 0 ]; then
  mkdir -p u && echo viejo > u/f1 && echo y > u/f2
  "$PARC" a u.parc u --no-progress >/dev/null 2>&1
  echo nuevo > u/f1; echo nuevo > u/f2; chmod 000 u/f1
  "$PARC" a u.parc u --no-progress >/dev/null 2>&1; code=$?
  chmod 644 u/f1
  check "ilegible: código 6"               '[ $code = 6 ]'
  rm -rf ux; "$PARC" x u.parc -dpux --no-progress >/dev/null 2>&1
  check "ilegible: queda la versión vieja, el resto se actualiza" '[ "$(cat ux/u/f1)" = viejo ] && [ "$(cat ux/u/f2)" = nuevo ]'
fi

# P3: enlaces
mkdir -p s/sub && echo hola > s/real.txt && ln -s real.txt s/rel && ln -s sub s/dir && ln -s .. s/loop \
  && ln -s /etc/passwd s/abs && ln -s noexiste s/roto
timeout 60 "$PARC" a l.parc s --no-progress >/dev/null 2>&1
check ".parc: guarda los enlaces sin recorrerlos" '[ "$("$PARC" l l.parc | grep -c "<LINK>")" = 5 ]'
check "t con enlaces"                      '"$PARC" t l.parc --no-progress | tail -1 | grep -q "Errores: 0"'
rm -rf o; "$PARC" x l.parc -dpo --no-progress >/dev/null 2>&1
check "x: recrea los enlaces"              '[ "$(readlink o/s/rel)" = real.txt ] && [ "$(readlink o/s/dir)" = sub ] && [ "$(cat o/s/rel)" = hola ]'
check "x: no crea el enlace absoluto"      '[ ! -L o/s/abs ]'
rm -rf o2; "$PARC" x l.parc -dpo2 -snld --no-progress >/dev/null 2>&1
check "-snld: lo crea"                     '[ "$(readlink o2/s/abs)" = /etc/passwd ]'
rm -rf oe; "$PARC" e l.parc -dpoe -snld --no-progress >/dev/null 2>&1
check "e: enlace en la raíz"               '[ "$(readlink oe/rel)" = real.txt ]'
echo nuevo > s/nuevo.txt; "$PARC" a l.parc s/nuevo.txt --no-progress >/dev/null 2>&1
check "actualizar conserva los enlaces"    '[ "$("$PARC" l l.parc | grep -c "<LINK>")" = 5 ]'
timeout 60 "$PARC" a l.arc s --no-progress >/dev/null 2>&1
check ".arc: enlace a archivo con contenido, a directorio salteado" '[ "$("$PARC" l l.arc | grep -c "<LINK>")" = 0 ] && "$PARC" l l.arc | grep -q " s/rel$" && ! "$PARC" l l.arc | grep -q " s/dir$"'

echo "== correcciones: $fail fallas"
[ $fail -eq 0 ]
