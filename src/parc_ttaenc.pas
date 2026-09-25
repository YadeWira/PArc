{ TTA (codificador): compresor de audio sin pérdida de FreeArc 0.67. Port de
  Compression/MM/tta.cpp (tta_compress, read_wave, split_int, split_float),
  entropy.cpp (encode_frame, put_binary, put_unary), filters.cpp (filters_compress,
  filter_compress) y C_TTA.cpp (parse_TTA); detección en parc_mmdet (mmdet.cpp).
  Decodificador: parc_tta (TTtaStage), que documenta el formato.

  Salida idéntica byte a byte a tta_compress del build de 32 bits (long = 32 bits) con
  lecturas completas y memoria de BigAlloc en cero (VirtualAlloc):
    - sin c/w/f: se juntan los primeros 1mb y se detecta (WAV y si no entropía con 1-2
      canales de 8-16 bits, umbral 0.50); si falla todo -> "guardado" (U32 0 + datos).
    - m0 -> guardado.  Con c/w/f el formato es el del método (w por defecto = 1 bit, o 4 bits
      con f, que por eso termina guardado: es así en el C).
    - bloques de 2^18 muestras (N = canales*bytes por muestra), cada uno
      U32 bytes, U32 tamaño Rice (0 = bloque guardado) + datos + resto (< N bytes).
  Memoria: 1mb de detección + un bloque (N*2^18 bytes) + canales (4 bytes por muestra) +
  el bit array (N*(2^18+100) bytes).

  Desvíos deliberados del C (su salida no se puede decodificar o se cae):
    - num_chan > 255 (el C trunca el byte de cabecera) o word_size = 0 (el C divide por
      cero): se guarda sin comprimir (nivel 0).
    - raw_data 2 (el decodificador de FreeArc lo rechaza): error de parámetros. }
unit parc_ttaenc;

{$mode objfpc}{$H+}
{$R-}{$Q-}

interface

uses
  SysUtils, parc_outstream;

type
  ETtaEncParams = class(Exception);
  ETtaEncError = class(Exception);

  TTtaEncParams = record
    Level, SkipHeader, IsFloat, NumChan, WordSize, Offset, RawData: Integer;
  end;

  TTtaEncPhase = (tpNone, tpDetect, tpHeader, tpStored, tpBlocks);

  TTtaEncStage = class(TOutStage)
  private
    FPar: TTtaEncParams;
    FPhase: TTtaEncPhase;
    FPrev: array of Byte;           // primer mb (detección)
    FPrevLen: SizeInt;
    FHdrLeft: SizeInt;              // bytes de encabezado (offset) que faltan copiar
    FLevel, FIsFloat, FNumChan, FWordSize, FByteSize, FN, FRaw: Integer;
    FBlk: array of Byte;            // bloque de entrada (FWanted bytes)
    FBlkLen, FWanted: SizeInt;
    FChan: array of array of LongInt;
    FBits: array of LongWord;       // bit_array_write
    FBitsSize: LongWord;            // bit_array_write_size (bytes)
    FBitPos: LongWord;              // bit_array_write_bits
    FMaxWord: SizeInt;              // palabra más alta tocada (para volver a limpiar)
    procedure Start;
    procedure Decide;
    procedure BeginStored;
    procedure BeginCoded(Offset: Integer; Hdr: PByte);
    procedure FeedBlocks(Buf: PByte; Count: SizeInt);
    procedure EncodeBlock;
    procedure PutBinary(Value, Bits: LongWord);
    procedure PutUnary(Value: LongWord);
    procedure EncodeFrame(Data: PLongInt; Len: LongWord);
  protected
    procedure DoWrite(Buf: PByte; Count: SizeInt); override;
    procedure DoFinish; override;
  public
    { Params = partes del método separadas por ':' con Params[0] = 'tta' }
    constructor Create(ATarget: TOutStage; const Params: TStringArray);
    constructor Create(ATarget: TOutStage; const APar: TTtaEncParams);
  end;

