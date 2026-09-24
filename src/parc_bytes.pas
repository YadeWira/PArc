{ Lectura de los tipos primitivos del formato (FORMATO-ARC.md §2) desde un buffer en memoria.
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

procedure Corrupt(const Msg: string);

implementation

procedure Corrupt(const Msg: string);
begin
  raise EArcCorrupt.Create('archivo dañado: ' + Msg);
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
  if (N < 0) or (N > Size - Pos) then Corrupt('lectura fuera del bloque');
  Inc(Pos, N);
end;

function TByteReader.U8: Byte;
begin
  if Pos >= Size then Corrupt('lectura fuera del bloque');
  Result := Data[Pos];
  Inc(Pos);
end;

function TByteReader.U32: LongWord;
begin
  if Size - Pos < 4 then Corrupt('lectura fuera del bloque');
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
  if (N < 0) or (N > Size - Pos) then Corrupt('lectura fuera del bloque');
  SetLength(Result, N);
  if N > 0 then Move(Data[Pos], Result[1], N);
  Inc(Pos, N);
end;

end.
