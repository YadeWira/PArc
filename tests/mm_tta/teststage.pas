program teststage;
{ Decodifica el payload de un .arc con parc_mm o parc_tta y lo compara byte a
  byte con el archivo original.

  Uso:  teststage <arc> <offset> <tamaño> <esperado> <metodo-con-params>
  Ej:   teststage a.arc 31 12345 foto.bmp  "mm:1*24"
        teststage b.arc 31  6789 tono.wav  "tta"
}
{$mode objfpc}{$H+}
uses
  SysUtils, Classes, parc_bytes, parc_stream, parc_methods, parc_mm, parc_tta;

var
  fs: TFileStream;
  slice: TInStage;
  st: TInStage;
  ms: TMemoryStream;
  buf: array[0..65535] of Byte;
  n, pos, malos, i: SizeInt;
  partes: TStringArray;
  exp: TFileStream;
  buf2: array[0..65535] of Byte;

begin
  if ParamCount < 5 then
  begin
    WriteLn('uso: teststage arc offset tamaño esperado metodo');
    Halt(2);
  end;
  partes := ParamStr(5).Split([':']);
  fs := TFileStream.Create(ParamStr(1), fmOpenRead or fmShareDenyNone);
  slice := TFileSliceStage.Create(fs, StrToInt64(ParamStr(2)), StrToInt64(ParamStr(3)));
  if partes[0] = 'mm' then
    st := TMmStage.Create(slice, ParseMmParams(partes))
  else if partes[0] = 'tta' then
    st := TTtaStage.Create(slice, ParseTtaParams(partes))
  else
  begin
    WriteLn('método desconocido: ', partes[0]);
    Halt(2);
  end;

  ms := TMemoryStream.Create;
  try
    repeat
      n := st.Read(@buf[0], SizeOf(buf));
      if n > 0 then ms.Write(buf[0], n);
    until (n <= 0) or (ms.Size > Int64(512) * 1024 * 1024);
  except
    on E: Exception do
    begin
      WriteLn('EXCEPCION ', E.ClassName, ': ', E.Message);
      st.Free; fs.Free; ms.Free;
      Halt(3);
    end;
  end;
  st.Free;      { libera la cadena de etapas (slice); fs va aparte }
  fs.Free;
  ms.SaveToFile(ParamStr(4) + '.dec');
  exp := TFileStream.Create(ParamStr(4), fmOpenRead or fmShareDenyNone);
  WriteLn(Format('decodificado: %d bytes   esperado: %d', [ms.Size, exp.Size]));
  if ms.Size <> exp.Size then
  begin
    WriteLn('FALLA: el tamaño no coincide');
    exp.Free; ms.Free; Halt(1);
  end;
  malos := 0; i := 0;
  pos := 0;
  while pos < ms.Size do
  begin
    n := SizeOf(buf);
    if ms.Size - pos < n then n := ms.Size - pos;
    ms.Position := pos; ms.Read(buf[0], n);
    exp.Position := pos; exp.Read(buf2[0], n);
    i := 0;
    while i < n do
    begin
      if buf[i] <> buf2[i] then
      begin
        if malos = 0 then WriteLn('primer byte distinto en el offset ', pos + i);
        Inc(malos);
      end;
      Inc(i);
    end;
    Inc(pos, SizeOf(buf));
  end;
  exp.Free; ms.Free;
  if malos = 0 then WriteLn('OK: byte a byte identico al original')
  else WriteLn('FALLA: ', malos, ' bytes distintos');
  if malos <> 0 then Halt(1);
end.
