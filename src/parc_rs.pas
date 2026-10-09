{ Reed-Solomon de borrado sobre GF(2^8), para el registro de recuperación de .parc.

  Código sistemático: k sectores de datos quedan tal cual y se agregan m de paridad,
  con k + m <= 256. Cualquier combinación de k sectores sanos (datos o paridad)
  alcanza para reconstruir el resto, siempre que se sepa CUÁLES están dañados (por
  eso es "de borrado": la detección la hace otro, p. ej. un CRC por sector).

  Campo: GF(2^8) con polinomio x^8+x^4+x^3+x^2+1 (0x11D) y generador 2, el mismo de
  par2/ISA-L/zfec, así hay tablas y valores de prueba conocidos.

  Matriz de paridad (FORMATO: no cambiarla sin cambiar la versión del registro).
  Se parte de una Cauchy C[i,j] = 1 / (x_i + y_j) con x_i = 255 - i, y_j = j
  (i = 0..m-1 paridad, j = 0..k-1 datos; distintos porque i + j <= 254). Toda
  submatriz cuadrada de una Cauchy es invertible, y eso es exactamente lo que hace
  falta para que CUALQUIER conjunto de borrados se pueda resolver. Después se escala
  por filas y columnas para que la fila 0 y la columna 0 sean todos unos:

      coef(i, j) = C[i,j] * C[0,0] / (C[0,j] * C[i,0])

  Escalar filas/columnas por constantes no nulas no rompe esa propiedad, y gana dos
  cosas: la paridad 0 es un XOR puro (rápido) y cada paridad arranca copiando el
  sector 0. Como x_i e y_j no dependen de k ni de m, coef(i, j) es una función fija:
  una paridad calculada con m = 3 es la misma que las 3 primeras con m = 5.

  Camino caliente: dst ^= coef * src sobre bytes. Se usa la tabla completa de
  multiplicar (64 KB, una fila de 256 bytes por coeficiente) y se arma de a 8 bytes
  para escribir una palabra en vez de ocho bytes. Todo con locales y punteros: FPC
  3.2.2 no mantiene en registros campos de objetos ni parámetros var. Los sectores se
  recorren en franjas (Chunk) para que las filas de destino queden en caché mientras
  se acumulan todos los orígenes. }
unit parc_rs;

{$mode objfpc}{$H+}
{$R-}{$Q-}

interface

const
  RS_MAX_SECTORS = 256;  // k + m

{ Calcula las m paridades de los k sectores de datos. Data: k punteros; Parity: m
  punteros (se sobreescriben). Todos de SectorSize bytes y sin solaparse. }
procedure RsEncode(k, m: Integer; const Data: array of PByte; SectorSize: SizeInt;
  const Parity: array of PByte);

{ Sectors/Present: k + m elementos, primero datos y después paridad. Reconstruye en
  su lugar los sectores con Present = False (datos y también paridad). Devuelve False
  si faltan más de m (o si los parámetros no tienen sentido); en ese caso no toca
  nada. }
function RsRecover(k, m: Integer; const Sectors: array of PByte;
  const Present: array of Boolean; SectorSize: SizeInt): Boolean;

{ Aritmética del campo y coeficientes, expuestos para pruebas y para documentar el
  formato. }
function GfMul(a, b: Byte): Byte;
function GfInv(a: Byte): Byte;   // a <> 0
function RsCoef(i, j: Integer): Byte;  // coeficiente de datos j en la paridad i
{ Dst ^= c * Src sobre n bytes: para codificar de corrido, sector por sector, sin tener
  la franja entera en memoria (el registro de recuperación recorre el archivo una vez). }
procedure RsMulAdd(c: Byte; Src, Dst: PByte; n: SizeInt);

{ Intercalado ("interleave") de un archivo de N sectores en franjas de a lo sumo
  255 - m sectores de datos, cada una con sus m paridades. El sector i va a la franja
  i mod S, en la posición i div S; a la inversa, la posición p de la franja s es el
  sector p * S + s. Así un daño contiguo de hasta S * m sectores pone a lo sumo m
  borrados en cada franja, y se repara. Las primeras (N mod S) franjas tienen un
  sector más que las demás. }
function RsStripeCount(NumSectors: Int64; m: Integer): Int64;      // S (0 si N = 0)
function RsStripeLen(NumSectors, Stripes, s: Int64): Integer;      // k de la franja s

