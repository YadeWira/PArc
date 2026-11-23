{ mmdet: layout detection for the multimedia methods `tta` and `mm` (PArc's own code, MIT;
  nothing from FreeArc).

  Two ways to find how a stream is laid out:
   1. Container headers: RIFF/RIFX WAVE (PCM, IEEE float, WAVE_FORMAT_EXTENSIBLE), AIFF/AIFC
      (NONE/twos/sowt/fl32/raw), BMP (Windows and OS/2 headers), TGA (uncompressed), binary
      PGM/PPM (P5/P6) and baseline uncompressed TIFF (contiguous strips, chunky pixels).
      The header gives the sample format, the offset of the samples and (for images) the row
      length, so nothing has to be guessed.
   2. Statistics, for headerless data: every candidate layout (channels x bytes per sample x
      byte order) is scored by the cost of its order-1/order-2 prediction residuals, about the
      bits per input byte a residual coder would need; the cheapest one wins if it beats the
      order-0 entropy of the raw bytes by the given factor.
  Everything is integer arithmetic on the bytes given, so the answer is the same on every
  platform. }
unit parc_mmdet;

{$mode objfpc}{$H+}
{$R-}{$Q-}
{$pointermath on}

interface

const
  { TMmLayout.Flags }
  MMF_BE    = 1;      // samples are big endian
  MMF_U8    = 2;      // 8-bit samples are unsigned (offset 128)
  MMF_FLOAT = 4;      // 32-bit IEEE float samples

  MMK_AUDIO = 0;
  MMK_IMAGE = 1;

type
  TMmLayout = record
    Kind: Integer;           // MMK_AUDIO / MMK_IMAGE
    NumChan: Integer;        // interleaved channels (1..255)
    Bits: Integer;           // bits per sample: 8, 16, 24 or 32
    Flags: Integer;          // MMF_*
    Offset: Int64;           // bytes before the first sample (the container header)
    DataLen: Int64;          // bytes of samples after Offset, -1 = up to the end
    Width: Integer;          // images: pixels per row (0 = unknown)
    RowBytes: Integer;       // images: bytes per row including padding (0 = unknown)
  end;

{ Container header at the start of Buf (Size bytes valid). }
function MmParseHeader(Buf: PByte; Size: SizeInt; out L: TMmLayout): Boolean;
{ Only the audio containers (WAV/AIFF). }
function MmParseAudioHeader(Buf: PByte; Size: SizeInt; out L: TMmLayout): Boolean;

