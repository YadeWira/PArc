{ Context-mixing codec (lpaq1-style) for PArc.
  Port of Matt Mahoney's lpaq1 (GPLv2) to Free Pascal, adapted to work as a block codec.
  It is slow but compresses text much better than PPMd/LZMA; intended for -m9/-mx. }
unit parc_cm;

{$mode objfpc}{$H+}
{$Q-}{$R-}

interface

uses
  Classes, SysUtils, Math, parc_bytes, parc_outstream, parc_stream;

{ Compress Src[0..SrcLen) into Dst (8-byte original size + arithmetic-coded data). }
function CmCompressMem(Src: PByte; SrcLen: SizeInt; out Dst: TBytes; Level: Integer = 6): Boolean;
{ Decompress a buffer produced by CmCompressMem. }
function CmDecompressMem(Src: PByte; SrcLen: SizeInt; out Dst: TBytes): Boolean;

type
  TCmEncStage = class(TOutStage)
  private
    FBuf: TBytes;
    FLen: SizeInt;
  protected
    procedure DoWrite(Buf: PByte; Count: SizeInt); override;
    procedure DoFinish; override;
  public
    constructor Create(ATarget: TOutStage);
  end;

  TCmDecStage = class(TInStage)
  private
    FData: TBytes;
    FPos: SizeInt;
    FReady: Boolean;
    procedure EnsureDecoded;
  public
    function Read(Buf: PByte; Count: SizeInt): SizeInt; override;
  end;

implementation

const
  CM_LEVEL_DEFAULT = 6;

  SQUASH_TAB: array[0..32] of LongInt = (1,2,3,6,10,16,27,45,73,120,194,310,488,747,1101,1546,2047,2549,2994,3348,3607,3785,3901,3975,4022,4050,4068,4079,4085,4089,4092,4093,4094);

  STATE_TABLE: array[0..255, 0..1] of Byte = (
  (1,2),
  (3,5),
  (4,6),
  (7,10),
  (8,12),
  (9,13),
  (11,14),
  (15,19),
  (16,23),
  (17,24),
  (18,25),
  (20,27),
  (21,28),
  (22,29),
  (26,30),
  (31,33),
  (32,35),
  (32,35),
  (32,35),
  (32,35),
  (34,37),
  (34,37),
  (34,37),
  (34,37),
  (34,37),
  (34,37),
  (36,39),
  (36,39),
  (36,39),
  (36,39),
  (38,40),
  (41,43),
  (42,45),
  (42,45),
  (44,47),
  (44,47),
  (46,49),
  (46,49),
  (48,51),
  (48,51),
  (50,52),
  (53,43),
  (54,57),
  (54,57),
  (56,59),
  (56,59),
  (58,61),
  (58,61),
  (60,63),
  (60,63),
  (62,65),
  (62,65),
  (50,66),
  (67,55),
  (68,57),
  (68,57),
  (70,73),
  (70,73),
  (72,75),
  (72,75),
  (74,77),
  (74,77),
  (76,79),
  (76,79),
  (62,81),
  (62,81),
  (64,82),
  (83,69),
  (84,71),
  (84,71),
  (86,73),
  (86,73),
  (44,59),
  (44,59),
  (58,61),
  (58,61),
  (60,49),
  (60,49),
  (76,89),
  (76,89),
  (78,91),
  (78,91),
  (80,92),
  (93,69),
  (94,87),
  (94,87),
  (96,45),
  (96,45),
  (48,99),
  (48,99),
  (88,101),
  (88,101),
  (80,102),
  (103,69),
  (104,87),
  (104,87),
  (106,57),
  (106,57),
  (62,109),
  (62,109),
  (88,111),
  (88,111),
  (80,112),
  (113,85),
  (114,87),
  (114,87),
  (116,57),
  (116,57),
  (62,119),
  (62,119),
  (88,121),
  (88,121),
  (90,122),
  (123,85),
  (124,97),
  (124,97),
  (126,57),
  (126,57),
  (62,129),
  (62,129),
  (98,131),
  (98,131),
  (90,132),
  (133,85),
  (134,97),
  (134,97),
  (136,57),
  (136,57),
  (62,139),
  (62,139),
  (98,141),
  (98,141),
  (90,142),
  (143,95),
  (144,97),
  (144,97),
  (68,57),
  (68,57),
  (62,81),
  (62,81),
  (98,147),
  (98,147),
  (100,148),
  (149,95),
  (150,107),
  (150,107),
  (108,151),
  (108,151),
  (100,152),
  (153,95),
  (154,107),
  (108,155),
  (100,156),
  (157,95),
  (158,107),
  (108,159),
  (100,160),
  (161,105),
  (162,107),
  (108,163),
  (110,164),
  (165,105),
  (166,117),
  (118,167),
  (110,168),
  (169,105),
  (170,117),
  (118,171),
  (110,172),
  (173,105),
  (174,117),
  (118,175),
  (110,176),
  (177,105),
  (178,117),
  (118,179),
  (110,180),
  (181,115),
  (182,117),
  (118,183),
  (120,184),
  (185,115),
  (186,127),
  (128,187),
  (120,188),
  (189,115),
  (190,127),
  (128,191),
  (120,192),
  (193,115),
  (194,127),
  (128,195),
  (120,196),
  (197,115),
  (198,127),
  (128,199),
  (120,200),
  (201,115),
  (202,127),
  (128,203),
  (120,204),
  (205,115),
  (206,127),
  (128,207),
  (120,208),
  (209,125),
  (210,127),
  (128,211),
  (130,212),
  (213,125),
  (214,137),
  (138,215),
  (130,216),
  (217,125),
  (218,137),
  (138,219),
  (130,220),
  (221,125),
  (222,137),
  (138,223),
  (130,224),
  (225,125),
  (226,137),
  (138,227),
  (130,228),
  (229,125),
  (230,137),
  (138,231),
  (130,232),
  (233,125),
  (234,137),
  (138,235),
  (130,236),
  (237,125),
  (238,137),
  (138,239),
  (130,240),
  (241,125),
  (242,137),
  (138,243),
  (130,244),
  (245,135),
  (246,137),
  (138,247),
  (140,248),
  (249,135),
  (250,69),
  (80,251),
  (140,252),
  (249,135),
  (250,69),
  (80,251),
  (140,252),
  (0,0),
  (0,0),
  (0,0)
  );