{ parse_TTA (parseInt estricto; "c*w" / "c*wf" como los sscanf del C) }
function ParseTtaEncParams(const Params: TStringArray): TTtaEncParams;

implementation

uses
  parc_mmdet;

{$IFDEF ENDIAN_BIG}
  {$ERROR 'parc_ttaenc: el bit array se arma en palabras little-endian'}
{$ENDIF}

const
  FRAME_SIZE = 1 shl 18;          // muestras por bloque
  DETECT_SIZE = 1 shl 20;         // 1mb de detección
  MAX_ORDER = 32;
  BUF_SIZE = 256;

  { bit_mask32 / bit_shift / shift_16 de entropy.cpp.  El C tiene 33 y 40 entradas; se
    extienden saturadas (como parc_tta) por si k crece más allá con datos patológicos,
    donde el C lee fuera del arreglo. }
  BIT_MASK32: array[0..63] of LongWord = (
    $00000000, $00000001, $00000003, $00000007, $0000000f, $0000001f, $0000003f, $0000007f,
    $000000ff, $000001ff, $000003ff, $000007ff, $00000fff, $00001fff, $00003fff, $00007fff,
    $0000ffff, $0001ffff, $0003ffff, $0007ffff, $000fffff, $001fffff, $003fffff, $007fffff,
    $00ffffff, $01ffffff, $03ffffff, $07ffffff, $0fffffff, $1fffffff, $3fffffff, $7fffffff,
    $ffffffff, $ffffffff, $ffffffff, $ffffffff, $ffffffff, $ffffffff, $ffffffff, $ffffffff,
    $ffffffff, $ffffffff, $ffffffff, $ffffffff, $ffffffff, $ffffffff, $ffffffff, $ffffffff,
    $ffffffff, $ffffffff, $ffffffff, $ffffffff, $ffffffff, $ffffffff, $ffffffff, $ffffffff,
    $ffffffff, $ffffffff, $ffffffff, $ffffffff, $ffffffff, $ffffffff, $ffffffff, $ffffffff);

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

  { canales / bits que prueba tta.cpp al detectar por entropía }
  TTA_CHANNELS: array[0..1] of Integer = (1, 2);
  TTA_BITVALUES: array[0..1] of Integer = (8, 16);

var
  BIT_SHIFT: array[0..63] of LongWord;   // 1<<k, saturado en 0x80000000 desde k=31
  SHIFT16: array[0..63] of LongWord;     // shift_16[k] = bit_shift[k+4]

type
  PFlt = ^TFlt;
  TFlt = record
    order, mode, shift, round: LongInt;
    qm: array[0..MAX_ORDER - 1] of LongInt;
    dx: array[0..BUF_SIZE - 1] of LongInt;
    dl: array[0..BUF_SIZE - 1] of LongInt;
    px, pl: Integer;
  end;

procedure InitTables;
var
  k: Integer;
begin
  for k := 0 to 63 do
  begin
    if k < 31 then BIT_SHIFT[k] := LongWord(1) shl k else BIT_SHIFT[k] := $80000000;
    if k + 4 < 31 then SHIFT16[k] := LongWord(1) shl (k + 4) else SHIFT16[k] := $80000000;
  end;
end;

{ --- parámetros ------------------------------------------------------------ }

function ParseTtaEncParams(const Params: TStringArray): TTtaEncParams;
var
  k, a, b: Integer;
  p: string;
  isF, ok: Boolean;
