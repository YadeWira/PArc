/* tta_core.c - core of PArc's lossless audio codec (method `tta`).
   MIT license, part of PArc; nothing from FreeArc or TTA.

   Freestanding C (no libc, no allocation): the caller gives the state memory
   (ttac_state_size) and the buffers.  Integer arithmetic only; wrapping is
   explicit (unsigned casts), signed right shifts are arithmetic (gcc, clang),
   so the output is the same with every compiler and target.  The per-sample
   pipeline, the residual coder and the stream are described in
   src/parc_tta.pas and docs/formato/FORMATO-PARC.md (6.8). */

typedef short i16;
typedef int i32;
typedef unsigned int u32;
typedef long long i64;
typedef unsigned long long u64;
typedef unsigned short u16;
typedef unsigned char u8;
typedef __SIZE_TYPE__ usize;

#define MAXORD 1024
#define HISTN (MAXORD + 512 + 8)   /* history window: order + slack before a move */
#define NCTX 64                    /* contexts from the running mean */
#define NSLOT 32                   /* tree (1..7), escape up (8..18), escape down (19..31) */
#define PS 7                       /* probability adaptation shift */
#define PMIN 127                   /* probabilities stay in [PMIN, 65536 - PMIN - 1] */
#define MAXCH 255                  /* channels */
#define MSH 4                      /* running mean: mean += u - mean >> MSH */

typedef struct {
  i32 nf;                          /* LMS filters, 0..3 */
  i32 order[3], shift[3];          /* order (multiple of 16, <= MAXORD), output shift */
  i32 a1, a2, a3;                  /* LMS steps for large / medium / small inputs */
  i32 s2shift, s2step;             /* short stage: weight scale, step */
  i32 ms;                          /* stereo mid/side */
  i32 r1, r2, r3, r4;              /* reserved (0) */
} ttac_cfg;

typedef struct {
  i32 order, shift, sh, pos, pending, avg;
  i16 coef[MAXORD];
  i16 hist[HISTN];
  i16 adapt[HISTN];
} lms_t;

typedef struct {
  i32 w[6];                        /* 4 own taps, 2 cross taps */
  i32 u[4];                        /* own inputs, newest first */
  i32 su[4];                       /* their signs (-1, 0, 1) */
  i32 cur, prev;                   /* this channel's input now / one sample back */
  i32 scur, sprev;                 /* their signs */
} short_t;

typedef struct {
  u32 mean;
  u16 pb[NCTX][NSLOT];
  u16 pm[33][3];
} ent_t;

typedef struct {
  i32 last;
  const short_t *o;                /* the short stage's other channel (set by ttac_init; the
                                      state must stay where it was initialised) */
  short_t s;
  short_t s2;                      /* final short stage (configuration r2 bit 0) */
  ent_t e;
  lms_t f[3];
} chan_t;

typedef struct {
  i32 nch, bits;
  ttac_cfg cfg;
  short_t zs;                      /* zeros: the "other channel" of a mono stream */
  chan_t ch[1];                    /* nch of them */
} state_t;

#define ADD32(a, b) ((i32)((u32)(a) + (u32)(b)))
#define SUB32(a, b) ((i32)((u32)(a) - (u32)(b)))

usize ttac_state_size(i32 nch)
{
  return sizeof(state_t) + (usize)(nch - 1) * sizeof(chan_t);
}

static void zero(void *p, usize n)
{
  volatile u8 *q = (volatile u8 *)p;
  while (n--) *q++ = 0;
}

void ttac_init(void *st, i32 nch, i32 bits, const ttac_cfg *cfg)
{
  state_t *S = (state_t *)st;
  i32 c, j, k, sh = bits - 16;
  if (sh < 0) sh = 0;
  zero(S, ttac_state_size(nch));
  S->nch = nch;
  S->bits = bits;
  S->cfg = *cfg;
  for (c = 0; c < nch; c++) {
    chan_t *ch = &S->ch[c];
    ch->o = nch == 1 ? &S->zs : c ? &S->ch[c - 1].s : &S->ch[nch - 1].s;
    for (j = 0; j < cfg->nf; j++) {
      ch->f[j].order = cfg->order[j];
      ch->f[j].shift = cfg->shift[j];
      ch->f[j].sh = sh;
      ch->f[j].pos = cfg->order[j] + 1;
    }
    ch->e.mean = 16 * 16;
    for (j = 0; j < NCTX; j++)
      for (k = 0; k < NSLOT; k++) ch->e.pb[j][k] = 32768;
    for (j = 0; j < 33; j++)
      for (k = 0; k < 3; k++) ch->e.pm[j][k] = 32768;
  }
}

/* ---------------------------------------------------------------- LMS */

/* c[i] += s * a[i] (16-bit wrap), returns sum c[i] * h[i] (32-bit wrap; the products
   fit, the sum wraps the same in any order) */
#if defined(__SSE2__) && !defined(TTAC_NO_SIMD)
#include <emmintrin.h>
#define LMS_BODY(UPD)                                                              \
  for (i = 0; i < n; i += 16) {                                                    \
    __m128i c0 = _mm_loadu_si128((const __m128i *)(c + i));                        \
    __m128i c1 = _mm_loadu_si128((const __m128i *)(c + i + 8));                    \
    UPD                                                                            \
    acc0 = _mm_add_epi32(acc0, _mm_madd_epi16(c0, _mm_loadu_si128((const __m128i *)(h + i))));     \
    acc1 = _mm_add_epi32(acc1, _mm_madd_epi16(c1, _mm_loadu_si128((const __m128i *)(h + i + 8)))); \
  }
#define LMS_UPD(OP)                                                                \
    c0 = OP(c0, _mm_loadu_si128((const __m128i *)(a + i)));                        \
    c1 = OP(c1, _mm_loadu_si128((const __m128i *)(a + i + 8)));                    \
    _mm_storeu_si128((__m128i *)(c + i), c0);                                      \
    _mm_storeu_si128((__m128i *)(c + i + 8), c1);
static inline i32 lms_dot_upd(i16 *__restrict c, const i16 *__restrict a, const i16 *__restrict h, i32 n, i32 s)
{
  i32 i;
  __m128i acc0 = _mm_setzero_si128(), acc1 = _mm_setzero_si128();
  if (s > 0) { LMS_BODY(LMS_UPD(_mm_add_epi16)) }
  else if (s < 0) { LMS_BODY(LMS_UPD(_mm_sub_epi16)) }
  else { LMS_BODY() }
  acc0 = _mm_add_epi32(acc0, acc1);
  acc0 = _mm_add_epi32(acc0, _mm_shuffle_epi32(acc0, 0x4E));
  acc0 = _mm_add_epi32(acc0, _mm_shuffle_epi32(acc0, 0xB1));
  return _mm_cvtsi128_si32(acc0);
}
#else
static inline i32 lms_dot_upd(i16 *__restrict c, const i16 *__restrict a, const i16 *__restrict h, i32 n, i32 s)
{
  i32 i;
  u32 sum = 0;
  if (s > 0) {
    for (i = 0; i < n; i++) {
      c[i] = (i16)(c[i] + a[i]);
      sum += (u32)((i32)c[i] * h[i]);
    }
  } else if (s < 0) {
    for (i = 0; i < n; i++) {
      c[i] = (i16)(c[i] - a[i]);
      sum += (u32)((i32)c[i] * h[i]);
    }
  } else {
    for (i = 0; i < n; i++) sum += (u32)((i32)c[i] * h[i]);
  }
  return (i32)sum;
}
#endif

