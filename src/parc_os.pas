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
type
  TFileMeta = record
    Size: Int64;
    MTimeNs: Int64;          // nanosegundos desde 1970 UTC
    IsDir: Boolean;
    HasWinAttr, HasUnixMode: Boolean;
    WinAttr, UnixMode: LongWord;
  end;

{ Ruta para pasarle al sistema de archivos. En Windows, las rutas de 240 caracteres o más
  llevan el prefijo \\?\ (absoluta, con '\'), sin el cual las APIs cortan en MAX_PATH (260)
  y el archivo "no existe"; funciona también en Win7. En los demás sistemas, igual. }
function FsPath(const P: string): string;
{ Crea el directorio y los que falten (ForceDirectories no maneja el prefijo \\?\). }
function MakeDirs(const Dir: string): Boolean;

{ Metadatos de un archivo o directorio (sigue enlaces simbólicos). False si no existe. }
function GetFileMeta(const Path: string; out Meta: TFileMeta): Boolean;

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
  {$IFDEF WINDOWS}Windows,{$ENDIF}{$IFDEF UNIX}BaseUnix, TermIO,{$ENDIF} Classes, SysUtils;

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

procedure WriteHandle(Std: DWORD; const S: string);
var
  h: THandle;
  W: UnicodeString;
  Mode, Done: DWORD;
  U: UTF8String;
begin
  h := GetStdHandle(Std);
  U := S + #13#10;
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
  if (Length(P) < 240) or (Copy(P, 1, 4) = '\\?\') then Exit(P);
  F := StringReplace(ExpandFileName(P), '/', '\', [rfReplaceAll]);
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
  {$IFDEF WINDOWS}WriteHandle(STD_OUTPUT_HANDLE, S);{$ELSE}WriteLn(StdOut, S);{$ENDIF}
end;

procedure ErrLn(const S: string);
begin
  {$IFDEF WINDOWS}WriteHandle(STD_ERROR_HANDLE, S);{$ELSE}WriteLn(StdErr, S);{$ENDIF}
end;

initialization
  {$IFDEF WINDOWS}
  // Que las funciones de archivo de la RTL interpreten nuestros string como UTF-8
  SetMultiByteConversionCodePage(CP_UTF8);
  SetMultiByteFileSystemCodePage(CP_UTF8);
  SetMultiByteRTLFileSystemCodePage(CP_UTF8);
  {$ENDIF}
  LoadArgs;
end.
