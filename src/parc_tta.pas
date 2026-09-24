{ TTA — códec de audio de FreeArc (Compression/MM/C_TTA.cpp + tta.cpp +
  entropy.cpp + filters.cpp).

  Stream:
    4 bytes de cabecera: level, raw_data*2+is_float, num_chan, word_size
    si level = 0 -> datos guardados: el resto se copia tal cual
    4 bytes offset (Int32 LE) + offset bytes literales (encabezado WAV)
    después, bloques:
      4 bytes BytesRead (Int32 LE): tamaño del bloque DESCOMPRIMIDO
      si raw_data = 0:
        4 bytes BitArraySize: 0 = bloque guardado (siguen BytesRead bytes crudos);
                              >0 = siguen BitArraySize bytes del codificador Rice
      (num_chan << is_float) canales de frame_len = BytesRead/N muestras:
        - raw_data = 0: decode_frame (Rice) + filters_decompress
        - raw_data != 0: muestras crudas, 4 bytes cada una
      combine_int / combine_float, entrelazado a bytes y luego los
      BytesRead mod N bytes que sobran del bloque.

  N = num_chan*byte_size.  La aritmética es de 32 bits (el encoder lo es): las
  muestras son Int32 y los filtros suman con wrapping de 32 bits.  Los filtros
  procesan ceil(order/8)*8 coeficientes (el C avanza de a 8), no `order`. }
unit parc_tta;

{$mode objfpc}{$H+}
{$R-}{$Q-}

interface

uses
  SysUtils, parc_stream;

type
  TTtaParams = record
    Level, SkipHeader, IsFloat, NumChan, WordSize, Offset, RawData: Integer;
  end;

  TTtaStage = class(TInStage)
  private
    FLevel, FIsFloat, FRawData, FNumChan, FWordSize, FByteSize, FN: Integer;
    FChan: array of array of LongInt;
    FBits: array of Byte;
    FBitsSize, FBitsPos: LongWord;
    FOut: array of Byte;
    FLen, FPos: SizeInt;
    FEof, FStarted, FStored: Boolean;
    procedure Start;
    function  NextBlock: Boolean;
    procedure BitInit(Size: LongWord);
    function  GetBinary(Bits: LongWord): LongWord;
    function  GetUnary: LongWord;
    procedure DecodeFrame(Ch: PLongInt; Len: LongWord);
    procedure FiltersDecompress(Data: PLongInt; Len: LongWord);
  public
    constructor Create(ASource: TInStage; const APar: TTtaParams);
    function Read(Buf: PByte; Count: SizeInt): SizeInt; override;
  end;

{ Parámetros como parse_TTA. }
function ParseTtaParams(const Params: TStringArray): TTtaParams;

implementation

uses
  parc_bytes, parc_methods;

