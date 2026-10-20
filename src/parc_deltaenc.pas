{ DELTA (codificador): detección de tablas binarias y resta de filas sucesivas. Port de
  Compression/Delta/Delta.cpp (delta_compress, delta_process, FAST_CHECK_FOR_DATA_TABLE,
  slow_check_for_data_table, search_for_table_boundary, analyze_table, diff_table,
  reorder_table, encode_type) y C_Delta.cpp (parse_DELTA) de FreeArc 0.67, Bulat Ziganshin.
  Decodificador: parc_filters (TDeltaStage).

  Salida idéntica byte a byte a delta_compress con lecturas completas: el C procesa bloques de
  exactamente BlockSize bytes (el último, lo que quede). Por bloque:
    U32 Size, U32 4*ntablas, TSkip[], TType[], TRows[] (U32 c/u), Size bytes procesados.
  Memoria: un bloque (crece con los datos hasta BlockSize) + copia temporal de una tabla. }
unit parc_deltaenc;

{$mode objfpc}{$H+}
{$goto on}
{$R-}{$Q-}

interface

uses
  SysUtils, parc_outstream;

type
  EDeltaEncParams = class(Exception);

  TDeltaEncParams = record
    BlockSize: LongInt;       // b<mem> o memoria sin nombre (8mb)
    ExtendedTables: Boolean;  // x (delta_compress no lo usa)
  end;

  TDeltaEncStage = class(TOutStage)
  private
    FPar: TDeltaEncParams;
    FBuf: array of Byte;      // bloque actual (+ margen como el BigAlloc del C)
    FLen: SizeInt;            // bytes acumulados en FBuf
    FTmp: array of Byte;      // ReorderingBuffer
    FSkip, FType, FRows: array of LongWord;
    FNTab: SizeInt;
    procedure EnsureCap(Need: SizeInt);
    procedure AddTable(Skip, TypeW, Rows: LongWord);
    function SlowCheck(N: LongInt; p: SizeInt; out TypeW: LongWord; out TabStart, TabEnd: SizeInt;
      BufStart, BufEnd: SizeInt): Boolean;
    procedure ProcessBlock(Size: SizeInt);
    procedure FlushBlock;
  protected
    procedure DoWrite(Buf: PByte; Count: SizeInt); override;
    procedure DoFinish; override;
  public
    { Params = partes del método separadas por ':' con Params[0] = 'delta' }
    constructor Create(ATarget: TOutStage; const Params: TStringArray);
    constructor Create(ATarget: TOutStage; const APar: TDeltaEncParams);
  end;

{ parse_DELTA; invalid parameters -> EDeltaEncParams }
function ParseDeltaEncParams(const Params: TStringArray): TDeltaEncParams;

implementation

uses
  parc_methods;

const
  MAX_ELEMENT_SIZE = 30;    // ancho máximo de elemento
  SMALL_ELEMENT_SIZE = 4;   // anchos chicos: se revisan en cada ciclo...
  FAST_CYCLES = 4;          // ...y los demás, cada 4 ciclos
  LINE = 32;                // bloque en el que se cuentan repeticiones de distancias
  DELTA = 8;                // desvío máximo entre valores sucesivos de una columna (FAST_CHECK)
  SLACK = MAX_ELEMENT_SIZE * 8 + 1;   // margen de BigAlloc(BlockSize+MAX_ELEMENT_SIZE*8+1)
  MAX_BLOCK_SIZE = $7FFFFF00;

{ parseMem64 de FreeArc (sin sufijo = 2^N): es ParseMem de parc_methods, una sola
  implementación para todos los métodos. }
function FaParseMem(const S: string; out V: QWord): Boolean;
begin
  Result := ParseMem(S, V);
end;

function ParseDeltaEncParams(const Params: TStringArray): TDeltaEncParams;
var
  k: Integer;
  p: string;
  m: QWord;
  ok: Boolean;
begin
  if (Length(Params) = 0) or (Params[0] <> 'delta') then
    raise EDeltaEncParams.Create('delta: not the method delta');
  // DELTA_METHOD::DELTA_METHOD
  Result.BlockSize := 8 shl 20;
  Result.ExtendedTables := False;
  for k := 1 to High(Params) do
  begin
    p := Params[k];
    if p = 'x' then begin Result.ExtendedTables := True; Continue; end;
    if (p <> '') and (p[1] = 'b') then ok := FaParseMem(Copy(p, 2, MaxInt), m)
    else ok := FaParseMem(p, m);
    if not ok then raise EDeltaEncParams.CreateFmt('delta: invalid parameter "%s"', [p]);
    // Con BlockSize=0 el C lee 0 bytes, lo toma como fin y descarta todo el stream
    if (m = 0) or (m > MAX_BLOCK_SIZE) then
      raise EDeltaEncParams.CreateFmt('delta: invalid block size "%s"', [p]);
    Result.BlockSize := LongInt(m);
  end;