{ Statistical detection on Buf.  Channels/ByteSizes: candidates; MaxRatio: the residual cost
  must be below MaxRatio x the order-0 entropy of the bytes (e.g. 0.80).  BigEndian: also try
  big-endian words.  Ratio returns the winner's cost / entropy (1.0 if nothing was tried). }
function MmDetectStats(Buf: PByte; Size: SizeInt; const Channels, ByteSizes: array of Integer;
  BigEndian: Boolean; MaxRatio: Double; out L: TMmLayout; out Ratio: Double): Boolean;

{ For the file grouping ($wav/$bmp): a header, or statistics on the given sample. }
function MmLooksMultimedia(Buf: PByte; Size: SizeInt; Thorough: Boolean): Boolean;

{ Method-string helpers shared by tta and mm: "N" or "=N" (digits only), and "C*W" / "C*Wf". }
function FaParseInt(const S: string; out V: Integer): Boolean;
function FaParseChanWord(const S: string; out A, B: Integer; out IsFloat: Boolean): Boolean;

implementation

function FaParseInt(const S: string; out V: Integer): Boolean;
var
  i, st: Integer;
  r: Int64;
begin
  V := 0;
  st := 1;
  if (S <> '') and (S[1] = '=') then st := 2;
  if st > Length(S) then Exit(False);
  r := 0;
  for i := st to Length(S) do
  begin
    if not (S[i] in ['0'..'9']) then Exit(False);
    r := r * 10 + (Ord(S[i]) - 48);
    if r > High(Integer) then Exit(False);
  end;
  V := r;
  Result := True;
end;

function FaParseChanWord(const S: string; out A, B: Integer; out IsFloat: Boolean): Boolean;
var
  p: Integer;
  w: string;
begin
  A := 0; B := 0; IsFloat := False;
  p := Pos('*', S);
  if p <= 1 then Exit(False);
  if not FaParseInt(Copy(S, 1, p - 1), A) then Exit(False);
  w := Copy(S, p + 1, MaxInt);
  if (w <> '') and (w[Length(w)] = 'f') then
  begin
    IsFloat := True;
    SetLength(w, Length(w) - 1);
  end;
  Result := FaParseInt(w, B) and (A > 0) and (B > 0);
end;

{ ---------------------------------------------------------------------------------------- }
{ headers }

function LE16(P: PByte): LongWord; inline;
begin
  Result := P[0] or (LongWord(P[1]) shl 8);
end;

function LE32(P: PByte): LongWord; inline;
begin
  Result := P[0] or (LongWord(P[1]) shl 8) or (LongWord(P[2]) shl 16) or (LongWord(P[3]) shl 24);
end;

function BE16(P: PByte): LongWord; inline;
begin
  Result := P[1] or (LongWord(P[0]) shl 8);
end;

function BE32(P: PByte): LongWord; inline;
begin
  Result := P[3] or (LongWord(P[2]) shl 8) or (LongWord(P[1]) shl 16) or (LongWord(P[0]) shl 24);
end;

function Tag(P: PByte; const T: string): Boolean;
begin
  Result := (P[0] = Ord(T[1])) and (P[1] = Ord(T[2])) and (P[2] = Ord(T[3])) and (P[3] = Ord(T[4]));
end;

procedure ClearLayout(out L: TMmLayout);
begin
  L.Kind := MMK_AUDIO;
  L.NumChan := 0;
  L.Bits := 0;
  L.Flags := 0;
  L.Offset := 0;
  L.DataLen := -1;
  L.Width := 0;
  L.RowBytes := 0;
end;

{ RIFF/RIFX WAVE }
function ParseWav(Buf: PByte; Size: SizeInt; out L: TMmLayout): Boolean;
var
  Big, HaveFmt: Boolean;
  Pos: SizeInt;
  CkSize: Int64;
  Fmt, Chan, Align, BitsPS: LongWord;

  function R16(P: PByte): LongWord;
  begin
    if Big then Result := BE16(P) else Result := LE16(P);
  end;

  function R32(P: PByte): LongWord;
  begin
    if Big then Result := BE32(P) else Result := LE32(P);
  end;

begin
  Result := False;
  ClearLayout(L);
  if Size < 12 then Exit;
  if Tag(Buf, 'RIFF') then Big := False
  else if Tag(Buf, 'RIFX') then Big := True
  else Exit;
  if not Tag(Buf + 8, 'WAVE') then Exit;
  HaveFmt := False;
  Fmt := 0; Chan := 0; Align := 0; BitsPS := 0;
  Pos := 12;
  while Pos + 8 <= Size do
  begin
    CkSize := R32(Buf + Pos + 4);
    if Tag(Buf + Pos, 'fmt ') then
    begin
      if (CkSize < 16) or (Pos + 8 + 16 > Size) then Exit;
      Fmt := R16(Buf + Pos + 8);
      Chan := R16(Buf + Pos + 10);
      Align := R16(Buf + Pos + 20);
      BitsPS := R16(Buf + Pos + 22);
      if (Fmt = $FFFE) and (CkSize >= 40) and (Pos + 8 + 26 <= Size) then
        Fmt := R16(Buf + Pos + 8 + 24);          // sub-format GUID: first two bytes
      HaveFmt := True;
    end
    else if Tag(Buf + Pos, 'data') then
    begin
      if not HaveFmt then Exit;
      if (Fmt <> 1) and (Fmt <> 3) then Exit;
      if (Chan = 0) or (Chan > 255) then Exit;
      // the container size per sample comes from the block alignment
      if (Align = 0) or (Align mod Chan <> 0) then Exit;
      L.Bits := (Align div Chan) * 8;
      if not (L.Bits in [8, 16, 24, 32]) then Exit;
      if (BitsPS = 0) or (BitsPS > LongWord(L.Bits)) then Exit;
      if Fmt = 3 then
      begin
        if L.Bits <> 32 then Exit;
        L.Flags := MMF_FLOAT;
      end;
      if L.Bits = 8 then L.Flags := L.Flags or MMF_U8;
      if Big then L.Flags := L.Flags or MMF_BE;
      L.NumChan := Chan;
      L.Offset := Pos + 8;
      L.DataLen := CkSize;
      if (CkSize = 0) or (CkSize = $FFFFFFFF) then L.DataLen := -1;   // streamed / RF64-style
      Exit(True);
    end;
    Inc(Pos, 8 + CkSize + (CkSize and 1));
    if CkSize > Size then Exit;
  end;
end;

{ AIFF / AIFC }
function ParseAiff(Buf: PByte; Size: SizeInt; out L: TMmLayout): Boolean;
var
  Aifc, HaveComm: Boolean;
  Pos: SizeInt;
  CkSize: Int64;
  Chan, BitsPS: LongWord;
  Comp: array[0..3] of Byte;
  Flags: Integer;
begin
  Result := False;
  ClearLayout(L);
  if Size < 12 then Exit;
  if not Tag(Buf, 'FORM') then Exit;
  if Tag(Buf + 8, 'AIFF') then Aifc := False
  else if Tag(Buf + 8, 'AIFC') then Aifc := True
  else Exit;
  HaveComm := False;
  Chan := 0; BitsPS := 0;
  Flags := MMF_BE;
  Pos := 12;
  while Pos + 8 <= Size do
  begin
    CkSize := BE32(Buf + Pos + 4);
    if Tag(Buf + Pos, 'COMM') then
    begin
      if (CkSize < 18) or (Pos + 8 + 18 > Size) then Exit;
      Chan := BE16(Buf + Pos + 8);
      BitsPS := BE16(Buf + Pos + 14);
      Flags := MMF_BE;
      if Aifc then
      begin
        if (CkSize < 22) or (Pos + 8 + 22 > Size) then Exit;
        Move(Buf[Pos + 8 + 18], Comp[0], 4);
        if Tag(@Comp[0], 'NONE') or Tag(@Comp[0], 'twos') then Flags := MMF_BE
        else if Tag(@Comp[0], 'sowt') then Flags := 0
        else if Tag(@Comp[0], 'fl32') or Tag(@Comp[0], 'FL32') then Flags := MMF_BE or MMF_FLOAT
        else if Tag(@Comp[0], 'raw ') then Flags := MMF_U8
        else Exit;
      end;
      HaveComm := True;
    end
    else if Tag(Buf + Pos, 'SSND') then
    begin
      if not HaveComm or (Pos + 16 > Size) or (CkSize < 8) then Exit;
      if (Chan = 0) or (Chan > 255) or (BitsPS = 0) or (BitsPS > 32) then Exit;
      L.Bits := ((BitsPS + 7) div 8) * 8;
      if (Flags and MMF_FLOAT <> 0) and (L.Bits <> 32) then Exit;
      if (Flags and MMF_U8 <> 0) and (L.Bits <> 8) then Exit;
      if L.Bits = 8 then Flags := Flags and not MMF_BE;
      L.Flags := Flags;
      L.NumChan := Chan;
      L.Offset := Pos + 16 + BE32(Buf + Pos + 8);
      L.DataLen := CkSize - 8 - BE32(Buf + Pos + 8);
      if L.DataLen < 0 then Exit;
      Exit(True);
    end;
    Inc(Pos, 8 + CkSize + (CkSize and 1));
    if CkSize > Size then Exit;
  end;
end;

procedure ImageLayout(var L: TMmLayout; Chan, Bits, Width: Integer; RowBytes: Int64; Off: Int64);
begin
  L.Kind := MMK_IMAGE;
  L.NumChan := Chan;
  L.Bits := Bits;
  L.Width := Width;
  L.RowBytes := RowBytes;
  L.Offset := Off;
  L.DataLen := -1;
end;

function ParseBmp(Buf: PByte; Size: SizeInt; out L: TMmLayout): Boolean;
var
  Off, Hs, Comp: LongWord;
  W, H: LongInt;
  Bpp: Integer;
  Row: Int64;
begin
  Result := False;
  ClearLayout(L);
  if (Size < 26) or (Buf[0] <> Ord('B')) or (Buf[1] <> Ord('M')) then Exit;
  Off := LE32(Buf + 10);
  Hs := LE32(Buf + 14);
  if Hs = 12 then
  begin
    W := LE16(Buf + 18);
    Bpp := LE16(Buf + 24);
    Comp := 0;
  end
  else if (Hs >= 40) and (Hs <= 255) and (Size >= 34) then
  begin
    W := LongInt(LE32(Buf + 18));
    H := LongInt(LE32(Buf + 22));
    Bpp := LE16(Buf + 28);
    Comp := LE32(Buf + 30);
    if H = 0 then Exit;
  end
  else Exit;
  if (Comp <> 0) and (Comp <> 3) and (Comp <> 6) then Exit;   // RGB / bit fields only
  if (W <= 0) or (W > 1 shl 20) then Exit;
  if (Off < 14 + Hs) or (Off > 1 shl 20) then Exit;
  Row := ((Int64(W) * Bpp + 31) div 32) * 4;
  case Bpp of
    8:  ImageLayout(L, 1, 8, W, Row, Off);
    16: ImageLayout(L, 0, 16, W, Row, Off);    // RGB555/565: no channels to predict
    24: ImageLayout(L, 3, 8, W, Row, Off);
    32: ImageLayout(L, 4, 8, W, Row, Off);
  else
    Exit;
  end;
  Result := True;
end;

{ a bare DIB (BMP without its 14-byte file header) }
function ParseDib(Buf: PByte; Size: SizeInt; out L: TMmLayout): Boolean;
var
  Hs, Comp, Colors: LongWord;
  W, H: LongInt;
  Bpp: Integer;
  Off, Row: Int64;
begin
  Result := False;
  ClearLayout(L);
  if Size < 40 then Exit;
  Hs := LE32(Buf);
  if not ((Hs = 40) or (Hs = 52) or (Hs = 56) or (Hs = 108) or (Hs = 124)) then Exit;
  W := LongInt(LE32(Buf + 4));
  H := LongInt(LE32(Buf + 8));
  if (LE16(Buf + 12) <> 1) or (W <= 0) or (W > 1 shl 20) or (H = 0) then Exit;
  Bpp := LE16(Buf + 14);
  Comp := LE32(Buf + 16);
  Colors := LE32(Buf + 32);
  if (Comp <> 0) and (Comp <> 3) then Exit;
  Off := Hs;
  if (Comp = 3) and (Hs = 40) then Inc(Off, 12);
  if Bpp <= 8 then
  begin
    if Colors = 0 then Colors := 1 shl Bpp;
    if Colors > 256 then Exit;
    Inc(Off, 4 * Int64(Colors));
  end;
  Row := ((Int64(W) * Bpp + 31) div 32) * 4;
  case Bpp of
    8:  ImageLayout(L, 1, 8, W, Row, Off);
    24: ImageLayout(L, 3, 8, W, Row, Off);
    32: ImageLayout(L, 4, 8, W, Row, Off);
  else
    Exit;
  end;
  Result := True;
end;

function ParseTga(Buf: PByte; Size: SizeInt; out L: TMmLayout): Boolean;
var
  IdLen, CmType, ImType, CmLen, CmBits, W, H, Bpp, Desc: Integer;
  Off: Int64;
begin
  Result := False;
  ClearLayout(L);
  if Size < 18 then Exit;
  IdLen := Buf[0];
  CmType := Buf[1];
  ImType := Buf[2];
  CmLen := LE16(Buf + 5);
  CmBits := Buf[7];
  W := LE16(Buf + 12);
  H := LE16(Buf + 14);
  Bpp := Buf[16];
  Desc := Buf[17];
  if not (ImType in [1, 2, 3]) or (CmType > 1) then Exit;
  if (ImType = 1) <> (CmType = 1) then Exit;
  if (CmType = 1) and not (CmBits in [15, 16, 24, 32]) then Exit;
  if (W = 0) or (H = 0) or (Desc and $C0 <> 0) then Exit;
  Off := 18 + IdLen;
  if CmType = 1 then Inc(Off, Int64(CmLen) * ((CmBits + 7) div 8));
  case Bpp of
    8:  ImageLayout(L, 1, 8, W, W, Off);
    16: ImageLayout(L, 0, 16, W, 2 * W, Off);  // RGB555: no channels to predict
    24: ImageLayout(L, 3, 8, W, 3 * W, Off);
    32: ImageLayout(L, 4, 8, W, 4 * W, Off);
  else
    Exit;
  end;
  if (Bpp = 16) and (ImType = 3) then Exit;
  if (Bpp = 8) and (ImType = 1) then L.NumChan := 0;   // palette indices: nothing to predict
  L.DataLen := Int64(L.RowBytes) * H;
  Result := True;
end;

{ binary PGM / PPM }
function ParsePnm(Buf: PByte; Size: SizeInt; out L: TMmLayout): Boolean;
var
  Pos: SizeInt;
  Vals: array[0..2] of Int64;
  k, Chan, Bits: Integer;
begin
  Result := False;
  ClearLayout(L);
  if (Size < 8) or (Buf[0] <> Ord('P')) or not (Buf[1] in [Ord('5'), Ord('6')]) then Exit;
  if Buf[1] = Ord('5') then Chan := 1 else Chan := 3;
  Pos := 2;
  for k := 0 to 2 do
  begin
    // white space and comments
    while Pos < Size do
    begin
      if Buf[Pos] = Ord('#') then
      begin
        while (Pos < Size) and (Buf[Pos] <> 10) and (Buf[Pos] <> 13) do Inc(Pos);
      end
      else if Buf[Pos] in [9, 10, 11, 12, 13, 32] then Inc(Pos)
      else Break;
    end;
    if (Pos >= Size) or not (Buf[Pos] in [Ord('0')..Ord('9')]) then Exit;
    Vals[k] := 0;
    while (Pos < Size) and (Buf[Pos] in [Ord('0')..Ord('9')]) do
    begin
      Vals[k] := Vals[k] * 10 + Buf[Pos] - 48;
      if Vals[k] > 1 shl 24 then Exit;
      Inc(Pos);
    end;
  end;
  if (Pos >= Size) or not (Buf[Pos] in [9, 10, 11, 12, 13, 32]) then Exit;
  Inc(Pos);
  if (Vals[0] = 0) or (Vals[1] = 0) or (Vals[2] = 0) or (Vals[2] > 65535) then Exit;
  if Vals[2] < 256 then Bits := 8 else Bits := 16;
  ImageLayout(L, Chan, Bits, Vals[0], Vals[0] * Chan * (Bits div 8), Pos);
  if Bits = 16 then L.Flags := MMF_BE;
  L.DataLen := Int64(L.RowBytes) * Vals[1];
  Result := True;
end;

{ baseline TIFF: uncompressed, chunky, 8/16-bit samples, strips stored one after another }
function ParseTiff(Buf: PByte; Size: SizeInt; out L: TMmLayout): Boolean;
var
  Big: Boolean;
  Ifd, n, i, Typ, Cnt, Val: LongWord;
  E: PByte;
  W, H, Spp, Bps, Comp, Planar, NStrips, StripOff0, StripsTag, StripsType: Int64;
  Row: Int64;
  StripCountTag, StripCountType: Int64;
  Off, Cur, Sz: Int64;

  function R16(P: PByte): LongWord;
  begin
    if Big then Result := BE16(P) else Result := LE16(P);
  end;

  function R32(P: PByte): LongWord;
  begin
    if Big then Result := BE32(P) else Result := LE32(P);
  end;

  function ValOf(Typ: LongWord; P: PByte): LongWord;
  begin
    if Typ = 3 then Result := R16(P) else Result := R32(P);
  end;

  { k-th value of an array tag of type Typ (3 or 4) at file offset / inline }
  function ArrVal(Tg, Ty, Count: Int64; k: Int64; out V: Int64): Boolean;
  var
    Sz1: Integer;
    P: Int64;
  begin
    Result := False;
    if Ty = 3 then Sz1 := 2 else if Ty = 4 then Sz1 := 4 else Exit;
    if Count * Sz1 <= 4 then P := Tg            // Tg = offset of the inline value field
    else P := Tg;                               // Tg = offset of the array
    P := P + k * Sz1;
    if P + Sz1 > Size then Exit;
    if Sz1 = 2 then V := R16(Buf + P) else V := R32(Buf + P);
    Result := True;
  end;

begin
  Result := False;
  ClearLayout(L);
  if Size < 16 then Exit;
  if (Buf[0] = Ord('I')) and (Buf[1] = Ord('I')) then Big := False
  else if (Buf[0] = Ord('M')) and (Buf[1] = Ord('M')) then Big := True
  else Exit;
  if R16(Buf + 2) <> 42 then Exit;
  Ifd := R32(Buf + 4);
  if (Ifd < 8) or (Int64(Ifd) + 2 > Size) then Exit;
  n := R16(Buf + Ifd);
  if Int64(Ifd) + 2 + Int64(n) * 12 > Size then Exit;
  W := 0; H := 0; Spp := 1; Bps := 1; Comp := 1; Planar := 1;
  NStrips := 0; StripsTag := -1; StripsType := 0; StripCountTag := -1; StripCountType := 0;
  for i := 0 to n - 1 do
  begin
    E := Buf + Ifd + 2 + i * 12;
    Typ := R16(E + 2);
    Cnt := R32(E + 4);
    Val := ValOf(Typ, E + 8);
    case R16(E) of
      256: W := Val;
      257: H := Val;
      258: Bps := Val;      // first value (all samples must be equal for us; checked below)
      259: Comp := Val;
      277: Spp := Val;
      284: Planar := Val;
      273:
        begin
          NStrips := Cnt; StripsType := Typ;
          if Cnt * (1 + Ord(Typ = 4)) * 2 <= 4 then StripsTag := (E + 8) - Buf else StripsTag := R32(E + 8);
        end;
      279:
        begin
          StripCountType := Typ;
          if Cnt * (1 + Ord(Typ = 4)) * 2 <= 4 then StripCountTag := (E + 8) - Buf else StripCountTag := R32(E + 8);
        end;
    end;
    // bits per sample with several samples: an array; read its first value
    if (R16(E) = 258) and (Cnt > 1) then
    begin
      if Cnt * 2 <= 4 then Bps := R16(E + 8)
      else if R32(E + 8) + 2 <= LongWord(Size) then Bps := R16(Buf + R32(E + 8))
      else Exit;
    end;
  end;
  if (Comp <> 1) or ((Planar <> 1) and (Spp > 1)) or (W <= 0) or (H <= 0) then Exit;
  if not (Bps in [8, 16]) or (Spp < 1) or (Spp > 4) then Exit;
  if (NStrips < 1) or (StripsTag < 0) then Exit;
  Row := W * Spp * (Bps div 8);
  // strips must follow each other
  if not ArrVal(StripsTag, StripsType, NStrips, 0, StripOff0) then Exit;
  if NStrips > 1 then
  begin
    if StripCountTag < 0 then Exit;
    Cur := StripOff0;
    for i := 0 to NStrips - 1 do
    begin
      if not ArrVal(StripsTag, StripsType, NStrips, i, Off) then Exit;
      if Off <> Cur then Exit;
      if not ArrVal(StripCountTag, StripCountType, NStrips, i, Sz) then Exit;
      Inc(Cur, Sz);
    end;
  end;
  ImageLayout(L, Spp, Bps, W, Row, StripOff0);
  if (Bps = 16) and Big then L.Flags := MMF_BE;
  L.DataLen := Row * H;
  Result := True;
end;

function MmParseAudioHeader(Buf: PByte; Size: SizeInt; out L: TMmLayout): Boolean;
begin
  Result := ParseWav(Buf, Size, L) or ParseAiff(Buf, Size, L);
end;

function MmParseHeader(Buf: PByte; Size: SizeInt; out L: TMmLayout): Boolean;
begin
  Result := MmParseAudioHeader(Buf, Size, L) or ParseBmp(Buf, Size, L) or ParsePnm(Buf, Size, L) or
    ParseTiff(Buf, Size, L) or ParseDib(Buf, Size, L) or ParseTga(Buf, Size, L);
end;

{ ---------------------------------------------------------------------------------------- }
{ statistics }

const
  STATS_MAX = 256 * 1024;

var
  BitLenTab: array[0..4095] of Byte;

function BitLen(V: LongWord): Integer; inline;
begin
  if V < 4096 then Result := BitLenTab[V]
  else Result := BsrDWord(V) + 1;
end;

function ReadSample(P: PByte; Bytes: Integer; Big: Boolean): LongInt; inline;
begin
  case Bytes of
    1: Result := P[0];
    2: if Big then Result := SmallInt(BE16(P)) else Result := SmallInt(LE16(P));
    3: if Big then Result := SarLongint(LongInt((LongWord(P[0]) shl 24) or (LongWord(P[1]) shl 16) or (LongWord(P[2]) shl 8)), 8)
       else Result := SarLongint(LongInt((LongWord(P[2]) shl 24) or (LongWord(P[1]) shl 16) or (LongWord(P[0]) shl 8)), 8);
  else
    if Big then Result := LongInt(BE32(P)) else Result := LongInt(LE32(P));
  end;
end;

{ Cost in 1/16 bit of the input bytes for one layout: per channel, the smaller of the order-1
  and order-2 residual costs (bit length + 1 for the sign). }
function LayoutCost(Buf: PByte; Size: SizeInt; Chan, Bytes: Integer; Big: Boolean): Int64;
var
  N, Frames, f, c: SizeInt;
  Step: SizeInt;
  P: PByte;
  x, x1, x2: LongInt;
  d1, d2: LongWord;
  c1, c2: Int64;
begin
  Step := Chan * Bytes;
  Frames := Size div Step;
  Result := 0;
  if Frames < 16 then Exit(Int64(1) shl 40);
  for c := 0 to Chan - 1 do
  begin
    c1 := 0; c2 := 0;
    P := Buf + c * Bytes;
    x1 := ReadSample(P, Bytes, Big);
    x2 := x1;
    for f := 1 to Frames - 1 do
    begin
      Inc(P, Step);
      x := ReadSample(P, Bytes, Big);
      d1 := LongWord(x - x1);
      if LongInt(d1) < 0 then d1 := LongWord(-LongInt(d1));
      d2 := LongWord(x - 2 * x1 + x2);
      if LongInt(d2) < 0 then d2 := LongWord(-LongInt(d2));
      Inc(c1, BitLen(d1) + Ord(d1 <> 0));
      Inc(c2, BitLen(d2) + Ord(d2 <> 0));
      x2 := x1;
      x1 := x;
    end;
    if c2 < c1 then c1 := c2;
    Inc(Result, c1);
  end;
  // per byte of the frames looked at, in 1/16 bit
  N := Frames * Step;
  Result := (Result * 16 * 1024) div N;   // 1/16 bit per byte, x1024
end;

function Order0Cost(Buf: PByte; Size: SizeInt): Int64;
var
  Cnt: array[0..255] of SizeInt;
  i: SizeInt;
  H: Double;
begin
  FillChar(Cnt, SizeOf(Cnt), 0);
  for i := 0 to Size - 1 do Inc(Cnt[Buf[i]]);
  H := 0;
  for i := 0 to 255 do
    if Cnt[i] > 0 then H := H - Cnt[i] * Ln(Cnt[i] / Size);
  H := H / Ln(2) / Size;              // bits per byte
  Result := Round(H * 16 * 1024);
end;

function MmDetectStats(Buf: PByte; Size: SizeInt; const Channels, ByteSizes: array of Integer;
  BigEndian: Boolean; MaxRatio: Double; out L: TMmLayout; out Ratio: Double): Boolean;
var
  ic, ib, e: Integer;
  Cost, Best, H0: Int64;
begin
  Result := False;
  ClearLayout(L);
  Ratio := 1.0;
  if Size < 256 then Exit;
  // 256 KB from the middle are enough (and keep this cheap)
  if Size > STATS_MAX then
  begin
    Buf := Buf + (((Size - STATS_MAX) div 2) div 144) * 144;   // keeps every frame alignment
    Size := STATS_MAX;
  end;
  H0 := Order0Cost(Buf, Size);
  if H0 <= 0 then Exit;
  Best := High(Int64);
  // wider samples first: narrower ones (which also look smooth in the high bytes of wide
  // samples) and more channels must win by 2 %
  for ib := High(ByteSizes) downto 0 do
    for ic := 0 to High(Channels) do
      for e := 0 to Ord(BigEndian and (ByteSizes[ib] > 1)) do
      begin
        if (Channels[ic] < 1) or not (ByteSizes[ib] in [1..4]) then Continue;
        Cost := LayoutCost(Buf, Size, Channels[ic], ByteSizes[ib], e = 1);
        if (Best = High(Int64)) or (Cost * 100 < Best * 98) then
        begin
          Best := Cost;
          L.NumChan := Channels[ic];
          L.Bits := ByteSizes[ib] * 8;
          if e = 1 then L.Flags := MMF_BE else L.Flags := 0;
          if L.Bits = 8 then L.Flags := MMF_U8;
        end;
      end;
  if Best = High(Int64) then Exit;
  Ratio := Best / H0;
  Result := Ratio < MaxRatio;
  if not Result then ClearLayout(L);
end;

function MmLooksMultimedia(Buf: PByte; Size: SizeInt; Thorough: Boolean): Boolean;
var
  L: TMmLayout;
  R: Double;
begin
  if Thorough then
    Result := MmDetectStats(Buf, Size, [1, 2, 3, 4], [1, 2, 3, 4], True, 0.80, L, R)
  else
    Result := MmDetectStats(Buf, Size, [1, 2, 3], [1, 2], False, 0.80, L, R);
end;

procedure InitTables;
var
  i: Integer;
begin
  BitLenTab[0] := 0;
  for i := 1 to 4095 do BitLenTab[i] := BsrDWord(i) + 1;
end;

initialization
  InitTables;
end.
