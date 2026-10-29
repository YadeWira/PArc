{ Trabajos en paralelo y el presupuesto global de hilos.

  Presupuesto: PARC_THREADS=N (por defecto, los núcleos) es el tope de hilos TRABAJANDO a la
  vez en todo el proceso, sumando todos los niveles (bloques en paralelo, 4x4/grzip adentro,
  hashing de REP, el match finder multihilo de LZMA, la verificación/extracción en paralelo).
  Hay N fichas: el hilo principal empieza con una y los hilos de los pools toman una por
  trabajo. Quien se bloquea esperando a otro hilo (un trabajo, un semáforo del match finder)
  suelta su ficha mientras espera y al despertar la recupera antes que los hilos que quieren
  empezar un trabajo nuevo. Así:
  - nunca corren más de N hilos (los que esperan no cuentan: están dormidos);
  - no hay deadlock: una ficha solo la tiene un hilo que corre, y todo hilo que corre termina
    su trabajo o llega a una espera que la suelta. Un trabajo que todavía nadie empezó lo
    ejecuta el mismo que lo espera, con su ficha (sin cambio de hilo);
  - las fichas van solas adonde hay trabajo: con un bloque enorme, a los hilos de 4x4/REP de
    ese bloque; con muchos bloques, a los que escriben bloques.
  Los pools se dimensionan (hilos creados, bloques en vuelo) con ThreadShare: el presupuesto
  entero en el nivel de arriba, o la parte que le toca a cada trabajo de un pool externo; si
  hay más trabajo que hilos, las etapas ordenadas (4x4, grzip) crecen hasta el presupuesto
  (TJobPool.CanGrow).

  Decodificación de bloques independientes en paralelo, con la salida en orden (como el
  MTCompressor de FreeArc, Compression/MultiThreading.h, que usan 4x4 y grzip).
  El hilo que llama lee los bloques en orden (la fuente no es thread-safe); un pool de hilos
  los decodifica y Read los entrega en el mismo orden.
  Nada de TThread.WaitFor en el camino caliente: en Unix, llamado desde el hilo principal,
  sondea con CheckSynchronize(100) y puede demorar hasta 100 ms por bloque. Se usan eventos. }
unit parc_parallel;

{$mode objfpc}{$H+}

interface

uses
  Classes, SysUtils, parc_stream;

