#!/usr/bin/env python3
"""Descifra un bloque de datos de un .parc con el esquema de docs/formato/FORMATO-PARC.md §3b,
con implementaciones independientes (openssl para Argon2id, hashlib para BLAKE2b, PyNaCl /
libsodium para XChaCha20-Poly1305 y python-cryptography para AES-256-GCM).

  parc_block.py <archivo.parc> <contraseña> <pos> <comp> <etapa> <salida>

Comprueba el valor de comprobación de la contraseña y cada etiqueta; escribe el claro (el bloque
comprimido, o los datos si el método era storing)."""
import hashlib
import subprocess
import sys

import nacl.bindings as nb
from cryptography.hazmat.primitives.ciphers.aead import AESGCM

arc, pwd, pos, comp, stage, out = sys.argv[1], sys.argv[2].encode(), int(sys.argv[3]), int(sys.argv[4]), sys.argv[5], sys.argv[6]
parts = stage.split(':')
cipher = parts[0]
p = {x[0]: x[1:] for x in parts[1:]}
t, m, lanes = int(p['t']), int(p['m']), int(p['p'])
salt, check, nonce = bytes.fromhex(p['s']), bytes.fromhex(p['c']), bytes.fromhex(p['n'])
header = 'h' in p

kdf = subprocess.run(['openssl', 'kdf', '-keylen', '32', '-kdfopt', 'hexpass:' + pwd.hex(), '-kdfopt', 'hexsalt:' + salt.hex(),
                      '-kdfopt', 'iter:%d' % t, '-kdfopt', 'memcost:%d' % m, '-kdfopt', 'lanes:%d' % lanes,
                      '-kdfopt', 'threads:1', 'ARGON2ID'], capture_output=True, text=True, check=True).stdout
master = bytes.fromhex(kdf.strip().replace(':', ''))


def sub(label):
    return hashlib.blake2b(('PArc/1 ' + label).encode(), digest_size=32, key=master).digest()


assert sub('check')[:8] == check, 'valor de comprobación distinto'
kuse = sub(('header ' if header else 'data ') + cipher)
data = open(arc, 'rb').read()[pos:pos + comp]
CH, TAG = 65536, 16
res = bytearray()
i = 0
off = 0
while True:
    rest = len(data) - off
    last = rest <= CH + TAG
    n = rest if last else CH + TAG
    chunk = data[off:off + n]
    if cipher == 'xchacha20':
        nn = nonce + i.to_bytes(7, 'little') + bytes([last])
        res += nb.crypto_aead_xchacha20poly1305_ietf_decrypt(chunk, None, nn, kuse)
    else:
        kblk = hashlib.blake2b(nonce, digest_size=32, key=kuse).digest()
        nn = i.to_bytes(11, 'little') + bytes([last])
        res += AESGCM(kblk).decrypt(nn, chunk, None)
    off += n
    i += 1
    if last:
        break
open(out, 'wb').write(res)
print('ok', cipher, i, 'trozos', len(res), 'bytes')
