{ Prueba diferencial del decodificador LZMA: el actual (src/parc_lzma, con camino rápido) contra
  la copia congelada de 0.0.2 (tests/lzma_ref/parc_lzma_ref, sin camino rápido).
  Uso: tests/test_lzma_diff [casos] [semilla] [archivos...]
  - Cada caso comprime datos generados (o un pedazo de los archivos dados) con parc_lzmaenc y
    parámetros al azar (lc/lp/pb, a0/a1, match finder, diccionario), y además arma variantes
    dañadas del stream: truncado, bits invertidos, bytes pisados, ceros, basura al final.
  - Cada variante se decodifica con los dos decodificadores de dos formas: memoria-a-memoria
    (LzmaDecodeRaw) y streaming (TLzmaStage, con una fuente que entrega pedazos de tamaño al
    azar, diccionario al azar y lecturas al azar).
  - Los dos tienen que dar exactamente lo mismo: mismo resultado, mismos bytes de salida y la
    misma excepción (o ninguna). Los streams sin dañar además tienen que dar los datos originales.
  Sale con 0 si todo coincide. }
program test_lzma_diff;

{$mode objfpc}{$H+}

uses
  SysUtils, Classes, Math, parc_stream, parc_lzma, parc_lzma_ref, parc_lzmaenc;

var
  Seed: LongWord = 2463534242;
  Fails, Runs, Valid, Caps: Integer;
  EncTime: QWord;
  Files: array of TBytes;

function Rnd(n: LongWord): LongWord;
begin
  // xorshift32: reproducible entre plataformas
  Seed := Seed xor (Seed shl 13);
  Seed := Seed xor (Seed shr 17);
  Seed := Seed xor (Seed shl 5);
  if n = 0 then Exit(0);
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

type
  { Fuente que entrega los bytes en pedazos de tamaño al azar (determinista por semilla). }
  TChunkStage = class(TInStage)
  private
    FData: TBytes;
    FPos: SizeInt;
    FSeed: LongWord;
    FMaxChunk: LongWord;
  public
    constructor Create(const Data: TBytes; ASeed, AMaxChunk: LongWord);
    function Read(Buf: PByte; Count: SizeInt): SizeInt; override;
  end;

constructor TChunkStage.Create(const Data: TBytes; ASeed, AMaxChunk: LongWord);
begin
  inherited Create(nil);
  FData := Copy(Data);
  FSeed := ASeed or 1;
  FMaxChunk := AMaxChunk;
end;

function TChunkStage.Read(Buf: PByte; Count: SizeInt): SizeInt;
var
  n: SizeInt;
begin
  Result := Length(FData) - FPos;
  if Result <= 0 then Exit(0);
  FSeed := FSeed xor (FSeed shl 13);
  FSeed := FSeed xor (FSeed shr 17);
  FSeed := FSeed xor (FSeed shl 5);
  n := 1 + FSeed mod FMaxChunk;
  if Result > n then Result := n;
  if Result > Count then Result := Count;
  Move(FData[FPos], Buf^, Result);
  Inc(FPos, Result);
end;

{ ---- datos de prueba ---- }

