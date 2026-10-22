{ REP (codificador): coincidencias de largo alcance. Port de Compression/REP/rep.cpp
  (rep_compress, CalcHashSize) y C_REP.cpp (REP_METHOD, parse_REP) de FreeArc 0.67,
  Bulat Ziganshin. Decodificador: parc_rep (TRepStage).

  Salida idéntica byte a byte a rep_compress con lecturas completas (fread): el C lee de a
  min(BlockSize-DataEnd, HTBLOCK) bytes y cada lectura devuelve todo lo pedido salvo al final
  del stream; acá cada "lectura" espera a tener esos bytes (o al Finish).

  Hilos: el C calcula los hashes (Job.process) en hilos de fondo y los consume en orden FIFO;
  el trabajo de un hilo solo lee bytes ya leídos que nadie modifica hasta consumirlo y solo
  escribe su propia ranura de ht[], así que hacerlo en un hilo o en el momento del Put da lo
  mismo. Acá, con más de un hilo (RepHashThreads), también va a hilos de fondo (THashTask);
  antes de mover FBuf (EnsureCap) o de volver a llenarlo desde 0 (fin de la ventana) se
  esperan todos los trabajos en vuelo (DrainTasks).
  Lo que SÍ cambia la salida es HTBUFS = max(16, 2*GetCompressionThreads()): cuántas lecturas
  de adelanto se hacen (DataEnd acota la búsqueda) y el contenido "viejo" de las ranuras
  (ver ProcessJob). Con <= 8 hilos HTBUFS=16 (valor por defecto, Threads=1); no depende de
  los hilos de hashing.

  Memoria: ventana BlockSize (se reserva a medida que llegan datos) + hash HashSize*4
  + ht HTBUFS*HTCOUNT*4 (256 KB con l512) + tablas de un bloque de 8 MB. }
unit parc_repenc;

{$mode objfpc}{$H+}
{$R-}{$Q-}

interface

uses
  SysUtils, parc_outstream;

type
  { Parámetros de REP_METHOD (C_REP.h) }
  TRepEncParams = record
    BlockSize: LongInt;       // b<mem> o memoria sin nombre (64mb): tamaño de la ventana
    MinCompression: LongInt;  // N%  (rep_compress no lo usa)
    ChunkSize: LongInt;       // c   (0 = automático)
    MinMatchLen: LongInt;     // l<n> o entero sin nombre (512)
    Barrier: LongInt;         // d<mem> (MaxInt)
    SmallestLen: LongInt;     // s<n> (512)
    HashBits: LongInt;        // h<n> (0 = automático)
    Amplifier: LongInt;       // a<n> / max (rep_compress no lo usa)
    Threads: LongInt;         // GetCompressionThreads() de FreeArc; solo afecta HTBUFS (no está en el método)
  end;

  ERepEncParams = class(Exception);
  TRepIntArray = array of LongInt;

  TRepJob = record
    Slot, BufPos, Bytes: LongInt;  // ranura en FHt, inicio en FBuf, bytes a indexar
    Busy: Boolean;                 // su hashing está en vuelo en un hilo de fondo
  end;

  TRepEncStage = class(TOutStage)
  private
    FPar: TRepEncParams;
    FBlockSize, FL, FHashSize, FHashMask, FMinLen, FSmallLen, FBarrier: LongInt;
    FPowL: LongWord;                    // PRIME^L (mod 2^32)
    FBuf: array of Byte;                // ventana; crece hasta FBlockSize
    FHashArr: TRepIntArray;         // hasharr[]
    FHt: TRepIntArray;                  // ht[]: HTBUFS ranuras de HTCOUNT enteros
    FHtBufs, FHtBlock, FHtCount: LongInt;
    FJobs: array of TRepJob;            // cola FIFO de trabajos de hashing
    FJobHead, FJobCount: LongInt;
    FFreeJobs, FHtIndex, FNextJobI, FNextFlush: LongInt;
    FDataEnd, FLastI, FLastMatch: LongInt;
    FDoItOnce, FMoreInput, FMoreHashed, FFinal: Boolean;
    FState: Integer;
    FReqSize, FGot: LongInt;            // lectura pendiente: FReqSize bytes en FBuf[FDataEnd..]
    // tablas del bloque actual (Buffer lens/offsets/datalens/dataOffsets del C)
    FLens, FOffs, FDLens, FDOffs: TRepIntArray;
    FNLens, FNOffs, FNDLens, FNDOffs: LongInt;
    FLiterals: LongInt;
    FPool: TObject;                     // TJobPool de hashing (nil = en línea)
    FTasks: array of TObject;           // THashTask por ranura de FJobs (se reusan)
    procedure WaitTask(Idx: LongInt);
    procedure DrainTasks;
    procedure Push(var A: TRepIntArray; var N: LongInt; V: LongInt);
    procedure EnsureCap(Need: LongInt);
    procedure HashJob(Slot, BufPos, Bytes: LongInt);
    procedure AfterRead(Size: LongInt);
    procedure ProcessJob(const J: TRepJob);
    procedure EncodeBlock;
    procedure Pump;
  protected
    procedure DoWrite(Buf: PByte; Count: SizeInt); override;
    procedure DoFinish; override;
  public
    constructor Create(ATarget: TOutStage; const APar: TRepEncParams);
    constructor Create(ATarget: TOutStage; const Params: TStringArray);
    destructor Destroy; override;
  end;

