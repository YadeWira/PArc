{ Escritura de archivos .parc (FORMATO-PARC.md).
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
    DirMethod: string;    // compresión del directorio y del footer
    Comment: RawByteString;
    Recovery: string;     // especificación del registro de recuperación ('' = sin), ya resuelta
    KeepTemp: Boolean;    // no renombrar: el llamador llama a FinishArchive (p. ej. después de
                          // cerrar el archivo viejo, que en Windows no se puede reemplazar abierto)
    Encryption: string;   // algoritmo (--encryption; "aes" = aes-256/ctr, como FreeArc)
    DataPassword: RawByteString;     // -p: cifra los bloques de datos ('' = sin cifrar)
    HeadersPassword: RawByteString;  // -hp: cifra también directorio y footer
    VolumeSize: Int64;    // -v: volúmenes de este tamaño (FileName.001, .002...); solo .parc
    Parallel: Boolean;    // comprimir grupos de datos independientes en paralelo
  end;

  TWriteStats = record
    Files, Dirs: Integer;
    Bytes, ArcSize: Int64;
  end;

  TLogProc = procedure(const Msg: string);

{ Escribe el archivo completo. Los grupos se escriben en orden; los directorios (entradas con
  Meta.IsDir) van en un bloque inicial sin datos, como hace FreeArc. }
function WriteArchive(const FileName: string; const Entries: TWriteEntryArray;
  const Groups: array of TSolidGroup; const Opt: TWriteOptions; Log: TLogProc): TWriteStats;

{ Reemplaza FileName por el temporal que dejó WriteArchive con KeepTemp. }
procedure FinishArchive(const FileName: string; VolumeSize: Int64 = 0);

{ Meta de una entrada que viene de un archivo existente. }
function MetaFromArchive(const F: TArcFileEntry): TFileMeta;

implementation

uses
  parc_bytes, parc_crc, parc_stream, parc_outstream, parc_encoders, parc_methods, parc_recovery, parc_progress,
  parc_volume, parc_parallel, parc_strmap;

const
  VERSION_PARC: array[0..3] of Byte = (PARC_FORMAT_VERSION, 0, 0, 0);
  COPY_BUF = 1 shl 20;

type
  TBlockInfo = record
    BlockType: Integer;
    Method: string;
    Pos, OrigSize, CompSize: Int64;
    Crc: LongWord;
  end;
  TBlockInfoArray = array of TBlockInfo;

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

{ Descriptor local (el formato base de FreeArc §3): firma, tipo, método, tamaños, CRC de los datos y
  CRC del propio descriptor. }
procedure WriteDescriptor(S: TStream; Parc: Boolean; const B: TBlockInfo);
var
  w: TByteWriter;
begin
  w.Clear;
  w.U32(PARC_SIGNATURE);
  w.VInt(B.BlockType);
  w.CStr(B.Method);
  w.VInt(B.OrigSize);
  w.VInt(B.CompSize);
  w.U32(B.Crc);
  w.U32(CalcCRC(PByte(w.Data), w.Len));
  S.WriteBuffer(w.Data[0], w.Len);
end;

function WriteControlBlock(S: TStream; Parc: Boolean; BlockType: Integer; const Method: string;
  const Data: TBytes; const Alg: string = ''; const Pwd: RawByteString = ''): TBlockInfo; forward;

{ Largo del descriptor de un bloque storing de Size bytes (no depende del CRC: siempre 4 bytes). }
function StoringDescriptorLen(Parc: Boolean; BlockType: Integer; Size: Int64): Integer;
var
  w: TByteWriter;
begin
  w.Clear;
  w.U32(PARC_SIGNATURE);
  w.VInt(BlockType);
  w.CStr('storing');
  w.VInt(Size);
  w.VInt(Size);
  w.U32(0);
  w.U32(0);
  Result := w.Len;
end;

{ Registro de recuperación (ArcRecover.hs; el formato base de FreeArc §7.4): dos RECOVERY_BLOCK storing,
  el de sectores y el de CRCs+info, protegiendo todo lo escrito hasta acá. El info guarda la
  posición del bloque de CRCs, así que hay que saber de antemano cuánto ocupa el de sectores. }
procedure WriteRecovery(S: TStream; const Spec: string; var Control: TBlockInfoArray);
var
  ArcSize, SectorsSize, CrcsSize, PosSectors, PosCrcs: Int64;
  SectorSize, RecSectors, n: Integer;
  Sectors, Crcs: TBytes;
  Info: TRecoveryInfo;
  B: TBlockInfo;
begin
  ArcSize := S.Position;
  if not RecoveryPlan(ArcSize, Spec, SectorSize, RecSectors, SectorsSize, CrcsSize) then   // .parc: Reed-Solomon
    raise Exception.CreateFmt('invalid -rr specification: "%s"', [Spec]);
  PosSectors := S.Position;
  PosCrcs := PosSectors + SectorsSize + StoringDescriptorLen(True, RECOVERY_BLOCK, SectorsSize);
  if not RecoveryBuild(S, ArcSize, 0, PosCrcs, Spec, Sectors, Crcs, Info) then
    raise Exception.Create('could not build the recovery record');
  S.Position := PosSectors;   // RecoveryBuild lee lo ya escrito
  // Solo el tamaño de los sectores decide dónde cae el bloque de CRCs; ese bloque lleva además
  // el addinfo (versión, tamaños) delante de los CRCs, así que mide más que CrcsSize
  if Length(Sectors) <> SectorsSize then
    raise Exception.CreateFmt('recovery record: %d sector bytes instead of %d',
      [Length(Sectors), SectorsSize]);
  n := Length(Control);
  SetLength(Control, n + 2);
  B := WriteControlBlock(S, True, RECOVERY_BLOCK, 'storing', Sectors);
  Control[n] := B;
  B := WriteControlBlock(S, True, RECOVERY_BLOCK, 'storing', Crcs);
  if B.Pos <> PosCrcs then raise Exception.Create('recovery record: CRC block position');
  Control[n + 1] := B;
end;

{ Escribe un bloque de control (datos comprimidos + descriptor) y devuelve su información. }
function WriteControlBlock(S: TStream; Parc: Boolean; BlockType: Integer; const Method: string;
  const Data: TBytes; const Alg: string; const Pwd: RawByteString): TBlockInfo;
var
  Comp: TBytes;
  EncMethod, Stored: string;
begin
  Result.BlockType := BlockType;
  Result.Method := Method;
  EncMethod := Method;
  if Pwd <> '' then
  begin
    // -hp: como el de datos, pero en el directorio y el footer (ArcvProcessCompress.hs)
    EncMethod := Method + '+' + MakeCipherStage(Alg, Pwd, Stored, Parc);
    Result.Method := Method + '+' + Stored;
  end;
  Result.Pos := S.Position;
  Result.OrigSize := Length(Data);
  Result.Crc := CalcCRC(PByte(Data), Length(Data));
  Comp := CompressMem(EncMethod, PByte(Data), Length(Data));
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

{ ZigZag: mapea Int64 a QWord para que los deltas chicos (positivos o negativos) ocupen
  pocos bytes en VInt. }
function ZigZag(V: Int64): QWord;
begin
  if V >= 0 then Result := QWord(V) shl 1
  else Result := (QWord(-V) shl 1) - 1;
end;

const
  POW10: array[0..9] of LongWord = (1, 10, 100, 1000, 10000, 100000, 1000000, 10000000,
    100000000, 1000000000);
  SUBSEC_SAMPLE = 65536;   // archivos que se miran para elegir la codificación de las fechas

{ Fechas del directorio: hay dos codificaciones sin pérdida (FORMATO-PARC.md §2).
  - MTIME_NS_DELTA (7): cada mtime en ns como delta zigzag del anterior. Ideal cuando muchos
    archivos seguidos tienen la misma fecha (instalaciones, copias sin ns).
  - MTIME_SUBSEC (8): solo la fracción de segundo; los segundos ya están en la columna Time.
    Con ns al azar (ext4, NTFS) ocupa bastante menos, y si no hay fracciones casi nada. Solo
    vale si todos los segundos entran en la columna Time (Int32: 1901-2038).
  Se elige la que comprimida con el método del directorio sale más chica (sobre los primeros
  SUBSEC_SAMPLE archivos, para acotar el costo en directorios enormes). Un PArc 0.0.2 no
  conoce el tag 8: lista y extrae con los segundos de la columna Time. }
procedure BuildMTimeField(const Ns: array of Int64; const DirMethod: string; out Tag: Integer;
  out Field: TByteWriter);
var
  f7, f8: TByteWriter;
  i, n, k, W, Sample: Integer;
  Sec, PrevNs: Int64;
  Sub: array of LongWord;
  MaxSub: LongWord;
  AllFit: Boolean;
  Len7, Len8: SizeInt;

  procedure PutSub(var Dst: TByteWriter; v: LongWord);
  var
    j: Integer;
  begin
    for j := 0 to W - 1 do
    begin
      Dst.U8(Byte(v));
      v := v shr 8;
    end;
  end;

begin
  n := Length(Ns);
  Sample := n;
  if Sample > SUBSEC_SAMPLE then Sample := SUBSEC_SAMPLE;
  f7.Clear;
  PrevNs := 0;
  Len7 := 0;
  for i := 0 to n - 1 do
  begin
    f7.VInt(ZigZag(Ns[i] - PrevNs));
    PrevNs := Ns[i];
    if i = Sample - 1 then Len7 := f7.Len;
  end;
  Tag := DIRTAG_MTIME_NS_DELTA;
  Field := f7;
  // Fracciones de segundo, si todos los segundos entran en la columna Time
  SetLength(Sub, n);
  AllFit := True;
  for i := 0 to n - 1 do
  begin
    Sec := Ns[i] div 1000000000;
    if (Ns[i] < 0) and (Ns[i] mod 1000000000 <> 0) then Dec(Sec);   // piso, como Time32
    if (Sec < Low(LongInt)) or (Sec > High(LongInt)) then
    begin
      AllFit := False;
      Break;
    end;
    Sub[i] := LongWord(Ns[i] - Sec * 1000000000);
  end;
  if not AllFit then Exit;
  // Unidad común más grande (10^k ns: 100 ns en NTFS, 1 µs...) y bytes por valor
  k := 9;
  MaxSub := 0;
  for i := 0 to n - 1 do
    if Sub[i] <> 0 then
    begin
      while (k > 0) and (Sub[i] mod POW10[k] <> 0) do Dec(k);
      if Sub[i] > MaxSub then MaxSub := Sub[i];
    end;
  if MaxSub = 0 then k := 9;
  MaxSub := MaxSub div POW10[k];
  W := 0;
  while (W < 4) and (QWord(MaxSub) >= QWord(1) shl (8 * W)) do Inc(W);
  f8.Clear;
  f8.U8(k);
  f8.U8(W);
  for i := 0 to n - 1 do PutSub(f8, Sub[i] div POW10[k]);
  if W = 0 then
  begin
    Tag := DIRTAG_MTIME_SUBSEC;
    Field := f8;
    Exit;
  end;
  // Comparar comprimidos (sobre una muestra del principio si es muy grande)
  Len8 := Length(CompressMem(DirMethod, PByte(f8.Data), 2 + Sample * W));
  Len7 := Length(CompressMem(DirMethod, PByte(f7.Data), Len7));
  if Len8 < Len7 then
  begin
    Tag := DIRTAG_MTIME_SUBSEC;
    Field := f8;
  end;
end;

{ Serializa el DIR_BLOCK (el formato base de FreeArc §6 + campos opcionales de FORMATO-PARC.md §2). }
function BuildDirectory(const Entries: array of TWriteEntry; const Blocks: array of TDataBlock;
  DirPos: Int64; Parc: Boolean; const DirMethod: string): TBytes;
var
  w, f: TByteWriter;
  All: array of TDirFile;
  DirMap: TStrIntMap;
  DirNames: array of string;
  Parent: string;
  DirIdx: array of Integer;
  b, i, n, k: Integer;
  Ns: array of Int64;
  Tag: Integer;
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
  // Mapa hash en vez de TStringList.IndexOf, que era O(archivos x directorios) con
  // AnsiCompareStr; igualdad de bytes y el mismo orden de aparición
  DirMap.Init(1024);
  DirNames := nil;
  SetLength(DirIdx, n);
  for i := 0 to n - 1 do
  begin
    Parent := ParentOf(Entries[All[i].Entry].StoredName);
    k := DirMap.Get(Parent);
    if k < 0 then
    begin
      k := DirMap.Count;
      if k >= Length(DirNames) then SetLength(DirNames, 2 * k + 64);
      DirMap.Put(Parent, k);
      DirNames[k] := Parent;
    end;
    DirIdx[i] := k;
  end;
  w.VInt(DirMap.Count);
  for i := 0 to DirMap.Count - 1 do w.CStr(DirNames[i]);

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
    // MTimeNs sin pérdida: delta zigzag (tag 7) o fracciones de segundo (tag 8)
    SetLength(Ns, n);
    for i := 0 to n - 1 do Ns[i] := Entries[All[i].Entry].Meta.MTimeNs;
    BuildMTimeField(Ns, DirMethod, Tag, f);
    OptField(Tag, f);
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
    // Enlaces simbólicos: solo los que hay (cantidad, y por cada uno índice, destino, ¿a dir?)
    k := 0;
    for i := 0 to n - 1 do
      if Entries[All[i].Entry].Meta.IsLink then Inc(k);
    if k > 0 then
    begin
      f.Clear;
      f.VInt(k);
      for i := 0 to n - 1 do
        with Entries[All[i].Entry].Meta do
          if IsLink then
          begin
            f.VInt(i);
            f.CStr(LinkTarget);
            f.U8(Ord(LinkToDir));
          end;
      OptField(DIRTAG_SYMLINK, f);
    end;
  end;
  w.VInt(DIRTAG_END);
  Result := w.Bytes;
end;

{ FOOTER_BLOCK (el formato base de FreeArc §5.1): bloques de control, locked, comentario viejo (0),
  recovery ('') y comentario (0 bytes). }
function BuildFooter(const Control: array of TBlockInfo; FooterPos: Int64; const Comment: RawByteString;
  const Recovery: string): TBytes;
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
  w.CStr(Recovery);   // configuración de -rr (para conservarla al actualizar)
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
  Result.IsLink := F.IsLink;
  Result.LinkToDir := F.LinkToDir;
  Result.LinkTarget := F.LinkTarget;
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
      if n > 0 then
      begin
        S.WriteBuffer(Buf[0], n);
        ProgressAdd(n);
      end;
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

function WriteDataBlock(S: TStream; const Entries: TWriteEntryArray; const G: TSolidGroup;
  const Opt: TWriteOptions; Log: TLogProc; var Stats: TWriteStats; Quiet: Boolean = False): TDataBlock;
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
  EncMethod, Stored: string;
  Pwd: RawByteString;
  Encrypted: Boolean;

  procedure SkipIn(Count: Int64);
  var
    m: SizeInt;
  begin
    while Count > 0 do
    begin
      if Count > Length(Buf) then m := Length(Buf) else m := Count;
      CurChain.ReadExact(@Buf[0], m);
      CheckCancel;   // lo salteado no está en el total del progreso
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
  // Un bloque viejo que se reempaqueta trae su cifrado guardado (sin clave): se saca, y si hay
  // -p se vuelve a cifrar con sal e IV nuevos
  Result.Method := LimitMethodToSize(WithoutCipher(G.Method), Size);
  EncMethod := Result.Method;
  // -p: cifrado al final de la cadena, con sal e IV propios del bloque (como FreeArc). En el
  // archivo queda la etapa sin la clave; el codificador usa la que la trae
  // Un bloque que ya estaba cifrado se vuelve a cifrar aunque no se haya dado -p (con la
  // contraseña con que se leyó): borrar un archivo no tiene que dejar el resto en claro
  Pwd := Opt.DataPassword;
  if Pwd = '' then
  begin
    Encrypted := WithoutCipher(G.Method) <> G.Method;
    // o algún archivo viene de un bloque viejo cifrado (al actualizar, el grupo trae el
    // método del preset, no el del bloque de donde salió)
    for i := 0 to High(G.Files) do
      with Entries[G.Files[i]] do
        if (SrcArc <> nil) and not Meta.IsDir and
           (WithoutCipher(SrcArc.DataBlocks[SrcArc.Files[SrcIndex].DataBlock].Method) <>
            SrcArc.DataBlocks[SrcArc.Files[SrcIndex].DataBlock].Method) then Encrypted := True;
    if Encrypted then Pwd := ArchivePassword;
  end;
  if (Pwd <> '') and (Size > 0) then
  begin
    EncMethod := Result.Method + '+' + MakeCipherStage(Opt.Encryption, Pwd, Stored, True);
    Result.Method := Result.Method + '+' + Stored;
  end;
  Result.Pos := S.Position;
  SetLength(Result.Files, Length(G.Files));
  SetLength(Buf, COPY_BUF);
  Enc4x4BlockHint := Size;   // (lo lee 4x4 al armarse la cadena, en este hilo)
  try
    Chain := CreateEncoderChain(EncMethod, TStreamSink.Create(S));
  finally
    Enc4x4BlockHint := 0;
  end;
  try
    for i := 0 to High(G.Files) do
    begin
      n := G.Files[i];
      Crc := CRC_INIT;
      Size := 0;
      if not Quiet and not Entries[n].Meta.IsDir then ProgressFile(Entries[n].StoredName);
      if not Entries[n].Meta.IsDir and not Entries[n].Meta.IsLink and (Entries[n].SrcArc <> nil) then
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
            if not Quiet then ProgressAdd(Got);
            Inc(Size, Got);
            Dec(Remaining, Got);
          end;
          CurNext := SrcIndex + 1;
          if (Crc xor CRC_INIT) <> SrcArc.Files[SrcIndex].Crc then
            raise EArcCorrupt.CreateFmt('wrong CRC in %s of the original archive: a damaged archive is not repacked', [StoredName]);
        end;
        Inc(Stats.Files);
        Inc(Stats.Bytes, Size);
      end
      else if Entries[n].Meta.IsLink then
        Inc(Stats.Files)
      else if not Entries[n].Meta.IsDir then
      begin
        F := TFileStream.Create(FsPath(Entries[n].DiskPath), fmOpenRead or fmShareDenyNone);   // también los que otro programa está escribiendo (logs): se avisa si cambian
        try
          repeat
            Got := F.Read(Buf[0], Length(Buf));
            if Got > 0 then
            begin
              Crc := UpdateCRC(Crc, @Buf[0], Got);
              Chain.Write(@Buf[0], Got);
              if not Quiet then ProgressAdd(Got);
              Inc(Size, Got);
            end;
          until Got <= 0;
        finally
          F.Free;
        end;
        if Size <> Entries[n].Meta.Size then
          if not Quiet and Assigned(Log) then Log(Format('Warning: %s changed size while being read (%d -> %d bytes)',
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

{ Salida de un bloque comprimido en un hilo. Mientras el bloque no es el siguiente a escribir,
  lo comprimido se guarda en memoria (con el presupuesto global de parc_parallel) y, si no
  alcanza, sigue en un temporal. Cuando le toca, el hilo principal vuelca lo guardado al archivo
  y el resto se escribe directo ahí: el bloque en curso no pasa por memoria ni por disco dos
  veces. Position es la lógica (bytes escritos a este bloque), que es lo que usa WriteDataBlock. }
type
  TBlockOut = class(TStream)
  private
    FLock: TRTLCriticalSection;
    FChunks: array of TBytes;   // en memoria, en orden; el último puede estar a medio llenar
    FCount: Integer;
    FLastUsed: SizeInt;
    FReserved: Int64;           // reservado del presupuesto global
    FSpill: TFileStream;        // lo que no entró en memoria (después de lo de FChunks)
    FSpillName: string;
    FDirect: TStream;           // <> nil: ya es su turno, se escribe al archivo
    FPos: Int64;
  protected
    function GetSize: Int64; override;
  public
    constructor Create(const SpillName: string);
    destructor Destroy; override;
    function Write(const Buffer; Count: LongInt): LongInt; override;
    function Read(var Buffer; Count: LongInt): LongInt; override;
    function Seek(const Offset: Int64; Origin: TSeekOrigin): Int64; override;
    { Vuelca lo guardado en S y pasa a escribir directo ahí (hilo principal). }
    procedure GoDirect(S: TStream);
  end;

const
  OUT_CHUNK = 1 shl 20;

constructor TBlockOut.Create(const SpillName: string);
begin
  inherited Create;
  InitCriticalSection(FLock);
  FSpillName := SpillName;
end;

destructor TBlockOut.Destroy;
begin
  FChunks := nil;
  if FReserved > 0 then MemBudgetRelease(FReserved);
  FReserved := 0;
  if FSpill <> nil then
  begin
    FreeAndNil(FSpill);
    DeleteFile(FsPath(FSpillName));
  end;
  DoneCriticalSection(FLock);
  inherited Destroy;
end;

function TBlockOut.GetSize: Int64;
begin
  Result := FPos;
end;

function TBlockOut.Read(var Buffer; Count: LongInt): LongInt;
begin
  raise EStreamError.Create('TBlockOut: read not supported');
end;

function TBlockOut.Seek(const Offset: Int64; Origin: TSeekOrigin): Int64;
begin
  if not (((Origin = soBeginning) and (Offset = FPos)) or ((Origin <> soBeginning) and (Offset = 0))) then
    raise EStreamError.Create('TBlockOut: seek not supported');
  Result := FPos;
end;

function TBlockOut.Write(const Buffer; Count: LongInt): LongInt;
var
  P: PByte;
  n: SizeInt;
begin
  Result := Count;
  if Count <= 0 then Exit;
  P := @Buffer;
  EnterCriticalSection(FLock);
  try
    Inc(FPos, Count);
    if FDirect <> nil then
    begin
      FDirect.WriteBuffer(P^, Count);
      Exit;
    end;
    while (Count > 0) and (FSpill = nil) do
    begin
      if (FCount = 0) or (FLastUsed = Length(FChunks[FCount - 1])) then
      begin
        // otro pedazo, si el presupuesto lo permite (las escrituras grandes, de su tamaño)
        if Count > OUT_CHUNK then n := Count else n := OUT_CHUNK;
        if not MemBudgetTryReserve(n) then
        begin
          FSpill := TFileStream.Create(FsPath(FSpillName), fmCreate);
          Break;
        end;
        Inc(FReserved, n);
        if FCount = Length(FChunks) then SetLength(FChunks, 2 * FCount + 8);
        SetLength(FChunks[FCount], n);
        Inc(FCount);
        FLastUsed := 0;
      end;
      n := Length(FChunks[FCount - 1]) - FLastUsed;
      if n > Count then n := Count;
      Move(P^, FChunks[FCount - 1][FLastUsed], n);
      Inc(FLastUsed, n);
      Inc(P, n);
      Dec(Count, n);
    end;
    if Count > 0 then FSpill.WriteBuffer(P^, Count);
  finally
    LeaveCriticalSection(FLock);
  end;
end;

procedure TBlockOut.GoDirect(S: TStream);
var
  i: Integer;
begin
  EnterCriticalSection(FLock);
  try
    for i := 0 to FCount - 1 do
    begin
      if i < FCount - 1 then S.WriteBuffer(FChunks[i][0], Length(FChunks[i]))
      else if FLastUsed > 0 then S.WriteBuffer(FChunks[i][0], FLastUsed);
      FChunks[i] := nil;
    end;
    FChunks := nil;
    FCount := 0;
    if FReserved > 0 then MemBudgetRelease(FReserved);
    FReserved := 0;
    if FSpill <> nil then
    begin
      FSpill.Position := 0;
      S.CopyFrom(FSpill, FSpill.Size);
      FreeAndNil(FSpill);
      DeleteFile(FsPath(FSpillName));
    end;
    FDirect := S;
  finally
    LeaveCriticalSection(FLock);
  end;
end;

{ Un bloque comprimido en un hilo, con su salida y sus estadísticas. }
type
  TWriteBlockJob = class(TParallelJob)
  public
    Entries: TWriteEntryArray;
    Group: TSolidGroup;
    Opt: TWriteOptions;
    Output: TBlockOut;
    Block: TDataBlock;
    Stats: TWriteStats;
    OrigBytes: Int64;
    procedure Process; override;
    destructor Destroy; override;
  end;

destructor TWriteBlockJob.Destroy;
begin
  Output.Free;
  inherited Destroy;
end;

procedure TWriteBlockJob.Process;
var
  i: Integer;
begin
  OrigBytes := 0;
  for i := 0 to High(Group.Files) do
    if not Entries[Group.Files[i]].Meta.IsDir then
      Inc(OrigBytes, Entries[Group.Files[i]].Meta.Size);
  Stats := Default(TWriteStats);
  Block := WriteDataBlock(Output, Entries, Group, Opt, nil, Stats, True);
end;

const
  { Entrada de los bloques que se pueden ir comprimiendo detrás del que se está escribiendo
    (su salida espera en memoria, con el presupuesto de PARC_BUFMEM, o en un temporal). }
  AHEAD_BYTES = {$IFDEF CPU64}Int64(256) shl 20{$ELSE}Int64(64) shl 20{$ENDIF};

{ Cuántos bloques se comprimen a la vez: hasta el presupuesto de hilos y la cantidad de
  bloques con datos, mientras la memoria estimada de sus compresores entre en la mitad de la
  RAM (la estimación del decodificador por 8: lzma bt4 usa ~11 veces el diccionario, que ya
  está limitado al tamaño del bloque). Las fichas que no usan los bloques las toman sus pools
  internos. }
function BlockWorkers(const Entries: TWriteEntryArray; const AllGroups: TSolidGroupArray): Integer;
var
  Est: array of Int64;
  i, k, n: Integer;
  Size: Int64;
begin
  SetLength(Est, Length(AllGroups));
  n := 0;
  for i := 0 to High(AllGroups) do
  begin
    Size := 0;
    for k := 0 to High(AllGroups[i].Files) do
      if not Entries[AllGroups[i].Files[k]].Meta.IsDir then Inc(Size, Entries[AllGroups[i].Files[k]].Meta.Size);
    if (Size = 0) or IsStoring(AllGroups[i].Method) then Continue;
    Est[n] := 8 * EstimateDecodeMem(LimitMethodToSize(WithoutCipher(AllGroups[i].Method), Size), Size);
    Inc(n);
  end;
  SetLength(Est, n);
  Result := BudgetThreads;
  if Result > n then Result := n;
  Result := ThreadsForMemory(Est, Result);
end;

{ Ordena AllGroups[First..] por tamaño de entrada, de mayor a menor (estable; storing cuenta
  0); antes de First está el grupo de directorios y enlaces, que queda primero. Nada si algún
  grupo copia un bloque viejo o algún archivo sale de un archivo viejo. Con -s- hay un grupo
  por archivo (decenas de miles): merge sort de índices y una sola permutación, O(G log G);
  la inserción sobre los registros (con campos gestionados) era cuadrática y tardaba más que
  comprimir. }
procedure SortGroupsBySize(const Entries: TWriteEntryArray; var AllGroups: TSolidGroupArray;
  First: Integer);
var
  Key: array of Int64;
  Idx, Tmp: array of Integer;
  Sorted: TSolidGroupArray;
  i, k: Integer;

  procedure Merge(Lo, Mid, Hi: Integer);
  var
    i, j, k: Integer;
  begin
    i := Lo; j := Mid; k := Lo;
    while (i < Mid) and (j < Hi) do
    begin
      // estable: el de la derecha pasa solo si es estrictamente mayor
      if Key[Idx[j]] > Key[Idx[i]] then begin Tmp[k] := Idx[j]; Inc(j); end
      else begin Tmp[k] := Idx[i]; Inc(i); end;
      Inc(k);
    end;
    while i < Mid do begin Tmp[k] := Idx[i]; Inc(i); Inc(k); end;
    while j < Hi do begin Tmp[k] := Idx[j]; Inc(j); Inc(k); end;
    for k := Lo to Hi - 1 do Idx[k] := Tmp[k];
  end;

  procedure Sort(Lo, Hi: Integer);
  var
    Mid: Integer;
  begin
    if Hi - Lo < 2 then Exit;
    Mid := (Lo + Hi) div 2;
    Sort(Lo, Mid);
    Sort(Mid, Hi);
    if Key[Idx[Mid]] > Key[Idx[Mid - 1]] then Merge(Lo, Mid, Hi);   // (ya en orden: nada)
  end;

begin
  for i := 0 to High(AllGroups) do
    if AllGroups[i].CopyFrom <> nil then Exit;
  for i := 0 to High(Entries) do
    if Entries[i].SrcArc <> nil then Exit;
  if Length(AllGroups) - First < 2 then Exit;
  SetLength(Key, Length(AllGroups));
  SetLength(Idx, Length(AllGroups));
  for i := 0 to High(AllGroups) do
  begin
    Idx[i] := i;
    Key[i] := 0;
    if not IsStoring(AllGroups[i].Method) then
      for k := 0 to High(AllGroups[i].Files) do
        if not Entries[AllGroups[i].Files[k]].Meta.IsDir then
          Inc(Key[i], Entries[AllGroups[i].Files[k]].Meta.Size);
  end;
  SetLength(Tmp, Length(AllGroups));
  Sort(First, Length(AllGroups));
  SetLength(Sorted, Length(AllGroups));
  for i := 0 to High(AllGroups) do
    Sorted[i] := AllGroups[Idx[i]];
  AllGroups := Sorted;
end;

function WriteArchive(const FileName: string; const Entries: TWriteEntryArray;
  const Groups: array of TSolidGroup; const Opt: TWriteOptions; Log: TLogProc): TWriteStats;
var
  Tmp: string;
  S: TStream;
  Hdr: TByteWriter;
  Control: TBlockInfoArray;
  Blocks: array of TDataBlock;
  DirGroup: TSolidGroup;
  AllGroups: TSolidGroupArray;
  Jobs: array of TWriteBlockJob;
  Pool: TJobPool;
  i, n, k: Integer;
  DirData: TBytes;
  Ok, UseParallel: Boolean;
  Total, BlockPos: Int64;
  Window, Workers, Next: Integer;
  Sizes: array of Int64;
  Ahead: Int64;
  HadToken: Boolean;
begin
  Result := Default(TWriteStats);
  if not EncoderAvailable(Opt.DirMethod) then
    raise EUnsupportedEncoder.CreateFmt('cannot compress with "%s" yet', [Opt.DirMethod]);
  for i := 0 to High(Groups) do
    if (Groups[i].CopyFrom = nil) and not EncoderAvailable(WithoutCipher(Groups[i].Method)) then
      raise EUnsupportedEncoder.CreateFmt('cannot compress with "%s" yet', [Groups[i].Method]);

  // Total para el progreso: bytes a comprimir, más los comprimidos de los bloques que se copian
  Total := 0;
  for i := 0 to High(Groups) do
    if Groups[i].CopyFrom <> nil then
      Inc(Total, Groups[i].CopyFrom.DataBlocks[Groups[i].CopyBlock].CompSize)
    else
      for n := 0 to High(Groups[i].Files) do
        if not Entries[Groups[i].Files[n]].Meta.IsDir then Inc(Total, Entries[Groups[i].Files[n]].Meta.Size);

  Tmp := FileName + '.tmp';
  Ok := False;
  ProgressBegin('Compressing', Total);
  if Opt.VolumeSize > 0 then S := TVolumeStream.CreateWrite(Tmp, Opt.VolumeSize)
  else S := TFileStream.Create(FsPath(Tmp), fmCreate);
  try
    try
      // HEADER: firma + versión, sin comprimir
      Hdr.Clear;
      Hdr.U32(PARC_SIGNATURE);
      Hdr.Raw(@VERSION_PARC[0], 4);
      SetLength(Control, 1);
      Control[0] := WriteControlBlock(S, True, HEADER_BLOCK, 'storing', Hdr.Bytes);

      // Directorios primero, en un bloque sin datos (como splitToSolidBlocks de FreeArc)
      DirGroup := Default(TSolidGroup);   // CopyFrom = nil: los registros locales no se inicializan solos
      DirGroup.Method := 'storing';
      // (tamaños de una vez, no de a uno: con -s- hay un grupo por archivo)
      SetLength(DirGroup.Files, Length(Entries));
      n := 0;
      for i := 0 to High(Entries) do
        if Entries[i].Meta.IsDir or Entries[i].Meta.IsLink then   // los enlaces tampoco tienen datos
        begin
          DirGroup.Files[n] := i;
          Inc(n);
        end;
      SetLength(DirGroup.Files, n);
      Blocks := nil;
      SetLength(AllGroups, Length(Groups) + 1);
      n := 0;
      if Length(DirGroup.Files) > 0 then
      begin
        AllGroups[0] := DirGroup;
        n := 1;
      end;
      for i := 0 to High(Groups) do
        if Length(Groups[i].Files) > 0 then
        begin
          AllGroups[n] := Groups[i];
          Inc(n);
        end;
      SetLength(AllGroups, n);

      // Bloques más grandes primero (como la planificación LPT): los hilos empiezan por lo que
      // más tarda y el final queda con bloques chicos, no con uno grande y los demás hilos sin
      // trabajo; t/x los toman en el mismo orden. Solo cambia el orden de los bloques en el
      // archivo (y en el listado), no su contenido; el orden depende solo de los datos. No al
      // actualizar: los archivos que salen de bloques viejos se leen en orden
      SortGroupsBySize(Entries, AllGroups, Ord(Length(DirGroup.Files) > 0));

      // Lo que se va a comprimir, para el tamaño de bloque de 4x4 (Adaptive4x4Block)
      Enc4x4TotalHint := 0;
      for i := 0 to High(AllGroups) do
        if (AllGroups[i].CopyFrom = nil) and not IsStoring(AllGroups[i].Method) then
          for k := 0 to High(AllGroups[i].Files) do
            if not Entries[AllGroups[i].Files[k]].Meta.IsDir then
              Inc(Enc4x4TotalHint, Entries[AllGroups[i].Files[k]].Meta.Size);

      // (con un solo hilo se escribe directo, sin pasar por el camino de los trabajos)
      UseParallel := Opt.Parallel and (Length(AllGroups) > 1) and (BudgetThreads >= 2) and
        (Opt.DataPassword = '') and (Opt.HeadersPassword = '');
      if UseParallel then
      begin
        n := 0;
        for i := 0 to High(AllGroups) do
          for k := 0 to High(AllGroups[i].Files) do
            if not Entries[AllGroups[i].Files[k]].Meta.IsDir then
            begin
              Inc(n);
              Break;
            end;
        if n < 2 then UseParallel := False;   // los directorios solos no justifican hilos
      end;
      if UseParallel then
        for i := 0 to High(Entries) do
          if Entries[i].SrcArc <> nil then UseParallel := False;
      if UseParallel then
        for i := 0 to High(AllGroups) do
          if AllGroups[i].CopyFrom <> nil then UseParallel := False;

      Workers := 0;
      if UseParallel then
      begin
        Workers := BlockWorkers(Entries, AllGroups);
        if Workers < 2 then UseParallel := False;
      end;

      if UseParallel then
      begin
        n := Length(AllGroups);
        SetLength(Jobs, n);
        Pool := TJobPool.Create(Workers, n);
        // Cada bloque planea sus pools internos (4x4, grzip, REP) con su parte del presupuesto;
        // si después sobran fichas (los últimos bloques), 4x4/grzip crecen solos
        Pool.Share := BudgetThreads div Workers;
        if Pool.Share < 1 then Pool.Share := 1;
        // Este hilo casi solo espera: sin ficha mientras tanto (las N son de los que comprimen),
        // salvo para copiar al archivo lo que un bloque ya dejó en memoria
        HadToken := BudgetWaitBegin;
        try
          for i := 0 to n - 1 do
          begin
            Jobs[i] := TWriteBlockJob.Create;
            Jobs[i].Entries := Entries;
            Jobs[i].Group := AllGroups[i];
            Jobs[i].Opt := Opt;
            Jobs[i].Output := TBlockOut.Create(FileName + '.blk' + IntToStr(i));
          end;
          // Ventana de trabajos en vuelo: lo que no es el bloque en curso espera en memoria,
          // así que no se arranca todo de una vez. Además de 2 por hilo, los que entren en
          // AHEAD_BYTES de entrada (hasta 16 por hilo): si no, un bloque grande seguido de
          // muchos chicos dejaba sin trabajo a los demás hilos hasta terminarlo, y otro bloque
          // grande más adelante no podía empezar (con muchos archivos chicos, todo en serie)
          Window := 2 * Pool.MaxWorkers;
          SetLength(Sizes, n);
          for i := 0 to n - 1 do
          begin
            Sizes[i] := 0;
            for k := 0 to High(AllGroups[i].Files) do
              if not Entries[AllGroups[i].Files[k]].Meta.IsDir then
                Inc(Sizes[i], Entries[AllGroups[i].Files[k]].Meta.Size);
          end;
          Next := 0;
          Ahead := 0;
          SetLength(Blocks, n);
          for i := 0 to n - 1 do
          begin
            // Ahead: entrada de los trabajos enviados después del bloque en curso (i)
            if i < Next then Dec(Ahead, Sizes[i]);
            while (Next < n) and ((Next <= i + Window) or
              ((Next - i <= 16 * Pool.MaxWorkers) and (Ahead + Sizes[Next] <= AHEAD_BYTES))) do
            begin
              Pool.Submit(Jobs[Next]);
              if Next > i then Inc(Ahead, Sizes[Next]);
              Inc(Next);
            end;
            Blocks[i].Pos := S.Position;
            // Lo ya comprimido, y el resto directo al archivo. Copiar lo guardado sí es trabajo
            // (puede ser mucho): con ficha
            BudgetWaitEnd(HadToken);
            try
              Jobs[i].Output.GoDirect(S);
            finally
              HadToken := BudgetWaitBegin;
            end;
            Pool.WaitJob(Jobs[i]);
            BlockPos := Blocks[i].Pos;
            Blocks[i] := Jobs[i].Block;
            Blocks[i].Pos := BlockPos;
            if S.Position - BlockPos <> Blocks[i].CompSize then
              raise Exception.Create('parallel block size mismatch');
            FreeAndNil(Jobs[i].Output);
            Inc(Result.Files, Jobs[i].Stats.Files);
            Inc(Result.Dirs, Jobs[i].Stats.Dirs);
            Inc(Result.Bytes, Jobs[i].Stats.Bytes);
            ProgressAdd(Jobs[i].OrigBytes);
          end;
        finally
          Pool.Free;   // espera a los hilos antes de liberar sus trabajos (y sus temporales)
          BudgetWaitEnd(HadToken);
          for i := 0 to High(Jobs) do Jobs[i].Free;
        end;
      end
      else
        for i := 0 to High(AllGroups) do
        begin
          n := Length(Blocks);
          SetLength(Blocks, n + 1);
          Blocks[n] := WriteDataBlock(S, Entries, AllGroups[i], Opt, Log, Result);
        end;

      ProgressEnd;
      CheckCancel;
      Enc4x4TotalHint := 0;

      // Directorio (los offsets de los bloques son relativos a su posición)
      DirData := BuildDirectory(Entries, Blocks, S.Position, True, Opt.DirMethod);
      SetLength(Control, 2);
      Control[1] := WriteControlBlock(S, True, DIR_BLOCK, Opt.DirMethod, DirData, Opt.Encryption, Opt.HeadersPassword);

      if Opt.Recovery <> '' then
      begin
        // Como ArcvProcessRead.hs: primero un footer provisional (encabezado y directorio, sin
        // recovery), que el registro también protege; al final se repite con la lista entera.
        // Sin él, los bloques de recuperación caen en otro lugar y la paridad de la cola cambia
        WriteControlBlock(S, True, FOOTER_BLOCK, Opt.DirMethod, BuildFooter(Control, S.Position, Opt.Comment, ''),
          Opt.Encryption, Opt.HeadersPassword);
        WriteRecovery(S, Opt.Recovery, Control);
      end;
      // Footer (las posiciones de los bloques de control, relativas a la del footer)
      WriteControlBlock(S, True, FOOTER_BLOCK, Opt.DirMethod, BuildFooter(Control, S.Position, Opt.Comment, Opt.Recovery),
        Opt.Encryption, Opt.HeadersPassword);
      Result.ArcSize := S.Size;
      Ok := True;
    finally
      Enc4x4TotalHint := 0;
      S.Free;
    end;
  finally
    if not Ok then
      if Opt.VolumeSize > 0 then DeleteVolumesFrom(Tmp, 1) else DeleteFile(FsPath(Tmp));
  end;
  if not Opt.KeepTemp then FinishArchive(FileName, Opt.VolumeSize);
end;

procedure FinishArchive(const FileName: string; VolumeSize: Int64);
var
  Tmp: string;
  i: Integer;
begin
  Tmp := FileName + '.tmp';
  if VolumeSize > 0 then
  begin
    // FileName.tmp.001... -> FileName.001...; fuera la versión anterior (suelta o en
    // volúmenes), incluidos los volúmenes que sobren si ahora son menos
    if FileExists(FsPath(FileName)) and not DeleteFile(FsPath(FileName)) then
      raise EFCreateError.CreateFmt('could not replace %s (is it open?)', [FileName]);
    i := 1;
    while FileExists(FsPath(VolumeName(Tmp, i))) do
    begin
      if FileExists(FsPath(VolumeName(FileName, i))) and not DeleteFile(FsPath(VolumeName(FileName, i))) then
        raise EFCreateError.CreateFmt('could not replace %s (is it open?); the new file was left at %s',
          [VolumeName(FileName, i), VolumeName(Tmp, i)]);
      if not RenameFile(FsPath(VolumeName(Tmp, i)), FsPath(VolumeName(FileName, i))) then
        raise EFCreateError.CreateFmt('could not rename %s to %s', [VolumeName(Tmp, i), VolumeName(FileName, i)]);
      Inc(i);
    end;
    DeleteVolumesFrom(FileName, i);
    Exit;
  end;
  if FileExists(FsPath(FileName)) and not DeleteFile(FsPath(FileName)) then
    raise EFCreateError.CreateFmt('could not replace %s (is it open?); the new file was left at %s', [FileName, Tmp]);
  if not RenameFile(FsPath(Tmp), FsPath(FileName)) then
    raise EFCreateError.CreateFmt('could not rename %s to %s', [Tmp, FileName]);
  DeleteVolumesFrom(FileName, 1);   // si antes estaba en volúmenes
end;

end.
