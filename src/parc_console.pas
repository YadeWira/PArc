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
procedure CmdList(A: TArchive; const Sel: array of Boolean);
{ v: listado detallado (fecha con ns, atributos, tamaño, parte comprimida, ratio, CRC, bloque,
  método). Sel vacío = todo. }
procedure CmdListVerbose(A: TArchive; const Sel: array of Boolean);

var
  { --verbose: una línea por archivo ("OK ..." al probar, "Extracted ..." al extraer). Sin él,
    como FreeArc, solo el progreso, los errores y el resumen. }
  ListFiles: Boolean = False;

{ 1865122242 -> '1,865,122,242' (como FreeArc). }
function Num(n: Int64): string;
{ '1 file', '155 files' (Word en singular; plural con 's'). }
function Count(n: Int64; const Word: string): string;
{ S con un color ANSI (Code: '1' negrita, '32' verde, '31' rojo, '2' tenue...) si hay colores. }
function Paint(const S, Code: string): string;
{ "<What> time: cpu 8.47 s / real 3.14 s = 270% · speed 594.4 MB/s" (FreeArc + toques). }
procedure PrintTimes(const What: string; T0, T1: QWord; Cpu0, Cpu1, Bytes: Int64);
{ "All OK" en verde, o los errores en rojo. }
procedure PrintResult(Errors: Integer);

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

{ Barra de Width celdas con octavos de celda (█▉▊▋▌▍▎▏). En Windows la consola sin fuente
  TrueType (Win7 por defecto: fuentes de mapa de bits) no tiene esos glifos: ahí, '#' y '-'. }
function Bar(Frac: Double; Width: Integer): string;
const
  Eighths: array[1..7] of string = ('▏', '▎', '▍', '▌', '▋', '▊', '▉');
var
  n, Full, Part, i: Integer;
begin
  if Frac < 0 then Frac := 0;
  if Frac > 1 then Frac := 1;
  n := Round(Frac * Width * 8);
  Full := n div 8;
  Part := n mod 8;
  Result := '';
  if not UseColors then
  begin
    // sin VT (Win7, redirigido...): ASCII puro
    for i := 1 to Width do
      if i <= Full then Result := Result + '#' else Result := Result + '-';
    Exit('[' + Result + ']');
  end;
  for i := 1 to Full do Result := Result + '█';
  if Full < Width then
  begin
    if Part > 0 then Result := Result + Eighths[Part] else Result := Result + ' ';
    for i := Full + 2 to Width do Result := Result + ' ';
  end;
  Result := #27'[36m' + Result + #27'[0m' + '▕';
  Result := '▕' + Result;
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
    L := L + ' ' + Bar(P.Done / P.Total, 20) +
         Format(' %5.1f%%  %s/%s MB', [100.0 * P.Done / P.Total, FmtMB(P.Done), FmtMB(P.Total)])
  else
    L := L + '  ' + FmtMB(P.Done) + ' MB';
  Rate := '';
  if P.ElapsedMs > 0 then
  begin
    Speed := P.Done / (P.ElapsedMs / 1000);   // bytes/s
    Rate := '  ' + FormatFloat('0.0', Speed / 1048576) + ' MB/s';
    if (Speed > 0) and (P.Total > P.Done) and (P.ElapsedMs >= 1000) then
      Rate := Rate + '  ' + 'ETA ' + FmtSecs(Round((P.Total - P.Done) / Speed));
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

procedure CmdList(A: TArchive; const Sel: array of Boolean);
var
  i, n: Integer;
  TotalSize, TotalComp: Int64;
  Kind: string;
  Ratio: string;
  All: Boolean;
begin
  // Sel vacío = todo; si no, solo lo elegido (patrones, -n, -x, -sm..., -ap)
  All := Length(Sel) = 0;
  TotalSize := 0;
  n := 0;
  for i := 0 to High(A.Files) do
    if All or Sel[i] then
    begin
      Inc(TotalSize, A.Files[i].Size);
      Inc(n);
    end;
  TotalComp := 0;
  for i := 0 to High(A.DataBlocks) do Inc(TotalComp, A.DataBlocks[i].CompSize);
  Ratio := '';
  // En archivos diminutos los encabezados dominan y el ratio no significa nada.
  if All and (TotalSize >= 64 * 1024) then
    Ratio := Format('   ratio: %.1f%%', [100.0 * TotalComp / TotalSize]);
  OutLn('Archive: ' + A.FileName);
  if All then
    OutLn(Format('  %d file(s)   size: %s   packed: %s%s',
      [Length(A.Files), FmtSize(TotalSize), FmtSize(TotalComp), Ratio]))
  else
    OutLn(Format('  %d of %d file(s) selected   size: %s',
      [n, Length(A.Files), FmtSize(TotalSize)]));
  OutLn('');
  OutLn('  Modified             Size  CRC       Name');
  OutLn('  -------------------  ----  --------  ----');
  for i := 0 to High(A.Files) do
    if All or Sel[i] then
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

{ Permisos Unix (rwxr-xr-x, con d/l delante) o atributos de Windows (RHSA); '-' si no hay. }
function AttrText(const F: TArcFileEntry): string;
const
  RWX = 'rwxrwxrwx';
var
  i: Integer;