type
  TCMStateMap = class
  protected
    N, cxt: Integer;
    t: array of LongWord;
    procedure Update(y, limit: Integer);
  public
    constructor Create(AN: Integer);
    function P(y, cx: Integer; limit: Integer = 1023): Integer;
  end;

  TCMAPM = class(TCMStateMap)
  public
    constructor Create(AN: Integer);
    function PP(y, pr, cx: Integer; limit: Integer = 255): Integer; inline;
  end;

  TCMMixer = class
  private
    N, M, cxt, nx, pr: Integer;
    tx, wx: array of Integer;
  public
    constructor Create(AN, AM: Integer);
    procedure Add(x: Integer);
    procedure SetCtx(cx: Integer);
    function P: Integer;
    procedure Update(y: Integer);
  end;

  TCMHashTable = class
  private
    N: Integer;
    t: TBytes;
  public
    constructor Create(AN: Integer);
    function Entry(i: LongWord): PByte;
  end;

  TCMMatchModel = class
  private
    N, HN: Integer;
    buf: TBytes;
    ht: array of Integer;
    pos, match, len: Integer;
    h1, h2: LongWord;
    c0, bcount: Integer;
    sm: TCMStateMap;
  public
    constructor Create(AN: Integer);
    function P(y: Integer; m: TCMMixer): Integer;
  end;

  TCMPredictor = class
  private
    pr: Integer;
    t0: array[0..65535] of Byte;
    t: TCMHashTable;
    c0, c4, bcount: Integer;
    cp: array[0..5] of PByte;
    sm: array[0..5] of TCMStateMap;
    a1, a2: TCMAPM;
    h: array[0..5] of LongWord;
    m: TCMMixer;
    mm: TCMMatchModel;
    MEM: Integer;
  public
    constructor Create(Level: Integer);
    destructor Destroy; override;
    function P: Integer;
    procedure Update(y: Integer);
  end;

var
  STRETCH: array[0..4095] of SmallInt;
  SM_DT: array[0..1023] of Integer;

function AShr(V: Int64; N: Integer): Int64;
begin
  if V >= 0 then Result := V shr N
  else Result := not ((not V) shr N);
end;

function Squash(D: Integer): Integer; inline;
var
  w: Integer;
begin
  if D > 2047 then Exit(4095);
  if D < -2047 then Exit(0);
  w := D and 127;
  D := AShr(D, 7) + 16;
  Result := (SQUASH_TAB[D] * (128 - w) + SQUASH_TAB[D + 1] * w + 64) shr 7;
