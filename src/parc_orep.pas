{ OREP en PArc: coincidencias de largo alcance en un solo pase (deduplicación antes de lzma,
  tor, ppmd...). Reemplaza a REP de FreeArc (GPL): OREP es código propio, MIT, escrito para
  PArc por osrep (src/orep, versión en src/orep/VERSION). Esta unidad es el pegamento: el
  método `orep` (parámetros y texto canónico), la etapa de decodificación (TInStage) y la de
  codificación (TOutStage), y la memoria de cada lado.

  Método: orep[:<ventana>][:<largo mínimo>][:w<mem>][:l<n>][:a<n>][:s<n>][:c<n>][:r<n>][:b<mem>][:d<mem>]
    ventana (w, o una memoria sin nombre)   distancia máxima (512mb; hasta 3840mb)
    largo mínimo (l, o un entero sin nombre) coincidencia más corta que se busca (64; >= 16)
    a  alineación: largos múltiplos de a y literales en su posición módulo a (0 = por bloque:
       1 en texto, 4 en lo demás; 0..4096, <= l)
    s  densidad de anclas (4; 1..64): más alta encuentra más coincidencias cortas, más lento
    c  candidatos por ancla (4; 1..4): más encuentra coincidencias más largas, 1 es lo más rápido
    r  una coincidencia que solo cubre una tirada de un byte y es más corta que esto queda para
       la etapa siguiente (0 = ninguna; hasta 65536): plz codifica esas tiradas casi gratis
    b  tamaño de bloque del stream (4mb; potencia de 2, 64kb..64mb)
    d  coincidencias más cercanas que esto quedan para el compresor de atrás (0)
  Las memorias como en el resto de PArc (sufijo b/k/m/g; sin sufijo, 2^N). El stream lleva
  su propio encabezado (ventana, bloque, alineación): el decodificador no usa los parámetros
  del método salvo para acotar la memoria (ver TOrepDecStage).

  Hilos (OREP 0.0.6): con dos fichas o más para el bloque (ThreadShare) y al menos 4 MB de
  entrada, OREP usa P.Threads = esa parte (hasta 4): un coordinador que busca mientras el hilo que
  escribe pasa el bloque anterior a la etapa siguiente, y ayudantes. Ningún hilo de OREP espera
  una ficha: P.OnWorkerTryBusy toma una del presupuesto global sin esperar (BudgetTryTake; si no
  hay, ese bloque o lote lo busca el hilo que ya tiene la suya) y OnWorkerIdle la devuelve
  (BudgetGive) antes de dormir, tras girar a lo sumo P.SpinUs = 200 us. El hilo que escribe
  suelta su ficha mientras espera a la búsqueda (OnCallerWaitBegin/End -> BudgetWaitBegin/End).
  Así nunca se pasa de PARC_THREADS (tests/thread_budget.py) y no hay deadlock: nadie espera una
  ficha teniendo otra. Sin ganchos OREP no se usa con hilos (P.Threads = 1). La salida es la
  misma con cualquier cantidad de hilos. PARC_OREP_THREADS=k fija k (1 = en línea). }
unit parc_orep;

{$mode objfpc}{$H+}
{$R-}{$Q-}

interface

uses
  SysUtils, parc_stream, parc_outstream, orep;

type
  { Parámetros del método `orep` (los del codificador; el stream trae los suyos) }
  TOrepMethod = record
    Window: QWord;
    MinLen, Align, Density, Cands, Chunk, RunKeep: LongWord;
    MinDist: QWord;
  end;

const
  OREP_DEF_WINDOW = QWord(512) shl 20;
  OREP_DEF_MINLEN = 64;
  OREP_DEF_ALIGN = 0;      // por bloque
  OREP_DEF_DENSITY = 4;
  OREP_DEF_CANDS = 4;
  OREP_DEF_CHUNK = 4 shl 20;

function DefaultOrepMethod: TOrepMethod;
{ Params[0] = 'orep'. Parámetros inválidos -> EUnsupportedMethod. }
function ParseOrepMethod(const Params: TStringArray): TOrepMethod;
{ Los parámetros de OREP para estos del método (sin SizeHint: la ventana ya viene recortada al
  bloque sólido por parc_canon, y así el encabezado del stream es la ventana del método). }
function OrepParamsOf(const M: TOrepMethod; Threads: LongWord): TOrepParams;
{ Memoria del codificador (OrepEncMemory) y del decodificador (OrepDecMemory). }
function OrepMethodEncMemory(const M: TOrepMethod): QWord;
function OrepMethodDecMemory(const M: TOrepMethod): QWord;
{ La ventana más grande <= M.Window (en MB enteros, mínimo 1 MB) con la que el codificador usa
  a lo sumo MemLim bytes. }