begin
  if (Length(Params) = 0) or (Params[0] <> 'tta') then
    raise ETtaEncParams.Create('tta: no es el método tta');
  // TTA_METHOD::TTA_METHOD
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
    ok := True;
    if p <> '' then
      case p[1] of
        'm': ok := FaParseInt(Copy(p, 2, MaxInt), Result.Level);
        's': begin Result.SkipHeader := 1; Continue; end;
        'f': begin Result.IsFloat := 1; Continue; end;
        'c': ok := FaParseInt(Copy(p, 2, MaxInt), Result.NumChan);
        'w': ok := FaParseInt(Copy(p, 2, MaxInt), Result.WordSize);
        'o': ok := FaParseInt(Copy(p, 2, MaxInt), Result.Offset);
        'r': ok := FaParseInt(Copy(p, 2, MaxInt), Result.RawData);
      else
        ok := False;
      end
    else
      ok := False;
    if (p <> '') and (p[1] in ['m', 'c', 'w', 'o', 'r']) then
    begin
      if not ok then raise ETtaEncParams.CreateFmt('tta: parámetro inválido "%s"', [p]);
      Continue;
    end;
    // sin nombre: c*w o c*wf
    if FaParseChanWord(p, a, b, isF) then
    begin
      if isF then Result.IsFloat := 1 else Result.IsFloat := 0;
      Result.NumChan := a;
      Result.WordSize := b;
    end
    else
      raise ETtaEncParams.CreateFmt('tta: parámetro inválido "%s"', [p]);
  end;
end;

{ --- filtros (filters.cpp) --------------------------------------------------- }

procedure FilterInit(fs: PFlt; order, shift, mode: Integer);
begin
  FillChar(fs^, SizeOf(TFlt), 0);
  fs^.order := order;
  fs^.shift := shift;
  if shift > 0 then fs^.round := LongInt(1) shl (shift - 1) else fs^.round := 0;
  fs^.mode := mode;
end;

{ filter_compress: el C recorre de a 8 coeficientes (order es siempre 8/16/32) }
procedure FilterCompress(fs: PFlt; Data: PLongInt); inline;
var
  i, n, pl, px, ord_: Integer;
  sum, out_, in_: LongInt;
  dl, dx, qm: PLongInt;
begin
  ord_ := fs^.order;
  n := ((ord_ + 7) div 8) * 8;
  pl := fs^.pl;
  px := fs^.px;
  dl := @fs^.dl[pl];
  dx := @fs^.dx[px];
  qm := @fs^.qm[0];
  sum := fs^.round;
  i := 0;
  while i < n do        // de a 8, como el C
  begin
    sum := sum + dl[i] * qm[i] + dl[i + 1] * qm[i + 1] + dl[i + 2] * qm[i + 2] + dl[i + 3] * qm[i + 3]
               + dl[i + 4] * qm[i + 4] + dl[i + 5] * qm[i + 5] + dl[i + 6] * qm[i + 6] + dl[i + 7] * qm[i + 7];
    Inc(i, 8);
  end;
  in_ := Data^;
  out_ := in_ - SarLongint(sum, fs^.shift);
  { pl[order] = entrada original (el decodificador guarda ahí su salida, que es la misma) }
  dl[ord_] := in_;
  if fs^.mode = 0 then
  begin
    dl[ord_ - 1] := dl[ord_] - dl[ord_ - 1];
    dl[ord_ - 2] := dl[ord_ - 1] - dl[ord_ - 2];
    dl[ord_ - 3] := dl[ord_ - 2] - dl[ord_ - 3];
  end;
  if out_ < 0 then
  begin
    i := 0;
    while i < n do
    begin
      qm[i] := qm[i] + dx[i]; qm[i + 1] := qm[i + 1] + dx[i + 1];
      qm[i + 2] := qm[i + 2] + dx[i + 2]; qm[i + 3] := qm[i + 3] + dx[i + 3];
      qm[i + 4] := qm[i + 4] + dx[i + 4]; qm[i + 5] := qm[i + 5] + dx[i + 5];
      qm[i + 6] := qm[i + 6] + dx[i + 6]; qm[i + 7] := qm[i + 7] + dx[i + 7];
      Inc(i, 8);
    end;
  end
  else if out_ > 0 then
  begin
    i := 0;
    while i < n do
    begin
      qm[i] := qm[i] - dx[i]; qm[i + 1] := qm[i + 1] - dx[i + 1];
      qm[i + 2] := qm[i + 2] - dx[i + 2]; qm[i + 3] := qm[i + 3] - dx[i + 3];
      qm[i + 4] := qm[i + 4] - dx[i + 4]; qm[i + 5] := qm[i + 5] - dx[i + 5];
      qm[i + 6] := qm[i + 6] - dx[i + 6]; qm[i + 7] := qm[i + 7] - dx[i + 7];
      Inc(i, 8);
    end;
  end;
  { *(pA-0..3) con pA = px+order; los signos salen de pl[order..order-3] }
  dx[ord_]     := LongInt((LongWord(dl[ord_])     shr 28) and 8) - 4;
  dx[ord_ - 1] := LongInt((LongWord(dl[ord_ - 1]) shr 29) and 4) - 2;
  dx[ord_ - 2] := LongInt((LongWord(dl[ord_ - 2]) shr 29) and 4) - 2;
  dx[ord_ - 3] := LongInt((LongWord(dl[ord_ - 3]) shr 30) and 2) - 1;
  if px + ord_ = BUF_SIZE - 1 then
  begin
    Move(fs^.dx[px + 1], fs^.dx[0], ord_ * SizeOf(LongInt));
    fs^.px := 0;
  end
  else fs^.px := px + 1;
  if pl + ord_ = BUF_SIZE - 1 then
  begin
    Move(fs^.dl[pl + 1], fs^.dl[0], ord_ * SizeOf(LongInt));
    fs^.pl := 0;
  end
  else fs^.pl := pl + 1;
  Data^ := out_;
