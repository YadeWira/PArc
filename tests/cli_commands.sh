#!/bin/bash
# tests/cli_commands.sh — comandos de FreeArc 0.67 agregados a PArc: c, cw, ch, rr, create, j,
# m, mf (-d/-df), v, lt y k, con sus casos de error.
set -u
export LC_ALL=C
ROOT=$(cd "$(dirname "$0")/.." && pwd)
PARC=${PARC_BIN:-$ROOT/build/linux64/parc}
W=${CLICMD_WORK:-${TMPDIR:-/tmp}/parc_cli_commands}
rm -rf -- "${W:?}"; mkdir -p "$W" && cd "$W" || exit 2
fail=0
ck() { if eval "$2"; then printf '  ok    %s\n' "$1"; else printf '  FAIL  %s\n' "$1"; fail=$((fail+1)); fi; }
P() { "$PARC" "$@" --no-progress </dev/null; }
q() { "$PARC" "$@" --no-progress </dev/null >/dev/null 2>&1; }
code() { "$PARC" "$@" --no-progress </dev/null >/dev/null 2>&1; echo $?; }
names() { P l "$@" 2>/dev/null | awk '/^  ----/{n++; next} n==1 {print $NF}'; }
okt() { P t "$@" 2>/dev/null | tail -1 | grep -q 'All OK'; }
KDF=-ae=chacha:t1:m8m:p1

mkdir -p src/sub src/empty
printf 'alpha\n' > src/a.txt; printf 'beta\n' > src/sub/b.txt; seq 1 50000 > src/n.txt
head -c 200000 /dev/urandom > src/r.bin

echo '-- c / cw / -z / --archive-comment'
q a c.parc src --archive-comment='first comment'
ck "a --archive-comment"                      '[ "$(P cw c.parc -)" = "first comment" ]'
printf 'from a file\nline 2\n' > cmt.txt; q c c.parc -zcmt.txt
ck "c -z<file>"                               'P cw c.parc - | cmp -s - cmt.txt'
q cw c.parc out.txt
ck "cw <file>"                                'cmp -s out.txt cmt.txt'
printf 'via stdin' | "$PARC" c c.parc -z --no-progress >/dev/null 2>&1
ck "c -z (stdin)"                             '[ "$(P cw c.parc -)" = "via stdin" ]'
ck "l muestra el comentario"                  'P l c.parc | grep -q "Comment: via stdin"'
q c c.parc --archive-comment=
ck "c vacío lo quita"                         '[ -z "$(P cw c.parc -)" ]'
ck "c sin comentario: error"                  '[ $(code c c.parc) = 1 ]'
ck "cw sin destino: error"                    '[ $(code cw c.parc) = 1 ]'
ck "c conserva los datos (bloques copiados)"  'okt c.parc && [ "$(P lb c.parc | grep "^  data" | wc -l)" -ge 1 ]'

echo '-- ch'
q a ch.parc src -m2; m0=$(P lb ch.parc | grep "^  data" | tail -1 | awk '{print $NF}')
q ch ch.parc -m5
m1=$(P lb ch.parc | grep "^  data" | tail -1 | awk '{print $NF}')
ck "ch -m5 recomprime ($m0 -> $m1)"           '[ "$m0" != "$m1" ] && okt ch.parc && [ "$(names ch.parc | wc -l)" = 7 ]'
q ch ch.parc -rr5%
ck "ch -rr5% agrega registro"                 'P lb ch.parc | grep -q "recovery=\"5%\"" && okt ch.parc'
q ch ch.parc -rr-
ck "ch -rr- lo quita"                         'P lb ch.parc | grep -q "recovery=\"\""'
ck "ch con nombres: error"                    '[ $(code ch ch.parc src/a.txt) = 1 ]'
ck "ch inexistente: error"                    '[ $(code ch nope.parc -m1) = 1 ] && [ ! -e nope.parc ]'
cp ch.parc ch.bak; q ch ch.parc
ck "ch sin opciones: copia los bloques"       '[ "$(P lb ch.parc | grep "^  data" | awk "{print \$NF}")" = "$(P lb ch.bak | grep "^  data" | awk "{print \$NF}")" ]'

