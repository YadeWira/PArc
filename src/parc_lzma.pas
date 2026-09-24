{ Decodificador LZMA1 "raw" memoria-a-memoria (FORMATO-ARC.md §7.1).
  Sin cabecera .lzma: lc/lp/pb vienen del string del método; el tamaño de salida es conocido
  (origsize) y el stream puede o no terminar con marca de fin.
  Implementación directa del algoritmo de referencia de Igor Pavlov (LzmaSpec, dominio público).
  El buffer de salida hace de diccionario, así que dictSize no hace falta para decodificar. }
unit parc_lzma;

{$mode objfpc}{$H+}
{$R-}{$Q-}

interface

type
  TLzmaResult = (lzOk, lzBadProps, lzDataError, lzInputEof);

function LzmaDecodeRaw(Src: PByte; SrcLen: SizeInt; Dst: PByte; DstLen: SizeInt;
  lc, lp, pb: Integer; out DstWritten: SizeInt): TLzmaResult;

implementation

const
  kNumBitModelTotalBits = 11;
  kBitModelTotal = 1 shl kNumBitModelTotalBits;
  kNumMoveBits = 5;
  kTopValue = LongWord(1) shl 24;
  kNumStates = 12;
  kNumPosBitsMax = 4;
  kNumLenToPosStates = 4;
  kNumAlignBits = 4;
  kStartPosModelIndex = 4;
  kEndPosModelIndex = 14;
  kNumFullDistances = 1 shl (kEndPosModelIndex shr 1);
  kMatchMinLen = 2;

type
  TProb = Word;
  PProb = ^TProb;

  TLenDecoder = record
    Choice, Choice2: TProb;
    Low: array[0..(1 shl kNumPosBitsMax) - 1, 0..7] of TProb;
    Mid: array[0..(1 shl kNumPosBitsMax) - 1, 0..7] of TProb;
    High: array[0..255] of TProb;
  end;

  TRangeDecoder = record
    Range, Code: LongWord;
    Src: PByte;
    SrcPos, SrcLen: SizeInt;
    Overrun: Boolean;
  end;

  TLzmaState = record
    rc: TRangeDecoder;
    Literals: array of TProb;
    IsMatch: array[0..(kNumStates shl kNumPosBitsMax) - 1] of TProb;
    IsRep, IsRepG0, IsRepG1, IsRepG2: array[0..kNumStates - 1] of TProb;
    IsRep0Long: array[0..(kNumStates shl kNumPosBitsMax) - 1] of TProb;
    PosSlot: array[0..kNumLenToPosStates - 1, 0..63] of TProb;
    PosDecoders: array[0..1 + kNumFullDistances - kEndPosModelIndex - 1] of TProb;
    Align: array[0..(1 shl kNumAlignBits) - 1] of TProb;
    LenDec, RepLenDec: TLenDecoder;
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

function RcNextByte(var rc: TRangeDecoder): Byte; inline;
begin
  if rc.SrcPos < rc.SrcLen then
  begin
    Result := rc.Src[rc.SrcPos];
    Inc(rc.SrcPos);
  end
  else
  begin
    // Leer más allá del final: marcamos el error y devolvemos 0 para no cortar el flujo
    rc.Overrun := True;
    Result := 0;
  end;
end;

function RcInit(var rc: TRangeDecoder): Boolean;
var
  i: Integer;
begin
  rc.Range := $FFFFFFFF;
  rc.Code := 0;
  rc.Overrun := False;
  Result := RcNextByte(rc) = 0;
  for i := 1 to 4 do rc.Code := (rc.Code shl 8) or RcNextByte(rc);
  if rc.Code = rc.Range then Result := False;
end;

procedure RcNormalize(var rc: TRangeDecoder); inline;
begin
  if rc.Range < kTopValue then
  begin
    rc.Range := rc.Range shl 8;
    rc.Code := (rc.Code shl 8) or RcNextByte(rc);
  end;
end;

function RcBit(var rc: TRangeDecoder; var Prob: TProb): LongWord; inline;
var
  Bound: LongWord;
