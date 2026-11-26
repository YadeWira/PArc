{ Data type of a chunk for the file grouping: '$compressed', '$text' or 'default'.

  PArc's own detector (2026-11, MIT; nothing from FreeArc). It answers the question the
  grouping asks: which family of chains suits these bytes?
    - '$compressed': nothing to gain (order-0 entropy near 8 bits, few byte pairs repeated
      within 256 bytes): the fast chains of $compressed;
    - '$text': a context model (the $text chains: ppmd, bwt, cm) should beat an LZ coder;
    - 'default' otherwise (the LZ chains with filters).
  Statistics (integers only):
    1. whole chunk: byte histogram -> order-0 entropy H0 and the share of letters;
    2. a sample of up to SAMPLE_MAX bytes from the middle. Above 7.6 bits only the byte pairs
       seen again within 256 bytes; below: order-1 entropy H1 (pair counts), how often the
       byte that followed the same 3 (5) bytes last time comes again (a cheap measure of what
       high-order contexts predict) and the share of bytes a greedy LZ parse (4-byte hash)
       covers with matches.
  '$text' is a linear score of those numbers above a threshold, fitted on 5,800 chunks of the
  sample corpus against the real sizes of the -m5 chains ($text = dict+lzp+ppmd:13, default =
  orep+exe+delta+lzma bt4), with the share of chunks sent to ppmd (which decompresses several
  times slower than lzma) held at what the previous detector sent. Every platform gives the
  same answer (fixed-point logarithms from an integer algorithm). }
unit parc_filetype;

{$mode objfpc}{$H+}
{$R-}{$Q-}
{$pointermath on}

interface

type
  TDatatypeStats = record
    Size: Integer;
    H0: Integer;          // order-0 entropy of the chunk, 1/256 bit per byte
    Letters: Integer;     // letters per 1024 bytes of the chunk
    Spaces: Integer;      // space, tab, CR, LF per 1024 bytes of the chunk
    Controls: Integer;    // other bytes below 32 (and 127) per 1024 bytes of the chunk
    Sample: Integer;      // bytes of the sample
    H1: Integer;          // order-1 entropy of the sample (pair counts), 1/256 bit per byte
    Hit3, Hit5: Integer;  // next byte as after the same 3 / 5 bytes last time, per 1024
    MatchBytes: Integer;  // bytes in LZ matches, per 1024
    NearPairs: Integer;   // pairs seen again within 256 bytes, per 1024 (only H0 >= 7.6 bits)
  end;

