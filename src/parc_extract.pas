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
  DateUtils, parc_os, parc_bytes, parc_crc, parc_stream, parc_methods, parc_progress, parc_parallel, parc_volume,
  parc_strmap;

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
    raise EArcCorrupt.CreateFmt('unsafe name in archive: "%s"', [Name]);
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

{ Verificación de un bloque en un hilo. No escribe nada: descomprime, calcula CRCs y
  guarda los mensajes para que el hilo principal los emita en orden. }
type
  TVerifyJob = class(TParallelJob)
  public
    A: TArchive;
    BlockIndex: Integer;
    Opt: TExtractOptions;
    Stats: TExtractStats;
    Messages: TStringList;
    Damaged: Boolean;
    Orig: Int64;           // bytes que se descomprimen (para el progreso)
    DoneKB: LongInt;       // progreso, en KB: lo suma el hilo principal (ProgressAdd no es
                           // para otros hilos)
    constructor Create;
    destructor Destroy; override;
    procedure Process; override;
  end;

constructor TVerifyJob.Create;
begin
  inherited Create;
  Messages := TStringList.Create;
end;

destructor TVerifyJob.Destroy;
begin
  Messages.Free;
  inherited Destroy;
end;

procedure TVerifyJob.Process;
var
  Blk: TArcBlock;
  Stream: TStream;
  Chain: TInStage;
  Buf: TBytes;
  i, Cur, LastWanted, n: Integer;
  F: TArcFileEntry;
  Crc: LongWord;
  Remaining, Pending: Int64;

  procedure Advance(Bytes: Int64);
  begin
    Inc(Pending, Bytes);
    if Pending >= 1024 then
    begin
      InterlockedExchangeAdd(DoneKB, LongInt(Pending shr 10));
      Pending := Pending and 1023;
    end;
    CheckCancel;
  end;

  procedure MarkRemaining;
  var k: Integer;
  begin
    for k := Cur to LastWanted do
      if not A.Files[k].IsDir and not A.Files[k].IsLink and Wanted(Opt, A.Files[k].Name) then
      begin
        Messages.Add('ERROR: ' + A.Files[k].Name + ' could not be verified');
        Inc(Stats.Errors);
      end;
  end;

begin
  Stats := Default(TExtractStats);
  Damaged := False;
  Pending := 0;
  Blk := A.DataBlocks[BlockIndex];
  LastWanted := -1;
  for i := Blk.FirstFile to Blk.FirstFile + Blk.FileCount - 1 do
    if not A.Files[i].IsDir and not A.Files[i].IsLink and Wanted(Opt, A.Files[i].Name) then LastWanted := i;
  Orig := 0;
  for i := Blk.FirstFile to LastWanted do
    if not A.Files[i].IsDir then Inc(Orig, A.Files[i].Size);
  if LastWanted < 0 then Exit;

  SetLength(Buf, COPY_BUF);
  Stream := OpenArchiveStream(A.FileName);
  Cur := Blk.FirstFile;
  try
    try
      Chain := CreateDecoderChain(Blk.Method, TFileSliceStage.Create(Stream, Blk.Pos, Blk.CompSize));
      try
      for i := Blk.FirstFile to LastWanted do
      begin
        Cur := i;
        F := A.Files[i];
        if F.IsDir or F.IsLink then Continue;
        if not Wanted(Opt, F.Name) then
        begin
          Remaining := F.Size;   // (solo hay que atravesarlo)
          while Remaining > 0 do
          begin
            if Remaining > Length(Buf) then n := Length(Buf) else n := Remaining;
            Chain.ReadExact(@Buf[0], n);
            Advance(n);
            Dec(Remaining, n);
          end;
          Continue;
        end;
        Crc := CRC_INIT;
        Remaining := F.Size;
        while Remaining > 0 do
        begin
          if Remaining > Length(Buf) then n := Length(Buf) else n := Remaining;
          Chain.ReadExact(@Buf[0], n);
          Crc := UpdateCRC(Crc, @Buf[0], n);
          Advance(n);
          Dec(Remaining, n);
        end;
        if (Crc xor CRC_INIT) <> F.Crc then
        begin
          Messages.Add(Format('CRC ERROR: %s (expected %.8x, got %.8x)', [F.Name, F.Crc, Crc xor CRC_INIT]));
          Inc(Stats.Errors);
        end
        else
        begin
          Messages.Add('OK       ' + F.Name);
          Inc(Stats.Files);
          Inc(Stats.Bytes, F.Size);
        end;
      end;
      finally
        Chain.Free;
      end;
    except
      on E: EUnsupportedMethod do
      begin
        Damaged := True;
        Stats.Unsupported := True;
        Messages.Add(Format('ERROR: %s (block at %d, %d file(s))', [E.Message, Blk.Pos, Blk.FileCount]));
        MarkRemaining;
      end;
      on E: EArcCorrupt do
      begin
        Damaged := True;
        Messages.Add(Format('ERROR: %s (block at %d)', [E.Message, Blk.Pos]));
        MarkRemaining;
      end;
    end;
  finally
    Stream.Free;
  end;
end;

{ `t` con bloques independientes en paralelo. La salida se emite en orden de bloque. }
function VerifyArchiveParallel(A: TArchive; const Opt: TExtractOptions; Log: TLogProc): TExtractStats;
var
  Total, Orig: Int64;
  b, i, n, Count, LastWanted: Integer;
  Jobs: array of TVerifyJob;
  Pool: TJobPool;
  Damaged, Finished: Boolean;
  Reported: array of Int64;
  Done: Int64;
  k: Integer;
