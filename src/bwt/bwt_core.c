/* bwt_core.c - the C core of PArc's `bwt` codec (src/parc_bwt.pas), MIT.

   One translation unit with:
     - libsais 2.12.2 (src/bwt/libsais.c, Apache-2.0 WITH LLVM-exception, vendored unchanged):
       suffix sorting for the forward BWT and the inverse BWT;
     - qlfc.c: the QLFC entropy coders, from libbsc 3.4.1 (Apache-2.0; see its header for
       the changes);
   and a tiny runtime so the object needs nothing from the C library (like OREP's core): the
   memory functions are local, and the only allocation (libsais' temporary buckets) goes to the
   allocator that the Pascal side registers with parc_bwt_set_alloc.

   build.sh compiles it per target with -ffreestanding -fno-builtin; src/parc_bwt.pas links
   the object with {$L bwt_core.o}. */

#include <stddef.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>
#include <limits.h>

/* Windows (mingw): functions with frames over a page call ___chkstk_ms to touch the stack pages in order
   (the guard page grows the stack one page at a time). It lives in libgcc, which FPC does not link, so here is
   one: probe every page from the caller's stack pointer down to SP - EAX/RAX, all registers preserved. */
#if defined(_WIN32) && defined(__x86_64__)
__asm__(
    ".text\n"
    ".globl ___chkstk_ms\n"
    "___chkstk_ms:\n"
    "    pushq %rcx\n"
    "    pushq %rax\n"
    "    leaq 24(%rsp), %rcx\n"
    "1:  cmpq $0x1000, %rax\n"
    "    jb 2f\n"
    "    subq $0x1000, %rcx\n"
    "    orq $0, (%rcx)\n"
    "    subq $0x1000, %rax\n"
    "    jmp 1b\n"
    "2:  subq %rax, %rcx\n"
    "    orq $0, (%rcx)\n"
    "    popq %rax\n"
    "    popq %rcx\n"
    "    ret\n");
#elif defined(_WIN32) && defined(__i386__)
__asm__(
    ".text\n"
    ".globl ___chkstk_ms\n"
    "___chkstk_ms:\n"
    "    pushl %ecx\n"
    "    pushl %eax\n"
    "    leal 12(%esp), %ecx\n"
    "1:  cmpl $0x1000, %eax\n"
    "    jb 2f\n"
    "    subl $0x1000, %ecx\n"
    "    orl $0, (%ecx)\n"
    "    subl $0x1000, %eax\n"
    "    jmp 1b\n"
    "2:  subl %eax, %ecx\n"
    "    orl $0, (%ecx)\n"
    "    popl %eax\n"
    "    popl %ecx\n"
    "    ret\n");
#endif

typedef void * (*parc_bwt_alloc_fn)(size_t size);
typedef void (*parc_bwt_free_fn)(void * p);

static parc_bwt_alloc_fn parc_bwt_alloc_cb;
static parc_bwt_free_fn  parc_bwt_free_cb;

void parc_bwt_set_alloc(parc_bwt_alloc_fn a, parc_bwt_free_fn f)
{
    parc_bwt_alloc_cb = a; parc_bwt_free_cb = f;
}

static void * parc_bwt_malloc(size_t size) { return parc_bwt_alloc_cb ? parc_bwt_alloc_cb(size) : NULL; }
static void parc_bwt_free(void * p) { if (p != NULL && parc_bwt_free_cb) parc_bwt_free_cb(p); }

static void * parc_bwt_memcpy(void * d, const void * s, size_t n)
{
    unsigned char * dp = (unsigned char *)d; const unsigned char * sp = (const unsigned char *)s;
    while (n >= 8) { uint64_t v; __builtin_memcpy(&v, sp, 8); __builtin_memcpy(dp, &v, 8); dp += 8; sp += 8; n -= 8; }
    while (n--) *dp++ = *sp++;
    return d;
}

static void * parc_bwt_memmove(void * d, const void * s, size_t n)
{
    unsigned char * dp = (unsigned char *)d; const unsigned char * sp = (const unsigned char *)s;
    if (dp == sp || n == 0) return d;
    if (dp < sp || dp >= sp + n) return parc_bwt_memcpy(d, s, n);
    dp += n; sp += n;
    while (n--) *--dp = *--sp;
    return d;
}

