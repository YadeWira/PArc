// Puente al codificador Tornado de FreeArc 0.67 (reference/freearc-0.67/Compression/Tornado),
// compilado tal cual con g++ / mingw-g++ (build.sh lo copia y le aplica parc_torglue.patch, que
// solo corrige el match de repdist leído más allá de bufend). Pascal lo llama únicamente por las
// funciones extern "C" de abajo (parc_torenc.pas):
//   - nada de excepciones de C++ (-fno-exceptions) y ninguna cruza la frontera: los errores
//     vuelven como códigos FREEARC_ERRCODE_* (< 0);
//   - CHECK (invariantes internos del C) no termina el proceso: salta (longjmp) a la entrada
//     y devuelve FREEARC_ERRCODE_INTERNAL;
//   - sin memoria: MyAlloc devuelve NULL y Tornado devuelve FREEARC_ERRCODE_NOT_ENOUGH_MEMORY;
//   - hilos: el único estado global que cambia por llamada (compress_all_at_once) pasa a ser
//     de la llamada (ParcCall), y las tablas lc/lc2/dc se arman una sola vez (parc_tor_init,
//     en la inicialización de la unidad) antes de cualquier hilo.
// Solo el codificador: el decodificador es el de Pascal (parc_tornado.pas, con chequeos de límites).
#include <stdlib.h>
#include <string.h>
#include <new>

// Estado de la llamada en curso (uno por hilo): el salto de CHECK y compress_all_at_once.
// El hilo lo encuentra por un puntero thread-local: __thread en Linux; en Windows TlsAlloc
// (mingw implementa __thread con emutls de libgcc, que espera el arranque de mingw).
struct ParcCall
{
  void *jb[5];   // __builtin_setjmp (sin libc ni el desenrollado SEH del longjmp de msvcrt)
  int   code;    // código de error de CHECK
  int   aao;     // compress_all_at_once: 1 en 4x4 (memoria a memoria), 0 en el stream
};
static ParcCall *parc_cur ();

// CHECK de FreeArc: printf + exit. Acá: volver a la entrada (parc_run) con el código de error.
[[noreturn]] static void parc_check_fail (int code)
{
  ParcCall *c = parc_cur();
  if (!c)  abort();   // fuera de parc_run (parc_tor_init): no puede fallar
  c->code = code;
  __builtin_longjmp (c->jb, 1);
}
#define CHECK(e,a,b)  {if (!(a))  parc_check_fail(e);}

// Compression.h declara "extern int compress_all_at_once;", que con esta macro pasa a ser la
// declaración de la función (definida abajo).
extern "C" int *parc_tor_aao ();
#define compress_all_at_once (*parc_tor_aao())

#define PARC_ENCODER_ONLY   // sin el decodificador de FreeArc (ver parc_torglue.patch)
#include "Common.h"
#include "Tornado/Tornado.cpp"

#ifdef FREEARC_WIN
static DWORD parc_tls = TLS_OUT_OF_INDEXES;
static ParcCall *parc_cur ()             {return (ParcCall*) TlsGetValue (parc_tls);}
static void parc_set_cur (ParcCall *c)   {TlsSetValue (parc_tls, c);}
#else
static __thread ParcCall *parc_cur_call;
static ParcCall *parc_cur ()             {return parc_cur_call;}
static void parc_set_cur (ParcCall *c)   {parc_cur_call = c;}
#endif
extern "C" int *parc_tor_aao ()  {return &parc_cur()->aao;}

// Memoria de Tornado (BigAlloc/MidAlloc/MyAlloc): en cero, como el mmap/VirtualAlloc de
// FreeArc. La salida depende de eso: los hashes leen unos bytes más allá de bufend.
void *MyAlloc (size_t size) throw()   {return calloc (1, size);}
void  MyFree  (void *address) throw() {free (address);}
#ifdef FREEARC_WIN
LPType DefaultLargePageMode = DISABLE;
void *MidAlloc (size_t size) throw()                {return MyAlloc (size);}
void  MidFree  (void *address) throw()              {MyFree (address);}
void *BigAlloc (int64 size, LPType) throw()         {return size == (size_t)size? MyAlloc ((size_t)size) : NULL;}
void  BigFree  (void *address) throw()              {MyFree (address);}
#endif

// operator new/delete sin libstdc++ (Tornado no usa new; por las dudas no lanzan)
void* operator new   (size_t n)                     {return malloc(n);}
void* operator new[] (size_t n)                     {return malloc(n);}
void  operator delete   (void *p) noexcept          {free(p);}
void  operator delete[] (void *p) noexcept          {free(p);}
void  operator delete   (void *p, size_t) noexcept  {free(p);}
void  operator delete[] (void *p, size_t) noexcept  {free(p);}

