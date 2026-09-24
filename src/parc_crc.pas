{ CRC-32 IEEE (poli 0xEDB88320), igual al UpdateCRC de FreeArc y a zlib.crc32.
  "Slicing-by-8": 8 tablas procesan 8 bytes por iteración en vez de 1 (el mismo resultado,
  varias veces más rápido; es lo que usa FreeArc en CompressionLibrary.cpp). }
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
  T: array[0..7, Byte] of LongWord;

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
    for k := 1 to 7 do
      T[k][i] := (T[k - 1][i] shr 8) xor T[0][T[k - 1][i] and $FF];
end;

function UpdateCRC(Crc: LongWord; Data: PByte; Len: SizeUInt): LongWord;
var
  a, b: LongWord;
begin
  // Hasta alinear no hace falta: los bytes se leen de a uno y se arman en little-endian
  while Len >= 8 do
  begin
    a := Crc xor (LongWord(Data[0]) or (LongWord(Data[1]) shl 8) or
                  (LongWord(Data[2]) shl 16) or (LongWord(Data[3]) shl 24));
    b := LongWord(Data[4]) or (LongWord(Data[5]) shl 8) or
         (LongWord(Data[6]) shl 16) or (LongWord(Data[7]) shl 24);
    Crc := T[7][a and $FF] xor T[6][(a shr 8) and $FF] xor
           T[5][(a shr 16) and $FF] xor T[4][a shr 24] xor
           T[3][b and $FF] xor T[2][(b shr 8) and $FF] xor
           T[1][(b shr 16) and $FF] xor T[0][b shr 24];
    Inc(Data, 8);
    Dec(Len, 8);
  end;
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