begin
  Result := Default(TExtractStats);
  Damaged := False;
  Total := 0;
  for b := 0 to High(A.DataBlocks) do
  begin
    LastWanted := -1;
    for i := A.DataBlocks[b].FirstFile to A.DataBlocks[b].FirstFile + A.DataBlocks[b].FileCount - 1 do
      if not A.Files[i].IsDir and not A.Files[i].IsLink and Wanted(Opt, A.Files[i].Name) then LastWanted := i;
    for i := A.DataBlocks[b].FirstFile to LastWanted do
      if not A.Files[i].IsDir then Inc(Total, A.Files[i].Size);
  end;
  ProgressBegin('Verifying', Total);

  for i := 0 to High(A.Files) do
    if A.Files[i].IsDir and Wanted(Opt, A.Files[i].Name) then Inc(Result.Dirs);

  Count := 0;
  for b := 0 to High(A.DataBlocks) do
  begin
    LastWanted := -1;
    for i := A.DataBlocks[b].FirstFile to A.DataBlocks[b].FirstFile + A.DataBlocks[b].FileCount - 1 do
      if not A.Files[i].IsDir and not A.Files[i].IsLink and Wanted(Opt, A.Files[i].Name) then LastWanted := i;
    if LastWanted >= 0 then Inc(Count);
  end;
  SetLength(Jobs, Count);
  n := 0;
  for b := 0 to High(A.DataBlocks) do
  begin
    LastWanted := -1;
    for i := A.DataBlocks[b].FirstFile to A.DataBlocks[b].FirstFile + A.DataBlocks[b].FileCount - 1 do
      if not A.Files[i].IsDir and not A.Files[i].IsLink and Wanted(Opt, A.Files[i].Name) then LastWanted := i;
    if LastWanted < 0 then Continue;
    Jobs[n] := TVerifyJob.Create;
    Jobs[n].A := A;
    Jobs[n].BlockIndex := b;
    Jobs[n].Opt := Opt;
    Inc(n);
  end;

  // Mensajes y estadísticas en orden de bloque, como el camino serial; el progreso lo suma
  // este hilo con lo que va avisando cada trabajo (también con un solo bloque: así se ve)
  SetLength(Reported, Count);
  try
    if Count > 0 then
    begin
      Pool := TJobPool.Create(ThreadCount(4), Count);
      try
        for i := 0 to Count - 1 do Pool.Submit(Jobs[i]);
        for i := 0 to Count - 1 do
          repeat
            Finished := Pool.WaitJobFor(Jobs[i], PROGRESS_INTERVAL);
            for k := i to Count - 1 do
            begin
              Done := Int64(Jobs[k].DoneKB) shl 10;
              if Done > Reported[k] then
              begin
                ProgressAdd(Done - Reported[k]);
                Reported[k] := Done;
              end;
            end;
          until Finished;
      finally
        Pool.Free;
      end;
    end;

    for i := 0 to Count - 1 do
    begin
      for n := 0 to Jobs[i].Messages.Count - 1 do Log(Jobs[i].Messages[n]);
      Inc(Result.Files, Jobs[i].Stats.Files);
      Inc(Result.Errors, Jobs[i].Stats.Errors);
      Inc(Result.Bytes, Jobs[i].Stats.Bytes);
      if Jobs[i].Stats.Unsupported then Result.Unsupported := True;
      if Jobs[i].Damaged then Damaged := True;
      Orig := Jobs[i].Orig;
      if Orig > Reported[i] then ProgressAdd(Orig - Reported[i]);
    end;
  finally
    for i := 0 to Count - 1 do Jobs[i].Free;
  end;

  // Enlaces: no tienen datos, se verifican como en el camino serial.
  for i := 0 to High(A.Files) do
    if A.Files[i].IsLink and Wanted(Opt, A.Files[i].Name) then
    begin
      Log('OK       ' + A.Files[i].Name + ' -> ' + A.Files[i].LinkTarget);
      Inc(Result.Files);
    end;

  ProgressEnd;
  if Damaged and (A.Recovery <> '') then
    Log('The archive has a recovery record: "parc r ' + ExtractFileName(A.FileName) +
      '" will try to repair it (writes fixed.' + ExtractFileName(A.FileName) + ').');
end;

{ Decodifica un bloque completo a un temporal, en un hilo. La extracción posterior lee de ese
  temporal y conserva el orden y el comportamiento del camino serial. }
type
  TDecodeTemps = array of string;

  TDecodeBlockJob = class(TParallelJob)
  public
    A: TArchive;
    BlockIndex: Integer;
    TempName: string;
    OK: Boolean;
    ErrMsg: string;
    procedure Process; override;
  end;

procedure TDecodeBlockJob.Process;
var
  Blk: TArcBlock;
  Stream, OutS: TStream;
  Chain: TInStage;
  Buf: TBytes;
  Remaining: Int64;
  n: SizeInt;
