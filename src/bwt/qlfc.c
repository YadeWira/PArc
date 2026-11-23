/*-----------------------------------------------------------*/
/* Quantized Local Frequency Coding (QLFC) for PArc's `bwt`  */
/*-----------------------------------------------------------*/

/*--

Derived from libbsc 3.4.1 (https://github.com/IlyaGrebnov/libbsc, tag v3.4.1),
files libbsc/coder/qlfc/qlfc.cpp, qlfc_model.h, qlfc_model.cpp,
libbsc/coder/common/rangecoder.h and predictor.h:

   Copyright (c) 2009-2026 Ilya Grebnov <ilya.grebnov@gmail.com>

   Licensed under the Apache License, Version 2.0 (the "License");
   you may not use this file except in compliance with the License.
   You may obtain a copy of the License at

       http://www.apache.org/licenses/LICENSE-2.0

   Unless required by applicable law or agreed to in writing, software
   distributed under the License is distributed on an "AS IS" BASIS,
   WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
   See the License for the specific language governing permissions and
   limitations under the License.

   (Full text: src/bwt/LICENSE-libbsc.)

Changes made for PArc (2026-11, by the PArc authors):
  - translated from C++ to C (the RangeCoder class, ProbabilityCounter and
    ProbabilityMixer became plain functions on structs; templates and
    references became parameters and pointers);
  - only the static and the adaptive coders are kept (the "fast" coder, the
    run-time CPU dispatch and the AVX/AVX2/SSE4.1 variants are gone: x86-64
    uses SSE2, AArch64 its NEON/64-bit paths, everything else plain C);
  - the range coder reads and writes its 16-bit words little-endian byte by
    byte (same bytes as libbsc on little-endian machines);
  - the decoders are bounded: the input is read only up to its end (an
    overrun is an error), the decoded size must be the expected one, runs
    never write past the output, the exponent loops stop at the model's size,
    an escape rank of 0 and ranks or runs out of range are errors, and the
    MTF table starts zeroed;
  - no allocation: the caller passes the model and the scratch buffer.
  The coded bytes are those of libbsc's coders for the same input.

--*/

#include <stddef.h>
#include <stdint.h>

#if defined(__GNUC__) || defined(__clang__)
  #define INLINE static __inline__ __attribute__((always_inline))
  #define NOINLINE __attribute__((noinline))
  #define RESTRICT __restrict__
  #define ALIGNED(x) __attribute__((aligned(x)))
  #define bsc_bit_scan_reverse(x)   (__builtin_clz(x) ^ 31)
  #define bsc_bit_scan_forward(x)   (__builtin_ctz(x))
  #define bsc_bit_scan_forward64(x) (__builtin_ctzll(x))
#else
  #error "qlfc.c needs gcc or clang"
#endif

#if defined(__SSE2__) && (defined(__x86_64__) || defined(_M_X64))
  #define QLFC_SSE2 1
  #include <emmintrin.h>
#elif defined(__aarch64__)
  #define QLFC_A64 1
  #include <arm_neon.h>
#endif

#define ALPHABET_SIZE 256

/* qlfc_tables.h declares its helpers "static INLINE int ...": INLINE already says static. */
#undef INLINE
#define INLINE __inline__ __attribute__((always_inline))
#include "qlfc_tables.h"
#undef INLINE
#define INLINE static __inline__ __attribute__((always_inline))

#define QLFC_NOT_COMPRESSIBLE (-1)
#define QLFC_DATA_CORRUPT     (-2)

static inline void q_memset(void * d, int v, size_t n) { unsigned char * p = (unsigned char *)d; while (n--) *p++ = (unsigned char)v; }

INLINE uint64_t q_load64(const unsigned char * p)
{
    uint64_t v; __builtin_memcpy(&v, p, 8); return v;
}

/*---------------------------------------------------------------------------*/
/* Range coder (rangecoder.h)                                                */
/*---------------------------------------------------------------------------*/

typedef struct
{
    uint64_t low;              /* low32 = bits 0..31, carry = bits 32..63 */
    uint32_t code, ffnum, cache, range;
    const unsigned char * in;
    const unsigned char * inEnd;
    int overrun;
    unsigned char * out;
    unsigned char * outEOB;
    unsigned char * outStart;
} RangeCoder;

INLINE void rc_output_short(RangeCoder * c, uint32_t s)
{
    c->out[0] = (unsigned char)s; c->out[1] = (unsigned char)(s >> 8); c->out += 2;
}

INLINE uint32_t rc_input_short(RangeCoder * c)
{
    if (c->in + 2 <= c->inEnd)
    {
        uint32_t s = (uint32_t)c->in[0] | ((uint32_t)c->in[1] << 8); c->in += 2; return s;
    }
    c->overrun = 1; return 0;
}

static NOINLINE uint32_t rc_shift_low_slow(RangeCoder * c)
{
    uint32_t low32 = (uint32_t)c->low, carry = (uint32_t)(c->low >> 32);
    if (low32 < 0xffff0000U || carry)
    {
        rc_output_short(c, c->cache + carry);
        if (c->ffnum)
        {
            uint32_t s = carry - 1;
            do { rc_output_short(c, s); } while (--c->ffnum);
        }
        c->cache = low32 >> 16; carry = 0;
    }
    else c->ffnum++;
    c->low = ((uint64_t)carry << 32) | (uint32_t)(low32 << 16);
    return c->range << 16;
}

static NOINLINE uint32_t rc_shift_low(RangeCoder * c)
{
    uint32_t low32 = (uint32_t)c->low;
    if (!c->ffnum && low32 < 0xffff0000U)
    {
        rc_output_short(c, c->cache + (uint32_t)(c->low >> 32));
        c->cache = low32 >> 16; c->low = (uint32_t)(low32 << 16);
        return c->range << 16;
    }
    return rc_shift_low_slow(c);
}

INLINE int rc_check_eob(const RangeCoder * c)
{
    return c->out + 2 * (size_t)c->ffnum >= c->outEOB;
}

INLINE void rc_init_encoder(RangeCoder * c, unsigned char * output, int outputSize)
{
    c->outStart = output; c->out = output; c->outEOB = output + outputSize - 16;
    c->low = 0; c->ffnum = 0; c->cache = 0; c->range = 0xffffffff;
}

INLINE int rc_finish_encoder(RangeCoder * c)
{
    if (c->range < 0x10000) rc_shift_low(c);
    rc_shift_low(c); rc_shift_low(c); rc_shift_low(c);
    return (int)(c->out - c->outStart);
}

INLINE void rc_encode_bit0(RangeCoder * c, int probability)
{
    if (c->range < 0x10000) c->range = rc_shift_low(c);
    c->range = (c->range >> 12) * (uint32_t)probability;
}

INLINE void rc_encode_bit1(RangeCoder * c, int probability)
{
    if (c->range < 0x10000) c->range = rc_shift_low(c);
    uint32_t r = (c->range >> 12) * (uint32_t)probability;
    c->low += r; c->range -= r;
}

INLINE void rc_encode_bit_p(RangeCoder * c, uint32_t bit, int probability)
{
    if (c->range < 0x10000) c->range = rc_shift_low(c);
    uint32_t r = (c->range >> 12) * (uint32_t)probability;
    c->low   = c->low + ((~bit + 1u) & r);
    c->range = r      + ((~bit + 1u) & (c->range - r - r));
}

INLINE void rc_encode_bit(RangeCoder * c, uint32_t bit)
{
    if (bit) rc_encode_bit1(c, 2048); else rc_encode_bit0(c, 2048);
}

INLINE void rc_encode_word(RangeCoder * c, uint32_t word)
{
    for (int bit = 31; bit >= 0; --bit) rc_encode_bit(c, word & (1u << bit));
}

INLINE void rc_init_decoder(RangeCoder * c, const unsigned char * input, const unsigned char * inputEnd)
{
    c->in = input; c->inEnd = inputEnd; c->overrun = 0;
    c->code = 0; c->range = 0xffffffff;
    c->code = (c->code << 16) | rc_input_short(c);
    c->code = (c->code << 16) | rc_input_short(c);
    c->code = (c->code << 16) | rc_input_short(c);
}

INLINE int rc_peak_bit(RangeCoder * c, int probability)
{
    if (c->range < 0x10000) { c->range <<= 16; c->code = (c->code << 16) | rc_input_short(c); }
    return c->code >= (c->range >> 12) * (uint32_t)probability;
}

INLINE int rc_decode_bit(RangeCoder * c, int probability)
{
    if (c->range < 0x10000) { c->range <<= 16; c->code = (c->code << 16) | rc_input_short(c); }
    uint32_t r = (c->range >> 12) * (uint32_t)probability;
    int bit = c->code >= r;
    c->range = bit ? c->range - r : r;
    c->code  = bit ? c->code  - r : c->code;
    return bit;
}

INLINE uint32_t rc_decode_bit_value(RangeCoder * c, int probability)
{
    if (c->range < 0x10000) { c->range <<= 16; c->code = (c->code << 16) | rc_input_short(c); }
    uint32_t r    = (c->range >> 12) * (uint32_t)probability;
    uint32_t bit  = c->code >= r;
    uint32_t mask = 0 - bit;
    c->code  = c->code - (r & mask);
    c->range = r + ((c->range - r - r) & mask);
    return bit;
}

INLINE void rc_decode_bit0(RangeCoder * c, int probability)
{
    c->range = (c->range >> 12) * (uint32_t)probability;
}

INLINE void rc_decode_bit1(RangeCoder * c, int probability)
{
    uint32_t r = (c->range >> 12) * (uint32_t)probability;
    c->code -= r; c->range -= r;
}

INLINE uint32_t rc_decode_word(RangeCoder * c)
{
    uint32_t word = 0;
    for (int bit = 31; bit >= 0; --bit) word += word + (uint32_t)rc_decode_bit(c, 2048);
    return word;
}

/*---------------------------------------------------------------------------*/
/* Counters and mixer (predictor.h)                                          */
/*---------------------------------------------------------------------------*/

INLINE void pc_update_bit0(short * p, const int threshold, const int adaptationRate)
{
    *p = (short)(*p + (((4096 - threshold - *p) * adaptationRate) >> 12));
}

INLINE void pc_update_bit1(short * p, const int threshold, const int adaptationRate)
{
    *p = (short)(*p - (((*p - threshold) * adaptationRate) >> 12));
}

INLINE void pc_update_bit_tab(short * p, const int * update)
{
    *p = (short)(*p - ((*p * update[0] - update[1]) >> 12));
}

typedef struct
{
    short stretchedProbability0;
    short stretchedProbability1;
    short stretchedProbability2;
    int   mixedProbability;
    int   index;
    short probabilityMap[17];
    int   weight0;
    int   weight1;
    int   weight2;
} ProbabilityMixer;

static void mixer_init(ProbabilityMixer * m)
{
    m->weight0 = m->weight1 = 2048 << 5; m->weight2 = 0;
    for (int p = 0; p < 17; ++p) m->probabilityMap[p] = (short)bsc_squash((p - 8) * 256);
    m->stretchedProbability0 = m->stretchedProbability1 = m->stretchedProbability2 = 0;
    m->mixedProbability = 0; m->index = 0;
}

INLINE short mixer_dot(int s0, int s1, int s2, const ProbabilityMixer * m)
{
    short sp = (short)((int)((unsigned int)s0 * (unsigned int)m->weight0 + (unsigned int)s1 * (unsigned int)m->weight1 + (unsigned int)s2 * (unsigned int)m->weight2) >> 17);
    if (sp < -2047) sp = -2047;
    if (sp >  2047) sp =  2047;
    return sp;
}

INLINE int mixer_mixup(ProbabilityMixer * m, const int probability0, const int probability1, const int probability2)
{
    m->stretchedProbability0 = (short)bsc_stretch(probability0);
    m->stretchedProbability1 = (short)bsc_stretch(probability1);
    m->stretchedProbability2 = (short)bsc_stretch(probability2);

    short sp = mixer_dot(m->stretchedProbability0, m->stretchedProbability1, m->stretchedProbability2, m);

    m->index = (sp + 2048) >> 8;
    const int weight      = sp & 255;
    const int probability = bsc_squash(sp);
    const int mapped      = m->probabilityMap[m->index] + (((m->probabilityMap[m->index + 1] - m->probabilityMap[m->index]) * weight) >> 8);

    return m->mixedProbability = (3 * probability + mapped) >> 2;
}

