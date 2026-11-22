{ delta: filter for tables of fixed-size records (PArc's own code, MIT; nothing from FreeArc).

  Binary files often contain runs of fixed-size records whose fields change slowly from one
  record to the next: audio samples, pixels, arrays of offsets or pointers, numeric tables. Such a
  run compresses much better after each field is replaced by its difference with the same field
  of the previous record. The encoder finds those runs and rewrites them in place; the rest of
  the data passes unchanged and the output has the same length as the input plus a small header
  per block.

  Encoder, per block (default 8 MB, `b<mem>`), in 512-byte windows:
   1. Repeat scan (one pass, x86-64 assembler): for each byte, the distance to the previous
      occurrence of its value. A field that repeats or changes slowly shows a peak of distances
      at the record size; text, random data and zero fill do not. A window is a candidate when
      such a peak stands out, or when its bytes change slowly from one to the next (8-bit audio,
      grey images: stride 1 cheaper than stride 2).
   2. Stride test: the window's cost at the peak's divisors and multiples (sum of a magnitude
      cost of p[i] - p[i-N], about the bits a small difference needs) against unrelated control
      strides; the best must cost under 11/16 of the controls.
   3. Extension: the run grows record by record in both directions while a moving average of the
      record cost stays under the halfway point between the two levels, so every byte of a table
      is looked at about once and other bytes almost never. Nearby runs of the same stride are
      joined across short gaps that are not worse than the threshold.
   4. Layout: on a sample of the run (16 KB + 1/32 of it, at most 96 KB) the field layouts are
      tried: 1-, 2- or 4-byte fields, little or big endian, at every alignment inside the record.
      For each field the order-0 entropy of its byte columns (integer fixed point) is estimated
      raw (a byte equal to the one a record back counts as a cheap repeat, as an LZ or context
      model sees it) and differenced with carries inside the field; each field is differenced
      only where that is cheaper, and the run is kept only if it saves 1/32 of the raw estimate.
  Everything is integer arithmetic over the block contents only, so the output is the same on
  every platform and does not depend on the thread count (the stage is single-threaded).

  Stream (version 1, see docs/formato/FORMATO-PARC.md §6.4):
    U8 version (= 1), then blocks until the end of the stream:
      VInt Len (1..2^30), VInt NSeg,
      NSeg x ( VInt Gap (bytes after the previous segment), U8 Stride (1..64),
               VInt Count (records, >= 2), U8 Layout, VInt Mask ),
      zero bytes up to a multiple of 8 bytes from the start of the stream,
      Len bytes of data.
    (The padding keeps the data at the same alignment as in the input: LZ and CM back ends
    use the position modulo 2, 4 or 8 as context.)
    Layout: bits 0-1 = log2 of the field width (1, 2 or 4 bytes; the stride is a multiple),
    bit 2 = big endian; other bits zero. Mask bit f = field f of every record after the first
    holds (field - same field of the previous record) mod 2^(8*width). }
unit parc_delta;

{$mode objfpc}{$H+}
{$R-}{$Q-}
{$pointermath on}

interface

uses
  SysUtils, parc_stream, parc_outstream;

const
  DELTA_STREAM_VERSION = 1;
  DELTA_MAX_STRIDE = 64;           // in the stream
  DELTA_MAX_BLOCK = 1 shl 30;

type
  EDeltaEncParams = class(Exception);

  TDeltaEncParams = record
    BlockSize: LongInt;       // b<mem> or a bare memory size (8mb)
    ExtendedTables: Boolean;  // x: strides up to 64 (default 32)
  end;

  TDeltaSeg = record
    Start: SizeInt;           // offset of the first record in the block
    Stride, Width: Integer;
    BigEndian: Boolean;
    Count: SizeInt;           // records
    Mask: QWord;              // differenced fields
  end;
  TDeltaSegArray = array of TDeltaSeg;

  TDeltaEncStage = class(TOutStage)
  private
    FPar: TDeltaEncParams;
    FBuf: array of Byte;
    FLen: SizeInt;
    FHeaderDone: Boolean;
    FOutPos: QWord;             // stream bytes written (for the header padding)
    procedure FlushBlock;
  protected
    procedure DoWrite(Buf: PByte; Count: SizeInt); override;
    procedure DoFinish; override;
  public
    { Params = the method split on ':' with Params[0] = 'delta' }
    constructor Create(ATarget: TOutStage; const Params: TStringArray);
    constructor Create(ATarget: TOutStage; const APar: TDeltaEncParams);
  end;

  TDeltaStage = class(TInStage)
  private
    FData: array of Byte;
    FLen, FPos: SizeInt;
    FEof, FStarted: Boolean;
    FInPos: QWord;              // stream bytes read (for the header padding)
    function RdByte: Byte;
    function RdVInt: QWord;
    function NextBlock: Boolean;
  public
    function Read(Buf: PByte; Count: SizeInt): SizeInt; override;
  end;

{ Invalid parameters -> EDeltaEncParams }
function ParseDeltaEncParams(const Params: TStringArray): TDeltaEncParams;

{ Finds the tables of Data[0..Len) (the encoder's analysis, exposed for tests). }
function DeltaAnalyze(Data: PByte; Len: SizeInt; const Par: TDeltaEncParams): TDeltaSegArray;
{ Applies (Encode) or undoes the transform of one segment in place. }
procedure DeltaApply(Data: PByte; const S: TDeltaSeg; Encode: Boolean);

implementation

uses
  parc_bytes;

const
  SAMPLE_BYTES = 96 * 1024;     // layout analysis sample per run
  MIN_RUN_BYTES = 256;
  WINDOW = 512;                 // analysis window
  GAIN_DIV = 32;                // a layout must save 1/GAIN_DIV of the estimated raw cost
  DETECT_RATIO = 11;            // best stride under 11/16 of the control strides
  MERGE_GAP = 256;
  BRIDGE_GAP = 8192;
  CONTROL: array[0..8] of Integer = (7, 13, 23, 29, 11, 17, 19, 31, 5);

var
  Ct: array[0..255] of Byte;            // cost of a byte difference (signed magnitude)
  L2: array[0..256] of Word;            // log2(1 + i/256) * 256
  CLogT: array[0..4095] of Int64;       // c * log2(c) * 256

{ log2(x) * 256, x >= 1, integer only (deterministic everywhere) }
function FLog2(x: LongWord): LongWord; inline;
var
  b: Integer;
begin
  b := BsrDWord(x);
  if b >= 8 then Result := LongWord(b) shl 8 + L2[(x shr (b - 8)) and 255]
  else Result := LongWord(b) shl 8 + L2[(x shl (8 - b)) and 255];
end;

{ Entropy of a histogram in 1/256 bits }
procedure InitTables;
var
  i, c, k: Integer;
  m: QWord;
  f: LongWord;
  mm: Integer;
begin
  for i := 0 to 255 do
  begin
    mm := ShortInt(Byte(i));
    if mm < 0 then mm := -mm;
    c := 1;
    while mm > 0 do begin Inc(c); mm := mm shr 1; end;
    Ct[i] := c;      // 0 -> 1, 1 -> 2, 2..3 -> 3, ..., 64..128 -> 8
  end;
  // log2(1 + i/256) by repeated squaring in fixed point (no floating point: same table on
  // every platform)
  for i := 0 to 256 do
  begin
    m := QWord(256 + i) shl 22;      // Q30, value in [1, 2]
    f := 0;
    for k := 1 to 12 do
    begin
      m := (m * m) shr 30;
      f := f shl 1;
      if m >= QWord(1) shl 31 then begin f := f or 1; m := m shr 1; end;
    end;
    if i = 256 then f := 4096;
    L2[i] := (f + 8) shr 4;
  end;
  CLogT[0] := 0;
  for i := 1 to High(CLogT) do CLogT[i] := Int64(i) * FLog2(i);
end;

function CLog(c: LongWord): Int64; inline;
begin
  if c < Length(CLogT) then Result := CLogT[c] else Result := Int64(c) * FLog2(c);
end;

{ CLog(k + 1) - CLog(k) }
function DLog(k: LongWord): Int64; inline;
begin
  if k < High(CLogT) then Result := CLogT[k + 1] - CLogT[k] else Result := CLog(k + 1) - CLog(k);
end;

{ Cost of a two-way choice seen a and b times, in 1/256 bits }
function BinCost(a, b: Int64): Int64;
begin
  Result := 0;
  if (a = 0) or (b = 0) then Exit;
  Result := (a + b) * FLog2(a + b) - a * FLog2(a) - b * FLog2(b);
end;

{ ---------------- parameters ---------------- }

function ParseDeltaEncParams(const Params: TStringArray): TDeltaEncParams;
var
  k: Integer;
  p: string;
  m: QWord;
  ok: Boolean;
begin
  if (Length(Params) = 0) or (Params[0] <> 'delta') then
    raise EDeltaEncParams.Create('delta: not the method delta');
  Result.BlockSize := 8 shl 20;
  Result.ExtendedTables := False;
  for k := 1 to High(Params) do
  begin
    p := Params[k];
    if p = '' then Continue;
    if p = 'x' then begin Result.ExtendedTables := True; Continue; end;
    if p[1] = 'b' then ok := ParseMemSize(Copy(p, 2, MaxInt), m)
    else ok := ParseMemSize(p, m);
    if not ok then raise EDeltaEncParams.CreateFmt('delta: invalid parameter "%s"', [p]);
    if (m = 0) or (m > DELTA_MAX_BLOCK) then
      raise EDeltaEncParams.CreateFmt('delta: invalid block size "%s"', [p]);
    Result.BlockSize := LongInt(m);
  end;
end;

{ ---------------- transform ---------------- }

function LoadField(p: PByte; W: Integer; BE: Boolean): LongWord; inline;
begin
  case W of
    1: Result := p[0];
    2: if BE then Result := (LongWord(p[0]) shl 8) or p[1]
       else Result := LongWord(p[0]) or (LongWord(p[1]) shl 8);
  else
    if BE then Result := (LongWord(p[0]) shl 24) or (LongWord(p[1]) shl 16) or (LongWord(p[2]) shl 8) or p[3]
    else Result := LongWord(p[0]) or (LongWord(p[1]) shl 8) or (LongWord(p[2]) shl 16) or (LongWord(p[3]) shl 24);
  end;
end;

procedure StoreField(p: PByte; W: Integer; BE: Boolean; v: LongWord); inline;
begin
  case W of
    1: p[0] := Byte(v);
    2: if BE then begin p[0] := Byte(v shr 8); p[1] := Byte(v); end
       else begin p[0] := Byte(v); p[1] := Byte(v shr 8); end;
  else
    if BE then begin p[0] := Byte(v shr 24); p[1] := Byte(v shr 16); p[2] := Byte(v shr 8); p[3] := Byte(v); end
    else begin p[0] := Byte(v); p[1] := Byte(v shr 8); p[2] := Byte(v shr 16); p[3] := Byte(v shr 24); end;
  end;
end;

{ Bytes: every byte of a full-mask, 1-byte-field run.  q[i] -/+= q[i-N]. }
procedure ApplyBytes(p: PByte; Len, N: SizeInt; Encode: Boolean);
var
  i: SizeInt;
  a, b: QWord;
const
  H = QWord($8080808080808080);
begin
  if Encode then
  begin
    i := Len - 1;
    if N >= 8 then
      while i - 7 >= N do
      begin
        // 8 bytes at a time, no borrow across lanes (sources not yet modified: i-N+7 < i-7 or equal lanes ahead)
        a := PQWord(p + i - 7)^;
        b := PQWord(p + i - 7 - N)^;
        PQWord(p + i - 7)^ := ((a or H) - (b and not H)) xor ((a xor not b) and H);
        Dec(i, 8);
      end;
    while i >= N do
    begin
      p[i] := Byte(p[i] - p[i - N]);
      Dec(i);
    end;
  end
  else
  begin
    i := N;
    if N >= 8 then
      while i + 8 <= Len do
      begin
        a := PQWord(p + i)^;
        b := PQWord(p + i - N)^;
        PQWord(p + i)^ := ((a and not H) + (b and not H)) xor ((a xor b) and H);
        Inc(i, 8);
      end;
    while i < Len do
    begin
      p[i] := Byte(p[i] + p[i - N]);
      Inc(i);
    end;
  end;
end;

procedure DeltaApply(Data: PByte; const S: TDeltaSeg; Encode: Boolean);
var
  p, r: PByte;
  k, f, NF, Cnt: SizeInt;
  Full: QWord;
  W, N, M: Integer;
  BE: Boolean;
  Offs: array[0..7] of SizeInt;
  o1, o2, o3: SizeInt;
  a0, a1, a2, a3: LongWord;
begin
  N := S.Stride;
  W := S.Width;
  BE := S.BigEndian;
  NF := N div W;
  p := Data + S.Start;
  if NF >= 64 then Full := High(QWord) else Full := (QWord(1) shl NF) - 1;
  if (W = 1) and (S.Mask = Full) and ((N >= 8) or Encode) then
  begin
    ApplyBytes(p, S.Count * N, N, Encode);
    Exit;
  end;
  if Encode then
  begin
    k := S.Count - 1;
    while k >= 1 do
    begin
      r := p + k * N;
      for f := 0 to NF - 1 do
        if (S.Mask shr f) and 1 <> 0 then
          StoreField(r + f * W, W, BE, LoadField(r + f * W, W, BE) - LoadField(r + f * W - N, W, BE));
      Dec(k);
    end;
  end
  else
  begin
    // decoding: the running sums stay in registers for up to four differenced fields
    M := 0;
    for f := 0 to NF - 1 do
      if (S.Mask shr f) and 1 <> 0 then
      begin
        if M < 8 then Offs[M] := f * W;
        Inc(M);
      end;
    Cnt := S.Count;
    if (W = 1) and (M <= 4) then
    begin
      r := p + Offs[0];
      case M of
        1: begin
             a0 := r[0];
             for k := 1 to Cnt - 1 do begin Inc(r, N); a0 := Byte(a0 + r[0]); r[0] := a0; end;
           end;
        2: begin
             o1 := Offs[1] - Offs[0];
             a0 := r[0]; a1 := r[o1];
             for k := 1 to Cnt - 1 do
             begin
               Inc(r, N);
               a0 := Byte(a0 + r[0]); r[0] := a0;
               a1 := Byte(a1 + r[o1]); r[o1] := a1;
             end;
           end;
        3: begin
             o1 := Offs[1] - Offs[0]; o2 := Offs[2] - Offs[0];
             a0 := r[0]; a1 := r[o1]; a2 := r[o2];
             for k := 1 to Cnt - 1 do
             begin
               Inc(r, N);
               a0 := Byte(a0 + r[0]); r[0] := a0;
               a1 := Byte(a1 + r[o1]); r[o1] := a1;
               a2 := Byte(a2 + r[o2]); r[o2] := a2;
             end;
           end;
        4: begin
             o1 := Offs[1] - Offs[0]; o2 := Offs[2] - Offs[0]; o3 := Offs[3] - Offs[0];
             a0 := r[0]; a1 := r[o1]; a2 := r[o2]; a3 := r[o3];
             for k := 1 to Cnt - 1 do
             begin
               Inc(r, N);
               a0 := Byte(a0 + r[0]); r[0] := a0;
               a1 := Byte(a1 + r[o1]); r[o1] := a1;
               a2 := Byte(a2 + r[o2]); r[o2] := a2;
               a3 := Byte(a3 + r[o3]); r[o3] := a3;
             end;
           end;
      end;
    end
    else if (M = 1) and (W = 2) then
    begin
      r := p + Offs[0];
      a0 := LoadField(r, 2, BE);
      for k := 1 to Cnt - 1 do
      begin
        Inc(r, N);
        a0 := a0 + LoadField(r, 2, BE);
        StoreField(r, 2, BE, a0);
      end;
    end
    else if (M = 1) and (W = 4) then
    begin
      r := p + Offs[0];
      a0 := LoadField(r, 4, BE);
      for k := 1 to Cnt - 1 do
      begin
        Inc(r, N);
        a0 := a0 + LoadField(r, 4, BE);
        StoreField(r, 4, BE, a0);
      end;
    end
    else if (M = 2) and (W = 2) then
    begin
      r := p + Offs[0];
      o1 := Offs[1] - Offs[0];
      a0 := LoadField(r, 2, BE);
      a1 := LoadField(r + o1, 2, BE);
      for k := 1 to Cnt - 1 do
      begin
        Inc(r, N);
        a0 := a0 + LoadField(r, 2, BE);
        StoreField(r, 2, BE, a0);
        a1 := a1 + LoadField(r + o1, 2, BE);
        StoreField(r + o1, 2, BE, a1);
      end;
    end
    else
      for k := 1 to Cnt - 1 do
      begin
        r := p + k * N;
        if W = 1 then
        begin
          for f := 0 to NF - 1 do
            if (S.Mask shr f) and 1 <> 0 then r[f] := Byte(r[f] + r[f - N]);
        end
        else
          for f := 0 to NF - 1 do
            if (S.Mask shr f) and 1 <> 0 then
              StoreField(r + f * W, W, BE, LoadField(r + f * W, W, BE) + LoadField(r + f * W - N, W, BE));
      end;
  end;
end;

{ ---------------- analysis ---------------- }

type
  TRun = record
    A, E: SizeInt;
    N: Integer;
  end;

{ Cost of record i (bytes [i, i+N)) against the previous one }
function RecCost(p: PByte; i: SizeInt; N: Integer): LongInt; inline;
var
  j: Integer;
begin
  Result := 0;
  for j := 0 to N - 1 do Inc(Result, Ct[Byte(p[i + j] - p[i + j - N])]);
end;

{ Average record cost (in the phase of the run that starts at A) over the gap [E, B) }
function GapCost(p: PByte; A, E, B: SizeInt; N: Integer): Int64;
var
  i: SizeInt;
  k: Int64;
begin
  Result := 0;
  k := 0;
  i := A + ((E - A) div N) * N;
  while i + N <= B do
  begin
    Inc(Result, RecCost(p, i, N));
    Inc(k);
    Inc(i, N);
  end;
  if k > 0 then Result := Result div k;
end;

function WindowCost(p: PByte; a, e: SizeInt; N: Integer): LongInt;
var
  q, r, qe: PByte;
  T: PByte;
  s0, s1, s2, s3: LongInt;
begin
  q := p + a;
  r := q - N;
  qe := p + e;
  T := @Ct[0];
  s0 := 0; s1 := 0; s2 := 0; s3 := 0;
  while q + 4 <= qe do
  begin
    Inc(s0, T[Byte(q[0] - r[0])]);
    Inc(s1, T[Byte(q[1] - r[1])]);
    Inc(s2, T[Byte(q[2] - r[2])]);
    Inc(s3, T[Byte(q[3] - r[3])]);
    Inc(q, 4);
    Inc(r, 4);
  end;
  while q < qe do
  begin
    Inc(s0, T[Byte(q[0] - r[0])]);
    Inc(q);
    Inc(r);
  end;
  Result := s0 + s1 + s2 + s3;
end;

type
  { State of the repeat-distance scan (pass 1) }
  TRepScan = record
    Q, QE: PByte;
    Last: PLongInt;       // 256 positions
    Hist: PLongInt;       // 4 lanes x 128: Hist[(pos and 3) * 128 + d], d = 0 when out of range
    Pos, Prev, MaxN: LongInt;
  end;

{ For every byte that differs from the one before it: d = distance to the previous occurrence
  of its value; counted when 1 <= d <= MaxN (in one of four lanes chosen by the position, so
  consecutive counts do not wait on each other). A byte equal to the previous one is skipped
  (runs are not tables, and skipping them keeps the scan fast on zero fill). }
{$IF defined(CPUX86_64) and not defined(PARC_NOASM)}
{$ASMMODE INTEL}
procedure RepScan(var S: TRepScan); assembler; nostackframe;
asm
  push   rbx
  push   r12
  push   r13
  push   r14
{$IFDEF WIN64}
  push   rdi
  push   rsi
  mov    rdi, rcx
{$ENDIF}
  mov    r8, qword ptr [rdi + TRepScan.Q]
  mov    r9, qword ptr [rdi + TRepScan.QE]
  mov    r10, qword ptr [rdi + TRepScan.Last]
  mov    r11, qword ptr [rdi + TRepScan.Hist]
  mov    edx, dword ptr [rdi + TRepScan.Pos]
  mov    r13d, dword ptr [rdi + TRepScan.Prev]
  mov    r12d, dword ptr [rdi + TRepScan.MaxN]
  xor    r14d, r14d
  cmp    r8, r9
  jae    @done
@loop:
  movzx  eax, byte ptr [r8]
  cmp    eax, r13d
  je     @next
  mov    r13d, eax
  mov    ecx, edx
  sub    ecx, dword ptr [r10 + rax * 4]
  mov    dword ptr [r10 + rax * 4], edx
  lea    esi, [rcx - 1]
  cmp    esi, r12d
  cmovae ecx, r14d
  mov    ebx, edx
  and    ebx, 3
  shl    ebx, 7
  add    ecx, ebx
  add    dword ptr [r11 + rcx * 4], 1
@next:
  add    r8, 1
  add    edx, 1
  cmp    r8, r9
  jb     @loop
@done:
  mov    dword ptr [rdi + TRepScan.Pos], edx
  mov    dword ptr [rdi + TRepScan.Prev], r13d
  mov    qword ptr [rdi + TRepScan.Q], r8
{$IFDEF WIN64}
  pop    rsi
  pop    rdi
{$ENDIF}
  pop    r14
  pop    r13
  pop    r12
  pop    rbx
end;
{$ELSE}
procedure RepScan(var S: TRepScan);
var
  q, qe: PByte;
  v, d, Pos, Prev: LongInt;
begin
  q := S.Q;
  qe := S.QE;
  Pos := S.Pos;
  Prev := S.Prev;
  while q < qe do
  begin
    v := q^;
    if v <> Prev then
    begin
      Prev := v;
      d := Pos - S.Last[v];
      S.Last[v] := Pos;
      if LongWord(d - 1) >= LongWord(S.MaxN) then d := 0;
      Inc(S.Hist[(Pos and 3) shl 7 + d]);
    end;
    Inc(q);
    Inc(Pos);
  end;
  S.Q := q;
  S.Pos := Pos;
  S.Prev := Prev;
end;
{$ENDIF}

type
  { Sample of a run for the layout search: up to three slices of whole records }
  TSample = record
    A: array[0..2] of SizeInt;       // offset of the first record of each slice
    Recs: array[0..2] of SizeInt;    // records in each slice
    NR: Integer;
  end;

{ Entropy of the byte columns of the sampled records 1.. of each slice, each record taken as
  W-byte fields (W = 1, 2, 4; BE = big endian), either raw (Delta = False) or as differences
  with the previous record. Cnt: N*256 counters, all zero on entry and on exit (only the
  touched ones are reset, so small runs cost little). Raw: a byte equal to the one a record back
  is a repeat that an LZ or context model gets almost for free, so it costs a flag; the others
  cost their column entropy. ColCost[c] in 1/256 bits. }
{ Column counters: entries hold (epoch shl 20) or count, so starting a new count is just a new
  epoch instead of clearing N * 256 entries (small runs cost little) }
type
  TCounters = record
    C: array of LongWord;          // DELTA_MAX_STRIDE * 256
    Epoch: LongWord;
  end;
  PCounters = ^TCounters;

procedure NewEpoch(Cnt: PCounters); inline;
begin
  Inc(Cnt^.Epoch);
  if Cnt^.Epoch >= 4096 then
  begin
    FillChar(Cnt^.C[0], Length(Cnt^.C) * SizeOf(LongWord), 0);
    Cnt^.Epoch := 1;
  end;
end;

procedure ColumnCosts(p: PByte; const Sm: TSample; N, W, Sh: Integer; BE, Delta: Boolean;
  Cnt: PCounters; ColCost: PInt64);
var
  Acc: array[0..DELTA_MAX_STRIDE - 1] of Int64;
  Eq: array[0..DELTA_MAX_STRIDE - 1] of LongWord;
  ri, c, f, NF: Integer;
  k, nr, Tot: SizeInt;
  q: PByte;
  v, e, Ep, EpHi: LongWord;
  idx: SizeInt;
  Cp: PLongWord;

  procedure Bump(i, col: SizeInt); inline;
  begin
    e := Cp[i];
    if e < EpHi then e := EpHi;           // older epoch: count 0
    Cp[i] := e + 1;
    Inc(Acc[col], DLog(e - EpHi));
  end;

begin
  NewEpoch(Cnt);
  Ep := Cnt^.Epoch;
  EpHi := Ep shl 20;
  Cp := @Cnt^.C[0];
  NF := N div W;
  FillChar(Acc, N * SizeOf(Int64), 0);
  FillChar(Eq, N * SizeOf(LongWord), 0);
  Tot := 0;
  for ri := 0 to Sm.NR - 1 do
  begin
    nr := Sm.Recs[ri];
    Inc(Tot, nr - 1);
    for k := 1 to nr - 1 do
    begin
      q := p + Sm.A[ri] + Sh + k * N;
      if not Delta then
      begin
        for c := 0 to N - 1 do
          if q[c] = q[c - N] then Inc(Eq[c])
          else Bump(c * 256 + q[c], c);
      end
      else if W = 1 then
        for c := 0 to N - 1 do Bump(c * 256 + Byte(q[c] - q[c - N]), c)
      else
        for f := 0 to NF - 1 do
        begin
          v := LoadField(q + f * W, W, BE) - LoadField(q + f * W - N, W, BE);
          for c := 0 to W - 1 do
          begin
            if BE then idx := f * W + W - 1 - c else idx := f * W + c;
            Bump(idx * 256 + Byte(v), idx);
            v := v shr 8;
          end;
        end;
    end;
  end;
  for c := 0 to N - 1 do
    if Delta then ColCost[c] := CLog(Tot) - Acc[c]
    else ColCost[c] := CLog(Tot - Eq[c]) - Acc[c] + BinCost(Eq[c], Tot - Eq[c]);
end;

{ Best layout for the run [A, E) of stride N; False if differencing is not worth it. }
function ChooseLayout(p: PByte; const R: TRun; const Par: TDeltaEncParams; Cnt: PCounters;
  out S: TDeltaSeg): Boolean;
var
  N, W, wl, sh, c, f, NF, j, nr: Integer;
  Cnt0, SampleBytes, RunBytes, Want: SizeInt;
  Sm, Sm2: TSample;
  RawC, DelC: array[0..DELTA_MAX_STRIDE - 1] of Int64;
  RawTotal, Best, Tot, Cr, Cd, BestW1, BestW2: Int64;
  BE: Boolean;
  Mask, BestMask: QWord;
  BestW, BestSh, ri: Integer;
  BestBE, Try4LE, Try4BE: Boolean;
  BestBE2: array[Boolean] of Int64;
begin
  Result := False;
  N := R.N;
  Cnt0 := (R.E - R.A) div N;
  if Cnt0 < 4 then Exit;
  RunBytes := Cnt0 * N;
  // sample: the whole run, or three slices (start, middle, end) totalling 16 KB + 1/32 of
  // the run, at most SAMPLE_BYTES; one record of margin for the alignment shift
  Want := 16384 + RunBytes div 32;
  if Want > SAMPLE_BYTES then Want := SAMPLE_BYTES;
  if RunBytes <= Want then
  begin
    Sm.NR := 1;
    Sm.A[0] := R.A; Sm.Recs[0] := Cnt0 - 1;
  end
  else
  begin
    Sm.NR := 3;
    nr := (Want div 3) div N;
    if nr < 4 then nr := 4;
    Sm.A[0] := R.A;
    Sm.A[1] := R.A + ((Cnt0 - nr) div 2) * N;
    Sm.A[2] := R.A + (Cnt0 - 1 - nr) * N;
    for ri := 0 to 2 do Sm.Recs[ri] := nr;
  end;
  SampleBytes := 0;
  for ri := 0 to Sm.NR - 1 do Inc(SampleBytes, Sm.Recs[ri] * N);

  // quick look on at most 4 KB: bytes differenced must show some gain
  if SampleBytes > 6144 then
  begin
    Sm2.NR := 3;
    nr := 1365 div N + 2;
    Sm2.A[0] := R.A;
    Sm2.A[1] := R.A + ((Cnt0 - nr) div 2) * N;
    Sm2.A[2] := R.A + (Cnt0 - 1 - nr) * N;
    for ri := 0 to 2 do Sm2.Recs[ri] := nr;
    ColumnCosts(p, Sm2, N, 1, 0, False, False, Cnt, @RawC[0]);
    ColumnCosts(p, Sm2, N, 1, 0, False, True, Cnt, @DelC[0]);
    Cr := 0; Cd := 0;
    for c := 0 to N - 1 do
    begin
      Inc(Cr, RawC[c]);
      if DelC[c] < RawC[c] then Inc(Cd, DelC[c]) else Inc(Cd, RawC[c]);
    end;
    if (Cr - Cd) * 4 * GAIN_DIV < Cr then Exit;
  end;
  ColumnCosts(p, Sm, N, 1, 0, False, False, Cnt, @RawC[0]);
  RawTotal := 0;
  for c := 0 to N - 1 do Inc(RawTotal, RawC[c]);
  Best := RawTotal;
  BestMask := 0; BestW := 1; BestSh := 0; BestBE := False;
  BestW1 := RawTotal; BestW2 := RawTotal;
  BestBE2[False] := RawTotal; BestBE2[True] := RawTotal;
  Try4LE := True; Try4BE := True;

  for wl := 0 to 2 do
  begin
    W := 1 shl wl;
    if (W > N) or (N mod W <> 0) then Break;
    NF := N div W;
    for j := 0 to Ord(W > 1) do
    begin
      BE := j = 1;
      if (W = 4) and ((BE and not Try4BE) or (not BE and not Try4LE)) then Continue;
      for sh := 0 to W - 1 do
      begin
        ColumnCosts(p, Sm, N, W, sh, BE, True, Cnt, @DelC[0]);
        Tot := 0;
        Mask := 0;
        for f := 0 to NF - 1 do
        begin
          Cr := 0; Cd := 0;
          for c := f * W to f * W + W - 1 do
          begin
            Inc(Cr, RawC[(c + sh) mod N]);
            Inc(Cd, DelC[c]);
          end;
          if Cd < Cr then
          begin
            Inc(Tot, Cd);
            Mask := Mask or (QWord(1) shl f);
          end
          else Inc(Tot, Cr);
        end;
        if (W = 2) and (Tot < BestBE2[BE]) then BestBE2[BE] := Tot;
        if (W = 1) and (Tot < BestW1) then BestW1 := Tot;
        if (W = 2) and (Tot < BestW2) then BestW2 := Tot;
        if (Mask <> 0) and (Tot < Best) then
        begin
          Best := Tot; BestMask := Mask; BestW := W; BestSh := sh; BestBE := BE;
        end;
      end;
    end;
    // bytes alone show no gain: wider fields will not either
    if (wl = 0) and ((RawTotal - Best) * 2 * GAIN_DIV < RawTotal) then Exit;
    // 4-byte fields only where 2-byte fields of that byte order beat single bytes
    if wl = 1 then
    begin
      Try4LE := BestBE2[False] < BestW1;
      Try4BE := BestBE2[True] < BestW1;
    end;
  end;
  if BestMask = 0 then Exit;
  // worth it: at least 1/GainDiv of the raw cost and 48 bytes (header) over the whole run
  if (RawTotal - Best) * GAIN_DIV < RawTotal then Exit;
  if ((RawTotal - Best) div 2048) * (RunBytes div SampleBytes + 1) < 48 then Exit;
  S.Start := R.A + BestSh;
  S.Stride := N;
  S.Width := BestW;
  S.BigEndian := BestBE;
  S.Count := (R.E - S.Start) div N;
  S.Mask := BestMask;
  Result := S.Count >= 2;
end;

function DeltaAnalyze(Data: PByte; Len: SizeInt; const Par: TDeltaEncParams): TDeltaSegArray;
var
  Runs: array of TRun;
  NRuns, NSegs: SizeInt;
  MaxN, N, BestN, HN: Integer;
  Cost: array[1..DELTA_MAX_STRIDE] of LongInt;
  Hist: array[0..DELTA_MAX_STRIDE + 1] of LongInt;
  Last: array[0..255] of LongInt;
  Hist4: array[0..511] of LongInt;
  Sc: TRepScan;
  q, qe: PByte;
  ws, we, a, e, lo, lastGood, cur, i, WLen: SizeInt;
  Cand: Boolean;
  Sum, BestC, T, rc, S1, S2, Pk, Avg: Int64;
  NCtl: Integer;
  Z, SLen: SizeInt;
  Peak: Boolean;
  Seg: TDeltaSeg;
  ri: SizeInt;
  LCnt: TCounters;

  procedure AddSeg(const X: TDeltaSeg);
  begin
    if NSegs = Length(Result) then SetLength(Result, 2 * NSegs + 16);
    Result[NSegs] := X;
    Inc(NSegs);
  end;

begin
  Result := nil;
  MaxN := 32;
  if Par.ExtendedTables then MaxN := 64;
  if Len < 8 * MaxN then Exit;
  Runs := nil;
  NRuns := 0;
  for i := 0 to 255 do Last[i] := -(DELTA_MAX_STRIDE + 1);
  // (positions fit in 32 bits: blocks are at most 1 GB)
  Sc.Last := @Last[0];
  Sc.Hist := @Hist4[0];
  Sc.Prev := -1;
  Sc.MaxN := MaxN;
  ws := MaxN;
  while ws + 4 * MaxN <= Len do
  begin
    we := ws + WINDOW;
    if we > Len then we := Len;
    WLen := we - ws;
    // pass 1: distance to the previous occurrence of each byte value (a field that repeats
    // or changes slowly shows a peak at the record size) and smoothness at stride 1
    for i := 0 to 3 do FillChar(Hist4[i * 128], (MaxN + 1) * SizeOf(LongInt), 0);
    Sc.Q := Data + ws;
    SLen := WLen;
    Sc.QE := Data + ws + SLen;
    Sc.Pos := LongInt(ws);
    RepScan(Sc);
    for N := 1 to MaxN do
      Hist[N] := Hist4[N] + Hist4[128 + N] + Hist4[256 + N] + Hist4[384 + N];
    qe := Data + we;
    // smoothness on every 8th byte
    S1 := 0;
    S2 := 0;
    q := Data + ws;
    Z := 0;
    while q < qe do
    begin
      Inc(S1, Ct[Byte(q[0] - q[-1])]);
      Inc(S2, Ct[Byte(q[0] - q[-2])]);
      Inc(Z, Ord(q[0] = q[-1]));
      Inc(q, 8);
    end;
    S1 := S1 * 8;
    S2 := S2 * 8;
    Z := Z * 2;
    HN := 2;
    for N := 3 to MaxN do
      if Hist[N] > Hist[HN] then HN := N;
    Hist[MaxN + 1] := 0;
    Pk := Hist[HN - 1];
    if Hist[HN + 1] > Pk then Pk := Hist[HN + 1];
    // a peak of repeats at one distance, or values that change slowly from byte to byte
    Peak := (Hist[HN] * 8 >= SLen) and (2 * Hist[HN] >= 3 * Pk);
    Cand := Peak or ((S1 * 8 < S2 * 7) and (S1 * 2 < 11 * WLen) and (Z * 40 < 9 * WLen));
    if Cand then
    begin
      // pass 2: cost of the window at the candidate strides (divisors and multiples of the
      // peak, or the small ones for slowly changing bytes) and at control strides that are
      // unrelated to it (the level of data that is not a table at that stride)
      if not Peak then HN := 12;     // smooth bytes: 1, 2, 3, 4, 6 and 12 (and 24)
      BestN := 0;
      BestC := High(LongInt);
      for N := 1 to MaxN do
        if (HN mod N = 0) or ((N mod HN = 0) and ((N <= 4 * HN) or (HN = 1))) then
        begin
          Cost[N] := WindowCost(Data, ws, we, N);
          if Cost[N] < BestC then begin BestC := Cost[N]; BestN := N; end;
        end;
      // smallest stride within 1/16 of the best (a period's multiples cost the same)
      for N := 1 to BestN - 1 do
        if (BestN mod N = 0) and (Cost[N] <= BestC + BestC div 16) then begin BestN := N; Break; end;
      BestC := Cost[BestN];
      Sum := 0;
      NCtl := 0;
      for i := 0 to High(CONTROL) do
        if (NCtl < 4) and (CONTROL[i] <= MaxN) and (HN mod CONTROL[i] <> 0) and (CONTROL[i] mod HN <> 0) then
        begin
          Inc(Sum, WindowCost(Data, ws, ws + WLen div 2, CONTROL[i]) * 2);
          Inc(NCtl);
        end;
      if NCtl > 0 then Sum := Sum div NCtl
      else
      begin
        // every stride was a candidate: compare with their average
        for N := 1 to MaxN do Inc(Sum, Cost[N]);
        Sum := Sum div MaxN;
      end;
      if BestC * 16 < Sum * DETECT_RATIO then
      begin
        N := BestN;
        // per-record threshold: halfway between the window's cost at this stride and at the
        // control strides (the level of data that is not a table)
        T := ((BestC + Sum) * N) div (2 * WLen);
        // extend backwards (record a becomes the raw first one) and forwards while a moving
        // average of the record cost stays under the threshold; the run ends at the last
        // record that was under it
        lo := 0;
        if NRuns > 0 then lo := Runs[NRuns - 1].E;
        cur := ws;
        lastGood := ws;
        Avg := (BestC * N * 8) div WLen;
        while cur - N >= lo do
        begin
          rc := RecCost(Data, cur, N);
          Dec(cur, N);
          Avg := Avg + rc - Avg div 8;
          if Avg > 8 * T then Break;
          if rc <= T then lastGood := cur;
        end;
        a := lastGood;
        e := ws + (WLen div N) * N;
        lastGood := e;
        Avg := (BestC * N * 8) div WLen;
        while e + N <= Len do
        begin
          rc := RecCost(Data, e, N);
          Inc(e, N);
          Avg := Avg + rc - Avg div 8;
          if Avg > 8 * T then Break;
          if rc <= T then lastGood := e;
        end;
        e := lastGood;
        if e - a >= MIN_RUN_BYTES then
        begin
          if (NRuns > 0) and (Runs[NRuns - 1].N = N) and ((a <= Runs[NRuns - 1].E + MERGE_GAP) or
             ((a <= Runs[NRuns - 1].E + BRIDGE_GAP) and
              (GapCost(Data, Runs[NRuns - 1].A, Runs[NRuns - 1].E, a, N) <= T))) then
            // continues the previous run (across a short gap, in its record phase)
            Runs[NRuns - 1].E := Runs[NRuns - 1].A + ((e - Runs[NRuns - 1].A) div N) * N
          else
          begin
            if NRuns = Length(Runs) then SetLength(Runs, 2 * NRuns + 16);
            Runs[NRuns].A := a; Runs[NRuns].E := e; Runs[NRuns].N := N;
            Inc(NRuns);
          end;
          if e > we then
          begin
            ws := e;
            Continue;
          end;
        end;
      end;
    end;
    ws := we;
  end;
  // layouts
  Result := nil;
  NSegs := 0;
  if NRuns > 0 then
  begin
    SetLength(LCnt.C, DELTA_MAX_STRIDE * 256);   // zeroed
    LCnt.Epoch := 0;
  end;
  for ri := 0 to NRuns - 1 do
    if ChooseLayout(Data, Runs[ri], Par, @LCnt, Seg) then AddSeg(Seg);
  SetLength(Result, NSegs);
end;

{ ---------------- encoder stage ---------------- }

procedure PutVInt(var B: TBytes; var n: SizeInt; V: QWord);
begin
  if n + 10 > Length(B) then SetLength(B, 2 * Length(B) + 64);
  while V >= $80 do
  begin
    B[n] := Byte(V) or $80;
    Inc(n);
    V := V shr 7;
  end;
  B[n] := Byte(V);
  Inc(n);
end;

constructor TDeltaEncStage.Create(ATarget: TOutStage; const Params: TStringArray);
begin
  Create(ATarget, ParseDeltaEncParams(Params));
end;

constructor TDeltaEncStage.Create(ATarget: TOutStage; const APar: TDeltaEncParams);
begin
  inherited Create(ATarget);
  FPar := APar;
end;

procedure TDeltaEncStage.FlushBlock;
var
  Segs: TDeltaSegArray;
  H: TBytes;
  n, Prev, i: SizeInt;
  wl: Integer;
begin
  if FLen = 0 then Exit;
  Segs := DeltaAnalyze(@FBuf[0], FLen, FPar);
  SetLength(H, 64 + 32 * Length(Segs));
  n := 0;
  if not FHeaderDone then
  begin
    H[0] := DELTA_STREAM_VERSION;
    n := 1;
    FHeaderDone := True;
  end;
  PutVInt(H, n, FLen);
  PutVInt(H, n, Length(Segs));
  Prev := 0;
  for i := 0 to High(Segs) do
    with Segs[i] do
    begin
      PutVInt(H, n, Start - Prev);
      if n + 2 > Length(H) then SetLength(H, 2 * Length(H));
      H[n] := Stride; Inc(n);
      PutVInt(H, n, Count);
      if Width = 1 then wl := 0 else if Width = 2 then wl := 1 else wl := 2;
      if n + 2 > Length(H) then SetLength(H, 2 * Length(H));
      H[n] := wl or (Ord(BigEndian) shl 2); Inc(n);
      PutVInt(H, n, Mask);
      Prev := Start + Count * Stride;
      DeltaApply(@FBuf[0], Segs[i], True);
    end;
  if n + 8 > Length(H) then SetLength(H, n + 8);
  while (FOutPos + QWord(n)) and 7 <> 0 do
  begin
    H[n] := 0;
    Inc(n);
  end;
  Emit(@H[0], n);
  Emit(@FBuf[0], FLen);
  Inc(FOutPos, QWord(n) + QWord(FLen));
  FLen := 0;
end;

procedure TDeltaEncStage.DoWrite(Buf: PByte; Count: SizeInt);
var
  k: SizeInt;
begin
  while Count > 0 do
  begin
    if Length(FBuf) < FPar.BlockSize then
    begin
      // grow with the data (small inputs do not reserve the whole block)
      k := FLen + Count;
      if k < 64 * 1024 then k := 64 * 1024;
      if k < 2 * Length(FBuf) then k := 2 * Length(FBuf);
      if k > FPar.BlockSize then k := FPar.BlockSize;
      if k > Length(FBuf) then SetLength(FBuf, k);
    end;
    k := Length(FBuf) - FLen;
    if k > Count then k := Count;
    Move(Buf^, FBuf[FLen], k);
    Inc(FLen, k);
    Inc(Buf, k);
    Dec(Count, k);
    if FLen = FPar.BlockSize then FlushBlock;
  end;
end;

procedure TDeltaEncStage.DoFinish;
begin
  FlushBlock;
end;

{ ---------------- decoder stage ---------------- }

function TDeltaStage.RdByte: Byte;
begin
  Source.ReadExact(@Result, 1);
  Inc(FInPos);
end;

function TDeltaStage.RdVInt: QWord;
var
  b: Byte;
  Sh: Integer;
begin
  Result := 0;
  Sh := 0;
  repeat
    b := RdByte;
    if (Sh = 63) and (b > 1) then Corrupt('delta: invalid number');
    Result := Result or (QWord(b and $7F) shl Sh);
    Inc(Sh, 7);
    if (b and $80 <> 0) and (Sh > 63) then Corrupt('delta: invalid number');
  until b and $80 = 0;
end;

function TDeltaStage.NextBlock: Boolean;
var
  b: Byte;
  Len, NSeg, Gap, Pos, i, Cnt: QWord;
  Segs: TDeltaSegArray;
  St, Lay: Byte;
  W, NF: Integer;
  Mask: QWord;
  Got, Need: SizeInt;
begin
  if not Source.ReadExactOrEof(@b, 1) then Exit(False);
  Inc(FInPos);
  if not FStarted then
  begin
    if b <> DELTA_STREAM_VERSION then Corrupt('delta: unknown stream version');
    FStarted := True;
    b := RdByte;
  end;
  // b = first byte of the block length
  Len := b and $7F;
  if b and $80 <> 0 then
  begin
    i := RdVInt;
    if i > (QWord(DELTA_MAX_BLOCK) shr 7) then Corrupt('delta: block too large');
    Len := Len or (i shl 7);
  end;
  if (Len = 0) or (Len > DELTA_MAX_BLOCK) then Corrupt('delta: invalid block size');
  NSeg := RdVInt;
  if NSeg > Len div 2 then Corrupt('delta: too many segments');
  Segs := nil;
  Pos := 0;
  i := 0;
  while i < NSeg do
  begin
    Gap := RdVInt;
    St := RdByte;
    Cnt := RdVInt;
    Lay := RdByte;
    Mask := RdVInt;
    if (St = 0) or (St > DELTA_MAX_STRIDE) or (Lay and not 7 <> 0) or ((Lay and 3) = 3) then
      Corrupt('delta: invalid segment');
    W := 1 shl (Lay and 3);
    if (St mod W <> 0) or ((W = 1) and (Lay and 4 <> 0)) then Corrupt('delta: invalid segment');
    NF := St div W;
    if (Mask = 0) or ((NF < 64) and (Mask shr NF <> 0)) then Corrupt('delta: invalid segment');
    if (Cnt < 2) or (Gap > Len) or (Cnt > Len) then Corrupt('delta: segment outside block');
    Inc(Pos, Gap);
    if i >= QWord(Length(Segs)) then SetLength(Segs, 2 * Length(Segs) + 16);
    if (Pos > Len) or (Cnt * St > Len - Pos) then Corrupt('delta: segment outside block');
    Segs[i].Start := Pos;
    Segs[i].Stride := St;
    Segs[i].Width := W;
    Segs[i].BigEndian := Lay and 4 <> 0;
    Segs[i].Count := Cnt;
    Segs[i].Mask := Mask;
    Inc(Pos, Cnt * St);
    Inc(i);
  end;
  // zero padding: the data starts at a multiple of 8 in the stream
  while FInPos and 7 <> 0 do
    if RdByte <> 0 then Corrupt('delta: invalid header padding');
  // the buffer grows as the data arrives: a damaged length must not reserve 1 GB up front
  Got := 0;
  while Got < SizeInt(Len) do
  begin
    Need := 2 * Got;
    if Need < 1 shl 20 then Need := 1 shl 20;
    if Need > SizeInt(Len) then Need := Len;
    if Need > Length(FData) then SetLength(FData, Need);
    Source.ReadExact(@FData[Got], Need - Got);
    Got := Need;
  end;
  Inc(FInPos, Len);
  i := 0;
  while i < NSeg do begin DeltaApply(@FData[0], Segs[i], False); Inc(i); end;
  FLen := Len;
  FPos := 0;
  Result := True;
end;

function TDeltaStage.Read(Buf: PByte; Count: SizeInt): SizeInt;
begin
  while FPos >= FLen do
  begin
    if FEof then Exit(0);
    if not NextBlock then
    begin
      FEof := True;
      Exit(0);
    end;
  end;
  Result := FLen - FPos;
  if Result > Count then Result := Count;
  Move(FData[FPos], Buf^, Result);
  Inc(FPos, Result);
end;

initialization
  InitTables;
end.