begin
  if F.HasUnixMode then
  begin
    if F.IsLink then Result := 'l' else if F.IsDir then Result := 'd' else Result := '-';
    for i := 0 to 8 do
      if (F.UnixMode and (1 shl (8 - i))) <> 0 then Result := Result + RWX[i + 1] else Result := Result + '-';
  end
  else if F.HasWinAttr then
  begin
    Result := '';
    if (F.WinAttr and $01) <> 0 then Result := Result + 'R' else Result := Result + '.';
    if (F.WinAttr and $02) <> 0 then Result := Result + 'H' else Result := Result + '.';
    if (F.WinAttr and $04) <> 0 then Result := Result + 'S' else Result := Result + '.';
    if (F.WinAttr and $10) <> 0 then Result := Result + 'D' else Result := Result + '.';
    if (F.WinAttr and $20) <> 0 then Result := Result + 'A' else Result := Result + '.';
  end
  else if F.IsDir then Result := 'd'
  else Result := '-';
end;

procedure CmdListVerbose(A: TArchive; const Sel: array of Boolean);
var
  i, n: Integer;
  PackedB, TotalSize, TotalPacked, Ns: Int64;
  B: TArcBlock;
  Ratio, Meth, Kind: string;
begin
  OutLn('Archive: ' + A.FileName);
  OutLn(Format('  %d file(s) in %d data block(s)%s%s', [Length(A.Files), Length(A.DataBlocks),
    BoolToStr(A.Locked, ', locked', ''), BoolToStr(A.Recovery <> '', ', recovery record ' + A.Recovery, '')]));
  OutLn('');
  OutLn('  Modified (UTC)                 Attributes            Size        Packed  Ratio  CRC       Blk  Method / Name');
  n := 0;
  TotalSize := 0; TotalPacked := 0;
  for i := 0 to High(A.Files) do
  begin
    if (Length(Sel) > 0) and not Sel[i] then Continue;
    Inc(n);
    with A.Files[i] do
    begin
      if HasMTimeNs then Ns := MTimeNs else Ns := Time * 1000000000;
      PackedB := 0;
      Meth := '';
      if not IsDir and not IsLink and (DataBlock >= 0) and (DataBlock <= High(A.DataBlocks)) then
      begin
        B := A.DataBlocks[DataBlock];
        if B.OrigSize > 0 then PackedB := Round(B.CompSize * (Size / B.OrigSize));
        Meth := B.Method;
      end;
      if IsDir then Kind := '<DIR>' else if IsLink then Kind := '<LINK>' else Kind := IntToStr(Size);
      if (Size > 0) and not IsDir then Ratio := Format('%5.1f%%', [100.0 * PackedB / Size]) else Ratio := '     -';
      Inc(TotalSize, Size);
      Inc(TotalPacked, PackedB);
      OutLn(Format('  %s.%.9d  %-10s  %14s  %12s %s  %.8x  %3s  %s',
        [FmtTime(Ns div 1000000000), ((Ns mod 1000000000) + 1000000000) mod 1000000000, AttrText(A.Files[i]),
         Kind, IntToStr(PackedB), Ratio, Crc, BoolToStr(Meth <> '', IntToStr(DataBlock), '-'),
         BoolToStr(Meth <> '', Meth, '')]));
      if IsLink then OutLn('      ' + Name + ' -> ' + LinkTarget) else OutLn('      ' + Name);
    end;
  end;
  OutLn('');
  if TotalSize > 0 then Ratio := Format(' · ratio %.1f%%', [100.0 * TotalPacked / TotalSize]) else Ratio := '';
  OutLn(Format('%d file(s), %s bytes => %s bytes%s', [n, Num(TotalSize), Num(TotalPacked), Ratio]));
  if A.Comment <> '' then OutLn('Comment: ' + A.Comment);
end;

procedure LogLine(const Msg: string);
begin
  if not ListFiles and ((Copy(Msg, 1, 9) = 'OK       ') or (Copy(Msg, 1, 10) = 'Extracted ')) then Exit;
  ClearProgress;
  if Copy(Msg, 1, 5) = 'ERROR' then OutLn(Paint(Msg, '31'))
  else if Copy(Msg, 1, 9) = 'CRC ERROR' then OutLn(Paint(Msg, '31'))
  else if Copy(Msg, 1, 8) = 'Warning:' then OutLn(Paint(Msg, '33'))
  else OutLn(Msg);
end;

function Num(n: Int64): string;
var
  i: Integer;
begin
  Result := IntToStr(Abs(n));
  i := Length(Result) - 2;
  while i > 1 do
  begin
    Insert(',', Result, i);
    Dec(i, 3);
  end;
  if n < 0 then Result := '-' + Result;
end;

function Count(n: Int64; const Word: string): string;
begin
  Result := Num(n) + ' ' + Word;
  if n <> 1 then Result := Result + 's';
end;

function Paint(const S, Code: string): string;
begin
  if UseColors then Result := #27'[' + Code + 'm' + S + #27'[0m' else Result := S;
end;

procedure PrintTimes(const What: string; T0, T1: QWord; Cpu0, Cpu1, Bytes: Int64);
var
  Real, Cpu: Double;
  L: string;
begin
  Real := (T1 - T0) / 1000.0;
  Cpu := (Cpu1 - Cpu0) / 1000.0;
  L := Format('%s time: cpu %.2f s / real %.2f s', [What, Cpu, Real]);
  if Real > 0 then
  begin
    L := L + Format(' = %d%%', [Round(100 * Cpu / Real)]);
    if Bytes > 0 then
      L := L + ' · speed ' + Paint(Format('%.1f MB/s', [Bytes / Real / 1048576.0]), '1');
  end;
  OutLn(L);
end;

procedure PrintResult(Errors: Integer);
begin
  if Errors = 0 then OutLn(Paint('All OK', '1;32'))
  else OutLn(Paint(Format('Errors: %d', [Errors]), '1;31'));
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
