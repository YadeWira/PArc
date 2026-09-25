{ MM (codificador): preprocesador multimedia de FreeArc 0.67 (resta de muestras sucesivas
  por canal, sin compresor propio). Port de Compression/MM/mm.cpp (mm_compress, diff1..4)
  y C_MM.cpp (parse_MM); detección en parc_mmdet (mmdet.cpp).
  Decodificador: parc_mm (TMmStage), que documenta el formato.

  Salida idéntica byte a byte a mm_compress del build de 32 bits con lecturas completas:
    - lee 1mb; sin c/w/f detecta: WAV (salvo :s) y si no entropía sobre check_bytes
      centrales (d<=2: 64kb, 1-3 canales de 8-16 bits; si no max(64kb,bytes/2), 1-4 canales
      de 8-32 bits; umbral 0.80).  Si falla: byte 0 + datos tal cual.
    - si no: [1+reorder*2][num_chan][word_size] U32 offset, offset bytes, relleno en cero
      hasta múltiplo de N desde el comienzo del stream, y los datos desde offset con la
      resta de muestras (las muestras incompletas del final salen sin tocar).
  Como la resta es continua y los bloques del C son múltiplos de N, la salida no depende
  del tamaño de los bloques: acá se procesa lo que llega (memoria: 1mb de detección).

  Desvíos deliberados del C (su salida no se puede decodificar o pierde datos):
    - reorder != 0: error de parámetros (el decodificador de FreeArc rechaza esos flags).
    - num_chan o word_size > 255 (el C trunca el byte de cabecera): se guarda (byte 0).
    - N = 0 con offset > 0 (WAV con BitsPerSample = 0): el C guarda los datos SIN los
      primeros offset bytes; acá se guardan completos. }
unit parc_mmenc;

{$mode objfpc}{$H+}
{$R-}{$Q-}

interface

uses
  SysUtils, parc_outstream;

type
  EMmEncParams = class(Exception);

  TMmEncParams = record
    Mode, SkipHeader, IsFloat, NumChan, WordSize, Offset, Reorder: Integer;
  end;

  TMmEncPhase = (mpNone, mpDetect, mpStored, mpDiff);

  TMmEncStage = class(TOutStage)
  private
    FPar: TMmEncParams;
    FPhase: TMmEncPhase;
    FPrev: array of Byte;           // primer mb
    FPrevLen: SizeInt;
    FNumChan, FByteSize, FN: Integer;
    FBaseW: array of LongWord;      // valor previo de cada canal
    FPart: array of Byte;           // muestra incompleta pendiente (< N bytes)
    FPartLen: SizeInt;
    FTmp: array of Byte;            // salida procesada
    procedure Start;
    procedure Decide;
    procedure DiffData(Buf: PByte; Count: SizeInt);
    procedure DiffSamples(Src: PByte; NSamples: SizeInt);
  protected
    procedure DoWrite(Buf: PByte; Count: SizeInt); override;
    procedure DoFinish; override;
  public
    { Params = partes del método separadas por ':' con Params[0] = 'mm' }
    constructor Create(ATarget: TOutStage; const Params: TStringArray);
    constructor Create(ATarget: TOutStage; const APar: TMmEncParams);
  end;

{ parse_MM }
function ParseMmEncParams(const Params: TStringArray): TMmEncParams;

implementation

uses
  parc_mmdet;

const
  BUFSIZE = 1 shl 20;               // primer bloque (detección)
  TMP_SIZE = 256 * 1024;

  { canales / bits de mmdet.cpp }
  MM_CHANNELS: array[0..3] of Integer = (1, 2, 3, 4);
  MM_BITVALUES: array[0..3] of Integer = (8, 16, 24, 32);
  FAST_CHANNELS: array[0..1] of Integer = (1, 3);
  FAST_BITVALUES: array[0..1] of Integer = (8, 16);

function ParseMmEncParams(const Params: TStringArray): TMmEncParams;
var
  k, a, b: Integer;
  p: string;
  isF, ok: Boolean;
begin
  if (Length(Params) = 0) or (Params[0] <> 'mm') then
    raise EMmEncParams.Create('mm: no es el método mm');
  // MM_METHOD::MM_METHOD
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
    if (p <> '') and (p[1] in ['s', 'f', 'd', 'c', 'w', 'o', 'r']) then
    begin
      case p[1] of
        's': begin Result.SkipHeader := 1; ok := True; end;
        'f': begin Result.IsFloat := 1; ok := True; end;
        'd': ok := FaParseInt(Copy(p, 2, MaxInt), Result.Mode);
        'c': ok := FaParseInt(Copy(p, 2, MaxInt), Result.NumChan);
        'w': ok := FaParseInt(Copy(p, 2, MaxInt), Result.WordSize);
        'o': ok := FaParseInt(Copy(p, 2, MaxInt), Result.Offset);
      else
        ok := FaParseInt(Copy(p, 2, MaxInt), Result.Reorder);
      end;
      if not ok then raise EMmEncParams.CreateFmt('mm: parámetro inválido "%s"', [p]);
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
      raise EMmEncParams.CreateFmt('mm: parámetro inválido "%s"', [p]);
  end;