end;

procedure InitTables;
var
  x, i, j, pi: Integer;
begin
  for x := -2047 to 2047 do
  begin
    i := Squash(x);
    if x = -2047 then pi := 0;
    for j := pi to i do STRETCH[j] := x;
    pi := i + 1;
  end;
  STRETCH[4095] := 2047;
  for i := 0 to 1023 do SM_DT[i] := 16384 div (i + i + 3);
end;

{ TCMStateMap }

constructor TCMStateMap.Create(AN: Integer);
var i: Integer;
begin
  inherited Create;
  N := AN;
  SetLength(t, N);
  for i := 0 to N - 1 do t[i] := LongWord(1) shl 31;
end;

procedure TCMStateMap.Update(y, limit: Integer); inline;
var
  nn, pv, v: LongInt;
  incv: LongWord;
begin
  nn := t[cxt] and 1023;
  pv := t[cxt] shr 10;
  if nn < limit then Inc(t[cxt])
  else t[cxt] := (t[cxt] and $fffffc00) or LongWord(limit);
  v := SarLongint((y shl 22) - pv, 3);
  incv := LongWord(v * SM_DT[nn]) and $fffffc00;
  t[cxt] := t[cxt] + incv;
end;

function TCMStateMap.P(y, cx, limit: Integer): Integer;
begin
  Update(y, limit);
  cxt := cx;
  Result := t[cxt] shr 20;
end;

{ TCMAPM }

constructor TCMAPM.Create(AN: Integer);
var i, pv: Integer;
begin
  inherited Create(AN * 24);
  for i := 0 to N - 1 do
  begin
    pv := ((i mod 24) * 2 + 1) * 4096 div 48 - 2048;
    t[i] := (LongWord(Squash(pv)) shl 20) + 6;
  end;
end;

function TCMAPM.PP(y, pr, cx, limit: Integer): Integer;
var
  wt: Integer;
begin
  Update(y, limit);
  pr := (STRETCH[pr] + 2048) * 23;
  wt := pr and $fff;
  cx := cx * 24 + (pr shr 12);
  pr := ((t[cx] shr 13) * ($1000 - wt) + (t[cx + 1] shr 13) * wt) shr 19;
  cxt := cx + (wt shr 11);
  Result := pr;
end;

{ TCMMixer }

constructor TCMMixer.Create(AN, AM: Integer);
begin
  inherited Create;
  N := AN; M := AM; cxt := 0; nx := 0; pr := 2048;
  SetLength(tx, 7);
  SetLength(wx, 7 * M);
end;

procedure TCMMixer.Add(x: Integer);
begin
  tx[nx] := x; Inc(nx);
end;

procedure TCMMixer.SetCtx(cx: Integer);
begin
  cxt := cx;
end;

function TCMMixer.P: Integer;
var
  sum: Int64;
  w: PInteger;
begin
  w := @wx[cxt * 7];
  sum := Int64(tx[0]) * w[0] + Int64(tx[1]) * w[1] + Int64(tx[2]) * w[2] +
         Int64(tx[3]) * w[3] + Int64(tx[4]) * w[4] + Int64(tx[5]) * w[5] +
         Int64(tx[6]) * w[6];
  pr := Squash(sum shr 16);
  Result := pr;
end;

procedure TCMMixer.Update(y: Integer);
var
  err: Integer;
  w: PInteger;
begin
  err := ((y shl 12) - pr) * 7;
  w := @wx[cxt * 7];
  Inc(w[0], SarLongint(tx[0] * err + $8000, 16));
  Inc(w[1], SarLongint(tx[1] * err + $8000, 16));
  Inc(w[2], SarLongint(tx[2] * err + $8000, 16));
  Inc(w[3], SarLongint(tx[3] * err + $8000, 16));
  Inc(w[4], SarLongint(tx[4] * err + $8000, 16));
  Inc(w[5], SarLongint(tx[5] * err + $8000, 16));
  Inc(w[6], SarLongint(tx[6] * err + $8000, 16));
  nx := 0;
end;

{ TCMHashTable }

constructor TCMHashTable.Create(AN: Integer);
begin
  inherited Create;
  N := AN;
  SetLength(t, N + 64);
end;

function TCMHashTable.Entry(i: LongWord): PByte; inline;
var
  chk: Byte;
  idx: LongWord;
