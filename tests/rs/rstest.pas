{ Pruebas y benchmark de parc_rs (Reed-Solomon de borrado).
  Uso: rstest [casos] [semilla]   (por defecto 3000 casos, semilla fija)
  Sale con código 1 si algo falla.

  El campo y los coeficientes se contrastan contra una implementación lenta e
  independiente (multiplicación a mano, inverso por fuerza bruta), así un error en las
  tablas no se valida a sí mismo. }
program rstest;

{$mode objfpc}{$H+}
{$R-}{$Q-}

uses
  SysUtils, parc_rs;

var
  Rng: QWord = $2545F4914F6CDD1D;
  Fails: Integer = 0;
  Checks: Int64 = 0;

function NextRand: QWord;
begin
  // xorshift64: reproducible igual en 32 y 64 bits, a diferencia de Random
  Rng := Rng xor (Rng shl 13);
  Rng := Rng xor (Rng shr 7);
  Rng := Rng xor (Rng shl 17);
  Result := Rng;
end;

function RandInt(lo, hi: Integer): Integer;  // [lo, hi]
begin
  Result := lo + Integer(NextRand mod QWord(hi - lo + 1));
end;

procedure FillRandom(p: PByte; n: SizeInt);
var
  i: SizeInt;
begin
  for i := 0 to n - 1 do p[i] := Byte(NextRand shr 24);
end;

procedure Fail(const msg: string);
begin
  Inc(Fails);
  if Fails <= 20 then WriteLn('FALLA: ', msg);
end;

// --- referencia lenta ---------------------------------------------------------

function SlowMul(a, b: Byte): Byte;
var
  r, x: Word;
begin
  r := 0;
  x := a;
  while b <> 0 do
  begin
    if b and 1 <> 0 then r := r xor x;
    x := x shl 1;
    if x and $100 <> 0 then x := x xor $11D;
    b := b shr 1;
  end;
  Result := r;
end;

function SlowInv(a: Byte): Byte;
var
  x: Integer;
begin
  for x := 1 to 255 do
    if SlowMul(a, x) = 1 then Exit(x);
  Result := 0;
end;

function RefCoef(i, j: Integer): Byte;
  function Cr(i, j: Integer): Byte;
  begin
    Result := SlowInv(Byte((255 - i) xor j));
  end;
begin
  Result := SlowMul(SlowMul(Cr(i, j), Cr(0, 0)), SlowInv(SlowMul(Cr(0, j), Cr(i, 0))));
end;

procedure TestField;
var
  a, b, i, j: Integer;
  inv: array[Byte] of Byte;
  cr: Byte;
begin
  for a := 0 to 255 do
    for b := 0 to 255 do
    begin
      Inc(Checks);
      if GfMul(a, b) <> SlowMul(a, b) then
        Fail(Format('GfMul(%d,%d)', [a, b]));
    end;
  for a := 1 to 255 do
  begin
    inv[a] := SlowInv(a);
    Inc(Checks);
    if GfInv(a) <> inv[a] then Fail(Format('GfInv(%d)', [a]));
  end;
  // todos los coeficientes que puede usar el formato (i + j <= 254)
  for i := 0 to 254 do
    for j := 0 to 254 - i do
    begin
      Inc(Checks);
      cr := SlowMul(SlowMul(inv[(255 - i) xor j], inv[255]),
                    inv[SlowMul(inv[255 xor j], inv[255 - i])]);
      if RsCoef(i, j) <> cr then Fail(Format('RsCoef(%d,%d)', [i, j]));
    end;
  // y unos pocos contra la fórmula escrita tal cual
  for a := 0 to 30 do
  begin
    i := RandInt(0, 254);
    j := RandInt(0, 254 - i);
    Inc(Checks);
    if RsCoef(i, j) <> RefCoef(i, j) then Fail(Format('RefCoef(%d,%d)', [i, j]));
  end;
  WriteLn('campo y coeficientes: ok');
end;

// --- casos al azar ------------------------------------------------------------

procedure RunCase(k, m: Integer; ss: SizeInt; CheckRef: Boolean; var Cases: Integer);
var
  n, i, j, e, t: Integer;
  Sec, Orig, Snap: array of PByte;
  Pres: array of Boolean;
  Idx: array of Integer;
  RC: array of Byte;
  Data, Par: array of PByte;
  ok: Boolean;
  acc: Byte;
  b: SizeInt;
  tag: string;
