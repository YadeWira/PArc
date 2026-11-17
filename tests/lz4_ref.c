/* tests/lz4_ref.c: LZ4 en C (lib/ de la versión indicada) por bloques de 1 MB: "<modo> <bytes> <FNV-1a>",
   para comparar con test_lz4frame blocks (tests/lz4frame.sh con LZ4_LIB_DIR=<lz4>/lib). */
#include <stdio.h>
#include <stdlib.h>
#include "lz4.h"
#include "lz4hc.h"
int main(int c, char**v){ FILE*f=fopen(v[2],"rb"); fseek(f,0,2); long n=ftell(f); rewind(f); char*s=malloc(n); fread(s,1,n,f);
 int bs=1<<20; char*d=malloc(LZ4_compressBound(bs)); long tot=0; unsigned h=2166136261u;
 for(long p=0;p<n;p+=bs){ int k=n-p<bs?n-p:bs; int r= v[1][0]=='h'? LZ4_compress_HC(s+p,d,k,LZ4_compressBound(bs),9) : LZ4_compress_default(s+p,d,k,LZ4_compressBound(bs)); tot+=r; for(int i=0;i<r;i++){h^=(unsigned char)d[i];h*=16777619u;} }
 printf("%s %ld %08x\n",v[1],tot,h); return 0; }