const
  MAX_ORDER = 32;
  BUF_SIZE  = 256;

  BIT_MASK32: array[0..39] of LongWord = (
    $00000000, $00000001, $00000003, $00000007,
    $0000000f, $0000001f, $0000003f, $0000007f,
    $000000ff, $000001ff, $000003ff, $000007ff,
    $00000fff, $00001fff, $00003fff, $00007fff,
    $0000ffff, $0001ffff, $0003ffff, $0007ffff,
    $000fffff, $001fffff, $003fffff, $007fffff,
    $00ffffff, $01ffffff, $03ffffff, $07ffffff,
    $0fffffff, $1fffffff, $3fffffff, $7fffffff,
    $ffffffff, $ffffffff, $ffffffff, $ffffffff, $ffffffff,
    $ffffffff, $ffffffff, $ffffffff);

  { bit_shift[k] = 1<<k (saturado en 0x80000000 desde k=32).  OJO: es DISTINTA
    de shift_16[k] = bit_shift[k+4]: los umbrales del Rice usan shift_16, pero el
    offset que se le suma a `value` en decode_frame usa bit_shift[k0]. }
  BIT_SHIFT: array[0..39] of LongWord = (
    $00000001, $00000002, $00000004, $00000008,
    $00000010, $00000020, $00000040, $00000080,
    $00000100, $00000200, $00000400, $00000800,
    $00001000, $00002000, $00004000, $00008000,
    $00010000, $00020000, $00040000, $00080000,
    $00100000, $00200000, $00400000, $00800000,
    $01000000, $02000000, $04000000, $08000000,
    $10000000, $20000000, $40000000, $80000000,
    $80000000, $80000000, $80000000, $80000000,
    $80000000, $80000000, $80000000, $80000000);

  { shift_16[k] = bit_shift[k+4] }
  SHIFT16: array[0..39] of LongWord = (
    $00000010, $00000020, $00000040, $00000080,
    $00000100, $00000200, $00000400, $00000800,
    $00001000, $00002000, $00004000, $00008000,
    $00010000, $00020000, $00040000, $00080000,
    $00100000, $00200000, $00400000, $00800000,
    $01000000, $02000000, $04000000, $08000000,
    $10000000, $20000000, $40000000, $80000000,
    $80000000, $80000000, $80000000, $80000000,
    $80000000, $80000000, $80000000, $80000000,
    $80000000, $80000000, $80000000, $80000000);

  { flt_set[filtro][level-1][byte_size-1] = (order, shift, mode) }
  FLT_SET: array[0..2, 0..2, 0..3, 0..2] of Integer = (
   (((8,10,0),  (8,9,0),   (8,10,0),  (8,12,1)),
    ((8,10,0),  (8,11,0),  (8,10,0),  (16,12,1)),
    ((8,10,0),  (8,11,0),  (8,10,0),  (32,12,1))),
   (((0,0,0),   (0,0,0),   (0,0,0),   (0,0,0)),
    ((16,10,1), (16,9,1),  (16,10,1), (0,0,0)),
    ((32,11,1), (32,11,1), (32,11,1), (0,0,0))),
   (((0,0,0),   (0,0,0),   (0,0,0),   (0,0,0)),
    ((0,0,0),   (0,0,0),   (0,0,0),   (0,0,0)),
    ((0,0,0),   (16,9,1),  (16,10,1), (0,0,0))));

type
  PFlt = ^TFlt;
  TFlt = record
    order, mode, shift, round: Integer;
    qm: array[0..MAX_ORDER - 1] of LongInt;
    dx: array[0..BUF_SIZE - 1] of LongInt;
    dl: array[0..BUF_SIZE - 1] of LongInt;
    px, pl: Integer;
  end;

function Swap16(x: LongWord): LongWord; inline;
begin
  Result := ((x and $00FF) shl 8) or ((x and $FF00) shr 8);
end;

function Predictor1(x: LongInt; k: Integer): LongInt; inline;
begin
  { el C hace la resta y el shift en uint64 y RECIÉN DESPUÉS castea a long:
    castear antes cambia el resultado cuando x es negativo }
  Result := LongInt(QWord((QWord(x) shl k) - QWord(x)) shr k);
end;

{ "c*w" o "c*wf" (canales*bits; la 'f' final marca punto flotante).  Igual que
  los dos sscanf de parse_TTA/parse_MM. }
function ParseChanWord(const p: string; out a, b: Integer; out isFloat: Boolean): Boolean;
var
  star: Integer;
  w: string;
begin
  Result := False;
  isFloat := False;
  star := Pos('*', p);
  if star = 0 then Exit;
  a := StrToIntDef(Copy(p, 1, star - 1), -1);
  if a <= 0 then Exit;
  w := Copy(p, star + 1, MaxInt);
  if (w <> '') and (w[Length(w)] = 'f') then
  begin
    isFloat := True;
    w := Copy(w, 1, Length(w) - 1);
  end;
  b := StrToIntDef(w, -1);
  Result := b > 0;
end;

{ --- filtros adaptativos ------------------------------------------------- }

procedure FilterInit(fs: PFlt; order, shift, mode: Integer);
begin
  FillChar(fs^, SizeOf(TFlt), 0);
  fs^.px := 0;
  fs^.pl := 0;
  fs^.order := order;
  fs^.shift := shift;
  if shift > 0 then fs^.round := 1 shl (shift - 1) else fs^.round := 0;
  fs^.mode := mode;
end;

{ el C recorre de a 8 coeficientes, así que procesa ceil(order/8)*8 }
function FltCount(fs: PFlt): Integer; inline;
begin
  Result := ((fs^.order + 7) div 8) * 8;
end;

procedure FilterDecompress(fs: PFlt; Data: PLongInt);
var
  i, n, pl, px: Integer;
  sum, out_, in_: LongInt;
