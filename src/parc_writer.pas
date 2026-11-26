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
    Encryption: string;   // -ae=: "chacha" (XChaCha20-Poly1305) o "aes" (AES-256-GCM), con :t/:m/:p
    DataPassword: RawByteString;     // -p: cifra los bloques de datos ('' = sin cifrar)
    HeadersPassword: RawByteString;  // -hp: cifra también directorio y footer
    VolumeSize: Int64;    // -v: volúmenes de este tamaño (FileName.001, .002...); solo .parc
    Parallel: Boolean;    // comprimir grupos de datos independientes en paralelo
    Locked: Boolean;      // -k / k: marca de bloqueado en el footer (no se modifica más)
    { ch con -p/-hp/-p-: la contraseña cambia. Los bloques viejos se leen con las que se dieron
      (-op, consola) y todo se reempaqueta solo con DataPassword ('' = sin cifrar), sin exigir
      que sea la de los bloques viejos. }
    ChangePassword: Boolean;
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

{ Reemplaza FileName por el temporal que dejó WriteArchive con KeepTemp. Si el temporal está
  en otro sistema de archivos (-w) y no se puede renombrar, se copia primero al lado del final. }
procedure FinishArchive(const FileName: string; VolumeSize: Int64 = 0);

{ El temporal del archivo que se escribe: FileName.tmp, o con -w <WorkDir>/<nombre>.<pid>.tmp. }
function TempArchiveName(const FileName: string): string;
{ Mueve Src a Dst (que no debe existir): rename, o copia y borrado si cruza sistemas de archivos. }
function MoveFileAcross(const Src, Dst: string): Boolean;

var
  { -w<dir>: directorio de los temporales (el archivo a medio escribir, los bloques que esperan
    turno); '' = junto al archivo. }
  WorkDir: string = '';

{ Meta de una entrada que viene de un archivo existente. }
function MetaFromArchive(const F: TArcFileEntry): TFileMeta;

implementation

uses
  parc_bytes, parc_crc, parc_stream, parc_outstream, parc_encoders, parc_methods, parc_recovery, parc_progress,
  parc_volume, parc_parallel, parc_strmap, parc_crypt, parc_canon;

const
  COPY_BUF = 1 shl 20;

type
  { Estado de un archivo ya escrito, en el orden del índice. }
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

const
  POW10: array[0..9] of LongWord = (1, 10, 100, 1000, 10000, 100000, 1000000, 10000000,
    100000000, 1000000000);

{ Seconds (floor) and sub-second nanoseconds of a time in ns. }
procedure SplitNs(Ns: Int64; out Sec: Int64; out Sub: LongWord);
begin
  Sec := Ns div 1000000000;
  if (Ns < 0) and (Ns mod 1000000000 <> 0) then Dec(Sec);
  Sub := LongWord(Ns - Sec * 1000000000);
end;

{ The index payload (FORMATO-PARC.md §3): a list of sections "U8 id · Uv length · bytes",
  ended by id 0. Entries in index order: the ones without data (directories, links) first,
  then the files of each data block in block order. NoData: Blocks[0] is the pseudo-block of
  the entries without data (it has no bytes and is not stored as a block). FirstPos: where
  the first data block starts (from the archive start). }
function BuildIndex(const Entries: array of TWriteEntry; const Blocks: array of TDataBlock;
  NoData: Boolean; FirstPos: Int64; const Opt: TWriteOptions): TBytes;
var
  w, f: TByteWriter;
  All: array of TDirFile;
  DirMap, MethMap: TStrIntMap;
  DirNames, MethNames: array of string;
  Parent, Prev: string;
  DirIdx: array of Integer;
  b, i, n, k, Z, B0, NB, Wd, Ws, Unit10: Integer;
  Secs: array of Int64;
  Subs: array of LongWord;
  MinSec, MaxRel, MaxSize: Int64;
  MaxSub: LongWord;
  AllWin, AllUnix: Boolean;
  Flags: QWord;
  Kind: Byte;

  procedure Section(Id: Byte; const Body: TByteWriter);
  begin
    w.U8(Id);
    w.Uv(Body.Len);
    w.Raw(PByte(Body.Data), Body.Len);
  end;

