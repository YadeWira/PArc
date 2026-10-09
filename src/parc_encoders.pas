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
  parc_crypt, parc_canon, parc_lz4enc;

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

type
  T4x4EncJob = class(TParallelJob)
  public
    Inner: string;
    InBuf: TBytes;
    OrigSize: SizeInt;
    Stored: Boolean;
    MinOrder0Ratio: Double;
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

procedure T4x4EncJob.Process;
begin
  LzmaSingleThreadHere := True;   // 4x4 ya reparte los bloques entre hilos
  // Como _4x4MTCompressor::Process: un bloque de >= 32 KB casi aleatorio (order-0 >= r%) ni
  // se intenta; y si no comprime, va guardado tal cual
  if (MinOrder0Ratio <> 0) and (Length(InBuf) >= 32 * 1024) and
     (Order0Ratio(PByte(InBuf), Length(InBuf)) >= MinOrder0Ratio) then
    Stored := True
  else if StageName(Inner) = 'lz4' then
    // LZ4_METHOD::DeCompressMem: versión + un solo bloque LZ4 (no el stream por bloques)
    Stored := not Lz4EncodeMem(Inner.Split([':']), PByte(InBuf), Length(InBuf), OutBuf)
  else if StageName(Inner) = 'tor' then
    // TORNADO_METHOD::DeCompressMem con compress_all_at_once=1; OutputSize = InSize
    Stored := not TorEncodeMem(Inner.Split([':']), PByte(InBuf), Length(InBuf), Length(InBuf), OutBuf)
  else
  begin
    OutBuf := CompressMem(Inner, PByte(InBuf), Length(InBuf));
    Stored := Length(OutBuf) >= Length(InBuf);
  end;
  if Stored then OutBuf := InBuf;
  OutSize := Length(OutBuf);
  InBuf := nil;
end;

{ T4x4EncStage }

constructor T4x4EncStage.Create(ATarget: TOutStage; const AInner: string; ABlockSize: SizeInt);
var
  Threads: Integer;
begin
  if not EncoderAvailable(AInner) then
    raise EUnsupportedEncoder.CreateFmt('todavía no se puede comprimir con "%s"', [AInner]);
  if ABlockSize < 4096 then ABlockSize := 4096;
  inherited Create(ATarget);
  FInner := AInner;
  FBlockSize := ABlockSize;
  MinOrder0Ratio := 0.99;
  Threads := ThreadCount(16);
  SetLength(FQueue, Threads + 1);
  FPool := TJobPool.Create(Threads, Threads + 1);
  EmitU32(0);   // versión del formato 4x4 (se escribe aunque no haya datos, como el C)
end;

destructor T4x4EncStage.Destroy;
var
  i: Integer;
begin
  FPool.Free;
  for i := 0 to FCount - 1 do FQueue[(FHead + i) mod Length(FQueue)].Free;
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
    Emit(PByte(Job.OutBuf), Job.OutSize);
  finally
    Job.Free;
  end;
end;

procedure T4x4EncStage.SubmitBlock;
var
  Job: T4x4EncJob;
begin
  if FLen = 0 then Exit;
  if FCount = Length(FQueue) then WriteOldest;
  Job := T4x4EncJob.Create;
  Job.Inner := FInner;
  Job.InBuf := Copy(FCur, 0, FLen);
  Job.OrigSize := FLen;
  Job.MinOrder0Ratio := MinOrder0Ratio;
  FQueue[(FHead + FCount) mod Length(FQueue)] := Job;
  Inc(FCount);
  TJobPool(FPool).Submit(Job);
  FLen := 0;
end;

procedure T4x4EncStage.DoWrite(Buf: PByte; Count: SizeInt);
var
  n: SizeInt;
begin
  if Length(FCur) = 0 then SetLength(FCur, FBlockSize);
  while Count > 0 do
  begin
    n := FBlockSize - FLen;
    if n > Count then n := Count;
    Move(Buf^, FCur[FLen], n);
    Inc(FLen, n);
    Inc(Buf, n);
    Dec(Count, n);
    if FLen = FBlockSize then SubmitBlock;
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
      'storing', 'exe', 'ppmd', 'lzp', 'lzma', 'rep', 'delta', 'dict', 'tta', 'mm', 'grzip': ;
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
    raise EUnsupportedEncoder.CreateFmt('todavía no se puede comprimir con "%s"', [Stage]);
  end;
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
    raise EUnsupportedEncoder.CreateFmt('todavía no se puede comprimir con "%s"', [Method]);
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
    raise EUnsupportedEncoder.CreateFmt('algoritmo de cifrado inválido: "%s"', [Algorithm]);
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