begin
  n := FltCount(fs);
  pl := fs^.pl;
  px := fs^.px;
  sum := fs^.round;
  for i := 0 to n - 1 do
    sum := sum + fs^.dl[pl + i] * fs^.qm[i];
  in_ := Data^;
  out_ := in_ + SarLongint(sum, fs^.shift);
  fs^.dl[pl + fs^.order] := out_;
  if fs^.mode = 0 then
  begin
    fs^.dl[pl + fs^.order - 1] := fs^.dl[pl + fs^.order] - fs^.dl[pl + fs^.order - 1];
    fs^.dl[pl + fs^.order - 2] := fs^.dl[pl + fs^.order - 1] - fs^.dl[pl + fs^.order - 2];
    fs^.dl[pl + fs^.order - 3] := fs^.dl[pl + fs^.order - 2] - fs^.dl[pl + fs^.order - 3];
  end;
  if in_ < 0 then
    for i := 0 to n - 1 do fs^.qm[i] := fs^.qm[i] + fs^.dx[px + i]
  else if in_ > 0 then
    for i := 0 to n - 1 do fs^.qm[i] := fs^.qm[i] - fs^.dx[px + i];
  { ojo con los índices: el C escribe en px+order, px+order-1, px+order-2, px+order-3
    (o sea *(pA-0)..*(pA-3) con pA = px+order), y los coeficientes salen de
    pl[order], pl[order-1], pl[order-2], pl[order-3] }
  fs^.dx[px + fs^.order] := ((fs^.dl[pl + fs^.order] shr 28) and 8) - 4;
  fs^.dx[px + fs^.order - 1] := ((fs^.dl[pl + fs^.order - 1] shr 29) and 4) - 2;
  fs^.dx[px + fs^.order - 2] := ((fs^.dl[pl + fs^.order - 2] shr 29) and 4) - 2;
  fs^.dx[px + fs^.order - 3] := ((fs^.dl[pl + fs^.order - 3] shr 30) and 2) - 1;
  if px + fs^.order = BUF_SIZE - 1 then
  begin
    Move(fs^.dx[px + 1], fs^.dx[0], fs^.order * SizeOf(LongInt));
    fs^.px := 0;
  end
  else fs^.px := px + 1;
  if pl + fs^.order = BUF_SIZE - 1 then
  begin
    Move(fs^.dl[pl + 1], fs^.dl[0], fs^.order * SizeOf(LongInt));
    fs^.pl := 0;
  end
  else fs^.pl := pl + 1;
  Data^ := out_;
end;

procedure TTtaStage.FiltersDecompress(Data: PLongInt; Len: LongWord);
var
  f1, f2, f3: TFlt;
  p: PLongInt;
  i: LongWord;
  last: LongInt;
begin
  FilterInit(@f1, FLT_SET[0][FLevel - 1][FByteSize - 1][0],
                 FLT_SET[0][FLevel - 1][FByteSize - 1][1],
                 FLT_SET[0][FLevel - 1][FByteSize - 1][2]);
  FilterInit(@f2, FLT_SET[1][FLevel - 1][FByteSize - 1][0],
                 FLT_SET[1][FLevel - 1][FByteSize - 1][1],
                 FLT_SET[1][FLevel - 1][FByteSize - 1][2]);
  FilterInit(@f3, FLT_SET[2][FLevel - 1][FByteSize - 1][0],
                 FLT_SET[2][FLevel - 1][FByteSize - 1][1],
                 FLT_SET[2][FLevel - 1][FByteSize - 1][2]);
  last := 0;
  p := Data;
  for i := 0 to Len - 1 do
  begin
    if f3.order <> 0 then FilterDecompress(@f3, p);
    if f2.order <> 0 then FilterDecompress(@f2, p);
    if f1.order <> 0 then FilterDecompress(@f1, p);
    case FByteSize of
      1: p^ := p^ + Predictor1(last, 4);
      2: p^ := p^ + Predictor1(last, 5);
      3: p^ := p^ + Predictor1(last, 5);
      4: p^ := p^ + last;
    end;
    last := p^;
    Inc(p);
  end;
end;

{ --- parámetros --------------------------------------------------------- }

function ParseTtaParams(const Params: TStringArray): TTtaParams;
var
  k, a, b: Integer;
  p: string;
  isF: Boolean;
