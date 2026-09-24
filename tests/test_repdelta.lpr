{ Round-trip de los codificadores rep y delta (parc_repenc, parc_deltaenc) contra los
  decodificadores de PArc (TRepStage, TDeltaStage):
    tests/test_repdelta [archivos...]
  Comprime cada dato con cada método escribiendo en pedazos de tamaño aleatorio (1 byte a
  1 MB) sobre una TMemSink, descomprime con TMemStage -> decodificador leyendo también en
  pedazos aleatorios, y compara byte a byte. Además de los archivos dados usa datos sintéticos
  (vacío, 1 byte, tablas int16/int32 crecientes, registros, repetición a gran distancia que
  fuerza la vuelta de la ventana, aleatorio) y prueba parámetros inválidos.
  Sale con 0 si todo pasa. }
program test_repdelta;

{$mode objfpc}{$H+}

uses
  SysUtils, Classes, parc_outstream, parc_stream, parc_rep, parc_filters, parc_repenc, parc_deltaenc;

var
  NOk, NBad: Integer;

function Compress(const Method: string; const Data: TBytes; MaxChunk: SizeInt): TBytes;
var
  Sink: TMemSink;
  St: TOutStage;
  Parts: TStringArray;
  pos, n: SizeInt;
begin
  Sink := TMemSink.Create;
  Parts := Method.Split([':']);
  try
    if Parts[0] = 'rep' then St := TRepEncStage.Create(Sink, Parts)
    else St := TDeltaEncStage.Create(Sink, Parts);
  except
    Sink.Free;
    raise;
  end;
  try
    pos := 0;
    while pos < Length(Data) do
    begin
      // Mezcla de pedazos chicos y grandes, hasta MaxChunk
      if Random(4) = 0 then n := 1 + Random(16) else n := 1 + Random(MaxChunk);
      if n > Length(Data) - pos then n := Length(Data) - pos;
      St.Write(@Data[pos], n);
      Inc(pos, n);
    end;
    St.Finish;
    Result := Sink.Bytes;
  finally
    St.Free;   // libera también Sink
  end;
end;

function Decompress(const Method: string; const Comp: TBytes): TBytes;
var
  Src: TMemStage;
  St: TInStage;
  Buf: array of Byte;
  n, len: SizeInt;
begin
  Src := TMemStage.Create(PByte(Comp), Length(Comp));
  if Copy(Method, 1, 3) = 'rep' then St := TRepStage.Create(Src)
  else St := TDeltaStage.Create(Src);
  try
    SetLength(Buf, 1 shl 20);
    SetLength(Result, 0);
    len := 0;
    repeat
      n := St.Read(@Buf[0], 1 + Random(Length(Buf)));
      if n > 0 then
      begin
        if len + n > Length(Result) then SetLength(Result, 2 * (len + n));
        Move(Buf[0], Result[len], n);
        Inc(len, n);
      end;
    until n = 0;
    SetLength(Result, len);
  finally
    St.Free;
  end;
end;

procedure RoundTrip(const Name, Method: string; const Data: TBytes);
var
  C, D: TBytes;
  t0: QWord;
  i: SizeInt;
  msg: string;
begin
  t0 := GetTickCount64;
  msg := '';
  try
    C := Compress(Method, Data, 1 shl 20);
    D := Decompress(Method, C);
    if Length(D) <> Length(Data) then
      msg := Format('largo %d, esperado %d', [Length(D), Length(Data)])
    else
      for i := 0 to High(D) do
        if D[i] <> Data[i] then begin msg := Format('difiere en %d', [i]); Break; end;
  except
    on E: Exception do msg := E.ClassName + ': ' + E.Message;
  end;
  if msg = '' then
  begin
    Inc(NOk);
    WriteLn(Format('OK    %-14s %-26s %10d -> %10d  %6.2f s', [Name, Method, Length(Data), Length(C),
      (GetTickCount64 - t0) / 1000]));
  end
  else
  begin
    Inc(NBad);
    WriteLn(Format('FALLA %-14s %-26s %s', [Name, Method, msg]));
  end;
end;

procedure ExpectInvalid(const Method: string);
var
  Sink: TMemSink;
  St: TOutStage;
  Parts: TStringArray;
  Raised: Boolean;
begin
  Sink := TMemSink.Create;
  Parts := Method.Split([':']);
  Raised := False;
  St := nil;
  try
    if Parts[0] = 'rep' then St := TRepEncStage.Create(Sink, Parts)
    else St := TDeltaEncStage.Create(Sink, Parts);
  except
    on E: Exception do Raised := True;
  end;
  if Raised then
  begin
    // El destino sigue siendo nuestro: liberarlo no puede fallar (no hubo doble liberación)
    Sink.Write(PByte(PChar('x')), 1);
    Sink.Free;
    Inc(NOk);
    WriteLn('OK    parámetro inválido rechazado: ', Method);
  end
  else
  begin
    St.Free;
    Inc(NBad);
    WriteLn('FALLA parámetro inválido aceptado: ', Method);
  end;
end;

function LoadFile(const FN: string): TBytes;
var
  fs: TFileStream;
begin
  fs := TFileStream.Create(FN, fmOpenRead or fmShareDenyNone);
  try
    SetLength(Result, fs.Size);
    if fs.Size > 0 then fs.ReadBuffer(Result[0], fs.Size);
  finally
    fs.Free;
  end;
end;

function RandomBytes(n: SizeInt): TBytes;
var
  i: SizeInt;
begin
  SetLength(Result, n);
  for i := 0 to n - 1 do Result[i] := Random(256);
