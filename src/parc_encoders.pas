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

implementation

uses
  parc_filters, parc_ppmd, parc_methods, parc_lzp, parc_parallel, parc_lzmaenc;

type
  T4x4EncJob = class(TParallelJob)
  public
    Inner: string;
    InBuf: TBytes;
    OrigSize: SizeInt;
    Stored: Boolean;
    procedure Process; override;
  end;

procedure T4x4EncJob.Process;
begin
  OutBuf := CompressMem(Inner, PByte(InBuf), Length(InBuf));
  // Como _4x4MTCompressor::Process: si no comprime, el bloque va guardado tal cual
  Stored := Length(OutBuf) >= Length(InBuf);
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
var
  Stages, Params: TStringArray;
  k, j: Integer;
  m, Need: QWord;
begin
  Need := 64 shl 10;
  while (Need < QWord(DataSize)) and (Need < (QWord(1) shl 40)) do Need := Need shl 1;
  Stages := Method.Split(['+']);
  for k := 0 to High(Stages) do
  begin
    Params := Stages[k].Split([':']);
    if Params[0] <> 'lzma' then Continue;
    for j := 1 to High(Params) do
      if (Params[j] <> '') and (StrToIntDef(Params[j], -1) < 0) and
         ((Params[j][1] in ['0'..'9']) and ParseMem(Params[j], m) or
          (Params[j][1] = 'd') and ParseMem(Copy(Params[j], 2, MaxInt), m)) then
        if m > Need then
          Params[j] := IntToStr(Need shr 10) + 'kb';
    Stages[k] := string.Join(':', Params);
  end;
  Result := string.Join('+', Stages);
end;

function EncoderAvailable(const Method: string): Boolean;
var
  Stage, Inner: string;
  Bs: SizeInt;
begin
  for Stage in Method.Split(['+']) do
    case StageName(Stage) of
      '4x4':
        begin
          Parse4x4(Stage, Inner, Bs);
          if not EncoderAvailable(Inner) then Exit(False);
        end;
      'storing', 'exe', 'ppmd', 'lzp', 'lzma': ;
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
  case StageName(Stage) of
    '4x4':
      begin
        Parse4x4(Stage, Inner, Bs);
        Result := T4x4EncStage.Create(Target, Inner, Bs);
      end;
    'storing': Result := TStoringStage.Create(Target);
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

end.
