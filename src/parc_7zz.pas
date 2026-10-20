{ Contenedores ajenos al formato .arc/.parc: .zip (lectura y escritura), .7z y .rar
  (solo lectura). PArc no implementa esos formatos: delega en 7-Zip ZS (7zz), que aporta
  además ZSTD, Brotli, LZ4, LZ5, Lizard y FastLZMA2 en ZIP/7z.

  El binario se busca en PARC_7ZZ, al lado de parc (7zz/7z) o en PATH. No se enlaza nada:
  se ejecuta como proceso externo (7-Zip ZS es LGPL 2.1+ con la restricción de unRAR). }
unit parc_7zz;

{$mode objfpc}{$H+}

interface

uses
  SysUtils, Classes;

type
  { Opciones que PArc traduce a la línea de comandos de 7zz. }
  T7zzOptions = record
    DestDir: string;          // -dp<dir>  -> -o<dir>
    Overwrite: Boolean;       // -o+       -> -aoa (si no, -aos)
    Password: string;         // -p...     ('' y PasswordGiven => -p, 7zz pregunta)
    PasswordGiven: Boolean;
    HeadersPassword: Boolean; // -hp (solo tiene efecto al crear 7z; en zip se avisa)
    Method: string;           // -m... de PArc; '' = default de 7zz
    Excludes: TStrings;       // -x<mask>  -> -x!<mask>
    Recursive: Boolean;       // -r
    VolumeSize: Int64;        // -v<bytes>
    NoProgress: Boolean;      // --no-progress -> -bsp0
    ShownName: string;        // nombre a mostrar en mensajes ('' = el del archivo)
  end;

{ 0 = no es un contenedor ajeno; 1 = zip; 2 = 7z; 3 = rar. }
function ForeignKind(const Name: string): Integer;

{ Ejecuta el comando sobre un .zip/.7z/.rar. Devuelve el código de salida de PArc y, si algo
  falla antes de ejecutar 7zz, el mensaje en Msg. }
function RunForeign(const Cmd, ArcName: string; Files: TStrings;
  const O: T7zzOptions; out Msg: string): Integer;

{ Ruta del 7zz/7z a usar ('' si no está). }
function Find7zz: string;

implementation

uses
  Process
  {$IFDEF UNIX}, BaseUnix{$ENDIF};

function ForeignKind(const Name: string): Integer;
var
  E: string;
begin
  E := LowerCase(ExtractFileExt(Name));
  if E = '.zip' then Result := 1
  else if E = '.7z' then Result := 2
  else if E = '.rar' then Result := 3
  else Result := 0;
end;

function ExecutableFile(const Path: string): Boolean;
begin
  Result := FileExists(Path);
  {$IFDEF UNIX}
  if Result then Result := fpAccess(Path, X_OK) = 0;
  {$ENDIF}
  if not Result then
  begin
    {$IFDEF WINDOWS}
    if FileExists(Path + '.exe') then Result := True;
    {$ENDIF}
  end;
end;

function Find7zz: string;
var
  Env, Dir, Candidate: string;
  Dirs: TStringArray;
  I: Integer;
begin
  Env := GetEnvironmentVariable('PARC_7ZZ');
  if Env <> '' then
  begin
    // si se pidió uno concreto y no sirve, no se cae a otro silenciosamente
    if ExecutableFile(Env) then Exit(Env) else Exit('');
  end;

  Dir := ExtractFilePath(ParamStr(0));
  Candidate := Dir + '7zz';
  if ExecutableFile(Candidate) then Exit(Candidate);
  {$IFDEF WINDOWS}
  if ExecutableFile(Candidate + '.exe') then Exit(Candidate + '.exe');
  {$ENDIF}
  Candidate := Dir + '7z';
  if ExecutableFile(Candidate) then Exit(Candidate);
  {$IFDEF WINDOWS}
  if ExecutableFile(Candidate + '.exe') then Exit(Candidate + '.exe');
  {$ENDIF}

  Dirs := GetEnvironmentVariable('PATH').Split([PathSeparator]);
  for I := 0 to High(Dirs) do
  begin
    if Dirs[I] = '' then Continue;
    Candidate := IncludeTrailingPathDelimiter(Dirs[I]) + '7zz';
    if ExecutableFile(Candidate) then Exit(Candidate);
    {$IFDEF WINDOWS}
    if ExecutableFile(Candidate + '.exe') then Exit(Candidate + '.exe');
    {$ENDIF}
    Candidate := IncludeTrailingPathDelimiter(Dirs[I]) + '7z';
    if ExecutableFile(Candidate) then Exit(Candidate);
    {$IFDEF WINDOWS}
    if ExecutableFile(Candidate + '.exe') then Exit(Candidate + '.exe');
    {$ENDIF}
  end;
  Result := '';
