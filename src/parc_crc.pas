{ CRC-32 IEEE (poli 0xEDB88320), igual al UpdateCRC de FreeArc y a zlib.crc32. }
unit parc_crc;

{$mode objfpc}{$H+}

interface

const
  CRC_INIT = $FFFFFFFF;

function UpdateCRC(Crc: LongWord; Data: PByte; Len: SizeUInt): LongWord;
function CalcCRC(Data: PByte; Len: SizeUInt): LongWord;

implementation

var
  CrcTable: array[Byte] of LongWord;

procedure InitTable;
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
    CrcTable[i] := r;
  end;
end;

function UpdateCRC(Crc: LongWord; Data: PByte; Len: SizeUInt): LongWord;
begin
  while Len > 0 do
  begin
    Crc := CrcTable[Byte(Crc) xor Data^] xor (Crc shr 8);
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
  InitTable;
end.