#define ALWAYS static inline __attribute__((always_inline))

ALWAYS i32 lms_predict(lms_t *f, const i32 order, const i32 shift)
{
  i32 dot = lms_dot_upd(f->coef, &f->adapt[f->pos - 1 - order], &f->hist[f->pos - order], order, f->pending);
  return (i32)((((i64)dot << f->sh) + ((i64)1 << (shift - 1))) >> shift);
}

ALWAYS void lms_push(lms_t *f, const i32 order, const i32 a1, const i32 a2, const i32 a3, i32 v, i32 err)
{
  i32 s, a, m;
  f->pending = (err > 0) - (err < 0);
  s = v >> f->sh;
  if (s > 32767) s = 32767; else if (s < -32768) s = -32768;
  a = s < 0 ? -s : s;
  f->hist[f->pos] = (i16)s;
  if (a > 3 * f->avg) m = a1;
  else if (3 * a > 4 * f->avg) m = a2;
  else m = a3;
  if (a == 0) m = 0;
  f->adapt[f->pos] = (i16)(s < 0 ? -m : m);
  f->avg += (a - f->avg) / 16;
  f->pos++;
  if (f->pos == HISTN) {
    i32 k, n = order + 1;
    for (k = 0; k < n; k++) {
      f->hist[k] = f->hist[HISTN - n + k];
      f->adapt[k] = f->adapt[HISTN - n + k];
    }
    f->pos = n;
  }
}

/* ---------------------------------------------------------------- short stage */

static inline i32 sgn(i32 x) { return (x > 0) - (x < 0); }


ALWAYS i32 short_predict(const short_t *s, const i32 s2shift, const short_t *o)
{
  i64 sum = (i64)s->w[0] * s->u[0] + (i64)s->w[1] * s->u[1] + (i64)s->w[2] * s->u[2] +
            (i64)s->w[3] * s->u[3] + (i64)s->w[4] * o->cur + (i64)s->w[5] * o->prev;
  return (i32)((sum + ((i64)1 << (s2shift - 1))) >> s2shift);
}

/* sign-sign update; o's values are 0 for a single channel */
ALWAYS void short_update(short_t *s, const i32 s2step, const short_t *o, i32 u, i32 err)
{
  i32 st = err > 0 ? s2step : err < 0 ? -s2step : 0;
  i32 su = sgn(u);
  s->w[0] += st * s->su[0];
  s->w[1] += st * s->su[1];
  s->w[2] += st * s->su[2];
  s->w[3] += st * s->su[3];
  s->w[4] += st * o->scur;
  s->w[5] += st * o->sprev;
  s->u[3] = s->u[2]; s->su[3] = s->su[2];
  s->u[2] = s->u[1]; s->su[2] = s->su[1];
  s->u[1] = s->u[0]; s->su[1] = s->su[0];
  s->u[0] = u; s->su[0] = su;
  s->prev = s->cur; s->sprev = s->scur;
  s->cur = u; s->scur = su;
}

/* ---------------------------------------------------------------- range coder */

typedef struct {
  u64 low;
  u32 range;
  u32 cache;
  u64 csize;
  u8 *p, *end;
} rce_t;

typedef struct {
  u32 code, range;
  const u8 *p, *end;
  i32 over;
} rcd_t;

static inline void rc_shift_low(rce_t *r)
{
  if ((u32)r->low < 0xFF000000u || (r->low >> 32) != 0) {
    u32 c = (u32)(r->low >> 32);
    do {
      if (r->p < r->end) *r->p = (u8)(r->cache + c);
      r->p++;
      r->cache = 0xFF;
    } while (--r->csize != 0);
    r->cache = (u32)(r->low >> 24) & 0xFF;
  }
  r->csize++;
  r->low = (r->low & 0x00FFFFFFu) << 8;
}

/* the bit only selects values: data-dependent branches cost more than the work */
static inline void rc_enc(rce_t *r, u16 *p, u32 bit)
{
  u32 pv = *p, bound = (r->range >> 16) * pv;
  u32 t = bit ? PMIN : 65536 - PMIN - 1;
  r->low += bit ? bound : 0;
  r->range = bit ? r->range - bound : bound;
  *p = (u16)(pv + ((i32)(t - pv) >> PS));
  while (r->range < (1u << 24)) {
    r->range <<= 8;
    rc_shift_low(r);
  }
}

static inline u32 rc_dec(rcd_t *r, u16 *p)
{
  u32 pv = *p, bound = (r->range >> 16) * pv;
  u32 bit = r->code >= bound;
  u32 t = bit ? PMIN : 65536 - PMIN - 1;
  r->code -= bit ? bound : 0;
  r->range = bit ? r->range - bound : bound;
  *p = (u16)(pv + ((i32)(t - pv) >> PS));
  while (r->range < (1u << 24)) {
    r->range <<= 8;
    if (r->p < r->end) r->code = (r->code << 8) | *r->p++;
    else { r->code <<= 8; r->over = 1; }
  }
  return bit;
}

/* raw bits, low first */
typedef struct {
  u64 acc;
  i32 n;
  u8 *p, *end;
} bw_t;

typedef struct {
  u64 acc;
  i32 n;
  const u8 *p, *end;
  i32 over;
} br_t;

static inline void bw_put(bw_t *b, u32 v, i32 n)
{
  b->acc |= (u64)v << b->n;
  b->n += n;
  if (b->n >= 32) {
    if (b->p + 4 <= b->end) {
      b->p[0] = (u8)b->acc; b->p[1] = (u8)(b->acc >> 8);
      b->p[2] = (u8)(b->acc >> 16); b->p[3] = (u8)(b->acc >> 24);
    }
    b->p += 4;
    b->acc >>= 32;
    b->n -= 32;
  }
}

static inline u32 br_get(br_t *b, i32 n)
{
  u32 v;
  if (b->n < n) {
    if (b->end - b->p >= 4) {
      b->acc |= (u64)(b->p[0] | ((u32)b->p[1] << 8) | ((u32)b->p[2] << 16) | ((u32)b->p[3] << 24)) << b->n;
      b->p += 4;
      b->n += 32;
    } else {
      while (b->n < n) {
        if (b->p < b->end) b->acc |= (u64)*b->p++ << b->n;
        else b->over = 1;
        b->n += 8;
      }
    }
  }
  v = (u32)b->acc & ((1u << n) - 1);
  b->acc >>= n;
  b->n -= n;
  return v;
}

/* ---------------------------------------------------------------- residual coder */

static inline i32 bitlen(u32 v) { return v ? 32 - __builtin_clz(v) : 0; }

/* context and expected bit length from the running mean (about 16 x mean of u) */
static inline u16 *ent_ctx(ent_t *e, i32 *k0)
{
  u32 t = e->mean + 16;
  i32 L = 31 - __builtin_clz(t);
  i32 ctx = 2 * L + (i32)((t >> (L - 1)) & 1);
  if (ctx > NCTX - 1) ctx = NCTX - 1;
  *k0 = L - 3 > 32 ? 32 : L - 3;
  return e->pb[ctx];
}