type
  { Un hilo esperando una ficha del presupuesto (en la cola de espera). }
  PBudgetWaiter = ^TBudgetWaiter;
  TBudgetWaiter = record
    Ev: PRTLEvent;
    Granted: Boolean;     // le dieron la ficha
    Abort: Boolean;       // (hilos de pool) ya no la quiere: el pool se está cerrando
    Next: PBudgetWaiter;
  end;

  { Un trabajo: la subclase lo carga y lo procesa en Process (en un hilo del pool), que deja el
    resultado en OutBuf[0..OutSize). }
  TParallelJob = class
  private
    FDone: PRTLEvent;
    { 0 pendiente o corriendo; 1 terminó pero el hilo todavía no señaló FDone; 2 terminado y
      señalado. Los que esperan ven el resultado con <>0 (el evento se puede haber consumido en
      una espera con tope), pero liberar o reusar el trabajo exige 2: si no, el hilo llamaba a
      RTLEventSetEvent sobre un evento ya destruido. }
    FFinished: LongInt;
    FErrClass: ExceptClass;
    FErrMsg: string;
    procedure Run;
    procedure WaitSignaled;
  public
    OutBuf: TBytes;
    OutSize: SizeInt;
    constructor Create;
    destructor Destroy; override;
    procedure BeforeDestruction; override;   // espera que Run suelte el trabajo
    procedure Process; virtual; abstract;
    { Para reusar un trabajo ya terminado (y esperado): limpia el error y el evento. }
    procedure ResetForReuse;
  end;

  TJobArray = array of TParallelJob;

  TJobPool = class;

  TParallelWorker = class(TThread)
  private
    FPool: TJobPool;
    FWaiter: TBudgetWaiter;   // su lugar en la cola del presupuesto (el pool lo puede cancelar)
  public
    constructor Create(APool: TJobPool);
    procedure Execute; override;
  end;

  { Pool de hilos: Submit encola un trabajo; WaitJob espera que termine y relanza su error. Los
    hilos se crean a demanda, hasta MaxWorkers (0: todo en línea, en el hilo que espera). Cada
    hilo toma una ficha del presupuesto por trabajo. }
  TJobPool = class
  private
    FPending: TJobArray;  // trabajos todavía no tomados por un hilo (anillo)
    FPendHead, FPendCount: Integer;
    FLock: TRTLCriticalSection;
    FWork: PRTLEvent;
    FStop: Boolean;
    FWorkers: array of TParallelWorker;
    FNumWorkers, FMaxWorkers: Integer;
    FRunning: LongInt;      // trabajos corriendo en hilos del pool (cada uno con su ficha)
    FShare: Integer;
    function TakeJob(W: TParallelWorker): TParallelJob;
    function TakeIfPending(Job: TParallelJob): Boolean;
    procedure RunInline(Job: TParallelJob);
    function WaitDone(Job: TParallelJob; Ms: Cardinal): Boolean;
  public
    constructor Create(MaxWorkers, MaxPending: Integer);
    destructor Destroy; override;   // espera que los hilos terminen su trabajo actual
    procedure Submit(Job: TParallelJob);
    procedure WaitJob(Job: TParallelJob);   // relanza la excepción del trabajo, si la hubo
    { Como WaitJob pero espera como mucho Ms: False si el trabajo todavía no terminó. }
    function WaitJobFor(Job: TParallelJob; Ms: Cardinal): Boolean;
    { Espera que termine sin relanzar su error (que queda para WaitJob/WaitJobFor). }
    procedure WaitJobQuiet(Job: TParallelJob);
    { Más hilos (crecer cuando sobran fichas). }
    procedure SetMaxWorkers(N: Integer);
    { Trabajos encolados que ningún hilo tomó todavía. }
    function PendingCount: Integer;
    { ¿Conviene un hilo más (tope Cap)? Si todos los hilos del pool están trabajando, el
      productor que iba a esperar suelta su ficha: otro hilo la puede usar. Así cada pool tiene
      como mucho un hilo más que los que trabajan, y en total no pasan de presupuesto + pools. }
    function CanGrow(Cap: Integer): Boolean;
    property MaxWorkers: Integer read FMaxWorkers;
    { Hilos que puede planear cada trabajo de este pool para sus pools internos (ThreadShare
      dentro del trabajo); 0 = el presupuesto entero. }
    property Share: Integer read FShare write FShare;
  end;


  TParallelBlockStage = class(TInStage)
  private
    FQueue: TJobArray;                // FIFO de bloques en vuelo, en orden de stream
    FHead, FCount, FMaxJobs: Integer;
    FCap, FExtra: Integer;            // tope de hilos y bloques extra por hilo pedidos
    FPool: TJobPool;
    FCur: TParallelJob;
    FPos: SizeInt;
    FSourceEof, FEof: Boolean;
    FErrClass: ExceptClass;           // error ya lanzado: se repite en cada Read posterior
    FErrMsg: string;
    procedure FillQueue;
  protected
    { El próximo bloque de la fuente, ya cargado, o nil al final del stream. }
    function ReadJob: TParallelJob; virtual; abstract;
    { Un bloque ya entregado: por defecto se libera; una subclase puede guardarlo para
      reciclar sus buffers. }
    procedure ReleaseJob(Job: TParallelJob); virtual;
  public
    { MaxThreads: tope de hilos (el presupuesto puede dar menos); ExtraJobs: bloques leídos por
      adelantado además de uno por hilo (como mucho uno más por hilo). }
    constructor Create(ASource: TInStage; MaxThreads, ExtraJobs: Integer);
    destructor Destroy; override;
    function Read(Buf: PByte; Count: SizeInt): SizeInt; override;
  end;