end;

{ PREDICTOR1(x,k) = (long)((((uint64)x << k) - x) >> k): en uint64 y recién después a long }
function Predictor1(x: LongInt; k: Integer): LongInt; inline;
begin
  Result := LongInt(QWord((QWord(Int64(x)) shl k) - QWord(Int64(x))) shr k);
end;

{ filters_compress: los filtros se reinician en cada canal de cada bloque }
procedure FiltersCompress(Data: PLongInt; Len: LongWord; Level, ByteSize: Integer);
var
  f1, f2, f3: TFlt;
  p: PLongInt;
  i: LongWord;
  tmp, last: LongInt;
begin
  FilterInit(@f1, FLT_SET[0][Level - 1][ByteSize - 1][0], FLT_SET[0][Level - 1][ByteSize - 1][1],
             FLT_SET[0][Level - 1][ByteSize - 1][2]);
  FilterInit(@f2, FLT_SET[1][Level - 1][ByteSize - 1][0], FLT_SET[1][Level - 1][ByteSize - 1][1],
             FLT_SET[1][Level - 1][ByteSize - 1][2]);
  FilterInit(@f3, FLT_SET[2][Level - 1][ByteSize - 1][0], FLT_SET[2][Level - 1][ByteSize - 1][1],
             FLT_SET[2][Level - 1][ByteSize - 1][2]);
  last := 0;
  p := Data;
  if Len = 0 then Exit;
  for i := 0 to Len - 1 do
  begin
    { etapa 1: predicción fija de orden 1 }
    tmp := p^;
    case ByteSize of
      1: p^ := p^ - Predictor1(last, 4);
      2: p^ := p^ - Predictor1(last, 5);
      3: p^ := p^ - Predictor1(last, 5);
      4: p^ := p^ - last;
    end;
    last := tmp;
    { etapa 2: filtros adaptativos }
    if f1.order <> 0 then FilterCompress(@f1, p);
    if f2.order <> 0 then FilterCompress(@f2, p);
    if f3.order <> 0 then FilterCompress(@f3, p);
    Inc(p);
  end;
end;

{ --- TTtaEncStage ------------------------------------------------------------ }

constructor TTtaEncStage.Create(ATarget: TOutStage; const Params: TStringArray);
begin
  Create(ATarget, ParseTtaEncParams(Params));
end;

