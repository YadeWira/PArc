{ parcsfx — módulo autoextraíble de PArc (PA-Lab; integrado por PArc).
  Un SFX es [este ejecutable][archivo .parc/.arc] pegados (parc a -sfx lo arma). El lector
  detecta el prefijo por la posición del footer (TArchive.SFXSize), así que el programa abre
  SU PROPIO ejecutable como archivo y opera sobre él.
  Comandos: (nada) = extraer al directorio actual, t = verificar, l = listar.
  Opciones: -dp<dir>  -o+ / -o-  -p<contraseña>  --no-progress.
  Solo decodificadores (ni parc_encoders ni parc_writer): pesa la mitad que parc.
  Códigos de salida como parc (docs/USO.md). }
program parcsfx;

{$mode objfpc}{$H+}

uses
  {$IFDEF UNIX}cthreads,{$ENDIF}
  Classes, SysUtils, parc_os, parc_bytes, parc_methods, parc_archive, parc_extract, parc_progress,
  parc_console;

const
  SFX_VERSION = '0.1.0';

procedure Usage;
begin
  OutLn('parcsfx ' + SFX_VERSION + ' — autoextraíble de PArc');
  OutLn('Uso: <este programa> [t|l] [-dp<dir>] [-o+|-o-] [-p<contraseña>] [--no-progress]');
  OutLn('  (sin comando)  extrae todo al directorio actual');
  OutLn('  t   verifica el contenido (descomprime y compara CRC, sin escribir)');
  OutLn('  l   lista el contenido');
  OutLn('  -dp<dir>  directorio de destino');
  OutLn('  -o+  sobrescribe los archivos que ya existen   -o-  los saltea   (sin nada: pregunta)');
  OutLn('  -p<contraseña>  contraseña de un archivo cifrado (si falta, se pide)');
  OutLn('  --no-progress  sin línea de progreso');
end;

function Run: Integer;
var
  ArcName, Cmd, S: string;
  Opt: TExtractOptions;
  St: TExtractStats;
  ShowProgress, Retry: Boolean;
  A: TArchive;
  Tries, i: Integer;
begin
  ArcName := Arg(0);          // el propio ejecutable (ruta Unicode real en Windows)
  Cmd := 'x';
  Opt := Default(TExtractOptions);
  Opt.Overwrite := owAsk;
  Opt.AskOverwrite := @AskOverwriteConsole;
  ShowProgress := True;
  Result := 0;
  for i := 1 to ArgCount do    // (ArgCount no cuenta el ejecutable)
  begin
    S := Arg(i);
    if (S = 't') or (S = 'l') then Cmd := S
    else if S = '--no-progress' then ShowProgress := False
    else if S = '-o+' then Opt.Overwrite := owAll
    else if S = '-o-' then Opt.Overwrite := owSkip
    else if Copy(S, 1, 3) = '-dp' then Opt.DestDir := Copy(S, 4, MaxInt)
    else if (Copy(S, 1, 2) = '-p') and (Length(S) > 2) then SetArchivePassword(Copy(S, 3, MaxInt))
    else if S = '-p' then   // sin valor: se pide cuando haga falta
    else if (S = '-h') or (S = '--help') or (S = '/?') then begin Usage; Exit(0); end
    else
    begin
      ErrLn('Opción desconocida: ' + S);
      Usage;
      Exit(1);
    end;
  end;
  Opt.TestOnly := Cmd = 't';
  if ShowProgress and ErrIsConsole then ProgressHandler := @DrawProgress;
  InstallCancelHandler(@OnCtrlC);

  Tries := 0;
  repeat
    Retry := False;
    try
      A := TArchive.Open(ArcName);
      try
        if Cmd = 'l' then CmdList(A)
        else
        begin
          St := ExtractArchive(A, Opt, @LogLine);
          if Opt.TestOnly then
            OutLn(Format('Verificados %d archivo(s), %d bytes. Errores: %d', [St.Files, St.Bytes, St.Errors]))
          else
            OutLn(Format('Extraídos %d archivo(s) y %d directorio(s), %d bytes. Saltados: %d. Errores: %d',
              [St.Files, St.Dirs, St.Bytes, St.Skipped, St.Errors]));
          if St.Errors > 0 then Result := 2;
        end;
      finally
        A.Free;
      end;
    except
      on E: EPasswordRequired do
        if (Tries < 3) and ReadPassword('Contraseña: ', S) then
        begin
          AddArchivePassword(S);
          Inc(Tries);
          Retry := True;
        end
        else begin ClearProgress; ErrLn('ERROR: ' + E.Message); Result := 5; end;
      on E: EBadPassword do
        if (Tries < 3) and ReadPassword('Contraseña incorrecta. Contraseña: ', S) then
        begin
          AddArchivePassword(S);
          Inc(Tries);
          Retry := True;
        end
        else begin ClearProgress; ErrLn('ERROR: ' + E.Message); Result := 5; end;
      on E: EOperationCancelled do begin ClearProgress; ErrLn('Cancelado.'); Result := EXIT_CANCELLED; end;
      on E: EArcCorrupt do begin ClearProgress; ErrLn('ERROR: ' + E.Message); Result := 2; end;
      on E: EUnsupportedMethod do begin ClearProgress; ErrLn('ERROR: ' + E.Message); Result := 3; end;
      on E: Exception do begin ClearProgress; ErrLn('ERROR: ' + E.Message); Result := 4; end;
    end;
  until not Retry;
end;

var
  Code: Integer;
begin
  Code := Run;
  PauseIfOwnConsole;   // con doble clic en Windows, que se vea el resultado
  Halt(Code);
end.
