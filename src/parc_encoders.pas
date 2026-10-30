{ Codificadores y armado de cadenas de compresión. Un método "a+b+c" se comprime
  datos -> a -> b -> c -> destino (el espejo de parc_methods.CreateDecoderChain). }
unit parc_encoders;

{$mode objfpc}{$H+}

interface

uses
  SysUtils, parc_outstream;

type
  EUnsupportedEncoder = class(Exception);

  { exe (BCJ x86) al comprimir: como bcj_x86_de_compress con encoding=1, convierte buffers
    llenos y guarda para el próximo lo que el filtro no llegó a procesar; un tramo final de
    <=5 bytes sale sin convertir. }
  TBcjEncStage = class(TOutStage)
  private
    FBuf: array of Byte;
    FLen: SizeInt;
    FIp, FState: LongWord;
    procedure Convert(Final: Boolean);
  protected
    procedure DoWrite(Buf: PByte; Count: SizeInt); override;
    procedure DoFinish; override;
  public
    constructor Create(ATarget: TOutStage);
  end;

  { srep (Compression/SREP): se acumula el bloque y se codifica en DoFinish; el bloque de
    FreeArc antepone un byte (1 = stream srep, 0 = guardado tal cual si no conviene). }
  TSrepEncStage = class(TOutStage)
  private
    FData: TBytes;
    FLen: SizeInt;
  protected
    procedure DoWrite(Buf: PByte; Count: SizeInt); override;
    procedure DoFinish; override;
  public
    constructor Create(ATarget: TOutStage);
  end;

  { dispack (C_DisPack.cpp, DISPACK_METHOD::compress): junta tramos de 16 KB que parecen
    ejecutable, los filtra con DisPackFilter y los escribe con tag; el resto va como datos.
    Acá se acumula el bloque entero y se codifica en DoFinish. }
  TDisPackEncStage = class(TOutStage)
  private
    FData: TBytes;
    FLen: SizeInt;
    FBlockSize: Integer;
  protected
    procedure DoWrite(Buf: PByte; Count: SizeInt); override;
    procedure DoFinish; override;
  public
    constructor Create(ATarget: TOutStage; ABlockSize: Integer);
  end;

  { 4x4 al comprimir (_4x4MTCompressor, C_4x4.cpp): U32 versión 0 y, por cada bloque de
    BlockSize bytes, [Int32 tamaño original, o -1 si se guardó sin comprimir][U32 largo][datos].
    Los bloques se comprimen en paralelo con el método interno y se escriben en orden. }
  T4x4EncStage = class(TOutStage)
  private
    FInner: string;
    FBlockSize: SizeInt;
    FCur: TBytes;           // bloque que se está llenando
    FLen: SizeInt;
    FPool: TObject;         // TJobPool
    FQueue: array of TObject;   // trabajos en vuelo, en orden
    FHead, FCount: Integer;
    FFree: array of TBytes;     // buffers de entrada ya escritos, para reciclar (sin ceros ni faltas de página)
    FNumFree: Integer;
    FTorCache: TObject;         // motores de tor reusados entre bloques (TTorEncCache)
    FHint, FIn: Int64;          // entrada esperada del bloque sólido (0: no se sabe) y recibida
    FTarget: SizeInt;           // tamaño del bloque que se está llenando (<= FBlockSize)
    procedure SubmitBlock;
    procedure WriteOldest;
  protected
    procedure DoWrite(Buf: PByte; Count: SizeInt); override;
    procedure DoFinish; override;
  public
    { 4x4:r<N>: con entropía order-0 >= N% un bloque ni se intenta comprimir (default 99) }
    MinOrder0Ratio: Double;
    constructor Create(ATarget: TOutStage; const AInner: string; ABlockSize: SizeInt);
    destructor Destroy; override;
  end;

var
  { Bytes de entrada de todo lo que se va a comprimir (lo fija el escritor del archivo; 0 si no
    se sabe, p. ej. -si). Con pocos datos para los hilos, 4x4 achica sus bloques (ver
    Adaptive4x4Block). }
  Enc4x4TotalHint: Int64 = 0;

threadvar
  { Bytes de entrada del bloque sólido cuya cadena se está armando en este hilo (0: no se
    sabe): con varios hilos, 4x4 achica sus últimos bloques (ver T4x4EncStage.DoWrite). }
  Enc4x4BlockHint: Int64;