{ --- Presupuesto global de hilos --- }

{ N: PARC_THREADS, o los núcleos (1..64). }
function BudgetThreads: Integer;
{ Fichas libres que nadie está esperando ahora (aproximado: sin lock). }
function BudgetIdle: Integer;
{ Antes de bloquearse esperando a otro hilo: suelta la ficha de este hilo, si tiene una.
  Devuelve si la tenía, para BudgetWaitEnd. }
function BudgetWaitBegin: Boolean;
{ Después de la espera: recupera la ficha (si Had), con prioridad sobre los trabajos nuevos. }
procedure BudgetWaitEnd(Had: Boolean);
{ Para hilos propios fuera de los pools (match finder de LZMA): tomar una ficha al empezar y
  devolverla al terminar (BudgetLeave también libera lo que el hilo reservó). }
procedure BudgetEnter;
procedure BudgetLeave;
{ ¿Este hilo tiene una ficha? }
function BudgetHeld: Boolean;
{ Hilos que el contexto actual puede planear: el presupuesto entero, o la parte de un trabajo
  de un pool externo (TJobPool.Share). }
function ThreadShare: Integer;
{ Hilos para un pool interno con tope Cap: min(Cap, ThreadShare); 0 si el presupuesto es de
  un solo hilo (los trabajos corren en línea, en el hilo que los espera). }
function PoolWorkers(Cap: Integer): Integer;
{ Agranda un anillo de trabajos (Head, Count) a NewLen, en orden desde 0. }
procedure GrowJobRing(var Q: TJobArray; var Head: Integer; Count, NewLen: Integer);

{ Presupuesto global de memoria para resultados que esperan su turno (bloques comprimidos en
  paralelo que todavía no se pueden escribir): min(1 GB, RAM/4), 256 MB en 32 bits;
  PARC_BUFMEM=<MB> lo reemplaza. TryReserve no espera: si no alcanza devuelve False y el que
  pidió usa otro camino (un temporal). }
function MemBudgetTryReserve(Bytes: Int64): Boolean;
procedure MemBudgetRelease(Bytes: Int64);

{$IFDEF PARC_RACE_TEST}
var
  RaceSleepMs: Integer = 0;   // pausa entre publicar el resultado y señalar el evento
  RaceHits: LongInt = 0;      // trabajos destruidos con Run todavía adentro
{$ENDIF}

implementation

uses
  parc_os;

{ ===== Presupuesto de hilos ===== }

const
  WAIT_FOREVER = High(Cardinal);

var
  BLock: TRTLCriticalSection;
  BTotal: Integer = 1;
  BAvail: Integer = 0;
  // Colas de espera: los que vuelven de una espera (alta) antes que los trabajos nuevos (baja)
  BHighHead, BHighTail, BLowHead, BLowTail: PBudgetWaiter;

threadvar
  TokenHeld: Boolean;
  CurShare: Integer;       // 0 = BTotal
  WaitEv: PRTLEvent;       // evento de este hilo para esperar fichas (se crea al primer uso)

function BudgetThreads: Integer;
begin
  Result := BTotal;
end;

function BudgetIdle: Integer;
begin
  Result := BAvail;
end;

function BudgetHeld: Boolean;
begin
  Result := TokenHeld;
end;

procedure Enqueue(W: PBudgetWaiter; High: Boolean);
begin
  W^.Next := nil;
  if High then
  begin
    if BHighTail = nil then BHighHead := W else BHighTail^.Next := W;
    BHighTail := W;
  end
  else
  begin
    if BLowTail = nil then BLowHead := W else BLowTail^.Next := W;
    BLowTail := W;
  end;
end;

{ Saca W de la cola baja (con BLock tomado). }
function UnlinkLow(W: PBudgetWaiter): Boolean;
var
  P, Prev: PBudgetWaiter;
begin
  Result := False;
  Prev := nil;
  P := BLowHead;
  while P <> nil do
  begin
    if P = W then
    begin
      if Prev = nil then BLowHead := P^.Next else Prev^.Next := P^.Next;
      if BLowTail = P then BLowTail := Prev;
      Exit(True);
    end;
    Prev := P;
    P := P^.Next;
  end;