static void * parc_bwt_memset(void * d, int c, size_t n)
{
    unsigned char * dp = (unsigned char *)d;
    uint64_t v = (unsigned char)c; v |= v << 8; v |= v << 16; v |= v << 32;
    while (n >= 8) { __builtin_memcpy(dp, &v, 8); dp += 8; n -= 8; }
    while (n--) *dp++ = (unsigned char)c;
    return d;
}

static void * parc_bwt_memchr(const void * s, int c, size_t n)
{
    const unsigned char * p = (const unsigned char *)s;
    for (; n; --n, ++p) if (*p == (unsigned char)c) return (void *)p;
    return NULL;
}

#define memchr  parc_bwt_memchr
#define malloc  parc_bwt_malloc
#define free    parc_bwt_free
#define memcpy  parc_bwt_memcpy
#define memmove parc_bwt_memmove
#define memset  parc_bwt_memset

#include "libsais.c"

#undef ALPHABET_SIZE
#undef INLINE
#undef RESTRICT
#include "qlfc.c"

/* LZP encoder of src/parc_lzp.pas (LzpEncodeBlock, PArc's own, MIT) in C, for the bwt blocks: the same
   algorithm and the same bytes (tests/bwt.sh compares them), without the barrier (bwt uses one minimum).
   hb = LzpBlockHashBits(len, hash bits); hash: 2 << hb entries; main: len bytes; lens: lensCap bytes.
   Returns 1 when the coded block (main + lens) is smaller than the input, else 0. */
static inline uint64_t lzp_load64(const uint8_t * p) { uint64_t v; __builtin_memcpy(&v, p, 8); return v; }

static inline uint32_t lzp_hash(const uint8_t * p, int shift)
{
    return (uint32_t)(((lzp_load64(p - 8) >> 32) * 0x9E3779B97F4A7C15ull) >> shift);
}

static inline int32_t lzp_match_len(const uint8_t * a, const uint8_t * b, int32_t limit)
{
    int32_t r = 0;
    while (r + 8 <= limit)
    {
        uint64_t x = lzp_load64(a + r) ^ lzp_load64(b + r);
        if (x != 0) return r + (int32_t)(__builtin_ctzll(x) >> 3);
        r += 8;
    }
    while (r < limit && a[r] == b[r]) r++;
    return r;
}

#define LZP_PUTLEN(V)                                                                   \
    do {                                                                                \
        int32_t v_ = (V);                                                               \
        if (nl + v_ / 255 + 2 > lensCap) return 0;                                      \
        while (v_ >= 255) { lens[nl++] = 255; v_ -= 255; }                              \
        lens[nl++] = (uint8_t)v_;                                                       \
    } while (0)

