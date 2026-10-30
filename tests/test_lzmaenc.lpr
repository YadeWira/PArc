{ Round-trip del codificador LZMA (parc_lzmaenc) contra el decodificador de PArc (parc_lzma).
  Uso: tests/test_lzmaenc [-dump DIR] [-quick] [archivos...]
  - Sin archivos usa solo datos generados (vacío, 1 byte, aleatorio, repetitivos, > diccionario).
  - Cada entrada se comprime con TLzmaEncStage entregándola en pedazos de tamaño aleatorio, se
    descomprime con TLzmaStage (sobre TMemStage) y se compara byte a byte. También se prueba
    LzmaEncodeMem y parámetros inválidos.
  - Match finder multihilo (bt4): con 2 y 3 hilos (NumThreads y la concesión LzmaEncThreadGrant)
    la salida tiene que ser idéntica a la de un hilo, también normalizando las posiciones.
    ht4 (:normal) multihilo: idéntica a la lista del multihilo con un hilo (LzmaHtListOneThread),
    también normalizando las filas (LzmaHtPosBits).
  - Con -dump DIR escribe DIR/NNNN.lz y DIR/manifest.txt ("NNNN.lz <orig> dict lc lp pb") para
    validar los streams con liblzma (Python lzma, FORMAT_RAW + FILTER_LZMA1).
  Sale con 0 si todo coincide. }
program test_lzmaenc;

{$mode objfpc}{$H+}

uses
  {$IFDEF UNIX}cthreads,{$ENDIF}
  SysUtils, Classes, parc_outstream, parc_stream, parc_lzma, parc_lzmaenc, parc_parallel;

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

{ Multihilo: misma salida que con un hilo, con NumThreads = 2/3 y con la concesión del hilo
  (NumThreads = 0); los hilos tienen que arrancar de verdad (LzmaMtStarts). }
procedure CheckMt(const Name: string; const Data: TBytes; const Method: string; NormLimit: LongWord;
  HtPosBits: Integer = 0);
var
  P: TLzmaEncParams;
  ref, comp, back: TBytes;
  msg: string;
  k, starts: Integer;
begin
  P := ParseLzmaEncParams(SplitMethod(Method));
  P.NumThreads := 1;
  LzmaHtPosBits := HtPosBits;
  // ht4: la referencia de un hilo es la lista del multihilo (la de FreeArc -mt1 es otra)
  LzmaHtListOneThread := True;
  try
    ref := EncodeStage(Data, P);
  finally
    LzmaHtListOneThread := False;
  end;
  LzmaMtNormLimit := NormLimit;
  try
    for k := 0 to 2 do
    begin
      msg := '';
      starts := LzmaMtStarts;
      case k of
        0: P.NumThreads := 2;
        1: P.NumThreads := 3;
        2: begin P.NumThreads := 0; LzmaEncThreadGrant := 2; end;
      end;
      try
        comp := EncodeStage(Data, P);
      finally
        LzmaEncThreadGrant := 0;
      end;
      if (Length(Data) >= 4096) and (LzmaMtStarts = starts) then msg := 'no arrancó el multihilo'
      else if (Length(comp) <> Length(ref)) or ((Length(ref) > 0) and not CompareMem(@comp[0], @ref[0], Length(ref))) then
        msg := Format('salida distinta de 1 hilo (%d vs %d)', [Length(comp), Length(ref)])
      else
      begin
        back := DecodeStage(comp, P, Length(Data), msg);
        if (msg = '') and (Length(Data) > 0) and not CompareMem(@back[0], @Data[0], Length(Data)) then
          msg := 'contenido distinto';
      end;
      if msg = '' then
      begin
        Inc(Passes);
        WriteLn(Format('  ok   mt%d %-18s %-30s norm=%-10d %10d -> %10d', [k, Name, Method, NormLimit, Length(Data), Length(comp)]));
      end
      else
      begin
        Inc(Fails);
        WriteLn(Format('  FAIL mt%d %-18s %-30s norm=%d: %s', [k, Name, Method, NormLimit, msg]));
      end;
    end;
  finally
    LzmaMtNormLimit := $FFFFFFFF;
    LzmaHtPosBits := 0;
  end;
end;

procedure ExpectThreads(const Method: string; NumThreads, Grant, Want: Integer);
var
  P: TLzmaEncParams;
  got: Integer;
