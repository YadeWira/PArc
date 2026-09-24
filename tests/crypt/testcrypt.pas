program testcrypt;
{ Prueba de parc_crypt: deriva la clave desde el password (comprobando el
  check-code) y descifra el payload de un .arc, comparándolo con el original.

  Uso: testcrypt <arc> <offset> <tamaño> <esperado> <etapa-de-cifrado> <password>

  Salidas:  0 ok · 1 bytes distintos · 3 corrupto · 4 password incorrecta
}
{$mode objfpc}{$H+}
uses
  SysUtils, Classes, parc_bytes, parc_stream, parc_methods, parc_crypt;

var
  fs: TFileStream;
  slice: TInStage;
  st: TDecryptStage;
  ms: TMemoryStream;
  exp: TFileStream;
  buf, buf2: array[0..65535] of Byte;
  n, pos, malos, i: SizeInt;
  partes: TStringArray;
  par, par2: TCryptParams;
  pwd: RawByteString;
  key: array of Byte;
  conClave: string;
begin
  if ParamCount < 6 then
  begin
    WriteLn('uso: testcrypt arc offset tamaño esperado etapa-cifrado password');
    Halt(2);
  end;
  partes := ParamStr(5).Split([':']);
  par := ParseCryptParams(partes);
  pwd := ParamStr(6);
  SetLength(key, par.KeySize);
  WriteLn('salt=', par.SaltHex, ' n=', par.NumIterations, ' keySize=', par.KeySize, ' c_arch=', par.CheckHex);
  WriteLn('deriv=', DerivedCheckHex(par, @pwd[1], Length(pwd)));
  if not DeriveKeyAndCheck(par, @pwd[1], Length(pwd), @key[0]) then
  begin
    WriteLn('PASSWORD INCORRECTA');
    Halt(4);
  end;
  { arma el método con clave y lo vuelve a parsear, igual que va a hacer el lector }
  conClave := KeyedMethod(par, @key[0]);
  par2 := ParseCryptParams(conClave.Split([':']));

  fs := TFileStream.Create(ParamStr(1), fmOpenRead or fmShareDenyNone);
  ms := TMemoryStream.Create;
  try
    slice := TFileSliceStage.Create(fs, StrToInt64(ParamStr(2)), StrToInt64(ParamStr(3)));
    st := TDecryptStage.Create(slice, par2);    { toma posesión de slice }
    repeat
      n := st.Read(@buf[0], SizeOf(buf));
      if n > 0 then ms.Write(buf[0], n);
    until (n <= 0) or (ms.Size > Int64(128) * 1024 * 1024);
  except
    on E: Exception do
    begin
      WriteLn('EXCEPCION ', E.ClassName, ': ', E.Message);
      fs.Free; ms.Free;
      Halt(3);
    end;
  end;
  st.Free;
  fs.Free;
  ms.SaveToFile(ParamStr(4) + '.dec');
  exp := TFileStream.Create(ParamStr(4), fmOpenRead or fmShareDenyNone);
  WriteLn(Format('descifrado: %d bytes   esperado: %d', [ms.Size, exp.Size]));
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
  if malos = 0 then WriteLn('OK: descifrado byte a byte correcto')
  else WriteLn('FALLA: ', malos, ' bytes distintos');
  if malos <> 0 then Halt(1);
end.