begin
  i := i * 123456791;
  i := (i shl 16) or (i shr 16);
  i := i * 234567891;
  chk := Byte(i shr 24);
  idx := (i * 16) and LongWord(N - 16);
  if t[idx] = chk then Exit(@t[idx]);
  if t[idx xor 16] = chk then Exit(@t[idx xor 16]);
  if t[idx xor 32] = chk then Exit(@t[idx xor 32]);
  if (t[idx + 1] > t[(idx + 1) xor 16]) or (t[idx + 1] > t[(idx + 1) xor 32]) then idx := idx xor 16;
  if t[idx + 1] > t[(idx + 1) xor 48] then idx := idx xor 48;
  FillChar(t[idx], 16, 0);
  t[idx] := chk;
  Result := @t[idx];
end;

{ TCMMatchModel }

constructor TCMMatchModel.Create(AN: Integer);
begin
  inherited Create;
  N := AN div 2 - 1;
  HN := AN div 8 - 1;
  SetLength(buf, N + 1);
  SetLength(ht, HN + 1);
  pos := 0; match := 0; len := 0; h1 := 0; h2 := 0; c0 := 1; bcount := 0;
  sm := TCMStateMap.Create(56 shl 8);
end;

function TCMMatchModel.P(y: Integer; m: TCMMixer): Integer;
var
  cxt, b, i: Integer;
begin
  c0 := c0 + c0 + y;
  Inc(bcount);
  if bcount = 8 then
  begin
    bcount := 0;
    h1 := (h1 * (3 shl 3) + LongWord(c0)) and LongWord(HN);
    h2 := (h2 * (5 shl 5) + LongWord(c0)) and LongWord(HN);
    buf[pos] := Byte(c0);
    Inc(pos);
    c0 := 1;
    pos := pos and N;
    if len > 0 then
    begin
      Inc(match);
      match := match and N;
      if len < 62 then Inc(len);
    end
    else
    begin
      match := ht[h1];
      if match <> pos then
      begin
        while (len < 62) and (((match - len - 1) and N) <> pos) and
              (buf[(match - len - 1) and N] = buf[(pos - len - 1) and N]) do Inc(len);
      end;
    end;
    if len < 2 then
    begin
      len := 0;
      match := ht[h2];
      if match <> pos then
      begin
        while (len < 62) and (((match - len - 1) and N) <> pos) and
              (buf[(match - len - 1) and N] = buf[(pos - len - 1) and N]) do Inc(len);
      end;
    end;
  end;

  cxt := c0;
  if (len > 0) and (((Integer(buf[match]) + 256) shr (8 - bcount)) = c0) then
  begin
    b := (buf[match] shr (7 - bcount)) and 1;
    if len < 16 then cxt := len * 2 + b
    else cxt := (len shr 2) * 2 + b + 24;
    cxt := cxt * 256 + buf[(pos - 1) and N];
  end
  else
    len := 0;
  m.Add(STRETCH[sm.P(y, cxt, 1023)]);

  if bcount = 0 then
  begin
    ht[h1] := pos;
    ht[h2] := pos;
  end;
  Result := len;
end;

{ TCMPredictor }

constructor TCMPredictor.Create(Level: Integer);
var i: Integer;
begin
  inherited Create;
  if Level < 0 then Level := 0;
  if Level > 9 then Level := 9;
  MEM := 1 shl (Level + 20);
  pr := 2048;
  c0 := 1; c4 := 0; bcount := 0;
  t := TCMHashTable.Create(MEM * 2);
  for i := 0 to 5 do
  begin
    cp[i] := @t0[0];
    sm[i] := TCMStateMap.Create(256);
    h[i] := 0;
  end;
  a1 := TCMAPM.Create($100);
  a2 := TCMAPM.Create($4000);
  m := TCMMixer.Create(7, 80);
  mm := TCMMatchModel.Create(MEM);
end;

destructor TCMPredictor.Destroy;
var i: Integer;
begin
  t.Free; mm.Free; m.Free; a1.Free; a2.Free;
  for i := 0 to 5 do sm[i].Free;
  inherited Destroy;
end;

function TCMPredictor.P: Integer;
begin
  Result := pr;
end;

procedure TCMPredictor.Update(y: Integer);
var
  i, j, order, len: Integer;
  c: Byte;
