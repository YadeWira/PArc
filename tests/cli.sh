#!/bin/bash
# tests/cli.sh — humo de toda la CLI: comandos, opciones y códigos de salida.
set -u
ROOT=$(cd "$(dirname "$0")/.." && pwd)
PARC=${PARC_BIN:-$ROOT/build/linux64/parc}
W=${CLI_WORK:-/tmp/opencode/cli_test}
rm -rf -- "${W:?}"; mkdir -p "$W/src/sub" "$W/src/empty" && cd "$W" || exit 2
fail=0
ck() { if eval "$2"; then printf '  ok    %s\n' "$1"; else printf '  FAIL %s\n' "$1"; fail=$((fail+1)); fi; }

printf 'alpha\n' > src/a.txt; printf 'beta\n' > src/sub/b.txt; printf 'gamma\n' > src/c.txt
ln -s a.txt src/link

# a, l, lb, t
ck "a crea"                    '"$PARC" a t.parc src -m4 --no-progress >/dev/null 2>&1; [ -s t.parc ]'
ck "l lista"                   '"$PARC" l t.parc | grep -q "src/a.txt"'
ck "l filtro"                  '"$PARC" l t.parc "*.txt" | grep -q "a.txt"'
ck "lb bloques"                '"$PARC" lb t.parc | grep -q "Data blocks"'
ck "t verifica"                '"$PARC" t t.parc --no-progress | grep -q "Errors: 0"'

# x, e, enlaces, -so
mkdir outx; ck "x con rutas"    '"$PARC" x t.parc -dpoutx --no-progress >/dev/null 2>&1; [ -f outx/src/a.txt ] && [ -f outx/src/sub/b.txt ]'
mkdir oute; (cd oute && "$PARC" e ../t.parc --no-progress >/dev/null 2>&1); ck "e sin rutas" 'test -f oute/a.txt && test -f oute/b.txt'
ck "x symlink"                 'test -L outx/src/link'
ck "-so a stdout"              '"$PARC" x t.parc src/a.txt -so 2>/dev/null | grep -q alpha'

# a reemplaza
printf 'alpha2\n' > src/a.txt
ck "a reemplaza"               '"$PARC" a t.parc src/a.txt --no-progress >/dev/null 2>&1; "$PARC" x t.parc src/a.txt -so 2>/dev/null | grep -q alpha2'

# u agrega y reemplaza; f solo existentes; d borra
sleep 1; printf 'alpha3\n' > src/a.txt; printf 'delta\n' > src/d.txt
ck "u actualiza y agrega"      '"$PARC" u t.parc src --no-progress >/dev/null 2>&1; "$PARC" x t.parc src/a.txt -so 2>/dev/null | grep -q alpha3 && "$PARC" l t.parc | grep -q d.txt'
sleep 1; printf 'alpha4\n' > src/a.txt; printf 'epsilon\n' > src/e.txt
ck "f actualiza, no agrega"    '"$PARC" f t.parc src --no-progress >/dev/null 2>&1; "$PARC" x t.parc src/a.txt -so 2>/dev/null | grep -q alpha4 && ! "$PARC" l t.parc | grep -q e.txt'
ck "d borra"                   '"$PARC" d t.parc src/c.txt --no-progress >/dev/null 2>&1; ! "$PARC" l t.parc | grep -q "src/c.txt"'

# stdin/stdout
ck "a -si"                     'printf "zeta\n" | "$PARC" a si.parc -siz.txt --no-progress >/dev/null 2>&1; "$PARC" l si.parc | grep -q z.txt'
ck "a a stdout (-)"            '"$PARC" a - src/a.txt --no-progress > so.parc 2>/dev/null; "$PARC" l so.parc | grep -q a.txt'

# cifrado
ck "a -p / x -p"               '"$PARC" a enc.parc src/a.txt -psecreto --no-progress >/dev/null 2>&1; "$PARC" x enc.parc src/a.txt -psecreto -so 2>/dev/null | grep -q alpha4'
ck "a -hp oculta lista"        '"$PARC" a hdr.parc src/a.txt -hpsecreto --no-progress >/dev/null 2>&1; ! "$PARC" l hdr.parc 2>/dev/null | grep -q a.txt; "$PARC" l hdr.parc -psecreto 2>/dev/null | grep -q a.txt'