begin
  OK := False;
  try
    Blk := A.DataBlocks[BlockIndex];
    Stream := OpenArchiveStream(A.FileName);
    try
      Chain := CreateDecoderChain(Blk.Method, TFileSliceStage.Create(Stream, Blk.Pos, Blk.CompSize));
      try
        OutS := TFileStream.Create(FsPath(TempName), fmCreate);
        try
          SetLength(Buf, COPY_BUF);
          Remaining := Blk.OrigSize;
          while Remaining > 0 do
          begin
            if Remaining > Length(Buf) then n := Length(Buf) else n := Remaining;
            Chain.ReadExact(@Buf[0], n);
            OutS.WriteBuffer(Buf[0], n);
            Dec(Remaining, n);
          end;
        finally
          OutS.Free;
        end;
      finally
        Chain.Free;
      end;
    finally
      Stream.Free;
    end;
    OK := True;
  except
    on E: EOperationCancelled do raise;
    on E: Exception do
    begin
      OK := False;
      ErrMsg := E.Message;
    end;
  end;
end;

{ Decodifica en paralelo los bloques que tienen archivos pedidos. Si algo falla, borra los
  temporales y devuelve False: la extracción sigue por el camino serial normal. }
function TryDecodeBlocksParallel(A: TArchive; const Opt: TExtractOptions;
  out Temps: TDecodeTemps): Boolean;
const
  MAX_DECODED = Int64(2) shl 30;
var
  b, i, n, Count, LastWanted: Integer;
  Total: Int64;
  Jobs: array of TDecodeBlockJob;
  Pool: TJobPool;
  Tmp: string;
begin
  Result := False;
  Temps := nil;
  SetLength(Temps, Length(A.DataBlocks));
  Count := 0;
  Total := 0;
  for b := 0 to High(A.DataBlocks) do
  begin
    LastWanted := -1;
    for i := A.DataBlocks[b].FirstFile to A.DataBlocks[b].FirstFile + A.DataBlocks[b].FileCount - 1 do
      if not A.Files[i].IsDir and not A.Files[i].IsLink and Wanted(Opt, A.Files[i].Name) then LastWanted := i;
    if LastWanted >= 0 then
    begin
      Inc(Count);
      Inc(Total, A.DataBlocks[b].OrigSize);
    end;
  end;
  if (Count < 2) or (Total > MAX_DECODED) then Exit;

  SetLength(Jobs, Count);
  n := 0;
  for b := 0 to High(A.DataBlocks) do
  begin
    LastWanted := -1;
    for i := A.DataBlocks[b].FirstFile to A.DataBlocks[b].FirstFile + A.DataBlocks[b].FileCount - 1 do
      if not A.Files[i].IsDir and not A.Files[i].IsLink and Wanted(Opt, A.Files[i].Name) then LastWanted := i;
    if LastWanted < 0 then Continue;
    Tmp := A.FileName + Format('.dec-%d-%d', [GetProcessID, b]);
    DeleteFile(FsPath(Tmp));
    Temps[b] := Tmp;
    Jobs[n] := TDecodeBlockJob.Create;
    Jobs[n].A := A;
    Jobs[n].BlockIndex := b;
    Jobs[n].TempName := Tmp;
    Inc(n);
  end;

  Pool := TJobPool.Create(ThreadCount(4), Count);
  try
    try
      for i := 0 to Count - 1 do Pool.Submit(Jobs[i]);
      for i := 0 to Count - 1 do Pool.WaitJob(Jobs[i]);
      Result := True;
      for i := 0 to Count - 1 do
        if not Jobs[i].OK then Result := False;
    finally
      Pool.Free;
    end;
  except
    for i := 0 to High(Temps) do
      if Temps[i] <> '' then DeleteFile(FsPath(Temps[i]));
    for i := 0 to Count - 1 do Jobs[i].Free;
    raise;
  end;
  for i := 0 to Count - 1 do Jobs[i].Free;
  if not Result then
  begin
    for i := 0 to High(Temps) do
      if Temps[i] <> '' then DeleteFile(FsPath(Temps[i]));
    Temps := nil;
  end;
end;

{ Extracción paralela directa: cada hilo descomprime un bloque y escribe sus archivos en el
  destino, sin el temporal intermedio (que escribía y releía todo dos veces y solo se usaba
  hasta 2 GB). Cada bloque hace lo mismo que el camino serial (mismos mensajes, mismo manejo de
  bloques dañados y de archivos a medias); los mensajes se guardan y se emiten en orden de
  bloque. Solo se usa cuando el resultado no depende del orden entre bloques: sin nombres de
  destino repetidos (tampoco sin distinguir mayúsculas: el destino puede ser vfat/exFAT/NTFS),
  sin preguntas de sobrescritura y sin -so/t.
  Memoria: los bloques que se decodifican a la vez se limitan según lo que estima cada
  decodificador; si igual falta memoria (EOutOfMemory), el trabajo borra lo que había escrito
  y el bloque se rehace después, en el hilo principal y sin otros decodificadores en marcha,
  como en el camino serial. }
type
  { Lo compartido por los trabajos de una extracción. }
  TExtractShared = class
  public
    DirLock: TRTLCriticalSection;
    Dirs: TStrIntMap;      // directorios de destino ya creados
    Abort: LongInt;        // 1: otro trabajo falló sin remedio, los demás cortan
    LowMem: LongInt;       // 1: a alguno le faltó memoria; los que no empezaron se postergan
    constructor Create;
    destructor Destroy; override;
    procedure EnsureDir(const Dir: string);
  end;

  EExtractAborted = class(Exception);

  TExtractBlockJob = class(TParallelJob)
  public
    A: TArchive;
    BlockIndex: Integer;
    Opt: TExtractOptions;
    Mode: TOverwriteMode;
    Shared: TExtractShared;
    Stats: TExtractStats;
    Messages: TStringList;
    Damaged: Boolean;
    Orig: Int64;           // bytes que se descomprimen (para el progreso)
    DoneKB: LongInt;       // progreso, en KB (lo lee el hilo principal)
    Reported: Int64;       // lo que el hilo principal ya pasó al progreso
    CurFile: LongInt;      // índice del archivo en curso (-1: ninguno)
    OutOfMem: Boolean;     // faltó memoria (o se postergó): rehacer en el hilo principal
    InMainThread: Boolean; // rehecho en el hilo principal: informa el progreso directamente
    Created: TStringList;  // archivos que este trabajo creó (se borran si hay que rehacerlo)
    constructor Create;
    destructor Destroy; override;
    procedure Extract;
    procedure Process; override;
    procedure ReportProgress;
  end;