end;

{ TDeltaEncStage }

constructor TDeltaEncStage.Create(ATarget: TOutStage; const Params: TStringArray);
begin
  Create(ATarget, ParseDeltaEncParams(Params));
end;

constructor TDeltaEncStage.Create(ATarget: TOutStage; const APar: TDeltaEncParams);
begin
  // Validar ANTES de inherited Create (si falla, Destroy ve FTarget=nil)
  if (APar.BlockSize <= 0) or (APar.BlockSize > MAX_BLOCK_SIZE) then
    raise EDeltaEncParams.Create('delta: invalid block size');
  FPar := APar;
  inherited Create(ATarget);
end;

procedure TDeltaEncStage.EnsureCap(Need: SizeInt);
var
  NewCap: SizeInt;
begin
  if Need + SLACK <= Length(FBuf) then Exit;
  NewCap := 2 * Length(FBuf);
  if NewCap < Need + SLACK then NewCap := Need + SLACK;
  if NewCap < 1 shl 16 then NewCap := 1 shl 16;
  if NewCap > SizeInt(FPar.BlockSize) + SLACK then NewCap := SizeInt(FPar.BlockSize) + SLACK;
  SetLength(FBuf, NewCap);
end;

procedure TDeltaEncStage.AddTable(Skip, TypeW, Rows: LongWord);
begin
  if FNTab >= Length(FSkip) then
  begin
    SetLength(FSkip, 2 * FNTab + 64);
    SetLength(FType, 2 * FNTab + 64);
    SetLength(FRows, 2 * FNTab + 64);
  end;
  FSkip[FNTab] := Skip;
  FType[FNTab] := TypeW;
  FRows[FNTab] := Rows;
  Inc(FNTab);
end;

function I16(b: PByte; i: SizeInt): LongInt; inline;
begin
  Result := SmallInt(Word(b[i]) or (Word(b[i + 1]) shl 8));
end;

{ search_for_table_boundary: recorre una columna (paso N, que puede ser negativo) y se detiene
  cuando los tramos monótonos se vuelven demasiado cortos (largo < 4). Índices en vez de punteros. }
function SearchBoundary(b: PByte; N: LongInt; t, BufStart, BufEnd: SizeInt; out UselessOut: LongInt): SizeInt;
var
  dir, len, omit, useless, bad, diff: LongInt;
  abs_diff, abs_item, cmp_item: LongInt;
  lastpoint: SizeInt;
  first_time: Boolean;
begin
  if I16(b, t + N) - I16(b, t) < 0 then dir := -1 else dir := 1;
  len := 0; omit := 0; useless := 0; UselessOut := 0; bad := 0;
  lastpoint := t;
  first_time := True;
  t := t + N;
  while (BufStart <= t + N) and (t + N + 2 <= BufEnd) do
  begin
    diff := I16(b, t) - I16(b, t - N);
    abs_diff := Abs(diff);
    abs_item := Abs(I16(b, t));
    if abs_item > 4095 then cmp_item := abs_item div 6 else cmp_item := abs_item div 3;
    if diff = 0 then
      Inc(useless)
    else if dir * diff > 0 then
    begin
      if abs_diff < cmp_item then begin Inc(len); omit := 0; end
      else begin Inc(useless); Inc(omit); end;
    end
    else
    begin
      if (len >= 4) or first_time then
      begin
        bad := 0;
        lastpoint := t - N * omit;
        UselessOut := useless;
        first_time := False;
      end
      else
      begin
        Inc(bad);
        if bad >= 2 then Break;   // segundo tramo monótono seguido con largo < 4
      end;
      if I16(b, t + N) - I16(b, t) < 0 then dir := -1 else dir := 1;
      len := 0; omit := 0;
      // Empezar el tramo en el valor actual si el cambio es en V, o en el siguiente si es en N
      if dir * diff > 0 then t := t - N;
    end;
    t := t + N;
  end;
  Result := lastpoint;
end;

{ Floor(log2(x)) = logb(x) para x >= 1 }
function IntLogB(x: SizeInt): LongInt;
begin
  Result := 0;
  while x > 1 do begin x := x shr 1; Inc(Result); end;
end;

{ slow_check_for_data_table: bordes exactos, criterio de aceptación y, si se acepta,
  analyze_table + diff_table + reorder_table + encode_type. }
function TDeltaEncStage.SlowCheck(N: LongInt; p: SizeInt; out TypeW: LongWord; out TabStart, TabEnd: SizeInt;
  BufStart, BufEnd: SizeInt): Boolean;