function DefaultRepEncParams: TRepEncParams;
{ parse_REP: Params[0] = 'rep'. Parámetros inválidos -> ERepEncParams. }
function ParseRepEncParams(const Params: TStringArray): TRepEncParams;
{ CalcHashSize + validación: devuelve L y HashSize, o excepción si el C fallaría
  (división por cero, hash vacío, cuelgue con BlockSize <= L, desbordes de int). }
procedure CheckRepEncParams(const P: TRepEncParams; out L, HashSize: LongInt);
{ GetCompressionMem de REP_METHOD: BlockSize + HashSize*4 }
function RepEncMemory(const P: TRepEncParams): Int64;

{ Hilos de fondo para el hashing de REP (HashingThreads del C): sale de PARC_THREADS / los
  núcleos, como los demás pools; 1 = en línea, sin hilos. }
function RepHashThreads: Integer;

implementation

uses
  parc_methods, parc_parallel;

const
  { Tope de hilos de hashing: el hashing (~1 GB/s por hilo) solo tiene que ir delante del
    bucle de búsqueda, que corre en el hilo que escribe. }
  REP_HASH_MAXTHREADS = 2;
  { Prefetch en ProcessJob: cuántos bloques de L bytes por delante (0 = sin el de datos) }
  REP_PF_HASH = 16;
  REP_PF_DATA = 8;

type
  { Job::process de rep_compress en un hilo de fondo }
  THashTask = class(TParallelJob)
  public
    Stage: TRepEncStage;
    Slot, BufPos, Bytes: LongInt;
    procedure Process; override;
  end;

procedure THashTask.Process;
begin
  Stage.HashJob(Slot, BufPos, Bytes);
end;

function RepHashThreads: Integer;
begin
  Result := ThreadCount(REP_HASH_MAXTHREADS);
  if Result > REP_HASH_MAXTHREADS then Result := REP_HASH_MAXTHREADS;
end;

const
  PRIME = 153191;
  MAX_BLOCK = 8 shl 20;   // 8 MB de entrada por bloque de salida

  stOuter = 0; stInner = 1; stRead = 2; stWaitRead = 3; stGet = 4; stEncode = 5;
  stFinal = 6; stDone = 7; stNotStarted = 8;

{ parseInt de Common.cpp: '=' opcional y solo dígitos }
function FaParseInt(const S: string; out V: LongInt): Boolean;
var
  i: Integer;
  n: QWord;
begin
  Result := False;
  V := 0;
  i := 1;
  if (i <= Length(S)) and (S[i] = '=') then Inc(i);
  if i > Length(S) then Exit;
  n := 0;
  while (i <= Length(S)) and (S[i] in ['0'..'9']) do
  begin
    n := n * 10 + QWord(Ord(S[i]) - Ord('0'));
    if n > High(LongInt) then Exit;   // el C lo truncaría a int: lo rechazamos
    Inc(i);
  end;
  if i <= Length(S) then Exit;
  V := LongInt(n);
  Result := True;
end;

{ parseMem64 de FreeArc (sin sufijo = 2^N): es ParseMem de parc_methods, una sola
  implementación para todos los métodos. }
function FaParseMem(const S: string; out V: QWord): Boolean;
begin
  Result := ParseMem(S, V);
end;

function DefaultRepEncParams: TRepEncParams;
begin
  // REP_METHOD::REP_METHOD
  Result.BlockSize := 64 shl 20;
  Result.MinCompression := 100;
  Result.ChunkSize := 0;
  Result.MinMatchLen := 512;
  Result.HashBits := 0;
  Result.Barrier := High(LongInt);
  Result.SmallestLen := 512;
  Result.Amplifier := 1;
  Result.Threads := 1;
end;