begin
  // Every entry, in index order
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
  Z := 0;
  B0 := 0;
  if NoData and (Length(Blocks) > 0) then
  begin
    Z := Length(Blocks[0].Files);
    B0 := 1;
  end;
  NB := Length(Blocks) - B0;

  w.Clear;
  // 1. ARCHIVE: flags, entries, entries without data, blocks
  f.Clear;
  Flags := 0;
  if Opt.Locked then Flags := Flags or ARC_FLAG_LOCKED;
  f.Uv(Flags);
  f.Uv(n);
  f.Uv(Z);
  f.Uv(NB);
  Section(SEC_ARCHIVE, f);

  // 2. BLOCKS: one run (they are written back to back), method table, per-block columns
  if NB > 0 then
  begin
    f.Clear;
    f.Uv(1);
    f.Uv(QWord(FirstPos));
    f.Uv(NB);
    MethMap.Init(64);
    MethNames := nil;
    SetLength(DirIdx, NB);
    for b := B0 to High(Blocks) do
    begin
      k := MethMap.Get(Blocks[b].Method);
      if k < 0 then
      begin
        k := MethMap.Count;
        if k >= Length(MethNames) then SetLength(MethNames, 2 * k + 8);
        MethMap.Put(Blocks[b].Method, k);
        MethNames[k] := Blocks[b].Method;
      end;
      DirIdx[b - B0] := k;
    end;
    f.Uv(MethMap.Count);
    for i := 0 to MethMap.Count - 1 do f.Str(MethNames[i]);
    for b := 0 to NB - 1 do f.Uv(DirIdx[b]);
    for b := B0 to High(Blocks) do f.Uv(Length(Blocks[b].Files));
    for b := B0 to High(Blocks) do f.Uv(QWord(Blocks[b].CompSize));
    Section(SEC_BLOCKS, f);
  end;

  if n = 0 then
  begin
    w.U8(SEC_END);
    Exit(w.Bytes);
  end;

  // 3. NAMES: parent directories (front-coded against the previous one, in order of first
  // use), base names, and each entry's directory as a delta from the previous entry's
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
  f.Clear;
  f.Uv(DirMap.Count);
  Prev := '';
  for i := 0 to DirMap.Count - 1 do
  begin
    k := 0;
    while (k < Length(Prev)) and (k < Length(DirNames[i])) and (Prev[k + 1] = DirNames[i][k + 1]) do Inc(k);
    f.Uv(k);
    f.ZStr(Copy(DirNames[i], k + 1, MaxInt));
    Prev := DirNames[i];
  end;
  for i := 0 to n - 1 do f.ZStr(BaseOf(Entries[All[i].Entry].StoredName));
  k := 0;
  for i := 0 to n - 1 do
  begin
    f.Sv(DirIdx[i] - k);
    k := DirIdx[i];
  end;
  Section(SEC_NAMES, f);

  // 4. KINDS of the entries without data
  if Z > 0 then
  begin
    f.Clear;
    for i := 0 to Z - 1 do
      with Entries[All[i].Entry].Meta do
      begin
        if IsLink then
        begin
          if LinkToDir then Kind := KIND_LINK_DIR else Kind := KIND_LINK;
        end
        else if IsDir then Kind := KIND_DIR
        else Kind := KIND_FILE;
        f.U8(Kind);
      end;
    Section(SEC_KINDS, f);
  end;

  // 5. SIZES (fixed width, big-endian) and 6. CRCS (non-empty files) of the files in blocks
  if n > Z then
  begin
    MaxSize := 0;
    for i := Z to n - 1 do
      if All[i].Size > MaxSize then MaxSize := All[i].Size;
    Wd := UBEWidth(QWord(MaxSize));
    f.Clear;
    f.U8(Wd);
    for i := Z to n - 1 do f.UBE(QWord(All[i].Size), Wd);
    Section(SEC_SIZES, f);
    f.Clear;
    for i := Z to n - 1 do
      if All[i].Size > 0 then f.U32(All[i].Crc);
    Section(SEC_CRCS, f);
  end;

  // 7. MTIME: seconds from the smallest one (fixed width, big-endian), then the sub-second part
  // in units of 10^k ns (fixed width, 0..4 bytes)
  SetLength(Secs, n);
  SetLength(Subs, n);
  MinSec := High(Int64);
  for i := 0 to n - 1 do
  begin
    SplitNs(Entries[All[i].Entry].Meta.MTimeNs, Secs[i], Subs[i]);
    if Secs[i] < MinSec then MinSec := Secs[i];
  end;
  MaxRel := 0;
  Unit10 := 9;
  MaxSub := 0;
  for i := 0 to n - 1 do
  begin
    if Secs[i] - MinSec > MaxRel then MaxRel := Secs[i] - MinSec;
    if Subs[i] <> 0 then
    begin
      while (Unit10 > 0) and (Subs[i] mod POW10[Unit10] <> 0) do Dec(Unit10);
      if Subs[i] > MaxSub then MaxSub := Subs[i];
    end;
  end;
  if MaxSub = 0 then Unit10 := 0;
  Ws := UBEWidth(MaxSub div POW10[Unit10]);
  Wd := UBEWidth(QWord(MaxRel));
  f.Clear;
  f.Sv(MinSec);
  f.U8(Wd);
  for i := 0 to n - 1 do f.UBE(QWord(Secs[i] - MinSec), Wd);
  f.U8(Unit10);
  f.U8(Ws);
  for i := 0 to n - 1 do f.UBE(Subs[i] div POW10[Unit10], Ws);
  Section(SEC_MTIME, f);

  // 8/9. Attributes, when every entry has them
  AllWin := True;
  AllUnix := True;
  for i := 0 to n - 1 do
  begin
    AllWin := AllWin and Entries[All[i].Entry].Meta.HasWinAttr;
    AllUnix := AllUnix and Entries[All[i].Entry].Meta.HasUnixMode;
  end;
  if AllUnix then
  begin
    f.Clear;
    for i := 0 to n - 1 do f.Uv(Entries[All[i].Entry].Meta.UnixMode);
    Section(SEC_UNIXMODE, f);
  end;
  if AllWin then
  begin
    f.Clear;
    for i := 0 to n - 1 do f.Uv(Entries[All[i].Entry].Meta.WinAttr);
    Section(SEC_WINATTR, f);
  end;

  // 10. LINKS: the target of each link, in order
  f.Clear;
  for i := 0 to Z - 1 do
    with Entries[All[i].Entry].Meta do
      if IsLink then f.Str(LinkTarget);
  if f.Len > 0 then Section(SEC_LINKS, f);

  // Optional: comment and the -rr spec (kept when the archive is updated)
  if Opt.Comment <> '' then
  begin
    f.Clear;
    f.Raw(PChar(Opt.Comment), Length(Opt.Comment));
    Section(SEC_COMMENT, f);
  end;
  if Opt.Recovery <> '' then
  begin
    f.Clear;
    f.Raw(PChar(Opt.Recovery), Length(Opt.Recovery));
    Section(SEC_RECOVERY, f);
  end;
  w.U8(SEC_END);
  Result := w.Bytes;