end;

function RoundDown(a, b: SizeInt): SizeInt; inline;
begin
  if b > 1 then Result := (a div b) * b else Result := a;
end;

function RoundUp(a, b: SizeInt): SizeInt; inline;
begin
  if (a <> 0) and (b > 1) then Result := RoundDown(a - 1, b) + b else Result := a;
end;

{ TMmEncStage }

constructor TMmEncStage.Create(ATarget: TOutStage; const Params: TStringArray);
begin
  Create(ATarget, ParseMmEncParams(Params));
end;

constructor TMmEncStage.Create(ATarget: TOutStage; const APar: TMmEncParams);
begin
  // Validar ANTES de inherited Create (si falla, Destroy ve FTarget=nil)
  if APar.Reorder <> 0 then
    raise EMmEncParams.Create('mm: reorder no lo decodifica FreeArc');
  if (APar.NumChan < 0) or (APar.WordSize < 0) or (APar.Offset < 0) then
    raise EMmEncParams.Create('mm: parámetros inválidos');
  FPar := APar;
  inherited Create(ATarget);
end;

procedure TMmEncStage.Start;
begin
  SetLength(FPrev, BUFSIZE);
  FPrevLen := 0;
  FPhase := mpDetect;
end;

{ mm_compress, desde la detección hasta el primer bloque }
procedure TMmEncStage.Decide;
var
  bytes, check_bytes, offset, ws, isF, nc, pad: SizeInt;
  detF, detN, detW, detO: Integer;
  hdr: array[0..2] of Byte;
  zero: array of Byte;
  ok: Boolean;
begin
  bytes := FPrevLen;
  if FPar.Mode <= 2 then check_bytes := 64 * 1024
  else
  begin
    check_bytes := bytes div 2;
    if check_bytes < 64 * 1024 then check_bytes := 64 * 1024;
  end;
  if check_bytes > bytes then check_bytes := bytes;

  isF := FPar.IsFloat; nc := FPar.NumChan; ws := FPar.WordSize; offset := FPar.Offset;
  if (isF <> 0) or (nc <> 0) or (ws <> 0) then
  begin
    if nc = 0 then nc := 1;
    if ws = 0 then
      if isF <> 0 then ws := 32 else ws := 8;
  end
  else
  begin
    ok := (FPar.SkipHeader = 0) and MmDetectWavHeader(@FPrev[0], bytes, detF, detN, detW, detO);
    if not ok then
      if FPar.Mode <= 2 then
        ok := MmDetectByEntropy(@FPrev[(bytes - check_bytes) div 2], check_bytes,
                FAST_CHANNELS, FAST_BITVALUES, 0.80, detF, detN, detW, detO)
      else
        ok := MmDetectByEntropy(@FPrev[(bytes - check_bytes) div 2], check_bytes,
                MM_CHANNELS, MM_BITVALUES, 0.80, detF, detN, detW, detO);
    if ok then
    begin
      isF := detF; nc := detN; ws := detW; offset := detO;
    end
    else
    begin
      isF := 0; nc := 0; ws := 0; offset := 0;
    end;
  end;
  if offset > bytes then offset := bytes;
  FByteSize := (ws + 7) div 8;
  FNumChan := nc;
  FN := nc * FByteSize;
  if (nc > 255) or (ws > 255) then FN := 0;       // desvío: la cabecera no lo representa

  if FN = 0 then
  begin
    { guardado: un byte 0 y los datos (desvío: sin descartar un offset de WAV) }
    hdr[0] := 0;
    Emit(@hdr[0], 1);
    Emit(@FPrev[0], bytes);
    FPhase := mpStored;
  end
  else
  begin
    hdr[0] := 1;                                  // 1 + reorder*2
    hdr[1] := Byte(nc);
    hdr[2] := Byte(ws);
    Emit(@hdr[0], 3);
    EmitU32(LongWord(offset));
    Emit(@FPrev[0], offset);
    { relleno hasta múltiplo de N: bytes de base, que está en cero }
    pad := RoundUp(3 + 4 + offset, FN) - (3 + 4 + offset);
    if pad > 0 then
    begin
      SetLength(zero, pad);
      FillChar(zero[0], pad, 0);
      Emit(@zero[0], pad);
    end;
    SetLength(FBaseW, nc);
    if nc > 0 then FillChar(FBaseW[0], nc * SizeOf(LongWord), 0);
    SetLength(FPart, FN);
    FPartLen := 0;
    SetLength(FTmp, RoundDown(TMP_SIZE, FN) + FN);
    FPhase := mpDiff;
    DiffData(@FPrev[offset], bytes - offset);
  end;
  FPrev := nil;
  FPrevLen := 0;