{ Arma la cadena de codificadores delante de Target (la cadena pasa a ser dueña de Target). }
function CreateEncoderChain(const Method: string; Target: TOutStage): TOutStage;

{ Comprime un bloque de control en memoria. }
function CompressMem(const Method: string; Src: PByte; SrcLen: SizeInt): TBytes;

{ Como SetDictionary de FreeArc: achica el diccionario de lzma (d<mem> o la memoria sin nombre)
  a la potencia de 2 >= DataSize (mínimo 64kb). El método ajustado es el que se guarda en el
  archivo, así que el descompresor también reserva solo eso. }
function LimitMethodToSize(const Method: string; DataSize: Int64): string;

{ True si CreateEncoderChain sabe comprimir con Method (sin crear nada). }
function EncoderAvailable(const Method: string): Boolean;

{ Etapa de cifrado para escribir un bloque, como generateEncryption de FreeArc: Algorithm es
  el de --encryption ("aes", "blowfish-448/cfb", ...), Password en UTF-8. Devuelve la etapa
  para el codificador (con :k) y en Stored la que se guarda en el archivo (sal, check-code e
  IV, sin la clave). Sal e IV son nuevos en cada llamado: uno por bloque, como FreeArc. }
const
  PARC_KDF_ITERATIONS = 200000;   // ~0,6 s por derivación (una por archivo)

function MakeCipherStage(const Algorithm: string; const Password: RawByteString; out Stored: string;
  Parc: Boolean): string;

{ Method sin sus etapas de cifrado (la de un bloque viejo que se reempaqueta: la que quedó en
  el archivo no trae la clave y no sirve para comprimir). }
function WithoutCipher(const Method: string): string;

implementation

uses
  Math, parc_filters, parc_ppmd, parc_methods, parc_lzp, parc_parallel, parc_lzmaenc,
  parc_repenc, parc_deltaenc, parc_dictenc, parc_ttaenc, parc_mmenc, parc_torenc, parc_grzipenc,
  parc_crypt, parc_canon, parc_lz4enc, parc_dispack, parc_srep, parc_cm, parc_bcj2;

{ ¿La etapa es de cifrado? El nombre va antes de '-' (bits) o '/' (modo): "aes-256/ctr". }
function IsCipherStage(const Stage: string): Boolean;
var
  Name: string;
  p: Integer;
begin
  Name := Stage.Split([':'])[0];
  p := Pos('-', Name); if p > 0 then Name := Copy(Name, 1, p - 1);
  p := Pos('/', Name); if p > 0 then Name := Copy(Name, 1, p - 1);
  Result := IsCipherName(Name);
end;

function StageName(const Stage: string): string; forward;
function FastInner4x4(const Inner: string): Boolean; forward;

type
  T4x4EncJob = class(TParallelJob)
  public
    Inner: string;
    InBuf: TBytes;          // el bloque del escritor (se le devuelve para reciclarlo)
    InLen: SizeInt;         // bytes válidos de InBuf (un buffer reciclado puede ser más largo)
    OrigSize: SizeInt;
    Stored: Boolean;
    MinOrder0Ratio: Double;
    TorCache: TObject;      // TTorEncCache de la etapa (nil si el método interno no es tor)
    procedure ProcessBlock;
    procedure Process; override;
  end;

{ order0_compression_ratio (C_4x4.cpp:115): entropía order-0 del bloque / su tamaño. }
function Order0Ratio(Buf: PByte; Size: SizeInt): Double;
var
  Count: array[0..255] of SizeInt;
  i: SizeInt;
  c: Integer;
begin
  FillChar(Count, SizeOf(Count), 0);
  for i := 0 to Size - 1 do Inc(Count[Buf[i]]);   // (el C cuenta de a 4; la suma es la misma)
  Result := 0;
  for c := 0 to 255 do
    if Count[c] <> 0 then
      Result := Result + Count[c] * Log2(Size / Count[c]) / 8;
  Result := Result / Size;
end;

{ Fracción de Buf[0..Size) cubierta por repeticiones de 8 bytes o más dentro del mismo trozo
  (hash de 4 bytes, la última posición por hash, voraz): una estimación barata de lo que un LZ
  puede sacar que el order-0 no ve. }
function RepeatCoverage(Buf: PByte; Size: SizeInt): Double;
const
  HBITS = 16;
var
  h: array of LongInt;
  i, c, l, cov: SizeInt;
  k: LongWord;
