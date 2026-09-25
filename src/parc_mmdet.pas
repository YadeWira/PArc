{ MMDET — detección de datos multimedia de FreeArc (Compression/MM/mmdet.cpp, Bulat
  Ziganshin): encabezado WAV (autodetect_wav_header) y análisis de entropía
  (autodetect_by_entropy, struct Model). La usan los codificadores tta (parc_ttaenc) y mm
  (parc_mmenc) para elegir canales / bits / offset cuando el método no los fija.

  Semántica del build de 32 bits de FreeArc (long = 32 bits; en Win64 también, LLP64):
  - count(): x*2 y (-x)*2-1 con wrapping de 32 bits (en el C es overflow con signo, UB:
    gcc -O2 sin -fwrapv genera un índice negativo y el C de referencia se cae con datos de
    32 bits; con -fwrapv da lo mismo que acá).
  - _24bit_diff_run lee el canal i en p+i y p+3N+i (no p+3i): es así en el C y se respeta.
  - calc_results/comparaciones en Double (IEEE doble, como SSE). El x87 del build -m32 de
    gcc da lo mismo en todos los casos probados; la diferencia solo podría aparecer si
    bits/8 cae a <1e-10 de un entero o un resultado es exactamente best*1.05. }
unit parc_mmdet;

{$mode objfpc}{$H+}
{$R-}{$Q-}

interface

{ autodetect_wav_header.  Size = bytes válidos en Buf. }
function MmDetectWavHeader(Buf: PByte; Size: SizeInt;
  out IsFloat, NumChan, WordSize, Offset: Integer): Boolean;

{ autodetect_by_entropy.  Channels/BitValues: variantes a probar (sin el 0 final del C). }
function MmDetectByEntropy(Buf: PByte; BufSize: LongInt; const Channels, BitValues: array of Integer;
  MinEntropy: Double; out IsFloat, NumChan, WordSize, Offset: Integer): Boolean;

{ parseInt de FreeArc (Common.cpp): '=' opcional y solo dígitos }
function FaParseInt(const S: string; out V: Integer): Boolean;
{ sscanf("%d*%d%s") / sscanf("%d*%d") de parse_TTA/parse_MM }
function FaParseChanWord(const S: string; out A, B: Integer; out IsFloat: Boolean): Boolean;

implementation

const
  STATSIZE = 1024;
  LONG_MAX = 2147483647;     // long de 32 bits

type
  { struct Model (solo lo que usa autodetect_by_entropy) }
  TMmModel = record
    Channels, Bitwidth, Offset: Integer;
    XBits: LongWord;         // unsigned long
    Result: LongInt;         // long
  end;

  TStats = array of LongInt;

function U16(p: PByte): LongWord; inline;
begin
  Result := LongWord(p[0]) or (LongWord(p[1]) shl 8);
end;

function U24(p: PByte): LongWord; inline;
begin
  Result := LongWord(p[0]) or (LongWord(p[1]) shl 8) or (LongWord(p[2]) shl 16);
end;

function U32(p: PByte): LongWord; inline;
begin
  Result := LongWord(p[0]) or (LongWord(p[1]) shl 8) or (LongWord(p[2]) shl 16) or
            (LongWord(p[3]) shl 24);
end;

{ Model::ucount: cada uno de los primeros 256 valores tiene su casilla; los mayores van por
  rangos y suman bits extra }
procedure UCount(var St: TStats; var XBits: LongWord; Ch: Integer; x: LongWord);
begin
  if x < (1 shl 8) then Inc(St[Ch * STATSIZE + Integer(x)])
  else if x < (1 shl 16) then begin Inc(St[Ch * STATSIZE + 256 + Integer(x shr 8)]); Inc(XBits, 8); end
  else if x < (1 shl 24) then begin Inc(St[Ch * STATSIZE + 512 + Integer(x shr 16)]); Inc(XBits, 16); end
  else begin Inc(St[Ch * STATSIZE + 768 + Integer(x shr 24)]); Inc(XBits, 24); end;
