{ Decodificador LZMA1 "raw" (FORMATO-ARC.md §7.1), reanudable y con diccionario circular.
  - Bloques de control: memoria-a-memoria, tamaño de salida conocido, sin marca de fin obligatoria.
  - Bloques de datos: streaming (TLzmaStage); el stream termina con marca de fin, como en
    lzma_decompress2 de FreeArc (C_LZMA.cpp), y el diccionario circular mide dictSize.
  Algoritmo según la especificación de referencia de Igor Pavlov (LzmaSpec, dominio público). }
unit parc_lzma;

{$mode objfpc}{$H+}
{$R-}{$Q-}

interface

uses
  SysUtils, parc_stream;

type
  TLzmaResult = (lzOk, lzBadProps, lzDataError, lzInputEof);

  TLzmaStatus = (lsLimit, lsEndMark, lsError, lsInputEof);

const
  kNumPosBitsMax = 4;
  kNumStates = 12;
  kNumLenToPosStates = 4;
  kNumAlignBits = 4;
  kEndPosModelIndex = 14;
  kNumFullDistances = 1 shl (kEndPosModelIndex shr 1);
  IN_BUF_SIZE = 1 shl 16;

type
  TProb = Word;
  PProb = ^TProb;

  TLenDecoder = record
    Choice, Choice2: TProb;
    Low: array[0..(1 shl kNumPosBitsMax) - 1, 0..7] of TProb;
    Mid: array[0..(1 shl kNumPosBitsMax) - 1, 0..7] of TProb;
    High: array[0..255] of TProb;
  end;

  TLzmaDecoder = class
  private
    // Range decoder con entrada "pull" desde FIn
    FIn: TInStage;
    FInBuf: array[0..IN_BUF_SIZE - 1] of Byte;
    FInPos, FInLen: SizeInt;
    FOverrun: Boolean;
    Range, Code: LongWord;
    // Modelo
    lc, lp, pb: Integer;
    Literals: array of TProb;
    IsMatch: array[0..(kNumStates shl kNumPosBitsMax) - 1] of TProb;
    IsRep, IsRepG0, IsRepG1, IsRepG2: array[0..kNumStates - 1] of TProb;
    IsRep0Long: array[0..(kNumStates shl kNumPosBitsMax) - 1] of TProb;
    PosSlot: array[0..kNumLenToPosStates - 1, 0..63] of TProb;
    PosDecoders: array[0..1 + kNumFullDistances - kEndPosModelIndex - 1] of TProb;
    Align: array[0..(1 shl kNumAlignBits) - 1] of TProb;
    LenDec, RepLenDec: TLenDecoder;
    State, Rep0, Rep1, Rep2, Rep3: LongWord;
    RemainLen: LongWord;       // bytes pendientes de un match cortado por el límite
    FInitialized, FFinished: Boolean;
    function RefillByte: Byte;
    function NextByte: Byte; inline;
    procedure Normalize; inline;
    function Bit(var Prob: TProb): LongWord; inline;
    function DirectBits(NumBits: Integer): LongWord;
    function BitTree(Probs: PProb; NumBits: Integer): LongWord;
    function BitTreeReverse(Probs: PProb; NumBits: Integer): LongWord;
    function LenDecode(var d: TLenDecoder; PosState: LongWord): LongWord;
    function DecodeDistance(Len: LongWord): LongWord;
    procedure CopyMatch(Limit: SizeInt);
  public
    Dict: PByte;
    DictSize: SizeInt;
    DicPos: SizeInt;           // posición de escritura en Dict
    TotalPos: QWord;           // bytes producidos desde el inicio
    constructor Create(Alc, Alp, Apb: Integer; ADict: PByte; ADictSize: SizeInt; AIn: TInStage);
    { Decodifica hasta que DicPos = Limit (Limit <= DictSize), marca de fin, error o fin de entrada. }
    function DecodeTo(Limit: SizeInt): TLzmaStatus;
    property Finished: Boolean read FFinished;
    property InputOverrun: Boolean read FOverrun;
  end;

  { Etapa de streaming para bloques de datos. Es dueña de su fuente. }
  TLzmaStage = class(TInStage)
  private
    FDec: TLzmaDecoder;
    FDictBuf: array of Byte;
    FReadPos: SizeInt;
    FEnded: Boolean;
  public
    constructor Create(ASource: TInStage; Alc, Alp, Apb: Integer; ADictSize: QWord);
    destructor Destroy; override;
    function Read(Buf: PByte; Count: SizeInt): SizeInt; override;
  end;

