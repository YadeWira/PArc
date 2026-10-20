{ Extracción y test. Cada bloque sólido se descomprime una sola vez, en streaming, y la salida
  se reparte entre sus archivos en orden (los offsets vienen del directorio, el formato base de FreeArc §6). }
unit parc_extract;

{$mode objfpc}{$H+}

interface

uses
  Classes, SysUtils, parc_archive;

type
  TOverwriteMode = (owAsk, owAll, owSkip);
  TOverwriteAnswer = (oaYes, oaNo, oaAll, oaNone);
  { Pregunta si se sobrescribe Name (owAsk). "Todos"/"ninguno" valen para el resto. }
  TAskOverwriteFunc = function(const Name: string): TOverwriteAnswer;

  TExtractOptions = record
    TestOnly: Boolean;       // `t`: descomprime y verifica CRC sin escribir
    DestDir: string;         // directorio de salida ('' = actual)
    FlatNames: Boolean;      // `e`: sin rutas
    Overwrite: TOverwriteMode;
    AskOverwrite: TAskOverwriteFunc;   // para owAsk; nil = saltear (sin consola a quién preguntar)
    Filter: TStringList;     // nombres/máscaras a incluir (nil = todos)
    UnsafeLinks: Boolean;    // -snld: crear también enlaces absolutos o que salen del destino
    ToStdout: Boolean;       // -so: el contenido de los archivos a stdout (sin crear nada)
  end;

  TExtractStats = record
    Files, Dirs, Errors, Skipped: Integer;
    Bytes: Int64;
    Unsupported: Boolean;   // algún bloque usa un método que PArc todavía no sabe leer
  end;

  TLogProc = procedure(const Msg: string);

function ExtractArchive(A: TArchive; const Opt: TExtractOptions; Log: TLogProc): TExtractStats;

{ Comodines estilo FreeArc ('*', '?'); en Windows sin distinguir mayúsculas. }
function MatchWild(const Name, Mask: string): Boolean;

{ ¿Name coincide con alguna máscara (nombre completo, nombre base o prefijo de directorio)? }
function MatchesAny(const Name: string; Masks: TStrings): Boolean;

implementation

uses
  DateUtils, parc_os, parc_bytes, parc_crc, parc_stream, parc_methods, parc_progress;

const
  COPY_BUF = 1 shl 20;

{ Comodines estilo FreeArc: '*' = cualquier secuencia, '?' = un carácter.
  En Windows sin distinguir mayúsculas. Backtracking simple sobre el último '*'. }
function MatchWildRaw(const Name, Mask: string): Boolean;
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

{ Como en DOS/Windows (y el pendiente de FreeArc "*.* и makefile.* должны включать makefile"):
  una máscara que termina en ".*" también vale para nombres sin punto. }
function MatchWild(const Name, Mask: string): Boolean;
begin
  Result := MatchWildRaw(Name, Mask);
  if not Result and (Length(Mask) >= 2) and (Copy(Mask, Length(Mask) - 1, 2) = '.*')
     and (Pos('.', Name) = 0) then
    Result := MatchWildRaw(Name, Copy(Mask, 1, Length(Mask) - 2));
end;

function MatchesAny(const Name: string; Masks: TStrings): Boolean;
var
  i: Integer;
begin
  if Masks <> nil then
    for i := 0 to Masks.Count - 1 do
      if MatchWild(Name, Masks[i]) or MatchWild(Copy(Name, LastDelimiter('/', Name) + 1, MaxInt), Masks[i])
         or (Name = Masks[i]) or (Copy(Name, 1, Length(Masks[i]) + 1) = Masks[i] + '/') then
        Exit(True);
  Result := False;
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

{ Fecha (con ns si el archivo es .parc) y permisos/atributos. Los permisos van después de la
  fecha: en Windows un archivo de solo lectura ya no aceptaría el cambio de fecha. }
procedure RestoreMeta(const FileName: string; const F: TArcFileEntry);
begin
  if F.HasMTimeNs then SetFileMTimeNs(FileName, F.MTimeNs)
  else SetFileMTimeNs(FileName, F.Time * 1000000000);
  SetFileAttrs(FileName, F.HasUnixMode, F.UnixMode, F.HasWinAttr, F.WinAttr);
end;

{ ¿El enlace Name -> Target apunta fuera de la carpeta de extracción? Absoluto, o con ".." que
  sube más allá de la raíz (contando desde el directorio del enlace). Un enlace así permitiría
  que otro archivo (de este o de otro archivo comprimido) se escriba fuera del destino. }