constructor TTtaEncStage.Create(ATarget: TOutStage; const APar: TTtaEncParams);
begin
  // Validar ANTES de inherited Create (si falla, Destroy ve FTarget=nil)
  if (APar.Level < 0) or (APar.NumChan < 0) or (APar.WordSize < 0) or (APar.Offset < 0) then
    raise ETtaEncParams.Create('tta: parámetros inválidos');
  if (APar.RawData < 0) or (APar.RawData > 1) then
    raise ETtaEncParams.Create('tta: raw_data > 1 no lo decodifica FreeArc');
  FPar := APar;
  inherited Create(ATarget);
end;

{ comienzo de tta_compress: decide el camino según los parámetros }
procedure TTtaEncStage.Start;
var
  hdr: array[0..3] of Byte;
begin
  FLevel := FPar.Level;
  if FLevel > 3 then FLevel := 3;               // level = mymin(level,3)
  FRaw := FPar.RawData;
  if FLevel = 0 then
  begin
    BeginStored;
    Exit;
  end;
  if (FPar.IsFloat <> 0) or (FPar.NumChan <> 0) or (FPar.WordSize <> 0) then
  begin
    { formato del usuario: num_chan||(num_chan=1); word_size||(word_size=is_float?4:1) }
    FIsFloat := FPar.IsFloat;
    FNumChan := FPar.NumChan;
    if FNumChan = 0 then FNumChan := 1;
    FWordSize := FPar.WordSize;
    if FWordSize = 0 then
      if FIsFloat <> 0 then FWordSize := 4 else FWordSize := 1;
    FByteSize := (FWordSize + 7) div 8;
    if ((FIsFloat <> 0) and (FByteSize <> 4)) or ((FIsFloat = 0) and (FByteSize >= 4)) or
       (FNumChan > 255) or (FWordSize > 255) then
    begin
      BeginStored;
      Exit;
    end;
    { el C escribe la cabecera, lee el encabezado (offset bytes) y lo copia tal cual }
    FN := FNumChan * FByteSize;
    hdr[0] := Byte(FLevel);
    hdr[1] := Byte(FRaw * 2 + FIsFloat);
    hdr[2] := Byte(FNumChan);
    hdr[3] := Byte(FWordSize);
    Emit(@hdr[0], 4);
    EmitU32(LongWord(FPar.Offset));
    FHdrLeft := FPar.Offset;
    FPhase := tpHeader;
    if FHdrLeft = 0 then BeginCoded(-1, nil);
    Exit;
  end;
  { autodetección: primero juntar 1mb }
  SetLength(FPrev, DETECT_SIZE);
  FPrevLen := 0;
  FPhase := tpDetect;
end;

procedure TTtaEncStage.BeginStored;
begin
  EmitU32(0);                                   // WRITE4(0): datos guardados
  FPhase := tpStored;
end;

{ Arranca los bloques.  Offset >= 0: emitir antes la cabecera + encabezado (autodetección) }
procedure TTtaEncStage.BeginCoded(Offset: Integer; Hdr: PByte);
var
  h: array[0..3] of Byte;
begin
  if Offset >= 0 then
  begin
    h[0] := Byte(FLevel);
    h[1] := Byte(FRaw * 2 + FIsFloat);
    h[2] := Byte(FNumChan);
    h[3] := Byte(FWordSize);
    Emit(@h[0], 4);
    EmitU32(LongWord(Offset));
    Emit(Hdr, Offset);
  end;
  FN := FNumChan * FByteSize;
  FWanted := SizeInt(FRAME_SIZE) * FN;
  SetLength(FBlk, FWanted);
  FBlkLen := 0;
  SetLength(FChan, FNumChan shl FIsFloat, FRAME_SIZE);
  FBitsSize := LongWord(FN * (FRAME_SIZE + 100));
  { +2 palabras de margen: put_* escribe hasta pos+1 y el control es (pos<<2)+8 > size }
  SetLength(FBits, FBitsSize div 4 + 4);
  FillChar(FBits[0], Length(FBits) * 4, 0);
  FMaxWord := 0;
  FPhase := tpBlocks;
