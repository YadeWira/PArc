{ MM — preprocesador multimedia de FreeArc (Compression/MM/mm.cpp).
  Filtro "diff" por canal, sin compresor propio: se usa como etapa previa de otro
  método (p.ej. `mm+grzip`), y el grupo $bmp de arc.groups lo invoca así.

  Stream:
    1 byte de flags:
      0        = datos guardados sin procesar (el resto del stream va tal cual)
      bit0     = 1 (diff); bits 1..7 deben ser 0 (reorder no soportado todavía)
    2 bytes  = num_chan, word_size(bits)
    4 bytes  = offset (Int32 LE): bytes del encabezado original que se copian intactos
    offset bytes (copia literal al destino)
    roundUp(3+4+offset, N) - (3+4+offset) bytes: relleno de alineación, que son los
      VALORES INICIALES del acumulador `base` de cada canal (el encoder los emite
      desde un base en cero, y el decoder los lee dentro de base y no los emite)
    después, chunks de a roundDown(BUFFER_SIZE, N) bytes con los datos "diffeados"

  N = num_chan * byte_size.  El decoder deshace el diff de a grupos de N bytes; el
  acumulador base persiste entre chunks (por eso el tamaño de chunk debe ser el
  mismo que usó el encoder).
  Aritmética: los elementos son de 8/16/24/32 bits y el diff se hace en 32 bits
  con wrapping (el encoder es de 32 bits). }
unit parc_mm;

{$mode objfpc}{$H+}
{$R-}{$Q-}

interface

uses
  SysUtils, parc_stream;

type
  TMmParams = record
    Mode, SkipHeader, IsFloat, NumChan, WordSize, Offset, Reorder: Integer;
  end;

  TMmStage = class(TInStage)
  private
    FPar: TMmParams;
    FBuf: array of Byte;
    FBase: array of Byte;
    FLen, FPos: SizeInt;
    FEof, FStarted, FStored: Boolean;
    FNumChan, FWordSize, FByteSize, FN, FChunk: Integer;
    procedure Start;
    function NextChunk: Boolean;
  public
    constructor Create(ASource: TInStage; const APar: TMmParams);
    function Read(Buf: PByte; Count: SizeInt): SizeInt; override;
  end;

{ Parámetros como parse_MM. }
function ParseMmParams(const Params: TStringArray): TMmParams;

implementation

uses
  parc_bytes, parc_methods;

const
  BUFFER_SIZE = 256 * 1024;

{ "c*w" o "c*wf" (canales*bits, la 'f' final marca punto flotante).
  Equivale a los dos sscanf de parse_MM. }
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

function ParseMmParams(const Params: TStringArray): TMmParams;
var
  k, a, b: Integer;
  p: string;
  isF: Boolean;
begin
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
    if p = '' then Continue;
    case p[1] of
      's': Result.SkipHeader := 1;
      'f': Result.IsFloat := 1;
      'd': Result.Mode := StrToIntDef(Copy(p, 2, MaxInt), Result.Mode);
      'c': Result.NumChan := StrToIntDef(Copy(p, 2, MaxInt), Result.NumChan);
      'w': Result.WordSize := StrToIntDef(Copy(p, 2, MaxInt), Result.WordSize);
      'o': Result.Offset := StrToIntDef(Copy(p, 2, MaxInt), Result.Offset);
      'r': Result.Reorder := StrToIntDef(Copy(p, 2, MaxInt), Result.Reorder);
    else
      { "c*w" o "c*wf" }
      if ParseChanWord(p, a, b, isF) then
      begin
        Result.NumChan := a;
        Result.WordSize := b;
        if isF then Result.IsFloat := 1;
      end
      else
        raise EUnsupportedMethod.Create('mm: parámetro inválido: ' + p);
    end;
  end;
end;

{ --- undiff de a N bytes, con acumulador por canal ---------------------- }

procedure Undiff1(Buf: PByte; BufSize, N: Integer; Base: PByte);
var
  p, e: PByte;
  i: Integer;
begin
  p := Buf;
  e := Buf + BufSize;
  while p + N <= e do
  begin
    for i := 0 to N - 1 do
    begin
      Base[i] := Base[i] + p[i];
      p[i] := Base[i];
    end;
    Inc(p, N);
  end;
end;

