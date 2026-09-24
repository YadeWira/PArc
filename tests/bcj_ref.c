/* Referencia para tests/test_bcj: bcj_x86_de_compress de FreeArc (C_BCJ.cpp) con el
   x86_Convert de 2008 que trae FreeArc, leyendo de stdin en pedazos de tamaño aleatorio.
   Uso: bcj_ref <seed> <enc 0|1> < in > out */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
typedef unsigned char Byte; typedef unsigned int UInt32; typedef size_t SizeT;
#include "../Compression/LZMA2/C/Bra86.c"
#define BUFSZ (1<<18)
int main(int argc, char **argv) {
  srand(atoi(argv[1])); int enc = atoi(argv[2]);
  UInt32 state; x86_Convert_Init(state); UInt32 ip = 0;
  static Byte Buf[BUFSZ]; int Rem = 0;
  for (;;) {
    /* El compresor de FreeArc recibe buffers llenos salvo al final: pedimos siempre hasta llenar */
    int want = BUFSZ - Rem, got = 0, x;
    while (got < want && (x = fread(Buf + Rem + got, 1, want - got, stdin)) > 0) got += x;
    int InSize = got + Rem;
    if (InSize == 0) break;
    int OutSize = InSize <= 5 ? InSize : (int)x86_Convert(Buf, InSize, ip, &state, enc);
    ip += OutSize; fwrite(Buf, 1, OutSize, stdout);
    Rem = InSize - OutSize; if (Rem > 0) memmove(Buf, Buf + OutSize, Rem);
    if (got == 0) { fwrite(Buf, 1, Rem, stdout); break; }
  }
  return 0;
}