begin
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
    if p = '' then Continue;
    case p[1] of
      'm': Result.Level := StrToIntDef(Copy(p, 2, MaxInt), Result.Level);
      's': Result.SkipHeader := 1;
      'f': Result.IsFloat := 1;
      'c': Result.NumChan := StrToIntDef(Copy(p, 2, MaxInt), Result.NumChan);
      'w': Result.WordSize := StrToIntDef(Copy(p, 2, MaxInt), Result.WordSize);
      'o': Result.Offset := StrToIntDef(Copy(p, 2, MaxInt), Result.Offset);
      'r': Result.RawData := StrToIntDef(Copy(p, 2, MaxInt), Result.RawData);
    else
      if ParseChanWord(p, a, b, isF) then
      begin
        Result.NumChan := a;
        Result.WordSize := b;
        if isF then Result.IsFloat := 1;
      end
      else
        raise EUnsupportedMethod.Create('tta: parámetro inválido: ' + p);
    end;
  end;
end;

{ --- bit array (entropy.cpp) -------------------------------------------- }

procedure TTtaStage.BitInit(Size: LongWord);
begin
  FBitsSize := Size;
  { 4 bytes de relleno: el C lee palabras de 32 bits y se pasa del final }
  SetLength(FBits, Size + 4);
  FillChar(FBits[0], Size + 4, 0);
  if Size > 0 then Source.ReadExact(@FBits[0], Size);
  FBitsPos := 0;
end;

function TTtaStage.GetBinary(Bits: LongWord): LongWord;
var
  fbit, rbit, pos: LongWord;
  w0, w1: LongWord;
begin
  fbit := FBitsPos and $1F;
  rbit := 32 - fbit;
  pos := FBitsPos shr 5;
  Result := 0;
  if pos > FBitsSize then Exit;
  w0 := LongWord(FBits[pos * 4]) or (LongWord(FBits[pos * 4 + 1]) shl 8) or
        (LongWord(FBits[pos * 4 + 2]) shl 16) or (LongWord(FBits[pos * 4 + 3]) shl 24);
  if Bits <= rbit then
    Result := (w0 shr fbit) and BIT_MASK32[Bits]
  else
  begin
    w1 := LongWord(FBits[pos * 4 + 4]) or (LongWord(FBits[pos * 4 + 5]) shl 8) or
          (LongWord(FBits[pos * 4 + 6]) shl 16) or (LongWord(FBits[pos * 4 + 7]) shl 24);
    Result := ((w0 shr fbit) and BIT_MASK32[rbit]) or
              ((w1 and BIT_MASK32[Bits - rbit]) shl rbit);
  end;
  Inc(FBitsPos, Bits);
end;

function TTtaStage.GetUnary: LongWord;
var
  fbit, rbit, pos: LongWord;
  mask, w: LongWord;
begin
  fbit := FBitsPos and $1F;
  rbit := 32 - fbit;
  pos := FBitsPos shr 5;
  Result := 0;
  if pos > FBitsSize then Exit;
  w := LongWord(FBits[pos * 4]) or (LongWord(FBits[pos * 4 + 1]) shl 8) or
       (LongWord(FBits[pos * 4 + 2]) shl 16) or (LongWord(FBits[pos * 4 + 3]) shl 24);
  if (w shr fbit) = BIT_MASK32[rbit] then
  begin
    Inc(Result, rbit);
    fbit := 0;
    while True do
    begin
      Inc(pos);
      w := LongWord(FBits[pos * 4]) or (LongWord(FBits[pos * 4 + 1]) shl 8) or
           (LongWord(FBits[pos * 4 + 2]) shl 16) or (LongWord(FBits[pos * 4 + 3]) shl 24);
      if w = BIT_MASK32[32] then Inc(Result, 32) else Break;
    end;
  end;
  mask := LongWord(1) shl fbit;
  while (w and mask) <> 0 do
  begin
    Inc(Result);
    if mask = $80000000 then Break;
    mask := mask shl 1;
  end;
  Inc(FBitsPos, Result + 1);
end;

procedure TTtaStage.DecodeFrame(Ch: PLongInt; Len: LongWord);
var
  p: PLongInt;
  k, k0, k1, sum0, sum1: LongWord;
  unary, binary, value: LongWord;
  depth: Integer;
  i: LongWord;
