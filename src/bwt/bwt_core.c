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
   anchors whose next 128 bytes (a signature of 4 words spread over them) were already seen at an
   earlier anchor. Repeats that short are common in dictionaries and markup, where the LZP does
   not pay; long ones (copies of texts, of files) are where it does. tab: 65536 entries. */
int32_t parc_repeat_share(const uint8_t * in, int32_t len, uint32_t * tab)
{
    int64_t anchors = 0, hits = 0;
    int32_t i;
    parc_bwt_memset(tab, 0, 65536 * sizeof(uint32_t));
    for (i = 0; i + 136 <= len; i++)
    {
        uint32_t v; __builtin_memcpy(&v, in + i, 4);
        if (((v * 0x9E3779B1u) >> 27) != 0) continue;
        anchors++;
        uint64_t k = (lzp_load64(in + i) * 0x9E3779B97F4A7C15ull) ^ (lzp_load64(in + i + 40) * 0xC2B2AE3D27D4EB4Full) ^
                     (lzp_load64(in + i + 80) * 0x165667B19E3779F9ull) ^ (lzp_load64(in + i + 120) * 0x27D4EB2F165667C5ull);
        uint32_t slot = (uint32_t)(k >> 48), chk = (uint32_t)k | 1;
        if (tab[slot] == chk) hits++; else tab[slot] = chk;
    }
    /* (32-bit arithmetic: no 64-bit division on 32-bit targets, which would need libgcc) */
    while (anchors >= ((int64_t)1 << 22)) { anchors >>= 1; hits >>= 1; }
    return anchors ? (int32_t)((uint32_t)hits * 1000u / (uint32_t)anchors) : 0;
}

/* Segmentation (see "adaptive blocks" in src/parc_bwt.pas): the best cut of p[0..n) by the order-1
   cost of the samples p[i - 1], p[i] for i = stride, 2 stride, ...; costs in 1/65536 bit, computed
   with integers only (the same cuts on every platform). work: 2 * 65536 + 2 * 256 uint32.
   Returns the cut (a multiple of stride, minSeg <= cut < n - minSeg), or 0 when no cut saves
   1/2^divShift of the cost plus penalty (in the same units). */
static int64_t seg_log2_fixed(uint64_t x)
{
    int k = 63 - __builtin_clzll(x), i;
    uint64_t m = k >= 31 ? x >> (k - 31) : x << (31 - k);
    int64_t r = (int64_t)k << 16;
    for (i = 15; i >= 0; --i)
    {
        m = (m * m) >> 31;
        if (m >= ((uint64_t)1 << 32)) { r += (int64_t)1 << i; m >>= 1; }
    }
    return r;
}

static inline int64_t seg_flogf(uint32_t f) { return f <= 1 ? 0 : (int64_t)f * seg_log2_fixed(f); }

static int32_t seg_d[65536];      /* seg_flogf(f + 1) - seg_flogf(f), built by parc_seg_init */
static int32_t seg_l[65536];      /* seg_log2_fixed(x) */

void parc_seg_init(void)
{
    for (uint32_t f = 0; f < 65536; ++f) seg_d[f] = (int32_t)(seg_flogf(f + 1) - seg_flogf(f));
    seg_l[0] = 0;
    for (uint32_t x = 1; x < 65536; ++x) seg_l[x] = (int32_t)seg_log2_fixed(x);
}

/* d(f) = (f + 1) log2 (f + 1) - f log2 f; above the table, log2 f + log2 e (exact to 1e-5 bit), with
   log2 f from the top 16 bits */
static inline int64_t seg_dd(uint32_t f)
{
    if (f < 65536) return seg_d[f];
    int s = (31 - __builtin_clz(f)) - 15;
    return (int64_t)seg_l[f >> s] + ((int64_t)s << 16) + 94548;
}

