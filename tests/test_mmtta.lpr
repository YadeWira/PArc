{ test_mmtta: helper of tests/mmtta.sh and tests/mmtta_cross.sh for PArc's own multimedia
  methods (src/parc_tta.pas, src/parc_mm.pas, src/parc_mmdet.pas, src/tta/mmtta_core.c).
    test_mmtta enc <method> <in> <out> <chunk>   encode, writing in pieces of <chunk> bytes
                                                 (0 = random sizes, fixed seed)
    test_mmtta dec <method> <in> <out>           decode, reading in random-sized pieces
    test_mmtta fuzz <method> <stream> <n> <seed> decode <n> damaged copies (flipped bytes, cuts,
                                                 inserted/deleted bytes): each must give data or a
                                                 clean EArcCorrupt, never another exception
    test_mmtta synth <dir>                       synthetic WAV/AIFF/BMP/TGA/PGM/PPM/TIFF/raw files
    test_mmtta detect <in>                       what parc_mmdet says about the file
  Exit code 0 = ok. }
program test_mmtta;

{$mode objfpc}{$H+}

uses
  SysUtils, Classes, Math, parc_bytes, parc_stream, parc_outstream, parc_mmdet, parc_tta, parc_mm;

function NewEncoder(const Method: string; Sink: TOutStage): TOutStage;
var
  Parts: TStringArray;
begin
  Parts := Method.Split([':']);
  case Parts[0] of
    'tta': Result := TTtaEncStage.Create(Sink, Parts);
    'mm': Result := TMmEncStage.Create(Sink, Parts);
  else
    raise Exception.Create('unknown method ' + Method);
  end;
end;

function NewDecoder(const Method: string; Src: TInStage): TInStage;
var
  Parts: TStringArray;
begin
  Parts := Method.Split([':']);
  case Parts[0] of
    'tta': Result := TTtaStage.Create(Src, ParseTtaParams(Parts));
    'mm': Result := TMmStage.Create(Src, ParseMmParams(Parts));
  else
    raise Exception.Create('unknown method ' + Method);
  end;
end;

function LoadFile(const FN: string): TBytes;
var
  fs: TFileStream;
begin
  fs := TFileStream.Create(FN, fmOpenRead or fmShareDenyNone);
  try
    SetLength(Result, fs.Size);
    if fs.Size > 0 then fs.ReadBuffer(Result[0], fs.Size);
  finally
    fs.Free;
  end;
end;

procedure SaveFile(const FN: string; const B: TBytes; Len: SizeInt = -1);
var
  fs: TFileStream;
begin
  if Len < 0 then Len := Length(B);
  fs := TFileStream.Create(FN, fmCreate);
  try
    if Len > 0 then fs.WriteBuffer(B[0], Len);
  finally
    fs.Free;
  end;
end;

function Encode(const Method: string; const Data: TBytes; Chunk: SizeInt): TBytes;
var
  Sink: TMemSink;
  E: TOutStage;
  p, n: SizeInt;
begin
  Sink := TMemSink.Create;
  E := NewEncoder(Method, Sink);
  try
    p := 0;
    while p < Length(Data) do
    begin
      if Chunk > 0 then n := Chunk else n := 1 + Random(200000);
      if n > Length(Data) - p then n := Length(Data) - p;
      E.Write(@Data[p], n);
      Inc(p, n);
    end;
    E.Finish;
    Result := Sink.Bytes;
  finally
    E.Free;
  end;
end;

function Decode(const Method: string; const C: TBytes; out Len: SizeInt): TBytes;
var
  D: TInStage;
  n, k: SizeInt;
begin
  if Length(C) > 0 then D := NewDecoder(Method, TMemStage.Create(@C[0], Length(C)))
  else D := NewDecoder(Method, TMemStage.Create(nil, 0));
  try
    SetLength(Result, 1 shl 16);
    Len := 0;
    repeat
      if Len + (1 shl 20) > Length(Result) then SetLength(Result, 2 * Length(Result) + (1 shl 20));
      k := 1 + Random(100000);
      n := D.Read(@Result[Len], k);
      Inc(Len, n);
    until n = 0;
  finally
    D.Free;
  end;
end;