constructor TExtractShared.Create;
begin
  inherited Create;
  InitCriticalSection(DirLock);
  Dirs.Init(256);
end;

destructor TExtractShared.Destroy;
begin
  DoneCriticalSection(DirLock);
  inherited Destroy;
end;

procedure TExtractShared.EnsureDir(const Dir: string);
begin
  EnterCriticalSection(DirLock);
  try
    if Dirs.Get(Dir) < 0 then
    begin
      MakeDirs(Dir);
      Dirs.Put(Dir, 1);
    end;
  finally
    LeaveCriticalSection(DirLock);
  end;
end;

constructor TExtractBlockJob.Create;
begin
  inherited Create;
  Messages := TStringList.Create;
  Created := TStringList.Create;
  CurFile := -1;
end;

destructor TExtractBlockJob.Destroy;
begin
  Messages.Free;
  Created.Free;
  inherited Destroy;
end;

{ En un hilo del pool. Si falta memoria no es un error todavía: se deshace lo hecho (lo que se
  escribió se borra; los mensajes y las estadísticas se descartan) y el hilo principal lo
  rehace cuando no quede ningún otro decodificador en marcha. }
procedure TExtractBlockJob.Process;
var
  k: Integer;
begin
  OutOfMem := False;
  if Shared.LowMem <> 0 then
  begin
    OutOfMem := True;   // postergado: no sumarle otro decodificador a los que ya no entran
    Exit;
  end;
  try
    Extract;
  except
    on EOutOfMemory do
    begin
      InterlockedExchange(Shared.LowMem, 1);
      for k := 0 to Created.Count - 1 do DeleteFile(FsPath(Created[k]));
      Created.Clear;
      Messages.Clear;
      CurFile := -1;
      OutOfMem := True;
    end;
  end;
end;

{ Solo desde el hilo principal. }
procedure TExtractBlockJob.ReportProgress;
var
  Done: Int64;
begin
  Done := Int64(DoneKB) shl 10;
  if Done > Reported then
  begin
    ProgressAdd(Done - Reported);
    Reported := Done;
  end;
end;

procedure TExtractBlockJob.Extract;
var
  Blk: TArcBlock;
  Stream: TStream;
  Chain: TInStage;
  Buf: TBytes;
  i, Cur, LastWanted: Integer;
  n: SizeInt;
  F: TArcFileEntry;
  ActualCrc: LongWord;
  Remaining, Pending: Int64;
  OutF: TFileStream;
  OutName: string;
  DoWrite, Opened, CurWriting: Boolean;

  // Progreso (en KB, que el hilo principal suma) y corte si se canceló o si otro trabajo falló
  procedure Advance(Bytes: Int64);
  begin
    Inc(Pending, Bytes);
    if Pending >= 1024 then
    begin
      InterlockedExchangeAdd(DoneKB, LongInt(Pending shr 10));
      Pending := Pending and 1023;
      if InMainThread then ReportProgress;
    end;
    CheckCancel;
    if Shared.Abort <> 0 then raise EExtractAborted.Create('aborted');
  end;

  procedure Skip(Count: Int64);
  begin
    while Count > 0 do
    begin
      if Count > Length(Buf) then n := Length(Buf) else n := Count;
      Chain.ReadExact(@Buf[0], n);
      Advance(n);
      Dec(Count, n);
    end;
  end;

  procedure MarkRemaining;
  var
    k: Integer;
  begin
    Damaged := True;
    for k := Cur to LastWanted do
      if not A.Files[k].IsDir and not A.Files[k].IsLink and Wanted(Opt, A.Files[k].Name) then
      begin
        if (k = Cur) and CurWriting then
          Messages.Add('ERROR: ' + A.Files[k].Name + ' is incomplete (whatever could be recovered was kept)')
        else
          Messages.Add('ERROR: ' + A.Files[k].Name + ' could not be extracted');
        Inc(Stats.Errors);
      end;
  end;