end;

{ Writes the index (header and payload) at the current position of S, which is IndexPos from
  the archive start. The payload is compressed with DirMethod (stored if that does not make it
  smaller and it is not encrypted); with -hp, encrypted with the header key. }
procedure WriteIndex(S: TStream; IndexPos: Int64; const Payload: TBytes; const Opt: TWriteOptions);
var
  Method: string;
  Comp: TBytes;
  w: TByteWriter;
begin
  Method := Opt.DirMethod;
  if Opt.HeadersPassword <> '' then
    Method := Method + '+' + MakeCipherStage(Opt.Encryption, Opt.HeadersPassword, True);
  Comp := CompressMem(Method, PByte(Payload), Length(Payload));
  if (Opt.HeadersPassword = '') and (Length(Comp) >= Length(Payload)) then
  begin
    Method := 'storing';
    Comp := Payload;
  end;
  w.Clear;
  w.U32(INDEX_MAGIC);
  w.Uv(QWord(IndexPos));
  w.Uv(Length(Comp));
  w.Uv(Length(Payload));
  w.Str(Method);
  w.U32(CalcCRC(PByte(Comp), Length(Comp)));
  w.U32(CalcCRC(PByte(Payload), Length(Payload)));
  w.U32(CalcCRC(PByte(w.Data), w.Len));
  S.WriteBuffer(w.Data[0], w.Len);
  if Length(Comp) > 0 then S.WriteBuffer(Comp[0], Length(Comp));
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
  EncMethod: string;
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
  // Un bloque viejo que se reempaqueta trae su etapa de cifrado: se saca, y si hay -p se
  // vuelve a cifrar con un nonce de bloque nuevo
  Result.Method := LimitMethodToSize(WithoutCipher(G.Method), Size);
  EncMethod := Result.Method;
  // -p: cifrado al final de la cadena. La etapa no lleva la clave (está en el caché de
  // parc_crypt), así que la cadena del codificador es la misma que queda en el archivo.
  // Un bloque que ya estaba cifrado se vuelve a cifrar aunque no se haya dado -p (con la
  // contraseña con que se leyó): borrar un archivo no tiene que dejar el resto en claro
  Pwd := Opt.DataPassword;
  if (Pwd = '') and not Opt.ChangePassword then
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
    EncMethod := Result.Method + '+' + MakeCipherStage(Opt.Encryption, Pwd, False);
    Result.Method := EncMethod;
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
    // lo que usa de verdad su cadena de codificadores (antes: 8 veces lo del decodificador)
    Est[n] := EncodeMemEstimate(LimitMethodToSize(WithoutCipher(AllGroups[i].Method), Size), Size);
    Inc(n);
  end;
  SetLength(Est, n);
  Result := BudgetThreads;
  if Result > n then Result := n;
  // los que corren a la vez tienen que entrar juntos en el límite de compresión (-lc o el
  // automático); sin límite, en la mitad de la RAM y del espacio de direcciones
  Result := ThreadsForMemory(Est, Result, EffectiveCompressLimit);
  if Result < 1 then Result := 1;
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

