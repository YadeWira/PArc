{ Escritura de archivos .parc y .arc (FORMATO-PARC.md, FORMATO-ARC.md).
  Orden en disco: HEADER + descriptor, bloques de datos (sin descriptor), DIR_BLOCK +
  descriptor, FOOTER + descriptor. Se escribe a un temporal que se renombra al final: si algo
  falla a mitad de camino no queda un archivo roto con el nombre final. }
unit parc_writer;

{$mode objfpc}{$H+}

interface

uses
  Classes, SysUtils, parc_os, parc_archive;

type
  TWriteEntry = record
    DiskPath: string;     // de dónde leerlo (si SrcArc = nil)
    StoredName: string;   // cómo se guarda: UTF-8, '/', relativo, sin '..'
    Meta: TFileMeta;
    SrcArc: TArchive;     // <> nil: viene de un archivo existente (actualizar/borrar)
    SrcIndex: Integer;    //   su índice en SrcArc.Files
  end;

  TWriteEntryArray = array of TWriteEntry;

  { Un bloque sólido: archivos (índices en Entries) que se comprimen juntos con Method. }
  TSolidGroup = record
    Method: string;
    Files: array of Integer;
    CopyFrom: TArchive;   // <> nil: copiar tal cual el bloque CopyBlock de ese archivo (sin
    CopyBlock: Integer;   //   recomprimir); Files son sus archivos, en su orden
  end;

  TSolidGroupArray = array of TSolidGroup;

  TWriteOptions = record
    Parc: Boolean;        // .parc (si no, .arc compatible con FreeArc 0.67)
    DirMethod: string;    // compresión del directorio y del footer
    Comment: RawByteString;
    KeepTemp: Boolean;    // no renombrar: el llamador llama a FinishArchive (p. ej. después de
  end;                    // cerrar el archivo viejo, que en Windows no se puede reemplazar abierto)

  TWriteStats = record
    Files, Dirs: Integer;
    Bytes, ArcSize: Int64;
  end;

  TLogProc = procedure(const Msg: string);

{ Escribe el archivo completo. Los grupos se escriben en orden; los directorios (entradas con
  Meta.IsDir) van en un bloque inicial sin datos, como hace FreeArc. }
function WriteArchive(const FileName: string; const Entries: array of TWriteEntry;
  const Groups: array of TSolidGroup; const Opt: TWriteOptions; Log: TLogProc): TWriteStats;

{ Reemplaza FileName por el temporal que dejó WriteArchive con KeepTemp. }
procedure FinishArchive(const FileName: string);

{ Meta de una entrada que viene de un archivo existente. }
function MetaFromArchive(const F: TArcFileEntry): TFileMeta;

implementation

uses
  parc_bytes, parc_crc, parc_stream, parc_outstream, parc_encoders, parc_methods;

const
  VERSION_ARC: array[0..3] of Byte = (0, 0, 6, 7);                // FreeArc 0.67
  VERSION_PARC: array[0..3] of Byte = (PARC_FORMAT_VERSION, 0, 0, 0);
  COPY_BUF = 1 shl 20;

type
  TBlockInfo = record
    BlockType: Integer;
    Method: string;
    Pos, OrigSize, CompSize: Int64;
    Crc: LongWord;
  end;

  { Estado de un archivo ya escrito, en el orden del directorio. }
  TDirFile = record
    Entry: Integer;       // índice en Entries
    Size: Int64;          // bytes leídos de verdad (el archivo pudo cambiar)
    Crc: LongWord;
  end;

  TDataBlock = record
    Method: string;
    Pos, CompSize: Int64;
    Files: array of TDirFile;
  end;

function Signature(Parc: Boolean): LongWord;
begin
  if Parc then Result := PARC_SIGNATURE else Result := ARC_SIGNATURE;
end;

{ Descriptor local (FORMATO-ARC.md §3): firma, tipo, método, tamaños, CRC de los datos y
  CRC del propio descriptor. }
procedure WriteDescriptor(S: TStream; Parc: Boolean; const B: TBlockInfo);
var
  w: TByteWriter;
begin
  w.Clear;
  w.U32(Signature(Parc));
  w.VInt(B.BlockType);
  w.CStr(B.Method);
  w.VInt(B.OrigSize);
  w.VInt(B.CompSize);
  w.U32(B.Crc);
  w.U32(CalcCRC(PByte(w.Data), w.Len));
  S.WriteBuffer(w.Data[0], w.Len);
