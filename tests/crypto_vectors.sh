#!/bin/bash
# tests/crypto_vectors.sh — primitivas de cifrado de PArc (parc_blake2, parc_chacha, parc_aes) y el
# formato de los bloques cifrados (parc_crypt), contra:
#   1. los vectores oficiales (tests/crypto/vectors.txt: RFC 7693, RFC 9106, RFC 8439,
#      draft-irtf-cfrg-xchacha, FIPS 197, casos 13-16 de GCM);
#   2. los vectores de NIST CAVP para AES-256-GCM (gcmEncryptExtIV256 y gcmDecrypt256, nonce de
#      96 bits y etiqueta de 128), si se pueden bajar (o están en $CAVP_DIR);
#   3. miles de casos al azar contra implementaciones independientes (tests/crypto/oracle.py:
#      hashlib, python-cryptography/OpenSSL, PyNaCl/libsodium, openssl kdf);
#   4. las etapas de trozos de 64 KiB (tests/crypto/stream_test.pas);
#   5. un bloque de un .parc descifrado en Python con el esquema del formato (parc_block.py).
# Cada cosa con el camino x86-64 (AVX2, AES-NI, PCLMULQDQ), con PARC_CRYPT=pas (sin AVX2 ni
# AES-NI) y con el build -dPARC_NOASM (todo Pascal, también Poly1305): tienen que dar lo mismo.
set -u
ROOT=$(cd "$(dirname "$0")/.." && pwd)
PARC=${PARC_BIN:-$ROOT/build/linux64/parc}
W=${CRYPTO_WORK:-${TMPDIR:-/tmp}/parc_crypto_vectors}
N=${CRYPTO_CASES:-4000}
CAVP_DIR=${CAVP_DIR:-/mnt/IA_LAB/compartido/parc/crypto-oracle/cavp-gcm}
CAVP_URL=https://csrc.nist.gov/CSRC/media/Projects/Cryptographic-Algorithm-Validation-Program/documents/mac/gcmtestvectors.zip
O="python3 -I $ROOT/tests/crypto/oracle.py"
rm -rf -- "${W:?}/u" "$W/un"; mkdir -p "$W/u" "$W/un" && cd "$W" || exit 2
python3 -c 'import cryptography, nacl' 2>/dev/null || { echo "faltan python3-cryptography / python3-nacl" >&2; exit 2; }
for v in "" _noasm; do
  if [ -z "$v" ]; then D=; U=u; else D=-dPARC_NOASM; U=un; fi
  fpc -O3 $D -Fu"$ROOT/src" -FU"$W/$U" -o"$W/ptest$v" "$ROOT/tests/crypto/ptest.pas" >/dev/null || exit 2
  fpc -O3 $D -Fu"$ROOT/src" -FU"$W/$U" -o"$W/stream$v" "$ROOT/tests/crypto/stream_test.pas" >/dev/null || exit 2
done
fail=0
check() { if eval "$2"; then printf '  ok    %s\n' "$1"; else printf '  FAIL  %s\n' "$1"; fail=$((fail+1)); fi; }
# compara las tres variantes con lo esperado: run <casos> <esperado>
run() {
  local c=$1 e=$2 r
  for r in asm pas noasm; do
    case $r in
      asm) ./ptest < "$c" > "r_$r.txt" ;;
      pas) PARC_CRYPT=pas ./ptest < "$c" > "r_$r.txt" ;;
      noasm) ./ptest_noasm < "$c" > "r_$r.txt" ;;
    esac
    cmp -s "r_$r.txt" "$e" || { echo "    ($r: $(diff "r_$r.txt" "$e" | grep -c '^<') diferencias)"; return 1; }
  done
}