function GenData: TBytes;
const
  Words: array[0..11] of string = ('the ', 'lzma ', 'match ', 'finder ', 'PArc ', 'Pascal ',
    'archive ', #10, '0123', 'zzzz', 'abcabcabc', 'freearc ');
var
  n, i, k, src, len: SizeInt;
  kind: LongWord;
  f: TBytes;
  s: string;
begin
  kind := Rnd(7);
  case Rnd(10) of
    0: n := Rnd(64);
    1..6: n := Rnd(40000);
    7, 8: n := Rnd(300000);
  else
    n := 300000 + Rnd(1700000);
  end;
  if (kind = 6) and (Length(Files) = 0) then kind := 2;
  SetLength(Result, n);
  case kind of
    0: for i := 0 to n - 1 do Result[i] := Rnd(256);                 // incompresible
    1: begin                                                           // texto
         i := 0;
         while i < n do
         begin
           s := Words[Rnd(Length(Words))];
           for k := 1 to Length(s) do
             if i + k - 1 < n then Result[i + k - 1] := Ord(s[k]);
           Inc(i, Length(s));
         end;
       end;
    2: begin                                                           // copias largas y reps
         for i := 0 to n - 1 do
           if (i < 16) or (Rnd(8) = 0) then Result[i] := Rnd(256)
           else
           begin
             src := i - 1 - SizeInt(Rnd(Min(i, 70000)));
             Result[i] := Result[src];
           end;
         i := 64;
         while i < n do
         begin
           len := 2 + Rnd(300);
           src := i - 1 - SizeInt(Rnd(Min(i, 500000)));
           for k := 0 to len - 1 do
             if i + k < n then Result[i + k] := Result[src + k];
           Inc(i, len + Rnd(200));
         end;
       end;
    3: for i := 0 to n - 1 do Result[i] := Byte(i div (1 + (i shr 12)));  // rampas
    4: if n > 0 then FillChar(Result[0], n, Rnd(256));                     // un solo byte
    5: for i := 0 to n - 1 do Result[i] := Byte((i * 7) xor (i shr 3)) and $F0 or Rnd(4);
    6: begin                                                               // pedazo de archivo
         f := Files[Rnd(Length(Files))];
         if n > Length(f) then n := Length(f);
         SetLength(Result, n);
         if n > 0 then Move(f[Rnd(Length(f) - n + 1)], Result[0], n);
       end;
  end;
end;

function RandomMethod(out lc, lp, pb: Integer; out dict: LongWord): string;
const
  Mfs: array[0..4] of string = ('ht4', 'ht4', 'hc4', 'bt4', 'bt2');
begin
  dict := LongWord(1) shl (12 + Rnd(9));          // 4 KB .. 1 MB
  lc := Rnd(9); lp := Rnd(5); pb := Rnd(5);
  if Rnd(2) = 0 then begin lc := 3; lp := 0; pb := 2; end;
  Result := Format('lzma:%db:%s:a%d:fb%d:lc%d:lp%d:pb%d', [dict, Mfs[Rnd(Length(Mfs))], Rnd(2),
    5 + Rnd(269), lc, lp, pb]);
  if Rnd(3) = 0 then Result := Result + ':mc' + IntToStr(1 + Rnd(64));
end;

{ ---- variantes dañadas ---- }

function Mutate(const C: TBytes; kind: LongWord): TBytes;
var
  i, n, p, len: SizeInt;
begin
  Result := Copy(C);
  n := Length(Result);
  case kind of
    0: ;                                                               // intacto
    1: SetLength(Result, Rnd(n + 1));                                  // truncado en cualquier lado
    2: if n > 0 then SetLength(Result, n - 1 - SizeInt(Rnd(Min(n, 40))));   // truncado cerca del final
    3: if n > 0 then                                                   // un bit
       begin
         p := Rnd(n);
         Result[p] := Result[p] xor (1 shl Rnd(8));
       end;
    4: for i := 0 to Rnd(8) do                                          // varios bits
         if n > 0 then
         begin
           p := Rnd(n);
           Result[p] := Result[p] xor (1 shl Rnd(8));
         end;
    5: if n > 0 then                                                   // bytes pisados al azar
       begin
         p := Rnd(n);
         len := 1 + Rnd(64);
         for i := p to Min(n - 1, p + len - 1) do Result[i] := Rnd(256);
       end;
    6: if n > 0 then                                                   // tramo en cero
       begin
         p := Rnd(n);
         len := 1 + Rnd(256);
         for i := p to Min(n - 1, p + len - 1) do Result[i] := 0;
       end;
    7: begin                                                           // basura al final
         SetLength(Result, n + 1 + Rnd(100));
         for i := n to High(Result) do Result[i] := Rnd(256);
       end;
    8: if n > 6 then                                                   // bit en la cola
       begin
         p := n - 1 - SizeInt(Rnd(Min(n, 24)));
         Result[p] := Result[p] xor (1 shl Rnd(8));
       end;
    9: begin                                                           // basura pura
         SetLength(Result, Rnd(3000));
         for i := 0 to High(Result) do Result[i] := Rnd(256);
         if (Length(Result) > 0) and (Rnd(2) = 0) then Result[0] := 0;
       end;
  end;
end;

{ ---- decodificación con los dos ---- }

procedure Fail(const What: string);
begin
  Inc(Fails);
  if Fails <= 20 then WriteLn('FAIL ', What);
end;

procedure CompareMem2(const Tag: string; const C: TBytes; DstLen: SizeInt; lc, lp, pb: Integer;
  const Orig: TBytes; MustMatch: Boolean);
var
  A, B: TBytes;
  wa, wb: SizeInt;
  ra, rb: Integer;
begin
  SetLength(A, DstLen + 1);
  SetLength(B, DstLen + 1);
  if DstLen > 0 then
  begin
    FillChar(A[0], DstLen, $5A);
    FillChar(B[0], DstLen, $5A);
  end;
  ra := Ord(parc_lzma.LzmaDecodeRaw(PByte(C), Length(C), PByte(A), DstLen, lc, lp, pb, wa));
  rb := Ord(parc_lzma_ref.LzmaDecodeRaw(PByte(C), Length(C), PByte(B), DstLen, lc, lp, pb, wb));
  Inc(Runs);
  if (ra <> rb) or (wa <> wb) or ((DstLen > 0) and not CompareMem(@A[0], @B[0], DstLen)) then
    Fail(Format('%s mem: nuevo r=%d w=%d, viejo r=%d w=%d', [Tag, ra, wa, rb, wb]))
  else if MustMatch and ((ra <> 0) or (wa <> Length(Orig)) or
    ((wa > 0) and not CompareMem(@A[0], @Orig[0], wa))) then
    Fail(Format('%s mem: stream válido mal decodificado r=%d w=%d/%d', [Tag, ra, wa, Length(Orig)]));
end;

function RunStage(UseNew: Boolean; const C: TBytes; lc, lp, pb: Integer; Dict: QWord;
  SrcSeed, MaxChunk, ReadSeed: LongWord; out Outcome: string): TBytes;
const
  CAP = 64 shl 20;
var
  st: TInStage;
  got, n, want: SizeInt;
  rs: LongWord;
begin
  Result := nil;
  Outcome := 'eof';
  got := 0;
  rs := ReadSeed or 1;
  st := nil;
  try
    try
      if UseNew then
        st := parc_lzma.TLzmaStage.Create(TChunkStage.Create(C, SrcSeed, MaxChunk), lc, lp, pb, Dict)
      else
        st := parc_lzma_ref.TLzmaStage.Create(TChunkStage.Create(C, SrcSeed, MaxChunk), lc, lp, pb, Dict);
      repeat
        rs := rs xor (rs shl 13); rs := rs xor (rs shr 17); rs := rs xor (rs shl 5);
        want := 1 + rs mod 200000;
        if Length(Result) < got + want then SetLength(Result, got + want + 65536);
        n := st.Read(@Result[got], want);
        Inc(got, n);
        if got > CAP then begin Outcome := 'cap'; Inc(Caps); Break; end;
      until n = 0;
    except
      on E: Exception do Outcome := E.ClassName + ': ' + E.Message;
    end;
  finally
    st.Free;
  end;
  SetLength(Result, got);
end;

procedure CompareStage(const Tag: string; const C: TBytes; lc, lp, pb: Integer; Dict: QWord;
  const Orig: TBytes; MustMatch: Boolean);
var
  A, B: TBytes;
  oa, ob: string;
  s1, mc, s2: LongWord;
begin
  s1 := Rnd($7FFFFFFF);
  s2 := Rnd($7FFFFFFF);
  case Rnd(4) of
    0: mc := 1 + Rnd(32);
    1: mc := 1 + Rnd(1000);
  else
    mc := 1 + Rnd(200000);
  end;
  A := RunStage(True, C, lc, lp, pb, Dict, s1, mc, s2, oa);
  B := RunStage(False, C, lc, lp, pb, Dict, s1, mc, s2, ob);
  Inc(Runs);
  if (oa <> ob) or (Length(A) <> Length(B)) or ((Length(A) > 0) and not CompareMem(@A[0], @B[0], Length(A))) then
    Fail(Format('%s stage (dict %d, chunk %d): nuevo %d B "%s", viejo %d B "%s"',
      [Tag, Dict, mc, Length(A), oa, Length(B), ob]))
  else if MustMatch and ((oa <> 'eof') or (Length(A) <> Length(Orig)) or
    ((Length(A) > 0) and not CompareMem(@A[0], @Orig[0], Length(A)))) then
    Fail(Format('%s stage: stream válido mal decodificado (%d/%d B, %s)', [Tag, Length(A), Length(Orig), oa]));
end;

procedure OneCase(idx: Integer);
var
  data, comp, m: TBytes;
  meth, tag: string;
  lc, lp, pb, j: Integer;
  dict: LongWord;
  P: TLzmaEncParams;
  endMark, intact: Boolean;
  kind: LongWord;
  dlen: SizeInt;
  sdict, t0: QWord;
begin
  data := GenData;
  meth := RandomMethod(lc, lp, pb, dict);
  P := ParseLzmaEncParams(meth.Split([':']));
  endMark := Rnd(4) <> 0;
  t0 := GetTickCount64;
  comp := LzmaEncodeMem(PByte(data), Length(data), P, endMark);
  Inc(EncTime, GetTickCount64 - t0);
  for j := 0 to 5 do
  begin
    if j = 0 then kind := 0 else kind := Rnd(10);
    m := Mutate(comp, kind);
    intact := kind = 0;
    tag := Format('caso %d.%d [%s, %d B, endmark %s, mut %d]', [idx, j, meth, Length(data),
      BoolToStr(endMark, True), kind]);
    // memoria: largo exacto, o de más (sin marca de fin pide bytes que no hay)
    dlen := Length(data);
    if Rnd(4) = 0 then dlen := dlen + SizeInt(Rnd(5000));
    CompareMem2(tag, m, dlen, lc, lp, pb, data, intact and (dlen = Length(data)));
    // streaming: exige marca de fin; diccionario como el del codificador o al azar
    case Rnd(4) of
      0: sdict := 4096 + Rnd(dict);
      1: sdict := 1 + Rnd(1 shl 16);
    else
      sdict := dict;
    end;
    CompareStage(tag, m, lc, lp, pb, sdict, data, intact and endMark and (sdict >= dict));
    if intact then Inc(Valid);
  end;
end;

var
  n, i: Integer;
  t0: QWord;
begin
  n := 2000;
  if ParamCount >= 1 then n := StrToInt(ParamStr(1));
  if ParamCount >= 2 then Seed := StrToInt64(ParamStr(2)) or 1;
  SetLength(Files, 0);
  for i := 3 to ParamCount do
  begin
    SetLength(Files, Length(Files) + 1);
    Files[High(Files)] := LoadFile(ParamStr(i));
  end;
  t0 := GetTickCount64;
  for i := 1 to n do OneCase(i);
  WriteLn(Format('test_lzma_diff: %d casos, %d decodificaciones comparadas (%d streams intactos, %d cortados a 64 MB), %d fallas, %.1f s (%.1f s comprimiendo)',
    [n, Runs, Valid, Caps, Fails, (GetTickCount64 - t0) / 1000, EncTime / 1000]));
  if Fails > 0 then Halt(1);
end.
