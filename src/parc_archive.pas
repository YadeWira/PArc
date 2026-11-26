{ Reader of PArc's container (docs/formato/FORMATO-PARC.md §1-§4): head, data blocks, index
  (the directory, with its header) and end locator, optionally followed by the recovery record
  (parc_recovery). The layout is PArc's own (format 2, 2026-11).

  How the index is found: the last bytes of the file are the end locator, or the descriptor of
  the recovery record whose record is preceded by the locator. If neither is intact, the file is
  scanned backwards for an index header whose header and payload checksums match: a damaged
  tail does not prevent listing (or repairing) the archive. }
unit parc_archive;

{$mode objfpc}{$H+}

interface

uses
  Classes, SysUtils, parc_os, parc_bytes, parc_stream, parc_volume;

const
  PARC_FORMAT_VERSION = 2;     // container version this reader understands (head field)

  HEAD_SIZE = 16;              // magic (8) · U16 version · U16 flags · U32 CRC-32 of bytes 0..11
  HEAD_MAGIC: array[0..7] of Byte = ($50, $41, $72, $63, $0D, $0A, $1A, $0A);   // "PArc\r\n\x1a\n"
  INDEX_MAGIC = $78694150;     // "PAix" (U32 LE) at the start of the index header
  LOC_SIZE = 24;               // U64 index pos · U64 archive length · U32 CRC · "PAel"
  LOC_MAGIC = $6C654150;       // "PAel"
  REC_DESC_SIZE = 48;          // recovery descriptor (parc_recovery), at both ends of the record
  REC_MAGIC = $72724150;       // "PArr"
  REC_VERSION = 1;

  { Index sections (FORMATO-PARC.md §3). An id with bit 7 set may be skipped by a reader that
    does not know it; any other unknown id makes the archive unreadable. }
  SEC_END      = 0;
  SEC_ARCHIVE  = 1;
  SEC_BLOCKS   = 2;
  SEC_NAMES    = 3;
  SEC_KINDS    = 4;
  SEC_SIZES    = 5;
  SEC_CRCS     = 6;
  SEC_MTIME    = 7;
  SEC_UNIXMODE = 8;
  SEC_WINATTR  = 9;
  SEC_LINKS    = 10;
  SEC_COMMENT  = $81;
  SEC_RECOVERY = $82;

  ARC_FLAG_LOCKED = 1;
  SIZES_LEB = $FF;             // SIZES: LEB128 column instead of a fixed width

  KIND_FILE = 0;
  KIND_DIR = 1;
  KIND_LINK = 2;
  KIND_LINK_DIR = 3;

  // Block types, for listings (lb)
  BLK_HEAD     = 1;
  BLK_DATA     = 2;
  BLK_INDEX    = 3;
  BLK_LOCATOR  = 4;
  BLK_RECOVERY = 5;
  DATA_BLOCK = BLK_DATA;