procedure DoFuzz(const Method, FN: string; N, Seed: Integer);
var
  C, D: TBytes;
  i, k, Clean, Ok: Integer;
  L: SizeInt;
  p: SizeInt;
begin
  C := LoadFile(FN);
  RandSeed := Seed;
  Clean := 0; Ok := 0;
  for i := 1 to N do
  begin
    D := Copy(C);
    case Random(4) of
      0: for k := 0 to Random(4) do
           if Length(D) > 0 then D[Random(Length(D))] := D[Random(Length(D))] xor (1 shl Random(8));
      1: if Length(D) > 0 then SetLength(D, Random(Length(D)));
      2: begin
           p := Random(Length(D) + 1);
           Insert([Byte(Random(256))], D, p);
         end;
      3: if Length(D) > 0 then Delete(D, Random(Length(D)), 1 + Random(8));
    end;
    try
      Decode(Method, D, L);
      Inc(Ok);
    except
      on E: EArcCorrupt do Inc(Clean);
      on E: Exception do
      begin
        WriteLn('case ', i, ': ', E.ClassName, ': ', E.Message);
        Halt(1);
      end;
    end;
  end;
  WriteLn(N, ' damaged: ', Clean, ' clean errors, ', Ok, ' decoded');
end;

{ ---------------------------------------------------------------------------------------- }
{ synthetic files }

var
  W: TBytes;
  WLen: SizeInt;

procedure B8(v: LongWord); begin if WLen >= Length(W) then SetLength(W, 2 * Length(W) + 1024); W[WLen] := Byte(v); Inc(WLen); end;
procedure L16(v: LongWord); begin B8(v); B8(v shr 8); end;
procedure L32(v: LongWord); begin L16(v); L16(v shr 16); end;
procedure M16(v: LongWord); begin B8(v shr 8); B8(v); end;
procedure M32(v: LongWord); begin M16(v shr 16); M16(v); end;
procedure Tag(const S: string); var i: Integer; begin for i := 1 to 4 do B8(Ord(S[i])); end;
procedure Flush(const FN: string); begin SaveFile(FN, W, WLen); WLen := 0; end;

{ a sample of a music-like signal: a few partials, a slow envelope, some noise }
function Sig(t, ch: Integer): Double;
begin
  Result := 0.4 * Sin(t * 0.0031 + ch) + 0.2 * Sin(t * 0.0011 * (ch + 1)) + 0.1 * Sin(t * 0.017) * Sin(t * 0.0003) +
    0.002 * (Random - 0.5);
end;

procedure PutSample(v: Double; Bits: Integer; BE, Flt: Boolean);
var
  x: Int64;
  f: Single;
begin
  if Flt then
  begin
    f := v;
    if BE then M32(PLongWord(@f)^) else L32(PLongWord(@f)^);
    Exit;
  end;
  x := Round(v * (Int64(1) shl (Bits - 1)));
  if x >= Int64(1) shl (Bits - 1) then x := (Int64(1) shl (Bits - 1)) - 1;
  if x < -(Int64(1) shl (Bits - 1)) then x := -(Int64(1) shl (Bits - 1));
  case Bits of
    8: B8(LongWord(x + 128));
    16: if BE then M16(LongWord(x)) else L16(LongWord(x));
    24: if BE then begin B8(LongWord(x) shr 16); M16(LongWord(x)); end
        else begin L16(LongWord(x)); B8(LongWord(x) shr 16); end;
    32: if BE then M32(LongWord(x)) else L32(LongWord(x));
  end;
end;

procedure Wav(const FN: string; Bits, Ch, Frames: Integer; Flt: Boolean; Trailer: Integer);
var
  t, c, Bytes: Integer;
begin
  Bytes := Frames * Ch * (Bits div 8);
  Tag('RIFF'); L32(36 + Bytes + Trailer); Tag('WAVE');
  Tag('fmt '); L32(16); L16(IfThen(Flt, 3, 1)); L16(Ch); L32(44100); L32(44100 * Ch * Bits div 8);
  L16(Ch * Bits div 8); L16(Bits);
  Tag('data'); L32(Bytes);
  for t := 0 to Frames - 1 do
    for c := 0 to Ch - 1 do PutSample(Sig(t, c), Bits, False, Flt);
  for t := 1 to Trailer do B8(t * 7);
  Flush(FN);
end;

