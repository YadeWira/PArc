{ Pruebas de parc_ppmd (tests/ppmd.sh):
    test_ppmd suite <archivo>...
        ida y vuelta de entradas chicas (vacía, 1 byte, repetidas, al azar) y de los archivos
        dados con muchos órdenes, memorias y métodos de recuperación; parámetros inválidos;
        cabecera que no coincide con el método.
    test_ppmd corrupt <archivo> <iteraciones> [semilla]
        streams dañados (bytes cambiados, cortados, alargados, cabecera tocada): el
        decodificador tiene que terminar con EArcCorrupt o con una salida, nunca con otra
        excepción, un acceso inválido o un cuelgue.
    test_ppmd enc <archivo> <orden> <memoria en bytes> <recuperación> <salida>
        escribe el stream (para comparar con el SDK en C o entre compilaciones). }
program test_ppmd;

{$mode objfpc}{$H+}

uses
  Classes, SysUtils, parc_bytes, parc_stream, parc_ppmd;

var
  Fails, Passes: Integer;

procedure Ok(const S: string);
begin
  Inc(Passes);
  if GetEnvironmentVariable('VERBOSE') <> '' then WriteLn('  ok   ', S);
end;

procedure Bad(const S: string);
begin
  Inc(Fails);
  WriteLn('  FAIL ', S);
end;

function LoadFile(const Name: string): TBytes;
var
  F: TFileStream;
begin
  F := TFileStream.Create(Name, fmOpenRead or fmShareDenyNone);
  try
    SetLength(Result, F.Size);
    if Length(Result) > 0 then F.ReadBuffer(Result[0], Length(Result));
  finally
    F.Free;
  end;
end;

procedure SaveFile(const Name: string; const B: TBytes);
var
  F: TFileStream;
begin
  F := TFileStream.Create(Name, fmCreate);
  try
    if Length(B) > 0 then F.WriteBuffer(B[0], Length(B));
  finally
    F.Free;
  end;
end;

{ Decodifica hasta el final (o hasta Limit bytes). }
function Decode(const Comp: TBytes; Order: Integer; Mem: Int64; Restore: Integer;
  Limit: SizeInt): TBytes;
var
  St: TPpmdStage;
  n, Got: SizeInt;
begin
  SetLength(Result, 1 shl 16);
  Got := 0;
  St := TPpmdStage.Create(TMemStage.Create(PByte(Comp), Length(Comp)), Order, Mem, Restore);
  try
    repeat
      if Got = Length(Result) then SetLength(Result, Got * 2);
      n := St.Read(@Result[Got], Length(Result) - Got);
      Inc(Got, n);
    until (n = 0) or (Got >= Limit);
  finally
    St.Free;
  end;
  SetLength(Result, Got);
end;

procedure RoundTrip(const Name: string; const Src: TBytes; Order: Integer; Mem: Int64; Restore: Integer);
var
  Comp, Back: TBytes;
  Tag: string;
begin
  Tag := Format('%s ppmd:%d:%d:r%d', [Name, Order, Mem, Restore]);
  try
    if not PpmdCompress(PByte(Src), Length(Src), Order, Mem, Restore, Comp) then
    begin
      Bad(Tag + ': PpmdCompress rechazó los parámetros');
      Exit;
    end;
    Back := Decode(Comp, Order, Mem, Restore, Length(Src) + 1);
    if (Length(Back) <> Length(Src)) or ((Length(Src) > 0) and not CompareMem(@Back[0], @Src[0], Length(Src))) then
      Bad(Format('%s: la vuelta no coincide (%d de %d bytes)', [Tag, Length(Back), Length(Src)]))
    else
      Ok(Format('%s: %d -> %d', [Tag, Length(Src), Length(Comp)]));
  except
    on E: Exception do Bad(Tag + ': ' + E.ClassName + ': ' + E.Message);
  end;
end;

procedure ExpectCorrupt(const Tag: string; const Comp: TBytes; Order: Integer; Mem: Int64; Restore: Integer);
begin
  try
    Decode(Comp, Order, Mem, Restore, 1 shl 20);
    Bad(Tag + ': se decodificó sin error');
  except
    on E: EArcCorrupt do Ok(Tag);
    on E: Exception do Bad(Tag + ': ' + E.ClassName + ': ' + E.Message);
  end;
end;

