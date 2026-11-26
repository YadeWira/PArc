{ Primitive encoding of PArc's container (docs/formato/FORMATO-PARC.md §1.2), read from and
  written to memory buffers. Every read checks bounds and raises EArcCorrupt when it would leave
  the buffer.

  - fixed-size integers: little-endian (U16/U32/U64);
  - Uv: unsigned LEB128 (7 bits per byte, low group first, high bit = more bytes follow), at most
    10 bytes, always the shortest form (a reader rejects overlong or overflowing encodings);
  - Sv: signed, zigzag-mapped ((v shl 1) xor (v sar 63)) and then Uv;
  - UBE(w): an unsigned value in exactly w bytes, big-endian (fixed-width columns, which a
    general-purpose compressor models better than varints);
  - Str: Uv length + that many bytes; ZStr: bytes up to a 0 byte (only for path columns). }
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
    function U16: Word;
    function U32: LongWord;
    function U64: QWord;
    function Uv: QWord;
    function UvSize: SizeInt;         // Uv that must fit in SizeInt and in what is left (counts)
    function Sv: Int64;
    function UBE(W: Integer): QWord;
    function Str: RawByteString;
    function ZStr: RawByteString;     // UTF-8 up to a 0 byte
    function Bytes(N: SizeInt): RawByteString;
  end;

  { Serialization into a growing buffer. }
  TByteWriter = record
    Data: TBytes;
    Len: SizeInt;
    procedure Clear;
    procedure Raw(Buf: Pointer; Count: SizeInt);
    procedure U8(V: Byte);
    procedure U16(V: Word);
    procedure U32(V: LongWord);
    procedure U64(V: QWord);
    procedure Uv(V: QWord);
    procedure Sv(V: Int64);
    procedure UBE(V: QWord; W: Integer);
    procedure Str(const S: RawByteString);
    procedure ZStr(const S: RawByteString);
    function Bytes: TBytes;
  end;

{ Zigzag: small signed values (either sign) to small unsigned ones. }
function ZigZag(V: Int64): QWord; inline;
function UnZigZag(V: QWord): Int64; inline;
{ Bytes needed to hold V in UBE (0 for V = 0). }
function UBEWidth(V: QWord): Integer;
{ Little-endian loads/stores on byte buffers. }
function GetU32(P: PByte): LongWord; inline;
function GetU64(P: PByte): QWord; inline;
procedure PutU32(P: PByte; V: LongWord); inline;
procedure PutU64(P: PByte; V: QWord); inline;

{ Memory size of a method parameter: "<digits>[unit]", unit b (bytes), k, m or g (KB, MB, GB;
  an optional "b" after it: "kb", "mb", "gb"), or none (or "^"): a power of two, "24" = 16 MB.
  A leading '=' is allowed. False if malformed or above 2^63. Every codec and the presets use
  this one syntax. }
function ParseMemSize(const S: string; out Value: QWord): Boolean;

procedure Corrupt(const Msg: string);

implementation

function ParseMemSize(const S: string; out Value: QWord): Boolean;
var
  p, n: Integer;
  Num: QWord;
  Shift: Integer;
  U: string;
begin
  Result := False;
  Value := 0;
  p := 1;
  n := Length(S);
  if (p <= n) and (S[p] = '=') then Inc(p);
  Num := 0;
  if (p > n) or not (S[p] in ['0'..'9']) then Exit;
  while (p <= n) and (S[p] in ['0'..'9']) do
  begin
    if Num > (QWord(1) shl 63) div 10 then Exit;
    Num := Num * 10 + QWord(Ord(S[p]) - Ord('0'));
    Inc(p);
  end;
  U := LowerCase(Copy(S, p, MaxInt));
  if (U = '') or (U = '^') then
  begin
    if Num > 63 then Exit;
    Value := QWord(1) shl Num;
    Exit(True);
  end;
  case U of
    'b': Shift := 0;
    'k', 'kb': Shift := 10;
    'm', 'mb': Shift := 20;
    'g', 'gb': Shift := 30;
  else
    Exit;
  end;
  if Num > (QWord(1) shl 63) shr Shift then Exit;
  Value := Num shl Shift;
  Result := True;
end;

procedure Corrupt(const Msg: string);
begin
  raise EArcCorrupt.Create('damaged archive: ' + Msg);
end;

function ZigZag(V: Int64): QWord;
begin
  if V >= 0 then Result := QWord(V) shl 1
  else Result := ((not QWord(V)) shl 1) or 1;
end;

function UnZigZag(V: QWord): Int64;
begin
  if (V and 1) = 0 then Result := Int64(V shr 1)
  else Result := Int64(not (V shr 1));
end;

function UBEWidth(V: QWord): Integer;
begin
  Result := 0;
  while (Result < 8) and (V <> 0) do
  begin
    V := V shr 8;
    Inc(Result);
  end;
end;

function GetU32(P: PByte): LongWord;
begin
  Result := LongWord(P[0]) or (LongWord(P[1]) shl 8) or (LongWord(P[2]) shl 16) or (LongWord(P[3]) shl 24);
end;