int32_t parc_lzp_encode(const uint8_t * in, int32_t len, int32_t minLen, int32_t hb, uint32_t * hash,
    uint8_t * out, uint8_t * lens, int32_t lensCap, int32_t * nMain, int32_t * nLens, uint8_t * escOut)
{
    enum { CTX_START = 8, PF = 8 };
    uint32_t f4[4][256];
    uint32_t ring[PF];
    int32_t i, nm = 0, nl = 0, ringEnd = 0, c;
    int shift = 64 - hb;
    uint8_t esc = 0;

    *nMain = 0; *nLens = 0; *escOut = 0;
    if (len <= 2 * CTX_START) return 0;
    parc_bwt_memset(f4, 0, sizeof(f4));
    for (i = 0; i + 4 <= len; i += 4) { f4[0][in[i]]++; f4[1][in[i + 1]]++; f4[2][in[i + 2]]++; f4[3][in[i + 3]]++; }
    for (; i < len; ++i) f4[0][in[i]]++;
    {
        uint64_t best = (uint64_t)f4[0][0] + f4[1][0] + f4[2][0] + f4[3][0];
        for (c = 1; c < 256; ++c)
        {
            uint64_t f = (uint64_t)f4[0][c] + f4[1][c] + f4[2][c] + f4[3][c];
            if (f < best) { best = f; esc = (uint8_t)c; }
        }
    }
    *escOut = esc;
    parc_bwt_memset(hash, 0, ((size_t)2 << hb) * sizeof(uint32_t));
    for (i = 0; i < CTX_START; ++i)
    {
        uint8_t b = in[i];
        out[nm++] = b;
        if (b == esc) LZP_PUTLEN(0);
    }
    i = CTX_START;
    while (i < len)
    {
        uint32_t h;
        if (i >= ringEnd)
        {
            ringEnd = i;
            while (ringEnd < i + PF && ringEnd < len)
            {
                ring[ringEnd & (PF - 1)] = lzp_hash(in + ringEnd, shift) * 2;
                __builtin_prefetch(&hash[ring[ringEnd & (PF - 1)]]);
                ringEnd++;
            }
        }
        h = ring[i & (PF - 1)];
        if (ringEnd < len)
        {
            ring[ringEnd & (PF - 1)] = lzp_hash(in + ringEnd, shift) * 2;
            __builtin_prefetch(&hash[ring[ringEnd & (PF - 1)]]);
            ringEnd++;
        }
        {
            int32_t p = (int32_t)hash[h], p2 = (int32_t)hash[h + 1];
            hash[h + 1] = (uint32_t)p;
            hash[h] = (uint32_t)i;
            if (p != 0 && i + 8 <= len)
            {
                uint64_t cur8 = lzp_load64(in + i);
                int32_t L = 0, which = 0;
                if (lzp_load64(in + p) == cur8) L = lzp_match_len(in + p, in + i, len - i);
                if (p2 != 0 && lzp_load64(in + p2) == cur8)
                {
                    int32_t L2 = lzp_match_len(in + p2, in + i, len - i);
                    if (L2 >= minLen && (L < minLen || L2 > L)) { L = L2; which = 1; }
                }
                if (L >= minLen)
                {
                    if (nm >= len - 1) return 0;
                    out[nm++] = esc;
                    LZP_PUTLEN(2 * (L - minLen) + 1 + which);
                    i += L;
                    continue;
                }
            }
        }
        {
            uint8_t b = in[i];
            if (nm >= len - 1) return 0;
            out[nm++] = b;
            if (b == esc) LZP_PUTLEN(0);
            i++;
        }
    }
    *nMain = nm; *nLens = nl;
    return nm + nl < len;
}

/* Share of long repeats in in[0..len), in per mille, estimated from content-defined anchors (about
   one position in 32, chosen by its 4 bytes, so repeats are found at any offset): the share of
   anchors whose next 32 bytes were already seen at an earlier anchor. tab: 65536 entries. */
int32_t parc_repeat_share(const uint8_t * in, int32_t len, uint32_t * tab)
{
    int64_t anchors = 0, hits = 0;
    int32_t i;
    parc_bwt_memset(tab, 0, 65536 * sizeof(uint32_t));
    for (i = 0; i + 40 <= len; i++)
    {
        uint32_t v; __builtin_memcpy(&v, in + i, 4);
        if (((v * 0x9E3779B1u) >> 27) != 0) continue;
        anchors++;
        uint64_t k = (lzp_load64(in + i) * 0x9E3779B97F4A7C15ull) ^ (lzp_load64(in + i + 8) * 0xC2B2AE3D27D4EB4Full) ^
                     (lzp_load64(in + i + 16) * 0x165667B19E3779F9ull) ^ (lzp_load64(in + i + 24) * 0x27D4EB2F165667C5ull);
        uint32_t slot = (uint32_t)(k >> 48), chk = (uint32_t)k | 1;
        if (tab[slot] == chk) hits++; else tab[slot] = chk;
    }
    return anchors ? (int32_t)(hits * 1000 / anchors) : 0;
}

/* Forward BWT of T[0..n) into U (may be T), A: n int32 of scratch. Returns the primary index (1..n), or < 0. */
int32_t parc_bwt_forward(const uint8_t * T, uint8_t * U, int32_t * A, int32_t n)
{
    return libsais_bwt(T, U, A, n, 0, NULL);
}

/* Inverse BWT of T[0..n) with the primary index into U (may be T), A: n + 1 int32. Returns 0, or < 0 if the index is
   out of range. */
int32_t parc_bwt_inverse(const uint8_t * T, uint8_t * U, int32_t * A, int32_t n, int32_t primary)
{
    return libsais_unbwt(T, U, A, n, NULL, primary);
}
