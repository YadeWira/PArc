{ cm: PArc's context-mixing compressor (own code, MIT; nothing from lpaq/paq/FreeArc).

  The model and the arithmetic coder are in src/cm/pcm_core.c (freestanding C, linked as
  pcm_core.o); this unit wraps them as pipeline stages. Bitwise prediction from:
   - bit-history states (one byte per context and bit position) for order 0 and 1 (direct
     tables) and orders 2, 3, 4, 6, word, word bigram, two sparse contexts and an indirect one
     (a hash table of 64-byte buckets holding four 16-byte nibble slots with an 8-bit check);
   - adaptive state maps (state -> probability, rate 1/n);
   - a match model over a history ring (longest recent match, predicted bit and length);
   - six mixers (SSE2 on x86-64, bit-exact portable C elsewhere) with weight sets selected by
     the partial byte, match state, context order, earlier bytes and byte classes; a second-layer
     mixer and two interpolated secondary estimators.
  Blocks of 64 KB whose order-0 entropy is close to 8 bits (already compressed data) are coded
  as raw bits without the model, which keeps such data at full speed in both directions.
  Everything is integer arithmetic, so the output is the same on every platform.

  Method: cm[:<level>]  level 1..9 (default 6: 128 MB contexts + 16 MB history + 16 MB match
  table, ~170 MB per stream). Inputs up to 1 MB get proportionally smaller tables.

  Stream (version 1, docs/formato/FORMATO-PARC.md §6.6):
    U8 version (= 1), U8 htbits, U8 wbits, U8 mtbits, U8 flags (bit 0: U32 size follows, for
    inputs up to 16 MB; the decoder then decodes it all at once and frees the model), then one
    arithmetic-coded stream: per block: bit "end" (p = 1/2); bit "modelled" (adaptive); bit
    "full" (p = 1/2), and if not full 16 bits of length (1..65535); then the bytes, MSB first,
    either predicted by the model or with p = 1/2. After the end bit the coder writes 4 bytes. }
unit parc_cm;

{$mode objfpc}{$H+}
{$Q-}{$R-}
{$pointermath on}

interface

uses
  SysUtils, parc_stream, parc_outstream;

const
  CM_STREAM_VERSION = 1;
  CM_DEFAULT_LEVEL = 6;
  CM_BLOCK = 65536;

type
  ECmParams = class(Exception);

  TCmEncStage = class(TOutStage)
  private
    FLevel: Integer;
    FRaw, FModel: Pointer;
    FBuf: array of Byte;     // pending input (up to CM_PROBE before the start, then a block)
    FLen: SizeInt;
    FStarted: Boolean;
    FErr: TObject;
    procedure Start(Total: SizeInt);
    procedure Flush(All: Boolean);
    procedure CheckErr;
  protected
    procedure DoWrite(Buf: PByte; Count: SizeInt); override;
    procedure DoFinish; override;
  public
    constructor Create(ATarget: TOutStage; ALevel: Integer = CM_DEFAULT_LEVEL);
    destructor Destroy; override;
  end;

  TCmDecStage = class(TInStage)
  private
    FRaw, FModel: Pointer;
    FOut: array of Byte;
    FPos, FLen: SizeInt;
    FStarted, FEnd: Boolean;
    FErr: TObject;
    procedure Start;
    procedure CheckErr;
  public
    destructor Destroy; override;
    function Read(Buf: PByte; Count: SizeInt): SizeInt; override;
  end;

{ cm[:<level>] -> level (1..9). }
function ParseCmLevel(const Parts: TStringArray): Integer;
{ Memory of one encoder for DataSize bytes (0 = unknown). }
function CmEncMemory(Level: Integer; DataSize: Int64): Int64;
{ Compress / decompress a whole buffer (tests and tools). }
function CmCompressMem(Src: PByte; SrcLen: SizeInt; out Dst: TBytes; Level: Integer = CM_DEFAULT_LEVEL): Boolean;
function CmDecompressMem(Src: PByte; SrcLen: SizeInt; out Dst: TBytes): Boolean;

implementation

uses
  parc_bytes;

{$L pcm_core.o}