procedure Suite(const Files: array of string);
const
  Orders: array[0..9] of Integer = (2, 3, 4, 6, 8, 12, 16, 24, 32, 64);
  Mems: array[0..4] of Int64 = (PPMD_MIN_MEM, 1 shl 16, 1 shl 20, 7 shl 20, 1 shl 25);
var
  Inputs: array of TBytes;
  Names: array of string;
  i, k, o, m, r: Integer;
  B, Comp: TBytes;
  Src: TMemStage;
  St: TPpmdStage;

  procedure Add(const N: string; const D: TBytes);
  begin
    SetLength(Inputs, Length(Inputs) + 1);
    Inputs[High(Inputs)] := D;
    SetLength(Names, Length(Names) + 1);
    Names[High(Names)] := N;
  end;

begin
  RandSeed := 12345;
  Add('vacío', nil);
  SetLength(B, 1); B[0] := 7; Add('1 byte', B);
  B := nil; SetLength(B, 2); B[0] := 0; B[1] := 255; Add('2 bytes', B);
  B := nil; SetLength(B, 100000); FillChar(B[0], Length(B), Ord('a')); Add('100000 x a', B);
  B := nil; SetLength(B, 70000);
  for k := 0 to High(B) do B[k] := Random(256);
  Add('azar 70000', B);
  B := nil; SetLength(B, 300000);
  for k := 0 to High(B) do B[k] := Byte(k * k shr 7) xor Byte(k shr 11);
  Add('patrón 300000', B);
  for i := 0 to High(Files) do Add(ExtractFileName(Files[i]), LoadFile(Files[i]));

  // Ida y vuelta: entradas chicas con todo; los archivos con una muestra de la matriz
  for i := 0 to High(Inputs) do
    for o := 0 to High(Orders) do
      for m := 0 to High(Mems) do
        for r := 0 to 1 do
          if (Length(Inputs[i]) <= 300000) or ((o + m + r) mod 3 = 0) then
            RoundTrip(Names[i], Inputs[i], Orders[o], Mems[m], r);

  // Parámetros inválidos: lanza antes de tomar la fuente (que sigue siendo del llamador)
  for k := 0 to 4 do
  begin
    Src := TMemStage.Create(nil, 0);
    try
      try
        case k of
          0: St := TPpmdStage.Create(Src, 1, 1 shl 20, 0);
          1: St := TPpmdStage.Create(Src, 65, 1 shl 20, 0);
          2: St := TPpmdStage.Create(Src, 6, PPMD_MIN_MEM - 1, 0);
          3: St := TPpmdStage.Create(Src, 6, Int64(PPMD_MAX_MEM) + 1, 0);
          else St := TPpmdStage.Create(Src, 6, 1 shl 20, 2);
        end;
        St.Free;
        Bad(Format('parámetros inválidos %d aceptados', [k]));
      except
        on E: EArcCorrupt do Ok(Format('parámetros inválidos %d', [k]));
      end;
    finally
      Src.Free;
    end;
  end;
  if PpmdCompress(nil, 0, 6, 1 shl 20, 3, Comp) then Bad('PpmdCompress con recuperación 3')
  else Ok('PpmdCompress con recuperación 3');

  // Cabecera que no coincide con el método, stream vacío o cortado
  PpmdCompress(PByte(Inputs[5]), Length(Inputs[5]), 6, 1 shl 20, 0, Comp);
  ExpectCorrupt('otro orden', Comp, 7, 1 shl 20, 0);
  ExpectCorrupt('otra memoria', Comp, 6, 2 shl 20, 0);
  ExpectCorrupt('otro método de recuperación', Comp, 6, 1 shl 20, 1);
  ExpectCorrupt('stream vacío', nil, 6, 1 shl 20, 0);
  ExpectCorrupt('solo la cabecera', Copy(Comp, 0, PPMD_HEADER_SIZE), 6, 1 shl 20, 0);
  ExpectCorrupt('sin los 4 bytes finales', Copy(Comp, 0, Length(Comp) - 4), 6, 1 shl 20, 0);
  B := Copy(Comp);
  B[1] := Ord('H');
  ExpectCorrupt('variante H', B, 6, 1 shl 20, 0);
end;

{ Streams dañados: solo EArcCorrupt o una salida; el límite de salida corta los streams que
  "decodifican" de más (la cadena real lo corta con el tamaño del bloque). }
