{ PArc — reescritura de FreeArc en Pascal.
  Listado, test y extracción de archivos FreeArc (.arc). }
program parc;

{$mode objfpc}{$H+}

uses
  {$IFDEF UNIX}cthreads,{$ENDIF}
  Classes, SysUtils, DateUtils, parc_os, parc_bytes, parc_methods, parc_archive, parc_extract, parc_writer, parc_encoders, parc_presets;

const
  PARC_VERSION = '0.0.3';
  // Método por defecto: el mismo que FreeArc (-m4)
  DEFAULT_METHOD = '4';
  // Directorio y footer: lo mismo que usa FreeArc
  DIR_METHOD = 'lzma:1mb:normal:bt4:32';

procedure Usage;
begin
  OutLn('PArc ' + PARC_VERSION + ' — archivador compatible con FreeArc');
  OutLn('Uso: parc <comando> <archivo> [archivos/máscaras...] [opciones]');
  OutLn('  l   lista el contenido');
  OutLn('  lb  lista los bloques (estructura interna)');
  OutLn('  t   verifica (descomprime y compara CRC, sin escribir)');
  OutLn('  x   extrae con rutas');
  OutLn('  e   extrae sin rutas');
  OutLn('  a   agrega y reemplaza (crea el archivo si no existe; .arc compatible si la extensión es .arc)');
  OutLn('  u   agrega y reemplaza solo si el del disco es más nuevo');
  OutLn('  f   actualiza solo los que ya están en el archivo, si el del disco es más nuevo');
  OutLn('  d   borra del archivo los nombres/máscaras indicados');
  OutLn('Opciones:');
  OutLn('  -dp<dir>  directorio de destino');
  OutLn('  -o+       sobrescribe archivos existentes    -o-  los saltea (default)');
  OutLn('  -m<método> preset -m0..-m9, -mx (default -m4, como FreeArc) o método, p. ej. -mlzma');
  OutLn('  -fmt=parc|arc  formato de salida (a/u/f/d)');
  OutLn('  -s-  sin sólido   -s<mem> tope de bytes por bloque sólido   -s<N>f tope de archivos');
  OutLn('  -x<máscara>  excluir (puede repetirse)');
  OutLn('  -p<contraseña>  contraseña de un archivo cifrado (si falta, se pide por consola)');
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

{ Junta las entradas a agregar: cada argumento es un archivo o un directorio (recursivo).
  Los nombres guardados son los del argumento, saneados (sin raíz ni ".."). }
procedure CollectEntries(const Paths: TStringList; const Exclude: string; Excludes: TStrings; var Entries: TWriteEntryArray);

  procedure AddEntry(const Disk, Stored: string; const Meta: TFileMeta);
  var
    n: Integer;
  begin
    if ExpandFileName(Disk) = Exclude then Exit;   // no meter el archivo que se está escribiendo
    if MatchesAny(Stored, Excludes) then Exit;     // -x<máscara>
    n := Length(Entries);
    SetLength(Entries, n + 1);
    Entries[n].DiskPath := Disk;
    Entries[n].StoredName := Stored;
    Entries[n].Meta := Meta;
  end;

  procedure Walk(const Disk, Stored: string);
  var
    SR: TSearchRec;
    Meta: TFileMeta;
    ChildDisk, ChildStored: string;
  begin
    // FsPath: sin el prefijo \\?\ de Windows, un directorio de ruta larga "no existe" y todo lo
    // que tiene adentro se perdía en silencio
    if FindFirst(IncludeTrailingPathDelimiter(FsPath(Disk)) + '*', faAnyFile {$IFDEF UNIX}or faSymLink{$ENDIF}, SR) <> 0 then
    begin
      ErrLn('Aviso: no se puede leer el directorio ' + Disk);
      Exit;
    end;
    try
      repeat
        if (SR.Name = '.') or (SR.Name = '..') then Continue;
        ChildDisk := IncludeTrailingPathDelimiter(Disk) + SR.Name;
        if Stored <> '' then ChildStored := Stored + '/' + SR.Name else ChildStored := SR.Name;
        if not GetFileMeta(ChildDisk, Meta) then
        begin
          ErrLn('Aviso: no se puede leer ' + ChildDisk);
          Continue;
        end;
        AddEntry(ChildDisk, ChildStored, Meta);
        // No seguir enlaces simbólicos a directorios: evita ciclos
        if Meta.IsDir {$IFDEF UNIX}and ((SR.Attr and faSymLink) = 0){$ENDIF} then
          Walk(ChildDisk, ChildStored);
      until FindNext(SR) <> 0;
    finally
      FindClose(SR);
    end;
  end;