echo '-- vectores oficiales'
grep -v '^#' "$ROOT/tests/crypto/vectors.txt" | cut -f1 > v.txt
grep -v '^#' "$ROOT/tests/crypto/vectors.txt" | cut -f2 > v_exp.txt
check "$(wc -l < v.txt) vectores (BLAKE2b, Argon2d/i/id, ChaCha20, Poly1305, AEAD, XChaCha20, AES, GCM)" 'run v.txt v_exp.txt'
check "el oráculo da lo mismo con los oficiales" "$O expect < v.txt | cmp -s - v_exp.txt"

echo '-- NIST CAVP AES-256-GCM'
if [ ! -f "$CAVP_DIR/gcmEncryptExtIV256.rsp" ]; then
  mkdir -p "$CAVP_DIR" 2>/dev/null && curl -fsS -m 120 -o "$W/gcm.zip" "$CAVP_URL" 2>/dev/null &&
    unzip -o -q "$W/gcm.zip" gcmEncryptExtIV256.rsp gcmDecrypt256.rsp -d "$CAVP_DIR"
fi
if [ -f "$CAVP_DIR/gcmEncryptExtIV256.rsp" ]; then
  $O nist "$CAVP_DIR/gcmEncryptExtIV256.rsp" "$CAVP_DIR/gcmDecrypt256.rsp" > nist.txt
  cut -f1 nist.txt > n.txt; cut -f2 nist.txt > n_exp.txt
  check "$(wc -l < n.txt) casos de CAVP ($(grep -c FAIL n_exp.txt) que tienen que fallar)" 'run n.txt n_exp.txt'
else
  echo "  (sin los .rsp de CAVP: no se pudieron bajar; se saltean)"
fi

echo '-- al azar contra implementaciones independientes'
seed=${CRYPTO_SEED:-$RANDOM}
$O gen "$N" "$seed" > c.txt && $O expect < c.txt > c_exp.txt || exit 2
check "$(wc -l < c.txt) casos al azar (semilla $seed; aperturas con bits cambiados: $(grep -c FAIL c_exp.txt))" 'run c.txt c_exp.txt'
$O gen-argon2 250 "$seed" > a.txt && $O expect < a.txt > a_exp.txt || exit 2
check "250 casos de Argon2 (d/i/id, p 1-8, secreto y AD)" 'run a.txt a_exp.txt'
(echo T 4; cat a.txt) | ./ptest | tail -n +2 > a_t4.txt
check "  los mismos con 4 hilos"                'cmp -s a_t4.txt a_exp.txt'

echo '-- trozos de 64 KiB'
check "etapas (bordes, cortes, trozos de más, reordenados, alterados)" './stream | tail -1 | grep -q " 0 fallas" && PARC_CRYPT=pas ./stream | tail -1 | grep -q " 0 fallas" && ./stream_noasm | tail -1 | grep -q " 0 fallas"'

echo '-- formato: un bloque de .parc descifrado en Python'
if [ -x "$PARC" ]; then
  head -c 300000 /dev/urandom > f.bin
  for a in chacha aes; do
    rm -f "$a.parc"; "$PARC" a "$a.parc" f.bin -m0 -p'clave ñ' -ae=$a --no-progress >/dev/null 2>&1
    L=$("$PARC" lb "$a.parc" 2>/dev/null | grep 'orig=300000')
    pos=$(echo "$L" | sed 's/.*pos=\([0-9]*\).*/\1/'); comp=$(echo "$L" | sed 's/.*comp=\([0-9]*\).*/\1/')
    st=$(echo "$L" | grep -oE '(xchacha20|aes256gcm):[^ +]*')
    check "-ae=$a: $st" "python3 -I '$ROOT/tests/crypto/parc_block.py' '$a.parc' 'clave ñ' '$pos' '$comp' '$st' '$a.out' >/dev/null && cmp -s f.bin '$a.out'"
  done
else
  echo "  (sin $PARC: se saltea)"
fi
rm -f f.bin ./*.parc ./*.out gcm.zip

echo "== crypto vectors: $fail failures"
[ $fail -eq 0 ]