begin
  SetLength(h, 1 shl HBITS);
  FillChar(h[0], Length(h) * SizeOf(LongInt), $FF);
  cov := 0;
  i := 0;
  while i + 8 <= Size do
  begin
    k := LongWord(PLongWord(Buf + i)^ * LongWord(2654435761)) shr (32 - HBITS);
    c := h[k];
    h[k] := i;
    if (c >= 0) and (PQWord(Buf + c)^ = PQWord(Buf + i)^) then
    begin
      l := 8;
      while (i + l < Size) and (Buf[c + l] = Buf[i + l]) do Inc(l);
      Inc(cov, l);
      Inc(i, l);
      Continue;
    end;
    Inc(i);
  end;
  Result := cov / Size;
end;

{ ¿Vale la pena intentar comprimir un bloque que tiene order-0 >= Ratio? FreeArc no lo
  intenta nunca, pero un bloque con unos MB comprimibles entre datos aleatorios tiene el
  order-0 del promedio (slice TILIN @488 MB, 8 MB: 0,9958; lzma lo deja en 0,977), y datos
  aleatorios repetidos tienen order-0 1. Se mira cada trozo de ~1 MB: si alguno repite
  (RepeatCoverage >= 4 %), sí. JPEG/MP3 casi no repiten (< 2 %) y siguen sin intentarse. }
function WorthTrying(Buf: PByte; Size: SizeInt): Boolean;
const
  PIECE = 1 shl 20;
var
  o, n: SizeInt;
begin
  o := 0;
  while o < Size do
  begin
    n := Size - o;
    if n - PIECE >= 64 * 1024 then n := PIECE;   // un resto de menos de 64 KB va con el último
    if RepeatCoverage(Buf + o, n) >= 0.04 then Exit(True);
    Inc(o, n);
  end;
  Result := False;
end;

procedure T4x4EncJob.Process;
var
  OldSingle: Boolean;
begin
  // 4x4 ya reparte los bloques entre hilos. Se restaura: el trabajo puede correr en el hilo
  // que lo espera (sin fichas libres), y ese hilo después puede usar LZMA multihilo
  OldSingle := LzmaSingleThreadHere;
  LzmaSingleThreadHere := True;
  try
    ProcessBlock;
  finally
    LzmaSingleThreadHere := OldSingle;
  end;
end;

procedure T4x4EncJob.ProcessBlock;
begin
  // Como _4x4MTCompressor::Process: un bloque de >= 32 KB casi aleatorio (order-0 >= r%) ni
  // se intenta, salvo que tenga trozos que sí se pueden comprimir (WorthTrying); y si no
  // comprime, va guardado tal cual
  if (MinOrder0Ratio <> 0) and (InLen >= 32 * 1024) and
     (Order0Ratio(PByte(InBuf), InLen) >= MinOrder0Ratio) and
     not WorthTrying(PByte(InBuf), InLen) then
    Stored := True
  else if StageName(Inner) = 'lz4' then
    // LZ4_METHOD::DeCompressMem: versión + un solo bloque LZ4 (no el stream por bloques)
    Stored := not Lz4EncodeMem(Inner.Split([':']), PByte(InBuf), InLen, OutBuf)
  else if StageName(Inner) = 'tor' then
    // TORNADO_METHOD::DeCompressMem con compress_all_at_once=1; OutputSize = InSize
    Stored := not TorEncodeMem(Inner.Split([':']), PByte(InBuf), InLen, InLen, OutBuf, TorCache)
  else
  begin
    OutBuf := CompressMem(Inner, PByte(InBuf), InLen);
    Stored := Length(OutBuf) >= InLen;
  end;
  // Guardado: se escribe InBuf tal cual (OutBuf no se usa)
  if Stored then OutSize := InLen else OutSize := Length(OutBuf);
end;

{ T4x4EncStage }

const
  { Tope de hilos de un 4x4 (como el decodificador: más allá, contención del heap) }
  T4X4_MAXTHREADS = 16;

constructor T4x4EncStage.Create(ATarget: TOutStage; const AInner: string; ABlockSize: SizeInt);
var
  Threads: Integer;
