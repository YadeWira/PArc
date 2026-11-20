#!/bin/bash
# tests/cli_options.sh — opciones de FreeArc 0.67 agregadas a PArc: -mt, -t/-tp, -y, -n y
# @listas, -ep/-ep1/-ap, -ag, filtros -sm/-sl/-ta/-tb/-tn/-to, --dirs/-ed/--nodates/-tk/-tl,
# -w, -lc/-ld, -kb, --sync, -mc, --print-config y -kf. Cada una sola y combinadas.
set -u
export LC_ALL=C
ROOT=$(cd "$(dirname "$0")/.." && pwd)
PARC=${PARC_BIN:-$ROOT/build/linux64/parc}
W=${CLIOPT_WORK:-${TMPDIR:-/tmp}/parc_cli_options}
rm -rf -- "${W:?}"; mkdir -p "$W" && cd "$W" || exit 2
fail=0
ck() { if eval "$2"; then printf '  ok    %s\n' "$1"; else printf '  FAIL  %s\n' "$1"; fail=$((fail+1)); fi; }
P() { "$PARC" "$@" --no-progress </dev/null; }
q() { "$PARC" "$@" --no-progress </dev/null >/dev/null 2>&1; }
code() { "$PARC" "$@" --no-progress </dev/null >/dev/null 2>&1; echo $?; }
names() { P l "$@" 2>/dev/null | awk '/^  ----/{n++; next} n==1 {print $NF}'; }

mk() {   # árbol de prueba
  rm -rf src; mkdir -p src/sub/deep src/empty src/docs
  printf 'alpha\n' > src/a.txt; printf 'beta\n' > src/sub/b.txt; printf 'gamma\n' > src/sub/deep/c.log
  printf 'doc\n' > src/docs/d.md
  head -c 300000 /dev/urandom > src/big.bin; head -c 2000 /dev/urandom > src/small.bin
  touch -d '2020-01-15 12:00:00' src/a.txt src/sub/b.txt
  touch -d '2024-06-01 08:00:00' src/sub/deep/c.log
}
mk

echo '-- -mt'
PARC_THREADS=1 q a e1.parc src -m1 -s-; q a m1.parc src -m1 -mt1 -s-
ck "-mt1 = PARC_THREADS=1 (mismos métodos)"  '[ "$(P lb e1.parc | grep -c "plz:2")" -gt 0 ] && diff <(P lb e1.parc | grep -o "[a-z0-9:+]*$" | sort) <(P lb m1.parc | grep -o "[a-z0-9:+]*$" | sort) >/dev/null'
PARC_THREADS=1 q a m4.parc src -m1 -mt4 -s-
ck "-mt4 manda sobre PARC_THREADS=1"          '! P lb m4.parc | grep -q "plz:2"'
ck "-mt0 = por defecto"                       '[ $(code a m0.parc src -mt0) = 0 ]'

echo '-- -t / -tp'
ck "-t: prueba después (All OK dos veces)"   '[ "$(P a t1.parc src -t 2>&1 | grep -c "All OK")" = 2 ]'
c=$(PARC_TEST_FLIP=-200 "$PARC" a t2.parc src -m2 -t --no-progress </dev/null >/dev/null 2>&1; echo $?)
ck "-t: archivo dañado tras escribir -> código 2"  '[ "$c" = 2 ]'
q a tp.parc src -m2; cp tp.parc tp.orig
python3 - <<'EOF'
f = open('tp.parc', 'r+b'); f.seek(-200, 2); b = f.read(1); f.seek(-200, 2); f.write(bytes([b[0] ^ 0x55])); f.close()
EOF
cp tp.parc tp.bad; echo new > newfile.txt
c=$(code a tp.parc newfile.txt -tp)
ck "-tp: dañado -> error, sin tocar"          '[ "$c" = 2 ] && cmp -s tp.parc tp.bad'
cp tp.orig tp.parc
ck "-tp: sano -> modifica"                    '[ $(code a tp.parc newfile.txt -tp) = 0 ] && names tp.parc | grep -qx newfile.txt'
ck "-t con x: rechazado"                      '[ $(code x tp.parc -t) = 1 ]'