{ Antes de escribir: con -p, si el archivo que se actualiza ya tiene bloques de datos cifrados,
  la contraseña tiene que ser la de ellos (los datos de un archivo no mezclan contraseñas: se
  rechaza como contraseña incorrecta). Y las claves se derivan acá, una vez y en este hilo,
  antes de repartir los bloques entre hilos; si es la del archivo, con su misma sal. }
procedure PrepareEncryption(const Entries: TWriteEntryArray; const Groups: array of TSolidGroup;
  const Opt: TWriteOptions);
var
  i: Integer;
  Found: string;

  procedure Look(const Method: string);
  begin
    if (Found = '') and (WithoutCipher(Method) <> Method) then Found := Method;
  end;

begin
  if Opt.DataPassword <> '' then
  begin
    Found := '';
    for i := 0 to High(Groups) do
      if Groups[i].CopyFrom <> nil then Look(Groups[i].CopyFrom.DataBlocks[Groups[i].CopyBlock].Method);
    for i := 0 to High(Entries) do
      with Entries[i] do
        if (SrcArc <> nil) and not Meta.IsDir and not Meta.IsLink then
          Look(SrcArc.DataBlocks[SrcArc.Files[SrcIndex].DataBlock].Method);
    if (Found <> '') and not Opt.ChangePassword and not CryptMethodPasswordOk(Found, Opt.DataPassword) then
      raise EBadPassword.Create('wrong password (the archive data is encrypted with another password)');
    MakeCipherStage(Opt.Encryption, Opt.DataPassword, False);   // (deriva la clave y la deja en el caché)
  end;
  if Opt.HeadersPassword <> '' then MakeCipherStage(Opt.Encryption, Opt.HeadersPassword, True);
end;

function WriteArchive(const FileName: string; const Entries: TWriteEntryArray;
  const Groups: array of TSolidGroup; const Opt: TWriteOptions; Log: TLogProc): TWriteStats;