type
  TPcmIo = function(Ctx: Pointer; Buf: PByte; N: LongWord): LongWord; cdecl;

function pcm_memsize(htbits, wbits, mtbits: LongWord): SizeUInt; cdecl; external name 'pcm_memsize';
procedure pcm_level_sizes(level: LongInt; out htb, wb, mtb: LongWord); cdecl; external name 'pcm_level_sizes';
function pcm_open(mem: Pointer; htbits, wbits, mtbits: LongWord; io: TPcmIo; ctx: Pointer;
  decoding: LongInt): LongInt; cdecl; external name 'pcm_open';
procedure pcm_enc_block(mem: Pointer; src: PByte; n: LongWord); cdecl; external name 'pcm_enc_block';
procedure pcm_enc_end(mem: Pointer); cdecl; external name 'pcm_enc_end';
function pcm_dec_block(mem: Pointer; dst: PByte): LongInt; cdecl; external name 'pcm_dec_block';

const
  CM_SMALL = 1 shl 20;      // inputs up to this size get tables sized to them
  CM_PROBE = 16 shl 20;     // inputs up to this size: the header carries the size and the
                            // decoder decodes the whole stream at once, then frees the model

function ParseCmLevel(const Parts: TStringArray): Integer;
var
  k: Integer;
begin
  Result := CM_DEFAULT_LEVEL;
  for k := 1 to High(Parts) do
    if Parts[k] <> '' then
    begin
      if not TryStrToInt(Parts[k], Result) or (Result < 1) or (Result > 9) then
        raise ECmParams.CreateFmt('cm: bad level "%s" (1..9)', [Parts[k]]);
    end;
end;

function CeilLog2(V: QWord): LongWord;
begin
  Result := 0;
  while (QWord(1) shl Result) < V do Inc(Result);
end;

