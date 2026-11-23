{ Canonical method text and per-block limits (PArc's own design, 2026-11).

  The chain stored with each solid block is canonical: every stage is parsed with its codec's
  own parameter parser and written back in one fixed form (memory sizes with units, defaults
  left out), so the same compression always gives the same text and the decoder reads exactly
  the parameters the encoder used.

  Size limit: a window, dictionary or block larger than the data only costs memory (and
  decoder memory, which is what the stored text promises). Each one is cut to the block's
  size plus 1 % and 512 bytes, rounded up to KB (up to 4 MB) or to MB (above):
    lzma dictionary (at least 32 KB), orep window, dict/lzp/bwt block (lzp/bwt hash bits to
    the block), plz window (its own rounding, PlzCanon), the inner method of 4x4.
  Memory limit (CanonStageMem): one stage shrunk so that its encoder fits in a byte budget,
  from each codec's own memory model; FitEncodeMem (parc_encoders) calls it on the stage that
  uses most until the whole chain fits.

  Stages the canonical form knows nothing about stay as written (the encoder reports what it
  cannot use). }
unit parc_canon;

{$mode objfpc}{$H+}

interface

{ Method (stages joined with '+') canonical and limited for a solid block of BlockSize bytes. }
function LimitAndCanonize(const Method: string; BlockSize: Int64): string;

{ A canonical stage shrunk so that its encoder uses at most about MemLim bytes. cm, srep and
  the filters do not change. }
function CanonStageMem(const Stage: string; MemLim: Int64): string;

{ Memory budget of the encoders that run at once (bytes; 0 = none): -lc<size>, or with the
  automatic setting (CompressMemLimit < 0) 75 % of the RAM; a 32-bit process also keeps to
  2.25 GB and 9/16 of its address space (the rest is buffers, libraries and fragmentation). }
function EffectiveCompressLimit: Int64;

var
  { -lc: -1 = automatic; 0 = no limit (-lc-); else bytes. Set while reading the command line,
    before compressing (read-only afterwards, from several threads). }
  CompressMemLimit: Int64 = -1;

implementation

uses
  SysUtils, Math, parc_os, parc_methods, parc_lzmaenc, parc_parallel, parc_orep, parc_plzenc,
  parc_bwt, parc_lzp, parc_dict, parc_lz4enc, parc_tta, parc_dispack;

const
  KB = Int64(1024);
  MB = Int64(1024) * 1024;
  GB = Int64(1024) * 1024 * 1024;
  LZMA_MIN_DICT = 32 * KB;
  T4X4_MAX_JOBS = 16;   // as parc_encoders (jobs in flight)

{ ------------------------------------------------------------------------------------------ }
{ Text helpers                                                                               }
{ ------------------------------------------------------------------------------------------ }

{ "64mb", "1035kb", "2gb", "512b": the largest unit that divides the value (MB only below
  4 GB, so that 32-bit readers of the number in MB never overflow). }
function MemText(V: Int64): string;
begin
  if (V > 0) and (V mod GB = 0) then Result := IntToStr(V div GB) + 'gb'
  else if (V > 0) and (V mod MB = 0) and (V < 4 * GB) then Result := IntToStr(V div MB) + 'mb'
  else if (V > 0) and (V mod KB = 0) then Result := IntToStr(V div KB) + 'kb'
  else Result := IntToStr(V) + 'b';
end;

{ What a block of Size bytes can use of a window: Size + 1 % + 512, rounded up. }
function SizeCap(Size: Int64): Int64;
var
  m: Int64;
begin
  if Size < 0 then Size := 0;
  m := Size + Size div 100 + 512;
  Result := (m + KB - 1) div KB * KB;
  if Result > 4 * MB then Result := (m + MB - 1) div MB * MB;
end;

{ Bits of a hash for a block: no more than ceil(log2(Block)). }
function CapBits(Bits: Integer; Block: Int64): Integer;
var
  b: Integer;
begin
  b := 0;
  while (b < 62) and ((Int64(1) shl b) < Block) do Inc(b);
  if b < Bits then Result := b else Result := Bits;
end;

{ The "N%" parameter (MinCompression), or -1. }
function PercentParam(const Parts: TStringArray): Integer;
var
  k: Integer;
begin
  Result := -1;
  for k := 1 to High(Parts) do
    if (Length(Parts[k]) > 1) and (Parts[k][Length(Parts[k])] = '%') then
      Result := StrToIntDef(Copy(Parts[k], 1, Length(Parts[k]) - 1), Result);
end;

{ ------------------------------------------------------------------------------------------ }
{ One canonical writer per codec. Limit: the window cap (0 = no cap). Each one raises on      }
{ parameters its codec does not accept (the caller then keeps the stage as written).        }
{ ------------------------------------------------------------------------------------------ }

function LzmaText(const P: TLzmaEncParams): string;
const
  MF_NAMES: array[TLzmaMatchFinder] of string = ('bt2', 'bt3', 'bt4', 'hc4', 'ht4');
begin
  Result := 'lzma:' + MemText(P.DictSize);
  if P.HashSize <> 0 then Result := Result + ':h' + MemText(P.HashSize);
  case P.Algorithm of
    0: Result := Result + ':fast';
    1: Result := Result + ':normal';
  else
    Result := Result + ':a' + IntToStr(P.Algorithm);
  end;
  if P.MatchFinder <> mfHT4 then Result := Result + ':' + MF_NAMES[P.MatchFinder];
  Result := Result + ':' + IntToStr(P.NumFastBytes);
  if P.MatchFinderCycles <> 0 then Result := Result + ':mc' + IntToStr(P.MatchFinderCycles);
  if P.pb <> 2 then Result := Result + ':pb' + IntToStr(P.pb);
  if P.lc <> 3 then Result := Result + ':lc' + IntToStr(P.lc);
  if P.lp <> 0 then Result := Result + ':lp' + IntToStr(P.lp);
end;

{ The largest m * 2^k (m = 8..15) below D, at least 1 MB. }
function LowerDictStep(D: QWord): QWord;
var
  k: Integer;
  m: QWord;
begin
  k := 0;
  while (D shr k) > 15 do Inc(k);
  m := D shr k;                          // 8..15 (or less for tiny D)
  if (m shl k) = D then Dec(m) else ;   // strictly below D
  if m < 8 then begin m := 15; Dec(k); end;
  if k < 0 then k := 0;
  Result := m shl k;
  if Result < MB then Result := MB;
end;

function CanonLzma(const Parts: TStringArray; Limit, MemLim: Int64): string;
var
  P: TLzmaEncParams;
begin
  P := ParseLzmaEncParams(Parts);
  if (Limit > 0) and (Int64(P.DictSize) > Limit) then P.DictSize := Limit;
  // memory: the next smaller dictionary of the form m * 2^k (m = 8..15) until it fits
  if MemLim > 0 then
    while (P.DictSize > MB) and (LzmaEncMemory(P) > QWord(MemLim)) do
      P.DictSize := LowerDictStep(P.DictSize);
  if P.DictSize < LZMA_MIN_DICT then P.DictSize := LZMA_MIN_DICT;
  Result := LzmaText(P);
end;

function CanonOrep(const Parts: TStringArray; Limit, MemLim: Int64): string;
var
  M: TOrepMethod;
begin
  M := ParseOrepMethod(Parts);
  if (Limit > 0) and (Int64(M.Window) > Limit) then M.Window := Limit;
  if MemLim > 0 then M.Window := OrepFitWindow(M, MemLim);
  Result := 'orep:' + MemText(M.Window);
  if M.MinLen <> OREP_DEF_MINLEN then Result := Result + ':l' + IntToStr(M.MinLen);
  if M.Align <> OREP_DEF_ALIGN then Result := Result + ':a' + IntToStr(M.Align);
  if M.Density <> OREP_DEF_DENSITY then Result := Result + ':s' + IntToStr(M.Density);
  if M.Cands <> OREP_DEF_CANDS then Result := Result + ':c' + IntToStr(M.Cands);
  if M.RunKeep <> 0 then Result := Result + ':r' + IntToStr(M.RunKeep);
  if M.Chunk <> OREP_DEF_CHUNK then Result := Result + ':b' + MemText(M.Chunk);
  if M.MinDist <> 0 then Result := Result + ':d' + MemText(M.MinDist);
end;

function CanonPpmd(const Parts: TStringArray; MemLim: Int64): string;
var
  P: TPpmdParams;
begin
  P := ParsePpmdParams(Parts);
  if (MemLim > 0) and (Int64(P.Mem) + 2 * MB > MemLim) then
    P.Mem := Max(MB, (MemLim - 2 * MB) div MB * MB);
  Result := 'ppmd:' + IntToStr(P.Order) + ':' + MemText(P.Mem);
  if P.Restore = 1 then Result := Result + ':r'
  else if P.Restore <> 0 then Result := Result + ':r' + IntToStr(P.Restore);
end;

function CanonDict(const Parts: TStringArray; Limit, MemLim: Int64): string;
var
  P: TDictParams;
  B: Int64;
begin
  P := ParseDictParams(Parts);
  B := P.BlockSize;
  if (Limit > 0) and (B > Limit) then B := Limit;
  // the encoder holds about three times its block
  if (MemLim > 0) and (3 * B + MB > MemLim) then B := Max(MB, (MemLim - MB) div 3 div KB * KB);
  Result := 'dict:' + MemText(B);
  if P.MinCompression <> 100 then Result := Result + ':' + IntToStr(P.MinCompression) + '%';
  if P.MinWeakChars <> 20 then Result := Result + ':c' + IntToStr(P.MinWeakChars);
  if P.MinLargeCnt <> 2048 then Result := Result + ':l' + IntToStr(P.MinLargeCnt);
  if P.MinMediumCnt <> 100 then Result := Result + ':m' + IntToStr(P.MinMediumCnt);
  if P.MinSmallCnt <> 50 then Result := Result + ':s' + IntToStr(P.MinSmallCnt);
  if P.MinRatio <> 4 then Result := Result + ':r' + IntToStr(P.MinRatio);
end;

function CanonLzp(const Parts: TStringArray; Limit, MemLim: Int64): string;
var
  P: TLzpParams;
  B: Int64;
  H, Pct: Integer;
begin
  P := ParseLzpParams(Parts);
  B := P.BlockSize;
  H := P.HashSizeLog;
  if (Limit > 0) and (B > Limit) then B := Limit;
  // input + output blocks and the hash (8 bytes per bucket)
  if MemLim > 0 then
    while (2 * B + (Int64(8) shl H) + MB > MemLim) and ((B > MB) or (H > 10)) do
      if (H > 10) and (((Int64(8) shl H) > B) or (B <= MB)) then Dec(H)
      else B := Max(MB, B div 2);
  H := CapBits(H, B);
  Result := 'lzp:' + MemText(B);
  Pct := PercentParam(Parts);
  if Pct >= 0 then Result := Result + ':' + IntToStr(Pct) + '%';
  Result := Result + ':' + IntToStr(P.MinMatchLen) + ':h' + IntToStr(H);
  if P.Barrier <> High(LongInt) then Result := Result + ':d' + MemText(P.Barrier);
  if P.SmallestLen <> 32 then Result := Result + ':s' + IntToStr(P.SmallestLen);
end;

function CanonBwt(const Parts: TStringArray; Limit, MemLim: Int64): string;
var
  P: TBwtParams;
  B: Int64;
begin
  P := ParseBwtParams(Parts);
  B := P.BlockSize;
  if (Limit > 0) and (B > Limit) then B := Limit;
  if MemLim > 0 then
    while (B > MB) and (BwtEncodeBlockMemory(P) > MemLim) do
    begin
      B := Max(MB, B div 2);
      P.BlockSize := B;
    end;
  Result := 'bwt:' + MemText(B) + ':m' + IntToStr(P.Level);
  if P.LzpMin > 0 then
    Result := Result + ':l' + IntToStr(P.LzpMin) + ':h' + IntToStr(CapBits(P.LzpHash, B))
  else
    Result := Result + ':l';
  if P.CoderSet >= 0 then Result := Result + ':e' + IntToStr(P.CoderSet);
  if P.Adaptive then Result := Result + ':a';
end;

function CanonLz4(const Parts: TStringArray): string;
var
  P: TLz4EncParams;
begin
  P := ParseLz4EncParams(Parts);
  Result := 'lz4';
  if P.Compressor <> 0 then Result := Result + ':c' + IntToStr(P.Compressor);
  if P.BlockSize <> MB then Result := Result + ':b' + MemText(P.BlockSize);
  if P.MinCompression <> 100 then Result := Result + ':' + IntToStr(P.MinCompression) + '%';
end;

function CanonTta(const Parts: TStringArray): string;
var
  P: TTtaEncParams;
begin
  P := ParseTtaEncParams(Parts);
  // only the level: the layout comes from the data
  Result := 'tta';
  if P.Level <> 3 then Result := Result + ':m' + IntToStr(P.Level);
end;

{ Size: the solid block's size (< 0: no size limit). }
function CanonStage(const Stage: string; Size, MemLim: Int64): string; forward;

{ 4x4: its own parameters (only b<mem>, the block, matters to the encoder), then the inner
  method, canonical with the same limits shared by its jobs. }
function Canon4x4(const Stage: string; Size, MemLim: Int64): string;
var
  Parts: TStringArray;
  Own, Inner: string;
  k: Integer;
  m: QWord;
  Jobs: Integer;
  Blk: Int64;
begin
  Parts := Stage.Split([':']);
  Own := '4x4';
  Inner := '';
  Blk := 0;
  for k := 1 to High(Parts) do
    if (Parts[k] <> '') and ((Parts[k][1] in ['0'..'9']) or
       ((Length(Parts[k]) > 1) and (Parts[k][2] in ['0'..'9']))) then
    begin
      if (Parts[k][1] = 'b') and ParseMem(Copy(Parts[k], 2, MaxInt), m) then
      begin
        Blk := m;
        Own := Own + ':b' + MemText(m);
      end
      else if (Parts[k][1] in ['0'..'9']) and ParseMem(Parts[k], m) then
      begin
        Blk := m;
        Own := Own + ':b' + MemText(m);
      end;
      // t<n>, i<n>, r<n>: FreeArc's thread and priority switches, unused here
    end
    else
    begin
      Inner := string.Join(':', Parts, k, Length(Parts) - k);
      Break;
    end;
  if Inner = '' then Inner := 'plz:1:1mb';
  if MemLim > 0 then
  begin
    // every job in flight holds an encoder and two blocks
    Jobs := Max(1, Min(BudgetThreads, T4X4_MAX_JOBS));
    if Blk = 0 then Blk := 8 * MB;
    MemLim := Max(MB, (MemLim - Blk) div Jobs - 2 * Blk);
  end;
  Result := Own + ':' + CanonStage(Inner, Size, MemLim);
end;

function CanonStage(const Stage: string; Size, MemLim: Int64): string;
var
  Parts: TStringArray;
  Limit: Int64;
begin
  Parts := Stage.Split([':']);
  if Length(Parts) = 0 then Exit(Stage);
  if Size >= 0 then Limit := SizeCap(Size) else Limit := 0;
  try
    case Parts[0] of
      'lzma': Result := CanonLzma(Parts, Limit, MemLim);
      'orep': Result := CanonOrep(Parts, Limit, MemLim);
      'ppmd': Result := CanonPpmd(Parts, MemLim);
      'dict': Result := CanonDict(Parts, Limit, MemLim);
      'lzp': Result := CanonLzp(Parts, Limit, MemLim);
      'bwt': Result := CanonBwt(Parts, Limit, MemLim);
      'plz': Result := PlzCanon(Parts, Limit, MemLim);   // (rounds its window to 64 KB)
      'lz4': Result := CanonLz4(Parts);
      'tta': Result := CanonTta(Parts);
      '4x4': Result := Canon4x4(Stage, Size, MemLim);
      // the filters choose their layout from the data: no parameters are kept
      'mm', 'delta', 'exe', 'srep', 'storing': Result := Parts[0];
      'dispack070':
        if DispackBlockSize(Parts) <> DispackBlockSize(['dispack070']) then
          Result := 'dispack070:' + MemText(DispackBlockSize(Parts))
        else
          Result := 'dispack070';
    else
      Result := Stage;   // cm, bcj2, ciphers, unknown names: as written
    end;
  except
    on Exception do Result := Stage;   // the encoder reports the bad parameter
  end;
end;

function LimitAndCanonize(const Method: string; BlockSize: Int64): string;
var
  St: string;
begin
  Result := '';
  if BlockSize < 0 then BlockSize := 0;
  for St in Method.Split(['+']) do
  begin
    if St = '' then Continue;
    if Result <> '' then Result := Result + '+';
    Result := Result + CanonStage(St, BlockSize, 0);
  end;
end;

function CanonStageMem(const Stage: string; MemLim: Int64): string;
begin
  if MemLim < MB then MemLim := MB;
  Result := CanonStage(Stage, -1, MemLim);
end;

function EffectiveCompressLimit: Int64;
var
  Ram, Space: Int64;
begin
  if CompressMemLimit >= 0 then Exit(CompressMemLimit);
  Ram := PhysicalMemory;
  if Ram > 0 then Result := Ram div 4 * 3 else Result := 0;
  {$IFNDEF CPU64}
  if (Result = 0) or (Result > Int64(9) * GB div 4) then Result := Int64(9) * GB div 4;
  Space := AddressSpaceLimit;
  if Space <= 0 then Space := 4 * GB;
  if Result > Space div 16 * 9 then Result := Space div 16 * 9;
  {$ELSE}
  Space := 0;
  if Space <> 0 then ;
  {$ENDIF}
end;

end.