type
  TArcBlock = record
    BlockType: Integer;
    Method: string;
    Pos: Int64;         // absolute position in the file (the SFX stub included)
    OrigSize: Int64;    // data block: sum of the sizes of its files
    CompSize: Int64;
    Crc: LongWord;      // index: CRC-32 of the decoded payload; data block: 0
    FirstFile: Integer; // data block: index of its first file in TArchive.Files
    FileCount: Integer; // data block: number of files
  end;

  TArcFileEntry = record
    Name: string;       // path inside the archive, '/' separators, UTF-8
    Size: Int64;
    Time: Int64;        // Unix seconds (floor of MTimeNs)
    IsDir: Boolean;
    Crc: LongWord;
    DataBlock: Integer; // index in TArchive.DataBlocks
    Offset: Int64;      // offset inside the decompressed solid block
    HasMTimeNs, HasWinAttr, HasUnixMode: Boolean;
    MTimeNs: Int64;     // nanoseconds since 1970 UTC
    WinAttr, UnixMode: LongWord;
    IsLink, LinkToDir: Boolean;   // symbolic link (no data: size 0)
    LinkTarget: string;           //   target, UTF-8 with '/'
  end;

  { The recovery record's descriptor (FORMATO-PARC.md §5). }
  TRecDesc = record
    ProtLen: Int64;       // protected bytes: from the archive start to the record
    RecLen: Int64;        // the whole record, both descriptors included
    Stripes: Int64;       // S
    SectorSize: Integer;
    Parity: Integer;      // m: parity sectors per stripe (0 = checks only)
    CheckWidth: Integer;  // bytes per sector check (2 or 4)
  end;

  TArchive = class
  private
    FStream: TStream;           // one file, or the volumes x.001, x.002... (parc_volume)
    FFileName: string;
    FBase: Int64;               // where the archive starts (after an SFX stub)
    procedure ReadAt(Pos: Int64; var Buf; Count: SizeInt);
    function TryLocator(EndPos: Int64; out IndexPos, ArcLen: Int64): Boolean;
    function TryIndexHeader(Pos: Int64; out Blk: TArcBlock; out SelfPos: Int64; out HdrLen: Integer): Boolean;
    function ScanForIndex(EndPos: Int64; out Blk: TArcBlock): Boolean;
    procedure CheckOldFormat;
    procedure CheckHead;
    procedure ParseIndex(const Payload: TBytes);
  public
    ArcSize: Int64;
    IndexBlk: TArcBlock;
    ControlBlocks: array of TArcBlock;   // head, index, locator and recovery, in file order
    DataBlocks: array of TArcBlock;
    Files: array of TArcFileEntry;
    Locked: Boolean;
    Recovery: string;                    // -rr spec kept for updates
    Comment: RawByteString;
    SFXSize: Int64;
    HasRecovery: Boolean;
    HasNoDataBlock: Boolean;             // DataBlocks[0] is the pseudo-block of the entries without data
    Rec: TRecDesc;
    RecPos: Int64;                       // absolute position of the recovery record
    Notice: string;                      // '' or a warning (damaged tail, index found by scanning)
    constructor Open(const AFileName: string);
    { The compressed bytes of a block, as an input stage (does not own the stream). }
    function OpenBlockData(const Block: TArcBlock): TInStage;
    { Closes the archive file (the parsed index stays); OpenBlockData fails afterwards. }
    procedure CloseStream;
    destructor Destroy; override;
    property FileName: string read FFileName;
  end;

function BlockTypeName(t: Integer): string;
function SanitizePath(const P: string): string;
{ Decodes a recovery descriptor (REC_DESC_SIZE bytes). False if it is not one. }
function DecodeRecDesc(P: PByte; out D: TRecDesc): Boolean;
procedure EncodeRecDesc(P: PByte; const D: TRecDesc);
{ Builds the head / end locator. }
procedure EncodeHead(P: PByte);
procedure EncodeLocator(P: PByte; IndexPos, ArcLen: Int64);

implementation

uses
  parc_crc, parc_methods, parc_progress;

const
  SCAN_CHUNK = 1 shl 20;
  POW10: array[0..9] of Int64 = (1, 10, 100, 1000, 10000, 100000, 1000000, 10000000,
    100000000, 1000000000);

function BlockTypeName(t: Integer): string;
begin
  case t of
    BLK_HEAD:     Result := 'head';
    BLK_DATA:     Result := 'data';
    BLK_INDEX:    Result := 'index';
    BLK_LOCATOR:  Result := 'locator';
    BLK_RECOVERY: Result := 'recovery';
  else
    Result := 'unknown(' + IntToStr(t) + ')';
  end;
end;

{ Normalizes separators to '/', drops absolute roots ("/", "C:") and "." / ".." components, so
  that extraction never writes outside the destination. }
function SanitizePath(const P: string): string;
var
  Parts: TStringArray;
  s, Part: string;
begin
  s := StringReplace(P, '\', '/', [rfReplaceAll]);
  if (Length(s) >= 2) and (s[2] = ':') then Delete(s, 1, 2);
  Result := '';
  Parts := s.Split(['/']);
  for Part in Parts do
  begin
    if (Part = '') or (Part = '.') or (Part = '..') then Continue;
    if Result <> '' then Result := Result + '/';
    Result := Result + Part;
  end;
end;

procedure EncodeHead(P: PByte);
begin
  Move(HEAD_MAGIC[0], P^, 8);
  P[8] := PARC_FORMAT_VERSION and $FF; P[9] := PARC_FORMAT_VERSION shr 8;
  P[10] := 0; P[11] := 0;
  PutU32(P + 12, CalcCRC(P, 12));
end;

{ CRC of the locator: its 16 bytes of fields and its magic. }
function LocatorCrc(P: PByte): LongWord;
begin
  Result := UpdateCRC(UpdateCRC(CRC_INIT, P, 16), P + 20, 4) xor CRC_INIT;
end;

procedure EncodeLocator(P: PByte; IndexPos, ArcLen: Int64);
begin
  PutU64(P, QWord(IndexPos));
  PutU64(P + 8, QWord(ArcLen));
  PutU32(P + 20, LOC_MAGIC);
  PutU32(P + 16, LocatorCrc(P));
end;

{ Descriptor: 0 U64 protected length · 8 U64 record length · 16 U64 stripes · 24 U32 sector
  size · 28 U16 m · 30 U8 check width · 31 U8 version · 32..39 zero · 40 U32 CRC-32 of bytes
  0..39 and 44..47 · 44 "PArr". }
function RecDescCrc(P: PByte): LongWord;
begin
  Result := UpdateCRC(UpdateCRC(CRC_INIT, P, 40), P + 44, 4) xor CRC_INIT;
end;

procedure EncodeRecDesc(P: PByte; const D: TRecDesc);
begin
  FillChar(P^, REC_DESC_SIZE, 0);
  PutU64(P, QWord(D.ProtLen));
  PutU64(P + 8, QWord(D.RecLen));
  PutU64(P + 16, QWord(D.Stripes));
  PutU32(P + 24, LongWord(D.SectorSize));
  P[28] := Byte(D.Parity); P[29] := Byte(D.Parity shr 8);
  P[30] := Byte(D.CheckWidth);
  P[31] := REC_VERSION;
  PutU32(P + 44, REC_MAGIC);
  PutU32(P + 40, RecDescCrc(P));
end;

function DecodeRecDesc(P: PByte; out D: TRecDesc): Boolean;
var
  i: Integer;
begin
  Result := False;
  D := Default(TRecDesc);
  if GetU32(P + 44) <> REC_MAGIC then Exit;
  if GetU32(P + 40) <> RecDescCrc(P) then Exit;
  if P[31] <> REC_VERSION then Exit;
  for i := 32 to 39 do if P[i] <> 0 then Exit;
  D.ProtLen := Int64(GetU64(P));
  D.RecLen := Int64(GetU64(P + 8));
  D.Stripes := Int64(GetU64(P + 16));
  D.SectorSize := Integer(GetU32(P + 24) and $7FFFFFFF);
  D.Parity := Integer(P[28]) or (Integer(P[29]) shl 8);
  D.CheckWidth := P[30];
  Result := (D.ProtLen > 0) and (D.RecLen >= 2 * REC_DESC_SIZE) and (D.SectorSize >= 512) and
            (D.Stripes >= 0) and (D.Parity <= 254) and ((D.CheckWidth = 2) or (D.CheckWidth = 4));
end;

{ A base name that SanitizePath would leave as it is (the usual case: no separators, not "."
  or "..", no drive). }
function PlainName(const S: string): Boolean;
var
  i: Integer;
begin
  Result := (S <> '') and (S <> '.') and (S <> '..') and not ((Length(S) >= 2) and (S[2] = ':'));
  if Result then
    for i := 1 to Length(S) do
      if (S[i] = '/') or (S[i] = '\') then Exit(False);
end;

constructor TArchive.Open(const AFileName: string);
var
  Tail: array[0..REC_DESC_SIZE - 1] of Byte;
  EndPos, IndexPos, ArcLen, SelfPos: Int64;
  HdrLen: Integer;
  Comp, Payload: TBytes;
  i: Integer;
  Found: Boolean;
  LocOk: Boolean;
begin
  inherited Create;
  FFileName := AFileName;
  FStream := OpenArchiveStream(AFileName);
  ArcSize := FStream.Size;
  EndPos := ArcSize;
  // 1. The recovery record, if the file ends with its descriptor
  if ArcSize >= REC_DESC_SIZE then
  begin
    ReadAt(ArcSize - REC_DESC_SIZE, Tail[0], REC_DESC_SIZE);
    if DecodeRecDesc(@Tail[0], Rec) and (Rec.RecLen <= ArcSize) then
    begin
      HasRecovery := True;
      RecPos := ArcSize - Rec.RecLen;
      EndPos := RecPos;
    end;
  end;
  // 2. The end locator, right before it (or at the end)
  LocOk := TryLocator(EndPos, IndexPos, ArcLen);
  Found := False;
  if LocOk then
  begin
    FBase := EndPos - ArcLen;
    Found := TryIndexHeader(FBase + IndexPos, IndexBlk, SelfPos, HdrLen) and (SelfPos = IndexPos) and
             (IndexBlk.Pos + IndexBlk.CompSize <= EndPos - LOC_SIZE);
    if not Found then Notice := 'the index header is damaged';
  end;
  // 3. Without it: look for the index by its header (a damaged or cut tail)
  if not Found then
  begin
    if not LocOk then CheckOldFormat;
    if not ScanForIndex(EndPos, IndexBlk) then
    begin
      if FStream is TVolumeStream then
        Corrupt(Format('index not found; %d volume(s) read, up to %s: is the next one missing?',
          [TVolumeStream(FStream).Names.Count, TVolumeStream(FStream).Names[TVolumeStream(FStream).Names.Count - 1]]));
      if not LocOk then
        raise EArcCorrupt.Create('not a .parc archive, or its end is damaged (no end locator, no index found)');
      Corrupt('the index is damaged' + BoolToStr(HasRecovery, ' (try "parc r")', ''));
    end;
    if Notice = '' then Notice := 'the end of the archive is damaged (index found by scanning)';
    if HasRecovery then Notice := Notice + '; repair it with "parc r"';
  end;
  SFXSize := FBase;
  CheckHead;

  // The index payload
  SetLength(Comp, IndexBlk.CompSize);
  if IndexBlk.CompSize > 0 then ReadAt(IndexBlk.Pos, Comp[0], IndexBlk.CompSize);
  if CalcCRC(PByte(Comp), Length(Comp)) <> LongWord(IndexBlk.FirstFile) then
    Corrupt('wrong checksum in the index' + BoolToStr(HasRecovery, ' (try "parc r")', ''));
  Payload := DecompressMem(IndexBlk.Method, PByte(Comp), Length(Comp), IndexBlk.OrigSize);
  Comp := nil;
  if (Length(Payload) <> IndexBlk.OrigSize) or (CalcCRC(PByte(Payload), Length(Payload)) <> IndexBlk.Crc) then
    Corrupt('wrong checksum in the decoded index');
  IndexBlk.FirstFile := 0;
  ParseIndex(Payload);

  // Control structures, for lb
  SetLength(ControlBlocks, 3 + Ord(HasRecovery));
  for i := 0 to High(ControlBlocks) do ControlBlocks[i] := Default(TArcBlock);
  ControlBlocks[0].BlockType := BLK_HEAD;
  ControlBlocks[0].Pos := FBase;
  ControlBlocks[0].OrigSize := HEAD_SIZE;
  ControlBlocks[0].CompSize := HEAD_SIZE;
  ControlBlocks[1] := IndexBlk;
  ControlBlocks[2].BlockType := BLK_LOCATOR;
  ControlBlocks[2].Pos := EndPos - LOC_SIZE;
  ControlBlocks[2].OrigSize := LOC_SIZE;
  ControlBlocks[2].CompSize := LOC_SIZE;
  if HasRecovery then
  begin
    ControlBlocks[3].BlockType := BLK_RECOVERY;
    ControlBlocks[3].Pos := RecPos;
    ControlBlocks[3].OrigSize := Rec.RecLen;
    ControlBlocks[3].CompSize := Rec.RecLen;
    ControlBlocks[3].Method := Format('rs:%d*%d:m%d', [Rec.Parity * Rec.Stripes, Rec.SectorSize, Rec.Parity]);
  end;
end;

destructor TArchive.Destroy;
begin
  FStream.Free;
  inherited Destroy;
end;

procedure TArchive.CloseStream;
begin
  FreeAndNil(FStream);
end;

function TArchive.OpenBlockData(const Block: TArcBlock): TInStage;
begin
  if FStream = nil then Corrupt('archive already closed');
  if (Block.Pos < 0) or (Block.CompSize < 0) or (Block.Pos + Block.CompSize > ArcSize) then
    Corrupt('data block outside the archive');
  Result := TFileSliceStage.Create(FStream, Block.Pos, Block.CompSize);
end;

procedure TArchive.ReadAt(Pos: Int64; var Buf; Count: SizeInt);
begin
  if (Pos < 0) or (Count < 0) or (Pos + Count > ArcSize) then Corrupt('structure outside the archive');
  FStream.Position := Pos;
  FStream.ReadBuffer(Buf, Count);
end;

function TArchive.TryLocator(EndPos: Int64; out IndexPos, ArcLen: Int64): Boolean;
var
  L: array[0..LOC_SIZE - 1] of Byte;
begin
  Result := False;
  IndexPos := 0;
  ArcLen := 0;
  if EndPos < HEAD_SIZE + LOC_SIZE then Exit;
  ReadAt(EndPos - LOC_SIZE, L[0], LOC_SIZE);
  if (GetU32(@L[20]) <> LOC_MAGIC) or (GetU32(@L[16]) <> LocatorCrc(@L[0])) then Exit;
  IndexPos := Int64(GetU64(@L[0]));
  ArcLen := Int64(GetU64(@L[8]));
  Result := (ArcLen >= HEAD_SIZE + LOC_SIZE) and (ArcLen <= EndPos) and
            (IndexPos >= HEAD_SIZE) and (IndexPos < ArcLen - LOC_SIZE);
end;

{ Index header: "PAix" · Uv own position (from the archive start) · Uv stored length · Uv
  decoded length · Str method · U32 CRC-32 of the stored payload · U32 CRC-32 of the decoded
  payload · U32 CRC-32 of the header up to here. The payload follows. Blk.FirstFile carries the
  stored CRC until it is checked. }
function TArchive.TryIndexHeader(Pos: Int64; out Blk: TArcBlock; out SelfPos: Int64; out HdrLen: Integer): Boolean;
var
  Buf: array of Byte;
  n: SizeInt;
  r: TByteReader;
  StoredCrc: LongWord;
begin
  Result := False;
  Blk := Default(TArcBlock);
  SelfPos := 0;
  HdrLen := 0;
  if (Pos < 0) or (Pos >= ArcSize) then Exit;
  n := 4096 + 64;
  if Pos + n > ArcSize then n := ArcSize - Pos;
  if n < 4 + 3 + 1 + 12 then Exit;
  SetLength(Buf, n);
  ReadAt(Pos, Buf[0], n);
  if GetU32(@Buf[0]) <> INDEX_MAGIC then Exit;
  r.Init(@Buf[0], n);
  try
    r.Skip(4);
    SelfPos := Int64(r.Uv);
    Blk.CompSize := Int64(r.Uv);
    Blk.OrigSize := Int64(r.Uv);
    Blk.Method := r.Str;
    StoredCrc := r.U32;
    Blk.Crc := r.U32;
    HdrLen := r.Pos;
    if r.U32 <> CalcCRC(@Buf[0], HdrLen) then Exit;
    Inc(HdrLen, 4);
  except
    on EArcCorrupt do Exit;
  end;
  if (SelfPos < 0) or (Blk.CompSize < 0) or (Blk.OrigSize < 0) or (Blk.OrigSize > High(SizeInt) div 2) or
     (Blk.CompSize > ArcSize) or (Pos + HdrLen + Blk.CompSize > ArcSize) or (SelfPos > Pos) then Exit;
  Blk.BlockType := BLK_INDEX;
  Blk.Pos := Pos + HdrLen;
  Blk.FirstFile := Integer(StoredCrc);
  Result := True;
end;

{ Backwards from EndPos: the last index header whose header and payload checksums match. }
function TArchive.ScanForIndex(EndPos: Int64; out Blk: TArcBlock): Boolean;
var
  Buf, Pay: TBytes;
  Lo, Hi, P: Int64;
  n, i: SizeInt;
  SelfPos: Int64;
  HdrLen: Integer;
begin
  Result := False;
  SetLength(Buf, SCAN_CHUNK + 4);
  Hi := EndPos;
  while Hi > 0 do
  begin
    Lo := Hi - SCAN_CHUNK;
    if Lo < 0 then Lo := 0;
    n := Hi - Lo;
    if Hi + 3 <= ArcSize then Inc(n, 3) else n := ArcSize - Lo;
    ReadAt(Lo, Buf[0], n);
    for i := n - 4 downto 0 do
      if (Buf[i] = $50) and (Buf[i + 1] = $41) and (Buf[i + 2] = $69) and (Buf[i + 3] = $78) then
      begin
        P := Lo + i;
        if not TryIndexHeader(P, Blk, SelfPos, HdrLen) then Continue;
        if Blk.CompSize > High(SizeInt) div 2 then Continue;
        SetLength(Pay, Blk.CompSize);
        if Blk.CompSize > 0 then ReadAt(Blk.Pos, Pay[0], Blk.CompSize);
        if CalcCRC(PByte(Pay), Length(Pay)) <> LongWord(Blk.FirstFile) then Continue;
        FBase := P - SelfPos;
        Exit(True);
      end;
    CheckCancel;
    Hi := Lo;
  end;
end;

{ An archive of PArc 0.0.5 or earlier (FreeArc-style container): it starts with "PAr\x01", or
  its footer descriptor ("PAr\x01" + type 4) is in its last 4096 bytes. }
procedure TArchive.CheckOldFormat;
var
  Buf: TBytes;
  n, i: SizeInt;
  Old: Boolean;
begin
  if ArcSize < 4 then Exit;
  SetLength(Buf, 4);
  ReadAt(0, Buf[0], 4);
  Old := (Buf[0] = $50) and (Buf[1] = $41) and (Buf[2] = $72) and (Buf[3] = $01);
  if not Old then
  begin
    n := 4096;
    if n > ArcSize then n := ArcSize;
    SetLength(Buf, n);
    ReadAt(ArcSize - n, Buf[0], n);
    for i := 0 to n - 5 do
      if (Buf[i] = $50) and (Buf[i + 1] = $41) and (Buf[i + 2] = $72) and (Buf[i + 3] = $01) and (Buf[i + 4] = $08) then
      begin
        Old := True;
        Break;
      end;
  end;
  if Old then
    raise EArcCorrupt.Create('old PArc format (PArc 0.0.5 and earlier): this version does not read it; ' +
      'extract it with PArc 0.0.5 and archive the files again');
end;

procedure TArchive.CheckHead;
var
  H: array[0..HEAD_SIZE - 1] of Byte;
  Version: Integer;
begin
  if (FBase < 0) or (FBase + HEAD_SIZE > ArcSize) then Corrupt('archive start outside the file');
  ReadAt(FBase, H[0], HEAD_SIZE);
  if (CompareByte(H[0], HEAD_MAGIC[0], 8) <> 0) or (GetU32(@H[12]) <> CalcCRC(@H[0], 12)) then
  begin
    if Notice <> '' then Notice := Notice + '; ';
    Notice := Notice + 'the archive head is damaged';
    Exit;
  end;
  Version := H[8] or (H[9] shl 8);
  if Version > PARC_FORMAT_VERSION then
    raise EArcCorrupt.CreateFmt('.parc container version %d: this PArc version understands up to %d',
      [Version, PARC_FORMAT_VERSION]);
  if (Version < PARC_FORMAT_VERSION) or (H[10] <> 0) or (H[11] <> 0) then
    raise EArcCorrupt.CreateFmt('.parc container version %d with flags %d: not supported', [Version, H[10] or (H[11] shl 8)]);
end;

procedure TArchive.ParseIndex(const Payload: TBytes);
var
  r, s: TByteReader;
  Id: Byte;
  Len: SizeInt;
  N, Z, B, NRuns, M, D, i, j, k, Shared, Total: SizeInt;
  Flags: QWord;
  HaveArchive, HaveBlocks, HaveNames, HaveKinds, HaveSizes, HaveCrcs, HaveTimes: Boolean;
  Methods: array of string;
  Dirs: array of RawByteString;
  Prev, Suffix: RawByteString;
  DirIdx: Int64;
  IdxMode: Byte;
  Ns: Int64;
  W, Wk, Ws: Integer;
  BaseSec, Sec: Int64;
  Sub: QWord;
  RunPos, RunCount, Pos: Int64;
  Kinds: array of Byte;
  BlockOfs: Int64;
  Cnt: Int64;

  procedure NeedArchive;
  begin
    if not HaveArchive then Corrupt('index section before the archive section');
  end;

begin
  r.Init(PByte(Payload), Length(Payload));
  HaveArchive := False; HaveBlocks := False; HaveNames := False; HaveKinds := False;
  Kinds := nil;
  HaveSizes := False; HaveCrcs := False; HaveTimes := False;
  N := 0; Z := 0; B := 0;
  repeat
    Id := r.U8;
    if Id = SEC_END then Break;
    Len := r.UvSize;
    if Len > r.Remaining then Corrupt('truncated index section');
    s.Init(@r.Data[r.Pos], Len);
    r.Skip(Len);
    case Id of
      SEC_ARCHIVE:
        begin
          if HaveArchive then Corrupt('repeated index section');
          HaveArchive := True;
          Flags := s.Uv;
          if (Flags and not QWord(ARC_FLAG_LOCKED)) <> 0 then
            raise EArcCorrupt.CreateFmt('the archive uses unknown features (flags %x)', [Flags]);
          Locked := (Flags and ARC_FLAG_LOCKED) <> 0;
          N := s.UvSize;
          Z := s.UvSize;
          B := s.UvSize;
          if (N > Length(Payload)) or (Z > N) or (B > Length(Payload)) or ((B = 0) and (N > Z)) then
            Corrupt('invalid counts in the index');
          SetLength(Files, N);
          for i := 0 to N - 1 do
          begin
            Files[i] := Default(TArcFileEntry);
            Files[i].DataBlock := -1;
          end;
          // data blocks; the entries without data (directories, links) first, in a pseudo-block
          SetLength(DataBlocks, B + Ord(Z > 0));
          for i := 0 to High(DataBlocks) do
          begin
            DataBlocks[i] := Default(TArcBlock);
            DataBlocks[i].BlockType := BLK_DATA;
            DataBlocks[i].Method := 'storing';
            DataBlocks[i].Pos := FBase + HEAD_SIZE;
          end;
          HasNoDataBlock := Z > 0;
          if Z > 0 then
          begin
            DataBlocks[0].FileCount := Z;
            for i := 0 to Z - 1 do Files[i].DataBlock := 0;
          end;
        end;
      SEC_BLOCKS:
        begin
          NeedArchive;
          if HaveBlocks then Corrupt('repeated index section');
          HaveBlocks := True;
          k := Ord(Z > 0);
          // runs of consecutive blocks: (offset from the archive start, count)
          NRuns := s.UvSize;
          if NRuns > s.Remaining then Corrupt('invalid run count');
          j := 0;
          for i := 0 to NRuns - 1 do
          begin
            RunPos := Int64(s.Uv);
            RunCount := Int64(s.Uv);
            if (RunCount > B - j) or (RunPos < HEAD_SIZE) or (RunPos > IndexBlk.Pos - FBase) then
              Corrupt('invalid block run');
            if RunCount = 0 then Continue;
            // the first block of the run starts there; the others follow (positions from sizes)
            DataBlocks[k + j].Pos := FBase + RunPos;
            Inc(j);
            Dec(RunCount);
            while RunCount > 0 do
            begin
              DataBlocks[k + j].Pos := -1;
              Inc(j);
              Dec(RunCount);
            end;
          end;
          if j <> B then Corrupt('block runs do not cover every block');
          M := s.UvSize;
          if M > s.Remaining then Corrupt('invalid method count');
          SetLength(Methods, M);
          for i := 0 to M - 1 do Methods[i] := s.Str;
          for i := 0 to B - 1 do
          begin
            j := s.UvSize;
            if j >= M then Corrupt('invalid method index');
            DataBlocks[k + i].Method := Methods[j];
          end;
          Total := Z;
          for i := 0 to B - 1 do
          begin
            Cnt := s.UvSize;
            if Cnt > N - Total then Corrupt('invalid file count');
            DataBlocks[k + i].FirstFile := Total;
            DataBlocks[k + i].FileCount := Cnt;
            for j := Total to Total + Cnt - 1 do Files[j].DataBlock := k + i;
            Inc(Total, Cnt);
          end;
          if Total <> N then Corrupt('the blocks do not hold every file');
          Pos := 0;
          for i := 0 to B - 1 do
          begin
            DataBlocks[k + i].CompSize := Int64(s.Uv);
            if DataBlocks[k + i].Pos >= 0 then Pos := DataBlocks[k + i].Pos
            else DataBlocks[k + i].Pos := Pos;
            DataBlocks[k + i].Crc := 0;
            if (DataBlocks[k + i].CompSize < 0) or (DataBlocks[k + i].CompSize > IndexBlk.Pos) or
               (Pos + DataBlocks[k + i].CompSize > IndexBlk.Pos) then
              Corrupt('data block outside the archive');
            Inc(Pos, DataBlocks[k + i].CompSize);
          end;
        end;
      SEC_NAMES:
        begin
          NeedArchive;
          HaveNames := True;
          D := s.UvSize;
          if D > s.Remaining then Corrupt('invalid directory count');
          SetLength(Dirs, D);
          Prev := '';
          for i := 0 to D - 1 do
          begin
            Shared := s.UvSize;
            if Shared > Length(Prev) then Corrupt('invalid directory name');
            Suffix := s.ZStr;
            Dirs[i] := Copy(Prev, 1, Shared) + Suffix;
            Prev := Dirs[i];
          end;
          for i := 0 to D - 1 do Dirs[i] := SanitizePath(Dirs[i]);
          for i := 0 to N - 1 do Files[i].Name := s.ZStr;
          IdxMode := s.U8;
          if IdxMode > 1 then Corrupt('invalid directory index encoding');
          DirIdx := 0;
          for i := 0 to N - 1 do
          begin
            if IdxMode = 0 then DirIdx := Int64(s.Uv and $7FFFFFFFFFFFFFFF)
            else Inc(DirIdx, s.Sv);
            if (DirIdx < 0) or (DirIdx >= D) then Corrupt('invalid directory index');
            if not PlainName(Files[i].Name) then Files[i].Name := SanitizePath(Files[i].Name);
            if Dirs[DirIdx] <> '' then
            begin
              if Files[i].Name <> '' then Files[i].Name := Dirs[DirIdx] + '/' + Files[i].Name
              else Files[i].Name := Dirs[DirIdx];
            end;
          end;
        end;
      SEC_KINDS:
        begin
          NeedArchive;
          HaveKinds := True;
          SetLength(Kinds, Z);
          for i := 0 to Z - 1 do
          begin
            Kinds[i] := s.U8;
            if Kinds[i] > KIND_LINK_DIR then Corrupt('invalid entry kind');
            Files[i].IsDir := Kinds[i] = KIND_DIR;
          end;
        end;
      SEC_SIZES:
        begin
          NeedArchive;
          HaveSizes := True;
          W := s.U8;
          if (W > 8) and (W <> SIZES_LEB) then Corrupt('invalid size width');
          for i := Z to N - 1 do
          begin
            if W = SIZES_LEB then Files[i].Size := Int64(s.Uv) else Files[i].Size := Int64(s.UBE(W));
            if Files[i].Size < 0 then Corrupt('invalid file size');
          end;
        end;
      SEC_CRCS:
        begin
          NeedArchive;
          if not HaveSizes then Corrupt('index CRCs before the sizes');
          HaveCrcs := True;
          for i := Z to N - 1 do
            if Files[i].Size > 0 then Files[i].Crc := s.U32;
        end;
      SEC_MTIME:
        begin
          NeedArchive;
          HaveTimes := True;
          IdxMode := s.U8;
          if IdxMode = 1 then
          begin
            // each time in ns as a delta from the previous one
            Ns := 0;
            for i := 0 to N - 1 do
            begin
              Ns := Int64(QWord(Ns) + QWord(s.Sv));
              Files[i].MTimeNs := Ns;
              Sec := Ns div 1000000000;
              if (Ns < 0) and (Ns mod 1000000000 <> 0) then Dec(Sec);
              Files[i].Time := Sec;
              Files[i].HasMTimeNs := True;
            end;
          end
          else if IdxMode <> 0 then Corrupt('invalid time encoding')
          else
          begin
          BaseSec := s.Sv;
          W := s.U8;
          if W > 8 then Corrupt('invalid time width');
          for i := 0 to N - 1 do
          begin
            Sec := BaseSec + Int64(s.UBE(W));
            if (Sec < -9223372035) or (Sec > 9223372035) then Corrupt('invalid time');
            Files[i].Time := Sec;
          end;
          Wk := s.U8;
          Ws := s.U8;
          if (Wk > 9) or (Ws > 4) then Corrupt('invalid sub-second time encoding');
          for i := 0 to N - 1 do
          begin
            Sub := s.UBE(Ws) * QWord(POW10[Wk]);
            if Sub >= 1000000000 then Corrupt('invalid sub-second time');
            Files[i].MTimeNs := Files[i].Time * 1000000000 + Int64(Sub);
            Files[i].HasMTimeNs := True;
          end;
          end;
        end;
      SEC_UNIXMODE, SEC_WINATTR:
        begin
          NeedArchive;
          for i := 0 to N - 1 do
          begin
            Flags := s.Uv;
            if Flags > $FFFFFFFF then Corrupt('invalid attributes');
            if Id = SEC_UNIXMODE then
            begin
              Files[i].UnixMode := LongWord(Flags);
              Files[i].HasUnixMode := True;
            end
            else
            begin
              Files[i].WinAttr := LongWord(Flags);
              Files[i].HasWinAttr := True;
            end;
          end;
        end;
      SEC_LINKS:
        begin
          NeedArchive;
          if not HaveKinds then Corrupt('index links before the kinds');
          for i := 0 to Z - 1 do
            if Kinds[i] >= KIND_LINK then
            begin
              Files[i].LinkTarget := s.Str;
              Files[i].LinkToDir := Kinds[i] = KIND_LINK_DIR;
              Files[i].IsLink := Files[i].LinkTarget <> '';
            end;
        end;
      SEC_COMMENT:
        begin
          Comment := s.Bytes(Len);
          SetCodePage(Comment, CP_UTF8, False);
        end;
      SEC_RECOVERY:
        Recovery := s.Bytes(Len);
    else
      if (Id and $80) = 0 then
        raise EArcCorrupt.CreateFmt('the index uses an unknown mandatory section (%d): written by a newer PArc?', [Id]);
      s.Pos := s.Size;
    end;
    if s.Pos <> s.Size then Corrupt(Format('index section %d has extra bytes', [Id]));
  until False;
  if not r.Eof then Corrupt('bytes after the end of the index');
  if not HaveArchive then Corrupt('index without its archive section');
  if (B > 0) and not HaveBlocks then Corrupt('index without its block table');
  if (N > 0) and not (HaveNames and HaveTimes) then Corrupt('index without names or dates');
  if (Z > 0) and not HaveKinds then Corrupt('index without entry kinds');
  if (N > Z) and not (HaveSizes and HaveCrcs) then Corrupt('index without sizes or CRCs');

  // Offsets inside each solid block and its decoded size
  for k := 0 to High(DataBlocks) do
  begin
    BlockOfs := 0;
    for i := DataBlocks[k].FirstFile to DataBlocks[k].FirstFile + DataBlocks[k].FileCount - 1 do
    begin
      Files[i].Offset := BlockOfs;
      Inc(BlockOfs, Files[i].Size);
    end;
    DataBlocks[k].OrigSize := BlockOfs;
  end;
end;

end.
