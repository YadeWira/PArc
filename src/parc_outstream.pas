{ Etapas de escritura encadenables (modelo "push"), el espejo de parc_stream para comprimir.
  Un método "a+b+c" se comprime armando  datos -> a -> b -> c -> archivo: cada etapa recibe
  bytes con Write, los transforma y se los pasa a su destino (Target). Finish vacía lo que la
  etapa tenga pendiente, escribe su cierre (marca de fin, último bloque...) y llama al Finish
  del destino. }
unit parc_outstream;

{$mode objfpc}{$H+}

interface

uses
  Classes, SysUtils;

type
  TOutStage = class
  private
    FTarget: TOutStage;
    FFinished: Boolean;
  protected
    { Implementación de la etapa: procesar Count bytes de Buf. }
    procedure DoWrite(Buf: PByte; Count: SizeInt); virtual; abstract;
    { Implementación del cierre: vaciar lo pendiente en Target (sin llamar a Target.Finish). }
    procedure DoFinish; virtual;
    { Para las subclases: mandar bytes al destino. }
    procedure Emit(Buf: PByte; Count: SizeInt);
    procedure EmitU32(V: LongWord);
  public
    constructor Create(ATarget: TOutStage);
    destructor Destroy; override;   // libera también el destino (la cadena es dueña de sí misma)
    procedure Write(Buf: PByte; Count: SizeInt);
    procedure Finish;               // cierra esta etapa y todas las siguientes; idempotente
    property Target: TOutStage read FTarget;
  end;

  { Destino final: escribe en un TStream (no es dueño) y cuenta los bytes. }
  TStreamSink = class(TOutStage)
  private
    FStream: TStream;
    FBytes: Int64;
    FBuf: TBytes;
    FUsed: Integer;
    procedure Flush;
  protected
    procedure DoWrite(Buf: PByte; Count: SizeInt); override;
    procedure DoFinish; override;
  public
    constructor Create(AStream: TStream);
    destructor Destroy; override;
    property Bytes: Int64 read FBytes;
  end;

  { Destino final en memoria (para bloques de control y tests). }
  TMemSink = class(TOutStage)
  private
    FData: TBytes;
    FLen: SizeInt;
  protected
    procedure DoWrite(Buf: PByte; Count: SizeInt); override;
  public
    constructor Create;
    function Bytes: TBytes;     // copia exacta de lo escrito
    property Len: SizeInt read FLen;
  end;

  { Etapa identidad (método `storing`). }
  TStoringStage = class(TOutStage)
  protected
    procedure DoWrite(Buf: PByte; Count: SizeInt); override;
  end;

implementation

uses
  parc_progress;

{ TOutStage }

constructor TOutStage.Create(ATarget: TOutStage);
begin
  inherited Create;
  FTarget := ATarget;
end;

destructor TOutStage.Destroy;
begin
  FTarget.Free;
  inherited Destroy;
end;

procedure TOutStage.DoFinish;
begin
end;

procedure TOutStage.Emit(Buf: PByte; Count: SizeInt);
begin
  // Cancelación también entre etapas: un Write de 1 MB puede disparar segundos de trabajo río
  // abajo (rep:2040m acumula y lzma:max lo comprime de a trozos)
  CheckCancel;
  if Count > 0 then FTarget.Write(Buf, Count);
end;

procedure TOutStage.EmitU32(V: LongWord);
var
  b: array[0..3] of Byte;
begin
  b[0] := Byte(V); b[1] := Byte(V shr 8); b[2] := Byte(V shr 16); b[3] := Byte(V shr 24);
  Emit(@b[0], 4);
end;

procedure TOutStage.Write(Buf: PByte; Count: SizeInt);
begin
  if FFinished then raise Exception.Create('escritura después de Finish');
  if Count > 0 then DoWrite(Buf, Count);
end;

procedure TOutStage.Finish;
begin
  if FFinished then Exit;
  FFinished := True;
  DoFinish;
  if FTarget <> nil then FTarget.Finish;
end;

{ TStreamSink }

const
  STREAM_SINK_BUF = 64 * 1024;

constructor TStreamSink.Create(AStream: TStream);
begin
  inherited Create(nil);
  FStream := AStream;
  SetLength(FBuf, STREAM_SINK_BUF);
end;

destructor TStreamSink.Destroy;
begin
  Flush;
  inherited Destroy;
end;

procedure TStreamSink.Flush;
begin
  if FUsed > 0 then
  begin
    FStream.WriteBuffer(FBuf[0], FUsed);
    FUsed := 0;
  end;
end;

procedure TStreamSink.DoWrite(Buf: PByte; Count: SizeInt);
begin
  Inc(FBytes, Count);
  // Los codecs emiten muchos pedazos chicos (el rango-coder de PPMd, por ejemplo): juntarlos
  // evita una llamada a write por pedazo. Lo grande va directo, sin copia.
  if Count >= Length(FBuf) then
  begin
    Flush;
    FStream.WriteBuffer(Buf^, Count);
    Exit;
  end;
  if FUsed + Count > Length(FBuf) then Flush;
  Move(Buf^, FBuf[FUsed], Count);
  Inc(FUsed, Count);
end;

procedure TStreamSink.DoFinish;
begin
  Flush;
end;

{ TMemSink }

constructor TMemSink.Create;
begin
  inherited Create(nil);
end;

procedure TMemSink.DoWrite(Buf: PByte; Count: SizeInt);
begin
  if FLen + Count > Length(FData) then
    SetLength(FData, 2 * (FLen + Count) + 4096);
  Move(Buf^, FData[FLen], Count);
  Inc(FLen, Count);
end;

function TMemSink.Bytes: TBytes;
begin
  Result := Copy(FData, 0, FLen);
end;

{ TStoringStage }

procedure TStoringStage.DoWrite(Buf: PByte; Count: SizeInt);
begin
  Emit(Buf, Count);
end;

end.