begin
  P := ParseLzmaEncParams(SplitMethod(Method));
  P.NumThreads := NumThreads;
  LzmaEncThreadGrant := Grant;
  got := LzmaEncThreadsFor(P);
  LzmaEncThreadGrant := 0;
  if got = Want then
  begin
    Inc(Passes);
    WriteLn(Format('  ok   hilos %s NumThreads=%d concesión=%d -> %d', [Method, NumThreads, Grant, got]));
  end
  else
  begin
    Inc(Fails);
    WriteLn(Format('  FAIL hilos %s NumThreads=%d concesión=%d -> %d (esperado %d)', [Method, NumThreads, Grant, got, Want]));
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
  AllMethods: array[0..18] of string = (
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
    'lzma:64mb:fast',
    // ht4 (tabla hash de FreeArc): filas de 1 entrada, mc grande (tope de fila) y a1
    'lzma:64kb:fast:ht4:mc1',
    'lzma:64kb:ht4:mc100000:fb273',
    'lzma:1mb:normal:ht4:mc64:lc0:lp4:pb4',
    'lzma:4mb:a1:ht4:fb5:mc3'
  );
  QuickMethods: array[0..5] of string = (
    'lzma:64kb:normal:bt4', 'lzma:64kb:fast:hc4', 'lzma:1mb:max', 'lzma:1mb:bt3:lc0:lp2:pb0', 'lzma:64mb:fastest',
    'lzma:64kb:ht4:mc100000');

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

  WriteLn('== hilos del match finder');
  // Sin concesión: automático, la parte del presupuesto global (al menos 2, como mucho los
  // que le sirven); un hilo dentro de 4x4 (LzmaSingleThreadHere) o con presupuesto de uno
  if BudgetThreads >= 2 then ExpectThreads('lzma:max', 0, 0, 3)
  else ExpectThreads('lzma:max', 0, 0, 1);
  LzmaSingleThreadHere := True;
  ExpectThreads('lzma:max', 0, 0, 1);
  ExpectThreads('lzma:max', 0, 2, 1);       // dentro de 4x4 manda el hilo único
  ExpectThreads('lzma:max', 2, 0, 2);       // salvo NumThreads explícito
  LzmaSingleThreadHere := False;
  ExpectThreads('lzma:max', 0, 2, 2);
  ExpectThreads('lzma:max', 0, 8, 3);       // más de 3 no le sirven
  ExpectThreads('lzma:max', 2, 0, 2);
  ExpectThreads('lzma:normal', 0, 4, 2);    // ht4: hasta 2 (LZ + filas)
  ExpectThreads('lzma:fast', 0, 4, 1);      // ht4 fast: un hilo
  ExpectThreads('lzma:fast:bt4', 3, 0, 1);  // fast: un hilo
  ExpectThreads('lzma:normal:bt4', 0, 3, 3);
  WriteLn('== multihilo (bt4)');
  d := GenFarRepeat(6 shl 20, (1 shl 20) - 1);
  CheckMt('repite a 1MB-1', d, 'lzma:1mb:max', $FFFFFFFF);
  CheckMt('repite a 1MB-1', d, 'lzma:1mb:normal:bt4:mc8', (1 shl 20) + (3 shl 19));
  d := GenRandom(3 shl 20);
  CheckMt('aleatorio 3MB', d, 'lzma:256kb:ultra', (1 shl 18) + (1 shl 19) + 7);
  SetLength(d, 5 shl 20); FillChar(d[0], Length(d), 0);
  CheckMt('ceros 5MB', d, 'lzma:4mb:max', $FFFFFFFF);
  SetLength(d, 100); FillChar(d[0], Length(d), 7);
  CheckMt('100 bytes', d, 'lzma:4mb:max', $FFFFFFFF);
  WriteLn('== multihilo (ht4)');
  d := GenFarRepeat(6 shl 20, (1 shl 20) - 1);
  CheckMt('repite a 1MB-1', d, 'lzma:1mb:normal', $FFFFFFFF);
  CheckMt('repite a 1MB-1', d, 'lzma:2mb:normal:mc4', $FFFFFFFF);
  d := GenFarRepeat(12 shl 20, 100003);
  CheckMt('repite 12MB norm', d, 'lzma:256kb:normal', $FFFFFFFF, 23);
  SetLength(d, 5 shl 20); FillChar(d[0], Length(d), 0);
  CheckMt('ceros 5MB', d, 'lzma:4mb:normal', $FFFFFFFF);
  SetLength(d, 100); FillChar(d[0], Length(d), 7);
  CheckMt('100 bytes', d, 'lzma:4mb:normal', $FFFFFFFF);

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
