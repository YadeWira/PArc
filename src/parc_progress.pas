{ Progreso y cancelación, sin nada de interfaz: la CLI
  instalan un ProgressHandler que dibuja, y piden cancelar con RequestCancel.
  Extracción y escritura llaman a ProgressAdd por cada trozo procesado (~1 MB); ahí se
  comprueba la cancelación, que lanza EOperationCancelled. El llamado al handler se limita a
  uno cada PROGRESS_INTERVAL ms, así que ProgressAdd es barato. Un solo hilo reporta progreso
  (el que llama a WriteArchive/ExtractArchive); RequestCancel se puede llamar desde cualquiera.
  Los codificadores largos (lzma, dict) y TOutStage.Emit también llaman a CheckCancel, en hilos
  del pool incluidos; lo que no se corta es un bloque de grzip ya en vuelo (≤ ~1 s). }
unit parc_progress;

{$mode objfpc}{$H+}

interface

uses
  SysUtils;

type
  EOperationCancelled = class(Exception);

  TProgressInfo = record
    Phase: string;        // 'Comprimiendo', 'Extrayendo', 'Verificando'
    Done, Total: Int64;   // bytes procesados / a procesar (Total = 0: no se sabe)
    CurrentFile: string;
    ElapsedMs: QWord;
    Finished: Boolean;    // último llamado de la fase (para cerrar la línea)
  end;

  TProgressProc = procedure(const P: TProgressInfo);

const
  PROGRESS_INTERVAL = 100;

var
  ProgressHandler: TProgressProc = nil;

procedure ProgressBegin(const Phase: string; Total: Int64);
procedure ProgressFile(const Name: string);
procedure ProgressAdd(Bytes: Int64);   // también comprueba la cancelación
procedure ProgressEnd;

procedure RequestCancel;
procedure ResetCancel;                 // antes de otra operación en el mismo proceso (GUI)
function CancelRequested: Boolean;
procedure CheckCancel;                 // lanza EOperationCancelled si se pidió

implementation

var
  Info: TProgressInfo;
  StartTick, LastTick: QWord;
  Active: Boolean;
  Cancelled: LongInt = 0;

procedure Report(Force: Boolean);
var
  Now: QWord;
begin
  if not Active or (ProgressHandler = nil) then Exit;
  Now := GetTickCount64;
  if not Force and (Now - LastTick < PROGRESS_INTERVAL) then Exit;
  LastTick := Now;
  Info.ElapsedMs := Now - StartTick;
  ProgressHandler(Info);
end;

procedure ProgressBegin(const Phase: string; Total: Int64);
begin
  Info := Default(TProgressInfo);
  Info.Phase := Phase;
  Info.Total := Total;
  StartTick := GetTickCount64;
  LastTick := StartTick;   // el primer dibujo, recién a los PROGRESS_INTERVAL ms
  Active := True;
end;

procedure ProgressFile(const Name: string);
begin
  Info.CurrentFile := Name;
  CheckCancel;
  Report(False);
end;

procedure ProgressAdd(Bytes: Int64);
begin
  Inc(Info.Done, Bytes);
  CheckCancel;
  Report(False);
end;

procedure ProgressEnd;
begin
  if not Active then Exit;
  Info.Finished := True;
  Report(True);
  Active := False;
end;

procedure RequestCancel;
begin
  InterlockedExchange(Cancelled, 1);
end;

procedure ResetCancel;
begin
  InterlockedExchange(Cancelled, 0);
end;

function CancelRequested: Boolean;
begin
  Result := Cancelled <> 0;
end;

procedure CheckCancel;
begin
  if Cancelled <> 0 then raise EOperationCancelled.Create('cancelado por el usuario');
end;

end.
