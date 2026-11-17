#!/bin/bash
# tests/parc_crypt.sh — cifrado de .parc (esquema 1: Argon2id + XChaCha20-Poly1305 / AES-256-GCM
# en trozos de 64 KiB; docs/formato/FORMATO-PARC.md §3b): contraseña buena y mala, -hp, todos los
# niveles, actualizar y borrar, contraseña Unicode, bytes alterados en cualquier lugar de un
# bloque cifrado, archivo truncado y bloques intercambiados.
set -u
ROOT=$(cd "$(dirname "$0")/.." && pwd)
PARC=${PARC_BIN:-$ROOT/build/linux64/parc}
W=${PCRYPT_WORK:-${TMPDIR:-/tmp}/parc_crypt}
export TMPDIR=${TMPDIR:-$W}
rm -rf -- "${W:?}"; mkdir -p "$W/d" && cd "$W" || exit 2
fail=0
check() { if eval "$2"; then printf '  ok    %s\n' "$1"; else printf '  FAIL  %s\n' "$1"; fail=$((fail+1)); fi; }
ms() { echo $(( ($(date +%s%N) - $1) / 1000000 )); }
okt() { "$PARC" t "$@" --no-progress </dev/null 2>/dev/null | tail -1 | grep -q 'All OK'; }
# código de salida de un comando de parc (sin consola: no pide contraseñas)
code() { "$PARC" "$@" --no-progress </dev/null >/dev/null 2>&1; echo $?; }
for i in $(seq 1 20); do seq "$i" 30000 > "d/f$i.txt"; done
head -c 200000 /dev/urandom > d/r.bin

echo '-- crear, probar, extraer'
t0=$(date +%s%N)
"$PARC" a c.parc d -s- -pClave -hp --no-progress >/dev/null 2>&1
ta=$(ms "$t0")
meth=$("$PARC" lb c.parc -pClave 2>/dev/null | grep '^  data' | grep -o 'xchacha20:[^ +]*' | head -1)
check "etapa xchacha20 con Argon2id t3 m64MiB p4"  '[[ "$meth" =~ ^xchacha20:t3:m65536:p4:s[0-9a-f]{32}:c[0-9a-f]{16}:n[0-9a-f]{32}$ ]]'
nsalt=$("$PARC" lb c.parc -pClave 2>/dev/null | grep -oE ':s[0-9a-f]{32}' | sort -u | wc -l)
nnonce=$("$PARC" lb c.parc -pClave 2>/dev/null | grep -oE ':n[0-9a-f]{32}' | sort -u | wc -l)
nblk=$("$PARC" lb c.parc -pClave 2>/dev/null | grep -c 'xchacha20:')
check "una sal para todo el archivo"            '[ "$nsalt" = 1 ]'
check "un nonce distinto por bloque ($nblk)"     '[ "$nnonce" = "$nblk" ] && [ "$nblk" -ge 23 ]'
check "una sola derivación al crear 23 bloques (${ta} ms)" '[ "$ta" -lt 3000 ]'
t0=$(date +%s%N); okt c.parc -pClave; ok=$?; tt=$(ms "$t0")
check "t sin errores"                           '[ $ok = 0 ]'
check "una sola derivación al leer (${tt} ms)"  '[ "$tt" -lt 3000 ]'
rm -rf o; "$PARC" x c.parc -dpo -pClave --no-progress >/dev/null 2>&1
check "x idéntico"                              'diff -r d o/d >/dev/null'

