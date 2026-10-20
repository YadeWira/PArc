{ PArc — archivador .parc en Pascal.
  Listado, test, extracción, creación y actualización de archivos .parc. }
program parc;

{$mode objfpc}{$H+}

uses
  {$IFDEF UNIX}cthreads, BaseUnix,{$ENDIF}
  Classes, SysUtils, Types, DateUtils, parc_os, parc_bytes, parc_methods, parc_archive, parc_extract, parc_writer, parc_encoders, parc_presets, parc_recovery, parc_progress, parc_filelist, parc_volume, parc_console;

const
  PARC_VERSION = '0.0.1';
  // Método por defecto: el mismo que FreeArc (-m4)
  DEFAULT_METHOD = '4';
  // Directorio y footer: lo mismo que usa FreeArc
  DIR_METHOD = 'lzma:1mb:normal:bt4:32';

{ Los errores de TFileStream vienen de FPC en inglés ("Unable to open file \"x\":
  No such file or directory"). Se traducen los casos habituales y se conserva el nombre. }
function FileErrorText(const Msg: string; Opening: Boolean): string;
var
  p, q: Integer;
  Name, Reason: string;
begin
  Result := Msg;
  p := Pos('"', Msg);
  if p = 0 then Exit;
  q := p + 1;
  while (q <= Length(Msg)) and (Msg[q] <> '"') do Inc(q);
  if q > Length(Msg) then Exit;
  Name := Copy(Msg, p + 1, q - p - 1);
  Reason := Copy(Msg, q + 1, MaxInt);
  if Copy(Reason, 1, 2) = ': ' then Delete(Reason, 1, 2);
  if Pos('No such file', Reason) > 0 then Reason := 'no existe'
  else if Pos('Permission denied', Reason) > 0 then Reason := 'permiso denegado'
  else if Pos('Is a directory', Reason) > 0 then Reason := 'es un directorio'
  else if Pos('File exists', Reason) > 0 then Reason := 'ya existe';
  if Reason = '' then
  begin
    if Opening then Result := 'no se pudo abrir "' + Name + '"'
    else Result := 'no se pudo crear "' + Name + '"';
  end
  else if Opening then Result := 'no se pudo abrir "' + Name + '": ' + Reason
  else Result := 'no se pudo crear "' + Name + '": ' + Reason;
end;

procedure Usage;
begin
  OutLn('PArc ' + PARC_VERSION + ' — archivador .parc');
  OutLn('Uso: parc <comando> <archivo> [archivos/máscaras...] [opciones]');
  OutLn('  l   lista el contenido');
  OutLn('  lb  lista los bloques (estructura interna)');
  OutLn('  t   verifica (descomprime y compara CRC, sin escribir)');
  OutLn('  x   extrae con rutas');
  OutLn('  e   extrae sin rutas');
  OutLn('  a   agrega y reemplaza (crea el archivo si no existe)');
  OutLn('  u   agrega y reemplaza solo si el del disco es más nuevo');
  OutLn('  f   actualiza solo los que ya están en el archivo, si el del disco es más nuevo');
  OutLn('  d   borra del archivo los nombres/máscaras indicados');
  OutLn('  r   repara con el registro de recuperación (-rr): escribe fixed.<nombre>');
  OutLn('Opciones:');
  OutLn('  -dp<dir>  directorio de destino (pegado: -dpdestino)');
  OutLn('  -o+       sobrescribe archivos existentes    -o-  los saltea (default)');
  OutLn('  -snld     crea también los enlaces que apuntan fuera del destino');
  OutLn('  -so       x/e: el contenido extraído a stdout (parc x copia.parc datos.txt -so)');
  OutLn('  -si[nombre]  a: agrega lo que llega por stdin con ese nombre (tar cf - dir | parc a x.parc -sidir.tar)');
  OutLn('  "-" como archivo: lo lee de stdin (l/t/x/e) o lo escribe en stdout (a)');
  OutLn('  -m<método> preset -m0..-m9, -mx (default -m4, como FreeArc) o método, p. ej. -mlzma');
  OutLn('  -s  como FreeArc: -s- sin sólido, -se por extensión, -s<N> o -s<N>f N archivos por');
  OutLn('     bloque, -s<N>m (o k/g/b) bloques de al menos ese tamaño; combinables: -se100f10m');
  OutLn('  -x<máscara>  excluir (pegada: -x*.txt; puede repetirse)');
  OutLn('  -r     las máscaras (*.txt, src/*.pas) buscan también en los subdirectorios');
  OutLn('  -rr[N%|N|Nm|N;S|N*S|-]  registro de recuperación (sin valor: 4%/2%/1% según tamaño;');
  OutLn('             N = sectores de 512; -rr- lo quita)');
  OutLn('Manual completo: docs/USO.md');
  OutLn('  -p<contraseña>  al leer: contraseña de un archivo cifrado (si falta, se pide);');
  OutLn('                  al comprimir: cifra los datos (-p solo: la pide por consola)');
  OutLn('  -hp[contraseña] cifra también el directorio (sin ella no se ve ni la lista)');
  OutLn('  -ae=<alg>  --encryption=<alg>  aes (default: aes-256/ctr), blowfish, serpent,');
  OutLn('             twofish; con tamaño/modo: serpent-256/cfb, blowfish-448/ctr, ...');
  OutLn('  -v<tamaño>  volúmenes de ese tamaño (x.parc.001, .002...; solo .parc): -v100m, -v4g, -v700000k');
  OutLn('  --no-progress  sin línea de progreso (tampoco se muestra si stderr no es una consola)');
  OutLn('Ctrl-C cancela limpiamente (no queda ni el temporal ni un archivo a medio extraer);');
  OutLn('un segundo Ctrl-C corta en el acto. Código de salida al cancelar: 130.');
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

{ r: como "arc r": busca sectores dañados con el registro de recuperación y, si todos se
  pueden reconstruir, escribe fixed.<nombre> (el original nunca se toca). }
function CmdRepair(const ArcName: string): Integer;
var
  Res: TRecoveryResult;
  Dest: string;
  i: Integer;
  L: string;
begin
  if not RecoveryRepair(ArcName, Res, Dest) then
  begin
    ErrLn('ERROR: ' + ArcName + ' no tiene registro de recuperación (crearlo con -rr)');
    Exit(1);
  end;
  OutLn(Format('Registro de recuperación %s: %d sector(es) de %d bytes',
    [Res.Info.Version, Res.Info.RecSectors, Res.Info.SectorSize]));
  if Length(Res.BadSectors) = 0 then
  begin
    OutLn('No hay sectores dañados.');
    Exit(0);
  end;
  L := '';
  for i := 0 to High(Res.BadSectors) do L := L + ' ' + IntToStr(Res.BadSectors[i]);
  OutLn(Format('Sectores dañados (%d):%s', [Length(Res.BadSectors), L]));
  if Length(Res.Unrecoverable) > 0 then
  begin
    L := '';
    for i := 0 to High(Res.Unrecoverable) do L := L + ' ' + IntToStr(Res.Unrecoverable[i]);
    ErrLn(Format('ERROR: %d sector(es) irrecuperable(s) (más dañados en el mismo grupo de los que el registro puede reparar):%s',
      [Length(Res.Unrecoverable), L]));
    Exit(2);
  end;
  OutLn(Format('Reparados %d sector(es) -> %s', [Length(Res.Repaired), Dest]));
  Result := 0;
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
  if St.Unsupported then Result := 3
  else if St.Errors > 0 then Result := 2
  else Result := 0;
end;

{ Orden en que Windows (NTFS, y wine) devuelve un directorio: sin distinguir mayúsculas,
  comparando en MAYÚSCULAS ('_' va después de las letras); si empatan, por bytes. }
function FileSizeOf(const Name: string): Int64;
var
  M: TFileMeta;
begin
  if GetFileMeta(Name, M) then Result := M.Size else Result := 0;
end;

{ ¿Path es el archivo que se está escribiendo (ArcPath), uno de sus volúmenes (ArcPath.001...)
  o un temporal (ArcPath.tmp, ArcPath.tmp.001...)? }
function IsOwnArchiveFile(const Path, ArcPath: string): Boolean;
var
  Rest: string;
  i: Integer;
begin
  if Path = ArcPath then Exit(True);
  if Copy(Path, 1, Length(ArcPath) + 1) <> ArcPath + '.' then Exit(False);
  Rest := Copy(Path, Length(ArcPath) + 2, MaxInt);
  if Rest = 'tmp' then Exit(True);
  if Copy(Rest, 1, 4) = 'tmp.' then Delete(Rest, 1, 4);
  Result := Length(Rest) >= 3;
  for i := 1 to Length(Rest) do
    if not (Rest[i] in ['0'..'9']) then Exit(False);
end;

function CompareEntryNames(List: TStringList; A, B: Integer): Integer;
var
  i, n: Integer;
  ca, cb: Byte;
  SA, SB: string;
begin
  SA := List[A]; SB := List[B];
  n := Length(SA);
  if Length(SB) < n then n := Length(SB);
  for i := 1 to n do
  begin
    ca := Ord(SA[i]); cb := Ord(SB[i]);
    if ca in [Ord('a')..Ord('z')] then Dec(ca, 32);
    if cb in [Ord('a')..Ord('z')] then Dec(cb, 32);
    if ca <> cb then Exit(Integer(ca) - Integer(cb));
  end;
  Result := Length(SA) - Length(SB);
  if Result = 0 then Result := CompareStr(SA, SB);
end;

{ Junta las entradas a agregar: cada argumento es un archivo, un directorio (recursivo) o una
  máscara con * y ? en el último componente ("src/*.pas"), como en FreeArc: la expande el propio
  parc porque cmd.exe no lo hace. Sin -r la máscara mira solo ese directorio (y los directorios
  que coinciden entran enteros); con -r busca también en todos los subdirectorios.
  Los nombres guardados son los del argumento, saneados (sin raíz ni ".."). }
var
  Unreadable: TStringList = nil;   // archivos que no se pudieron abrir (se saltean con aviso)

procedure CollectEntries(const Paths: TStringList; const Exclude: string; Excludes: TStrings; Recursive: Boolean;
  var Entries: TWriteEntryArray);

  procedure AddEntry(const Disk, Stored: string; const Meta: TFileMeta);
  var
    n: Integer;
    H: THandle;
  begin
    if IsOwnArchiveFile(ExpandFileName(Disk), Exclude) then Exit;   // ni el archivo que se escribe ni sus volúmenes
    if MatchesAny(Stored, Excludes) then Exit;     // -x<máscara>
    // Uno ilegible (sin permiso, o bloqueado por otro programa en Windows) no aborta todo el
    // trabajo: se avisa y se saltea; al actualizar queda la versión que ya estaba en el archivo.
    // (FreeArc tenía el bug opuesto: el archivo desaparecía del archivo comprimido.)
    if not Meta.IsDir and not Meta.IsLink then
    begin
      H := FileOpen(FsPath(Disk), fmOpenRead or fmShareDenyNone);
      if H = THandle(-1) then
      begin
        ErrLn('Aviso: no se puede leer ' + Disk + ' (se saltea)');
        if Unreadable = nil then Unreadable := TStringList.Create;
        Unreadable.Add(Disk);
        Exit;
      end;
      FileClose(H);
    end;
    n := Length(Entries);
    SetLength(Entries, n + 1);
    Entries[n].DiskPath := Disk;
    Entries[n].StoredName := Stored;
    Entries[n].Meta := Meta;
  end;

  { Como findFiles_FileInfo de FreeArc: primero todas las entradas del directorio (en el orden
    de Windows: sin distinguir mayúsculas), después cada subdirectorio, en ese mismo orden. }
  procedure Walk(const Disk, Stored: string);
  var
    SR: TSearchRec;
    Meta: TFileMeta;
    Names: TStringList;
    Recurse: array of Boolean;
    ChildDisk, ChildStored: string;
    i: Integer;
  begin
    // FsPath: sin el prefijo \\?\ de Windows, un directorio de ruta larga "no existe" y todo lo
    // que tiene adentro se perdía en silencio
    if FindFirst(IncludeTrailingPathDelimiter(FsPath(Disk)) + '*', faAnyFile {$IFDEF UNIX}or faSymLink{$ENDIF}, SR) <> 0 then
    begin
      ErrLn('Aviso: no se puede leer el directorio ' + Disk);
      Exit;
    end;
    Names := TStringList.Create;
    try
      try
        repeat
          if (SR.Name = '.') or (SR.Name = '..') then Continue;
          Names.Add(SR.Name);
        until FindNext(SR) <> 0;
      finally
        FindClose(SR);
      end;
      Names.CustomSort(@CompareEntryNames);
      SetLength(Recurse, Names.Count);
      for i := 0 to Names.Count - 1 do
      begin
        Recurse[i] := False;
        ChildDisk := IncludeTrailingPathDelimiter(Disk) + Names[i];
        if Stored <> '' then ChildStored := Stored + '/' + Names[i] else ChildStored := Names[i];
        // Un enlace (symlink, o junction de Windows) se guarda como enlace y no se recorre:
        // así no hay ciclos ni se archiva dos veces lo mismo
        if not GetLinkMeta(ChildDisk, Meta) and not GetFileMeta(ChildDisk, Meta) then
        begin
          ErrLn('Aviso: no se puede leer ' + ChildDisk);
          Continue;
        end;
        AddEntry(ChildDisk, ChildStored, Meta);
        Recurse[i] := Meta.IsDir;
      end;
      for i := 0 to Names.Count - 1 do
        if Recurse[i] then
        begin
          ChildDisk := IncludeTrailingPathDelimiter(Disk) + Names[i];
          if Stored <> '' then ChildStored := Stored + '/' + Names[i] else ChildStored := Names[i];
          Walk(ChildDisk, ChildStored);
        end;
    finally
      Names.Free;
    end;
  end;

  function HasWild(const S: string): Boolean;
  begin
    Result := (Pos('*', S) > 0) or (Pos('?', S) > 0);
  end;

  { Las entradas de Dir que coinciden con Mask; con Recursive, también las de sus subdirectorios.
    Devuelve cuántas coincidieron. }
  function Expand(const Dir, Mask: string): Integer;
  var
    SR: TSearchRec;
    Meta: TFileMeta;
    Names: TStringList;
    Child: string;
    i: Integer;
  begin
    Result := 0;
    Names := TStringList.Create;
    try
      if Dir = '' then Child := '.' else Child := Dir;
      if FindFirst(IncludeTrailingPathDelimiter(FsPath(Child)) + '*', faAnyFile {$IFDEF UNIX}or faSymLink{$ENDIF}, SR) = 0 then
        try
          repeat
            if (SR.Name <> '.') and (SR.Name <> '..') then Names.Add(SR.Name);
          until FindNext(SR) <> 0;
        finally
          FindClose(SR);
        end;
      Names.CustomSort(@CompareEntryNames);
      for i := 0 to Names.Count - 1 do
      begin
        Child := Dir + Names[i];
        if not GetLinkMeta(Child, Meta) and not GetFileMeta(Child, Meta) then Continue;
        if MatchWild(Names[i], Mask) then
        begin
          Inc(Result);
          AddEntry(Child, SanitizePath(Child), Meta);
          if Meta.IsDir then Walk(Child, SanitizePath(Child));
        end
        else if Recursive and Meta.IsDir then
          Inc(Result, Expand(IncludeTrailingPathDelimiter(Child), Mask));
      end;
    finally
      Names.Free;
    end;
  end;

var
  i, Cut: Integer;
  Meta: TFileMeta;
  Stored, Dir, Mask: string;
begin
  for i := 0 to Paths.Count - 1 do
  begin
    if HasWild(Paths[i]) then
    begin
      Cut := LastDelimiter('/' {$IFDEF WINDOWS}+ '\:'{$ENDIF}, Paths[i]);
      Dir := Copy(Paths[i], 1, Cut);
      Mask := Copy(Paths[i], Cut + 1, MaxInt);
      if HasWild(Dir) then
        raise EFOpenError.CreateFmt('los comodines van solo en el último componente: %s', [Paths[i]]);
      if Expand(Dir, Mask) = 0 then ErrLn('Aviso: ningún archivo coincide con ' + Paths[i]);
      Continue;
    end;
    if not GetFileMeta(Paths[i], Meta) then
      raise EFOpenError.CreateFmt('no existe: %s', [Paths[i]]);
    Stored := SanitizePath(Paths[i]);
    if Stored <> '' then AddEntry(Paths[i], Stored, Meta);   // "." o "/" no se guardan a sí mismos
    if Meta.IsDir then Walk(ExcludeTrailingPathDelimiter(Paths[i]), Stored);
  end;
end;

type
  TModifyOptions = record
    Method, Fmt: string;
    MethodGiven: Boolean;    // -m explícito (con d, FreeArc recompila todo: --recompress)
    Recompress: Boolean;     // --recompress: rehacer todos los bloques viejos
    Solid: TFaCrits;         // -s...: criterios de corte de los bloques sólidos (FaParseSolidOption)
    Excludes: TStringList;   // -x<máscara>
    Recursive: Boolean;      // -r: las máscaras buscan también en los subdirectorios
    StdinName: string;       // -si[nombre]: un archivo más, leído de stdin, con ese nombre
    StdinFile: string;       //   el temporal donde se volcó
    ShownName: string;       // el nombre que se muestra ('' = el del archivo; "-": salida estándar)
    Recovery: string;        // -rr...: '--' si no se dio la opción
    Encryption: string;      // -ae= / --encryption=
    VolumeSize: Int64;       // -v<tamaño>: volúmenes (solo .parc); 0 = como estaba
    DataPassword, HeadersPassword: RawByteString;   // '' = sin cifrar
  end;

{ Como ArcRecover.hs: sin -rr se conserva lo que tenía el archivo; -rr/-rr+ usa eso o el
  recomendado por tamaño (4%/2%/1%); -rr- ninguno; -rr0.1% y -rr0.01% solo CRCs. }
function ResolveRecovery(const Opt, Old: string; ArcSize: Int64): string;
var
  Recommended: string;
begin
  if ArcSize < 300000 then Recommended := '4%'
  else if ArcSize < 2000000 then Recommended := '2%'
  else Recommended := '1%';
  case Opt of
    '-':        Result := '';
    '--':       Result := Old;
    '', '+':    if Old <> '' then Result := Old else Result := Recommended;
    '0.1%':     Result := '0*4kb';     // lo que guarda arc.exe 0.67.1 (el fuente dice 0*4096)
    '0.01%':    Result := '0*64kb';    // ídem (el fuente dice 0*65536)
  else
    Result := Opt;
  end;
end;

{ Agrupa entradas nuevas en bloques sólidos exactamente como FreeArc 0.67 (parc_filelist):
  orden gerpn, tipo por arc.groups y por contenido, un grupo por método y los cortes de -s,
  de dict/grzip/lzp y de tta/mm. }
procedure GroupNewEntries(const Entries: TWriteEntryArray; const Idx: array of Integer;
  const MO: TModifyOptions; var Groups: TSolidGroupArray);
var
  GM: TGroupMethods;
  Files: array of TFaFile;
  Crits: TFaCrits;
  Blocks: TFaBlocks;
  i, g, k: Integer;
begin
  if Length(Idx) = 0 then Exit;
  GM := DecodeMethod(MO.Method, CpuCount);
  SetLength(Files, Length(Idx));
  for i := 0 to High(Idx) do
  begin
    Files[i].Name := Entries[Idx[i]].StoredName;
    Files[i].DiskPath := Entries[Idx[i]].DiskPath;
    Files[i].Size := Entries[Idx[i]].Meta.Size;
  end;
  // -s: los criterios de FreeArc (FaParseSolidOption); sin -s, todo junto
  Crits := MO.Solid;
  Blocks := FaSolidBlocks(Files, GM, Crits, FaDetectLevel(MO.Method));
  for i := 0 to High(Blocks) do
  begin
    g := Length(Groups);
    SetLength(Groups, g + 1);
    Groups[g] := Default(TSolidGroup);
    Groups[g].Method := Blocks[i].Method;
    SetLength(Groups[g].Files, Length(Blocks[i].Files));
    for k := 0 to High(Blocks[i].Files) do Groups[g].Files[k] := Idx[Blocks[i].Files[k]];
  end;
end;

{ Clave para comparar nombres del archivo con los del disco (en Windows sin mayúsculas). }
function NameKey(const Name: string): string;
begin
  {$IFDEF WINDOWS}Result := LowerCase(Name);{$ELSE}Result := Name;{$ENDIF}
end;

{ Bloques de un archivo que se actualiza, como FreeArc 0.67 (join_lists + splitToSolidBlocks):
  - lista 1: los archivos del archivo viejo en su orden; el que se reemplaza (a/u/f) queda en
    su lugar pero ahora viene del disco; los borrados no están;
  - lista 2: los nuevos del disco, en el orden de sort_files;
  - merge por la clave gerpn (o una detrás de la otra si no se ordena);
  - parc_filelist tipifica (los viejos, por el compresor de su bloque), agrupa por método y
    corta con el splitBy de FreeArc, que conserva los bloques viejos que quedaron enteros.
  Keep/Old: qué archivos viejos siguen y su entrada; NewIdx: las entradas del disco. }
procedure PlanUpdate(A: TArchive; const Keep: array of Boolean; const Old: array of Integer;
  const Entries: TWriteEntryArray; const NewIdx: array of Integer; const MO: TModifyOptions;
  Recompress: Boolean; var Groups: TSolidGroupArray);
var
  L1, L2, M: array of TFaFile;
  E1, E2, EM: array of Integer;        // entrada de cada elemento de L1, L2, M
  Used: array of Boolean;              // entrada nueva ya usada como reemplazo
  ByName: TStringList;
  BlockOf, PosOf, CountOf: array of Integer;
  GM: TGroupMethods;
  Blocks: TFaBlocks;
  Order: TIntegerDynArray;
  b, j, k, n, pos, g, x, y: Integer;

  function DiskFile(e: Integer): TFaFile;
  begin
    Result := Default(TFaFile);
    Result.Name := Entries[e].StoredName;
    Result.DiskPath := Entries[e].DiskPath;
    Result.Size := Entries[e].Meta.Size;
  end;

begin
  GM := DecodeMethod(MO.Method, CpuCount);
  // Bloque, posición y cantidad de archivos (sin directorios) de cada archivo viejo
  SetLength(BlockOf, Length(A.Files)); SetLength(PosOf, Length(A.Files)); SetLength(CountOf, Length(A.Files));
  for b := 0 to High(A.DataBlocks) do
  begin
    n := 0;
    for j := A.DataBlocks[b].FirstFile to A.DataBlocks[b].FirstFile + A.DataBlocks[b].FileCount - 1 do
      if not A.Files[j].IsDir and not A.Files[j].IsLink then Inc(n);
    pos := 0;
    for j := A.DataBlocks[b].FirstFile to A.DataBlocks[b].FirstFile + A.DataBlocks[b].FileCount - 1 do
      if not A.Files[j].IsDir and not A.Files[j].IsLink then
      begin
        BlockOf[j] := b; PosOf[j] := pos; CountOf[j] := n;
        Inc(pos);
      end;
  end;
  // Las entradas nuevas por nombre, para poner cada reemplazo en el lugar del viejo
  ByName := TStringList.Create;
  try
    ByName.Sorted := True;
    ByName.Duplicates := dupIgnore;
    for k := 0 to High(NewIdx) do ByName.AddObject(NameKey(Entries[NewIdx[k]].StoredName), TObject(PtrInt(k)));
    SetLength(Used, Length(NewIdx));
    SetLength(L1, Length(A.Files) + Length(NewIdx)); SetLength(E1, Length(L1));
    n := 0;
    for j := 0 to High(A.Files) do
    begin
      if A.Files[j].IsDir or A.Files[j].IsLink then Continue;   // sin datos: van en el bloque de directorios
      if Keep[j] then
      begin
        L1[n] := Default(TFaFile);
        L1[n].Name := A.Files[j].Name;
        L1[n].Size := A.Files[j].Size;
        L1[n].IsOld := True;
        L1[n].OldBlock := BlockOf[j];
        L1[n].OldPos := PosOf[j];
        L1[n].OldBlockFiles := CountOf[j];
        L1[n].OldMethod := A.DataBlocks[BlockOf[j]].Method;
        E1[n] := Old[j];
        Inc(n);
      end
      else
      begin
        k := ByName.IndexOf(NameKey(A.Files[j].Name));
        if k >= 0 then
        begin
          k := PtrInt(ByName.Objects[k]);
          if not Used[k] then
          begin
            Used[k] := True;
            L1[n] := DiskFile(NewIdx[k]); E1[n] := NewIdx[k]; Inc(n);
          end;
        end;
      end;
    end;
    SetLength(L1, n); SetLength(E1, n);
  finally
    ByName.Free;
  end;
  // Los que no estaban, en el orden de sort_files
  SetLength(L2, Length(NewIdx)); SetLength(E2, Length(NewIdx));
  n := 0;
  for k := 0 to High(NewIdx) do
    if not Used[k] then begin L2[n] := DiskFile(NewIdx[k]); E2[n] := NewIdx[k]; Inc(n); end;
  SetLength(L2, n); SetLength(E2, n);
  if FaSortEnabled(GM, MO.Solid) and (n > 1) then
  begin
    Order := FaSortFiles(L2);
    M := Copy(L2); EM := Copy(E2);
    for k := 0 to High(Order) do begin L2[k] := M[Order[k]]; E2[k] := EM[Order[k]]; end;
  end;
  // merge (Utils.hs): si el viejo es mayor, va el nuevo; si no (empate incluido), el viejo
  SetLength(M, Length(L1) + Length(L2)); SetLength(EM, Length(M));
  x := 0; y := 0; n := 0;
  while (x < Length(L1)) or (y < Length(L2)) do
    if (y >= Length(L2)) or ((x < Length(L1)) and
       not (FaSortEnabled(GM, MO.Solid) and (FaMergeCompare(L1[x], L2[y]) > 0))) then
    begin
      M[n] := L1[x]; EM[n] := E1[x]; Inc(x); Inc(n);
    end
    else
    begin
      M[n] := L2[y]; EM[n] := E2[y]; Inc(y); Inc(n);
    end;
  Blocks := FaSolidBlocks(M, GM, MO.Solid, FaDetectLevel(MO.Method), True, not Recompress);
  for k := 0 to High(Blocks) do
  begin
    g := Length(Groups);
    SetLength(Groups, g + 1);
    Groups[g] := Default(TSolidGroup);
    if Blocks[k].CopyOld then
    begin
      Groups[g].CopyFrom := A;
      Groups[g].CopyBlock := Blocks[k].OldBlock;
      Groups[g].Method := A.DataBlocks[Blocks[k].OldBlock].Method;
    end
    else
      Groups[g].Method := Blocks[k].Method;
    SetLength(Groups[g].Files, Length(Blocks[k].Files));
    for j := 0 to High(Blocks[k].Files) do Groups[g].Files[j] := EM[Blocks[k].Files[j]];
  end;
end;

{ Antepone Prefix (el módulo) a Target, a través de un temporal. }
procedure PrependToFile(const Target: string; const Prefix: TBytes);
var
  Src, Dst: TFileStream;
  Tmp: string;
begin
  Tmp := Target + '.prefix.tmp';
  Dst := TFileStream.Create(FsPath(Tmp), fmCreate);
  try
    try
      if Length(Prefix) > 0 then Dst.WriteBuffer(Prefix[0], Length(Prefix));
      Src := TFileStream.Create(FsPath(Target), fmOpenRead or fmShareDenyWrite);
      try
        Dst.CopyFrom(Src, 0);
      finally
        Src.Free;
      end;
    finally
      Dst.Free;
    end;
  except
    DeleteFile(FsPath(Tmp));
    raise;
  end;
  if not DeleteFile(FsPath(Target)) or not RenameFile(FsPath(Tmp), FsPath(Target)) then
    raise EFCreateError.CreateFmt('no se pudo escribir %s', [Target]);
end;

function ReadWholeFile(const Name: string; MaxLen: Int64 = High(Int64)): TBytes;
var
  F: TFileStream;
  n: Int64;
begin
  F := TFileStream.Create(FsPath(Name), fmOpenRead or fmShareDenyWrite);
  try
    n := F.Size;
    if n > MaxLen then n := MaxLen;
    SetLength(Result, n);
    if n > 0 then F.ReadBuffer(Result[0], n);
  finally
    F.Free;
  end;
end;

{ a (agregar/reemplazar), u (solo si es más nuevo), f (solo actualizar lo que ya está),
  d (borrar). Sobre un archivo existente, los bloques que se conservan enteros se copian tal
  cual y los que pierden archivos se reempaquetan; se escribe un temporal que reemplaza al
  original al final. }
function CmdModify(const Cmd, ArcName: string; const Paths: TStringList; const MO: TModifyOptions): Integer;
var
  A: TArchive;
  Disk, Entries: TWriteEntryArray;
  NewIdx: array of Integer;
  Groups: TSolidGroupArray;
  Keep: array of Boolean;
  ByName: TStringList;
  Opt: TWriteOptions;
  St: TWriteStats;
  i, j, n, Removed, Replaced, Added: Integer;
  Missing, Verb, OldRR, VolBase, VolInfo, FinalName: string;
  SfxPrefix: TBytes;
  NVol: Integer;
  RRSize: Int64;
  Exists, Newer: Boolean;
  Recompress: Boolean;           // d con -m explícito: FreeArc recompila todos los bloques
  Old: array of Integer;         // índice en Entries de cada archivo viejo conservado (-1 si no)

  function AddEntry(const E: TWriteEntry): Integer;
  begin
    Result := Length(Entries);
    SetLength(Entries, Result + 1);
    Entries[Result] := E;
  end;

begin
  if (Cmd <> 'd') and (Paths.Count = 0) and (MO.StdinFile = '') then
  begin
    ErrLn('ERROR: no se indicaron archivos');
    Exit(1);
  end;
  Exists := ArchiveExists(ArcName);
  if not Exists and ((Cmd = 'd') or (Cmd = 'f')) then
  begin
    ErrLn('ERROR: no existe ' + ArcName);
    Exit(1);
  end;
  A := nil;
  if Exists then A := TArchive.Open(ArcName);
  try
    // PArc ya no crea autoextraíbles, pero si el archivo ya traía un módulo delante se
    // guarda (lo que va antes del archivo) y se vuelve a poner al actualizarlo.
    SfxPrefix := nil;
    if (A <> nil) and (A.SFXSize > 0) then SfxPrefix := ReadWholeFile(ArcName, A.SFXSize);
    if (A <> nil) and A.Locked then
    begin
      ErrLn('ERROR: ' + ArcName + ' está bloqueado contra cambios (-k de FreeArc)');
      Exit(1);
    end;
    Disk := nil;
    if Cmd <> 'd' then CollectEntries(Paths, ExpandFileName(ArcName), MO.Excludes, MO.Recursive, Disk);
    // -si: lo que llegó por stdin, ya volcado a un temporal, con el nombre pedido
    if (Cmd <> 'd') and (MO.StdinFile <> '') then
    begin
      n := Length(Disk);
      SetLength(Disk, n + 1);
      Disk[n] := Default(TWriteEntry);
      Disk[n].DiskPath := MO.StdinFile;
      Disk[n].StoredName := SanitizePath(MO.StdinName);
      GetFileMeta(MO.StdinFile, Disk[n].Meta);
      Disk[n].Meta.MTimeNs := Int64(DateTimeToUnix(Now, False)) * 1000000000;
    end;
    if (Cmd <> 'd') and (Length(Disk) = 0) and not Exists then
    begin
      // como FreeArc ("No files to archive"): no se crea un archivo vacío
      ErrLn('ERROR: no hay archivos para agregar');
      Exit(1);
    end;

    Entries := nil;
    NewIdx := nil;
    Removed := 0; Replaced := 0; Added := 0;
    // Archivos viejos: cuáles se conservan
    if A <> nil then
    begin
      ByName := TStringList.Create;
      try
        ByName.Sorted := True;
        ByName.Duplicates := dupIgnore;
        for i := 0 to High(Disk) do ByName.AddObject(NameKey(Disk[i].StoredName), TObject(PtrInt(i)));
        SetLength(Keep, Length(A.Files));
        SetLength(Old, Length(A.Files));
        for j := 0 to High(A.Files) do
        begin
          Keep[j] := True;
          Old[j] := -1;
          if Cmd = 'd' then
            Keep[j] := not MatchesAny(A.Files[j].Name, Paths)
          else
          begin
            i := ByName.IndexOf(NameKey(A.Files[j].Name));
            if i >= 0 then
            begin
              i := PtrInt(ByName.Objects[i]);
              if A.Files[j].IsDir and Disk[i].Meta.IsDir then
                Disk[i].Meta.Size := -1   // el directorio ya está: no duplicarlo
              else
              begin
                // u y f solo reemplazan si el del disco es más nuevo (comparado en segundos,
                // la precisión de .arc)
                Newer := (Disk[i].Meta.MTimeNs div 1000000000) > (MetaFromArchive(A.Files[j]).MTimeNs div 1000000000);
                if (Cmd = 'a') or Newer then
                begin
                  Keep[j] := False;
                  Inc(Replaced);
                end
                else
                  Disk[i].Meta.Size := -1;  // se queda el del archivo
              end;
            end;
          end;
          if not Keep[j] and (Cmd = 'd') then Inc(Removed);
        end;
      finally
        ByName.Free;
      end;
      // Entradas conservadas (en el orden del archivo)
      for j := 0 to High(A.Files) do
        if Keep[j] then
        begin
          Old[j] := AddEntry(Default(TWriteEntry));
          Entries[Old[j]].StoredName := A.Files[j].Name;
          Entries[Old[j]].Meta := MetaFromArchive(A.Files[j]);
          Entries[Old[j]].SrcArc := A;
          Entries[Old[j]].SrcIndex := j;
        end;
    end;
    // Archivos nuevos del disco (f solo actualiza: no agrega los que no estaban)
    for i := 0 to High(Disk) do
    begin
      if Disk[i].Meta.Size < 0 then Continue;
      // f solo actualiza lo que ya está: ni archivos ni directorios nuevos
      if Cmd = 'f' then
      begin
        n := 0;
        if A <> nil then
          for j := 0 to High(A.Files) do
            if NameKey(A.Files[j].Name) = NameKey(Disk[i].StoredName) then n := 1;
        if n = 0 then Continue;
      end;
      j := AddEntry(Disk[i]);
      if not Disk[i].Meta.IsDir and not Disk[i].Meta.IsLink then
      begin
        SetLength(NewIdx, Length(NewIdx) + 1);
        NewIdx[High(NewIdx)] := j;
        Inc(Added);
      end;
    end;
    Dec(Added, Replaced);
    Groups := nil;
    // Cmdline.hs: con los comandos que copian (d entre ellos), un -m explícito implica
    // --recompress: los bloques viejos se rehacen con ese método en vez de copiarse.
    Recompress := MO.Recompress or ((Cmd = 'd') and MO.MethodGiven);
    if A = nil then
      GroupNewEntries(Entries, NewIdx, MO, Groups)
    else
      PlanUpdate(A, Keep, Old, Entries, NewIdx, MO, Recompress, Groups);

    // Avisar de una vez qué métodos todavía no se pueden comprimir
    Missing := '';
    for i := 0 to High(Groups) do
      if (Groups[i].CopyFrom = nil) and not EncoderAvailable(WithoutCipher(Groups[i].Method)) then
        Missing := Missing + LineEnding + '  ' + Groups[i].Method;
    if Missing <> '' then
    begin
      ErrLn('ERROR: todavía no hay codificador para:' + Missing);
      Exit(3);
    end;

    Opt := Default(TWriteOptions);   // KeepTemp/Comment: los registros locales no se inicializan solos
    Opt.DirMethod := DIR_METHOD;
    Opt.KeepTemp := True;            // el original se cierra antes de reemplazarlo (Windows)
    if A <> nil then Opt.Comment := A.Comment;
    // El tamaño para el % recomendado es el de los datos (aproximado: lo de entrada)
    OldRR := '';
    if A <> nil then OldRR := A.Recovery;
    RRSize := 0;
    for i := 0 to High(Entries) do Inc(RRSize, Entries[i].Meta.Size);
    Opt.Recovery := ResolveRecovery(MO.Recovery, OldRR, RRSize);
    Opt.Encryption := MO.Encryption;
    Opt.DataPassword := MO.DataPassword;
    Opt.HeadersPassword := MO.HeadersPassword;
    // Volúmenes: -v, o el tamaño que ya tenían (el del primero) si se actualiza uno partido
    Opt.VolumeSize := MO.VolumeSize;
    if (Opt.VolumeSize = 0) and IsVolumeSet(ArcName, VolBase) then
      Opt.VolumeSize := FileSizeOf(VolumeName(ArcName, 1));
    St := WriteArchive(ArcName, Entries, Groups, Opt, @LogLine);
  finally
    A.Free;
  end;
  FinishArchive(ArcName, Opt.VolumeSize);
  FinalName := ArcName;
  if not Exists then Verb := 'Creado' else Verb := 'Actualizado';
  // PArc ya no crea autoextraíbles; si el archivo ya traía un módulo delante, se conserva
  if Length(SfxPrefix) > 0 then
  begin
    PrependToFile(ArcName, SfxPrefix);
    // el archivo se reescribió: que siga siendo ejecutable
    {$IFDEF UNIX}FpChmod(ArcName, &755);{$ENDIF}
  end;
  VolInfo := '';
  if Opt.VolumeSize > 0 then
  begin
    NVol := 0;
    while FileExists(FsPath(VolumeName(ArcName, NVol + 1))) do Inc(NVol);
    VolInfo := Format(', %d volumen(es) de %d bytes: %s ...', [NVol, Opt.VolumeSize, VolumeName(ArcName, 1)]);
  end;
  if MO.ShownName <> '' then FinalName := MO.ShownName;
  OutLn(Format('%s %s (%s%s): %d archivo(s) y %d directorio(s), %d bytes -> %d bytes',
    [Verb, FinalName, 'parc' + BoolToStr(Length(SfxPrefix) > 0, ', autoextraíble', ''), VolInfo, St.Files, St.Dirs, St.Bytes, St.ArcSize]));
  if Exists then
    OutLn(Format('  agregados %d, reemplazados %d, borrados %d', [Added, Replaced, Removed]));
  Result := 0;
  if (Unreadable <> nil) and (Unreadable.Count > 0) then
  begin
    ErrLn(Format('Aviso: %d archivo(s) no se pudieron leer y no se agregaron (si ya estaban, quedó la versión anterior)',
      [Unreadable.Count]));
    Result := EXIT_WARNINGS;
  end;
end;

var
  Cmd, ArcName, Pwd2, S: string;
  VolSize: Int64;
  A: TArchive;
  Opt: TExtractOptions;
  MO: TModifyOptions;
  Filter, Excludes: TStringList;
  i, Code, Tries: Integer;
  Retry, ShowProgress, Writing, ToStdout: Boolean;
  DPwd, HPwd: string;
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
  MO := Default(TModifyOptions);
  MO.Method := DEFAULT_METHOD;
  Filter := TStringList.Create;
  Excludes := TStringList.Create;
  MO.Excludes := Excludes;
  MO.Recovery := '--';
  MO.Encryption := 'aes';
  DPwd := '--'; HPwd := '--';   // '--' = no se dio la opción (como Cmdline.hs)
  Code := 0;
  ShowProgress := True;
  try
    for i := 2 to ArgCount do
    begin
      S := Arg(i);
      if (Length(S) > 1) and (S[1] = '-') then
      begin
        if Copy(S, 1, 3) = '-dp' then
        begin
          if Length(S) = 3 then
          begin
            ErrLn('ERROR: -dp necesita un directorio pegado (-dp<dir>)');
            Halt(1);
          end;
          Opt.DestDir := Copy(S, 4, MaxInt);
        end
        else if S = '--no-progress' then ShowProgress := False
        else if Copy(S, 1, 4) = '-sfx' then
        begin
          ErrLn('ERROR: -sfx ya no existe: PArc no crea autoextraíbles');
          Halt(1);
        end
        else if (Copy(S, 1, 2) = '-v') and ParseVolumeSize(Copy(S, 3, MaxInt), VolSize) then
          MO.VolumeSize := VolSize
        else if S = '-o+' then Opt.Overwrite := owAll
        else if S = '-snld' then Opt.UnsafeLinks := True
        else if S = '-so' then Opt.ToStdout := True
        else if Copy(S, 1, 3) = '-si' then
        begin
          MO.StdinName := Copy(S, 4, MaxInt);
          if MO.StdinName = '' then MO.StdinName := 'stdin';
        end
        else if S = '-o-' then Opt.Overwrite := owSkip
        else if S = '--recompress' then MO.Recompress := True
        else if Copy(S, 1, 2) = '-m' then
        begin
          MO.Method := Copy(S, 3, MaxInt);   // preset (0..9, x, ...) o método explícito
          MO.MethodGiven := True;
        end
        else if Copy(S, 1, 5) = '-fmt=' then
        begin
          ErrLn('ERROR: -fmt ya no existe: PArc solo usa el formato .parc');
          Halt(1);
        end
        else if Copy(S, 1, 2) = '-x' then
        begin
          if Length(S) = 2 then
          begin
            ErrLn('ERROR: -x necesita una máscara pegada (-x<patrón>, p. ej. -x*.txt)');
            Halt(1);
          end;
          Excludes.Add(Copy(S, 3, MaxInt));
        end
        // -s- no sólido; -s<mem> tope de bytes por bloque; -s<N>f tope de archivos
        else if Copy(S, 1, 3) = '-rr' then MO.Recovery := Copy(S, 4, MaxInt)
        else if S = '-r' then MO.Recursive := True
        else if (Copy(S, 1, 2) = '-s') and FaParseSolidOption(Copy(S, 3, MaxInt), MO.Solid) then
          // (los criterios quedaron en MO.Solid)
        else if Copy(S, 1, 3) = '-hp' then HPwd := Copy(S, 4, MaxInt)
        else if Copy(S, 1, 2) = '-p' then DPwd := Copy(S, 3, MaxInt)
        else if Copy(S, 1, 4) = '-ae=' then MO.Encryption := Copy(S, 5, MaxInt)
        else if Copy(S, 1, 13) = '--encryption=' then MO.Encryption := Copy(S, 14, MaxInt)
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
    if (ArcName <> '-') and (LowerCase(ExtractFileExt(ArcName)) = '.arc') then
    begin
      ErrLn('ERROR: PArc ya no lee ni escribe .arc (ahora solo .parc). Para .arc usá FreeArc-ex.');
      Halt(1);
    end;
    Opt.Filter := Filter;
    Writing := (Cmd = 'a') or (Cmd = 'u') or (Cmd = 'f') or (Cmd = 'd');
    // stdin y stdout. Un archivo no se puede escribir de corrido (los descriptores apuntan
    // atrás) ni leer sin saber dónde termina (el footer va al final): se pasa por un temporal.
    // stdout lleva datos: los mensajes van a stderr.
    if Opt.ToStdout then OutToStderr := True;
    if (MO.StdinName <> '') and (Cmd <> 'a') then
    begin
      ErrLn('ERROR: -si es solo para el comando a');
      Halt(1);
    end;
    if (MO.StdinName <> '') and (ArcName = '-') then
    begin
      ErrLn('ERROR: stdin no puede ser a la vez el archivo y un archivo a agregar (-si con "-")');
      Halt(1);
    end;
    ToStdout := False;
    if ArcName = '-' then
    begin
      if (Cmd = 'l') or (Cmd = 'lb') or (Cmd = 't') or (Cmd = 'x') or (Cmd = 'e') then
      begin
        ArcName := IncludeTrailingPathDelimiter(GetTempDir) + Format('parc-stdin-%d.tmp', [GetProcessID]);
        RegisterTempFile(ArcName);
        StdinToFile(ArcName);
      end
      else if Cmd = 'a' then
      begin
        if MO.VolumeSize > 0 then
        begin
          ErrLn('ERROR: -v no va con un archivo por stdout ("-")');
          Halt(1);
        end;
        OutToStderr := True;
        ToStdout := True;
        MO.ShownName := '(salida estándar)';
        S := '.parc';
        ArcName := IncludeTrailingPathDelimiter(GetTempDir) + Format('parc-stdout-%d', [GetProcessID]) + S;
        RegisterTempFile(ArcName);
      end
      else
      begin
        ErrLn('ERROR: "-" (stdin/stdout) sirve con l, lb, t, x, e y a');
        Halt(1);
      end;
    end;
    if MO.StdinName <> '' then
    begin
      // al lado del archivo: el tamaño tiene que conocerse antes de comprimir (el diccionario
      // se ajusta a él), y en el disco del archivo seguro que hay lugar
      MO.StdinFile := ExtractFilePath(ExpandFileName(ArcName)) + Format('.parc-stdin-%d.tmp', [GetProcessID]);
      RegisterTempFile(MO.StdinFile);
      StdinToFile(MO.StdinFile);
    end;
    // "x.parc.001" es lo mismo que "x.parc" (el primero de sus volúmenes)
    if IsVolumeSet(ArcName, S) then ArcName := S;
    // Contraseñas como Cmdline.hs: -p solo cifra datos; -hp (con o sin -p) cifra también
    // los encabezados; -p y -hp con valores distintos, uno para cada cosa
    if HPwd <> '--' then
    begin
      if HPwd = '' then HPwd := DPwd;
      if DPwd = '--' then DPwd := HPwd
      else if DPwd = '' then DPwd := HPwd;
    end;
    if Writing and ((DPwd = '') or (HPwd = '')) then
    begin
      // -p / -hp sin valor al comprimir: pedirla dos veces (un error de tipeo no tiene arreglo)
      if not ReadPassword('Contraseña para cifrar: ', S) or (S = '') then
      begin
        ErrLn('ERROR: hace falta una contraseña (no hay consola para pedirla)');
        Halt(1);
      end;
      if not ReadPassword('Repetila: ', Pwd2) or (Pwd2 <> S) then
      begin
        ErrLn('ERROR: las contraseñas no coinciden');
        Halt(1);
      end;
      if DPwd = '' then DPwd := S;
      if HPwd = '' then HPwd := S;
    end;
    if (DPwd <> '--') and (DPwd <> '') then MO.DataPassword := DPwd;
    if (HPwd <> '--') and (HPwd <> '') then MO.HeadersPassword := HPwd;
    // La principal es la de los datos (con esa se vuelve a cifrar lo que se reempaqueta);
    // la de encabezados, si es otra, se prueba también (-p y -hp distintas)
    if MO.DataPassword <> '' then SetArchivePassword(MO.DataPassword);
    if (MO.HeadersPassword <> '') and (MO.HeadersPassword <> MO.DataPassword) then
      AddArchivePassword(MO.HeadersPassword);


    if ShowProgress and ErrIsConsole then ProgressHandler := @DrawProgress;
    InstallCancelHandler(@OnCtrlC);
    if Cmd = 'r' then
    begin
      // Antes de abrir el archivo: dañado puede no abrir normalmente
      try
        Code := CmdRepair(ArcName);
      except
        on E: Exception do begin ErrLn('ERROR: ' + E.Message); Code := 4; end;
      end;
      Halt(Code);
    end;
    if (Cmd = 'a') or (Cmd = 'u') or (Cmd = 'f') or (Cmd = 'd') then
    begin
      Tries := 0;
      repeat
      Retry := False;
      try
        Code := CmdModify(Cmd, ArcName, Filter, MO);
        if ToStdout and ((Code = 0) or (Code = EXIT_WARNINGS)) then FileToStdout(ArcName);
      except
        // El archivo viejo está cifrado y no se dio -p: pedirla, como en x/t
        on E: EPasswordRequired do
          if (Tries < 3) and ReadPassword('Contraseña: ', S) then
          begin
            AddArchivePassword(S);   // se suma a las ya dadas (-p y -hp pueden ser distintas)
            Inc(Tries);
            Retry := True;
          end
          else begin ClearProgress; ErrLn('ERROR: ' + E.Message); Code := 5; end;
        on E: EBadPassword do
          if (Tries < 3) and ReadPassword('Contraseña incorrecta. Contraseña: ', S) then
          begin
            AddArchivePassword(S);   // se suma a las ya dadas (-p y -hp pueden ser distintas)
            Inc(Tries);
            Retry := True;
          end
          else begin ClearProgress; ErrLn('ERROR: ' + E.Message); Code := 5; end;
        on E: EOperationCancelled do begin
          ClearProgress;
          if FileExists(FsPath(ArcName)) then ErrLn('Cancelado: ' + ArcName + ' quedó como estaba.')
          else ErrLn('Cancelado: no se creó ' + ArcName + '.');
          Code := EXIT_CANCELLED;
        end;
        on E: EUnsupportedEncoder do begin ClearProgress; ErrLn('ERROR: ' + E.Message); Code := 3; end;
        on E: EFOpenError do
        begin ClearProgress; ErrLn('ERROR: ' + FileErrorText(E.Message, True)); Code := 4; end;
        on E: EFCreateError do
        begin ClearProgress; ErrLn('ERROR: ' + FileErrorText(E.Message, False)); Code := 4; end;
        on E: Exception do begin ClearProgress; ErrLn('ERROR: ' + E.Message); Code := 4; end;
      end;
      until not Retry;
      Halt(Code);
    end;
    Tries := 0;
    repeat
      Retry := False;
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
        on E: EPasswordRequired do
          // Sin -p: pedirla por consola (hasta 3 intentos), como FreeArc
          if (Tries < 3) and ReadPassword('Contraseña: ', S) then
          begin
            AddArchivePassword(S);   // se suma a las ya dadas (-p y -hp pueden ser distintas)
            Inc(Tries);
            Retry := True;
          end
          else begin ErrLn('ERROR: ' + E.Message); Code := 5; end;
        on E: EBadPassword do
          if (Tries > 0) and (Tries < 3) and ReadPassword('Contraseña incorrecta. Contraseña: ', S) then
          begin
            AddArchivePassword(S);   // se suma a las ya dadas (-p y -hp pueden ser distintas)
            Inc(Tries);
            Retry := True;
          end
          else begin ErrLn('ERROR: ' + E.Message); Code := 5; end;
        on E: EOperationCancelled do begin ClearProgress; ErrLn('Cancelado.'); Code := EXIT_CANCELLED; end;
        on E: EArcCorrupt do begin ClearProgress; ErrLn('ERROR: ' + E.Message); Code := 2; end;
        on E: EUnsupportedMethod do begin ClearProgress; ErrLn('ERROR: ' + E.Message); Code := 3; end;
        on E: EFOpenError do
        begin ClearProgress; ErrLn('ERROR: ' + FileErrorText(E.Message, True)); Code := 4; end;
        on E: EFCreateError do
        begin ClearProgress; ErrLn('ERROR: ' + FileErrorText(E.Message, False)); Code := 4; end;
        on E: Exception do begin ClearProgress; ErrLn('ERROR: ' + E.Message); Code := 4; end;
      end;
    until not Retry;
  finally
    Filter.Free;
    Excludes.Free;
  end;
  Halt(Code);
end.