var
  i: Integer;
  Meta: TFileMeta;
  Stored: string;
begin
  for i := 0 to Paths.Count - 1 do
  begin
    if not GetFileMeta(Paths[i], Meta) then
      raise EFOpenError.CreateFmt('no existe: %s', [Paths[i]]);
    Stored := SanitizePath(Paths[i]);
    if Stored <> '' then AddEntry(Paths[i], Stored, Meta);   // "." o "/" no se guardan a sí mismos
    if Meta.IsDir then Walk(ExcludeTrailingPathDelimiter(Paths[i]), Stored);
  end;
end;

function NoSolid(const Method: string): Boolean;
var
  Stage, Name: string;
begin
  for Stage in Method.Split(['+']) do
  begin
    Name := Stage.Split([':'])[0];
    if (Name = 'tta') or (Name = 'mm') then Exit(True);
  end;
  Result := False;
end;

{ Orden de los archivos nuevos: grupo de arc.groups, extensión, nombre (archivos parecidos
  juntos en el bloque sólido). }
procedure SortIndices(const Idx: array of Integer; const Entries: TWriteEntryArray);

  function Key(i: Integer): string;
  var
    Name: string;
  begin
    Name := Entries[i].StoredName;
    Result := Format('%.4d', [GroupOrder(FileGroup(Name))]) + #1 +
              LowerCase(ExtractFileExt(Name)) + #1 + Name;
  end;

var
  Keys: TStringList;
  i: Integer;
  P: PInteger;
begin
  if Length(Idx) = 0 then Exit;
  Keys := TStringList.Create;
  try
    Keys.CaseSensitive := True;
    for i := 0 to High(Idx) do Keys.AddObject(Key(Idx[i]), TObject(PtrInt(Idx[i])));
    Keys.Sort;
    P := @Idx[0];   // (Idx es const para aceptar arreglos abiertos; se reordena en su lugar)
    for i := 0 to Keys.Count - 1 do P[i] := PtrInt(Keys.Objects[i]);
  finally
    Keys.Free;
  end;
end;

type
  TModifyOptions = record
    Method, Fmt: string;
    SolidBytes: Int64;       // -s<mem>: tope de bytes por bloque sólido (0 = sin tope)
    SolidFiles: Integer;     // -s<N>f: tope de archivos por bloque (0 = sin tope)
    NonSolid: Boolean;       // -s-: cada archivo en su propio bloque
    Excludes: TStringList;   // -x<máscara>
  end;

{ Agrupa entradas nuevas en bloques sólidos: método de su grupo de arc.groups (-m5 -> $text:
  dict+lzp+ppmd, etc.), un bloque por método, cortado por -s. }
procedure GroupNewEntries(const Entries: TWriteEntryArray; const Idx: array of Integer;
  const MO: TModifyOptions; var Groups: TSolidGroupArray);
var
  GM: TGroupMethods;
  i, n, g, k, j: Integer;
  M: string;
  Open: array of Integer;       // bloque abierto por método (índice en Groups), -1 si no
  OpenBytes: array of Int64;
  Methods: TStringList;