INLINE int mixer_mixup_update(ProbabilityMixer * m, const int bit, const int probability0, const int probability1, const int probability2,
    const int learningRate0, const int learningRate1, const int learningRate2, const int threshold, const int adaptationRate)
{
    const short s0 = (short)bsc_stretch(probability0);
    const short s1 = (short)bsc_stretch(probability1);
    const short s2 = (short)bsc_stretch(probability2);

    short sp = mixer_dot(s0, s1, s2, m);

    const int weight      = sp & 255;
    const int index       = (sp + 2048) >> 8;
    const int probability = bsc_squash(sp);
    short * e             = &m->probabilityMap[index];
    const int mapped      = e[0] + (((e[1] - e[0]) * weight) >> 8);
    const int mixed       = (3 * probability + mapped) >> 2;

    if (bit) { pc_update_bit1(&e[0], threshold, adaptationRate); pc_update_bit1(&e[1], threshold, adaptationRate); }
    else     { pc_update_bit0(&e[0], threshold, adaptationRate); pc_update_bit0(&e[1], threshold, adaptationRate); }

    const int eps = bit ? mixed - 1 : mixed - 4095;
    m->weight0 -= (learningRate0 * eps * s0) >> 16;
    m->weight1 -= (learningRate1 * eps * s1) >> 16;
    m->weight2 -= (learningRate2 * eps * s2) >> 16;

    return mixed;
}

INLINE void mixer_update(ProbabilityMixer * m, const int bit,
    const int learningRate0, const int learningRate1, const int learningRate2, const int threshold, const int adaptationRate)
{
    short * e = &m->probabilityMap[m->index];
    if (bit) { pc_update_bit1(&e[0], threshold, adaptationRate); pc_update_bit1(&e[1], threshold, adaptationRate); }
    else     { pc_update_bit0(&e[0], threshold, adaptationRate); pc_update_bit0(&e[1], threshold, adaptationRate); }

    const int eps = bit ? m->mixedProbability - 1 : m->mixedProbability - 4095;
    m->weight0 -= (learningRate0 * eps * m->stretchedProbability0) >> 16;
    m->weight1 -= (learningRate1 * eps * m->stretchedProbability1) >> 16;
    m->weight2 -= (learningRate2 * eps * m->stretchedProbability2) >> 16;
}

/*---------------------------------------------------------------------------*/
/* Models (qlfc_model.h)                                                     */
/*---------------------------------------------------------------------------*/

enum {
M_RANK_TS_TH0 =    1, M_RANK_TS_AR0 =   57,
M_RANK_TS_TH1 = -111, M_RANK_TS_AR1 =   31,
M_RANK_TC_TH0 =  291, M_RANK_TC_AR0 =  250,
M_RANK_TC_TH1 =  154, M_RANK_TC_AR1 =  528,
M_RANK_TP_TH0 =  375, M_RANK_TP_AR0 =  163,
M_RANK_TP_TH1 =  313, M_RANK_TP_AR1 =  639,
M_RANK_TM_TH0 =  -41, M_RANK_TM_AR0 =   96,
M_RANK_TM_TH1 =   53, M_RANK_TM_AR1 =   49,
M_RANK_TM_LR0 =   20, M_RANK_TM_LR1 =   47,
M_RANK_TM_LR2 =   27,
M_RANK_ES_TH0 = -137, M_RANK_ES_AR0 =   17,
M_RANK_ES_TH1 =  482, M_RANK_ES_AR1 =   40,
M_RANK_EC_TH0 =   61, M_RANK_EC_AR0 =  192,
M_RANK_EC_TH1 =  200, M_RANK_EC_AR1 =  133,
M_RANK_EP_TH0 =   54, M_RANK_EP_AR0 = 1342,
M_RANK_EP_TH1 =  578, M_RANK_EP_AR1 = 1067,
M_RANK_EM_TH0 =  -11, M_RANK_EM_AR0 =  318,
M_RANK_EM_TH1 =  144, M_RANK_EM_AR1 =  848,
M_RANK_EM_LR0 =   49, M_RANK_EM_LR1 =   41,
M_RANK_EM_LR2 =   40,
M_RANK_MS_TH0 = -145, M_RANK_MS_AR0 =   18,
M_RANK_MS_TH1 =  114, M_RANK_MS_AR1 =   24,
M_RANK_MC_TH0 =  -43, M_RANK_MC_AR0 =   69,
M_RANK_MC_TH1 =  -36, M_RANK_MC_AR1 =   78,
M_RANK_MP_TH0 =   -2, M_RANK_MP_AR0 = 1119,
M_RANK_MP_TH1 =   11, M_RANK_MP_AR1 = 1181,
M_RANK_MM_TH0 = -203, M_RANK_MM_AR0 =   20,
M_RANK_MM_TH1 = -271, M_RANK_MM_AR1 =   15,
M_RANK_MM_LR0 =  263, M_RANK_MM_LR1 =  175,
M_RANK_MM_LR2 =   17,
M_RANK_PS_TH0 =  -99, M_RANK_PS_AR0 =   32,
M_RANK_PS_TH1 =  318, M_RANK_PS_AR1 =   42,
M_RANK_PC_TH0 =   17, M_RANK_PC_AR0 =  101,
M_RANK_PC_TH1 = 1116, M_RANK_PC_AR1 =  246,
M_RANK_PP_TH0 =   22, M_RANK_PP_AR0 =  964,
M_RANK_PP_TH1 =   -2, M_RANK_PP_AR1 = 1110,
M_RANK_PM_TH0 = -194, M_RANK_PM_AR0 =   21,
M_RANK_PM_TH1 = -129, M_RANK_PM_AR1 =   20,
M_RANK_PM_LR0 =  480, M_RANK_PM_LR1 =  202,
M_RANK_PM_LR2 =   17,
M_RUN_TS_TH0 =  -93, M_RUN_TS_AR0 =   34,
M_RUN_TS_TH1 =   -4, M_RUN_TS_AR1 =   51,
M_RUN_TC_TH0 =  139, M_RUN_TC_AR0 =  423,
M_RUN_TC_TH1 =  244, M_RUN_TC_AR1 =  162,
M_RUN_TP_TH0 =  275, M_RUN_TP_AR0 =  450,
M_RUN_TP_TH1 =   -6, M_RUN_TP_AR1 =  579,
M_RUN_TM_TH0 =  -68, M_RUN_TM_AR0 =   25,
M_RUN_TM_TH1 =    1, M_RUN_TM_AR1 =   64,
M_RUN_TM_LR0 =   15, M_RUN_TM_LR1 =   50,
M_RUN_TM_LR2 =   78,
M_RUN_ES_TH0 = -116, M_RUN_ES_AR0 =   31,
M_RUN_ES_TH1 =   43, M_RUN_ES_AR1 =   45,
M_RUN_EC_TH0 =  165, M_RUN_EC_AR0 =  222,
M_RUN_EC_TH1 =   30, M_RUN_EC_AR1 =  324,
M_RUN_EP_TH0 =  315, M_RUN_EP_AR0 =  857,
M_RUN_EP_TH1 =  109, M_RUN_EP_AR1 =  867,
M_RUN_EM_TH0 =  -14, M_RUN_EM_AR0 =  215,
M_RUN_EM_TH1 =   61, M_RUN_EM_AR1 =   73,
M_RUN_EM_LR0 =   35, M_RUN_EM_LR1 =   37,
M_RUN_EM_LR2 =   42,
M_RUN_MS_TH0 = -176, M_RUN_MS_AR0 =   14,
M_RUN_MS_TH1 = -141, M_RUN_MS_AR1 =   21,
M_RUN_MC_TH0 =   84, M_RUN_MC_AR0 =  172,
M_RUN_MC_TH1 =   37, M_RUN_MC_AR1 =  263,
M_RUN_MP_TH0 =    2, M_RUN_MP_AR0 =   15,
M_RUN_MP_TH1 = -197, M_RUN_MP_AR1 =   20,
M_RUN_MM_TH0 =  -27, M_RUN_MM_AR0 =  142,
M_RUN_MM_TH1 = -146, M_RUN_MM_AR1 =   27,
M_RUN_MM_LR0 =   51, M_RUN_MM_LR1 =   44,
M_RUN_MM_LR2 =   80,

F_RANK_TS_TH0 = -116, F_RANK_TS_AR0 =   33,
F_RANK_TS_TH1 =  -78, F_RANK_TS_AR1 =   34,
F_RANK_TC_TH0 =   -2, F_RANK_TC_AR0 =  282,
F_RANK_TC_TH1 =   12, F_RANK_TC_AR1 =  274,
F_RANK_TP_TH0 =    4, F_RANK_TP_AR0 =  697,
F_RANK_TP_TH1 =   55, F_RANK_TP_AR1 = 1185,
F_RANK_TM_LR0 =   17, F_RANK_TM_LR1 =   14,
F_RANK_TM_LR2 =    1,
F_RANK_ES_TH0 = -177, F_RANK_ES_AR0 =   23,
F_RANK_ES_TH1 = -370, F_RANK_ES_AR1 =   11,
F_RANK_EC_TH0 =  -14, F_RANK_EC_AR0 =  271,
F_RANK_EC_TH1 =    3, F_RANK_EC_AR1 =  308,
F_RANK_EP_TH0 =   -3, F_RANK_EP_AR0 =  788,
F_RANK_EP_TH1 =  135, F_RANK_EP_AR1 = 1364,
F_RANK_EM_LR0 =   22, F_RANK_EM_LR1 =    6,
F_RANK_EM_LR2 =    4,
F_RANK_MS_TH0 = -254, F_RANK_MS_AR0 =   16,
F_RANK_MS_TH1 = -177, F_RANK_MS_AR1 =   20,
F_RANK_MC_TH0 =  -55, F_RANK_MC_AR0 =   73,
F_RANK_MC_TH1 =  -54, F_RANK_MC_AR1 =   74,
F_RANK_MP_TH0 =   -6, F_RANK_MP_AR0 =  575,
F_RANK_MP_TH1 = 1670, F_RANK_MP_AR1 = 1173,
F_RANK_MM_LR0 =   15, F_RANK_MM_LR1 =   10,
F_RANK_MM_LR2 =    7,
F_RANK_PS_TH0 = -126, F_RANK_PS_AR0 =   32,
F_RANK_PS_TH1 = -126, F_RANK_PS_AR1 =   32,
F_RANK_PC_TH0 =  -33, F_RANK_PC_AR0 =  120,
F_RANK_PC_TH1 =  -25, F_RANK_PC_AR1 =  157,
F_RANK_PP_TH0 =   -6, F_RANK_PP_AR0 =  585,
F_RANK_PP_TH1 =  150, F_RANK_PP_AR1 =  275,
F_RANK_PM_LR0 =   16, F_RANK_PM_LR1 =   11,
F_RANK_PM_LR2 =    5,
F_RUN_TS_TH0 =  -68, F_RUN_TS_AR0 =   38,
F_RUN_TS_TH1 = -112, F_RUN_TS_AR1 =   36,
F_RUN_TC_TH0 =   -4, F_RUN_TC_AR0 =  221,
F_RUN_TC_TH1 =  -13, F_RUN_TC_AR1 =  231,
F_RUN_TP_TH0 =    0, F_RUN_TP_AR0 =    0,
F_RUN_TP_TH1 =    0, F_RUN_TP_AR1 =    0,
F_RUN_TM_LR0 =   14, F_RUN_TM_LR1 =   18,
F_RUN_TM_LR2 =    0,
F_RUN_ES_TH0 =  -90, F_RUN_ES_AR0 =   45,
F_RUN_ES_TH1 =  -92, F_RUN_ES_AR1 =   44,
F_RUN_EC_TH0 =   -3, F_RUN_EC_AR0 =  325,
F_RUN_EC_TH1 =  -11, F_RUN_EC_AR1 =  341,
F_RUN_EP_TH0 =   24, F_RUN_EP_AR0 =  887,
F_RUN_EP_TH1 =   -4, F_RUN_EP_AR1 =  765,
F_RUN_EM_LR0 =   14, F_RUN_EM_LR1 =   15,
F_RUN_EM_LR2 =    3,
F_RUN_MS_TH0 = -275, F_RUN_MS_AR0 =   14,
F_RUN_MS_TH1 = -185, F_RUN_MS_AR1 =   22,
F_RUN_MC_TH0 =  -18, F_RUN_MC_AR0 =  191,
F_RUN_MC_TH1 =  -15, F_RUN_MC_AR1 =  241,
F_RUN_MP_TH0 =  -73, F_RUN_MP_AR0 =   54,
F_RUN_MP_TH1 = -214, F_RUN_MP_AR1 =   19,
F_RUN_MM_LR0 =    7, F_RUN_MM_LR1 =   15,
F_RUN_MM_LR2 =   10,
F_RANK_P_NEAR = 512,
F_RUN_M_NEAR  = 512
};

