{ mm: multimedia decorrelation filter (PArc's own code, MIT; nothing from FreeArc).

  The method keeps FreeArc's name `mm` and its parameters, but the filter and its stream
  are new.  It goes in front of a general compressor (`mm+grzip`, `mm+plz`, `mm+lzma`) and
  replaces every sample by (sample - prediction) mod 2^bits, keeping its width, byte order
  and position, so the output has the length of the input plus a small header.

  Layout (parc_mmdet): the container header when there is one (WAV/AIFF audio; BMP, TGA,
  PGM/PPM and uncompressed TIFF images, which also give the row length), the method's
  c/w/o parameters, or the statistics of the first MB.  Prediction (the hot loops are C,
  src/tta/mmtta_core.c): audio and images without rows per channel from the last one or
  two samples; images from their neighbours (up, gradient a+b-c, the LOCO-I median edge
  detector, the average of left and up, or left), optionally with the residuals of R and B
  minus that of G (two channels: the second minus the first).  The encoder picks the one
  with the smallest residual cost on up to 256 KB of the first MB.

  Stream (version 1, docs/formato/FORMATO-PARC.md §6.7):
    U8 version = 1, U8 mode: 0 = stored (the rest is the data), 1 = filtered:
      U8 channels (1..16), U8 bytes per sample (1..4), U8 flags (bit 0 big endian,
      bit 1 unsigned), U8 predictor (0..5), U8 cross (0/1), VInt width (pixels per row,
      0 = no rows), VInt row bytes, VInt header bytes, VInt data bytes + 1 (0 = to the end),
      zero bytes up to a multiple of 8 from the stream start,
      the header bytes as they are, the data filtered, the rest as it is.
  Rows: the first width x channels x bytes bytes of each row are samples, the rest (row
  padding) passes as it is; a final incomplete row or sample frame passes as it is. }
unit parc_mm;

{$mode objfpc}{$H+}
{$R-}{$Q-}
{$pointermath on}

interface

uses
  SysUtils, parc_stream, parc_outstream, parc_mmdet;

const
  MM_STREAM_VERSION = 1;
  MM_MAX_CHAN = 16;
  MM_DETECT = 1 shl 20;
  MM_CHUNK = 64 * 1024;
  MM_MAX_ROW = 16 shl 20;

type
  EMmEncParams = class(Exception);

  TMmParams = record
    Mode, SkipHeader, IsFloat, NumChan, WordSize, Offset, Reorder: Integer;
  end;
  TMmEncParams = TMmParams;

  { the C filter state (mm_t in mmtta_core.c) }
  TMmCore = record
    NumChan, Bytes, BE, Uns, Pred, Cross: LongInt;
    Width, RowBytes: LongInt;
    Last1, Last2: array[0..MM_MAX_CHAN - 1] of LongInt;
    Cost: QWord;
  end;
  PMmCore = ^TMmCore;

  TMmEncPhase = (mpDetect, mpStored, mpFiltered);

  TMmEncStage = class(TOutStage)
  private
    FPar: TMmEncParams;
    FPhase: TMmEncPhase;
    FBuf: TBytes;                 // detection buffer
    FLen: SizeInt;
    FM: TMmCore;
    FHdrLeft, FDataLeft: Int64;   // header bytes to pass, data bytes to filter (-1: to the end)
    FUnit: SizeInt;               // a row or a sample frame
    FPend: TBytes;                // incomplete unit
    FPendLen: SizeInt;
    FPrev: TBytes;                // last original row (2D)
    FHavePrev: Boolean;
    FOut: TBytes;
    procedure Decide;
    procedure ChoosePred(Data: PByte; Len: SizeInt);
    function Pays(Data: PByte; Len: SizeInt): Boolean;
    function FramePhase(const L: TMmLayout): Integer;
    procedure Feed(P: PByte; N: SizeInt);
    procedure FilterUnits(P: PByte; Units: SizeInt);
  protected
    procedure DoWrite(Buf: PByte; Count: SizeInt); override;
    procedure DoFinish; override;
  public
    constructor Create(ATarget: TOutStage; const Params: TStringArray);
    constructor Create(ATarget: TOutStage; const APar: TMmEncParams);
  end;

  TMmStage = class(TInStage)
  private
    FStarted, FStored: Boolean;
    FM: TMmCore;
    FHdrLeft, FDataLeft: Int64;
    FUnit: SizeInt;
    FBuf: TBytes;
    FLen, FPos: SizeInt;
    FPrev: TBytes;
    FHavePrev: Boolean;
    FEof: Boolean;
    procedure Start;
    function Fill: Boolean;
  public
    constructor Create(ASource: TInStage; const APar: TMmParams);
    function Read(Buf: PByte; Count: SizeInt): SizeInt; override;
  end;

function ParseMmParams(const Params: TStringArray): TMmParams;
function ParseMmEncParams(const Params: TStringArray): TMmEncParams;

implementation

uses
  parc_bytes,
  parc_tta;   // parc_tta links mmtta_core.o (once)

procedure mm_enc_rows(m: PMmCore; src, prev, dst: PByte; nrows: SizeUInt; cost: LongInt); cdecl; external name 'mm_enc_rows';
procedure mm_dec_rows(m: PMmCore; buf, prev: PByte; nrows: SizeUInt); cdecl; external name 'mm_dec_rows';
procedure mm_enc_1d(m: PMmCore; src, dst: PByte; frames: SizeUInt; cost: LongInt); cdecl; external name 'mm_enc_1d';
procedure mm_dec_1d(m: PMmCore; buf: PByte; frames: SizeUInt); cdecl; external name 'mm_dec_1d';
function mm_state_size: SizeUInt; cdecl; external name 'mm_state_size';
procedure mm_costs_2d(m: PMmCore; src: PByte; nrows: SizeUInt; cost: PQWord); cdecl; external name 'mm_costs_2d';
function mm_lz_cost(p: PByte; n: SizeUInt; tab: PLongWord): QWord; cdecl; external name 'mm_lz_cost';
function mm_find_stride(p: PByte; len: SizeUInt; n, smin, smax, k1, k2: LongWord): LongWord; cdecl; external name 'mm_find_stride';

{ ---------------------------------------------------------------------------------------- }
{ parameters }

function ParseMmEncParams(const Params: TStringArray): TMmEncParams;
var
  k, a, b: Integer;
  p: string;
  isF, ok: Boolean;
begin
  if (Length(Params) = 0) or (Params[0] <> 'mm') then
    raise EMmEncParams.Create('mm: not the method mm');
  Result.Mode := 9;
  Result.SkipHeader := 0;
  Result.IsFloat := 0;
  Result.NumChan := 0;
  Result.WordSize := 0;
  Result.Offset := 0;
  Result.Reorder := 0;
  for k := 1 to High(Params) do
  begin
    p := Params[k];
    if p = '' then raise EMmEncParams.Create('mm: empty parameter');
    case p[1] of
      's': ok := Length(p) = 1;
      'f': ok := Length(p) = 1;
      'd': ok := FaParseInt(Copy(p, 2, MaxInt), Result.Mode);
      'c': ok := FaParseInt(Copy(p, 2, MaxInt), Result.NumChan);
      'w': ok := FaParseInt(Copy(p, 2, MaxInt), Result.WordSize);
      'o': ok := FaParseInt(Copy(p, 2, MaxInt), Result.Offset);
      'r': ok := FaParseInt(Copy(p, 2, MaxInt), Result.Reorder) and (Result.Reorder = 0);
    else
      ok := FaParseChanWord(p, a, b, isF);
      if ok then
      begin
        Result.NumChan := a;
        Result.WordSize := b;
        Result.IsFloat := Ord(isF);
      end;
    end;
    if not ok then raise EMmEncParams.CreateFmt('mm: invalid parameter "%s"', [p]);
    if p = 's' then Result.SkipHeader := 1;
    if p = 'f' then Result.IsFloat := 1;
  end;
end;

function ParseMmParams(const Params: TStringArray): TMmParams;
begin
  try
    Result := ParseMmEncParams(Params);
  except
    on E: EMmEncParams do raise EArcCorrupt.Create(E.Message);
  end;
end;

{ LEB128 (7 bits per byte, low group first, bit 7 = more) }
procedure PutLeb(var W: TByteWriter; V: QWord);
begin
  repeat
    if V > $7F then W.U8((V and $7F) or $80) else W.U8(V);
    V := V shr 7;
  until V = 0;
end;

{ ---------------------------------------------------------------------------------------- }
{ encoder }

constructor TMmEncStage.Create(ATarget: TOutStage; const Params: TStringArray);
begin
  Create(ATarget, ParseMmEncParams(Params));
end;

constructor TMmEncStage.Create(ATarget: TOutStage; const APar: TMmEncParams);
begin
  inherited Create(ATarget);
  if mm_state_size <> SizeOf(TMmCore) then raise EMmEncParams.Create('mm: core mismatch');
  FPar := APar;
  FPhase := mpDetect;
  SetLength(FBuf, MM_DETECT);
end;

{ the predictor with the smallest residual cost on (up to) 256 KB of data }
procedure TMmEncStage.ChoosePred(Data: PByte; Len: SizeInt);
var
  Lim, Units: SizeInt;
  p, c, BestP, BestC: Integer;
  Costs: array[0..11] of QWord;
  Best: QWord;
  M: TMmCore;
begin
  FM.Pred := 0; FM.Cross := 0;
  if FPar.Mode <= 2 then Lim := 64 * 1024 else Lim := 128 * 1024;
  if Lim < 4 * FUnit then Lim := 4 * FUnit;
  if Len > Lim then
  begin
    Data := Data + ((Len - Lim) div 2 div FUnit) * FUnit;   // from the middle
    Len := Lim;
  end;
  Units := Len div FUnit;
  if Units < 2 then Exit;
  Best := High(QWord);
  BestP := 0; BestC := 0;
  if FM.Width > 0 then
  begin
    // all 2D predictors in one pass
    mm_costs_2d(@FM, Data, Units, @Costs[0]);
    for p := 0 to 5 do
      for c := 0 to Ord(FM.NumChan >= 2) do
        if (p <> 1) and (Costs[2 * p + c] < Best) then
        begin
          Best := Costs[2 * p + c];
          BestP := p;
          BestC := c;
        end;
  end
  else
    for p := 0 to 1 do
      for c := 0 to Ord(FM.NumChan >= 2) do
      begin
        M := FM;
        M.Pred := p;
        M.Cross := c;
        M.Cost := 0;
        FillChar(M.Last1, SizeOf(M.Last1), 0);
        FillChar(M.Last2, SizeOf(M.Last2), 0);
        mm_enc_1d(@M, Data, nil, Units, 1);
        if M.Cost < Best then
        begin
          Best := M.Cost;
          BestP := p;
          BestC := c;
        end;
      end;
  FM.Pred := BestP;
  FM.Cross := BestC;
end;

{ the offset (0 .. frame size - 1) at which sample frames line up best: the smallest
  order-1 residual cost on the middle of the detection buffer }
function TMmEncStage.FramePhase(const L: TMmLayout): Integer;
var
  F, ph, Len, Units: SizeInt;
  M: TMmCore;
  Best: QWord;
  Mid: PByte;
begin
  Result := 0;
  F := L.NumChan * (L.Bits div 8);
  if (F <= 1) or (FLen < 4 * F + F) then Exit;
  Len := FLen - F;
  Units := 64 * 1024;
  if Len > Units then Len := Units;
  Units := Len div F;
  Mid := @FBuf[((FLen - F - Units * F) div 2 div F) * F];
  Best := High(QWord);
  for ph := 0 to F - 1 do
  begin
    FillChar(M, SizeOf(M), 0);
    M.NumChan := L.NumChan;
    M.Bytes := L.Bits div 8;
    M.BE := Ord(L.Flags and MMF_BE <> 0);
    M.Uns := Ord(L.Flags and MMF_U8 <> 0);
    mm_enc_1d(@M, Mid + ph, nil, Units, 1);
    if M.Cost < Best then
    begin
      Best := M.Cost;
      Result := ph;
    end;
  end;
end;

procedure TMmEncStage.Decide;
var
  L: TMmLayout;
  Ok: Boolean;
  R: Double;
  W: TByteWriter;
  Avail: SizeInt;
  S: LongWord;
begin
  Ok := False;
  FillChar(L, SizeOf(L), 0);
  L.DataLen := -1;
  if (FPar.NumChan > 0) or (FPar.WordSize > 0) or (FPar.IsFloat <> 0) then
  begin
    L.NumChan := FPar.NumChan;
    if L.NumChan = 0 then L.NumChan := 1;
    L.Bits := FPar.WordSize;
    if L.Bits = 0 then
      if FPar.IsFloat <> 0 then L.Bits := 32 else L.Bits := 8;
    L.Offset := FPar.Offset;
    if L.Bits = 8 then L.Flags := MMF_U8;
    Ok := L.Bits in [8, 16, 24, 32];
  end
  else
  begin
    if FPar.SkipHeader = 0 then Ok := MmParseHeader(@FBuf[0], FLen, L);
    if not Ok then
    begin
      if FPar.Mode <= 2 then
        Ok := MmDetectStats(@FBuf[0], FLen, [1, 2, 3, 4], [1, 2], False, 0.80, L, R)
      else
        Ok := MmDetectStats(@FBuf[0], FLen, [1, 2, 3, 4], [1, 2, 3, 4], True, 0.80, L, R);
      L.Offset := 0;
      L.DataLen := -1;
      // where the first whole sample frame starts (an unknown header before the samples)
      if Ok then L.Offset := FramePhase(L);
      // 8-bit pixels without a header (e.g. a TIFF whose directory is at the end): look for
      // the row length
      if Ok and (L.Bits = 8) and (L.NumChan in [1, 3, 4]) then
      begin
        if FPar.Mode <= 2 then S := mm_find_stride(@FBuf[L.Offset], FLen - L.Offset, L.NumChan, 16, 32768, 64, 4096)
        else S := mm_find_stride(@FBuf[L.Offset], FLen - L.Offset, L.NumChan, 16, 65536, 128, 8192);
        if S > 0 then
        begin
          L.Kind := MMK_IMAGE;
          L.Width := S div LongWord(L.NumChan);
          L.RowBytes := S;
        end;
      end;
    end;
  end;
  // (a header with no channels: a packed format such as 16-bit RGB555, left alone)
  if Ok and ((L.NumChan < 1) or (L.NumChan > MM_MAX_CHAN)) then Ok := False;
  FillChar(FM, SizeOf(FM), 0);
  if Ok then
  begin
    FM.NumChan := L.NumChan;
    FM.Bytes := L.Bits div 8;
    FM.BE := Ord(L.Flags and MMF_BE <> 0);
    FM.Uns := Ord((L.Kind = MMK_IMAGE) or (L.Flags and MMF_U8 <> 0));
    if (L.Kind = MMK_IMAGE) and (L.Width > 0) and (L.RowBytes >= Int64(L.Width) * L.NumChan * (L.Bits div 8)) and
       (L.RowBytes <= MM_MAX_ROW) then
    begin
      FM.Width := L.Width;
      FM.RowBytes := L.RowBytes;
      FUnit := L.RowBytes;
    end
    else
      FUnit := FM.NumChan * FM.Bytes;
  end;
  W.Clear;
  W.U8(MM_STREAM_VERSION);
  if not Ok then
  begin
    W.U8(0);
    Emit(@W.Data[0], W.Len);
    FPhase := mpStored;
    Exit;
  end;
  // the predictor, on the data in the detection buffer
  Avail := FLen - L.Offset;
  if (L.DataLen >= 0) and (Avail > L.DataLen) then Avail := L.DataLen;
  if Avail > 0 then
  begin
    ChoosePred(@FBuf[L.Offset], Avail);
    if not Pays(@FBuf[L.Offset], Avail) then
    begin
      W.U8(0);
      Emit(@W.Data[0], W.Len);
      FPhase := mpStored;
      Exit;
    end;
  end;
  W.U8(1);
  W.U8(FM.NumChan);
  W.U8(FM.Bytes);
  W.U8(FM.BE or (FM.Uns shl 1));
  W.U8(FM.Pred);
  W.U8(FM.Cross);
  PutLeb(W, FM.Width);
  PutLeb(W, FM.RowBytes);
  PutLeb(W, L.Offset);
  PutLeb(W, L.DataLen + 1);
  while W.Len mod 8 <> 0 do W.U8(0);
  Emit(@W.Data[0], W.Len);
  FHdrLeft := L.Offset;
  FDataLeft := L.DataLen;
  if FDataLeft > 0 then FDataLeft := FDataLeft - FDataLeft mod FUnit;   // the rest passes raw
  SetLength(FPend, FUnit);
  SetLength(FPrev, FUnit);
  SetLength(FOut, MM_CHUNK + FUnit);
  FPhase := mpFiltered;
end;

{ Units whole rows / sample frames at P (all inside the data region) }
procedure TMmEncStage.FilterUnits(P: PByte; Units: SizeInt);
var
  k, PrevP: SizeInt;
  Pp: PByte;
begin
  while Units > 0 do
  begin
    k := MM_CHUNK div FUnit;
    if k < 1 then k := 1;
    if k > Units then k := Units;
    if FM.Width > 0 then
    begin
      if FHavePrev then Pp := @FPrev[0] else Pp := nil;
      mm_enc_rows(@FM, P, Pp, @FOut[0], k, 0);
      Move(P[(k - 1) * FUnit], FPrev[0], FUnit);
      FHavePrev := True;
    end
    else
      mm_enc_1d(@FM, P, @FOut[0], k, 0);
    PrevP := k * FUnit;
    Emit(@FOut[0], PrevP);
    Inc(P, PrevP);
    Dec(Units, k);
  end;
end;

procedure TMmEncStage.Feed(P: PByte; N: SizeInt);
var
  k, Units: SizeInt;
begin
  while N > 0 do
  begin
    if FHdrLeft > 0 then
    begin
      k := N;
      if k > FHdrLeft then k := FHdrLeft;
      Emit(P, k);
      Inc(P, k); Dec(N, k); Dec(FHdrLeft, k);
      Continue;
    end;
    if FDataLeft = 0 then
    begin
      Emit(P, N);
      Exit;
    end;
    // complete the pending unit
    if FPendLen > 0 then
    begin
      k := FUnit - FPendLen;
      if k > N then k := N;
      Move(P^, FPend[FPendLen], k);
      Inc(FPendLen, k); Inc(P, k); Dec(N, k);
      if FPendLen = FUnit then
      begin
        FilterUnits(@FPend[0], 1);
        FPendLen := 0;
        if FDataLeft > 0 then Dec(FDataLeft, FUnit);
      end;
      Continue;
    end;
    Units := N div FUnit;
    if (FDataLeft > 0) and (Units > FDataLeft div FUnit) then Units := FDataLeft div FUnit;
    if Units > 0 then
    begin
      FilterUnits(P, Units);
      k := Units * FUnit;
      Inc(P, k); Dec(N, k);
      if FDataLeft > 0 then Dec(FDataLeft, k);
      Continue;
    end;
    Move(P^, FPend[0], N);
    FPendLen := N;
    N := 0;
  end;
end;

procedure TMmEncStage.DoWrite(Buf: PByte; Count: SizeInt);
var
  k: SizeInt;
  Tmp: TBytes;
begin
  if Count <= 0 then Exit;
  case FPhase of
    mpDetect:
      begin
        k := MM_DETECT - FLen;
        if k > Count then k := Count;
        Move(Buf^, FBuf[FLen], k);
        Inc(FLen, k); Inc(Buf, k); Dec(Count, k);
        if FLen < MM_DETECT then Exit;
        Decide;
        Tmp := FBuf;
        FBuf := nil;
        if FPhase = mpStored then Emit(@Tmp[0], FLen) else Feed(@Tmp[0], FLen);
        FLen := 0;
        if Count > 0 then DoWrite(Buf, Count);
      end;
    mpStored: Emit(Buf, Count);
    mpFiltered: Feed(Buf, Count);
  end;
end;

procedure TMmEncStage.DoFinish;
var
  Tmp: TBytes;
begin
  if FPhase = mpDetect then
  begin
    Decide;
    Tmp := FBuf;
    FBuf := nil;
    if FLen > 0 then
      if FPhase = mpStored then Emit(@Tmp[0], FLen) else Feed(@Tmp[0], FLen);
    FLen := 0;
  end;
  // an incomplete unit at the end passes as it is
  if (FPhase = mpFiltered) and (FPendLen > 0) then
  begin
    Emit(@FPend[0], FPendLen);
    FPendLen := 0;
  end;
end;

{ Does the filter pay?  The residuals of smooth data compress much better, but synthetic and
  palette images (flat areas, repeated patterns) often compress better as they are.  A fast LZ
  estimate on the same sample, raw and filtered, decides. }
function LzSize(P: PByte; N: SizeInt): QWord;
var
  Tab: array of LongWord;
begin
  SetLength(Tab, 1 shl 14);
  Result := mm_lz_cost(P, N, @Tab[0]);
end;
function TMmEncStage.Pays(Data: PByte; Len: SizeInt): Boolean;
var
  Lim, Units: SizeInt;
  M: TMmCore;
  Tmp: TBytes;
begin
  if FPar.Mode <= 2 then Lim := 64 * 1024 else Lim := 128 * 1024;
  if Lim < 4 * FUnit then Lim := 4 * FUnit;
  if Len > Lim then
  begin
    Data := Data + ((Len - Lim) div 2 div FUnit) * FUnit;
    Len := Lim;
  end;
  Units := Len div FUnit;
  if Units < 2 then Exit(True);
  Len := Units * FUnit;
  M := FM;
  FillChar(M.Last1, SizeOf(M.Last1), 0);
  FillChar(M.Last2, SizeOf(M.Last2), 0);
  SetLength(Tmp, Len);
  if M.Width > 0 then mm_enc_rows(@M, Data, nil, @Tmp[0], Units, 0)
  else mm_enc_1d(@M, Data, @Tmp[0], Units, 0);
  Result := LzSize(@Tmp[0], Len) < LzSize(Data, Len);
end;

{ ---------------------------------------------------------------------------------------- }
{ decoder }

constructor TMmStage.Create(ASource: TInStage; const APar: TMmParams);
begin
  inherited Create(ASource);
end;

function ReadVIntFrom(S: TInStage): QWord;
var
  b: Byte;
  sh: Integer;
begin
  Result := 0;
  sh := 0;
  repeat
    S.ReadExact(@b, 1);
    if (sh = 63) and (b > 1) then Corrupt('mm: invalid number');
    Result := Result or (QWord(b and $7F) shl sh);
    Inc(sh, 7);
    if (sh > 63) and (b and $80 <> 0) then Corrupt('mm: invalid number');
  until b and $80 = 0;
end;

procedure TMmStage.Start;
var
  b: array[0..5] of Byte;
  Pos: Int64;
  Wd, Rb, Off, DL: QWord;
  Pad: array[0..7] of Byte;
  k: Integer;

  function VI: QWord;
  var
    x: Byte;
    sh: Integer;
  begin
    Result := 0;
    sh := 0;
    repeat
      Source.ReadExact(@x, 1);
      Inc(Pos);
      if sh > 56 then Corrupt('mm: invalid number');
      Result := Result or (QWord(x and $7F) shl sh);
      Inc(sh, 7);
    until x and $80 = 0;
  end;

begin
  FStarted := True;
  if not Source.ReadExactOrEof(@b[0], 1) then Corrupt('mm: empty stream');
  if b[0] <> MM_STREAM_VERSION then Corrupt('mm: unknown stream version (not a PArc 0.0.7+ mm stream)');
  Source.ReadExact(@b[0], 1);
  if b[0] = 0 then
  begin
    FStored := True;
    Exit;
  end;
  if b[0] <> 1 then Corrupt('mm: invalid mode');
  Source.ReadExact(@b[0], 5);
  Pos := 7;
  FillChar(FM, SizeOf(FM), 0);
  FM.NumChan := b[0];
  FM.Bytes := b[1];
  FM.BE := b[2] and 1;
  FM.Uns := (b[2] shr 1) and 1;
  FM.Pred := b[3];
  FM.Cross := b[4];
  Wd := VI;
  Rb := VI;
  Off := VI;
  DL := VI;
  if (FM.NumChan < 1) or (FM.NumChan > MM_MAX_CHAN) or (FM.Bytes < 1) or (FM.Bytes > 4) or
     (b[2] > 3) or (FM.Pred > 5) or (FM.Cross > 1) or (Off > QWord(High(Int64))) or (DL > QWord(High(Int64))) then
    Corrupt('mm: invalid header');
  if Wd > 0 then
  begin
    if (FM.Pred < 2) and (FM.Pred <> 0) or (Rb > MM_MAX_ROW) or (Wd * FM.NumChan * FM.Bytes > Rb) then
      Corrupt('mm: invalid header');
    FM.Width := Wd;
    FM.RowBytes := Rb;
    FUnit := Rb;
  end
  else
  begin
    if (FM.Pred > 1) or (Rb <> 0) then Corrupt('mm: invalid header');
    FUnit := FM.NumChan * FM.Bytes;
  end;
  k := (8 - Pos mod 8) mod 8;
  if k > 0 then
  begin
    Source.ReadExact(@Pad[0], k);
    while k > 0 do
    begin
      Dec(k);
      if Pad[k] <> 0 then Corrupt('mm: invalid padding');
    end;
  end;
  FHdrLeft := Off;
  FDataLeft := Int64(DL) - 1;
  if FDataLeft > 0 then FDataLeft := FDataLeft - FDataLeft mod FUnit;
  k := MM_CHUNK div FUnit;
  if k < 1 then k := 1;
  SetLength(FBuf, k * FUnit);
  SetLength(FPrev, FUnit);
end;

{ next piece of output into FBuf: data units decoded, or raw bytes }
function TMmStage.Fill: Boolean;
var
  Want, Got, Units, k: SizeInt;
  Pp: PByte;
begin
  FPos := 0;
  FLen := 0;
  if FEof then Exit(False);
  if (FHdrLeft > 0) or (FDataLeft = 0) then
  begin
    Want := Length(FBuf);
    if (FHdrLeft > 0) and (Want > FHdrLeft) then Want := FHdrLeft;
    Got := Source.Read(@FBuf[0], Want);
    if Got = 0 then
    begin
      if FHdrLeft > 0 then Corrupt('mm: truncated stream');
      FEof := True;
      Exit(False);
    end;
    if FHdrLeft > 0 then Dec(FHdrLeft, Got);
    FLen := Got;
    Exit(True);
  end;
  Want := Length(FBuf);
  if (FDataLeft > 0) and (Want > FDataLeft) then Want := FDataLeft;
  // as many bytes as there are (a short stream ends in an incomplete unit that is raw)
  Got := 0;
  while Got < Want do
  begin
    k := Source.Read(@FBuf[Got], Want - Got);
    if k = 0 then Break;
    Inc(Got, k);
  end;
  if Got = 0 then
  begin
    if FDataLeft > 0 then Corrupt('mm: truncated stream');
    FEof := True;
    Exit(False);
  end;
  Units := Got div FUnit;
  if Units > 0 then
    if FM.Width > 0 then
    begin
      if FHavePrev then Pp := @FPrev[0] else Pp := nil;
      mm_dec_rows(@FM, @FBuf[0], Pp, Units);
      Move(FBuf[(Units - 1) * FUnit], FPrev[0], FUnit);
      FHavePrev := True;
    end
    else
      mm_dec_1d(@FM, @FBuf[0], Units);
  if FDataLeft > 0 then Dec(FDataLeft, Got);
  // a short read is the end of the stream (an incomplete unit there is raw)
  if Got < Want then FEof := True;
  FLen := Got;
  Result := True;
end;

function TMmStage.Read(Buf: PByte; Count: SizeInt): SizeInt;
var
  k: SizeInt;
begin
  Result := 0;
  if Count <= 0 then Exit;
  if not FStarted then Start;
  if FStored then Exit(Source.Read(Buf, Count));
  if FPos >= FLen then
    if not Fill then Exit(0);
  k := FLen - FPos;
  if k > Count then k := Count;
  Move(FBuf[FPos], Buf^, k);
  Inc(FPos, k);
  Result := k;
end;

end.
