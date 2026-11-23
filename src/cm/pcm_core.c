/* pcm_core.c - PArc context-mixing compressor (method "cm"), native core.
 *
 * Copyright (c) 2026 PArc authors. MIT License (see LICENSE in this folder).
 *
 * Written from scratch for PArc from published ideas (bitwise context mixing:
 * hashed bit-history contexts, adaptive state maps, a gated linear mixer in the
 * logistic domain, secondary estimation; see Mahoney, "Data Compression
 * Explained", and the PAQ/ZPAQ literature).  No code from lpaq/paq/FreeArc.
 *
 * Freestanding C: no libc.  The caller (src/parc_cm.pas) provides one zeroed
 * memory arena of pcm_memsize() bytes and two I/O callbacks.  All arithmetic
 * is integer and exactly specified, so every platform produces the same bytes.
 * The stream format is described in docs/formato/FORMATO-PARC.md (section "cm").
 */
#include <stdint.h>
#include <stddef.h>

#if defined(__SSE2__) && !defined(PCM_NO_SIMD)
#include <emmintrin.h>
#define PCM_SSE2 1
#endif

typedef uint8_t U8;
typedef uint16_t U16;
typedef uint32_t U32;
typedef int32_t I32;
typedef int16_t I16;
typedef uint64_t U64;
typedef int64_t I64;

/* I/O callback: encoder writes n bytes (returns n); decoder reads up to n bytes
 * (returns 0 at end of input). */
typedef U32 (*pcm_io_fn)(void *ctx, U8 *buf, U32 n);

#define PCM_BLK 65536u        /* bytes per block (raw / modelled decision) */
#define NCD 2                 /* direct contexts: order 0, order 1 */
#define NCH 7                 /* hashed contexts */
#define NC (NCD + NCH)
#define NI 24                 /* mixer inputs (multiple of 8) */
#define NM 4                  /* first layer mixers */
#define NSETS (256 + 48 + 48 + 256)
#define IOBUF 65536u

/* tuning parameters (constants in the product build) */
#define PCM_TDEF {8, 2, 1023, 5, 2, 1, 1024, 6, 0, 2, 0, 0, 0, 0, 0, 3, 0, 0, 3, 0}
#ifdef PCM_TUNE
int pcm_T[24] = PCM_TDEF;
#else
static const int pcm_T[24] = PCM_TDEF;
#endif
#define P(i) pcm_T[i]

/* ------------------------------------------------------------------------ */

typedef struct {
  /* configuration (from the stream header) */
  U32 htbits;                 /* hash table: 1<<htbits buckets of 64 bytes */
  U32 wbits;                  /* history ring: 1<<wbits bytes */
  U32 mtbits;                 /* match table: 1<<mtbits entries */
  /* constant tables */
  I16 st[4096];               /* stretch: 12-bit p -> logistic domain (+-2047) */
  I16 sq[4096];               /* squash: x+2048 -> 12-bit p */
  U8 nex[256][2];             /* bit-history state transitions */
  U8 pri[256];                /* state confidence (replacement priority) */
  I32 rec[1024];              /* 65536/(n+1.5) */
  U32 smi0[256];              /* initial state-map values */
  /* arena pointers */
  U8 *ht, *buf, *o1, *o2s;
  U32 *mt;
  U32 *sm;                    /* NC*256 state maps + 64 match map */
  I16 *w1, *w2;
  U16 *a1, *a2, *a3;
  U8 *iob;
  /* model state */
  U32 c0, bpos, c4, c8, pos, nib;
  U32 wh, wh1;                /* word hashes */
  U32 hh[NCH];                /* context hashes at byte boundary */
  U8 *slot[NCH];
  U8 o0[256];
  U8 *sp[NC];
  U32 smx[NC];
  U32 mlen, mptr, mbyte, mctx, msmx;
  I16 x[NI];
  I16 x2[8];
  I32 st1[NM];
  I32 p1[NM];
  U32 sel[NM];
  U32 sel2;
  I32 pm, pr;
  U32 ai1, ai2, ai3, aw1, aw2, aw3;
  I32 lr1, lr2;
  /* coder */
  U32 rlo, rhi, xv;
  U32 iop, ion, eof;
  pcm_io_fn io;
  void *ioctx;
  U32 flagp;                  /* probability of "block is modelled" */
} pcm_t;

/* ------------------------------------------------------------------------ */
/* tables */

static const short sq33[33] = {1, 2, 4, 6, 10, 17, 27, 45, 74, 120, 194, 311, 488,
  747, 1102, 1546, 2048, 2550, 2994, 3349, 3608, 3785, 3902, 3976, 4022, 4051,
  4069, 4079, 4086, 4090, 4092, 4094, 4095};