function ParseRepEncParams(const Params: TStringArray): TRepEncParams;
var
  k: Integer;
  p: string;
  m: QWord;
  n: LongInt;

  procedure Bad;
  begin
    raise ERepEncParams.CreateFmt('rep: invalid parameter "%s"', [p]);
  end;

  function Int(const S: string): LongInt;
  begin
    if not FaParseInt(S, Result) then Bad;
  end;

  function Mem(const S: string): LongInt;
  begin
    if not FaParseMem(S, m) then Bad;
    if m > QWord(High(LongInt)) then
      raise ERepEncParams.CreateFmt('rep: "%s" is too large (max. 2 GB - 1)', [p]);
    Result := LongInt(m);
  end;

begin
  if (Length(Params) = 0) or (Params[0] <> 'rep') then
    raise ERepEncParams.Create('rep: not the method rep');
  Result := DefaultRepEncParams;
  // parse_REP (C_REP.cpp)
  for k := 1 to High(Params) do
  begin
    p := Params[k];
    if p = 'max' then begin Result.Amplifier := 99; Continue; end;
    if p = '' then Bad;
    case p[1] of
      'b': begin Result.BlockSize := Mem(Copy(p, 2, MaxInt)); Continue; end;
      'l': begin Result.MinMatchLen := Int(Copy(p, 2, MaxInt)); Continue; end;
      'c': begin Result.ChunkSize := Int(Copy(p, 2, MaxInt)); Continue; end;
      'd': begin Result.Barrier := Mem(Copy(p, 2, MaxInt)); Continue; end;
      's': begin Result.SmallestLen := Int(Copy(p, 2, MaxInt)); Continue; end;
      'h': begin Result.HashBits := Int(Copy(p, 2, MaxInt)); Continue; end;
      'a': begin Result.Amplifier := Int(Copy(p, 2, MaxInt)); Continue; end;
    end;
    // "N%" = MinCompression (si no es un entero, se sigue probando como en el C)
    if (p[Length(p)] = '%') and FaParseInt(Copy(p, 1, Length(p) - 1), n) then
    begin
      Result.MinCompression := n;
      Continue;
    end;
    // Sin nombre: entero -> MinMatchLen; si no, memoria -> BlockSize
    if FaParseInt(p, n) then Result.MinMatchLen := n
    else Result.BlockSize := Mem(p);
  end;
  CheckRepEncParams(Result, n, n);   // validar ya, no al crear la etapa
end;

{ rounddown_to_power_of(n,2) de Common.h (n=0 -> 1) }
function RoundDownPow2(n: QWord): QWord;
begin
  Result := 1;
  if n = 0 then Exit;
  while Result <= n shr 1 do Result := Result shl 1;
end;

{ roundup_to_power_of(n,2) de Common.h (0 -> 0, 1 -> 1) }
function RoundUpPow2(n: QWord): QWord;
begin
  if n = 0 then Exit(0);
  Result := 1;
  while Result < n do Result := Result shl 1;
end;

procedure CheckRepEncParams(const P: TRepEncParams; out L, HashSize: LongInt);
var
  Len, Small: LongInt;
  q: QWord;
begin
  L := 0;
  HashSize := 0;
  if P.BlockSize <= 0 then raise ERepEncParams.Create('rep: invalid block size');
  if (P.MinMatchLen < 1) or (P.SmallestLen < 1) then
    raise ERepEncParams.Create('rep: invalid minimum match length');
  if P.ChunkSize < 0 then raise ERepEncParams.Create('rep: invalid ChunkSize');
  if (P.HashBits < 0) or (P.HashBits > 30) then raise ERepEncParams.Create('rep: invalid HashBits (0..30)');
  if P.Barrier < 0 then raise ERepEncParams.Create('rep: invalid Barrier');
  if (P.Threads < 1) or (P.Threads > 4096) then raise ERepEncParams.Create('rep: invalid thread count');
  // rep_compress: SmallestLen se limita a MinMatchLen; CalcHashSize
  Small := P.SmallestLen;
  if Small > P.MinMatchLen then Small := P.MinMatchLen;
  Len := Small;
  if P.MinMatchLen < Len then Len := P.MinMatchLen;
  if P.ChunkSize <> 0 then L := P.ChunkSize
  else L := LongInt(RoundDownPow2(QWord(Len - 1)) div 2);
  // L=0 (l1/l2 sin c) divide por cero en el C; con L > 2^28 desborda 4*L en HTBLOCK
  if (L < 1) or (L > 1 shl 28) then
    raise ERepEncParams.CreateFmt('rep: invalid hash block size L=%d (l>=3 or c>=1)', [L]);
  // Con BlockSize <= L el C se cuelga (Get() sin trabajos pendientes)
  if P.BlockSize <= L then raise ERepEncParams.Create('rep: block must be larger than L');
  if P.HashBits > 0 then HashSize := LongInt(1) shl P.HashBits
  else
  begin
    q := RoundUpPow2(QWord(P.BlockSize) div 3 * 2);
    if L div 4 > 16 then q := q div QWord(L div 4) else q := q div 16;
    HashSize := LongInt(q);
  end;
  // Con HashSize=0 el C indexa hasharr[hash & -1]: fuera del arreglo
  if HashSize < 1 then raise ERepEncParams.Create('rep: block too small for the hash');