var
  b: PByte;
  useless, rows, useful, skipBits, T, k, i, neq, carry, newcarry, sub: LongInt;
  x: SizeInt;
  doDiff, immutable: array[0..MAX_ELEMENT_SIZE - 1] of Boolean;
  r, q, pp: SizeInt;
  accept: Boolean;
begin
  Result := False;
  TypeW := 0;
  b := @FBuf[0];
  // Primero hacia atrás desde p buscando el comienzo, luego hacia adelante buscando el fin
  TabStart := SearchBoundary(b, -N, p, BufStart, BufEnd, useless);
  TabEnd := SearchBoundary(b, N, TabStart, BufStart, BufEnd, useless);
  rows := (TabEnd - TabStart) div N;       // división de C (trunca hacia cero)
  useful := rows - useless;
  x := TabStart - BufStart;
  if x < 1 then x := 1;
  skipBits := IntLogB(x);
  // useful*sqrt(N) > 30+4*skipBits, en enteros: el C lo hace en double, pero u*sqrt(N)
  // nunca queda a menos de ~1/(2T) de un entero T (salvo N cuadrado perfecto, exacto),
  // así que la comparación da lo mismo que la exacta.
  T := 30 + 4 * skipBits;
  if useful <= 0 then accept := False
  else if useful >= 1 shl 20 then accept := True
  else accept := Int64(useful) * useful * N > Int64(T) * T;
  if not accept then Exit;

  // analyze_table: columnas (casi) constantes = inmutables; el resto se resta
  for k := 0 to N - 1 do
  begin
    neq := 0;
    pp := TabStart + k;
    for i := 1 to rows - 1 do
    begin
      if b[pp + N] <> b[pp] then Inc(neq);
      Inc(pp, N);
    end;
    immutable[k] := (neq * 4 < rows) and (N <> 2) and (N <> 4) and (N <> 8);
    doDiff[k] := not immutable[k];
  end;

  // diff_table: de la última fila a la segunda, resta la anterior con acarreo (LSB primero)
  r := TabStart + SizeInt(N) * rows;
  while True do
  begin
    Dec(r, N);
    if r <= TabStart then Break;
    carry := 0;
    for i := 0 to N - 1 do
      if doDiff[i] then
      begin
        sub := LongInt(b[r + i - N]) + carry;
        if LongInt(b[r + i]) < sub then newcarry := 1 else newcarry := 0;
        b[r + i] := Byte(b[r + i] - sub);
        carry := newcarry;
      end
      else
        carry := 0;
  end;

  // reorder_table: primero todas las columnas inmutables, después las demás
  // (el C lo hace siempre, aunque no haya ninguna inmutable: queda igual)
  if SizeInt(N) * rows > Length(FTmp) then SetLength(FTmp, SizeInt(N) * rows);
  if rows > 0 then Move(b[TabStart], FTmp[0], SizeInt(N) * rows);
  pp := TabStart;
  q := 0;
  for i := 0 to rows - 1 do
    for k := 0 to N - 1 do
    begin
      if immutable[k] then begin b[pp] := FTmp[q]; Inc(pp); end;
      Inc(q);
    end;
  q := 0;
  for i := 0 to rows - 1 do
    for k := 0 to N - 1 do
    begin
      if not immutable[k] then begin b[pp] := FTmp[q]; Inc(pp); end;
      Inc(q);
    end;

  // encode_type: bit N = ancho, bits 0..N-1 = columna inmutable
  TypeW := LongWord(1) shl N;
  for i := 0 to N - 1 do
    if immutable[i] then Inc(TypeW, LongWord(1) shl i);
  Result := True;
end;

{ delta_process: fase 1 (repeticiones del mismo nibble alto a la misma distancia dentro de
  cada LINE), fase 2 (FAST_CHECK) y fase 3 (SlowCheck) }
procedure TDeltaEncStage.ProcessBlock(Size: SizeInt);
label
  found;
var
  b: PByte;
  BufEnd, LastTableEnd, ptr, p, TabStart, TabEnd: SizeInt;
  hash: array[0..255] of SizeInt;
  count, count1: array[0..255] of Byte;
  cycle, i, j, N, lim, n1: LongInt;
  TypeW: LongWord;

  function FastCheck(N: LongInt; p: SizeInt): Boolean; inline;
  begin
    Result := (LongWord(LongInt(b[p + 1]) - LongInt(b[p + N + 1]) + DELTA) <= 2 * DELTA)
      and (LongWord(LongInt(b[p + N + 1]) - LongInt(b[p + 2 * N + 1]) + DELTA) <= 2 * DELTA)
      and (LongWord(LongInt(b[p + 2 * N + 1]) - LongInt(b[p + 3 * N + 1]) + DELTA) <= 2 * DELTA)
      and (I16(b, p) + I16(b, p + N) <> I16(b, p + 2 * N) + I16(b, p + 3 * N));
  end;