/* bit-history states: (n0, n1, last bit) with bounded counts */
static const U8 bound_tabs[5][9] = {
  {40, 30, 20, 12, 9, 7, 7, 0, 7},
  {30, 24, 16, 12, 9, 7, 7, 0, 10},
  {40, 30, 20, 12, 9, 7, 7, 7, 9},
  {50, 30, 20, 12, 9, 7, 7, 0, 6},
  {24, 18, 14, 11, 9, 7, 7, 0, 12}};
#define bound_tab bound_tabs[P(18)]

static int st_ok(int a, int b) {
  int lo = a < b ? a : b, hi = a < b ? b : a;
  if (lo > 7) return 0;
  return hi <= bound_tab[lo];
}

static int st_haslb(int a, int b) { return a > 0 && b > 0 && a + b <= bound_tab[8]; }

static void build_states(pcm_t *m, U8 *sa, U8 *sb, U8 *sl, int *ns) {
  int n = 0, t, a, l;
  /* enumerate in order of total, then n0, then last bit */
  for (t = 0; t <= 80; t++)
    for (a = 0; a <= t; a++) {
      int b = t - a;
      if (!st_ok(a, b)) continue;
      for (l = 0; l <= (st_haslb(a, b) ? 1 : 0); l++) {
        sa[n] = (U8)a; sb[n] = (U8)b; sl[n] = (U8)l; n++;
      }
    }
  *ns = n;
  {
    int s, y, k;
    for (s = 0; s < n; s++) {
      m->pri[s] = (U8)(sa[s] + sb[s] > 255 ? 255 : sa[s] + sb[s]);
      for (y = 0; y < 2; y++) {
        int c[2], lb;
        c[0] = sa[s]; c[1] = sb[s];
        c[y]++;
        if (P(9) == 0) { if (c[1 - y] >= 3) c[1 - y] = c[1 - y] / 2 + 1; }
        else if (P(9) == 1) { int o = c[1 - y]; if (o >= 3) { int r = 1; while ((1 << r) <= o) r++; c[1 - y] = r; } }
        else if (P(9) == 2) { if (c[1 - y] >= 2) c[1 - y] = (c[1 - y] + 1) / 2; }
        else { if (c[1 - y] >= 4) c[1 - y] = c[1 - y] / 3 + 2; }
        while (!st_ok(c[0], c[1])) {
          if (c[1 - y] > 0) c[1 - y]--; else c[y]--;
        }
        lb = st_haslb(c[0], c[1]) ? y : 0;
        for (k = 0; k < n; k++)
          if (sa[k] == c[0] && sb[k] == c[1] && sl[k] == lb) break;
        m->nex[s][y] = (U8)k;
      }
    }
    for (s = n; s < 256; s++) { m->nex[s][0] = m->nex[s][1] = 0; m->pri[s] = 0; }
  }
}

static void init_tables(pcm_t *m) {
  int i, x;
  U8 sa[256], sb[256], sl[256];
  int ns;
  for (i = 0; i < 4096; i++) {
    int xx = i - 2048, j = (xx + 2048) >> 7, w = (xx + 2048) & 127;
    int v = j >= 32 ? 4095 : (sq33[j] * (128 - w) + sq33[j + 1] * w + 64) >> 7;
    if (v < 1) v = 1;
    if (v > 4095) v = 4095;
    m->sq[i] = (I16)v;
  }
  {
    int pi = 0;
    for (x = -2047; x <= 2047; x++) {
      int v = m->sq[x + 2048];
      for (i = pi; i <= v; i++) m->st[i] = (I16)x;
      pi = v + 1;
    }
    for (i = pi; i < 4096; i++) m->st[i] = 2047;
  }
  for (i = 0; i < 1024; i++) m->rec[i] = (I32)(131072 / (2 * i + 3));
  build_states(m, sa, sb, sl, &ns);
  for (i = 0; i < 256; i++) {
    U32 p;
    if (i < ns) p = (U32)(((U64)(2 * sb[i] + 1) << 22) / (U32)(2 * (sa[i] + sb[i]) + 2));
    else p = 1u << 21;
    if (p > (1u << 22) - 1) p = (1u << 22) - 1;
    m->smi0[i] = p << 10;
  }
}

/* ------------------------------------------------------------------------ */
/* arena layout */

typedef struct { size_t ht, buf, o1, o2s, mt, sm, w1, w2, a1, a2, a3, iob, total; } layout_t;

#define A2N 65536u
#define A3N 65536u