begin
  Stats := Default(TExtractStats);
  Damaged := False;
  Pending := 0;
  DoneKB := 0;   // (al rehacerlo, el progreso solo avanza cuando pasa lo ya informado)
  Blk := A.DataBlocks[BlockIndex];
  LastWanted := -1;
  for i := Blk.FirstFile to Blk.FirstFile + Blk.FileCount - 1 do
    if not A.Files[i].IsDir and not A.Files[i].IsLink and Wanted(Opt, A.Files[i].Name) then LastWanted := i;
  Orig := 0;
  for i := Blk.FirstFile to LastWanted do
    if not A.Files[i].IsDir then Inc(Orig, A.Files[i].Size);
  if LastWanted < 0 then Exit;
  SetLength(Buf, COPY_BUF);
  Cur := Blk.FirstFile;
  CurWriting := False;
  Stream := OpenArchiveStream(A.FileName);
  try
    try
      Chain := CreateDecoderChain(Blk.Method, TFileSliceStage.Create(Stream, Blk.Pos, Blk.CompSize));
      try
        for i := Blk.FirstFile to LastWanted do
        begin
          Cur := i;
          CurWriting := False;
          F := A.Files[i];
          if F.IsDir or F.IsLink then Continue;   // los enlaces se crean al final
          if not Wanted(Opt, F.Name) then
          begin
            Skip(F.Size);
            Continue;
          end;
          CurFile := i;
          if InMainThread then ProgressFile(F.Name);
          OutName := DiskName(Opt, F.Name);
          OutF := nil;
          DoWrite := True;
          // (como en el camino serial: más de 4 GB no entra en FAT/FAT32)
          if (F.Size > High(LongWord)) and IsFatVolume(ExtractFileDir(ExpandFileName(OutName))) then
          begin
            Messages.Add(Format('ERROR: %s is %d bytes and the destination is FAT/FAT32 (4 GB per-file maximum): not extracted',
              [F.Name, F.Size]));
            Inc(Stats.Errors);
            Skip(F.Size);
            Continue;
          end;
          // Sin preguntas acá (con owAsk solo se llega si no existe ninguno): owAll
          // sobrescribe, lo demás saltea
          if FileExists(FsPath(OutName)) and (Mode <> owAll) then
          begin
            Messages.Add('Skipped (already exists): ' + OutName);
            Inc(Stats.Skipped);
            DoWrite := False;
          end
          else
          begin
            Shared.EnsureDir(ExtractFileDir(ExpandFileName(OutName)));
            OutF := TFileStream.Create(FsPath(OutName), fmCreate);
            Created.Add(OutName);
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
                if OutF <> nil then OutF.WriteBuffer(Buf[0], n);
                Advance(n);
                Dec(Remaining, n);
              end;
            finally
              OutF.Free;
            end;
          except
            on E: EStreamError do
            begin
              if Opened then
              begin
                DeleteFile(FsPath(OutName));
                raise EInOutError.CreateFmt('could not write %s (%s): disk full or permission denied?',
                  [OutName, E.Message]);
              end;
              raise;
            end;
            // Datos dañados o método desconocido: queda lo que se pudo recuperar (como en el
            // camino serial; se informa como incompleto)
            on EArcCorrupt do raise;
            on EUnsupportedMethod do raise;
            // Cualquier otro corte (cancelado, otro bloque falló, falta de memoria...): no
            // dejarlo a medias
            on Exception do
            begin
              if Opened then DeleteFile(FsPath(OutName));
              raise;
            end;
          end;
          ActualCrc := ActualCrc xor CRC_INIT;
          CurWriting := False;
          Cur := i + 1;
          if Opened then RestoreMeta(OutName, F);
          if ActualCrc <> F.Crc then
          begin
            Messages.Add(Format('CRC ERROR: %s (expected %.8x, got %.8x)', [F.Name, F.Crc, ActualCrc]));
            Inc(Stats.Errors);
          end
          else if DoWrite then
          begin
            Messages.Add('Extracted ' + F.Name);
            Inc(Stats.Files);
            Inc(Stats.Bytes, F.Size);
          end;
        end;
      finally
        Chain.Free;
      end;
    except
      on E: EUnsupportedMethod do
      begin
        Stats.Unsupported := True;
        Messages.Add(Format('ERROR: %s (block at %d, %d file(s))', [E.Message, Blk.Pos, Blk.FileCount]));
        MarkRemaining;
      end;
      on E: EArcCorrupt do
      begin
        Messages.Add(Format('ERROR: %s (block at %d)', [E.Message, Blk.Pos]));
        MarkRemaining;
      end;
    end;
  finally
    Stream.Free;
  end;
end;

{ Clave para comparar nombres de destino sin distinguir mayúsculas. En Windows, la del
  sistema; en el resto, el destino también puede no distinguirlas (vfat, exFAT, ntfs3, ext4
  con casefold) y sin cwstring WideLowerCase solo pasa ASCII: se pliegan ASCII, Latin-1,
  Latin Extended-A, griego y cirílico en UTF-8, que es donde hay mayúsculas en la práctica.
  Plegar de más solo hace que se use el camino de siempre. }
function CaseFoldKey(const Name: string): string;
{$IFDEF WINDOWS}
begin
  Result := UTF8Encode(WideLowerCase(UTF8Decode(Name)));
end;
{$ELSE}
var
  i, n: Integer;
  c: LongWord;
begin
  Result := Name;
  n := Length(Result);
  i := 1;
  while i <= n do
  begin
    if Result[i] in ['A'..'Z'] then
    begin
      Result[i] := Chr(Ord(Result[i]) + 32);
      Inc(i);
    end
    else if (Ord(Result[i]) in [$C2..$DF]) and (i < n) and ((Ord(Result[i + 1]) and $C0) = $80) then
    begin
      // Secuencia de 2 bytes: U+0080..U+07FF
      c := (LongWord(Ord(Result[i]) and $1F) shl 6) or LongWord(Ord(Result[i + 1]) and $3F);
      case c of
        $C0..$D6, $D8..$DE: Inc(c, $20);                       // Latin-1
        $100..$137, $14A..$177: c := c or 1;                   // Latin Extended-A (pares)
        $139..$148, $179..$17E: if (c and 1) = 1 then Inc(c);  //   (impares)
        $178: c := $FF;
        $391..$3A1, $3A3..$3AB: Inc(c, $20);                   // griego
        $400..$40F: Inc(c, $50);                               // cirílico
        $410..$42F: Inc(c, $20);
        $460..$481, $48A..$4BF, $4D0..$52F: c := c or 1;
      end;
      Result[i] := Chr($C0 or (c shr 6));
      Result[i + 1] := Chr($80 or (c and $3F));
      Inc(i, 2);
    end
    else
      Inc(i);
  end;