function OrepFitWindow(const M: TOrepMethod; MemLim: QWord): QWord;

type
  POrepDec = ^TOrepDec;

  TOrepDecStage = class(TInStage)
  private
    FDec: POrepDec;            // del pool de decodificadores (OrepDecReset) o nuevo
    FLimit: QWord;
    FEnd, FSrcEof: Boolean;
    FIn: array of Byte;
    FInPos, FInLen: SizeInt;
  public
    constructor Create(ASource: TInStage; const M: TOrepMethod);
    destructor Destroy; override;
    function Read(Buf: PByte; Count: SizeInt): SizeInt; override;
  end;

  POrepEnc = ^TOrepEnc;

  TOrepEncStage = class(TOutStage)
  private
    FM: TOrepMethod;
    FEnc: POrepEnc;
    FInited: Boolean;
    FPend: array of Byte;      // entrada antes de crear OREP (para decidir los hilos)
    FPendLen: SizeInt;
    FOut: array of Byte;
    FCallerHad: Boolean;       // el hilo que escribe tenía ficha al empezar a esperar a OREP
    { Cola de salida demorada (memoria): hasta FTailMax bytes de la salida de OREP quedan aquí
      mientras FProduced <= FTailUntil, en trozos de OREP_OUT_BUF; al terminar se libera OREP
      (anillo y tabla) ANTES de pasar la cola a la etapa siguiente, que así crece (lzma bt4) sin
      OREP vivo. Con FTailMax = 0, como antes. }
    FTailMax: SizeInt;
    FTailUntil, FProduced: QWord;
    FQ: array of PByte;
    FQLen: array of SizeInt;
    FQN: Integer;
    FQHeld: SizeInt;
    FSpare: PByte;
    procedure Start(Threads: Integer);
    procedure Run(Buf: PByte; Count: SizeInt; Mode: Integer);
    procedure QDrain(Keep: SizeInt; FreeIt: Boolean);
    procedure QFreeAll;
  protected
    procedure DoWrite(Buf: PByte; Count: SizeInt); override;
    procedure DoFinish; override;
  public
    constructor Create(ATarget: TOutStage; const M: TOrepMethod);
    constructor Create(ATarget: TOutStage; const Params: TStringArray);
    destructor Destroy; override;
    { Demora hasta MaxBytes de salida mientras la salida total no pase de UntilBytes. }
    procedure SetTail(MaxBytes: SizeInt; UntilBytes: QWord);
  end;

implementation

uses
  parc_methods, parc_bytes, parc_parallel;

function DefaultOrepMethod: TOrepMethod;
begin
  Result.Window := OREP_DEF_WINDOW;
  Result.MinLen := OREP_DEF_MINLEN;
  Result.Align := OREP_DEF_ALIGN;
  Result.Density := OREP_DEF_DENSITY;
  Result.Cands := OREP_DEF_CANDS;
  Result.RunKeep := 0;
  Result.Chunk := OREP_DEF_CHUNK;
  Result.MinDist := 0;
end;

function ParseOrepMethod(const Params: TStringArray): TOrepMethod;
var
  k: Integer;
  p: string;

  procedure Bad;
  begin
    raise EUnsupportedMethod.CreateFmt('orep: invalid parameter "%s"', [p]);
  end;

  function Int(const S: string): LongWord;
  var
    v: Int64;
  begin
    v := StrToInt64Def(S, -1);
    if (S = '') or not (S[1] in ['0'..'9']) or (v < 0) or (v > High(LongWord)) then Bad;
    Result := LongWord(v);
  end;

  function Mem(const S: string): QWord;
  begin
    if not ParseMem(S, Result) then Bad;
  end;

var
  OP: TOrepParams;