end;

function RepEncMemory(const P: TRepEncParams): Int64;
var
  L, H: LongInt;
begin
  CheckRepEncParams(P, L, H);
  Result := Int64(P.BlockSize) + Int64(H) * 4;
end;

{ TRepEncStage }

constructor TRepEncStage.Create(ATarget: TOutStage; const Params: TStringArray);
begin
  Create(ATarget, ParseRepEncParams(Params));
end;

constructor TRepEncStage.Create(ATarget: TOutStage; const APar: TRepEncParams);
var
  i, n: Integer;
  pw, b: LongWord;
begin
  // Validar y reservar ANTES de inherited Create: si algo falla, Destroy ve FTarget=nil
  // y el destino sigue siendo del llamador.
  CheckRepEncParams(APar, FL, FHashSize);
  FPar := APar;
  FBlockSize := APar.BlockSize;
  FHashMask := FHashSize - 1;
  FMinLen := APar.MinMatchLen;
  FSmallLen := APar.SmallestLen;
  if FSmallLen > FMinLen then FSmallLen := FMinLen;
  FBarrier := APar.Barrier;
  // power(PRIME, L) en int: el resultado mod 2^32 no depende del orden de las operaciones
  pw := 1; b := PRIME; i := FL;
  while i > 0 do
  begin
    if Odd(i) then pw := pw * b;
    b := b * b;
    i := i shr 1;
  end;
  FPowL := pw;
  // HTBUFS / HTBLOCK / HTCOUNT de rep_compress
  FHtBufs := 2 * APar.Threads;
  if FHtBufs < 16 then FHtBufs := 16;
  if 256 * 1024 > 4 * FL then FHtBlock := 256 * 1024 else FHtBlock := 4 * FL;
  FHtBlock := FHtBlock div FL * FL;
  FHtCount := FHtBlock div FL * 2;
  SetLength(FHashArr, FHashSize);                 // memset(hasharr, 0)
  SetLength(FHt, Int64(FHtBufs) * FHtCount);      // BigAlloc = VirtualAlloc: en cero
  SetLength(FJobs, FHtBufs);
  inherited Create(ATarget);
  FFreeJobs := FHtBufs;
  FDoItOnce := True;
  FMoreInput := True;
  FMoreHashed := True;
  FState := stNotStarted;
  // Hashing en hilos de fondo, como HashingThreads del C. No cambia la salida: HTBUFS sale
  // de APar.Threads, no de estos hilos.
  n := RepHashThreads;
  if n > 1 then
  begin
    FPool := TJobPool.Create(n, FHtBufs);
    SetLength(FTasks, FHtBufs);
    for i := 0 to FHtBufs - 1 do
    begin
      FTasks[i] := THashTask.Create;
      THashTask(FTasks[i]).Stage := Self;
    end;
  end;
end;

destructor TRepEncStage.Destroy;
var
  i: Integer;
begin
  if FPool <> nil then
  begin
    // Ningún hilo puede seguir leyendo FBuf o escribiendo FHt después de esto
    try DrainTasks; except end;
    FreeAndNil(FPool);
  end;
  for i := 0 to High(FTasks) do FTasks[i].Free;
  inherited Destroy;
end;

{ Espera el hashing en vuelo del trabajo FJobs[Idx] (si lo hay) y relanza su error. }
procedure TRepEncStage.WaitTask(Idx: LongInt);
begin
  if not FJobs[Idx].Busy then Exit;
  FJobs[Idx].Busy := False;
  TJobPool(FPool).WaitJob(TParallelJob(FTasks[Idx]));
end;

{ Espera todos los hashings en vuelo (antes de mover FBuf o de volver a llenarlo desde 0). }
procedure TRepEncStage.DrainTasks;
var
  k: LongInt;
begin
  for k := 0 to FJobCount - 1 do WaitTask((FJobHead + k) mod FHtBufs);
end;

procedure TRepEncStage.Push(var A: TRepIntArray; var N: LongInt; V: LongInt);
begin
  if N >= Length(A) then SetLength(A, 2 * N + 1024);
  A[N] := V;
  Inc(N);
end;

procedure TRepEncStage.EnsureCap(Need: LongInt);
var
  NewCap: Int64;