echo '-- -y'
q a y.parc src/a.txt; mkdir -p yo/src; echo old > yo/src/a.txt
q x y.parc -dpyo
ck "sin -y no sobrescribe"                    'grep -qx old yo/src/a.txt'
q x y.parc -dpyo -y
ck "-y sobrescribe"                           'grep -qx alpha yo/src/a.txt'
echo old > yo/src/a.txt; q x y.parc -dpyo -y -o-
ck "-y -o-: -o- manda"                        'grep -qx old yo/src/a.txt'

echo '-- -n y @listas'
q a n.parc src -n*.txt
ck "-n al agregar"                            '[ "$(names n.parc | sort | tr "\n" " ")" = "src/a.txt src/sub/b.txt " ]'
q a nx.parc src '-n*.txt' '-n*.log' -xb.txt
ck "-n repetido con -x"                       '[ "$(names nx.parc | sort | tr "\n" " ")" = "src/a.txt src/sub/deep/c.log " ]'
q a all.parc src
ck "l -n"                                     '[ "$(names all.parc -n*.md)" = "src/docs/d.md" ]'
rm -rf xn; q x all.parc -dpxn '-n*.txt' -xsrc/sub
ck "x -n con -x"                              '[ -f xn/src/a.txt ] && [ ! -e xn/src/sub/b.txt ] && [ ! -e xn/src/big.bin ]'
printf '# lista\n*.log\n\nsrc/docs\n' > list.txt
ck "@lista posicional (l)"                    '[ "$(names all.parc @list.txt | sort | tr "\n" " ")" = "src/docs src/docs/d.md src/sub/deep/c.log " ]'
q a la.parc @list.txt 2>/dev/null; printf 'src/a.txt\nsrc/docs\n' > addlist.txt; q a la.parc @addlist.txt
ck "@lista al agregar"                        '[ "$(names la.parc | sort | tr "\n" " ")" = "src/a.txt src/docs src/docs/d.md " ]'
printf '*.bin\n' > ex.txt; q a lx.parc src -x@ex.txt
ck "-x@lista"                                 '! names lx.parc | grep -q "\.bin$" && names lx.parc | grep -q a.txt'
: > empty.txt
ck "-n@lista vacía: nada"                     '[ -z "$(names all.parc -n@empty.txt)" ]'
cp all.parc nd.parc; q d nd.parc -n*.bin
ck "d -n"                                     '! names nd.parc | grep -q "\.bin$" && names nd.parc | grep -q a.txt'
ck "lista inexistente: código 4"              '[ $(code l all.parc @nolist.txt) = 4 ]'