end;

{ Toma una ficha esperando en W (que vive mientras dura la espera). False solo si W.Abort
  (el pool del hilo se cierra). }
function AcquireWith(var W: TBudgetWaiter; High: Boolean): Boolean;
var
  g: Boolean;
begin
  EnterCriticalSection(BLock);
  if W.Abort then
  begin
    LeaveCriticalSection(BLock);
    Exit(False);
  end;
  if (BAvail > 0) and (BHighHead = nil) and (High or (BLowHead = nil)) then
  begin
    Dec(BAvail);
    LeaveCriticalSection(BLock);
    TokenHeld := True;
    Exit(True);
  end;
  if WaitEv = nil then WaitEv := RTLEventCreate;
  W.Ev := WaitEv;
  W.Granted := False;
  Enqueue(@W, High);
  LeaveCriticalSection(BLock);
  repeat
    RTLEventWaitFor(W.Ev);
    // Granted/Abort se escriben con BLock tomado, y el aviso también: después de verlos acá,
    // nadie más toca W ni el evento por esta espera
    EnterCriticalSection(BLock);
    g := W.Granted;
    if not g and W.Abort then
    begin
      LeaveCriticalSection(BLock);
      Exit(False);
    end;
    LeaveCriticalSection(BLock);
  until g;
  TokenHeld := True;
  Result := True;
end;

procedure BudgetAcquire(High: Boolean);
var
  W: TBudgetWaiter;
begin
  W := Default(TBudgetWaiter);
  AcquireWith(W, High);
end;

procedure BudgetRelease;
var
  W: PBudgetWaiter;
begin
  TokenHeld := False;
  EnterCriticalSection(BLock);
  W := BHighHead;
  if W <> nil then
  begin
    BHighHead := W^.Next;
    if BHighHead = nil then BHighTail := nil;
  end
  else
  begin
    W := BLowHead;
    if W <> nil then
    begin
      BLowHead := W^.Next;
      if BLowHead = nil then BLowTail := nil;
    end;
  end;
  if W = nil then Inc(BAvail)
  else
  begin
    // La ficha pasa directo al que espera (nadie se la puede robar en el medio)
    W^.Granted := True;
    RTLEventSetEvent(W^.Ev);
  end;
  LeaveCriticalSection(BLock);
end;

{ Un pool que se cierra: su hilo ya no espera ficha (si estaba en la cola, sale sin ella). }
procedure BudgetAbortWaiter(var W: TBudgetWaiter);
begin
  EnterCriticalSection(BLock);
  W.Abort := True;
  if not W.Granted and UnlinkLow(@W) then RTLEventSetEvent(W.Ev);
  LeaveCriticalSection(BLock);
end;

function BudgetWaitBegin: Boolean;
begin
  Result := TokenHeld;
  if Result then BudgetRelease;
end;

procedure BudgetWaitEnd(Had: Boolean);
begin
  if Had then BudgetAcquire(True);
end;

procedure BudgetEnter;
begin
  if not TokenHeld then BudgetAcquire(False);
end;

procedure BudgetLeave;
begin
  if TokenHeld then BudgetRelease;
  if WaitEv <> nil then
  begin
    RTLEventDestroy(WaitEv);
    WaitEv := nil;
  end;
end;

function ThreadShare: Integer;
begin
  Result := CurShare;
  if (Result <= 0) or (Result > BTotal) then Result := BTotal;
end;

function PoolWorkers(Cap: Integer): Integer;
begin
  if BTotal <= 1 then Exit(0);
  Result := ThreadShare;
  if Result > Cap then Result := Cap;
  if Result < 1 then Result := 1;
end;

procedure GrowJobRing(var Q: TJobArray; var Head: Integer; Count, NewLen: Integer);
var
  N: TJobArray;
  i: Integer;