echo '-- contraseñas'
check "contraseña mala: código 5"               '[ "$(code t c.parc -pOtra)" = 5 ]'
check "contraseña mala: lo dice"                '"$PARC" t c.parc -pOtra --no-progress </dev/null 2>&1 | grep -q "wrong password"'
check "-hp sin contraseña: no lista (código 5)" '[ "$(code l c.parc)" = 5 ]'
check "-hp sin contraseña: lo dice"             '"$PARC" l c.parc --no-progress </dev/null 2>&1 | grep -q "archive is encrypted"'
check "-hp sin contraseña: nada de la lista"    '! "$PARC" l c.parc --no-progress </dev/null 2>&1 | grep -q "f1.txt"'
"$PARC" a p.parc d -pClave --no-progress >/dev/null 2>&1
check "-p solo: lista sin contraseña"           '"$PARC" l p.parc --no-progress </dev/null 2>/dev/null | grep -q "f1.txt"'
check "-p solo: t sin contraseña = código 5"    '[ "$(code t p.parc)" = 5 ]'
check "-p solo: directorio sin cifrar"          '! "$PARC" lb p.parc 2>/dev/null | grep "directory" | grep -q xchacha20'
"$PARC" a two.parc d -pDatos -hpCabeceras --no-progress >/dev/null 2>&1
check "-p y -hp distintas: t con las dos"       'okt two.parc -pDatos -hpCabeceras'
check "-p y -hp distintas: sólo -hp lista"      '"$PARC" l two.parc -pCabeceras --no-progress </dev/null 2>/dev/null | grep -q "f1.txt"'
check "-p y -hp distintas: sólo -hp no extrae"  '[ "$(code t two.parc -pCabeceras)" = 5 ]'
"$PARC" a u.parc d/f1.txt -p'contraseña日本😀' --no-progress >/dev/null 2>&1
check "contraseña Unicode (UTF-8)"              'okt u.parc -p"contraseña日本😀"'
check "contraseña Unicode: otra forma falla"    '[ "$(code t u.parc -p"contrasena日本😀")" = 5 ]'

echo '-- algoritmos y costo de la derivación'
"$PARC" a g.parc d -pClave -hp -ae=aes --no-progress >/dev/null 2>&1
check "-ae=aes: etapa aes256gcm"                '"$PARC" lb g.parc -pClave 2>/dev/null | grep -q "aes256gcm:t3:m65536:p4:"'
check "-ae=aes: t"                              'okt g.parc -pClave'
rm -rf og; "$PARC" x g.parc -dpog -pClave --no-progress >/dev/null 2>&1
check "-ae=aes: x idéntico"                     'diff -r d og/d >/dev/null'
"$PARC" a k.parc d/f2.txt -pClave -ae=chacha:t1:m8m:p2 --no-progress >/dev/null 2>&1
check "-ae con :t :m :p propios"                '"$PARC" lb k.parc -pClave 2>/dev/null | grep -q "xchacha20:t1:m8192:p2:"'
check "  y se lee"                              'okt k.parc -pClave'
check "-ae=blowfish: rechazado (código 1)"      '[ "$(code a z.parc d/f1.txt -pClave -ae=blowfish)" = 1 ] && [ ! -e z.parc ]'
check "-ae=chacha:m1: costo inválido"           '[ "$(code a z.parc d/f1.txt -pClave -ae=chacha:m1)" = 1 ]'

echo '-- todos los niveles'
for m in -m0 -m1 -m2 -m3 -m4 -m5 -m6 -m7 -m8 -m9 -mx; do
  rm -f q.parc; "$PARC" a q.parc d -pClave "$m" --no-progress >/dev/null 2>&1
  check "$m -p"                                 'okt q.parc -pClave'
done
rm -f q.parc; PARC_THREADS=4 "$PARC" a q.parc d -s- -pClave -hp -m1 --no-progress >/dev/null 2>&1
check "-m1 -s- con 4 hilos (bloques en paralelo)" 'okt q.parc -pClave'
rm -f q.parc; "$PARC" a q.parc d -pClave -ae=aes -m3 --no-progress >/dev/null 2>&1
check "-m3 -ae=aes"                             'okt q.parc -pClave'