end;

{ Traduce un -m de PArc al método de 7-Zip. Devuelve False si no se reconoce. }
function MapMethod(const M: string; Switches: TStringList): Boolean;
var
  Name, Lev: string;
  P, N: Integer;
begin
  Result := True;
  if M = '' then Exit;
  if (M = 'x') or (M = 'X') then
  begin
    Switches.Add('-mx=9');
    Exit;
  end;
  if (Length(M) = 1) and (M[1] in ['0'..'9']) then
  begin
    Switches.Add('-mx=' + M);
    Exit;
  end;
  P := Pos(':', M);
  if P > 0 then
  begin
    Name := Copy(M, 1, P - 1);
    Lev := Copy(M, P + 1, MaxInt);
  end
  else
  begin
    Name := M;
    Lev := '';
  end;
  Name := LowerCase(Name);
  if Name = 'store' then Name := 'copy'
  else if Name = 'storing' then Name := 'copy'
  else if Name = 'deflate' then Name := 'Deflate'
  else if Name = 'lzma' then Name := 'LZMA'
  else if Name = 'ppmd' then Name := 'PPMd'
  else if Name = 'zstd' then Name := 'ZSTD'
  else if Name = 'brotli' then Name := 'BROTLI'
  else if Name = 'lz4' then Name := 'LZ4'
  else if Name = 'lz5' then Name := 'LZ5'
  else if Name = 'lizard' then Name := 'LIZARD'
  else if Name = 'flzma2' then Name := 'FLZMA2'
  else if Name = 'copy' then Name := 'Copy'
  else
  begin
    Result := False;
    Exit;
  end;
  if Name = 'Copy' then
  begin
    Switches.Add('-mx=0');
    Exit;
  end;
  Switches.Add('-mm=' + Name);
  if Lev <> '' then
  begin
    if TryStrToInt(Lev, N) and (N >= 0) and (N <= 22) then
      Switches.Add('-mx=' + IntToStr(N));
    // otros parámetros del método (p. ej. "64m") no se traducen: 7zz usa su default
  end;
end;

function Run7zzProcess(const Args: TStringList; out Msg: string): Integer;
var
  P: TProcess;
  Exe: string;
  I: Integer;
begin
  Exe := Find7zz;
  if Exe = '' then
  begin
    Msg := 'ERROR: para .zip/.7z/.rar hace falta 7-Zip ZS (7zz). Definí PARC_7ZZ, ' +
           'ponelo al lado de parc o compilalo con tools/build-7zz.sh';
    Exit(4);
  end;
  P := TProcess.Create(nil);
  try
    P.Executable := Exe;
    for I := 0 to Args.Count - 1 do P.Parameters.Add(Args[I]);
    P.Options := [poWaitOnExit];
    try
      P.Execute;
    except
      on E: Exception do
      begin
        Msg := 'ERROR: no se pudo ejecutar ' + Exe + ': ' + E.Message;
        Exit(4);
      end;
    end;
    case P.ExitStatus of
      0: Result := 0;
      1: Result := 6;    // advertencia: algún archivo no se pudo procesar
      2: Result := 2;    // error fatal (datos dañados o similar)
      7: Result := 1;    // línea de comandos
      8: Result := 4;    // sin memoria
      255: Result := 130; // interrumpido por el usuario
    else
      Result := 4;
    end;
  finally
    P.Free;
  end;
end;

function RunForeign(const Cmd, ArcName: string; Files: TStrings;
  const O: T7zzOptions; out Msg: string): Integer;
var
  Kind: Integer;
  Zip, Writable, Create: Boolean;
  Args: TStringList;
  SevenCmd: string;
  I: Integer;
  Shown: string;

  procedure Add(const S: string);
  begin
    Args.Add(S);
  end;

