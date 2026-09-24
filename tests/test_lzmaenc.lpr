{ Round-trip del codificador LZMA (parc_lzmaenc) contra el decodificador de PArc (parc_lzma).
  Uso: tests/test_lzmaenc [-dump DIR] [-quick] [archivos...]
  - Sin archivos usa solo datos generados (vacío, 1 byte, aleatorio, repetitivos, > diccionario).
  - Cada entrada se comprime con TLzmaEncStage entregándola en pedazos de tamaño aleatorio, se
    descomprime con TLzmaStage (sobre TMemStage) y se compara byte a byte. También se prueba
    LzmaEncodeMem y parámetros inválidos.
  - Con -dump DIR escribe DIR/NNNN.lz y DIR/manifest.txt ("NNNN.lz <orig> dict lc lp pb") para
    validar los streams con liblzma (Python lzma, FORMAT_RAW + FILTER_LZMA1).
  Sale con 0 si todo coincide. }
program test_lzmaenc;

{$mode objfpc}{$H+}

uses
  SysUtils, Classes, parc_outstream, parc_stream, parc_lzma, parc_lzmaenc;

var
  Fails, Passes, DumpN: Integer;
  DumpDir: string;
  Manifest: TStringList;
  Quick: Boolean;
  Seed: LongWord = 12345;

function Rnd(n: LongWord): LongWord;
begin
  // xorshift32: reproducible entre plataformas
  Seed := Seed xor (Seed shl 13);
  Seed := Seed xor (Seed shr 17);
  Seed := Seed xor (Seed shl 5);
  Result := Seed mod n;
end;

function LoadFile(const N: string): TBytes;
var
  f: TFileStream;
begin
  f := TFileStream.Create(N, fmOpenRead or fmShareDenyNone);
  try
    SetLength(Result, f.Size);
    if f.Size > 0 then f.ReadBuffer(Result[0], f.Size);
  finally
    f.Free;
  end;
end;

procedure SaveFile(const N: string; const B: TBytes);
var
  f: TFileStream;
begin
  f := TFileStream.Create(N, fmCreate);
  try
    if Length(B) > 0 then f.WriteBuffer(B[0], Length(B));
  finally
    f.Free;
  end;
end;

function SplitMethod(const M: string): TStringArray;
begin
  Result := M.Split([':']);
end;

{ Comprime con la etapa en pedazos aleatorios }
function EncodeStage(const Data: TBytes; const P: TLzmaEncParams): TBytes;
var
  sink: TMemSink;
  st: TLzmaEncStage;
  pos, n: SizeInt;
  r: LongWord;
begin
  sink := TMemSink.Create;
  st := TLzmaEncStage.Create(sink, P, True);
  try
    pos := 0;
    while pos < Length(Data) do
    begin
      r := Rnd(100);
      if r < 40 then n := 1 + Rnd(64)
      else if r < 70 then n := 1 + Rnd(4096)
      else if r < 95 then n := 1 + Rnd(300000)
      else n := 1 + Rnd(3000000);
      if n > Length(Data) - pos then n := Length(Data) - pos;
      st.Write(@Data[pos], n);
      if Rnd(10) = 0 then st.Write(@Data[pos], 0);   // escrituras vacías
      Inc(pos, n);
    end;
    st.Finish;
    Result := sink.Bytes;
  finally
    st.Free;   // libera también sink
  end;
end;

{ Descomprime con TLzmaStage (streaming, exige marca de fin) }
function DecodeStage(const Comp: TBytes; const P: TLzmaEncParams; ExpectLen: SizeInt; out Msg: string): TBytes;
var
  dec: TLzmaStage;
  n, got: SizeInt;
  extra: Byte;
begin
  Msg := '';
  SetLength(Result, ExpectLen);
  dec := TLzmaStage.Create(TMemStage.Create(PByte(Comp), Length(Comp)), P.lc, P.lp, P.pb, P.DictSize);
  try
    got := 0;
    try
      while got < ExpectLen do
      begin
        n := dec.Read(@Result[got], ExpectLen - got);
        if n <= 0 then Break;
        Inc(got, n);
      end;
      if got <> ExpectLen then Msg := Format('decodificó %d de %d', [got, ExpectLen])
      else if dec.Read(@extra, 1) <> 0 then Msg := 'bytes de más tras el final';
    except
      on E: Exception do Msg := 'excepción del decodificador: ' + E.Message;
    end;
  finally
    dec.Free;
  end;
end;

procedure Dump(const Comp: TBytes; const P: TLzmaEncParams; const Orig: string);
var
  n: string;
begin
  if DumpDir = '' then Exit;
  Inc(DumpN);
  n := Format('%.4d.lz', [DumpN]);
  SaveFile(IncludeTrailingPathDelimiter(DumpDir) + n, Comp);
  Manifest.Add(Format('%s %s %d %d %d %d', [n, Orig, P.DictSize, P.lc, P.lp, P.pb]));
end;

procedure Check(const Name: string; const Data: TBytes; const Method: string; const OrigPath: string);
var
  P: TLzmaEncParams;
  comp, back: TBytes;
  msg: string;
  t0: QWord;