end;

{ Model::count: x>=0 ? x*2 : (-x)*2-1, en 32 bits con wrapping }
procedure SCount(var St: TStats; var XBits: LongWord; Ch: Integer; x: LongInt); inline;
begin
  if x >= 0 then UCount(St, XBits, Ch, LongWord(x) shl 1)
  else UCount(St, XBits, Ch, ((LongWord(0) - LongWord(x)) shl 1) - 1);
end;

{ Model::calc_results }
procedure CalcResults(var M: TMmModel; const St: TStats);
var
  n, i: Integer;
  total: LongInt;
  bits, t: Double;
begin
  bits := 0;
  for n := 0 to M.Channels - 1 do
  begin
    total := 0;
    for i := 0 to STATSIZE - 1 do total := total + St[n * STATSIZE + i];
    for i := 0 to STATSIZE - 1 do
      if St[n * STATSIZE + i] <> 0 then
      begin
        { bits += stats * log(double(total)/stats) / log(double(2)) }
        t := Double(St[n * STATSIZE + i]) * Ln(Double(total) / Double(St[n * STATSIZE + i]));
        t := t / Ln(Double(2));
        bits := bits + t;
      end;
  end;
  { result = (long)(bits/8 + xbits/8)   (xbits/8 es división entera) }
  t := bits / 8 + Double(M.XBits div 8);
  M.Result := LongInt(Trunc(t));
end;

{ Model::start_count }
procedure StartCount(var M: TMmModel; var St: TStats; AChannels, ABitwidth, AOffset: Integer);
begin
  M.Channels := AChannels;
  M.Bitwidth := ABitwidth;
  M.Offset := AOffset;
  M.XBits := LongWord(AChannels * 128 * ABitwidth);
  M.Result := 0;
  SetLength(St, AChannels * STATSIZE);
  if Length(St) > 0 then FillChar(St[0], Length(St) * SizeOf(LongInt), 0);
end;

{ Model::run_order0 = run(1,8,0): _8bit_run con N=1 }
procedure RunOrder0(var M: TMmModel; var St: TStats; Buf: PByte; Size: SizeInt);
var
  i: SizeInt;
begin
  StartCount(M, St, 1, 8, 0);
  for i := 0 to Size - 1 do UCount(St, M.XBits, 0, Buf[i]);
  CalcResults(M, St);
end;

{ Model::diff_run(channels, bitwidth, offset) con _8/16/24/32bit_diff_run }
procedure DiffRun(var M: TMmModel; var St: TStats; Buf: PByte; Size: SizeInt;
  N, Bits, AOffset: Integer);
var
  p: SizeInt;
  i: Integer;
  b: PByte;
begin
  StartCount(M, St, N, Bits, AOffset);
  b := Buf + AOffset;
  Size := Size - AOffset;
  p := 0;
  case Bits of
    8:   // p+N*2 <= bufend, paso N
      while p + 2 * N <= Size do
      begin
        for i := 0 to N - 1 do UCount(St, M.XBits, i, Byte(b[p + N + i] - b[p + i]));
        Inc(p, N);
      end;
    16:  // short*: p+N*2 <= bufend son 4N bytes; paso N shorts
      while p + 4 * N <= Size do
      begin
        for i := 0 to N - 1 do
          SCount(St, M.XBits, i, LongInt(SmallInt(U16(b + p + 2 * (N + i)))) -
                                 LongInt(SmallInt(U16(b + p + 2 * i))));
        Inc(p, 2 * N);
      end;
    24:  // OJO: el C lee en p+i y p+3N+i (no p+3i)
      while p + 6 * N <= Size do
      begin
        for i := 0 to N - 1 do
          SCount(St, M.XBits, i, LongInt(U24(b + p + 3 * N + i)) - LongInt(U24(b + p + i)));
        Inc(p, 3 * N);
      end;
    32:  // long* de 32 bits: 8N bytes por comparación, paso N longs; resta con wrapping
      while p + 8 * N <= Size do
      begin
        for i := 0 to N - 1 do
          SCount(St, M.XBits, i, LongInt(U32(b + p + 4 * (N + i)) - U32(b + p + 4 * i)));
        Inc(p, 4 * N);
      end;
  end;
  CalcResults(M, St);