end;

function Table16(Rows: SizeInt): TBytes;
var
  i: SizeInt;
  v: Word;
begin
  SetLength(Result, 2 * Rows);
  v := 0;
  for i := 0 to Rows - 1 do
  begin
    v := (v + 1 + Random(40)) mod 30000;
    Result[2 * i] := Byte(v); Result[2 * i + 1] := Byte(v shr 8);
  end;
end;

function Table32(Rows: SizeInt): TBytes;
var
  i: SizeInt;
  v: LongWord;
begin
  SetLength(Result, 4 * Rows);
  v := 0;
  for i := 0 to Rows - 1 do
  begin
    Inc(v, 1 + Random(5000));
    Move(v, Result[4 * i], 4);
  end;
end;

{ Registros de 12 bytes (int32 creciente, constante, contador, constante) intercalados con texto }
function Records(Count: SizeInt): TBytes;
var
  i, p, k, n, r: SizeInt;
  t: LongWord;
  w: Word;
  c: LongWord;
begin
  SetLength(Result, Count * 12 + Count div 4 * 3);
  p := 0; t := 0;
  i := 0;
  while i < Count do
  begin
    n := 50 + Random(2000);
    for r := 1 to n do
    begin
      if p + 12 > Length(Result) then Break;
      Inc(t, Random(300));
      Move(t, Result[p], 4);
      w := 7; Move(w, Result[p + 4], 2);
      w := Word(i); Move(w, Result[p + 6], 2);
      c := $DEADBEEF; Move(c, Result[p + 8], 4);
      Inc(p, 12); Inc(i);
    end;
    for k := 1 to 100 + Random(500) do
    begin
      if p >= Length(Result) then Break;
      Result[p] := Ord('a') + Random(26);
      Inc(p);
    end;
    if p + 12 > Length(Result) then Break;
  end;
  SetLength(Result, p);
end;

{ X + aleatorio + X: coincidencia a gran distancia; con ventana chica, vuelve al principio }
function FarRepeat(const X: TBytes; Gap: SizeInt): TBytes;
var
  G: TBytes;
begin
  G := RandomBytes(Gap);
  SetLength(Result, 2 * Length(X) + Gap);
  if Length(X) > 0 then
  begin
    Move(X[0], Result[0], Length(X));
    Move(X[0], Result[Length(X) + Gap], Length(X));
  end;
  Move(G[0], Result[Length(X)], Gap);
end;

const
  RepMethods: array[0..7] of string = (
    'rep', 'rep:32', 'rep:b1mb:l64', 'rep:1000000b:128', 'rep:b256kb:l16:d64kb:s8',
    'rep:b2mb:c100:l200', 'rep:b16mb:h16:l8', 'rep:b3333333b:l3');
  DeltaMethods: array[0..4] of string = ('delta', 'delta:b1mb', 'delta:100000b', 'delta:x:b4096b', 'delta:b100b');

var
  Names: array of string;
  Datas: array of TBytes;

procedure Add(const N: string; const D: TBytes);
begin
  SetLength(Names, Length(Names) + 1);
  SetLength(Datas, Length(Datas) + 1);
  Names[High(Names)] := N;
  Datas[High(Datas)] := D;
end;

var
  i, k: Integer;
  One, Mid: TBytes;
begin
  RandSeed := 20260924;
  Add('vacío', nil);
  SetLength(One, 1); One[0] := 65;
  Add('1 byte', One);
  Add('aleatorio', RandomBytes(3 shl 20));
  Add('tabla int16', Table16(700000));
  Add('tabla int32', Table32(500000));
  Add('registros12', Records(200000));
  Mid := RandomBytes(600000);
  Add('rep lejano', FarRepeat(Mid, 1500000));      // 2.7 MB: vuelve en b1mb/b2mb
  for i := 1 to ParamCount do Add(ExtractFileName(ParamStr(i)), LoadFile(ParamStr(i)));

  for k := 0 to High(Datas) do
  begin
    for i := 0 to High(RepMethods) do
    begin
      // l3 (L=1) es lento: solo datos chicos
      if (Pos(':l3', RepMethods[i]) > 0) and (Length(Datas[k]) > 4000000) then Continue;
      RoundTrip(Names[k], RepMethods[i], Datas[k]);
    end;
    for i := 0 to High(DeltaMethods) do
      RoundTrip(Names[k], DeltaMethods[i], Datas[k]);
  end;

  // Robustez: parámetros inválidos -> excepción limpia, sin tocar el destino
  ExpectInvalid('rep:l2');            // L=0: el C divide por cero
  ExpectInvalid('rep:1');
  ExpectInvalid('rep:b100b');         // bloque <= L: el C se cuelga
  ExpectInvalid('rep:b10b:l3');       // hash vacío
  ExpectInvalid('rep:bxyz');
  ExpectInvalid('rep:h31');
  ExpectInvalid('rep:c0:l0');
  ExpectInvalid('rep:foo');
  ExpectInvalid('rep:4gb');
  ExpectInvalid('rep:');
  ExpectInvalid('rep:d4gb');
  ExpectInvalid('rep:l99999999999');
  ExpectInvalid('delta:0b');         // bloque 0: el C descartaría todo
  ExpectInvalid('delta:b');
  ExpectInvalid('delta:xx');
  ExpectInvalid('delta:3gb');
  ExpectInvalid('delta:8q');
  ExpectInvalid('lzma');

  WriteLn(Format('%d OK, %d fallas', [NOk, NBad]));
  if NBad > 0 then Halt(1);
end.
