{ Extracción y test. Cada bloque sólido se descomprime una sola vez, en streaming, y la salida
  se reparte entre sus archivos en orden (los offsets vienen del directorio, FORMATO-ARC.md §6). }
unit parc_extract;

{$mode objfpc}{$H+}

interface

uses
  Classes, SysUtils, parc_archive;

type
  TOverwriteMode = (owAsk, owAll, owSkip);

  TExtractOptions = record
    TestOnly: Boolean;       // `t`: descomprime y verifica CRC sin escribir
    DestDir: string;         // directorio de salida ('' = actual)
    FlatNames: Boolean;      // `e`: sin rutas
    Overwrite: TOverwriteMode;
    Filter: TStringList;     // nombres/máscaras a incluir (nil = todos)
  end;

  TExtractStats = record
    Files, Dirs, Errors, Skipped: Integer;
    Bytes: Int64;
  end;

  TLogProc = procedure(const Msg: string);

function ExtractArchive(A: TArchive; const Opt: TExtractOptions; Log: TLogProc): TExtractStats;

implementation

uses
  DateUtils, parc_bytes, parc_crc, parc_stream, parc_methods;

const
  COPY_BUF = 1 shl 20;

{ Comodines estilo FreeArc: '*' = cualquier secuencia, '?' = un carácter.
  En Windows sin distinguir mayúsculas. Backtracking simple sobre el último '*'. }
function MatchWild(const Name, Mask: string): Boolean;
var
  n, m, StarM, StarN: Integer;
  a, b: string;
begin
  {$IFDEF WINDOWS}a := LowerCase(Name); b := LowerCase(Mask);{$ELSE}a := Name; b := Mask;{$ENDIF}
  n := 1; m := 1; StarM := 0; StarN := 0;
  while n <= Length(a) do
  begin
    if (m <= Length(b)) and ((b[m] = '?') or (b[m] = a[n])) then
    begin
      Inc(n); Inc(m);
    end
    else if (m <= Length(b)) and (b[m] = '*') then
    begin
      StarM := m; StarN := n; Inc(m);
    end
    else if StarM > 0 then
    begin
      m := StarM + 1; Inc(StarN); n := StarN;
    end
    else
      Exit(False);
  end;
  while (m <= Length(b)) and (b[m] = '*') do Inc(m);
  Result := m > Length(b);
end;

function Wanted(const Opt: TExtractOptions; const Name: string): Boolean;
var
  i: Integer;
begin
  if (Opt.Filter = nil) or (Opt.Filter.Count = 0) then Exit(True);
  for i := 0 to Opt.Filter.Count - 1 do
    if MatchWild(Name, Opt.Filter[i]) or MatchWild(Copy(Name, LastDelimiter('/', Name) + 1, MaxInt), Opt.Filter[i])
       or (Name = Opt.Filter[i]) or (Copy(Name, 1, Length(Opt.Filter[i]) + 1) = Opt.Filter[i] + '/') then
      Exit(True);
  Result := False;
end;

{ Ruta de salida en el disco. Los nombres ya vienen saneados por TArchive (sin "..", sin raíz),
  pero lo volvemos a verificar acá: es la última línea de defensa antes de escribir. }
function DiskName(const Opt: TExtractOptions; const Name: string): string;
var
  Rel: string;
begin
  Rel := SanitizePath(Name);   // sin raíz, sin "." ni ".."
  if Opt.FlatNames then Rel := Copy(Rel, LastDelimiter('/', Rel) + 1, MaxInt);
  // En Windows, ':' dentro de un nombre abre un stream alternativo (ADS): no lo permitimos
  if (Rel = '') {$IFDEF WINDOWS}or (Pos(':', Rel) > 0){$ENDIF} then
    raise EArcCorrupt.CreateFmt('nombre inseguro en el archivo: "%s"', [Name]);
  Rel := StringReplace(Rel, '/', PathDelim, [rfReplaceAll]);
  if Opt.DestDir <> '' then Result := IncludeTrailingPathDelimiter(Opt.DestDir) + Rel
  else Result := Rel;
end;

procedure SetFileTime(const FileName: string; UnixTime: Int64);
begin
  FileSetDate(FileName, DateTimeToFileDate(UnixToDateTime(UnixTime, False)));
end;

{ Lee y descarta Count bytes de la cadena (archivos no pedidos dentro de un bloque sólido). }
procedure SkipBytes(Chain: TInStage; Count: Int64; var Buf: TBytes);
var
  n: SizeInt;
begin
  while Count > 0 do
  begin
    if Count > Length(Buf) then n := Length(Buf) else n := Count;
    Chain.ReadExact(@Buf[0], n);
    Dec(Count, n);
  end;