begin
  Bound := (rc.Range shr kNumBitModelTotalBits) * Prob;
  if rc.Code < Bound then
  begin
    Prob := Prob + ((kBitModelTotal - Prob) shr kNumMoveBits);
    rc.Range := Bound;
    Result := 0;
  end
  else
  begin
    Prob := Prob - (Prob shr kNumMoveBits);
    rc.Code := rc.Code - Bound;
    rc.Range := rc.Range - Bound;
    Result := 1;
  end;
  RcNormalize(rc);
end;

function RcDirectBits(var rc: TRangeDecoder; NumBits: Integer): LongWord;
var
  t: LongWord;
begin
  Result := 0;
  while NumBits > 0 do
  begin
    rc.Range := rc.Range shr 1;
    rc.Code := rc.Code - rc.Range;
    t := LongWord(0) - (rc.Code shr 31);
    rc.Code := rc.Code + (rc.Range and t);
    Result := (Result shl 1) + (t + 1);
    RcNormalize(rc);
    Dec(NumBits);
  end;
end;

function BitTree(var rc: TRangeDecoder; Probs: PProb; NumBits: Integer): LongWord;
var
  m: LongWord;
  i: Integer;
begin
  m := 1;
  for i := 1 to NumBits do m := (m shl 1) + RcBit(rc, Probs[m]);
  Result := m - (LongWord(1) shl NumBits);
end;

function BitTreeReverse(var rc: TRangeDecoder; Probs: PProb; NumBits: Integer): LongWord;
var
  m, bit: LongWord;
  i: Integer;
begin
  m := 1;
  Result := 0;
  for i := 0 to NumBits - 1 do
  begin
    bit := RcBit(rc, Probs[m]);
    m := (m shl 1) + bit;
    Result := Result or (bit shl i);
  end;
end;

procedure LenInit(var d: TLenDecoder);
begin
  InitProbs(@d, SizeOf(d) div SizeOf(TProb));
end;

function LenDecode(var rc: TRangeDecoder; var d: TLenDecoder; PosState: LongWord): LongWord;
begin
  if RcBit(rc, d.Choice) = 0 then
    Exit(BitTree(rc, @d.Low[PosState][0], 3));
  if RcBit(rc, d.Choice2) = 0 then
    Exit(8 + BitTree(rc, @d.Mid[PosState][0], 3));
  Result := 16 + BitTree(rc, @d.High[0], 8);
end;

function DecodeDistance(var s: TLzmaState; Len: LongWord): LongWord;
var
  LenState, PosSlot, NumDirectBits: LongWord;
begin
  LenState := Len;
  if LenState > kNumLenToPosStates - 1 then LenState := kNumLenToPosStates - 1;
  PosSlot := BitTree(s.rc, @s.PosSlot[LenState][0], 6);
  if PosSlot < 4 then Exit(PosSlot);
  NumDirectBits := (PosSlot shr 1) - 1;
  Result := (2 or (PosSlot and 1)) shl NumDirectBits;
  if PosSlot < kEndPosModelIndex then
    Result := Result + BitTreeReverse(s.rc, @s.PosDecoders[Result - PosSlot], NumDirectBits)
  else
  begin
    Result := Result + (RcDirectBits(s.rc, NumDirectBits - kNumAlignBits) shl kNumAlignBits);
    Result := Result + BitTreeReverse(s.rc, @s.Align[0], kNumAlignBits);
  end;
end;

function LzmaDecodeRaw(Src: PByte; SrcLen: SizeInt; Dst: PByte; DstLen: SizeInt;
  lc, lp, pb: Integer; out DstWritten: SizeInt): TLzmaResult;
var
  s: TLzmaState;
  OutPos: SizeInt;
  State, Rep0, Rep1, Rep2, Rep3, Len, Dist: LongWord;
  PosState, PbMask, LpMask, Symbol, MatchByte, MatchBit, Bit: LongWord;
  PrevByte: Byte;
  LitProbs: PProb;
  i: SizeInt;