begin
  GM := DecodeMethod(MO.Method, CpuCount);
  Methods := TStringList.Create;
  try
    // Ordenar primero (grupo de arc.groups, extensión, nombre) y después cortar por -s
    SortIndices(Idx, Entries);
    for j := 0 to High(Idx) do
    begin
      i := Idx[j];
      M := MethodForGroup(GM, FileGroup(Entries[i].StoredName));
      if M = '' then M := 'storing';
      k := Methods.IndexOf(M);
      if k < 0 then
      begin
        k := Methods.Add(M);
        SetLength(Open, k + 1);
        SetLength(OpenBytes, k + 1);
        Open[k] := -1;
      end;
      g := Open[k];
      // tta/mm no admiten sólido (nosolid? de C_TTA.h/C_MM.h); -s- y los topes de -s cortan
      if (g >= 0) and (MO.NonSolid or NoSolid(M) or
         ((MO.SolidBytes > 0) and (OpenBytes[k] + Entries[i].Meta.Size > MO.SolidBytes)) or
         ((MO.SolidFiles > 0) and (Length(Groups[g].Files) >= MO.SolidFiles))) then
        g := -1;
      if g < 0 then
      begin
        g := Length(Groups);
        SetLength(Groups, g + 1);
        Groups[g] := Default(TSolidGroup);
        Groups[g].Method := M;
        Open[k] := g;
        OpenBytes[k] := 0;
      end;
      n := Length(Groups[g].Files);
      SetLength(Groups[g].Files, n + 1);
      Groups[g].Files[n] := i;
      Inc(OpenBytes[k], Entries[i].Meta.Size);
    end;
  finally
    Methods.Free;
  end;
end;

{ Clave para comparar nombres del archivo con los del disco (en Windows sin mayúsculas). }
function NameKey(const Name: string): string;
begin
  {$IFDEF WINDOWS}Result := LowerCase(Name);{$ELSE}Result := Name;{$ENDIF}
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
  i, j, n, b, KeptInBlock, Removed, Replaced, Added: Integer;
  Missing, Verb: string;
  Exists, Newer: Boolean;
  Old: array of Integer;         // índice en Entries de cada archivo viejo conservado (-1 si no)

  function AddEntry(const E: TWriteEntry): Integer;
  begin
    Result := Length(Entries);
    SetLength(Entries, Result + 1);
    Entries[Result] := E;
  end;

begin
  if (Cmd <> 'd') and (Paths.Count = 0) then
  begin
    ErrLn('ERROR: no se indicaron archivos');
    Exit(1);
  end;
  Exists := FileExists(FsPath(ArcName));
  if not Exists and ((Cmd = 'd') or (Cmd = 'f')) then
  begin
    ErrLn('ERROR: no existe ' + ArcName);
    Exit(1);
  end;
  A := nil;
  if Exists then A := TArchive.Open(ArcName);
  try
    if (A <> nil) and A.Locked then
    begin
      ErrLn('ERROR: ' + ArcName + ' está bloqueado contra cambios (-k de FreeArc)');
      Exit(1);
    end;
    Disk := nil;
    if Cmd <> 'd' then CollectEntries(Paths, ExpandFileName(ArcName), MO.Excludes, Disk);

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
      // Bloques viejos: enteros -> copia; con bajas -> reempaquetar; vacíos -> nada
      Groups := nil;
      for b := 0 to High(A.DataBlocks) do
      begin
        KeptInBlock := 0;
        n := 0;
        for j := A.DataBlocks[b].FirstFile to A.DataBlocks[b].FirstFile + A.DataBlocks[b].FileCount - 1 do
          if not A.Files[j].IsDir then
          begin
            Inc(n);
            if Keep[j] then Inc(KeptInBlock);
          end;
        if KeptInBlock = 0 then Continue;
        i := Length(Groups);
        SetLength(Groups, i + 1);
        Groups[i] := Default(TSolidGroup);
        Groups[i].Method := A.DataBlocks[b].Method;
        if KeptInBlock = n then
        begin
          Groups[i].CopyFrom := A;
          Groups[i].CopyBlock := b;
        end;
        for j := A.DataBlocks[b].FirstFile to A.DataBlocks[b].FirstFile + A.DataBlocks[b].FileCount - 1 do
          if Keep[j] and not A.Files[j].IsDir then
          begin
            SetLength(Groups[i].Files, Length(Groups[i].Files) + 1);
            Groups[i].Files[High(Groups[i].Files)] := Old[j];
          end;
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
      if not Disk[i].Meta.IsDir then
      begin
        SetLength(NewIdx, Length(NewIdx) + 1);
        NewIdx[High(NewIdx)] := j;
        Inc(Added);
      end;
    end;
    Dec(Added, Replaced);
    GroupNewEntries(Entries, NewIdx, MO, Groups);

    // Avisar de una vez qué métodos todavía no se pueden comprimir
    Missing := '';
    for i := 0 to High(Groups) do
      if (Groups[i].CopyFrom = nil) and not EncoderAvailable(Groups[i].Method) then
        Missing := Missing + LineEnding + '  ' + Groups[i].Method;
    if Missing <> '' then
    begin
      ErrLn('ERROR: todavía no hay codificador para:' + Missing);
      Exit(3);
    end;

    Opt := Default(TWriteOptions);   // KeepTemp/Comment: los registros locales no se inicializan solos
    Opt.DirMethod := DIR_METHOD;
    Opt.KeepTemp := True;            // el original se cierra antes de reemplazarlo (Windows)
    if MO.Fmt <> '' then Opt.Parc := MO.Fmt = 'parc'
    else if A <> nil then Opt.Parc := A.IsParc
    else Opt.Parc := LowerCase(ExtractFileExt(ArcName)) <> '.arc';
    if A <> nil then Opt.Comment := A.Comment;
    St := WriteArchive(ArcName, Entries, Groups, Opt, @LogLine);
  finally
    A.Free;
  end;
  FinishArchive(ArcName);
  if not Exists then Verb := 'Creado' else Verb := 'Actualizado';
  OutLn(Format('%s %s (%s): %d archivo(s) y %d directorio(s), %d bytes -> %d bytes',
    [Verb, ArcName, BoolToStr(Opt.Parc, 'parc', 'arc'), St.Files, St.Dirs, St.Bytes, St.ArcSize]));
  if Exists then
    OutLn(Format('  agregados %d, reemplazados %d, borrados %d', [Added, Replaced, Removed]));
  Result := 0;