begin
  cp[0]^ := STATE_TABLE[cp[0]^][y];
  cp[1]^ := STATE_TABLE[cp[1]^][y];
  cp[2]^ := STATE_TABLE[cp[2]^][y];
  cp[3]^ := STATE_TABLE[cp[3]^][y];
  cp[4]^ := STATE_TABLE[cp[4]^][y];
  cp[5]^ := STATE_TABLE[cp[5]^][y];
  m.Update(y);

  Inc(bcount);
  c0 := c0 + c0 + y;
  if c0 >= 256 then
  begin
    c0 := c0 - 256;
    c4 := (c4 shl 8) or c0;
    h[0] := LongWord(c0) shl 8;
    h[1] := ((LongWord(c4) and $ffff) shl 5) or $57000000;
    h[2] := (LongWord(c4) shl 8) * 3;
    h[3] := LongWord(c4) * 5;
    h[4] := (h[4] * (11 shl 5) + LongWord(c0) * 13) and $3fffffff;
    if (c0 >= 65) and (c0 <= 90) then Inc(c0, 32);
    if (c0 >= 97) and (c0 <= 122) then h[5] := (h[5] + LongWord(c0)) * (7 shl 3)
    else h[5] := 0;
    cp[1] := t.Entry(h[1]) + 1;
    cp[2] := t.Entry(h[2]) + 1;
    cp[3] := t.Entry(h[3]) + 1;
    cp[4] := t.Entry(h[4]) + 1;
    cp[5] := t.Entry(h[5]) + 1;
    c0 := 1;
    bcount := 0;
  end;
  if bcount = 4 then
  begin
    cp[1] := t.Entry(h[1] + LongWord(c0)) + 1;
    cp[2] := t.Entry(h[2] + LongWord(c0)) + 1;
    cp[3] := t.Entry(h[3] + LongWord(c0)) + 1;
    cp[4] := t.Entry(h[4] + LongWord(c0)) + 1;
    cp[5] := t.Entry(h[5] + LongWord(c0)) + 1;
  end
  else if bcount > 0 then
  begin
    j := (y + 1) shl ((bcount and 3) - 1);
    Inc(cp[1], j); Inc(cp[2], j); Inc(cp[3], j); Inc(cp[4], j); Inc(cp[5], j);
  end;
  cp[0] := @t0[h[0] + LongWord(c0)];

  len := mm.P(y, m);
  order := 0;
  if len = 0 then
  begin
    if cp[4]^ <> 0 then Inc(order);
    if cp[3]^ <> 0 then Inc(order);
    if cp[2]^ <> 0 then Inc(order);
    if cp[1]^ <> 0 then Inc(order);
  end
  else
    order := 5 + Ord(len >= 8) + Ord(len >= 12) + Ord(len >= 16) + Ord(len >= 32);
  m.Add(STRETCH[sm[0].P(y, cp[0]^, 1023)]);
  m.Add(STRETCH[sm[1].P(y, cp[1]^, 1023)]);
  m.Add(STRETCH[sm[2].P(y, cp[2]^, 1023)]);
  m.Add(STRETCH[sm[3].P(y, cp[3]^, 1023)]);
  m.Add(STRETCH[sm[4].P(y, cp[4]^, 1023)]);
  m.Add(STRETCH[sm[5].P(y, cp[5]^, 1023)]);
  m.SetCtx(order + 10 * Integer(h[0] shr 13));
  pr := m.P;
  pr := (pr + 3 * a1.PP(y, pr, c0)) shr 2;
  pr := (pr + 3 * a2.PP(y, pr, c0 xor Integer(h[0] shr 2))) shr 2;
end;

{ Arithmetic coder }

type
  TCMEncoder = class
  private
    FPr: TCMPredictor;
    FModeCompress: Boolean;
    FIn: PByte;
    FInLen, FInPos: SizeInt;
    FOut: TBytes;
    FOutLen: SizeInt;
    x1, x2, x: LongWord;
    function Code(y: Integer): Integer;
    procedure PutByte(b: Byte);
    function GetByte: Byte;
    procedure CompressByte(c: Integer);
    function DecompressByte: Integer;
  public
    constructor Create(Level: Integer; Compressing: Boolean; Src: PByte; SrcLen: SizeInt);
    destructor Destroy; override;
    function Compress: TBytes;
    function Decompress(OrigLen: SizeInt): TBytes;
  end;