end;

function MmDetectByEntropy(Buf: PByte; BufSize: LongInt; const Channels, BitValues: array of Integer;
  MinEntropy: Double; out IsFloat, NumChan, WordSize, Offset: Integer): Boolean;
var
  model, best: TMmModel;
  St: TStats;
  model0, lim: Double;
  ci, bi, N, bits, off: Integer;
begin
  Result := False;
  IsFloat := 0; NumChan := 0; WordSize := 0; Offset := 0;
  if BufSize < 500 then Exit;              // no alcanza para detectar
  RunOrder0(model, St, Buf, BufSize);
  model0 := Double(model.Result);
  lim := Double(BufSize) * MinEntropy;
  if model0 < lim then Exit;               // order-0 ya lo achica mucho: no es MM
  { best_model.result = LONG_MAX; su bitwidth no se inicializa en el C, pero la regla 3
    lo reemplaza siempre en la primera iteración: 0 da el mismo resultado }
  best.Result := LONG_MAX;
  best.Bitwidth := 0;
  best.Channels := 0;
  best.Offset := 0;
  for ci := 0 to High(Channels) do
  begin
    N := Channels[ci];
    if N = 0 then Break;
    for bi := 0 to High(BitValues) do
    begin
      bits := BitValues[bi];
      if bits = 0 then Break;
      off := 0;
      while off * 8 < bits do
      begin
        DiffRun(model, St, Buf, BufSize, N, bits, off);
        if (model.Result < best.Result) and (model.Bitwidth >= best.Bitwidth) then best := model;
        { palabras más largas y "suficientemente buenas" }
        if model.Bitwidth > best.Bitwidth then
        begin
          lim := Double(best.Result) * 1.05;
          if Double(model.Result) < lim then
          begin
            lim := model0 * 0.95;
            if Double(model.Result) < lim then best := model;
          end;
        end;
        { menos bits pero al menos 5% mejor }
        lim := Double(best.Result) * 0.95;
        if Double(model.Result) < lim then best := model;
        Inc(off);
      end;
    end;
  end;
  lim := model0 * 0.95;
  if Double(best.Result) < lim then
  begin
    IsFloat := 0;
    NumChan := best.Channels;
    WordSize := best.Bitwidth;
    Offset := best.Offset;
    Result := True;
  end;
end;

function MmDetectWavHeader(Buf: PByte; Size: SizeInt;
  out IsFloat, NumChan, WordSize, Offset: Integer): Boolean;
const
  WAVE_FORMAT_PCM = 1;
  WAVE_FORMAT_PCM2 = $FFFE;
  WAVE_FORMAT_IEEE_FLOAT = 3;
  RIFF_SIGN = $46464952;
  WAVE_SIGN = $45564157;
  fmt_SIGN  = $20746D66;
  data_SIGN = $61746164;
  MAX_BPS = 32;
  HDR = 36;                  // sizeof(wave_hdr_t)
var
  s1, skip: LongWord;
  p, np: Int64;
  guard: Int64;