end;

function ExtractArchive(A: TArchive; const Opt: TExtractOptions; Log: TLogProc): TExtractStats;
var
  b, i, LastWanted: Integer;
  Blk: TArcBlock;
  Chain: TInStage;
  Buf: TBytes;
  OutF: TFileStream;
  OutName: string;
  Remaining: Int64;
  n: SizeInt;
  ActualCrc: LongWord;
  F: TArcFileEntry;
  DoWrite: Boolean;
begin
  Result := Default(TExtractStats);
  SetLength(Buf, COPY_BUF);

  // Directorios primero (incluye los vacíos, que no tienen datos)
  for i := 0 to High(A.Files) do
    if A.Files[i].IsDir and Wanted(Opt, A.Files[i].Name) then
    begin
      if not Opt.TestOnly and not Opt.FlatNames then
        ForceDirectories(DiskName(Opt, A.Files[i].Name));
      Inc(Result.Dirs);
    end;

  for b := 0 to High(A.DataBlocks) do
  begin
    Blk := A.DataBlocks[b];
    // ¿Hay algo que hacer en este bloque? Si no, ni lo abrimos
    LastWanted := -1;
    for i := Blk.FirstFile to Blk.FirstFile + Blk.FileCount - 1 do
      if not A.Files[i].IsDir and Wanted(Opt, A.Files[i].Name) then LastWanted := i;
    if LastWanted < 0 then Continue;

    Chain := nil;
    try
      try
        Chain := CreateDecoderChain(Blk.Method, A.OpenBlockData(Blk));
        for i := Blk.FirstFile to LastWanted do
        begin
          // Copia local a propósito, sin `with`: el campo Crc del registro tapaba la variable
          // local y la verificación de CRC comparaba el valor consigo mismo
          F := A.Files[i];
          if F.IsDir then Continue;
          if not Wanted(Opt, F.Name) then
          begin
            SkipBytes(Chain, F.Size, Buf);
            Continue;
          end;

          OutF := nil;
          DoWrite := not Opt.TestOnly;
          if DoWrite then
          begin
            OutName := DiskName(Opt, F.Name);
            if FileExists(OutName) and (Opt.Overwrite <> owAll) then
            begin
              Log('Saltado (ya existe): ' + OutName);
              Inc(Result.Skipped);
              DoWrite := False;
            end
            else
            begin
              ForceDirectories(ExtractFileDir(ExpandFileName(OutName)));
              OutF := TFileStream.Create(OutName, fmCreate);
            end;
          end;
          try
            ActualCrc := CRC_INIT;
            Remaining := F.Size;
            while Remaining > 0 do
            begin
              if Remaining > Length(Buf) then n := Length(Buf) else n := Remaining;
              Chain.ReadExact(@Buf[0], n);
              ActualCrc := UpdateCRC(ActualCrc, @Buf[0], n);
              if OutF <> nil then OutF.WriteBuffer(Buf[0], n);
              Dec(Remaining, n);
            end;
          finally
            OutF.Free;
          end;
          ActualCrc := ActualCrc xor CRC_INIT;
          if OutF <> nil then SetFileTime(OutName, F.Time);
          if ActualCrc <> F.Crc then
          begin
            Log(Format('ERROR de CRC: %s (esperado %.8x, obtenido %.8x)', [F.Name, F.Crc, ActualCrc]));
            Inc(Result.Errors);
          end
          else if DoWrite or Opt.TestOnly then
          begin
            if Opt.TestOnly then Log('OK       ' + F.Name) else Log('Extraído ' + F.Name);
            Inc(Result.Files);
            Inc(Result.Bytes, F.Size);
          end;
        end;
      except
        on E: EUnsupportedMethod do
        begin
          Log(Format('ERROR: %s (bloque en pos %d, %d archivo(s))', [E.Message, Blk.Pos, Blk.FileCount]));
          Inc(Result.Errors);
        end;
        on E: EArcCorrupt do
        begin
          Log(Format('ERROR: %s (bloque en pos %d)', [E.Message, Blk.Pos]));
          Inc(Result.Errors);
        end;
      end;
    finally
      Chain.Free;
    end;
  end;

  // Las fechas de los directorios se ponen al final (escribir adentro las cambia)
  if not Opt.TestOnly and not Opt.FlatNames then
    for i := 0 to High(A.Files) do
      if A.Files[i].IsDir and Wanted(Opt, A.Files[i].Name) then
        SetFileTime(DiskName(Opt, A.Files[i].Name), A.Files[i].Time);
end;

end.
