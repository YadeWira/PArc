program stream_test;
{ Etapas de cifrado de parc_crypt (trozos de 64 KiB): ida y vuelta en los bordes de los trozos,
  y que cortar, agregar, quitar, reordenar o alterar trozos falle siempre (sin entregar nada
  del trozo afectado), con los dos cifrados y con claves de datos y de cabeceras.
  Imprime "stream: N casos, M fallas". }
{$mode objfpc}{$H+}
uses
  {$IFDEF UNIX}cthreads,{$ENDIF} SysUtils, parc_bytes, parc_stream, parc_outstream, parc_crypt;

var
  Fails, Cases: Integer;

procedure Fail(const Msg: string);
begin
  Inc(Fails);
  WriteLn('  FAIL ', Msg);
end;

function Encrypt(const Par: TCryptParams; const Master: TMasterKey; const Plain: TBytes; Piece: SizeInt): TBytes;
var
  Sink: TMemSink;
  St: TAeadEncryptStage;
  p, n: SizeInt;
begin
  Sink := TMemSink.Create;
  St := TAeadEncryptStage.Create(Sink, Par, Master);
  try
    p := 0;
    while p < Length(Plain) do
    begin
      n := Piece;
      if n > Length(Plain) - p then n := Length(Plain) - p;
      St.Write(@Plain[p], n);
      Inc(p, n);
    end;
    St.Finish;
    Result := Sink.Bytes;
  finally
    St.Free;
  end;
end;

{ Descifra todo; False si falla la autenticación. Got = lo que se entregó antes del error. }
function Decrypt(const Par: TCryptParams; const Master: TMasterKey; const Enc: TBytes; out Plain: TBytes;
  out Got: SizeInt): Boolean;
var
  St: TAeadDecryptStage;
  n: SizeInt;
begin
  Result := True;
  Got := 0;
  SetLength(Plain, Length(Enc) + 16);
  if Length(Enc) = 0 then St := TAeadDecryptStage.Create(TMemStage.Create(nil, 0), Par, Master)
  else St := TAeadDecryptStage.Create(TMemStage.Create(@Enc[0], Length(Enc)), Par, Master);
  try
    try
      repeat
        n := St.Read(@Plain[Got], 7777);
        Inc(Got, n);
      until n = 0;
    except
      on E: EArcCorrupt do Result := False;
    end;
  finally
    St.Free;
  end;
  SetLength(Plain, Got);
end;

procedure ExpectFail(const What: string; const Par: TCryptParams; const Master: TMasterKey; const Enc: TBytes;
  MaxGood: SizeInt);
var
  P: TBytes;
  Got: SizeInt;
begin
  Inc(Cases);
  if Decrypt(Par, Master, Enc, P, Got) then Fail(What + ': se aceptó')
  else if Got > MaxGood then Fail(Format('%s: entregó %d bytes (máximo %d)', [What, Got, MaxGood]));
end;

const
  CH = CRYPT_CHUNK;
  K = CRYPT_CHUNK + CRYPT_TAG;
  SIZES: array[0..11] of SizeInt = (0, 1, 15, 16, 17, CH - 1, CH, CH + 1, 2 * CH - 1, 2 * CH, 2 * CH + 1, 3 * CH + 12345);

var
  Par, Par2: TCryptParams;
  C: TCipherChoice;
  Master: TMasterKey;
  Plain, Enc, Bad, Dec: TBytes;
  i, s, Nch: Integer;
  Got: SizeInt;
  Kind: TCipherKind;
  Hdr: Boolean;
  Stage: string;