begin
  if Need <= Length(FBuf) then Exit;
  NewCap := 2 * Int64(Length(FBuf));
  if NewCap < Need then NewCap := Need;
  if NewCap < 1 shl 20 then NewCap := 1 shl 20;
  if NewCap > FBlockSize then NewCap := FBlockSize;
  if FPool <> nil then DrainTasks;   // SetLength puede mover FBuf
  SetLength(FBuf, NewCap);
end;

{ Un bloque de L bytes (L par) del hash rodante: recorre los L hashes que empiezan en p[0..L)
  (h es el de p[0]) y deja en h el de p[L], en maxh/maxi el máximo con signo y su índice
  (maxh entra = h, maxi = 0).
  El hash rodante h' = h*PRIME + (p[L] - p[0]*PRIME^L) es una cadena serie de imul; acá se
  avanza de a dos pasos, h'' = h*PRIME^2 + (t0*PRIME + t1), y h' se calcula fuera de la
  cadena: la mitad de latencia. Todo es mod 2^32, así que hashes, máximos e índices son los
  mismos que paso a paso. En x86_64 va en ensamblador (FPC saca h o p a memoria en Pascal);
  está aparte de HashJob para que las variables del asm no saquen de los registros las del
  camino de L impar. }
procedure RepHashEvenBlock(p: PByte; L: LongInt; pl: LongWord; var h, maxh: LongWord;
  var maxi: LongInt);
{$IF DEFINED(CPUX86_64) AND NOT DEFINED(PARC_NOASM)}
var
  pp: PByte;
  LL: LongInt;
  pw, hh, mh: LongWord;
  mi: LongInt;
begin
  pp := p; LL := L; pw := pl; hh := h; mh := maxh;
  asm
    movq    pp, %rsi
    movslq  LL, %r8
    leaq    (%rsi,%r8), %rdi
    movl    pw, %r9d
    movl    hh, %eax
    movl    mh, %r10d
    xorl    %r11d, %r11d
    xorl    %ecx, %ecx
  .Lrephash2:
    movzbl  (%rsi,%rcx), %edx
    imull   %r9d, %edx
    movzbl  (%rdi,%rcx), %r12d
    subl    %edx, %r12d            // t0 = p[i+L] - p[i]*PRIME^L
    movzbl  1(%rsi,%rcx), %edx
    imull   %r9d, %edx
    movzbl  1(%rdi,%rcx), %r13d
    subl    %edx, %r13d            // t1 = p[i+1+L] - p[i+1]*PRIME^L
    imull   $0x25667, %eax, %r14d
    addl    %r12d, %r14d           // h1 = h*PRIME + t0
    cmpl    %r10d, %eax
    cmovgl  %eax, %r10d
    cmovgl  %ecx, %r11d            // si h > maxh: maxh := h; maxi := i
    leal    1(%rcx), %edx
    cmpl    %r10d, %r14d
    cmovgl  %r14d, %r10d
    cmovgl  %edx, %r11d            // si h1 > maxh: maxh := h1; maxi := i+1
    imull   $0x25667, %r12d, %r12d
    addl    %r13d, %r12d
    imull   $0x76C55D71, %eax, %eax
    addl    %r12d, %eax            // h = h*PRIME^2 + (t0*PRIME + t1)
    addl    $2, %ecx
    cmpl    %r8d, %ecx
    jl      .Lrephash2
    movl    %eax, hh
    movl    %r10d, mh
    movl    %r11d, mi
  end ['rax', 'rcx', 'rdx', 'rsi', 'rdi', 'r8', 'r9', 'r10', 'r11', 'r12', 'r13', 'r14'];
  h := hh; maxh := mh; maxi := mi;
end;
{$ELSE}
const
  P2 = LongWord($76C55D71);   // PRIME^2 mod 2^32
var
  q: PByte;
  i, mi: LongInt;
  hh, h1, mh, t0, t1: LongWord;
begin
  q := p + L;
  hh := h; mh := maxh; mi := 0;
  i := 0;
  while i < L do
  begin
    t0 := LongWord(q[i]) - LongWord(p[i]) * pl;
    t1 := LongWord(q[i + 1]) - LongWord(p[i + 1]) * pl;
    h1 := hh * PRIME + t0;
    if LongInt(hh) > LongInt(mh) then begin mh := hh; mi := i; end;
    if LongInt(h1) > LongInt(mh) then begin mh := h1; mi := i + 1; end;
    hh := hh * P2 + (t0 * PRIME + t1);
    Inc(i, 2);
  end;
  h := hh; maxh := mh; maxi := mi;
end;
{$ENDIF}

{ Job::process: por cada bloque de L bytes guarda el hash máximo (con signo) de los L hashes
  rodantes que empiezan en él y su índice. }