echo '-- -ep / -ep1 / -ap'
q a ep.parc src -ep
ck "-ep: sin rutas ni directorios"            '[ "$(names ep.parc | sort | tr "\n" " ")" = "a.txt b.txt big.bin c.log d.md small.bin " ]'
mkdir -p dup/x dup/y; echo 1 > dup/x/f; echo 2 > dup/y/f
ck "-ep: nombre repetido avisa"               'P a epd.parc dup -ep 2>&1 | grep -q "duplicate name f" && [ "$(names epd.parc)" = f ]'
q a ep1.parc src -ep1
ck "-ep1: sin el directorio base"             'names ep1.parc | grep -qx a.txt && names ep1.parc | grep -qx sub/deep/c.log && ! names ep1.parc | grep -q "^src"'
q a ep1m.parc 'src/sub/*' -ep1
ck "-ep1 con máscara"                         'names ep1m.parc | grep -qx b.txt && names ep1m.parc | grep -qx deep/c.log'
rm -rf epx; q x all.parc -ep -dpepx
ck "x -ep con -dp (planos)"                   '[ -f epx/a.txt ] && [ -f epx/c.log ] && [ ! -d epx/src ]'
q a ap.parc src -ep1 -apbackup/today
ck "-ap al agregar"                           'names ap.parc | grep -qx backup/today/a.txt && names ap.parc | grep -qx backup/today/sub/b.txt'
ck "l -ap: subárbol sin prefijo"              '[ "$(names ap.parc -apbackup/today/sub | sort | tr "\n" " ")" = "b.txt deep deep/c.log " ]'
rm -rf apx; q x ap.parc -apbackup/today -dpapx
ck "x -ap"                                    '[ -f apx/a.txt ] && [ -f apx/sub/deep/c.log ] && [ ! -e apx/backup ]'
rm -rf apx2; q x ap.parc -apbackup/today '*.txt' -dpapx2
ck "x -ap con patrón"                         '[ -f apx2/a.txt ] && [ -f apx2/sub/b.txt ] && [ ! -e apx2/big.bin ]'
cp ap.parc apd.parc; q d apd.parc -apbackup/today/sub
ck "d -ap: borra solo ese subárbol"           '! names apd.parc | grep -q "/sub/" && names apd.parc | grep -qx backup/today/a.txt'

echo '-- -ag'
q a ag.parc src/a.txt -ag; n=$(ls ag2*.parc 2>/dev/null | head -1)
ck "-ag: YYYYMMDDhhmmss"                      '[[ "$n" =~ ^ag[0-9]{14}\.parc$ ]]'
q a ag.parc src/a.txt '-ag-YYYY-MM-DD'; d=$(date +%Y-%m-%d)
ck "-agFMT"                                   '[ -f "ag-$d.parc" ]'
ck "l con -ag (mismo nombre)"                 'names "ag-$d.parc" | grep -q a.txt && names ag.parc "-ag-YYYY-MM-DD" | grep -q a.txt'

echo '-- filtros de tamaño y fecha'
ck "-sm"                                      '[ "$(names all.parc -sm100k)" = src/big.bin ]'
ck "-sl"                                      '! names all.parc -sl10 | grep -q bin && names all.parc -sl10 | grep -q a.txt'
ck "-sm y -sl juntos"                         '[ "$(names all.parc -sm1k -sl100k)" = src/small.bin ]'
ck "-tb"                                      '[ "$(names all.parc -tb20210101 | sort | tr "\n" " ")" = "src/a.txt src/sub/b.txt " ]'
ck "-ta"                                      '! names all.parc -ta20210101 | grep -q a.txt && names all.parc -ta20210101 | grep -q c.log'
ck "-ta -tb (rango)"                          '[ "$(names all.parc -ta20240101 -tb20250101)" = src/sub/deep/c.log ]'
ck "-tn (más nuevo que 1d)"                   'names all.parc -tn1d | grep -q big.bin && ! names all.parc -tn1d | grep -q c.log'
ck "-to (más viejo que 1w)"                   '[ "$(names all.parc -to1w | sort | tr "\n" " ")" = "src/a.txt src/sub/b.txt src/sub/deep/c.log " ]'
ck "-tn2h30m"                                 'names all.parc -tn2h30m | grep -q big.bin'
q a sz.parc src -sm100k
ck "a -sm (sin directorios)"                  '[ "$(names sz.parc)" = src/big.bin ]'
q a tm.parc src -to1w --dirs
ck "a -to --dirs (con directorios)"           'names tm.parc | grep -qx src/empty && ! names tm.parc | grep -q big.bin'
cp all.parc df.parc; q d df.parc -sm100k
ck "d con filtro de tamaño"                   '! names df.parc | grep -q big.bin && names df.parc | grep -q small.bin && names df.parc | grep -qx src/empty'
cp all.parc dt.parc; q d dt.parc 'src/sub' -tb20210101
ck "d con patrón y filtro de fecha"           '! names dt.parc | grep -q b.txt && names dt.parc | grep -q c.log'
ck "d sin nada: error"                        '[ $(code d dt.parc) = 1 ]'
ck "tamaño inválido: error"                   '[ $(code l all.parc -smX) = 1 ] && [ $(code l all.parc -ta2020) = 1 ]'
rm -rf fx; q x all.parc -sl10 -dpfx
ck "x -sl (sin directorios vacíos)"           '[ -f fx/src/a.txt ] && [ ! -e fx/src/big.bin ] && [ ! -e fx/src/empty ]'