function LinkEscapes(const Name, Target: string): Boolean;
var
  Depth, i: Integer;
  Part, T: string;
  Parts: TStringArray;
begin
  T := StringReplace(Target, '\', '/', [rfReplaceAll]);
  if (T = '') or (T[1] = '/') or ((Length(T) >= 2) and (T[2] = ':')) then Exit(True);
  Depth := 0;
  for i := 1 to Length(Name) do
    if Name[i] = '/' then Inc(Depth);   // directorios por encima del enlace dentro del archivo
  Parts := T.Split(['/']);
  for Part in Parts do
    if Part = '..' then
    begin
      Dec(Depth);
      if Depth < 0 then Exit(True);
    end
    else if (Part <> '') and (Part <> '.') then Inc(Depth);
  Result := False;
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
    ProgressAdd(n);
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
  Lm: TFileMeta;
  DoWrite, Opened: Boolean;
  StdOutS: TStream;        // -so
  Cur: Integer;            // el archivo que se está procesando en el bloque (-1: ninguno)
  CurWriting: Boolean;     //   y si ya se estaba escribiendo en el disco
  BlockDamaged: Boolean;

  { El bloque se cortó (datos dañados o método desconocido): se informa cada archivo pedido
    que quedó sin extraer, y el que estaba a medio escribir queda con lo que se recuperó. }
  procedure ReportLost(const Blk: TArcBlock; LastWanted: Integer);
  var
    k: Integer;
  begin
    BlockDamaged := True;
    if Cur < 0 then Cur := Blk.FirstFile;
    for k := Cur to LastWanted do
      if not A.Files[k].IsDir and not A.Files[k].IsLink and Wanted(Opt, A.Files[k].Name) then
      begin
        if (k = Cur) and CurWriting then
          Log('ERROR: ' + A.Files[k].Name + ' quedó incompleto (se dejó lo que se pudo recuperar)')
        else if Opt.TestOnly then
          Log('ERROR: ' + A.Files[k].Name + ' no se pudo verificar')
        else
          Log('ERROR: ' + A.Files[k].Name + ' no se pudo extraer');
        Inc(Result.Errors);
      end;
  end;

var
  Total: Int64;
  Mode: TOverwriteMode;
  Ask: TOverwriteAnswer;

  // Hasta qué archivo hay que descomprimir el bloque b (-1: nada que hacer en él)
  function LastWantedIn(const Blk: TArcBlock): Integer;
  var
    k: Integer;
  begin
    Result := -1;
    for k := Blk.FirstFile to Blk.FirstFile + Blk.FileCount - 1 do
      if not A.Files[k].IsDir and not A.Files[k].IsLink and Wanted(Opt, A.Files[k].Name) then Result := k;
  end;

begin
  Result := Default(TExtractStats);
  BlockDamaged := False;
  StdOutS := nil;
  if Opt.ToStdout then
    StdOutS := THandleStream.Create(StdoutHandle);
  try
  SetLength(Buf, COPY_BUF);
  Mode := Opt.Overwrite;

  // Total para el progreso: lo que se descomprime, incluidos los archivos no pedidos que hay
  // que atravesar dentro de un bloque sólido
  Total := 0;
  for b := 0 to High(A.DataBlocks) do
  begin
    LastWanted := LastWantedIn(A.DataBlocks[b]);
    for i := A.DataBlocks[b].FirstFile to LastWanted do
      if not A.Files[i].IsDir then Inc(Total, A.Files[i].Size);
  end;
  if Opt.TestOnly then ProgressBegin('Verificando', Total) else ProgressBegin('Extrayendo', Total);

  // Directorios primero (incluye los vacíos, que no tienen datos)
  for i := 0 to High(A.Files) do
    if A.Files[i].IsDir and Wanted(Opt, A.Files[i].Name) then
    begin
      if not Opt.TestOnly and not Opt.FlatNames and not Opt.ToStdout then
        MakeDirs(DiskName(Opt, A.Files[i].Name));
      Inc(Result.Dirs);
    end;

  for b := 0 to High(A.DataBlocks) do
  begin
    Blk := A.DataBlocks[b];
    // ¿Hay algo que hacer en este bloque? Si no, ni lo abrimos
    LastWanted := LastWantedIn(Blk);
    if LastWanted < 0 then Continue;

    Chain := nil;
    Cur := -1;
    CurWriting := False;
    try
      try
        Chain := CreateDecoderChain(Blk.Method, A.OpenBlockData(Blk));
        for i := Blk.FirstFile to LastWanted do
        begin
          Cur := i;
          CurWriting := False;
          // Copia local a propósito, sin `with`: el campo Crc del registro tapaba la variable
          // local y la verificación de CRC comparaba el valor consigo mismo
          F := A.Files[i];
          if F.IsDir or F.IsLink then Continue;   // los enlaces se crean al final
          if not Wanted(Opt, F.Name) then
          begin
            SkipBytes(Chain, F.Size, Buf);
            Continue;
          end;

          ProgressFile(F.Name);
          OutF := nil;
          DoWrite := not Opt.TestOnly and not Opt.ToStdout;
          // Un archivo de más de 4 GB no entra en FAT/FAT32: avisarlo antes, en vez de escribir
          // 4 GB y fallar con "Stream write error" (FreeArc además se colgaba, #168)
          if DoWrite and (F.Size > High(LongWord)) and IsFatVolume(ExtractFileDir(ExpandFileName(DiskName(Opt, F.Name)))) then
          begin
            Log(Format('ERROR: %s mide %d bytes y el destino es FAT/FAT32 (máximo 4 GB por archivo): no se extrae',
              [F.Name, F.Size]));
            Inc(Result.Errors);
            SkipBytes(Chain, F.Size, Buf);
            Cur := i + 1;
            Continue;
          end;
          if DoWrite then
          begin
            OutName := DiskName(Opt, F.Name);
            if FileExists(FsPath(OutName)) and (Mode = owAsk) then
              if not Assigned(Opt.AskOverwrite) then Ask := oaNo
              else
              begin
                Ask := Opt.AskOverwrite(OutName);
                if Ask = oaAll then Mode := owAll else if Ask = oaNone then Mode := owSkip;
              end
            else if Mode = owAll then Ask := oaYes
            else Ask := oaNo;
            if FileExists(FsPath(OutName)) and (Ask in [oaNo, oaNone]) then
            begin
              Log('Saltado (ya existe): ' + OutName);
              Inc(Result.Skipped);
              DoWrite := False;
            end
            else
            begin
              MakeDirs(ExtractFileDir(ExpandFileName(OutName)));
              OutF := TFileStream.Create(FsPath(OutName), fmCreate);
            end;
          end;
          Opened := OutF <> nil;
          CurWriting := Opened;
          try
            try
              ActualCrc := CRC_INIT;
              Remaining := F.Size;
              while Remaining > 0 do
              begin
                if Remaining > Length(Buf) then n := Length(Buf) else n := Remaining;
                Chain.ReadExact(@Buf[0], n);
                ActualCrc := UpdateCRC(ActualCrc, @Buf[0], n);
                if OutF <> nil then OutF.WriteBuffer(Buf[0], n)
                else if StdOutS <> nil then StdOutS.WriteBuffer(Buf[0], n);
                ProgressAdd(n);
                Dec(Remaining, n);
              end;
            finally
              OutF.Free;
            end;
          except
            // Cancelado a mitad de un archivo: no dejarlo a medias en el disco
            on EOperationCancelled do
            begin
              if Opened then DeleteFile(FsPath(OutName));
              raise;
            end;
            // No se pudo escribir (disco lleno, sin permiso...): tampoco se deja a medias, y se
            // corta todo, porque los que siguen fallarían igual
            on E: EStreamError do
            begin
              if Opened then
              begin
                DeleteFile(FsPath(OutName));
                raise EInOutError.CreateFmt('no se pudo escribir %s (%s): ¿disco lleno o sin permiso?',
                  [OutName, E.Message]);
              end;
              raise;
            end;
          end;
          ActualCrc := ActualCrc xor CRC_INIT;
          CurWriting := False;
          Cur := i + 1;   // este ya se informa abajo; si el bloque se corta, desde el siguiente
          if OutF <> nil then RestoreMeta(OutName, F);
          if ActualCrc <> F.Crc then
          begin
            Log(Format('ERROR de CRC: %s (esperado %.8x, obtenido %.8x)', [F.Name, F.Crc, ActualCrc]));
            Inc(Result.Errors);
          end
          else if DoWrite or Opt.TestOnly or Opt.ToStdout then
          begin
            if Opt.TestOnly then Log('OK       ' + F.Name) else Log('Extraído ' + F.Name);
            Inc(Result.Files);
            Inc(Result.Bytes, F.Size);
          end;
        end;
      except
        on E: EUnsupportedMethod do
        begin
          Result.Unsupported := True;
          Log(Format('ERROR: %s (bloque en pos %d, %d archivo(s))', [E.Message, Blk.Pos, Blk.FileCount]));
          ReportLost(Blk, LastWanted);
        end;
        on E: EArcCorrupt do
        begin
          Log(Format('ERROR: %s (bloque en pos %d)', [E.Message, Blk.Pos]));
          ReportLost(Blk, LastWanted);
        end;
      end;
    finally
      Chain.Free;
    end;
  end;

  ProgressEnd;
  // Los demás bloques se extrajeron igual; con registro de recuperación, se puede reparar
  if BlockDamaged and (A.Recovery <> '') then
    Log('El archivo tiene registro de recuperación: "parc r ' + ExtractFileName(A.FileName) +
      '" intenta repararlo (escribe fixed.' + ExtractFileName(A.FileName) + ').');

  // Enlaces simbólicos, al final: si se crearan antes, un archivo de este mismo archivo
  // comprimido podría escribirse a través de uno de ellos
  for i := 0 to High(A.Files) do
  begin
    F := A.Files[i];
    if not F.IsLink or not Wanted(Opt, F.Name) or Opt.ToStdout then Continue;
    if Opt.TestOnly then
    begin
      Log('OK       ' + F.Name + ' -> ' + F.LinkTarget);
      Inc(Result.Files);
      Continue;
    end;
    // con `e` (sin rutas) el enlace queda en la raíz del destino: se mide desde ahí
    if Opt.FlatNames then OutName := Copy(F.Name, LastDelimiter('/', F.Name) + 1, MaxInt) else OutName := F.Name;
    if LinkEscapes(OutName, F.LinkTarget) and not Opt.UnsafeLinks then
    begin
      Log('Aviso: no se crea el enlace ' + F.Name + ' -> ' + F.LinkTarget +
        ' (apunta fuera del destino; -snld lo permite)');
      Inc(Result.Skipped);
      Continue;
    end;
    OutName := DiskName(Opt, F.Name);
    Opened := GetLinkMeta(OutName, Lm) or FileExists(FsPath(OutName)) or DirectoryExists(FsPath(OutName));
    if Opened then
    begin
      if Mode = owAsk then
        if not Assigned(Opt.AskOverwrite) then Ask := oaNo
        else
        begin
          Ask := Opt.AskOverwrite(OutName);
          if Ask = oaAll then Mode := owAll else if Ask = oaNone then Mode := owSkip;
        end
      else if Mode = owAll then Ask := oaYes
      else Ask := oaNo;
      // un directorio de verdad no se reemplaza por un enlace
      if (Ask in [oaNo, oaNone]) or (not GetLinkMeta(OutName, Lm) and DirectoryExists(FsPath(OutName))) then
      begin
        Log('Saltado (ya existe): ' + OutName);
        Inc(Result.Skipped);
        Continue;
      end;
      if not DeleteFile(FsPath(OutName)) then RemoveDir(FsPath(OutName));   // (un enlace a dir en Windows)
    end;
    MakeDirs(ExtractFileDir(ExpandFileName(OutName)));
    if MakeSymLink(OutName, F.LinkTarget, F.LinkToDir) then
    begin
      Log('Extraído ' + F.Name + ' -> ' + F.LinkTarget);
      Inc(Result.Files);
    end
    else
    begin
      Log('Aviso: no se pudo crear el enlace ' + OutName + ' -> ' + F.LinkTarget
        {$IFDEF WINDOWS} + ' (en Windows hace falta modo desarrollador o ser administrador)'{$ENDIF});
      Inc(Result.Skipped);
    end;
  end;

  // Las fechas de los directorios se ponen al final (escribir adentro las cambia)
  if not Opt.TestOnly and not Opt.FlatNames and not Opt.ToStdout then
    for i := 0 to High(A.Files) do
      if A.Files[i].IsDir and Wanted(Opt, A.Files[i].Name) then
        RestoreMeta(DiskName(Opt, A.Files[i].Name), A.Files[i]);
  finally
    StdOutS.Free;   // (THandleStream no cierra el handle)
  end;
end;

end.
