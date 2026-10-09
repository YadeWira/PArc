{ Diferencias entre plataformas: argumentos y salida de consola en UTF-8.
  En Windows, ParamStr pasa por la página de códigos ANSI y pierde los nombres Unicode, y
  WriteFile de UTF-8 a la consola con CP 65001 falla en Win7; por eso usamos las APIs W. }
unit parc_os;

{$mode objfpc}{$H+}

interface

function ArgCount: Integer;
function Arg(i: Integer): string;          // UTF-8; Arg(0) = ejecutable
procedure OutLn(const S: string = '');      // S en UTF-8
procedure ErrLn(const S: string);

var
  { stdout lleva datos (-so, o el archivo con "-"): los mensajes de OutLn van a stderr. }
  OutToStderr: Boolean = False;

{ Se borra al terminar el programa (también con Halt o Ctrl-C). }
procedure RegisterTempFile(const Path: string);
{ Copia toda la entrada estándar a Path (binario). Devuelve los bytes copiados. }
function StdinToFile(const Path: string): Int64;
{ Copia Path a la salida estándar (binario). }
procedure FileToStdout(const Path: string);
{ El handle de la salida estándar (para escribir datos binarios en ella). }
function StdoutHandle: THandle;
{ Escribe en stderr sin salto de línea (la línea de progreso, que se reescribe con #13). }
procedure ErrWrite(const S: string);
{ ¿stderr es una consola/terminal? (si está redirigida no se muestra el progreso) }
function ErrIsConsole: Boolean;
{ ¿stdin es una consola/terminal? (para preguntar algo; redirigida, no) }
function InIsConsole: Boolean;
{ Ancho de la consola en columnas (80 si no se sabe). }
function ConsoleWidth: Integer;

type
  TCancelProc = procedure;
{ Ctrl-C (y Ctrl-Break en Windows): el primero llama a Proc (en Windows, desde otro hilo) y
  el proceso sigue para poder limpiar; el segundo lo termina como siempre. }
procedure InstallCancelHandler(Proc: TCancelProc);
type
  TFileMeta = record
    Size: Int64;
    MTimeNs: Int64;          // nanosegundos desde 1970 UTC
    IsDir: Boolean;
    HasWinAttr, HasUnixMode: Boolean;
    WinAttr, UnixMode: LongWord;
    IsLink: Boolean;         // enlace simbólico (o junction de Windows) guardado como enlace
    LinkToDir: Boolean;      //   apunta a un directorio (en Windows hay que crearlo distinto)
    LinkTarget: string;      //   destino, UTF-8 y con '/' (en Windows se vuelve a '\' al crearlo)
  end;

{ Ruta para pasarle al sistema de archivos. En Windows, las rutas de 240 caracteres o más
  llevan el prefijo \\?\ (absoluta, con '\'), sin el cual las APIs cortan en MAX_PATH (260)
  y el archivo "no existe"; funciona también en Win7. En los demás sistemas, igual. }
function FsPath(const P: string): string;
{ Crea el directorio y los que falten (ForceDirectories no maneja el prefijo \\?\). }
function MakeDirs(const Dir: string): Boolean;

{ Metadatos de un archivo o directorio (sigue enlaces simbólicos). False si no existe. }
function GetFileMeta(const Path: string; out Meta: TFileMeta): Boolean;

{ Si Path es un enlace simbólico (o, en Windows, un symlink o una junction; otros puntos de
  reanálisis como los de OneDrive no cuentan), devuelve True y sus metadatos sin seguirlo:
  IsLink, LinkTarget, LinkToDir, fecha y tamaño 0. Para todo lo demás, False. }
function GetLinkMeta(const Path: string; out Meta: TFileMeta): Boolean;
{ Crea el enlace Path -> Target. En Windows hace falta permiso (administrador o modo
  desarrollador); si no hay, devuelve False. }
function MakeSymLink(const Path, Target: string; ToDir: Boolean): Boolean;

{ Fija la fecha de modificación (ns desde 1970 UTC) de un archivo o directorio. }
function SetFileMTimeNs(const Path: string; Ns: Int64): Boolean;
{ Restaura permisos Unix (st_mode and 7777) o atributos de Windows, según la plataforma:
  lo que sea de la otra plataforma se ignora. }
procedure SetFileAttrs(const Path: string; HasUnixMode: Boolean; UnixMode: LongWord;
  HasWinAttr: Boolean; WinAttr: LongWord);

{ Pide una contraseña por consola sin mostrarla. False si no hay consola (entrada redirigida). }
function ReadPassword(const Prompt: string; out Pwd: string): Boolean;

{ Núcleos disponibles. TThread.ProcessorCount de FPC 3.2.2 devuelve siempre 1 en Linux. }
function CpuCount: Integer;

implementation

uses
  {$IFDEF WINDOWS}Windows,{$ENDIF}{$IFDEF UNIX}BaseUnix, TermIO, Linux,{$ENDIF} Classes, SysUtils;

var
  Args: array of string;

{$IFDEF WINDOWS}
function CommandLineToArgvW(lpCmdLine: PWideChar; out pNumArgs: Integer): PPWideChar;
  stdcall; external 'shell32.dll';

procedure LoadArgs;
var
  argv: PPWideChar;
  n, i: Integer;
begin
  argv := CommandLineToArgvW(GetCommandLineW, n);
  if argv = nil then Exit;
  SetLength(Args, n);
  for i := 0 to n - 1 do
    Args[i] := UTF8Encode(UnicodeString(argv[i]));
  LocalFree(HLOCAL(argv));
end;

procedure WriteHandle(Std: DWORD; const S: string; NewLine: Boolean = True);
var
  h: THandle;
  W: UnicodeString;
  Mode, Done: DWORD;
  U: UTF8String;
begin
  h := GetStdHandle(Std);
  U := S;
  if NewLine then U := U + #13#10;
  if GetConsoleMode(h, Mode) then
  begin
    W := UTF8Decode(U);
    if W <> '' then WriteConsoleW(h, PWideChar(W), Length(W), Done, nil);
  end
  else if U <> '' then
    WriteFile(h, U[1], Length(U), Done, nil);   // redirigido a archivo/pipe: UTF-8 crudo
end;
{$ELSE}
procedure LoadArgs;
var
  i: Integer;
begin
  SetLength(Args, ParamCount + 1);
  for i := 0 to ParamCount do Args[i] := ParamStr(i);
end;
{$ENDIF}

{$IFDEF LINUX}
const
  _SC_NPROCESSORS_ONLN = 84;   // glibc
function sysconf(name: LongInt): PtrInt; cdecl; external 'c';
{$ENDIF}

function CpuCount: Integer;
begin
  {$IFDEF LINUX}
  Result := sysconf(_SC_NPROCESSORS_ONLN);
  {$ELSE}
  Result := TThread.ProcessorCount;
  {$ENDIF}
  if Result < 1 then Result := 1;
end;

{$IFDEF WINDOWS}
function FsPath(const P: string): string;
var
  F: string;
begin
  if Copy(P, 1, 4) = '\\?\' then Exit(P);
  // El límite de MAX_PATH es sobre la ruta ABSOLUTA: una relativa corta dentro de un
  // directorio actual largo también se pasa (x -dpdestino con nombres largos fallaba)
  F := StringReplace(ExpandFileName(P), '/', '\', [rfReplaceAll]);
  if Length(F) < 240 then Exit(P);
  if Copy(F, 1, 4) = '\\?\' then Result := F
  else if Copy(F, 1, 2) = '\\' then Result := '\\?\UNC\' + Copy(F, 3, MaxInt)   // \\servidor\recurso
  else Result := '\\?\' + F;
end;

function MakeDirs(const Dir: string): Boolean;
var
  F, Prefix: string;
  i, Start: Integer;
begin
  if Dir = '' then Exit(True);
  F := StringReplace(ExpandFileName(Dir), '/', '\', [rfReplaceAll]);
  F := ExcludeTrailingPathDelimiter(F);
  // Saltear la raíz: "C:\" o "\\servidor\recurso\"
  if Copy(F, 1, 2) = '\\' then
  begin
    Start := 3;
    for i := 1 to 2 do
      while (Start <= Length(F)) and (F[Start] <> '\') do Inc(Start);
    Inc(Start);
  end
  else Start := 4;
  for i := Start to Length(F) + 1 do
    if (i > Length(F)) or (F[i] = '\') then
    begin
      Prefix := Copy(F, 1, i - 1);
      if not DirectoryExists(FsPath(Prefix)) then
        if not CreateDir(FsPath(Prefix)) and not DirectoryExists(FsPath(Prefix)) then Exit(False);
    end;
  Result := True;
end;

const
  // Entre 1601-01-01 (FILETIME) y 1970-01-01, en intervalos de 100 ns
  FILETIME_UNIX_DIFF = 116444736000000000;

function GetFileMeta(const Path: string; out Meta: TFileMeta): Boolean;
var
  D: WIN32_FILE_ATTRIBUTE_DATA;
  W: UnicodeString;
  T: Int64;
begin
  Meta := Default(TFileMeta);
  W := UTF8Decode(FsPath(Path));
  Result := GetFileAttributesExW(PWideChar(W), GetFileExInfoStandard, @D);
  if not Result then Exit;
  Meta.IsDir := (D.dwFileAttributes and FILE_ATTRIBUTE_DIRECTORY) <> 0;
  if not Meta.IsDir then Meta.Size := (Int64(D.nFileSizeHigh) shl 32) or D.nFileSizeLow;
  T := (Int64(D.ftLastWriteTime.dwHighDateTime) shl 32) or D.ftLastWriteTime.dwLowDateTime;
  Meta.MTimeNs := (T - FILETIME_UNIX_DIFF) * 100;
  Meta.HasWinAttr := True;
  Meta.WinAttr := D.dwFileAttributes;
end;

const
  FSCTL_GET_REPARSE_POINT = $000900A8;
  IO_REPARSE_TAG_MOUNT_POINT = $A0000003;   // junction
  IO_REPARSE_TAG_SYMLINK = $A000000C;
  FILE_FLAG_OPEN_REPARSE_POINT = $00200000;
  SYMBOLIC_LINK_FLAG_DIRECTORY = 1;
  SYMBOLIC_LINK_FLAG_ALLOW_UNPRIVILEGED_CREATE = 2;   // Windows 10 1703+ con modo desarrollador

function GetLinkMeta(const Path: string; out Meta: TFileMeta): Boolean;
var
  W, Target: UnicodeString;
  H: THandle;
  Buf: array[0..16383] of Byte;
  Got: DWORD;
  Tag: LongWord;
  P: PByte;
  SubOff, SubLen, PrnOff, PrnLen: Word;
begin
  Result := False;
  if not GetFileMeta(Path, Meta) then Exit;
  if (Meta.WinAttr and FILE_ATTRIBUTE_REPARSE_POINT) = 0 then Exit;
  W := UTF8Decode(FsPath(Path));
  H := CreateFileW(PWideChar(W), 0, FILE_SHARE_READ or FILE_SHARE_WRITE or FILE_SHARE_DELETE, nil,
                   OPEN_EXISTING, FILE_FLAG_OPEN_REPARSE_POINT or FILE_FLAG_BACKUP_SEMANTICS, 0);
  if H = INVALID_HANDLE_VALUE then Exit;
  try
    if not DeviceIoControl(H, FSCTL_GET_REPARSE_POINT, nil, 0, @Buf, SizeOf(Buf), Got, nil) or (Got < 16) then Exit;
  finally
    CloseHandle(H);
  end;
  Tag := PLongWord(@Buf[0])^;
  // REPARSE_DATA_BUFFER: tag, len, reservado, y los offsets de SubstituteName y PrintName;
  // el symlink tiene además 4 bytes de flags antes de los nombres
  SubOff := PWord(@Buf[8])^; SubLen := PWord(@Buf[10])^;
  PrnOff := PWord(@Buf[12])^; PrnLen := PWord(@Buf[14])^;
  if Tag = IO_REPARSE_TAG_SYMLINK then P := @Buf[20]
  else if Tag = IO_REPARSE_TAG_MOUNT_POINT then P := @Buf[16]
  else Exit;   // OneDrive, deduplicación, etc.: se tratan como archivos normales
  if (PtrUInt(P - PByte(@Buf[0])) + PrnOff + PrnLen > Got) or
     (PtrUInt(P - PByte(@Buf[0])) + SubOff + SubLen > Got) then Exit;
  if PrnLen > 0 then SetString(Target, PWideChar(P + PrnOff), PrnLen div 2)
  else SetString(Target, PWideChar(P + SubOff), SubLen div 2);
  if Copy(Target, 1, 4) = '\??\' then Delete(Target, 1, 4);
  Meta.IsLink := True;
  Meta.LinkToDir := Meta.IsDir;
  Meta.LinkTarget := StringReplace(UTF8Encode(Target), '\', '/', [rfReplaceAll]);
  Meta.IsDir := False;
  Meta.Size := 0;
  Result := True;
end;

function MakeSymLink(const Path, Target: string; ToDir: Boolean): Boolean;
type
  TCreateSymbolicLinkW = function(lpSymlinkFileName, lpTargetFileName: PWideChar; dwFlags: DWORD): BOOLEAN; stdcall;
var
  F: TCreateSymbolicLinkW;
  W, T: UnicodeString;
  Flags: DWORD;
begin
  Result := False;
  Pointer(F) := GetProcAddress(GetModuleHandle('kernel32.dll'), 'CreateSymbolicLinkW');
  if not Assigned(F) then Exit;   // (XP)
  W := UTF8Decode(FsPath(Path));
  T := UTF8Decode(StringReplace(Target, '/', '\', [rfReplaceAll]));
  if ToDir then Flags := SYMBOLIC_LINK_FLAG_DIRECTORY else Flags := 0;
  Result := F(PWideChar(W), PWideChar(T), Flags or SYMBOLIC_LINK_FLAG_ALLOW_UNPRIVILEGED_CREATE);
  // Windows 7 y 8 no conocen la bandera y fallan con ERROR_INVALID_PARAMETER
  if not Result and (GetLastError = ERROR_INVALID_PARAMETER) then
    Result := F(PWideChar(W), PWideChar(T), Flags);
end;
{$ELSE}
function FsPath(const P: string): string;
begin
  Result := P;
end;

function MakeDirs(const Dir: string): Boolean;
begin
  Result := (Dir = '') or ForceDirectories(Dir);
end;

function GetFileMeta(const Path: string; out Meta: TFileMeta): Boolean;
var
  St: Stat;
begin
  Meta := Default(TFileMeta);
  Result := FpStat(Path, St) = 0;
  if not Result then Exit;
  Meta.IsDir := FpS_ISDIR(St.st_mode);
  if not Meta.IsDir then Meta.Size := St.st_size;
  Meta.MTimeNs := Int64(St.st_mtime) * 1000000000 + St.st_mtime_nsec;
  Meta.HasUnixMode := True;
  Meta.UnixMode := St.st_mode;
end;

function GetLinkMeta(const Path: string; out Meta: TFileMeta): Boolean;
var
  St, Tgt: Stat;
  Buf: array[0..4095] of Char;
  n: SizeInt;
begin
  Meta := Default(TFileMeta);
  Result := False;
  if (FpLStat(Path, St) <> 0) or not FpS_ISLNK(St.st_mode) then Exit;
  n := FpReadLink(PChar(Path), @Buf[0], SizeOf(Buf));
  if n < 0 then Exit;
  SetString(Meta.LinkTarget, PChar(@Buf[0]), n);
  Meta.IsLink := True;
  Meta.LinkToDir := (FpStat(Path, Tgt) = 0) and FpS_ISDIR(Tgt.st_mode);
  Meta.MTimeNs := Int64(St.st_mtime) * 1000000000 + St.st_mtime_nsec;
  Meta.HasUnixMode := True;
  Meta.UnixMode := St.st_mode;
  Result := True;
end;

function MakeSymLink(const Path, Target: string; ToDir: Boolean): Boolean;
begin
  Result := FpSymLink(PChar(Target), PChar(Path)) = 0;
end;
{$ENDIF}

{$IFDEF WINDOWS}
function SetFileMTimeNs(const Path: string; Ns: Int64): Boolean;
var
  H: THandle;
  W: UnicodeString;
  T: Int64;
  FT: TFileTime;
begin
  W := UTF8Decode(FsPath(Path));
  // FILE_FLAG_BACKUP_SEMANTICS: necesario para abrir directorios
  H := CreateFileW(PWideChar(W), FILE_WRITE_ATTRIBUTES, FILE_SHARE_READ or FILE_SHARE_WRITE, nil,
                   OPEN_EXISTING, FILE_FLAG_BACKUP_SEMANTICS, 0);
  if H = INVALID_HANDLE_VALUE then Exit(False);
  T := Ns div 100 + FILETIME_UNIX_DIFF;
  FT.dwLowDateTime := DWORD(T);
  FT.dwHighDateTime := DWORD(T shr 32);
  Result := SetFileTime(H, nil, nil, @FT);
  CloseHandle(H);
end;

procedure SetFileAttrs(const Path: string; HasUnixMode: Boolean; UnixMode: LongWord;
  HasWinAttr: Boolean; WinAttr: LongWord);
const
  // Solo los atributos que tiene sentido restaurar (no directorio, comprimido, etc.)
  KEEP = FILE_ATTRIBUTE_READONLY or FILE_ATTRIBUTE_HIDDEN or FILE_ATTRIBUTE_SYSTEM or FILE_ATTRIBUTE_ARCHIVE;
var
  W: UnicodeString;
begin
  if not HasWinAttr then Exit;
  W := UTF8Decode(FsPath(Path));
  SetFileAttributesW(PWideChar(W), WinAttr and KEEP);
end;
{$ELSE}
type
  TTimeSpec2 = array[0..1] of timespec;
const
  AT_FDCWD = -100;
function utimensat(dirfd: LongInt; path: PChar; times: Pointer; flags: LongInt): LongInt; cdecl; external 'c';

function SetFileMTimeNs(const Path: string; Ns: Int64): Boolean;
var
  T: TTimeSpec2;
  Sec, NSec: Int64;
begin
  Sec := Ns div 1000000000;
  NSec := Ns mod 1000000000;
  if NSec < 0 then begin Inc(NSec, 1000000000); Dec(Sec); end;
  T[0].tv_sec := Sec; T[0].tv_nsec := NSec;   // acceso = modificación
  T[1].tv_sec := Sec; T[1].tv_nsec := NSec;
  Result := utimensat(AT_FDCWD, PChar(Path), @T[0], 0) = 0;
end;

procedure SetFileAttrs(const Path: string; HasUnixMode: Boolean; UnixMode: LongWord;
  HasWinAttr: Boolean; WinAttr: LongWord);
begin
  if HasUnixMode then FpChmod(Path, UnixMode and &7777);
end;
{$ENDIF}

{$IFDEF WINDOWS}
function ReadPassword(const Prompt: string; out Pwd: string): Boolean;
var
  H: THandle;
  Mode, Got: DWORD;
  Buf: array[0..511] of WideChar;
  W: UnicodeString;
begin
  Pwd := '';
  H := GetStdHandle(STD_INPUT_HANDLE);
  if not GetConsoleMode(H, Mode) then Exit(False);
  ErrLn(Prompt);
  SetConsoleMode(H, Mode and not ENABLE_ECHO_INPUT);
  try
    Result := ReadConsoleW(H, @Buf[0], Length(Buf) - 1, Got, nil);
  finally
    SetConsoleMode(H, Mode);
  end;
  if not Result then Exit;
  SetString(W, PWideChar(@Buf[0]), Got);
  while (W <> '') and (W[Length(W)] in [#13, #10]) do SetLength(W, Length(W) - 1);
  Pwd := UTF8Encode(W);
end;
{$ELSE}
function ReadPassword(const Prompt: string; out Pwd: string): Boolean;
var
  Old, New: Termios;
  c: Char;
begin
  Pwd := '';
  if TCGetAttr(0, Old) <> 0 then Exit(False);   // no es una terminal
  ErrLn(Prompt);
  New := Old;
  New.c_lflag := New.c_lflag and not ECHO;
  TCSetAttr(0, TCSANOW, New);
  try
    while (FpRead(0, c, 1) = 1) and (c <> #10) do Pwd := Pwd + c;
  finally
    TCSetAttr(0, TCSANOW, Old);
  end;
  ErrLn('');
  Result := True;
end;
{$ENDIF}

function ArgCount: Integer;
begin
  Result := Length(Args) - 1;
end;

function Arg(i: Integer): string;
begin
  if (i >= 0) and (i < Length(Args)) then Result := Args[i] else Result := '';
end;

procedure OutLn(const S: string);
begin
  if OutToStderr then begin ErrLn(S); Exit; end;
  {$IFDEF WINDOWS}WriteHandle(STD_OUTPUT_HANDLE, S);{$ELSE}WriteLn(StdOut, S);{$ENDIF}
end;

var
  TempFiles: TStringList = nil;

procedure RegisterTempFile(const Path: string);
begin
  if TempFiles = nil then TempFiles := TStringList.Create;
  TempFiles.Add(Path);
end;

procedure CopyStream(Src, Dst: TStream; var Total: Int64);
var
  Buf: array of Byte;
  n: LongInt;
begin
  SetLength(Buf, 1 shl 20);
  repeat
    n := Src.Read(Buf[0], Length(Buf));
    if n > 0 then
    begin
      Dst.WriteBuffer(Buf[0], n);
      Inc(Total, n);
    end;
  until n <= 0;
end;

function StdinToFile(const Path: string): Int64;
var
  Src: THandleStream;
  Dst: TFileStream;
begin
  Result := 0;
  Src := THandleStream.Create({$IFDEF WINDOWS}GetStdHandle(STD_INPUT_HANDLE){$ELSE}StdInputHandle{$ENDIF});
  try
    Dst := TFileStream.Create(FsPath(Path), fmCreate);
    try
      CopyStream(Src, Dst, Result);
    finally
      Dst.Free;
    end;
  finally
    Src.Free;   // (THandleStream no cierra el handle)
  end;
end;

function StdoutHandle: THandle;
begin
  Result := {$IFDEF WINDOWS}GetStdHandle(STD_OUTPUT_HANDLE){$ELSE}StdOutputHandle{$ENDIF};
end;

procedure FileToStdout(const Path: string);
var
  Src: TFileStream;
  Dst: THandleStream;
  Total: Int64;
begin
  Total := 0;
  Src := TFileStream.Create(FsPath(Path), fmOpenRead or fmShareDenyWrite);
  try
    Dst := THandleStream.Create({$IFDEF WINDOWS}GetStdHandle(STD_OUTPUT_HANDLE){$ELSE}StdOutputHandle{$ENDIF});
    try
      CopyStream(Src, Dst, Total);
    finally
      Dst.Free;
    end;
  finally
    Src.Free;
  end;
end;

procedure ErrLn(const S: string);
begin
  {$IFDEF WINDOWS}WriteHandle(STD_ERROR_HANDLE, S);{$ELSE}WriteLn(StdErr, S);{$ENDIF}
end;

procedure ErrWrite(const S: string);
begin
  {$IFDEF WINDOWS}WriteHandle(STD_ERROR_HANDLE, S, False);{$ELSE}Write(StdErr, S); Flush(StdErr);{$ENDIF}
end;

function ErrIsConsole: Boolean;
{$IFDEF WINDOWS}
var
  Mode: DWORD;
begin
  Result := GetConsoleMode(GetStdHandle(STD_ERROR_HANDLE), Mode);
end;
{$ELSE}
begin
  Result := IsATTY(2) = 1;
end;
{$ENDIF}

function InIsConsole: Boolean;
{$IFDEF WINDOWS}
var
  Mode: DWORD;
begin
  Result := GetConsoleMode(GetStdHandle(STD_INPUT_HANDLE), Mode);
end;
{$ELSE}
begin
  Result := IsATTY(0) = 1;
end;
{$ENDIF}

function ConsoleWidth: Integer;
{$IFDEF WINDOWS}
var
  Info: TConsoleScreenBufferInfo;
begin
  if GetConsoleScreenBufferInfo(GetStdHandle(STD_ERROR_HANDLE), Info) then
    Result := Info.srWindow.Right - Info.srWindow.Left + 1
  else
    Result := 80;
end;
{$ELSE}
var
  WS: TWinSize;
begin
  if (FpIOCtl(2, TIOCGWINSZ, @WS) = 0) and (WS.ws_col > 0) then Result := WS.ws_col
  else Result := 80;
end;
{$ENDIF}

var
  CancelProc: TCancelProc = nil;
  CancelCount: LongInt = 0;

{$IFDEF WINDOWS}
function CtrlHandler(CtrlType: DWORD): BOOL; stdcall;
begin
  Result := False;
  if (CtrlType = CTRL_C_EVENT) or (CtrlType = CTRL_BREAK_EVENT) then
    if InterlockedIncrement(CancelCount) = 1 then
    begin
      if CancelProc <> nil then CancelProc;
      Result := True;           // el primero lo manejamos; el segundo sigue al default (termina)
    end;
end;

procedure InstallCancelHandler(Proc: TCancelProc);
begin
  CancelProc := Proc;
  // Un proceso creado con CREATE_NEW_PROCESS_GROUP (y sus hijos: se hereda) ignora Ctrl-C por
  // completo, sin llegar a los manejadores; reactivarlo, que para eso instalamos uno
  SetConsoleCtrlHandler(nil, False);
  SetConsoleCtrlHandler(@CtrlHandler, True);
end;
{$ELSE}
var
  FirstSigMs: Int64 = 0;

function MonoMs: Int64;
var
  T: TTimeSpec;
begin
  clock_gettime(CLOCK_MONOTONIC, @T);
  Result := Int64(T.tv_sec) * 1000 + T.tv_nsec div 1000000;
end;

procedure SigIntHandler(Sig: CInt); cdecl;
begin
  // Solo cosas seguras en un manejador de señal (clock_gettime, kill, sigaction).
  // Un segundo SIGINT muy pegado al primero se ignora: `timeout` y `kill -INT -<grupo>` lo
  // mandan dos veces (al proceso y a su grupo) y no es un segundo Ctrl-C del usuario
  Inc(CancelCount);
  if CancelCount = 1 then
  begin
    FirstSigMs := MonoMs;
    if CancelProc <> nil then CancelProc;
  end
  else if MonoMs - FirstSigMs > 500 then
  begin
    // Segundo Ctrl-C de verdad: morir por la señal, como sin manejador (el shell ve 130)
    FpSignal(SIGINT, SignalHandler(SIG_DFL));
    FpKill(FpGetPid, SIGINT);
  end;
end;

procedure InstallCancelHandler(Proc: TCancelProc);
begin
  CancelProc := Proc;
  FpSignal(SIGINT, @SigIntHandler);
end;
{$ENDIF}

initialization
  {$IFDEF WINDOWS}
  // Que las funciones de archivo de la RTL interpreten nuestros string como UTF-8
  SetMultiByteConversionCodePage(CP_UTF8);
  SetMultiByteFileSystemCodePage(CP_UTF8);
  SetMultiByteRTLFileSystemCodePage(CP_UTF8);
  {$ENDIF}
  LoadArgs;
finalization
  if TempFiles <> nil then
  begin
    while TempFiles.Count > 0 do
    begin
      DeleteFile(FsPath(TempFiles[TempFiles.Count - 1]));
      TempFiles.Delete(TempFiles.Count - 1);
    end;
    TempFiles.Free;
  end;
end.
