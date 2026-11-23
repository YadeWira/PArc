{ bwt: PArc's block-sorting compressor (MIT; replaces FreeArc's GRZip, which is LGPL).

  Each block goes through three steps, undone in reverse order by the decoder:
   1. LZP (parc_lzp, PArc's own): long repeats become an escape byte plus a length, so the
      sort works on less data and the coder does not spend bits on what the LZP finds for free.
      The lengths stream is appended to the literals: both are sorted together;
   2. the Burrows-Wheeler transform, built with libsais (Ilya Grebnov, Apache-2.0, vendored
      unchanged in src/bwt/), which also does the inverse;
   3. QLFC (quantized local frequency coding): the run heads of the BWT output are coded as
      move-to-front ranks plus run lengths, bit by bit with adaptive binary contexts.
      Two coders from libbsc 3.4.1 (Ilya Grebnov, Apache-2.0) translated to C in
      src/bwt/qlfc.c: "static" (three counters averaged with fixed weights) and "adaptive"
      (the same counters mixed by a small neural mixer per context; slower, smaller).
  The C core (src/bwt/bwt_core.c) needs nothing from the C library: build.sh compiles it per
  target and this unit links the object. Everything is integer arithmetic on the block: the
  output does not depend on the platform or the thread count.

  Blocks are compressed and decompressed in parallel (a pool of jobs, written and delivered in
  order) within the PARC_THREADS budget (parc_parallel).

  Method string: bwt[:<block>][:m1..m4][:l|:l<N>|:<N>][:h<N>][:e1|:e2], also b<block>; GRZip's
  other switches (a, s, d, p, t<N>, i<N>) are accepted and ignored. Defaults: 8 MB, m1, LZP
  with minimum match 32 and 18 hash bits. m1 = adaptive coder, m2..m4 = static coder; e1/e2
  choose the coder explicitly. A bare integer is the LZP minimum; a bare memory size the
  block (as with GRZip). `grzip:...` strings are read as `bwt:...` by the canonizer.

  Stream (version 1, docs/formato/FORMATO-PARC.md §6.6):
    U8 version (1), U8 LZP hash bits (0 = no LZP), [VInt LZP minimum if bits > 0]; both must
    be those of the method string. Then blocks until the end of the stream:
      VInt Len (1..block size), U8 mode:
        0: Len stored bytes;
        1: U8 flags (bits 0-1: coder 1 static / 2 adaptive; bit 2: LZP applied; others 0),
           [LZP: U8 escape, VInt minimum, VInt NMain, VInt NLens], VInt Primary, VInt CodedLen, CodedLen
           bytes of QLFC data. The BWT input has M = NMain + NLens bytes with LZP (the main
           stream, then the lengths), else M = Len; Primary is libsais' primary index (1..M).
    VInt = LEB128 (7 bits per byte, low group first). }
unit parc_bwt;

{$mode objfpc}{$H+}
{$pointermath on}
{$R-}{$Q-}

interface

uses
  SysUtils, parc_stream, parc_outstream, parc_parallel, parc_lzp;

const
  BWT_STREAM_VERSION = 1;
  BWT_MAX_BLOCK = 1 shl 30;
  BWT_DEF_BLOCK = 8 shl 20;
  BWT_DEF_LZP_MIN = 32;
  BWT_DEF_LZP_HASH = 18;
  BWT_CODER_STATIC = 1;
  BWT_CODER_ADAPTIVE = 2;
  { Blocks shorter than this are stored }
  BWT_MIN_CODED = 64;

type
  EBwtParams = class(Exception);

  TBwtParams = record
    BlockSize: SizeInt;
    Level: Integer;          // m1..m4
    CoderSet: Integer;       // e1/e2 given (0 = from the level)
    Coder: Integer;          // BWT_CODER_*
    LzpMin: Integer;         // 0 = no LZP
    LzpHash: Integer;
    Adaptive: Boolean;       // a: blocks cut where the statistics change
  end;

  { Encoder: blocks of BlockSize bytes compressed in parallel and written in order. }
  TBwtEncStage = class(TOutStage)
  private
    FPar: TBwtParams;
    FCur: TBytes;
    FLen: SizeInt;
    FPool: TJobPool;
    FQueue: TJobArray;
    FHead, FCount: Integer;
    FHeaderDone: Boolean;
    FSeg: TObject;               // segmentation model (a), created on first use
    procedure SubmitJob(var Data: TBytes; Len: SizeInt);
    procedure FlushBlock(Final: Boolean);
    procedure WriteOldest;
  protected
    procedure DoWrite(Buf: PByte; Count: SizeInt); override;
    procedure DoFinish; override;
  public
    constructor Create(ATarget: TOutStage; const Params: TStringArray);
    destructor Destroy; override;
  end;

  { Decoder: blocks decoded in parallel, delivered in order. }
  TBwtStage = class(TParallelBlockStage)
  private
    FPar: TBwtParams;
    FStarted: Boolean;
    function RdByte: Byte;
    function RdVInt: QWord;
  protected
    function ReadJob: TParallelJob; override;
  public
    constructor Create(ASource: TInStage; const Params: TStringArray);
  end;