end;

{ diff1..diff4 sobre NSamples muestras completas (N bytes c/u) de Src, a FTmp }
procedure TMmEncStage.DiffSamples(Src: PByte; NSamples: SizeInt);
var
  s, i, nc: SizeInt;
  p, d: PByte;
  x: LongWord;
begin
  nc := FNumChan;
  p := Src;
  d := @FTmp[0];
  case FByteSize of
    1:
      for s := 0 to NSamples - 1 do
      begin
        for i := 0 to nc - 1 do
        begin
          x := p[i];
          d[i] := Byte(x - FBaseW[i]);
          FBaseW[i] := x;
        end;
        Inc(p, nc); Inc(d, nc);
      end;
    2:
      for s := 0 to NSamples - 1 do
      begin
        for i := 0 to nc - 1 do
        begin
          x := LongWord(p[2 * i]) or (LongWord(p[2 * i + 1]) shl 8);
          PWord(d + 2 * i)^ := NtoLE(Word(x - FBaseW[i]));
          FBaseW[i] := x;
        end;
        Inc(p, 2 * nc); Inc(d, 2 * nc);
      end;
    3:  // value24/setvalue24: 24 bits, base de 32
      for s := 0 to NSamples - 1 do
      begin
        for i := 0 to nc - 1 do
        begin
          x := LongWord(p[3 * i]) or (LongWord(p[3 * i + 1]) shl 8) or (LongWord(p[3 * i + 2]) shl 16);
          d[3 * i] := Byte(x - FBaseW[i]);
          d[3 * i + 1] := Byte((x - FBaseW[i]) shr 8);
          d[3 * i + 2] := Byte((x - FBaseW[i]) shr 16);
          FBaseW[i] := x;
        end;
        Inc(p, 3 * nc); Inc(d, 3 * nc);
      end;
    4:
      for s := 0 to NSamples - 1 do
      begin
        for i := 0 to nc - 1 do
        begin
          x := LongWord(p[4 * i]) or (LongWord(p[4 * i + 1]) shl 8) or
               (LongWord(p[4 * i + 2]) shl 16) or (LongWord(p[4 * i + 3]) shl 24);
          PLongWord(d + 4 * i)^ := NtoLE(LongWord(x - FBaseW[i]));
          FBaseW[i] := x;
        end;
        Inc(p, 4 * nc); Inc(d, 4 * nc);
      end;
  else
    Move(Src^, FTmp[0], NSamples * FN);         // byte_size > 4: el C no resta nada
  end;
  Emit(@FTmp[0], NSamples * FN);
end;

{ Procesa las muestras completas; guarda la incompleta del final para el próximo Write }
procedure TMmEncStage.DiffData(Buf: PByte; Count: SizeInt);
var
  n, maxs: SizeInt;
begin
  if FPartLen > 0 then
  begin
    n := FN - FPartLen;
    if n > Count then n := Count;
    Move(Buf^, FPart[FPartLen], n);
    Inc(FPartLen, n); Inc(Buf, n); Dec(Count, n);
    if FPartLen < FN then Exit;
    DiffSamples(@FPart[0], 1);
    FPartLen := 0;
  end;
  maxs := (Length(FTmp) - FN) div FN;
  while Count >= FN do
  begin
    n := Count div FN;
    if n > maxs then n := maxs;
    DiffSamples(Buf, n);
    Inc(Buf, n * FN); Dec(Count, n * FN);
  end;
  if Count > 0 then
  begin
    Move(Buf^, FPart[0], Count);
    FPartLen := Count;
  end;
end;

procedure TMmEncStage.DoWrite(Buf: PByte; Count: SizeInt);
var
  n: SizeInt;
begin
  if FPhase = mpNone then Start;
  while Count > 0 do
    case FPhase of
      mpDetect:
        begin
          n := BUFSIZE - FPrevLen;
          if n > Count then n := Count;
          Move(Buf^, FPrev[FPrevLen], n);
          Inc(FPrevLen, n); Inc(Buf, n); Dec(Count, n);
          if FPrevLen = BUFSIZE then Decide;
        end;
      mpStored:
        begin
          Emit(Buf, Count);
          Exit;
        end;
      mpDiff:
        begin
          DiffData(Buf, Count);
          Exit;
        end;
    end;
end;

procedure TMmEncStage.DoFinish;
begin
  if FPhase = mpNone then Start;
  { entrada vacía: el C no escribe nada }
  if (FPhase = mpDetect) and (FPrevLen > 0) then Decide;
  { muestra incompleta final: sale sin restar }
  if (FPhase = mpDiff) and (FPartLen > 0) then Emit(@FPart[0], FPartLen);
  FPartLen := 0;
  FPrev := nil;
  FTmp := nil;
end;

end.