procedure Aiff(const FN: string; Bits, Ch, Frames: Integer);
var
  t, c, Bytes: Integer;
begin
  Bytes := Frames * Ch * (Bits div 8);
  Tag('FORM'); M32(4 + 26 + 16 + Bytes); Tag('AIFF');
  Tag('COMM'); M32(18); M16(Ch); M32(Frames); M16(Bits);
  B8($40); B8($0E); B8($AC); B8($44); for t := 1 to 6 do B8(0);
  Tag('SSND'); M32(8 + Bytes); M32(0); M32(0);
  for t := 0 to Frames - 1 do
    for c := 0 to Ch - 1 do
      if Bits = 8 then B8(Byte(Round(Sig(t, c) * 127))) else PutSample(Sig(t, c), Bits, True, False);
  Flush(FN);
end;

function Pix(x, y, c: Integer): Integer;
begin
  Result := (x * (c + 1) + y * 2 + Round(40 * Sin(x * 0.05) * Cos(y * 0.07)) + Random(6)) and 255;
end;

procedure Bmp(const FN: string; Wd, Ht, Bpp: Integer);
var
  Row, x, y, c, k: Integer;
begin
  Row := ((Wd * Bpp + 31) div 32) * 4;
  B8(Ord('B')); B8(Ord('M')); L32(54 + 1024 * Ord(Bpp = 8) + Row * Ht); L32(0); L32(54 + 1024 * Ord(Bpp = 8));
  L32(40); L32(Wd); L32(Ht); L16(1); L16(Bpp); L32(0); L32(Row * Ht); L32(2835); L32(2835); L32(0); L32(0);
  if Bpp = 8 then for k := 0 to 255 do L32(k * $010101);
  for y := 0 to Ht - 1 do
  begin
    for x := 0 to Wd - 1 do
      for c := 0 to Bpp div 8 - 1 do B8(Pix(x, y, c));
    for k := Wd * Bpp div 8 to Row - 1 do B8(0);
  end;
  Flush(FN);
end;

procedure Tga(const FN: string; Wd, Ht, Bpp: Integer);
var
  x, y, c: Integer;
begin
  B8(3); B8(0); B8(2); L16(0); L16(0); B8(0); L16(0); L16(0); L16(Wd); L16(Ht); B8(Bpp); B8(0);
  B8(1); B8(2); B8(3);
  for y := 0 to Ht - 1 do
    for x := 0 to Wd - 1 do
      for c := 0 to Bpp div 8 - 1 do B8(Pix(x, y, c));
  Flush(FN);
end;

procedure Pnm(const FN: string; Wd, Ht, Ch, MaxV: Integer);
var
  x, y, c: Integer;
  S: string;
begin
  if Ch = 1 then S := 'P5' else S := 'P6';
  S := S + #10'# synthetic'#10 + IntToStr(Wd) + ' ' + IntToStr(Ht) + #10 + IntToStr(MaxV) + #10;
  for x := 1 to Length(S) do B8(Ord(S[x]));
  for y := 0 to Ht - 1 do
    for x := 0 to Wd - 1 do
      for c := 0 to Ch - 1 do
        if MaxV > 255 then M16(Pix(x, y, c) * 200 + Random(50)) else B8(Pix(x, y, c));
  Flush(FN);
end;

procedure Tiff(const FN: string; Wd, Ht: Integer);
var
  x, y, c: Integer;
  procedure Ent(Tg, Ty, Cnt, V: LongWord); begin L16(Tg); L16(Ty); L32(Cnt); L32(V); end;
begin
  B8(Ord('I')); B8(Ord('I')); L16(42); L32(8);
  L16(9);
  Ent(256, 4, 1, Wd); Ent(257, 4, 1, Ht); Ent(258, 3, 1, 8); Ent(259, 3, 1, 1); Ent(262, 3, 1, 2);
  Ent(273, 4, 1, 8 + 2 + 9 * 12 + 4); Ent(277, 3, 1, 3); Ent(278, 4, 1, Ht); Ent(279, 4, 1, Wd * Ht * 3);
  L32(0);
  for y := 0 to Ht - 1 do
    for x := 0 to Wd - 1 do
      for c := 0 to 2 do B8(Pix(x, y, c));
  Flush(FN);
end;