begin
  if NewLen < Count then NewLen := Count;
  SetLength(N, NewLen);
  for i := 0 to Count - 1 do N[i] := Q[(Head + i) mod Length(Q)];
  Q := N;
  Head := 0;
end;

procedure InitBudget;
var
  n: Integer;
begin
  n := StrToIntDef(GetEnvironmentVariable('PARC_THREADS'), 0);
  if n <= 0 then n := CpuCount;
  if n > 64 then n := 64;
  if n < 1 then n := 1;
  BTotal := n;
  BAvail := n - 1;      // la del hilo principal
  TokenHeld := True;    // (initialization corre en el hilo principal)
end;

{ TParallelJob }

constructor TParallelJob.Create;
begin
  inherited Create;
  FDone := RTLEventCreate;
end;

{ Si Run ya publicó el resultado pero no terminó de señalar el evento, espera esas dos
  instrucciones: después el hilo ya no toca el trabajo. }
procedure TParallelJob.WaitSignaled;
begin
  while InterlockedCompareExchange(FFinished, 1, 1) = 1 do ThreadSwitch;
end;

procedure TParallelJob.BeforeDestruction;
begin
  // Antes que cualquier destructor (de la subclase también): nada se libera con Run adentro
  WaitSignaled;
  inherited BeforeDestruction;
end;

destructor TParallelJob.Destroy;
begin
  {$IFDEF PARC_RACE_TEST}
  if InterlockedCompareExchange(FFinished, 1, 1) = 1 then InterlockedIncrement(RaceHits);
  {$ENDIF}
  RTLEventDestroy(FDone);
  inherited Destroy;
end;

procedure TParallelJob.ResetForReuse;
begin
  WaitSignaled;
  FErrClass := nil;
  FErrMsg := '';
  // Sin esto, WaitJob de un trabajo reusado (los de hashing de REP) volvía sin esperar
  InterlockedExchange(FFinished, 0);
  RTLEventResetEvent(FDone);
end;

procedure TParallelJob.Run;
begin
  try
    Process;
  except
    // Las excepciones no cruzan hilos: se guardan y se relanzan al entregar el bloque
    on E: Exception do
    begin
      FErrClass := ExceptClass(E.ClassType);
      FErrMsg := E.Message;
    end;
  end;
  InterlockedExchange(FFinished, 1);
  {$IFDEF PARC_RACE_TEST}
  if RaceSleepMs > 0 then Sleep(RaceSleepMs);   // ventana ampliada (tests/test_jobfree.lpr)
  {$ENDIF}
  RTLEventSetEvent(FDone);
  InterlockedExchange(FFinished, 2);   // desde acá el hilo ya no toca el trabajo
end;

{ TParallelWorker }

constructor TParallelWorker.Create(APool: TJobPool);
begin
  FPool := APool;
  FWaiter := Default(TBudgetWaiter);
  FreeOnTerminate := False;
  inherited Create(False);
end;

procedure TParallelWorker.Execute;
var
  Job: TParallelJob;
begin
  CurShare := FPool.FShare;
  while True do
  begin
    Job := FPool.TakeJob(Self);   // ya con ficha
    if Job = nil then Break;
    InterlockedIncrement(FPool.FRunning);
    try
      Job.Run;
    finally
      InterlockedDecrement(FPool.FRunning);
      BudgetRelease;
    end;
  end;
  BudgetLeave;
end;

var
  BudgetLock: TRTLCriticalSection;
  BudgetLimit: Int64 = -1;   // -1: todavía no calculado
  BudgetUsed: Int64 = 0;

function MemBudgetTryReserve(Bytes: Int64): Boolean;
var
  Ram: Int64;