end;

{ Detección sobre el primer mb (o todo, si es menos) }
procedure TTtaEncStage.Decide;
var
  isF, nc, ws, off: Integer;
  ok: Boolean;
begin
  ok := (FPar.SkipHeader = 0) and MmDetectWavHeader(@FPrev[0], FPrevLen, isF, nc, ws, off);
  if not ok then
    ok := MmDetectByEntropy(@FPrev[0], FPrevLen, TTA_CHANNELS, TTA_BITVALUES, 0.50, isF, nc, ws, off);
  if ok then
  begin
    FIsFloat := isF;
    FNumChan := nc;
    FWordSize := ws;
    FByteSize := (ws + 7) div 8;
    { TTA no soporta enteros de 32+ bits ni float que no sea de 32; y (desvío) >255
      canales o word_size 0 tampoco }
    if ((isF <> 0) and (FByteSize <> 4)) or ((isF = 0) and (FByteSize >= 4)) or
       (nc > 255) or (FByteSize = 0) or (off > FPrevLen) then ok := False;
  end;
  if not ok then
  begin
    BeginStored;
    Emit(@FPrev[0], FPrevLen);
  end
  else
  begin
    BeginCoded(off, @FPrev[0]);
    FeedBlocks(@FPrev[off], FPrevLen - off);
  end;
  FPrev := nil;
  FPrevLen := 0;
end;

procedure TTtaEncStage.FeedBlocks(Buf: PByte; Count: SizeInt);
var
  n: SizeInt;
begin
  while Count > 0 do
  begin
    n := FWanted - FBlkLen;
    if n > Count then n := Count;
    Move(Buf^, FBlk[FBlkLen], n);
    Inc(FBlkLen, n); Inc(Buf, n); Dec(Count, n);
    if FBlkLen = FWanted then EncodeBlock;
  end;
end;

procedure TTtaEncStage.DoWrite(Buf: PByte; Count: SizeInt);
var
  n: SizeInt;
begin
  if FPhase = tpNone then Start;
  while Count > 0 do
    case FPhase of
      tpStored:
        begin
          Emit(Buf, Count);
          Exit;
        end;
      tpDetect:
        begin
          n := DETECT_SIZE - FPrevLen;
          if n > Count then n := Count;
          Move(Buf^, FPrev[FPrevLen], n);
          Inc(FPrevLen, n); Inc(Buf, n); Dec(Count, n);
          if FPrevLen = DETECT_SIZE then Decide;
        end;
      tpHeader:
        begin
          n := FHdrLeft;
          if n > Count then n := Count;
          Emit(Buf, n);
          Dec(FHdrLeft, n); Inc(Buf, n); Dec(Count, n);
          if FHdrLeft = 0 then BeginCoded(-1, nil);
        end;
      tpBlocks:
        begin
          FeedBlocks(Buf, Count);
          Exit;
        end;
    end;
end;

procedure TTtaEncStage.DoFinish;
begin
  if FPhase = tpNone then Start;
  case FPhase of
    tpDetect:
      if FPrevLen > 0 then Decide;              // entrada vacía: el C no escribe nada
    tpHeader:
      raise ETtaEncError.Create('tta: la entrada es más corta que el offset');
  end;
  if (FPhase = tpBlocks) and (FBlkLen > 0) then EncodeBlock;
  FBlk := nil;
  FChan := nil;
  FBits := nil;
end;

{ --- bit array (entropy.cpp) ---------------------------------------------------- }

{ put_binary.  Si no entra, bit_array_write_bits = UINT_MAX (el bloque irá guardado). }
procedure TTtaEncStage.PutBinary(Value, Bits: LongWord);
var
  fbit, rbit, pos: LongWord;