echo '-- ch: cifrado'
q a enc.parc src -m2
q ch enc.parc -pOld -hp $KDF
ck "ch -p -hp: cifra todo"                    '[ $(code l enc.parc) = 5 ] && okt enc.parc -pOld'
q ch enc.parc -pNew $KDF -opOld
ck "ch -p<nueva> -op<vieja>: cambia"          'okt enc.parc -pNew && [ $(code t enc.parc -pOld) = 5 ] && [ $(code l enc.parc) = 5 ]'
c=$(code ch enc.parc -p-)
ck "ch -p- sin la contraseña vieja: 5"        '[ $c = 5 ] && okt enc.parc -pNew'
q ch enc.parc -p- -opNew
ck "ch -p- -op: quita el cifrado"             'okt enc.parc && ! P lb enc.parc | grep -q "xchacha20\|aes256gcm"'
q a enc2.parc src -pK -hp $KDF; q k enc2.parc -pK $KDF
ck "ch/k con la misma -p: encabezados siguen cifrados"  '[ $(code l enc2.parc) = 5 ] && okt enc2.parc -pK'
q a enc3.parc src -pK -hp $KDF; q ch enc3.parc -hp- -pK
ck "ch -hp-: solo los encabezados en claro"   '[ $(code l enc3.parc) = 0 ] && [ $(code t enc3.parc) = 5 ] && okt enc3.parc -pK'

echo '-- rr y r'
q a rr.parc src -m3
q rr4% rr.parc
ck "rr4%: registro de recuperación"           'P lb rr.parc | grep -q "recovery=\"4%\""'
python3 - <<'EOF'
f = open('rr.parc', 'r+b'); f.seek(5000); b = f.read(64); f.seek(5000); f.write(bytes(x ^ 0xFF for x in b)); f.close()
EOF
ck "rr: dañado falla t"                       '[ $(code t rr.parc) = 2 ]'
q r rr.parc
ck "rr + r: reparado"                         'okt fixed.rr.parc'
ck "rr sobre inexistente: error"              '[ $(code rr nope.parc) = 1 ]'

echo '-- create'
q a cr.parc src/a.txt src/sub; q create cr.parc src/n.txt
ck "create reemplaza el existente"            '[ "$(names cr.parc)" = src/n.txt ]'
q create cr2.parc src/a.txt
ck "create nuevo"                             '[ "$(names cr2.parc)" = src/a.txt ]'
ck "create sin archivos: error, sin tocar"    '[ $(code create cr.parc) = 1 ] && [ "$(names cr.parc)" = src/n.txt ]'

echo '-- j'
mkdir -p ja jb; echo one > ja/x.txt; echo old > ja/same.txt; seq 1 9999 > ja/big.txt
echo new > jb/same.txt; echo two > jb/y.txt
q a JA.parc ja -ep1 -s-; q a JB.parc jb -ep1 -m1
mb=$(P lb JB.parc | grep "^  data" | grep -v "orig=0 " | awk '{print $NF}' | sort)
q j JA.parc JB.parc
ck "j junta los archivos"                     '[ "$(names JA.parc | sort | tr "\n" " ")" = "big.txt same.txt x.txt y.txt " ] && okt JA.parc'
ck "j: el que se junta gana (mismo nombre)"   '[ "$(P x JA.parc same.txt -so 2>/dev/null)" = new ]'
ck "j: bloques copiados con su método"        'P lb JA.parc | grep -q "$(echo "$mb" | head -1)"'
ck "j consigo mismo: error"                   '[ $(code j JA.parc JA.parc) = 4 ]'
ck "j inexistente: error, sin tocar"          'cp JA.parc ja.bak; [ $(code j JA.parc nope.parc) = 4 ] && cmp -s JA.parc ja.bak'
ck "j sin archivos: error"                    '[ $(code j JA.parc) = 1 ]'
q a JE.parc jb -ep1 -pE $KDF; q a JC.parc ja -ep1
q j JC.parc JE.parc -pE
ck "j de un cifrado: sus bloques siguen cifrados"  'P lb JC.parc | grep -q xchacha20 && okt JC.parc -pE && [ $(code t JC.parc) = 5 ]'
q a JF.parc ja -ep1 -pF $KDF
ck "j: -p distinta a la de los bloques: 5"    '[ $(code j JF.parc JE.parc -pF) = 5 ]'