begin
  EnterCriticalSection(BudgetLock);
  try
    if BudgetLimit < 0 then
    begin
      BudgetLimit := Int64(StrToIntDef(GetEnvironmentVariable('PARC_BUFMEM'), -1)) shl 20;
      if BudgetLimit < 0 then
      begin
        {$IFDEF CPU64}BudgetLimit := Int64(1) shl 30;{$ELSE}BudgetLimit := Int64(256) shl 20;{$ENDIF}
        Ram := PhysicalMemory;
        if (Ram > 0) and (Ram div 4 < BudgetLimit) then BudgetLimit := Ram div 4;
      end;
    end;
    Result := BudgetUsed + Bytes <= BudgetLimit;
    if Result then Inc(BudgetUsed, Bytes);
  finally
    LeaveCriticalSection(BudgetLock);
  end;
end;

procedure MemBudgetRelease(Bytes: Int64);
begin
  EnterCriticalSection(BudgetLock);
  Dec(BudgetUsed, Bytes);
  LeaveCriticalSection(BudgetLock);
end;

{ TJobPool }

constructor TJobPool.Create(MaxWorkers, MaxPending: Integer);
begin
  inherited Create;
  if MaxWorkers < 0 then MaxWorkers := 0;
  FMaxWorkers := MaxWorkers;
  if MaxPending < 1 then MaxPending := 1;
  SetLength(FPending, MaxPending);
  SetLength(FWorkers, FMaxWorkers);
  InitCriticalSection(FLock);
  FWork := RTLEventCreate;
end;

destructor TJobPool.Destroy;
var
  i, n: Integer;
  Had: Boolean;
begin
  // Parar el pool: los hilos terminan el trabajo que tengan y salen. Los que esperaban una
  // ficha para empezar uno nuevo dejan de esperarla
  Had := BudgetWaitBegin;
  try
    EnterCriticalSection(FLock);
    FStop := True;
    LeaveCriticalSection(FLock);
    for i := 0 to FNumWorkers - 1 do BudgetAbortWaiter(FWorkers[i].FWaiter);
    for i := 0 to FNumWorkers - 1 do
    begin
      n := 0;
      while not FWorkers[i].Finished do
      begin
        RTLEventSetEvent(FWork);
        // (si todavía está terminando un trabajo, p. ej. tras un error, sin ocupar un núcleo)
        if n < 64 then ThreadSwitch else Sleep(1);
        Inc(n);
      end;
      FWorkers[i].Free;   // ya terminó: Free solo hace el join
    end;
  finally
    BudgetWaitEnd(Had);
  end;
  RTLEventDestroy(FWork);
  DoneCriticalSection(FLock);
  inherited Destroy;
end;

procedure TJobPool.SetMaxWorkers(N: Integer);
begin
  if N <= FMaxWorkers then Exit;
  FMaxWorkers := N;
  SetLength(FWorkers, N);
end;

function TJobPool.CanGrow(Cap: Integer): Boolean;
begin
  if Cap > BTotal then Cap := BTotal;
  Result := (BTotal > 1) and (FMaxWorkers > 0) and (FMaxWorkers < Cap) and
    (InterlockedCompareExchange(FRunning, 0, 0) >= FMaxWorkers);
end;

function TJobPool.PendingCount: Integer;
begin
  EnterCriticalSection(FLock);
  Result := FPendCount;
  LeaveCriticalSection(FLock);
end;

procedure TJobPool.Submit(Job: TParallelJob);
begin
  EnterCriticalSection(FLock);
  if FPendCount >= Length(FPending) then GrowJobRing(FPending, FPendHead, FPendCount, 2 * Length(FPending));
  FPending[(FPendHead + FPendCount) mod Length(FPending)] := Job;
  Inc(FPendCount);
  LeaveCriticalSection(FLock);
  RTLEventSetEvent(FWork);
  // Un hilo más por trabajo pendiente, hasta el tope
  if FNumWorkers < FMaxWorkers then
  begin
    FWorkers[FNumWorkers] := TParallelWorker.Create(Self);
    Inc(FNumWorkers);
  end;
end;

{ En un hilo del pool: el próximo trabajo pendiente, con la ficha del presupuesto ya tomada, o
  nil si hay que salir (sin ficha). La ficha se pide antes de sacar el trabajo de la cola:
  mientras se espera, el que espera ese trabajo lo puede ejecutar él mismo. }