begin
  P := ParseLzmaEncParams(SplitMethod(Method));
  t0 := GetTickCount64;
  comp := EncodeStage(Data, P);
  back := DecodeStage(comp, P, Length(Data), msg);
  if (msg = '') and (Length(Data) > 0) and not CompareMem(@back[0], @Data[0], Length(Data)) then
    msg := 'contenido distinto';
  if msg = '' then
  begin
    Inc(Passes);
    WriteLn(Format('  ok   %-22s %-34s %10d -> %10d  %6d ms', [Name, Method, Length(Data), Length(comp), GetTickCount64 - t0]));
    if OrigPath <> '' then Dump(comp, P, OrigPath);
  end
  else
  begin
    Inc(Fails);
    WriteLn(Format('  FAIL %-22s %-34s %s', [Name, Method, msg]));
  end;
end;

procedure CheckMem(const Name: string; const Data: TBytes; const Method: string);
var
  P: TLzmaEncParams;
  comp, back: TBytes;
  msg: string;
begin
  P := ParseLzmaEncParams(SplitMethod(Method));
  comp := LzmaEncodeMem(PByte(Data), Length(Data), P, True);
  back := DecodeStage(comp, P, Length(Data), msg);
  if (msg = '') and (Length(Data) > 0) and not CompareMem(@back[0], @Data[0], Length(Data)) then
    msg := 'contenido distinto';
  if msg = '' then
  begin
    Inc(Passes);
    WriteLn(Format('  ok   mem %-18s %-34s %10d -> %10d', [Name, Method, Length(Data), Length(comp)]));
  end
  else
  begin
    Inc(Fails);
    WriteLn(Format('  FAIL mem %-18s %-34s %s', [Name, Method, msg]));
  end;
end;

procedure ExpectError(const Method: string);
var
  P: TLzmaEncParams;
  st: TLzmaEncStage;
  sink: TMemSink;
begin
  sink := TMemSink.Create;
  try
    try
      P := ParseLzmaEncParams(SplitMethod(Method));
      st := TLzmaEncStage.Create(sink, P, True);
      sink := nil;   // adoptado
      st.Free;
      Inc(Fails);
      WriteLn('  FAIL inválido aceptado: ', Method);
    except
      on E: ELzmaEncParams do
      begin
        Inc(Passes);
        WriteLn('  ok   inválido rechazado: ', Method, '  (', E.Message, ')');
      end;
      on E: Exception do
      begin
        Inc(Fails);
        WriteLn('  FAIL inválido con excepción inesperada ', E.ClassName, ': ', Method);
      end;
    end;
  finally
    sink.Free;   // si el constructor falló, el destino no fue adoptado
  end;
end;

procedure ExpectParse(const Method: string; Dict: QWord; mf: TLzmaMatchFinder; fb, mc, algo: Integer);
var
  P: TLzmaEncParams;
begin
  P := ParseLzmaEncParams(SplitMethod(Method));
  if (P.DictSize = Dict) and (P.MatchFinder = mf) and (P.NumFastBytes = fb)
    and (P.MatchFinderCycles = mc) and (P.Algorithm = algo) then
  begin
    Inc(Passes);
    WriteLn('  ok   parse ', Method);
  end
  else
  begin
    Inc(Fails);
    WriteLn(Format('  FAIL parse %s: d=%d mf=%d fb=%d mc=%d a=%d', [Method, P.DictSize, Ord(P.MatchFinder),
      P.NumFastBytes, P.MatchFinderCycles, P.Algorithm]));
  end;
end;

function GenRandom(n: SizeInt): TBytes;
var
  i: SizeInt;
begin
  SetLength(Result, n);
  for i := 0 to n - 1 do Result[i] := Byte(Rnd(256));
end;

function GenRepeat(n, period: SizeInt): TBytes;
var
  i: SizeInt;
begin
  SetLength(Result, n);
  for i := 0 to n - 1 do Result[i] := Byte((i mod period) * 7 + 3);
end;

{ Bloques que se repiten a distancias cercanas al diccionario (fuerza el deslizamiento) }
function GenFarRepeat(n, blk: SizeInt): TBytes;
var
  base: TBytes;
  i: SizeInt;
begin
  base := GenRandom(blk);
  SetLength(Result, n);
  for i := 0 to n - 1 do
  begin
    Result[i] := base[i mod blk];
    if Rnd(5000) = 0 then Result[i] := Byte(Rnd(256));   // mutaciones sueltas
  end;
end;

const
  AllMethods: array[0..14] of string = (
    'lzma:64kb:normal:bt4',
    'lzma:64kb:fast:hc4',
    'lzma:64kb:bt2:a1:fb16',
    'lzma:64kb:bt3:lc0:lp2:pb0',
    'lzma:1mb:max',
    'lzma:1mb:ultra',
    'lzma:1mb:fastest',
    'lzma:1mb:hc4:lc8:lp4:pb4:a0',
    'lzma:1mb:bt4:lc0:lp0:pb0:fb273',
    'lzma:4mb:normal',
    'lzma:4mb:a1:bt3:mc4:fb5',
    'lzma:d20:bt2:a0:fb64',
    'lzma:64mb:normal:bt4',
    'lzma:64mb:max',
    'lzma:64mb:fast'
  );
  QuickMethods: array[0..4] of string = (
    'lzma:64kb:normal:bt4', 'lzma:64kb:fast:hc4', 'lzma:1mb:max', 'lzma:1mb:bt3:lc0:lp2:pb0', 'lzma:64mb:fastest');