begin
  if (Length(Params) = 0) or (Params[0] <> 'orep') then
    raise EUnsupportedMethod.Create('orep: not the method orep');
  Result := DefaultOrepMethod;
  for k := 1 to High(Params) do
  begin
    p := LowerCase(Params[k]);
    if p = '' then Bad;
    case p[1] of
      'w': Result.Window := Mem(Copy(p, 2, MaxInt));
      'l': Result.MinLen := Int(Copy(p, 2, MaxInt));
      'a': Result.Align := Int(Copy(p, 2, MaxInt));
      's': Result.Density := Int(Copy(p, 2, MaxInt));
      'c': Result.Cands := Int(Copy(p, 2, MaxInt));
      'r': Result.RunKeep := Int(Copy(p, 2, MaxInt));
      'b':
        begin
          Result.Chunk := High(LongWord);   // fuera de rango: lo rechaza la validación
          if Mem(Copy(p, 2, MaxInt)) < High(LongWord) then Result.Chunk := Mem(Copy(p, 2, MaxInt));
        end;
      'd': Result.MinDist := Mem(Copy(p, 2, MaxInt));
      '0'..'9':
        // sin nombre: un entero es el largo mínimo; una memoria con sufijo, la ventana
        if StrToInt64Def(p, -1) >= 0 then Result.MinLen := Int(p)
        else Result.Window := Mem(p);
    else
      Bad;
    end;
  end;
  // validar ya (con los límites de OREP), no al crear la etapa
  OP := OrepParamsOf(Result, 1);
  if OrepEncMemory(OP) = 0 then
    raise EUnsupportedMethod.CreateFmt('orep: invalid parameters "%s" (window 1b..3840mb, ' +
      'l16..65536, a0..4096 and <= l, s1..64, c1..4, r0..65536, b64kb..64mb, power of 2)', [string.Join(':', Params)]);
end;

function OrepParamsOf(const M: TOrepMethod; Threads: LongWord): TOrepParams;
begin
  OrepParamsDefault(Result);
  Result.Window := M.Window;
  Result.SizeHint := 0;
  Result.MinLen := M.MinLen;
  Result.Chunk := M.Chunk;
  Result.Align := M.Align;
  Result.Density := M.Density;
  Result.Cands := M.Cands;
  Result.RunKeep := M.RunKeep;
  Result.MinDist := M.MinDist;
  Result.Threads := Threads;
end;

function OrepMethodEncMemory(const M: TOrepMethod): QWord;
begin
  Result := OrepEncMemory(OrepParamsOf(M, 1));
end;

function OrepMethodDecMemory(const M: TOrepMethod): QWord;
begin
  Result := OrepDecMemory(M.Window, M.Chunk);
end;

function OrepFitWindow(const M: TOrepMethod; MemLim: QWord): QWord;
var
  T: TOrepMethod;
  Lo, Hi, Mid: QWord;
begin
  // búsqueda binaria en MB: la memoria crece con la ventana
  T := M;
  Hi := M.Window shr 20;
  if Hi < 1 then Exit(M.Window);
  Lo := 1;
  T.Window := Hi shl 20;
  if OrepMethodEncMemory(T) <= MemLim then Exit(T.Window);
  while Lo < Hi do
  begin
    Mid := (Lo + Hi + 1) div 2;
    T.Window := Mid shl 20;
    if OrepMethodEncMemory(T) <= MemLim then Lo := Mid else Hi := Mid - 1;
  end;
  Result := Lo shl 20;
end;

{ ---- decodificador ---- }

const
  OREP_IN_BUF = 256 * 1024;
  { Decodificadores ociosos para reusar (OrepDecReset: conserva su anillo, sin volver a reservar
    ni tocar páginas nuevas; con muchos bloques chicos, p. ej. -s- o la extracción en paralelo,
    es lo que más cuesta). Solo los de anillo chico, y pocos: la memoria queda tomada. }
  OREP_DEC_POOL = 8;
  OREP_DEC_POOL_MAXMEM = 64 shl 20;

var
  DecPool: array[0..OREP_DEC_POOL - 1] of POrepDec;
  DecPoolCount: Integer = 0;
  DecPoolLock: TRTLCriticalSection;

{ Un decodificador listo para un stream nuevo: uno del pool (OrepDecReset) o uno nuevo. }
function TakeDecoder(Limit: QWord): POrepDec;
begin
  Result := nil;
  EnterCriticalSection(DecPoolLock);
  if DecPoolCount > 0 then
  begin
    Dec(DecPoolCount);
    Result := DecPool[DecPoolCount];
    DecPool[DecPoolCount] := nil;
  end;
  LeaveCriticalSection(DecPoolLock);
  if (Result <> nil) and (OrepDecReset(Result^) <> OREP_OK) then
  begin
    OrepDecEnd(Result^);
    Dispose(Result);
    Result := nil;
  end;
  if Result = nil then
  begin
    New(Result);
    OrepDecInit(Result^, Limit);
  end;
  Result^.MemLimit := Limit;   // el del método de este bloque
end;