int32_t parc_seg_split(const uint8_t * p, int32_t n, int32_t stride, int32_t minSeg, int64_t penalty, int32_t divShift,
    uint32_t * work)
{
    uint32_t * T = work;               /* [ctx * 256 + sym] * 2: right, left */
    uint32_t * C = work + 2 * 65536;   /* [ctx] * 2 */
    int64_t whole = 0, cur, best;
    int32_t i, bi = 0, stop;
    if (n < 2 * minSeg) return 0;
    parc_bwt_memset(work, 0, (2 * 65536 + 2 * 256) * sizeof(uint32_t));
    for (i = stride; i < n; i += stride)
    {
        uint32_t c = p[i - 1];
        T[2 * ((c << 8) | p[i])]++;
        C[2 * c]++;
    }
    for (i = 0; i < 256; ++i) whole += seg_flogf(C[2 * i]);
    for (i = 0; i < 65536; ++i) whole -= seg_flogf(T[2 * i]);
    cur = whole;
    best = whole - (whole >> divShift) - penalty;
    stop = n - minSeg;
    for (i = stride; i < stop; i += stride)
    {
        if (cur < best && i >= minSeg) { best = cur; bi = i; }
        uint32_t c = p[i - 1];
        uint32_t * t = &T[2 * ((c << 8) | p[i])];
        uint32_t x = --t[0], y = t[1]++;
        cur += seg_dd(x) - seg_dd(y);
        uint32_t * q = &C[2 * c];
        x = --q[0]; y = q[1]++;
        cur += seg_dd(y) - seg_dd(x);
    }
    return bi;
}

/*---------------------------------------------------------------------------*/
/* Order-5 sort transform (ST5), from libbsc 3.4.1 st/st.cpp (Copyright (c) 2009-2026 Ilya Grebnov,  */
/* Apache-2.0): bsc_st5_transform_serial and the serial inverse (bsc_unst_sort_serial and the three */
/* reconstructions), translated to C. Changes: no allocation (the caller passes P and the buckets), */
/* and the inverse checks every link it follows against n and returns -1 on damaged data.         */
/*---------------------------------------------------------------------------*/

#define ST_ALPHABET 256
#define ST_SQRT 16

/* T[0..n) in place -> ST5 output; T must have 28 bytes of room after n. P: n uint32;
   bucket: 16 * 256 * 256 int32, zeroed by this function. Returns the index (0..n-1). */
int32_t parc_st5_forward(uint8_t * T, uint32_t * P, int32_t * bucket, int32_t n)
{
    int32_t i;
    if (n <= 1) return 0;
    for (i = 0; i < 28; ++i) T[n + i] = T[i];
    parc_bwt_memset(bucket, 0, (size_t)ST_SQRT * ST_ALPHABET * ST_ALPHABET * sizeof(int32_t));

    uint8_t C0 = T[n - 2] & 0xf, C1 = T[n - 1];
    for (i = 0; i < n; ++i)
    {
        uint8_t C2 = T[i];
        bucket[(C0 << 16) | (C1 << 8) | C2]++;
        C0 = C1 & 0xf; C1 = C2;
    }
    for (int32_t sum = 0, j = 0; j < ST_SQRT * ST_ALPHABET * ST_ALPHABET; ++j)
    {
        int32_t tmp = sum; sum += bucket[j]; bucket[j] = tmp;
    }

    int32_t pos = bucket[((T[2] & 0xf) << 16) | (T[3] << 8) | T[4]];

    uint8_t L = T[n - 1];
    uint32_t W = ((uint32_t)T[0] << 24) | ((uint32_t)T[1] << 16) | ((uint32_t)T[2] << 8) | T[3];
    for (i = 0; i < n; ++i)
    {
        uint32_t V = (W & 0xfffff000) | L;
        L = (uint8_t)(W >> 24); W = (W << 8) | T[i + 4];
        P[bucket[W & 0x000fffff]++] = V;
    }

    parc_bwt_memset(bucket, 0, (size_t)ST_SQRT * ST_ALPHABET * ST_ALPHABET * sizeof(int32_t));

    uint8_t P0 = T[n - 2], P1 = T[n - 1];
    for (i = 0; i < n; ++i)
    {
        uint8_t P2 = T[i];
        bucket[(P0 << 12) | (P1 << 4) | (P2 >> 4)]++;
        P0 = P1; P1 = P2;
    }
    for (int32_t sum = 0, j = 0; j < ST_SQRT * ST_ALPHABET * ST_ALPHABET; ++j)
    {
        sum += bucket[j]; bucket[j] = sum;
    }

    for (i = n - 1; i >= pos; --i) T[--bucket[P[i] >> 12]] = (uint8_t)(P[i] & 0xff);
    int32_t index = bucket[P[pos] >> 12];
    for (i = pos - 1; i >= 0; --i) T[--bucket[P[i] >> 12]] = (uint8_t)(P[i] & 0xff);

    return index;
}