echo '-- --dirs / -ed / --nodates / -tk / -tl'
q a ed.parc src -ed
ck "-ed: sin directorios"                     '! names ed.parc | grep -qx src/empty && names ed.parc | grep -q a.txt'
ck "por defecto: con directorios vacíos"      'names all.parc | grep -qx src/empty'
rm -rf edx; q x all.parc -ed -dpedx
ck "x -ed: no crea los vacíos"                '[ ! -e edx/src/empty ] && [ -f edx/src/a.txt ]'
q a nd2.parc src/a.txt --nodates; rm -rf ndx; q x nd2.parc -dpndx
ck "--nodates: no guarda fechas"              'P l nd2.parc | grep -q "1970-01-01" && [ $(( $(date +%s) - $(stat -c %Y ndx/src/a.txt) )) -lt 100 ]'
q a tk.parc src/a.txt; touch -d '2001-02-03 04:05:06' tk.parc; q a tk.parc src/sub/b.txt -tk
ck "-tk: conserva la fecha del archivo"       '[ "$(date -r tk.parc +%Y%m%d%H%M%S)" = 20010203040506 ]'
q a tl.parc src/a.txt src/sub/deep/c.log -tl
ck "-tl: fecha del más nuevo"                 '[ "$(date -r tl.parc +%Y%m%d%H%M)" = 202406010800 ]'

echo '-- -w'
mkdir -p wdir; q a w.parc src -wwdir
ck "-w: crea, sin temporales"                 '[ -s w.parc ] && [ -z "$(ls -A wdir)" ] && P t w.parc | grep -q "All OK"'
q a w.parc newfile.txt -wwdir
ck "-w: actualiza"                            'names w.parc | grep -qx newfile.txt && [ -z "$(ls -A wdir)" ]'
OTHER=/dev/shm/parc-w-$$; mkdir -p "$OTHER"
if [ -d "$OTHER" ] && [ "$(stat -c %d "$OTHER")" != "$(stat -c %d .)" ]; then
  q a wx.parc src -w"$OTHER"; q a wx.parc newfile.txt -w"$OTHER" -v100k
  ck "-w en otro sistema de archivos (copia)"   '[ -s wx.parc.001 ] && P t wx.parc | grep -q "All OK" && [ -z "$(ls -A "$OTHER")" ]'
fi
rm -rf "$OTHER"
ck "-w inexistente: error"                    '[ $(code a w2.parc src -wnoexiste) = 1 ] && [ ! -e w2.parc ]'
ck "-w excluye su temporal"                   'q a wself.parc . -wwdir -x"*.parc" -xsrc; ! names wself.parc | grep -q "\.tmp"'