begin
  DstWritten := 0;
  if (lc < 0) or (lc > 8) or (lp < 0) or (lp > 4) or (pb < 0) or (pb > kNumPosBitsMax) then
    Exit(lzBadProps);

  SetLength(s.Literals, SizeInt($300) shl (lc + lp));
  InitProbs(@s.Literals[0], Length(s.Literals));
  InitProbs(@s.IsMatch, Length(s.IsMatch));
  InitProbs(@s.IsRep, kNumStates);
  InitProbs(@s.IsRepG0, kNumStates);
  InitProbs(@s.IsRepG1, kNumStates);
  InitProbs(@s.IsRepG2, kNumStates);
  InitProbs(@s.IsRep0Long, Length(s.IsRep0Long));
  InitProbs(@s.PosSlot, SizeOf(s.PosSlot) div SizeOf(TProb));
  InitProbs(@s.PosDecoders, Length(s.PosDecoders));
  InitProbs(@s.Align, Length(s.Align));
  LenInit(s.LenDec);
  LenInit(s.RepLenDec);

  s.rc.Src := Src;
  s.rc.SrcLen := SrcLen;
  s.rc.SrcPos := 0;
  if not RcInit(s.rc) then Exit(lzDataError);

  PbMask := (LongWord(1) shl pb) - 1;
  LpMask := (LongWord(1) shl lp) - 1;
  State := 0; Rep0 := 0; Rep1 := 0; Rep2 := 0; Rep3 := 0;
  OutPos := 0;
  Result := lzOk;

  while OutPos < DstLen do
  begin
    PosState := LongWord(OutPos) and PbMask;
    if RcBit(s.rc, s.IsMatch[(State shl kNumPosBitsMax) + PosState]) = 0 then
    begin
      // Literal
      if OutPos > 0 then PrevByte := Dst[OutPos - 1] else PrevByte := 0;
      LitProbs := @s.Literals[$300 * (((LongWord(OutPos) and LpMask) shl lc) + (LongWord(PrevByte) shr (8 - lc)))];
      Symbol := 1;
      if State >= 7 then
      begin
        MatchByte := Dst[OutPos - SizeInt(Rep0) - 1];
        repeat
          MatchBit := (MatchByte shr 7) and 1;
          MatchByte := MatchByte shl 1;
          Bit := RcBit(s.rc, LitProbs[((1 + MatchBit) shl 8) + Symbol]);
          Symbol := (Symbol shl 1) or Bit;
          if MatchBit <> Bit then Break;
        until Symbol >= $100;
      end;
      while Symbol < $100 do
        Symbol := (Symbol shl 1) or RcBit(s.rc, LitProbs[Symbol]);
      Dst[OutPos] := Byte(Symbol - $100);
      Inc(OutPos);
      if State < 4 then State := 0
      else if State < 10 then State := State - 3
      else State := State - 6;
    end
    else
    begin
      if RcBit(s.rc, s.IsRep[State]) <> 0 then
      begin
        if OutPos = 0 then Exit(lzDataError);
        if RcBit(s.rc, s.IsRepG0[State]) = 0 then
        begin
          if RcBit(s.rc, s.IsRep0Long[(State shl kNumPosBitsMax) + PosState]) = 0 then
          begin
            // "Short rep": un solo byte desde rep0
            if State < 7 then State := 9 else State := 11;
            Dst[OutPos] := Dst[OutPos - SizeInt(Rep0) - 1];
            Inc(OutPos);
            Continue;
          end;
        end
        else
        begin
          if RcBit(s.rc, s.IsRepG1[State]) = 0 then
            Dist := Rep1
          else
          begin
            if RcBit(s.rc, s.IsRepG2[State]) = 0 then
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
        Len := LenDecode(s.rc, s.RepLenDec, PosState);
        if State < 7 then State := 8 else State := 11;
      end
      else
      begin
        Rep3 := Rep2; Rep2 := Rep1; Rep1 := Rep0;
        Len := LenDecode(s.rc, s.LenDec, PosState);
        if State < 7 then State := 7 else State := 10;
        Rep0 := DecodeDistance(s, Len);
        if Rep0 = $FFFFFFFF then
          Break;   // marca de fin
        if SizeInt(Rep0) >= OutPos then Exit(lzDataError);
      end;
      Len := Len + kMatchMinLen;
      // Copia byte a byte: los solapamientos (dist < len) son legales
      i := OutPos - SizeInt(Rep0) - 1;
      while (Len > 0) and (OutPos < DstLen) do
      begin
        Dst[OutPos] := Dst[i];
        Inc(OutPos);
        Inc(i);
        Dec(Len);
      end;
    end;
    if s.rc.Overrun then Break;
  end;

  DstWritten := OutPos;
  if s.rc.Overrun then Result := lzInputEof;
end;

end.