end;
{$ENDIF}

{ Memoria que estima el decodificador de un bloque: por cada etapa, el mayor parámetro de
  memoria (diccionario, ventana de rep, modelo de ppmd...) sin pasar del tamaño del bloque (con
  un mínimo, por los modelos que no dependen de él), más los búferes. Es aproximada: solo
  decide cuántos bloques se decodifican a la vez; si se queda corta, el trabajo al que le falte
  memoria se rehace solo. }
function EstimateDecodeMem(const Method: string; OrigSize: Int64): Int64;
var
  Stages, Params: TStringArray;
  s, k: Integer;
  p: string;
  m: QWord;
  StageMax, Cap: Int64;
begin
  Result := 8 shl 20;
  Cap := OrigSize;
  if Cap < 64 shl 20 then Cap := 64 shl 20;
  Stages := Method.Split(['+']);
  for s := 0 to High(Stages) do
  begin
    Params := Stages[s].Split([':']);
    StageMax := 0;
    for k := 1 to High(Params) do
    begin
      p := Params[k];
      while (p <> '') and not (p[1] in ['0'..'9']) do Delete(p, 1, 1);   // d64m, mem48m, *1gb...
      // Solo con sufijo explícito: un entero pelado suele ser un orden o un nivel
      if (p <> '') and (LowerCase(p[Length(p)]) in ['b', 'k', 'm', 'g']) and ParseMem(p, m) then
        if (m <= QWord(High(Int64))) and (Int64(m) > StageMax) then StageMax := Int64(m);
    end;
    if StageMax > Cap then StageMax := Cap;
    Inc(Result, StageMax);
  end;
end;

{ Cuántos bloques se pueden decodificar a la vez: hasta Threads, mientras los más grandes
  entren en la mitad de la memoria física y del espacio de direcciones (ulimit -v, ~2 GB en
  win32). }
function ThreadsForMemory(const Est: array of Int64; Threads: Integer): Integer;
var
  Sorted: array of Int64;
  i, j: Integer;
  t, Budget, Lim, Sum: Int64;
begin
  Budget := High(Int64);
  Lim := PhysicalMemory;
  if Lim > 0 then Budget := Lim div 2;
  Lim := AddressSpaceLimit;
  if (Lim > 0) and (Lim div 2 < Budget) then Budget := Lim div 2;
  {$IFNDEF CPU64}
  if Budget > Int64(1) shl 30 then Budget := Int64(1) shl 30;
  {$ENDIF}
  SetLength(Sorted, Length(Est));
  for i := 0 to High(Est) do Sorted[i] := Est[i];
  // Los Threads más grandes (selección parcial, de mayor a menor)
  for i := 0 to High(Sorted) do
  begin
    if i >= Threads then Break;
    for j := i + 1 to High(Sorted) do
      if Sorted[j] > Sorted[i] then
      begin
        t := Sorted[i]; Sorted[i] := Sorted[j]; Sorted[j] := t;
      end;
  end;
  Result := 0;
  Sum := 0;
  while (Result < Threads) and (Result <= High(Sorted)) do
  begin
    if Sum + Sorted[Result] > Budget then Break;
    Inc(Sum, Sorted[Result]);
    Inc(Result);
  end;
end;

{ Intenta la extracción paralela directa. False (sin haber tocado nada) si no corresponde. }
function TryExtractParallel(A: TArchive; const Opt: TExtractOptions; Mode: TOverwriteMode;
  Log: TLogProc; var Stats: TExtractStats; var Damaged: Boolean): Boolean;
var
  b, i, k, m, Count, LastWanted, Threads, Cur: Integer;
  Jobs: array of TExtractBlockJob;
  Est: array of Int64;
  Pool: TJobPool;
  Names: TStrIntMap;
  Name: string;
  Shared: TExtractShared;
  Finished: Boolean;
