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
{ Núcleos disponibles. TThread.ProcessorCount de FPC 3.2.2 devuelve siempre 1 en Linux. }
function CpuCount: Integer;

implementation

uses
  {$IFDEF WINDOWS}Windows,{$ENDIF} Classes, SysUtils;

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