procedure TRepEncStage.HashJob(Slot, BufPos, Bytes: LongInt);
var
  p, pe: PByte;
  hp: PLongInt;
  h, maxh: LongWord;
  i, maxi, blk, NumBlocks, L: LongInt;
  pl, pr: LongWord;
begin
  L := FL;
  pr := PRIME;
  NumBlocks := Bytes div L;
  if NumBlocks <= 0 then Exit;
  pl := FPowL;
  hp := @FHt[Slot];
  p := @FBuf[BufPos];
  h := 0;
  for i := 0 to L - 1 do h := h * pr + p[i];     // update_hash(0, buf[i])
  for blk := 0 to NumBlocks - 1 do
  begin
    maxh := h; maxi := 0;
    if not Odd(L) then
    begin
      RepHashEvenBlock(p, L, pl, h, maxh, maxi);   // de a dos pasos
      Inc(p, L);
    end
    else
    begin
      pe := p + L;
      i := 0;
      while p < pe do
      begin
        if LongInt(h) > LongInt(maxh) then begin maxh := h; maxi := i; end;
        h := h * pr + p[L] - LongWord(p[0]) * pl;  // update_hash(ptr[0], ptr[L])
        Inc(p); Inc(i);
      end;
    end;
    hp^ := LongInt(maxh); Inc(hp);
    hp^ := maxi; Inc(hp);
  end;
end;

{ Cola de rep_compress tras READ_LEN (bloque "ЧТЕНИЕ ВХОДНЫХ ДАННЫХ") }
procedure TRepEncStage.AfterRead(Size: LongInt);
var
  bytes, idx: LongInt;
  J: TRepJob;
  T: THashTask;
begin
  if FDoItOnce then begin EmitU32(LongWord(FBlockSize)); FDoItOnce := False; end;
  if Size = 0 then FMoreInput := False;
  Inc(FDataEnd, Size);
  bytes := FDataEnd - (FNextJobI + FL);
  if bytes <= 0 then
  begin
    if Size > 0 then Exit;     // continue: seguir leyendo sin encolar
    bytes := 0;                // trabajo vacío = fin de datos
  end;
  J.Slot := FHtIndex * FHtCount;
  J.BufPos := FNextJobI;
  J.Bytes := bytes;
  idx := (FJobHead + FJobCount) mod FHtBufs;
  // En el C lo hace un hilo; ver comentario de la unidad
  J.Busy := (FPool <> nil) and (bytes >= FL);
  if J.Busy then
  begin
    T := THashTask(FTasks[idx]);
    T.ResetForReuse;
    T.Slot := J.Slot; T.BufPos := J.BufPos; T.Bytes := J.Bytes;
    TJobPool(FPool).Submit(T);
  end
  else
    HashJob(J.Slot, J.BufPos, J.Bytes);
  FJobs[idx] := J;
  Inc(FJobCount);
  Inc(FNextJobI, bytes);
  FHtIndex := (FHtIndex + 1) mod FHtBufs;
  Dec(FFreeJobs);
end;

{ Bucle principal de búsqueda sobre los resultados de un trabajo de hashing.
  Rareza del C: consume ceil((next_fill-last_i)/L) pares aunque el trabajo haya escrito
  floor(bytes/L); si bytes no es múltiplo de L (última lectura parcial, o BlockSize que no es
  múltiplo de HTBLOCK/L) lee un par "viejo" de la ranura (cero o de un trabajo anterior).
  Eso es determinista y acá se reproduce igual, porque FHt tiene las mismas ranuras.
  Velocidad: casi todo el tiempo son fallos de caché (una lectura al azar de hasharr por
  bloque y otra de buf[match]); como los hashes de los bloques siguientes ya están en FHt, se
  adelantan esas lecturas con prefetch (solo dentro de la ranura de este trabajo: la siguiente
  puede estar escribiéndola un hilo de hashing). Las coincidencias se extienden de a 8 bytes
  (en little endian) con el mismo resultado que byte a byte. }
procedure TRepEncStage.ProcessJob(const J: TRepJob);
var
  hp, next_fill, hash, i, match, LowBound, HighBound, st, en, q, pm, offset, lim, SlotEnd, pf: LongInt;
  b: PByte;
  {$IFDEF ENDIAN_LITTLE}
  x: QWord;
  {$ENDIF}
