{ PArc — reescritura de FreeArc en Pascal.
  Listado, test y extracción de archivos FreeArc (.arc). }
program parc;

{$mode objfpc}{$H+}

uses
  {$IFDEF UNIX}cthreads,{$ENDIF}
  Classes, SysUtils, DateUtils, parc_os, parc_bytes, parc_methods, parc_archive, parc_extract;

const
  PARC_VERSION = '0.0.2';

procedure Usage;
begin
  OutLn('PArc ' + PARC_VERSION + ' — archivador compatible con FreeArc');
  OutLn('Uso: parc <comando> <archivo> [archivos/máscaras...] [opciones]');
  OutLn('  l   lista el contenido');
  OutLn('  lb  lista los bloques (estructura interna)');
  OutLn('  t   verifica (descomprime y compara CRC, sin escribir)');
  OutLn('  x   extrae con rutas');
  OutLn('  e   extrae sin rutas');
  OutLn('Opciones:');
  OutLn('  -dp<dir>  directorio de destino');
  OutLn('  -o+       sobrescribe archivos existentes    -o-  los saltea (default)');
end;

function FmtTime(t: Int64): string;
begin
  Result := FormatDateTime('yyyy-mm-dd hh:nn:ss', UnixToDateTime(t, True));
end;

procedure CmdList(A: TArchive);
var
  i: Integer;
  TotalSize, TotalComp: Int64;
  Kind: string;
begin
  OutLn('Fecha/hora (UTC)            Tamaño       CRC  Nombre');
  OutLn('-------------------  --------------  --------  ------');
  TotalSize := 0;
  for i := 0 to High(A.Files) do
    with A.Files[i] do
    begin
      if IsDir then Kind := '<DIR>' else Kind := IntToStr(Size);
      OutLn(Format('%s  %14s  %.8x  %s', [FmtTime(Time), Kind, Crc, Name]));
      Inc(TotalSize, Size);
    end;
  TotalComp := 0;
  for i := 0 to High(A.DataBlocks) do Inc(TotalComp, A.DataBlocks[i].CompSize);
  OutLn('-------------------  --------------  --------  ------');
  OutLn(Format('%d archivo(s), %d bytes, comprimido %d bytes', [Length(A.Files), TotalSize, TotalComp]));
  if A.Comment <> '' then OutLn('Comentario: ' + A.Comment);
end;

procedure PrintBlock(const B: TArcBlock);
begin
  OutLn(Format('  %-10s pos=%-12d orig=%-12d comp=%-12d %s',
    [BlockTypeName(B.BlockType), B.Pos, B.OrigSize, B.CompSize, B.Method]));
end;

procedure CmdBlocks(A: TArchive);
var
  i: Integer;
begin
  OutLn(Format('Archivo: %s (%d bytes), SFX=%d, bloqueado=%s, recovery="%s"',
    [A.FileName, A.ArcSize, A.SFXSize, BoolToStr(A.Locked, 'sí', 'no'), A.Recovery]));
  OutLn('Bloques de control:');
  for i := 0 to High(A.ControlBlocks) do PrintBlock(A.ControlBlocks[i]);
  PrintBlock(A.Footer);
  OutLn('Bloques de datos:');
  for i := 0 to High(A.DataBlocks) do
  begin
    PrintBlock(A.DataBlocks[i]);
    OutLn(Format('             %d archivo(s) desde #%d', [A.DataBlocks[i].FileCount, A.DataBlocks[i].FirstFile]));
  end;
end;

procedure LogLine(const Msg: string);
begin
  OutLn(Msg);
end;

function CmdExtract(A: TArchive; const Cmd: string; const Opt0: TExtractOptions): Integer;
var
  Opt: TExtractOptions;
  St: TExtractStats;
begin
  Opt := Opt0;
  Opt.TestOnly := Cmd = 't';
  Opt.FlatNames := Cmd = 'e';
  St := ExtractArchive(A, Opt, @LogLine);
  if Opt.TestOnly then
    OutLn(Format('Verificados %d archivo(s), %d bytes. Errores: %d', [St.Files, St.Bytes, St.Errors]))
  else
    OutLn(Format('Extraídos %d archivo(s) y %d directorio(s), %d bytes. Saltados: %d. Errores: %d',
      [St.Files, St.Dirs, St.Bytes, St.Skipped, St.Errors]));
  if St.Errors > 0 then Result := 2 else Result := 0;
end;

var
  Cmd, ArcName, S: string;
  A: TArchive;
  Opt: TExtractOptions;
  Filter: TStringList;
  i, Code: Integer;
begin
  if ArgCount < 2 then
  begin
    Usage;
    Halt(1);
  end;
  Cmd := Arg(1);
  Opt := Default(TExtractOptions);
  Opt.Overwrite := owSkip;
  ArcName := '';
  Filter := TStringList.Create;
  Code := 0;
  try
    for i := 2 to ArgCount do
    begin
      S := Arg(i);
      if (Length(S) > 1) and (S[1] = '-') then
      begin
        if Copy(S, 1, 3) = '-dp' then Opt.DestDir := Copy(S, 4, MaxInt)
        else if S = '-o+' then Opt.Overwrite := owAll
        else if S = '-o-' then Opt.Overwrite := owSkip
        else
        begin
          ErrLn('Opción desconocida: ' + S);
          Halt(1);
        end;
      end
      else if ArcName = '' then ArcName := S
      else Filter.Add(S);
    end;
    if ArcName = '' then
    begin
      Usage;
      Halt(1);
    end;
    Opt.Filter := Filter;
    try
      A := TArchive.Open(ArcName);
      try
        if Cmd = 'l' then CmdList(A)
        else if Cmd = 'lb' then CmdBlocks(A)
        else if (Cmd = 't') or (Cmd = 'x') or (Cmd = 'e') then Code := CmdExtract(A, Cmd, Opt)
        else
        begin
          Usage;
          Code := 1;
        end;
      finally
        A.Free;
      end;
    except
      on E: EArcCorrupt do begin ErrLn('ERROR: ' + E.Message); Code := 2; end;
      on E: EUnsupportedMethod do begin ErrLn('ERROR: ' + E.Message); Code := 3; end;
      on E: Exception do begin ErrLn('ERROR: ' + E.Message); Code := 4; end;
    end;
  finally
    Filter.Free;
  end;
  Halt(Code);
end.