echo '-- -lc / -ld'
head -c 8000000 /dev/urandom > lc.bin; seq 1 400000 >> lc.bin
q a lc0.parc lc.bin -mlzma:64mb:max -s-; q a lc1.parc lc.bin -mlzma:64mb:max -s- -lc32m
d0=$(P lb lc0.parc | grep "^  data" | grep -o "lzma:[0-9]*[km]b" | head -1); d1=$(P lb lc1.parc | grep "^  data" | grep -o "lzma:[0-9]*[km]b" | head -1)
ck "-lc reduce el diccionario de lzma ($d0 -> $d1)"  '[ "$d0" = lzma:11mb ] && [ -n "$d1" ] && [ "$d1" != "$d0" ] && P t lc1.parc | grep -q "All OK"'
q a lc2.parc src -m9 -lc16m
ck "-lc con un preset (ppmd/rep dentro del límite)" '! P lb lc2.parc | grep -oE "(ppmd:[0-9]+|rep|lzma):[0-9]+(gb|mb)" | grep -E ":([2-9][0-9]|[0-9]{3,})mb|gb" && P t lc2.parc | grep -q "All OK"'
q a ld.parc lc.bin -mlzma:64mb -s-
ck "-ld: rechaza con código 7"                '[ $(code t ld.parc -ld1m) = 7 ] && [ $(code x ld.parc -ld1m -dpldx) = 7 ] && [ ! -s ldx/lc.bin ]'
ck "-ld suficiente: OK"                       '[ $(code t ld.parc -ld1g) = 0 ] && [ $(code t ld.parc -ld-) = 0 ]'
ck "-ld mensaje claro"                        'P t ld.parc -ld1m 2>&1 | grep -q "more than the -ld limit"'
ck "-lc inválido"                             '[ $(code a z.parc src -lcX) = 1 ]'

echo '-- -kb'
mkdir -p kb; for i in 1 2 3; do seq $((i*1000)) $((i*1000+60000)) > kb/f$i.txt; done
flip() {   # flip <archivo> <offset desde el bloque de datos>
  local pos; pos=$(P lb "$1" | awk '/ data / && !/orig=0 / {sub("pos=","",$2); print $2; exit}')
  python3 -c "import sys; f=open(sys.argv[1],'r+b'); p=int(sys.argv[2]); f.seek(p); b=f.read(1); f.seek(p); f.write(bytes([b[0]^0x55]))" "$1" $((pos + $2))
}
# storing: error de CRC en f2 (el archivo sale entero pero mal)
q a kbs.parc kb -m0; flip kbs.parc 400000
rm -rf kbx; out=$(P x kbs.parc -dpkbx 2>&1); c=$?
ck "CRC: sin -kb, código 2 y se borra"        '[ $c = 2 ] && echo "$out" | grep -q "CRC ERROR: kb/f2.txt.*deleted; -kb" && [ ! -e kbx/kb/f2.txt ] && cmp -s kbx/kb/f1.txt kb/f1.txt'
rm -rf kbk; out=$(P x kbs.parc -dpkbk -kb 2>&1); c=$?
ck "CRC: -kb lo conserva"                     '[ $c = 2 ] && [ "$(stat -c %s kbk/kb/f2.txt)" = "$(stat -c %s kb/f2.txt)" ] && ! cmp -s kbk/kb/f2.txt kb/f2.txt'
# lzma cortado a mitad de un archivo: incompleto
seq 1 600000 > kbig.txt; q a kbl.parc kbig.txt -mlzma -s; flip kbl.parc $(( $(P lb kbl.parc | awk '/ data / && !/orig=0 / {sub("comp=","",$4); print $4; exit}') / 2 ))
rm -rf kbx2; out=$(P x kbl.parc -dpkbx2 2>&1); c=$?
ck "incompleto: sin -kb se borra"             '[ $c = 2 ] && echo "$out" | grep -q "is incomplete (deleted" && [ -z "$(find kbx2 -type f)" ]'
rm -rf kbk2; out=$(PARC_THREADS=1 "$PARC" x kbl.parc -dpkbk2 -kb --no-progress 2>&1 </dev/null)
ck "incompleto: -kb conserva lo recuperado"   'echo "$out" | grep -q "is incomplete (kept: -kb)" && [ -n "$(find kbk2 -type f -size +1000k)" ]'
ck "t: -kb no cambia el test"                 '[ $(code t kbs.parc -kb) = 2 ]'

