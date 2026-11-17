{ Prueba del ensamblador de PPMd (parc_ppmd8_x64.inc): comprime un archivo con PpmdCompress,
  guarda el stream y lo vuelve a decodificar con TPpmdStage. tests/ppmd_asm.sh la compila dos
  veces (con ensamblador y con -dPARC_NOASM) y exige el mismo stream: el ensamblador tiene que
  ser bit a bit el Pascal, también en el estado del asignador, que solo se nota con el modelo
  lleno (memoria chica: restart y cut-off).
  Uso: test_ppmd_asm <entrada> <orden> <memoria en KB> <recuperación> <salida> }
program test_ppmd_asm;

{$mode objfpc}{$H+}

uses
  Classes, SysUtils, parc_stream, parc_ppmd;

var
  F: TFileStream;
  Src, Comp, Back: TBytes;
  Order, Restore: Integer;
  Mem: Int64;
  St: TPpmdStage;
  n, Got: SizeInt;
begin
  if ParamCount <> 5 then
  begin
    WriteLn('uso: test_ppmd_asm <entrada> <orden> <memoria KB> <recuperación> <salida>');
    Halt(2);
  end;
  Order := StrToInt(ParamStr(2));
  Mem := StrToInt64(ParamStr(3)) shl 10;
  Restore := StrToInt(ParamStr(4));
  F := TFileStream.Create(ParamStr(1), fmOpenRead);
  try
    SetLength(Src, F.Size);
    if Length(Src) > 0 then F.ReadBuffer(Src[0], Length(Src));
  finally
    F.Free;
  end;
  if not PpmdCompress(PByte(Src), Length(Src), Order, Mem, Restore, Comp) then
  begin
    WriteLn('PpmdCompress falló');
    Halt(1);
  end;
  F := TFileStream.Create(ParamStr(5), fmCreate);
  try
    if Length(Comp) > 0 then F.WriteBuffer(Comp[0], Length(Comp));
  finally
    F.Free;
  end;
  // De vuelta, con el decodificador de esta misma compilación
  SetLength(Back, Length(Src) + 1);
  St := TPpmdStage.Create(TMemStage.Create(PByte(Comp), Length(Comp)), Order, Mem, Restore);
  try
    Got := 0;
    repeat
      n := St.Read(@Back[Got], Length(Back) - Got);
      Inc(Got, n);
    until (n = 0) or (Got = Length(Back));
  finally
    St.Free;
  end;
  if (Got <> Length(Src)) or ((Got > 0) and not CompareMem(@Back[0], @Src[0], Got)) then
  begin
    WriteLn('la decodificación no devuelve la entrada (', Got, ' de ', Length(Src), ' bytes)');
    Halt(1);
  end;
end.