begin
  if not EncoderAvailable(AInner) then
    raise EUnsupportedEncoder.CreateFmt('cannot compress with "%s" yet', [AInner]);
  if ABlockSize < 4096 then ABlockSize := 4096;
  inherited Create(ATarget);
  FInner := AInner;
  FBlockSize := ABlockSize;
  MinOrder0Ratio := 0.99;
  // Hilos según el presupuesto (o la parte de este bloque, si hay bloques en paralelo); la
  // cola crece después si sobran fichas (SubmitBlock). Con un solo hilo, todo en línea
  Threads := PoolWorkers(T4X4_MAXTHREADS);
  if Threads > 0 then SetLength(FQueue, Threads + 1) else SetLength(FQueue, 1);
  FPool := TJobPool.Create(Threads, Length(FQueue));
  if StageName(AInner) = 'tor' then FTorCache := TTorEncCache.Create;
  if (BudgetThreads >= 2) and FastInner4x4(AInner) then FHint := Enc4x4BlockHint;
  EmitU32(0);   // versión del formato 4x4 (se escribe aunque no haya datos, como el C)
end;

destructor T4x4EncStage.Destroy;
var
  i: Integer;
begin
  FPool.Free;
  for i := 0 to FCount - 1 do FQueue[(FHead + i) mod Length(FQueue)].Free;
  FTorCache.Free;      // después del pool: ningún trabajo usa ya sus motores
  inherited Destroy;
end;

procedure T4x4EncStage.WriteOldest;
var
  Job: T4x4EncJob;
begin
  Job := T4x4EncJob(FQueue[FHead]);
  FHead := (FHead + 1) mod Length(FQueue);
  Dec(FCount);
  try
    TJobPool(FPool).WaitJob(Job);
    // Encabezado del bloque: tamaño original (-1 = guardado) y largo de los datos
    if Job.Stored then EmitU32($FFFFFFFF) else EmitU32(LongWord(Job.OrigSize));
    EmitU32(LongWord(Job.OutSize));
    if Job.Stored then Emit(PByte(Job.InBuf), Job.OutSize)
    else Emit(PByte(Job.OutBuf), Job.OutSize);
    // Ya escrito: el buffer de entrada vuelve al escritor para el próximo bloque
    if FNumFree >= Length(FFree) then SetLength(FFree, FNumFree + 4);
    FFree[FNumFree] := Job.InBuf;
    Inc(FNumFree);
    Job.InBuf := nil;
  finally
    Job.Free;
  end;
end;

procedure T4x4EncStage.SubmitBlock;
var
  Job: T4x4EncJob;
  Q: array of TObject;
  i, w: Integer;
begin
  if FLen = 0 then Exit;
  if FCount = Length(FQueue) then
  begin
    // Cola llena: si todos los hilos están trabajando, un bloque y un hilo más en vez de
    // esperar al más viejo (este hilo iba a soltar su ficha: la usa el nuevo)
    w := TJobPool(FPool).MaxWorkers;
    if TJobPool(FPool).CanGrow(T4X4_MAXTHREADS) then
    begin
      SetLength(Q, Length(FQueue) + 1);
      for i := 0 to FCount - 1 do Q[i] := FQueue[(FHead + i) mod Length(FQueue)];
      FQueue := Q;
      FHead := 0;
      TJobPool(FPool).SetMaxWorkers(w + 1);
    end
    else
      WriteOldest;
  end;
  Job := T4x4EncJob.Create;
  Job.Inner := FInner;
  // Sin copiar: el bloque lleno pasa al trabajo y se sigue llenando un buffer reciclado
  Job.InBuf := FCur;
  Job.InLen := FLen;
  Job.OrigSize := FLen;
  FCur := nil;
  if FNumFree > 0 then
  begin
    Dec(FNumFree);
    FCur := FFree[FNumFree];
    FFree[FNumFree] := nil;
  end;
  Job.MinOrder0Ratio := MinOrder0Ratio;
  Job.TorCache := FTorCache;
  FQueue[(FHead + FCount) mod Length(FQueue)] := Job;
  Inc(FCount);
  TJobPool(FPool).Submit(Job);
  FLen := 0;
end;

procedure T4x4EncStage.DoWrite(Buf: PByte; Count: SizeInt);
const
  MB = 1 shl 20;
var
  n: SizeInt;
  Rem, Low: Int64;
