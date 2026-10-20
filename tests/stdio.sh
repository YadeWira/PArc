#!/bin/bash
# tests/stdio.sh — entrada y salida estándar (-si, -so, "-") y extracción con bloques dañados.
set -u
ROOT=$(cd "$(dirname "$0")/.." && pwd)
PARC=${PARC_BIN:-$ROOT/build/linux64/parc}
W=${STDIO_WORK:-/mnt/IA_LAB/agentes/PArc/stdio}
rm -rf -- "${W:?}"; mkdir -p "$W/d" && cd "$W" || exit 2
fail=0
check() { if eval "$2"; then printf '  ok    %s\n' "$1"; else printf '  FAIL %s\n' "$1"; fail=$((fail+1)); fi; }
seq 1 100000 > d/a.txt; head -c 50000 /dev/urandom > d/b.bin

seq 1 200000 | "$PARC" a s.parc -sidatos.txt --no-progress >/dev/null 2>&1
check "-si: un archivo con el nombre pedido" '"$PARC" l s.parc | grep -q " datos.txt$"'
check "-so: el contenido idéntico, nada más"  '"$PARC" x s.parc -so --no-progress 2>/dev/null | cmp -s - <(seq 1 200000)'
check "-so: los mensajes a stderr"            '"$PARC" x s.parc -so --no-progress 2>&1 >/dev/null | grep -q "Extracted datos.txt" && ! "$PARC" x s.parc -so --no-progress 2>/dev/null | grep -q "Extracted"'
tar cf - d | "$PARC" a t.parc -sid.tar -m5 --no-progress >/dev/null 2>&1
check "tar | parc -si y parc -so | tar"       '[ "$("$PARC" x t.parc -so 2>/dev/null | tar tf - | tr "\n" " ")" = "d/ d/a.txt d/b.bin " ]'
"$PARC" a - d --no-progress > o.parc 2>/dev/null
check "a -: el archivo por stdout"            '"$PARC" t o.parc --no-progress | tail -1 | grep -q "Errors: 0"'
rm -rf ox; "$PARC" x - -dpox --no-progress < o.parc >/dev/null 2>&1
check "x -: desde stdin"                      'diff -rq d ox/d >/dev/null'
check "l -"                                   '"$PARC" l - < o.parc | grep -q "d/a.txt"'
check "-so de un archivo puntual"             '"$PARC" x o.parc d/a.txt -so --no-progress 2>/dev/null | cmp -s - d/a.txt'
seq 1 1000 | "$PARC" a e.parc -si -pClave -hp --no-progress >/dev/null 2>&1
check "-si cifrado"                           '[ "$("$PARC" x e.parc -so -pClave 2>/dev/null | tail -1)" = 1000 ]'
check "-si con u: rechazado"                  '! echo x | "$PARC" u s.parc -si --no-progress >/dev/null 2>&1'
check "no quedan temporales"                  '[ -z "$(ls -A | grep parc-stdin)" ] && [ -z "$(ls /tmp 2>/dev/null | grep "parc-std.*-$$")" ]'

# Bloque sólido dañado: se informa cada archivo y los demás bloques salen
mkdir -p b && for i in 1 2 3; do seq $((i*1000)) $((i*1000+60000)) > b/f$i.txt; done; head -c 100000 /dev/urandom > b/z.bin
"$PARC" a b.parc b -m4 -rr --no-progress >/dev/null 2>&1
pos=$("$PARC" lb b.parc | awk '/ data / && /4x4:lzma|lzma/ {sub("pos=","",$2); print $2; exit}')
python3 - "$pos" <<'EOF'
import sys
p = int(sys.argv[1]) + 300
f = open('b.parc', 'r+b'); f.seek(p); b = f.read(1); f.seek(p); f.write(bytes([b[0] ^ 0x55]))
EOF
out=$("$PARC" x b.parc -dpbx --no-progress 2>&1); code=$?
check "bloque dañado: código 2"               '[ $code = 2 ]'
check "bloque dañado: informa cada archivo"   '[ "$(echo "$out" | grep -c "b/f[123].txt \(could not be extracted\|is incomplete\)")" = 3 ]'
check "bloque dañado: el otro bloque sale"    'cmp -s b/z.bin bx/b/z.bin'
check "bloque dañado: sugiere parc r"         'echo "$out" | grep -q "parc r b.parc"'

echo "== stdin/stdout: $fail failures"
[ $fail -eq 0 ]
