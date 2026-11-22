{ lzp: long-repeat filter in front of PPMd/BWT/CM (PArc's own code, MIT; nothing from FreeArc).

  LZP (Bloom, 1996) predicts that the text following a context continues as it did after the
  previous occurrence of that context. A table indexed by a hash of the last K bytes holds the
  position that followed the context last time; at each position the encoder compares the data
  there with the data at the predicted position and, when they agree for at least the minimum
  length, replaces the repeat by an escape byte and its length. Nothing is sent for the
  prediction itself: the decoder keeps the same table. Context models (PPMd, CM) and BWT code long
  repeats poorly and slowly; removing them first makes the back end faster and usually smaller.

  Design (not FreeArc's stream):
   - the context is the last 4 bytes, hashed into 2^h buckets (h at most 1 + log2 of the block)
     of two positions, the most recent first: both candidates are compared and the longer match
     (beyond its minimum) wins; one bit in the length says which. The table is cleared per
     block and positions are block offsets (blocks up to 1 GB);
   - minimum length: `l` (MinMatchLen), or `s` (SmallestLen) for a repeat that starts more than
     `d` (Barrier) bytes back: close repeats are left to the back end, whose high-order
     contexts already predict them well, far ones are taken shorter;
   - the escape is the least frequent byte value of each block (often absent from text, so a
     literal escape is rare), stored in the block header;
   - the main stream holds the literals and one escape per match; the lengths go to a separate
     stream after it (0 = the escape was a literal, else 2 * (length - minimum) + 1 + candidate,
     in bytes of 255 plus a last byte < 255), so the back end sees plain text with an
     occasional escape;
   - matches are compared 8 bytes at a time; the encoder computes and prefetches the table slots
     8 positions ahead, the decoder writes literals 8 at a time with their 8 slots computed
     together, so the table's cache misses overlap.
  Everything is integer arithmetic on the block, single-threaded: the output does not depend on
  the platform or the thread count.

  Stream (version 1, docs/formato/FORMATO-PARC.md §6.5):
    U8 version (1), U8 context bytes (4), U8 hash bits, VInt MinMatchLen, VInt SmallestLen,
    VInt Barrier (all must equal the method's, after the limits of Normalize); then blocks until
    the end of the stream:
      VInt Len (1..block size), U8 mode: 0 = stored (Len bytes follow);
      1 = coded: U8 escape, VInt NMain, VInt NLens, NMain bytes, NLens bytes. }
unit parc_lzp;

{$mode objfpc}{$H+}
{$R-}{$Q-}
{$pointermath on}

interface

uses
  SysUtils, parc_stream, parc_outstream;

const
  LZP_STREAM_VERSION = 1;
  LZP_MAX_BLOCK = 1 shl 30;
  LZP_MAX_HASH_BITS = 26;

type
  TLzpParams = record
    BlockSize: SizeInt;
    MinMatchLen, HashSizeLog, SmallestLen: Integer;
    Barrier: Int64;
  end;

  { Decoder }
  TLzpStage = class(TInStage)
  private
    FPar: TLzpParams;
    FK, FHashBits: Integer;
    FIn, FOut: array of Byte;
    FHash: array of LongWord;
    FLen, FPos: SizeInt;
    FEof, FStarted: Boolean;
    function RdByte: Byte;
    function RdVInt: QWord;
    function NextBlock: Boolean;
  public
    constructor Create(ASource: TInStage; const APar: TLzpParams);
    function Read(Buf: PByte; Count: SizeInt): SizeInt; override;
  end;

  { Encoder: works per block of BlockSize; a block that does not reach MinCompression ("N%" of
    the method) is stored. }
  TLzpEncStage = class(TOutStage)
  private
    FPar: TLzpParams;
    FMinCompression: Integer;
    FIn, FMain, FLens: array of Byte;
    FHash: array of LongWord;
    FInLen: SizeInt;
    FHeaderDone: Boolean;
    procedure FlushBlock;
  protected
    procedure DoWrite(Buf: PByte; Count: SizeInt); override;
    procedure DoFinish; override;
  public
    constructor Create(ATarget: TOutStage; const APar: TLzpParams; AMinCompression: Integer);
  end;

{ b<mem> block (8mb), l<n> or a bare integer: minimum match (64), h<n> hash bits (18),
  d<mem> barrier (none), s<n> smallest match (32); "N%" (MinCompression) is the encoder's. }
function ParseLzpParams(const Params: TStringArray): TLzpParams;

{ Block coder, exposed for tests. Main must hold Len bytes; Lens grows. Returns False if the
  block does not compress. }
function LzpEncodeBlock(Inp: PByte; Len: SizeInt; const Par: TLzpParams; var Hash: array of LongWord;
  var Main, Lens: TBytes; out NMain, NLens: SizeInt; out Esc: Byte): Boolean;

implementation

uses
  parc_bytes;

const
  CTX = 4;                         // context bytes
  CTX_START = 8;                   // first position with a context (the hash reads 8 bytes)
  HASH_MUL = QWord($9E3779B97F4A7C15);
  PF_AHEAD = 8;

function ParseLzpParams(const Params: TStringArray): TLzpParams;
var
  k: Integer;
  p: string;
  m: QWord;
  n: Integer;
begin
  Result.BlockSize := 8 shl 20;
  Result.MinMatchLen := 64;
  Result.HashSizeLog := 18;
  Result.Barrier := High(LongInt);
  Result.SmallestLen := 32;
  for k := 1 to High(Params) do
  begin
    p := Params[k];
    if p = '' then Continue;
    case p[1] of
      'b': if ParseMemSize(Copy(p, 2, MaxInt), m) then Result.BlockSize := m;
      'l': Result.MinMatchLen := StrToIntDef(Copy(p, 2, MaxInt), Result.MinMatchLen);
      'h': Result.HashSizeLog := StrToIntDef(Copy(p, 2, MaxInt), Result.HashSizeLog);
      'd': if ParseMemSize(Copy(p, 2, MaxInt), m) then Result.Barrier := m;
      's': Result.SmallestLen := StrToIntDef(Copy(p, 2, MaxInt), Result.SmallestLen);
    else
      if p[Length(p)] = '%' then Continue;                  // MinCompression: encoder only
      n := StrToIntDef(p, -1);
      if n >= 0 then Result.MinMatchLen := n                 // bare integer = MinMatchLen
      else if ParseMemSize(p, m) then Result.BlockSize := m;     // memory = BlockSize
    end;
  end;
end;

{ Limits shared by the encoder and the decoder }
procedure Normalize(var P: TLzpParams);
begin
  if (P.BlockSize <= 0) or (P.BlockSize > LZP_MAX_BLOCK) then P.BlockSize := LZP_MAX_BLOCK;
  if P.MinMatchLen < 8 then P.MinMatchLen := 8;
  if P.MinMatchLen > 65535 then P.MinMatchLen := 65535;
  if P.SmallestLen < 8 then P.SmallestLen := 8;
  if P.SmallestLen > P.MinMatchLen then P.SmallestLen := P.MinMatchLen;
  if P.HashSizeLog < 10 then P.HashSizeLog := 10;
  if P.HashSizeLog > LZP_MAX_HASH_BITS then P.HashSizeLog := LZP_MAX_HASH_BITS;
  if P.Barrier < 0 then P.Barrier := 0;
  if P.Barrier > LZP_MAX_BLOCK then P.Barrier := LZP_MAX_BLOCK;
end;

{ Bucket bits for a block of Len bytes: the parameter, but no more than 1 + log2(Len); each
  bucket holds two positions, the most recent first }
function BlockHashBits(Len: SizeInt; Bits: Integer): Integer;
var
  b: Integer;
begin
  b := 1;
  while (b < 31) and ((SizeInt(1) shl b) < Len) do Inc(b);
  Inc(b);
  if b < 10 then b := 10;
  if b > Bits then b := Bits;
  Result := b;
end;

function Load64(p: PByte): QWord; inline;
begin
{$IFDEF ENDIAN_LITTLE}
  Result := PQWord(p)^;
{$ELSE}
  Result := LEtoN(PQWord(p)^);
{$ENDIF}
end;

{ (The decoder's literal loop computes 4-byte contexts directly: it assumes CTX = 4.) }
{ The context value: the 8 bytes before p, little endian (the nearest one in the top byte; the
  decoder keeps it rolling in a register: V = V shr 8 or byte shl 56); the hash uses the top
  CTX bytes }
function CtxValue(p: PByte): QWord; inline;
begin
  Result := Load64(p - 8);
end;

function CtxHashV(V: QWord; Shift: Integer): LongWord; inline;
begin
  Result := LongWord(((V shr (64 - 8 * CTX)) * HASH_MUL) shr Shift);
end;

{ length of the common prefix of a and b, at most Limit }
function MatchLen(a, b: PByte; Limit: SizeInt): SizeInt; inline;
var
  x: QWord;
begin
  Result := 0;
  while Result + 8 <= Limit do
  begin
    x := Load64(a + Result) xor Load64(b + Result);
    if x <> 0 then
    begin
      Inc(Result, BsfQWord(x) shr 3);
      Exit;
    end;
    Inc(Result, 8);
  end;
  while (Result < Limit) and (a[Result] = b[Result]) do Inc(Result);
end;

procedure PutVInt(var B: TBytes; var n: SizeInt; V: QWord); inline;
begin
  if n + 10 > Length(B) then SetLength(B, 2 * Length(B) + 1024);
  while V >= $80 do
  begin
    B[n] := Byte(V) or $80;
    Inc(n);
    V := V shr 7;
  end;
  B[n] := Byte(V);
  Inc(n);
end;

{ A length in the length stream: 255 while at least 255 is left, then the rest }
procedure PutLen(var B: TBytes; var n: SizeInt; V: SizeInt); inline;
begin
  if n + V div 255 + 2 > Length(B) then SetLength(B, 2 * Length(B) + V div 255 + 1024);
  while V >= 255 do
  begin
    B[n] := 255;
    Inc(n);
    Dec(V, 255);
  end;
  B[n] := V;
  Inc(n);
end;

function LzpEncodeBlock(Inp: PByte; Len: SizeInt; const Par: TLzpParams; var Hash: array of LongWord;
  var Main, Lens: TBytes; out NMain, NLens: SizeInt; out Esc: Byte): Boolean;
var
  Freq: array[0..255] of SizeInt;
  i, L, p, nm, nl, MinL, SmallL: SizeInt;
  Shift, hb, c: Integer;
  h: LongWord;
  b: Byte;
  Barrier: SizeInt;
  Out: PByte;
  p2, L2, c2, Which: SizeInt;
  Ring: array[0..PF_AHEAD - 1] of LongWord;
  RingEnd: SizeInt;
  Cur8: QWord;
  F4: array[0..3, 0..255] of LongWord;
begin
  NMain := 0; NLens := 0; Esc := 0;
  Result := False;
  if Len <= 2 * CTX_START then Exit;
  // escape: the least frequent byte value
  FillChar(F4, SizeOf(F4), 0);
  i := 0;
  while i + 4 <= Len do
  begin
    Inc(F4[0][Inp[i]]); Inc(F4[1][Inp[i + 1]]); Inc(F4[2][Inp[i + 2]]); Inc(F4[3][Inp[i + 3]]);
    Inc(i, 4);
  end;
  while i < Len do begin Inc(F4[0][Inp[i]]); Inc(i); end;
  for c := 0 to 255 do Freq[c] := SizeInt(F4[0][c]) + F4[1][c] + F4[2][c] + F4[3][c];
  Esc := 0;
  for c := 1 to 255 do
    if Freq[c] < Freq[Esc] then Esc := c;
  hb := BlockHashBits(Len, Par.HashSizeLog);
  Shift := 64 - hb;
  FillChar(Hash[0], (SizeInt(2) shl hb) * SizeOf(LongWord), 0);
  if Length(Main) < Len then SetLength(Main, Len);
  if Length(Lens) < 4096 then SetLength(Lens, 4096);
  Out := @Main[0];
  MinL := Par.MinMatchLen;
  SmallL := Par.SmallestLen;
  Barrier := Par.Barrier;
  nm := 0; nl := 0;
  // the first bytes have no context
  for i := 0 to CTX_START - 1 do
  begin
    b := Inp[i];
    Out[nm] := b; Inc(nm);
    if b = Esc then PutLen(Lens, nl, 0);
  end;
  i := CTX_START;
  RingEnd := 0;
  while i < Len do
  begin
    // the table slots of the next positions are computed (and fetched) PF_AHEAD positions
    // ahead, so their cache misses overlap this position's work
    if i >= RingEnd then
    begin
      // (re)fill the ring after a match
      RingEnd := i;
      while (RingEnd < i + PF_AHEAD) and (RingEnd < Len) do
      begin
        Ring[RingEnd and (PF_AHEAD - 1)] := CtxHashV(CtxValue(Inp + RingEnd), Shift) * 2;
        Prefetch(Hash[Ring[RingEnd and (PF_AHEAD - 1)]]);
        Inc(RingEnd);
      end;
    end;
    h := Ring[i and (PF_AHEAD - 1)];
    if RingEnd < Len then
    begin
      Ring[RingEnd and (PF_AHEAD - 1)] := CtxHashV(CtxValue(Inp + RingEnd), Shift) * 2;
      Prefetch(Hash[Ring[RingEnd and (PF_AHEAD - 1)]]);
      Inc(RingEnd);
    end;
    p := Hash[h];
    p2 := Hash[h + 1];
    Hash[h + 1] := LongWord(p);
    Hash[h] := LongWord(i);
    if (p <> 0) and (i + 8 <= Len) then
    begin
      // two candidates: the longer match (beyond its minimum) wins, the most recent on a tie;
      // every minimum is at least 8, so the first 8 bytes must agree
      Cur8 := Load64(Inp + i);
      L := 0; c := 1;
      if Load64(Inp + p) = Cur8 then
      begin
        L := MatchLen(Inp + p, Inp + i, Len - i);
        if i - p > Barrier then c := SmallL else c := MinL;
      end;
      Which := 0;
      if (p2 <> 0) and (Load64(Inp + p2) = Cur8) then
      begin
        L2 := MatchLen(Inp + p2, Inp + i, Len - i);
        if i - p2 > Barrier then c2 := SmallL else c2 := MinL;
        if (L2 >= c2) and ((L < c) or (L2 - c2 > L - c)) then begin L := L2; c := c2; Which := 1; end;
      end;
      if L >= c then
      begin
        if nm >= Len - 1 then Exit;          // no gain
        Out[nm] := Esc; Inc(nm);
        PutLen(Lens, nl, 2 * (L - c) + 1 + Which);
        Inc(i, L);
        Continue;
      end;
    end;
    b := Inp[i];
    if nm >= Len - 1 then Exit;
    Out[nm] := b; Inc(nm);
    if b = Esc then PutLen(Lens, nl, 0);
    Inc(i);
  end;
  NMain := nm;
  NLens := nl;
  Result := nm + nl < Len;
end;

{ Decodes a coded block into Dst[0..Len); False if the data are inconsistent }
function LzpDecodeBlock(Main: PByte; NMain: SizeInt; Lens: PByte; NLens: SizeInt; Esc: Byte;
  Dst: PByte; Len: SizeInt; const Par: TLzpParams; HashBits: Integer; var Hash: array of LongWord): Boolean;
var
  i, mp, lp, mEnd, p, L, c, k: SizeInt;
  Shift: Integer;
  h: LongWord;
  b: Byte;
  v: QWord;
  MinL, SmallL, Barrier: SizeInt;
  Cv: QWord;
  Tab: PLongWord;
  q, qe, d: PByte;
  h0, h1, h2, h3, h4, h5, h6, h7, Pos32: LongWord;
  c8, x8, Esc8: QWord;
  p2: SizeInt;
begin
  Result := False;
  if Len <= 2 * CTX_START then Exit;
  Shift := 64 - BlockHashBits(Len, HashBits);
  FillChar(Hash[0], (SizeInt(2) shl (64 - Shift)) * SizeOf(LongWord), 0);
  MinL := Par.MinMatchLen;
  SmallL := Par.SmallestLen;
  Barrier := Par.Barrier;
  mp := 0; lp := 0; i := 0;
  mEnd := NMain;
  Cv := 0;
  Tab := @Hash[0];
  Esc8 := QWord($0101010101010101) * Esc;
  while mp < mEnd do
  begin
    // literal run: no escape, at most up to the end of the block
    if i >= CTX_START then
    begin
      q := Main + mp;
      qe := Main + mEnd;
      if qe - q > Len - i then qe := q + (Len - i);
      d := Dst + i;
      // in groups of 8 literals: the table slots are computed (and fetched) first, so their
      // cache misses overlap instead of following one another
      while qe - q >= 8 do
      begin
        x8 := Load64(q) xor Esc8;          // a zero byte = an escape among the 8
        if ((x8 - QWord($0101010101010101)) and not x8 and QWord($8080808080808080)) <> 0 then Break;
        // contexts of the 8 positions: the 4 bytes before each, from the rolling context
        // and the 8 literals (independent of each other)
        x8 := Load64(q);
        Pos32 := LongWord(d - Dst);
        h0 := LongWord((QWord(LongWord(Cv shr 32)) * HASH_MUL) shr Shift) * 2;
        h1 := LongWord((QWord(LongWord((Cv shr 40) or (x8 shl 24))) * HASH_MUL) shr Shift) * 2;
        h2 := LongWord((QWord(LongWord((Cv shr 48) or (x8 shl 16))) * HASH_MUL) shr Shift) * 2;
        h3 := LongWord((QWord(LongWord((Cv shr 56) or (x8 shl 8))) * HASH_MUL) shr Shift) * 2;
        h4 := LongWord((QWord(LongWord(x8)) * HASH_MUL) shr Shift) * 2;
        h5 := LongWord((QWord(LongWord(x8 shr 8)) * HASH_MUL) shr Shift) * 2;
        h6 := LongWord((QWord(LongWord(x8 shr 16)) * HASH_MUL) shr Shift) * 2;
        h7 := LongWord((QWord(LongWord(x8 shr 24)) * HASH_MUL) shr Shift) * 2;
        Prefetch(Tab[h0]); Prefetch(Tab[h1]); Prefetch(Tab[h2]); Prefetch(Tab[h3]);
        Prefetch(Tab[h4]); Prefetch(Tab[h5]); Prefetch(Tab[h6]); Prefetch(Tab[h7]);
        Tab[h0 + 1] := Tab[h0]; Tab[h0] := Pos32;
        Tab[h1 + 1] := Tab[h1]; Tab[h1] := Pos32 + 1;
        Tab[h2 + 1] := Tab[h2]; Tab[h2] := Pos32 + 2;
        Tab[h3 + 1] := Tab[h3]; Tab[h3] := Pos32 + 3;
        Tab[h4 + 1] := Tab[h4]; Tab[h4] := Pos32 + 4;
        Tab[h5 + 1] := Tab[h5]; Tab[h5] := Pos32 + 5;
        Tab[h6 + 1] := Tab[h6]; Tab[h6] := Pos32 + 6;
        Tab[h7 + 1] := Tab[h7]; Tab[h7] := Pos32 + 7;
        c8 := x8;
        PQWord(d)^ := PQWord(q)^;
        Cv := c8;
        Inc(q, 8);
        Inc(d, 8);
      end;
      while q < qe do
      begin
        b := q^;
        if b = Esc then Break;
        h := CtxHashV(Cv, Shift) * 2;
        Tab[h + 1] := Tab[h];
        Tab[h] := LongWord(d - Dst);
        d^ := b;
        Cv := (Cv shr 8) or (QWord(b) shl 56);
        Inc(q);
        Inc(d);
      end;
      mp := q - Main;
      i := d - Dst;
      if mp >= mEnd then Break;
      if Main[mp] <> Esc then Exit;      // more literals than the block holds
      h := CtxHashV(Cv, Shift) * 2;
      p := Tab[h];
      p2 := Tab[h + 1];
      Tab[h + 1] := LongWord(p);
      Tab[h] := LongWord(i);
    end
    else
    begin
      p := 0; p2 := 0;
      b := Main[mp];
      if b <> Esc then
      begin
        Inc(mp);
        Dst[i] := b;
        Cv := (Cv shr 8) or (QWord(b) shl 56);
        Inc(i);
        Continue;
      end;
    end;
    Inc(mp);
    // escape: a length follows in the length stream (bytes of 255 add up, the last one < 255)
    v := 0;
    repeat
      if lp >= NLens then Exit;
      c := Lens[lp];
      Inc(lp);
      Inc(v, c);
    until c < 255;
    if v = 0 then
    begin
      if i >= Len then Exit;
      Dst[i] := Esc;
      Cv := (Cv shr 8) or (QWord(Esc) shl 56);
      Inc(i);
      Continue;
    end;
    if v > QWord(2 * Len) then Exit;
    if v and 1 = 0 then p := p2;      // the older candidate
    if p = 0 then Exit;
    if i - p > Barrier then c := SmallL else c := MinL;
    L := SizeInt((v - 1) shr 1) + c;
    if L > Len - i then Exit;
    // forward copy (the source may overlap the destination)
    if i - p >= 8 then
    begin
      k := 0;
      while k + 8 <= L do
      begin
        PQWord(Dst + i + k)^ := PQWord(Dst + p + k)^;
        Inc(k, 8);
      end;
      while k < L do begin Dst[i + k] := Dst[p + k]; Inc(k); end;
    end
    else
      for k := 0 to L - 1 do Dst[i + k] := Dst[p + k];
    Inc(i, L);
    Cv := CtxValue(Dst + i);      // L >= 8: the context is all match bytes
  end;
  Result := (i = Len) and (lp = NLens);
end;

{ ---------------- encoder stage ---------------- }

constructor TLzpEncStage.Create(ATarget: TOutStage; const APar: TLzpParams; AMinCompression: Integer);
begin
  inherited Create(ATarget);
  FPar := APar;
  Normalize(FPar);
  FMinCompression := AMinCompression;
  if (FMinCompression <= 0) or (FMinCompression > 100) then FMinCompression := 100;
end;

procedure TLzpEncStage.FlushBlock;
var
  H: TBytes;
  n, NMain, NLens: SizeInt;
  Esc: Byte;
  Ok: Boolean;
begin
  if FInLen = 0 then Exit;
  SetLength(H, 64);
  n := 0;
  if not FHeaderDone then
  begin
    H[0] := LZP_STREAM_VERSION;
    H[1] := CTX;
    H[2] := FPar.HashSizeLog;
    n := 3;
    PutVInt(H, n, FPar.MinMatchLen);
    PutVInt(H, n, FPar.SmallestLen);
    PutVInt(H, n, FPar.Barrier);
    FHeaderDone := True;
  end;
  if Length(FHash) = 0 then SetLength(FHash, SizeInt(2) shl BlockHashBits(FPar.BlockSize, FPar.HashSizeLog));
  Ok := LzpEncodeBlock(@FIn[0], FInLen, FPar, FHash, FMain, FLens, NMain, NLens, Esc);
  // MinCompression: the coded block must be at most N% of the input
  if Ok and ((NMain + NLens + 16) * 100 > Int64(FInLen) * FMinCompression) then Ok := False;
  PutVInt(H, n, FInLen);
  if Ok then
  begin
    H[n] := 1; Inc(n);
    H[n] := Esc; Inc(n);
    PutVInt(H, n, NMain);
    PutVInt(H, n, NLens);
    Emit(@H[0], n);
    Emit(@FMain[0], NMain);
    if NLens > 0 then Emit(@FLens[0], NLens);
  end
  else
  begin
    H[n] := 0; Inc(n);
    Emit(@H[0], n);
    Emit(@FIn[0], FInLen);
  end;
  FInLen := 0;
end;

procedure TLzpEncStage.DoWrite(Buf: PByte; Count: SizeInt);
var
  k: SizeInt;
begin
  while Count > 0 do
  begin
    if Length(FIn) < FPar.BlockSize then
    begin
      // grow with the data (small inputs do not reserve the whole block)
      k := FInLen + Count;
      if k < 64 * 1024 then k := 64 * 1024;
      if k < 2 * Length(FIn) then k := 2 * Length(FIn);
      if k > FPar.BlockSize then k := FPar.BlockSize;
      if k > Length(FIn) then SetLength(FIn, k);
    end;
    k := Length(FIn) - FInLen;
    if k > Count then k := Count;
    Move(Buf^, FIn[FInLen], k);
    Inc(FInLen, k);
    Inc(Buf, k);
    Dec(Count, k);
    if FInLen = FPar.BlockSize then FlushBlock;
  end;
end;

procedure TLzpEncStage.DoFinish;
begin
  FlushBlock;
end;

{ ---------------- decoder stage ---------------- }

constructor TLzpStage.Create(ASource: TInStage; const APar: TLzpParams);
begin
  inherited Create(ASource);
  FPar := APar;
  Normalize(FPar);
end;

function TLzpStage.RdByte: Byte;
begin
  Source.ReadExact(@Result, 1);
end;

function TLzpStage.RdVInt: QWord;
var
  b: Byte;
  Sh: Integer;
begin
  Result := 0;
  Sh := 0;
  repeat
    b := RdByte;
    if Sh > 56 then Corrupt('lzp: invalid number');
    Result := Result or (QWord(b and $7F) shl Sh);
    Inc(Sh, 7);
  until b and $80 = 0;
end;

function TLzpStage.NextBlock: Boolean;
var
  b, Mode, Esc: Byte;
  Len, NMain, NLens: QWord;
begin
  if not Source.ReadExactOrEof(@b, 1) then Exit(False);
  if not FStarted then
  begin
    // stream header: it must describe the parameters of the method string
    if b <> LZP_STREAM_VERSION then Corrupt('lzp: unknown stream version');
    FK := RdByte;
    FHashBits := RdByte;
    if (FK <> CTX) or (FHashBits <> FPar.HashSizeLog) or (RdVInt <> QWord(FPar.MinMatchLen)) or
       (RdVInt <> QWord(FPar.SmallestLen)) or (RdVInt <> QWord(FPar.Barrier)) then
      Corrupt('lzp: stream parameters differ from the method');
    FStarted := True;
    if not Source.ReadExactOrEof(@b, 1) then Exit(False);
  end;
  // b = first byte of the block length
  Len := b and $7F;
  if b and $80 <> 0 then Len := Len or (RdVInt shl 7);
  if (Len = 0) or (Len > QWord(FPar.BlockSize)) then Corrupt('lzp: invalid block size');
  Mode := RdByte;
  if Length(FOut) < SizeInt(Len) then
  begin
    FOut := nil;
    SetLength(FOut, Len);   // at most the block size of the method string
  end;
  case Mode of
    0: Source.ReadExact(@FOut[0], Len);
    1:
      begin
        Esc := RdByte;
        NMain := RdVInt;
        NLens := RdVInt;
        // (every escape takes a main byte and at most 1 + 2 * length / 255 length bytes)
        if (NMain > Len) or (NLens > NMain + 2 * (Len div 255) + 2) then Corrupt('lzp: invalid block');
        if SizeInt(NMain + NLens) > Length(FIn) then
        begin
          FIn := nil;
          SetLength(FIn, NMain + NLens);     // bounded by the block size of the method string
        end;
        if NMain + NLens > 0 then Source.ReadExact(@FIn[0], NMain + NLens);
        if Length(FIn) = 0 then SetLength(FIn, 1);
        if Length(FHash) = 0 then
          SetLength(FHash, SizeInt(2) shl BlockHashBits(FPar.BlockSize, FHashBits));
        if not LzpDecodeBlock(@FIn[0], NMain, @FIn[NMain], NLens, Esc, @FOut[0], Len, FPar,
          FHashBits, FHash) then Corrupt('lzp: damaged block');
      end;
  else
    Corrupt('lzp: invalid block mode');
  end;
  FLen := Len;
  FPos := 0;
  Result := True;
end;

function TLzpStage.Read(Buf: PByte; Count: SizeInt): SizeInt;
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
  Move(FOut[FPos], Buf^, Result);
  Inc(FPos, Result);
end;

end.