begin
  fbit := FBitPos and $1F;
  rbit := 32 - fbit;
  pos := FBitPos shr 5;
  if (pos shl 2) + 8 > FBitsSize then
  begin
    FBitPos := $FFFFFFFF;
    Exit;
  end;
  FBits[pos] := (FBits[pos] and BIT_MASK32[fbit]) or ((Value and BIT_MASK32[Bits]) shl fbit);
  if Bits > rbit then
  begin
    FBits[pos + 1] := Value shr rbit;
    if SizeInt(pos) + 1 > FMaxWord then FMaxWord := pos + 1;
  end
  else if SizeInt(pos) > FMaxWord then FMaxWord := pos;
  Inc(FBitPos, Bits);
end;

{ put_unary: Value unos y un cero.  El C no escribe la palabra del cero cuando los unos
  terminan justo en un borde de palabra: queda la memoria de BigAlloc, que es cero. }
procedure TTtaEncStage.PutUnary(Value: LongWord);
var
  fbit, rbit, pos, unary: LongWord;
begin
  fbit := FBitPos and $1F;
  rbit := 32 - fbit;
  pos := FBitPos shr 5;
  if (pos shl 2) + 8 + Value div 8 > FBitsSize then
  begin
    FBitPos := $FFFFFFFF;
    Exit;
  end;
  FBits[pos] := FBits[pos] and BIT_MASK32[fbit];
  if Value < rbit then
    FBits[pos] := FBits[pos] or (BIT_MASK32[Value] shl fbit)
  else
  begin
    FBits[pos] := FBits[pos] or (BIT_MASK32[rbit] shl fbit);
    Inc(pos);
    unary := Value - rbit;
    while unary > 32 do
    begin
      FBits[pos] := $FFFFFFFF;
      Inc(pos);
      Dec(unary, 32);
    end;
    if unary <> 0 then FBits[pos] := BIT_MASK32[unary];
  end;
  if SizeInt(pos) > FMaxWord then FMaxWord := pos;
  Inc(FBitPos, Value + 1);
end;

{ encode_frame: Rice adaptativo con dos niveles (k0 / k1) }
procedure TTtaEncStage.EncodeFrame(Data: PLongInt; Len: LongWord);
var
  p: PLongInt;
  i, value, unary, k, k0, k1, sum0, sum1: LongWord;
  x: LongInt;
begin
  k0 := 10; k1 := 10;
  sum0 := SHIFT16[k0];
  sum1 := SHIFT16[k1];
  p := Data;
  if Len = 0 then Exit;
  for i := 0 to Len - 1 do
  begin
    { ENC(x) = x>0 ? (x<<1)-1 : (-x)<<1, en 32 bits }
    x := p^;
    if x > 0 then value := (LongWord(x) shl 1) - 1
    else value := (LongWord(0) - LongWord(x)) shl 1;
    k := k0;
    sum0 := sum0 + value - (sum0 shr 4);
    if (k0 > 0) and (sum0 < SHIFT16[k0]) then Dec(k0)
    else if sum0 > SHIFT16[k0 + 1] then Inc(k0);
    if value >= BIT_SHIFT[k] then
    begin
      value := value - BIT_SHIFT[k];
      k := k1;
      sum1 := sum1 + value - (sum1 shr 4);
      if (k1 > 0) and (sum1 < SHIFT16[k1]) then Dec(k1)
      else if sum1 > SHIFT16[k1 + 1] then Inc(k1);
      unary := 1 + (value shr (k and 31));      // x86: la cuenta del shift va mod 32
    end
    else
      unary := 0;
    if unary >= 50 then
    begin
      PutUnary(50);
      PutBinary(unary, 32);
    end
    else
      PutUnary(unary);
    if k <> 0 then PutBinary(value and BIT_MASK32[k], k);
    if k0 > 58 then k0 := 58;                   // solo con datos patológicos (el C lee fuera)
    if k1 > 58 then k1 := 58;
    Inc(p);
  end;
end;

{ Swap16 de ttaenc.h: invierte el ORDEN DE LOS BITS de 16 bits (no los bytes) }
function BitRev16(x: LongWord): LongWord; inline;
var
  i: Integer;