echo '-- actualizar y borrar'
echo nuevo > d/nuevo.txt
"$PARC" a c.parc d/nuevo.txt -pClave -hp --no-progress >/dev/null 2>&1
check "agregar a un .parc cifrado"              'okt c.parc -pClave'
nsalt=$("$PARC" lb c.parc -pClave 2>/dev/null | grep -oE ':s[0-9a-f]{32}' | sort -u | wc -l)
check "  con la misma sal (una derivación)"     '[ "$nsalt" = 1 ]'
cp c.parc c0.parc
check "agregar con otra contraseña: código 5"   '[ "$(code a c.parc d/nuevo.txt -pOtra -hp)" = 5 ]'
check "  y el archivo queda igual"              'cmp -s c.parc c0.parc'
cp p.parc p0.parc
check "-p solo, agregar con otra: código 5"     '[ "$(code a p.parc d/nuevo.txt -pOtra)" = 5 ]'
check "  y el archivo queda igual"              'cmp -s p.parc p0.parc'
"$PARC" a p.parc d/nuevo.txt -pClave --no-progress >/dev/null 2>&1
check "-p solo, agregar con la misma"           'okt p.parc -pClave'
"$PARC" d c.parc d/f3.txt -pClave -hp --no-progress >/dev/null 2>&1
check "borrar de un .parc cifrado"              'okt c.parc -pClave && ! "$PARC" l c.parc -pClave --no-progress 2>/dev/null | grep -q "f3.txt"'
"$PARC" a s.parc d -pClave --no-progress >/dev/null 2>&1      # sólido: borrar reempaqueta
"$PARC" d s.parc d/f5.txt -pClave --no-progress >/dev/null 2>&1
check "borrar de un bloque sólido cifrado"      'okt s.parc -pClave'
check "  el bloque reempaquetado sigue cifrado" '! "$PARC" lb s.parc 2>/dev/null | grep "^  data" | grep -v "orig=0 " | grep -vq xchacha20'
"$PARC" u s.parc d -pClave --no-progress >/dev/null 2>&1
check "u en un .parc cifrado"                   'okt s.parc -pClave && "$PARC" l s.parc --no-progress 2>/dev/null | grep -q "f5.txt"'

echo '-- datos alterados, truncados e intercambiados'
# Bloques de datos cifrados de p.parc (sólo -p: el directorio sin cifrar dice dónde están)
python3 - "$PARC" <<'EOF' > blocks.txt
import re, subprocess, sys
out = subprocess.run([sys.argv[1], 'lb', 'p.parc'], capture_output=True, text=True).stdout
for m in re.finditer(r'pos=(\d+)\s+orig=(\d+)\s+comp=(\d+)\s+(\S+)', out):
    if 'xchacha20' in m.group(4):
        print(m.group(1), m.group(3))
EOF
bad=0; crash=0; n=0
while read -r pos comp; do
  offs="0 1 15 16 65535 65536 65551 65552 65553 $((comp/2)) $((comp-17)) $((comp-16)) $((comp-1))"
  for k in $(seq 1 12); do offs="$offs $(( (RANDOM * 32768 + RANDOM) % comp ))"; done
  for off in $offs; do
    [ "$off" -ge 0 ] && [ "$off" -lt "$comp" ] || continue
    cp p.parc alt.parc
    python3 -c "
import sys; f = open('alt.parc', 'r+b'); f.seek($pos + $off); b = f.read(1); f.seek($pos + $off); f.write(bytes([b[0] ^ 0x5a]))"
    out=$("$PARC" t alt.parc -pClave --no-progress </dev/null 2>&1); rc=$?
    n=$((n+1))
    if [ $rc != 2 ] || ! echo "$out" | grep -q "authentication failed"; then
      bad=$((bad+1)); echo "    (bloque en $pos, byte $off: código $rc)"
    fi
    [ $rc -gt 5 ] && crash=$((crash+1))
  done