// f[0..13] = los campos de PackMethod en orden (find_tables como 0/1)
static PackMethod parc_method (const int *f)
{
  PackMethod m;
  m.number = f[0];  m.encoding_method = f[1];  m.find_tables = f[2]!=0;  m.hash_row_width = f[3];
  m.hashsize = (uint)f[4];  m.match_finder = f[5];  m.buffer = (uint)f[6];  m.match_parser = f[7];
  m.hash3 = f[8];  m.shift = f[9];  m.update_step = f[10];  m.auxhash_size = (uint)f[11];
  m.auxhash_row_width = f[12];  m.fast_bytes = f[13];
  return m;
}

// tor_compress con el salto de CHECK armado. El longjmp se saltea destructores y no libera nada:
// solo puede pasar si un invariante del C falla (los parámetros ya los validó Pascal).
static int parc_run (PackMethod m, CALLBACK_FUNC *cb, void *aux, int aao)
{
  ParcCall call, *saved = parc_cur();
  int r;
  call.code = FREEARC_ERRCODE_INTERNAL;
  call.aao  = aao;
  parc_set_cur (&call);
  if (__builtin_setjmp (call.jb) != 0)  r = call.code < 0? call.code : FREEARC_ERRCODE_INTERNAL;
  else                                  r = tor_compress (m, cb, aux, NULL, -1);
  parc_set_cur (saved);
  return r;
}

// ---- memoria a memoria (4x4:tor; FreeArc: TORNADO_METHOD::DeCompressMem con compress_all_at_once=1)
struct ParcMemIO { const unsigned char *src; int srclen, rpos; unsigned char *dst; int dstcap, wpos; };

static int parc_memcb (const char *what, void *buf, int size, void *aux)
{
  ParcMemIO *io = (ParcMemIO*) aux;
  if (strequ (what, "read")) {
    int n = io->srclen - io->rpos;  if (n > size)  n = size;
    memcpy (buf, io->src + io->rpos, n);  io->rpos += n;
    return n;
  } else if (strequ (what, "write")) {
    if (size > io->dstcap - io->wpos)  return FREEARC_ERRCODE_OUTBLOCK_TOO_SMALL;
    memcpy (io->dst + io->wpos, buf, size);  io->wpos += size;
    return size;
  }
  return FREEARC_OK;   // "progress" y demás
}

// Comprime src entero. 0 = ok y *outlen bytes en dst; < 0 = FREEARC_ERRCODE_* (OUTBLOCK_TOO_SMALL
// si la salida no entra en dstcap).
extern "C" int parc_tor_compress_mem (const int *f, const void *src, int srclen, void *dst, int dstcap, int *outlen)
{
  ParcMemIO io = {(const unsigned char*) src, srclen, 0, (unsigned char*) dst, dstcap, 0};
  int r = parc_run (parc_method (f), parc_memcb, &io, 1);
  *outlen = io.wpos;
  return r < 0? r : 0;
}

// ---- stream (tor de una etapa; FreeArc: TORNADO_METHOD::compress con compress_all_at_once=0)
typedef int (*ParcIoFunc) (void *aux, void *buf, int size);
struct ParcCbIO { ParcIoFunc rd, wr; void *aux; };

static int parc_streamcb (const char *what, void *buf, int size, void *aux)
{
  ParcCbIO *io = (ParcCbIO*) aux;
  if (strequ (what, "read"))   return io->rd (io->aux, buf, size);
  if (strequ (what, "write"))  return io->wr (io->aux, buf, size);
  return FREEARC_OK;
}

// rd/wr (Pascal, cdecl) devuelven los bytes leídos/escritos o un código < 0; las lecturas tienen
// que ser completas salvo al final de los datos (como read_data de FreeArc).
extern "C" int parc_tor_compress_stream (const int *f, ParcIoFunc rd, ParcIoFunc wr, void *aux)
{
  ParcCbIO io = {rd, wr, aux};
  int r = parc_run (parc_method (f), parc_streamcb, &io, 0);
  return r < 0? r : 0;
}

// El arranque de FPC no siempre corre los constructores estáticos de C++ (.init_array):
// las tablas de códigos de largo y distancia se arman acá (idempotente).
extern "C" void parc_tor_init (void)
{
#ifdef FREEARC_WIN
  if (parc_tls == TLS_OUT_OF_INDEXES)  parc_tls = TlsAlloc();
#endif
  new (&lc)  LengthCoder <elements(extra_lbits)>  (extra_lbits);
  new (&lc2) LengthCoder <elements(extra_lbits2)> (extra_lbits2);
  new (&dc)  DistanceCoder (extra_dbits, elements(extra_dbits));
}