implementation

uses
  SysUtils;

var
  GfExp: array[0..511] of Byte;   // duplicada: exp[log a + log b] sin "mod 255"
  GfLog: array[Byte] of Word;
  MulTab: array[Byte, Byte] of Byte;

procedure InitTables;
var
  i, a, b: Integer;
  x: Word;
begin
  x := 1;
  for i := 0 to 254 do
  begin
    GfExp[i] := x;
    GfLog[x] := i;
    x := x shl 1;
    if x and $100 <> 0 then x := x xor $11D;
  end;
  for i := 255 to 511 do GfExp[i] := GfExp[i - 255];
  GfLog[0] := 0;  // no se usa: el 0 se trata aparte
  for a := 0 to 255 do
    for b := 0 to 255 do
      if (a = 0) or (b = 0) then MulTab[a, b] := 0
      else MulTab[a, b] := GfExp[GfLog[a] + GfLog[b]];
end;

function GfMul(a, b: Byte): Byte;
begin
  Result := MulTab[a, b];
end;

function GfInv(a: Byte): Byte;
begin
  Result := GfExp[255 - GfLog[a]];
end;

function CauchyRaw(i, j: Integer): Byte; inline;
begin
  Result := GfInv(Byte((255 - i) xor j));
end;

function RsCoef(i, j: Integer): Byte;
begin
  Result := GfMul(GfMul(CauchyRaw(i, j), CauchyRaw(0, 0)),
                  GfInv(GfMul(CauchyRaw(0, j), CauchyRaw(i, 0))));
end;

// --- filas: el camino caliente ------------------------------------------------

procedure XorRow(Src, Dst: PByte; n: SizeInt);
var
  e: PByte;
begin
  e := Src + (n and not SizeInt(SizeOf(PtrUInt) - 1));
  while Src < e do
  begin
    PPtrUInt(Dst)^ := PPtrUInt(Dst)^ xor PPtrUInt(Src)^;
    Inc(Src, SizeOf(PtrUInt));
    Inc(Dst, SizeOf(PtrUInt));
  end;
  e := Src + (n and (SizeOf(PtrUInt) - 1));
  while Src < e do
  begin
    Dst^ := Dst^ xor Src^;
    Inc(Src);
    Inc(Dst);
  end;
end;

// Dst ^= T[Src], T = fila de MulTab del coeficiente
procedure MulAddRow(T, Src, Dst: PByte; n: SizeInt);
var
  e: PByte;
begin
{$IFDEF ENDIAN_LITTLE}
  e := Src + (n and not SizeInt(7));
  while Src < e do
  begin
  {$IFDEF CPU64}
    PQWord(Dst)^ := PQWord(Dst)^ xor
      (QWord(T[Src[0]]) or (QWord(T[Src[1]]) shl 8) or
       (QWord(T[Src[2]]) shl 16) or (QWord(T[Src[3]]) shl 24) or
       (QWord(T[Src[4]]) shl 32) or (QWord(T[Src[5]]) shl 40) or
       (QWord(T[Src[6]]) shl 48) or (QWord(T[Src[7]]) shl 56));
  {$ELSE}
    // en 32 bits una QWord son dos registros: mejor dos palabras de 32
    PLongWord(Dst)^ := PLongWord(Dst)^ xor
      (LongWord(T[Src[0]]) or (LongWord(T[Src[1]]) shl 8) or
       (LongWord(T[Src[2]]) shl 16) or (LongWord(T[Src[3]]) shl 24));
    PLongWord(Dst + 4)^ := PLongWord(Dst + 4)^ xor
      (LongWord(T[Src[4]]) or (LongWord(T[Src[5]]) shl 8) or
       (LongWord(T[Src[6]]) shl 16) or (LongWord(T[Src[7]]) shl 24));
  {$ENDIF}
    Inc(Src, 8);
    Inc(Dst, 8);
  end;
  e := Src + (n and 7);
{$ELSE}
  e := Src + n;
{$ENDIF}
  while Src < e do
  begin
    Dst^ := Dst^ xor T[Src^];
    Inc(Src);
    Inc(Dst);
  end;
end;

// Dst ^= c * Src
procedure AccumRow(c: Byte; Src, Dst: PByte; n: SizeInt);
begin
  case c of
    0: ;
    1: XorRow(Src, Dst, n);
  else
    MulAddRow(@MulTab[c, 0], Src, Dst, n);
  end;
