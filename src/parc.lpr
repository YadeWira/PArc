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
  OutLn('  a   crea un archivo (.parc; .arc compatible con FreeArc si la extensión es .arc)');
  OutLn('Opciones:');
  OutLn('  -dp<dir>  directorio de destino');
  OutLn('  -o+       sobrescribe archivos existentes    -o-  los saltea (default)');
  OutLn('  -m<método> preset -m0..-m9, -mx (default -m4, como FreeArc) o método, p. ej. -mlzma');
  OutLn('  -fmt=parc|arc  formato de salida (a)');
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
procedure CollectEntries(const Paths: TStringList; const Exclude: string; var Entries: TWriteEntryArray);

  procedure AddEntry(const Disk, Stored: string; const Meta: TFileMeta);
  var
    n: Integer;
  begin
    if ExpandFileName(Disk) = Exclude then Exit;   // no meter el archivo que se está escribiendo
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

{ Orden dentro de un bloque sólido: grupo de arc.groups, extensión, nombre (inserción simple:
  los bloques típicos tienen miles de archivos, no millones). }
procedure SortGroupFiles(var G: TSolidGroup; const Entries: TWriteEntryArray);

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
begin
  Keys := TStringList.Create;
  try
    Keys.CaseSensitive := True;
    for i := 0 to High(G.Files) do Keys.AddObject(Key(G.Files[i]), TObject(PtrInt(G.Files[i])));
    Keys.Sort;
    for i := 0 to Keys.Count - 1 do G.Files[i] := PtrInt(Keys.Objects[i]);
  finally
    Keys.Free;
  end;
end;

function CmdAdd(const ArcName: string; const Paths: TStringList; const Method, Fmt: string): Integer;
var
  Entries: TWriteEntryArray;
  GM: TGroupMethods;
  Groups: array of TSolidGroup;
  Opt: TWriteOptions;
  St: TWriteStats;
  i, n, g, k: Integer;
  M, Missing: string;
begin
  if Paths.Count = 0 then
  begin
    ErrLn('ERROR: no se indicaron archivos para agregar');
    Exit(1);
  end;
  if FileExists(FsPath(ArcName)) then
  begin
    ErrLn('ERROR: ' + ArcName + ' ya existe (actualizar un archivo existente todavía no está soportado)');
    Exit(1);
  end;
  Entries := nil;
  CollectEntries(Paths, ExpandFileName(ArcName), Entries);
  // Cada archivo va al método de su grupo de arc.groups (-m5 -> $text: dict+lzp+ppmd, etc.);
  // los que comparten método van al mismo bloque sólido
  GM := DecodeMethod(Method, CpuCount);
  Groups := nil;
  for i := 0 to High(Entries) do
    if not Entries[i].Meta.IsDir then
    begin
      M := MethodForGroup(GM, FileGroup(Entries[i].StoredName));
      if M = '' then M := 'storing';
      // tta y mm no admiten sólido (doit "nosolid?" en C_TTA.h/C_MM.h): cada WAV/BMP tiene su
      // propia cabecera y sus parámetros, así que va en su propio bloque
      k := -1;
      if not NoSolid(M) then
        for g := 0 to High(Groups) do
          if Groups[g].Method = M then k := g;
      if k < 0 then
      begin
        k := Length(Groups);
        SetLength(Groups, k + 1);
        Groups[k].Method := M;
        Groups[k].Files := nil;
      end;
      n := Length(Groups[k].Files);
      SetLength(Groups[k].Files, n + 1);
      Groups[k].Files[n] := i;
    end;
  // Dentro de cada bloque: por grupo de arc.groups, extensión y nombre (archivos parecidos juntos)
  for g := 0 to High(Groups) do SortGroupFiles(Groups[g], Entries);
  // Avisar de una vez qué métodos todavía no se pueden comprimir
  Missing := '';
  for g := 0 to High(Groups) do
    if not EncoderAvailable(Groups[g].Method) then Missing := Missing + LineEnding + '  ' + Groups[g].Method;
  if Missing <> '' then
  begin
    ErrLn('ERROR: todavía no hay codificador para:' + Missing);
    Exit(3);
  end;
  Opt.DirMethod := DIR_METHOD;
  if Fmt <> '' then Opt.Parc := Fmt = 'parc'
  else Opt.Parc := LowerCase(ExtractFileExt(ArcName)) <> '.arc';
  St := WriteArchive(ArcName, Entries, Groups, Opt, @LogLine);
  OutLn(Format('Creado %s (%s): %d archivo(s) y %d directorio(s), %d bytes -> %d bytes',
    [ArcName, BoolToStr(Opt.Parc, 'parc', 'arc'), St.Files, St.Dirs, St.Bytes, St.ArcSize]));
  Result := 0;
end;

var
  Cmd, ArcName, S, Method, Fmt: string;
  A: TArchive;
  Opt: TExtractOptions;
  Filter: TStringList;
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
  Method := DEFAULT_METHOD;
  Fmt := '';
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
        else if Copy(S, 1, 2) = '-m' then
        begin
          Method := Copy(S, 3, MaxInt);   // preset (0..9, x, ...) o método explícito
        end
        else if Copy(S, 1, 5) = '-fmt=' then Fmt := LowerCase(Copy(S, 6, MaxInt))
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
    if Cmd = 'a' then
    begin
      try
        Code := CmdAdd(ArcName, Filter, Method, Fmt);
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
  end;
  Halt(Code);
end.