static inline void ent_update(ent_t *e, u32 u)
{
  if (u > (1u << 23)) u = 1u << 23;
  e->mean = e->mean + u - (e->mean >> MSH);
}

/* bit length b of u: s = b - k0 + 3 clamped to 0..7 in a 3-level tree (context ctx),
   beyond the ends (rare) the distance in unary; then the two bits under the leading
   one (context b) and the rest raw */
ALWAYS void ent_encode(ent_t *e, rce_t *r, bw_t *bw, u32 u, const i32 fast)
{
  i32 k0, b, j, m, sym;
  u16 *P = ent_ctx(e, &k0);
  b = bitlen(u);
  sym = b - k0 + 3;
  if (sym < 0) sym = 0;
  if (sym > 7) sym = 7;
  rc_enc(r, &P[1], (u32)sym >> 2);
  rc_enc(r, &P[2 + (sym >> 2)], (u32)(sym >> 1) & 1);
  rc_enc(r, &P[4 + (sym >> 1)], (u32)sym & 1);
  if (sym == 7) {
    for (j = k0 + 4; j < 32; j++) {
      m = j - k0 - 4 < 11 ? 8 + j - k0 - 4 : 18;
      rc_enc(r, &P[m], b > j);
      if (b <= j) break;
    }
  } else if (sym == 0) {
    for (j = k0 - 3; j >= 1; j--) {
      m = k0 - 3 - j < 12 ? 19 + k0 - 3 - j : 31;
      rc_enc(r, &P[m], b < j);
      if (b >= j) break;
    }
  }
  if (fast > 1) {
    if (b >= 2) bw_put(bw, u & ((1u << (b - 1)) - 1), b - 1);
  } else if (b >= 2) {
    m = (u >> (b - 2)) & 1;
    rc_enc(r, &e->pm[b][0], (u32)m);
    if (b >= 3) {
      if (fast) bw_put(bw, u & ((1u << (b - 2)) - 1), b - 2);
      else {
        rc_enc(r, &e->pm[b][1 + m], (u >> (b - 3)) & 1);
        if (b >= 4) bw_put(bw, u & ((1u << (b - 3)) - 1), b - 3);
      }
    }
  }
  ent_update(e, u);
}

ALWAYS u32 ent_decode(ent_t *e, rcd_t *r, br_t *br, const i32 fast)
{
  i32 k0, b, j, m, sym;
  u32 u;
  u16 *P = ent_ctx(e, &k0);
  sym = (i32)rc_dec(r, &P[1]);
  sym = sym * 2 + (i32)rc_dec(r, &P[2 + sym]);
  sym = sym * 2 + (i32)rc_dec(r, &P[4 + sym]);
  b = k0 + sym - 3;
  if (sym == 7) {
    for (j = k0 + 4; j < 32; j++) {
      m = j - k0 - 4 < 11 ? 8 + j - k0 - 4 : 18;
      if (!rc_dec(r, &P[m])) break;
    }
    b = j;
  } else if (sym == 0) {
    for (j = k0 - 3; j >= 1; j--) {
      m = k0 - 3 - j < 12 ? 19 + k0 - 3 - j : 31;
      if (!rc_dec(r, &P[m])) break;
    }
    b = j < 0 ? 0 : j;
  }
  if (b < 0 || b > 32) { r->over = 1; b = 0; }
  if (b < 2) u = (u32)b;
  else if (fast > 1) u = (1u << (b - 1)) | br_get(br, b - 1);
  else {
    m = (i32)rc_dec(r, &e->pm[b][0]);
    u = 2u | (u32)m;
    if (b >= 3) {
      if (fast) u = (u << (b - 2)) | br_get(br, b - 2);
      else {
        u = (u << 1) | rc_dec(r, &e->pm[b][1 + m]);
        if (b >= 4) u = (u << (b - 3)) | br_get(br, b - 3);
      }
    }
  }
  ent_update(e, u);
  return u;
}

/* ---------------------------------------------------------------- frames */

#define PARAMS const i32 nf, const i32 o0, const i32 s0, const i32 o1, const i32 s1, const i32 o2, \
  const i32 s2, const i32 a1, const i32 a2, const i32 a3, const i32 s2shift, const i32 s2step, const i32 ms, const i32 r1

/* Encodes frames x nch samples of x (interleaved; x is changed).
   Returns 0, or -1 when the coded frame does not fit the buffers. */
ALWAYS i32 enc_body(state_t *S, i32 *x, usize frames, u8 *rc, usize rccap, usize *rclen,
                    u8 *raw, usize rawcap, usize *rawlen, PARAMS)
{
  const i32 nc = S->nch, fast = (r1 & 1) | ((r1 >> 1) & 2), noshort = (r1 >> 1) & 1,
            fin = S->cfg.r2 & 1;
  i32 c, j, k;
  usize i;
  rce_t r;
  bw_t bw;
  if (nc > MAXCH) return -1;
  r.low = 0; r.range = 0xFFFFFFFFu; r.cache = 0; r.csize = 1; r.p = rc; r.end = rc + rccap;
  bw.acc = 0; bw.n = 0; bw.p = raw; bw.end = raw + rawcap;
  for (i = 0; i < frames; i++) {
    i32 *xs = x + i * nc;
    if (nc == 2 && ms) {
      i32 l = xs[0], rr = xs[1], s = SUB32(l, rr);
      xs[1] = s;
      xs[0] = ADD32(rr, s >> 1);
    }
    for (c = 0; c < nc; c++) {
      chan_t *ch = S->ch + c;
      const short_t *o = ch->o;
      i32 v = xs[c], e, p;
      /* fixed first order */
      e = SUB32(v, (i32)(((i64)ch->last * 31) >> 5));
      ch->last = v;
      /* short adaptive stage */
      if (!noshort) {
        p = short_predict(&ch->s, s2shift, o);
        v = SUB32(e, p);
        short_update(&ch->s, s2step, o, e, v);
        e = v;
      }
      /* LMS cascade */
      for (j = 0; j < nf; j++) {
        const i32 od = j == 0 ? o0 : j == 1 ? o1 : o2, sf = j == 0 ? s0 : j == 1 ? s1 : s2;
        p = lms_predict(&ch->f[j], od, sf);
        v = SUB32(e, p);
        lms_push(&ch->f[j], od, a1, a2, a3, e, v);
        e = v;
      }
      if (fin) {
        p = short_predict(&ch->s2, s2shift, &S->zs);
        v = SUB32(e, p);
        short_update(&ch->s2, s2step, &S->zs, e, v);
        e = v;
      }
      ent_encode(&ch->e, &r, &bw, ((u32)e << 1) ^ (u32)(e >> 31), fast);
    }
    if (r.p + 64 * nc > r.end || bw.p + 8 * nc > bw.end) return -1;
  }
  for (k = 0; k < 5; k++) rc_shift_low(&r);
  while (bw.n > 0) {
    if (bw.p < bw.end) *bw.p = (u8)bw.acc;
    bw.p++;
    bw.acc >>= 8;
    bw.n -= 8;
  }
  if (r.p > r.end || bw.p > bw.end) return -1;
  *rclen = (usize)(r.p - rc);
  *rawlen = (usize)(bw.p - raw);
  return 0;
}

