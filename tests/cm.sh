#!/bin/bash
# tests/cm.sh — context-mixing codec (cm), -mxx (CM max) and -mx (fast-decode max).
set -u
ROOT=$(cd "$(dirname "$0")/.." && pwd)
PARC=${PARC_BIN:-$ROOT/build/linux64/parc}
W=${CM_WORK:-/tmp/opencode/cm_test}
rm -rf -- "${W:?}"; mkdir -p "$W/corpus" && cd "$W" || exit 2
fail=0
check() { if eval "$2"; then printf '  ok    %s\n' "$1"; else printf '  FAIL %s\n' "$1"; fail=$((fail+1)); fi; }

seq 1 200000 > corpus/texto.txt
printf 'linea repetida\n' >> corpus/texto.txt
for i in $(seq 1 20); do cat "$ROOT/docs/USO.md"; done > corpus/prosa.txt
head -c 300000 /dev/urandom > corpus/azar.bin
: > corpus/vacio.bin
printf 'A' > corpus/uno.bin

"$PARC" a cm.parc corpus -mcm --no-progress >/dev/null 2>&1
check "a -mcm"                    '[ -s cm.parc ]'
check "t -mcm"                    '"$PARC" t cm.parc --no-progress | tail -1 | grep -q "Errors: 0"'
rm -rf out; "$PARC" x cm.parc -dpout --no-progress >/dev/null 2>&1
check "x -mcm idéntico"           'diff -r corpus out/corpus >/dev/null'

rm -f m9.parc m6.parc mx.parc xx.parc
"$PARC" a m9.parc corpus/prosa.txt -m9 --no-progress >/dev/null 2>&1
"$PARC" a m6.parc corpus -m6 --no-progress >/dev/null 2>&1
"$PARC" a xx.parc corpus/prosa.txt -mxx --no-progress >/dev/null 2>&1
"$PARC" a mx.parc corpus/prosa.txt -mx --no-progress >/dev/null 2>&1
check "-mxx más chico que -m9"    '[ "$(stat -c%s xx.parc)" -lt "$(stat -c%s m9.parc)" ]'
check "-mxx verifica"             '"$PARC" t xx.parc --no-progress | tail -1 | grep -q "Errors: 0"'
rm -rf outxx; "$PARC" x xx.parc -dpoutxx --no-progress >/dev/null 2>&1
check "-mxx extrae idéntico"      'cmp corpus/prosa.txt outxx/corpus/prosa.txt'
check "-mx verifica"              '"$PARC" t mx.parc --no-progress | tail -1 | grep -q "Errors: 0"'
rm -rf outmx; "$PARC" x mx.parc -dpoutmx --no-progress >/dev/null 2>&1
check "-mx extrae idéntico"       'cmp corpus/prosa.txt outmx/corpus/prosa.txt'
check "-mx más chico que -m6"     '[ "$(stat -c%s mx.parc)" -lt "$(stat -c%s m6.parc)" ]'
rm -f mx1.parc; PARC_THREADS=1 "$PARC" a mx1.parc corpus/prosa.txt -mx --no-progress >/dev/null 2>&1
check "-mx paralelo == serial"    '[ "$(stat -c%s mx.parc)" = "$(stat -c%s mx1.parc)" ]'

cp xx.parc bad.parc
python3 - <<'PY'
f=open('bad.parc','r+b'); f.seek(120); b=f.read(1); f.seek(120); f.write(bytes([b[0]^0x55]))
PY
check "cm dañado: código 2"       '{ "$PARC" t bad.parc --no-progress >/dev/null 2>&1; [ $? = 2 ]; }'

"$PARC" a e.parc corpus/prosa.txt -mxx -pclave --no-progress >/dev/null 2>&1
check "cm cifrado"                '"$PARC" t e.parc -pclave --no-progress | tail -1 | grep -q "Errors: 0"'

echo "== cm: $fail failures"
[ $fail -eq 0 ]