function ValidLzmaProps(lc, lp, pb: Integer): Boolean;

{ Memoria-a-memoria (bloques de control). No exige marca de fin. }
function LzmaDecodeRaw(Src: PByte; SrcLen: SizeInt; Dst: PByte; DstLen: SizeInt;
  lc, lp, pb: Integer; out DstWritten: SizeInt): TLzmaResult;

implementation

uses
  parc_bytes;

const
  kNumBitModelTotalBits = 11;
  kBitModelTotal = 1 shl kNumBitModelTotalBits;
  kNumMoveBits = 5;
  kTopValue = LongWord(1) shl 24;
  kMatchMinLen = 2;

function ValidLzmaProps(lc, lp, pb: Integer): Boolean;
begin
  Result := (lc >= 0) and (lc <= 8) and (lp >= 0) and (lp <= 4) and (pb >= 0) and (pb <= kNumPosBitsMax);
end;

procedure InitProbs(p: PProb; Count: SizeInt);
begin
  while Count > 0 do
  begin
    p^ := kBitModelTotal shr 1;
    Inc(p);
    Dec(Count);
  end;
end;

{ TLzmaDecoder }

constructor TLzmaDecoder.Create(Alc, Alp, Apb: Integer; ADict: PByte; ADictSize: SizeInt; AIn: TInStage);
begin
  inherited Create;
  lc := Alc; lp := Alp; pb := Apb;
  Dict := ADict;
  DictSize := ADictSize;
  FIn := AIn;
  SetLength(Literals, SizeInt($300) shl (lc + lp));
  InitProbs(@Literals[0], Length(Literals));
  InitProbs(@IsMatch, Length(IsMatch));
  InitProbs(@IsRep, kNumStates);
  InitProbs(@IsRepG0, kNumStates);
  InitProbs(@IsRepG1, kNumStates);
  InitProbs(@IsRepG2, kNumStates);
  InitProbs(@IsRep0Long, Length(IsRep0Long));
  InitProbs(@PosSlot, SizeOf(PosSlot) div SizeOf(TProb));
  InitProbs(@PosDecoders, Length(PosDecoders));
  InitProbs(@Align, Length(Align));
  InitProbs(@LenDec, SizeOf(LenDec) div SizeOf(TProb));
  InitProbs(@RepLenDec, SizeOf(RepLenDec) div SizeOf(TProb));
end;

{ Camino lento de NextByte: recargar el buffer de entrada desde la fuente. Separado para que
  NextByte (el camino rápido) sí se pueda expandir en línea. }
function TLzmaDecoder.RefillByte: Byte;
begin
  FInLen := FIn.Read(@FInBuf[0], IN_BUF_SIZE);
  FInPos := 0;
  if FInLen <= 0 then
  begin
    // Más allá del final: marcamos el error y devolvemos 0 para no cortar el flujo
    FInLen := 0;
    FOverrun := True;
    Exit(0);
  end;
  Result := FInBuf[0];
  FInPos := 1;
end;

function TLzmaDecoder.NextByte: Byte;
begin
  if FInPos < FInLen then
  begin
    Result := FInBuf[FInPos];
    Inc(FInPos);
  end
  else
    Result := RefillByte;
end;