static void layout(U32 htbits, U32 wbits, U32 mtbits, layout_t *L) {
  size_t o = (sizeof(pcm_t) + 63) & ~(size_t)63;
  L->ht = o;  o += (size_t)64 << htbits;
  L->buf = o; o += (size_t)1 << wbits;
  L->o1 = o;  o += 65536;
  L->o2s = o;  o += 65536;
  L->mt = o;  o += (size_t)4 << mtbits;
  L->sm = o;  o += 4 * (NC * 256 + 64);
  L->w1 = o;  o += 2 * NSETS * NI;
  L->w2 = o;  o += 2 * 256 * 8;
  L->a1 = o;  o += 2 * 256 * 33;
  L->a2 = o;  o += 2 * (size_t)A2N * 33;
  L->a3 = o;  o += 2 * (size_t)A3N * 33;
  o = (o + 63) & ~(size_t)63;
  L->iob = o; o += IOBUF;
  L->total = o + 64;
}

/* level -> sizes; the encoder may shrink them for small inputs */
static void level_sizes(int level, U32 *htb, U32 *wb, U32 *mtb) {
  if (level < 1) level = 1;
  if (level > 9) level = 9;
  *htb = 15 + level;          /* level 6: 2M buckets = 128 MB */
  *wb = 18 + level;           /* level 6: 16 MB */
  *mtb = 16 + level;          /* level 6: 4M entries = 16 MB */
}

size_t pcm_memsize(U32 htbits, U32 wbits, U32 mtbits) {
  layout_t L;
  layout(htbits, wbits, mtbits, &L);
  return L.total;
}

void pcm_level_sizes(int level, U32 *htb, U32 *wb, U32 *mtb) { level_sizes(level, htb, wb, mtb); }

/* ------------------------------------------------------------------------ */
/* helpers */

static inline U32 hash3(U32 a, U32 b, U32 c) {
  U32 h = a * 0x9E3779B1u ^ b * 0x85EBCA77u ^ c * 0xC2B2AE3Du;
  h ^= h >> 15;
  h *= 0x27D4EB2Fu;
  h ^= h >> 13;
  return h;
}

static inline U8 *ht_bucket(pcm_t *m, U32 h) {
  return m->ht + ((size_t)((h >> 8) & ((1u << m->htbits) - 1)) << 6);
}

static inline U8 *ht_find(pcm_t *m, U32 h) {
  U8 *b = ht_bucket(m, h);
  U8 chk = (U8)h;
  U8 *best;
  int bp, k;
  if (b[0] == chk) return b;
  if (b[16] == chk) return b + 16;
  if (b[32] == chk) return b + 32;
  if (b[48] == chk) return b + 48;
  best = b; bp = m->pri[b[1]];
  for (k = 1; k < 4; k++) {
    int p = m->pri[b[k * 16 + 1]];
    if (p < bp) { bp = p; best = b + k * 16; }
  }
  for (k = 0; k < 16; k++) best[k] = 0;
  best[0] = chk;
  return best;
}

static inline I32 squash(pcm_t *m, I32 x) {
  if (x > 2047) x = 2047;
  if (x < -2047) x = -2047;
  return m->sq[x + 2048];
}

static inline I32 dot16(const I16 *x, const I16 *w, int n) {
#ifdef PCM_SSE2
  __m128i s = _mm_setzero_si128();
  int i;
  for (i = 0; i < n; i += 8)
    s = _mm_add_epi32(s, _mm_madd_epi16(_mm_loadu_si128((const __m128i *)(x + i)),
                                        _mm_loadu_si128((const __m128i *)(w + i))));
  s = _mm_add_epi32(s, _mm_srli_si128(s, 8));
  s = _mm_add_epi32(s, _mm_srli_si128(s, 4));
  return _mm_cvtsi128_si32(s);
#else
  I32 s = 0;
  int i;
  for (i = 0; i < n; i++) s += (I32)x[i] * w[i];
  return s;
#endif
}

/* w += round((x*e) >> 14), saturated to int16 */
static inline void train16(const I16 *x, I16 *w, int n, I32 e) {
#ifdef PCM_SSE2
  __m128i ev = _mm_set1_epi16((short)e), one = _mm_set1_epi16(1);
  int i;
  for (i = 0; i < n; i += 8) {
    __m128i xv = _mm_loadu_si128((const __m128i *)(x + i));
    __m128i t = _mm_mulhi_epi16(_mm_slli_epi16(xv, 3), ev);
    t = _mm_srai_epi16(_mm_add_epi16(t, one), 1);
    _mm_storeu_si128((__m128i *)(w + i), _mm_adds_epi16(_mm_loadu_si128((const __m128i *)(w + i)), t));
  }
#else
  int i;
  for (i = 0; i < n; i++) {
    I32 t = ((I32)(x[i] * 8) * e) >> 16;
    I32 v;
    t = (I16)(t + 1) >> 1;
    v = w[i] + t;
    if (v > 32767) v = 32767;
    if (v < -32768) v = -32768;
    w[i] = (I16)v;
  }
#endif
}