begin
  Result := False;
  IsFloat := 0; NumChan := 0; WordSize := 0; Offset := 0;
  if (Size < HDR) or (U32(Buf) <> RIFF_SIGN) or (U32(Buf + 8) <> WAVE_SIGN) or
     (U32(Buf + 12) <> fmt_SIGN) or (U32(Buf + 16) > U32(Buf + 4)) or
     (U16(Buf + 22) = 0) or (U16(Buf + 34) > MAX_BPS) then Exit;
  case U16(Buf + 20) of
    WAVE_FORMAT_IEEE_FLOAT: IsFloat := 1;
    WAVE_FORMAT_PCM, WAVE_FORMAT_PCM2: IsFloat := 0;
  else
    Exit;
  end;
  p := HDR;
  s1 := U32(Buf + 16);
  { bytes extra del chunk fmt (comparación sin signo de 32 bits, como el C) }
  if s1 > 16 then
  begin
    if (s1 - 16) >= LongWord(Size - p) then Exit;
    p := p + (s1 - 16);
  end;
  if 8 >= LongWord(Size - p) then Exit;
  { saltear subchunks hasta 'data'.  skip_bytes es ulong de 32 bits y p avanza con wrapping:
    con SubchunkSize >= 0xFFFFFFF0 el C retrocede o no avanza (bucle infinito o lectura antes
    del buffer).  Acá eso se declara "no es WAV". }
  guard := 0;
  while U32(Buf + p) <> data_SIGN do
  begin
    skip := LongWord(8 + U32(Buf + p + 4));
    if LongWord(skip + 8) >= LongWord(Size - p) then Exit;
    np := Int64(LongInt(LongWord(p) + skip));   // puntero de 32 bits
    if (np < 0) or (np = p) then Exit;
    Inc(guard);
    if guard > Size then Exit;
    p := np;
    if p + 8 > Size then Exit;
  end;
  p := p + 8;
  NumChan := U16(Buf + 22);
  WordSize := U16(Buf + 34);
  Offset := Integer(p);
  Result := True;
end;

{ --- parámetros compartidos por parse_TTA y parse_MM --------------------------- }

function FaParseInt(const S: string; out V: Integer): Boolean;
var
  i: Integer;
  n: QWord;
begin
  Result := False;
  V := 0;
  i := 1;
  if (i <= Length(S)) and (S[i] = '=') then Inc(i);
  if i > Length(S) then Exit;
  n := 0;
  while (i <= Length(S)) and (S[i] in ['0'..'9']) do
  begin
    n := n * 10 + QWord(Ord(S[i]) - Ord('0'));
    if n > High(LongInt) then Exit;
    Inc(i);
  end;
  if i <= Length(S) then Exit;
  V := Integer(n);
  Result := True;
end;

{ %d de sscanf: blancos, signo opcional y al menos un dígito }
function ScanInt(const S: string; var i: Integer; out V: Integer): Boolean;
var
  neg: Boolean;
  n: Int64;
  d: Integer;
begin
  Result := False;
  V := 0;
  while (i <= Length(S)) and (S[i] in [' ', #9, #10, #13, #11, #12]) do Inc(i);
  neg := False;
  if (i <= Length(S)) and (S[i] in ['+', '-']) then
  begin
    neg := S[i] = '-';
    Inc(i);
  end;
  if (i > Length(S)) or not (S[i] in ['0'..'9']) then Exit;
  n := 0;
  d := 0;
  while (i <= Length(S)) and (S[i] in ['0'..'9']) do
  begin
    if n < High(LongInt) then n := n * 10 + (Ord(S[i]) - Ord('0'));
    Inc(i); Inc(d);
  end;
  if n > High(LongInt) then n := High(LongInt);
  if neg then n := -n;
  V := Integer(n);
  Result := True;
end;

function FaParseChanWord(const S: string; out A, B: Integer; out IsFloat: Boolean): Boolean;
var
  i, j: Integer;
begin
  Result := False;
  IsFloat := False;
  A := 0; B := 0;
  i := 1;
  if not ScanInt(S, i, A) then Exit;
  if (i > Length(S)) or (S[i] <> '*') then Exit;
  Inc(i);
  if not ScanInt(S, i, B) then Exit;
  { %s: el token siguiente (tras blancos) tiene que ser exactamente "f" }
  while (i <= Length(S)) and (S[i] in [' ', #9, #10, #13, #11, #12]) do Inc(i);
  j := i;
  while (j <= Length(S)) and not (S[j] in [' ', #9, #10, #13, #11, #12]) do Inc(j);
  IsFloat := Copy(S, i, j - i) = 'f';
  Result := True;
end;

end.