end;

{ Escribe un bloque de control (datos comprimidos + descriptor) y devuelve su información. }
function WriteControlBlock(S: TStream; Parc: Boolean; BlockType: Integer; const Method: string;
  const Data: TBytes): TBlockInfo;
var
  Comp: TBytes;
begin
  Result.BlockType := BlockType;
  Result.Method := Method;
  Result.Pos := S.Position;
  Result.OrigSize := Length(Data);
  Result.Crc := CalcCRC(PByte(Data), Length(Data));
  Comp := CompressMem(Method, PByte(Data), Length(Data));
  Result.CompSize := Length(Comp);
  if Length(Comp) > 0 then S.WriteBuffer(Comp[0], Length(Comp));
  WriteDescriptor(S, Parc, Result);
end;

function ParentOf(const Name: string): string;
var
  p: Integer;
begin
  p := LastDelimiter('/', Name);
  if p > 0 then Result := Copy(Name, 1, p - 1) else Result := '';
end;

function BaseOf(const Name: string): string;
begin
  Result := Copy(Name, LastDelimiter('/', Name) + 1, MaxInt);
end;

{ Tiempo de la columna Time (CTime de 32 bits con signo): recortado a su rango. }
function Time32(Ns: Int64): LongWord;
var
  Sec: Int64;
begin
  Sec := Ns div 1000000000;
  if (Ns < 0) and (Ns mod 1000000000 <> 0) then Dec(Sec);   // piso, no truncamiento
  if Sec > High(LongInt) then Sec := High(LongInt);
  if Sec < Low(LongInt) then Sec := Low(LongInt);
  Result := LongWord(LongInt(Sec));
end;

{ Serializa el DIR_BLOCK (FORMATO-ARC.md §6 + campos opcionales de FORMATO-PARC.md §2). }
function BuildDirectory(const Entries: array of TWriteEntry; const Blocks: array of TDataBlock;
  DirPos: Int64; Parc: Boolean): TBytes;
var
  w, f: TByteWriter;
  All: array of TDirFile;
  Dirs: TStringList;
  DirIdx: array of Integer;
  b, i, n, k: Integer;
  AllWin, AllUnix: Boolean;

  procedure OptField(Tag: Integer; const Field: TByteWriter);
  begin
    w.VInt(Tag);
    w.U8(0);                  // no obligatorio: un lector viejo lo puede saltear
    w.VInt(Field.Len);
    w.Raw(PByte(Field.Data), Field.Len);
  end;

begin
  w.Clear;
  // 1. Bloques de datos
  w.VInt(Length(Blocks));
  for b := 0 to High(Blocks) do w.VInt(Length(Blocks[b].Files));
  for b := 0 to High(Blocks) do w.CStr(Blocks[b].Method);
  for b := 0 to High(Blocks) do w.VInt(DirPos - Blocks[b].Pos);
  for b := 0 to High(Blocks) do w.VInt(Blocks[b].CompSize);

  // Todos los archivos en el orden de los bloques
  n := 0;
  for b := 0 to High(Blocks) do Inc(n, Length(Blocks[b].Files));
  SetLength(All, n);
  n := 0;
  for b := 0 to High(Blocks) do
    for i := 0 to High(Blocks[b].Files) do
    begin
      All[n] := Blocks[b].Files[i];
      Inc(n);
    end;

  // 2. Directorios únicos, en orden de aparición (enumDirectories de ArhiveDirectory.hs)
  Dirs := TStringList.Create;
  try
    Dirs.CaseSensitive := True;
    SetLength(DirIdx, n);
    for i := 0 to n - 1 do
    begin
      k := Dirs.IndexOf(ParentOf(Entries[All[i].Entry].StoredName));
      if k < 0 then k := Dirs.Add(ParentOf(Entries[All[i].Entry].StoredName));
      DirIdx[i] := k;
    end;
    w.VInt(Dirs.Count);
    for i := 0 to Dirs.Count - 1 do w.CStr(Dirs[i]);
  finally
    Dirs.Free;
  end;

  // 3. Columnas por archivo
  for i := 0 to n - 1 do w.CStr(BaseOf(Entries[All[i].Entry].StoredName));
  for i := 0 to n - 1 do w.VInt(DirIdx[i]);
  for i := 0 to n - 1 do w.VInt(All[i].Size);
  for i := 0 to n - 1 do w.U32(Time32(Entries[All[i].Entry].Meta.MTimeNs));
  for i := 0 to n - 1 do w.U8(Ord(Entries[All[i].Entry].Meta.IsDir));
  for i := 0 to n - 1 do w.U32(All[i].Crc);

  // 4. Campos opcionales (solo .parc)
  if Parc then
  begin
    f.Clear;
    for i := 0 to n - 1 do f.I64(Entries[All[i].Entry].Meta.MTimeNs);
    OptField(DIRTAG_MTIME_NS, f);
    AllWin := n > 0;
    AllUnix := n > 0;
    for i := 0 to n - 1 do
    begin
      AllWin := AllWin and Entries[All[i].Entry].Meta.HasWinAttr;
      AllUnix := AllUnix and Entries[All[i].Entry].Meta.HasUnixMode;
    end;
    if AllWin then
    begin
      f.Clear;
      for i := 0 to n - 1 do f.U32(Entries[All[i].Entry].Meta.WinAttr);
      OptField(DIRTAG_WIN_ATTR, f);
    end;
    if AllUnix then
    begin
      f.Clear;
      for i := 0 to n - 1 do f.U32(Entries[All[i].Entry].Meta.UnixMode);
      OptField(DIRTAG_UNIX_MODE, f);
    end;
  end;
  w.VInt(DIRTAG_END);
  Result := w.Bytes;
