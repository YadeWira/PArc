{ 4x4: independent blocks compressed in parallel with an inner method (PArc's own code, MIT;
  nothing from FreeArc). The method keeps FreeArc's name `4x4` and its parameter syntax
  (`4x4[:b<mem>][:r<N>][:t<N>][:i<N>]:<inner method>`), but the stream, the encoder and the
  decoder are new (stream in docs/formato/FORMATO-PARC.md §6.11).

  Stream: "4X" + version byte 1, then records until an end record:
    0                          end of stream
    1  VInt RawLen  <RawLen bytes>               stored
    2  VInt RawLen  VInt PackLen  <PackLen>      packed with the inner method (PackLen < RawLen)
  Every record decodes on its own, so the decoder runs them in parallel and delivers them in
  order; a damaged packed record decodes to zeros with a warning and the rest continue.

  Encoder: the input is cut into blocks (b<mem>, default the inner method's window; see
  Parse4x4), each one a job on a pool of the thread budget. Inside a job the block is scanned
  in 64 KB cells for order-0 entropy: runs of at least 256 KB of cells at or above r% (default
  99) are "noise" and are stored without trying the inner method, unless a scan with
  content-defined anchors finds that at least 4 % of the run repeats inside the block (then the
  inner method can use it). The output depends only on the data, the parameters and the block
  size, never on how the jobs were scheduled. }
unit parc_4x4;

{$mode objfpc}{$H+}
{$R-}{$Q-}

interface

uses
  SysUtils, parc_outstream, parc_stream, parc_parallel;

const
  { Thread cap of a 4x4 stage (encoder and decoder): more only adds heap contention. }
  FX_MAXTHREADS = 16;

