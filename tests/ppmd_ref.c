/* tests/ppmd_ref.c — arnés para tests/ppmd.sh: codifica un archivo con el Ppmd8 del LZMA SDK
   (C original, dominio público) con marca de fin y escribe el stream crudo, para comparar con
   parc_ppmd (que agrega una cabecera de 8 bytes). El SDK no está en el repositorio: el script
   lo toma de $PPMD_SDK.
   Uso: ppmd_ref <entrada> <orden> <memoria en bytes> <recuperación> <salida> */
#include <stdio.h>
#include <stdlib.h>
#include "Precomp.h"
#include "Ppmd8.h"

static void *AllocF(ISzAllocPtr p, size_t s) { (void)p; return malloc(s); }
static void FreeF(ISzAllocPtr p, void *a) { (void)p; free(a); }
static const ISzAlloc g_Alloc = { AllocF, FreeF };
static FILE *g_out;
static void WriteF(IByteOutPtr p, Byte b) { (void)p; fputc(b, g_out); }
static const IByteOut g_Out = { WriteF };

int main(int argc, char **argv)
{
  CPpmd8 p;
  FILE *f;
  long n, i;
  unsigned char *b;
  if (argc != 6) return 2;
  f = fopen(argv[1], "rb");
  if (!f) return 2;
  fseek(f, 0, SEEK_END); n = ftell(f); fseek(f, 0, SEEK_SET);
  b = (unsigned char *)malloc(n + 1);
  if (fread(b, 1, n, f) != (size_t)n) return 2;
  fclose(f);
  g_out = fopen(argv[5], "wb");
  if (!g_out) return 2;
  Ppmd8_Construct(&p);
  if (!Ppmd8_Alloc(&p, (UInt32)strtoul(argv[3], NULL, 10), &g_Alloc)) return 3;
  p.Stream.Out = &g_Out;
  Ppmd8_Init_RangeEnc(&p);
  Ppmd8_Init(&p, (unsigned)atoi(argv[2]), (unsigned)atoi(argv[4]));
  for (i = 0; i < n; i++) Ppmd8_EncodeSymbol(&p, b[i]);
  Ppmd8_EncodeSymbol(&p, -1);
  Ppmd8_Flush_RangeEnc(&p);
  fclose(g_out);
  Ppmd8_Free(&p, &g_Alloc);
  return 0;
}