end;

{ FOOTER_BLOCK (FORMATO-ARC.md §5.1): bloques de control, locked, comentario viejo (0),
  recovery ('') y comentario (0 bytes). }
function BuildFooter(const Control: array of TBlockInfo; FooterPos: Int64; const Comment: RawByteString): TBytes;
var
  w: TByteWriter;
  i: Integer;
begin
  w.Clear;
  w.VInt(Length(Control));
  for i := 0 to High(Control) do
  begin
    w.VInt(Control[i].BlockType);
    w.CStr(Control[i].Method);
    w.VInt(FooterPos - Control[i].Pos);
    w.VInt(Control[i].OrigSize);
    w.VInt(Control[i].CompSize);
    w.U32(Control[i].Crc);
  end;
  w.U8(0);        // locked
  w.VInt(0);      // comentario viejo (UCS-4)
  w.CStr('');     // recovery
  w.VInt(Length(Comment));   // comentario (UTF-8, puede tener NUL)
  w.Raw(PChar(Comment), Length(Comment));
  Result := w.Bytes;
end;

{ Comprime los archivos de un grupo como un bloque sólido. }
function MetaFromArchive(const F: TArcFileEntry): TFileMeta;
begin
  Result := Default(TFileMeta);
  Result.Size := F.Size;
  Result.IsDir := F.IsDir;
  if F.HasMTimeNs then Result.MTimeNs := F.MTimeNs else Result.MTimeNs := F.Time * 1000000000;
  Result.HasWinAttr := F.HasWinAttr;
  Result.WinAttr := F.WinAttr;
  Result.HasUnixMode := F.HasUnixMode;
  Result.UnixMode := F.UnixMode;
end;

{ Copia tal cual un bloque de un archivo existente (sus bytes comprimidos, sin tocarlos: vale
  también para bloques cifrados). }
function CopyDataBlock(S: TStream; const Entries: array of TWriteEntry; const G: TSolidGroup;
  var Stats: TWriteStats): TDataBlock;
var
  Blk: TArcBlock;
  Src: TInStage;
  Buf: TBytes;
  n: SizeInt;
  i: Integer;
begin
  Blk := G.CopyFrom.DataBlocks[G.CopyBlock];
  Result.Method := Blk.Method;
  Result.Pos := S.Position;
  SetLength(Buf, COPY_BUF);
  Src := G.CopyFrom.OpenBlockData(Blk);
  try
    repeat
      n := Src.Read(@Buf[0], Length(Buf));
      if n > 0 then S.WriteBuffer(Buf[0], n);
    until n <= 0;
  finally
    Src.Free;
  end;
  Result.CompSize := S.Position - Result.Pos;
  SetLength(Result.Files, Length(G.Files));
  for i := 0 to High(G.Files) do
    with Entries[G.Files[i]] do
    begin
      Result.Files[i].Entry := G.Files[i];
      Result.Files[i].Size := SrcArc.Files[SrcIndex].Size;
      Result.Files[i].Crc := SrcArc.Files[SrcIndex].Crc;
      if Meta.IsDir then Inc(Stats.Dirs)
      else begin Inc(Stats.Files); Inc(Stats.Bytes, Meta.Size); end;
    end;
