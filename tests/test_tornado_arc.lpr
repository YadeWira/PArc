{ Validación de parc_tornado contra archivos .arc reales de FreeArc, sin pasar por el CLI:
  tests/test_tornado_arc <archivo.arc>...
  Cada bloque de datos con método "tor[:...]" se abre con TTornadoStage (streaming) y cada
  "4x4:...tor..." con un lector 4x4 mínimo (formato de C_4x4.cpp) que decodifica cada bloque
  con TornadoDecodeMem (compress_all_at_once, como FreeArc dentro de 4x4). Se verifica el CRC
  de cada archivo, en orden dentro del bloque (como parc_extract). Otros métodos se saltean.
  Sale con 0 si todos los CRC coinciden y hubo al menos un bloque tor. }
program test_tornado_arc;
{$mode objfpc}{$H+}
uses SysUtils, Classes, parc_bytes, parc_stream, parc_crc, parc_archive, parc_tornado;

type
  { 4x4: U32 versión (=0) y bloques [Int32 OutSize][U32 InSize][datos]; OutSize=-1: guardado. }
  T4x4TorStage = class(TInStage)
  private
    FOut: TBytes;
    FPos, FLen: SizeInt;
    FStarted: Boolean;
  public
    Blocks: Integer;
    function Read(Buf: PByte; Count: SizeInt): SizeInt; override;
  end;

function T4x4TorStage.Read(Buf: PByte; Count: SizeInt): SizeInt;
var
  hdr: array[0..3] of Byte;
  OutSize: LongInt;
  InSize: LongWord;
  InBuf: TBytes;
  w: SizeInt;
begin
  while FPos >= FLen do
  begin
    if not FStarted then
    begin
      FStarted := True;
      if not Source.ReadExactOrEof(@hdr[0], 4) then Exit(0);
      if (hdr[0] or hdr[1] or hdr[2] or hdr[3]) <> 0 then Corrupt('4x4: versión desconocida');
    end;
    if not Source.ReadExactOrEof(@hdr[0], 4) then Exit(0);
    OutSize := LongInt(LongWord(hdr[0]) or (LongWord(hdr[1]) shl 8) or (LongWord(hdr[2]) shl 16) or (LongWord(hdr[3]) shl 24));
    InSize := Source.ReadU32;
    if (InSize > $7FFFFFFF) or (OutSize < -1) then Corrupt('4x4: tamaño inválido');
    SetLength(InBuf, InSize);
    if InSize > 0 then Source.ReadExact(@InBuf[0], InSize);
    Inc(Blocks);
    if OutSize = -1 then
    begin
      FOut := InBuf;
      FLen := InSize;
    end
    else
    begin
      SetLength(FOut, OutSize);
      if not TornadoDecodeMem(PByte(InBuf), InSize, PByte(FOut), OutSize, w) then
        Corrupt('4x4: la salida de tor no entra en el bloque');
      if w <> OutSize then Corrupt(Format('4x4: tor dio %d bytes, esperados %d', [w, OutSize]));
      FLen := OutSize;
    end;
    FPos := 0;
  end;
  Result := FLen - FPos;
  if Result > Count then Result := Count;
  Move(FOut[FPos], Buf^, Result);
  Inc(FPos, Result);
end;

function IsTor(const M: string): Boolean;
begin
  Result := (M = 'tor') or (Copy(M, 1, 4) = 'tor:');
end;

function Is4x4Tor(const M: string): Boolean;
begin
  Result := (Copy(M, 1, 4) = '4x4:') and (Pos('+', M) = 0) and (Pos(':tor', M) > 0);
end;

var
  A: TArchive;
  a_, b, i, nOk, nBad, nBlocks: Integer;
  Blk: TArcBlock;
  Chain: TInStage;
  Buf: TBytes;
  Remaining, n: Int64;
  Crc: LongWord;
  extra: Byte;
begin
  nOk := 0; nBad := 0; nBlocks := 0;
  SetLength(Buf, 1 shl 20);
  for a_ := 1 to ParamCount do
  begin
    A := TArchive.Open(ParamStr(a_));
    try
      for b := 0 to High(A.DataBlocks) do
      begin
        Blk := A.DataBlocks[b];
        if IsTor(Blk.Method) then Chain := TTornadoStage.Create(A.OpenBlockData(Blk))
        else if Is4x4Tor(Blk.Method) then Chain := T4x4TorStage.Create(A.OpenBlockData(Blk))
        else
        begin
          WriteLn(Format('%s: bloque %d "%s" salteado', [ExtractFileName(ParamStr(a_)), b, Blk.Method]));
          Continue;
        end;
        Inc(nBlocks);
        try
          try
            for i := Blk.FirstFile to Blk.FirstFile + Blk.FileCount - 1 do
            begin
              if A.Files[i].IsDir then Continue;
              Crc := CRC_INIT;
              Remaining := A.Files[i].Size;
              while Remaining > 0 do
              begin
                if Remaining > Length(Buf) then n := Length(Buf) else n := Remaining;
                Chain.ReadExact(@Buf[0], n);
                Crc := UpdateCRC(Crc, @Buf[0], n);
                Dec(Remaining, n);
              end;
              Crc := Crc xor CRC_INIT;
              if Crc = A.Files[i].Crc then Inc(nOk)
              else
              begin
                Inc(nBad);
                WriteLn(Format('  CRC MAL %s (esperado %.8x, obtenido %.8x)', [A.Files[i].Name, A.Files[i].Crc, Crc]));
              end;
            end;
            if Chain.Read(@extra, 1) <> 0 then
            begin
              Inc(nBad);
              WriteLn('  el bloque descomprime a más bytes que la suma de sus archivos');
            end;
            Write(Format('%s: bloque %d "%s", %d archivos, %d -> %d bytes', [ExtractFileName(ParamStr(a_)), b,
              Blk.Method, Blk.FileCount, Blk.CompSize, Blk.OrigSize]));
            if Chain is T4x4TorStage then Write(Format(' (%d bloques 4x4)', [T4x4TorStage(Chain).Blocks]));
            WriteLn;
          except
            on E: Exception do
            begin
              Inc(nBad);
              WriteLn(Format('  ERROR en bloque %d: %s: %s', [b, E.ClassName, E.Message]));
            end;
          end;
        finally
          Chain.Free;
        end;
      end;
    finally
      A.Free;
    end;
  end;
  WriteLn(Format('bloques tor: %d, CRC ok: %d, fallas: %d', [nBlocks, nOk, nBad]));
  if (nBad = 0) and (nBlocks > 0) then Halt(0) else Halt(1);
end.