{ Devuelve un decodificador que terminó bien su stream (o lo libera). }
procedure GiveDecoder(D: POrepDec; Ok: Boolean);
begin
  if Ok and (OrepDecMemory(D^.Window, D^.Chunk) <= OREP_DEC_POOL_MAXMEM) then
  begin
    EnterCriticalSection(DecPoolLock);
    if DecPoolCount < OREP_DEC_POOL then
    begin
      DecPool[DecPoolCount] := D;
      Inc(DecPoolCount);
      D := nil;
    end;
    LeaveCriticalSection(DecPoolLock);
  end;
  if D <> nil then
  begin
    OrepDecEnd(D^);
    Dispose(D);
  end;
end;

procedure FreeDecPool;
var
  i: Integer;
begin
  for i := 0 to DecPoolCount - 1 do
  begin
    OrepDecEnd(DecPool[i]^);
    Dispose(DecPool[i]);
  end;
  DecPoolCount := 0;
end;

constructor TOrepDecStage.Create(ASource: TInStage; const M: TOrepMethod);
begin
  inherited Create(ASource);
  // El encabezado del stream no puede pedir más memoria que la que declara el método (que es
  // lo que mira -ld): si lo hace, el stream o el método están dañados
  FLimit := OrepMethodDecMemory(M);
  FDec := TakeDecoder(FLimit);
  SetLength(FIn, OREP_IN_BUF);
end;

destructor TOrepDecStage.Destroy;
begin
  if FDec <> nil then GiveDecoder(FDec, FEnd);
  FDec := nil;
  inherited Destroy;
end;

{ Con OrepDecPeek: la salida ya verificada se copia de la memoria del decodificador directo al
  búfer del que lee (OrepDecSkip la marca como usada), sin pasar por otro búfer. }
function TOrepDecStage.Read(Buf: PByte; Count: SizeInt): SizeInt;
var
  NextIn, Data: PByte;
  AvailIn, Avail: SizeUInt;
  r: Integer;
  Extra: Byte;
begin
  Result := 0;
  if FEnd or (Count <= 0) then Exit;
  while True do
  begin
    if (FInPos = FInLen) and not FSrcEof then
    begin
      FInPos := 0;
      FInLen := Source.Read(@FIn[0], Length(FIn));
      if FInLen = 0 then FSrcEof := True;
    end;
    NextIn := @FIn[FInPos];
    AvailIn := FInLen - FInPos;
    r := OrepDecPeek(FDec^, NextIn, AvailIn, Data, Avail);
    FInPos := FInLen - SizeInt(AvailIn);
    if r < 0 then
    begin
      if r = OREP_E_MEM then
        if OrepDecMemory(FDec^.Window, FDec^.Chunk) > FLimit then
          Corrupt('orep: the stream needs more memory than its method declares')
        else
          OutOfMemoryError;
      Corrupt('orep: ' + OrepErrorText(r));
    end;
    if Avail > 0 then
    begin
      if SizeUInt(Count) < Avail then Avail := Count;
      Move(Data^, Buf^, Avail);
      OrepDecSkip(FDec^, Avail);
      Exit(Avail);
    end;
    if r = OREP_END then
    begin
      // nada después del fin del stream
      if (FInPos < FInLen) or (not FSrcEof and (Source.Read(@Extra, 1) <> 0)) then
        Corrupt('orep: data after the end of the stream');
      FEnd := True;
      Exit;
    end;
    if AvailIn > 0 then Corrupt('orep: decoder stalled');
    if FSrcEof then Corrupt('orep: truncated stream');
  end;
end;

{ ---- codificador ---- }

const
  OREP_OUT_BUF = 1 shl 20;      // salida de una llamada a OREP
  { Hilos de OREP como mucho (más allá casi no acelera) }
  OREP_MAX_THREADS = 4;
  { Giro de un hilo ocioso de OREP antes de devolver la ficha y dormir (sugerido por OREP) }
  OREP_SPIN_US = 200;
  { Con menos entrada que esto la etapa no crea hilos (no compensa) }
  OREP_THREADS_MIN_INPUT = 4 shl 20;

{ Ganchos de OREP 0.0.6 (ver el comentario de la unidad). Las fichas de los hilos de OREP no
  van atadas a un hilo: la puede pedir el que escribe para el coordinador y devolverla este. }
function OrepHookTryBusy(Ctx: Pointer): Boolean;
begin
  Result := BudgetTryTake;
end;

procedure OrepHookIdle(Ctx: Pointer);
begin
  BudgetGive;
end;