end;

function WriteDataBlock(S: TStream; const Entries: array of TWriteEntry; const G: TSolidGroup;
  Log: TLogProc; var Stats: TWriteStats): TDataBlock;
var
  Chain: TOutStage;
  Buf: TBytes;
  i, n: Integer;
  F: TFileStream;
  Got: SizeInt;
  Crc: LongWord;
  Size: Int64;
  // Entradas que vienen de un archivo existente: el bloque viejo se descomprime en orden,
  // salteando los archivos que no se conservan
  CurArc: TArchive;
  CurBlock, CurNext, k: Integer;
  CurChain: TInStage;
  Remaining: Int64;

  procedure SkipIn(Count: Int64);
  var
    m: SizeInt;
  begin
    while Count > 0 do
    begin
      if Count > Length(Buf) then m := Length(Buf) else m := Count;
      CurChain.ReadExact(@Buf[0], m);
      Dec(Count, m);
    end;
  end;

begin
  if G.CopyFrom <> nil then Exit(CopyDataBlock(S, Entries, G, Stats));
  CurArc := nil; CurBlock := -1; CurNext := 0; CurChain := nil;
  // Diccionario ajustado al tamaño del bloque (el método ajustado es el que queda en el archivo)
  Size := 0;
  for i := 0 to High(G.Files) do
    if not Entries[G.Files[i]].Meta.IsDir then Inc(Size, Entries[G.Files[i]].Meta.Size);
  Result.Method := LimitMethodToSize(G.Method, Size);
  Result.Pos := S.Position;
  SetLength(Result.Files, Length(G.Files));
  SetLength(Buf, COPY_BUF);
  Chain := CreateEncoderChain(Result.Method, TStreamSink.Create(S));
  try
    for i := 0 to High(G.Files) do
    begin
      n := G.Files[i];
      Crc := CRC_INIT;
      Size := 0;
      if not Entries[n].Meta.IsDir and (Entries[n].SrcArc <> nil) then
      begin
        with Entries[n] do
        begin
          k := SrcArc.Files[SrcIndex].DataBlock;
          if (CurArc <> SrcArc) or (CurBlock <> k) or (SrcIndex < CurNext) then
          begin
            FreeAndNil(CurChain);
            CurArc := SrcArc;
            CurBlock := k;
            CurNext := SrcArc.DataBlocks[k].FirstFile;
            CurChain := CreateDecoderChain(SrcArc.DataBlocks[k].Method, SrcArc.OpenBlockData(SrcArc.DataBlocks[k]));
          end;
          while CurNext < SrcIndex do
          begin
            SkipIn(SrcArc.Files[CurNext].Size);
            Inc(CurNext);
          end;
          Remaining := SrcArc.Files[SrcIndex].Size;
          while Remaining > 0 do
          begin
            if Remaining > Length(Buf) then Got := Length(Buf) else Got := Remaining;
            CurChain.ReadExact(@Buf[0], Got);
            Crc := UpdateCRC(Crc, @Buf[0], Got);
            Chain.Write(@Buf[0], Got);
            Inc(Size, Got);
            Dec(Remaining, Got);
          end;
          CurNext := SrcIndex + 1;
          if (Crc xor CRC_INIT) <> SrcArc.Files[SrcIndex].Crc then
            raise EArcCorrupt.CreateFmt('CRC incorrecto en %s del archivo original: no se reempaqueta un archivo dañado', [StoredName]);
        end;
        Inc(Stats.Files);
        Inc(Stats.Bytes, Size);
      end
      else if not Entries[n].Meta.IsDir then
      begin
        F := TFileStream.Create(FsPath(Entries[n].DiskPath), fmOpenRead or fmShareDenyWrite);
        try
          repeat
            Got := F.Read(Buf[0], Length(Buf));
            if Got > 0 then
            begin
              Crc := UpdateCRC(Crc, @Buf[0], Got);
              Chain.Write(@Buf[0], Got);
              Inc(Size, Got);
            end;
          until Got <= 0;
        finally
          F.Free;
        end;
        if Size <> Entries[n].Meta.Size then
          Log(Format('Aviso: %s cambió de tamaño mientras se leía (%d -> %d bytes)',
            [Entries[n].DiskPath, Entries[n].Meta.Size, Size]));
        Inc(Stats.Files);
        Inc(Stats.Bytes, Size);
      end
      else
        Inc(Stats.Dirs);
      Result.Files[i].Entry := n;
      Result.Files[i].Size := Size;
      Result.Files[i].Crc := Crc xor CRC_INIT;
    end;
    Chain.Finish;
  finally
    Chain.Free;
    CurChain.Free;
  end;
  Result.CompSize := S.Position - Result.Pos;
