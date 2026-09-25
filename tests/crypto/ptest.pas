program ptest;
{ El mismo protocolo que oracle.c, sobre las primitivas de parc_crypt. }
{$mode objfpc}{$H+}
uses SysUtils, parc_stream, parc_crypt;

function Unhex(const S: string): TBytes;
var i: Integer;
begin
  SetLength(Result, Length(S) div 2);
  for i := 0 to High(Result) do Result[i] := StrToInt('$' + Copy(S, 2 * i + 1, 2));
end;

function Hex(const B: TBytes; N: Integer): string;
var i: Integer;
begin
  Result := '';
  for i := 0 to N - 1 do Result := Result + LowerCase(IntToHex(B[i], 2));
end;

var
  L, Cmd: string;
  P: TStringArray;
  Pwd, Salt, Data, Outp: TBytes;
  Par: TCryptParams;
  St: TDecryptStage;
  got, r: Integer;
begin
  while not EOF(Input) do
  begin
    ReadLn(L);
    P := L.Split([' ']);
    if Length(P) = 0 then Continue;
    Cmd := P[0];
    if Cmd = 'E' then
    begin
      if P[1] = 'aes' then WriteLn(LowerCase(AesEcb(P[2], P[3])))
      else if P[1] = 'blowfish' then WriteLn(LowerCase(BlowfishTestVec(P[2], P[3])))
      else if P[1] = 'serpent' then WriteLn(LowerCase(SerpentTestVec(P[2], P[3])))
      else if P[1] = 'twofish' then WriteLn(LowerCase(TwofishTestVec(P[2], P[3])));
    end
    else if Cmd = 'H' then
    begin
      if P[1] = '-' then Data := nil else Data := Unhex(P[1]);
      if Length(Data) = 0 then WriteLn(Hex(Sha512Data(nil, 0), 64))
      else WriteLn(Hex(Sha512Data(@Data[0], Length(Data)), 64));
    end
    else if Cmd = 'P' then
    begin
      Pwd := Unhex(P[1]); Salt := Unhex(P[2]);
      SetLength(Outp, StrToInt(P[4]));
      Pbkdf2HmacSha512(PByte(Pwd), Length(Pwd), PByte(Salt), Length(Salt), StrToInt(P[3]), @Outp[0], Length(Outp));
      WriteLn(Hex(Outp, Length(Outp)));
    end
    else if Cmd = 'M' then
    begin
      // :f = hex normal (sin el decodificador "buggy" de FreeArc)
      Par := ParseCryptParams((P[1] + '-' + IntToStr(Length(P[3]) * 4) + '/' + P[2] + ':f:k' + P[3] + ':i' + P[4]).Split([':']));
      Data := Unhex(P[5]);
      SetLength(Outp, Length(Data));
      St := TDecryptStage.Create(TMemStage.Create(@Data[0], Length(Data)), Par);
      got := 0;
      repeat r := St.Read(@Outp[got], Length(Outp) - got); if r > 0 then Inc(got, r); until (r <= 0) or (got = Length(Outp));
      St.Free;
      WriteLn(Hex(Outp, got));
    end;
    Flush(Output);
  end;
end.
