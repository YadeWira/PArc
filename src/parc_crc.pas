{ CRC-32 IEEE (poli 0xEDB88320), igual al UpdateCRC de FreeArc y a zlib.crc32.
  "Slicing-by-16": 16 tablas procesan 16 bytes por iteración en vez de 1 (el mismo resultado,
  varias veces más rápido), con lecturas de 32 bits: las plataformas de PArc (x86, x64) son
  little-endian y leen sin alinear sin costo. En big-endian se usa el camino de a un byte. }
unit parc_crc;

{$mode objfpc}{$H+}
{$R-}{$Q-}

interface

const
  CRC_INIT = $FFFFFFFF;

function UpdateCRC(Crc: LongWord; Data: PByte; Len: SizeUInt): LongWord;
function CalcCRC(Data: PByte; Len: SizeUInt): LongWord;

implementation

var
  T: array[0..15, Byte] of LongWord;

procedure InitTables;
var
  i, k: Integer;
  r: LongWord;
begin
  for i := 0 to 255 do
  begin
    r := i;
    for k := 1 to 8 do
      if (r and 1) <> 0 then r := (r shr 1) xor $EDB88320
      else r := r shr 1;
    T[0][i] := r;
  end;
  // T[k][i] = CRC de i seguido de k bytes en cero
  for i := 0 to 255 do
    for k := 1 to 15 do
      T[k][i] := (T[k - 1][i] shr 8) xor T[0][T[k - 1][i] and $FF];
end;

function UpdateCRC(Crc: LongWord; Data: PByte; Len: SizeUInt): LongWord;
{$IFDEF ENDIAN_LITTLE}
var
  a, b, c, d: LongWord;
begin
  while Len >= 16 do
  begin
    a := Crc xor PLongWord(Data)^;
    b := PLongWord(Data + 4)^;
    c := PLongWord(Data + 8)^;
    d := PLongWord(Data + 12)^;
    Crc := T[15][a and $FF] xor T[14][(a shr 8) and $FF] xor
           T[13][(a shr 16) and $FF] xor T[12][a shr 24] xor
           T[11][b and $FF] xor T[10][(b shr 8) and $FF] xor
           T[9][(b shr 16) and $FF] xor T[8][b shr 24] xor
           T[7][c and $FF] xor T[6][(c shr 8) and $FF] xor
           T[5][(c shr 16) and $FF] xor T[4][c shr 24] xor
           T[3][d and $FF] xor T[2][(d shr 8) and $FF] xor
           T[1][(d shr 16) and $FF] xor T[0][d shr 24];
    Inc(Data, 16);
    Dec(Len, 16);
  end;
{$ELSE}
begin
{$ENDIF}
  while Len > 0 do
  begin
    Crc := T[0][Byte(Crc) xor Data^] xor (Crc shr 8);
    Inc(Data);
    Dec(Len);
  end;
  Result := Crc;
end;

function CalcCRC(Data: PByte; Len: SizeUInt): LongWord;
begin
  Result := UpdateCRC(CRC_INIT, Data, Len) xor CRC_INIT;
end;

initialization
  InitTables;
end.