function TJobPool.TakeJob(W: TParallelWorker): TParallelJob;
var
  More, Has: Boolean;
begin
  while True do
  begin
    EnterCriticalSection(FLock);
    if FStop then
    begin
      LeaveCriticalSection(FLock);
      RTLEventSetEvent(FWork);   // que salga el próximo también
      Exit(nil);
    end;
    Has := FPendCount > 0;
    LeaveCriticalSection(FLock);
    if not Has then
    begin
      RTLEventWaitFor(FWork, 50);
      Continue;
    end;
    if not AcquireWith(W.FWaiter, False) then Continue;   // abortado: el próximo ciclo ve FStop
    EnterCriticalSection(FLock);
    if not FStop and (FPendCount > 0) then
    begin
      Result := FPending[FPendHead];
      FPending[FPendHead] := nil;
      FPendHead := (FPendHead + 1) mod Length(FPending);
      Dec(FPendCount);
      More := FPendCount > 0;
      LeaveCriticalSection(FLock);
      if More then RTLEventSetEvent(FWork);   // el evento se resetea solo: despertar a otro
      Exit;
    end;
    LeaveCriticalSection(FLock);
    BudgetRelease;   // se lo llevó otro (o el pool se cierra)
  end;
end;

{ Si Job sigue en la cola (ningún hilo lo tomó), lo saca: lo va a ejecutar el que espera. }
function TJobPool.TakeIfPending(Job: TParallelJob): Boolean;
var
  i, k, n: Integer;
begin
  Result := False;
  EnterCriticalSection(FLock);
  n := Length(FPending);
  for i := 0 to FPendCount - 1 do
    if FPending[(FPendHead + i) mod n] = Job then
    begin
      // cerrar el hueco corriendo los siguientes uno hacia atrás
      for k := i to FPendCount - 2 do
        FPending[(FPendHead + k) mod n] := FPending[(FPendHead + k + 1) mod n];
      FPending[(FPendHead + FPendCount - 1) mod n] := nil;
      Dec(FPendCount);
      Result := True;
      Break;
    end;
  LeaveCriticalSection(FLock);
end;

procedure TJobPool.RunInline(Job: TParallelJob);
var
  Had, OldShare: Integer;
begin
  // En este hilo, con su ficha (o con una prestada si no tenía: pool sin hilos)
  Had := Ord(TokenHeld);
  if Had = 0 then BudgetAcquire(True);
  OldShare := CurShare;
  if FShare > 0 then CurShare := FShare;
  try
    Job.Run;
  finally
    CurShare := OldShare;
    if Had = 0 then BudgetRelease;
  end;
end;

{ Espera (como mucho Ms; WAIT_FOREVER = hasta que termine) a que Job termine; True si terminó.
  Si nadie lo empezó y este hilo tiene ficha (o el pool no tiene hilos), lo ejecuta acá. }
function TJobPool.WaitDone(Job: TParallelJob; Ms: Cardinal): Boolean;
var
  Had: Boolean;
begin
  if Job.FFinished <> 0 then Exit(True);
  if (TokenHeld or (FMaxWorkers = 0)) and TakeIfPending(Job) then
  begin
    RunInline(Job);
    Exit(True);
  end;
  Had := BudgetWaitBegin;
  try
    if Ms = WAIT_FOREVER then
      while Job.FFinished = 0 do RTLEventWaitFor(Job.FDone)
    else if Job.FFinished = 0 then
      RTLEventWaitFor(Job.FDone, Ms);
  finally
    BudgetWaitEnd(Had);
  end;
  Result := Job.FFinished <> 0;
end;

procedure TJobPool.WaitJob(Job: TParallelJob);
begin
  WaitDone(Job, WAIT_FOREVER);
  if Job.FErrClass <> nil then raise Job.FErrClass.Create(Job.FErrMsg);
end;

function TJobPool.WaitJobFor(Job: TParallelJob; Ms: Cardinal): Boolean;
begin
  Result := WaitDone(Job, Ms);
  if Result and (Job.FErrClass <> nil) then raise Job.FErrClass.Create(Job.FErrMsg);