{ Table sizes for a stream: the level's, or smaller ones for a small input (Total >= 0). }
procedure CmSizes(Level: Integer; Total: Int64; out htb, wb, mtb: LongWord);
var
  b: LongWord;
begin
  pcm_level_sizes(Level, htb, wb, mtb);
  if (Total >= 0) and (Total <= CM_SMALL) then
  begin
    // 4 buckets (16 nibble slots) per input byte at most; the history and the match table
    // need not be larger than the input
    b := CeilLog2(QWord(Total) * 4 + 1);
    if b < 10 then b := 10;
    if b < htb then htb := b;
    b := CeilLog2(QWord(Total) + 1024);
    if b < 16 then b := 16;
    if b < wb then wb := b;
    b := CeilLog2(QWord(Total) + 1);
    if b < 12 then b := 12;
    if b < mtb then mtb := b;
  end;
end;

function CmEncMemory(Level: Integer; DataSize: Int64): Int64;
var
  htb, wb, mtb: LongWord;
begin
  if DataSize > 0 then CmSizes(Level, DataSize, htb, wb, mtb)
  else CmSizes(Level, -1, htb, wb, mtb);
  Result := Int64(pcm_memsize(htb, wb, mtb)) + 2 * CM_BLOCK + (1 shl 20);
  if (DataSize <= 0) or (DataSize > CM_PROBE) then Inc(Result, CM_PROBE)
  else Inc(Result, DataSize);
end;

function AllocModel(htb, wb, mtb: LongWord; out Raw: Pointer): Pointer;
var
  sz: SizeUInt;
begin
  sz := pcm_memsize(htb, wb, mtb);
  GetMem(Raw, sz + 64);
  Result := Pointer((PtrUInt(Raw) + 63) and not PtrUInt(63));
  FillChar(Result^, sz, 0);
end;

{ ---- encoder ---- }

function EncIo(Ctx: Pointer; Buf: PByte; N: LongWord): LongWord; cdecl;
var
  s: TCmEncStage;
begin
  s := TCmEncStage(Ctx);
  Result := N;
  if s.FErr <> nil then Exit;
  try
    s.Emit(Buf, N);
  except
    s.FErr := TObject(AcquireExceptionObject);
  end;
end;

constructor TCmEncStage.Create(ATarget: TOutStage; ALevel: Integer);
begin
  inherited Create(ATarget);
  if (ALevel < 1) or (ALevel > 9) then ALevel := CM_DEFAULT_LEVEL;
  FLevel := ALevel;
end;

destructor TCmEncStage.Destroy;
begin
  if FRaw <> nil then FreeMem(FRaw);
  FErr.Free;
  inherited Destroy;
end;

procedure TCmEncStage.CheckErr;
var
  e: TObject;
begin
  if FErr <> nil then
  begin
    e := FErr;
    FErr := nil;
    raise e;
  end;
end;

procedure TCmEncStage.Start(Total: SizeInt);
var
  htb, wb, mtb: LongWord;
  h: array[0..8] of Byte;
  hl: Integer;
begin
  CmSizes(FLevel, Total, htb, wb, mtb);
  h[0] := CM_STREAM_VERSION; h[1] := htb; h[2] := wb; h[3] := mtb;
  hl := 5;
  if Total >= 0 then
  begin
    h[4] := 1;
    h[5] := Byte(Total); h[6] := Byte(Total shr 8); h[7] := Byte(Total shr 16); h[8] := Byte(Total shr 24);
    hl := 9;
  end
  else h[4] := 0;
  Emit(@h[0], hl);
  FModel := AllocModel(htb, wb, mtb, FRaw);
  if pcm_open(FModel, htb, wb, mtb, @EncIo, Self, 0) <> 0 then
    raise Exception.Create('cm: bad table sizes');
  FStarted := True;
end;

{ Code the whole blocks of FBuf (and the tail too if All). }
procedure TCmEncStage.Flush(All: Boolean);
var
  p, n: SizeInt;
begin
  p := 0;
  while (FLen - p >= CM_BLOCK) or (All and (FLen - p > 0)) do
  begin
    n := FLen - p;
    if n > CM_BLOCK then n := CM_BLOCK;
    pcm_enc_block(FModel, @FBuf[p], n);
    CheckErr;
    Inc(p, n);
  end;
  if p > 0 then
  begin
    if FLen > p then Move(FBuf[p], FBuf[0], FLen - p);
    Dec(FLen, p);
  end;
end;

procedure TCmEncStage.DoWrite(Buf: PByte; Count: SizeInt);
var
  n: SizeInt;
begin
  while Count > 0 do
  begin
    if not FStarted then
    begin
      n := CM_PROBE + 1 - FLen;
      if n > Count then n := Count;
      if FLen + n > Length(FBuf) then
      begin
        if 2 * Length(FBuf) > FLen + n then SetLength(FBuf, 2 * Length(FBuf))
        else SetLength(FBuf, FLen + n);
      end;
      Move(Buf^, FBuf[FLen], n);
      Inc(FLen, n); Inc(Buf, n); Dec(Count, n);
      if FLen > CM_PROBE then
      begin
        Start(-1);     // large input: the level's sizes
        Flush(False);
        if Length(FBuf) > 2 * CM_BLOCK then
        begin
          // keep only a block's worth of buffer from now on
          SetLength(FBuf, 2 * CM_BLOCK);
        end;
      end;
    end
    else
    begin
      n := Length(FBuf) - FLen;
      if n > Count then n := Count;
      Move(Buf^, FBuf[FLen], n);
      Inc(FLen, n); Inc(Buf, n); Dec(Count, n);
      if FLen >= CM_BLOCK then Flush(False);
    end;
  end;
end;

procedure TCmEncStage.DoFinish;
begin
  if not FStarted then Start(FLen);
  Flush(True);
  pcm_enc_end(FModel);
  CheckErr;
  FreeMem(FRaw);
  FRaw := nil; FModel := nil;
  SetLength(FBuf, 0);
end;

{ ---- decoder ---- }

function DecIo(Ctx: Pointer; Buf: PByte; N: LongWord): LongWord; cdecl;
var
  s: TCmDecStage;
begin
  s := TCmDecStage(Ctx);
  Result := 0;
  if s.FErr <> nil then Exit;
  try
    Result := s.Source.Read(Buf, N);
  except
    s.FErr := TObject(AcquireExceptionObject);
    Result := 0;
  end;
end;

destructor TCmDecStage.Destroy;
begin
  if FRaw <> nil then FreeMem(FRaw);
  FErr.Free;
  inherited Destroy;
end;

procedure TCmDecStage.Start;
var
  h: array[0..8] of Byte;
  total, got: SizeInt;
  r: LongInt;
begin
  FStarted := True;
  if not Source.ReadExactOrEof(@h[0], 5) then Corrupt('cm: empty stream');
  if h[0] <> CM_STREAM_VERSION then Corrupt('cm: unknown stream version');
  if (h[1] < 10) or (h[1] > 24) or (h[2] < 16) or (h[2] > 27) or (h[3] < 12) or (h[3] > 25) or
     (h[4] > 1) then
    Corrupt('cm: bad header');
  total := -1;
  if h[4] = 1 then
  begin
    Source.ReadExact(@h[5], 4);
    total := SizeInt(LongWord(h[5]) or (LongWord(h[6]) shl 8) or (LongWord(h[7]) shl 16) or
      (LongWord(h[8]) shl 24));
    if total > CM_PROBE then Corrupt('cm: bad header');
  end;
  FModel := AllocModel(h[1], h[2], h[3], FRaw);
  pcm_open(FModel, h[1], h[2], h[3], @DecIo, Self, 1);
  if total < 0 then
  begin
    SetLength(FOut, CM_BLOCK);
    Exit;
  end;
  // known (small) size: decode it all now and free the model before the stages above
  // allocate theirs
  SetLength(FOut, total + CM_BLOCK);
  got := 0;
  repeat
    r := pcm_dec_block(FModel, @FOut[got]);
    CheckErr;
    if r < 0 then Corrupt('cm: damaged stream');
    Inc(got, r);
    if got > total then Corrupt('cm: damaged stream');
  until r = 0;
  if got <> total then Corrupt('cm: damaged stream');
  FreeMem(FRaw);
  FRaw := nil; FModel := nil;
  FEnd := True;
  FPos := 0;
  FLen := total;
end;

procedure TCmDecStage.CheckErr;
var
  e: TObject;
begin
  if FErr <> nil then
  begin
    e := FErr;
    FErr := nil;
    raise e;
  end;
end;

function TCmDecStage.Read(Buf: PByte; Count: SizeInt): SizeInt;
var
  r: LongInt;
begin
  Result := 0;
  if not FStarted then Start;
  while (FPos >= FLen) and not FEnd do
  begin
    r := pcm_dec_block(FModel, @FOut[0]);
    CheckErr;
    if r < 0 then Corrupt('cm: damaged stream');
    if r = 0 then
    begin
      FEnd := True;
      FreeMem(FRaw);
      FRaw := nil; FModel := nil;
    end;
    FPos := 0;
    FLen := r;
  end;
  if FPos >= FLen then Exit(0);
  Result := FLen - FPos;
  if Result > Count then Result := Count;
  Move(FOut[FPos], Buf^, Result);
  Inc(FPos, Result);
end;

{ ---- whole buffers ---- }

function CmCompressMem(Src: PByte; SrcLen: SizeInt; out Dst: TBytes; Level: Integer): Boolean;
var
  sink: TMemSink;
  st: TCmEncStage;
begin
  sink := TMemSink.Create;
  st := TCmEncStage.Create(sink, Level);
  try
    st.Write(Src, SrcLen);
    st.Finish;
    Dst := sink.Bytes;
    Result := True;
  finally
    st.Free;
  end;
end;

function CmDecompressMem(Src: PByte; SrcLen: SizeInt; out Dst: TBytes): Boolean;
var
  st: TCmDecStage;
  n, got: SizeInt;
begin
  st := TCmDecStage.Create(TMemStage.Create(Src, SrcLen));
  try
    got := 0;
    SetLength(Dst, 1 shl 16);
    repeat
      if got = Length(Dst) then SetLength(Dst, 2 * Length(Dst));
      n := st.Read(@Dst[got], Length(Dst) - got);
      Inc(got, n);
    until n = 0;
    SetLength(Dst, got);
    Result := True;
  finally
    st.Free;
  end;
end;

end.