begin
  k0 := 10; k1 := 10;
  sum0 := SHIFT16[k0]; sum1 := SHIFT16[k1];
  p := Ch;
  for i := 0 to Len - 1 do
  begin
    unary := GetUnary;
    if unary = 50 then unary := GetBinary(32);
    if unary = 0 then
    begin
      depth := 0; k := k0;
    end
    else
    begin
      depth := 1; k := k1;
      Dec(unary);
    end;
    if k <> 0 then
    begin
      binary := GetBinary(k);
      value := (unary shl k) + binary;
    end
    else
      value := unary;
    if depth = 1 then
    begin
      sum1 := sum1 + value - (sum1 shr 4);
      if (k1 > 0) and (sum1 < SHIFT16[k1]) then Dec(k1)
      else if sum1 > SHIFT16[k1 + 1] then Inc(k1);
      value := value + BIT_SHIFT[k0];
    end;
    sum0 := sum0 + value - (sum0 shr 4);
    if (k0 > 0) and (sum0 < SHIFT16[k0]) then Dec(k0)
    else if sum0 > SHIFT16[k0 + 1] then Inc(k0);
    if (value and 1) <> 0 then p^ := LongInt((value + 1) shr 1)
    else p^ := -LongInt(value shr 1);
    Inc(p);
  end;
end;

{ --- stage -------------------------------------------------------------- }

constructor TTtaStage.Create(ASource: TInStage; const APar: TTtaParams);
begin
  if (APar.Level < 0) or (APar.Level > 3) then
    raise EUnsupportedMethod.Create('tta: nivel fuera de rango');
  if (APar.RawData < 0) or (APar.RawData > 1) then
    raise EUnsupportedMethod.Create('tta: raw_data no soportado');
  if (APar.NumChan < 0) or (APar.WordSize < 0) then
    raise EUnsupportedMethod.Create('tta: parámetros inválidos');
  inherited Create(ASource);
end;

procedure TTtaStage.Start;
var
  b4: array[0..3] of Byte;
  offset: LongInt;
begin
  FStarted := True;
  Source.ReadExact(@b4[0], 4);
  FLevel := b4[0];
  FIsFloat := b4[1] mod 2;
  FRawData := b4[1] div 2;
  FNumChan := b4[2];
  FWordSize := b4[3];
  FByteSize := (FWordSize + 7) div 8;
  if (FLevel > 3) or (FRawData > 1) or (FNumChan = 0) or
     ((FIsFloat <> 0) and (FByteSize <> 4)) or
     ((FIsFloat = 0) and (FByteSize >= 4)) then
    Corrupt('tta: cabecera no soportada');
  FN := FNumChan * FByteSize;
  if FN = 0 then Corrupt('tta: N = 0');
  if FLevel = 0 then
  begin
    FStored := True;
    Exit;
  end;
  Source.ReadExact(@b4[0], 4);
  offset := LongInt(LongWord(b4[0]) or (LongWord(b4[1]) shl 8) or
                    (LongWord(b4[2]) shl 16) or (LongWord(b4[3]) shl 24));
  if offset < 0 then Corrupt('tta: offset inválido');
  if offset > 0 then
  begin
    SetLength(FOut, offset);
    Source.ReadExact(@FOut[0], offset);
    FLen := offset; FPos := 0;
  end;
end;

function TTtaStage.NextBlock: Boolean;
var
  b4: array[0..3] of Byte;
  bytes_read, bit_array_size, rest, frame_len: LongWord;
  i, j, nchan: Integer;