end;

procedure TJobPool.WaitJobQuiet(Job: TParallelJob);
begin
  WaitDone(Job, WAIT_FOREVER);
end;

{ TParallelBlockStage }

constructor TParallelBlockStage.Create(ASource: TInStage; MaxThreads, ExtraJobs: Integer);
var
  Threads, w: Integer;
begin
  inherited Create(ASource);
  FCap := MaxThreads;
  FExtra := ExtraJobs;
  Threads := PoolWorkers(MaxThreads);
  w := Threads;
  if w < 1 then w := 1;
  if ExtraJobs > w then ExtraJobs := w;
  FMaxJobs := w + ExtraJobs;
  if FMaxJobs < 2 then FMaxJobs := 2;
  SetLength(FQueue, FMaxJobs);
  FPool := TJobPool.Create(Threads, FMaxJobs);
end;

destructor TParallelBlockStage.Destroy;
var
  i: Integer;
begin
  FPool.Free;   // espera a los hilos antes de liberar los trabajos
  FCur.Free;
  for i := 0 to FCount - 1 do FQueue[(FHead + i) mod FMaxJobs].Free;
  inherited Destroy;
end;

procedure TParallelBlockStage.ReleaseJob(Job: TParallelJob);
begin
  Job.Free;
end;

procedure TParallelBlockStage.FillQueue;
var
  Job: TParallelJob;
  w, e: Integer;
begin
  while not FSourceEof do
  begin
    if FCount >= FMaxJobs then
    begin
      // Lleno: si todos los hilos están trabajando, uno más (este hilo va a esperar)
      if FPool.CanGrow(FCap) then
      begin
        w := FPool.MaxWorkers + 1;
        e := FExtra;
        if e > w then e := w;
        if w + e > FMaxJobs then
        begin
          GrowJobRing(FQueue, FHead, FCount, w + e);
          FMaxJobs := w + e;
        end;
        FPool.SetMaxWorkers(w);
      end
      else
        Break;
    end;
    Job := ReadJob;
    if Job = nil then
    begin
      FSourceEof := True;
      Break;
    end;
    FQueue[(FHead + FCount) mod FMaxJobs] := Job;
    Inc(FCount);
    FPool.Submit(Job);
  end;
end;

function TParallelBlockStage.Read(Buf: PByte; Count: SizeInt): SizeInt;
begin
  if FErrClass <> nil then raise FErrClass.Create(FErrMsg);
  while (FCur = nil) or (FPos >= FCur.OutSize) do
  begin
    if FCur <> nil then
    begin
      ReleaseJob(FCur);
      FCur := nil;
    end;
    if FEof then Exit(0);
    try
      FillQueue;
      if FCount = 0 then
      begin
        FEof := True;
        Exit(0);
      end;
      FCur := FQueue[FHead];
      FQueue[FHead] := nil;
      FHead := (FHead + 1) mod FMaxJobs;
      Dec(FCount);
      FPool.WaitJobQuiet(FCur);
      FPos := 0;
      if FCur.FErrClass <> nil then
      begin
        FErrClass := FCur.FErrClass;
        FErrMsg := FCur.FErrMsg;
        FreeAndNil(FCur);
        raise FErrClass.Create(FErrMsg);
      end;
      FillQueue;   // reponer la cola mientras se entrega este bloque
    except
      on E: Exception do
      begin
        if FErrClass = nil then
        begin
          FErrClass := ExceptClass(E.ClassType);
          FErrMsg := E.Message;
        end;
        raise;
      end;
    end;
  end;
  Result := FCur.OutSize - FPos;
  if Result > Count then Result := Count;
  Move(FCur.OutBuf[FPos], Buf^, Result);
  Inc(FPos, Result);
end;

initialization
  InitCriticalSection(BudgetLock);
  InitCriticalSection(BLock);
  InitBudget;
finalization
  DoneCriticalSection(BLock);
  DoneCriticalSection(BudgetLock);
end.