begin
  Result := False;
  if Opt.TestOnly or Opt.ToStdout then Exit;
  Threads := ThreadCount(4);
  if Threads < 2 then Exit;
  Count := 0;
  SetLength(Est, Length(A.DataBlocks));
  for b := 0 to High(A.DataBlocks) do
  begin
    LastWanted := -1;
    for i := A.DataBlocks[b].FirstFile to A.DataBlocks[b].FirstFile + A.DataBlocks[b].FileCount - 1 do
      if not A.Files[i].IsDir and not A.Files[i].IsLink and Wanted(Opt, A.Files[i].Name) then LastWanted := i;
    if LastWanted >= 0 then
    begin
      Est[Count] := EstimateDecodeMem(A.DataBlocks[b].Method, A.DataBlocks[b].OrigSize);
      Inc(Count);
    end;
  end;
  if Count < 2 then Exit;
  SetLength(Est, Count);
  // Si no entran al menos dos decodificadores a la vez, el camino de siempre (uno por vez)
  Threads := ThreadsForMemory(Est, Threads);
  if Threads < 2 then Exit;
  // Nombres de destino repetidos, también sin distinguir mayúsculas (el orden decidiría cuál
  // queda, y dos hilos crearían el mismo archivo a la vez), nombres inválidos (el camino
  // serial los informa en su bloque) o preguntas de sobrescritura: no
  Names.Init(Length(A.Files));
  try
    for i := 0 to High(A.Files) do
      if not A.Files[i].IsDir and Wanted(Opt, A.Files[i].Name) then
      begin
        Name := DiskName(Opt, A.Files[i].Name);
        if (Mode = owAsk) and not A.Files[i].IsLink and FileExists(FsPath(Name)) then Exit;
        Name := CaseFoldKey(Name);
        if Names.Get(Name) >= 0 then Exit;
        Names.Put(Name, i);
      end;
  except
    on EArcCorrupt do Exit;
  end;

  SetLength(Jobs, Count);
  Shared := TExtractShared.Create;
  try
    k := 0;
    for b := 0 to High(A.DataBlocks) do
    begin
      LastWanted := -1;
      for i := A.DataBlocks[b].FirstFile to A.DataBlocks[b].FirstFile + A.DataBlocks[b].FileCount - 1 do
        if not A.Files[i].IsDir and not A.Files[i].IsLink and Wanted(Opt, A.Files[i].Name) then LastWanted := i;
      if LastWanted < 0 then Continue;
      Jobs[k] := TExtractBlockJob.Create;
      Jobs[k].A := A;
      Jobs[k].BlockIndex := b;
      Jobs[k].Opt := Opt;
      Jobs[k].Mode := Mode;
      Jobs[k].Shared := Shared;
      Inc(k);
    end;
    Cur := 0;
    Pool := TJobPool.Create(Threads, Count);
    try
      try
        for i := 0 to Count - 1 do Pool.Submit(Jobs[i]);
        // En orden de bloque: mensajes y estadísticas cuando termina cada uno; mientras tanto,
        // el progreso de todos (el progreso solo se informa desde este hilo)
        for i := 0 to Count - 1 do
        begin
          Cur := i;
          repeat
            Finished := Pool.WaitJobFor(Jobs[i], PROGRESS_INTERVAL);
            for k := i to Count - 1 do Jobs[k].ReportProgress;
            if not Finished and (Jobs[i].CurFile >= 0) then ProgressFile(A.Files[Jobs[i].CurFile].Name);
          until Finished;
          if Jobs[i].OutOfMem then
          begin
            // Faltó memoria (o se postergó): se rehace acá cuando ya no queda ningún otro
            // decodificador en marcha. Si así tampoco alcanza, es el error del camino serial
            for k := i + 1 to Count - 1 do Pool.WaitJobQuiet(Jobs[k]);
            Jobs[i].OutOfMem := False;   // (si falla acá, lo ya extraído de este bloque se informa)
            Jobs[i].InMainThread := True;
            Jobs[i].Extract;
          end;
          for k := 0 to Jobs[i].Messages.Count - 1 do Log(Jobs[i].Messages[k]);
          Inc(Stats.Files, Jobs[i].Stats.Files);
          Inc(Stats.Errors, Jobs[i].Stats.Errors);
          Inc(Stats.Skipped, Jobs[i].Stats.Skipped);
          Inc(Stats.Bytes, Jobs[i].Stats.Bytes);
          if Jobs[i].Stats.Unsupported then Stats.Unsupported := True;
          if Jobs[i].Damaged then Damaged := True;
          if Jobs[i].Orig > Jobs[i].Reported then ProgressAdd(Jobs[i].Orig - Jobs[i].Reported);
          Jobs[i].Reported := Jobs[i].Orig;
        end;
      except
        InterlockedExchange(Shared.Abort, 1);   // los demás cortan en su próximo pedazo
        FreeAndNil(Pool);                       // y se espera que terminen
        // Lo que sí quedó en el disco (archivos completos de este bloque y de los siguientes
        // que terminaron o cortaron después) se informa, como lo habría hecho el camino serial
        for k := Cur to Count - 1 do
          if not Jobs[k].OutOfMem then
            for m := 0 to Jobs[k].Messages.Count - 1 do Log(Jobs[k].Messages[m]);
        raise;
      end;
    finally
      Pool.Free;
    end;
  finally
    for i := 0 to Count - 1 do Jobs[i].Free;
    Shared.Free;
  end;
  Result := True;
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
  Temps: TDecodeTemps;
  TempStream: TFileStream;
  DecodedParallel, DirectParallel: Boolean;
  StdOutS: TStream;        // -so
  Cur: Integer;            // el archivo que se está procesando en el bloque (-1: ninguno)
  CurWriting: Boolean;     //   y si ya se estaba escribiendo en el disco
  BlockDamaged: Boolean;

  { El bloque se cortó (damaged data o método desconocido): se informa cada archivo pedido
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
          Log('ERROR: ' + A.Files[k].Name + ' is incomplete (whatever could be recovered was kept)')
        else if Opt.TestOnly then
          Log('ERROR: ' + A.Files[k].Name + ' could not be verified')
        else
          Log('ERROR: ' + A.Files[k].Name + ' could not be extracted');
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
  if Opt.TestOnly then Exit(VerifyArchiveParallel(A, Opt, Log));
  Result := Default(TExtractStats);
  BlockDamaged := False;
  StdOutS := nil;
  if Opt.ToStdout then
    StdOutS := THandleStream.Create(StdoutHandle);
  try
  SetLength(Buf, COPY_BUF);
  Mode := Opt.Overwrite;
  Temps := nil;
  DecodedParallel := False;

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

  DirectParallel := TryExtractParallel(A, Opt, Mode, Log, Result, BlockDamaged);
  // Si no (nombres repetidos, preguntas pendientes), decodificar en paralelo a temporales y
  // escribir en orden; con un solo hilo eso solo agregaría una escritura y una lectura de todo
  if not DirectParallel and (ThreadCount(4) >= 2) then
    DecodedParallel := TryDecodeBlocksParallel(A, Opt, Temps);

  if not DirectParallel then
  for b := 0 to High(A.DataBlocks) do
  begin
    Blk := A.DataBlocks[b];
    // ¿Hay algo que hacer en este bloque? Si no, ni lo abrimos
    LastWanted := LastWantedIn(Blk);
    if LastWanted < 0 then Continue;

    Chain := nil;
    TempStream := nil;
    Cur := -1;
    CurWriting := False;
    try
      try
        if DecodedParallel and (b <= High(Temps)) and (Temps[b] <> '') then
        begin
          TempStream := TFileStream.Create(FsPath(Temps[b]), fmOpenRead);
          Chain := TFileSliceStage.Create(TempStream, 0, Blk.OrigSize);
        end
        else
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
            Log(Format('ERROR: %s is %d bytes and the destination is FAT/FAT32 (4 GB per-file maximum): not extracted',
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
              Log('Skipped (already exists): ' + OutName);
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
                raise EInOutError.CreateFmt('could not write %s (%s): disk full or permission denied?',
                  [OutName, E.Message]);
              end;
              raise;
            end;
            // Datos dañados o método desconocido: queda lo que se pudo recuperar (se informa
            // como incompleto); cualquier otro corte (falta de memoria...) tampoco lo deja a medias
            on EArcCorrupt do raise;
            on EUnsupportedMethod do raise;
            on Exception do
            begin
              if Opened then DeleteFile(FsPath(OutName));
              raise;
            end;
          end;
          ActualCrc := ActualCrc xor CRC_INIT;
          CurWriting := False;
          Cur := i + 1;   // este ya se informa abajo; si el bloque se corta, desde el siguiente
          if OutF <> nil then RestoreMeta(OutName, F);
          if ActualCrc <> F.Crc then
          begin
            Log(Format('CRC ERROR: %s (expected %.8x, got %.8x)', [F.Name, F.Crc, ActualCrc]));
            Inc(Result.Errors);
          end
          else if DoWrite or Opt.TestOnly or Opt.ToStdout then
          begin
            if Opt.TestOnly then Log('OK       ' + F.Name) else Log('Extracted ' + F.Name);
            Inc(Result.Files);
            Inc(Result.Bytes, F.Size);
          end;
        end;
      except
        on E: EUnsupportedMethod do
        begin
          Result.Unsupported := True;
          Log(Format('ERROR: %s (block at %d, %d file(s))', [E.Message, Blk.Pos, Blk.FileCount]));
          ReportLost(Blk, LastWanted);
        end;
        on E: EArcCorrupt do
        begin
          Log(Format('ERROR: %s (block at %d)', [E.Message, Blk.Pos]));
          ReportLost(Blk, LastWanted);
        end;
      end;
    finally
      Chain.Free;
      TempStream.Free;
      if (b <= High(Temps)) and (Temps[b] <> '') then
      begin
        DeleteFile(FsPath(Temps[b]));
        Temps[b] := '';
      end;
    end;
  end;

  ProgressEnd;
  // Los demás bloques se extrajeron igual; con registro de recuperación, se puede reparar
  if BlockDamaged and (A.Recovery <> '') then
    Log('The archive has a recovery record: "parc r ' + ExtractFileName(A.FileName) +
      '" will try to repair it (writes fixed.' + ExtractFileName(A.FileName) + ').');

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
      Log('Warning: not creating link ' + F.Name + ' -> ' + F.LinkTarget +
        ' (points outside the destination; -snld allows it)');
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
        Log('Skipped (already exists): ' + OutName);
        Inc(Result.Skipped);
        Continue;
      end;
      if not DeleteFile(FsPath(OutName)) then RemoveDir(FsPath(OutName));   // (un enlace a dir en Windows)
    end;
    MakeDirs(ExtractFileDir(ExpandFileName(OutName)));
    if MakeSymLink(OutName, F.LinkTarget, F.LinkToDir) then
    begin
      Log('Extracted ' + F.Name + ' -> ' + F.LinkTarget);
      Inc(Result.Files);
    end
    else
    begin
      Log('Warning: could not create link ' + OutName + ' -> ' + F.LinkTarget
        {$IFDEF WINDOWS} + ' (on Windows this requires developer mode or administrator)'{$ENDIF});
      Inc(Result.Skipped);
    end;
  end;

  // Las fechas de los directorios se ponen al final (escribir adentro las cambia)
  if not Opt.TestOnly and not Opt.FlatNames and not Opt.ToStdout then
    for i := 0 to High(A.Files) do
      if A.Files[i].IsDir and Wanted(Opt, A.Files[i].Name) then
        RestoreMeta(DiskName(Opt, A.Files[i].Name), A.Files[i]);
  finally
    if Temps <> nil then
      for i := 0 to High(Temps) do
        if Temps[i] <> '' then DeleteFile(FsPath(Temps[i]));
    StdOutS.Free;   // (THandleStream no cierra el handle)
  end;
end;

end.
