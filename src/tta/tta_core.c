/* tta_core.c - core of PArc's lossless audio codec (method `tta`).
   MIT license, part of PArc; nothing from FreeArc or TTA.

   Freestanding C (no libc, no allocation): the caller gives the state memory
   (ttac_state_size) and the buffers.  Integer arithmetic only; wrapping is
   explicit (unsigned casts), signed right shifts are arithmetic (gcc, clang),
   so the output is the same with every compiler and target.  The per-sample
   pipeline, the residual coder and the stream are described in
   src/parc_tta.pas and docs/formato/FORMATO-PARC.md (6.6). */

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
  i32 cur, prev;                   /* this channel's input now / one sample back */
} short_t;

typedef struct {
  u32 mean;
  u16 pb[NCTX][NSLOT];
  u16 pm[33][3];
} ent_t;

typedef struct {
  i32 last;
  short_t s;
  ent_t e;
  lms_t f[3];
} chan_t;

typedef struct {
  i32 nch, bits;
  ttac_cfg cfg;
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

static inline i32 lms_predict(lms_t *f)
{
  i32 dot = lms_dot_upd(f->coef, &f->adapt[f->pos - 1 - f->order], &f->hist[f->pos - f->order],
                        f->order, f->pending);
  return (i32)((((i64)dot << f->sh) + ((i64)1 << (f->shift - 1))) >> f->shift);
}

static inline void lms_push(lms_t *f, const ttac_cfg *cfg, i32 v, i32 err)
{
  i32 s, a, m;
  f->pending = (err > 0) - (err < 0);
  s = v >> f->sh;
  if (s > 32767) s = 32767; else if (s < -32768) s = -32768;
  a = s < 0 ? -s : s;
  f->hist[f->pos] = (i16)s;
  if (a > 3 * f->avg) m = cfg->a1;
  else if (3 * a > 4 * f->avg) m = cfg->a2;
  else m = cfg->a3;
  if (a == 0) m = 0;
  f->adapt[f->pos] = (i16)(s < 0 ? -m : m);
  f->avg += (a - f->avg) / 16;
  f->pos++;
  if (f->pos == HISTN) {
    i32 k, n = f->order + 1;
    for (k = 0; k < n; k++) {
      f->hist[k] = f->hist[HISTN - n + k];
      f->adapt[k] = f->adapt[HISTN - n + k];
    }
    f->pos = n;
  }
}

/* ---------------------------------------------------------------- short stage */

static inline i32 sgn(i32 x) { return (x > 0) - (x < 0); }

static inline i32 short_predict(const short_t *s, const ttac_cfg *cfg, i32 o0, i32 o1)
{
  i64 sum = (i64)s->w[0] * s->u[0] + (i64)s->w[1] * s->u[1] + (i64)s->w[2] * s->u[2] +
            (i64)s->w[3] * s->u[3] + (i64)s->w[4] * o0 + (i64)s->w[5] * o1;
  return (i32)((sum + ((i64)1 << (cfg->s2shift - 1))) >> cfg->s2shift);
}

static inline void short_update(short_t *s, const ttac_cfg *cfg, i32 o0, i32 o1, i32 u, i32 err)
{
  i32 st = cfg->s2step * sgn(err);
  s->w[0] += st * sgn(s->u[0]);
  s->w[1] += st * sgn(s->u[1]);
  s->w[2] += st * sgn(s->u[2]);
  s->w[3] += st * sgn(s->u[3]);
  s->w[4] += st * sgn(o0);
  s->w[5] += st * sgn(o1);
  s->u[3] = s->u[2];
  s->u[2] = s->u[1];
  s->u[1] = s->u[0];
  s->u[0] = u;
  s->prev = s->cur;
  s->cur = u;
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
static inline void ent_encode(ent_t *e, rce_t *r, bw_t *bw, u32 u)
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
  if (b >= 2) {
    m = (u >> (b - 2)) & 1;
    rc_enc(r, &e->pm[b][0], (u32)m);
    if (b >= 3) {
      rc_enc(r, &e->pm[b][1 + m], (u >> (b - 3)) & 1);
      if (b >= 4) bw_put(bw, u & ((1u << (b - 3)) - 1), b - 3);
    }
  }
  ent_update(e, u);
}

static inline u32 ent_decode(ent_t *e, rcd_t *r, br_t *br)
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
  else {
    m = (i32)rc_dec(r, &e->pm[b][0]);
    u = 2u | (u32)m;
    if (b >= 3) {
      u = (u << 1) | rc_dec(r, &e->pm[b][1 + m]);
      if (b >= 4) u = (u << (b - 3)) | br_get(br, b - 3);
    }
  }
  ent_update(e, u);
  return u;
}