/* Decodes frames x nch samples into x.  Returns 0, or 1 for a damaged frame. */
ALWAYS i32 dec_body(state_t *S, i32 *x, usize frames, const u8 *rc, usize rclen, const u8 *raw, usize rawlen, PARAMS)
{
  const i32 nc = S->nch, fast = (r1 & 1) | ((r1 >> 1) & 2), noshort = (r1 >> 1) & 1,
            fin = S->cfg.r2 & 1;
  i32 c, j, k;
  usize i;
  rcd_t r;
  br_t br;
  if (rclen < 5 || rc[0] != 0) return 1;
  if (nc > MAXCH) return 1;

  r.p = rc; r.end = rc + rclen; r.over = 0; r.range = 0xFFFFFFFFu; r.code = 0;
  for (k = 0; k < 5; k++) r.code = (r.code << 8) | *r.p++;
  br.acc = 0; br.n = 0; br.p = raw; br.end = raw + rawlen; br.over = 0;
  for (i = 0; i < frames; i++) {
    i32 *xs = x + i * nc;
    for (c = 0; c < nc; c++) {
      chan_t *ch = S->ch + c;
      const short_t *o = ch->o;
      u32 u = ent_decode(&ch->e, &r, &br, fast);
      i32 e = (i32)(u >> 1) ^ -(i32)(u & 1), p, v;
      if (fin) {
        p = short_predict(&ch->s2, s2shift, &S->zs);
        v = ADD32(e, p);
        short_update(&ch->s2, s2step, &S->zs, v, e);
        e = v;
      }
      for (j = nf - 1; j >= 0; j--) {
        const i32 od = j == 0 ? o0 : j == 1 ? o1 : o2, sf = j == 0 ? s0 : j == 1 ? s1 : s2;
        p = lms_predict(&ch->f[j], od, sf);
        v = ADD32(e, p);
        lms_push(&ch->f[j], od, a1, a2, a3, v, e);
        e = v;
      }
      if (!noshort) {
        p = short_predict(&ch->s, s2shift, o);
        v = ADD32(e, p);
        short_update(&ch->s, s2step, o, v, e);
        e = v;
      }
      v = ADD32(e, (i32)(((i64)ch->last * 31) >> 5));
      ch->last = v;
      xs[c] = v;
    }
    if (nc == 2 && ms) {
      i32 m = xs[0], s = xs[1], rr = SUB32(m, s >> 1);
      xs[0] = ADD32(s, rr);
      xs[1] = rr;
    }
    if (r.over | br.over) return 1;
  }
  if (r.p != r.end || br.p != br.end || br.n >= 8) return 1;
  return 0;
}

/* the levels' configurations get their own compiled loops (constants unrolled);
   anything else goes through the generic one */
#define SPECS(X) \
  X(1, 16, 12, 0, 0, 0, 0, 32, 16, 8, 12, 4, 1, 7) \
  X(1, 32, 13, 0, 0, 0, 0, 32, 16, 8, 12, 4, 1, 5) \
  X(2, 256, 15, 16, 12, 0, 0, 32, 16, 8, 12, 4, 1, 1) \
  X(2, 256, 15, 16, 12, 0, 0, 32, 16, 8, 12, 4, 1, 0)

#define CFG_IS(NF, O0, S0, O1, S1, O2, S2, A1, A2, A3, SSH, SST, MS, R1) \
  (c->nf == NF && c->order[0] == O0 && c->shift[0] == S0 && c->order[1] == O1 && c->shift[1] == S1 && \
   c->order[2] == O2 && c->shift[2] == S2 && c->a1 == A1 && c->a2 == A2 && c->a3 == A3 && \
   c->s2shift == SSH && c->s2step == SST && c->ms == MS && c->r1 == R1 && c->r2 == 0)

#define ENC_SPEC(...) if (CFG_IS(__VA_ARGS__)) return enc_body(S, x, frames, rc, rccap, rclen, raw, rawcap, rawlen, __VA_ARGS__);
#define DEC_SPEC(...) if (CFG_IS(__VA_ARGS__)) return dec_body(S, x, frames, rc, rclen, raw, rawlen, __VA_ARGS__);
#define CFG_ARGS c->nf, c->order[0], c->shift[0], c->order[1], c->shift[1], c->order[2], c->shift[2], \
  c->a1, c->a2, c->a3, c->s2shift, c->s2step, c->ms, c->r1

/* Encodes frames x nch samples of x (interleaved; x is changed).
   Returns 0, or -1 when the coded frame does not fit the buffers. */
i32 ttac_encode(void *st, i32 *x, usize frames, u8 *rc, usize rccap, usize *rclen,
                u8 *raw, usize rawcap, usize *rawlen)
{
  state_t *S = (state_t *)st;
  const ttac_cfg *c = &S->cfg;
  SPECS(ENC_SPEC)
  return enc_body(S, x, frames, rc, rccap, rclen, raw, rawcap, rawlen, CFG_ARGS);
}

/* Decodes frames x nch samples into x.  Returns 0, or 1 for a damaged frame. */
i32 ttac_decode(void *st, i32 *x, usize frames, const u8 *rc, usize rclen, const u8 *raw, usize rawlen)
{
  state_t *S = (state_t *)st;
  const ttac_cfg *c = &S->cfg;
  SPECS(DEC_SPEC)
  return dec_body(S, x, frames, rc, rclen, raw, rawlen, CFG_ARGS);
}

/* ================================================================ mm filter

   Same-size decorrelation in front of a general compressor: each sample is replaced by
   (sample - prediction) mod 2^bits, written back with its own width and byte order.
   1D (audio, or images without a known row length): per channel, order 1 or 2 from the
   previous samples.  2D (images): up, gradient a+b-c, MED (the LOCO-I median edge
   detector) or the average of left and up, from the original neighbours (the first row
   predicts from the left, the first column from above).  Cross: with 2 channels the
   second channel's residual minus the first's; with 3 or more, channels 0 and 2 minus
   channel 1 (G of RGB/BGR); other channels (alpha) as they are. */

#define MMCH 16

typedef struct {
  i32 nch, bytes, be, uns, pred, cross;
  i32 width, rowbytes;
  i32 last1[MMCH], last2[MMCH];
  u64 cost;
} mm_t;

usize mm_state_size(void) { return sizeof(mm_t); }

ALWAYS i32 mm_get(const u8 *p, const i32 bytes, const i32 be, const i32 uns)
{
  u32 v;
  switch (bytes) {
  case 1: v = p[0]; break;
  case 2: v = be ? ((u32)p[0] << 8) | p[1] : p[0] | ((u32)p[1] << 8); break;
  case 3: v = be ? ((u32)p[0] << 16) | ((u32)p[1] << 8) | p[2] : p[0] | ((u32)p[1] << 8) | ((u32)p[2] << 16); break;
  default: v = be ? ((u32)p[0] << 24) | ((u32)p[1] << 16) | ((u32)p[2] << 8) | p[3]
                  : p[0] | ((u32)p[1] << 8) | ((u32)p[2] << 16) | ((u32)p[3] << 24);
  }
  if (!uns && bytes < 4) {          /* sign-extend */
    i32 sh = 32 - 8 * bytes;
    return (i32)(v << sh) >> sh;
  }
  return (i32)v;
}