procedure TLzmaDecoder.Normalize;
begin
  if Range < kTopValue then
  begin
    Range := Range shl 8;
    // NextByte escrito a mano: FPC no lo expande en línea y este es el camino más caliente
    if FInPos < FInLen then
    begin
      Code := (Code shl 8) or FInBuf[FInPos];
      Inc(FInPos);
    end
    else
      Code := (Code shl 8) or RefillByte;
  end;
end;

function TLzmaDecoder.Bit(var Prob: TProb): LongWord;
var
  Bound: LongWord;
begin
  Bound := (Range shr kNumBitModelTotalBits) * Prob;
  if Code < Bound then
  begin
    Prob := Prob + ((kBitModelTotal - Prob) shr kNumMoveBits);
    Range := Bound;
    Result := 0;
  end
  else
  begin
    Prob := Prob - (Prob shr kNumMoveBits);
    Code := Code - Bound;
    Range := Range - Bound;
    Result := 1;
  end;
  Normalize;
end;

function TLzmaDecoder.DirectBits(NumBits: Integer): LongWord;
var
  t: LongWord;
begin
  Result := 0;
  while NumBits > 0 do
  begin
    Range := Range shr 1;
    Code := Code - Range;
    t := LongWord(0) - (Code shr 31);
    Code := Code + (Range and t);
    Result := (Result shl 1) + (t + 1);
    Normalize;
    Dec(NumBits);
  end;
end;

function TLzmaDecoder.BitTree(Probs: PProb; NumBits: Integer): LongWord;
var
  m: LongWord;
  i: Integer;
begin
  m := 1;
  for i := 1 to NumBits do m := (m shl 1) + Bit(Probs[m]);
  Result := m - (LongWord(1) shl NumBits);
end;

function TLzmaDecoder.BitTreeReverse(Probs: PProb; NumBits: Integer): LongWord;
var
  m, b: LongWord;
  i: Integer;
begin
  m := 1;
  Result := 0;
  for i := 0 to NumBits - 1 do
  begin
    b := Bit(Probs[m]);
    m := (m shl 1) + b;
    Result := Result or (b shl i);
  end;
end;

function TLzmaDecoder.LenDecode(var d: TLenDecoder; PosState: LongWord): LongWord;
begin
  if Bit(d.Choice) = 0 then
    Exit(BitTree(@d.Low[PosState][0], 3));
  if Bit(d.Choice2) = 0 then
    Exit(8 + BitTree(@d.Mid[PosState][0], 3));
  Result := 16 + BitTree(@d.High[0], 8);
end;

function TLzmaDecoder.DecodeDistance(Len: LongWord): LongWord;
var
  LenState, Slot, NumDirectBits: LongWord;
begin
  LenState := Len;
  if LenState > kNumLenToPosStates - 1 then LenState := kNumLenToPosStates - 1;
  Slot := BitTree(@PosSlot[LenState][0], 6);
  if Slot < 4 then Exit(Slot);
  NumDirectBits := (Slot shr 1) - 1;
  Result := (2 or (Slot and 1)) shl NumDirectBits;
  if Slot < kEndPosModelIndex then
    Result := Result + BitTreeReverse(@PosDecoders[Result - Slot], NumDirectBits)
  else
  begin
    Result := Result + (DirectBits(NumDirectBits - kNumAlignBits) shl kNumAlignBits);
    Result := Result + BitTreeReverse(@Align[0], kNumAlignBits);
  end;
end;

{ Copia RemainLen bytes desde la distancia Rep0 (circular), sin pasar de Limit.
  Los solapamientos (dist < len) son legales: se copia byte a byte. }
procedure TLzmaDecoder.CopyMatch(Limit: SizeInt);
var
  Src, n, k, Dist: SizeInt;
  D, S: PByte;