/* inverse ST5 of T[0..n) in place; P: n uint32; bucket: 256 * 256 uint32. 0, or -1 if damaged. */
int32_t parc_st5_inverse(uint8_t * T, uint32_t * P, uint32_t * bucket, int32_t n, int32_t start)
{
    uint32_t count[ST_ALPHABET], index[ST_ALPHABET];
    int32_t group[ST_ALPHABET];
    int32_t i, c, failBack = 0;

    if (n <= 1) return (n == 1 && start == 0) || n == 0 ? 0 : -1;
    if (start < 0 || start >= n) return -1;
    parc_bwt_memset(P, 0, (size_t)n * sizeof(uint32_t));
    parc_bwt_memset(bucket, 0, (size_t)ST_ALPHABET * ST_ALPHABET * sizeof(uint32_t));
    parc_bwt_memset(count, 0, sizeof(count));

    /* sort: the group boundaries of order 2, 3, 4 and 5 */
    for (i = 0; i < n; ++i) count[T[i]]++;
    for (int32_t sum = 0, cc = 0; cc < ST_ALPHABET; ++cc)
    {
        if (count[cc] >= 0x800000) failBack = 1;
        int32_t tmp = sum; sum += (int32_t)count[cc]; count[cc] = (uint32_t)tmp;
        if ((int32_t)count[cc] != sum)
        {
            uint32_t * bucket_p = &bucket[cc << 8];
            for (i = (int32_t)count[cc]; i < sum; ++i) bucket_p[T[i]]++;
        }
    }
    for (c = 0; c < ST_ALPHABET; ++c)
        for (int32_t d = 0; d < c; ++d)
        {
            uint32_t tmp = bucket[(d << 8) | c]; bucket[(d << 8) | c] = bucket[(c << 8) | d]; bucket[(c << 8) | d] = tmp;
        }

    parc_bwt_memcpy(index, count, sizeof(index));
    for (c = 0; c < ST_ALPHABET; ++c) group[c] = -1;
    for (int32_t sum = 0, w = 0; w < ST_ALPHABET * ST_ALPHABET; ++w)
    {
        int32_t tmp = sum; sum += (int32_t)bucket[w]; bucket[w] = (uint32_t)tmp;
        if (sum > n) return -1;
        for (i = (int32_t)bucket[w]; i < sum; ++i)
        {
            uint8_t ch = T[i];
            if (group[ch] != w) { group[ch] = w; P[index[ch]] = 0x80000000u; }
            index[ch]++;
        }
    }
    {
        uint32_t mask0 = 0x80000000u, mask1 = 0x40000000u;   /* k = 5: one more round */
        parc_bwt_memcpy(index, count, sizeof(index));
        for (c = 0; c < ST_ALPHABET; ++c) group[c] = -1;
        for (int32_t g = 0, j = 0; j < n; ++j)
        {
            if (P[j] & mask0) g = j;
            uint8_t ch = T[j];
            if (group[ch] != g) { group[ch] = g; P[index[ch]] += mask1; }
            index[ch]++;
        }
    }

    if (n < 0x800000)
    {
        /* case 1 */
        parc_bwt_memcpy(index, count, sizeof(index));
        for (c = 0; c < ST_ALPHABET; ++c) group[c] = -1;
        for (int32_t g = 0, j = 0; j < n; ++j)
        {
            if (P[j] > 0) g = j;
            uint8_t ch = T[j];
            if (group[ch] < g) { group[ch] = j; P[j] = ((uint32_t)ch << 24) | index[ch]; }
            else { P[j] = ((uint32_t)ch << 24) | 0x800000 | (uint32_t)group[ch]; P[group[ch]]++; }
            index[ch]++;
        }
        for (int32_t p = start, j = n - 1; j >= 0; --j)
        {
            uint32_t u = P[p];
            if (u & 0x800000)
            {
                p = (int32_t)(u & 0x7fffff);
                if (p >= n) return -1;
                u = P[p];
            }
            T[j] = (uint8_t)(u >> 24); P[p]--; p = (int32_t)(u & 0x7fffff);
            if (p >= n) return -1;
        }
    }
    else if (!failBack)
    {
        /* case 2 */
        parc_bwt_memset(index, 0, sizeof(index));
        for (c = 0; c < ST_ALPHABET; ++c) group[c] = -1;
        for (int32_t g = 0, j = 0; j < n; ++j)
        {
            if (P[j] > 0) g = j;
            uint8_t ch = T[j];
            if (group[ch] < g) { group[ch] = j; P[j] = ((uint32_t)ch << 24) | index[ch]; }
            else { P[j] = ((uint32_t)ch << 24) | 0x800000 | (uint32_t)(j - group[ch]); P[group[ch]]++; }
            index[ch]++;
        }
        for (int32_t p = start, j = n - 1; j >= 0; --j)
        {
            uint32_t u = P[p];
            if (u & 0x800000)
            {
                p = p - (int32_t)(u & 0x7fffff);
                if (p < 0) return -1;
                u = P[p];
            }
            uint8_t ch = (uint8_t)(u >> 24);
            T[j] = ch; P[p]--; p = (int32_t)(u & 0x7fffff) + (int32_t)count[ch];
            if (p >= n) return -1;
        }
    }
    else
    {
        /* case 3: a symbol with 2^23 occurrences or more */
        enum { FASTBITS = 10 };
        uint8_t fastbits[1 << FASTBITS];
        parc_bwt_memcpy(index, count, sizeof(index));
        for (c = 0; c < ST_ALPHABET; ++c) group[c] = -1;
        for (int32_t g = 0, j = 0; j < n; ++j)
        {
            if (P[j] > 0) g = j;
            uint8_t ch = T[j];
            if (group[ch] < g) { group[ch] = j; P[j] = index[ch]; }
            else { P[j] = 0x80000000u | (uint32_t)group[ch]; P[group[ch]]++; }
            index[ch]++;
        }
        int shift = 0; while (((n - 1) >> shift) >= (1 << FASTBITS)) shift++;
        for (int32_t v = 0, cc = 0; cc < ST_ALPHABET; ++cc)
        {
            index[cc] = (cc + 1 < ST_ALPHABET) ? count[cc + 1] : (uint32_t)n;
            if (count[cc] != index[cc])
                for (; v <= (int32_t)((index[cc] - 1) >> shift); ++v) fastbits[v] = (uint8_t)cc;
        }
        if (P[start] & 0x80000000u)
        {
            start = (int32_t)(P[start] & 0x7fffffff);
            if (start >= n) return -1;
        }
        {
            int32_t s = fastbits[start >> shift];
            while (index[s] <= (uint32_t)start) { if (++s >= ST_ALPHABET) return -1; }
            T[0] = (uint8_t)s;
        }
        P[start]--; start = (int32_t)P[start] + 1;
        if (start < 0 || start >= n) return -1;
        for (int32_t p = start, j = n - 1; j >= 1; --j)
        {
            uint32_t u = P[p];
            if (u & 0x80000000u)
            {
                p = (int32_t)(u & 0x7fffffff);
                if (p >= n) return -1;
                u = P[p];
            }
            int32_t s = fastbits[p >> shift];
            while (index[s] <= (uint32_t)p) { if (++s >= ST_ALPHABET) return -1; }
            T[j] = (uint8_t)s;
            P[p]--; p = (int32_t)u;
            if (p < 0 || p >= n) return -1;
        }
    }
    return 0;
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