begin
  while Count > 0 do
  begin
    if Length(FCur) = 0 then SetLength(FCur, FBlockSize);
    if FLen = 0 then
    begin
      // Bloque nuevo. Cerca del final del bloque sólido (menos de dos bloques por llegar), un
      // cuarto de lo que falta, hasta FBlockSize/4: el final son varios bloques chicos que
      // terminan casi juntos en vez de uno o dos grandes con los demás hilos sin trabajo. Lo
      // que falta se estima con el tamaño de entrada del bloque sólido (con rep delante llega
      // menos, y el final más chico casi no se da), así que solo depende de los datos: la
      // salida es la misma en cada corrida
      FTarget := FBlockSize;
      Rem := FHint - FIn;
      if (FHint > 0) and (Rem < 2 * Int64(FBlockSize)) then
      begin
        Low := FBlockSize div 4;
        if Low < MB then Low := MB;
        if (Rem + 3) div 4 > Low then Low := (Rem + 3) div 4;
        if Low < FTarget then FTarget := Low;
      end;
    end;
    n := FTarget - FLen;
    if n > Count then n := Count;
    Move(Buf^, FCur[FLen], n);
    Inc(FLen, n);
    Inc(FIn, n);
    Inc(Buf, n);
    Dec(Count, n);
    if FLen = FTarget then SubmitBlock;
  end;
end;

procedure T4x4EncStage.DoFinish;
begin
  SubmitBlock;
  while FCount > 0 do WriteOldest;
end;


const
  BCJ_ENC_BUFFER = 1 shl 20;

{ TBcjEncStage }

constructor TBcjEncStage.Create(ATarget: TOutStage);
begin
  inherited Create(ATarget);
  SetLength(FBuf, BCJ_ENC_BUFFER);
end;

procedure TBcjEncStage.Convert(Final: Boolean);
var
  Done, Rem: SizeInt;
begin
  if FLen = 0 then Exit;
  if FLen <= 5 then
    Done := FLen    // FreeArc: menos de 5 bytes el filtro no los toca
  else
  begin
    Done := BcjX86Code(@FBuf[0], FLen, FIp, FState, True);
    if Final and (Done = 0) then Done := FLen;
  end;
  Inc(FIp, LongWord(Done));
  Emit(@FBuf[0], Done);
  Rem := FLen - Done;
  if Rem > 0 then Move(FBuf[Done], FBuf[0], Rem);
  FLen := Rem;
end;

procedure TBcjEncStage.DoWrite(Buf: PByte; Count: SizeInt);
var
  n: SizeInt;
begin
  while Count > 0 do
  begin
    n := Length(FBuf) - FLen;
    if n > Count then n := Count;
    Move(Buf^, FBuf[FLen], n);
    Inc(FLen, n);
    Inc(Buf, n);
    Dec(Count, n);
    if FLen = Length(FBuf) then Convert(False);
  end;
end;

procedure TBcjEncStage.DoFinish;
begin
  // Como el bucle de FreeArc al llegar al final: convertir lo que quede hasta que el
  // remanente sea <=5 bytes (que sale sin convertir)
  while FLen > 0 do Convert(True);
end;

{ Fábrica }

function StageName(const Stage: string): string;
var
  p: Integer;
begin
  p := Pos(':', Stage);
  if p > 0 then Result := Copy(Stage, 1, p - 1) else Result := Stage;
end;

{ Método interno de 4x4 y tamaño de bloque: b<mem> explícito o, como _4x4MTCompressor, el
  diccionario del método interno (la primera memoria con sufijo de sus parámetros); 8mb si no. }
procedure Parse4x4(const Stage: string; out Inner: string; out BlockSize: SizeInt);
var
  Params: TStringArray;
  k, j: Integer;
  m: QWord;
begin
  Params := Stage.Split([':']);
  Inner := 'tor:3:1mb';
  BlockSize := 0;
  for k := 1 to High(Params) do
    if (Params[k] <> '') and ((Params[k][1] in ['0'..'9']) or
       ((Length(Params[k]) > 1) and (Params[k][2] in ['0'..'9']))) then
    begin
      if (Params[k][1] = 'b') and ParseMem(Copy(Params[k], 2, MaxInt), m) then BlockSize := m;
    end
    else
    begin
      Inner := string.Join(':', Params, k, Length(Params) - k);
      Break;
    end;
  if (BlockSize = 0) and (StageName(Inner) = 'tor') then
    BlockSize := TorDictionary(Inner.Split([':']));    // cmethod->GetDictionary()
  if (BlockSize = 0) and (StageName(Inner) = 'lz4') and Lz4EncAvailable(Inner) then
    BlockSize := ParseLz4EncParams(Inner.Split([':'])).BlockSize;   // LZ4_METHOD::GetDictionary
  if BlockSize = 0 then
  begin
    Params := Inner.Split([':']);
    for j := 1 to High(Params) do
      if (Params[j] <> '') and (Params[j][1] in ['0'..'9']) and (StrToIntDef(Params[j], -1) < 0) and
         ParseMem(Params[j], m) then
      begin
        BlockSize := m;
        Break;
      end;
  end;
  if BlockSize = 0 then BlockSize := 8 shl 20;