static inline I32 apm_p(pcm_t *m, U16 *t, I32 pr, U32 ctx, U32 *ix, U32 *iw) {
  I32 s = m->st[pr] + 2048;
  U32 lo = (U32)s >> 7, w = (U32)s & 127;
  U32 i = ctx * 33 + lo;
  *ix = i; *iw = w;
  return (I32)((t[i] * (128 - w) + t[i + 1] * w) >> 11);
}

static inline void apm_u(U16 *t, U32 i, U32 w, int y, int rate) {
  I32 g = y ? 65535 : 0;
  I32 a = t[i], b = t[i + 1];
  a += (((g - a) >> rate) * (I32)(128 - w)) >> 7;
  b += (((g - b) >> rate) * (I32)w) >> 7;
  t[i] = (U16)a; t[i + 1] = (U16)b;
}

static inline void sm_update(pcm_t *m, U32 *t, int y, int limit) {
  U32 v = *t;
  U32 n = v & 1023;
  I32 p = (I32)(v >> 10);
  I32 target = y ? (1 << 22) - 1 : 0;
  p += (I32)(((I64)(target - p) * m->rec[n]) >> 16);
  if ((I32)n < limit) n++;
  *t = ((U32)p << 10) | n;
}

/* ------------------------------------------------------------------------ */
/* model */

static void model_init(pcm_t *m) {
  int i, j;
  init_tables(m);
  for (i = 0; i < NC * 256 + 64; i++) m->sm[i] = m->smi0[i & 255];
  for (i = NC * 256; i < NC * 256 + 64; i++) m->sm[i] = (1u << 31);
  for (i = 0; i < NSETS; i++)
    for (j = 0; j < NI; j++) m->w1[i * NI + j] = (I16)(j < 2 * NC + 2 && (j & 1) == 0 ? P(6) : 0);
  for (i = 0; i < 256; i++)
    for (j = 0; j < 8; j++) m->w2[i * 8 + j] = (I16)(j < NM ? 4096 / NM : 0);
  for (i = 0; i < 256 * 33; i++) m->a1[i] = (U16)(m->sq[((i % 33) - 16) * 128 + 2048 > 4095 ? 4095 : ((i % 33) - 16) * 128 + 2048] * 16);
  for (i = 0; i < (int)(A2N * 33); i++) m->a2[i] = m->a1[i % 33];
  for (i = 0; i < (int)(A3N * 33); i++) m->a3[i] = m->a1[i % 33];
  m->c0 = 1; m->bpos = 0; m->nib = 1;
  m->lr1 = P(14) ? P(14) : P(0); m->lr2 = P(1);
  m->x[NI - 1] = 256;
  m->x2[NM] = 256;
  for (i = 0; i < NCH; i++) m->slot[i] = ht_find(m, hash3(i + 1, 0, 0));
  m->flagp = 1u << 15;
}