end;

function WriteArchive(const FileName: string; const Entries: array of TWriteEntry;
  const Groups: array of TSolidGroup; const Opt: TWriteOptions; Log: TLogProc): TWriteStats;
var
  Tmp: string;
  S: TFileStream;
  Hdr: TByteWriter;
  Control: array of TBlockInfo;
  Blocks: array of TDataBlock;
  DirGroup: TSolidGroup;
  i, n: Integer;
  DirData: TBytes;
  Ok: Boolean;
begin
  Result := Default(TWriteStats);
  if not EncoderAvailable(Opt.DirMethod) then
    raise EUnsupportedEncoder.CreateFmt('todavía no se puede comprimir con "%s"', [Opt.DirMethod]);
  for i := 0 to High(Groups) do
    if (Groups[i].CopyFrom = nil) and not EncoderAvailable(Groups[i].Method) then
      raise EUnsupportedEncoder.CreateFmt('todavía no se puede comprimir con "%s"', [Groups[i].Method]);

  Tmp := FileName + '.tmp';
  Ok := False;
  S := TFileStream.Create(FsPath(Tmp), fmCreate);
  try
    try
      // HEADER: firma + versión, sin comprimir
      Hdr.Clear;
      Hdr.U32(Signature(Opt.Parc));
      if Opt.Parc then Hdr.Raw(@VERSION_PARC[0], 4) else Hdr.Raw(@VERSION_ARC[0], 4);
      SetLength(Control, 1);
      Control[0] := WriteControlBlock(S, Opt.Parc, HEADER_BLOCK, 'storing', Hdr.Bytes);

      // Directorios primero, en un bloque sin datos (como splitToSolidBlocks de FreeArc)
      DirGroup := Default(TSolidGroup);   // CopyFrom = nil: los registros locales no se inicializan solos
      DirGroup.Method := 'storing';
      for i := 0 to High(Entries) do
        if Entries[i].Meta.IsDir then
        begin
          n := Length(DirGroup.Files);
          SetLength(DirGroup.Files, n + 1);
          DirGroup.Files[n] := i;
        end;
      Blocks := nil;
      if Length(DirGroup.Files) > 0 then
      begin
        SetLength(Blocks, 1);
        Blocks[0] := WriteDataBlock(S, Entries, DirGroup, Log, Result);
      end;
      for i := 0 to High(Groups) do
        if Length(Groups[i].Files) > 0 then
        begin
          n := Length(Blocks);
          SetLength(Blocks, n + 1);
          Blocks[n] := WriteDataBlock(S, Entries, Groups[i], Log, Result);
        end;

      // Directorio (los offsets de los bloques son relativos a su posición)
      DirData := BuildDirectory(Entries, Blocks, S.Position, Opt.Parc);
      SetLength(Control, 2);
      Control[1] := WriteControlBlock(S, Opt.Parc, DIR_BLOCK, Opt.DirMethod, DirData);

      // Footer (las posiciones de los bloques de control, relativas a la del footer)
      WriteControlBlock(S, Opt.Parc, FOOTER_BLOCK, Opt.DirMethod, BuildFooter(Control, S.Position, Opt.Comment));
      Result.ArcSize := S.Size;
      Ok := True;
    finally
      S.Free;
    end;
  finally
    if not Ok then DeleteFile(FsPath(Tmp));
  end;
  if not Opt.KeepTemp then FinishArchive(FileName);
end;

procedure FinishArchive(const FileName: string);
var
  Tmp: string;
begin
  Tmp := FileName + '.tmp';
  if FileExists(FsPath(FileName)) and not DeleteFile(FsPath(FileName)) then
    raise EFCreateError.CreateFmt('no se pudo reemplazar %s (¿está abierto?); el nuevo quedó en %s', [FileName, Tmp]);
  if not RenameFile(FsPath(Tmp), FsPath(FileName)) then
    raise EFCreateError.CreateFmt('no se pudo renombrar %s a %s', [Tmp, FileName]);
end;

end.