end;

{ Tamaño de bloque de 4x4 según los datos y los hilos: si todo lo que se comprime
  (Enc4x4TotalHint) no da al menos 3 bloques por hilo, los bloques se achican hasta eso (en MB
  enteros, como mucho a la cuarta parte y no menos de 1 MB). Si no, el final de cada archivo
  era uno o dos bloques grandes con los demás hilos sin trabajo (exe -m1, 4 hilos: 8 bloques
  de 16 MB). El tamaño depende solo de los datos y de PARC_THREADS: la salida es la misma en
  cada corrida con el mismo N. Bloques más chicos limitan la ventana del método interno (en
  datos de muchos archivos casi no cuesta; en un archivo grande la regla no cambia nada). }
function Adaptive4x4Block(BlockSize: SizeInt): SizeInt;
const
  MB = 1 shl 20;
var
  Want, c: Int64;
begin
  Result := BlockSize;
  if (BudgetThreads < 2) or (Enc4x4TotalHint <= 0) or (BlockSize <= MB) then Exit;
  Want := 3 * BudgetThreads;
  if Enc4x4TotalHint div BlockSize >= Want then Exit;
  c := (Enc4x4TotalHint + Want - 1) div Want;
  c := (c + MB - 1) div MB * MB;
  if c < BlockSize div 4 then c := BlockSize div 4;
  if c < MB then c := MB;
  if c < BlockSize then Result := c;
end;

{ ¿Método interno rápido (tor, lz4, lzma fast)? Solo con esos 4x4 achica bloques
  (Adaptive4x4Block y el final de T4x4EncStage.DoWrite): son los niveles -m1..-m3, donde el
  tiempo pesa; con lzma normal/max, ppmd, etc. el bloque grande vale más por el tamaño (y
  esos niveles ya sobran en velocidad). }
function FastInner4x4(const Inner: string): Boolean;
begin
  case StageName(Inner) of
    'tor', 'lz4': Result := True;
    'lzma': Result := ParseLzmaEncParams(Inner.Split([':'])).Algorithm = 0;
  else
    Result := False;
  end;
end;

{ ¿El método 4x4 fija su tamaño de bloque (b<mem>)? }
function Has4x4BlockParam(const Stage: string): Boolean;
var
  Params: TStringArray;
  k: Integer;
begin
  Params := Stage.Split([':']);
  Result := False;
  for k := 1 to High(Params) do
    if (Params[k] <> '') and ((Params[k][1] in ['0'..'9']) or
       ((Length(Params[k]) > 1) and (Params[k][2] in ['0'..'9']))) then
    begin
      if Params[k][1] = 'b' then Exit(True);
    end
    else
      Break;   // desde acá, el método interno
end;

function LimitMethodToSize(const Method: string; DataSize: Int64): string;
begin
  // limitDictionary + el texto canónico de cada compresor (parc_canon, PA-Lab): el mismo
  // método que guarda FreeArc para un bloque de ese tamaño
  Result := LimitAndCanonize(Method, DataSize);
end;

function EncoderAvailable(const Method: string): Boolean;
var
  Stage, Inner: string;
  Bs: SizeInt;
begin
  for Stage in Method.Split(['+']) do
    if IsCipherStage(Stage) then Continue
    else case StageName(Stage) of
      '4x4':
        begin
          Parse4x4(Stage, Inner, Bs);
          if not EncoderAvailable(Inner) then Exit(False);
        end;
      'tor': if not TorEncAvailable(Stage) then Exit(False);
      'lz4': if not Lz4EncAvailable(Stage) then Exit(False);
      'storing', 'exe', 'ppmd', 'lzp', 'lzma', 'rep', 'delta', 'dict', 'tta', 'mm', 'grzip', 'cm',
      'dispack', 'dispack070', 'srep', 'bcj2', 'exe2': ;
    else
      Exit(False);
    end;
  Result := True;