procedure Raw16(const FN: string; Ch, Frames: Integer);
var
  t, c: Integer;
begin
  for t := 0 to Frames - 1 do
    for c := 0 to Ch - 1 do PutSample(Sig(t, c), 16, False, False);
  Flush(FN);
end;

procedure Synth(const Dir: string);
begin
  ForceDirectories(Dir);
  RandSeed := 12345;
  SetLength(W, 1 shl 20);
  WLen := 0;
  Wav(Dir + '/w8m.wav', 8, 1, 300000, False, 0);
  Wav(Dir + '/w16s.wav', 16, 2, 400000, False, 37);
  Wav(Dir + '/w16m.wav', 16, 1, 150001, False, 0);
  Wav(Dir + '/w24s.wav', 24, 2, 200000, False, 0);
  Wav(Dir + '/w32s.wav', 32, 2, 100000, False, 0);
  Wav(Dir + '/wf32s.wav', 32, 2, 100000, True, 0);
  Wav(Dir + '/w16c6.wav', 16, 6, 60000, False, 3);
  Wav(Dir + '/w16tiny.wav', 16, 2, 3, False, 1);
  Aiff(Dir + '/a16s.aif', 16, 2, 150000);
  Aiff(Dir + '/a8m.aif', 8, 1, 100000);
  Raw16(Dir + '/raw16s.pcm', 2, 300000);
  Bmp(Dir + '/b24.bmp', 333, 211, 24);
  Bmp(Dir + '/b32.bmp', 300, 200, 32);
  Bmp(Dir + '/b8.bmp', 257, 199, 8);
  Tga(Dir + '/t24.tga', 320, 240, 24);
  Tga(Dir + '/t32.tga', 200, 150, 32);
  Pnm(Dir + '/p5.pgm', 400, 300, 1, 255);
  Pnm(Dir + '/p6.ppm', 300, 200, 3, 255);
  Pnm(Dir + '/p6w.ppm', 200, 100, 3, 65535);
  Tiff(Dir + '/i24.tif', 256, 180);
end;

procedure Detect(const FN: string);
var
  D: TBytes;
  L: TMmLayout;
  R: Double;
  n: SizeInt;
begin
  D := LoadFile(FN);
  n := Min(Length(D), 1 shl 20);
  if (n > 0) and MmParseHeader(@D[0], n, L) then
    WriteLn('header kind=', L.Kind, ' chan=', L.NumChan, ' bits=', L.Bits, ' flags=', L.Flags, ' offset=', L.Offset,
      ' len=', L.DataLen, ' width=', L.Width, ' row=', L.RowBytes)
  else if (n > 0) and MmDetectStats(@D[0], n, [1, 2, 3, 4], [1, 2, 3, 4], True, 0.80, L, R) then
    WriteLn('stats chan=', L.NumChan, ' bits=', L.Bits, ' flags=', L.Flags, ' ratio=', R: 0: 3)
  else
    WriteLn('none');
end;

var
  Data, C: TBytes;
  L: SizeInt;
begin
  try
    RandSeed := 1;
    if (ParamCount >= 5) and (ParamStr(1) = 'enc') then
    begin
      Data := LoadFile(ParamStr(3));
      C := Encode(ParamStr(2), Data, StrToInt(ParamStr(5)));
      SaveFile(ParamStr(4), C);
    end
    else if (ParamCount >= 4) and (ParamStr(1) = 'dec') then
    begin
      C := LoadFile(ParamStr(3));
      Data := Decode(ParamStr(2), C, L);
      SaveFile(ParamStr(4), Data, L);
    end
    else if (ParamCount >= 5) and (ParamStr(1) = 'fuzz') then
      DoFuzz(ParamStr(2), ParamStr(3), StrToInt(ParamStr(4)), StrToInt(ParamStr(5)))
    else if (ParamCount >= 2) and (ParamStr(1) = 'synth') then
      Synth(ParamStr(2))
    else if (ParamCount >= 2) and (ParamStr(1) = 'detect') then
      Detect(ParamStr(2))
    else
    begin
      WriteLn('usage: see the header of tests/test_mmtta.lpr');
      Halt(2);
    end;
  except
    on E: Exception do
    begin
      WriteLn(E.ClassName, ': ', E.Message);
      Halt(1);
    end;
  end;
end.