static const int F_RANK_M_UPDATE[3][2][2] =
{
    { { F_RANK_MS_AR0, (4096 - F_RANK_MS_TH0) * F_RANK_MS_AR0 - 4095 }, { F_RANK_MS_AR1, F_RANK_MS_TH1 * F_RANK_MS_AR1 } },
    { { F_RANK_MC_AR0, (4096 - F_RANK_MC_TH0) * F_RANK_MC_AR0 - 4095 }, { F_RANK_MC_AR1, F_RANK_MC_TH1 * F_RANK_MC_AR1 } },
    { { F_RANK_MP_AR0, (4096 - F_RANK_MP_TH0) * F_RANK_MP_AR0 - 4095 }, { F_RANK_MP_AR1, F_RANK_MP_TH1 * F_RANK_MP_AR1 } }
};

static const int F_RANK_P_UPDATE[3][2][2] =
{
    { { F_RANK_PS_AR0, (4096 - F_RANK_PS_TH0) * F_RANK_PS_AR0 - 4095 }, { F_RANK_PS_AR1, F_RANK_PS_TH1 * F_RANK_PS_AR1 } },
    { { F_RANK_PC_AR0, (4096 - F_RANK_PC_TH0) * F_RANK_PC_AR0 - 4095 }, { F_RANK_PC_AR1, F_RANK_PC_TH1 * F_RANK_PC_AR1 } },
    { { F_RANK_PP_AR0, (4096 - F_RANK_PP_TH0) * F_RANK_PP_AR0 - 4095 }, { F_RANK_PP_AR1, F_RANK_PP_TH1 * F_RANK_PP_AR1 } }
};

static const int F_RUN_M_UPDATE[3][2][2] =
{
    { { F_RUN_MS_AR0, (4096 - F_RUN_MS_TH0) * F_RUN_MS_AR0 - 4095 }, { F_RUN_MS_AR1, F_RUN_MS_TH1 * F_RUN_MS_AR1 } },
    { { F_RUN_MC_AR0, (4096 - F_RUN_MC_TH0) * F_RUN_MC_AR0 - 4095 }, { F_RUN_MC_AR1, F_RUN_MC_TH1 * F_RUN_MC_AR1 } },
    { { F_RUN_MP_AR0, (4096 - F_RUN_MP_TH0) * F_RUN_MP_AR0 - 4095 }, { F_RUN_MP_AR1, F_RUN_MP_TH1 * F_RUN_MP_AR1 } }
};

#define MANTISSA_ROW_START(bitRankSize) (1 << (bitRankSize))

typedef struct
{
    short StaticModel;
    short StateModel[ALPHABET_SIZE];
    short CharModel[ALPHABET_SIZE];
    struct
    {
        short StaticModel[8];
        short StateModel[ALPHABET_SIZE][8];
        short CharModel[ALPHABET_SIZE][8];
    } Exponent;
    struct
    {
        short StaticModel[256];
        short StateModel[ALPHABET_SIZE][256];
        short CharModel[ALPHABET_SIZE][256];
    } Mantissa;
    struct
    {
        short StaticModel[ALPHABET_SIZE];
        short StateModel[ALPHABET_SIZE][ALPHABET_SIZE];
        short CharModel[ALPHABET_SIZE][ALPHABET_SIZE];
    } Escape;
} QlfcRankModel;

typedef struct
{
    short StaticModel;
    short StateModel[ALPHABET_SIZE];
    short CharModel[ALPHABET_SIZE];
    struct
    {
        short StaticModel[32];
        short StateModel[ALPHABET_SIZE][32];
        short CharModel[ALPHABET_SIZE][32];
    } Exponent;
    struct
    {
        short StaticModel[32];
        short StateModel[ALPHABET_SIZE][32];
        short CharModel[ALPHABET_SIZE][32];
    } Mantissa[32];
} QlfcRunModel;

typedef struct
{
    QlfcRankModel Rank;
    QlfcRunModel  Run;
} QlfcStatisticalModel1;

typedef struct
{
    QlfcRankModel Rank;
    QlfcRunModel  Run;
    ProbabilityMixer mixerOfRank[ALPHABET_SIZE];
    ProbabilityMixer mixerOfRankExponent[8][8];
    ProbabilityMixer mixerOfRankMantissa[8];
    ProbabilityMixer mixerOfRankEscape[ALPHABET_SIZE];
    ProbabilityMixer mixerOfRun[ALPHABET_SIZE];
    ProbabilityMixer mixerOfRunExponent[32][32];
    ProbabilityMixer mixerOfRunMantissa[32];
} QlfcStatisticalModel2;

static void qlfc_fill(void * dst, size_t size, short v)
{
    short * p = (short *)dst; for (size_t i = 0; i < size / 2; ++i) p[i] = v;
}

static NOINLINE void qlfc_init_model1(QlfcStatisticalModel1 * model)
{
    qlfc_fill(&model->Rank, sizeof(model->Rank), 2048);
    qlfc_fill(&model->Run, sizeof(model->Run), 2048);
}

static NOINLINE void qlfc_init_model2(QlfcStatisticalModel2 * model)
{
    qlfc_fill(&model->Rank, sizeof(model->Rank), 2048);
    qlfc_fill(&model->Run, sizeof(model->Run), 2048);
    for (int i = 0; i < ALPHABET_SIZE; ++i)
    {
        mixer_init(&model->mixerOfRank[i]); mixer_init(&model->mixerOfRankEscape[i]); mixer_init(&model->mixerOfRun[i]);
    }
    for (int bit = 0; bit < 8; ++bit)
    {
        mixer_init(&model->mixerOfRankMantissa[bit]);
        for (int context = 0; context < 8; ++context) mixer_init(&model->mixerOfRankExponent[context][bit]);
    }
    for (int bit = 0; bit < 32; ++bit)
    {
        mixer_init(&model->mixerOfRunMantissa[bit]);
        for (int context = 0; context < 32; ++context) mixer_init(&model->mixerOfRunExponent[context][bit]);
    }
}

/*---------------------------------------------------------------------------*/
/* Transform: ranks of the run heads, last to first (qlfc.cpp)               */
/*---------------------------------------------------------------------------*/

#if defined(QLFC_SSE2) || defined(QLFC_A64)

INLINE ptrdiff_t qlfc_transform_scan(const unsigned char * RESTRICT input, ptrdiff_t i, unsigned char currentChar, ptrdiff_t * pw, unsigned long long * pm)
{
    ptrdiff_t w = *pw; unsigned long long m = *pm;
#if defined(QLFC_SSE2)
    while (w >= 0)
    {
        if (m != 0) { int k = bsc_bit_scan_reverse((unsigned int)(m)); m ^= (unsigned long long)1 << k; *pw = w; *pm = m; return w + k; }

        i = w; w -= 16; if (w >= 0) { m = (unsigned long long)(_mm_movemask_epi8(_mm_cmpeq_epi8(_mm_loadu_si128((const __m128i *)(input + w)), _mm_loadu_si128((const __m128i *)(input + w + 1)))) ^ 0xffff); }
    }
#else
    while (w >= 0)
    {
        if (m != 0) { int k = (__builtin_clzll(m) ^ 63) / 8; m &= ((unsigned long long)1 << (8 * k)) - 1; *pw = w; *pm = m; return w + k; }

        i = w; w -= 8; if (w >= 0) { m = q_load64(input + w) ^ q_load64(input + w + 1); }
    }
#endif
    *pw = w; *pm = m;
    do {} while ((--i >= 0) && (input[i] == currentChar)); return i;
}

static unsigned char * qlfc_transform(const unsigned char * RESTRICT input, unsigned char * RESTRICT buffer, int n, unsigned char * RESTRICT MTFTable)
{
    signed char ALIGNED(64) ranks[ALPHABET_SIZE];
    signed char ALIGNED(64) flags[ALPHABET_SIZE];

    for (ptrdiff_t i = 0; i < ALPHABET_SIZE; ++i) { ranks[i] = (signed char)(i - 128); }
    for (ptrdiff_t i = 0; i < ALPHABET_SIZE; ++i) { flags[i] = 0; }

    ptrdiff_t i = (ptrdiff_t)n - 1, j = n; signed char nSymbols = 0;
    ptrdiff_t w = i; unsigned long long m = 0;

    for (; i >= 0; )
    {
        unsigned char currentChar1 = input[i]; i = qlfc_transform_scan(input, i, currentChar1, &w, &m); if (i < 0) { i = 0; break; }
        unsigned char currentChar2 = input[i]; i = qlfc_transform_scan(input, i, currentChar2, &w, &m);

        signed char rank1 = ranks[currentChar1], rank2 = ranks[currentChar2]; rank2 += rank1 > rank2;

        buffer[--j] = (unsigned char)(rank1 + 128); if (flags[currentChar1] == 0) { flags[currentChar1] = 1; buffer[j] = (unsigned char)nSymbols++; }
        buffer[--j] = (unsigned char)(rank2 + 128); if (flags[currentChar2] == 0) { flags[currentChar2] = 1; buffer[j] = (unsigned char)nSymbols++; }

#if defined(QLFC_SSE2)
        {
            __m128i r1 = _mm_set1_epi8(rank1), r2 = _mm_set1_epi8(rank2);
            for (int k = 0; k < 16; k += 2)
            {
                __m128i x = _mm_load_si128((__m128i *)(ranks + 16 * k)), y = _mm_load_si128((__m128i *)(ranks + 16 * (k + 1)));
                x = _mm_sub_epi8(_mm_sub_epi8(x, _mm_cmpgt_epi8(r1, x)), _mm_cmpgt_epi8(r2, x));
                y = _mm_sub_epi8(_mm_sub_epi8(y, _mm_cmpgt_epi8(r1, y)), _mm_cmpgt_epi8(r2, y));
                _mm_store_si128((__m128i *)(ranks + 16 * k), x); _mm_store_si128((__m128i *)(ranks + 16 * (k + 1)), y);
            }
        }
#else
        {
            int8x16_t r1 = vdupq_n_s8(rank1), r2 = vdupq_n_s8(rank2);
            for (int k = 0; k < 16; k += 2)
            {
                int8x16_t x = vld1q_s8((int8_t const *)(ranks + 16 * k)), y = vld1q_s8((int8_t const *)(ranks + 16 * (k + 1)));
                x = vsubq_s8(vsubq_s8(x, vreinterpretq_s8_u8(vcgtq_s8(r1, x))), vreinterpretq_s8_u8(vcgtq_s8(r2, x)));
                y = vsubq_s8(vsubq_s8(y, vreinterpretq_s8_u8(vcgtq_s8(r1, y))), vreinterpretq_s8_u8(vcgtq_s8(r2, y)));
                vst1q_s8((int8_t *)(ranks + 16 * k), x); vst1q_s8((int8_t *)(ranks + 16 * (k + 1)), y);
            }
        }
#endif

        ranks[currentChar1] = -127; ranks[currentChar2] = -128;
    }

    if (i >= 0)
    {
        unsigned char currentChar = input[0]; signed char rank = ranks[currentChar];

        buffer[--j] = (unsigned char)(rank + 128); if (flags[currentChar] == 0) { flags[currentChar] = 1; buffer[j] = (unsigned char)nSymbols++; }

        for (int t = 0; t < 256; ++t) { ranks[t] -= (ranks[t] < rank ? -1 : 0); }

        ranks[currentChar] = -128;
    }

    buffer[n - 1] = 1;

    for (ptrdiff_t k = 0; k < ALPHABET_SIZE; ++k) { MTFTable[ranks[k] + 128] = (unsigned char)k; }
    for (ptrdiff_t k = 1; k < ALPHABET_SIZE; ++k) { if (flags[MTFTable[k]] == 0) { MTFTable[k] = MTFTable[k - 1]; break; } }

    return buffer + j;
}

#else