static inline int predict(pcm_t *m) {
  I16 *x = m->x;
  U32 c0 = m->c0, nib = m->nib;
  int i, ord = 0;
  I32 pm, p;
  /* direct contexts */
  {
    U8 *sp = P(16) ? m->o2s + (((m->c4 >> 8) & 255) << 8) + c0 : m->o0 + c0;
    U32 s = *sp, k = s;
    U32 v = m->sm[k] >> 20;
    m->sp[0] = sp; m->smx[0] = k;
    x[0] = m->st[v]; x[1] = (I16)(P(4) ? ((I32)v - 2048) >> P(4) : 0);
    sp = m->o1 + ((m->c4 & 255) << 8) + c0;
    s = *sp; k = 256 + s; v = m->sm[k] >> 20;
    m->sp[1] = sp; m->smx[1] = k;
    x[2] = m->st[v]; x[3] = (I16)(P(4) ? ((I32)v - 2048) >> P(4) : 0);
  }
  for (i = 0; i < NCH; i++) {
    U8 *sp = m->slot[i] + nib;
    U32 s = *sp, k = (U32)(i + NCD) * 256 + s;
    U32 v = m->sm[k] >> 20;
    m->sp[i + NCD] = sp; m->smx[i + NCD] = k;
    if (P(8) && s == 0) { x[2 * (i + NCD)] = 0; x[2 * (i + NCD) + 1] = 0; }
    else {
    x[2 * (i + NCD)] = m->st[v];
    x[2 * (i + NCD) + 1] = (I16)(P(4) ? ((I32)v - 2048) >> P(4) : 0);
    }
    if (i < 4 && s) ord++;
  }
  /* match model */
  if (m->mlen) {
    U32 eb = m->mbyte | 256;
    if ((eb >> (8 - m->bpos)) == c0) {
      U32 bit = (eb >> (7 - m->bpos)) & 1, l = m->mlen, lb;
      U32 v;
      lb = l < 16 ? l : (l < 32 ? 16 : (l < 64 ? 17 : (l < 128 ? 18 : (l < 256 ? 19 : 20))));
      m->mctx = lb * 2 + bit;
      m->msmx = NC * 256 + m->mctx;
      v = m->sm[m->msmx] >> 20;
      x[2 * NC] = m->st[v];
      x[2 * NC + 1] = (I16)(bit ? (lb << 6) : -(I32)(lb << 6));
    } else {
      m->mlen = 0; m->mctx = 0;
      x[2 * NC] = 0; x[2 * NC + 1] = 0;
    }
  } else {
    m->mctx = 0;
    x[2 * NC] = 0; x[2 * NC + 1] = 0;
  }
  /* mixer layer 1 */
  m->sel[0] = c0;
  m->sel[1] = 256 + m->mctx;
  m->sel[2] = 256 + 48 + ord * 8 + m->bpos;
  switch (P(5)) {
    case 1: m->sel[3] = 256 + 48 + 48 + ((m->c4 >> 8) & 255); break;
    case 2: m->sel[3] = 256 + 48 + 48 + (((m->c4 >> 4) & 15) << 3 | m->bpos) * 2; if (m->sel[3] >= NSETS) m->sel[3] = NSETS - 1; break;
    case 3: m->sel[3] = 256 + 48 + 48 + ((m->c4 * 0x9E3779B1u) >> 24); break;
    default: m->sel[3] = 256 + 48 + 48 + (m->c4 & 255);
  }
  for (i = 0; i < NM; i++) {
    I32 d;
    if (P(19) && i >= P(19)) { m->x2[i] = 0; m->p1[i] = 2048; continue; }
    d = dot16(x, m->w1 + m->sel[i] * NI, NI) >> 12;
    if (d > 2047) d = 2047;
    if (d < -2047) d = -2047;
    m->st1[i] = d;
    m->p1[i] = m->sq[d + 2048];
    m->x2[i] = (I16)d;
  }
  m->sel2 = c0;
  {
    I32 d = dot16(m->x2, m->w2 + m->sel2 * 8, 8) >> 12;
    pm = squash(m, d);
  }
  m->pm = pm;
  /* secondary estimation */
  {
    I32 q1 = apm_p(m, m->a1, pm, c0, &m->ai1, &m->aw1);
    U32 c2x = P(17) ? (c0 | ((hash3(m->c4 & 0xffff, 3, 0) >> 24) << 8)) : (c0 | ((m->c4 & 255) << 8));
    I32 q2 = apm_p(m, m->a2, pm, c2x & (A2N - 1), &m->ai2, &m->aw2);
    U32 c3 = m->mlen ? (m->mbyte << 8 | c0) ^ ((m->mlen < 16 ? m->mlen : 15) << 12)
                     : (hash3(m->c4 & 0xffff, 7, 0) & 0xff00) | c0;
    I32 q3 = apm_p(m, m->a3, pm, c3 & (A3N - 1), &m->ai3, &m->aw3);
    switch (P(15)) {
      case 1: p = (pm + q1 + q2 + q3 + 2) >> 2; break;
      case 2: p = (q1 + 2 * q2 + q3 + 2) >> 2; break;
      case 3: p = (pm + 3 * q2 + 2 * q3 + 3) / 6; break;
      case 4: p = (pm + q1 + 4 * q2 + 2 * q3 + 4) >> 3; break;
      default: p = (2 * pm + q1 + 3 * q2 + 2 * q3 + 4) >> 3;
    }
  }
  if (p < 1) p = 1;
  if (p > 4095) p = 4095;
  m->pr = p;
  return p;
}

static inline void update_byte(pcm_t *m);