var
  Tmp: string;
  S: TStream;
  Small: array[0..63] of Byte;
  IndexPos: Int64;
  Blocks: array of TDataBlock;
  DirGroup: TSolidGroup;
  AllGroups: TSolidGroupArray;
  Jobs: array of TWriteBlockJob;
  Pool: TJobPool;
  i, n, k: Integer;
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
  PrepareEncryption(Entries, Groups, Opt);

  // Total para el progreso: bytes a comprimir, más los comprimidos de los bloques que se copian
  Total := 0;
  for i := 0 to High(Groups) do
    if Groups[i].CopyFrom <> nil then
      Inc(Total, Groups[i].CopyFrom.DataBlocks[Groups[i].CopyBlock].CompSize)
    else
      for n := 0 to High(Groups[i].Files) do
        if not Entries[Groups[i].Files[n]].Meta.IsDir then Inc(Total, Entries[Groups[i].Files[n]].Meta.Size);

  Tmp := TempArchiveName(FileName);
  Ok := False;
  ProgressBegin('Compressing', Total);
  if Opt.VolumeSize > 0 then S := TVolumeStream.CreateWrite(Tmp, Opt.VolumeSize)
  else S := TFileStream.Create(FsPath(Tmp), fmCreate);
  try
    try
      // Head: magic, container version, CRC
      EncodeHead(@Small[0]);
      S.WriteBuffer(Small[0], HEAD_SIZE);

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
      // (con -p también: las claves ya están derivadas y cada bloque solo saca su nonce)
      UseParallel := Opt.Parallel and (Length(AllGroups) > 1) and (BudgetThreads >= 2);
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
        // Cada bloque planea sus pools internos (4x4, bwt, OREP) con su parte del presupuesto;
        // si después sobran fichas (los últimos bloques), 4x4/bwt crecen solos
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
            Jobs[i].Output := TBlockOut.Create(Tmp + '.blk' + IntToStr(i));
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

      // Index, end locator and, with -rr, the recovery record (it protects everything before it)
      IndexPos := S.Position;
      WriteIndex(S, IndexPos, BuildIndex(Entries, Blocks, Length(DirGroup.Files) > 0, HEAD_SIZE, Opt), Opt);
      EncodeLocator(@Small[0], IndexPos, S.Position + LOC_SIZE);
      S.WriteBuffer(Small[0], LOC_SIZE);
      if Opt.Recovery <> '' then WriteRecoveryRecord(S, S.Position, Opt.Recovery);
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

function TempArchiveName(const FileName: string): string;
begin
  if WorkDir = '' then Result := FileName + '.tmp'
  else Result := IncludeTrailingPathDelimiter(WorkDir) + ExtractFileName(FileName) + Format('.%d.tmp', [GetProcessID]);
end;

function MoveFileAcross(const Src, Dst: string): Boolean;
var
  I, O: TFileStream;
begin
  if RenameFile(FsPath(Src), FsPath(Dst)) then Exit(True);
  Result := False;
  if not FileExists(FsPath(Src)) or FileExists(FsPath(Dst)) then Exit;
  try
    I := TFileStream.Create(FsPath(Src), fmOpenRead or fmShareDenyWrite);
    try
      O := TFileStream.Create(FsPath(Dst), fmCreate);
      try
        O.CopyFrom(I, 0);
      finally
        O.Free;
      end;
    finally
      I.Free;
    end;
  except
    DeleteFile(FsPath(Dst));
    Exit(False);
  end;
  DeleteFile(FsPath(Src));
  Result := True;
end;

procedure FinishArchive(const FileName: string; VolumeSize: Int64);
var
  Tmp, Near: string;
  i: Integer;
begin
  Tmp := TempArchiveName(FileName);
  if WorkDir <> '' then
  begin
    // -w: primero al lado del destino (copia si es otro disco), y desde ahí el reemplazo de
    // siempre: si la copia falla, el archivo viejo sigue intacto
    Near := FileName + '.tmp';
    if VolumeSize > 0 then
    begin
      DeleteVolumesFrom(Near, 1);
      i := 1;
      while FileExists(FsPath(VolumeName(Tmp, i))) do
      begin
        if not MoveFileAcross(VolumeName(Tmp, i), VolumeName(Near, i)) then
          raise EFCreateError.CreateFmt('could not move %s to %s', [VolumeName(Tmp, i), VolumeName(Near, i)]);
        Inc(i);
      end;
    end
    else
    begin
      DeleteFile(FsPath(Near));
      if not MoveFileAcross(Tmp, Near) then
        raise EFCreateError.CreateFmt('could not move %s to %s', [Tmp, Near]);
    end;
    Tmp := Near;
  end;
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
