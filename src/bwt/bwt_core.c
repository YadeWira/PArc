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