begin
  Fails := 0; Cases := 0;
  RandSeed := 12345;
  for Kind := Low(TCipherKind) to High(TCipherKind) do
    for Hdr := False to True do
    begin
      C.Kind := Kind; C.T := 1; C.M := 64; C.P := 1;
      Stage := CryptStageForWrite(C, 'clave de prueba', Hdr);
      Par := ParseCipherStage(Stage);
      if CipherStageString(Par) <> Stage then Fail('la cadena de la etapa no vuelve igual: ' + Stage);
      if not CryptLookup(Par, Master) then begin Fail('sin clave en el caché'); Continue; end;
      for s := 0 to High(SIZES) do
      begin
        SetLength(Plain, SIZES[s]);
        for i := 0 to High(Plain) do Plain[i] := Random(256);
        Enc := Encrypt(Par, Master, Plain, 1 + Random(100000));
        Nch := (SIZES[s] + CH - 1) div CH;
        if Nch = 0 then Nch := 1;
        Inc(Cases);
        if Length(Enc) <> SIZES[s] + Nch * CRYPT_TAG then
          Fail(Format('%s %d: largo cifrado %d', [CipherName(Kind), SIZES[s], Length(Enc)]));
        Inc(Cases);
        if not Decrypt(Par, Master, Enc, Dec, Got) or (Length(Dec) <> Length(Plain)) or
           ((Length(Plain) > 0) and not CompareMem(@Dec[0], @Plain[0], Length(Plain))) then
          Fail(Format('%s %d: ida y vuelta', [CipherName(Kind), SIZES[s]]));
        // byte alterado en cada trozo (comienzo, medio, etiqueta): nada de ese trozo sale
        for i := 0 to Nch - 1 do
        begin
          Bad := Copy(Enc);
          Bad[i * K] := Bad[i * K] xor $80;
          ExpectFail(Format('%d: trozo %d, primer byte', [SIZES[s], i]), Par, Master, Bad, i * CH);
          Bad := Copy(Enc);
          if i < Nch - 1 then Bad[i * K + K - 1] := Bad[i * K + K - 1] xor 1
          else Bad[High(Bad)] := Bad[High(Bad)] xor 1;
          ExpectFail(Format('%d: trozo %d, etiqueta', [SIZES[s], i]), Par, Master, Bad, i * CH);
        end;
        // truncado: un byte menos, y cortado justo en el borde de un trozo
        if Length(Enc) > 0 then
          ExpectFail(Format('%d: un byte menos', [SIZES[s]]), Par, Master, Copy(Enc, 0, Length(Enc) - 1), (Nch - 1) * CH);
        for i := 1 to Nch - 1 do
          ExpectFail(Format('%d: cortado tras el trozo %d', [SIZES[s], i]), Par, Master, Copy(Enc, 0, i * K), i * CH);
        // un trozo de más (copia del primero) o sin el primero
        if Nch >= 2 then
        begin
          ExpectFail(Format('%d: sin el primer trozo', [SIZES[s]]), Par, Master, Copy(Enc, K, MaxInt), 0);
          Bad := Copy(Enc, 0, K);
          Bad := Concat(Bad, Copy(Enc, 0, MaxInt));
          ExpectFail(Format('%d: primer trozo repetido', [SIZES[s]]), Par, Master, Bad, CH);
          // dos trozos intercambiados
          Bad := Concat(Copy(Enc, K, K), Copy(Enc, 0, K), Copy(Enc, 2 * K, MaxInt));
          ExpectFail(Format('%d: trozos 0 y 1 intercambiados', [SIZES[s]]), Par, Master, Bad, 0);
        end;
        Bad := Concat(Copy(Enc), Copy(Enc, 0, 20));
        ExpectFail(Format('%d: bytes de más al final', [SIZES[s]]), Par, Master, Bad, Nch * CH);
        // otro nonce de bloque, el otro uso (datos/cabeceras): no abre
        Par2 := Par;
        Par2.Nonce[3] := Par2.Nonce[3] xor 1;
        ExpectFail(Format('%d: otro nonce de bloque', [SIZES[s]]), Par2, Master, Enc, 0);
        Par2 := Par;
        Par2.Header := not Par.Header;
        ExpectFail(Format('%d: clave del otro uso', [SIZES[s]]), Par2, Master, Enc, 0);
      end;
    end;
  // la contraseña: buena, mala, y una etapa con otra sal
  C.Kind := ckXChaCha20; C.T := 1; C.M := 64; C.P := 2;
  Par := ParseCipherStage(CryptStageForWrite(C, 'otra clave', False));
  Inc(Cases);
  if not CryptTryPassword(Par, 'otra clave', Master) then Fail('contraseña buena rechazada');
  Inc(Cases);
  if CryptTryPassword(Par, 'otra clavE', Master) then Fail('contraseña mala aceptada');
  Inc(Cases);
  if CryptTryPassword(Par, 'otra clavE', Master) then Fail('contraseña mala aceptada (del caché)');
  // etapas mal formadas
  for Stage in ['xchacha20:t1:m64:p1:s00:c0000000000000000:n00000000000000000000000000000000',
                'xchacha20:t0:m64:p1:s00000000000000000000000000000000:c0000000000000000:n00000000000000000000000000000000',
                'xchacha20:t1:m4:p1:s00000000000000000000000000000000:c0000000000000000:n00000000000000000000000000000000',
                'xchacha20:t1:m99999999:p1:s00000000000000000000000000000000:c0000000000000000:n00000000000000000000000000000000',
                'xchacha20:t1:m64:p1:s00000000000000000000000000000000:c0000000000000000',
                'xchacha20:t1:m64:p1:s00000000000000000000000000000000:c0000000000000000:n00000000000000000000000000000000:q',
                'aes256gcm:t1:t1:m64:p1:s00000000000000000000000000000000:c0000000000000000:n00000000000000000000000000000000'] do
  begin
    Inc(Cases);
    try
      ParseCipherStage(Stage);
      Fail('etapa aceptada: ' + Stage);
    except
      on E: EArcCorrupt do ;
    end;
  end;
  WriteLn(Format('stream: %d casos, %d fallas', [Cases, Fails]));
  if Fails > 0 then Halt(1);
end.
