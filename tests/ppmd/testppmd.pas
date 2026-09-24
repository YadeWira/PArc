program testppmd;
{ Prueba unitaria de parc_ppmd: decodifica un bloque PPMd crudo y lo compara,
  byte a byte, con el archivo original.

  El payload de un .arc de un solo método ES el stream PPMd, así que se le pasan
  el offset y el tamaño que informa `arc.exe lt`.

  Uso:
    testppmd <archivo.arc> <offset> <tamaño> <archivo_esperado> <orden> <memMB>
}
{$mode objfpc}{$H+}
uses
  SysUtils, Classes, parc_bytes, parc_stream, parc_ppmd;

var
  fs: TFileStream;
  slice: TFileSliceStage;
  stage: TPpmdStage;
  ms, exp: TMemoryStream;
  buf, buf2: array[0..65535] of Byte;
  n, m, i, malos: SizeInt;
  pos: Int64;
begin
  if ParamCount < 6 then
  begin
    WriteLn('uso: testppmd arc offset tamaño esperado orden memMB');
    Halt(2);
  end;
  fs := TFileStream.Create(ParamStr(1), fmOpenRead or fmShareDenyNone);
  slice := TFileSliceStage.Create(fs, StrToInt64(ParamStr(2)), StrToInt64(ParamStr(3)));
  stage := TPpmdStage.Create(slice, StrToInt(ParamStr(5)),
                             Int64(StrToInt(ParamStr(6))) * 1024 * 1024, 0, 0);
  ms := TMemoryStream.Create;
  try
    repeat
      n := stage.Read(@buf[0], SizeOf(buf));
      if n > 0 then ms.Write(buf[0], n);
    until (n <= 0) or (ms.Size > Int64(64) * 1024 * 1024);  { tope: un stream corrupto no debe colgar }
  except
    on E: EArcCorrupt do
    begin
      WriteLn('CORRUPTO: ', E.Message);
      stage.Free; fs.Free; ms.Free;
      Halt(3);
    end;
  end;
  stage.Free;      { libera la cadena de etapas (slice); fs es aparte }
  fs.Free;

  ms.SaveToFile(ParamStr(4) + '.dec');
  exp := TMemoryStream.Create;
  exp.LoadFromFile(ParamStr(4));
  WriteLn(Format('decodificado: %d bytes   esperado: %d bytes', [ms.Size, exp.Size]));
  if ms.Size <> exp.Size then
  begin
    WriteLn('FALLA: el tamaño no coincide');
    exp.Free; ms.Free; Halt(1);
  end;
  malos := 0;
  pos := 0;
  while pos < ms.Size do
  begin
    n := SizeOf(buf);
    if ms.Size - pos < n then n := ms.Size - pos;
    ms.Position := pos;  ms.Read(buf[0], n);
    exp.Position := pos; exp.Read(buf2[0], n);
    m := 0;
    while m < n do
    begin
      if buf[m] <> buf2[m] then
      begin
        if malos = 0 then
          WriteLn(Format('primer byte distinto en el offset %d', [pos + m]));
        Inc(malos);
      end;
      Inc(m);
    end;
    Inc(pos, n);
  end;
  if malos = 0 then
    WriteLn('OK: byte a byte identico al original')
  else
    WriteLn(Format('FALLA: %d bytes distintos', [malos]));
  exp.Free; ms.Free;
  if malos <> 0 then Halt(1);
end.