procedure RunSet(const Name: string; const Data: TBytes; const OrigPath: string);
var
  m: string;
begin
  if Quick then
    for m in QuickMethods do Check(Name, Data, m, OrigPath)
  else
    for m in AllMethods do Check(Name, Data, m, OrigPath);
end;

procedure SaveTmp(const Name: string; const Data: TBytes; out Path: string);
begin
  Path := '';
  if DumpDir = '' then Exit;
  Path := IncludeTrailingPathDelimiter(DumpDir) + Name + '.orig';
  SaveFile(Path, Data);
end;

var
  i: Integer;
  files: TStringList;
  d, one: TBytes;
  path: string;
  f: string;
begin
  files := TStringList.Create;
  Manifest := TStringList.Create;
  i := 1;
  while i <= ParamCount do
  begin
    if ParamStr(i) = '-dump' then begin Inc(i); DumpDir := ParamStr(i); ForceDirectories(DumpDir); end
    else if ParamStr(i) = '-quick' then Quick := True
    else files.Add(ParamStr(i));
    Inc(i);
  end;

  WriteLn('== parámetros');
  ExpectParse('lzma', 64 shl 20, mfHT4, 32, 0, 1);
  ExpectParse('lzma:max', 64 shl 20, mfBT4, 128, 0, 1);
  ExpectParse('lzma:ultra:hc4', 64 shl 20, mfHC4, 128, 128, 1);
  ExpectParse('lzma:hc4:ultra', 64 shl 20, mfHC4, 128, 128, 1);
  ExpectParse('lzma:fastest:16mb', 16 shl 20, mfHT4, 5, 1, 0);
  ExpectParse('lzma:d24:a0:fb64:mc7:mf=bt2', 16 shl 20, mfBT2, 64, 7, 0);
  ExpectParse('lzma:1gb:273:BT3', QWord(1) shl 30, mfBT3, 273, 0, 1);
  ExpectParse('lzma:h64m:normal:BT4:*garbage', 64 shl 20, mfBT4, 32, 0, 1);
  ExpectError('lzma:lc9');
  ExpectError('lzma:lp5');
  ExpectError('lzma:pb5');
  ExpectError('lzma:mf=bt9');
  ExpectError('lzma:zzz');
  ExpectError('lzma:dxyz');
  ExpectError('lzma:d0b');
  ExpectError('lzma:fb-3');
  ExpectError('lzma:lc');
  ExpectError('lzip');

  WriteLn('== datos generados');
  SetLength(d, 0);
  SaveTmp('vacio', d, path); RunSet('vacío', d, path); CheckMem('vacío', d, 'lzma:max');
  SetLength(one, 1); one[0] := $41;
  SaveTmp('uno', one, path); RunSet('1 byte', one, path); CheckMem('1 byte', one, 'lzma:fast');
  d := GenRandom(3 shl 20);
  SaveTmp('aleatorio', d, path); RunSet('aleatorio 3MB', d, path); CheckMem('aleatorio', d, 'lzma:normal');
  SetLength(d, 5 shl 20); FillChar(d[0], Length(d), 0);
  SaveTmp('ceros', d, path); RunSet('ceros 5MB', d, path); CheckMem('ceros', d, 'lzma:bt4');
  d := GenRepeat(2 shl 20, 3);
  SaveTmp('periodo3', d, path); RunSet('período 3', d, path); CheckMem('período 3', d, 'lzma:hc4');
  d := GenFarRepeat(3 shl 20, 60000);
  SaveTmp('lejos60k', d, path); RunSet('repite a 60000', d, path);
  d := GenFarRepeat(4 shl 20, 65536);
  SaveTmp('lejos64k', d, path); RunSet('repite a 65536', d, path);
  d := GenFarRepeat(6 shl 20, (1 shl 20) - 1);
  SaveTmp('lejos1m', d, path); RunSet('repite a 1MB-1', d, path);

  if files.Count > 0 then
  begin
    WriteLn('== archivos');
    for f in files do
    begin
      d := LoadFile(f);
      RunSet(ExtractFileName(f), d, ExpandFileName(f));
      CheckMem(ExtractFileName(f), d, 'lzma:normal:bt4');
      CheckMem(ExtractFileName(f), d, 'lzma:64kb:fast');
    end;
  end;

  if DumpDir <> '' then Manifest.SaveToFile(IncludeTrailingPathDelimiter(DumpDir) + 'manifest.txt');
  WriteLn(Format('== %d ok, %d fallos', [Passes, Fails]));
  Manifest.Free;
  files.Free;
  if Fails > 0 then Halt(1);
end.