procedure OrepHookCallerWaitBegin(Ctx: Pointer);
begin
  TOrepEncStage(Ctx).FCallerHad := BudgetWaitBegin;
end;

procedure OrepHookCallerWaitEnd(Ctx: Pointer);
begin
  BudgetWaitEnd(TOrepEncStage(Ctx).FCallerHad);
end;

function OrepEncThreads: Integer;
begin
  Result := StrToIntDef(GetEnvironmentVariable('PARC_OREP_THREADS'), 0);
  if Result <= 0 then Result := OREP_MAX_THREADS;
  if Result > PoolWorkers(OREP_MAX_THREADS) then Result := PoolWorkers(OREP_MAX_THREADS);
  if Result < 2 then Result := 1;
end;

constructor TOrepEncStage.Create(ATarget: TOutStage; const Params: TStringArray);
begin
  Create(ATarget, ParseOrepMethod(Params));
end;

constructor TOrepEncStage.Create(ATarget: TOutStage; const M: TOrepMethod);
begin
  // Validar ANTES de inherited Create: si algo falla, Destroy ve FTarget=nil y el destino sigue
  // siendo del llamador. OREP se crea con la primera entrada que alcanza (o al final): así se
  // sabe si vale la pena con hilos
  if OrepMethodEncMemory(M) = 0 then raise EUnsupportedMethod.Create('orep: invalid parameters');
  FM := M;
  SetLength(FOut, OREP_OUT_BUF);
  inherited Create(ATarget);
end;

destructor TOrepEncStage.Destroy;
begin
  if FInited then OrepEncEnd(FEnc^);   // espera y cierra sus hilos
  FInited := False;
  if FEnc <> nil then Dispose(FEnc);
  FEnc := nil;
  QFreeAll;
  inherited Destroy;
end;

procedure TOrepEncStage.SetTail(MaxBytes: SizeInt; UntilBytes: QWord);
var
  v: Int64;
begin
  v := StrToInt64Def(GetEnvironmentVariable('PARC_OREP_TAIL'), -1);   // MB, para medir
  if v >= 0 then MaxBytes := v shl 20;
  if MaxBytes < 0 then MaxBytes := 0;
  FTailMax := MaxBytes;
  FTailUntil := UntilBytes;
end;

procedure TOrepEncStage.QFreeAll;
var
  i: Integer;
begin
  for i := 0 to FQN - 1 do FreeMem(FQ[i]);
  FQN := 0;
  FQHeld := 0;
  if FSpare <> nil then FreeMem(FSpare);
  FSpare := nil;
end;

{ Pasa a la etapa siguiente los trozos más viejos hasta que queden <= Keep bytes (solo trozos
  llenos, salvo Keep = 0). FreeIt: libera cada trozo (al final, para que baje el RSS). }
procedure TOrepEncStage.QDrain(Keep: SizeInt; FreeIt: Boolean);
var
  p: PByte;
  n: SizeInt;
begin
  while (FQN > 0) and (FQHeld > Keep) and ((Keep = 0) or (FQLen[0] = OREP_OUT_BUF)) do
  begin
    p := FQ[0];
    n := FQLen[0];
    Dec(FQN);
    if FQN > 0 then
    begin
      Move(FQ[1], FQ[0], FQN * SizeOf(PByte));
      Move(FQLen[1], FQLen[0], FQN * SizeOf(SizeInt));
    end;
    Dec(FQHeld, n);
    if n > 0 then Emit(p, n);
    if FreeIt or (FSpare <> nil) then FreeMem(p) else FSpare := p;
  end;
end;

procedure TOrepEncStage.Start(Threads: Integer);
var
  P: TOrepParams;
  r: Integer;
begin
  P := OrepParamsOf(FM, Threads);
  if Threads >= 2 then
  begin
    // todos los ganchos o ninguno: con hilos y sin ellos podría haber deadlock (OREP 0.0.6)
    P.OnWorkerTryBusy := @OrepHookTryBusy;
    P.OnWorkerIdle := @OrepHookIdle;
    P.OnCallerWaitBegin := @OrepHookCallerWaitBegin;
    P.OnCallerWaitEnd := @OrepHookCallerWaitEnd;
    P.HookCtx := Self;
    P.SpinUs := OREP_SPIN_US;
  end;
  New(FEnc);   // en el heap: con hilos no se puede mover
  r := OrepEncInit(FEnc^, P);
  if r = OREP_E_MEM then OutOfMemoryError;
  if r <> OREP_OK then raise EUnsupportedMethod.Create('orep: ' + OrepErrorText(r));
  FInited := True;
