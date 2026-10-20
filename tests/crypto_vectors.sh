#!/bin/bash
# tests/crypto_vectors.sh — primitivas de cifrado de PArc contra LibTomCrypt, en vectores al azar.
#
# Oráculos (tests/crypto/oracle.c): la copia 1.17 que trae FreeArc (Compression/_Encryption,
# compilada como C++ con las mismas definiciones que C_Encryption.cpp; es la única con
# Serpent) y LibTomCrypt 1.18.2 oficial. Compara AES, Blowfish, Serpent, Twofish (ECB),
# CTR (contador little-endian, como FreeArc) y CFB, SHA-512 y PBKDF2-HMAC-SHA512.
set -u
ROOT=$(cd "$(dirname "$0")/.." && pwd)
W=${CRYPTO_WORK:-/mnt/IA_LAB/agentes/PArc/crypto_vectors}
TAR=${LTC_TAR:-/mnt/IA_LAB/compartido/parc/crypto-oracle/ltc-1.18.2.tar.xz}
mkdir -p "$W/u" && cd "$W" || exit 2
[ -f libtomcrypt-1.18.2/libtomcrypt.a ] || { tar xf "$TAR" && make -C libtomcrypt-1.18.2 -j8 >/dev/null 2>&1; } || exit 2
E=$ROOT/reference/freearc-0.67/Compression/_Encryption
g++ -O2 -fpermissive -w -x c++ -DLTC117 -I"$E/headers" -I"$E" -o o117 "$ROOT/tests/crypto/oracle.c" || exit 2
gcc -O2 -I libtomcrypt-1.18.2/src/headers -o o118 "$ROOT/tests/crypto/oracle.c" libtomcrypt-1.18.2/libtomcrypt.a || exit 2
fpc -O2 -Fu"$ROOT/src" -FU"$W/u" -o"$W/ptest" "$ROOT/tests/crypto/ptest.pas" >/dev/null || exit 2
[ -x "$W/ptest" ] || { echo "no se pudo compilar ptest" >&2; exit 2; }
python3 - <<'PY'
import random, os
random.seed(int.from_bytes(os.urandom(4), 'little'))
h = lambda n: os.urandom(n).hex()
out = []
for c, ks, bs in [('aes', [16, 24, 32], 16), ('blowfish', list(range(8, 57)), 8),
                  ('serpent', [16, 24, 32], 16), ('twofish', [16, 24, 32], 16)]:
    for _ in range(400): out.append(f'E {c} {h(random.choice(ks))} {h(bs)}')
    for mode in ['ctr', 'cfb']:
        for _ in range(150): out.append(f'M {c} {mode} {h(random.choice(ks))} {h(bs)} {h(random.randint(1, 5000))}')
for n in list(range(1, 300)) + [1000, 65536, 100000]: out.append(f'H {h(n)}')
out.append('H -')
for _ in range(300):
    out.append(f'P {h(random.randint(1, 40))} {h(random.randint(8, 64))} {random.randint(1, 1500)} {random.randint(1, 130)}')
open('cases.txt', 'w').write('\n'.join(out) + '\n')
PY
./ptest < cases.txt > r_pas.txt; ./o117 < cases.txt > r_117.txt; ./o118 < cases.txt > r_118.txt
# Línea por línea (un archivo vacío o corto tiene que contar como diferencia)
[ "$(wc -l < r_pas.txt)" = "$(wc -l < cases.txt)" ] || { echo "ptest no respondió todos los casos" >&2; exit 1; }
d117=$(paste -d'|' r_pas.txt r_117.txt | awk -F'|' '$1!=$2' | wc -l)
d118=$(paste -d'|' cases.txt r_pas.txt r_118.txt | grep -v '^[EM] serpent' | awk -F'|' '$2!=$3' | wc -l)
echo "== cifrado: $(wc -l < cases.txt) casos; diferencias con LibTomCrypt 1.17 (FreeArc): $d117; con 1.18.2: $d118"
[ "$d117" = 0 ] && [ "$d118" = 0 ]