end;

var
  Cmd, ArcName, S: string;
  A: TArchive;
  Opt: TExtractOptions;
  MO: TModifyOptions;
  Filter, Excludes: TStringList;
  SolidMem: QWord;
  i, Code, Tries: Integer;
  Retry: Boolean;
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
        else if Copy(S, 1, 2) = '-m' then
          MO.Method := Copy(S, 3, MaxInt)   // preset (0..9, x, ...) o método explícito
        else if Copy(S, 1, 5) = '-fmt=' then MO.Fmt := LowerCase(Copy(S, 6, MaxInt))
        else if Copy(S, 1, 2) = '-x' then Excludes.Add(Copy(S, 3, MaxInt))
        // -s- no sólido; -s<mem> tope de bytes por bloque; -s<N>f tope de archivos
        else if S = '-s-' then MO.NonSolid := True
        else if (Copy(S, 1, 2) = '-s') and (Length(S) > 2) and (S[Length(S)] = 'f') then
          MO.SolidFiles := StrToIntDef(Copy(S, 3, Length(S) - 3), 0)
        else if (Copy(S, 1, 2) = '-s') and ParseMem(Copy(S, 3, MaxInt), SolidMem) then
          MO.SolidBytes := SolidMem
        else if Copy(S, 1, 2) = '-p' then SetArchivePassword(Copy(S, 3, MaxInt))
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
    if (Cmd = 'a') or (Cmd = 'u') or (Cmd = 'f') or (Cmd = 'd') then
    begin
      try
        Code := CmdModify(Cmd, ArcName, Filter, MO);
      except
        on E: EUnsupportedEncoder do begin ErrLn('ERROR: ' + E.Message); Code := 3; end;
        on E: Exception do begin ErrLn('ERROR: ' + E.Message); Code := 4; end;
      end;
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
            SetArchivePassword(S);
            Inc(Tries);
            Retry := True;
          end
          else begin ErrLn('ERROR: ' + E.Message); Code := 5; end;
        on E: EBadPassword do
          if (Tries > 0) and (Tries < 3) and ReadPassword('Contraseña incorrecta. Contraseña: ', S) then
          begin
            SetArchivePassword(S);
            Inc(Tries);
            Retry := True;
          end
          else begin ErrLn('ERROR: ' + E.Message); Code := 5; end;
        on E: EArcCorrupt do begin ErrLn('ERROR: ' + E.Message); Code := 2; end;
        on E: EUnsupportedMethod do begin ErrLn('ERROR: ' + E.Message); Code := 3; end;
        on E: Exception do begin ErrLn('ERROR: ' + E.Message); Code := 4; end;
      end;
    until not Retry;
  finally
    Filter.Free;
    Excludes.Free;
  end;
  Halt(Code);
end.