ALWAYS void mm_put(u8 *p, const i32 bytes, const i32 be, u32 v)
{
  switch (bytes) {
  case 1: p[0] = (u8)v; break;
  case 2: if (be) { p[0] = (u8)(v >> 8); p[1] = (u8)v; } else { p[0] = (u8)v; p[1] = (u8)(v >> 8); } break;
  case 3: if (be) { p[0] = (u8)(v >> 16); p[1] = (u8)(v >> 8); p[2] = (u8)v; }
          else { p[0] = (u8)v; p[1] = (u8)(v >> 8); p[2] = (u8)(v >> 16); } break;
  default: if (be) { p[0] = (u8)(v >> 24); p[1] = (u8)(v >> 16); p[2] = (u8)(v >> 8); p[3] = (u8)v; }
           else { p[0] = (u8)v; p[1] = (u8)(v >> 8); p[2] = (u8)(v >> 16); p[3] = (u8)(v >> 24); }
  }
}

/* cost of a residual: bit length of its magnitude as a signed `bytes`-byte number, + sign */
ALWAYS u32 mm_rcost(u32 r, const i32 bytes)
{
  i32 sh = 32 - 8 * bytes, v = (i32)(r << sh) >> sh;
  u32 a = v < 0 ? (u32)-v : (u32)v;
  return (u32)bitlen(a) + (a != 0);
}

ALWAYS i32 mm_pred2d(const i32 kind, i32 a, i32 b, i32 c)
{
  i32 mx, mn;
  switch (kind) {
  case 2: return b;
  case 3: return ADD32(a, SUB32(b, c));
  case 4:
    mx = a > b ? a : b;
    mn = a < b ? a : b;
    return c >= mx ? mn : c <= mn ? mx : ADD32(a, SUB32(b, c));
  case 5: return (i32)(((i64)a + b) >> 1);
  default: return a;
  }
}

ALWAYS i32 mm_ref(const i32 nch) { return nch >= 3 ? 1 : 0; }
ALWAYS i32 mm_crossed(const i32 nch, i32 ch) { return nch == 2 ? ch == 1 : nch >= 3 && (ch == 0 || ch == 2); }

/* a value as mm_get reads it back from its bytes */
ALWAYS i32 mm_norm(u32 v, const i32 bytes, const i32 uns)
{
  if (bytes == 4) return (i32)v;
  if (uns) return (i32)(v & ((1u << (8 * bytes)) - 1));
  return (i32)(v << (32 - 8 * bytes)) >> (32 - 8 * bytes);
}

/* 1D: frames whole sample frames; cost: only add up the cost.  The last values live in
   locals (registers when nch is a constant) and go back to m at the end. */
ALWAYS void mm1_enc(mm_t *m, const u8 *src, u8 *dst, usize frames, const i32 nch, const i32 bytes,
                    const i32 be, const i32 uns, const i32 order, const i32 cross, const i32 cost)
{
  usize i;
  i32 ch, l1[MMCH], l2[MMCH];
  u64 cs = 0;
  const i32 N = nch * bytes, ref = mm_ref(nch);
  for (ch = 0; ch < nch; ch++) { l1[ch] = m->last1[ch]; l2[ch] = m->last2[ch]; }
  for (i = 0; i < frames; i++) {
    u32 r[MMCH];
    for (ch = 0; ch < nch; ch++) {
      i32 v = mm_get(src + i * N + ch * bytes, bytes, be, uns);
      i32 p = order == 2 ? SUB32(2 * (u32)l1[ch], l2[ch]) : l1[ch];
      l2[ch] = l1[ch];
      l1[ch] = v;
      r[ch] = (u32)SUB32(v, p);
    }
    for (ch = 0; ch < nch; ch++) {
      u32 o = cross && mm_crossed(nch, ch) ? r[ch] - r[ref] : r[ch];
      if (cost) cs += mm_rcost(o, bytes);
      else mm_put(dst + i * N + ch * bytes, bytes, be, o);
    }
  }
  for (ch = 0; ch < nch; ch++) { m->last1[ch] = l1[ch]; m->last2[ch] = l2[ch]; }
  m->cost += cs;
}

ALWAYS void mm1_dec(mm_t *m, u8 *buf, usize frames, const i32 nch, const i32 bytes,
                    const i32 be, const i32 uns, const i32 order, const i32 cross)
{
  usize i;
  i32 ch, l1[MMCH], l2[MMCH];
  const i32 N = nch * bytes, ref = mm_ref(nch);
  for (ch = 0; ch < nch; ch++) { l1[ch] = m->last1[ch]; l2[ch] = m->last2[ch]; }
  for (i = 0; i < frames; i++) {
    u8 *q = buf + i * N;
    u32 rr = (u32)mm_get(q + ref * bytes, bytes, be, 1);
    for (ch = 0; ch < nch; ch++) {
      u32 o = (u32)mm_get(q + ch * bytes, bytes, be, 1);
      i32 p = order == 2 ? SUB32(2 * (u32)l1[ch], l2[ch]) : l1[ch], v;
      if (cross && mm_crossed(nch, ch)) o += rr;
      v = mm_norm(o + (u32)p, bytes, uns);
      mm_put(q + ch * bytes, bytes, be, (u32)v);
      l2[ch] = l1[ch];
      l1[ch] = v;
    }
  }
  for (ch = 0; ch < nch; ch++) { m->last1[ch] = l1[ch]; m->last2[ch] = l2[ch]; }
}

/* 2D: nrows rows of rowbytes at src; prev = the original row before them (NULL at the top).
   The left and up-left values of each channel are carried in locals along the row. */
ALWAYS void mm2_enc(mm_t *m, const u8 *src, const u8 *prev, u8 *dst, usize nrows, const i32 nch,
                    const i32 bytes, const i32 be, const i32 uns, const i32 kind, const i32 cross, const i32 cost)
{
  usize y;
  i32 x, ch;
  u64 cs = 0;
  const i32 N = nch * bytes, ref = mm_ref(nch), w = m->width, rb = m->rowbytes;
  for (y = 0; y < nrows; y++) {
    const u8 *cur = src + y * rb, *up = y ? cur - rb : prev;
    u8 *out = cost ? 0 : dst + y * rb;
    i32 a[MMCH], c[MMCH];
    for (ch = 0; ch < nch; ch++) { a[ch] = 0; c[ch] = 0; }
    for (x = 0; x < w; x++) {
      u32 r[MMCH];
      for (ch = 0; ch < nch; ch++) {
        const i32 off = x * N + ch * bytes;
        i32 v = mm_get(cur + off, bytes, be, uns), p;
        if (up) {
          i32 b = mm_get(up + off, bytes, be, uns);
          p = x ? mm_pred2d(kind, a[ch], b, c[ch]) : b;
          c[ch] = b;
        } else
          p = a[ch];
        a[ch] = v;
        r[ch] = (u32)SUB32(v, p);
      }
      for (ch = 0; ch < nch; ch++) {
        u32 o = cross && mm_crossed(nch, ch) ? r[ch] - r[ref] : r[ch];
        if (cost) cs += mm_rcost(o, bytes);
        else mm_put(out + x * N + ch * bytes, bytes, be, o);
      }
    }
    if (!cost)
      for (x = w * N; x < rb; x++) out[x] = cur[x];   /* row padding as it is */
  }
  m->cost += cs;
}