begin
  Result := 0;
  Msg := '';
  Kind := ForeignKind(ArcName);
  if Kind = 0 then
  begin
    Msg := 'ERROR: no es un contenedor soportado: ' + ArcName;
    Exit(1);
  end;
  Zip := Kind = 1;
  Writable := Zip;
  Shown := ArcName;
  if O.ShownName <> '' then Shown := O.ShownName;

  // comandos
  Create := False;
  if Cmd = 'a' then
  begin
    if not Writable then
    begin
      Msg := 'ERROR: ' + ExtractFileExt(ArcName) + ' es de solo lectura en PArc (se puede ' +
             'listar, verificar y extraer; no agregar ni borrar)';
      Exit(1);
    end;
    SevenCmd := 'a'; Create := True;
  end
  else if Cmd = 'u' then
  begin
    if not Writable then
    begin
      Msg := 'ERROR: ' + ExtractFileExt(ArcName) + ' es de solo lectura en PArc';
      Exit(1);
    end;
    SevenCmd := 'u'; Create := True;
  end
  else if Cmd = 'f' then
  begin
    if not Writable then
    begin
      Msg := 'ERROR: ' + ExtractFileExt(ArcName) + ' es de solo lectura en PArc';
      Exit(1);
    end;
    // freshen: solo los que ya están, si el del disco es más nuevo
    SevenCmd := 'u'; Create := True;
  end
  else if Cmd = 'd' then
  begin
    if not Writable then
    begin
      Msg := 'ERROR: ' + ExtractFileExt(ArcName) + ' es de solo lectura en PArc';
      Exit(1);
    end;
    SevenCmd := 'd';
  end
  else if Cmd = 'l' then SevenCmd := 'l'
  else if Cmd = 't' then SevenCmd := 't'
  else if Cmd = 'x' then SevenCmd := 'x'
  else if Cmd = 'e' then SevenCmd := 'e'
  else if Cmd = 'lb' then
  begin
    Msg := 'ERROR: "lb" (bloques internos) no aplica a ' + ExtractFileExt(ArcName) +
           '; usá "parc l"';
    Exit(1);
  end
  else if Cmd = 'r' then
  begin
    Msg := 'ERROR: "r" (reparar) solo aplica a .arc/.parc';
    Exit(1);
  end
  else
  begin
    Msg := 'ERROR: comando no soportado para ' + ExtractFileExt(ArcName) + ': ' + Cmd;
    Exit(1);
  end;

  Args := TStringList.Create;
  try
    Add(SevenCmd);
    if Create and Zip then Add('-tzip');
    if Cmd = 'f' then
      // freshen (k_ActionSet_Fresh): no agrega nuevos; reemplaza si el del disco es más nuevo
      Add('-up1q1r0x1y2z1w2');
    if (Cmd = 'x') or (Cmd = 'e') then
    begin
      if O.DestDir <> '' then Add('-o' + O.DestDir);
      if O.Overwrite then Add('-aoa') else Add('-aos');
    end;
    if Create then
    begin
      if O.Method <> '' then
        if not MapMethod(O.Method, Args) then
        begin
          Msg := 'ERROR: método no soportado para .zip: -m' + O.Method +
                 ' (usá deflate, lzma, ppmd, zstd, brotli, lz4, lz5, lizard, flzma2 o 0..9)';
          Exit(1);
        end;
      if O.VolumeSize > 0 then Add('-v' + IntToStr(O.VolumeSize) + 'b');
      // no meter el propio archivo dentro de sí mismo
      Add('-xr!' + ExtractFileName(ArcName));
    end;
    if O.PasswordGiven then
    begin
      if O.Password <> '' then Add('-p' + O.Password) else Add('-p');
      if O.HeadersPassword and (Kind = 2) then Add('-mhe=on');
    end;
    if O.Recursive then Add('-r');
    if O.NoProgress then Add('-bsp0');
    if Assigned(O.Excludes) then
      for I := 0 to O.Excludes.Count - 1 do
        Add('-xr!' + O.Excludes[I]);
    Add('-y');
    Add(ArcName);
    for I := 0 to Files.Count - 1 do
      if Files[I] <> '' then Add(Files[I]);
    Result := Run7zzProcess(Args, Msg);
  finally
    Args.Free;
  end;
end;

end.
