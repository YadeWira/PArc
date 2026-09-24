{ PArc — reescritura de FreeArc en Pascal.
  Fase 1: listado de archivos FreeArc (.arc) y PArc (.parc). }
program parc;

{$mode objfpc}{$H+}

uses
  SysUtils, DateUtils, parc_os, parc_bytes, parc_methods, parc_archive;

const
  PARC_VERSION = '0.0.1';

procedure Usage;
begin
  OutLn('PArc ' + PARC_VERSION + ' — archivador compatible con FreeArc');
  OutLn('Uso: parc <comando> <archivo>');
  OutLn('  l   lista el contenido');
  OutLn('  lb  lista los bloques (estructura interna)');
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

var
  Cmd: string;
  A: TArchive;
begin
  if ArgCount < 2 then
  begin
    Usage;
    Halt(1);
  end;
  Cmd := Arg(1);
  try
    A := TArchive.Open(Arg(2));
    try
      if Cmd = 'l' then CmdList(A)
      else if Cmd = 'lb' then CmdBlocks(A)
      else
      begin
        Usage;
        Halt(1);
      end;
    finally
      A.Free;
    end;
  except
    on E: EArcCorrupt do begin ErrLn('ERROR: ' + E.Message); Halt(2); end;
    on E: EUnsupportedMethod do begin ErrLn('ERROR: ' + E.Message); Halt(3); end;
    on E: Exception do begin ErrLn('ERROR: ' + E.Message); Halt(4); end;
  end;
end.
