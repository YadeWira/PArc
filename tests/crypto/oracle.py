#!/usr/bin/env python3
"""Oráculo independiente para las primitivas de cifrado de PArc (protocolo de tests/crypto/ptest.pas).

  oracle.py gen <n> <semilla>     casos al azar en stdout
  oracle.py expect                lee casos de stdin y escribe la respuesta esperada
  oracle.py nist <archivo.rsp>..  casos "caso\\tesperado" de los .rsp de NIST CAVP (gcm*256)

Implementaciones independientes: hashlib (BLAKE2b), python-cryptography / OpenSSL
(ChaCha20, Poly1305, ChaCha20-Poly1305, AES, AES-GCM), PyNaCl / libsodium (XChaCha20-Poly1305,
HChaCha20 por ctypes, Argon2id/Argon2i con p = 1) y el CLI de openssl (Argon2 con p > 1,
secreto y datos asociados).
"""
import ctypes
import hashlib
import os
import random
import subprocess
import sys

from cryptography.hazmat.primitives.ciphers import Cipher, algorithms, modes
from cryptography.hazmat.primitives.ciphers.aead import AESGCM, ChaCha20Poly1305
from cryptography.hazmat.primitives.poly1305 import Poly1305
from cryptography.exceptions import InvalidTag
import nacl.bindings as nb

sodium = ctypes.CDLL('libsodium.so.23')
sodium.sodium_init()


def h(b):
    return b.hex() if b else '-'


def u(s):
    return b'' if s == '-' else bytes.fromhex(s)


def hchacha(key, nonce):
    out = ctypes.create_string_buffer(32)
    sodium.crypto_core_hchacha20(out, nonce, key, None)
    return out.raw


def argon2(kind, t, m, p, tlen, pwd, salt, secret, ad):
    # libsodium: sólo p = 1, sin secreto ni AD, sal de 16 bytes
    if p == 1 and not secret and not ad and len(salt) == 16 and kind in ('i', 'id') and tlen >= 16:
        alg = {'i': 1, 'id': 2}[kind]
        out = ctypes.create_string_buffer(tlen)
        r = sodium.crypto_pwhash(out, ctypes.c_ulonglong(tlen), pwd, ctypes.c_ulonglong(len(pwd)), salt,
                                 ctypes.c_ulonglong(t), ctypes.c_size_t(m * 1024), ctypes.c_int(alg))
        if r == 0:
            return out.raw
    args = ['openssl', 'kdf', '-keylen', str(tlen), '-kdfopt', 'hexpass:' + pwd.hex(),
            '-kdfopt', 'hexsalt:' + salt.hex(), '-kdfopt', 'iter:%d' % t, '-kdfopt', 'memcost:%d' % m,
            '-kdfopt', 'lanes:%d' % p, '-kdfopt', 'threads:1']
    if secret:
        args += ['-kdfopt', 'hexsecret:' + secret.hex()]
    if ad:
        args += ['-kdfopt', 'hexad:' + ad.hex()]
    args.append({'d': 'ARGON2D', 'i': 'ARGON2I', 'id': 'ARGON2ID'}[kind])
    out = subprocess.run(args, capture_output=True, text=True, check=True).stdout
    return bytes.fromhex(out.strip().replace(':', ''))


def expect(line):
    f = line.split()
    c = f[0]
    if c == 'T':
        return 'ok'
    if c == 'B2':
        key = u(f[2])
        return hashlib.blake2b(u(f[3]), digest_size=int(f[1]), key=key).hexdigest()
    if c == 'A2':
        return h(argon2(f[1], int(f[2]), int(f[3]), int(f[4]), int(f[5]), u(f[6]), u(f[7]), u(f[8]), u(f[9])))
    if c == 'CC':
        nonce = int(f[3]).to_bytes(4, 'little') + u(f[2])
        enc = Cipher(algorithms.ChaCha20(u(f[1]), nonce), mode=None).encryptor()
        return h(enc.update(u(f[4])))
    if c == 'HC':
        return h(hchacha(u(f[1]), u(f[2])))
    if c == 'P5':
        return h(Poly1305.generate_tag(u(f[1]), u(f[2])))
    if c == 'AE':
        enc = Cipher(algorithms.AES(u(f[1])), modes.ECB()).encryptor()
        return h(enc.update(u(f[2])))
    key, nonce, ad, msg = u(f[1]), u(f[2]), u(f[3]), u(f[4])
    if c == 'CP':
        return h(ChaCha20Poly1305(key).encrypt(nonce, msg, ad or None))
    if c == 'GC':
        return h(AESGCM(key).encrypt(nonce, msg, ad or None))
    if c == 'XC':
        return h(nb.crypto_aead_xchacha20poly1305_ietf_encrypt(msg, ad or None, nonce, key))
    try:
        if c == 'CO':
            return h(ChaCha20Poly1305(key).decrypt(nonce, msg, ad or None))
        if c == 'GO':
            return h(AESGCM(key).decrypt(nonce, msg, ad or None))
        if c == 'XO':
            return h(nb.crypto_aead_xchacha20poly1305_ietf_decrypt(msg, ad or None, nonce, key))
    except (InvalidTag, nacl_error()):
        return 'FAIL'
    raise ValueError(line)


def nacl_error():
    import nacl.exceptions
    return nacl.exceptions.CryptoError