static unsigned char * qlfc_transform(const unsigned char * RESTRICT input, unsigned char * RESTRICT buffer, int n, unsigned char * RESTRICT MTFTable)
{
    unsigned char Flag[ALPHABET_SIZE];

    for (int i = 0; i < ALPHABET_SIZE; ++i) Flag[i] = 0;
    for (int i = 0; i < ALPHABET_SIZE; ++i) MTFTable[i] = (unsigned char)i;

    if (input[n - 1] == 0)
    {
        MTFTable[0] = 1; MTFTable[1] = 0;
    }

    int index = n, nSymbols = 0;
    for (int i = n - 1; i >= 0;)
    {
        unsigned char currentChar = input[i--];
        for (; (i >= 0) && (input[i] == currentChar); --i) ;

        unsigned char previousChar = MTFTable[0], rank = 1; MTFTable[0] = currentChar;
        while (1)
        {
            unsigned char temporaryChar0 = MTFTable[rank + 0]; MTFTable[rank + 0] = previousChar;
            if (temporaryChar0 == currentChar) { rank += 0; break; }

            unsigned char temporaryChar1 = MTFTable[rank + 1]; MTFTable[rank + 1] = temporaryChar0;
            if (temporaryChar1 == currentChar) { rank += 1; break; }

            unsigned char temporaryChar2 = MTFTable[rank + 2]; MTFTable[rank + 2] = temporaryChar1;
            if (temporaryChar2 == currentChar) { rank += 2; break; }

            unsigned char temporaryChar3 = MTFTable[rank + 3]; MTFTable[rank + 3] = temporaryChar2;
            if (temporaryChar3 == currentChar) { rank += 3; break; }

            rank += 4; previousChar = temporaryChar3;
        }

        if (Flag[currentChar] == 0)
        {
            Flag[currentChar] = 1;
            rank = (unsigned char)nSymbols++;
        }

        buffer[--index] = rank;
    }

    buffer[n - 1] = 1;

    for (int rank = 1; rank < ALPHABET_SIZE; ++rank)
    {
        if (Flag[MTFTable[rank]] == 0)
        {
            MTFTable[rank] = MTFTable[rank - 1];
            break;
        }
    }

    return buffer + index;
}

#endif

/* The alphabet in MTF order, coded bit by bit with only the bits that can still differ. Returns maxRank. */
static int qlfc_encode_alphabet(RangeCoder * coder, const unsigned char * MTFTable)
{
    unsigned char usedChar[ALPHABET_SIZE];
    for (int i = 0; i < ALPHABET_SIZE; ++i) usedChar[i] = 0;

    int maxRank = 7, prevChar = -1;
    for (int rank = 0; rank < ALPHABET_SIZE; ++rank)
    {
        int currentChar = MTFTable[rank];

        for (int bit = 7; bit >= 0; --bit)
        {
            int bit0 = 0, bit1 = 0;

            for (int c = (currentChar >> (bit + 1)) << (bit + 1); c < ((currentChar >> (bit + 1)) + 1) << (bit + 1); ++c)
            {
                if (c == prevChar || usedChar[c] == 0)
                {
                    if (c & (1 << bit)) bit1 = 1; else bit0 = 1;
                    if (bit0 && bit1) break;
                }
            }

            if (bit0 && bit1)
            {
                rc_encode_bit(coder, currentChar & (1 << bit));
            }
        }

        if (currentChar == prevChar)
        {
            maxRank = rank > 1 ? bsc_bit_scan_reverse(rank - 1) : 0;
            break;
        }

        prevChar = currentChar; usedChar[currentChar] = 1;
    }
    return maxRank;
}

static int qlfc_decode_alphabet(RangeCoder * coder, unsigned char * MTFTable)
{
    unsigned char usedChar[ALPHABET_SIZE];
    for (int i = 0; i < ALPHABET_SIZE; ++i) usedChar[i] = 0;

    int maxRank = 7, prevChar = -1;
    for (int rank = 0; rank < ALPHABET_SIZE; ++rank)
    {
        int currentChar = 0;

        for (int bit = 7; bit >= 0; --bit)
        {
            int bit0 = 0, bit1 = 0;

            for (int c = currentChar << (bit + 1); c < (currentChar + 1) << (bit + 1); ++c)
            {
                if (c == prevChar || usedChar[c] == 0)
                {
                    if (c & (1 << bit)) bit1 = 1; else bit0 = 1;
                    if (bit0 && bit1) break;
                }
            }

            if (bit0 && bit1)
            {
                currentChar += currentChar + rc_decode_bit(coder, 2048);
            }
            else
            {
                if (bit0) currentChar += currentChar + 0;
                if (bit1) currentChar += currentChar + 1;
            }
        }

        MTFTable[rank] = (unsigned char)currentChar;

        if (currentChar == prevChar)
        {
            maxRank = rank > 1 ? bsc_bit_scan_reverse(rank - 1) : 0;
            break;
        }

        prevChar = currentChar; usedChar[currentChar] = 1;
    }
    return maxRank;
}

/* Length of the run that starts at input (encoders). */
#define QLFC_SCAN_RUN()                                                                                             \
    int currentChar = *input, runSize;                                                                              \
    {                                                                                                               \
        const unsigned char * inputStart = input++;                                                                 \
        if (rankArray < rankArrayTail)                                                                              \
        {                                                                                                           \
            QLFC_SCAN_FAST();                                                                                       \
        }                                                                                                           \
        else                                                                                                        \
        {                                                                                                           \
            if (input < inputTail) { input = inputTail; }                                                           \
            while ((input < inputEnd) && (*input == currentChar)) { input++; }                                      \
        }                                                                                                           \
        runSize = (int)(input - inputStart);                                                                        \
    }

#if defined(QLFC_SSE2)
  #define QLFC_SCAN_FAST()                                                                                          \
    __m128i v = _mm_set1_epi8((char)currentChar);                                                                   \
    while (1)                                                                                                       \
    {                                                                                                               \
        int mm = _mm_movemask_epi8(_mm_cmpeq_epi8(_mm_loadu_si128((const __m128i *)input), v)) ^ 0xffff;           \
        if (mm != 0) { input += bsc_bit_scan_forward((unsigned int)(mm)); break; }                                  \
        input += 16;                                                                                                \
    }
#elif defined(QLFC_A64)
  #define QLFC_SCAN_FAST()                                                                                          \
    unsigned long long v = (unsigned long long)currentChar; v |= (v << 8); v |= (v << 16); v |= (v << 32);          \
    while (1)                                                                                                       \
    {                                                                                                               \
        unsigned long long mm = q_load64(input) ^ v;                                                                \
        if (mm != 0) { input += bsc_bit_scan_forward64(mm) / 8; break; }                                            \
        input += 8;                                                                                                 \
    }
#else
  #define QLFC_SCAN_FAST() while (*input == currentChar) { input++; }
#endif

#define QLFC_ENCODE_PROLOGUE()                                                                                      \
    const unsigned char * inputEnd      = input  + inputSize;                                                       \
    const unsigned char * rankArrayEnd  = buffer + inputSize;                                                       \
    const unsigned char * inputTail     = inputEnd;                                                                 \
    const unsigned char * rankArrayTail = rankArrayEnd - 1;                                                         \
    for (const unsigned char * p = inputEnd - 1; (p > input) && (inputEnd - p < 16); --p)                          \
    {                                                                                                               \
        if (p[0] != p[-1]) { inputTail = p; rankArrayTail--; }                                                      \
    }

/*---------------------------------------------------------------------------*/
/* Adaptive coder                                                            */
/*---------------------------------------------------------------------------*/

