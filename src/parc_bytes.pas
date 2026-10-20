{ Lectura de los tipos primitivos del formato (el formato base de FreeArc §2) desde un buffer en memoria.
  Toda lectura verifica límites y lanza EArcCorrupt si se sale del buffer. }
unit parc_bytes;

{$mode objfpc}{$H+}
{$modeswitch advancedrecords}

interface

uses
  SysUtils;

type
  EArcCorrupt = class(Exception);

  TByteReader = record
    Data: PByte;
    Size: SizeInt;
    Pos: SizeInt;
    procedure Init(AData: PByte; ASize: SizeInt);
    function Eof: Boolean;
    function Remaining: SizeInt;
    procedure Skip(N: SizeInt);
    function U8: Byte;
    function U32: LongWord;
    function VInt: QWord;
    function VIntSize: SizeInt;       // VInt que tiene que caber en SizeInt (conteos, longitudes)
    function CStr: RawByteString;     // UTF-8 terminado en NUL
    function Bytes(N: SizeInt): RawByteString;
  end;

  { Serialización de los tipos primitivos (el formato base de FreeArc §2) en un buffer que crece. }
  TByteWriter = record
    Data: TBytes;
    Len: SizeInt;
    procedure Clear;
    procedure Raw(Buf: Pointer; Count: SizeInt);
    procedure U8(V: Byte);
    procedure U32(V: LongWord);
    procedure I64(V: Int64);
    procedure VInt(V: QWord);         // siempre en la forma más corta, como FreeArc
    procedure CStr(const S: RawByteString);
    function Bytes: TBytes;
  end;

procedure Corrupt(const Msg: string);

implementation

procedure Corrupt(const Msg: string);
begin
  raise EArcCorrupt.Create('damaged archive: ' + Msg);
end;

procedure TByteReader.Init(AData: PByte; ASize: SizeInt);
begin
  Data := AData;
  Size := ASize;
  Pos := 0;
end;

function TByteReader.Eof: Boolean;
begin
  Result := Pos >= Size;
end;

function TByteReader.Remaining: SizeInt;
begin
  Result := Size - Pos;
end;

procedure TByteReader.Skip(N: SizeInt);
begin
  if (N < 0) or (N > Size - Pos) then Corrupt('read outside block');
  Inc(Pos, N);
end;

function TByteReader.U8: Byte;
begin
  if Pos >= Size then Corrupt('read outside block');
  Result := Data[Pos];
  Inc(Pos);
end;

function TByteReader.U32: LongWord;
begin
  if Size - Pos < 4 then Corrupt('read outside block');
  Result := LongWord(Data[Pos]) or (LongWord(Data[Pos + 1]) shl 8) or
            (LongWord(Data[Pos + 2]) shl 16) or (LongWord(Data[Pos + 3]) shl 24);
  Inc(Pos, 4);
end;

function TByteReader.VInt: QWord;
var
  First: Byte;
  n, i: Integer;
begin
  First := U8;
  Dec(Pos);
  // n = cantidad de bits 1 consecutivos en la parte baja del primer byte
  n := 0;
  while (n < 8) and (((First shr n) and 1) = 1) do Inc(n);
  if n = 8 then
  begin
    if Size - Pos < 9 then Corrupt('entero truncado');
    Result := 0;
    for i := 8 downto 1 do Result := (Result shl 8) or Data[Pos + i];
    Inc(Pos, 9);
    Exit;
  end;
  if Size - Pos < n + 1 then Corrupt('entero truncado');
  Result := 0;
  for i := n downto 0 do Result := (Result shl 8) or Data[Pos + i];
  Result := Result shr (n + 1);
  Inc(Pos, n + 1);
end;

function TByteReader.VIntSize: SizeInt;
var
  v: QWord;
begin
  v := VInt;
  if v > QWord(High(SizeInt)) then Corrupt('valor demasiado grande');
  Result := SizeInt(v);
end;

function TByteReader.CStr: RawByteString;
var
  e: SizeInt;
begin
  e := Pos;
  while (e < Size) and (Data[e] <> 0) do Inc(e);
  if e >= Size then Corrupt('cadena sin terminar');
  SetLength(Result, e - Pos);
  if e > Pos then Move(Data[Pos], Result[1], e - Pos);
  SetCodePage(Result, CP_UTF8, False);
  Pos := e + 1;
end;

function TByteReader.Bytes(N: SizeInt): RawByteString;
begin
  if (N < 0) or (N > Size - Pos) then Corrupt('read outside block');
  SetLength(Result, N);
  if N > 0 then Move(Data[Pos], Result[1], N);
  Inc(Pos, N);
end;

{ TByteWriter }

procedure TByteWriter.Clear;
begin
  Data := nil;
  Len := 0;
end;

procedure TByteWriter.Raw(Buf: Pointer; Count: SizeInt);
begin
  if Count <= 0 then Exit;
  if Len + Count > Length(Data) then SetLength(Data, 2 * (Len + Count) + 256);
  Move(Buf^, Data[Len], Count);
  Inc(Len, Count);
end;

procedure TByteWriter.U8(V: Byte);
begin
  Raw(@V, 1);
end;

procedure TByteWriter.U32(V: LongWord);
var
  b: array[0..3] of Byte;
begin
  b[0] := Byte(V); b[1] := Byte(V shr 8); b[2] := Byte(V shr 16); b[3] := Byte(V shr 24);
  Raw(@b[0], 4);
end;

procedure TByteWriter.I64(V: Int64);
begin
  U32(LongWord(QWord(V)));
  U32(LongWord(QWord(V) shr 32));
end;

{ Con n+1 bytes (n = 0..7) entran valores < 2^(7*(n+1)): se guarda V shl (n+1) con n bits 1
  abajo. Desde 2^56: byte 0xFF + 8 bytes (FastBufferData Integer de ByteStream.hs). }
procedure TByteWriter.VInt(V: QWord);
var
  n, i: Integer;
  X: QWord;
  b: array[0..8] of Byte;
begin
  n := 0;
  while (n < 8) and (V >= (QWord(1) shl (7 * (n + 1)))) do Inc(n);
  if n = 8 then
  begin
    b[0] := $FF;
    for i := 1 to 8 do b[i] := Byte(V shr (8 * (i - 1)));
    Raw(@b[0], 9);
    Exit;
  end;
  X := (V shl (n + 1)) or ((QWord(1) shl n) - 1);
  for i := 0 to n do b[i] := Byte(X shr (8 * i));
  Raw(@b[0], n + 1);
end;

procedure TByteWriter.CStr(const S: RawByteString);
begin
  if Pos(#0, S) > 0 then raise Exception.Create('cadena con NUL');
  Raw(PChar(S), Length(S));
  U8(0);
end;

function TByteWriter.Bytes: TBytes;
begin
  Result := Copy(Data, 0, Len);
end;

end.