constructor TCMEncoder.Create(Level: Integer; Compressing: Boolean; Src: PByte; SrcLen: SizeInt);
begin
  inherited Create;
  FPr := TCMPredictor.Create(Level);
  FModeCompress := Compressing;
  FIn := Src; FInLen := SrcLen; FInPos := 0;
  x1 := 0; x2 := $ffffffff; x := 0;
  if not Compressing then
  begin
    if SrcLen < 4 then raise Exception.Create('cm: truncated stream');
    x := (LongWord(Src[0]) shl 24) or (LongWord(Src[1]) shl 16) or (LongWord(Src[2]) shl 8) or Src[3];
    FInPos := 4;
  end;
end;

destructor TCMEncoder.Destroy;
begin
  FPr.Free;
  inherited Destroy;
end;

procedure TCMEncoder.PutByte(b: Byte);
begin
  if FOutLen >= Length(FOut) then SetLength(FOut, 2 * FOutLen + 4096);
  FOut[FOutLen] := b; Inc(FOutLen);
end;

function TCMEncoder.GetByte: Byte;
begin
  if FInPos >= FInLen then Exit(255);
  Result := FIn[FInPos]; Inc(FInPos);
end;

function TCMEncoder.Code(y: Integer): Integer;
var
  p: Integer;
  xmid, r: LongWord;
begin
  p := FPr.P;
  p := p + Ord(p < 2048);
  r := x2 - x1;
  xmid := x1 + (r shr 12) * LongWord(p) + ((r and $fff) * LongWord(p) shr 12);
  if not FModeCompress then y := Ord(x <= xmid);
  if y <> 0 then x2 := xmid else x1 := xmid + 1;
  FPr.Update(y);
  while ((x1 xor x2) and $ff000000) = 0 do
  begin
    if FModeCompress then PutByte(Byte(x2 shr 24));
    x1 := x1 shl 8;
    x2 := (x2 shl 8) + 255;
    if not FModeCompress then x := (x shl 8) + GetByte;
  end;
  Result := y;
end;

procedure TCMEncoder.CompressByte(c: Integer);
var i: Integer;
begin
  for i := 7 downto 0 do Code((c shr i) and 1);
end;

function TCMEncoder.DecompressByte: Integer;
var i: Integer;
begin
  Result := 0;
  for i := 0 to 7 do Result := Result + Result + Code(0);
end;

function TCMEncoder.Compress: TBytes;
var i: Integer;
begin
  for i := 0 to FInLen - 1 do CompressByte(FIn[i]);
  PutByte(Byte(x1 shr 24));
  SetLength(FOut, FOutLen);
  Result := FOut;
end;

function TCMEncoder.Decompress(OrigLen: SizeInt): TBytes;
var i: Integer;
begin
  SetLength(FOut, OrigLen);
  FOutLen := 0;
  for i := 0 to OrigLen - 1 do PutByte(Byte(DecompressByte));
  SetLength(FOut, FOutLen);
  Result := FOut;
end;

{ Quick order-0 entropy estimate over a few samples: random/encrypted data is stored
  directly instead of spending seconds in the CM model only to fall back to raw. }
function LooksIncompressible(Src: PByte; SrcLen: SizeInt): Boolean;
var
  Count: array[0..255] of Int64;
  Chunk, Total, Start, I, J, Take: SizeInt;
  P: Double;
  H: Double;
begin
  Result := False;
  if SrcLen < 4096 then Exit;
  FillChar(Count, SizeOf(Count), 0);
  Total := 0;
  Chunk := Min(SrcLen, 65536);
  for I := 0 to 3 do
  begin
    Start := (Int64(SrcLen - Chunk) * I) div 3;
    Take := Chunk;
    for J := 0 to Take - 1 do Inc(Count[Src[Start + J]]);
    Inc(Total, Take);
  end;
  H := 0;
  for I := 0 to 255 do
    if Count[I] > 0 then
    begin
      P := Count[I] / Total;
      H := H - P * (Ln(P) / Ln(2));
    end;
  Result := H > 7.95;
end;

{ Public block API }

function CmCompressMem(Src: PByte; SrcLen: SizeInt; out Dst: TBytes; Level: Integer): Boolean;
var
  E: TCMEncoder;
  C: TBytes;
  i, n: Integer;