static inline void update(pcm_t *m, int y) {
  int i;
  /* contexts */
  {
    U32 *sm = m->sm;
    const I32 *rec = m->rec;
    U8 *spl[NC];
    U8 ns[NC];
    I32 target = y ? (1 << 22) - 1 : 0;
    for (i = 0; i < NC; i++) {
      U32 *t = sm + m->smx[i];
      U32 v = *t, n = v & 1023;
      I32 pp = (I32)(v >> 10);
      pp += (I32)(((I64)(target - pp) * rec[n]) >> 16);
      if ((I32)n < P(2)) n++;
      *t = ((U32)pp << 10) | n;
      spl[i] = m->sp[i];
      ns[i] = m->nex[*spl[i]][y];
    }
    if (m->mctx) sm_update(m, sm + m->msmx, y, P(2));
    for (i = 0; i < NC; i++) *spl[i] = ns[i];
  }
  /* mixers */
  for (i = 0; i < (P(19) ? P(19) : NM); i++) {
    I32 e = (((y << 12) - m->p1[i]) * m->lr1) >> 4;
    train16(m->x, m->w1 + m->sel[i] * NI, NI, e);
  }
  {
    I32 e = (((y << 12) - m->pm) * m->lr2) >> 4;
    train16(m->x2, m->w2 + m->sel2 * 8, 8, e);
  }
  apm_u(m->a1, m->ai1, m->aw1, y, P(3));
  apm_u(m->a2, m->ai2, m->aw2, y, P(3));
  apm_u(m->a3, m->ai3, m->aw3, y, P(3));
  /* bit state */
  m->c0 = (m->c0 << 1) | (U32)y;
  m->bpos++;
  if (m->bpos == 8) {
    update_byte(m);
  } else if (m->bpos == 4) {
    U32 h = m->c0 * 0x6F4F2A35u;
    for (i = 0; i < NCH; i++) m->slot[i] = ht_find(m, m->hh[i] + h);
    m->nib = 1;
  } else {
    m->nib = (m->nib << 1) | (U32)y;
    if (P(12) && m->bpos == 3) {
      U32 h0 = (m->c0 << 1) * 0x6F4F2A35u, h1 = ((m->c0 << 1) | 1) * 0x6F4F2A35u;
      for (i = 0; i < NCH; i++) {
        __builtin_prefetch(ht_bucket(m, m->hh[i] + h0));
        __builtin_prefetch(ht_bucket(m, m->hh[i] + h1));
      }
    }
  }
}

static inline int is_word(U32 c) {
  if (P(13) == 1) return (c - 'a' < 26u) || (c - 'A' < 26u) || (c - '0' < 10u) || c >= 128 || c < 32;
  if (P(13) == 2) return c != 32 && c != 10 && c != ',' && c != '.';
  return (c - 'a' < 26u) || (c - 'A' < 26u) || c >= 128;
}

static inline void update_byte(pcm_t *m) {
  U32 c = m->c0 & 255;
  U32 wmask = (1u << m->wbits) - 1;
  int i;
  m->buf[m->pos & wmask] = (U8)c;
  m->pos++;
  m->c8 = (m->c8 << 8) | (m->c4 >> 24);
  m->c4 = (m->c4 << 8) | c;
  m->c0 = 1; m->bpos = 0; m->nib = 1;
  /* word */
  if (is_word(c)) {
    U32 lc = (c - 'A' < 26u) ? c + 32 : c;
    m->wh = (m->wh + lc + 1) * 0x2F0B4C27u;
  } else if (m->wh) {
    m->wh1 = m->wh;
    m->wh = 0;
  }
  /* match model */
  {
    U32 mh = hash3(m->c4, m->c8 & 0xffff, 99) >> (32 - m->mtbits);
    if (m->mlen) {
      if (m->mbyte == c) {
        if (m->mlen < 65535) m->mlen++;
        m->mptr++;
      } else m->mlen = 0;
    }
    if (m->mlen == 0 && m->pos >= 8) {
      U32 cand = m->mt[mh];
      if (cand && m->pos - cand < wmask - 64) {
        U32 l = 0;
        while (l < 32 && l < cand && m->buf[(cand - 1 - l) & wmask] == m->buf[(m->pos - 1 - l) & wmask]) l++;
        if (l >= (U32)P(7)) { m->mlen = l; m->mptr = cand; }
      }
    }
    m->mt[mh] = m->pos;
    if (m->mlen) m->mbyte = m->buf[m->mptr & wmask];
  }
  /* contexts */
  {
    U32 c4 = m->c4, c8 = m->c8;
    m->hh[0] = hash3(1, c4 & 0xffff, 0);
    m->hh[1] = hash3(2, c4 & 0xffffff, 0);
    m->hh[2] = hash3(3, c4, 0);
    m->hh[3] = hash3(4, c4, c8 & 0xffff);
    m->hh[4] = hash3(5, m->wh, m->wh ? 0 : (c & 255) + 1);
    switch (P(10)) {
      case 1: m->hh[5] = hash3(6, c4, c8 & 0xff); break;
      case 2: m->hh[5] = hash3(6, c4, c8 & 0xffffff); break;
      case 3: m->hh[5] = hash3(6, m->wh, c4 & 0xff00); break;
      default: m->hh[5] = hash3(6, c4 & 0xffff00, 0);
    }
    switch (P(11)) {
      case 1: m->hh[6] = hash3(7, c4, c8); break;
      case 2: m->hh[6] = hash3(7, c4, c8 & 0xff); break;
      default: m->hh[6] = hash3(7, m->wh, m->wh1);
    }
    for (i = 0; i < NCH; i++) __builtin_prefetch(ht_bucket(m, m->hh[i]));
    for (i = 0; i < NCH; i++) m->slot[i] = ht_find(m, m->hh[i]);
  }
}