end;

// Dst := c * Src
procedure SetRow(c: Byte; Src, Dst: PByte; n: SizeInt);
begin
  case c of
    0: FillChar(Dst^, n, 0);
    1: Move(Src^, Dst^, n);
  else
    // poner en cero y acumular aprovecha las escrituras de a palabra de MulAddRow
    FillChar(Dst^, n, 0);
    MulAddRow(@MulTab[c, 0], Src, Dst, n);
  end;
end;

{ Tamaño de franja: que las filas de destino + la de origen entren en ~64 KB (L1/L2)
  mientras se recorren todos los orígenes. Múltiplo de 64 para no partir líneas. }
procedure RsMulAdd(c: Byte; Src, Dst: PByte; n: SizeInt);
begin
  AccumRow(c, Src, Dst, n);
end;

function ChunkFor(Rows: Integer; SectorSize: SizeInt): SizeInt;
begin
  Result := (64 * 1024) div (Rows + 1);
  if Result < 1024 then Result := 1024;
  Result := Result and not SizeInt(63);
  if Result > SectorSize then Result := SectorSize;
end;

function ValidKM(k, m: Integer): Boolean;
begin
  Result := (k >= 1) and (m >= 1) and (k + m <= RS_MAX_SECTORS);
end;

procedure BuildCoefs(k, m: Integer; out C: TBytes);
var
  i, j: Integer;
begin
  SetLength(C, k * m);
  for i := 0 to m - 1 do
    for j := 0 to k - 1 do
      C[i * k + j] := RsCoef(i, j);
end;

procedure RsEncode(k, m: Integer; const Data: array of PByte; SectorSize: SizeInt;
  const Parity: array of PByte);
var
  C: TBytes;
  i, j: Integer;
  off, n, chunk: SizeInt;
  src: PByte;
begin
  if not ValidKM(k, m) or (Length(Data) < k) or (Length(Parity) < m) or (SectorSize < 0) then
    raise ERangeError.CreateFmt('RsEncode: parámetros inválidos (k=%d, m=%d)', [k, m]);
  BuildCoefs(k, m, C);
  chunk := ChunkFor(m, SectorSize);
  off := 0;
  while off < SectorSize do
  begin
    n := SectorSize - off;
    if n > chunk then n := chunk;
    // la columna 0 es toda unos: cada paridad arranca como copia del sector 0
    src := Data[0] + off;
    for i := 0 to m - 1 do
      Move(src^, (Parity[i] + off)^, n);
    // origen por fuera: cada sector de datos se lee una vez y se reparte a las m filas
    for j := 1 to k - 1 do
    begin
      src := Data[j] + off;
      for i := 0 to m - 1 do
        AccumRow(C[i * k + j], src, Parity[i] + off, n);
    end;
    Inc(off, n);
  end;
end;

// Gauss-Jordan sobre GF(2^8); A (n x n, por filas) se destruye, Inv sale la inversa
function InvertMatrix(n: Integer; var A: TBytes; out Inv: TBytes): Boolean;
var
  r, c, p, col: Integer;
  t, f: Byte;
begin
  SetLength(Inv, n * n);
  FillChar(Inv[0], n * n, 0);
  for r := 0 to n - 1 do Inv[r * n + r] := 1;
  for col := 0 to n - 1 do
  begin
    p := col;
    while (p < n) and (A[p * n + col] = 0) do Inc(p);
    if p = n then Exit(False);  // con Cauchy no pasa, pero mejor no confiar
    if p <> col then
      for c := 0 to n - 1 do
      begin
        t := A[p * n + c]; A[p * n + c] := A[col * n + c]; A[col * n + c] := t;
        t := Inv[p * n + c]; Inv[p * n + c] := Inv[col * n + c]; Inv[col * n + c] := t;
      end;
    f := GfInv(A[col * n + col]);
    for c := 0 to n - 1 do
    begin
      A[col * n + c] := MulTab[f, A[col * n + c]];
      Inv[col * n + c] := MulTab[f, Inv[col * n + c]];
    end;
    for r := 0 to n - 1 do
    begin
      f := A[r * n + col];
      if (r = col) or (f = 0) then Continue;
      for c := 0 to n - 1 do
      begin
        A[r * n + c] := A[r * n + c] xor MulTab[f, A[col * n + c]];
        Inv[r * n + c] := Inv[r * n + c] xor MulTab[f, Inv[col * n + c]];
      end;
    end;
  end;
  Result := True;