end;

function CreateStage(const Stage: string; Target: TOutStage): TOutStage;
var
  pp: TPpmdParams;
  Parts: TStringArray;
  Inner: string;
  Bs: SizeInt;
  mc, k: Integer;
begin
  Parts := Stage.Split([':']);
  if IsCipherStage(Stage) then Exit(TEncryptStage.Create(Target, ParseCryptParams(Parts)));
  case StageName(Stage) of
    '4x4':
      begin
        Parse4x4(Stage, Inner, Bs);
        if not Has4x4BlockParam(Stage) and FastInner4x4(Inner) then Bs := Adaptive4x4Block(Bs);
        Result := T4x4EncStage.Create(Target, Inner, Bs);
        // r<percent> (antes del método interno)
        for k := 1 to High(Parts) do
        begin
          if Pos(Parts[k], Inner) = 1 then Break;
          if (Length(Parts[k]) > 1) and (Parts[k][1] = 'r') then
            T4x4EncStage(Result).MinOrder0Ratio := StrToFloatDef(Copy(Parts[k], 2, MaxInt), 99, DefaultFormatSettings) / 100;
        end;
      end;
    'storing': Result := TStoringStage.Create(Target);
    'cm':      Result := TCmEncStage.Create(Target);
    'rep':     Result := TRepEncStage.Create(Target, Parts);
    'delta':   Result := TDeltaEncStage.Create(Target, Parts);
    'dict':    Result := TDictEncStage.Create(Target, Parts);
    'tor':     Result := TTorEncStage.Create(Target, Parts);
    'lz4':     Result := TLz4EncStage.Create(Target, Parts);
    'grzip':   Result := TGrzipEncStage.Create(Target, Parts);
    'tta':     Result := TTtaEncStage.Create(Target, Parts);
    'mm':      Result := TMmEncStage.Create(Target, Parts);
    'lzma':
      // Con marca de fin: en los bloques de datos el decodificador de FreeArc la exige
      Result := TLzmaEncStage.Create(Target, ParseLzmaEncParams(Parts), True);
    'exe':     Result := TBcjEncStage.Create(Target);
    'bcj2', 'exe2': Result := TBcj2EncStage.Create(Target);
    'dispack', 'dispack070':
      Result := TDisPackEncStage.Create(Target, DispackBlockSize(Parts));
    'srep':
      Result := TSrepEncStage.Create(Target);
    'lzp':
      begin
        { MinCompression ("N%"): lo usa solo el compresor; ParseLzpParams lo saltea. }
        mc := 0;
        for k := 1 to High(Parts) do
          if (Parts[k] <> '') and (Parts[k][Length(Parts[k])] = '%') then
            mc := StrToIntDef(Copy(Parts[k], 1, Length(Parts[k]) - 1), 0);
        Result := TLzpEncStage.Create(Target, ParseLzpParams(Parts), mc);
      end;
    'ppmd':
      begin
        // La misma sintaxis que el decodificador (parse_PPMD): una sola implementación
        pp := ParsePpmdParams(Parts);
        Result := TPpmdEncStage.Create(Target, pp.Order, pp.Mem, pp.MRMethod, pp.Chunk);
      end;
  else
    raise EUnsupportedEncoder.CreateFmt('cannot compress with "%s" yet', [Stage]);
  end;
end;

{ TSrepEncStage }

constructor TSrepEncStage.Create(ATarget: TOutStage);
begin
  inherited Create(ATarget);
  FData := nil;
  FLen := 0;
end;

procedure TSrepEncStage.DoWrite(Buf: PByte; Count: SizeInt);
var
  Cap: SizeInt;
begin
  if Count <= 0 then Exit;
  if FLen + Count > Length(FData) then
  begin
    Cap := Length(FData);
    if Cap = 0 then Cap := 64 * 1024;
    while Cap < FLen + Count do Cap := Cap * 2;
    SetLength(FData, Cap);
  end;
  Move(Buf^, FData[FLen], Count);
  Inc(FLen, Count);
end;

procedure TSrepEncStage.DoFinish;
var
  Enc: TBytes;
  Flag: Byte;
