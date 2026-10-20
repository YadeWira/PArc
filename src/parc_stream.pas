{ Etapas de lectura encadenables (modelo "pull"): cada decodificador es un TInStage que pide
  bytes a su fuente (otro TInStage). Así un método "a+b+c" se descomprime armando
  archivo -> c -> b -> a, sin tener el bloque sólido completo en memoria. }
unit parc_stream;

{$mode objfpc}{$H+}

interface

uses
  Classes, SysUtils, parc_bytes;

type
  TInStage = class
  private
    FSource: TInStage;
  public
    constructor Create(ASource: TInStage);
    destructor Destroy; override;    // libera también la fuente (la cadena es dueña de sí misma)
    { Lee hasta Count bytes. Devuelve 0 solo al final del stream; si no, al menos 1. }
    function Read(Buf: PByte; Count: SizeInt): SizeInt; virtual; abstract;
    { Lee exactamente Count bytes o lanza EArcCorrupt. }
    procedure ReadExact(Buf: PByte; Count: SizeInt);
    { Como ReadExact, pero devuelve False si el stream terminó limpio antes del primer byte. }
    function ReadExactOrEof(Buf: PByte; Count: SizeInt): Boolean;
    function ReadU32: LongWord;
    property Source: TInStage read FSource;
  end;

  { Un rango [Pos, Pos+Len) de un archivo abierto (no es dueña del TStream). }
  TFileSliceStage = class(TInStage)
  private
    FStream: TStream;
    FPos, FRemaining: Int64;
  public
    constructor Create(AStream: TStream; APos, ALen: Int64);
    function Read(Buf: PByte; Count: SizeInt): SizeInt; override;
  end;

  { Bytes en memoria (se copian). }
  TMemStage = class(TInStage)
  private
    FData: TBytes;
    FPos: SizeInt;
  public
    constructor Create(Data: PByte; Len: SizeInt);
    function Read(Buf: PByte; Count: SizeInt): SizeInt; override;
  end;

implementation

constructor TInStage.Create(ASource: TInStage);
begin
  inherited Create;
  FSource := ASource;
end;

destructor TInStage.Destroy;
begin
  FSource.Free;
  inherited Destroy;
end;

procedure TInStage.ReadExact(Buf: PByte; Count: SizeInt);
var
  n: SizeInt;
begin
  while Count > 0 do
  begin
    n := Read(Buf, Count);
    if n <= 0 then Corrupt('datos truncados');
    Inc(Buf, n);
    Dec(Count, n);
  end;
end;

function TInStage.ReadExactOrEof(Buf: PByte; Count: SizeInt): Boolean;
var
  n: SizeInt;
begin
  Result := True;
  if Count <= 0 then Exit;
  n := Read(Buf, Count);
  if n <= 0 then Exit(False);
  ReadExact(Buf + n, Count - n);
end;

function TInStage.ReadU32: LongWord;
var
  b: array[0..3] of Byte;
begin
  ReadExact(@b[0], 4);
  Result := LongWord(b[0]) or (LongWord(b[1]) shl 8) or (LongWord(b[2]) shl 16) or (LongWord(b[3]) shl 24);
end;

constructor TFileSliceStage.Create(AStream: TStream; APos, ALen: Int64);
begin
  inherited Create(nil);
  FStream := AStream;
  FPos := APos;
  FRemaining := ALen;
end;

function TFileSliceStage.Read(Buf: PByte; Count: SizeInt): SizeInt;
begin
  if Count > FRemaining then Count := FRemaining;
  if Count <= 0 then Exit(0);
  FStream.Position := FPos;
  Result := FStream.Read(Buf^, Count);
  if Result <= 0 then Corrupt('file ends earlier than expected');
  Inc(FPos, Result);
  Dec(FRemaining, Result);
end;

constructor TMemStage.Create(Data: PByte; Len: SizeInt);
begin
  inherited Create(nil);
  SetLength(FData, Len);
  if Len > 0 then Move(Data^, FData[0], Len);
end;

function TMemStage.Read(Buf: PByte; Count: SizeInt): SizeInt;
begin
  Result := Length(FData) - FPos;
  if Result > Count then Result := Count;
  if Result <= 0 then Exit(0);
  Move(FData[FPos], Buf^, Result);
  Inc(FPos, Result);
end;

end.