ALWAYS void mm2_dec(mm_t *m, u8 *buf, const u8 *prev, usize nrows, const i32 nch,
                    const i32 bytes, const i32 be, const i32 uns, const i32 kind, const i32 cross)
{
  usize y;
  i32 x, ch;
  const i32 N = nch * bytes, ref = mm_ref(nch), w = m->width, rb = m->rowbytes;
  for (y = 0; y < nrows; y++) {
    u8 *cur = buf + y * rb;
    const u8 *up = y ? cur - rb : prev;
    i32 a[MMCH], c[MMCH];
    for (ch = 0; ch < nch; ch++) { a[ch] = 0; c[ch] = 0; }
    if (!up) {
      for (x = 0; x < w; x++) {
        u8 *q = cur + x * N;
        u32 rr = (u32)mm_get(q + ref * bytes, bytes, be, 1);
        for (ch = 0; ch < nch; ch++) {
          u32 o = (u32)mm_get(q + ch * bytes, bytes, be, 1);
          if (cross && mm_crossed(nch, ch)) o += rr;
          a[ch] = mm_norm(o + (u32)a[ch], bytes, uns);
          mm_put(q + ch * bytes, bytes, be, (u32)a[ch]);
        }
      }
      continue;
    }
    for (x = 0; x < w; x++) {
      u8 *q = cur + x * N;
      const u8 *uq = up + x * N;
      u32 rr = (u32)mm_get(q + ref * bytes, bytes, be, 1);
      for (ch = 0; ch < nch; ch++) {
        u32 o = (u32)mm_get(q + ch * bytes, bytes, be, 1);
        i32 b = mm_get(uq + ch * bytes, bytes, be, uns);
        i32 p = x ? mm_pred2d(kind, a[ch], b, c[ch]) : b;
        if (cross && mm_crossed(nch, ch)) o += rr;
        a[ch] = mm_norm(o + (u32)p, bytes, uns);
        c[ch] = b;
        mm_put(q + ch * bytes, bytes, be, (u32)a[ch]);
      }
    }
  }
}


/* ---------------------------------------------------------------- 8-bit images, fast paths */

ALWAYS u8 mm_p8(const i32 kind, u32 a, u32 b, u32 c)
{
  u32 mx, mn;
  switch (kind) {
  case 2: return (u8)b;
  case 3: return (u8)(a + b - c);
  case 4: {
    /* branchless: the comparisons only make masks (they are unpredictable) */
    u32 m1, m2;
    mx = a ^ ((a ^ b) & (0u - (u32)(b > a)));
    mn = a ^ b ^ mx;
    m1 = 0u - (u32)(c >= mx);
    m2 = 0u - (u32)(c <= mn);
    return (u8)((mn & m1) | (~m1 & ((mx & m2) | (~m2 & (a + b - c)))));
  }
  case 5: return (u8)((a + b) >> 1);
  default: return (u8)a;
  }
}

#if defined(__SSE2__) && !defined(TTAC_NO_SIMD)
/* predictions of 16 bytes at once (unsigned bytes; the same values as mm_p8) */
ALWAYS __m128i mm_p8v(const i32 kind, __m128i a, __m128i b, __m128i c)
{
  __m128i mx, mn, g, m1, m2, one;
  switch (kind) {
  case 2: return b;
  case 3: return _mm_sub_epi8(_mm_add_epi8(a, b), c);
  case 4:
    mx = _mm_max_epu8(a, b);
    mn = _mm_min_epu8(a, b);
    g = _mm_sub_epi8(_mm_add_epi8(a, b), c);
    m1 = _mm_cmpeq_epi8(_mm_max_epu8(c, mx), c);          /* c >= mx */
    m2 = _mm_cmpeq_epi8(_mm_min_epu8(c, mn), c);          /* c <= mn */
    g = _mm_or_si128(_mm_and_si128(m2, mx), _mm_andnot_si128(m2, g));
    return _mm_or_si128(_mm_and_si128(m1, mn), _mm_andnot_si128(m1, g));
  case 5:
    one = _mm_set1_epi8(1);
    return _mm_sub_epi8(_mm_avg_epu8(a, b), _mm_and_si128(_mm_xor_si128(a, b), one));
  default: return a;
  }
}
#endif

/* encoder, unsigned bytes, rows: residuals in place of the samples, then the cross pass */
ALWAYS void mm2_enc8(mm_t *m, const u8 *src, const u8 *prev, u8 *dst, usize nrows,
                     const i32 nch, const i32 kind, const i32 cross)
{
  usize y;
  i32 i, x;
  const i32 N = nch, w = m->width, rb = m->rowbytes, n = w * nch;
  for (y = 0; y < nrows; y++) {
    const u8 *cur = src + y * rb, *up = y ? cur - rb : prev;
    u8 *out = dst + y * rb;
    if (!up) {
      for (i = 0; i < N && i < n; i++) out[i] = cur[i];
      for (; i < n; i++) out[i] = (u8)(cur[i] - cur[i - N]);
    } else {
      for (i = 0; i < N && i < n; i++) out[i] = (u8)(cur[i] - up[i]);
      i = N;
#if defined(__SSE2__) && !defined(TTAC_NO_SIMD)
      for (; i + 16 <= n; i += 16) {
        __m128i a = _mm_loadu_si128((const __m128i *)(cur + i - N));
        __m128i b = _mm_loadu_si128((const __m128i *)(up + i));
        __m128i c = _mm_loadu_si128((const __m128i *)(up + i - N));
        __m128i v = _mm_loadu_si128((const __m128i *)(cur + i));
        _mm_storeu_si128((__m128i *)(out + i), _mm_sub_epi8(v, mm_p8v(kind, a, b, c)));
      }
#endif
      for (; i < n; i++) out[i] = (u8)(cur[i] - mm_p8(kind, cur[i - N], up[i], up[i - N]));
    }
    if (cross && nch >= 2) {
      if (nch == 2)
        for (x = 0; x < w; x++) out[2 * x + 1] = (u8)(out[2 * x + 1] - out[2 * x]);
      else
        for (x = 0; x < w; x++) {
          u8 g = out[x * N + 1];
          out[x * N] = (u8)(out[x * N] - g);
          out[x * N + 2] = (u8)(out[x * N + 2] - g);
        }
    }
    for (i = n; i < rb; i++) out[i] = cur[i];
  }
}