/* ------------------------------------------------------------------------ */
/* arithmetic coder (32-bit, carry-less) */

static inline void io_put(pcm_t *m, U8 c) {
  m->iob[m->iop++] = c;
  if (m->iop == IOBUF) { m->io(m->ioctx, m->iob, m->iop); m->iop = 0; }
}

static inline U32 io_get(pcm_t *m) {
  if (m->iop == m->ion) {
    m->ion = m->io(m->ioctx, m->iob, IOBUF);
    m->iop = 0;
    if (m->ion == 0) { m->eof++; return 0; }
  }
  return m->iob[m->iop++];
}

static inline void enc_bit(pcm_t *m, int y, U32 p16) {
  U32 xm = m->rlo + (U32)(((U64)(m->rhi - m->rlo) * p16) >> 16);
  if (y) m->rhi = xm; else m->rlo = xm + 1;
  while (((m->rlo ^ m->rhi) & 0xff000000u) == 0) {
    io_put(m, (U8)(m->rhi >> 24));
    m->rlo <<= 8;
    m->rhi = (m->rhi << 8) | 255;
  }
}

static inline int dec_bit(pcm_t *m, U32 p16) {
  U32 xm = m->rlo + (U32)(((U64)(m->rhi - m->rlo) * p16) >> 16);
  int y = m->xv <= xm;
  if (y) m->rhi = xm; else m->rlo = xm + 1;
  while (((m->rlo ^ m->rhi) & 0xff000000u) == 0) {
    m->rlo <<= 8;
    m->rhi = (m->rhi << 8) | 255;
    m->xv = (m->xv << 8) | io_get(m);
  }
  return y;
}

static inline U32 p12to16(I32 p) { return (U32)p << 4; }

/* ------------------------------------------------------------------------ */
/* block classification: order-0 entropy (bits*256 per byte) */

static U32 ilog2_8(U32 x) {      /* log2(x) * 256, x >= 1 */
  U32 r = 0, k, f;
  while (x >= 2) { x >>= 1; r += 256; }
  (void)k; (void)f;
  return r;
}

static U32 flog2(U32 x) {        /* log2(x) * 256 with 8 fractional bits, x >= 1 */
  U32 r = 0, i;
  U64 v;
  if (x == 0) return 0;
  while (x >= (2u << 16)) { x >>= 1; r += 256; }
  while (x < (1u << 16)) { x <<= 1; r -= 256; }
  r += 16 * 256;
  v = x;                          /* 1.0 = 1<<16 */
  for (i = 128; i; i >>= 1) {
    v = (v * v) >> 16;
    if (v >= (2u << 16)) { v >>= 1; r += i; }
  }
  return r;
}

static U32 entropy0(const U8 *p, U32 n) {
  U32 cnt[256], i;
  U64 s = 0;
  for (i = 0; i < 256; i++) cnt[i] = 0;
  for (i = 0; i < n; i++) cnt[p[i]]++;
  for (i = 0; i < 256; i++)
    if (cnt[i]) s += (U64)cnt[i] * (flog2(n) - flog2(cnt[i]));
  (void)ilog2_8;
  return n ? (U32)(s / n) : 0;
}

/* ------------------------------------------------------------------------ */
/* public API */

#define PCM_ERR_PARAM -1
#define PCM_ERR_DATA -2

/* mem: zeroed arena of pcm_memsize(...) bytes, 64-byte aligned */
int pcm_open(void *mem, U32 htbits, U32 wbits, U32 mtbits, pcm_io_fn io, void *ctx, int decoding) {
  pcm_t *m = (pcm_t *)mem;
  layout_t L;
  U8 *base = (U8 *)mem;
  if (htbits < 10 || htbits > 24 || wbits < 16 || wbits > 27 || mtbits < 12 || mtbits > 25) return PCM_ERR_PARAM;
  layout(htbits, wbits, mtbits, &L);
  m->htbits = htbits; m->wbits = wbits; m->mtbits = mtbits;
  m->ht = base + L.ht; m->buf = base + L.buf; m->o1 = base + L.o1; m->o2s = base + L.o2s;
  m->mt = (U32 *)(base + L.mt); m->sm = (U32 *)(base + L.sm);
  m->w1 = (I16 *)(base + L.w1); m->w2 = (I16 *)(base + L.w2);
  m->a1 = (U16 *)(base + L.a1); m->a2 = (U16 *)(base + L.a2); m->a3 = (U16 *)(base + L.a3);
  m->iob = base + L.iob;
  m->io = io; m->ioctx = ctx;
  model_init(m);
  m->rlo = 0; m->rhi = 0xffffffffu; m->iop = 0; m->ion = 0; m->eof = 0;
  if (decoding) {
    int i;
    for (i = 0; i < 4; i++) m->xv = (m->xv << 8) | io_get(m);
  }
  return 0;
}