end;

{ OrepEncRun hasta consumir Count bytes (OREP_RUN) o hasta el fin del stream (OREP_FINISH);
  la salida va a la etapa siguiente de a OREP_OUT_BUF bytes. Con hilos, la búsqueda de un bloque
  sigue en el coordinador mientras este hilo pasa el anterior a la etapa siguiente. }
procedure TOrepEncStage.Run(Buf: PByte; Count: SizeInt; Mode: Integer);
var
  NextIn, NextOut, p: PByte;
  AvailIn, AvailOut: SizeUInt;
  r: Integer;
  n: SizeInt;
begin
  NextIn := Buf;
  AvailIn := Count;
  repeat
    if FTailMax = 0 then
    begin
      NextOut := @FOut[0];
      AvailOut := Length(FOut);
      r := OrepEncRun(FEnc^, NextIn, AvailIn, NextOut, AvailOut, Mode);
      if r = OREP_E_MEM then OutOfMemoryError;
      if r < 0 then raise EUnsupportedMethod.Create('orep: ' + OrepErrorText(r));
      n := Length(FOut) - SizeInt(AvailOut);
      if n > 0 then Emit(@FOut[0], n);
    end
    else
    begin
      if (FQN = 0) or (FQLen[FQN - 1] = OREP_OUT_BUF) then
      begin
        if FSpare <> nil then begin p := FSpare; FSpare := nil; end
        else p := GetMem(OREP_OUT_BUF);
        if FQN >= Length(FQ) then
        begin
          SetLength(FQ, FQN + 16);
          SetLength(FQLen, FQN + 16);
        end;
        FQ[FQN] := p;
        FQLen[FQN] := 0;
        Inc(FQN);
      end;
      NextOut := FQ[FQN - 1] + FQLen[FQN - 1];
      AvailOut := OREP_OUT_BUF - FQLen[FQN - 1];
      n := AvailOut;
      r := OrepEncRun(FEnc^, NextIn, AvailIn, NextOut, AvailOut, Mode);
      if r = OREP_E_MEM then OutOfMemoryError;
      if r < 0 then raise EUnsupportedMethod.Create('orep: ' + OrepErrorText(r));
      n := n - SizeInt(AvailOut);
      Inc(FQLen[FQN - 1], n);
      Inc(FQHeld, n);
      Inc(FProduced, n);
      if FProduced > FTailUntil then
      begin
        // la etapa siguiente ya no crece: sin cola desde aquí
        QDrain(0, True);
        QFreeAll;
        FTailMax := 0;
        AvailOut := 1;   // (para la condición de salida)
      end
      else
        QDrain(FTailMax, False);
    end;
  until (r = OREP_END) or ((Mode <> OREP_FINISH) and (AvailIn = 0) and (AvailOut > 0));
end;

procedure TOrepEncStage.DoWrite(Buf: PByte; Count: SizeInt);
var
  n: SizeInt;
begin
  if not FInited then
  begin
    if FPendLen + Count < OREP_THREADS_MIN_INPUT then
    begin
      if Length(FPend) < FPendLen + Count then SetLength(FPend, OREP_THREADS_MIN_INPUT);
      Move(Buf^, FPend[FPendLen], Count);
      Inc(FPendLen, Count);
      Exit;
    end;
    Start(OrepEncThreads);
    if FPendLen > 0 then
    begin
      n := FPendLen;
      FPendLen := 0;
      Run(@FPend[0], n, OREP_RUN);
    end;
    FPend := nil;
  end;
  Run(Buf, Count, OREP_RUN);
end;

procedure TOrepEncStage.DoFinish;
begin
  if not FInited then
  begin
    Start(1);
    if FPendLen > 0 then Run(@FPend[0], FPendLen, OREP_RUN);
    FPend := nil;
    FPendLen := 0;
  end;
  Run(nil, 0, OREP_FINISH);
  // OREP ya no hace falta: liberar anillo, tabla e hilos antes de pasar la cola y de que la
  // etapa siguiente termine (su memoria sigue creciendo hasta su Finish)
  if FInited then OrepEncEnd(FEnc^);
  FInited := False;
  if FEnc <> nil then Dispose(FEnc);
  FEnc := nil;
  FOut := nil;
  QDrain(0, True);
  QFreeAll;
end;

initialization
  InitCriticalSection(DecPoolLock);
finalization
  FreeDecPool;
  DoneCriticalSection(DecPoolLock);
end.