begin
  Result := False;
  if LooksIncompressible(Src, SrcLen) then
  begin
    SetLength(Dst, 9 + SrcLen);
    for i := 0 to 7 do Dst[i] := Byte(QWord(SrcLen) shr (8 * i));
    Dst[8] := 1;
    if SrcLen > 0 then Move(Src^, Dst[9], SrcLen);
    Exit(True);
  end;
  E := TCMEncoder.Create(Level, True, Src, SrcLen);
  try
    C := E.Compress;
  finally
    E.Free;
  end;
  SetLength(Dst, 9 + Length(C));
  for i := 0 to 7 do Dst[i] := Byte(QWord(SrcLen) shr (8 * i));
  if Length(C) >= SrcLen then
  begin
    Dst[8] := 1;                    // incompressible: store raw
    if SrcLen > 0 then Move(Src^, Dst[9], SrcLen);
    SetLength(Dst, 9 + SrcLen);
  end
  else
  begin
    Dst[8] := 0;                    // CM stream
    if Length(C) > 0 then Move(C[0], Dst[9], Length(C));
  end;
  Result := True;
end;

function CmDecompressMem(Src: PByte; SrcLen: SizeInt; out Dst: TBytes): Boolean;
var
  E: TCMEncoder;
  OrigLen: QWord;
  i: Integer;
begin
  Result := False;
  if SrcLen < 9 then Exit;
  OrigLen := 0;
  for i := 0 to 7 do OrigLen := OrigLen or (QWord(Src[i]) shl (8 * i));
  if OrigLen > QWord(High(SizeInt)) then Exit;
  if Src[8] <> 0 then
  begin
    if SrcLen - 9 < SizeInt(OrigLen) then Exit;
    SetLength(Dst, SizeInt(OrigLen));
    if OrigLen > 0 then Move(Src[9], Dst[0], SizeInt(OrigLen));
    Exit(True);
  end;
  if OrigLen = 0 then
  begin
    SetLength(Dst, 0);
    Exit(True);
  end;
  E := TCMEncoder.Create(CM_LEVEL_DEFAULT, False, Src + 9, SrcLen - 9);
  try
    Dst := E.Decompress(SizeInt(OrigLen));
  finally
    E.Free;
  end;
  Result := True;
end;

{ Stages }

constructor TCmEncStage.Create(ATarget: TOutStage);
begin
  inherited Create(ATarget);
end;

procedure TCmEncStage.DoWrite(Buf: PByte; Count: SizeInt);
begin
  if FLen + Count > Length(FBuf) then SetLength(FBuf, 2 * (FLen + Count) + 4096);
  if Count > 0 then Move(Buf^, FBuf[FLen], Count);
  Inc(FLen, Count);
end;

procedure TCmEncStage.DoFinish;
var
  Comp: TBytes;
  Size: QWord;
  b: array[0..7] of Byte;
  i: Integer;
begin
  Comp := nil;
  if FLen > 0 then CmCompressMem(PByte(@FBuf[0]), FLen, Comp, CM_LEVEL_DEFAULT)
  else CmCompressMem(nil, 0, Comp, CM_LEVEL_DEFAULT);
  Size := QWord(FLen);
  for i := 0 to 7 do b[i] := Byte(Size shr (8 * i));
  Emit(@b[0], 8);
  if Length(Comp) > 8 then Emit(@Comp[8], Length(Comp) - 8);
end;

procedure TCmDecStage.EnsureDecoded;
var
  Raw: TBytes;
  used, cap, got: SizeInt;
  b: array[0..65535] of Byte;
begin
  if FReady then Exit;
  FReady := True;
  SetLength(Raw, 0);
  used := 0; cap := 0;
  repeat
    got := Source.Read(@b[0], SizeOf(b));
    if got > 0 then
    begin
      if used + got > cap then
      begin
        cap := 2 * (used + got) + 65536;
        SetLength(Raw, cap);
      end;
      Move(b[0], Raw[used], got);
      Inc(used, got);
    end;
  until got <= 0;
  SetLength(Raw, used);
  if not CmDecompressMem(PByte(@Raw[0]), Length(Raw), FData) then
    raise EArcCorrupt.Create('cm: invalid stream');
  FPos := 0;
end;

function TCmDecStage.Read(Buf: PByte; Count: SizeInt): SizeInt;
begin
  EnsureDecoded;
  Result := Length(FData) - FPos;
  if Result > Count then Result := Count;
  if Result <= 0 then Exit(0);
  Move(FData[FPos], Buf^, Result);
  Inc(FPos, Result);
end;

initialization
  InitTables;
end.
