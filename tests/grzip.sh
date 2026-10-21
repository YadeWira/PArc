#!/bin/bash
# tests/grzip.sh — GRZip adaptive LZP mode, round-trip and compatibility.
set -u
ROOT=$(cd "$(dirname "$0")/.." && pwd)
PARC=${PARC_BIN:-$ROOT/build/linux64/parc}
W=${GRZIP_WORK:-/tmp/opencode/grzip_test}
rm -rf -- "${W:?}"; mkdir -p "$W" && cd "$W" || exit 2
fail=0
check() { if eval "$2"; then printf '  ok    %s\n' "$1"; else printf '  FAIL %s\n' "$1"; fail=$((fail+1)); fi; }

# Bloque grande: el codificador debe subir LZP a l64/h22.
for i in $(seq 1 800); do cat "$ROOT/docs/USO.md"; done > grande.txt
"$PARC" a grande.parc grande.txt -m'grzip:8mb:m1:l32:h17' --no-progress >/dev/null 2>&1
check "bloque grande comprime"    '[ -s grande.parc ]'
check "LZP adaptado l64/h22"      'python3 - <<'"'"'PY'"'"'
import struct
b=open("grande.parc","rb").read(); h=struct.unpack_from("<7I",b,31)
m=h[1]; assert (m//65536)%32767==64 and (m//256)%256==22, m
PY' 
check "bloque grande verifica"    '"$PARC" t grande.parc --no-progress | tail -1 | grep -q "Errors: 0"'
rm -rf outg; "$PARC" x grande.parc -dpoutg --no-progress >/dev/null 2>&1
check "bloque grande extrae"      'cmp grande.txt outg/grande.txt'

# Bloque chico: debe conservar los parámetros rápidos.
head -c 2000000 grande.txt > chico.txt
"$PARC" a chico.parc chico.txt -m'grzip:8mb:m1:l32:h17' --no-progress >/dev/null 2>&1
check "bloque chico comprime"     '[ -s chico.parc ]'
check "LZP chico sin adaptar"     'python3 - <<'"'"'PY'"'"'
import struct
b=open("chico.parc","rb").read(); h=struct.unpack_from("<7I",b,31)
m=h[1]; assert (m//65536)%32767!=64 or (m//256)%256!=22, m
PY' 
check "bloque chico verifica"     '"$PARC" t chico.parc --no-progress | tail -1 | grep -q "Errors: 0"'

# Datos incompresibles: no debe fallar.
head -c 3000000 /dev/urandom > azar.bin
"$PARC" a azar.parc azar.bin -mgrzip --no-progress >/dev/null 2>&1
check "GRZip con datos aleatorios" '"$PARC" t azar.parc --no-progress | tail -1 | grep -q "Errors: 0"'

echo "== grzip: $fail failures"
[ $fail -eq 0 ]