# volúmenes, recuperación, sólidos, exclusiones y máscaras recursivas
ck "a -v / x"                  '"$PARC" a vol.parc src/a.txt -v1k --no-progress >/dev/null 2>&1; [ -f vol.parc.001 ]; "$PARC" x vol.parc.001 -so 2>/dev/null | grep -q alpha4'
ck "a -rr / r"                 '"$PARC" a rr.parc src -rr5% --no-progress >/dev/null 2>&1; "$PARC" r rr.parc | grep -q "No damaged sectors"'
ck "-s- no sólido"             '"$PARC" a solid.parc src -s- --no-progress >/dev/null 2>&1; [ -s solid.parc ]'
ck "-x excluye"                '"$PARC" a ex.parc src "-x*.txt" --no-progress >/dev/null 2>&1; ! "$PARC" l ex.parc | grep -q "src/a.txt"'
ck "-r máscara recursiva"      '"$PARC" a rec.parc "src/*.txt" -r --no-progress >/dev/null 2>&1; "$PARC" l rec.parc | grep -q "sub/b.txt"'
ck "-m método explícito"       '"$PARC" a met.parc src/a.txt -mlzma --no-progress >/dev/null 2>&1; "$PARC" l met.parc | grep -q a.txt'

# sobrescritura
mkdir ov; "$PARC" x t.parc -dpov --no-progress >/dev/null 2>&1
printf 'cambiado\n' > ov/src/a.txt
ck "-o- no sobrescribe"        '"$PARC" x t.parc -dpov -o- --no-progress >/dev/null 2>&1; grep -q cambiado ov/src/a.txt'
ck "-o+ sobrescribe"           '"$PARC" x t.parc -dpov -o+ --no-progress >/dev/null 2>&1; grep -q alpha4 ov/src/a.txt'

# ayuda y versión
ck "sin argumentos: 0"         '"$PARC" >/dev/null 2>&1; [ $? = 0 ]'
ck "--version"                '"$PARC" --version | grep -q "^PArc 0.0.2"'
ck "help: 0"                  '"$PARC" help >/dev/null 2>&1; [ $? = 0 ]'
ck "help de comando"          '"$PARC" help x | grep -q "Extract keeping"'
ck "comando desconocido: 1"   '"$PARC" nope >/dev/null 2>&1; [ $? = 1 ]'

# dañado
cp t.parc bad.parc; printf X | dd of=bad.parc bs=1 seek=100 conv=notrunc 2>/dev/null
ck "t dañado: código 2"        '"$PARC" t bad.parc --no-progress >/dev/null 2>&1; [ $? = 2 ]'
ck "x dañado: código 2"        '"$PARC" x bad.parc -dpbadout --no-progress >/dev/null 2>&1; [ $? = 2 ]'

# errores de uso y E/S
ck "archivo inexistente: 4"    '"$PARC" l noexiste.parc >/dev/null 2>&1; [ $? = 4 ]'
ck "mensaje de apertura"       '"$PARC" l noexiste.parc 2>&1 | grep -q "could not open"'
ck ".arc rechazado"            '"$PARC" a x.arc src >/dev/null 2>&1; [ $? = 1 ] && "$PARC" a x.arc src 2>&1 | grep -q "only .parc"'
ck "-fmt Unknown option"          '"$PARC" a x.parc src -fmt=arc >/dev/null 2>&1; [ $? = 1 ] && "$PARC" a x.parc src -fmt=arc 2>&1 | grep -q "Unknown option"'
ck "-sfx Unknown option"          '"$PARC" a x.parc src -sfx >/dev/null 2>&1; [ $? = 1 ] && "$PARC" a x.parc src -sfx 2>&1 | grep -q "Unknown option"'
ck "opción Unknown option"        '"$PARC" a x.parc src -zzz >/dev/null 2>&1; [ $? = 1 ] && "$PARC" a x.parc src -zzz 2>&1 | grep -q "Unknown option"'
ck "sin archivos"              '"$PARC" a vacio.parc >/dev/null 2>&1; [ $? = 1 ]'
ck "-si solo con a"            '"$PARC" l t.parc -si >/dev/null 2>&1; [ $? = 1 ]'
ck "-x sin máscara: 1"         '"$PARC" a x.parc src -x >/dev/null 2>&1; [ $? = 1 ]'
ck "-dp sin directorio: 1"     '"$PARC" x t.parc -dp >/dev/null 2>&1; [ $? = 1 ]'
ck "f sin archivo: 1"          '"$PARC" f no.parc src >/dev/null 2>&1; [ $? = 1 ]'
ck "d sin archivo: 1"          '"$PARC" d no.parc src >/dev/null 2>&1; [ $? = 1 ]'
ck "r sin registro: 1"         '"$PARC" r t.parc >/dev/null 2>&1; [ $? = 1 ]'
ck "r avisa el registro"       '"$PARC" r t.parc 2>&1 | grep -q "recovery record"'

echo "== CLI: $fail failures"
[ $fail -eq 0 ]