procedure CorruptTest(const FileName: string; Iters: Integer; Seed: Integer);
var
  Src, Comp, B, Back: TBytes;
  it, k, n, Order, Restore, kind: Integer;
  Mem: Int64;
  Outcome: array[0..2] of Integer;
  Tag: string;
  T0: QWord;
begin
  Src := LoadFile(FileName);
  if Length(Src) > 1 shl 20 then SetLength(Src, 1 shl 20);
  RandSeed := Seed;
  FillChar(Outcome, SizeOf(Outcome), 0);
  for it := 1 to Iters do
  begin
    Order := 2 + Random(20);
    Mem := Int64(1) shl (11 + Random(12));
    Restore := Random(2);
    n := 1 + Random(Length(Src));
    PpmdCompress(PByte(Src), n, Order, Mem, Restore, Comp);
    B := Copy(Comp);
    kind := Random(5);
    case kind of
      0: for k := 1 to 1 + Random(4) do   // bytes cambiados (no en la cabecera)
           if Length(B) > PPMD_HEADER_SIZE then
             B[PPMD_HEADER_SIZE + Random(Length(B) - PPMD_HEADER_SIZE)] := Random(256);
      1: SetLength(B, PPMD_HEADER_SIZE + Random(Length(B) - PPMD_HEADER_SIZE + 1));   // cortado
      2: begin                                                                    // alargado
           k := Length(B);
           SetLength(B, k + 1 + Random(64));
           while k < Length(B) do begin B[k] := Random(256); Inc(k); end;
         end;
      3: begin                                     // un bit dado vuelta
           k := PPMD_HEADER_SIZE + Random(Length(B) - PPMD_HEADER_SIZE);
           B[k] := B[k] xor (1 shl Random(8));
         end;
      else
        for k := PPMD_HEADER_SIZE to High(B) do B[k] := Random(256);   // basura entera
    end;
    Tag := Format('iteración %d (ppmd:%d:%d:r%d, %d bytes, daño %d)', [it, Order, Mem, Restore, n, kind]);
    T0 := GetTickCount64;
    try
      Back := Decode(B, Order, Mem, Restore, 2 * n + (1 shl 16));
      if (Length(Back) = n) and CompareMem(@Back[0], @Src[0], n) then Inc(Outcome[0])
      else Inc(Outcome[1]);
      Ok(Tag);
    except
      on E: EArcCorrupt do begin Inc(Outcome[2]); Ok(Tag); end;
      on E: Exception do Bad(Tag + ': ' + E.ClassName + ': ' + E.Message);
    end;
    if GetTickCount64 - T0 > 20000 then Bad(Tag + ': más de 20 s');
  end;
  WriteLn(Format('  dañados: %d iguales, %d salida distinta, %d EArcCorrupt',
    [Outcome[0], Outcome[1], Outcome[2]]));
end;

var
  Files: array of string;
  i: Integer;
  Comp: TBytes;
  Src: TBytes;
begin
  if ParamCount < 1 then
  begin
    WriteLn('uso: test_ppmd suite <archivo>... | corrupt <archivo> <iteraciones> [semilla] |');
    WriteLn('     enc <archivo> <orden> <memoria> <recuperación> <salida>');
    Halt(2);
  end;
  Fails := 0;
  Passes := 0;
  if ParamStr(1) = 'suite' then
  begin
    SetLength(Files, ParamCount - 1);
    for i := 2 to ParamCount do Files[i - 2] := ParamStr(i);
    Suite(Files);
  end
  else if ParamStr(1) = 'corrupt' then
    CorruptTest(ParamStr(2), StrToInt(ParamStr(3)), StrToIntDef(ParamStr(4), 1))
  else if ParamStr(1) = 'enc' then
  begin
    Src := LoadFile(ParamStr(2));
    if not PpmdCompress(PByte(Src), Length(Src), StrToInt(ParamStr(3)), StrToInt64(ParamStr(4)),
      StrToInt(ParamStr(5)), Comp) then Halt(1);
    SaveFile(ParamStr(6), Comp);
    RoundTrip(ExtractFileName(ParamStr(2)), Src, StrToInt(ParamStr(3)), StrToInt64(ParamStr(4)),
      StrToInt(ParamStr(5)));
  end
  else
    Halt(2);
  WriteLn(Format('  %d ok, %d fallos', [Passes, Fails]));
  if Fails > 0 then Halt(1);
end.