/* decoder, unsigned bytes, rows, in place */
ALWAYS void mm2_dec8(mm_t *m, u8 *buf, const u8 *prev, usize nrows,
                     const i32 nch, const i32 kind, const i32 cross)
{
  usize y;
  i32 i, x;
  const i32 N = nch, w = m->width, rb = m->rowbytes, n = w * nch;
  for (y = 0; y < nrows; y++) {
    u8 *cur = buf + y * rb;
    const u8 *up = y ? cur - rb : prev;
    if (cross && nch >= 2) {
      if (nch == 2)
        for (x = 0; x < w; x++) cur[2 * x + 1] = (u8)(cur[2 * x + 1] + cur[2 * x]);
      else
        for (x = 0; x < w; x++) {
          u8 g = cur[x * N + 1];
          cur[x * N] = (u8)(cur[x * N] + g);
          cur[x * N + 2] = (u8)(cur[x * N + 2] + g);
        }
    }
    if (!up) {
      for (i = N; i < n; i++) cur[i] = (u8)(cur[i] + cur[i - N]);
    } else if (kind == 2) {
      for (i = 0; i < n; i++) cur[i] = (u8)(cur[i] + up[i]);
    } else {
      for (i = 0; i < N && i < n; i++) cur[i] = (u8)(cur[i] + up[i]);
#if defined(__SSE2__) && !defined(TTAC_NO_SIMD)
      if (N >= 3 && w >= 3) {
        /* a whole pixel per step: the channels' serial chains side by side in one register
           (4-byte loads; the last pixel of the row goes scalar so nothing is read past it) */
        __m128i av = _mm_cvtsi32_si128((i32)(cur[0] | ((u32)cur[1] << 8) | ((u32)cur[2] << 16) |
                                             (N == 4 ? (u32)cur[3] << 24 : 0)));
        __m128i cv = _mm_cvtsi32_si128((i32)(up[0] | ((u32)up[1] << 8) | ((u32)up[2] << 16) |
                                             (N == 4 ? (u32)up[3] << 24 : 0)));
        for (x = 1; x < w - 1; x++) {
          u32 rv, bv4, o;
          __m128i bv, v;
          __builtin_memcpy(&rv, cur + x * N, 4);
          __builtin_memcpy(&bv4, up + x * N, 4);
          bv = _mm_cvtsi32_si128((i32)bv4);
          v = _mm_add_epi8(_mm_cvtsi32_si128((i32)rv), mm_p8v(kind, av, bv, cv));
          o = (u32)_mm_cvtsi128_si32(v);
          if (N == 4) __builtin_memcpy(cur + x * N, &o, 4);
          else { cur[x * N] = (u8)o; cur[x * N + 1] = (u8)(o >> 8); cur[x * N + 2] = (u8)(o >> 16); }
          av = v;
          cv = bv;
        }
        i = (w - 1) * N;
      }
#endif
      for (; i < n; i++) cur[i] = (u8)(cur[i] + mm_p8(kind, cur[i - N], up[i], up[i - N]));
    }
  }
}

#define K8E(NCH, K) if (m->pred == K) { if (m->cross) mm2_enc8(m, src, prev, dst, nrows, NCH, K, 1); \
  else mm2_enc8(m, src, prev, dst, nrows, NCH, K, 0); return; }
#define N8E(NCH) if (m->nch == NCH) { K8E(NCH, 0) K8E(NCH, 2) K8E(NCH, 3) K8E(NCH, 4) K8E(NCH, 5) }
#define K8D(NCH, K) if (m->pred == K) { if (m->cross) mm2_dec8(m, buf, prev, nrows, NCH, K, 1); \
  else mm2_dec8(m, buf, prev, nrows, NCH, K, 0); return; }
#define N8D(NCH) if (m->nch == NCH) { K8D(NCH, 0) K8D(NCH, 2) K8D(NCH, 3) K8D(NCH, 4) K8D(NCH, 5) }

/* the common layouts get their own loops, the rest the generic one */
#define MM_SPECS2(X) X(1, 1, 0, 1) X(3, 1, 0, 1) X(4, 1, 0, 1)
#define MM_SPECS1(X) X(1, 1, 0, 1) X(2, 2, 0, 0) X(1, 2, 0, 0) X(2, 1, 0, 1)
#define MM_IS(NCH, BYTES, BE, UNS) (m->nch == NCH && m->bytes == BYTES && m->be == BE && m->uns == UNS)

#define E2K(NCH, BYTES, BE, UNS, K) \
  if (m->pred == K) { \
    if (m->cross) mm2_enc(m, src, prev, dst, nrows, NCH, BYTES, BE, UNS, K, 1, cost); \
    else mm2_enc(m, src, prev, dst, nrows, NCH, BYTES, BE, UNS, K, 0, cost); \
    return; }
#define E2(NCH, BYTES, BE, UNS) if (MM_IS(NCH, BYTES, BE, UNS)) { E2K(NCH, BYTES, BE, UNS, 0) \
  E2K(NCH, BYTES, BE, UNS, 2) E2K(NCH, BYTES, BE, UNS, 3) E2K(NCH, BYTES, BE, UNS, 4) E2K(NCH, BYTES, BE, UNS, 5) }
#define D2K(NCH, BYTES, BE, UNS, K) \
  if (m->pred == K) { \
    if (m->cross) mm2_dec(m, buf, prev, nrows, NCH, BYTES, BE, UNS, K, 1); \
    else mm2_dec(m, buf, prev, nrows, NCH, BYTES, BE, UNS, K, 0); \
    return; }
#define D2(NCH, BYTES, BE, UNS) if (MM_IS(NCH, BYTES, BE, UNS)) { D2K(NCH, BYTES, BE, UNS, 0) \
  D2K(NCH, BYTES, BE, UNS, 2) D2K(NCH, BYTES, BE, UNS, 3) D2K(NCH, BYTES, BE, UNS, 4) D2K(NCH, BYTES, BE, UNS, 5) }
#define E1K(NCH, BYTES, BE, UNS, K) \
  if (m->pred == K - 1) { \
    if (m->cross) mm1_enc(m, src, dst, frames, NCH, BYTES, BE, UNS, K, 1, cost); \
    else mm1_enc(m, src, dst, frames, NCH, BYTES, BE, UNS, K, 0, cost); \
    return; }
#define E1(NCH, BYTES, BE, UNS) if (MM_IS(NCH, BYTES, BE, UNS)) { E1K(NCH, BYTES, BE, UNS, 1) E1K(NCH, BYTES, BE, UNS, 2) }
#define D1K(NCH, BYTES, BE, UNS, K) \
  if (m->pred == K - 1) { \
    if (m->cross) mm1_dec(m, buf, frames, NCH, BYTES, BE, UNS, K, 1); \
    else mm1_dec(m, buf, frames, NCH, BYTES, BE, UNS, K, 0); \
    return; }
#define D1(NCH, BYTES, BE, UNS) if (MM_IS(NCH, BYTES, BE, UNS)) { D1K(NCH, BYTES, BE, UNS, 1) D1K(NCH, BYTES, BE, UNS, 2) }

/* pred: 0 = order 1, 1 = order 2 (1D); 2 = up, 3 = gradient, 4 = MED, 5 = average (2D).
   cost != 0: nothing is written, m->cost grows by the residuals' cost. */
void mm_enc_rows(mm_t *m, const u8 *src, const u8 *prev, u8 *dst, usize nrows, i32 cost)
{
  if (!cost && m->bytes == 1 && m->uns && !m->be) { N8E(1) N8E(2) N8E(3) N8E(4) }
  if (cost) {
    const i32 cost = 1;
    MM_SPECS2(E2)
    mm2_enc(m, src, prev, dst, nrows, m->nch, m->bytes, m->be, m->uns, m->pred, m->cross, 1);
  } else {
    const i32 cost = 0;
    MM_SPECS2(E2)
    mm2_enc(m, src, prev, dst, nrows, m->nch, m->bytes, m->be, m->uns, m->pred, m->cross, 0);
  }
}