echo '-- --sync'
mk; q a sy.parc src; rm src/sub/b.txt; rm -r src/docs; echo nuevo > src/new.txt
q u sy.parc src --sync
ck "--sync con u: borra lo que ya no está"    '! names sy.parc | grep -q b.txt && ! names sy.parc | grep -q docs && names sy.parc | grep -qx src/new.txt && names sy.parc | grep -qx src/a.txt'
mkdir -p other; echo o > other/o.txt; q a sy.parc other; rm other/o.txt; echo p > other/p.txt
q a sy.parc src --sync
ck "--sync solo dentro de los argumentos"     'names sy.parc | grep -qx other/o.txt'
q a sy.parc other --sync -x'*.txt'
ck "--sync respeta -x"                        'names sy.parc | grep -qx other/o.txt'
ck "--sync con x: rechazado"                  '[ $(code x sy.parc --sync) = 1 ]'

echo '-- -mc'
mk; q a mc0.parc src -m5 -s-
q a mc1.parc src -m5 -s- -mc-rep -mc-exe -mcd-
ck "-m5 trae rep/exe/delta"                   'P lb mc0.parc | grep -q "rep:" '
ck "-mc-rep -mc-exe -mcd- los quita"          '! P lb mc1.parc | grep -qE "(^| |\+)(rep|exe|delta)(:|\+| |$)" && P t mc1.parc | grep -q "All OK"'
q a mc2.parc src -m5 -s- '-mc$text,$default:-lzp'
ck "-mc con grupos"                           '! P lb mc2.parc | grep -q "lzp:" && P t mc2.parc | grep -q "All OK"'
q a mc3.parc src -mcm
ck "-mcm sigue siendo el método cm"           'P lb mc3.parc | grep -q " cm"'

echo '-- --print-config'
out=$("$PARC" --print-config 2>&1); c=$?
ck "--print-config"                           '[ $c = 0 ] && echo "$out" | grep -q "^\[Compression methods\]" && echo "$out" | grep -q "^-m5 = " && echo "$out" | grep -q "^\$text"'
ck "--print-config con -mt1"                  '"$PARC" --print-config -mt1 | grep -q "^-m1 = .*plz:2"'

echo '-- -kf'
head -c 1000 /dev/urandom > key.bin; head -c 1000 /dev/urandom > key2.bin
q a kf.parc src -kfkey.bin -ae=chacha:t1:m8m:p1
ck "-kf solo: cifra y abre"                   'P t kf.parc -kfkey.bin | grep -q "All OK"'
ck "-kf otro archivo: contraseña incorrecta"  '[ $(code t kf.parc -kfkey2.bin) = 5 ]'
ck "-kf sin clave: pide contraseña (5)"       '[ $(code t kf.parc) = 5 ]'
q a kfp.parc src -kfkey.bin -pSecreto -hp -ae=aes:t1:m8m:p1
ck "-kf + -p: los dos"                        'P t kfp.parc -kfkey.bin -pSecreto | grep -q "All OK"'
ck "-kf + -p: falta -kf"                      '[ $(code t kfp.parc -pSecreto) = 5 ]'
ck "-kf + -p: falta -p"                       '[ $(code l kfp.parc -kfkey.bin) = 5 ]'
ck "-kf + -p: -p equivocada"                  '[ $(code t kfp.parc -kfkey.bin -pOtra) = 5 ]'
q a kfp.parc newfile.txt -kfkey.bin -pSecreto -hp -ae=aes:t1:m8m:p1
ck "-kf al actualizar"                        'names kfp.parc -kfkey.bin -pSecreto | grep -qx newfile.txt'
: > key0.bin
ck "-kf vacío: error"                         '[ $(code a kf0.parc src -kfkey0.bin) = 4 ]'

echo '-- combinaciones'
rm -rf cx; q x all.parc -n*.txt -x*b.txt -ep -dpcx
ck "-n -x -ep -dp"                            '[ "$(ls cx)" = a.txt ]'
q a cmb.parc src -ep1 -apbk -sm1k -t
ck "-ep1 -ap -sm -t"                          '[ "$(names cmb.parc | sort | tr "\n" " ")" = "bk/big.bin bk/small.bin " ]'

rm -f lc.bin lc*.parc ld.parc
echo "== CLI options: $fail failures"
[ $fail -eq 0 ]