begin
  b := @FBuf[0];
  BufEnd := Size;
  LastTableEnd := 0;
  for i := 0 to 255 do hash[i] := -1;     // buf-1
  FillChar(count, SizeOf(count), 0);
  FillChar(count1, SizeOf(count1), 0);
  cycle := 0;
  ptr := MAX_ELEMENT_SIZE;
  while ptr + LINE < BufEnd do
  begin
    // *(int32*)ptr != *(int32*)(ptr+3): saltear bloques de bytes iguales (p. ej. ceros)
    if PLongWord(@b[ptr])^ <> PLongWord(@b[ptr + 3])^ then
    begin
      if cycle = 0 then lim := MAX_ELEMENT_SIZE else lim := SMALL_ELEMENT_SIZE;
      for i := 0 to lim - 1 do
      begin
        count1[i + 1] := count[i + 1];
        count[i + 1] := 0;
      end;
      for p := ptr to ptr + LINE - 1 do
      begin
        n1 := LongInt(p - hash[b[p] shr 4]);   // repetición por los 4 bits altos
        hash[b[p] shr 4] := p;
        Inc(count[n1 and 255]);                // BYTE: da la vuelta como en el C
      end;
      cycle := (cycle + 1) mod FAST_CYCLES;
      // Candidatos: distancias con al menos 24/12 repeticiones en las dos últimas vueltas
      if cycle = 0 then lim := MAX_ELEMENT_SIZE else lim := SMALL_ELEMENT_SIZE;
      for i := 0 to lim - 1 do
      begin
        if i >= SMALL_ELEMENT_SIZE then j := 24 else j := 12;
        if LongInt(count[i + 1]) + LongInt(count1[i + 1]) >= j then
        begin
          N := i + 1;
          if i >= SMALL_ELEMENT_SIZE then p := ptr - (FAST_CYCLES - 1) * LINE else p := ptr;
          for j := 0 to N - 1 do
          begin
            if FastCheck(N, p) and SlowCheck(N, p, TypeW, TabStart, TabEnd, LastTableEnd, BufEnd) then
            begin
              AddTable(LongWord(TabStart - LastTableEnd), TypeW, LongWord((TabEnd - TabStart) div N));
              LastTableEnd := TabEnd;
              ptr := LastTableEnd - LINE;
              cycle := 0;
              goto found;
            end;
            Inc(p);
          end;
        end;
      end;
    end;
  found:
    Inc(ptr, LINE);
  end;
end;

procedure TDeltaEncStage.FlushBlock;
var
  Size: SizeInt;
  Hdr: array of Byte;

  procedure PutArr(const A: array of LongWord; Base: SizeInt);
  var
    i: SizeInt;
  begin
    for i := 0 to FNTab - 1 do
    begin
      Hdr[Base + 4 * i] := Byte(A[i]);
      Hdr[Base + 4 * i + 1] := Byte(A[i] shr 8);
      Hdr[Base + 4 * i + 2] := Byte(A[i] shr 16);
      Hdr[Base + 4 * i + 3] := Byte(A[i] shr 24);
    end;
  end;

begin
  Size := FLen;
  if Size = 0 then Exit;   // READ_LEN_OR_EOF: 0 bytes = fin, sin bloque
  FNTab := 0;
  FillChar(FBuf[Size], SLACK, 0);
  ProcessBlock(Size);
  EmitU32(LongWord(Size));
  EmitU32(LongWord(4 * FNTab));
  if FNTab > 0 then
  begin
    SetLength(Hdr, 12 * FNTab);
    PutArr(FSkip, 0);
    PutArr(FType, 4 * FNTab);
    PutArr(FRows, 8 * FNTab);
    Emit(@Hdr[0], Length(Hdr));
  end;
  Emit(@FBuf[0], Size);
  FLen := 0;
end;

procedure TDeltaEncStage.DoWrite(Buf: PByte; Count: SizeInt);
var
  n: SizeInt;
begin
  while Count > 0 do
  begin
    // Bloque lleno y llegan más datos: procesarlo (READ_LEN_OR_EOF lee bloques completos)
    if FLen = FPar.BlockSize then FlushBlock;
    n := SizeInt(FPar.BlockSize) - FLen;
    if n > Count then n := Count;
    EnsureCap(FLen + n);
    Move(Buf^, FBuf[FLen], n);
    Inc(FLen, n);
    Inc(Buf, n);
    Dec(Count, n);
  end;
end;

procedure TDeltaEncStage.DoFinish;
begin
  FlushBlock;
  FBuf := nil;
  FTmp := nil;
end;

end.