def gen(n, seed):
    rnd = random.Random(seed)
    rb = lambda k: bytes(rnd.getrandbits(8) for _ in range(k))
    # largos que cruzan los bordes de los caminos (bloques de 16/64, vueltas de 4·64 y 8·16)
    def ln():
        r = rnd.random()
        if r < 0.3:
            return rnd.randint(0, 80)
        if r < 0.6:
            return rnd.choice([255, 256, 257, 511, 512, 513, 1023, 1024, 1025, 127, 128, 129, 143, 144])
        if r < 0.95:
            return rnd.randint(81, 5000)
        return rnd.choice([65536, 65537, 100000])
    out = []
    for _ in range(n):
        k = rnd.random()
        if k < 0.10:
            kl = rnd.choice([0, 0, 1, 16, 32, 63, 64])
            out.append('B2 %d %s %s' % (rnd.randint(1, 64), h(rb(kl)), h(rb(ln()))))
        elif k < 0.18:
            # (sin pasar de 2^32 bloques: el contador de RFC 8439 es de 32 bits y OpenSSL acarrea)
            msg = rb(ln())
            ctr = rnd.choice([0, 1, rnd.randint(0, 2**32 - 1)])
            ctr = min(ctr, 2**32 - 1 - len(msg) // 64 - 1)
            out.append('CC %s %s %d %s' % (h(rb(32)), h(rb(12)), ctr, h(msg)))
        elif k < 0.22:
            out.append('HC %s %s' % (h(rb(32)), h(rb(16))))
        elif k < 0.32:
            out.append('P5 %s %s' % (h(rb(32)), h(rb(ln()))))
        elif k < 0.36:
            out.append('AE %s %s' % (h(rb(32)), h(rb(16))))
        else:
            kind = rnd.choice(['CP', 'XC', 'GC'])
            nl = {'CP': 12, 'XC': 24, 'GC': 12}[kind]
            key, nonce, ad, msg = rb(32), rb(nl), rb(rnd.choice([0, 0, 1, 12, 16, 17, rnd.randint(0, 300)])), rb(ln())
            out.append('%s %s %s %s %s' % (kind, h(key), h(nonce), h(ad), h(msg)))
            # y abrirlo: bien, o con un bit cambiado (cifrado, etiqueta o AD)
            ct = bytes.fromhex(expect(out[-1]))
            r = rnd.random()
            if r < 0.5:
                ct = bytearray(ct)
                i = rnd.randrange(len(ct))
                ct[i] ^= 1 << rnd.randrange(8)
                ct = bytes(ct)
            elif r < 0.6 and ad:
                ad = bytes([ad[0] ^ 1]) + ad[1:]
            out.append('%s %s %s %s %s' % (kind[0] + 'O', h(key), h(nonce), h(ad), h(ct)))
    return out


def gen_argon2(n, seed):
    rnd = random.Random(seed)
    rb = lambda k: bytes(rnd.getrandbits(8) for _ in range(k))
    out = []
    for i in range(n):
        p = rnd.choice([1, 1, 2, 3, 4, 5, 8])
        m = rnd.randint(8 * p, 8 * p + 300)
        t = rnd.randint(1, 4)
        kind = rnd.choice(['d', 'i', 'id', 'id'])
        tl = rnd.choice([4, 16, 32, 32, 64, 65, 100, 128])
        sl = rnd.choice([8, 16, 16, 32])
        sec = rb(rnd.choice([0, 0, 0, 8, 32]))
        ad = rb(rnd.choice([0, 0, 0, 12, 40]))
        out.append('A2 %s %d %d %d %d %s %s %s %s' % (kind, t, m, p, tl, h(rb(rnd.randint(0, 40))), h(rb(sl)), h(sec), h(ad)))
    return out


def nist(files):
    out = []
    for fn in files:
        dec = 'Decrypt' in fn
        cur = {}
        params = {}
        for line in open(fn):
            line = line.strip()
            if line.startswith('['):
                k, _, v = line[1:-1].partition(' = ')
                params[k] = v
                continue
            if ' = ' in line or line.endswith('='):
                k, _, v = line.partition('=')
                cur[k.strip()] = v.strip()
            elif line == 'FAIL':
                cur['FAIL'] = True
            if line == '' and cur:
                if params.get('IVlen') == '96' and params.get('Taglen') == '128' and 'Tag' in cur:
                    key, iv, aad = cur['Key'], cur['IV'], cur.get('AAD', '') or '-'
                    if dec:
                        ct = (cur.get('CT', '') + cur['Tag'])
                        exp = 'FAIL' if cur.get('FAIL') else (cur.get('PT', '') or '-')
                        out.append('GO %s %s %s %s\t%s' % (key, iv, aad, ct, exp))
                    else:
                        out.append('GC %s %s %s %s\t%s' % (key, iv, aad, cur.get('PT', '') or '-', cur.get('CT', '') + cur['Tag']))
                cur = {}
    return out


if __name__ == '__main__':
    if sys.argv[1] == 'gen':
        print('\n'.join(gen(int(sys.argv[2]), int(sys.argv[3]))))
    elif sys.argv[1] == 'gen-argon2':
        print('\n'.join(gen_argon2(int(sys.argv[2]), int(sys.argv[3]))))
    elif sys.argv[1] == 'expect':
        for line in sys.stdin:
            if line.strip():
                print(expect(line))
    elif sys.argv[1] == 'nist':
        print('\n'.join(nist(sys.argv[2:])))