begin
  Src := DicPos - SizeInt(Rep0) - 1;
  if Src < 0 then Inc(Src, DictSize);
  Dist := SizeInt(Rep0) + 1;
  // Por tramos: hasta Limit, hasta el fin del diccionario (la fuente da la vuelta) y lo que
  // falte del match; los contadores se actualizan una vez por tramo
  while (RemainLen > 0) and (DicPos < Limit) do
  begin
    n := Limit - DicPos;
    if n > SizeInt(RemainLen) then n := RemainLen;
    if n > DictSize - Src then n := DictSize - Src;
    D := Dict + DicPos;
    S := Dict + Src;
    if Dist >= n then
      Move(S^, D^, n)                  // sin solapamiento
    else
      for k := 0 to n - 1 do D[k] := S[k];   // solapado (dist < len): byte a byte, hacia adelante
    Inc(DicPos, n);
    Inc(Src, n);
    if Src = DictSize then Src := 0;
    Dec(RemainLen, n);
    Inc(TotalPos, n);
  end;
end;

function TLzmaDecoder.DecodeTo(Limit: SizeInt): TLzmaStatus;
var
  PosState, PbMask, LpMask, Symbol, MatchByte, MatchBit, b, Len, Dist: LongWord;
  PrevByte: Byte;
  LitProbs: PProb;
  i: Integer;
  Src: SizeInt;
begin
  if FFinished then Exit(lsEndMark);
  if not FInitialized then
  begin
    FInitialized := True;
    Range := $FFFFFFFF;
    Code := 0;
    if NextByte <> 0 then Exit(lsError);
    for i := 1 to 4 do Code := (Code shl 8) or NextByte;
    if FOverrun then Exit(lsInputEof);
    if Code = Range then Exit(lsError);
  end;

  if RemainLen > 0 then CopyMatch(Limit);

  PbMask := (LongWord(1) shl pb) - 1;
  LpMask := (LongWord(1) shl lp) - 1;
  while DicPos < Limit do
  begin
    if FOverrun then Exit(lsInputEof);
    PosState := LongWord(TotalPos) and PbMask;
    if Bit(IsMatch[(State shl kNumPosBitsMax) + PosState]) = 0 then
    begin
      // Literal
      if TotalPos = 0 then PrevByte := 0
      else if DicPos > 0 then PrevByte := Dict[DicPos - 1]
      else PrevByte := Dict[DictSize - 1];
      LitProbs := @Literals[$300 * (((LongWord(TotalPos) and LpMask) shl lc) + (LongWord(PrevByte) shr (8 - lc)))];
      Symbol := 1;
      if State >= 7 then
      begin
        Src := DicPos - SizeInt(Rep0) - 1;
        if Src < 0 then Inc(Src, DictSize);
        MatchByte := Dict[Src];
        repeat
          MatchBit := (MatchByte shr 7) and 1;
          MatchByte := MatchByte shl 1;
          b := Bit(LitProbs[((1 + MatchBit) shl 8) + Symbol]);
          Symbol := (Symbol shl 1) or b;
          if MatchBit <> b then Break;
        until Symbol >= $100;
      end;
      while Symbol < $100 do
        Symbol := (Symbol shl 1) or Bit(LitProbs[Symbol]);
      Dict[DicPos] := Byte(Symbol - $100);
      Inc(DicPos);
      Inc(TotalPos);
      if State < 4 then State := 0
      else if State < 10 then State := State - 3
      else State := State - 6;
      Continue;
    end;

    if Bit(IsRep[State]) <> 0 then
    begin
      if TotalPos = 0 then Exit(lsError);
      if Bit(IsRepG0[State]) = 0 then
      begin
        if Bit(IsRep0Long[(State shl kNumPosBitsMax) + PosState]) = 0 then
        begin
          // "Short rep": un solo byte desde rep0
          if State < 7 then State := 9 else State := 11;
          RemainLen := 1;
          CopyMatch(Limit);
          Continue;
        end;
      end
      else
      begin
        if Bit(IsRepG1[State]) = 0 then
          Dist := Rep1
        else
        begin
          if Bit(IsRepG2[State]) = 0 then
            Dist := Rep2
          else
          begin
            Dist := Rep3;
            Rep3 := Rep2;
          end;
          Rep2 := Rep1;
        end;
        Rep1 := Rep0;
        Rep0 := Dist;
      end;
      Len := LenDecode(RepLenDec, PosState);
      if State < 7 then State := 8 else State := 11;
    end
    else
    begin
      Rep3 := Rep2; Rep2 := Rep1; Rep1 := Rep0;
      Len := LenDecode(LenDec, PosState);
      if State < 7 then State := 7 else State := 10;
      Rep0 := DecodeDistance(Len);
      if Rep0 = $FFFFFFFF then
      begin
        FFinished := True;
        if FOverrun then Exit(lsInputEof);
        Exit(lsEndMark);
      end;
      if (QWord(Rep0) >= TotalPos) or (SizeInt(Rep0) >= DictSize) then Exit(lsError);
    end;
    RemainLen := Len + kMatchMinLen;
    CopyMatch(Limit);
  end;
  if FOverrun then Exit(lsInputEof);
  Result := lsLimit;
