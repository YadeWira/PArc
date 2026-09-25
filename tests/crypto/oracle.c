/* Oráculo LibTomCrypt: lee casos por stdin, imprime el resultado en hex (uno por línea).
   E <cifra> <clave> <bloque>            cifrado ECB de un bloque
   H <datos>                             SHA-512
   P <pwd> <sal> <iter> <largo>          PBKDF2-HMAC-SHA512 (pkcs_5_alg2)
   M <cifra> ctr|cfb <clave> <iv> <datos> CTR (contador little-endian, como FreeArc): cifrar;
                                          CFB: DEScifrar (lo que hace el lado lector) */
#ifdef LTC117
#define LTC_NO_CIPHERS
#define   LTC_BLOWFISH
#define   LTC_RIJNDAEL
#define     ENCRYPT_ONLY
#define   LTC_TWOFISH
#define   LTC_SERPENT
#define LTC_NO_MODES
#define   LTC_CFB_MODE
#define   LTC_CTR_MODE
#define LTC_NO_HASHES
#define   LTC_SHA512
#define LTC_NO_MACS
#define   LTC_HMAC
#define LTC_NO_MATH
#define LTC_NO_PK
#define   LTC_MECC
#define LTC_NO_TEST
#include "ciphers/aes/aes.c"
#include "ciphers/blowfish.c"
#include "ciphers/twofish/twofish.c"
#include "ciphers/serpent.c"
#include "crypt/crypt_argchk.c"
#include "crypt/crypt_cipher_descriptor.c"
#include "crypt/crypt_cipher_is_valid.c"
#include "crypt/crypt_find_cipher.c"
#include "crypt/crypt_find_hash.c"
#include "crypt/crypt_hash_descriptor.c"
#include "crypt/crypt_hash_is_valid.c"
#include "crypt/crypt_register_cipher.c"
#include "crypt/crypt_register_hash.c"
#include "hashes/helper/hash_memory.c"
#include "hashes/sha2/sha512.c"
#include "mac/hmac/hmac_done.c"
#include "mac/hmac/hmac_init.c"
#include "mac/hmac/hmac_memory.c"
#include "mac/hmac/hmac_process.c"
#include "misc/pkcs5/pkcs_5_2.c"
#include "misc/zeromem.c"
#include "modes/ctr/ctr_encrypt.c"
#include "modes/ctr/ctr_start.c"
#include "modes/cfb/cfb_decrypt.c"
#include "modes/cfb/cfb_start.c"
#else
#include <tomcrypt.h>
#endif
#include <stdio.h>
#include <string.h>
#include <stdlib.h>

static int unhex(const char *s, unsigned char *b) { int n = strlen(s) / 2; for (int i = 0; i < n; i++) sscanf(s + 2*i, "%2hhx", &b[i]); return n; }
static void phex(const unsigned char *b, int n) { for (int i = 0; i < n; i++) printf("%02x", b[i]); printf("\n"); }
static int cid(const char *n) {
  if (!strcmp(n, "aes")) return find_cipher("aes") >= 0 ? find_cipher("aes") : find_cipher("rijndael");
  return find_cipher(n);
}
int main(void) {
#ifdef LTC117
  register_cipher(&aes_enc_desc);   /* FreeArc compila AES con ENCRYPT_ONLY */
#else
  register_cipher(&aes_desc);
#endif
  register_cipher(&blowfish_desc); register_cipher(&twofish_desc);
#ifdef LTC117
  register_cipher(&serpent_desc);
#endif
  register_hash(&sha512_desc);
  static char line[1 << 22], a[64], b[1 << 20], c[1 << 20], d[1 << 21], e[64];
  static unsigned char k[256], p[1 << 20], o[1 << 20], iv[64];
  while (fgets(line, sizeof line, stdin)) {
    if (line[0] == 'E') {
      sscanf(line + 2, "%63s %s %s", a, b, c);
      int c_ = cid(a); if (c_ < 0) { printf("sin-cifra\n"); continue; }
      int kl = unhex(b, k), pl = unhex(c, p); symmetric_key sk;
      if (cipher_descriptor[c_].setup(k, kl, 0, &sk) != CRYPT_OK) { printf("setup-error\n"); continue; }
      cipher_descriptor[c_].ecb_encrypt(p, o, &sk); phex(o, pl);
    } else if (line[0] == 'H') {
      sscanf(line + 2, "%s", d); int n = strcmp(d, "-") ? unhex(d, p) : 0; unsigned long ol = 64;
      hash_memory(find_hash("sha512"), p, n, o, &ol); phex(o, 64);
    } else if (line[0] == 'P') {
      int it, ol_; sscanf(line + 2, "%s %s %d %d", b, c, &it, &ol_);
      int pl = unhex(b, p), sl = unhex(c, k); unsigned long ol = ol_;
      pkcs_5_alg2(p, pl, k, sl, it, find_hash("sha512"), o, &ol); phex(o, ol);
    } else if (line[0] == 'M') {
      sscanf(line + 2, "%63s %63s %s %s %s", a, e, b, c, d);
      int c_ = cid(a); if (c_ < 0) { printf("sin-cifra\n"); continue; }
      int kl = unhex(b, k); unhex(c, iv); int n = unhex(d, p);
      if (!strcmp(e, "ctr")) { symmetric_CTR s; ctr_start(c_, iv, k, kl, 0, CTR_COUNTER_LITTLE_ENDIAN, &s); ctr_encrypt(p, o, n, &s); }
      else { symmetric_CFB s; cfb_start(c_, iv, k, kl, 0, &s); cfb_decrypt(p, o, n, &s); }
      phex(o, n);
    }
    fflush(stdout);
  }
  return 0;
}