/* ---------------------------------------------------------------- frames */

/* Encodes frames x nch samples of x (interleaved; x is changed).
   Returns 0, or -1 when the coded frame does not fit the buffers. */
i32 ttac_encode(void *st, i32 *x, usize frames, u8 *rc, usize rccap, usize *rclen,
                u8 *raw, usize rawcap, usize *rawlen)
{
  state_t *S = (state_t *)st;
  const ttac_cfg *cfg = &S->cfg;
  const i32 nc = S->nch, nf = cfg->nf;
  i32 c, j, k;
  usize i;
  rce_t r;
  bw_t bw;
  r.low = 0; r.range = 0xFFFFFFFFu; r.cache = 0; r.csize = 1; r.p = rc; r.end = rc + rccap;
  bw.acc = 0; bw.n = 0; bw.p = raw; bw.end = raw + rawcap;
  for (i = 0; i < frames; i++) {
    i32 *xs = x + i * nc;
    if (nc == 2 && cfg->ms) {
      i32 l = xs[0], rr = xs[1], s = SUB32(l, rr);
      xs[1] = s;
      xs[0] = ADD32(rr, s >> 1);
    }
    for (c = 0; c < nc; c++) {
      chan_t *ch = &S->ch[c];
      const chan_t *o = &S->ch[c ? c - 1 : nc - 1];
      i32 o0 = nc > 1 ? o->s.cur : 0, o1 = nc > 1 ? o->s.prev : 0;
      i32 v = xs[c], e, p;
      /* fixed first order */
      e = SUB32(v, (i32)(((i64)ch->last * 31) >> 5));
      ch->last = v;
      /* short adaptive stage */
      p = short_predict(&ch->s, cfg, o0, o1);
      v = SUB32(e, p);
      short_update(&ch->s, cfg, o0, o1, e, v);
      e = v;
      /* LMS cascade */
      for (j = 0; j < nf; j++) {
        p = lms_predict(&ch->f[j]);
        v = SUB32(e, p);
        lms_push(&ch->f[j], cfg, e, v);
        e = v;
      }
      ent_encode(&ch->e, &r, &bw, ((u32)e << 1) ^ (u32)(e >> 31));
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
i32 ttac_decode(void *st, i32 *x, usize frames, const u8 *rc, usize rclen, const u8 *raw, usize rawlen)
{
  state_t *S = (state_t *)st;
  const ttac_cfg *cfg = &S->cfg;
  const i32 nc = S->nch, nf = cfg->nf;
  i32 c, j, k;
  usize i;
  rcd_t r;
  br_t br;
  if (rclen < 5 || rc[0] != 0) return 1;
  r.p = rc; r.end = rc + rclen; r.over = 0; r.range = 0xFFFFFFFFu; r.code = 0;
  for (k = 0; k < 5; k++) r.code = (r.code << 8) | *r.p++;
  br.acc = 0; br.n = 0; br.p = raw; br.end = raw + rawlen; br.over = 0;
  for (i = 0; i < frames; i++) {
    i32 *xs = x + i * nc;
    for (c = 0; c < nc; c++) {
      chan_t *ch = &S->ch[c];
      const chan_t *o = &S->ch[c ? c - 1 : nc - 1];
      i32 o0 = nc > 1 ? o->s.cur : 0, o1 = nc > 1 ? o->s.prev : 0;
      u32 u = ent_decode(&ch->e, &r, &br);
      i32 e = (i32)(u >> 1) ^ -(i32)(u & 1), p, v;
      for (j = nf - 1; j >= 0; j--) {
        p = lms_predict(&ch->f[j]);
        v = ADD32(e, p);
        lms_push(&ch->f[j], cfg, v, e);
        e = v;
      }
      p = short_predict(&ch->s, cfg, o0, o1);
      v = ADD32(e, p);
      short_update(&ch->s, cfg, o0, o1, v, e);
      v = ADD32(v, (i32)(((i64)ch->last * 31) >> 5));
      ch->last = v;
      xs[c] = v;
    }
    if (nc == 2 && cfg->ms) {
      i32 m = xs[0], s = xs[1], rr = SUB32(m, s >> 1);
      xs[0] = ADD32(s, rr);
      xs[1] = rr;
    }
    if (r.over | br.over) return 1;
  }
  if (r.p != r.end || br.p != br.end || br.n >= 8) return 1;
  return 0;
}
