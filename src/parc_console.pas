{ Lo de consola de parc: la línea de progreso, el listado, la pregunta antes de
  sobrescribir y, en Windows, la pausa final cuando el programa abrió su propia ventana. }
unit parc_console;

{$mode objfpc}{$H+}

interface

uses
  SysUtils, DateUtils, parc_os, parc_archive, parc_extract, parc_progress;

const
  EXIT_CANCELLED = 130;   // como un proceso cortado por SIGINT (128 + 2)
  EXIT_WARNINGS = 6;    // terminó, pero algunos archivos no se pudieron leer

procedure ClearProgress;
procedure DrawProgress(const P: TProgressInfo);
procedure LogLine(const Msg: string);
procedure OnCtrlC;
function FmtTime(t: Int64): string;
procedure CmdList(A: TArchive);

{ Pregunta por consola si se sobrescribe Name: [s]í, [n]o, [t]odos, n[i]nguno. Sin consola en
  la entrada, no. }
function AskOverwriteConsole(const Name: string): TOverwriteAnswer;

{ En Windows, si el proceso es el único de su consola (se abrió con doble clic), espera Enter
  antes de salir para que se vea el resultado. En los demás casos no hace nada. }
procedure PauseIfOwnConsole;

implementation

{$IFDEF WINDOWS}
uses
  Windows;

function GetConsoleProcessList(lpdwProcessList: PDWORD; dwProcessCount: DWORD): DWORD;
  stdcall; external 'kernel32.dll';
{$ENDIF}

var
  ProgressShown: Boolean = False;   // hay una línea de progreso dibujada en stderr