done < blocks.txt
check "$n bytes alterados en bloques cifrados: todos fallan la autenticación (código 2)" '[ $bad = 0 ] && [ $n -ge 25 ]'
check "  sin caídas"                            '[ $crash = 0 ]'
# -hp: un byte del directorio cifrado
dpos=$("$PARC" lb c.parc -pClave 2>/dev/null | sed -n 's/.*directory *pos=\([0-9]*\).*/\1/p')
cp c.parc alt.parc
python3 -c "
f = open('alt.parc', 'r+b'); f.seek($dpos + 5); b = f.read(1); f.seek($dpos + 5); f.write(bytes([b[0] ^ 1]))"
rc=$(code l alt.parc -pClave)
check "-hp: directorio alterado, error limpio (código $rc)" '[ "$rc" = 2 ]'
# Truncado: en varios puntos (el final con el footer se pierde, o un bloque queda corto)
sz=$(stat -c %s p.parc); badt=0
for cut in 1 17 100 1000 $((sz/2)) $((sz-5000)); do
  head -c $((sz - cut)) p.parc > tr.parc
  rc=$(code t tr.parc -pClave)
  { [ "$rc" = 2 ] || [ "$rc" = 4 ]; } || badt=$((badt+1))
done
check "archivo truncado en 6 puntos: error limpio" '[ $badt = 0 ]'
# Dos bloques del mismo tamaño intercambiados: el nonce de cada bloque está en su método
head -c 70000 /dev/urandom > d2a.bin; head -c 70000 /dev/urandom > d2b.bin
"$PARC" a sw.parc d2a.bin d2b.bin -s- -m1 -pClave --no-progress >/dev/null 2>&1
python3 - "$PARC" <<'EOF'
import re, subprocess, sys
out = subprocess.run([sys.argv[1], 'lb', 'sw.parc'], capture_output=True, text=True).stdout
b = [(int(p), int(c)) for p, o, c, m in re.findall(r'pos=(\d+)\s+orig=(\d+)\s+comp=(\d+)\s+(\S+)', out) if 'xchacha20' in m and o != '0']
assert len(b) == 2 and b[0][1] == b[1][1], b
data = bytearray(open('sw.parc', 'rb').read())
(p1, c), (p2, _) = b
data[p1:p1 + c], data[p2:p2 + c] = data[p2:p2 + c], data[p1:p1 + c]
open('swapped.parc', 'wb').write(data)
# y dentro de un bloque: dos trozos de 64 KiB + 16 intercambiados (bloque de 3 trozos)
EOF
check "bloques intercambiados: falla la autenticación" '"$PARC" t swapped.parc -pClave --no-progress </dev/null 2>&1 | grep -q "authentication failed"'
head -c 200000 /dev/urandom > big.bin
"$PARC" a ch.parc big.bin -m0 -pClave --no-progress >/dev/null 2>&1
python3 - "$PARC" <<'EOF'
import re, subprocess, sys
out = subprocess.run([sys.argv[1], 'lb', 'ch.parc'], capture_output=True, text=True).stdout
p, c = [(int(p), int(c)) for p, o, c, m in re.findall(r'pos=(\d+)\s+orig=(\d+)\s+comp=(\d+)\s+(\S+)', out) if 'xchacha20' in m][0]
K = 65536 + 16
assert c == 200000 + 4 * 16, c
data = bytearray(open('ch.parc', 'rb').read())
a, b = data[p:p + K], data[p + K:p + 2 * K]
data[p:p + K], data[p + K:p + 2 * K] = b, a
open('chswap.parc', 'wb').write(data)
EOF
check "trozos de un bloque intercambiados: falla"  '"$PARC" t chswap.parc -pClave --no-progress </dev/null 2>&1 | grep -q "authentication failed"'
check "  y no se extrae nada del bloque"           'rm -rf oc; "$PARC" x chswap.parc -dpoc -pClave --no-progress </dev/null >/dev/null 2>&1; [ ! -s oc/big.bin ]'

echo "== .parc encryption: $fail failures"
[ $fail -eq 0 ]
