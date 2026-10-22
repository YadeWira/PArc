{ Prueba de parc_crc: UpdateCRC (con PCLMULQDQ si la CPU lo tiene) contra el camino de tablas y
  contra un CRC de a un bit, en largos y alineaciones al azar, encadenando trozos.
  Uso: test_crc [bench]   (bench: velocidad de cada camino sobre 1 GB) }
program test_crc;

{$mode objfpc}{$H+}
{$R-}{$Q-}

uses
  SysUtils, parc_crc;

function BitCRC(Crc: LongWord; Data: PByte; Len: SizeUInt): LongWord;
var
  i, k: SizeUInt;
begin
  for i := 0 to Len - 1 do
  begin
    Crc := Crc xor Data[i];
    for k := 1 to 8 do
      if (Crc and 1) <> 0 then Crc := (Crc shr 1) xor $EDB88320 else Crc := Crc shr 1;
  end;
  Result := Crc;
end;

var
  Buf: array of Byte;
  i, Fails, Tests: Integer;
  Ofs, Len, Cut: SizeUInt;
  A, B, C: LongWord;
  S: AnsiString;
  T0: QWord;
  Pass: Integer;
begin
  Fails := 0; Tests := 0;
  S := '123456789';
  if CalcCRC(PByte(S), Length(S)) <> $CBF43926 then
  begin
    WriteLn('FAIL vector 123456789');
    Inc(Fails);
  end;
  SetLength(Buf, 1 shl 20 + 64);
  RandSeed := 12345;
  for i := 0 to High(Buf) do Buf[i] := Random(256);
  // Largos chicos y alrededor de los umbrales, todas las alineaciones
  for Len := 0 to 600 do
    for Ofs := 0 to 15 do
    begin
      A := UpdateCRC(CRC_INIT, @Buf[Ofs], Len);
      B := UpdateCRCTable(CRC_INIT, @Buf[Ofs], Len);
      if Len > 0 then C := BitCRC(CRC_INIT, @Buf[Ofs], Len) else C := CRC_INIT;
      Inc(Tests);
      if (A <> B) or (A <> C) then
      begin
        Inc(Fails);
        if Fails < 10 then WriteLn(Format('FAIL len=%d ofs=%d %.8x %.8x %.8x', [Len, Ofs, A, B, C]));
      end;
    end;
  // Largos y alineaciones al azar, en dos trozos encadenados
  for i := 1 to 20000 do
  begin
    Ofs := Random(64);
    Len := Random(1 shl 20 - 64);
    if i mod 4 = 0 then Len := Random(5000);
    Cut := Random(Int64(Len) + 1);
    A := UpdateCRC(UpdateCRC(CRC_INIT, @Buf[Ofs], Cut), @Buf[Ofs + Cut], Len - Cut);
    B := UpdateCRCTable(CRC_INIT, @Buf[Ofs], Len);
    Inc(Tests);
    if A <> B then
    begin
      Inc(Fails);
      if Fails < 10 then WriteLn(Format('FAIL len=%d ofs=%d cut=%d %.8x %.8x', [Len, Ofs, Cut, A, B]));
    end;
  end;
  WriteLn(Format('crc: %d tests, %d failures (pclmul=%s)', [Tests, Fails, BoolToStr(CRCUsesPclmul, True)]));
  if (ParamCount >= 1) and (ParamStr(1) = 'bench') then
    for Pass := 1 to 2 do
    begin
      T0 := GetTickCount64;
      A := CRC_INIT;
      for i := 1 to 1024 do A := UpdateCRCTable(A, @Buf[0], 1 shl 20);
      WriteLn(Format('table : %.0f MB/s (%.8x)', [1024 / ((GetTickCount64 - T0 + 1) / 1000), A]));
      T0 := GetTickCount64;
      B := CRC_INIT;
      for i := 1 to 1024 do B := UpdateCRC(B, @Buf[0], 1 shl 20);
      WriteLn(Format('update: %.0f MB/s (%.8x)', [1024 / ((GetTickCount64 - T0 + 1) / 1000), B]));
    end;
  if Fails > 0 then Halt(1);
end.