begin
  n := k + m;
  tag := Format('k=%d m=%d ss=%d', [k, m, ss]);
  SetLength(Sec, n); SetLength(Orig, n); SetLength(Snap, n);
  SetLength(Pres, n); SetLength(Idx, n);
  for i := 0 to n - 1 do
  begin
    GetMem(Sec[i], ss + 1);
    GetMem(Orig[i], ss + 1);
    GetMem(Snap[i], ss + 1);
  end;
  for i := 0 to k - 1 do FillRandom(Sec[i], ss);
  for i := k to n - 1 do FillRandom(Sec[i], ss);  // basura: RsEncode debe pisarla
  SetLength(Data, k); SetLength(Par, m);
  for i := 0 to k - 1 do Data[i] := Sec[i];
  for i := 0 to m - 1 do Par[i] := Sec[k + i];
  RsEncode(k, m, Data, ss, Par);
  for i := 0 to n - 1 do Move(Sec[i]^, Orig[i]^, ss);

  if CheckRef then
  begin
    Inc(Checks);
    SetLength(RC, m * k);
    for i := 0 to m - 1 do
      for j := 0 to k - 1 do RC[i * k + j] := RefCoef(i, j);
    for i := 0 to m - 1 do
      for b := 0 to ss - 1 do
      begin
        acc := 0;
        for j := 0 to k - 1 do acc := acc xor SlowMul(RC[i * k + j], Data[j][b]);
        if acc <> Par[i][b] then
        begin
          Fail(tag + Format(' paridad %d byte %d distinta de la referencia', [i, b]));
          Break;
        end;
      end;
  end;

  // e borrados al azar entre 0 y m, mezclando datos y paridad
  for i := 0 to n - 1 do Idx[i] := i;
  for i := n - 1 downto 1 do
  begin
    j := RandInt(0, i);
    t := Idx[i]; Idx[i] := Idx[j]; Idx[j] := t;
  end;
  e := RandInt(0, m);
  for i := 0 to n - 1 do Pres[i] := True;
  for i := 0 to e - 1 do
  begin
    Pres[Idx[i]] := False;
    FillRandom(Sec[Idx[i]], ss);
  end;
  Inc(Checks);
  ok := RsRecover(k, m, Sec, Pres, ss);
  if not ok then Fail(tag + Format(' RsRecover=False con %d borrados', [e]))
  else
    for i := 0 to n - 1 do
      if CompareByte(Sec[i]^, Orig[i]^, ss) <> 0 then
      begin
        Fail(tag + Format(' sector %d (%s) mal reconstruido con %d borrados',
          [i, BoolToStr(i < k, 'datos', 'paridad'), e]));
        Break;
      end;

  // m + 1 borrados: tiene que negarse y no tocar nada
  for i := 0 to n - 1 do Move(Orig[i]^, Sec[i]^, ss);
  for i := 0 to n - 1 do Pres[i] := True;
  for i := 0 to m do
  begin
    Pres[Idx[i]] := False;
    FillRandom(Sec[Idx[i]], ss);
  end;
  for i := 0 to n - 1 do Move(Sec[i]^, Snap[i]^, ss);
  Inc(Checks);
  if RsRecover(k, m, Sec, Pres, ss) then
    Fail(tag + Format(' RsRecover=True con %d borrados', [m + 1]))
  else
    for i := 0 to n - 1 do
      if CompareByte(Sec[i]^, Snap[i]^, ss) <> 0 then
      begin
        Fail(tag + ' RsRecover modificó sectores al devolver False');
        Break;
      end;

  for i := 0 to n - 1 do
  begin
    FreeMem(Sec[i]); FreeMem(Orig[i]); FreeMem(Snap[i]);
  end;
  Inc(Cases);
end;

procedure TestStripes;
var
  N, S, s2, tot: Int64;
  m, i: Integer;