void mm_dec_rows(mm_t *m, u8 *buf, const u8 *prev, usize nrows)
{
  if (m->bytes == 1 && m->uns && !m->be) { N8D(1) N8D(2) N8D(3) N8D(4) }
  MM_SPECS2(D2)
  mm2_dec(m, buf, prev, nrows, m->nch, m->bytes, m->be, m->uns, m->pred, m->cross);
}

void mm_enc_1d(mm_t *m, const u8 *src, u8 *dst, usize frames, i32 cost)
{
  if (cost) {
    const i32 cost = 1;
    MM_SPECS1(E1)
    mm1_enc(m, src, dst, frames, m->nch, m->bytes, m->be, m->uns, m->pred + 1, m->cross, 1);
  } else {
    const i32 cost = 0;
    MM_SPECS1(E1)
    mm1_enc(m, src, dst, frames, m->nch, m->bytes, m->be, m->uns, m->pred + 1, m->cross, 0);
  }
}

void mm_dec_1d(mm_t *m, u8 *buf, usize frames)
{
  MM_SPECS1(D1)
  mm1_dec(m, buf, frames, m->nch, m->bytes, m->be, m->uns, m->pred + 1, m->cross);
}

/* costs of all 2D predictors in one pass: cost[2 * k + cross] for k = 0 (left), 2..5 */
ALWAYS void mm2_costs_body(const mm_t *m, const u8 *src, usize nrows, u64 *cost, const i32 nch,
                           const i32 bytes, const i32 be, const i32 uns)
{
  usize y;
  i32 x, ch, k;
  const i32 N = nch * bytes, ref = mm_ref(nch), w = m->width, rb = m->rowbytes;
  for (y = 1; y < nrows; y++) {
    const u8 *cur = src + y * rb, *up = cur - rb;
    for (x = 1; x < w; x++) {
      u32 r[6][MMCH];
      for (ch = 0; ch < nch; ch++) {
        const i32 off = x * N + ch * bytes;
        i32 v = mm_get(cur + off, bytes, be, uns), a = mm_get(cur + off - N, bytes, be, uns);
        i32 b = mm_get(up + off, bytes, be, uns), c = mm_get(up + off - N, bytes, be, uns);
        r[0][ch] = (u32)SUB32(v, a);
        r[2][ch] = (u32)SUB32(v, mm_pred2d(2, a, b, c));
        r[3][ch] = (u32)SUB32(v, mm_pred2d(3, a, b, c));
        r[4][ch] = (u32)SUB32(v, mm_pred2d(4, a, b, c));
        r[5][ch] = (u32)SUB32(v, mm_pred2d(5, a, b, c));
      }
      for (k = 0; k < 6; k++) {
        if (k == 1) continue;
        for (ch = 0; ch < nch; ch++) {
          cost[2 * k] += mm_rcost(r[k][ch], bytes);
          if (nch >= 2) cost[2 * k + 1] += mm_rcost(mm_crossed(nch, ch) ? r[k][ch] - r[k][ref] : r[k][ch], bytes);
        }
      }
    }
  }
}

void mm_costs_2d(const mm_t *m, const u8 *src, usize nrows, u64 *cost)
{
  i32 k;
  for (k = 0; k < 12; k++) cost[k] = 0;
  if (m->bytes == 1 && m->uns && m->nch == 3) mm2_costs_body(m, src, nrows, cost, 3, 1, 0, 1);
  else if (m->bytes == 1 && m->uns && m->nch == 4) mm2_costs_body(m, src, nrows, cost, 4, 1, 0, 1);
  else if (m->bytes == 1 && m->uns && m->nch == 1) mm2_costs_body(m, src, nrows, cost, 1, 1, 0, 1);
  else mm2_costs_body(m, src, nrows, cost, m->nch, m->bytes, m->be, m->uns);
}

/* ================================================================ row length

   For images without a header the mm encoder looks for the row length S (bytes): the byte
   distance where the data repeats best.  Coarse pass: every S in [smin, smax] on k1 sample
   positions; the 16 best go to a fine pass on k2 positions.  Returns S, or 0 when no S beats
   the distance n (the left neighbour) by 15 %. */

static u64 mm_dist_cost(const u8 *p, usize len, u32 S, u32 from, u32 k)
{
  u64 c = 0;
  usize i, step = (len - from) / k;
  u32 j;
  if (step == 0) step = 1;
  for (j = 0, i = from; j < k && i < len; j++, i += step) {
    i32 d = (i32)p[i] - (i32)p[i - S];
    c += (u32)(d < 0 ? -d : d);
  }
  return c;
}

u32 mm_find_stride(const u8 *p, usize len, u32 n, u32 smin, u32 smax, u32 k1, u32 k2)
{
  u32 best[16], S, j, m;
  u64 bc[16], c, ref;
  if (smax > len / 3) smax = (u32)(len / 3);
  if (smin < 2 * n) smin = 2 * n;
  if (smin > smax || len < 4096) return 0;
  for (j = 0; j < 16; j++) { best[j] = 0; bc[j] = ~(u64)0; }
  for (S = smin; S <= smax; S++) {
    c = mm_dist_cost(p, len, S, smax, k1);
    if (c < bc[15]) {
      for (j = 15; j > 0 && bc[j - 1] > c; j--) { bc[j] = bc[j - 1]; best[j] = best[j - 1]; }
      bc[j] = c; best[j] = S;
    }
  }
  m = 0;
  c = ~(u64)0;
  for (j = 0; j < 16; j++) {
    u64 f;
    if (!best[j]) continue;
    f = mm_dist_cost(p, len, best[j], smax, k2);
    if (f < c || (f == c && best[j] < m)) { c = f; m = best[j]; }
  }
  ref = mm_dist_cost(p, len, n, smax, k2);
  if (!m || c * 100 > ref * 85) return 0;
  return m;
}

/* ================================================================ LZ cost estimate

   Whether mm pays is decided by how a fast LZ sees a sample, raw and filtered: greedy matches
   of at least 4 bytes through a hash of the next 4 bytes (tab: 2^14 positions given by the
   caller), a literal costing 9 bits and a match 24.  Returns the cost in bits. */
u64 mm_lz_cost(const u8 *p, usize n, u32 *tab)
{
  usize i = 0, j;
  u64 c = 0;
  for (j = 0; j < (1u << 14); j++) tab[j] = 0xFFFFFFFFu;
  while (i + 4 <= n) {
    u32 v = p[i] | ((u32)p[i + 1] << 8) | ((u32)p[i + 2] << 16) | ((u32)p[i + 3] << 24);
    u32 h = (v * 2654435761u) >> 18, cand = tab[h];
    tab[h] = (u32)i;
    if (cand != 0xFFFFFFFFu && p[cand] == p[i] && p[cand + 1] == p[i + 1] && p[cand + 2] == p[i + 2] &&
        p[cand + 3] == p[i + 3]) {
      usize l = 4;
      while (i + l < n && p[cand + l] == p[i + l]) l++;
      c += 24;
      i += l;
    } else {
      c += 9;
      i++;
    }
  }
  return c + 9 * (n - i);
}