begin
  b := @FBuf[0];
  hp := J.Slot;
  SlotEnd := J.Slot + FHtCount;
  next_fill := J.BufPos + J.Bytes;
  while FLastI < next_fill do
  begin
    if hp + 1 >= Length(FHt) then
      raise Exception.Create('rep: estado interno inconsistente (ht)');
    hash := FHt[hp];
    i := FHt[hp + 1] + FLastI;
    // La entrada de hasharr de REP_PF_HASH bloques más adelante y los datos del candidato de
    // REP_PF_DATA bloques más adelante (su entrada ya debería estar en caché). Solo adelanta
    // lecturas: el resultado no cambia.
    if hp + 2 * REP_PF_HASH < SlotEnd then
      prefetch(FHashArr[LongWord(FHt[hp + 2 * REP_PF_HASH]) and LongWord(FHashMask)]);
    if (REP_PF_DATA > 0) and (hp + 2 * REP_PF_DATA < SlotEnd) then
    begin
      pf := FHashArr[LongWord(FHt[hp + 2 * REP_PF_DATA]) and LongWord(FHashMask)];
      if pf > 0 then prefetch(b[pf - 1]);
    end;
    Inc(hp, 2);
    if i >= FLastMatch then
    begin
      match := FHashArr[LongWord(hash) and LongWord(FHashMask)];
      if (match <> 0) and not ((match >= i) and (match < FDataEnd)) then
      begin
        if match < i then LowBound := i - match
        else if match - FDataEnd > i then LowBound := 0
        else LowBound := i - (match - FDataEnd);
        HighBound := FBlockSize - match + i;
        // find_match_start(buf+match, buf+i, buf+max(last_match,LowBound))
        lim := FLastMatch; if LowBound > lim then lim := LowBound;
        q := i; pm := match;
        st := -1;
        {$IFDEF ENDIAN_LITTLE}
        // De a 8 bytes: el byte distinto más alto (Bsr) es el primero que encuentra el bucle
        while q - 8 >= lim do
        begin
          x := PQWord(b + q - 8)^ xor PQWord(b + pm - 8)^;
          if x <> 0 then begin st := q - 8 + LongInt(BsrQWord(x) shr 3) + 1; Break; end;
          Dec(q, 8); Dec(pm, 8);
        end;
        if st < 0 then
        {$ENDIF}
        begin
          while q > lim do
          begin
            Dec(pm); Dec(q);
            if b[pm] <> b[q] then begin st := q + 1; Break; end;
          end;
          if st < 0 then st := q;
        end;
        // find_match_end(buf+match, buf+i, buf+min(DataEnd,HighBound))
        lim := FDataEnd; if HighBound < lim then lim := HighBound;
        q := i; pm := match;
        {$IFDEF ENDIAN_LITTLE}
        // De a 8 bytes: el byte distinto más bajo (Bsf) es donde termina la coincidencia
        while q + 8 <= lim do
        begin
          x := PQWord(b + q)^ xor PQWord(b + pm)^;
          if x <> 0 then begin Inc(q, LongInt(BsfQWord(x) shr 3)); lim := q; Break; end;
          Inc(q, 8); Inc(pm, 8);
        end;
        {$ENDIF}
        while (q < lim) and (b[pm] = b[q]) do begin Inc(pm); Inc(q); end;
        en := q;
        if i - match < FBarrier then lim := FMinLen else lim := FSmallLen;
        if en - st >= lim then
        begin
          offset := i - match;
          if offset < 0 then Inc(offset, FBlockSize);
          Push(FDOffs, FNDOffs, FLastMatch);
          Push(FDLens, FNDLens, st - FLastMatch);
          Push(FOffs, FNOffs, offset);
          Push(FLens, FNLens, en - st);
          Inc(FLiterals, st - FLastMatch);
          FLastMatch := en;
        end;
      end;
    end;
    // no_match: el bloque entra al hash
    FHashArr[LongWord(hash) and LongWord(FHashMask)] := i;
    Inc(FLastI, FL);
  end;
end;

{ encode_data: cierra y emite un bloque }
procedure TRepEncStage.EncodeBlock;
var
  Hdr: array of Byte;
  outsize, k, n, pos: LongInt;

  procedure Put(V: LongInt);
  begin
    Hdr[pos] := Byte(V); Hdr[pos + 1] := Byte(V shr 8);
    Hdr[pos + 2] := Byte(V shr 16); Hdr[pos + 3] := Byte(V shr 24);
    Inc(pos, 4);
  end;

