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
           [LZP: U8 escape, VInt NMain, VInt NLens], VInt Primary, VInt CodedLen, CodedLen
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
    procedure SubmitBlock;
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

{ The C core's primitives, for tests: forward/inverse BWT and QLFC on whole buffers. }
function BwtForward(T, U: PByte; A: PLongInt; n: LongInt): LongInt;
function BwtInverse(T, U: PByte; A: PLongInt; n, Primary: LongInt): LongInt;

implementation

uses
  parc_bytes;

{$L bwt_core.o}

type
  TBwtAllocFn = function(Size: SizeUInt): Pointer; cdecl;
  TBwtFreeFn = procedure(P: Pointer); cdecl;

procedure parc_bwt_set_alloc(a: TBwtAllocFn; f: TBwtFreeFn); cdecl; external name 'parc_bwt_set_alloc';
function parc_bwt_forward(T, U: PByte; A: PLongInt; n: LongInt): LongInt; cdecl; external name 'parc_bwt_forward';
function parc_bwt_inverse(T, U: PByte; A: PLongInt; n, primary: LongInt): LongInt; cdecl; external name 'parc_bwt_inverse';
function parc_qlfc_model_size(coder: LongInt): LongInt; cdecl; external name 'parc_qlfc_model_size';
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
        'a', 's', 'd', 'p': if r <> '' then raise EBwtParams.CreateFmt('bwt: invalid parameter "%s"', [p]);
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
end;

function LzpParamsOf(const P: TBwtParams; BlockSize: SizeInt): TLzpParams;
begin
  Result.BlockSize := BlockSize;
  Result.MinMatchLen := P.LzpMin;
  Result.SmallestLen := P.LzpMin;
  Result.HashSizeLog := P.LzpHash;
  Result.Barrier := LZP_MAX_BLOCK;
  LzpNormalize(Result);
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
  Main, Lens: TBytes;
  Esc, Flags: Byte;
  UseLzp: Boolean;
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
  if P.LzpMin > 0 then
  begin
    Lp := LzpParamsOf(P, Len);
    SetLength(Hash, SizeInt(2) shl LzpBlockHashBits(Len, Lp.HashSizeLog));
    if LzpEncodeBlock(Inp, Len, Lp, Hash, Main, Lens, NMain, NLens, Esc) then
    begin
      UseLzp := True;
      if NLens > 0 then Move(Lens[0], Main[NMain], NLens);
    end;
    Hash := nil;
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

procedure TBwtEncStage.SubmitBlock;
var
  Job: TBwtEncJob;
  Q: TJobArray;
  i, w: Integer;
  H: TBytes;
  hb: SizeInt;
begin
  if FLen = 0 then Exit;
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
  Job.InBuf := FCur;       // the filled block goes to the job, no copy
  Job.InLen := FLen;
  FCur := nil;
  FLen := 0;
  FQueue[(FHead + FCount) mod Length(FQueue)] := Job;
  Inc(FCount);
  FPool.Submit(Job);
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
    if FLen = FPar.BlockSize then SubmitBlock;
  end;
end;

procedure TBwtEncStage.DoFinish;
begin
  SubmitBlock;
  while FCount > 0 do WriteOldest;
end;

{ ---------------- decoder ---------------- }

type
  TBwtJob = class(TParallelJob)
  public
    Par: TBwtParams;
    Len, M, NMain, NLens, Primary, DataLen: SizeInt;
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
    Lp := LzpParamsOf(Par, Len);
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
  Len, NMain, NLens, Primary, DataLen, M: QWord;
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
end.