#define MIX_ENC(bit, P0, P1, P2, PFX)                                                                                   \
    do {                                                                                                                \
        int probability0 = (P0), probability1 = (P1), probability2 = (P2);                                              \
        if (bit)                                                                                                        \
        {                                                                                                               \
            pc_update_bit1(sp_,  PFX##S_TH1, PFX##S_AR1);                                                               \
            pc_update_bit1(cp_,  PFX##C_TH1, PFX##C_AR1);                                                               \
            pc_update_bit1(tp_,  PFX##P_TH1, PFX##P_AR1);                                                               \
            rc_encode_bit1(&coder, mixer_mixup_update(mixer, 1, probability0, probability1, probability2,              \
                PFX##M_LR0, PFX##M_LR1, PFX##M_LR2, PFX##M_TH1, PFX##M_AR1));                                           \
        }                                                                                                               \
        else                                                                                                            \
        {                                                                                                               \
            pc_update_bit0(sp_,  PFX##S_TH0, PFX##S_AR0);                                                               \
            pc_update_bit0(cp_,  PFX##C_TH0, PFX##C_AR0);                                                               \
            pc_update_bit0(tp_,  PFX##P_TH0, PFX##P_AR0);                                                               \
            rc_encode_bit0(&coder, mixer_mixup_update(mixer, 0, probability0, probability1, probability2,              \
                PFX##M_LR0, PFX##M_LR1, PFX##M_LR2, PFX##M_TH0, PFX##M_AR0));                                           \
        }                                                                                                               \
    } while (0)

static int qlfc_adaptive_encode(const unsigned char * input, unsigned char * output, unsigned char * buffer, int inputSize, int outputSize, QlfcStatisticalModel2 * model)
{
    unsigned char MTFTable[ALPHABET_SIZE];

    qlfc_init_model2(model);

    int contextRank0 = 0;
    int contextRank4 = 0;
    int contextRun   = 0;
    int maxRank      = 7;
    int avgRank      = 0;

    unsigned char rankHistory[ALPHABET_SIZE], runHistory[ALPHABET_SIZE];
    for (int i = 0; i < ALPHABET_SIZE; ++i) rankHistory[i] = runHistory[i] = 0;

    unsigned char * rankArray = qlfc_transform(input, buffer, inputSize, MTFTable);

    RangeCoder coder;
    rc_init_encoder(&coder, output, outputSize);
    rc_encode_word(&coder, (uint32_t)inputSize);

    maxRank = qlfc_encode_alphabet(&coder, MTFTable);

    QLFC_ENCODE_PROLOGUE();

    for (; rankArray < rankArrayEnd; )
    {
        if (rc_check_eob(&coder)) return QLFC_NOT_COMPRESSIBLE;

        QLFC_SCAN_RUN();

        int rank    = *rankArray++;
        int history = rankHistory[currentChar];
        int state   = model_rank_state(contextRank4, contextRun, history);

        short * RESTRICT statePredictor  = &model->Rank.StateModel[state];
        short * RESTRICT charPredictor   = &model->Rank.CharModel[currentChar];
        short * RESTRICT staticPredictor = &model->Rank.StaticModel;
        ProbabilityMixer * RESTRICT mixer = &model->mixerOfRank[currentChar];
        short * sp_; short * cp_; short * tp_;

        if (avgRank < 32)
        {
            if (rank == 1)
            {
                rankHistory[currentChar] = 0;
                sp_ = statePredictor; cp_ = charPredictor; tp_ = staticPredictor;
                MIX_ENC(0, *charPredictor, *statePredictor, *staticPredictor, M_RANK_T);
            }
            else
            {
                sp_ = statePredictor; cp_ = charPredictor; tp_ = staticPredictor;
                MIX_ENC(1, *charPredictor, *statePredictor, *staticPredictor, M_RANK_T);

                int bitRankSize = bsc_bit_scan_reverse((unsigned int)rank); rankHistory[currentChar] = (unsigned char)bitRankSize;

                statePredictor  = &model->Rank.Exponent.StateModel[state][0];
                charPredictor   = &model->Rank.Exponent.CharModel[currentChar][0];
                staticPredictor = &model->Rank.Exponent.StaticModel[0];
                mixer           = &model->mixerOfRankExponent[history < 1 ? 1 : history][1];

                for (int bit = 1; bit < bitRankSize; ++bit, ++statePredictor, ++charPredictor, ++staticPredictor)
                {
                    sp_ = statePredictor; cp_ = charPredictor; tp_ = staticPredictor;
                    MIX_ENC(1, *charPredictor, *statePredictor, *staticPredictor, M_RANK_E);
                    mixer = &model->mixerOfRankExponent[history <= bit ? bit + 1 : history][bit + 1];
                }
                if (bitRankSize < maxRank)
                {
                    sp_ = statePredictor; cp_ = charPredictor; tp_ = staticPredictor;
                    MIX_ENC(0, *charPredictor, *statePredictor, *staticPredictor, M_RANK_E);
                }

                statePredictor  = &model->Rank.Mantissa.StateModel[state][MANTISSA_ROW_START(bitRankSize)];
                charPredictor   = &model->Rank.Mantissa.CharModel[currentChar][MANTISSA_ROW_START(bitRankSize)];
                staticPredictor = &model->Rank.Mantissa.StaticModel[MANTISSA_ROW_START(bitRankSize)];
                mixer           = &model->mixerOfRankMantissa[bitRankSize];

                for (int context = 1, bit = bitRankSize - 1; bit >= 0; --bit)
                {
                    int b = (rank >> bit) & 1;
                    sp_ = &statePredictor[context]; cp_ = &charPredictor[context]; tp_ = &staticPredictor[context];
                    MIX_ENC(b, charPredictor[context], statePredictor[context], staticPredictor[context], M_RANK_M);
                    context += context + b;
                }
            }
        }
        else
        {
            rankHistory[currentChar] = (unsigned char)bsc_bit_scan_reverse((unsigned int)rank);

            statePredictor  = &model->Rank.Escape.StateModel[state][0];
            charPredictor   = &model->Rank.Escape.CharModel[currentChar][0];
            staticPredictor = &model->Rank.Escape.StaticModel[0];

            for (int context = 1, bit = maxRank; bit >= 0; --bit)
            {
                int b = (rank >> bit) & 1;
                mixer = &model->mixerOfRankEscape[context];
                sp_ = &statePredictor[context]; cp_ = &charPredictor[context]; tp_ = &staticPredictor[context];
                MIX_ENC(b, charPredictor[context], statePredictor[context], staticPredictor[context], M_RANK_P);
                context += context + b;
            }
        }

        avgRank         =  (avgRank * 124 + rank * 4) >> 7;
        rank            =  rank - 1;
        history         =  runHistory[currentChar];
        state           =  model_run_state(contextRank0, contextRun, rank, history);
        statePredictor  = &model->Run.StateModel[state];
        charPredictor   = &model->Run.CharModel[currentChar];
        staticPredictor = &model->Run.StaticModel;
        mixer           = &model->mixerOfRun[currentChar];

        if (runSize == 1)
        {
            runHistory[currentChar] = (unsigned char)((runHistory[currentChar] + 2) >> 2);
            sp_ = statePredictor; cp_ = charPredictor; tp_ = staticPredictor;
            MIX_ENC(0, *charPredictor, *statePredictor, *staticPredictor, M_RUN_T);
        }
        else
        {
            sp_ = statePredictor; cp_ = charPredictor; tp_ = staticPredictor;
            MIX_ENC(1, *charPredictor, *statePredictor, *staticPredictor, M_RUN_T);

            int bitRunSize = bsc_bit_scan_reverse((unsigned int)runSize); runHistory[currentChar] = (unsigned char)((runHistory[currentChar] + 3 * bitRunSize + 3) >> 2);

            statePredictor  = &model->Run.Exponent.StateModel[state][0];
            charPredictor   = &model->Run.Exponent.CharModel[currentChar][0];
            staticPredictor = &model->Run.Exponent.StaticModel[0];
            mixer           = &model->mixerOfRunExponent[history < 1 ? 1 : history][1];

            for (int bit = 1; bit < bitRunSize; ++bit, ++statePredictor, ++charPredictor, ++staticPredictor)
            {
                sp_ = statePredictor; cp_ = charPredictor; tp_ = staticPredictor;
                MIX_ENC(1, *charPredictor, *statePredictor, *staticPredictor, M_RUN_E);
                mixer = &model->mixerOfRunExponent[history <= bit ? bit + 1 : history][bit + 1];
            }
            {
                sp_ = statePredictor; cp_ = charPredictor; tp_ = staticPredictor;
                MIX_ENC(0, *charPredictor, *statePredictor, *staticPredictor, M_RUN_E);
            }

            statePredictor  = &model->Run.Mantissa[bitRunSize].StateModel[state][0];
            charPredictor   = &model->Run.Mantissa[bitRunSize].CharModel[currentChar][0];
            staticPredictor = &model->Run.Mantissa[bitRunSize].StaticModel[0];
            mixer           = &model->mixerOfRunMantissa[bitRunSize];

            for (int context = 1, bit = bitRunSize - 1; bit >= 0; --bit)
            {
                int b = (runSize >> bit) & 1;
                sp_ = &statePredictor[context]; cp_ = &charPredictor[context]; tp_ = &staticPredictor[context];
                MIX_ENC(b, charPredictor[context], statePredictor[context], staticPredictor[context], M_RUN_M);
                if (bitRunSize <= 5) context += context + b; else context++;
            }
        }

        contextRank0 = ((contextRank0 << 1) | (rank == 0   ? 1    : 0)) & 0x7;
        contextRank4 = ((contextRank4 << 2) | (rank < 3    ? rank : 3)) & 0xff;
        contextRun   = ((contextRun   << 1) | (runSize < 3 ? 1    : 0)) & 0xf;
    }

    return rc_finish_encoder(&coder);
}

/* MTF: move the symbol at rank to the front (decoders). */
INLINE void qlfc_mtf_update(unsigned char * MTFTable, int rank, int currentChar)
{
    for (int r = 0; r < rank; ++r) MTFTable[r] = MTFTable[r + 1];
    MTFTable[rank] = (unsigned char)currentChar;
}

INLINE void qlfc_put_run(unsigned char * output, int i, int n, int currentChar, int runSize)
{
#if defined(QLFC_SSE2)
    if (runSize <= 16 && i <= n - 16) { _mm_storeu_si128((__m128i *)(output + i), _mm_set1_epi8((char)currentChar)); return; }
#elif defined(QLFC_A64)
    if (runSize <= 16 && i <= n - 16) { vst1q_u8(output + i, vdupq_n_u8((unsigned char)currentChar)); return; }
#endif
    q_memset(output + i, currentChar, (size_t)runSize);
}

#define MIX_DEC_UPDATE(bit, PFX)                                                                                        \
    do {                                                                                                                \
        if (bit)                                                                                                        \
        {                                                                                                               \
            pc_update_bit1(sp_, PFX##S_TH1, PFX##S_AR1);                                                                \
            pc_update_bit1(cp_, PFX##C_TH1, PFX##C_AR1);                                                                \
            pc_update_bit1(tp_, PFX##P_TH1, PFX##P_AR1);                                                                \
            mixer_update(mixer, 1, PFX##M_LR0, PFX##M_LR1, PFX##M_LR2, PFX##M_TH1, PFX##M_AR1);                         \
        }                                                                                                               \
        else                                                                                                            \
        {                                                                                                               \
            pc_update_bit0(sp_, PFX##S_TH0, PFX##S_AR0);                                                                \
            pc_update_bit0(cp_, PFX##C_TH0, PFX##C_AR0);                                                                \
            pc_update_bit0(tp_, PFX##P_TH0, PFX##P_AR0);                                                                \
            mixer_update(mixer, 0, PFX##M_LR0, PFX##M_LR1, PFX##M_LR2, PFX##M_TH0, PFX##M_AR0);                         \
        }                                                                                                               \
    } while (0)

static int qlfc_adaptive_decode(const unsigned char * input, const unsigned char * inputEnd, unsigned char * output, int n, QlfcStatisticalModel2 * model)
{
    RangeCoder coder;

    unsigned char ALIGNED(64) MTFTable[ALPHABET_SIZE];
    for (int i = 0; i < ALPHABET_SIZE; ++i) MTFTable[i] = 0;

    qlfc_init_model2(model);

    int contextRank0 = 0;
    int contextRank4 = 0;
    int contextRun   = 0;
    int maxRank      = 7;
    int avgRank      = 0;

    unsigned char rankHistory[ALPHABET_SIZE], runHistory[ALPHABET_SIZE];
    for (int i = 0; i < ALPHABET_SIZE; ++i) rankHistory[i] = runHistory[i] = 0;

    rc_init_decoder(&coder, input, inputEnd);
    if ((int)rc_decode_word(&coder) != n) return QLFC_DATA_CORRUPT;

    maxRank = qlfc_decode_alphabet(&coder, MTFTable);

    for (int i = 0; i < n;)
    {
        int currentChar = MTFTable[0];
        int history     = rankHistory[currentChar];
        int state       = model_rank_state(contextRank4, contextRun, history);

        short * RESTRICT statePredictor  = &model->Rank.StateModel[state];
        short * RESTRICT charPredictor   = &model->Rank.CharModel[currentChar];
        short * RESTRICT staticPredictor = &model->Rank.StaticModel;
        ProbabilityMixer * RESTRICT mixer = &model->mixerOfRank[currentChar];
        short * sp_; short * cp_; short * tp_;

        int rank = 1;
        if (avgRank < 32)
        {
            sp_ = statePredictor; cp_ = charPredictor; tp_ = staticPredictor;
            if (rc_decode_bit(&coder, mixer_mixup(mixer, *charPredictor, *statePredictor, *staticPredictor)))
            {
                MIX_DEC_UPDATE(1, M_RANK_T);

                statePredictor  = &model->Rank.Exponent.StateModel[state][0];
                charPredictor   = &model->Rank.Exponent.CharModel[currentChar][0];
                staticPredictor = &model->Rank.Exponent.StaticModel[0];
                mixer           = &model->mixerOfRankExponent[history < 1 ? 1 : history][1];

                int bitRankSize = 1;
                while (1)
                {
                    if (bitRankSize >= maxRank) break;
                    sp_ = statePredictor; cp_ = charPredictor; tp_ = staticPredictor;
                    int probability = mixer_mixup(mixer, *charPredictor, *statePredictor, *staticPredictor);
                    if (rc_peak_bit(&coder, probability))
                    {
                        MIX_DEC_UPDATE(1, M_RANK_E);
                        statePredictor++; charPredictor++; staticPredictor++;
                        bitRankSize++;
                        mixer = &model->mixerOfRankExponent[history < bitRankSize ? bitRankSize : history][bitRankSize];
                        rc_decode_bit1(&coder, probability);
                    }
                    else
                    {
                        MIX_DEC_UPDATE(0, M_RANK_E);
                        rc_decode_bit0(&coder, probability);
                        break;
                    }
                }

                rankHistory[currentChar] = (unsigned char)bitRankSize;

                statePredictor  = &model->Rank.Mantissa.StateModel[state][MANTISSA_ROW_START(bitRankSize)];
                charPredictor   = &model->Rank.Mantissa.CharModel[currentChar][MANTISSA_ROW_START(bitRankSize)];
                staticPredictor = &model->Rank.Mantissa.StaticModel[MANTISSA_ROW_START(bitRankSize)];
                mixer           = &model->mixerOfRankMantissa[bitRankSize];

                for (int bit = bitRankSize - 1; bit >= 0; --bit)
                {
                    sp_ = &statePredictor[rank]; cp_ = &charPredictor[rank]; tp_ = &staticPredictor[rank];
                    if (rc_decode_bit(&coder, mixer_mixup(mixer, charPredictor[rank], statePredictor[rank], staticPredictor[rank])))
                    {
                        MIX_DEC_UPDATE(1, M_RANK_M);
                        rank += rank + 1;
                    }
                    else
                    {
                        MIX_DEC_UPDATE(0, M_RANK_M);
                        rank += rank;
                    }
                }
            }
            else
            {
                rankHistory[currentChar] = 0;
                MIX_DEC_UPDATE(0, M_RANK_T);
            }
        }
        else
        {
            statePredictor  = &model->Rank.Escape.StateModel[state][0];
            charPredictor   = &model->Rank.Escape.CharModel[currentChar][0];
            staticPredictor = &model->Rank.Escape.StaticModel[0];

            rank = 0;
            size_t context = 1;
            for (int bit = maxRank; bit >= 0; --bit)
            {
                mixer = &model->mixerOfRankEscape[context];
                sp_ = &statePredictor[context]; cp_ = &charPredictor[context]; tp_ = &staticPredictor[context];

                if (rc_decode_bit(&coder, mixer_mixup(mixer, charPredictor[context], statePredictor[context], staticPredictor[context])))
                {
                    MIX_DEC_UPDATE(1, M_RANK_P);
                    context += context + 1; rank += rank + 1;
                }
                else
                {
                    MIX_DEC_UPDATE(0, M_RANK_P);
                    context += context; rank += rank;
                }
            }

            if (rank == 0) return QLFC_DATA_CORRUPT;
            rankHistory[currentChar] = (unsigned char)bsc_bit_scan_reverse((unsigned int)rank);
        }

        if (rank > 255) return QLFC_DATA_CORRUPT;
        qlfc_mtf_update(MTFTable, rank, currentChar);

        avgRank         =  (avgRank * 124 + rank * 4) >> 7;
        rank            =  rank - 1;
        history         =  runHistory[currentChar];
        state           =  model_run_state(contextRank0, contextRun, rank, history);
        statePredictor  = &model->Run.StateModel[state];
        charPredictor   = &model->Run.CharModel[currentChar];
        staticPredictor = &model->Run.StaticModel;
        mixer           = &model->mixerOfRun[currentChar];

        sp_ = statePredictor; cp_ = charPredictor; tp_ = staticPredictor;
        if (rc_decode_bit(&coder, mixer_mixup(mixer, *charPredictor, *statePredictor, *staticPredictor)))
        {
            MIX_DEC_UPDATE(1, M_RUN_T);

            statePredictor  = &model->Run.Exponent.StateModel[state][0];
            charPredictor   = &model->Run.Exponent.CharModel[currentChar][0];
            staticPredictor = &model->Run.Exponent.StaticModel[0];
            mixer           = &model->mixerOfRunExponent[history < 1 ? 1 : history][1];

            int runSize = 1, bitRunSize = 1;
            while (1)
            {
                sp_ = statePredictor; cp_ = charPredictor; tp_ = staticPredictor;
                int probability = mixer_mixup(mixer, *charPredictor, *statePredictor, *staticPredictor);
                if (rc_peak_bit(&coder, probability))
                {
                    MIX_DEC_UPDATE(1, M_RUN_E);
                    statePredictor++; charPredictor++; staticPredictor++;
                    bitRunSize++;
                    if (bitRunSize > 30) return QLFC_DATA_CORRUPT;
                    mixer = &model->mixerOfRunExponent[history < bitRunSize ? bitRunSize : history][bitRunSize];
                    rc_decode_bit1(&coder, probability);
                }
                else
                {
                    MIX_DEC_UPDATE(0, M_RUN_E);
                    rc_decode_bit0(&coder, probability);
                    break;
                }
            }

            runHistory[currentChar] = (unsigned char)((runHistory[currentChar] + 3 * bitRunSize + 3) >> 2);

            statePredictor  = &model->Run.Mantissa[bitRunSize].StateModel[state][0];
            charPredictor   = &model->Run.Mantissa[bitRunSize].CharModel[currentChar][0];
            staticPredictor = &model->Run.Mantissa[bitRunSize].StaticModel[0];
            mixer           = &model->mixerOfRunMantissa[bitRunSize];

            for (int context = 1, bit = bitRunSize - 1; bit >= 0; --bit)
            {
                sp_ = &statePredictor[context]; cp_ = &charPredictor[context]; tp_ = &staticPredictor[context];
                if (rc_decode_bit(&coder, mixer_mixup(mixer, charPredictor[context], statePredictor[context], staticPredictor[context])))
                {
                    MIX_DEC_UPDATE(1, M_RUN_M);
                    runSize += runSize + 1; if (bitRunSize <= 5) context += context + 1; else context++;
                }
                else
                {
                    MIX_DEC_UPDATE(0, M_RUN_M);
                    runSize += runSize; if (bitRunSize <= 5) context += context; else context++;
                }
            }

            contextRank0 = ((contextRank0 << 1) | (rank == 0   ? 1    : 0)) & 0x7;
            contextRank4 = ((contextRank4 << 2) | (rank < 3    ? rank : 3)) & 0xff;
            contextRun   = ((contextRun   << 1) | (runSize < 3 ? 1    : 0)) & 0xf;

            if (runSize > n - i) return QLFC_DATA_CORRUPT;
            qlfc_put_run(output, i, n, currentChar, runSize); i += runSize;
        }
        else
        {
            runHistory[currentChar] = (unsigned char)((runHistory[currentChar] + 2) >> 2);
            MIX_DEC_UPDATE(0, M_RUN_T);

            contextRank0 = ((contextRank0 << 1) | (rank == 0   ? 1    : 0)) & 0x7;
            contextRank4 = ((contextRank4 << 2) | (rank < 3    ? rank : 3)) & 0xff;
            contextRun   = ((contextRun   << 1) | (                     1)) & 0xf;

            output[i++] = (unsigned char)currentChar;
        }
    }

    return coder.overrun ? QLFC_DATA_CORRUPT : n;
}

/*---------------------------------------------------------------------------*/
/* Static coder                                                              */
/*---------------------------------------------------------------------------*/

#define ST_P(LR, c, s, t) (((c) * LR##0 + (s) * LR##1 + (t) * LR##2) >> 5)

static int qlfc_static_encode(const unsigned char * input, unsigned char * output, unsigned char * buffer, int inputSize, int outputSize, QlfcStatisticalModel1 * model)
{
    unsigned char MTFTable[ALPHABET_SIZE];

    qlfc_init_model1(model);

    int contextRank0 = 0;
    int contextRank4 = 0;
    int contextRun   = 0;
    int maxRank      = 7;
    int avgRank      = 0;

    unsigned char rankHistory[ALPHABET_SIZE], runHistory[ALPHABET_SIZE];
    for (int i = 0; i < ALPHABET_SIZE; ++i) rankHistory[i] = runHistory[i] = 0;

    unsigned char * rankArray = qlfc_transform(input, buffer, inputSize, MTFTable);

    RangeCoder coder;
    rc_init_encoder(&coder, output, outputSize);
    rc_encode_word(&coder, (uint32_t)inputSize);

    maxRank = qlfc_encode_alphabet(&coder, MTFTable);

    QLFC_ENCODE_PROLOGUE();

    for (; rankArray < rankArrayEnd; )
    {
        if (rc_check_eob(&coder)) return QLFC_NOT_COMPRESSIBLE;

        QLFC_SCAN_RUN();

        int rank    = *rankArray++;
        int history = rankHistory[currentChar];
        int state   = model_rank_state(contextRank4, contextRun, history);

        short * RESTRICT statePredictor  = &model->Rank.StateModel[state];
        short * RESTRICT charPredictor   = &model->Rank.CharModel[currentChar];
        short * RESTRICT staticPredictor = &model->Rank.StaticModel;

        if (avgRank < 32)
        {
            if (rank == 1)
            {
                rankHistory[currentChar] = 0;

                int probability = ST_P(F_RANK_TM_LR, *charPredictor, *statePredictor, *staticPredictor);

                pc_update_bit0(statePredictor,  F_RANK_TS_TH0, F_RANK_TS_AR0);
                pc_update_bit0(charPredictor,   F_RANK_TC_TH0, F_RANK_TC_AR0);
                pc_update_bit0(staticPredictor, F_RANK_TP_TH0, F_RANK_TP_AR0);

                rc_encode_bit0(&coder, probability);
            }
            else
            {
                {
                    int probability = ST_P(F_RANK_TM_LR, *charPredictor, *statePredictor, *staticPredictor);

                    pc_update_bit1(statePredictor,  F_RANK_TS_TH1, F_RANK_TS_AR1);
                    pc_update_bit1(charPredictor,   F_RANK_TC_TH1, F_RANK_TC_AR1);
                    pc_update_bit1(staticPredictor, F_RANK_TP_TH1, F_RANK_TP_AR1);

                    rc_encode_bit1(&coder, probability);
                }

                int bitRankSize = bsc_bit_scan_reverse((unsigned int)rank); rankHistory[currentChar] = (unsigned char)bitRankSize;

                statePredictor  = &model->Rank.Exponent.StateModel[state][0];
                charPredictor   = &model->Rank.Exponent.CharModel[currentChar][0];
                staticPredictor = &model->Rank.Exponent.StaticModel[0];

                for (int bit = 1; bit < bitRankSize; ++bit, ++statePredictor, ++charPredictor, ++staticPredictor)
                {
                    int probability = ST_P(F_RANK_EM_LR, *charPredictor, *statePredictor, *staticPredictor);

                    pc_update_bit1(statePredictor,  F_RANK_ES_TH1, F_RANK_ES_AR1);
                    pc_update_bit1(charPredictor,   F_RANK_EC_TH1, F_RANK_EC_AR1);
                    pc_update_bit1(staticPredictor, F_RANK_EP_TH1, F_RANK_EP_AR1);

                    rc_encode_bit1(&coder, probability);
                }
                if (bitRankSize < maxRank)
                {
                    int probability = ST_P(F_RANK_EM_LR, *charPredictor, *statePredictor, *staticPredictor);

                    pc_update_bit0(statePredictor,  F_RANK_ES_TH0, F_RANK_ES_AR0);
                    pc_update_bit0(charPredictor,   F_RANK_EC_TH0, F_RANK_EC_AR0);
                    pc_update_bit0(staticPredictor, F_RANK_EP_TH0, F_RANK_EP_AR0);

                    rc_encode_bit0(&coder, probability);
                }

                statePredictor  = &model->Rank.Mantissa.StateModel[state][MANTISSA_ROW_START(bitRankSize)];
                charPredictor   = &model->Rank.Mantissa.CharModel[currentChar][MANTISSA_ROW_START(bitRankSize)];
                staticPredictor = &model->Rank.Mantissa.StaticModel[MANTISSA_ROW_START(bitRankSize)];

                for (int context = 1, bit = bitRankSize - 1; bit >= 0; --bit)
                {
                    unsigned int b = (rank >> bit) & 1;

                    int statePr  = statePredictor[context];  int probability = statePr * F_RANK_MM_LR1;   statePredictor[context]  = (short)(statePr  - ((statePr  * F_RANK_M_UPDATE[0][b][0] - F_RANK_M_UPDATE[0][b][1]) >> 12));
                    int charPr   = charPredictor[context];   probability += charPr * F_RANK_MM_LR0;       charPredictor[context]   = (short)(charPr   - ((charPr   * F_RANK_M_UPDATE[1][b][0] - F_RANK_M_UPDATE[1][b][1]) >> 12));
                    int staticPr = staticPredictor[context]; probability += staticPr * F_RANK_MM_LR2;     staticPredictor[context] = (short)(staticPr - ((staticPr * F_RANK_M_UPDATE[2][b][0] - F_RANK_M_UPDATE[2][b][1]) >> 12));
                    probability >>= 5;

                    context += context + (int)b; rc_encode_bit_p(&coder, b, probability);
                }
            }
        }
        else
        {
            rankHistory[currentChar] = (unsigned char)bsc_bit_scan_reverse((unsigned int)rank);

            statePredictor  = &model->Rank.Escape.StateModel[state][0];
            charPredictor   = &model->Rank.Escape.CharModel[currentChar][0];
            staticPredictor = &model->Rank.Escape.StaticModel[0];

            for (int context = 1, bit = maxRank; bit >= 0; --bit)
            {
                unsigned int b = (rank >> bit) & 1;

                int statePr  = statePredictor[context];  int probability = statePr * F_RANK_PM_LR1;   statePredictor[context]  = (short)(statePr  - ((statePr  * F_RANK_P_UPDATE[0][b][0] - F_RANK_P_UPDATE[0][b][1]) >> 12));
                int charPr   = charPredictor[context];   probability += charPr * F_RANK_PM_LR0;       charPredictor[context]   = (short)(charPr   - ((charPr   * F_RANK_P_UPDATE[1][b][0] - F_RANK_P_UPDATE[1][b][1]) >> 12));
                int staticPr = staticPredictor[context]; probability += staticPr * F_RANK_PM_LR2;     staticPredictor[context] = (short)(staticPr - ((staticPr * F_RANK_P_UPDATE[2][b][0] - F_RANK_P_UPDATE[2][b][1]) >> 12));
                probability >>= 5;

                context += context + (int)b; rc_encode_bit_p(&coder, b, probability);
            }
        }

        avgRank         =  (avgRank * 124 + rank * 4) >> 7;
        rank            =  rank - 1;
        history         =  runHistory[currentChar];
        state           =  model_run_state(contextRank0, contextRun, rank, history);
        statePredictor  = &model->Run.StateModel[state];
        charPredictor   = &model->Run.CharModel[currentChar];
        staticPredictor = &model->Run.StaticModel;

        if (runSize == 1)
        {
            runHistory[currentChar] = (unsigned char)((runHistory[currentChar] + 2) >> 2);

            int probability = ST_P(F_RUN_TM_LR, *charPredictor, *statePredictor, *staticPredictor);

            pc_update_bit0(statePredictor,  F_RUN_TS_TH0, F_RUN_TS_AR0);
            pc_update_bit0(charPredictor,   F_RUN_TC_TH0, F_RUN_TC_AR0);
            pc_update_bit0(staticPredictor, F_RUN_TP_TH0, F_RUN_TP_AR0);

            rc_encode_bit0(&coder, probability);
        }
        else
        {
            {
                int probability = ST_P(F_RUN_TM_LR, *charPredictor, *statePredictor, *staticPredictor);

                pc_update_bit1(statePredictor,  F_RUN_TS_TH1, F_RUN_TS_AR1);
                pc_update_bit1(charPredictor,   F_RUN_TC_TH1, F_RUN_TC_AR1);
                pc_update_bit1(staticPredictor, F_RUN_TP_TH1, F_RUN_TP_AR1);

                rc_encode_bit1(&coder, probability);
            }

            int bitRunSize = bsc_bit_scan_reverse((unsigned int)runSize); runHistory[currentChar] = (unsigned char)((runHistory[currentChar] + 3 * bitRunSize + 3) >> 2);

            statePredictor  = &model->Run.Exponent.StateModel[state][0];
            charPredictor   = &model->Run.Exponent.CharModel[currentChar][0];
            staticPredictor = &model->Run.Exponent.StaticModel[0];

            for (int bit = 1; bit < bitRunSize; ++bit, ++statePredictor, ++charPredictor, ++staticPredictor)
            {
                int probability = ST_P(F_RUN_EM_LR, *charPredictor, *statePredictor, *staticPredictor);

                pc_update_bit1(statePredictor,  F_RUN_ES_TH1, F_RUN_ES_AR1);
                pc_update_bit1(charPredictor,   F_RUN_EC_TH1, F_RUN_EC_AR1);
                pc_update_bit1(staticPredictor, F_RUN_EP_TH1, F_RUN_EP_AR1);

                rc_encode_bit1(&coder, probability);
            }
            {
                int probability = ST_P(F_RUN_EM_LR, *charPredictor, *statePredictor, *staticPredictor);

                pc_update_bit0(statePredictor,  F_RUN_ES_TH0, F_RUN_ES_AR0);
                pc_update_bit0(charPredictor,   F_RUN_EC_TH0, F_RUN_EC_AR0);
                pc_update_bit0(staticPredictor, F_RUN_EP_TH0, F_RUN_EP_AR0);

                rc_encode_bit0(&coder, probability);
            }

            statePredictor  = &model->Run.Mantissa[bitRunSize].StateModel[state][0];
            charPredictor   = &model->Run.Mantissa[bitRunSize].CharModel[currentChar][0];
            staticPredictor = &model->Run.Mantissa[bitRunSize].StaticModel[0];

            for (int context = 1, bit = bitRunSize - 1; bit >= 0; --bit)
            {
                unsigned int b = (runSize >> bit) & 1;

                int statePr  = statePredictor[context];  int probability = statePr * F_RUN_MM_LR1;   statePredictor[context]  = (short)(statePr  - ((statePr  * F_RUN_M_UPDATE[0][b][0] - F_RUN_M_UPDATE[0][b][1]) >> 12));
                int charPr   = charPredictor[context];   probability += charPr * F_RUN_MM_LR0;       charPredictor[context]   = (short)(charPr   - ((charPr   * F_RUN_M_UPDATE[1][b][0] - F_RUN_M_UPDATE[1][b][1]) >> 12));
                int staticPr = staticPredictor[context]; probability += staticPr * F_RUN_MM_LR2;     staticPredictor[context] = (short)(staticPr - ((staticPr * F_RUN_M_UPDATE[2][b][0] - F_RUN_M_UPDATE[2][b][1]) >> 12));
                probability >>= 5;

                int ctx = context + context + (int)b; context++; if (bitRunSize <= 5) { context = ctx; } rc_encode_bit_p(&coder, b, probability);
            }
        }

        contextRank0 = ((contextRank0 << 1) | (rank == 0   ? 1    : 0)) & 0x7;
        contextRank4 = ((contextRank4 << 2) | (rank < 3    ? rank : 3)) & 0xff;
        contextRun   = ((contextRun   << 1) | (runSize < 3 ? 1    : 0)) & 0xf;
    }

    return rc_finish_encoder(&coder);
}

#define ST_MIX(c, s, t, P, LR) ((c[P] * LR##0 + s[P] * LR##1 + t[P] * LR##2) >> 5)

static NOINLINE int qlfc_static_decode_escape(RangeCoder * coder, short * RESTRICT statePredictor, short * RESTRICT charPredictor, short * RESTRICT staticPredictor, int maxRank)
{
    size_t context = 1;

    int probability = ST_MIX(charPredictor, statePredictor, staticPredictor, 1, F_RANK_PM_LR);
    for (int bit = maxRank; bit > 0; --bit)
    {
        if ((unsigned int)(probability - F_RANK_P_NEAR) <= (unsigned int)(4096 - 2 * F_RANK_P_NEAR))
        {
            int probability0 = ST_MIX(charPredictor, statePredictor, staticPredictor, 2 * context + 0, F_RANK_PM_LR);
            int probability1 = ST_MIX(charPredictor, statePredictor, staticPredictor, 2 * context + 1, F_RANK_PM_LR);

            unsigned int b = rc_decode_bit_value(coder, probability);

            pc_update_bit_tab(&statePredictor[context],  F_RANK_P_UPDATE[0][b]);
            pc_update_bit_tab(&charPredictor[context],   F_RANK_P_UPDATE[1][b]);
            pc_update_bit_tab(&staticPredictor[context], F_RANK_P_UPDATE[2][b]);

            probability = probability0 + ((probability1 - probability0) & (int)(0 - b)); context += context + b;
        }
        else if (rc_peak_bit(coder, probability))
        {
            pc_update_bit_tab(&statePredictor[context],  F_RANK_P_UPDATE[0][1]);
            pc_update_bit_tab(&charPredictor[context],   F_RANK_P_UPDATE[1][1]);
            pc_update_bit_tab(&staticPredictor[context], F_RANK_P_UPDATE[2][1]);
            rc_decode_bit1(coder, probability);

            context += context + 1; probability = ST_MIX(charPredictor, statePredictor, staticPredictor, context, F_RANK_PM_LR);
        }
        else
        {
            pc_update_bit_tab(&statePredictor[context],  F_RANK_P_UPDATE[0][0]);
            pc_update_bit_tab(&charPredictor[context],   F_RANK_P_UPDATE[1][0]);
            pc_update_bit_tab(&staticPredictor[context], F_RANK_P_UPDATE[2][0]);
            rc_decode_bit0(coder, probability);

            context += context; probability = ST_MIX(charPredictor, statePredictor, staticPredictor, context, F_RANK_PM_LR);
        }
    }

    if ((unsigned int)(probability - F_RANK_P_NEAR) <= (unsigned int)(4096 - 2 * F_RANK_P_NEAR))
    {
        unsigned int b = rc_decode_bit_value(coder, probability);

        pc_update_bit_tab(&statePredictor[context],  F_RANK_P_UPDATE[0][b]);
        pc_update_bit_tab(&charPredictor[context],   F_RANK_P_UPDATE[1][b]);
        pc_update_bit_tab(&staticPredictor[context], F_RANK_P_UPDATE[2][b]);

        context += context + b;
    }
    else if (rc_peak_bit(coder, probability))
    {
        pc_update_bit_tab(&statePredictor[context],  F_RANK_P_UPDATE[0][1]);
        pc_update_bit_tab(&charPredictor[context],   F_RANK_P_UPDATE[1][1]);
        pc_update_bit_tab(&staticPredictor[context], F_RANK_P_UPDATE[2][1]);
        rc_decode_bit1(coder, probability);

        context += context + 1;
    }
    else
    {
        pc_update_bit_tab(&statePredictor[context],  F_RANK_P_UPDATE[0][0]);
        pc_update_bit_tab(&charPredictor[context],   F_RANK_P_UPDATE[1][0]);
        pc_update_bit_tab(&staticPredictor[context], F_RANK_P_UPDATE[2][0]);
        rc_decode_bit0(coder, probability);

        context += context;
    }

    return (int)(context - ((size_t)2 << maxRank));
}

static int qlfc_static_decode(const unsigned char * input, const unsigned char * inputEnd, unsigned char * output, int n, QlfcStatisticalModel1 * model)
{
    RangeCoder coder;

    unsigned char ALIGNED(64) MTFTable[ALPHABET_SIZE];
    for (int i = 0; i < ALPHABET_SIZE; ++i) MTFTable[i] = 0;

    qlfc_init_model1(model);

    int contextRank0 = 0;
    int contextRank4 = 0;
    int contextRun   = 0;
    int maxRank      = 7;
    int avgRank      = 0;

    unsigned char rankHistory[ALPHABET_SIZE], runHistory[ALPHABET_SIZE];
    for (int i = 0; i < ALPHABET_SIZE; ++i) rankHistory[i] = runHistory[i] = 0;

    rc_init_decoder(&coder, input, inputEnd);
    if ((int)rc_decode_word(&coder) != n) return QLFC_DATA_CORRUPT;

    maxRank = qlfc_decode_alphabet(&coder, MTFTable);

    for (int i = 0; i < n;)
    {
        int currentChar = MTFTable[0];
        int history     = rankHistory[currentChar];
        int state       = model_rank_state(contextRank4, contextRun, history);

        short * RESTRICT statePredictor  = &model->Rank.StateModel[state];
        short * RESTRICT charPredictor   = &model->Rank.CharModel[currentChar];
        short * RESTRICT staticPredictor = &model->Rank.StaticModel;

        int rank = 1;
        if (avgRank < 32)
        {
            if (rc_decode_bit(&coder, ST_P(F_RANK_TM_LR, *charPredictor, *statePredictor, *staticPredictor)))
            {
                pc_update_bit1(statePredictor,  F_RANK_TS_TH1, F_RANK_TS_AR1);
                pc_update_bit1(charPredictor,   F_RANK_TC_TH1, F_RANK_TC_AR1);
                pc_update_bit1(staticPredictor, F_RANK_TP_TH1, F_RANK_TP_AR1);

                statePredictor  = &model->Rank.Exponent.StateModel[state][0];
                charPredictor   = &model->Rank.Exponent.CharModel[currentChar][0];
                staticPredictor = &model->Rank.Exponent.StaticModel[0];

                int bitRankSize = 1;
                while (1)
                {
                    if (bitRankSize >= maxRank) break;

                    int probability = ST_P(F_RANK_EM_LR, *charPredictor, *statePredictor, *staticPredictor);
                    if (rc_peak_bit(&coder, probability))
                    {
                        pc_update_bit1(statePredictor,  F_RANK_ES_TH1, F_RANK_ES_AR1); statePredictor++;
                        pc_update_bit1(charPredictor,   F_RANK_EC_TH1, F_RANK_EC_AR1); charPredictor++;
                        pc_update_bit1(staticPredictor, F_RANK_EP_TH1, F_RANK_EP_AR1); staticPredictor++;
                        bitRankSize++;
                        rc_decode_bit1(&coder, probability);
                    }
                    else
                    {
                        pc_update_bit0(statePredictor,  F_RANK_ES_TH0, F_RANK_ES_AR0);
                        pc_update_bit0(charPredictor,   F_RANK_EC_TH0, F_RANK_EC_AR0);
                        pc_update_bit0(staticPredictor, F_RANK_EP_TH0, F_RANK_EP_AR0);
                        rc_decode_bit0(&coder, probability);
                        break;
                    }
                }

                rankHistory[currentChar] = (unsigned char)bitRankSize;

                statePredictor  = &model->Rank.Mantissa.StateModel[state][MANTISSA_ROW_START(bitRankSize)];
                charPredictor   = &model->Rank.Mantissa.CharModel[currentChar][MANTISSA_ROW_START(bitRankSize)];
                staticPredictor = &model->Rank.Mantissa.StaticModel[MANTISSA_ROW_START(bitRankSize)];

                int probability = ST_MIX(charPredictor, statePredictor, staticPredictor, rank, F_RANK_MM_LR);
                for (int bit = bitRankSize - 1; bit > 0; --bit)
                {
                    int probability0 = ST_MIX(charPredictor, statePredictor, staticPredictor, 2 * rank + 0, F_RANK_MM_LR);
                    int probability1 = ST_MIX(charPredictor, statePredictor, staticPredictor, 2 * rank + 1, F_RANK_MM_LR);

                    unsigned int b = rc_decode_bit_value(&coder, probability);

                    pc_update_bit_tab(&statePredictor[rank],  F_RANK_M_UPDATE[0][b]);
                    pc_update_bit_tab(&charPredictor[rank],   F_RANK_M_UPDATE[1][b]);
                    pc_update_bit_tab(&staticPredictor[rank], F_RANK_M_UPDATE[2][b]);

                    probability = probability0 + ((probability1 - probability0) & (int)(0 - b)); rank += rank + (int)b;
                }
                {
                    unsigned int b = rc_decode_bit_value(&coder, probability);

                    pc_update_bit_tab(&statePredictor[rank],  F_RANK_M_UPDATE[0][b]);
                    pc_update_bit_tab(&charPredictor[rank],   F_RANK_M_UPDATE[1][b]);
                    pc_update_bit_tab(&staticPredictor[rank], F_RANK_M_UPDATE[2][b]);

                    rank += rank + (int)b;
                }
            }
            else
            {
                rankHistory[currentChar] = 0;
                pc_update_bit0(statePredictor,  F_RANK_TS_TH0, F_RANK_TS_AR0);
                pc_update_bit0(charPredictor,   F_RANK_TC_TH0, F_RANK_TC_AR0);
                pc_update_bit0(staticPredictor, F_RANK_TP_TH0, F_RANK_TP_AR0);
            }
        }
        else
        {
            statePredictor  = &model->Rank.Escape.StateModel[state][0];
            charPredictor   = &model->Rank.Escape.CharModel[currentChar][0];
            staticPredictor = &model->Rank.Escape.StaticModel[0];

            rank = qlfc_static_decode_escape(&coder, statePredictor, charPredictor, staticPredictor, maxRank);

            if (rank <= 0) return QLFC_DATA_CORRUPT;
            rankHistory[currentChar] = (unsigned char)bsc_bit_scan_reverse((unsigned int)rank);
        }

        if (rank > 255) return QLFC_DATA_CORRUPT;
        qlfc_mtf_update(MTFTable, rank, currentChar);

        avgRank         =  (avgRank * 124 + rank * 4) >> 7;
        rank            =  rank - 1;
        history         =  runHistory[currentChar];
        state           =  model_run_state(contextRank0, contextRun, rank, history);
        statePredictor  = &model->Run.StateModel[state];
        charPredictor   = &model->Run.CharModel[currentChar];
        staticPredictor = &model->Run.StaticModel;

        if (rc_decode_bit(&coder, ST_P(F_RUN_TM_LR, *charPredictor, *statePredictor, *staticPredictor)))
        {
            pc_update_bit1(statePredictor,  F_RUN_TS_TH1, F_RUN_TS_AR1);
            pc_update_bit1(charPredictor,   F_RUN_TC_TH1, F_RUN_TC_AR1);
            pc_update_bit1(staticPredictor, F_RUN_TP_TH1, F_RUN_TP_AR1);

            statePredictor  = &model->Run.Exponent.StateModel[state][0];
            charPredictor   = &model->Run.Exponent.CharModel[currentChar][0];
            staticPredictor = &model->Run.Exponent.StaticModel[0];

            int runSize = 1, bitRunSize = 1;
            while (1)
            {
                int probability = ST_P(F_RUN_EM_LR, *charPredictor, *statePredictor, *staticPredictor);
                if (rc_peak_bit(&coder, probability))
                {
                    pc_update_bit1(statePredictor,  F_RUN_ES_TH1, F_RUN_ES_AR1); statePredictor++;
                    pc_update_bit1(charPredictor,   F_RUN_EC_TH1, F_RUN_EC_AR1); charPredictor++;
                    pc_update_bit1(staticPredictor, F_RUN_EP_TH1, F_RUN_EP_AR1); staticPredictor++;
                    bitRunSize++;
                    if (bitRunSize > 30) return QLFC_DATA_CORRUPT;
                    rc_decode_bit1(&coder, probability);
                }
                else
                {
                    pc_update_bit0(statePredictor,  F_RUN_ES_TH0, F_RUN_ES_AR0);
                    pc_update_bit0(charPredictor,   F_RUN_EC_TH0, F_RUN_EC_AR0);
                    pc_update_bit0(staticPredictor, F_RUN_EP_TH0, F_RUN_EP_AR0);
                    rc_decode_bit0(&coder, probability);
                    break;
                }
            }

            runHistory[currentChar] = (unsigned char)((runHistory[currentChar] + 3 * bitRunSize + 3) >> 2);

            statePredictor  = &model->Run.Mantissa[bitRunSize].StateModel[state][0];
            charPredictor   = &model->Run.Mantissa[bitRunSize].CharModel[currentChar][0];
            staticPredictor = &model->Run.Mantissa[bitRunSize].StaticModel[0];

            if (bitRunSize <= 5)
            {
                size_t context = 1;

                int probability = ST_MIX(charPredictor, statePredictor, staticPredictor, 1, F_RUN_MM_LR);
                for (int bit = bitRunSize - 1; bit > 0; --bit)
                {
                    if ((unsigned int)(probability - F_RUN_M_NEAR) <= (unsigned int)(4096 - 2 * F_RUN_M_NEAR))
                    {
                        int probability0 = ST_MIX(charPredictor, statePredictor, staticPredictor, 2 * context + 0, F_RUN_MM_LR);
                        int probability1 = ST_MIX(charPredictor, statePredictor, staticPredictor, 2 * context + 1, F_RUN_MM_LR);

                        unsigned int b = rc_decode_bit_value(&coder, probability);

                        pc_update_bit_tab(&statePredictor[context],  F_RUN_M_UPDATE[0][b]);
                        pc_update_bit_tab(&charPredictor[context],   F_RUN_M_UPDATE[1][b]);
                        pc_update_bit_tab(&staticPredictor[context], F_RUN_M_UPDATE[2][b]);

                        probability = probability0 + ((probability1 - probability0) & (int)(0 - b)); context += context + b; runSize += runSize + (int)b;
                    }
                    else if (rc_peak_bit(&coder, probability))
                    {
                        pc_update_bit_tab(&statePredictor[context],  F_RUN_M_UPDATE[0][1]);
                        pc_update_bit_tab(&charPredictor[context],   F_RUN_M_UPDATE[1][1]);
                        pc_update_bit_tab(&staticPredictor[context], F_RUN_M_UPDATE[2][1]);
                        rc_decode_bit1(&coder, probability);

                        context += context + 1; runSize += runSize + 1; probability = ST_MIX(charPredictor, statePredictor, staticPredictor, context, F_RUN_MM_LR);
                    }
                    else
                    {
                        pc_update_bit_tab(&statePredictor[context],  F_RUN_M_UPDATE[0][0]);
                        pc_update_bit_tab(&charPredictor[context],   F_RUN_M_UPDATE[1][0]);
                        pc_update_bit_tab(&staticPredictor[context], F_RUN_M_UPDATE[2][0]);
                        rc_decode_bit0(&coder, probability);

                        context += context; runSize += runSize; probability = ST_MIX(charPredictor, statePredictor, staticPredictor, context, F_RUN_MM_LR);
                    }
                }

                if ((unsigned int)(probability - F_RUN_M_NEAR) <= (unsigned int)(4096 - 2 * F_RUN_M_NEAR))
                {
                    unsigned int b = rc_decode_bit_value(&coder, probability);

                    pc_update_bit_tab(&statePredictor[context],  F_RUN_M_UPDATE[0][b]);
                    pc_update_bit_tab(&charPredictor[context],   F_RUN_M_UPDATE[1][b]);
                    pc_update_bit_tab(&staticPredictor[context], F_RUN_M_UPDATE[2][b]);

                    runSize += runSize + (int)b;
                }
                else if (rc_peak_bit(&coder, probability))
                {
                    pc_update_bit_tab(&statePredictor[context],  F_RUN_M_UPDATE[0][1]);
                    pc_update_bit_tab(&charPredictor[context],   F_RUN_M_UPDATE[1][1]);
                    pc_update_bit_tab(&staticPredictor[context], F_RUN_M_UPDATE[2][1]);
                    rc_decode_bit1(&coder, probability);

                    runSize += runSize + 1;
                }
                else
                {
                    pc_update_bit_tab(&statePredictor[context],  F_RUN_M_UPDATE[0][0]);
                    pc_update_bit_tab(&charPredictor[context],   F_RUN_M_UPDATE[1][0]);
                    pc_update_bit_tab(&staticPredictor[context], F_RUN_M_UPDATE[2][0]);
                    rc_decode_bit0(&coder, probability);

                    runSize += runSize;
                }
            }
            else
            {
                for (size_t context = 1; context <= (size_t)bitRunSize; ++context)
                {
                    unsigned int b = rc_decode_bit_value(&coder, ST_MIX(charPredictor, statePredictor, staticPredictor, context, F_RUN_MM_LR));

                    pc_update_bit_tab(&statePredictor[context],  F_RUN_M_UPDATE[0][b]);
                    pc_update_bit_tab(&charPredictor[context],   F_RUN_M_UPDATE[1][b]);
                    pc_update_bit_tab(&staticPredictor[context], F_RUN_M_UPDATE[2][b]);

                    runSize += runSize + (int)b;
                }
            }

            contextRank0 = ((contextRank0 << 1) | (rank == 0   ? 1    : 0)) & 0x7;
            contextRank4 = ((contextRank4 << 2) | (rank < 3    ? rank : 3)) & 0xff;
            contextRun   = ((contextRun   << 1) | (runSize < 3 ? 1    : 0)) & 0xf;

            if (runSize > n - i) return QLFC_DATA_CORRUPT;
            qlfc_put_run(output, i, n, currentChar, runSize); i += runSize;
        }
        else
        {
            runHistory[currentChar] = (unsigned char)((runHistory[currentChar] + 2) >> 2);
            pc_update_bit0(statePredictor,  F_RUN_TS_TH0, F_RUN_TS_AR0);
            pc_update_bit0(charPredictor,   F_RUN_TC_TH0, F_RUN_TC_AR0);
            pc_update_bit0(staticPredictor, F_RUN_TP_TH0, F_RUN_TP_AR0);

            contextRank0 = ((contextRank0 << 1) | (rank == 0   ? 1    : 0)) & 0x7;
            contextRank4 = ((contextRank4 << 2) | (rank < 3    ? rank : 3)) & 0xff;
            contextRun   = ((contextRun   << 1) | (                     1)) & 0xf;

            output[i++] = (unsigned char)currentChar;
        }
    }

    return coder.overrun ? QLFC_DATA_CORRUPT : n;
}

/*---------------------------------------------------------------------------*/
/* Entry points for PArc (cdecl, no allocation)                              */
/*---------------------------------------------------------------------------*/

/* Coder 1 = static, 2 = adaptive. */
int32_t parc_qlfc_model_size(int32_t coder)
{
    return coder == 2 ? (int32_t)sizeof(QlfcStatisticalModel2) : (int32_t)sizeof(QlfcStatisticalModel1);
}

/* input[0..n) -> output; outputSize is the limit for the coded bytes (the encoder gives up a little before it, and
   output must hold outputSize + 4096 bytes); buffer: n bytes of scratch. Returns the coded size, or -1 if it does not
   fit (not compressible). n >= 1. */
int32_t parc_qlfc_encode(const uint8_t * input, uint8_t * output, uint8_t * buffer, int32_t n, int32_t outputSize, int32_t coder, void * model)
{
    if (n < 1 || outputSize < 64) return QLFC_NOT_COMPRESSIBLE;
    if (coder == 2) return qlfc_adaptive_encode(input, output, buffer, n, outputSize, (QlfcStatisticalModel2 *)model);
    return qlfc_static_encode(input, output, buffer, n, outputSize, (QlfcStatisticalModel1 *)model);
}

/* input[0..inputSize) -> output[0..n). Returns n, or -2 if the data is damaged. */
int32_t parc_qlfc_decode(const uint8_t * input, int32_t inputSize, uint8_t * output, int32_t n, int32_t coder, void * model)
{
    if (n < 1 || inputSize < 0) return QLFC_DATA_CORRUPT;
    if (coder == 2) return qlfc_adaptive_decode(input, input + inputSize, output, n, (QlfcStatisticalModel2 *)model);
    return qlfc_static_decode(input, input + inputSize, output, n, (QlfcStatisticalModel1 *)model);
}