procedure Undiff2(Buf: PByte; BufSize, N: Integer; Base: PByte);
var
  p, e: PByte;
  i: Integer;
  v: LongWord;
begin
  p := Buf;
  e := Buf + BufSize;
  { N elementos de 2 bytes por grupo }
  while p + N * 2 <= e do
  begin
    for i := 0 to N - 1 do
    begin
      v := (LongWord(p[2 * i]) or (LongWord(p[2 * i + 1]) shl 8)) +
           (LongWord(Base[2 * i]) or (LongWord(Base[2 * i + 1]) shl 8));
      Base[2 * i] := v and $FF;
      Base[2 * i + 1] := (v shr 8) and $FF;
      p[2 * i] := Base[2 * i];
      p[2 * i + 1] := Base[2 * i + 1];
    end;
    Inc(p, N * 2);
  end;
end;

procedure Undiff3(Buf: PByte; BufSize, N: Integer; Base: PByte);
var
  p, e: PByte;
  i: Integer;
  v: LongWord;
begin
  p := Buf;
  e := Buf + BufSize;
  while p + N * 3 <= e do
  begin
    for i := 0 to N - 1 do
    begin
      v := LongWord(p[i * 3]) or (LongWord(p[i * 3 + 1]) shl 8) or (LongWord(p[i * 3 + 2]) shl 16);
      v := v + (LongWord(Base[i * 4]) or (LongWord(Base[i * 4 + 1]) shl 8) or
                (LongWord(Base[i * 4 + 2]) shl 16) or (LongWord(Base[i * 4 + 3]) shl 24));
      Base[i * 4] := v and $FF;
      Base[i * 4 + 1] := (v shr 8) and $FF;
      Base[i * 4 + 2] := (v shr 16) and $FF;
      Base[i * 4 + 3] := (v shr 24) and $FF;
      p[i * 3] := Base[i * 4];                     { setvalue24: mantiene el 4º byte }
      p[i * 3 + 1] := Base[i * 4 + 1];
      p[i * 3 + 2] := Base[i * 4 + 2];
    end;
    Inc(p, N * 3);
  end;
end;

procedure Undiff4(Buf: PByte; BufSize, N: Integer; Base: PByte);
var
  p, e: PByte;
  i: Integer;
  v: LongWord;
begin
  p := Buf;
  e := Buf + BufSize;
  { N elementos de 4 bytes por grupo }
  while p + N * 4 <= e do
  begin
    for i := 0 to N - 1 do
    begin
      v := (LongWord(p[4 * i]) or (LongWord(p[4 * i + 1]) shl 8) or
            (LongWord(p[4 * i + 2]) shl 16) or (LongWord(p[4 * i + 3]) shl 24)) +
           (LongWord(Base[4 * i]) or (LongWord(Base[4 * i + 1]) shl 8) or
            (LongWord(Base[4 * i + 2]) shl 16) or (LongWord(Base[4 * i + 3]) shl 24));
      Base[4 * i] := v and $FF;
      Base[4 * i + 1] := (v shr 8) and $FF;
      Base[4 * i + 2] := (v shr 16) and $FF;
      Base[4 * i + 3] := (v shr 24) and $FF;
      p[4 * i] := Base[4 * i];
      p[4 * i + 1] := Base[4 * i + 1];
      p[4 * i + 2] := Base[4 * i + 2];
      p[4 * i + 3] := Base[4 * i + 3];
    end;
    Inc(p, N * 4);
  end;
end;

{ --- TMmStage ----------------------------------------------------------- }

constructor TMmStage.Create(ASource: TInStage; const APar: TMmParams);
begin
  if (APar.Reorder <> 0) then
    raise EUnsupportedMethod.Create('mm: reorder todavía no soportado');
  if (APar.NumChan < 0) or (APar.WordSize < 0) then
    raise EUnsupportedMethod.Create('mm: parámetros inválidos');
  inherited Create(ASource);
  FPar := APar;
end;

function RoundDown(a, b: SizeInt): SizeInt; inline;
begin
  if b <= 0 then Exit(0);
  Result := (a div b) * b;
end;

function RoundUp(a, b: SizeInt): SizeInt; inline;
begin
  if b <= 0 then Exit(a);
  Result := ((a + b - 1) div b) * b;
end;