begin
  if not Source.ReadExactOrEof(@b4[0], 4) then Exit(False);
  bytes_read := LongWord(b4[0]) or (LongWord(b4[1]) shl 8) or
                (LongWord(b4[2]) shl 16) or (LongWord(b4[3]) shl 24);
  if bytes_read > (LongWord(1) shl 30) then Corrupt('tta: bloque demasiado grande');
  frame_len := bytes_read div LongWord(FN);

  if FRawData = 0 then
  begin
    Source.ReadExact(@b4[0], 4);
    bit_array_size := LongWord(b4[0]) or (LongWord(b4[1]) shl 8) or
                      (LongWord(b4[2]) shl 16) or (LongWord(b4[3]) shl 24);
    if bit_array_size > (LongWord(1) shl 30) then
      Corrupt('tta: bloque comprimido demasiado grande');
    if bit_array_size = 0 then
    begin
      SetLength(FOut, bytes_read);
      if bytes_read > 0 then Source.ReadExact(@FOut[0], bytes_read);
      FLen := bytes_read; FPos := 0;
      Exit(True);
    end;
    BitInit(bit_array_size);
  end;

  if Length(FChan) <> 2 * FNumChan then SetLength(FChan, 2 * FNumChan);
  for i := 0 to (FNumChan shl Integer(FIsFloat)) - 1 do
  begin
    if Length(FChan[i]) < SizeInt(frame_len) then SetLength(FChan[i], frame_len);
    if FRawData <> 0 then
    begin
      { el encoder de 32 bits escribe 4 bytes por muestra }
      if frame_len > 0 then Source.ReadExact(@FChan[i][0], frame_len * 4);
    end
    else
      if frame_len > 0 then DecodeFrame(@FChan[i][0], frame_len);
    { los filtros se aplican SIEMPRE (también con raw_data) }
    FiltersDecompress(@FChan[i][0], frame_len);
  end;

  if FIsFloat <> 0 then
  begin
    for i := 0 to frame_len - 1 do
      for j := 0 to FNumChan - 1 do
        FChan[j][i] := LongInt(((LongWord(FChan[j][i]) + $3F80) shl 16) or
                               Swap16(LongWord(Abs(FChan[j + FNumChan][i]) - 1) and $FFFF) or
                               (LongWord(FChan[j + FNumChan][i]) and $80000000));
  end
  else if FNumChan > 1 then
  begin
    for i := 0 to frame_len - 1 do
    begin
      nchan := FNumChan - 1;
      FChan[nchan][i] := FChan[nchan][i] + (FChan[nchan - 1][i] div 2);
      while nchan > 0 do
      begin
        FChan[nchan - 1][i] := FChan[nchan][i] - FChan[nchan - 1][i];
        Dec(nchan);
      end;
    end;
  end;

  { entrelazado a bytes }
  SetLength(FOut, bytes_read);
  case FByteSize of
    1:
      for i := 0 to frame_len - 1 do
        for j := 0 to FNumChan - 1 do
          FOut[i * FNumChan + j] := Byte(FChan[j][i] + $80);
    2:
      for i := 0 to frame_len - 1 do
        for j := 0 to FNumChan - 1 do
        begin
          FOut[(i * FNumChan + j) * 2] := Byte(LongWord(FChan[j][i]) and $FF);
          FOut[(i * FNumChan + j) * 2 + 1] := Byte((LongWord(FChan[j][i]) shr 8) and $FF);
        end;
    3:
      for i := 0 to frame_len - 1 do
        for j := 0 to FNumChan - 1 do
        begin
          FOut[(i * FNumChan + j) * 3] := Byte(LongWord(FChan[j][i]) and $FF);
          FOut[(i * FNumChan + j) * 3 + 1] := Byte((LongWord(FChan[j][i]) shr 8) and $FF);
          FOut[(i * FNumChan + j) * 3 + 2] := Byte((LongWord(FChan[j][i]) shr 16) and $FF);
        end;
    4:
      for i := 0 to frame_len - 1 do
        for j := 0 to FNumChan - 1 do
        begin
          FOut[(i * FNumChan + j) * 4] := Byte(LongWord(FChan[j][i]) and $FF);
          FOut[(i * FNumChan + j) * 4 + 1] := Byte((LongWord(FChan[j][i]) shr 8) and $FF);
          FOut[(i * FNumChan + j) * 4 + 2] := Byte((LongWord(FChan[j][i]) shr 16) and $FF);
          FOut[(i * FNumChan + j) * 4 + 3] := Byte((LongWord(FChan[j][i]) shr 24) and $FF);
        end;
  else
    Corrupt('tta: byte_size inválido');
  end;

  rest := bytes_read mod LongWord(FN);
  if rest > 0 then Source.ReadExact(@FOut[bytes_read - rest], rest);
  FLen := bytes_read;
  FPos := 0;
  Result := True;
end;

function TTtaStage.Read(Buf: PByte; Count: SizeInt): SizeInt;
var
  n: SizeInt;
begin
  Result := 0;
  if not FStarted then Start;
  if FStored then Exit(Source.Read(Buf, Count));
  while Count > 0 do
  begin
    while FPos >= FLen do
    begin
      if FEof then Exit;
      if not NextBlock then
      begin
        FEof := True;
        Exit;
      end;
    end;
    n := FLen - FPos;
    if n > Count then n := Count;
    Move(FOut[FPos], Buf^, n);
    Inc(FPos, n); Inc(Buf, n); Dec(Count, n); Inc(Result, n);
  end;
end;

end.