function GetU64(P: PByte): QWord;
begin
  Result := QWord(GetU32(P)) or (QWord(GetU32(P + 4)) shl 32);
end;

procedure PutU32(P: PByte; V: LongWord);
begin
  P[0] := Byte(V and $FF); P[1] := Byte((V shr 8) and $FF); P[2] := Byte((V shr 16) and $FF); P[3] := Byte(V shr 24);
end;

procedure PutU64(P: PByte; V: QWord);
begin
  PutU32(P, LongWord(V));
  PutU32(P + 4, LongWord(V shr 32));
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
  if (N < 0) or (N > Size - Pos) then Corrupt('read outside the structure');
  Inc(Pos, N);
end;

function TByteReader.U8: Byte;
begin
  if Pos >= Size then Corrupt('read outside the structure');
  Result := Data[Pos];
  Inc(Pos);
end;

function TByteReader.U16: Word;
begin
  if Size - Pos < 2 then Corrupt('read outside the structure');
  Result := Word(Data[Pos]) or (Word(Data[Pos + 1]) shl 8);
  Inc(Pos, 2);
end;

function TByteReader.U32: LongWord;
begin
  if Size - Pos < 4 then Corrupt('read outside the structure');
  Result := GetU32(@Data[Pos]);
  Inc(Pos, 4);
end;

function TByteReader.U64: QWord;
begin
  if Size - Pos < 8 then Corrupt('read outside the structure');
  Result := GetU64(@Data[Pos]);
  Inc(Pos, 8);
end;

function TByteReader.Uv: QWord;
var
  b: Byte;
  Shift: Integer;
begin
  Result := 0;
  Shift := 0;
  repeat
    if Pos >= Size then Corrupt('truncated integer');
    b := Data[Pos];
    Inc(Pos);
    if Shift = 63 then
    begin
      if b > 1 then Corrupt('integer too large');
    end
    else if Shift > 63 then Corrupt('integer too large');
    Result := Result or (QWord(b and $7F) shl Shift);
    Inc(Shift, 7);
  until b < $80;
  if (b = 0) and (Shift > 7) then Corrupt('non-canonical integer');
end;

function TByteReader.UvSize: SizeInt;
var
  v: QWord;
begin
  v := Uv;
  if v > QWord(High(SizeInt)) then Corrupt('value too large');
  Result := SizeInt(v);
end;

function TByteReader.Sv: Int64;
begin
  Result := UnZigZag(Uv);
end;

function TByteReader.UBE(W: Integer): QWord;
var
  i: Integer;
begin
  if (W < 0) or (W > 8) or (Size - Pos < W) then Corrupt('read outside the structure');
  Result := 0;
  for i := 0 to W - 1 do Result := (Result shl 8) or Data[Pos + i];
  Inc(Pos, W);
end;

function TByteReader.Str: RawByteString;
var
  n: SizeInt;
begin
  n := UvSize;
  Result := Bytes(n);
  SetCodePage(Result, CP_UTF8, False);
end;

function TByteReader.ZStr: RawByteString;
var
  e: SizeInt;
begin
  e := Pos;
  while (e < Size) and (Data[e] <> 0) do Inc(e);
  if e >= Size then Corrupt('unterminated name');
  SetLength(Result, e - Pos);
  if e > Pos then Move(Data[Pos], Result[1], e - Pos);
  SetCodePage(Result, CP_UTF8, False);
  Pos := e + 1;
end;

function TByteReader.Bytes(N: SizeInt): RawByteString;
begin
  if (N < 0) or (N > Size - Pos) then Corrupt('read outside the structure');
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
  if Len >= Length(Data) then SetLength(Data, 2 * Len + 256);
  Data[Len] := V;
  Inc(Len);
end;

procedure TByteWriter.U16(V: Word);
begin
  U8(Byte(V));
  U8(Byte(V shr 8));
end;

procedure TByteWriter.U32(V: LongWord);
var
  b: array[0..3] of Byte;
begin
  PutU32(@b[0], V);
  Raw(@b[0], 4);
end;

procedure TByteWriter.U64(V: QWord);
var
  b: array[0..7] of Byte;
begin
  PutU64(@b[0], V);
  Raw(@b[0], 8);
end;

procedure TByteWriter.Uv(V: QWord);
begin
  while V >= $80 do
  begin
    U8(Byte(V) or $80);
    V := V shr 7;
  end;
  U8(Byte(V));
end;

procedure TByteWriter.Sv(V: Int64);
begin
  Uv(ZigZag(V));
end;

procedure TByteWriter.UBE(V: QWord; W: Integer);
var
  i: Integer;
begin
  for i := W - 1 downto 0 do U8(Byte(V shr (8 * i)));
end;

procedure TByteWriter.Str(const S: RawByteString);
begin
  Uv(Length(S));
  Raw(PChar(S), Length(S));
end;

procedure TByteWriter.ZStr(const S: RawByteString);
begin
  if System.Pos(#0, S) > 0 then raise Exception.Create('name with a NUL byte');
  Raw(PChar(S), Length(S));
  U8(0);
end;

function TByteWriter.Bytes: TBytes;
begin
  Result := Copy(Data, 0, Len);
end;

end.