{ Inner method and block size of a `4x4:...` stage. The 4x4 parameters are the leading ones
  that start with a digit or whose second character is a digit (b7mb, r99, t4, i0); the rest
  is the inner method (plz:1:1mb when there is none). Block size: b<mem>, else the inner
  method's window (plz, lz4) or its first memory parameter, else 8 MB. }
procedure Parse4x4(const Stage: string; out Inner: string; out BlockSize: SizeInt);
{ r<N> of the stage as a fraction (0.99 if absent). }
function Noise4x4(const Stage: string): Double;

type
  T4x4EncStage = class(TOutStage)
  private
    FInner: string;
    FBlockSize, FTarget: SizeInt;
    FTail: SizeInt;           // block size once the tail of the expected input was reached
    FNoise: Double;
    FHint, FIn: Int64;
    FCur: TBytes;
    FLen: SizeInt;
    FPool: TJobPool;
    FQueue: TJobArray;
    FHead, FCount: Integer;
    FFree: array of TBytes;
    FNumFree: Integer;
    FPlzCache: TObject;
    FHeaderDone: Boolean;
    procedure NextTarget;
    procedure WriteHeader;
    procedure SubmitBlock;
    procedure WriteOldest;
  protected
    procedure DoWrite(Buf: PByte; Count: SizeInt); override;
    procedure DoFinish; override;
  public
    { AHint: input expected by the stage (0 = unknown); with it and 2+ threads the last
      blocks are made smaller so that every thread gets work. }
    constructor Create(ATarget: TOutStage; const AInner: string; ABlockSize: SizeInt;
      ANoise: Double; AHint: Int64);
    destructor Destroy; override;
  end;

  T4x4DecStage = class(TParallelBlockStage)
  private
    FInner: string;
    FKind: Integer;
    Flc, Flp, Fpb: Integer;
    FStarted, FEnded: Boolean;
    FFreeJobs: TJobArray;
    FNumFree: Integer;
    function RdVInt: QWord;
  protected
    function ReadJob: TParallelJob; override;
    procedure ReleaseJob(Job: TParallelJob); override;
  public
    constructor Create(ASource: TInStage; const AInner: string);
    destructor Destroy; override;
  end;

{ Inner method from the parameters of a 4x4 stage (Params[0] = '4x4'). }
function Inner4x4Method(const Params: TStringArray): string;

implementation

uses
  Math, parc_bytes, parc_os, parc_methods, parc_encoders, parc_lzma, parc_lzmaenc, parc_lz4,
  parc_lz4enc, parc_plz, parc_plzenc;

const
  FX_MAGIC0 = Ord('4');
  FX_MAGIC1 = Ord('X');
  FX_VERSION = 1;
  REC_END = 0;
  REC_STORED = 1;
  REC_PACKED = 2;
  REC_MIXED = 3;
  MAX_RAW = SizeInt($7FFFFFFF);

  CELL = 64 * 1024;             // entropy cell
  NOISE_RUN = 256 * 1024;       // shortest run of noise cells that is stored apart
  REPEAT_SHARE = 0.04;          // repeated share of a noise run from which it is packed
  NOISE_EST_RANDOM = 0.96;      // the same in a block that is near-random as a whole
  NOISE_MINE0_RANDOM = 0.98;    // and the order-0 entropy from which its cells are tried
  NOISE_EST = 0.998;             // LZ estimate (over the cell's size) from which a cell is noise
  EST_WINDOW = 1 shl 20;        // match distance of the estimate
  GEAR_SHIFT = 55;              // anchors: about one every 2^(64-GEAR_SHIFT) bytes
  MB = 1 shl 20;

  IK_OTHER = 0;
  IK_LZMA = 1;
  IK_PLZ = 2;
  IK_LZ4 = 3;

function StageNameOf(const S: string): string;
var
  p: Integer;
begin
  p := Pos(':', S);
  if p > 0 then Result := Copy(S, 1, p - 1) else Result := S;
end;

function InnerKindOf(const Inner: string): Integer;
begin
  if Pos('+', Inner) > 0 then Exit(IK_OTHER);
  case StageNameOf(Inner) of
    'lzma': Result := IK_LZMA;
    'plz': Result := IK_PLZ;
    'lz4': Result := IK_LZ4;
  else
    Result := IK_OTHER;
  end;
end;

{ A parameter of 4x4 itself (not of the inner method)? }
function OwnParam(const P: string): Boolean; inline;
begin
  Result := (P <> '') and ((P[1] in ['0'..'9']) or ((Length(P) > 1) and (P[2] in ['0'..'9'])));
end;

function Inner4x4Method(const Params: TStringArray): string;
var
  k: Integer;
begin
  for k := 1 to High(Params) do
    if not OwnParam(Params[k]) then
      Exit(string.Join(':', Params, k, Length(Params) - k));
  Result := 'plz:1:1mb';
end;

procedure Parse4x4(const Stage: string; out Inner: string; out BlockSize: SizeInt);
var
  P, IP: TStringArray;
  k: Integer;
  m: QWord;
begin
  P := Stage.Split([':']);
  Inner := Inner4x4Method(P);
  BlockSize := 0;
  for k := 1 to High(P) do
  begin
    if not OwnParam(P[k]) then Break;
    if (P[k][1] in ['b', 'B']) and ParseMem(Copy(P[k], 2, MaxInt), m) and (m > 0) then
      BlockSize := Min(m, QWord(MAX_RAW));
  end;
  if BlockSize > 0 then Exit;
  IP := Inner.Split([':']);
  case StageNameOf(Inner) of
    'plz': if PlzEncAvailable(Inner) then BlockSize := PlzDictionary(IP);
    'lz4': if Lz4EncAvailable(Inner) then BlockSize := ParseLz4EncParams(IP).BlockSize;
  end;
  if BlockSize = 0 then
    for k := 1 to High(IP) do
      // first memory size with a suffix ("16mb"; a bare number is a count, not a size)
      if (IP[k] <> '') and (IP[k][1] in ['0'..'9']) and (StrToIntDef(IP[k], -1) < 0) and
         ParseMem(IP[k], m) then
      begin
        BlockSize := Min(m, QWord(MAX_RAW));
        Break;
      end;
  if BlockSize <= 0 then BlockSize := 8 * MB;
end;

function Noise4x4(const Stage: string): Double;
var
  P: TStringArray;
  k: Integer;
begin
  Result := 0.99;
  P := Stage.Split([':']);
  for k := 1 to High(P) do
  begin
    if not OwnParam(P[k]) then Break;
    if (P[k][1] in ['r', 'R']) and (Length(P[k]) > 1) then
      Result := StrToFloatDef(Copy(P[k], 2, MaxInt), 99, DefaultFormatSettings) / 100;
  end;
end;

procedure PutVInt(var B: TBytes; var N: Integer; V: QWord);
begin
  while V >= $80 do
  begin
    B[N] := Byte(V) or $80;
    Inc(N);
    V := V shr 7;
  end;
  B[N] := V;
  Inc(N);
end;

{ ---------------------------------------------------------------------------------------- }
{ Block analysis                                                                            }
{ ---------------------------------------------------------------------------------------- }

{ Order-0 entropy of Buf[0..Len) in bits per byte, over 8. }
function CellEntropy(Buf: PByte; Len: SizeInt): Double;
var
  C: array[0..3, 0..255] of LongWord;
  i, n4: SizeInt;
  v: LongWord;
  s: Integer;
  t, l2: Double;
begin
  FillChar(C, SizeOf(C), 0);
  n4 := Len and not SizeInt(3);
  i := 0;
  while i < n4 do
  begin
    v := PLongWord(Buf + i)^;
    Inc(C[0, v and $FF]);
    Inc(C[1, (v shr 8) and $FF]);
    Inc(C[2, (v shr 16) and $FF]);
    Inc(C[3, v shr 24]);
    Inc(i, 4);
  end;
  while i < Len do
  begin
    Inc(C[0, Buf[i]]);
    Inc(i);
  end;
  t := 0;
  l2 := Log2(Len);
  for s := 0 to 255 do
  begin
    v := C[0, s] + C[1, s] + C[2, s] + C[3, s];
    if v <> 0 then t := t + v * (l2 - Log2(v));
  end;
  Result := t / Len / 8;
end;

{ Estimated size, over its length, of the cell Blk[Lo..Hi) packed by an LZ with an entropy
  coder: greedy matches of 4+ bytes (a 4-byte hash, last position) at most EST_WINDOW back in
  the block, a literal costing the cell's order-0 entropy E0 (bits per byte, over 8) and a
  match 3 bytes. It follows what lzma does with near-random data closely enough to tell which
  cells are worth packing. Tab holds positions in the block (-1 = none) and is kept between
  the cells of a block. }
function LzEstimate(Blk: PByte; Lo, Hi: SizeInt; E0: Double; var Tab: array of SizeInt): Double;
const
  HB = 16;
var
  i, p, l, lit, m: SizeInt;
  k: LongWord;
begin
  i := Lo;
  lit := 0;
  m := 0;
  while i + 4 <= Hi do
  begin
    k := LongWord(PLongWord(Blk + i)^ * LongWord(2654435761)) shr (32 - HB);
    p := Tab[k];
    Tab[k] := i;
    if (p >= 0) and (i - p <= EST_WINDOW) and (PLongWord(Blk + p)^ = PLongWord(Blk + i)^) then
    begin
      l := 4;
      while (i + l < Hi) and (Blk[p + l] = Blk[i + l]) do Inc(l);
      Inc(m);
      Inc(i, l);
      Continue;
    end;
    Inc(lit);
    Inc(i);
  end;
  Inc(lit, Hi - i);
  Result := (lit * E0 * 8 + m * 24) / 8 / (Hi - Lo);
end;

var
  Gear: array[0..255] of QWord;

procedure InitGear;
var
  x, z: QWord;
  i: Integer;
begin
  x := QWord($2545F4914F6CDD1D);
  for i := 0 to 255 do
  begin
    // splitmix64
    x := x + QWord($9E3779B97F4A7C15);
    z := x;
    z := (z xor (z shr 30)) * QWord($BF58476D1CE4E5B9);
    z := (z xor (z shr 27)) * QWord($94D049BB133111EB);
    Gear[i] := z xor (z shr 31);
  end;
end;

type
  TNoiseRun = record
    Lo, Hi, Cov: SizeInt;
  end;
  TNoiseRuns = array of TNoiseRun;

{ Does some run overlap [Lo, Hi)? (R sorted, disjoint) }
function Overlaps(const R: array of TNoiseRun; NR: Integer; Lo, Hi: SizeInt): Boolean;
var
  a, b, m: Integer;
begin
  // first run that ends after Lo
  a := 0;
  b := NR;
  while a < b do
  begin
    m := (a + b) div 2;
    if R[m].Hi <= Lo then a := m + 1 else b := m;
  end;
  Result := (a < NR) and (R[a].Lo < Hi);
end;

{ Adds to each run its overlap with [Lo, Hi). }
procedure Credit(var R: array of TNoiseRun; NR: Integer; Lo, Hi: SizeInt);
var
  k: Integer;
begin
  for k := 0 to NR - 1 do
    if (R[k].Hi > Lo) and (R[k].Lo < Hi) then
      Inc(R[k].Cov, Min(Hi, R[k].Hi) - Max(Lo, R[k].Lo));
end;

{ For each run R[i], how many of its bytes take part in a repeat inside Buf[0..Len), as the
  copy or as the original (a run that an earlier or later part of the block repeats must be
  packed with it, or the copy loses its reference), found through content-defined anchors: a
  gear hash over the last 64 bytes, an anchor where its top bits are zero (about one every
  512 bytes), a table of the last position of each anchor hash, and a 32-byte check before
  the match is extended forwards. Repeats shorter than about a KB are missed, which is fine:
  noise has none worth packing. }
procedure RepeatScan(Buf: PByte; Len: SizeInt; var R: array of TNoiseRun; NR: Integer);
const
  WIN = 32;
var
  Tab: array of SizeInt;
  Key: array of QWord;
  h: QWord;
  i, p, l, Warm: SizeInt;
  slot: LongWord;
  TBITS: Integer;
  hit: Boolean;
begin
  if NR = 0 then Exit;
  // two slots per expected anchor: the anchors of the whole block stay in the table
  TBITS := 12;
  while (TBITS < 26) and (SizeInt(1) shl TBITS < 2 * (Len shr (64 - GEAR_SHIFT))) do Inc(TBITS);
  SetLength(Tab, 1 shl TBITS);
  SetLength(Key, 1 shl TBITS);
  FillChar(Tab[0], Length(Tab) * SizeOf(SizeInt), $FF);
  h := 0;
  i := 0;
  Warm := 64;
  while i < Len do
  begin
    h := (h shl 1) + Gear[Buf[i]];
    Inc(i);
    if (h shr GEAR_SHIFT <> 0) or (i < Warm) then Continue;
    slot := LongWord(h shr 20) and ((1 shl TBITS) - 1);
    p := Tab[slot];
    hit := (p >= 0) and (Key[slot] = h);
    Tab[slot] := i;
    Key[slot] := h;
    if not hit then Continue;
    if not Overlaps(R, NR, i - WIN, Len) and not Overlaps(R, NR, p - WIN, i) then Continue;
    if CompareByte(Buf[p - WIN], Buf[i - WIN], WIN) <> 0 then Continue;
    l := 0;
    while (i + l < Len) and (Buf[p + l] = Buf[i + l]) do Inc(l);
    // every run that the copy or the original overlaps gets the overlap
    Credit(R, NR, i - WIN, i + l);
    Credit(R, NR, p - WIN, p + l);
    Inc(i, l);
    h := 0;
    Warm := i + 64;
  end;
end;

{ ---------------------------------------------------------------------------------------- }
{ Encoder                                                                                   }
{ ---------------------------------------------------------------------------------------- }

type
  T4x4EncJob = class(TParallelJob)
  public
    Inner: string;
    Kind: Integer;
    InnerParams: TStringArray;
    InBuf: TBytes;
    InLen: SizeInt;
    Noise: Double;
    PlzCache: TObject;
    { result: one record for the whole block }
    RecKind: Byte;
    Segs: array of SizeInt;     // REC_MIXED: lengths, packed and stored alternating
    NSegs: Integer;
    Data: TBytes;               // REC_PACKED/REC_MIXED: the packed bytes
    function Pack(Src: PByte; Len: SizeInt; out D: TBytes): Boolean;
    procedure FindNoise(var Runs: TNoiseRuns; out NR: Integer);
    procedure Process; override;
  end;

function T4x4EncJob.Pack(Src: PByte; Len: SizeInt; out D: TBytes): Boolean;
var
  ok: Boolean;
begin
  D := nil;
  case Kind of
    IK_PLZ: ok := PlzEncodeMem(InnerParams, Src, Len, D, PlzCache);
    IK_LZ4: ok := Lz4EncodeMem(InnerParams, Src, Len, D);
    IK_LZMA:
      begin
        D := LzmaEncodeMem(Src, Len, ParseLzmaEncParams(InnerParams), False);
        ok := True;
      end;
  else
    begin
      D := CompressMem(Inner, Src, Len);
      ok := True;
    end;
  end;
  Result := ok and (Length(D) > 0) and (SizeInt(Length(D)) < Len);
  if not Result then D := nil;
end;

{ Runs of noise cells (see the unit header) that are stored apart. }
procedure T4x4EncJob.FindNoise(var Runs: TNoiseRuns; out NR: Integer);
var
  NC, c, Run0, Lo, Hi: SizeInt;
  IsNoise: array of Boolean;
  Tab: array of SizeInt;
  E0, Est, MinE0: Double;
  k, n: Integer;
begin
  NR := 0;
  if (Noise >= 1) or (InLen < NOISE_RUN) then Exit;
  NC := (InLen + CELL - 1) div CELL;
  SetLength(IsNoise, NC);
  // in a block that is near-random as a whole (order-0 >= r) a cell has to promise more to be
  // worth the time of the inner method (4 % instead of 0.5 %)
  Est := NOISE_EST;
  MinE0 := Noise;
  if CellEntropy(@InBuf[0], InLen) >= Noise then
  begin
    Est := NOISE_EST_RANDOM;
    MinE0 := NOISE_MINE0_RANDOM;
  end;
  SetLength(Tab, 1 shl 16);
  FillChar(Tab[0], Length(Tab) * SizeOf(SizeInt), $FF);
  for c := 0 to NC - 1 do
  begin
    Lo := c * CELL;
    Hi := Min(Lo + CELL, InLen);
    // (a short last cell takes its neighbour's verdict)
    if (Hi - Lo < CELL div 4) and (c > 0) then IsNoise[c] := IsNoise[c - 1]
    else
    begin
      // flat order-0 statistics, and then no gain worth the time of the inner method either:
      // short repeats and structure show in the LZ estimate
      E0 := CellEntropy(@InBuf[Lo], Hi - Lo);
      IsNoise[c] := (E0 >= MinE0) and (LzEstimate(@InBuf[0], Lo, Hi, E0, Tab) >= Est);
    end;
  end;
  c := 0;
  while c < NC do
  begin
    if not IsNoise[c] then
    begin
      Inc(c);
      Continue;
    end;
    Run0 := c;
    while (c < NC) and IsNoise[c] do Inc(c);
    Lo := Run0 * CELL;
    Hi := Min(c * CELL, InLen);
    if Hi - Lo >= NOISE_RUN then
    begin
      if NR = Length(Runs) then SetLength(Runs, NR * 2 + 4);
      Runs[NR].Lo := Lo;
      Runs[NR].Hi := Hi;
      Runs[NR].Cov := 0;
      Inc(NR);
    end;
  end;
  // runs that repeat earlier data of the block go to the inner method after all
  RepeatScan(@InBuf[0], InLen, Runs, NR);
  n := 0;
  for k := 0 to NR - 1 do
    if Runs[k].Cov < REPEAT_SHARE * (Runs[k].Hi - Runs[k].Lo) then
    begin
      Runs[n] := Runs[k];
      Inc(n);
    end;
  NR := n;
end;

procedure T4x4EncJob.Process;
var
  Runs: TNoiseRuns;
  NR, k: Integer;
  G: TBytes;
  GLen, Pos0: SizeInt;
  Grant: Integer;
begin
  // the blocks are already spread over the threads: one thread for the inner method
  Grant := LzmaEncThreadGrant;
  LzmaEncThreadGrant := 1;
  try
    Runs := nil;
    FindNoise(Runs, NR);
    NSegs := 0;
    if NR = 0 then
    begin
      if Pack(@InBuf[0], InLen, Data) then RecKind := REC_PACKED else RecKind := REC_STORED;
      Exit;
    end;
    // the bytes between the noise runs are packed together (they keep their common context)
    // and the runs are stored after them
    SetLength(Segs, 2 * NR + 1);
    SetLength(G, InLen);
    GLen := 0;
    Pos0 := 0;
    for k := 0 to NR - 1 do
    begin
      Segs[NSegs] := Runs[k].Lo - Pos0;
      Segs[NSegs + 1] := Runs[k].Hi - Runs[k].Lo;
      Inc(NSegs, 2);
      Move(InBuf[Pos0], G[GLen], Runs[k].Lo - Pos0);
      Inc(GLen, Runs[k].Lo - Pos0);
      Pos0 := Runs[k].Hi;
    end;
    if Pos0 < InLen then
    begin
      Segs[NSegs] := InLen - Pos0;
      Inc(NSegs);
      Move(InBuf[Pos0], G[GLen], InLen - Pos0);
      Inc(GLen, InLen - Pos0);
    end;
    if (GLen > 0) and Pack(@G[0], GLen, Data) then RecKind := REC_MIXED
    else
    begin
      RecKind := REC_STORED;
      NSegs := 0;
    end;
  finally
    LzmaEncThreadGrant := Grant;
  end;
end;

constructor T4x4EncStage.Create(ATarget: TOutStage; const AInner: string; ABlockSize: SizeInt;
  ANoise: Double; AHint: Int64);
var
  Threads: Integer;
begin
  inherited Create(ATarget);
  FInner := AInner;
  FBlockSize := ABlockSize;
  if FBlockSize < 64 * 1024 then FBlockSize := 64 * 1024;
  if FBlockSize > MAX_RAW then FBlockSize := MAX_RAW;
  FNoise := ANoise;
  // plz and lz4 go through near-random data faster than the analysis would
  if InnerKindOf(AInner) in [IK_PLZ, IK_LZ4] then FNoise := 2;
  FHint := AHint;
  Threads := PoolWorkers(FX_MAXTHREADS);
  if Threads > 0 then SetLength(FQueue, Threads + 1) else SetLength(FQueue, 1);
  FPool := TJobPool.Create(Threads, FX_MAXTHREADS + 1);
  if InnerKindOf(FInner) = IK_PLZ then FPlzCache := TPlzEncCache.Create;
  FTarget := 0;
end;

destructor T4x4EncStage.Destroy;
var
  i: Integer;
begin
  FPool.Free;
  for i := 0 to FCount - 1 do FQueue[(FHead + i) mod Length(FQueue)].Free;
  FPlzCache.Free;
  inherited Destroy;
end;

{ Size of the block that starts now. With the expected input known and 2+ threads, once
  what is left would not give every thread a full block, the rest is cut in equal blocks, one
  per thread (not below 1 MB nor 1/8 of the block size), fixed from then on. }
procedure T4x4EncStage.NextTarget;
var
  Left, T: Int64;
  N: Integer;
begin
  FTarget := FBlockSize;
  if FTail > 0 then
  begin
    FTarget := FTail;
    Exit;
  end;
  if (FHint <= 0) or (FPool.MaxWorkers < 1) then Exit;
  N := BudgetThreads;
  if N > FX_MAXTHREADS then N := FX_MAXTHREADS;
  if N < 2 then Exit;
  Left := FHint - FIn;
  if Left <= 0 then Exit;
  if Left >= Int64(N) * FBlockSize then Exit;
  T := (Left + N - 1) div N;
  T := (T + 65535) and not Int64(65535);
  if T < MB then T := MB;
  if T < FBlockSize div 8 then T := FBlockSize div 8;
  if T > FBlockSize then T := FBlockSize;
  FTail := T;
  FTarget := T;
end;

procedure T4x4EncStage.WriteOldest;
var
  Job: T4x4EncJob;
  H: TBytes;
  n, j: Integer;
  Off: SizeInt;
begin
  Job := T4x4EncJob(FQueue[FHead]);
  FHead := (FHead + 1) mod Length(FQueue);
  Dec(FCount);
  try
    FPool.WaitJob(Job);
    SetLength(H, 24 + 10 * Job.NSegs);
    H[0] := Job.RecKind;
    n := 1;
    PutVInt(H, n, Job.InLen);
    case Job.RecKind of
      REC_STORED:
        begin
          Emit(@H[0], n);
          Emit(@Job.InBuf[0], Job.InLen);
        end;
      REC_PACKED:
        begin
          PutVInt(H, n, Length(Job.Data));
          Emit(@H[0], n);
          Emit(@Job.Data[0], Length(Job.Data));
        end;
      REC_MIXED:
        begin
          PutVInt(H, n, Job.NSegs);
          for j := 0 to Job.NSegs - 1 do PutVInt(H, n, Job.Segs[j]);
          PutVInt(H, n, Length(Job.Data));
          Emit(@H[0], n);
          Emit(@Job.Data[0], Length(Job.Data));
          Off := 0;
          for j := 0 to Job.NSegs - 1 do
          begin
            if Odd(j) then Emit(@Job.InBuf[Off], Job.Segs[j]);
            Inc(Off, Job.Segs[j]);
          end;
        end;
    end;
    // the input buffer goes back for the next blocks (no new pages to fault in)
    if (Length(Job.InBuf) >= FTarget) and (FNumFree < Length(FQueue)) then
    begin
      if FNumFree = Length(FFree) then SetLength(FFree, FNumFree + 4);
      FFree[FNumFree] := Job.InBuf;
      Inc(FNumFree);
    end;
    Job.InBuf := nil;
  finally
    Job.Free;
  end;
end;

procedure T4x4EncStage.SubmitBlock;
var
  Job: T4x4EncJob;
  Q: TJobArray;
  i: Integer;
begin
  if FLen = 0 then Exit;
  if FCount = Length(FQueue) then
  begin
    // every job of the queue is running: one thread more if the budget has a token for it
    if (FPool.MaxWorkers > 0) and (Length(FQueue) <= FX_MAXTHREADS) and FPool.CanGrow(FX_MAXTHREADS) then
    begin
      SetLength(Q, Length(FQueue) + 1);
      for i := 0 to FCount - 1 do Q[i] := FQueue[(FHead + i) mod Length(FQueue)];
      FQueue := Q;
      FHead := 0;
      FPool.SetMaxWorkers(FPool.MaxWorkers + 1);
    end
    else
      WriteOldest;
  end;
  Job := T4x4EncJob.Create;
  Job.Inner := FInner;
  Job.Kind := InnerKindOf(FInner);
  Job.InnerParams := FInner.Split([':']);
  Job.InBuf := FCur;
  Job.InLen := FLen;
  Job.Noise := FNoise;
  Job.PlzCache := FPlzCache;
  FCur := nil;
  FLen := 0;
  FQueue[(FHead + FCount) mod Length(FQueue)] := Job;
  Inc(FCount);
  FPool.Submit(Job);
end;

procedure T4x4EncStage.WriteHeader;
var
  H: array[0..2] of Byte;
begin
  FHeaderDone := True;
  H[0] := FX_MAGIC0;
  H[1] := FX_MAGIC1;
  H[2] := FX_VERSION;
  Emit(@H[0], 3);
  NextTarget;
end;

procedure T4x4EncStage.DoWrite(Buf: PByte; Count: SizeInt);
var
  k, Cap: SizeInt;
begin
  if not FHeaderDone then WriteHeader;
  while Count > 0 do
  begin
    if FCur = nil then
    begin
      if FNumFree > 0 then
      begin
        Dec(FNumFree);
        FCur := FFree[FNumFree];
        FFree[FNumFree] := nil;
      end;
    end;
    Cap := Length(FCur);
    if Cap < FTarget then
    begin
      // grow with the data (small inputs do not reserve the whole block)
      k := FLen + Count;
      if k < 64 * 1024 then k := 64 * 1024;
      if k < 2 * Cap then k := 2 * Cap;
      if k > FTarget then k := FTarget;
      if k > Cap then
      begin
        SetLength(FCur, k);
        Cap := k;
      end;
    end;
    k := Min(FTarget, Cap) - FLen;
    if k > Count then k := Count;
    Move(Buf^, FCur[FLen], k);
    Inc(FLen, k);
    Inc(FIn, k);
    Inc(Buf, k);
    Dec(Count, k);
    if FLen >= FTarget then
    begin
      SubmitBlock;
      NextTarget;
    end;
  end;
end;

procedure T4x4EncStage.DoFinish;
var
  E: Byte;
begin
  if not FHeaderDone then WriteHeader;
  SubmitBlock;
  while FCount > 0 do WriteOldest;
  E := REC_END;
  Emit(@E, 1);
end;

{ ---------------------------------------------------------------------------------------- }
{ Decoder                                                                                   }
{ ---------------------------------------------------------------------------------------- }

type
  T4x4DecJob = class(TParallelJob)
  public
    Stage: T4x4DecStage;
    Kind: Byte;
    Data: TBytes;               // packed bytes, then (REC_MIXED) the stored segments
    PackLen: SizeInt;
    Segs: array of SizeInt;
    NSegs: Integer;
    Tmp: TBytes;
    procedure Unpack(Dst: PByte; DstLen: SizeInt);
    procedure Process; override;
  end;

{ The packed bytes into Dst[0..DstLen); zeros and a warning if they do not decode. }
procedure T4x4DecJob.Unpack(Dst: PByte; DstLen: SizeInt);
var
  W: SizeInt;
  R: TLzmaResult;
  T: TBytes;
begin
  try
    case Stage.FKind of
      IK_LZMA:
        begin
          R := LzmaDecodeRaw(@Data[0], PackLen, Dst, DstLen, Stage.Flc, Stage.Flp, Stage.Fpb, W);
          if (R = lzDataError) or (R = lzBadProps) or (W <> DstLen) then
            Corrupt('4x4: lzma record does not decode');
        end;
      IK_PLZ:
        if not PlzDecodeMem(@Data[0], PackLen, Dst, DstLen) then
          Corrupt('4x4: plz record does not decode');
      IK_LZ4:
        if not Lz4DecodeMem(@Data[0], PackLen, Dst, DstLen) then
          Corrupt('4x4: lz4 record does not decode');
    else
      begin
        T := DecompressMem(Stage.FInner, @Data[0], PackLen, DstLen);
        Move(T[0], Dst^, DstLen);
      end;
    end;
  except
    on E: EArcCorrupt do
    begin
      ErrLn('Warning: damaged 4x4 record (' + E.Message + '); zeros are returned for its ' +
        IntToStr(DstLen) + ' bytes and the remaining records continue');
      FillChar(Dst^, DstLen, 0);
    end;
  end;
end;

procedure T4x4DecJob.Process;
var
  j: Integer;
  GLen, Off, GOff, SOff: SizeInt;
begin
  if Kind = REC_STORED then Exit;     // ReadJob already put the bytes in OutBuf
  if SizeInt(Length(OutBuf)) < OutSize then
  begin
    OutBuf := nil;
    SetLength(OutBuf, OutSize);
  end;
  if Kind = REC_PACKED then
  begin
    Unpack(@OutBuf[0], OutSize);
    Exit;
  end;
  GLen := 0;
  j := 0;
  while j < NSegs do
  begin
    Inc(GLen, Segs[j]);
    Inc(j, 2);
  end;
  if SizeInt(Length(Tmp)) < GLen then
  begin
    Tmp := nil;
    SetLength(Tmp, GLen);
  end;
  Unpack(@Tmp[0], GLen);
  Off := 0;
  GOff := 0;
  SOff := PackLen;
  for j := 0 to NSegs - 1 do
  begin
    if Odd(j) then
    begin
      Move(Data[SOff], OutBuf[Off], Segs[j]);
      Inc(SOff, Segs[j]);
    end
    else
    begin
      Move(Tmp[GOff], OutBuf[Off], Segs[j]);
      Inc(GOff, Segs[j]);
    end;
    Inc(Off, Segs[j]);
  end;
end;

constructor T4x4DecStage.Create(ASource: TInStage; const AInner: string);
var
  lz: TLzmaEncParams;
begin
  inherited Create(ASource, FX_MAXTHREADS, 1);
  // records can be small (the stored noise runs): read ahead by bytes too
  ReadAheadBytes := 16 * MB;
  FInner := AInner;
  FKind := InnerKindOf(AInner);
  if FKind = IK_LZMA then
  begin
    try
      lz := ParseLzmaEncParams(AInner.Split([':']));
    except
      on E: Exception do raise EUnsupportedMethod.Create('4x4: ' + E.Message);
    end;
    if not ValidLzmaProps(lz.lc, lz.lp, lz.pb) then
      raise EUnsupportedMethod.Create('4x4: invalid lzma properties');
    Flc := lz.lc;
    Flp := lz.lp;
    Fpb := lz.pb;
  end;
end;

destructor T4x4DecStage.Destroy;
var
  i: Integer;
begin
  inherited Destroy;
  for i := 0 to FNumFree - 1 do FFreeJobs[i].Free;
end;

function T4x4DecStage.RdVInt: QWord;
var
  b: Byte;
  s: Integer;
begin
  Result := 0;
  s := 0;
  repeat
    Source.ReadExact(@b, 1);
    if s > 56 then Corrupt('4x4: invalid number');
    Result := Result or (QWord(b and $7F) shl s);
    Inc(s, 7);
  until b and $80 = 0;
end;

procedure T4x4DecStage.ReleaseJob(Job: TParallelJob);
begin
  // packed records keep their buffers for the next ones (stored ones gave theirs away)
  if (T4x4DecJob(Job).Kind <> REC_STORED) and (FNumFree < QueueCapacity) then
  begin
    if FNumFree = Length(FFreeJobs) then SetLength(FFreeJobs, FNumFree + 8);
    FFreeJobs[FNumFree] := Job;
    Inc(FNumFree);
  end
  else
    Job.Free;
end;

function T4x4DecStage.ReadJob: TParallelJob;
var
  H: array[0..2] of Byte;
  b: Byte;
  RawLen, PackLen, NS, L, Sum, GSum, Need: QWord;
  Job: T4x4DecJob;
  j: Integer;
begin
  Result := nil;
  if FEnded then Exit;
  if not FStarted then
  begin
    Source.ReadExact(@H[0], 3);
    if (H[0] <> FX_MAGIC0) or (H[1] <> FX_MAGIC1) then Corrupt('4x4: not a 4x4 stream');
    if H[2] <> FX_VERSION then Corrupt('4x4: unknown stream version');
    FStarted := True;
  end;
  if not Source.ReadExactOrEof(@b, 1) then Corrupt('4x4: truncated stream');
  if b = REC_END then
  begin
    FEnded := True;
    Exit;
  end;
  if (b < REC_STORED) or (b > REC_MIXED) then Corrupt('4x4: invalid record');
  RawLen := RdVInt;
  if (RawLen = 0) or (RawLen > QWord(MAX_RAW)) then Corrupt('4x4: invalid record size');
  if FNumFree > 0 then
  begin
    Dec(FNumFree);
    Job := T4x4DecJob(FFreeJobs[FNumFree]);
    Job.ResetForReuse;
  end
  else
  begin
    Job := T4x4DecJob.Create;
    Job.Stage := Self;
  end;
  try
    Job.Kind := b;
    Job.OutSize := RawLen;
    Job.NSegs := 0;
    if b = REC_STORED then
    begin
      Job.OutBuf := nil;
      SetLength(Job.OutBuf, RawLen);
      Source.ReadExact(@Job.OutBuf[0], RawLen);
    end
    else
    begin
      GSum := RawLen;
      Sum := 0;
      if b = REC_MIXED then
      begin
        NS := RdVInt;
        if (NS < 2) or (NS > RawLen) or (NS > 1 shl 20) then Corrupt('4x4: invalid record');
        if Length(Job.Segs) < NS then SetLength(Job.Segs, NS);
        GSum := 0;
        for j := 0 to NS - 1 do
        begin
          L := RdVInt;
          if L > RawLen then Corrupt('4x4: invalid record');
          Job.Segs[j] := L;
          Inc(Sum, L);
          if not Odd(j) then Inc(GSum, L);
        end;
        if (Sum <> RawLen) or (GSum = 0) then Corrupt('4x4: invalid record');
        Job.NSegs := NS;
        Sum := RawLen - GSum;    // stored bytes after the packed ones
      end;
      PackLen := RdVInt;
      if (PackLen = 0) or (PackLen >= GSum) then Corrupt('4x4: invalid record size');
      Need := PackLen + Sum;
      if SizeInt(Length(Job.Data)) < SizeInt(Need) then
      begin
        Job.Data := nil;
        SetLength(Job.Data, Need);
      end;
      Job.PackLen := PackLen;
      Source.ReadExact(@Job.Data[0], Need);
    end;
  except
    Job.Free;
    raise;
  end;
  Result := Job;
end;

initialization
  InitGear;
end.