begin
  for i := 1 to 2000 do
  begin
    m := RandInt(1, 254);
    N := RandInt(0, 200000);
    S := RsStripeCount(N, m);
    tot := 0;
    Inc(Checks);
    s2 := 0;  // while y no for: un for con Int64 no compila en 32 bits
    while s2 < S do
    begin
      if RsStripeLen(N, S, s2) > 255 - m then
        Fail(Format('franja %d de N=%d m=%d excede 255-m', [s2, N, m]));
      Inc(tot, RsStripeLen(N, S, s2));
      Inc(s2);
    end;
    // el sector i cae en la franja i mod S, posición i div S < largo de esa franja
    if N > 0 then
    begin
      s2 := NextRand mod QWord(N);
      if s2 div S >= RsStripeLen(N, S, s2 mod S) then
        Fail(Format('sector %d de N=%d m=%d fuera de su franja', [s2, N, m]));
    end;
    if tot <> N then Fail(Format('franjas de N=%d m=%d suman %d', [N, m, tot]));
  end;
  WriteLn('intercalado: ok');
end;

// --- benchmark ----------------------------------------------------------------

procedure Bench;
const
  K = 250; M = 5; SS = 4096; MINMS = 1500;
var
  Sec: array of PByte;
  Data, Par: array of PByte;
  Pres: array of Boolean;
  i, iters: Integer;
  t0, dt: QWord;
  mb: Double;
begin
  SetLength(Sec, K + M); SetLength(Pres, K + M);
  SetLength(Data, K); SetLength(Par, M);
  for i := 0 to K + M - 1 do GetMem(Sec[i], SS);
  for i := 0 to K - 1 do begin FillRandom(Sec[i], SS); Data[i] := Sec[i]; end;
  for i := 0 to M - 1 do Par[i] := Sec[K + i];
  mb := K * SS / 1e6;  // MB de datos por iteración

  iters := 0;
  t0 := GetTickCount64;
  repeat
    RsEncode(K, M, Data, SS, Par);
    Inc(iters);
    dt := GetTickCount64 - t0;
  until dt >= MINMS;
  WriteLn(Format('RsEncode  k=%d m=%d ss=%d: %.1f MB/s (de datos)',
    [K, M, SS, iters * mb / (dt / 1000)]));

  // peor caso: los 5 borrados en datos (los de paridad salen más baratos)
  for i := 0 to K + M - 1 do Pres[i] := True;
  for i := 0 to M - 1 do Pres[i * 50 + 7] := False;
  iters := 0;
  t0 := GetTickCount64;
  repeat
    if not RsRecover(K, M, Sec, Pres, SS) then Fail('bench: RsRecover=False');
    Inc(iters);
    dt := GetTickCount64 - t0;
  until dt >= MINMS;
  WriteLn(Format('RsRecover k=%d m=%d ss=%d, 5 datos borrados: %.1f MB/s (de datos)',
    [K, M, SS, iters * mb / (dt / 1000)]));

  for i := 0 to K + M - 1 do FreeMem(Sec[i]);
end;

var
  NCases, Cases, c, k, m: Integer;
  ss: SizeInt;
  t0: QWord;
begin
  NCases := 3000;
  if ParamCount >= 1 then NCases := StrToInt(ParamStr(1));
  if ParamCount >= 2 then Rng := StrToQWord(ParamStr(2));
  t0 := GetTickCount64;
  TestField;
  TestStripes;

  Cases := 0;
  // bordes fijos
  RunCase(1, 1, 1, True, Cases);
  RunCase(1, 255, 7, True, Cases);
  RunCase(255, 1, 9, True, Cases);
  RunCase(128, 128, 33, True, Cases);
  RunCase(3, 2, 0, False, Cases);
  RunCase(250, 5, 4096, False, Cases);
  RunCase(10, 4, 100000, False, Cases);  // varias franjas internas (Chunk)
  for c := 1 to NCases do
  begin
    k := RandInt(1, 250);
    if c mod 25 = 0 then m := 256 - k        // k + m = 256, el máximo
    else m := RandInt(1, 255 - k);
    ss := RandInt(1, 4096);
    // la referencia lenta es O(k*m*ss): sólo en casos chicos
    RunCase(k, m, ss, (k * m * ss <= 200000) and (c mod 3 = 0), Cases);
  end;
  WriteLn(Format('%d casos al azar + bordes (%d verificaciones) en %.1f s',
    [Cases, Checks, (GetTickCount64 - t0) / 1000]));

  Bench;

  WriteLn(Format('RESUMEN: %d casos, %d fallas', [Cases, Fails]));
  if Fails > 0 then Halt(1);
end.