procedure TMmStage.Start;
var
  hdr: array[0..2] of Byte;
  b4: array[0..3] of Byte;
  offset: LongInt;
  align: SizeInt;
begin
  FStarted := True;
  if not Source.ReadExactOrEof(@hdr[0], 1) then
  begin
    FEof := True; FStored := True; FLen := 0;
    Exit;
  end;
  if hdr[0] = 0 then
  begin
    FStored := True;
    Exit;
  end;
  if (hdr[0] and not 1) <> 0 then
    Corrupt('mm: flags no soportados (reorder)');
  Source.ReadExact(@hdr[1], 2);
  FNumChan := hdr[1];
  FWordSize := hdr[2];
  if (FNumChan = 0) then Corrupt('mm: num_chan = 0');
  FByteSize := (FWordSize + 7) div 8;
  if (FByteSize < 1) or (FByteSize > 4) then Corrupt('mm: word_size inválido');
  FN := FNumChan * FByteSize;
  Source.ReadExact(@b4[0], 4);
  offset := LongInt(LongWord(b4[0]) or (LongWord(b4[1]) shl 8) or
                    (LongWord(b4[2]) shl 16) or (LongWord(b4[3]) shl 24));
  if offset < 0 then Corrupt('mm: offset inválido');
  { el encabezado original se copia tal cual }
  if offset > 0 then
  begin
    SetLength(FBuf, offset);
    Source.ReadExact(@FBuf[0], offset);
    FLen := offset;
    FPos := 0;
  end;
  { acumulador de cada canal: el encoder usa 4 bytes por canal para 24 bits }
  if FByteSize = 3 then SetLength(FBase, FNumChan * 4)
  else SetLength(FBase, FNumChan * FByteSize);
  FillChar(FBase[0], Length(FBase), 0);
  { relleno de alineación = valores iniciales de base (no se emiten) }
  align := RoundUp(3 + 4 + offset, FN) - (3 + 4 + offset);
  if align > 0 then
  begin
    if align > Length(FBase) then Corrupt('mm: alineación inválida');
    Source.ReadExact(@FBase[0], align);
  end;
  FChunk := RoundDown(BUFFER_SIZE, FN);
  { OJO: no limpiar FBuf acá — todavía contiene los `offset` bytes del encabezado
    original que hay que entregar (FLen quedó en offset). }
end;

function TMmStage.NextChunk: Boolean;
var
  n: SizeInt;
begin
  if FStored then
  begin
    SetLength(FBuf, BUFFER_SIZE);
    n := Source.Read(@FBuf[0], BUFFER_SIZE);
    FLen := n;
    FPos := 0;
    Exit(n > 0);
  end;
  if FChunk <= 0 then Exit(False);
  if Length(FBuf) < FChunk then SetLength(FBuf, FChunk);
  n := Source.Read(@FBuf[0], FChunk);
  FLen := n;
  FPos := 0;
  if n <= 0 then Exit(False);
  case FByteSize of
    1: Undiff1(@FBuf[0], n, FNumChan, @FBase[0]);
    2: Undiff2(@FBuf[0], n, FNumChan, @FBase[0]);
    3: Undiff3(@FBuf[0], n, FNumChan, @FBase[0]);
    4: Undiff4(@FBuf[0], n, FNumChan, @FBase[0]);
  else
    Corrupt('mm: byte_size inválido');
  end;
  Result := True;
end;

function TMmStage.Read(Buf: PByte; Count: SizeInt): SizeInt;
var
  n: SizeInt;
begin
  Result := 0;
  if not FStarted then Start;
  while Count > 0 do
  begin
    while FPos >= FLen do
    begin
      if FEof then Exit;
      if not NextChunk then
      begin
        FEof := True;
        Exit;
      end;
    end;
    n := FLen - FPos;
    if n > Count then n := Count;
    if (n < 0) or (FPos + n > Length(FBuf)) then
      raise Exception.CreateFmt('mm: inconsistencia FPos=%d FLen=%d len(FBuf)=%d n=%d chunk=%d',
        [FPos, FLen, Length(FBuf), n, FChunk]);
    Move(FBuf[FPos], Buf^, n);
    Inc(FPos, n); Inc(Buf, n); Dec(Count, n); Inc(Result, n);
  end;
end;

end.
