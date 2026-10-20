// tests/dispack_ref.cpp — referencia C de DisPack (Compression/DisPack/DisPack.cpp).
// Uso: dispack_ref f <origin> < in > out       (filtra)
//      dispack_ref u <origin> <outsize> < in > out   (desfiltra)
// Sale con 1 si el filtro/desfiltro falla.
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include "DisPack.hpp"

static unsigned char *ReadAll(FILE *f, long *n)
{
    long cap = 1 << 20, len = 0;
    unsigned char *buf = (unsigned char *) malloc(cap);
    size_t got;
    while ((got = fread(buf + len, 1, cap - len, f)) > 0) {
        len += got;
        if (len == cap) { cap *= 2; buf = (unsigned char *) realloc(buf, cap); }
    }
    *n = len;
    return buf;
}

int main(int argc, char **argv)
{
    long n;
    unsigned char *in = ReadAll(stdin, &n);
    if (argc < 3) { fprintf(stderr, "uso: f|u origin [outsize]\n"); return 2; }
    unsigned origin = (unsigned) strtoul(argv[2], NULL, 0);
    if (argv[1][0] == 'f') {
        unsigned outSize = 0;
        unsigned char *out = DisFilter(in, (int) n, origin, outSize);
        if (!out) return 1;
        fwrite(out, 1, outSize, stdout);
        free(out);
    } else {
        unsigned outSize = (unsigned) strtoul(argv[3], NULL, 0);
        unsigned char *out = (unsigned char *) malloc(outSize ? outSize : 1);
        if (!DisUnFilter(in, (unsigned) n, out, outSize, origin)) return 1;
        fwrite(out, 1, outSize, stdout);
        free(out);
    }
    free(in);
    return 0;
}