echo '-- m / mf / -d / -df'
mk() { rm -rf mv; mkdir -p mv/d/e mv/keep; echo x > mv/d/f; echo y > mv/g; echo z > mv/keep/z; ln -s ../../target.txt mv/lnk; echo T > target.txt; }
mk; q m M.parc mv -x'*keep*'
ck "m: borra archivos y carpetas vacías"      '[ ! -e mv/g ] && [ ! -e mv/d ] && [ -f mv/keep/z ] && okt M.parc && names M.parc | grep -qx mv/d/f'
ck "m: borra el enlace, no su destino"        '[ ! -L mv/lnk ] && [ "$(cat target.txt)" = T ]'
mk; q mf MF.parc mv
ck "mf: solo archivos, carpetas quedan"       '[ ! -e mv/g ] && [ ! -e mv/d/f ] && [ -d mv/d/e ] && [ ! -e mv/keep/z ]'
mk; q a D.parc mv -d
ck "a -d = m"                                 '[ ! -e mv/d ] && [ ! -e mv/keep ] && okt D.parc'
mk; q a DF.parc mv -df
ck "a -df = mf"                               '[ ! -e mv/g ] && [ -d mv/d/e ]'
mk; c=$(code m nodir/M2.parc mv)
ck "m con escritura fallida: nada se borra"   '[ $c = 4 ] && [ -f mv/g ] && [ -f mv/d/f ] && [ -L mv/lnk ]'
mk; seq 1 20000 > mv/d/big; c=$(PARC_TEST_FLIP=2000 "$PARC" m MT.parc mv -m0 -t --no-progress </dev/null >/dev/null 2>&1; echo $?)
ck "m -t con test fallido: nada se borra"     '[ $c = 2 ] && [ -f mv/g ] && [ -f mv/d/f ]'
mk; q a U.parc mv; sleep 1; echo y2 > mv/g; q u U.parc mv -d
ck "u -d: borra lo actualizado y lo que no cambió no"  '[ ! -e mv/g ] && [ -f mv/d/f ]'
ck "-d con x: error"                          '[ $(code x U.parc -d) = 1 ]'
ck "m a stdout: error"                        '[ $(code m - mv) = 1 ]'

echo '-- v / lt'
q a v.parc src -m3
out=$(P v v.parc)
ck "v: ns, permisos, ratio, bloque y método"  'echo "$out" | grep -qE "[0-9]{4}-[0-9]{2}-[0-9]{2} [0-9:]{8}\.[0-9]{9}" && echo "$out" | grep -q -- "-rw" && echo "$out" | grep -q "%" && echo "$out" | grep -q "src/n.txt" && echo "$out" | grep -qE "(lzma|tor|ppmd|grzip|lzp|dict)"'
ck "v con patrón"                             '[ "$(P v v.parc "*.bin" | grep -c "      src/")" = 1 ]'
out=$(P lt v.parc)
ck "lt: bloques y offsets por archivo"        'echo "$out" | grep -q "Data blocks:" && echo "$out" | grep -q "^Files:" && echo "$out" | grep -qE "^  [0-9]+ +[0-9]+ +[0-9]+ +[0-9]+ +[0-9A-F]{8}"'

echo '-- k'
q a k.parc src; q k k.parc
ck "k: bloqueado (lb)"                        'P lb k.parc | grep -q "locked=yes"'
for c in "a k.parc src/a.txt" "u k.parc src" "f k.parc src" "d k.parc src/a.txt" "ch k.parc -m1" "c k.parc --archive-comment=x" "rr k.parc" "j k.parc JB.parc" "k k.parc" "m k.parc src/a.txt" "create k.parc src/a.txt"; do
  r=$(code $c)
  ck "k: '$c' se niega (1)"                   '[ $r = 1 ]'
done
ck "k: el mensaje lo dice"                    'P a k.parc src/a.txt 2>&1 | grep -q "is locked"'
ck "k: t, l, x siguen"                        'okt k.parc && names k.parc | grep -q a.txt && [ $(code x k.parc -dpkx) = 0 ] && [ -f kx/src/a.txt ]'
ck "m sobre bloqueado no borra"               '[ -f src/a.txt ]'
q a k2.parc src -k
ck "a -k bloquea"                             'P lb k2.parc | grep -q "locked=yes"'

echo "== CLI commands: $fail failures"
[ $fail -eq 0 ]