{ Type of Buf[0..BufSize-1] for the preset level Level (1..9; the bias towards '$text' can
  depend on the level's chains). With Buf = nil: the list of types it can answer. }
function DetectDatatype(Buf: PByte; BufSize: Integer; Level: Integer = 5): string;

{ The statistics behind the answer (tests, tuning), and the answer from them. }
function DatatypeStats(Buf: PByte; BufSize: Integer): TDatatypeStats;
function DatatypeOfStats(const S: TDatatypeStats; Level: Integer = 5): string;

implementation

uses
  SysUtils;

const
  SAMPLE_MAX = 16384;
  LOG_ONE = 256;                    // fixed point of the logarithms
  LOG_TABLE = 1 shl 17;             // LogTab covers 0..LOG_TABLE-1
  HASH_BITS = 12;
  CTX_BITS = 13;

  // '$compressed': H0 >= 7.62 bits and at most 11 % of the pairs repeated within 256 bytes
  COMPRESSED_H0 = 1951;
  COMPRESSED_NEAR = 115;
  // '$text': W_* . stats > TEXT_BIAS (weights per unit of each field), only below 7.6 bits
  TEXT_MAX_H0 = 1946;
  {$I parc_filetype_weights.inc}

type
  { Working tables of one call (from a small pool: detection runs on several threads) }
  PTables = ^TTables;
  TTables = record
    C1: array[0..65535] of Word;              // pair counts (all 0 between calls)
    Touched: array[0..SAMPLE_MAX] of Word;    // the cells of C1 in use
    LzHead: array[0..(1 shl HASH_BITS) - 1] of LongInt;
    NearPos: array[0..65535] of LongWord;     // Gen shl 16 + last position + 1 of each pair
    Gen: LongWord;
    Last3, Last5: array[0..(1 shl CTX_BITS) - 1] of Byte;
    Next: PTables;
  end;

var
  LogTab: array of Integer;        // LogTab[x] = round(256 * log2(x)), LogTab[0] = 0
  Pool: PTables = nil;
  PoolLock: TRTLCriticalSection;

{ ------------------------------------------------------------------------------------------ }

{ 256 * log2(x) for x >= 1, rounded, by repeated squaring of the mantissa (integers only). }
function FixLog2(x: QWord): Integer;
var
  k, i, r: Integer;
  m: QWord;      // mantissa in [1, 2) as Q30
begin
  k := 0;
  while (x shr (k + 1)) <> 0 do Inc(k);
  if k >= 30 then m := x shr (k - 30) else m := x shl (30 - k);
  r := 0;
  for i := 1 to 9 do      // 9 fraction bits, rounded to 8
  begin
    m := (m * m) shr 30;
    r := r shl 1;
    if m >= (QWord(2) shl 30) then
    begin
      m := m shr 1;
      r := r or 1;
    end;
  end;
  Result := k * LOG_ONE + (r + 1) shr 1;
end;

function L2(x: QWord): Integer; inline;
begin
  if x < LOG_TABLE then Result := LogTab[x] else Result := FixLog2(x);
end;

procedure BuildLogTable;
var
  i: Integer;
begin
  SetLength(LogTab, LOG_TABLE);
  LogTab[0] := 0;
  for i := 1 to LOG_TABLE - 1 do LogTab[i] := FixLog2(i);
end;

function TakeTables: PTables;
begin
  EnterCriticalSection(PoolLock);
  Result := Pool;
  if Result <> nil then Pool := Result^.Next;
  LeaveCriticalSection(PoolLock);
  if Result = nil then
  begin
    New(Result);
    FillChar(Result^.C1, SizeOf(Result^.C1), 0);
    FillChar(Result^.NearPos, SizeOf(Result^.NearPos), 0);
    Result^.Gen := 0;
  end;
end;

procedure GiveTables(T: PTables);
begin
  EnterCriticalSection(PoolLock);
  T^.Next := Pool;
  Pool := T;
  LeaveCriticalSection(PoolLock);
end;

{ ------------------------------------------------------------------------------------------ }

{ Bytes of P[0..N-1] that a greedy LZ parse covers with matches of 4+ bytes (4-byte hash,
  last position only). }
function MatchCover(T: PTables; P: PByte; N: Integer): Integer;
var
  i, j, Len: Integer;
  h, v: LongWord;
begin
  FillChar(T^.LzHead, SizeOf(T^.LzHead), $FF);
  Result := 0;
  i := 0;
  while i + 4 <= N do
  begin
    v := PLongWord(P + i)^;
    h := LongWord(v * LongWord(2654435761)) shr (32 - HASH_BITS);
    j := T^.LzHead[h];
    T^.LzHead[h] := i;
    if (j >= 0) and (PLongWord(P + j)^ = v) then
    begin
      Len := 4;
      while (i + Len < N) and (P[j + Len] = P[i + Len]) do Inc(Len);
      Inc(Result, Len);
      Inc(i, Len);
    end
    else
      Inc(i);
  end;
end;

function DatatypeStats(Buf: PByte; BufSize: Integer): TDatatypeStats;
var
  T: PTables;
  Hist: array[0..3, 0..255] of LongInt;
  Row: array[0..255] of LongInt;
  i, Letters, Near, n, Cell, h3, h5, NT: Integer;
  S: PByte;
  Acc: Int64;
  v, Stamp, c3, c5: LongWord;
  w: Word;
begin
  Result := Default(TDatatypeStats);
  Result.Size := BufSize;
  if (Buf = nil) or (BufSize <= 0) then Exit;
  // whole chunk: histogram (four tables, so that runs of a byte do not stall)
  FillChar(Hist, SizeOf(Hist), 0);
  i := 0;
  while i + 4 <= BufSize do
  begin
    Inc(Hist[0, Buf[i]]); Inc(Hist[1, Buf[i + 1]]); Inc(Hist[2, Buf[i + 2]]); Inc(Hist[3, Buf[i + 3]]);
    Inc(i, 4);
  end;
  while i < BufSize do
  begin
    Inc(Hist[0, Buf[i]]);
    Inc(i);
  end;
  Acc := Int64(BufSize) * L2(BufSize);
  for i := 0 to 255 do
  begin
    n := Hist[0, i] + Hist[1, i] + Hist[2, i] + Hist[3, i];
    Hist[0, i] := n;
    if n > 0 then Dec(Acc, Int64(n) * L2(n));
  end;
  Result.H0 := Acc div BufSize;
  Letters := 0;
  for i := Ord('A') to Ord('Z') do Inc(Letters, Hist[0, i] + Hist[0, i + 32]);
  Result.Letters := Int64(Letters) * 1024 div BufSize;
  n := Hist[0, 9] + Hist[0, 10] + Hist[0, 13] + Hist[0, 32];
  Result.Spaces := Int64(n) * 1024 div BufSize;
  n := Hist[0, 127] - Hist[0, 9] - Hist[0, 10] - Hist[0, 13];
  for i := 0 to 31 do Inc(n, Hist[0, i]);
  Result.Controls := Int64(n) * 1024 div BufSize;
  // the sample, from the middle
  n := BufSize;
  if n > SAMPLE_MAX then n := SAMPLE_MAX;
  Result.Sample := n;
  S := Buf + (BufSize - n) div 2;
  T := TakeTables;
  try
    if Result.H0 >= TEXT_MAX_H0 then
    begin
      // only the "$compressed" question is left: pairs repeated within 256 bytes
      Inc(T^.Gen);
      if T^.Gen > $FFFF then
      begin
        FillChar(T^.NearPos, SizeOf(T^.NearPos), 0);
        T^.Gen := 1;
      end;
      Stamp := T^.Gen shl 16;
      Near := 0;
      for i := 1 to n - 1 do
      begin
        w := S[i - 1] shl 8 or S[i];
        v := T^.NearPos[w];
        if (v and $FFFF0000 = Stamp) and (LongWord(i + 1) - (v and $FFFF) < 256) then Inc(Near);
        T^.NearPos[w] := Stamp or LongWord(i + 1);
      end;
      if n > 1 then Result.NearPairs := Int64(Near) * 1024 div (n - 1);
      Exit;
    end;
    FillChar(T^.Last3, SizeOf(T^.Last3), 0);
    FillChar(T^.Last5, SizeOf(T^.Last5), 0);
    h3 := 0; h5 := 0; NT := 0;
    for i := 1 to n - 1 do
    begin
      // pair counts (order-1 entropy)
      w := S[i - 1] shl 8 or S[i];
      if T^.C1[w] = 0 then
      begin
        T^.Touched[NT] := w;
        Inc(NT);
      end;
      Inc(T^.C1[w]);
      // the byte that followed the same 3 / 5 bytes last time
      if i >= 5 then
      begin
        c3 := LongWord((LongWord(S[i - 3]) or LongWord(S[i - 2]) shl 8 or LongWord(S[i - 1]) shl 16) *
          LongWord(2654435761)) shr (32 - CTX_BITS);
        c5 := LongWord(((LongWord(S[i - 4]) or LongWord(S[i - 3]) shl 8 or LongWord(S[i - 2]) shl 16 or
          LongWord(S[i - 1]) shl 24) xor (LongWord(S[i - 5]) shl 13)) * LongWord(2246822519)) shr (32 - CTX_BITS);
        if T^.Last3[c3] = S[i] then Inc(h3);
        if T^.Last5[c5] = S[i] then Inc(h5);
        T^.Last3[c3] := S[i];
        T^.Last5[c5] := S[i];
      end;
    end;
    if n > 1 then
    begin
      // H(X1 | X0) = (sum_rows r*log r - sum_cells c*log c) / pairs
      FillChar(Row, SizeOf(Row), 0);
      Acc := 0;
      for i := 0 to NT - 1 do
      begin
        Cell := T^.Touched[i];
        Inc(Row[Cell shr 8], T^.C1[Cell]);
        Dec(Acc, Int64(T^.C1[Cell]) * L2(T^.C1[Cell]));
        T^.C1[Cell] := 0;
      end;
      for i := 0 to 255 do
        if Row[i] > 0 then Inc(Acc, Int64(Row[i]) * L2(Row[i]));
      Result.H1 := Acc div (n - 1);
    end;
    if n > 5 then
    begin
      Result.Hit3 := Int64(h3) * 1024 div (n - 5);
      Result.Hit5 := Int64(h5) * 1024 div (n - 5);
    end;
    Result.MatchBytes := Int64(MatchCover(T, S, n)) * 1024 div n;
  finally
    GiveTables(T);
  end;
end;

function DatatypeOfStats(const S: TDatatypeStats; Level: Integer): string;
var
  Score: Int64;
begin
  Result := 'default';
  if S.Size < 16 then Exit;
  if (S.H0 >= COMPRESSED_H0) and (S.NearPairs <= COMPRESSED_NEAR) then Exit('$compressed');
  if S.H0 >= TEXT_MAX_H0 then Exit;
  Score := Int64(W_H0) * S.H0 + Int64(W_H1) * S.H1 + Int64(W_LETTERS) * S.Letters +
    Int64(W_HIT3) * S.Hit3 + Int64(W_HIT5) * S.Hit5 + Int64(W_MATCH) * S.MatchBytes +
    Int64(W_SPACES) * S.Spaces + Int64(W_CONTROLS) * S.Controls;
  if S.Letters > TEXT_LETTER_STEP then Inc(Score, W_LETTER_STEP);
  if Level < 1 then Level := 1;
  if Level > 9 then Level := 9;
  if Score > TEXT_BIAS + TEXT_LEVEL_BIAS[Level] then Result := '$text';
end;

function DetectDatatype(Buf: PByte; BufSize: Integer; Level: Integer): string;
begin
  if Buf = nil then Exit('$compressed $text');
  Result := DatatypeOfStats(DatatypeStats(Buf, BufSize), Level);
end;

procedure FreePool;
var
  T: PTables;
begin
  while Pool <> nil do
  begin
    T := Pool;
    Pool := T^.Next;
    Dispose(T);
  end;
end;

initialization
  InitCriticalSection(PoolLock);
  BuildLogTable;
finalization
  FreePool;
  DoneCriticalSection(PoolLock);
end.
