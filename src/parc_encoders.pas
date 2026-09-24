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

{ Arma la cadena de codificadores delante de Target (la cadena pasa a ser dueña de Target). }
function CreateEncoderChain(const Method: string; Target: TOutStage): TOutStage;

{ Comprime un bloque de control en memoria. }
function CompressMem(const Method: string; Src: PByte; SrcLen: SizeInt): TBytes;

{ True si CreateEncoderChain sabe comprimir con Method (sin crear nada). }
function EncoderAvailable(const Method: string): Boolean;

implementation

uses
  parc_filters, parc_ppmd, parc_methods;

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

function EncoderAvailable(const Method: string): Boolean;
var
  Stage: string;
begin
  for Stage in Method.Split(['+']) do
    case StageName(Stage) of
      'storing', 'exe', 'ppmd': ;
    else
      Exit(False);
    end;
  Result := True;
end;

function CreateStage(const Stage: string; Target: TOutStage): TOutStage;
var
  pp: TPpmdParams;
begin
  case StageName(Stage) of
    'storing': Result := TStoringStage.Create(Target);
    'exe':     Result := TBcjEncStage.Create(Target);
    'ppmd':
      begin
        // La misma sintaxis que el decodificador (parse_PPMD): una sola implementación
        pp := ParsePpmdParams(Stage.Split([':']));
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