static inline void enc_flagbit(pcm_t *m, int y) {
  enc_bit(m, y, m->flagp);
  if (y) m->flagp += (65536 - m->flagp) >> 4; else m->flagp -= m->flagp >> 4;
  if (m->flagp < 64) m->flagp = 64;
  if (m->flagp > 65472) m->flagp = 65472;
}

static inline int dec_flagbit(pcm_t *m) {
  int y = dec_bit(m, m->flagp);
  if (y) m->flagp += (65536 - m->flagp) >> 4; else m->flagp -= m->flagp >> 4;
  if (m->flagp < 64) m->flagp = 64;
  if (m->flagp > 65472) m->flagp = 65472;
  return y;
}

/* raw bytes still enter the history so the contexts and match model see them */
static inline void raw_byte(pcm_t *m, U32 c) {
  U32 wmask = (1u << m->wbits) - 1;
  m->buf[m->pos & wmask] = (U8)c;
  m->pos++;
  m->c8 = (m->c8 << 8) | (m->c4 >> 24);
  m->c4 = (m->c4 << 8) | c;
}

static void raw_end(pcm_t *m) {
  /* re-derive the byte-boundary contexts after a raw block */
  m->c0 = 1; m->bpos = 0; m->nib = 1; m->mlen = 0; m->wh = 0;
  m->pos--;
  m->c0 = 256 | (m->c4 & 255);
  m->c4 >>= 8; m->c4 |= (m->c8 & 255) << 24; m->c8 >>= 8;
  update_byte(m);
}

/* thresholds: order-0 entropy (bits*256) above which a block is stored */
#define RAW_H0 (U32)(7.92 * 256)

/* encode one block of n (1..PCM_BLK) bytes */
void pcm_enc_block(void *mem, const U8 *src, U32 n) {
  pcm_t *m = (pcm_t *)mem;
  U32 i, j;
  int modelled = 1;
  if (n >= 4096 && entropy0(src, n) > RAW_H0) modelled = 0;
  enc_bit(m, 0, 32768);                       /* not end */
  enc_flagbit(m, modelled);
  if (n == PCM_BLK) enc_bit(m, 1, 32768);
  else {
    enc_bit(m, 0, 32768);
    for (j = 16; j-- > 0;) enc_bit(m, (n >> j) & 1, 32768);
  }
  if (P(14) && m->lr1 > P(0)) m->lr1--;
  if (modelled) {
    for (i = 0; i < n; i++) {
      U32 c = src[i];
      for (j = 8; j-- > 0;) {
        int y = (c >> j) & 1;
        enc_bit(m, y, p12to16(predict(m)));
        update(m, y);
      }
    }
  } else {
    for (i = 0; i < n; i++) {
      U32 c = src[i];
      for (j = 8; j-- > 0;) enc_bit(m, (c >> j) & 1, 32768);
      raw_byte(m, c);
    }
    raw_end(m);
  }
}

void pcm_enc_end(void *mem) {
  pcm_t *m = (pcm_t *)mem;
  int i;
  enc_bit(m, 1, 32768);
  for (i = 0; i < 4; i++) { io_put(m, (U8)(m->rlo >> 24)); m->rlo <<= 8; }
  if (m->iop) m->io(m->ioctx, m->iob, m->iop);
  m->iop = 0;
}

/* decode the next block into dst (PCM_BLK bytes of room); returns its length,
 * 0 at the end of the stream, or a negative error */
int pcm_dec_block(void *mem, U8 *dst) {
  pcm_t *m = (pcm_t *)mem;
  U32 i, j, n;
  int modelled;
  if (dec_bit(m, 32768)) return 0;
  modelled = dec_flagbit(m);
  if (dec_bit(m, 32768)) n = PCM_BLK;
  else {
    n = 0;
    for (j = 0; j < 16; j++) n = (n << 1) | (U32)dec_bit(m, 32768);
    if (n == 0) return PCM_ERR_DATA;
  }
  if (P(14) && m->lr1 > P(0)) m->lr1--;
  if (modelled) {
    for (i = 0; i < n; i++) {
      for (j = 0; j < 8; j++) {
        int y = dec_bit(m, p12to16(predict(m)));
        update(m, y);
      }
      dst[i] = (U8)m->c4;
      if (m->eof > 8) return PCM_ERR_DATA;
    }
  } else {
    for (i = 0; i < n; i++) {
      U32 c = 0;
      for (j = 0; j < 8; j++) c = (c << 1) | (U32)dec_bit(m, 32768);
      dst[i] = (U8)c;
      raw_byte(m, c);
      if (m->eof > 8) return PCM_ERR_DATA;
    }
    raw_end(m);
  }
  return (int)n;
}