begin
  if (FNextFlush = FBlockSize) or not FMoreHashed then FLastI := FDataEnd;
  if FLastMatch > FLastI then
    Push(FDLens, FNDLens, 0)   // datalens siempre tiene num+1 entradas
  else
  begin
    Push(FDOffs, FNDOffs, FLastMatch);
    Push(FDLens, FNDLens, FLastI - FLastMatch);
    Inc(FLiterals, FLastI - FLastMatch);
    FLastMatch := FLastI;
  end;
  if FNextFlush = FBlockSize then
  begin
    // Fin de la ventana: seguir llenándola desde el principio (las lecturas nuevas pisan FBuf
    // desde 0: ningún hashing en vuelo puede estar leyendo ahí)
    if FPool <> nil then DrainTasks;
    FDataEnd := 0; FLastMatch := 0; FLastI := 0; FNextJobI := 0; FNextFlush := 0;
  end;
  outsize := 4 * 2 + 4 * FNLens + 4 * FNOffs + 4 * FNDLens + FLiterals;
  SetLength(Hdr, 8 + 4 * (FNLens + FNOffs + FNDLens));
  pos := 0;
  Put(outsize - 4);
  Put(FNLens);
  for k := 0 to FNLens - 1 do Put(FLens[k]);
  for k := 0 to FNOffs - 1 do Put(FOffs[k]);
  for k := 0 to FNDLens - 1 do Put(FDLens[k]);
  Emit(@Hdr[0], pos);
  // Literales: pares (dataOffsets[k], datalens[k])
  for k := 0 to FNDOffs - 1 do
  begin
    n := FDLens[k];
    if n > 0 then Emit(@FBuf[FDOffs[k]], n);
  end;
end;

{ Máquina de estados equivalente a los bucles de rep_compress; se detiene solo cuando una
  lectura no puede completarse todavía (faltan datos y no es el Finish). }
procedure TRepEncStage.Pump;
var
  J: TRepJob;
  datalen: LongInt;
begin
  repeat
    case FState of
      stNotStarted, stOuter:
        begin
          // while (MoreHashedData): vaciar tablas y fijar el próximo límite de 8 MB
          FNLens := 0; FNOffs := 0; FNDLens := 0; FNDOffs := 0; FLiterals := 0;
          if FBlockSize - FNextFlush < MAX_BLOCK then Inc(FNextFlush, FBlockSize - FNextFlush)
          else Inc(FNextFlush, MAX_BLOCK);
          FState := stInner;
        end;
      stInner:
        if FLastI + FL < FNextFlush then FState := stRead else FState := stEncode;
      stRead:
        if (FFreeJobs > 0) and (FDataEnd < FBlockSize) and FMoreInput then
        begin
          FReqSize := FBlockSize - FDataEnd;
          if FReqSize > FHtBlock then FReqSize := FHtBlock;
          FGot := 0;
          EnsureCap(FDataEnd + FReqSize);
          FState := stWaitRead;
        end
        else
          FState := stGet;
      stWaitRead:
        begin
          if (FGot < FReqSize) and not FFinal then Exit;
          AfterRead(FGot);
          FState := stRead;
        end;
      stGet:
        begin
          // HashingThreads.Get(): en el C, sin trabajos pendientes se colgaría
          if FJobCount = 0 then raise Exception.Create('rep: estado interno inconsistente (sin trabajos)');
          WaitTask(FJobHead);
          J := FJobs[FJobHead];
          FJobHead := (FJobHead + 1) mod FHtBufs;
          Dec(FJobCount);
          Inc(FFreeJobs);
          if J.Bytes = 0 then
          begin
            FMoreHashed := False;
            FState := stEncode;
          end
          else
          begin
            ProcessJob(J);
            FState := stInner;
          end;
        end;
      stEncode:
        begin
          EncodeBlock;
          if FMoreHashed then FState := stOuter else FState := stFinal;
        end;
      stFinal:
        begin
          // Bloque final con el resto sin comprimir (en la práctica vacío) y el 0 de fin
          datalen := FDataEnd - FLastMatch;
          if datalen <> 0 then
          begin
            EmitU32(LongWord(8 + datalen));
            EmitU32(0);
            EmitU32(LongWord(datalen));
            Emit(@FBuf[FLastMatch], datalen);
          end;
          EmitU32(0);
          FState := stDone;
        end;
    else
      Exit;   // stDone
    end;
  until False;
end;

procedure TRepEncStage.DoWrite(Buf: PByte; Count: SizeInt);
var
  n: SizeInt;
begin
  if FState = stNotStarted then Pump;
  while Count > 0 do
  begin
    if FState <> stWaitRead then raise Exception.Create('rep: estado interno inconsistente (escritura)');
    n := FReqSize - FGot;
    if n > Count then n := Count;
    Move(Buf^, FBuf[FDataEnd + FGot], n);
    Inc(FGot, n);
    Inc(Buf, n);
    Dec(Count, n);
    if FGot = FReqSize then Pump;
  end;
end;

procedure TRepEncStage.DoFinish;
begin
  FFinal := True;
  Pump;
  if FPool <> nil then DrainTasks;
  // La memoria grande ya no hace falta
  FBuf := nil; FHashArr := nil; FHt := nil;
end;

end.
