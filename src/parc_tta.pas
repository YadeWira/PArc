{ tta: lossless audio codec (PArc's own code, MIT; nothing from FreeArc or TTA).

  The method keeps FreeArc's name `tta` and its parameters, but codec and stream are new.
  Samples (8/16/24/32-bit integers or 32-bit floats, any byte order, 1..255 interleaved
  channels) go through a cascade of adaptive predictors, each one predicting what the
  previous stages left; the final residual is coded with an adaptive binary range coder.

  Per channel and sample:
   1. Stereo: (L, R) -> (M, S) with S = L - R, M = R + (S >> 1) (lossless mid/side).
   2. Fixed first-order prediction: d = x - (31 * x[n-1]) >> 5.
   3. Sign-sign LMS filters on 16-bit saturated history (orders 16..1024 by level), as in
      the published NN-filter cascades of lossless audio coders: prediction = sum(c[i] *
      h[i]) >> shift, then each coefficient moves by +/- a step whose size depends on how
      large that history value was against the running mean; the dot product and the
      coefficient update of the previous sample are one pass (SSE2 on x86-64).
   4. A short adaptive stage (int32 weights, 64-bit sums) over the last values of this
      channel and the current/previous value of the previous channel.
   5. The residual, zigzag-mapped to u, is coded as its bit length b (binary decisions
      walked from the bucket the running mean of u expects, in a context of that mean),
      the two bits below the leading one (adaptive, context b) and the rest raw.
  The models learn continuously across frames; a frame only bounds the coded bytes.
  Everything is integer arithmetic with fixed wrapping, so the stream is the same on every
  platform (the assembler and the Pascal loops give identical results).

  Stream (version 1, docs/formato/FORMATO-PARC.md §6.6):
    U8 version = 1, U8 mode: 0 = stored (the rest of the stream is the data),
                             1 = coded: U8 channels, U8 bits, U8 flags, U8 level,
    then chunks until type 0:
      U8 type = 1 (coded): VInt frames, VInt rcLen, VInt rawLen, rcLen bytes, rawLen bytes
      U8 type = 2 (raw):   VInt len, len bytes (container header, trailing data, partial
                           samples, frames that did not compress)
      U8 type = 0: end; nothing may follow. }
unit parc_tta;

{$mode objfpc}{$H+}
{$R-}{$Q-}
{$pointermath on}

interface

uses
  SysUtils, parc_stream, parc_outstream, parc_mmdet;

const
  TTA_STREAM_VERSION = 1;
  TTA_MAX_LEVEL = 9;
  TTA_FRAME_VALUES = 1 shl 17;          // samples (all channels) per coded frame
  TTA_DETECT = 1 shl 20;                // bytes looked at to choose the format
  TTA_RAW_CHUNK = 1 shl 20;             // raw chunks (the decoder accepts up to this)

  ACF_BE = MMF_BE;
  ACF_U8 = MMF_U8;
  ACF_FLOAT = MMF_FLOAT;

type
  ETtaEncParams = class(Exception);

  TTtaParams = record
    Level, SkipHeader, IsFloat, NumChan, WordSize, Offset, RawData: Integer;
  end;
  TTtaEncParams = TTtaParams;

  { predictor configuration of a level (the layout of ttac_cfg in tta_core.c) }
  TAcConfig = record
    NF: LongInt;                          // sign-sign LMS filters (0..3)
    Order, Shift: array[0..2] of LongInt; // order (multiple of 16, <= 1024), output shift
    A1, A2, A3: LongInt;                  // LMS steps for large / medium / small inputs
    S2Shift, S2Step: LongInt;             // short stage: weight scale, step
    MS: LongInt;                          // 1: stereo mid/side
    R1, R2, R3, R4: LongInt;              // reserved (0)
  end;

  TAcFormat = record
    NumChan, Bits, Flags, Level: Integer;
  end;

  { the codec state of one stream (the C core's state block) }
  TAcCodec = class
  private
    FFmt: TAcFormat;
    FCfg: TAcConfig;
    FStateMem, FSaveMem: Pointer;
    FState, FSave: Pointer;
    FStateSize: SizeUInt;
    FX: array of LongInt;                 // a frame of samples, interleaved
    FRc, FRaw: TBytes;
  public
    constructor Create(const Fmt: TAcFormat; const ACfg: TAcConfig);
    destructor Destroy; override;
    property Fmt: TAcFormat read FFmt;
    property Cfg: TAcConfig read FCfg;
    { bytes -> coded frame (Frames whole sample frames at Src).  Returns False (state
      unchanged) when the coded frame would not be smaller than the input. }
    function EncodeFrame(Src: PByte; Frames: SizeInt; out Rc: PByte; out RcLen: SizeInt;
      out Raw: PByte; out RawLen: SizeInt): Boolean;
    { coded frame -> bytes (Frames x NumChan x Bits/8 at Dst); False if damaged }
    function DecodeFrame(Rc: PByte; RcLen: SizeInt; Raw: PByte; RawLen: SizeInt;
      Frames: SizeInt; Dst: PByte): Boolean;
  end;

  TTtaEncPhase = (tpDetect, tpStored, tpCoded);

  TTtaEncStage = class(TOutStage)
  private
    FPar: TTtaEncParams;
    FPhase: TTtaEncPhase;
    FBuf: TBytes;                         // detection buffer, then the pending input
    FLen: SizeInt;
    FCodec: TAcCodec;
    FHdrLeft: Int64;                      // container header bytes still to pass raw
    FDataLeft: Int64;                     // sample bytes left in the coded region (-1 = no limit)
    FFrameBytes: SizeInt;
    FSampleBytes: Integer;
    FRaw: TBytes;                         // raw bytes waiting for their chunk
    FRawLen: SizeInt;
    procedure Decide;
    procedure EmitRaw(P: PByte; N: SizeInt);
    procedure FlushRaw;
    procedure EmitVInt(V: QWord);
    procedure Process(P: PByte; N: SizeInt; Final: Boolean);
    procedure CodeFrame(P: PByte; Frames: SizeInt);
  protected
    procedure DoWrite(Buf: PByte; Count: SizeInt); override;
    procedure DoFinish; override;
  public
    constructor Create(ATarget: TOutStage; const Params: TStringArray);
    constructor Create(ATarget: TOutStage; const APar: TTtaEncParams);
    destructor Destroy; override;
  end;

  TTtaStage = class(TInStage)
  private
    FStarted, FStored, FEnd: Boolean;
    FCodec: TAcCodec;
    FOut: TBytes;
    FOutLen, FOutPos: SizeInt;
    FIn: TBytes;
    FRawLeft: Int64;                      // bytes of a raw chunk still to pass
    procedure Start;
    function NextChunk: Boolean;
  public
    constructor Create(ASource: TInStage; const APar: TTtaParams);
    destructor Destroy; override;
    function Read(Buf: PByte; Count: SizeInt): SizeInt; override;
  end;

function ParseTtaParams(const Params: TStringArray): TTtaParams;
function ParseTtaEncParams(const Params: TStringArray): TTtaEncParams;
function TtaLevelConfig(Level, Bits: Integer): TAcConfig;

var
  { experiments: when set, every level uses this configuration }
  TtaCfgOverride: Boolean = False;
  TtaCfgValue: TAcConfig;

implementation

uses
  parc_bytes;



{ ---------------------------------------------------------------------------------------- }
{ parameters }

function ParseTtaEncParams(const Params: TStringArray): TTtaEncParams;
var
  k, a, b: Integer;
  p: string;
  isF, ok: Boolean;
begin
  if (Length(Params) = 0) or (Params[0] <> 'tta') then
    raise ETtaEncParams.Create('tta: not the method tta');
  Result.Level := 3;
  Result.SkipHeader := 0;
  Result.IsFloat := 0;
  Result.NumChan := 0;
  Result.WordSize := 0;
  Result.Offset := 0;
  Result.RawData := 0;
  for k := 1 to High(Params) do
  begin
    p := Params[k];
    if p = '' then raise ETtaEncParams.Create('tta: empty parameter');
    ok := True;
    case p[1] of
      'm': ok := FaParseInt(Copy(p, 2, MaxInt), Result.Level) and (Result.Level <= TTA_MAX_LEVEL);
      's': ok := Length(p) = 1;
      'f': ok := Length(p) = 1;
      'c': ok := FaParseInt(Copy(p, 2, MaxInt), Result.NumChan);
      'w': ok := FaParseInt(Copy(p, 2, MaxInt), Result.WordSize);
      'o': ok := FaParseInt(Copy(p, 2, MaxInt), Result.Offset);
      'r': ok := FaParseInt(Copy(p, 2, MaxInt), Result.RawData) and (Result.RawData <= 1);
    else
      ok := FaParseChanWord(p, a, b, isF);
      if ok then
      begin
        Result.NumChan := a;
        Result.WordSize := b;
        Result.IsFloat := Ord(isF);
      end;
    end;
    if not ok then raise ETtaEncParams.CreateFmt('tta: invalid parameter "%s"', [p]);
    if p = 's' then Result.SkipHeader := 1;
    if p = 'f' then Result.IsFloat := 1;
  end;
end;

function ParseTtaParams(const Params: TStringArray): TTtaParams;
begin
  try
    Result := ParseTtaEncParams(Params);
  except
    on E: ETtaEncParams do raise EArcCorrupt.Create(E.Message);
  end;
end;

{ ---------------------------------------------------------------------------------------- }
{ configurations }

function TtaLevelConfig(Level, Bits: Integer): TAcConfig;
begin
  FillChar(Result, SizeOf(Result), 0);
  Result.A1 := 32; Result.A2 := 16; Result.A3 := 8;
  Result.S2Shift := 12;
  Result.S2Step := 4;
  Result.MS := 1;
  case Level of
    0, 1:
      begin
        // one LMS of 16, no short stage, mantissa raw
        Result.NF := 1;
        Result.Order[0] := 16; Result.Shift[0] := 12;
        Result.R1 := 7;
      end;
    2:
      begin
        // one LMS of 32, short stage, mantissa raw
        Result.NF := 1;
        Result.Order[0] := 32; Result.Shift[0] := 13;
        Result.R1 := 5;
      end;
    3, 4, 5:
      begin
        // LMS 256 + 16, short stage, one modeled mantissa bit
        Result.NF := 2;
        Result.Order[0] := 256; Result.Shift[0] := 15;
        Result.Order[1] := 16; Result.Shift[1] := 12;
        Result.R1 := 1;
      end;
  else
    begin
      // as 3, two modeled mantissa bits
      Result.NF := 2;
      Result.Order[0] := 256; Result.Shift[0] := 15;
      Result.Order[1] := 16; Result.Shift[1] := 12;
    end;
  end;
  if TtaCfgOverride then Result := TtaCfgValue;
end;

{ the configuration in the stream header: U8 NF, NF x (U16 order, U8 shift), U8 A1, A2, A3,
  S2Shift, S2Step, MS, R1, R2 }
function CfgBytes(const C: TAcConfig): TBytes;
var
  j, n: Integer;
begin
  SetLength(Result, 1 + 3 * C.NF + 8);
  Result[0] := C.NF;
  n := 1;
  for j := 0 to C.NF - 1 do
  begin
    Result[n] := Byte(C.Order[j]);
    Result[n + 1] := Byte(C.Order[j] shr 8);
    Result[n + 2] := C.Shift[j];
    Inc(n, 3);
  end;
  Result[n] := C.A1; Result[n + 1] := C.A2; Result[n + 2] := C.A3;
  Result[n + 3] := C.S2Shift; Result[n + 4] := C.S2Step; Result[n + 5] := C.MS; Result[n + 6] := C.R1;
  Result[n + 7] := C.R2;
end;

function ReadCfg(S: TInStage): TAcConfig;
var
  b: array[0..7] of Byte;
  j: Integer;
begin
  FillChar(Result, SizeOf(Result), 0);
  S.ReadExact(@b[0], 1);
  Result.NF := b[0];
  if Result.NF > 3 then Corrupt('tta: invalid configuration');
  for j := 0 to Result.NF - 1 do
  begin
    S.ReadExact(@b[0], 3);
    Result.Order[j] := b[0] or (b[1] shl 8);
    Result.Shift[j] := b[2];
    if (Result.Order[j] < 16) or (Result.Order[j] > 1024) or (Result.Order[j] mod 16 <> 0) or
       (Result.Shift[j] < 1) or (Result.Shift[j] > 24) then
      Corrupt('tta: invalid configuration');
  end;
  S.ReadExact(@b[0], 8);
  Result.A1 := b[0]; Result.A2 := b[1]; Result.A3 := b[2];
  Result.S2Shift := b[3]; Result.S2Step := b[4]; Result.MS := b[5]; Result.R1 := b[6]; Result.R2 := b[7];
  if (Result.S2Shift < 1) or (Result.S2Shift > 24) or (Result.MS > 1) or (Result.R1 > 7) or (Result.R2 > 1) then
    Corrupt('tta: invalid configuration');
end;

{ ---------------------------------------------------------------------------------------- }
{ the C core (src/tta/mmtta_core.c) }

{$L mmtta_core.o}
function ttac_state_size(nch: LongInt): SizeUInt; cdecl; external name 'ttac_state_size';
procedure ttac_init(st: Pointer; nch, bits: LongInt; cfg: Pointer); cdecl; external name 'ttac_init';
function ttac_encode(st: Pointer; x: PLongInt; frames: SizeUInt; rc: PByte; rccap: SizeUInt;
  out rclen: SizeUInt; raw: PByte; rawcap: SizeUInt; out rawlen: SizeUInt): LongInt; cdecl;
  external name 'ttac_encode';
function ttac_decode(st: Pointer; x: PLongInt; frames: SizeUInt; rc: PByte; rclen: SizeUInt;
  raw: PByte; rawlen: SizeUInt): LongInt; cdecl; external name 'ttac_decode';

{ ---------------------------------------------------------------------------------------- }
{ samples <-> integers }

procedure BytesToInts(Src: PByte; Dst: PLongInt; Count: SizeInt; Bits, Flags: Integer);
var
  i: SizeInt;
  v: LongWord;
begin
  case Bits of
    8:
      if Flags and ACF_U8 <> 0 then
        for i := 0 to Count - 1 do Dst[i] := LongInt(Src[i]) - 128
      else
        for i := 0 to Count - 1 do Dst[i] := ShortInt(Src[i]);
    16:
      if Flags and ACF_BE <> 0 then
        for i := 0 to Count - 1 do Dst[i] := SmallInt((Src[2 * i] shl 8) or Src[2 * i + 1])
      else
        for i := 0 to Count - 1 do Dst[i] := SmallInt(Src[2 * i] or (Src[2 * i + 1] shl 8));
    24:
      if Flags and ACF_BE <> 0 then
        for i := 0 to Count - 1 do
          Dst[i] := SarLongint(LongInt((LongWord(Src[3 * i]) shl 24) or (LongWord(Src[3 * i + 1]) shl 16) or
            (LongWord(Src[3 * i + 2]) shl 8)), 8)
      else
        for i := 0 to Count - 1 do
          Dst[i] := SarLongint(LongInt((LongWord(Src[3 * i + 2]) shl 24) or (LongWord(Src[3 * i + 1]) shl 16) or
            (LongWord(Src[3 * i]) shl 8)), 8);
  else
    for i := 0 to Count - 1 do
    begin
      if Flags and ACF_BE <> 0 then
        v := (LongWord(Src[4 * i]) shl 24) or (LongWord(Src[4 * i + 1]) shl 16) or
          (LongWord(Src[4 * i + 2]) shl 8) or Src[4 * i + 3]
      else
        v := LongWord(Src[4 * i]) or (LongWord(Src[4 * i + 1]) shl 8) or
          (LongWord(Src[4 * i + 2]) shl 16) or (LongWord(Src[4 * i + 3]) shl 24);
      // floats: sign-magnitude -> two's complement order (an involution)
      if (Flags and ACF_FLOAT <> 0) and (LongInt(v) < 0) then v := v xor $7FFFFFFF;
      Dst[i] := LongInt(v);
    end;
  end;
end;

procedure IntsToBytes(Src: PLongInt; Dst: PByte; Count: SizeInt; Bits, Flags: Integer);
var
  i: SizeInt;
  v: LongWord;
begin
  case Bits of
    8:
      if Flags and ACF_U8 <> 0 then
        for i := 0 to Count - 1 do Dst[i] := Byte(Src[i] + 128)
      else
        for i := 0 to Count - 1 do Dst[i] := Byte(Src[i]);
    16:
      if Flags and ACF_BE <> 0 then
        for i := 0 to Count - 1 do
        begin
          Dst[2 * i] := Byte(Src[i] shr 8);
          Dst[2 * i + 1] := Byte(Src[i]);
        end
      else
        for i := 0 to Count - 1 do
        begin
          Dst[2 * i] := Byte(Src[i]);
          Dst[2 * i + 1] := Byte(Src[i] shr 8);
        end;
    24:
      if Flags and ACF_BE <> 0 then
        for i := 0 to Count - 1 do
        begin
          Dst[3 * i] := Byte(Src[i] shr 16);
          Dst[3 * i + 1] := Byte(Src[i] shr 8);
          Dst[3 * i + 2] := Byte(Src[i]);
        end
      else
        for i := 0 to Count - 1 do
        begin
          Dst[3 * i] := Byte(Src[i]);
          Dst[3 * i + 1] := Byte(Src[i] shr 8);
          Dst[3 * i + 2] := Byte(Src[i] shr 16);
        end;
  else
    for i := 0 to Count - 1 do
    begin
      v := LongWord(Src[i]);
      if (Flags and ACF_FLOAT <> 0) and (LongInt(v) < 0) then v := v xor $7FFFFFFF;
      if Flags and ACF_BE <> 0 then
      begin
        Dst[4 * i] := Byte(v shr 24);
        Dst[4 * i + 1] := Byte(v shr 16);
        Dst[4 * i + 2] := Byte(v shr 8);
        Dst[4 * i + 3] := Byte(v);
      end
      else
      begin
        Dst[4 * i] := Byte(v);
        Dst[4 * i + 1] := Byte(v shr 8);
        Dst[4 * i + 2] := Byte(v shr 16);
        Dst[4 * i + 3] := Byte(v shr 24);
      end;
    end;
  end;
end;

{ ---------------------------------------------------------------------------------------- }
{ codec }

constructor TAcCodec.Create(const Fmt: TAcFormat; const ACfg: TAcConfig);
var
  Frames: SizeInt;
begin
  inherited Create;
  FFmt := Fmt;
  FCfg := ACfg;
  FStateSize := ttac_state_size(Fmt.NumChan);
  FStateMem := GetMem(FStateSize + 64);
  FState := Pointer((PtrUInt(FStateMem) + 63) and not PtrUInt(63));
  ttac_init(FState, Fmt.NumChan, Fmt.Bits, @FCfg);
  Frames := TTA_FRAME_VALUES div Fmt.NumChan;
  if Frames < 1 then Frames := 1;
  SetLength(FX, Frames * Fmt.NumChan);
end;

destructor TAcCodec.Destroy;
begin
  FreeMem(FStateMem);
  if FSaveMem <> nil then FreeMem(FSaveMem);
  inherited Destroy;
end;

function TAcCodec.EncodeFrame(Src: PByte; Frames: SizeInt; out Rc: PByte; out RcLen: SizeInt;
  out Raw: PByte; out RawLen: SizeInt): Boolean;
var
  Bytes: SizeInt;
  rl, wl: SizeUInt;
begin
  Bytes := Frames * FFmt.NumChan * (FFmt.Bits div 8);
  BytesToInts(Src, @FX[0], Frames * FFmt.NumChan, FFmt.Bits, FFmt.Flags);
  // keep the state: a frame that does not compress is stored and must not change it
  if FSaveMem = nil then
  begin
    FSaveMem := GetMem(FStateSize + 64);
    FSave := Pointer((PtrUInt(FSaveMem) + 63) and not PtrUInt(63));
  end;
  Move(FState^, FSave^, FStateSize);
  if Length(FRc) < Bytes + 64 then SetLength(FRc, Bytes + 64);
  if Length(FRaw) < Bytes + 64 then SetLength(FRaw, Bytes + 64);
  Result := (ttac_encode(FState, @FX[0], Frames, @FRc[0], Bytes, rl, @FRaw[0], Bytes, wl) = 0) and
    (SizeInt(rl + wl) + 12 < Bytes);
  if not Result then
  begin
    Move(FSave^, FState^, FStateSize);
    Exit;
  end;
  Rc := @FRc[0];
  RcLen := rl;
  Raw := @FRaw[0];
  RawLen := wl;
end;

function TAcCodec.DecodeFrame(Rc: PByte; RcLen: SizeInt; Raw: PByte; RawLen: SizeInt;
  Frames: SizeInt; Dst: PByte): Boolean;
begin
  Result := ttac_decode(FState, @FX[0], Frames, Rc, RcLen, Raw, RawLen) = 0;
  IntsToBytes(@FX[0], Dst, Frames * FFmt.NumChan, FFmt.Bits, FFmt.Flags);
end;

{ ---------------------------------------------------------------------------------------- }
{ encoder stage }

constructor TTtaEncStage.Create(ATarget: TOutStage; const Params: TStringArray);
begin
  Create(ATarget, ParseTtaEncParams(Params));
end;

constructor TTtaEncStage.Create(ATarget: TOutStage; const APar: TTtaEncParams);
begin
  inherited Create(ATarget);
  FPar := APar;
  FPhase := tpDetect;
  SetLength(FBuf, TTA_DETECT);
  FLen := 0;
end;

destructor TTtaEncStage.Destroy;
begin
  FCodec.Free;
  inherited Destroy;
end;

procedure TTtaEncStage.EmitVInt(V: QWord);
var
  b: array[0..9] of Byte;
  n: Integer;
begin
  n := 0;
  repeat
    b[n] := V and $7F;
    V := V shr 7;
    if V <> 0 then b[n] := b[n] or $80;
    Inc(n);
  until V = 0;
  Emit(@b[0], n);
end;

{ raw bytes are gathered into chunks of 1 MB, so the stream does not depend on write sizes }
procedure TTtaEncStage.EmitRaw(P: PByte; N: SizeInt);
var
  k: SizeInt;
begin
  if Length(FRaw) < TTA_RAW_CHUNK then SetLength(FRaw, TTA_RAW_CHUNK);
  while N > 0 do
  begin
    k := TTA_RAW_CHUNK - FRawLen;
    if k > N then k := N;
    Move(P^, FRaw[FRawLen], k);
    Inc(FRawLen, k);
    Inc(P, k);
    Dec(N, k);
    if FRawLen = TTA_RAW_CHUNK then FlushRaw;
  end;
end;

procedure TTtaEncStage.FlushRaw;
var
  t: Byte;
begin
  if FRawLen = 0 then Exit;
  t := 2;
  Emit(@t, 1);
  EmitVInt(FRawLen);
  Emit(@FRaw[0], FRawLen);
  FRawLen := 0;
end;

procedure TTtaEncStage.Decide;
var
  L: TMmLayout;
  Ok: Boolean;
  Fmt: TAcFormat;
  R: Double;
  Hdr: array[0..5] of Byte;
  Cfg: TAcConfig;
  CB: TBytes;
begin
  Ok := False;
  FillChar(L, SizeOf(L), 0);
  L.DataLen := -1;
  if (FPar.Level > 0) and (FPar.RawData = 0) then
  begin
    if (FPar.NumChan > 0) or (FPar.WordSize > 0) or (FPar.IsFloat <> 0) then
    begin
      L.NumChan := FPar.NumChan;
      if L.NumChan = 0 then L.NumChan := 1;
      L.Bits := FPar.WordSize;
      if L.Bits = 0 then
        if FPar.IsFloat <> 0 then L.Bits := 32 else L.Bits := 8;
      L.Offset := FPar.Offset;
      if FPar.IsFloat <> 0 then L.Flags := ACF_FLOAT
      else if L.Bits = 8 then L.Flags := ACF_U8;
      Ok := (L.Bits in [8, 16, 24, 32]) and ((FPar.IsFloat = 0) or (L.Bits = 32));
    end
    else
    begin
      if FPar.SkipHeader = 0 then Ok := MmParseAudioHeader(@FBuf[0], FLen, L);
      if not Ok then
      begin
        Ok := MmDetectStats(@FBuf[0], FLen, [1, 2, 4, 6], [1, 2, 3], True, 0.80, L, R);
        L.Offset := 0;
        L.DataLen := -1;
      end;
    end;
    if L.NumChan > 255 then Ok := False;
  end;
  Hdr[0] := TTA_STREAM_VERSION;
  if not Ok then
  begin
    Hdr[1] := 0;
    Emit(@Hdr[0], 2);
    FPhase := tpStored;
    Exit;
  end;
  Fmt.NumChan := L.NumChan;
  Fmt.Bits := L.Bits;
  Fmt.Flags := L.Flags and (ACF_BE or ACF_U8 or ACF_FLOAT);
  Fmt.Level := FPar.Level;
  if Fmt.Level < 1 then Fmt.Level := 1;
  Hdr[1] := 1;
  Hdr[2] := Fmt.NumChan;
  Hdr[3] := Fmt.Bits;
  Hdr[4] := Fmt.Flags;
  Hdr[5] := Fmt.Level;
  Emit(@Hdr[0], 6);
  Cfg := TtaLevelConfig(Fmt.Level, Fmt.Bits);
  CB := CfgBytes(Cfg);
  Emit(@CB[0], Length(CB));
  FCodec := TAcCodec.Create(Fmt, Cfg);
  FSampleBytes := Fmt.NumChan * (Fmt.Bits div 8);
  FFrameBytes := (TTA_FRAME_VALUES div Fmt.NumChan) * FSampleBytes;
  if FFrameBytes < FSampleBytes then FFrameBytes := FSampleBytes;
  FHdrLeft := L.Offset;
  FDataLeft := L.DataLen;
  if FDataLeft >= 0 then FDataLeft := FDataLeft - FDataLeft mod FSampleBytes;
  if Length(FBuf) < FFrameBytes then SetLength(FBuf, FFrameBytes);
  FPhase := tpCoded;
end;

procedure TTtaEncStage.CodeFrame(P: PByte; Frames: SizeInt);
var
  Rc, Raw: PByte;
  RcLen, RawLen: SizeInt;
  t: Byte;
begin
  if FCodec.EncodeFrame(P, Frames, Rc, RcLen, Raw, RawLen) then
  begin
    FlushRaw;
    t := 1;
    Emit(@t, 1);
    EmitVInt(Frames);
    EmitVInt(RcLen);
    EmitVInt(RawLen);
    Emit(Rc, RcLen);
    if RawLen > 0 then Emit(Raw, RawLen);
  end
  else
    EmitRaw(P, Frames * FSampleBytes);
end;

{ coded phase: P/N new input appended to the pending bytes }
procedure TTtaEncStage.Process(P: PByte; N: SizeInt; Final: Boolean);
var
  k, Whole: SizeInt;
begin
  while (N > 0) or (FLen > 0) do
  begin
    // container header
    if FHdrLeft > 0 then
    begin
      if FLen > 0 then
      begin
        k := FLen;
        if k > FHdrLeft then k := FHdrLeft;
        EmitRaw(@FBuf[0], k);
        Move(FBuf[k], FBuf[0], FLen - k);
        Dec(FLen, k);
      end
      else
      begin
        k := N;
        if k > FHdrLeft then k := FHdrLeft;
        EmitRaw(P, k);
        Inc(P, k);
        Dec(N, k);
      end;
      Dec(FHdrLeft, k);
      Continue;
    end;
    // after the coded region: raw
    if FDataLeft = 0 then
    begin
      if FLen > 0 then
      begin
        EmitRaw(@FBuf[0], FLen);
        FLen := 0;
      end;
      EmitRaw(P, N);
      Exit;
    end;
    // fill a frame
    k := FFrameBytes;
    if (FDataLeft > 0) and (k > FDataLeft) then k := FDataLeft;
    if (FLen = 0) and (N >= k) then
    begin
      CodeFrame(P, k div FSampleBytes);
      Inc(P, k);
      Dec(N, k);
      if FDataLeft > 0 then Dec(FDataLeft, k);
      Continue;
    end;
    Whole := k - FLen;
    if Whole > N then Whole := N;
    Move(P^, FBuf[FLen], Whole);
    Inc(FLen, Whole);
    Inc(P, Whole);
    Dec(N, Whole);
    if FLen = k then
    begin
      CodeFrame(@FBuf[0], k div FSampleBytes);
      FLen := 0;
      if FDataLeft > 0 then Dec(FDataLeft, k);
      Continue;
    end;
    // N = 0 here: wait for more unless this is the end
    if not Final then Exit;
    Whole := FLen - FLen mod FSampleBytes;
    if Whole > 0 then CodeFrame(@FBuf[0], Whole div FSampleBytes);
    if FLen > Whole then EmitRaw(@FBuf[Whole], FLen - Whole);
    FLen := 0;
    Exit;
  end;
end;

procedure TTtaEncStage.DoWrite(Buf: PByte; Count: SizeInt);
var
  k: SizeInt;
  Tmp: TBytes;
begin
  if Count <= 0 then Exit;
  case FPhase of
    tpDetect:
      begin
        k := TTA_DETECT - FLen;
        if k > Count then k := Count;
        Move(Buf^, FBuf[FLen], k);
        Inc(FLen, k);
        Inc(Buf, k);
        Dec(Count, k);
        if FLen < TTA_DETECT then Exit;
        Decide;
        if FPhase = tpStored then
        begin
          Emit(@FBuf[0], FLen);
          FLen := 0;
          if Count > 0 then Emit(Buf, Count);
          Exit;
        end;
        // re-feed the detection buffer
        Tmp := Copy(FBuf, 0, FLen);
        FLen := 0;
        Process(@Tmp[0], Length(Tmp), False);
        if Count > 0 then Process(Buf, Count, False);
      end;
    tpStored:
      Emit(Buf, Count);
    tpCoded:
      Process(Buf, Count, False);
  end;
end;

procedure TTtaEncStage.DoFinish;
var
  t: Byte;
  Tmp: TBytes;
  k: SizeInt;
begin
  if FPhase = tpDetect then
  begin
    Decide;
    if FPhase = tpStored then
    begin
      if FLen > 0 then Emit(@FBuf[0], FLen);
      FLen := 0;
      Exit;
    end;
    k := FLen;
    Tmp := Copy(FBuf, 0, k);
    FLen := 0;
    if k > 0 then Process(@Tmp[0], k, True) else Process(nil, 0, True);
  end
  else if FPhase = tpCoded then
    Process(nil, 0, True);
  if FPhase = tpCoded then
  begin
    FlushRaw;
    t := 0;
    Emit(@t, 1);
  end;
end;

{ ---------------------------------------------------------------------------------------- }
{ decoder stage }

constructor TTtaStage.Create(ASource: TInStage; const APar: TTtaParams);
begin
  inherited Create(ASource);
end;

destructor TTtaStage.Destroy;
begin
  FCodec.Free;
  inherited Destroy;
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
    if (sh = 63) and (b > 1) then Corrupt('tta: invalid number');
    Result := Result or (QWord(b and $7F) shl sh);
    Inc(sh, 7);
    if (sh > 63) and (b and $80 <> 0) then Corrupt('tta: invalid number');
  until b and $80 = 0;
end;

procedure TTtaStage.Start;
var
  Hdr: array[0..3] of Byte;
  b: Byte;
  Fmt: TAcFormat;
begin
  FStarted := True;
  if not Source.ReadExactOrEof(@b, 1) then Corrupt('tta: empty stream');
  if b <> TTA_STREAM_VERSION then Corrupt('tta: unknown stream version (not a PArc 0.0.7+ tta stream)');
  Source.ReadExact(@b, 1);
  if b = 0 then
  begin
    FStored := True;
    Exit;
  end;
  if b <> 1 then Corrupt('tta: invalid mode');
  Source.ReadExact(@Hdr[0], 4);
  Fmt.NumChan := Hdr[0];
  Fmt.Bits := Hdr[1];
  Fmt.Flags := Hdr[2];
  Fmt.Level := Hdr[3];
  if (Fmt.NumChan = 0) or not (Fmt.Bits in [8, 16, 24, 32]) or (Fmt.Flags and not 7 <> 0) or
     ((Fmt.Flags and ACF_FLOAT <> 0) and (Fmt.Bits <> 32)) or ((Fmt.Flags and ACF_U8 <> 0) and (Fmt.Bits <> 8)) or
     (Fmt.Level < 1) or (Fmt.Level > TTA_MAX_LEVEL) then
    Corrupt('tta: invalid format');
  FCodec := TAcCodec.Create(Fmt, ReadCfg(Source));
end;

function TTtaStage.NextChunk: Boolean;
var
  t: Byte;
  Frames, RcLen, RawLen, MaxFrames, Bytes: QWord;
  SampleBytes: Integer;
begin
  Result := False;
  if FEnd then Exit;
  Source.ReadExact(@t, 1);
  case t of
    0:
      begin
        if Source.Read(@t, 1) <> 0 then Corrupt('tta: data after the end');
        FEnd := True;
      end;
    1:
      begin
        SampleBytes := FCodec.Fmt.NumChan * (FCodec.Fmt.Bits div 8);
        MaxFrames := TTA_FRAME_VALUES div FCodec.Fmt.NumChan;
        if MaxFrames < 1 then MaxFrames := 1;
        Frames := ReadVIntFrom(Source);
        RcLen := ReadVIntFrom(Source);
        RawLen := ReadVIntFrom(Source);
        Bytes := Frames * SampleBytes;
        if (Frames = 0) or (Frames > MaxFrames) or (RcLen < 5) or (RcLen > 2 * Bytes + 64) or
           (RawLen > Bytes) then
          Corrupt('tta: invalid frame');
        if QWord(Length(FIn)) < RcLen + RawLen then SetLength(FIn, RcLen + RawLen);
        Source.ReadExact(@FIn[0], RcLen + RawLen);
        if QWord(Length(FOut)) < Bytes then SetLength(FOut, Bytes);
        if not FCodec.DecodeFrame(@FIn[0], RcLen, @FIn[RcLen], RawLen, Frames, @FOut[0]) then
          Corrupt('tta: damaged frame');
        FOutLen := Bytes;
        FOutPos := 0;
        Result := True;
      end;
    2:
      begin
        FRawLeft := ReadVIntFrom(Source);
        if (FRawLeft = 0) or (FRawLeft > TTA_RAW_CHUNK) then Corrupt('tta: invalid raw chunk');
        Result := True;
      end;
  else
    Corrupt('tta: invalid chunk');
  end;
end;

function TTtaStage.Read(Buf: PByte; Count: SizeInt): SizeInt;
var
  k: SizeInt;
begin
  Result := 0;
  if Count <= 0 then Exit;
  if not FStarted then Start;
  if FStored then Exit(Source.Read(Buf, Count));
  while Result = 0 do
  begin
    if FRawLeft > 0 then
    begin
      k := Count;
      if k > FRawLeft then k := FRawLeft;
      Source.ReadExact(Buf, k);
      Dec(FRawLeft, k);
      Exit(k);
    end;
    if FOutPos < FOutLen then
    begin
      k := FOutLen - FOutPos;
      if k > Count then k := Count;
      Move(FOut[FOutPos], Buf^, k);
      Inc(FOutPos, k);
      Exit(k);
    end;
    if not NextChunk then Exit(0);
  end;
end;

end.