{ Method parameters (EBwtParams if invalid), normalized. }
function ParseBwtParams(const Params: TStringArray): TBwtParams;

{ Canonical method string for P with block size BlockSize. }
function BwtMethodString(const P: TBwtParams; BlockSize: SizeInt): string;

{ Memory of one block being compressed / decompressed (bytes). }
function BwtEncodeBlockMemory(const P: TBwtParams): Int64;
function BwtDecodeBlockMemory(const P: TBwtParams): Int64;

{ One block record (VInt Len onwards), for tests. }
function BwtEncodeBlock(Inp: PByte; Len: SizeInt; const P: TBwtParams): TBytes;

{ For tests: True if the C core's LZP gives the bytes of parc_lzp.LzpEncodeBlock on Inp[0..Len). }
function BwtLzpSameAsPascal(Inp: PByte; Len: SizeInt; MinLen, HashBits: Integer): Boolean;

{ The C core's primitives, for tests: forward/inverse BWT and QLFC on whole buffers. }
function BwtForward(T, U: PByte; A: PLongInt; n: LongInt): LongInt;
function BwtInverse(T, U: PByte; A: PLongInt; n, Primary: LongInt): LongInt;

implementation

uses
  Math, parc_bytes;

{$L bwt_core.o}

type
  TBwtAllocFn = function(Size: SizeUInt): Pointer; cdecl;
  TBwtFreeFn = procedure(P: Pointer); cdecl;

procedure parc_bwt_set_alloc(a: TBwtAllocFn; f: TBwtFreeFn); cdecl; external name 'parc_bwt_set_alloc';
function parc_bwt_forward(T, U: PByte; A: PLongInt; n: LongInt): LongInt; cdecl; external name 'parc_bwt_forward';
function parc_bwt_inverse(T, U: PByte; A: PLongInt; n, primary: LongInt): LongInt; cdecl; external name 'parc_bwt_inverse';
function parc_qlfc_model_size(coder: LongInt): LongInt; cdecl; external name 'parc_qlfc_model_size';
function parc_lzp_encode(input: PByte; len, minLen, hb: LongInt; hash: PLongWord; output, lens: PByte; lensCap: LongInt;
  out nMain, nLens: LongInt; out esc: Byte): LongInt; cdecl; external name 'parc_lzp_encode';
function parc_qlfc_encode(input, output, buffer: PByte; n, outputSize, coder: LongInt; model: Pointer): LongInt; cdecl;
  external name 'parc_qlfc_encode';
function parc_qlfc_decode(input: PByte; inputSize: LongInt; output: PByte; n, coder: LongInt; model: Pointer): LongInt; cdecl;
  external name 'parc_qlfc_decode';

function CoreAlloc(Size: SizeUInt): Pointer; cdecl;
begin
  try
    Result := GetMem(Size);
  except
    Result := nil;
  end;
end;

procedure CoreFree(P: Pointer); cdecl;
begin
  FreeMem(P);
end;

function BwtForward(T, U: PByte; A: PLongInt; n: LongInt): LongInt;
begin
  Result := parc_bwt_forward(T, U, A, n);
end;

function BwtInverse(T, U: PByte; A: PLongInt; n, Primary: LongInt): LongInt;
begin
  Result := parc_bwt_inverse(T, U, A, n, Primary);
end;

const
  BWT_MAXTHREADS = 16;
  { Slack after the QLFC encoder's input (it reads ahead 16 bytes) and after its output }
  IN_SLACK = 16;
  OUT_SLACK = 8192;
  LZP_MAX_MIN = 65535;
  LZP_REDO_PCT = 50;

{ ---------------- parameters ---------------- }

function Min(a, b: QWord): QWord; inline;
begin
  if a < b then Result := a else Result := b;
end;

function ParseBwtParams(const Params: TStringArray): TBwtParams;
var
  k, n: Integer;
  p, r: string;
  m: QWord;

  function Num(const S: string): Integer;
  begin
    Result := StrToIntDef(S, -1);
    if Result < 0 then raise EBwtParams.CreateFmt('bwt: invalid parameter "%s"', [p]);
  end;

begin
  Result.BlockSize := BWT_DEF_BLOCK;
  Result.Level := 1;
  Result.CoderSet := 0;
  Result.Adaptive := False;
  Result.LzpMin := BWT_DEF_LZP_MIN;
  Result.LzpHash := BWT_DEF_LZP_HASH;
  for k := 1 to High(Params) do
  begin
    p := LowerCase(Trim(Params[k]));
    if p = '' then Continue;
    r := Copy(p, 2, MaxInt);
    if (p[1] in ['a'..'z']) and ((r = '') or (r[1] in ['0'..'9'])) then
      case p[1] of
        'm':
          begin
            Result.Level := Num(r);
            if (Result.Level < 1) or (Result.Level > 4) then
              raise EBwtParams.CreateFmt('bwt: invalid level "%s" (m1..m4)', [p]);
          end;
        'l': if r = '' then Result.LzpMin := 0 else Result.LzpMin := Num(r);
        'h': Result.LzpHash := Num(r);
        'e':
          begin
            Result.CoderSet := Num(r);
            if (Result.CoderSet < 1) or (Result.CoderSet > 2) then
              raise EBwtParams.CreateFmt('bwt: invalid coder "%s" (e1 or e2)', [p]);
          end;
        'b':
          if ParseMemSize(r, m) then Result.BlockSize := SizeInt(Min(m, QWord(High(SizeInt))))
          else raise EBwtParams.CreateFmt('bwt: invalid block size "%s"', [p]);
        // GRZip's switches: adaptive block, alternative sort, delta filter, threads, buffers
        'a':
          if r = '' then Result.Adaptive := True
          else raise EBwtParams.CreateFmt('bwt: invalid parameter "%s"', [p]);
        's', 'd', 'p': if r <> '' then raise EBwtParams.CreateFmt('bwt: invalid parameter "%s"', [p]);
        't', 'i': ;
      else
        raise EBwtParams.CreateFmt('bwt: unknown parameter "%s"', [p]);
      end
    else
    begin
      n := StrToIntDef(p, -1);
      if n >= 0 then Result.LzpMin := n
      else if ParseMemSize(p, m) then Result.BlockSize := SizeInt(Min(m, QWord(High(SizeInt))))
      else raise EBwtParams.CreateFmt('bwt: unknown parameter "%s"', [p]);
    end;
  end;
  if Result.BlockSize < 1 then raise EBwtParams.Create('bwt: invalid block size');
  if Result.BlockSize > BWT_MAX_BLOCK then Result.BlockSize := BWT_MAX_BLOCK;
  if Result.LzpMin > 0 then
  begin
    if Result.LzpMin < 8 then Result.LzpMin := 8;
    if Result.LzpMin > 65535 then Result.LzpMin := 65535;
  end;
  if Result.LzpHash < 10 then Result.LzpHash := 10;
  if Result.LzpHash > LZP_MAX_HASH_BITS then Result.LzpHash := LZP_MAX_HASH_BITS;
  if Result.CoderSet <> 0 then Result.Coder := Result.CoderSet
  else if Result.Level = 1 then Result.Coder := BWT_CODER_ADAPTIVE
  else Result.Coder := BWT_CODER_STATIC;
end;

function BwtMethodString(const P: TBwtParams; BlockSize: SizeInt): string;
begin
  Result := 'bwt:' + IntToStr(BlockSize) + 'b:m' + IntToStr(P.Level);
  if P.LzpMin > 0 then Result := Result + ':l' + IntToStr(P.LzpMin) + ':h' + IntToStr(P.LzpHash)
  else Result := Result + ':l';
  if P.CoderSet <> 0 then Result := Result + ':e' + IntToStr(P.CoderSet);
  if P.Adaptive then Result := Result + ':a';
end;

function LzpParamsOf(const P: TBwtParams; BlockSize: SizeInt; MinLen: Integer): TLzpParams;
begin
  Result.BlockSize := BlockSize;
  Result.MinMatchLen := MinLen;
  Result.SmallestLen := MinLen;
  Result.HashSizeLog := P.LzpHash;
  Result.Barrier := LZP_MAX_BLOCK;
  LzpNormalize(Result);
end;

{ LzpEncodeBlock of parc_lzp (one minimum, no barrier) by the C core: same bytes, faster. Main
  holds Len bytes, Lens Len bytes. }
function LzpEncode(Inp: PByte; Len: SizeInt; const Lp: TLzpParams; var Hash: array of LongWord; var Main: TBytes;
  Lens: PByte; out NMain, NLens: SizeInt; out Esc: Byte): Boolean;
var
  nm, nl: LongInt;
begin
  Result := parc_lzp_encode(Inp, Len, Lp.MinMatchLen, LzpBlockHashBits(Len, Lp.HashSizeLog), @Hash[0], @Main[0],
    Lens, Len, nm, nl, Esc) <> 0;
  NMain := nm;
  NLens := nl;
end;

function BwtLzpSameAsPascal(Inp: PByte; Len: SizeInt; MinLen, HashBits: Integer): Boolean;
var
  P: TBwtParams;
  Lp: TLzpParams;
  Hash: array of LongWord;
  M1, M2, L1: TBytes;
  L2: PByte;
  a1, a2, b1, b2: SizeInt;
  e1, e2: Byte;
  r1, r2: Boolean;
begin
  P.LzpMin := MinLen;
  P.LzpHash := HashBits;
  Lp := LzpParamsOf(P, Len, MinLen);
  SetLength(Hash, SizeInt(2) shl LzpBlockHashBits(Len, Lp.HashSizeLog));
  SetLength(M1, Len + 1);
  SetLength(M2, Len + 1);
  r1 := LzpEncodeBlock(Inp, Len, Lp, Hash, M1, L1, a1, b1, e1);
  L2 := GetMem(Len + 1);
  try
    r2 := LzpEncode(Inp, Len, Lp, Hash, M2, L2, a2, b2, e2);
    Result := (r1 = r2) and (not r1 or ((a1 = a2) and (b1 = b2) and (e1 = e2) and
      CompareMem(@M1[0], @M2[0], a1) and ((b1 = 0) or CompareMem(@L1[0], L2, b1))));
  finally
    FreeMem(L2);
  end;
end;

function BwtEncodeBlockMemory(const P: TBwtParams): Int64;
begin
  // input + BWT buffer + suffix array (4 bytes per byte) + model; the LZP table only before
  // the sort
  Result := 6 * Int64(P.BlockSize) + 2 shl 20;
end;

function BwtDecodeBlockMemory(const P: TBwtParams): Int64;
begin
  // coded data + BWT buffer + inverse table (4 bytes per byte); output and LZP table after
  Result := 6 * Int64(P.BlockSize) + 2 shl 20;
end;

{ ---------------- VInt ---------------- }

procedure PutVInt(var B: TBytes; var n: SizeInt; V: QWord);
begin
  if n + 10 > Length(B) then SetLength(B, n + 64);
  while V >= $80 do
  begin
    B[n] := Byte(V) or $80;
    Inc(n);
    V := V shr 7;
  end;
  B[n] := Byte(V);
  Inc(n);
end;

{ ---------------- one block ---------------- }

function BwtEncodeBlock(Inp: PByte; Len: SizeInt; const P: TBwtParams): TBytes;
var
  H: TBytes;
  n, NMain, NLens, M, OutCap, C, Need: SizeInt;
  Lp: TLzpParams;
  Hash: array of LongWord;
  Main: TBytes;
  Lens: PByte;
  Esc, Flags: Byte;
  UseLzp: Boolean;
  MinLen: Integer;
  A: PLongInt;
  Model, OutP, Scratch, Extra: Pointer;
  Primary: LongInt;

  procedure Stored;
  begin
    n := 0;
    SetLength(H, 16);
    PutVInt(H, n, Len);
    H[n] := 0;
    Inc(n);
    SetLength(Result, n + Len);
    Move(H[0], Result[0], n);
    if Len > 0 then Move(Inp^, Result[n], Len);
  end;

begin
  Result := nil;
  if Len < BWT_MIN_CODED then
  begin
    Stored;
    Exit;
  end;
  UseLzp := False;
  NMain := 0; NLens := 0; Esc := 0;
  SetLength(Main, Len + IN_SLACK);
  MinLen := P.LzpMin;
  if MinLen > 0 then
  begin
    Lp := LzpParamsOf(P, Len, MinLen);
    SetLength(Hash, SizeInt(2) shl LzpBlockHashBits(Len, Lp.HashSizeLog));
    Lens := GetMem(Len);
    UseLzp := LzpEncode(Inp, Len, Lp, Hash, Main, Lens, NMain, NLens, Esc);
    // When the LZP takes away more than LZP_REDO_PCT % of the block with the method's minimum,
    // the data are made of short repeats that the BWT codes better itself (tables, markup,
    // databases): the block is filtered again with 4 times the minimum (adaptive coder only: the
    // second pass costs time that the fast levels do not have)
    if UseLzp and (P.Coder = BWT_CODER_ADAPTIVE) and ((Len - NMain) * 100 > Len * LZP_REDO_PCT) and
       (4 * MinLen <= LZP_MAX_MIN) then
    begin
      MinLen := 4 * MinLen;
      Lp := LzpParamsOf(P, Len, MinLen);
      UseLzp := LzpEncode(Inp, Len, Lp, Hash, Main, Lens, NMain, NLens, Esc);
    end;
    if UseLzp and (NLens > 0) then Move(Lens^, Main[NMain], NLens);
    Hash := nil;
    FreeMem(Lens);
    Lens := nil;
  end;
  if UseLzp then M := NMain + NLens
  else
  begin
    M := Len;
    Move(Inp^, Main[0], Len);
  end;
  if M < 1 then
  begin
    Stored;
    Exit;
  end;
  A := GetMem(SizeInt(M) * SizeOf(LongInt));
  Model := nil;
  Extra := nil;
  try
    Primary := parc_bwt_forward(@Main[0], @Main[0], A, M);
    if Primary < 1 then raise EOutOfMemory.Create('bwt: suffix sorting failed');
    // the coder's output and scratch inside the suffix array when they fit
    OutCap := M;
    Need := 2 * SizeInt(M) + OUT_SLACK;
    if Need <= SizeInt(M) * SizeOf(LongInt) then
    begin
      OutP := A;
      Scratch := PByte(A) + M + OUT_SLACK;
    end
    else
    begin
      Extra := GetMem(Need);
      OutP := Extra;
      Scratch := PByte(Extra) + M + OUT_SLACK;
    end;
    Model := GetMem(parc_qlfc_model_size(P.Coder));
    C := parc_qlfc_encode(@Main[0], OutP, Scratch, M, OutCap, P.Coder, Model);
    FreeMem(Model);
    Model := nil;
    Main := nil;
    // the block record
    if C > 0 then
    begin
      SetLength(H, 64);
      n := 0;
      PutVInt(H, n, Len);
      H[n] := 1; Inc(n);
      Flags := P.Coder;
      if UseLzp then Flags := Flags or 4;
      H[n] := Flags; Inc(n);
      if UseLzp then
      begin
        H[n] := Esc; Inc(n);
        PutVInt(H, n, MinLen);
        PutVInt(H, n, NMain);
        PutVInt(H, n, NLens);
      end;
      PutVInt(H, n, Primary);
      PutVInt(H, n, C);
      if n + C < Len then
      begin
        SetLength(Result, n + C);
        Move(H[0], Result[0], n);
        Move(OutP^, Result[n], C);
      end;
    end;
  finally
    if Model <> nil then FreeMem(Model);
    if Extra <> nil then FreeMem(Extra);
    FreeMem(A);
  end;
  if Result = nil then Stored;
end;

{ ---------------- adaptive blocks (a) ----------------

  A block of mixed data (a solid block of many files: text, tables, binaries) sorts and codes
  worse than its parts coded apart. The cost of a piece of data is estimated with order-1
  statistics (the previous byte as context): cost = sum over contexts of N log2 N - sum over
  (context, symbol) of f log2 f, in bits. Sweeping a cut point through the block moves one
  sample at a time from the right model to the left one, so the cost of every split is known
  in one pass; the best split is taken when it saves more than 1/32 of the cost plus about
  1.5 KB (what the coder spends learning a new model), and both halves are split again the same
  way. To keep it cheap only every SEG_STRIDE-th byte is a sample, and no piece is smaller than
  SEG_MIN. }

const
  SEG_STRIDE = 4;
  SEG_MIN = 128 * 1024;
  SEG_MAX = 64;              // pieces per block
  SEG_PENALTY = 12288.0;     // bits
  SEG_TAB = 65536;

type
  TSegModel = class
    L, R: array of LongInt;         // [ctx * 256 + sym]
    LC, RC: array[0..255] of LongInt;
    constructor Create;
  end;

var
  SegLog: array of Single;           // f log2 f for f < SEG_TAB (read only once built)
  SegD: array of Single;             // (f + 1) log2 (f + 1) - f log2 f for f < SEG_TAB
  SegLogLock: TRTLCriticalSection;

function FLogF(f: LongInt): Double; inline;
begin
  if f < SEG_TAB then Result := SegLog[f]
  else Result := f * Log2(f);
end;

{ FLogF(f + 1) - FLogF(f) }
function DLogF(f: LongInt): Single; inline;
begin
  if f < SEG_TAB then Result := SegD[f]
  else Result := (f + 1) * Log2(f + 1) - f * Log2(f);
end;

procedure BuildSegLog;
var
  i: Integer;
begin
  EnterCriticalSection(SegLogLock);
  try
    if Length(SegLog) = 0 then
    begin
      SetLength(SegD, SEG_TAB);
      SetLength(SegLog, SEG_TAB);
      SegLog[0] := 0;
      for i := 1 to SEG_TAB - 1 do SegLog[i] := i * Log2(i);
      for i := 0 to SEG_TAB - 1 do SegD[i] := (i + 1) * Log2(i + 1) - SegLog[i];
    end;
  finally
    LeaveCriticalSection(SegLogLock);
  end;
end;

constructor TSegModel.Create;
begin
  SetLength(L, 65536);
  SetLength(R, 65536);
  BuildSegLog;
end;

{ Best cut of P[0..n) (a multiple of SEG_STRIDE, SEG_MIN <= cut <= n - SEG_MIN), or 0 }
function SegSplit(M: TSegModel; P: PByte; n: SizeInt): SizeInt;
var
  i, c, k, Best: SizeInt;
  Whole, Cur, BestCost: Double;
  x, y: LongInt;
begin
  Result := 0;
  if n < 2 * SEG_MIN then Exit;
  FillChar(M.L[0], 65536 * SizeOf(LongInt), 0);
  FillChar(M.R[0], 65536 * SizeOf(LongInt), 0);
  FillChar(M.LC, SizeOf(M.LC), 0);
  FillChar(M.RC, SizeOf(M.RC), 0);
  i := SEG_STRIDE;
  while i < n do
  begin
    c := P[i - 1];
    Inc(M.R[c shl 8 + P[i]]);
    Inc(M.RC[c]);
    Inc(i, SEG_STRIDE);
  end;
  Whole := 0;
  for c := 0 to 255 do Whole := Whole + FLogF(M.RC[c]);
  for k := 0 to 65535 do
    if M.R[k] > 1 then Whole := Whole - FLogF(M.R[k]);
  Cur := Whole;
  BestCost := Whole - Whole / 32 - SEG_PENALTY;
  Best := 0;
  i := SEG_STRIDE;
  while i < n - SEG_MIN do
  begin
    if (i >= SEG_MIN) and (Cur < BestCost) then
    begin
      BestCost := Cur;
      Best := i;
    end;
    c := P[i - 1];
    k := c shl 8 + P[i];
    // one sample from the right model to the left one
    x := M.R[k] - 1; M.R[k] := x;
    y := M.L[k]; M.L[k] := y + 1;
    Cur := Cur + DLogF(x) - DLogF(y);
    x := M.RC[c] - 1; M.RC[c] := x;
    y := M.LC[c]; M.LC[c] := y + 1;
    Cur := Cur - DLogF(x) + DLogF(y);
    Inc(i, SEG_STRIDE);
  end;
  Result := Best;
end;

{ Cut points of P[0..n) into Cuts (ascending, ending with n) }
procedure SegSplitAll(M: TSegModel; P: PByte; n: SizeInt; var Cuts: array of SizeInt; var NCuts: Integer;
  Base: SizeInt);
var
  c: SizeInt;
begin
  c := 0;
  if NCuts < SEG_MAX - 1 then c := SegSplit(M, P, n);
  if c = 0 then
  begin
    Cuts[NCuts] := Base + n;
    Inc(NCuts);
    Exit;
  end;
  SegSplitAll(M, P, c, Cuts, NCuts, Base);
  SegSplitAll(M, P + c, n - c, Cuts, NCuts, Base + c);
end;

{ ---------------- encoder stage ---------------- }

type
  TBwtEncJob = class(TParallelJob)
  public
    InBuf: TBytes;
    InLen: SizeInt;
    Par: TBwtParams;
    procedure Process; override;
  end;

procedure TBwtEncJob.Process;
begin
  OutBuf := BwtEncodeBlock(@InBuf[0], InLen, Par);
  OutSize := Length(OutBuf);
  InBuf := nil;
end;

constructor TBwtEncStage.Create(ATarget: TOutStage; const Params: TStringArray);
var
  Threads: Integer;
begin
  FPar := ParseBwtParams(Params);
  inherited Create(ATarget);
  Threads := PoolWorkers(BWT_MAXTHREADS);
  if Threads > 0 then SetLength(FQueue, Threads + 1) else SetLength(FQueue, 1);
  FPool := TJobPool.Create(Threads, Length(FQueue));
end;

destructor TBwtEncStage.Destroy;
var
  i: Integer;
begin
  FPool.Free;
  for i := 0 to FCount - 1 do FQueue[(FHead + i) mod Length(FQueue)].Free;
  FSeg.Free;
  inherited Destroy;
end;

procedure TBwtEncStage.WriteOldest;
var
  Job: TParallelJob;
begin
  Job := FQueue[FHead];
  FHead := (FHead + 1) mod Length(FQueue);
  Dec(FCount);
  try
    FPool.WaitJob(Job);
    if Job.OutSize > 0 then Emit(@Job.OutBuf[0], Job.OutSize);
  finally
    Job.Free;
  end;
end;

procedure TBwtEncStage.SubmitJob(var Data: TBytes; Len: SizeInt);
var
  Job: TBwtEncJob;
  Q: TJobArray;
  i, w: Integer;
  H: TBytes;
  hb: SizeInt;
begin
  if Len = 0 then Exit;
  if not FHeaderDone then
  begin
    FHeaderDone := True;
    SetLength(H, 16);
    H[0] := BWT_STREAM_VERSION;
    hb := 2;
    if FPar.LzpMin > 0 then
    begin
      H[1] := FPar.LzpHash;
      PutVInt(H, hb, FPar.LzpMin);
    end
    else
      H[1] := 0;
    Emit(@H[0], hb);
  end;
  if FCount = Length(FQueue) then
  begin
    // queue full: one more thread and job instead of waiting, if every thread is busy
    w := FPool.MaxWorkers;
    if FPool.CanGrow(BWT_MAXTHREADS) then
    begin
      SetLength(Q, Length(FQueue) + 1);
      for i := 0 to FCount - 1 do Q[i] := FQueue[(FHead + i) mod Length(FQueue)];
      FQueue := Q;
      FHead := 0;
      FPool.SetMaxWorkers(w + 1);
    end
    else
      WriteOldest;
  end
  else if (FCount >= FPool.MaxWorkers) and (BudgetIdle > 0) and FPool.CanGrow(BWT_MAXTHREADS) then
    FPool.SetMaxWorkers(FPool.MaxWorkers + 1);
  Job := TBwtEncJob.Create;
  Job.Par := FPar;
  Job.InBuf := Data;       // the buffer goes to the job, no copy
  Job.InLen := Len;
  Data := nil;
  FQueue[(FHead + FCount) mod Length(FQueue)] := Job;
  Inc(FCount);
  FPool.Submit(Job);
end;

procedure TBwtEncStage.FlushBlock(Final: Boolean);
var
  Cuts: array[0..SEG_MAX - 1] of SizeInt;
  NCuts, k: Integer;
  Prev, Last: SizeInt;
  B: TBytes;
begin
  if FLen = 0 then Exit;
  NCuts := 0;
  if FPar.Adaptive and (FLen >= 2 * SEG_MIN) then
  begin
    if FSeg = nil then FSeg := TSegModel.Create;
    SegSplitAll(TSegModel(FSeg), @FCur[0], FLen, Cuts, NCuts, 0);
  end;
  if NCuts <= 1 then
  begin
    SubmitJob(FCur, FLen);
    FLen := 0;
    Exit;
  end;
  // every piece but the last goes now; without more data coming the last one too, else it
  // stays at the start of the buffer and grows with what follows
  Prev := 0;
  Last := NCuts - 1;
  if Final then Last := NCuts;
  for k := 0 to Last - 1 do
  begin
    B := Copy(FCur, Prev, Cuts[k] - Prev);
    SubmitJob(B, Cuts[k] - Prev);
    Prev := Cuts[k];
  end;
  if Final then
  begin
    FCur := nil;
    FLen := 0;
  end
  else
  begin
    Move(FCur[Prev], FCur[0], FLen - Prev);
    FLen := FLen - Prev;
  end;
end;

procedure TBwtEncStage.DoWrite(Buf: PByte; Count: SizeInt);
var
  k: SizeInt;
begin
  while Count > 0 do
  begin
    if Length(FCur) < FPar.BlockSize then
    begin
      // grow with the data (small inputs do not reserve the whole block)
      k := FLen + Count;
      if k < 64 * 1024 then k := 64 * 1024;
      if k < 2 * Length(FCur) then k := 2 * Length(FCur);
      if k > FPar.BlockSize then k := FPar.BlockSize;
      if k > Length(FCur) then SetLength(FCur, k);
    end;
    k := Length(FCur) - FLen;
    if k > Count then k := Count;
    Move(Buf^, FCur[FLen], k);
    Inc(FLen, k);
    Inc(Buf, k);
    Dec(Count, k);
    if FLen = FPar.BlockSize then FlushBlock(False);
  end;
end;

procedure TBwtEncStage.DoFinish;
begin
  FlushBlock(True);
  while FCount > 0 do WriteOldest;
end;

{ ---------------- decoder ---------------- }

type
  TBwtJob = class(TParallelJob)
  public
    Par: TBwtParams;
    Len, M, NMain, NLens, Primary, DataLen: SizeInt;
    LzpMin: Integer;
    Mode, Flags, Esc: Byte;
    Data: TBytes;
    procedure Process; override;
  end;

procedure TBwtJob.Process;
var
  T, Outp: TBytes;
  A: PLongInt;
  Model: Pointer;
  r: LongInt;
  Lp: TLzpParams;
  Hash: array of LongWord;
begin
  if Mode = 0 then
  begin
    OutBuf := Data;
    OutSize := Len;
    Data := nil;
    Exit;
  end;
  SetLength(T, M);
  Model := GetMem(parc_qlfc_model_size(Flags and 3));
  try
    r := parc_qlfc_decode(@Data[0], DataLen, @T[0], M, Flags and 3, Model);
  finally
    FreeMem(Model);
  end;
  Data := nil;
  if r <> M then Corrupt('bwt: damaged block');
  A := GetMem((SizeInt(M) + 1) * SizeOf(LongInt));
  try
    r := parc_bwt_inverse(@T[0], @T[0], A, M, Primary);
  finally
    FreeMem(A);
  end;
  if r <> 0 then Corrupt('bwt: damaged block (primary index)');
  if Flags and 4 <> 0 then
  begin
    Lp := LzpParamsOf(Par, Len, LzpMin);
    SetLength(Hash, SizeInt(2) shl LzpBlockHashBits(Len, Lp.HashSizeLog));
    SetLength(Outp, Len);
    if not LzpDecodeBlock(@T[0], NMain, @T[NMain], NLens, Esc, @Outp[0], Len, Lp, Lp.HashSizeLog, Hash) then
      Corrupt('bwt: damaged block (LZP)');
    OutBuf := Outp;
  end
  else
    OutBuf := T;
  OutSize := Len;
end;

constructor TBwtStage.Create(ASource: TInStage; const Params: TStringArray);
begin
  // one block read ahead per thread: while one is delivered the others are being decoded
  inherited Create(ASource, BWT_MAXTHREADS, 1);
  try
    FPar := ParseBwtParams(Params);
  except
    on E: EBwtParams do Corrupt(E.Message);
  end;
end;

function TBwtStage.RdByte: Byte;
begin
  Source.ReadExact(@Result, 1);
end;

function TBwtStage.RdVInt: QWord;
var
  b: Byte;
  s: Integer;
begin
  Result := 0;
  s := 0;
  repeat
    b := RdByte;
    if s > 56 then Corrupt('bwt: invalid number');
    Result := Result or (QWord(b and $7F) shl s);
    Inc(s, 7);
  until b and $80 = 0;
end;

function TBwtStage.ReadJob: TParallelJob;
var
  b: Byte;
  Len, NMain, NLens, Primary, DataLen, M, MinL: QWord;
  Job: TBwtJob;
begin
  Result := nil;
  if not FStarted then
  begin
    if not Source.ReadExactOrEof(@b, 1) then Exit;
    if b <> BWT_STREAM_VERSION then Corrupt('bwt: unknown stream version');
    b := RdByte;
    if FPar.LzpMin > 0 then
    begin
      if (b <> FPar.LzpHash) or (RdVInt <> QWord(FPar.LzpMin)) then
        Corrupt('bwt: stream parameters differ from the method');
    end
    else if b <> 0 then Corrupt('bwt: stream parameters differ from the method');
    FStarted := True;
  end;
  if not Source.ReadExactOrEof(@b, 1) then Exit;
  Len := b and $7F;
  if b and $80 <> 0 then Len := Len or (RdVInt shl 7);
  if (Len = 0) or (Len > QWord(FPar.BlockSize)) then Corrupt('bwt: invalid block size');
  Job := TBwtJob.Create;
  try
    Job.Par := FPar;
    Job.Len := Len;
    Job.Mode := RdByte;
    case Job.Mode of
      0:
        begin
          SetLength(Job.Data, Len);
          Source.ReadExact(@Job.Data[0], Len);
        end;
      1:
        begin
          Job.Flags := RdByte;
          if (Job.Flags and not 7 <> 0) or not ((Job.Flags and 3) in [BWT_CODER_STATIC, BWT_CODER_ADAPTIVE]) or
             ((Job.Flags and 4 <> 0) and (FPar.LzpMin = 0)) then Corrupt('bwt: invalid block flags');
          if Job.Flags and 4 <> 0 then
          begin
            Job.Esc := RdByte;
            MinL := RdVInt;
            if (MinL < 8) or (MinL > LZP_MAX_MIN) then Corrupt('bwt: invalid LZP minimum');
            Job.LzpMin := MinL;
            NMain := RdVInt;
            NLens := RdVInt;
            // (every escape takes a main byte and at most 1 + 2 * length / 255 length bytes)
            if (NMain > Len) or (NLens > NMain + 2 * (Len div 255) + 2) then Corrupt('bwt: invalid block');
            M := NMain + NLens;
            if (M = 0) or (M > Len) then Corrupt('bwt: invalid block');
            Job.NMain := NMain;
            Job.NLens := NLens;
          end
          else
            M := Len;
          Job.M := M;
          Primary := RdVInt;
          if (Primary = 0) or (Primary > M) then Corrupt('bwt: invalid primary index');
          Job.Primary := Primary;
          DataLen := RdVInt;
          if DataLen > Len then Corrupt('bwt: invalid block');
          Job.DataLen := DataLen;
          SetLength(Job.Data, DataLen + 1);
          if DataLen > 0 then Source.ReadExact(@Job.Data[0], DataLen);
        end;
    else
      Corrupt('bwt: invalid block mode');
    end;
  except
    Job.Free;
    raise;
  end;
  Result := Job;
end;

initialization
  parc_bwt_set_alloc(@CoreAlloc, @CoreFree);
  InitCriticalSection(SegLogLock);
finalization
  DoneCriticalSection(SegLogLock);
end.