procedure ClearProgress;
begin
  if not ProgressShown then Exit;
  ErrWrite(#13 + StringOfChar(' ', ConsoleWidth - 1) + #13);
  ProgressShown := False;
end;

{ Caracteres que ocupa en pantalla un texto UTF-8 (sin contar bytes de continuación). }
function DisplayLen(const S: string): Integer;
var
  i: Integer;
begin
  Result := 0;
  for i := 1 to Length(S) do
    if (Ord(S[i]) and $C0) <> $80 then Inc(Result);
end;

{ Los últimos Max caracteres de S (el final de una ruta es lo que la identifica). }
function TailChars(const S: string; Max: Integer): string;
var
  i, n: Integer;
begin
  if Max <= 0 then Exit('');
  if DisplayLen(S) <= Max then Exit(S);
  n := 0;
  i := Length(S) + 1;
  while (i > 1) and (n < Max - 1) do
  begin
    Dec(i);
    if (Ord(S[i]) and $C0) <> $80 then Inc(n);
  end;
  Result := '…' + Copy(S, i, MaxInt);
end;

function FmtMB(Bytes: Int64): string;
begin
  Result := FormatFloat('0.0', Bytes / 1048576);
end;

function FmtSecs(Secs: Int64): string;
begin
  if Secs >= 3600 then Result := Format('%d:%.2d:%.2d', [Secs div 3600, (Secs div 60) mod 60, Secs mod 60])
  else Result := Format('%.2d:%.2d', [Secs div 60, Secs mod 60]);
end;

{ Una línea en stderr que se reescribe: fase, %, MB, velocidad, tiempo restante y archivo. }
procedure DrawProgress(const P: TProgressInfo);
var
  L, Rate: string;
  Width: Integer;
  Speed: Double;
begin
  if P.Finished then
  begin
    ClearProgress;
    Exit;
  end;
  L := P.Phase;
  if P.Total > 0 then
    L := L + Format(' %5.1f%%  %s/%s MB', [100.0 * P.Done / P.Total, FmtMB(P.Done), FmtMB(P.Total)])
  else
    L := L + '  ' + FmtMB(P.Done) + ' MB';
  Rate := '';
  if P.ElapsedMs > 0 then
  begin
    Speed := P.Done / (P.ElapsedMs / 1000);   // bytes/s
    Rate := '  ' + FormatFloat('0.0', Speed / 1048576) + ' MB/s';
    if (Speed > 0) and (P.Total > P.Done) and (P.ElapsedMs >= 1000) then
      Rate := Rate + '  ' + FmtSecs(Round((P.Total - P.Done) / Speed)) + ' restante';
  end;
  L := L + Rate;
  Width := ConsoleWidth - 1;
  if P.CurrentFile <> '' then L := L + '  ' + TailChars(P.CurrentFile, Width - DisplayLen(L) - 2);
  if DisplayLen(L) > Width then L := Copy(L, 1, Width);
  ErrWrite(#13 + L + StringOfChar(' ', Width - DisplayLen(L)));
  ProgressShown := True;
end;

procedure OnCtrlC;
begin
  RequestCancel;
end;

function FmtTime(t: Int64): string;
begin
  Result := FormatDateTime('yyyy-mm-dd hh:nn:ss', UnixToDateTime(t, True));
end;

function FmtSize(Bytes: Int64): string;
begin
  if Bytes >= Int64(1) shl 30 then
    Result := FormatFloat('0.0', Bytes / (Int64(1) shl 30)) + ' GB'
  else if Bytes >= Int64(1) shl 20 then
    Result := FormatFloat('0.0', Bytes / (Int64(1) shl 20)) + ' MB'
  else if Bytes >= 1024 then
    Result := FormatFloat('0.0', Bytes / 1024) + ' KB'
  else
    Result := IntToStr(Bytes) + ' B';
end;

procedure CmdList(A: TArchive);
var
  i: Integer;
  TotalSize, TotalComp: Int64;
  Kind: string;
  Ratio: string;
begin
  TotalSize := 0;
  for i := 0 to High(A.Files) do Inc(TotalSize, A.Files[i].Size);
  TotalComp := 0;
  for i := 0 to High(A.DataBlocks) do Inc(TotalComp, A.DataBlocks[i].CompSize);
  Ratio := '';
  // En archivos diminutos los encabezados dominan y el ratio no significa nada.
  if TotalSize >= 64 * 1024 then
    Ratio := Format('   ratio: %.1f%%', [100.0 * TotalComp / TotalSize]);
  OutLn('Archive: ' + A.FileName);
  OutLn(Format('  %d file(s)   size: %s   packed: %s%s',
    [Length(A.Files), FmtSize(TotalSize), FmtSize(TotalComp), Ratio]));
  OutLn('');
  OutLn('  Modified             Size  CRC       Name');
  OutLn('  -------------------  ----  --------  ----');
  for i := 0 to High(A.Files) do
    with A.Files[i] do
    begin
      if IsDir then Kind := '<DIR>' else if IsLink then Kind := '<LINK>' else Kind := IntToStr(Size);
      if IsLink then
        OutLn(Format('  %s  %14s  %.8x  %s -> %s', [FmtTime(Time), Kind, Crc, Name, LinkTarget]))
      else
        OutLn(Format('  %s  %14s  %.8x  %s', [FmtTime(Time), Kind, Crc, Name]));
    end;
  OutLn('  -------------------  ----  --------  ----');
  if A.Comment <> '' then OutLn('Comment: ' + A.Comment);
end;

procedure LogLine(const Msg: string);
begin
  ClearProgress;
  OutLn(Msg);
end;


function AskOverwriteConsole(const Name: string): TOverwriteAnswer;
var
  L: string;
begin
  Result := oaNo;
  if not InIsConsole then Exit;
  ClearProgress;
  repeat
    OutLn('Already exists: ' + Name);
    ErrWrite('Overwrite? [y]es, [n]o, [a]ll, n[o]ne: ');
    L := '';
    if EOF(Input) then Exit;
    ReadLn(L);
    L := LowerCase(Trim(L));
    if (L = 'y') or (L = 'yes') or (L = 's') or (L = 'si') then Exit(oaYes);
    if (L = 'n') or (L = 'no') then Exit(oaNo);
    if (L = 'a') or (L = 'all') or (L = 't') then Exit(oaAll);
    if (L = 'o') or (L = 'none') or (L = 'i') then Exit(oaNone);
  until False;
end;

procedure PauseIfOwnConsole;
{$IFDEF WINDOWS}
var
  Pids: array[0..1] of DWORD;
  L: string;
begin
  if (GetConsoleProcessList(@Pids[0], 2) = 1) and InIsConsole then
  begin
    ErrWrite('Press Enter to close...');
    ReadLn(L);
  end;
end;
{$ELSE}
begin
end;
{$ENDIF}

end.