end;

{ TLzmaStage }

constructor TLzmaStage.Create(ASource: TInStage; Alc, Alp, Apb: Integer; ADictSize: QWord);
var
  n: SizeInt;
begin
  // Validar antes de adoptar ASource: si el constructor falla, FPC llama a Destroy, y la
  // cadena que nos creó también liberaría ASource (doble liberación)
  if not ValidLzmaProps(Alc, Alp, Apb) then Corrupt('propiedades lzma inválidas');
  if ADictSize > QWord(High(SizeInt) div 2) then Corrupt('diccionario lzma demasiado grande');
  inherited Create(ASource);
  n := ADictSize;
  if n < 4096 then n := 4096;
  SetLength(FDictBuf, n);
  FDec := TLzmaDecoder.Create(Alc, Alp, Apb, @FDictBuf[0], n, ASource);
end;

destructor TLzmaStage.Destroy;
begin
  FDec.Free;
  inherited Destroy;
end;

function TLzmaStage.Read(Buf: PByte; Count: SizeInt): SizeInt;
const
  CHUNK = 1 shl 20;
var
  Limit: SizeInt;
  st: TLzmaStatus;
begin
  Result := 0;
  if Count <= 0 then Exit;
  while FReadPos >= FDec.DicPos do
  begin
    if FEnded then Exit(0);
    if FDec.DicPos = FDec.DictSize then
    begin
      // Todo lo del diccionario ya se entregó: se puede reciclar desde el principio
      FDec.DicPos := 0;
      FReadPos := 0;
    end;
    Limit := FDec.DicPos + CHUNK;
    if Limit > FDec.DictSize then Limit := FDec.DictSize;
    st := FDec.DecodeTo(Limit);
    case st of
      lsEndMark: FEnded := True;
      lsError: Corrupt('datos lzma inválidos');
      lsInputEof: Corrupt('stream lzma truncado');
      lsLimit: ;
    end;
  end;
  Result := FDec.DicPos - FReadPos;
  if Result > Count then Result := Count;
  Move(FDictBuf[FReadPos], Buf^, Result);
  Inc(FReadPos, Result);
end;

{ Memoria-a-memoria }

function LzmaDecodeRaw(Src: PByte; SrcLen: SizeInt; Dst: PByte; DstLen: SizeInt;
  lc, lp, pb: Integer; out DstWritten: SizeInt): TLzmaResult;
var
  Input: TMemStage;
  Dec: TLzmaDecoder;
begin
  DstWritten := 0;
  if not ValidLzmaProps(lc, lp, pb) then Exit(lzBadProps);
  if DstLen = 0 then Exit(lzOk);
  Input := TMemStage.Create(Src, SrcLen);
  Dec := TLzmaDecoder.Create(lc, lp, pb, Dst, DstLen, Input);
  try
    case Dec.DecodeTo(DstLen) of
      lsLimit, lsEndMark: Result := lzOk;
      lsInputEof: Result := lzInputEof;
    else
      Result := lzDataError;
    end;
    DstWritten := Dec.DicPos;
  finally
    Dec.Free;
    Input.Free;
  end;
end;

end.