end;

{ Con E = datos borrados (ne) y P = ne paridades sanas, para cada p en P:
    S_p = Paridad_p xor suma(j sano) coef(p,j) * D_j = suma(j en E) coef(p,j) * D_j
  o sea S = A * D_E con A = coef[P, E], una submatriz de Cauchy escalada (invertible).
  Entonces D_E = A^-1 * S. Después las paridades borradas se recalculan como en
  RsEncode. Costo ~ ne * k por byte, igual que codificar ne paridades. }
function RsRecover(k, m: Integer; const Sectors: array of PByte;
  const Present: array of Boolean; SectorSize: SizeInt): Boolean;
var
  C, A, Inv, Syn: TBytes;
  E, P, MissPar: array of Integer;
  ne, nmp, i, j, r, x: Integer;
  off, n, chunk: SizeInt;
  src, dst: PByte;
begin
  Result := False;
  if not ValidKM(k, m) or (Length(Sectors) < k + m) or (Length(Present) < k + m) or
     (SectorSize < 0) then Exit;
  SetLength(E, k);
  SetLength(MissPar, m);
  ne := 0;
  nmp := 0;
  for j := 0 to k - 1 do
    if not Present[j] then begin E[ne] := j; Inc(ne); end;
  for i := 0 to m - 1 do
    if not Present[k + i] then begin MissPar[nmp] := i; Inc(nmp); end;
  if ne + nmp > m then Exit;
  Result := True;
  if (ne + nmp = 0) or (SectorSize = 0) then Exit;

  BuildCoefs(k, m, C);
  if ne > 0 then
  begin
    // las primeras ne paridades sanas (hay: m - nmp >= ne)
    SetLength(P, ne);
    x := 0;
    for i := 0 to m - 1 do
      if Present[k + i] and (x < ne) then begin P[x] := i; Inc(x); end;
    SetLength(A, ne * ne);
    for r := 0 to ne - 1 do
      for x := 0 to ne - 1 do
        A[r * ne + x] := C[P[r] * k + E[x]];
    if not InvertMatrix(ne, A, Inv) then Exit(False);
  end;

  chunk := ChunkFor(ne + nmp, SectorSize);
  if ne > 0 then SetLength(Syn, ne * chunk);
  off := 0;
  while off < SectorSize do
  begin
    n := SectorSize - off;
    if n > chunk then n := chunk;
    if ne > 0 then
    begin
      for r := 0 to ne - 1 do
        Move((Sectors[k + P[r]] + off)^, Syn[r * chunk], n);
      x := 0;  // recorre E en paralelo para saltear los borrados
      for j := 0 to k - 1 do
      begin
        if (x < ne) and (E[x] = j) then begin Inc(x); Continue; end;
        src := Sectors[j] + off;
        for r := 0 to ne - 1 do
          AccumRow(C[P[r] * k + j], src, @Syn[r * chunk], n);
      end;
      for x := 0 to ne - 1 do
      begin
        dst := Sectors[E[x]] + off;
        SetRow(Inv[x * ne], @Syn[0], dst, n);
        for r := 1 to ne - 1 do
          AccumRow(Inv[x * ne + r], @Syn[r * chunk], dst, n);
      end;
    end;
    // paridades borradas: los datos de esta franja ya están completos
    for x := 0 to nmp - 1 do
    begin
      i := MissPar[x];
      dst := Sectors[k + i] + off;
      Move((Sectors[0] + off)^, dst^, n);
      for j := 1 to k - 1 do
        AccumRow(C[i * k + j], Sectors[j] + off, dst, n);
    end;
    Inc(off, n);
  end;
end;

function RsStripeCount(NumSectors: Int64; m: Integer): Int64;
var
  kmax: Int64;
begin
  kmax := 255 - m;
  if (NumSectors <= 0) or (kmax < 1) then Exit(0);
  Result := (NumSectors + kmax - 1) div kmax;
end;

function RsStripeLen(NumSectors, Stripes, s: Int64): Integer;
begin
  if (Stripes <= 0) or (s < 0) or (s >= Stripes) then Exit(0);
  Result := (NumSectors - s + Stripes - 1) div Stripes;
end;

initialization
  InitTables;
end.
