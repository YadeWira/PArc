{ Decodificación de bloques independientes en paralelo, con la salida en orden (como el
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
  { Un trabajo: la subclase lo carga y lo procesa en Process (en un hilo del pool), que deja el
    resultado en OutBuf[0..OutSize). }
  TParallelJob = class
  private
    FDone: PRTLEvent;
    FErrClass: ExceptClass;
    FErrMsg: string;
    procedure Run;
  public
    OutBuf: TBytes;
    OutSize: SizeInt;
    constructor Create;
    destructor Destroy; override;
    procedure Process; virtual; abstract;
  end;

  TJobPool = class;

  TParallelWorker = class(TThread)
  private
    FPool: TJobPool;
  public
    constructor Create(APool: TJobPool);
    procedure Execute; override;
  end;

  { Pool de hilos: Submit encola un trabajo; WaitJob espera que termine y relanza su error. Los
    hilos se crean a demanda, hasta MaxWorkers. }
  TJobPool = class
  private
    FPending: array of TParallelJob;  // trabajos todavía no tomados por un hilo (anillo)
    FPendHead, FPendCount: Integer;
    FLock: TRTLCriticalSection;
    FWork: PRTLEvent;
    FStop: Boolean;
    FWorkers: array of TParallelWorker;
    FNumWorkers, FMaxWorkers: Integer;
    function TakeJob: TParallelJob;
  public
    constructor Create(MaxWorkers, MaxPending: Integer);
    destructor Destroy; override;   // espera que los hilos terminen su trabajo actual
    procedure Submit(Job: TParallelJob);
    procedure WaitJob(Job: TParallelJob);   // relanza la excepción del trabajo, si la hubo
    property MaxWorkers: Integer read FMaxWorkers;
  end;


  TParallelBlockStage = class(TInStage)
  private
    FQueue: array of TParallelJob;    // FIFO de bloques en vuelo, en orden de stream
    FHead, FCount, FMaxJobs: Integer;
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
  public
    { MaxThreads: tope por defecto (PARC_THREADS lo reemplaza); ExtraJobs: bloques leídos por
      adelantado además de uno por hilo. }
    constructor Create(ASource: TInStage; MaxThreads, ExtraJobs: Integer);
    destructor Destroy; override;
    function Read(Buf: PByte; Count: SizeInt): SizeInt; override;
  end;

{ Hilos a usar: PARC_THREADS si está definido; si no, los núcleos, hasta Cap. }
function ThreadCount(Cap: Integer): Integer;

implementation

uses
  parc_os;

{ TParallelJob }

constructor TParallelJob.Create;
begin
  inherited Create;
  FDone := RTLEventCreate;
end;

destructor TParallelJob.Destroy;
begin
  RTLEventDestroy(FDone);
  inherited Destroy;
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
  RTLEventSetEvent(FDone);
end;

{ TParallelWorker }

constructor TParallelWorker.Create(APool: TJobPool);
begin
  FPool := APool;
  FreeOnTerminate := False;
  inherited Create(False);
end;

procedure TParallelWorker.Execute;
var
  Job: TParallelJob;
begin
  while True do
  begin
    Job := FPool.TakeJob;
    if Job = nil then Break;
    Job.Run;
  end;
end;

function ThreadCount(Cap: Integer): Integer;
begin
  Result := StrToIntDef(GetEnvironmentVariable('PARC_THREADS'), 0);
  if Result <= 0 then
  begin
    Result := CpuCount;
    if Result > Cap then Result := Cap;
  end;
  if Result > 64 then Result := 64;
  if Result < 1 then Result := 1;
end;

{ TJobPool }

constructor TJobPool.Create(MaxWorkers, MaxPending: Integer);
begin
  inherited Create;
  FMaxWorkers := MaxWorkers;
  if MaxPending < 1 then MaxPending := 1;
  SetLength(FPending, MaxPending);
  SetLength(FWorkers, FMaxWorkers);
  InitCriticalSection(FLock);
  FWork := RTLEventCreate;
end;

destructor TJobPool.Destroy;
var
  i: Integer;
begin
  // Parar el pool: los hilos terminan el trabajo que tengan y salen
  EnterCriticalSection(FLock);
  FStop := True;
  LeaveCriticalSection(FLock);
  for i := 0 to FNumWorkers - 1 do
  begin
    while not FWorkers[i].Finished do
    begin
      RTLEventSetEvent(FWork);
      ThreadSwitch;
    end;
    FWorkers[i].Free;   // ya terminó: Free solo hace el join
  end;
  RTLEventDestroy(FWork);
  DoneCriticalSection(FLock);
  inherited Destroy;
end;

procedure TJobPool.Submit(Job: TParallelJob);
begin
  EnterCriticalSection(FLock);
  if FPendCount >= Length(FPending) then SetLength(FPending, 2 * Length(FPending));
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

{ En un hilo del pool: el próximo trabajo pendiente, o nil si hay que salir. }
function TJobPool.TakeJob: TParallelJob;
var
  More: Boolean;
begin
  while True do
  begin
    EnterCriticalSection(FLock);
    if FStop then
    begin
      LeaveCriticalSection(FLock);
      Exit(nil);
    end;
    if FPendCount > 0 then
    begin
      Result := FPending[FPendHead];
      FPendHead := (FPendHead + 1) mod Length(FPending);
      Dec(FPendCount);
      More := FPendCount > 0;
      LeaveCriticalSection(FLock);
      if More then RTLEventSetEvent(FWork);   // el evento se resetea solo: despertar a otro
      Exit;
    end;
    LeaveCriticalSection(FLock);
    RTLEventWaitFor(FWork, 50);
  end;
end;

procedure TJobPool.WaitJob(Job: TParallelJob);
begin
  RTLEventWaitFor(Job.FDone);
  if Job.FErrClass <> nil then raise Job.FErrClass.Create(Job.FErrMsg);
end;

{ TParallelBlockStage }

constructor TParallelBlockStage.Create(ASource: TInStage; MaxThreads, ExtraJobs: Integer);
var
  Threads: Integer;
begin
  inherited Create(ASource);
  Threads := ThreadCount(MaxThreads);
  FMaxJobs := Threads + ExtraJobs;
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

procedure TParallelBlockStage.FillQueue;
var
  Job: TParallelJob;
begin
  while not FSourceEof and (FCount < FMaxJobs) do
  begin
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
    FreeAndNil(FCur);
    if FEof then Exit(0);
    try
      FillQueue;
      if FCount = 0 then
      begin
        FEof := True;
        Exit(0);
      end;
      FCur := FQueue[FHead];
      FHead := (FHead + 1) mod FMaxJobs;
      Dec(FCount);
      RTLEventWaitFor(FCur.FDone);
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

end.