begin
  Result := 0;
  for i := 0 to 15 do
    if (x and (LongWord(1) shl i)) <> 0 then Result := Result or (LongWord(1) shl (15 - i));
end;

{ Un bloque: read_wave (a enteros) + split_int/split_float + filtros + Rice }
procedure TTtaEncStage.EncodeBlock;
var
  bytes_read, frame_len, rest, bsize: LongWord;
  i, j, nc, nch: Integer;
  b: PByte;
  t, neg, v: LongWord;
  s: LongInt;
  fl: SizeInt;
begin
  bytes_read := LongWord(FBlkLen);
  frame_len := bytes_read div LongWord(FN);
  rest := bytes_read mod LongWord(FN);
  nc := FNumChan;
  fl := frame_len;
  EmitU32(bytes_read);                          // WRITE4(bytes_read)
  b := @FBlk[0];
  { read_wave + split }
  for i := 0 to fl - 1 do
    for j := 0 to nc - 1 do
    begin
      case FByteSize of
        1: s := LongInt(b[0]) - $80;
        2: s := LongInt(SmallInt(Word(b[0]) or (Word(b[1]) shl 8)));
        3: s := SarLongint(LongInt((LongWord(b[0]) or (LongWord(b[1]) shl 8) or
                                    (LongWord(b[2]) shl 16)) shl 8), 8);
      else
        s := LongInt(LongWord(b[0]) or (LongWord(b[1]) shl 8) or (LongWord(b[2]) shl 16) or
                     (LongWord(b[3]) shl 24));
      end;
      Inc(b, FByteSize);
      if FIsFloat <> 0 then
      begin
        { split_float }
        t := LongWord(s);
        if (t and $80000000) <> 0 then neg := $FFFFFFFF else neg := 1;
        FChan[j][i] := LongInt(((t and $7FFF0000) shr 16) - $3F80);
        FChan[j + nc][i] := LongInt((BitRev16(t and $FFFF) + 1) * neg);
      end
      else
        FChan[j][i] := s;
    end;
  if (FIsFloat = 0) and (nc > 1) then
    { split_int: diferencias entre canales }
    for i := 0 to fl - 1 do
    begin
      for j := 0 to nc - 2 do FChan[j][i] := FChan[j + 1][i] - FChan[j][i];
      FChan[nc - 1][i] := FChan[nc - 1][i] - (FChan[nc - 2][i] div 2);
    end;

  { init_bit_array_write: el buffer ya está en cero }
  FBitPos := 0;
  nch := nc shl FIsFloat;
  for i := 0 to nch - 1 do
  begin
    if fl > 0 then FiltersCompress(@FChan[i][0], frame_len, FLevel, FByteSize);
    if FRaw = 0 then
    begin
      if fl > 0 then EncodeFrame(@FChan[i][0], frame_len);
    end
    else
    begin
      { raw_data 1: las muestras filtradas, 4 bytes (long de 32 bits) c/u }
      for j := 0 to fl - 1 do
      begin
        v := LongWord(FChan[i][j]);
        EmitU32(v);
      end;
    end;
  end;

  if FRaw = 0 then
  begin
    { get_len }
    bsize := (FBitPos shr 3) + LongWord(Ord((FBitPos and 7) <> 0));
    if bsize >= bytes_read then
    begin
      EmitU32(0);                               // no comprime: bloque original
      Emit(@FBlk[0], bytes_read);
      rest := 0;
    end
    else
    begin
      EmitU32(bsize);
      Emit(PByte(@FBits[0]), bsize);
    end;
  end;
  if rest > 0 then Emit(@FBlk[bytes_read - rest], rest);
  { dejar el bit array en cero para el próximo bloque (el C pide memoria nueva) }
  if FMaxWord + 1 > Length(FBits) then FMaxWord := Length(FBits) - 1;
  FillChar(FBits[0], (FMaxWord + 1) * 4, 0);
  FMaxWord := 0;
  FBlkLen := 0;
end;

initialization
  InitTables;
end.