begin
  if FLen > 0 then
  begin
    Enc := SrepEncode(@FData[0], FLen);
    if (Length(Enc) = 0) or (Length(Enc) >= FLen) then
    begin
      // no conviene: se guarda tal cual (0)
      Flag := 0;
      Emit(@Flag, 1);
      Emit(@FData[0], FLen);
    end
    else
    begin
      Flag := 1;
      Emit(@Flag, 1);
      Emit(@Enc[0], Length(Enc));
    end;
  end;
  inherited DoFinish;
end;

{ TDisPackEncStage }

constructor TDisPackEncStage.Create(ATarget: TOutStage; ABlockSize: Integer);
begin
  inherited Create(ATarget);
  FBlockSize := ABlockSize;
  if FBlockSize <= 0 then FBlockSize := DISPACK_BLOCK;
  FData := nil;
  FLen := 0;
end;

procedure TDisPackEncStage.DoWrite(Buf: PByte; Count: SizeInt);
var
  Cap: SizeInt;
begin
  if Count <= 0 then Exit;
  if FLen + Count > Length(FData) then
  begin
    Cap := Length(FData);
    if Cap = 0 then Cap := 64 * 1024;
    while Cap < FLen + Count do Cap := Cap * 2;
    SetLength(FData, Cap);
  end;
  Move(Buf^, FData[FLen], Count);
  Inc(FLen, Count);
end;

procedure TDisPackEncStage.DoFinish;
var
  Enc: TBytes;
begin
  if FLen > 0 then
  begin
    Enc := DispackEncode(@FData[0], FLen, FBlockSize);
    if Length(Enc) > 0 then Emit(@Enc[0], Length(Enc));
  end;
  inherited DoFinish;
end;

function CreateEncoderChain(const Method: string; Target: TOutStage): TOutStage;
var
  Stages: TStringArray;
  k: Integer;
begin
  // Validar todo antes de crear nada: si no, habría que desarmar la cadena a medias
  if not EncoderAvailable(Method) then
  begin
    Target.Free;
    raise EUnsupportedEncoder.CreateFmt('cannot compress with "%s" yet', [Method]);
  end;
  Result := Target;
  try
    Stages := Method.Split(['+']);
    for k := High(Stages) downto 0 do
      Result := CreateStage(Stages[k], Result);
  except
    Result.Free;   // libera lo ya armado (y con eso Target)
    raise;
  end;
end;

function CompressMem(const Method: string; Src: PByte; SrcLen: SizeInt): TBytes;
var
  Sink: TMemSink;
  Chain: TOutStage;
begin
  Sink := TMemSink.Create;
  Chain := CreateEncoderChain(Method, Sink);
  try
    Chain.Write(Src, SrcLen);
    Chain.Finish;
    Result := Sink.Bytes;
  finally
    Chain.Free;   // libera también Sink
  end;
end;

{ Bytes de la contraseña como los ve FreeArc 0.67 sin :f (como PasswordBytes de
  parc_methods): el byte bajo de cada carácter Unicode. }
function MakeCipherStage(const Algorithm: string; const Password: RawByteString; out Stored: string;
  Parc: Boolean): string;
var
  W: UnicodeString;
  Pwd: RawByteString;
  Alg: string;
  i: Integer;
begin
  Alg := Algorithm;
  if Parc then
  begin
    // .parc: hex de la clave bien decodificado y contraseña en UTF-8 (:f), etiqueta de
    // autenticación (:m) y 200000 iteraciones de PBKDF2 si no se pidió otra cantidad
    Alg := Alg + ':f:m';
    if Pos(':n', Algorithm) = 0 then Alg := Alg + ':n' + IntToStr(PARC_KDF_ITERATIONS);
    Pwd := Password;
  end
  else
  begin
    // .arc: como FreeArc sin :f (cada carácter recortado a su byte bajo)
    W := UTF8Decode(Password);
    SetLength(Pwd, Length(W));
    for i := 1 to Length(W) do Pwd[i] := Chr(Ord(W[i]) and $FF);
  end;
  if not IsCipherStage(Algorithm) or not MakeEncryption(Alg, Pwd, Stored, Result) then
    raise EUnsupportedEncoder.CreateFmt('invalid encryption algorithm: "%s"', [Algorithm]);
end;

function WithoutCipher(const Method: string): string;
var
  Stage: string;
begin
  Result := '';
  for Stage in Method.Split(['+']) do
    if not IsCipherStage(Stage) then
    begin
      if Result <> '' then Result := Result + '+';
      Result := Result + Stage;
    end;
  if Result = '' then Result := 'storing';
end;

end.
