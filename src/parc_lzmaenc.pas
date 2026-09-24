{ Codificador LZMA1 "raw" (sin cabecera .lzma): port a Pascal de LzmaEnc.c + LzFind.c del
  LZMA SDK 26.03 (Igor Pavlov, dominio público), un solo hilo (sin LzFindMt).
  Uso en FreeArc (C_LZMA.cpp, lzma_compress2): las propiedades no se escriben (salen del string
  del método) y el stream lleva marca de fin (writeEndMark = 1), que lzma_decompress2 exige
  (LZMA_STATUS_FINISHED_WITH_MARK) al descomprimir en streaming.
  - TLzmaEncStage: etapa "push" (TOutStage) para bloques de datos.
  - LzmaEncodeMem: memoria-a-memoria (LzmaEnc_MemEncode), para bloques de control y 4x4.
  Match finders: bt2, bt3, bt4, hc4. El ht4 de FreeArc (tabla hash con cubetas, propio de su
  LzFind.c) no existe en el SDK 26.03: se mapea a hc4 (con mc por defecto = fb/2, como el ht4).
  El stream sigue siendo LZMA estándar; solo cambian la razón de compresión y la velocidad.
  Con los mismos parámetros la salida es idéntica byte a byte a la del SDK 26.03 (LzmaEnc_Encode
  y LzmaEnc_MemEncode). Diferencias con FreeArc 0.67 (SDK 9.x modificado):
  - mc = 0 usa la fórmula de FreeArc (bt: 16+fb/2, hc4: 16+fb/4, ht4: fb/2).
  - "h" (tamaño del hash) se acepta y se ignora: el SDK 26.03 lo deriva del diccionario.
  - No se aplica el redondeo de LZMA_METHOD::SetDictionary (mínimo 32kb, rounddown_mem): el
    llamador debe escribir en el método exactamente el DictSize con que comprime. }
unit parc_lzmaenc;

{$mode objfpc}{$H+}
{$R-}{$Q-}
{$pointermath on}
{$inline on}

interface

uses
  SysUtils, parc_outstream;

type
  ELzmaEncParams = class(Exception);

  TLzmaMatchFinder = (mfBT2, mfBT3, mfBT4, mfHC4, mfHT4);

  TLzmaEncParams = record
    DictSize: QWord;
    HashSize: QWord;            // "h" de FreeArc: se acepta pero el SDK 26.03 deriva el hash del diccionario
    lc, lp, pb: Integer;
    Algorithm: Integer;         // 0 = fast (GetOptimumFast), >= 1 = normal (óptimo)
    NumFastBytes: Integer;      // se recorta a 5..273 como LzmaEnc_SetProps
    MatchFinderCycles: Integer; // 0 = automático (fórmula de LzmaEncProps_Normalize de FreeArc)
    MatchFinder: TLzmaMatchFinder;
  end;

  { Etapa de compresión LZMA. Bufferea internamente lo justo para que el match finder nunca
    vea el "fin de stream" antes de Finish. }
  TLzmaEncStage = class(TOutStage)
  private
    FEnc: TObject;              // TLzmaEnc (interno)
    FPend: TBytes;              // entrada todavía no tomada por el match finder
    FPendPos, FPendLen: SizeInt;
    FExt: PByte;                // buffer del llamador durante DoWrite (se lee sin copiar)
    FExtLen: SizeInt;
    FEof: Boolean;
    FThreshold: SizeInt;
    function ReadIn(Buf: PByte; Size: SizeInt): SizeInt;
    procedure WriteOut(Buf: PByte; Size: SizeInt);
  protected
    procedure DoWrite(Buf: PByte; Count: SizeInt); override;
    procedure DoFinish; override;
  public
    constructor Create(ATarget: TOutStage; const P: TLzmaEncParams; WriteEndMark: Boolean = True);
    destructor Destroy; override;
  end;

function DefaultLzmaEncParams: TLzmaEncParams;
{ Como parse_LZMA (C_LZMA.cpp): Params[0] = 'lzma'. Lanza ELzmaEncParams si un parámetro no
  opcional es inválido. }
function ParseLzmaEncParams(const Params: TStringArray): TLzmaEncParams;
{ Lanza ELzmaEncParams si P no se puede usar para comprimir. }
procedure ValidateLzmaEncParams(const P: TLzmaEncParams);
function LzmaEncodeMem(Src: PByte; SrcLen: SizeInt; const P: TLzmaEncParams; WriteEndMark: Boolean): TBytes;

implementation

const
  kLzmaMaxHistorySize = LongWord(15) shl 28;
  kTopValue = LongWord(1) shl 24;
  kNumBitModelTotalBits = 11;
  kBitModelTotal = 1 shl kNumBitModelTotalBits;
  kNumMoveBits = 5;
  kProbInitValue = kBitModelTotal shr 1;
  kNumMoveReducingBits = 4;
  kNumBitPriceShiftBits = 4;
  REP_LEN_COUNT = 64;
  kNumOpts = 1 shl 11;
  kNumLenToPosStates = 4;
  kNumPosSlotBits = 6;
  kDicLogSizeMax = 32;
  kNumAlignBits = 4;
  kAlignTableSize = 1 shl kNumAlignBits;
  kAlignMask = kAlignTableSize - 1;
  kStartPosModelIndex = 4;
  kEndPosModelIndex = 14;
  kNumFullDistances = 1 shl (kEndPosModelIndex shr 1);
  kLenNumLowBits = 3;
  kLenNumLowSymbols = 1 shl kLenNumLowBits;
  kLenNumHighBits = 8;
  LZMA_MATCH_LEN_MIN = 2;
  LZMA_MATCH_LEN_MAX = 273;
  LZMA_NUM_REPS = 4;
  kInfinityPrice = 1 shl 30;
  MARK_LIT = LongWord($FFFFFFFF);
  RC_BUF_SIZE = 1 shl 16;

  kState_LitAfterMatch = 4;
  kState_LitAfterRep = 5;
  kState_MatchAfterLit = 7;
  kState_RepAfterLit = 8;

  kLiteralNextStates: array[0..11] of Byte = (0, 0, 0, 0, 1, 2, 3, 4, 5, 6, 4, 5);
  kMatchNextStates: array[0..11] of Byte = (7, 7, 7, 7, 7, 7, 7, 10, 10, 10, 10, 10);
  kRepNextStates: array[0..11] of Byte = (8, 8, 8, 8, 8, 8, 8, 11, 11, 11, 11, 11);
  kShortRepNextStates: array[0..11] of Byte = (9, 9, 9, 9, 9, 9, 9, 11, 11, 11, 11, 11);

  // LzFind.c / LzHash.h
  kBlockMoveAlign = 1 shl 7;
  kBlockSizeAlign = 1 shl 16;
  kBlockSizeReserveMin = 1 shl 24;
  kHash2Size = 1 shl 10;
  kHash3Size = 1 shl 16;
  kFix3HashSize = kHash2Size;
  kFix4HashSize = kHash2Size + kHash3Size;
  kLzHash_CrcShift_1 = 5;

{ Núcleo del codificador (CLzmaEnc + CMatchFinder) }
type
  TMfRead = function(Buf: PByte; Size: SizeInt): SizeInt of object;
  TEncWrite = procedure(Buf: PByte; Size: SizeInt) of object;

  PMatchFinder = ^TMatchFinder;
  TMfGetMatches = function(p: PMatchFinder; distances: PLongWord): PLongWord;
  TMfSkip = procedure(p: PMatchFinder; num: LongWord);

  { CMatchFinder (LzFind.h) }
  TMatchFinder = record
    buffer: PByte;
    pos, posLimit, streamPos, lenLimit: LongWord;
    cyclicBufferPos, cyclicBufferSize: LongWord;
    streamEndWasReached, btMode, directInput: Boolean;
    matchMaxLen: LongWord;
    hash, son: PLongWord;
    hashMask, cutValue: LongWord;
    bufBase: PByte;
    blockSize, keepSizeBefore, keepSizeAfter: LongWord;
    numHashBytes: LongWord;
    directInputRem: QWord;
    historySize, fixedHashSize: LongWord;
    crc: array[0..255] of LongWord;
    expectedDataSize: QWord;
    Read: TMfRead;
  end;

  TProb = Word;
  PProb = ^TProb;

  TOptimal = record
    price: LongWord;
    state: Word;
    extra: Word;
    len: LongWord;
    dist: LongWord;
    reps: array[0..3] of LongWord;
  end;
  POptimal = ^TOptimal;

  TLenEnc = record
    low: array[0..(16 shl 4) - 1] of TProb;
    high: array[0..255] of TProb;
  end;
  PLenEnc = ^TLenEnc;

  TLenPriceEnc = record
    tableSize: LongWord;
    prices: array[0..15, 0..271] of LongWord;
  end;
  PLenPriceEnc = ^TLenPriceEnc;

  TLzmaEnc = class
  private
    mf: TMatchFinder;
    GetMatchesF: TMfGetMatches;
    SkipF: TMfSkip;
    FOptCur, FOptEnd, FLongestMatchLen, FNumPairs, FNumAvail: LongWord;
    FState, numFastBytes, FAdditionalOffset: LongWord;
    FReps: array[0..3] of LongWord;
    lpMask, pbMask: LongWord;
    litProbs: PProb;
    // CRangeEnc
    rcRange, rcCache: LongWord;
    rcLow, rcCacheSize, rcProcessed: QWord;
    rcBuf, rcBufLim: PByte;
    rcBufBase: array of Byte;
    FBackRes: LongWord;
    lc, lp, pb, lclp: LongWord;
    fastMode, writeEndMark, FFinished, needInit: Boolean;
    matchPriceCount: LongWord;
    repLenEncCounter: Integer;
    distTableSize: LongWord;
    dictSize: LongWord;
    ProbPrices: array[0..127] of LongWord;
    FMatches: array[0..273 * 2 + 2 - 1] of LongWord;
    alignPrices: array[0..15] of LongWord;
    posSlotPrices: array[0..3, 0..63] of LongWord;
    distancesPrices: array[0..3, 0..127] of LongWord;
    posAlignEncoder: array[0..15] of TProb;
    isRep, isRepG0, isRepG1, isRepG2: array[0..11] of TProb;
    isMatch, isRep0Long: array[0..11, 0..15] of TProb;
    posSlotEncoder: array[0..3, 0..63] of TProb;
    posEncoders: array[0..127] of TProb;
    lenProbs, repLenProbs: TLenEnc;
    lenEnc, repLenEnc: TLenPriceEnc;
    opt: array[0..(1 shl 11) - 1] of TOptimal;
    OnWrite: TEncWrite;
    procedure RcFlushStream;
    procedure RcShiftLow;
    procedure RcBit(prob: PProb; bit: LongWord); inline;
    procedure LitEncode(probs: PProb; sym: LongWord);
    procedure LitEncodeMatched(probs: PProb; sym, matchByte: LongWord);
    procedure RcTreeReverseEncode(probs: PProb; numBits, sym: LongWord);
    procedure LenEncEncode(p: PLenEnc; sym, posState: LongWord);
    function GP(prob, bit: LongWord): LongWord; inline;
    function GP0(prob: LongWord): LongWord; inline;
    function GP1(prob: LongWord): LongWord; inline;
    function LitPrice(probs: PProb; sym: LongWord): LongWord;
    function LitMatchedPrice(probs: PProb; sym, matchByte: LongWord): LongWord;
    procedure SetPrices3(probs: PProb; startPrice: LongWord; prices: PLongWord);
    procedure LenPriceUpdateTables(p: PLenPriceEnc; numPosStates: LongWord; enc: PLenEnc);
    function ReadMatchDistances(out numPairsRes: LongWord): LongWord;
    procedure MovePos(num: LongWord); inline;
    function LitProbsPtr(pos, prevByte: LongWord): PProb; inline;
    function PriceShortRep(state, posState: LongWord): LongWord; inline;
    function PriceRep0(state, posState: LongWord): LongWord; inline;
    function PricePureRep(repIndex, state, posState: LongWord): LongWord;
    function Backward(cur: LongWord): LongWord;
    function GetOptimum(position: LongWord): LongWord;
    function GetOptimumFast: LongWord;
    procedure WriteEndMarker(posState: LongWord);
    procedure Flush(nowPos: LongWord);
    procedure FillAlignPrices;
    procedure FillDistancesPrices;
    procedure InitState;
    procedure InitPrices;
  public
    nowPos64: QWord;
    { Valida P (excepción ELzmaEncParams) y reserva toda la memoria. }
    constructor Create(const P: TLzmaEncParams; AWriteEndMark: Boolean; ARead: TMfRead;
      AWrite: TEncWrite; DirectSrc: PByte; DirectLen: QWord);
    destructor Destroy; override;
    procedure CodeOneBlock;
    function AvailIn: QWord;
    property Finished: Boolean read FFinished;
  end;

{ ====================================================================== }
{ Match finder (LzFind.c)                                                  }
{ ====================================================================== }

function MfAvail(p: PMatchFinder): LongWord; inline;
begin
  Result := LongWord(p^.streamPos - p^.pos);
end;

{ MatchFinder_ReadBlock }
procedure MfReadBlock(p: PMatchFinder);
var
  curSize: LongWord;
  dest: PByte;
  size: SizeInt;
begin
  if p^.streamEndWasReached then Exit;
  if p^.directInput then
  begin
    curSize := LongWord($FFFFFFFF) - MfAvail(p);
    if curSize > p^.directInputRem then curSize := LongWord(p^.directInputRem);
    p^.streamPos := LongWord(p^.streamPos + curSize);
    Dec(p^.directInputRem, curSize);
    if p^.directInputRem = 0 then p^.streamEndWasReached := True;
    Exit;
  end;
  repeat
    dest := p^.buffer + MfAvail(p);
    size := (p^.bufBase + p^.blockSize) - dest;
    if size = 0 then Exit;
    size := p^.Read(dest, size);
    if size = 0 then
    begin
      p^.streamEndWasReached := True;
      Exit;
    end;
    p^.streamPos := LongWord(p^.streamPos + LongWord(size));
  until MfAvail(p) > p^.keepSizeAfter;
end;

{ MatchFinder_MoveBlock }
procedure MfMoveBlock(p: PMatchFinder);
var
  offset, keepBefore: PtrUInt;
begin
  offset := PtrUInt(p^.buffer - p^.bufBase) - p^.keepSizeBefore;
  keepBefore := (offset and (kBlockMoveAlign - 1)) + p^.keepSizeBefore;
  p^.buffer := p^.bufBase + keepBefore;
  Move((p^.bufBase + (offset and not PtrUInt(kBlockMoveAlign - 1)))^, p^.bufBase^,
    keepBefore + PtrUInt(MfAvail(p)));
end;

{ MatchFinder_NeedMove }
function MfNeedMove(p: PMatchFinder): Boolean;
begin
  if p^.directInput or p^.streamEndWasReached then Exit(False);
  Result := PtrUInt((p^.bufBase + p^.blockSize) - p^.buffer) <= p^.keepSizeAfter;
end;

procedure MfConstruct(p: PMatchFinder);
var
  i, j: Integer;
  r: LongWord;
begin
  FillChar(p^, SizeOf(p^), 0);
  p^.expectedDataSize := High(QWord);
  p^.cutValue := 32;
  p^.btMode := True;
  p^.numHashBytes := 4;
  for i := 0 to 255 do
  begin
    r := i;
    for j := 0 to 7 do
      if (r and 1) <> 0 then r := (r shr 1) xor $EDB88320 else r := r shr 1;
    p^.crc[i] := r;
  end;
end;

procedure MfFree(p: PMatchFinder);
begin
  if p^.hash <> nil then FreeMem(p^.hash);
  p^.hash := nil;
  if p^.son <> nil then FreeMem(p^.son);
  p^.son := nil;
  if p^.bufBase <> nil then FreeMem(p^.bufBase);
  p^.bufBase := nil;
end;

{ GetBlockSize }
function MfGetBlockSize(p: PMatchFinder; historySize: LongWord): LongWord;
const
  kBlockSizeMax = LongWord(0 - kBlockSizeAlign);
var
  blockSize, rem, reserve: LongWord;
begin
  blockSize := LongWord(p^.keepSizeBefore + p^.keepSizeAfter);
  if (p^.keepSizeBefore < historySize) or (blockSize < p^.keepSizeBefore) then Exit(0);
  rem := LongWord(kBlockSizeMax - blockSize);
  if blockSize < (LongWord(1) shl 30) then reserve := blockSize shr 1 else reserve := blockSize shr 2;
  reserve := reserve + (1 shl 12) + kBlockMoveAlign + kBlockSizeAlign;
  if (blockSize >= kBlockSizeMax) or (rem < kBlockSizeReserveMin) then Exit(0);
  if reserve >= rem then
    blockSize := kBlockSizeMax
  else
  begin
    blockSize := blockSize + reserve;
    blockSize := blockSize and not LongWord(kBlockSizeAlign - 1);
  end;
  Result := blockSize;
end;

{ MatchFinder_GetHashMask }
function MfGetHashMask(p: PMatchFinder; hs: LongWord): LongWord;
begin
  if p^.numHashBytes = 2 then Exit((1 shl 16) - 1);
  if hs <> 0 then Dec(hs);
  hs := hs or (hs shr 1);
  hs := hs or (hs shr 2);
  hs := hs or (hs shr 4);
  hs := hs or (hs shr 8);
  hs := hs shr 1;
  if hs >= (1 shl 24) then
  begin
    if p^.numHashBytes = 3 then hs := (1 shl 24) - 1 else hs := hs shr 1;
  end;
  hs := hs or ((1 shl 16) - 1);
  Result := hs;
end;

{ MatchFinder_Create (sin numHashOutBits, que FreeArc no usa). Lanza EOutOfMemory. }
procedure MfCreate(p: PMatchFinder; historySize, keepAddBufferBefore, matchMaxLen,
  keepAddBufferAfter: LongWord);
var
  hs, hsCur, fixed: LongWord;
  hashSizeSum, numSons, newSize: QWord;
begin
  p^.keepSizeBefore := historySize + keepAddBufferBefore + 1;
  keepAddBufferAfter := keepAddBufferAfter + matchMaxLen;
  if keepAddBufferAfter < p^.numHashBytes then keepAddBufferAfter := p^.numHashBytes;
  p^.keepSizeAfter := keepAddBufferAfter;
  if p^.directInput then
    p^.blockSize := 0
  else
  begin
    p^.blockSize := MfGetBlockSize(p, historySize);
    if p^.blockSize = 0 then raise ELzmaEncParams.Create('lzma: diccionario demasiado grande');
    {$IFDEF CPU32}
    if p^.blockSize > LongWord(High(SizeInt)) then raise EOutOfMemory.Create('lzma: sin memoria para la ventana');
    {$ENDIF}
    p^.bufBase := GetMem(p^.blockSize);
  end;
  hs := MfGetHashMask(p, historySize);
  hsCur := hs;
  if p^.expectedDataSize < historySize then
  begin
    hsCur := MfGetHashMask(p, LongWord(p^.expectedDataSize));
    if hsCur >= hs then hsCur := hs;
  end;
  p^.hashMask := hsCur;
  hashSizeSum := QWord(hs) + 1;
  fixed := 0;
  if p^.numHashBytes > 2 then Inc(fixed, kHash2Size);
  if p^.numHashBytes > 3 then Inc(fixed, kHash3Size);
  Inc(hashSizeSum, fixed);
  p^.fixedHashSize := fixed;
  p^.matchMaxLen := matchMaxLen;
  p^.historySize := historySize;
  p^.cyclicBufferSize := historySize + 1;
  numSons := QWord(p^.cyclicBufferSize);
  if p^.btMode then numSons := numSons shl 1;
  // El SDK reserva hash y son en un solo bloque; acá van por separado (misma salida) para
  // no exigir un bloque contiguo enorme en 32 bits.
  newSize := (numSons + $F) and not QWord($F);
  if (hashSizeSum * 4 > QWord(High(SizeInt))) or (newSize * 4 > QWord(High(SizeInt))) then
    raise EOutOfMemory.Create('lzma: sin memoria para el match finder');
  p^.hash := GetMem(SizeInt(hashSizeSum * 4));
  p^.son := GetMem(SizeInt(newSize * 4));
end;

{ MatchFinder_SetLimits }
procedure MfSetLimits(p: PMatchFinder);
var
  k, n, ksa, mm: LongWord;
begin
  n := LongWord(0 - p^.pos);   // kMaxValForNormalize = 0
  if n = 0 then n := LongWord($FFFFFFFF);
  k := p^.cyclicBufferSize - p^.cyclicBufferPos;
  if k < n then n := k;
  k := MfAvail(p);
  ksa := p^.keepSizeAfter;
  mm := p^.matchMaxLen;
  if k > ksa then
    k := k - ksa
  else if k >= mm then
    k := k - mm + 1
  else
  begin
    mm := k;
    if k <> 0 then k := 1;
  end;
  p^.lenLimit := mm;
  if k < n then n := k;
  p^.posLimit := LongWord(p^.pos + n);
end;

{ MatchFinder_Init }
procedure MfInit(p: PMatchFinder);
begin
  FillDWord((p^.hash + p^.fixedHashSize)^, SizeInt(p^.hashMask) + 1, 0);
  if p^.fixedHashSize > 0 then FillDWord(p^.hash^, p^.fixedHashSize, 0);
  if not p^.directInput then p^.buffer := p^.bufBase;
  p^.pos := 1;
  p^.streamPos := 1;
  p^.streamEndWasReached := False;
  MfReadBlock(p);
  p^.cyclicBufferPos := p^.pos;
  MfSetLimits(p);
end;

{ MatchFinder_Normalize3 (resta con saturación) }
procedure MfNormalize3(subValue: LongWord; items: PLongWord; numItems: PtrUInt);
var
  v: LongWord;
begin
  while numItems <> 0 do
  begin
    v := items^;
    if v < subValue then v := subValue;
    items^ := v - subValue;
    Inc(items);
    Dec(numItems);
  end;
end;

{ MatchFinder_CheckLimits }
procedure MfCheckLimits(p: PMatchFinder);
var
  subValue: LongWord;
  numSonRefs: PtrUInt;
begin
  if p^.keepSizeAfter = MfAvail(p) then
  begin
    if MfNeedMove(p) then MfMoveBlock(p);
    MfReadBlock(p);
  end;
  if p^.pos = 0 then
    if MfAvail(p) >= p^.numHashBytes then
    begin
      subValue := LongWord(p^.pos - p^.historySize - 1);
      p^.pos := LongWord(p^.pos - subValue);
      p^.streamPos := LongWord(p^.streamPos - subValue);
      MfNormalize3(subValue, p^.hash, PtrUInt(p^.hashMask) + 1 + p^.fixedHashSize);
      numSonRefs := p^.cyclicBufferSize;
      if p^.btMode then numSonRefs := numSonRefs shl 1;
      MfNormalize3(subValue, p^.son, numSonRefs);
    end;
  if p^.cyclicBufferPos = p^.cyclicBufferSize then p^.cyclicBufferPos := 0;
  MfSetLimits(p);
end;

{ MOVE_POS / MatchFinder_MovePos }
procedure MfMovePos(p: PMatchFinder); inline;
begin
  Inc(p^.cyclicBufferPos);
  Inc(p^.buffer);
  p^.pos := LongWord(p^.pos + 1);
  if p^.pos = p^.posLimit then MfCheckLimits(p);
end;

function CycIndex(cyclicBufferPos, delta, cyclicBufferSize: LongWord): PtrUInt; inline;
begin
  if cyclicBufferPos < delta then
    Result := PtrUInt(cyclicBufferPos - delta + cyclicBufferSize)
  else
    Result := cyclicBufferPos - delta;
end;

{ Hc_GetMatchesSpec }
function HcGetMatchesSpec(lenLimit, curMatch, pos: LongWord; cur: PByte; son: PLongWord;
  cyclicBufferPos, cyclicBufferSize, cutValue: LongWord; d: PLongWord; maxLen: LongWord): PLongWord;
var
  lim, c: PByte;
  delta, len: LongWord;
  diff: PtrInt;
begin
  lim := cur + lenLimit;
  son[cyclicBufferPos] := curMatch;
  repeat
    if curMatch = 0 then Break;
    delta := LongWord(pos - curMatch);
    if delta >= cyclicBufferSize then Break;
    curMatch := son[CycIndex(cyclicBufferPos, delta, cyclicBufferSize)];
    diff := -PtrInt(delta);
    if cur[maxLen] = cur[PtrInt(maxLen) + diff] then
    begin
      c := cur;
      while c^ = c[diff] do
      begin
        Inc(c);
        if c = lim then
        begin
          d[0] := LongWord(lim - cur);
          d[1] := delta - 1;
          Exit(d + 2);
        end;
      end;
      len := LongWord(c - cur);
      if maxLen < len then
      begin
        maxLen := len;
        d[0] := len;
        d[1] := delta - 1;
        Inc(d, 2);
      end;
    end;
    Dec(cutValue);
  until cutValue = 0;
  Result := d;
end;

{ GetMatchesSpec1 (árbol binario) }
function BtGetMatchesSpec(lenLimit, curMatch, pos: LongWord; cur: PByte; son: PLongWord;
  cyclicBufferPos, cyclicBufferSize, cutValue: LongWord; d: PLongWord; maxLen: LongWord): PLongWord;
var
  ptr0, ptr1, pair: PLongWord;
  len0, len1, len, cmCheck, delta, pair0: LongWord;
  pb: PByte;
begin
  ptr0 := son + (PtrUInt(cyclicBufferPos) shl 1) + 1;
  ptr1 := son + (PtrUInt(cyclicBufferPos) shl 1);
  len0 := 0; len1 := 0;
  cmCheck := LongWord(pos - cyclicBufferSize);
  if pos < cyclicBufferSize then cmCheck := 0;
  if cmCheck < curMatch then
    repeat
      delta := LongWord(pos - curMatch);
      pair := son + (CycIndex(cyclicBufferPos, delta, cyclicBufferSize) shl 1);
      pb := cur - delta;
      if len0 < len1 then len := len0 else len := len1;
      pair0 := pair[0];
      if pb[len] = cur[len] then
      begin
        Inc(len);
        if (len <> lenLimit) and (pb[len] = cur[len]) then
        begin
          Inc(len);
          while (len <> lenLimit) and (pb[len] = cur[len]) do Inc(len);
        end;
        if maxLen < len then
        begin
          maxLen := len;
          d[0] := len;
          d[1] := delta - 1;
          Inc(d, 2);
          if len = lenLimit then
          begin
            ptr1^ := pair0;
            ptr0^ := pair[1];
            Exit(d);
          end;
        end;
      end;
      if pb[len] < cur[len] then
      begin
        ptr1^ := curMatch;
        curMatch := pair[1];
        ptr1 := pair + 1;
        len1 := len;
      end
      else
      begin
        ptr0^ := curMatch;
        curMatch := pair[0];
        ptr0 := pair;
        len0 := len;
      end;
      Dec(cutValue);
    until (cutValue = 0) or not (cmCheck < curMatch);
  ptr0^ := 0;
  ptr1^ := 0;
  Result := d;
end;

{ SkipMatchesSpec }
procedure BtSkipMatchesSpec(lenLimit, curMatch, pos: LongWord; cur: PByte; son: PLongWord;
  cyclicBufferPos, cyclicBufferSize, cutValue: LongWord);
var
  ptr0, ptr1, pair: PLongWord;
  len0, len1, len, cmCheck, delta: LongWord;
  pb: PByte;
begin
  ptr0 := son + (PtrUInt(cyclicBufferPos) shl 1) + 1;
  ptr1 := son + (PtrUInt(cyclicBufferPos) shl 1);
  len0 := 0; len1 := 0;
  cmCheck := LongWord(pos - cyclicBufferSize);
  if pos < cyclicBufferSize then cmCheck := 0;
  if cmCheck < curMatch then
    repeat
      delta := LongWord(pos - curMatch);
      pair := son + (CycIndex(cyclicBufferPos, delta, cyclicBufferSize) shl 1);
      pb := cur - delta;
      if len0 < len1 then len := len0 else len := len1;
      if pb[len] = cur[len] then
      begin
        Inc(len);
        while (len <> lenLimit) and (pb[len] = cur[len]) do Inc(len);
        if len = lenLimit then
        begin
          ptr1^ := pair[0];
          ptr0^ := pair[1];
          Exit;
        end;
      end;
      if pb[len] < cur[len] then
      begin
        ptr1^ := curMatch;
        curMatch := pair[1];
        ptr1 := pair + 1;
        len1 := len;
      end
      else
      begin
        ptr0^ := curMatch;
        curMatch := pair[0];
        ptr0 := pair;
        len0 := len;
      end;
      Dec(cutValue);
    until (cutValue = 0) or not (cmCheck < curMatch);
  ptr0^ := 0;
  ptr1^ := 0;
end;

{ UPDATE_maxLen }
function UpdateMaxLen(cur: PByte; d2, maxLen, lenLimit: LongWord): LongWord; inline;
var
  c, lim: PByte;
  diff: PtrInt;
begin
  diff := -PtrInt(d2);
  c := cur + maxLen;
  lim := cur + lenLimit;
  while (c <> lim) and (c[diff] = c^) do Inc(c);
  Result := LongWord(c - cur);
end;

{ Bt2_MatchFinder_GetMatches }
function Bt2GetMatches(p: PMatchFinder; distances: PLongWord): PLongWord;
var
  hv, curMatch, lenLimit: LongWord;
  cur: PByte;
begin
  lenLimit := p^.lenLimit;
  if lenLimit < 2 then begin MfMovePos(p); Exit(distances); end;
  cur := p^.buffer;
  hv := cur[0] or (LongWord(cur[1]) shl 8);
  curMatch := p^.hash[hv];
  p^.hash[hv] := p^.pos;
  distances := BtGetMatchesSpec(lenLimit, curMatch, p^.pos, p^.buffer, p^.son,
    p^.cyclicBufferPos, p^.cyclicBufferSize, p^.cutValue, distances, 1);
  MfMovePos(p);
  Result := distances;
end;

{ Bt3_MatchFinder_GetMatches }
function Bt3GetMatches(p: PMatchFinder; distances: PLongWord): PLongWord;
var
  hv, h2, d2, pos, mmm, maxLen, curMatch, lenLimit, temp: LongWord;
  cur: PByte;
  hash: PLongWord;
begin
  lenLimit := p^.lenLimit;
  if lenLimit < 3 then begin MfMovePos(p); Exit(distances); end;
  cur := p^.buffer;
  temp := p^.crc[cur[0]] xor cur[1];
  h2 := temp and (kHash2Size - 1);
  hv := (temp xor (LongWord(cur[2]) shl 8)) and p^.hashMask;
  hash := p^.hash;
  pos := p^.pos;
  d2 := LongWord(pos - hash[h2]);
  curMatch := hash[kFix3HashSize + hv];
  hash[h2] := pos;
  hash[kFix3HashSize + hv] := pos;
  mmm := p^.cyclicBufferSize;
  if pos < mmm then mmm := pos;
  maxLen := 2;
  if (d2 < mmm) and ((cur - d2)^ = cur^) then
  begin
    maxLen := UpdateMaxLen(cur, d2, maxLen, lenLimit);
    distances[0] := maxLen;
    distances[1] := d2 - 1;
    Inc(distances, 2);
    if maxLen = lenLimit then
    begin
      BtSkipMatchesSpec(lenLimit, curMatch, p^.pos, p^.buffer, p^.son,
        p^.cyclicBufferPos, p^.cyclicBufferSize, p^.cutValue);
      MfMovePos(p);
      Exit(distances);
    end;
  end;
  distances := BtGetMatchesSpec(lenLimit, curMatch, p^.pos, p^.buffer, p^.son,
    p^.cyclicBufferPos, p^.cyclicBufferSize, p^.cutValue, distances, maxLen);
  MfMovePos(p);
  Result := distances;
end;

{ Bt4_MatchFinder_GetMatches y Hc4_MatchFinder_GetMatches comparten la cabecera. }
function Bt4GetMatches(p: PMatchFinder; distances: PLongWord): PLongWord;
var
  hv, h2, h3, d2, d3, pos, mmm, maxLen, curMatch, lenLimit, temp: LongWord;
  cur: PByte;
  hash: PLongWord;
begin
  lenLimit := p^.lenLimit;
  if lenLimit < 4 then begin MfMovePos(p); Exit(distances); end;
  cur := p^.buffer;
  temp := p^.crc[cur[0]] xor cur[1];
  h2 := temp and (kHash2Size - 1);
  temp := temp xor (LongWord(cur[2]) shl 8);
  h3 := temp and (kHash3Size - 1);
  hv := (temp xor LongWord(p^.crc[cur[3]] shl kLzHash_CrcShift_1)) and p^.hashMask;
  hash := p^.hash;
  pos := p^.pos;
  d2 := LongWord(pos - hash[h2]);
  d3 := LongWord(pos - hash[kFix3HashSize + h3]);
  curMatch := hash[kFix4HashSize + hv];
  hash[h2] := pos;
  hash[kFix3HashSize + h3] := pos;
  hash[kFix4HashSize + hv] := pos;
  mmm := p^.cyclicBufferSize;
  if pos < mmm then mmm := pos;
  maxLen := 3;
  repeat
    if (d2 < mmm) and ((cur - d2)^ = cur^) then
    begin
      distances[0] := 2;
      distances[1] := d2 - 1;
      Inc(distances, 2);
      if (cur - d2)[2] = cur[2] then
      else if (d3 < mmm) and ((cur - d3)^ = cur^) then
      begin
        d2 := d3;
        distances[1] := d3 - 1;
        Inc(distances, 2);
      end
      else
        Break;
    end
    else if (d3 < mmm) and ((cur - d3)^ = cur^) then
    begin
      d2 := d3;
      distances[1] := d3 - 1;
      Inc(distances, 2);
    end
    else
      Break;
    maxLen := UpdateMaxLen(cur, d2, maxLen, lenLimit);
    distances[-2] := maxLen;
    if maxLen = lenLimit then
    begin
      BtSkipMatchesSpec(lenLimit, curMatch, p^.pos, p^.buffer, p^.son,
        p^.cyclicBufferPos, p^.cyclicBufferSize, p^.cutValue);
      MfMovePos(p);
      Exit(distances);
    end;
    Break;
  until True;
  distances := BtGetMatchesSpec(lenLimit, curMatch, p^.pos, p^.buffer, p^.son,
    p^.cyclicBufferPos, p^.cyclicBufferSize, p^.cutValue, distances, maxLen);
  MfMovePos(p);
  Result := distances;
end;

function Hc4GetMatches(p: PMatchFinder; distances: PLongWord): PLongWord;
var
  hv, h2, h3, d2, d3, pos, mmm, maxLen, curMatch, lenLimit, temp: LongWord;
  cur: PByte;
  hash: PLongWord;
begin
  lenLimit := p^.lenLimit;
  if lenLimit < 4 then begin MfMovePos(p); Exit(distances); end;
  cur := p^.buffer;
  temp := p^.crc[cur[0]] xor cur[1];
  h2 := temp and (kHash2Size - 1);
  temp := temp xor (LongWord(cur[2]) shl 8);
  h3 := temp and (kHash3Size - 1);
  hv := (temp xor LongWord(p^.crc[cur[3]] shl kLzHash_CrcShift_1)) and p^.hashMask;
  hash := p^.hash;
  pos := p^.pos;
  d2 := LongWord(pos - hash[h2]);
  d3 := LongWord(pos - hash[kFix3HashSize + h3]);
  curMatch := hash[kFix4HashSize + hv];
  hash[h2] := pos;
  hash[kFix3HashSize + h3] := pos;
  hash[kFix4HashSize + hv] := pos;
  mmm := p^.cyclicBufferSize;
  if pos < mmm then mmm := pos;
  maxLen := 3;
  repeat
    if (d2 < mmm) and ((cur - d2)^ = cur^) then
    begin
      distances[0] := 2;
      distances[1] := d2 - 1;
      Inc(distances, 2);
      if (cur - d2)[2] = cur[2] then
      else if (d3 < mmm) and ((cur - d3)^ = cur^) then
      begin
        d2 := d3;
        distances[1] := d3 - 1;
        Inc(distances, 2);
      end
      else
        Break;
    end
    else if (d3 < mmm) and ((cur - d3)^ = cur^) then
    begin
      d2 := d3;
      distances[1] := d3 - 1;
      Inc(distances, 2);
    end
    else
      Break;
    maxLen := UpdateMaxLen(cur, d2, maxLen, lenLimit);
    distances[-2] := maxLen;
    if maxLen = lenLimit then
    begin
      p^.son[p^.cyclicBufferPos] := curMatch;
      MfMovePos(p);
      Exit(distances);
    end;
    Break;
  until True;
  distances := HcGetMatchesSpec(lenLimit, curMatch, p^.pos, p^.buffer, p^.son,
    p^.cyclicBufferPos, p^.cyclicBufferSize, p^.cutValue, distances, maxLen);
  MfMovePos(p);
  Result := distances;
end;

{ Bt2_MatchFinder_Skip }
procedure Bt2Skip(p: PMatchFinder; num: LongWord);
var
  hv, curMatch: LongWord;
  cur: PByte;
begin
  repeat
    if p^.lenLimit < 2 then
      MfMovePos(p)
    else
    begin
      cur := p^.buffer;
      hv := cur[0] or (LongWord(cur[1]) shl 8);
      curMatch := p^.hash[hv];
      p^.hash[hv] := p^.pos;
      BtSkipMatchesSpec(p^.lenLimit, curMatch, p^.pos, p^.buffer, p^.son,
        p^.cyclicBufferPos, p^.cyclicBufferSize, p^.cutValue);
      MfMovePos(p);
    end;
    Dec(num);
  until num = 0;
end;

{ Bt3_MatchFinder_Skip }
procedure Bt3Skip(p: PMatchFinder; num: LongWord);
var
  hv, h2, curMatch, temp: LongWord;
  cur: PByte;
  hash: PLongWord;
begin
  repeat
    if p^.lenLimit < 3 then
      MfMovePos(p)
    else
    begin
      cur := p^.buffer;
      temp := p^.crc[cur[0]] xor cur[1];
      h2 := temp and (kHash2Size - 1);
      hv := (temp xor (LongWord(cur[2]) shl 8)) and p^.hashMask;
      hash := p^.hash;
      curMatch := hash[kFix3HashSize + hv];
      hash[h2] := p^.pos;
      hash[kFix3HashSize + hv] := p^.pos;
      BtSkipMatchesSpec(p^.lenLimit, curMatch, p^.pos, p^.buffer, p^.son,
        p^.cyclicBufferPos, p^.cyclicBufferSize, p^.cutValue);
      MfMovePos(p);
    end;
    Dec(num);
  until num = 0;
end;

{ Bt4_MatchFinder_Skip }
procedure Bt4Skip(p: PMatchFinder; num: LongWord);
var
  hv, h2, h3, curMatch, temp: LongWord;
  cur: PByte;
  hash: PLongWord;
begin
  repeat
    if p^.lenLimit < 4 then
      MfMovePos(p)
    else
    begin
      cur := p^.buffer;
      temp := p^.crc[cur[0]] xor cur[1];
      h2 := temp and (kHash2Size - 1);
      temp := temp xor (LongWord(cur[2]) shl 8);
      h3 := temp and (kHash3Size - 1);
      hv := (temp xor LongWord(p^.crc[cur[3]] shl kLzHash_CrcShift_1)) and p^.hashMask;
      hash := p^.hash;
      curMatch := hash[kFix4HashSize + hv];
      hash[h2] := p^.pos;
      hash[kFix3HashSize + h3] := p^.pos;
      hash[kFix4HashSize + hv] := p^.pos;
      BtSkipMatchesSpec(p^.lenLimit, curMatch, p^.pos, p^.buffer, p^.son,
        p^.cyclicBufferPos, p^.cyclicBufferSize, p^.cutValue);
      MfMovePos(p);
    end;
    Dec(num);
  until num = 0;
end;

{ Hc4_MatchFinder_Skip (HC_SKIP_HEADER / HC_SKIP_FOOTER) }
procedure Hc4Skip(p: PMatchFinder; num: LongWord);
var
  cur: PByte;
  hash, son: PLongWord;
  pos, num2, rem, hv, h2, h3, temp, curMatch: LongWord;
begin
  repeat
    if p^.lenLimit < 4 then
    begin
      MfMovePos(p);
      Dec(num);
      Continue;
    end;
    pos := p^.pos;
    num2 := num;
    rem := LongWord(p^.posLimit - pos);
    if num2 >= rem then num2 := rem;
    Dec(num, num2);
    son := p^.son + p^.cyclicBufferPos;
    p^.cyclicBufferPos := p^.cyclicBufferPos + num2;
    cur := p^.buffer;
    hash := p^.hash;
    repeat
      temp := p^.crc[cur[0]] xor cur[1];
      h2 := temp and (kHash2Size - 1);
      temp := temp xor (LongWord(cur[2]) shl 8);
      h3 := temp and (kHash3Size - 1);
      hv := (temp xor LongWord(p^.crc[cur[3]] shl kLzHash_CrcShift_1)) and p^.hashMask;
      curMatch := hash[kFix4HashSize + hv];
      hash[h2] := pos;
      hash[kFix3HashSize + h3] := pos;
      hash[kFix4HashSize + hv] := pos;
      Inc(cur);
      pos := LongWord(pos + 1);
      son^ := curMatch;
      Inc(son);
      Dec(num2);
    until num2 = 0;
    p^.buffer := cur;
    p^.pos := pos;
    if pos = p^.posLimit then MfCheckLimits(p);
  until num = 0;
end;

{ ====================================================================== }
{ Codificador (LzmaEnc.c)                                                  }
{ ====================================================================== }

{ GetPosSlot2 (BSR2_RET): pos >= 2 }
function CalcPosSlot2(pos: LongWord): LongWord; inline;
var
  zz: LongWord;
begin
  zz := BsrDWord(pos) - 1;
  Result := zz + zz + (pos shr zz);
end;

{ GetPosSlot }
function CalcPosSlot(pos: LongWord): LongWord; inline;
begin
  if pos < 2 then Result := pos else Result := CalcPosSlot2(pos);
end;

{ ---------- CRangeEnc ---------- }

{ RangeEnc_FlushStream }
procedure TLzmaEnc.RcFlushStream;
var
  num: SizeInt;
begin
  num := rcBuf - PByte(@rcBufBase[0]);
  if num > 0 then OnWrite(@rcBufBase[0], num);
  Inc(rcProcessed, num);
  rcBuf := @rcBufBase[0];
end;

{ RangeEnc_ShiftLow }
procedure TLzmaEnc.RcShiftLow;
var
  low, high: LongWord;
begin
  low := LongWord(rcLow);
  high := LongWord(rcLow shr 32);
  rcLow := LongWord(low shl 8);
  if (low < LongWord($FF000000)) or (high <> 0) then
  begin
    rcBuf^ := Byte(rcCache + high);
    Inc(rcBuf);
    rcCache := low shr 24;
    if rcBuf = rcBufLim then RcFlushStream;
    if rcCacheSize = 0 then Exit;
    high := high + $FF;
    repeat
      rcBuf^ := Byte(high);
      Inc(rcBuf);
      if rcBuf = rcBufLim then RcFlushStream;
      Dec(rcCacheSize);
    until rcCacheSize = 0;
    Exit;
  end;
  Inc(rcCacheSize);
end;

{ RC_BIT (versión con rama; mismo resultado que la versión sin ramas del SDK) }
procedure TLzmaEnc.RcBit(prob: PProb; bit: LongWord);
var
  ttt, newBound: LongWord;
begin
  ttt := prob^;
  newBound := (rcRange shr kNumBitModelTotalBits) * ttt;
  if bit = 0 then
  begin
    rcRange := newBound;
    prob^ := TProb(ttt + ((kBitModelTotal - ttt) shr kNumMoveBits));
  end
  else
  begin
    rcLow := rcLow + newBound;
    rcRange := rcRange - newBound;
    prob^ := TProb(ttt - (ttt shr kNumMoveBits));
  end;
  if rcRange < kTopValue then
  begin
    rcRange := LongWord(rcRange shl 8);
    RcShiftLow;
  end;
end;

{ LitEnc_Encode }
procedure TLzmaEnc.LitEncode(probs: PProb; sym: LongWord);
var
  bit: LongWord;
begin
  sym := sym or $100;
  repeat
    bit := (sym shr 7) and 1;
    RcBit(probs + (sym shr 8), bit);
    sym := sym shl 1;
  until sym >= $10000;
end;

{ LitEnc_EncodeMatched }
procedure TLzmaEnc.LitEncodeMatched(probs: PProb; sym, matchByte: LongWord);
var
  offs, bit: LongWord;
  prob: PProb;
begin
  offs := $100;
  sym := sym or $100;
  repeat
    matchByte := matchByte shl 1;
    prob := probs + (offs + (matchByte and offs) + (sym shr 8));
    bit := (sym shr 7) and 1;
    sym := sym shl 1;
    offs := offs and not (matchByte xor sym);
    RcBit(prob, bit);
  until sym >= $10000;
end;

{ RcTree_ReverseEncode }
procedure TLzmaEnc.RcTreeReverseEncode(probs: PProb; numBits, sym: LongWord);
var
  m, bit: LongWord;
begin
  m := 1;
  repeat
    bit := sym and 1;
    sym := sym shr 1;
    RcBit(probs + m, bit);
    m := (m shl 1) or bit;
    Dec(numBits);
  until numBits = 0;
end;

{ LenEnc_Encode: low[0] = choice, low[8] = choice2; árboles low/mid en low[posState*16 + ...] }
procedure TLzmaEnc.LenEncEncode(p: PLenEnc; sym, posState: LongWord);
var
  probs: PProb;
  m, bit: LongWord;
begin
  probs := @p^.low[0];
  if sym >= kLenNumLowSymbols then
  begin
    RcBit(probs, 1);
    Inc(probs, kLenNumLowSymbols);
    if sym >= kLenNumLowSymbols * 2 then
    begin
      RcBit(probs, 1);
      LitEncode(@p^.high[0], sym - kLenNumLowSymbols * 2);
      Exit;
    end;
    Dec(sym, kLenNumLowSymbols);
  end;
  RcBit(probs, 0);
  Inc(probs, posState shl (1 + kLenNumLowBits));
  bit := sym shr 2; RcBit(probs + 1, bit); m := 2 + bit;
  bit := (sym shr 1) and 1; RcBit(probs + m, bit); m := (m shl 1) + bit;
  bit := sym and 1; RcBit(probs + m, bit);
end;

{ ---------- precios ---------- }

{ LzmaEnc_InitPriceTables }
procedure InitPriceTables(var ProbPrices: array of LongWord);
var
  i, j, w, bitCount: LongWord;
begin
  for i := 0 to (kBitModelTotal shr kNumMoveReducingBits) - 1 do
  begin
    w := (i shl kNumMoveReducingBits) + (1 shl (kNumMoveReducingBits - 1));
    bitCount := 0;
    for j := 0 to kNumBitPriceShiftBits - 1 do
    begin
      w := w * w;
      bitCount := bitCount shl 1;
      while w >= (LongWord(1) shl 16) do
      begin
        w := w shr 1;
        Inc(bitCount);
      end;
    end;
    ProbPrices[i] := (LongWord(kNumBitModelTotalBits) shl kNumBitPriceShiftBits) - 15 - bitCount;
  end;
end;


function TLzmaEnc.LitPrice(probs: PProb; sym: LongWord): LongWord;
var
  bit: LongWord;
begin
  Result := 0;
  sym := sym or $100;
  repeat
    bit := sym and 1;
    sym := sym shr 1;
    if bit = 0 then Inc(Result, ProbPrices[probs[sym] shr 4])
    else Inc(Result, ProbPrices[(probs[sym] xor (kBitModelTotal - 1)) shr 4]);
  until sym < 2;
end;

{ LitEnc_Matched_GetPrice }
function TLzmaEnc.LitMatchedPrice(probs: PProb; sym, matchByte: LongWord): LongWord;
var
  offs, prob: LongWord;
begin
  Result := 0;
  offs := $100;
  sym := sym or $100;
  repeat
    matchByte := matchByte shl 1;
    prob := probs[offs + (matchByte and offs) + (sym shr 8)];
    if ((sym shr 7) and 1) = 0 then Inc(Result, ProbPrices[prob shr 4])
    else Inc(Result, ProbPrices[(prob xor (kBitModelTotal - 1)) shr 4]);
    sym := sym shl 1;
    offs := offs and not (matchByte xor sym);
  until sym >= $10000;
end;

{ GET_PRICE / GET_PRICE_0 / GET_PRICE_1 }
function TLzmaEnc.GP(prob, bit: LongWord): LongWord;
begin
  if bit <> 0 then prob := prob xor (kBitModelTotal - 1);
  Result := ProbPrices[prob shr kNumMoveReducingBits];
end;

function TLzmaEnc.GP0(prob: LongWord): LongWord;
begin
  Result := ProbPrices[prob shr kNumMoveReducingBits];
end;

function TLzmaEnc.GP1(prob: LongWord): LongWord;
begin
  Result := ProbPrices[(prob xor (kBitModelTotal - 1)) shr kNumMoveReducingBits];
end;

{ SetPrices_3 }
procedure TLzmaEnc.SetPrices3(probs: PProb; startPrice: LongWord; prices: PLongWord);
var
  i, pr, prob: LongWord;
begin
  i := 0;
  while i < 8 do
  begin
    pr := startPrice;
    Inc(pr, GP(probs[1], i shr 2));
    Inc(pr, GP(probs[2 + (i shr 2)], (i shr 1) and 1));
    prob := probs[4 + (i shr 1)];
    prices[i] := pr + GP0(prob);
    prices[i + 1] := pr + GP1(prob);
    Inc(i, 2);
  end;
end;

{ LenPriceEnc_UpdateTables }
procedure TLzmaEnc.LenPriceUpdateTables(p: PLenPriceEnc; numPosStates: LongWord; enc: PLenEnc);
var
  a, b, c, prob, posState, i, sym, pr, bit: LongWord;
  prices: PLongWord;
  probs: PProb;
begin
  prob := enc^.low[0];
  b := GP1(prob);
  a := GP0(prob);
  c := b + GP0(enc^.low[kLenNumLowSymbols]);
  for posState := 0 to numPosStates - 1 do
  begin
    prices := @p^.prices[posState][0];
    probs := @enc^.low[posState shl (1 + kLenNumLowBits)];
    SetPrices3(probs, a, prices);
    SetPrices3(probs + kLenNumLowSymbols, c, prices + kLenNumLowSymbols);
  end;
  i := p^.tableSize;
  if i > kLenNumLowSymbols * 2 then
  begin
    probs := @enc^.high[0];
    prices := @p^.prices[0][kLenNumLowSymbols * 2];
    i := (i - (kLenNumLowSymbols * 2 - 1)) shr 1;
    b := b + GP1(enc^.low[kLenNumLowSymbols]);
    repeat
      Dec(i);
      sym := i + (1 shl (kLenNumHighBits - 1));
      pr := b;
      repeat
        bit := sym and 1;
        sym := sym shr 1;
        Inc(pr, GP(probs[sym], bit));
      until sym < 2;
      prob := probs[i + (1 shl (kLenNumHighBits - 1))];
      prices[i * 2] := pr + GP0(prob);
      prices[i * 2 + 1] := pr + GP1(prob);
    until i = 0;
    for posState := 1 to numPosStates - 1 do
      Move(p^.prices[0][kLenNumLowSymbols * 2], p^.prices[posState][kLenNumLowSymbols * 2],
        (p^.tableSize - kLenNumLowSymbols * 2) * SizeOf(LongWord));
  end;
end;

{ MOVE_POS }
procedure TLzmaEnc.MovePos(num: LongWord);
begin
  Inc(FAdditionalOffset, num);
  SkipF(@mf, num);
end;

{ ReadMatchDistances }
function TLzmaEnc.ReadMatchDistances(out numPairsRes: LongWord): LongWord;
var
  numPairs, len, numAvail: LongWord;
  d: PLongWord;
  p1, p2, lim: PByte;
  dif: PtrInt;
begin
  Inc(FAdditionalOffset);
  FNumAvail := MfAvail(@mf);
  d := GetMatchesF(@mf, @FMatches[0]);
  numPairs := LongWord(d - PLongWord(@FMatches[0]));
  numPairsRes := numPairs;
  if numPairs = 0 then Exit(0);
  len := FMatches[numPairs - 2];
  if len <> numFastBytes then Exit(len);
  numAvail := FNumAvail;
  if numAvail > LZMA_MATCH_LEN_MAX then numAvail := LZMA_MATCH_LEN_MAX;
  p1 := mf.buffer - 1;
  p2 := p1 + len;
  dif := -1 - PtrInt(FMatches[numPairs - 1]);
  lim := p1 + numAvail;
  while (p2 <> lim) and (p2^ = p2[dif]) do Inc(p2);
  Result := LongWord(p2 - p1);
end;

{ LIT_PROBS }
function TLzmaEnc.LitProbsPtr(pos, prevByte: LongWord): PProb;
begin
  Result := litProbs + PtrUInt(3) * ((LongWord((pos shl 8) + prevByte) and lpMask) shl lc);
end;

{ GetPrice_ShortRep }
function TLzmaEnc.PriceShortRep(state, posState: LongWord): LongWord;
begin
  Result := GP0(isRepG0[state]) + GP0(isRep0Long[state][posState]);
end;

{ GetPrice_Rep_0 }
function TLzmaEnc.PriceRep0(state, posState: LongWord): LongWord;
begin
  Result := GP1(isMatch[state][posState]) + GP1(isRep0Long[state][posState])
    + GP1(isRep[state]) + GP0(isRepG0[state]);
end;

{ GetPrice_PureRep }
function TLzmaEnc.PricePureRep(repIndex, state, posState: LongWord): LongWord;
var
  prob: LongWord;
begin
  prob := isRepG0[state];
  if repIndex = 0 then
  begin
    Result := GP0(prob);
    Inc(Result, GP1(isRep0Long[state][posState]));
  end
  else
  begin
    Result := GP1(prob);
    prob := isRepG1[state];
    if repIndex = 1 then
      Inc(Result, GP0(prob))
    else
    begin
      Inc(Result, GP1(prob));
      Inc(Result, GP(isRepG2[state], repIndex - 2));
    end;
  end;
end;

{ Backward }
function TLzmaEnc.Backward(cur: LongWord): LongWord;
var
  wr, dist, len, extra: LongWord;
begin
  wr := cur + 1;
  FOptEnd := wr;
  while True do
  begin
    dist := opt[cur].dist;
    len := opt[cur].len;
    extra := opt[cur].extra;
    Dec(cur, len);
    if extra <> 0 then
    begin
      Dec(wr);
      opt[wr].len := len;
      Dec(cur, extra);
      len := extra;
      if extra = 1 then
      begin
        opt[wr].dist := dist;
        dist := MARK_LIT;
      end
      else
      begin
        opt[wr].dist := 0;
        Dec(len);
        Dec(wr);
        opt[wr].dist := MARK_LIT;
        opt[wr].len := 1;
      end;
    end;
    if cur = 0 then
    begin
      FBackRes := dist;
      FOptCur := wr;
      Exit(len);
    end;
    Dec(wr);
    opt[wr].dist := dist;
    opt[wr].len := len;
  end;
end;

function IsLitState(s: LongWord): Boolean; inline;
begin
  Result := s < 7;
end;

{ GetOptimum: parseo óptimo }
function TLzmaEnc.GetOptimum(position: LongWord): LongWord;
var
  last, cur: LongWord;
  reps: array[0..3] of LongWord;
  repLens: array[0..3] of LongWord;
  matches: PLongWord;
  numAvail, numPairs, mainLen, repMaxIndex, i, posState, len, repLen: LongWord;
  matchPrice, repMatchPrice, shortRepPrice, pr, pr2, normalMatchPrice, dist: LongWord;
  data, data2: PByte;
  curByte, matchByte: LongWord;
  probs: PProb;
  o, curOpt, nextOpt, prevOpt: POptimal;
  offs, lenToPosState, slot: LongWord;
  numAvailFull, newLen, prev, state, startLen, litPr: LongWord;
  nextIsLit: Boolean;
  b0, j, best, delta, temp, limit, state2, posState2, offset, len2, repIndex, prob, posSlot, lenNorm: LongWord;
begin
  FOptCur := 0;
  FOptEnd := 0;
  if FAdditionalOffset = 0 then
    mainLen := ReadMatchDistances(numPairs)
  else
  begin
    mainLen := FLongestMatchLen;
    numPairs := FNumPairs;
  end;
  numAvail := FNumAvail;
  if numAvail < 2 then
  begin
    FBackRes := MARK_LIT;
    Exit(1);
  end;
  if numAvail > LZMA_MATCH_LEN_MAX then numAvail := LZMA_MATCH_LEN_MAX;
  data := mf.buffer - 1;
  repMaxIndex := 0;
  for i := 0 to LZMA_NUM_REPS - 1 do
  begin
    reps[i] := FReps[i];
    data2 := data - reps[i];
    if (data[0] <> data2[0]) or (data[1] <> data2[1]) then
    begin
      repLens[i] := 0;
      Continue;
    end;
    len := 2;
    while (len < numAvail) and (data[len] = data2[len]) do Inc(len);
    repLens[i] := len;
    if len > repLens[repMaxIndex] then repMaxIndex := i;
    if len = LZMA_MATCH_LEN_MAX then Break;
  end;
  if repLens[repMaxIndex] >= numFastBytes then
  begin
    FBackRes := repMaxIndex;
    len := repLens[repMaxIndex];
    MovePos(len - 1);
    Exit(len);
  end;
  matches := @FMatches[0];
  if mainLen >= numFastBytes then
  begin
    FBackRes := matches[numPairs - 1] + LZMA_NUM_REPS;
    MovePos(mainLen - 1);
    Exit(mainLen);
  end;
  curByte := data^;
  matchByte := (data - reps[0])^;
  last := repLens[repMaxIndex];
  if last <= mainLen then last := mainLen;
  if (last < 2) and (curByte <> matchByte) then
  begin
    FBackRes := MARK_LIT;
    Exit(1);
  end;
  opt[0].state := FState;
  posState := position and pbMask;
  probs := LitProbsPtr(position, (data - 1)^);
  if not IsLitState(FState) then
    pr := LitMatchedPrice(probs, curByte, matchByte)
  else
    pr := LitPrice(probs, curByte);
  opt[1].price := GP0(isMatch[FState][posState]) + pr;
  opt[1].dist := MARK_LIT;
  opt[1].extra := 0;
  matchPrice := GP1(isMatch[FState][posState]);
  repMatchPrice := matchPrice + GP1(isRep[FState]);
  if (matchByte = curByte) and (repLens[0] = 0) then
  begin
    shortRepPrice := repMatchPrice + PriceShortRep(FState, posState);
    if shortRepPrice < opt[1].price then
    begin
      opt[1].price := shortRepPrice;
      opt[1].dist := 0;
      opt[1].extra := 0;
    end;
    if last < 2 then
    begin
      FBackRes := opt[1].dist;
      Exit(1);
    end;
  end;
  opt[1].len := 1;
  opt[0].reps[0] := reps[0];
  opt[0].reps[1] := reps[1];
  opt[0].reps[2] := reps[2];
  opt[0].reps[3] := reps[3];

  // ---------- REP ----------
  for i := 0 to LZMA_NUM_REPS - 1 do
  begin
    repLen := repLens[i];
    if repLen < 2 then Continue;
    pr := repMatchPrice + PricePureRep(i, FState, posState);
    repeat
      pr2 := pr + repLenEnc.prices[posState][repLen - LZMA_MATCH_LEN_MIN];
      o := @opt[repLen];
      if pr2 < o^.price then
      begin
        o^.price := pr2;
        o^.len := repLen;
        o^.dist := i;
        o^.extra := 0;
      end;
      Dec(repLen);
    until repLen < 2;
  end;

  // ---------- MATCH ----------
  len := repLens[0] + 1;
  if len <= mainLen then
  begin
    offs := 0;
    normalMatchPrice := matchPrice + GP0(isRep[FState]);
    if len < 2 then
      len := 2
    else
      while len > matches[offs] do Inc(offs, 2);
    while True do
    begin
      dist := matches[offs + 1];
      pr := normalMatchPrice + lenEnc.prices[posState][len - LZMA_MATCH_LEN_MIN];
      if len < kNumLenToPosStates + 1 then lenToPosState := len - 2 else lenToPosState := kNumLenToPosStates - 1;
      if dist < kNumFullDistances then
        Inc(pr, distancesPrices[lenToPosState][dist and (kNumFullDistances - 1)])
      else
      begin
        slot := CalcPosSlot2(dist);
        Inc(pr, alignPrices[dist and kAlignMask]);
        Inc(pr, posSlotPrices[lenToPosState][slot]);
      end;
      o := @opt[len];
      if pr < o^.price then
      begin
        o^.price := pr;
        o^.len := len;
        o^.dist := dist + LZMA_NUM_REPS;
        o^.extra := 0;
      end;
      if len = matches[offs] then
      begin
        Inc(offs, 2);
        if offs = numPairs then Break;
      end;
      Inc(len);
    end;
  end;

  cur := 0;

  // ---------- Optimal Parsing ----------
  while True do
  begin
    Inc(cur);
    if cur = last then Break;

    if cur >= kNumOpts - 64 then
    begin
      pr := opt[cur].price;
      best := cur;
      for j := cur + 1 to last do
      begin
        pr2 := opt[j].price;
        if pr >= pr2 then
        begin
          pr := pr2;
          best := j;
        end;
      end;
      delta := best - cur;
      if delta <> 0 then MovePos(delta);
      cur := best;
      Break;
    end;

    newLen := ReadMatchDistances(numPairs);
    if newLen >= numFastBytes then
    begin
      FNumPairs := numPairs;
      FLongestMatchLen := newLen;
      Break;
    end;

    curOpt := @opt[cur];
    Inc(position);
    prev := cur - curOpt^.len;

    if curOpt^.len = 1 then
    begin
      state := opt[prev].state;
      if curOpt^.dist = 0 then
        state := kShortRepNextStates[state]
      else
        state := kLiteralNextStates[state];
    end
    else
    begin
      dist := curOpt^.dist;
      if curOpt^.extra <> 0 then
      begin
        Dec(prev, curOpt^.extra);
        state := kState_RepAfterLit;
        if curOpt^.extra = 1 then
          if dist < LZMA_NUM_REPS then state := kState_RepAfterLit else state := kState_MatchAfterLit;
      end
      else
      begin
        state := opt[prev].state;
        if dist < LZMA_NUM_REPS then
          state := kRepNextStates[state]
        else
          state := kMatchNextStates[state];
      end;
      prevOpt := @opt[prev];
      b0 := prevOpt^.reps[0];
      if dist < LZMA_NUM_REPS then
      begin
        if dist = 0 then
        begin
          reps[0] := b0;
          reps[1] := prevOpt^.reps[1];
          reps[2] := prevOpt^.reps[2];
          reps[3] := prevOpt^.reps[3];
        end
        else
        begin
          reps[1] := b0;
          b0 := prevOpt^.reps[1];
          if dist = 1 then
          begin
            reps[0] := b0;
            reps[2] := prevOpt^.reps[2];
            reps[3] := prevOpt^.reps[3];
          end
          else
          begin
            reps[2] := b0;
            reps[0] := prevOpt^.reps[dist];
            reps[3] := prevOpt^.reps[dist xor 1];
          end;
        end;
      end
      else
      begin
        reps[0] := dist - LZMA_NUM_REPS + 1;
        reps[1] := b0;
        reps[2] := prevOpt^.reps[1];
        reps[3] := prevOpt^.reps[2];
      end;
    end;

    curOpt^.state := state;
    curOpt^.reps[0] := reps[0];
    curOpt^.reps[1] := reps[1];
    curOpt^.reps[2] := reps[2];
    curOpt^.reps[3] := reps[3];

    data := mf.buffer - 1;
    curByte := data^;
    matchByte := (data - reps[0])^;
    posState := position and pbMask;

    prob := isMatch[state][posState];
    matchPrice := curOpt^.price + GP1(prob);
    litPr := curOpt^.price + GP0(prob);

    nextOpt := @opt[cur + 1];
    nextIsLit := False;

    if ((nextOpt^.price < kInfinityPrice) and (matchByte = curByte)) or (litPr > nextOpt^.price) then
      litPr := 0
    else
    begin
      probs := LitProbsPtr(position, (data - 1)^);
      if not IsLitState(state) then
        Inc(litPr, LitMatchedPrice(probs, curByte, matchByte))
      else
        Inc(litPr, LitPrice(probs, curByte));
      if litPr < nextOpt^.price then
      begin
        nextOpt^.price := litPr;
        nextOpt^.len := 1;
        nextOpt^.dist := MARK_LIT;
        nextOpt^.extra := 0;
        nextIsLit := True;
      end;
    end;

    repMatchPrice := matchPrice + GP1(isRep[state]);

    numAvailFull := FNumAvail;
    temp := kNumOpts - 1 - cur;
    if numAvailFull > temp then numAvailFull := temp;

    // ---------- SHORT_REP ----------
    if IsLitState(state) and (matchByte = curByte) and (repMatchPrice < nextOpt^.price)
      and ((nextOpt^.len < 2) or (nextOpt^.dist <> 0)) then
    begin
      shortRepPrice := repMatchPrice + PriceShortRep(state, posState);
      if shortRepPrice < nextOpt^.price then
      begin
        nextOpt^.price := shortRepPrice;
        nextOpt^.len := 1;
        nextOpt^.dist := 0;
        nextOpt^.extra := 0;
        nextIsLit := False;
      end;
    end;

    if numAvailFull < 2 then Continue;
    if numAvailFull <= numFastBytes then numAvail := numAvailFull else numAvail := numFastBytes;

    // ---------- LIT : REP_0 ----------
    if (not nextIsLit) and (litPr <> 0) and (matchByte <> curByte) and (numAvailFull > 2) then
    begin
      data2 := data - reps[0];
      if (data[1] = data2[1]) and (data[2] = data2[2]) then
      begin
        limit := numFastBytes + 1;
        if limit > numAvailFull then limit := numAvailFull;
        len := 3;
        while (len < limit) and (data[len] = data2[len]) do Inc(len);
        state2 := kLiteralNextStates[state];
        posState2 := (position + 1) and pbMask;
        pr := litPr + PriceRep0(state2, posState2);
        offset := cur + len;
        if last < offset then last := offset;
        Dec(len);
        pr2 := pr + repLenEnc.prices[posState2][len - LZMA_MATCH_LEN_MIN];
        o := @opt[offset];
        if pr2 < o^.price then
        begin
          o^.price := pr2;
          o^.len := len;
          o^.dist := 0;
          o^.extra := 1;
        end;
      end;
    end;

    startLen := 2;

    // ---------- REP ----------
    for repIndex := 0 to LZMA_NUM_REPS - 1 do
    begin
      data2 := data - reps[repIndex];
      if (data[0] <> data2[0]) or (data[1] <> data2[1]) then Continue;
      len := 2;
      while (len < numAvail) and (data[len] = data2[len]) do Inc(len);
      offset := cur + len;
      if last < offset then last := offset;
      len2 := len;
      pr := repMatchPrice + PricePureRep(repIndex, state, posState);
      repeat
        pr2 := pr + repLenEnc.prices[posState][len2 - LZMA_MATCH_LEN_MIN];
        o := @opt[cur + len2];
        if pr2 < o^.price then
        begin
          o^.price := pr2;
          o^.len := len2;
          o^.dist := repIndex;
          o^.extra := 0;
        end;
        Dec(len2);
      until len2 < 2;

      if repIndex = 0 then startLen := len + 1;

      // ---------- REP : LIT : REP_0 ----------
      len2 := len + 1;
      limit := len2 + numFastBytes;
      if limit > numAvailFull then limit := numAvailFull;
      Inc(len2, 2);
      if (len2 <= limit) and (data[len2 - 2] = data2[len2 - 2]) and (data[len2 - 1] = data2[len2 - 1]) then
      begin
        state2 := kRepNextStates[state];
        posState2 := (position + len) and pbMask;
        Inc(pr, repLenEnc.prices[posState][len - LZMA_MATCH_LEN_MIN]
          + GP0(isMatch[state2][posState2])
          + LitMatchedPrice(LitProbsPtr(position + len, data[len - 1]), data[len], data2[len]));
        state2 := kState_LitAfterRep;
        posState2 := (posState2 + 1) and pbMask;
        Inc(pr, PriceRep0(state2, posState2));
        while (len2 < limit) and (data[len2] = data2[len2]) do Inc(len2);
        Dec(len2, len);
        offset := cur + len + len2;
        if last < offset then last := offset;
        Dec(len2);
        pr2 := pr + repLenEnc.prices[posState2][len2 - LZMA_MATCH_LEN_MIN];
        o := @opt[offset];
        if pr2 < o^.price then
        begin
          o^.price := pr2;
          o^.len := len2;
          o^.extra := len + 1;
          o^.dist := repIndex;
        end;
      end;
    end;

    // ---------- MATCH ----------
    if newLen > numAvail then
    begin
      newLen := numAvail;
      numPairs := 0;
      while newLen > matches[numPairs] do Inc(numPairs, 2);
      matches[numPairs] := newLen;
      Inc(numPairs, 2);
    end;

    if newLen >= startLen then
    begin
      normalMatchPrice := matchPrice + GP0(isRep[state]);
      offset := cur + newLen;
      if last < offset then last := offset;
      offs := 0;
      while startLen > matches[offs] do Inc(offs, 2);
      dist := matches[offs + 1];
      posSlot := 0;
      if dist >= kNumFullDistances then posSlot := CalcPosSlot2(dist);
      len := startLen;
      while True do
      begin
        pr := normalMatchPrice + lenEnc.prices[posState][len - LZMA_MATCH_LEN_MIN];
        lenNorm := len - 2;
        if lenNorm >= kNumLenToPosStates - 1 then lenNorm := kNumLenToPosStates - 1;
        if dist < kNumFullDistances then
          Inc(pr, distancesPrices[lenNorm][dist and (kNumFullDistances - 1)])
        else
          Inc(pr, posSlotPrices[lenNorm][posSlot] + alignPrices[dist and kAlignMask]);
        o := @opt[cur + len];
        if pr < o^.price then
        begin
          o^.price := pr;
          o^.len := len;
          o^.dist := dist + LZMA_NUM_REPS;
          o^.extra := 0;
        end;

        if len = matches[offs] then
        begin
          // MATCH : LIT : REP_0
          data2 := data - dist - 1;
          len2 := len + 1;
          limit := len2 + numFastBytes;
          if limit > numAvailFull then limit := numAvailFull;
          Inc(len2, 2);
          if (len2 <= limit) and (data[len2 - 2] = data2[len2 - 2]) and (data[len2 - 1] = data2[len2 - 1]) then
          begin
            while (len2 < limit) and (data[len2] = data2[len2]) do Inc(len2);
            Dec(len2, len);
            state2 := kMatchNextStates[state];
            posState2 := (position + len) and pbMask;
            Inc(pr, GP0(isMatch[state2][posState2]));
            Inc(pr, LitMatchedPrice(LitProbsPtr(position + len, data[len - 1]), data[len], data2[len]));
            state2 := kState_LitAfterMatch;
            posState2 := (posState2 + 1) and pbMask;
            Inc(pr, PriceRep0(state2, posState2));
            offset := cur + len + len2;
            if last < offset then last := offset;
            Dec(len2);
            pr2 := pr + repLenEnc.prices[posState2][len2 - LZMA_MATCH_LEN_MIN];
            o := @opt[offset];
            if pr2 < o^.price then
            begin
              o^.price := pr2;
              o^.len := len2;
              o^.extra := len + 1;
              o^.dist := dist + LZMA_NUM_REPS;
            end;
          end;
          Inc(offs, 2);
          if offs = numPairs then Break;
          dist := matches[offs + 1];
          if dist >= kNumFullDistances then posSlot := CalcPosSlot2(dist);
        end;
        Inc(len);
      end;
    end;
  end;

  repeat
    opt[last].price := kInfinityPrice;
    Dec(last);
  until last = 0;

  Result := Backward(cur);
end;

function ChangePair(smallDist, bigDist: LongWord): Boolean; inline;
begin
  Result := (bigDist shr 7) > smallDist;
end;

{ GetOptimumFast }
function TLzmaEnc.GetOptimumFast: LongWord;
var
  numAvail, mainDist, mainLen, numPairs, repIndex, repLen, i, len, dist2, len1, newDist, limit: LongWord;
  data, data2: PByte;
begin
  if FAdditionalOffset = 0 then
    mainLen := ReadMatchDistances(numPairs)
  else
  begin
    mainLen := FLongestMatchLen;
    numPairs := FNumPairs;
  end;
  numAvail := FNumAvail;
  FBackRes := MARK_LIT;
  if numAvail < 2 then Exit(1);
  if numAvail > LZMA_MATCH_LEN_MAX then numAvail := LZMA_MATCH_LEN_MAX;
  data := mf.buffer - 1;
  repLen := 0;
  repIndex := 0;
  for i := 0 to LZMA_NUM_REPS - 1 do
  begin
    data2 := data - FReps[i];
    if (data[0] <> data2[0]) or (data[1] <> data2[1]) then Continue;
    len := 2;
    while (len < numAvail) and (data[len] = data2[len]) do Inc(len);
    if len >= numFastBytes then
    begin
      FBackRes := i;
      MovePos(len - 1);
      Exit(len);
    end;
    if len > repLen then
    begin
      repIndex := i;
      repLen := len;
    end;
  end;
  if mainLen >= numFastBytes then
  begin
    FBackRes := FMatches[numPairs - 1] + LZMA_NUM_REPS;
    MovePos(mainLen - 1);
    Exit(mainLen);
  end;
  mainDist := 0;
  if mainLen >= 2 then
  begin
    mainDist := FMatches[numPairs - 1];
    while numPairs > 2 do
    begin
      if mainLen <> FMatches[numPairs - 4] + 1 then Break;
      dist2 := FMatches[numPairs - 3];
      if not ChangePair(dist2, mainDist) then Break;
      Dec(numPairs, 2);
      Dec(mainLen);
      mainDist := dist2;
    end;
    if (mainLen = 2) and (mainDist >= $80) then mainLen := 1;
  end;
  if repLen >= 2 then
    if (repLen + 1 >= mainLen)
      or ((repLen + 2 >= mainLen) and (mainDist >= (1 shl 9)))
      or ((repLen + 3 >= mainLen) and (mainDist >= (1 shl 15))) then
    begin
      FBackRes := repIndex;
      MovePos(repLen - 1);
      Exit(repLen);
    end;
  if (mainLen < 2) or (numAvail <= 2) then Exit(1);

  len1 := ReadMatchDistances(FNumPairs);
  FLongestMatchLen := len1;
  if len1 >= 2 then
  begin
    newDist := FMatches[FNumPairs - 1];
    if ((len1 >= mainLen) and (newDist < mainDist))
      or ((len1 = mainLen + 1) and not ChangePair(mainDist, newDist))
      or (len1 > mainLen + 1)
      or ((len1 + 1 >= mainLen) and (mainLen >= 3) and ChangePair(newDist, mainDist)) then
      Exit(1);
  end;

  data := mf.buffer - 1;
  for i := 0 to LZMA_NUM_REPS - 1 do
  begin
    data2 := data - FReps[i];
    if (data[0] <> data2[0]) or (data[1] <> data2[1]) then Continue;
    limit := mainLen - 1;
    len := 2;
    while True do
    begin
      if len >= limit then Exit(1);
      if data[len] <> data2[len] then Break;
      Inc(len);
    end;
  end;

  FBackRes := mainDist + LZMA_NUM_REPS;
  if mainLen <> 2 then MovePos(mainLen - 2);
  Result := mainLen;
end;

{ WriteEndMarker }
procedure TLzmaEnc.WriteEndMarker(posState: LongWord);
var
  probs: PProb;
  m, numBits: LongWord;
begin
  RcBit(@isMatch[FState][posState], 1);
  RcBit(@isRep[FState], 0);
  FState := kMatchNextStates[FState];
  LenEncEncode(@lenProbs, 0, posState);
  probs := @posSlotEncoder[0][0];
  m := 1;
  repeat
    RcBit(probs + m, 1);
    m := (m shl 1) + 1;
  until m >= (1 shl kNumPosSlotBits);
  numBits := 30 - kNumAlignBits;
  repeat
    rcRange := rcRange shr 1;
    rcLow := rcLow + rcRange;
    if rcRange < kTopValue then
    begin
      rcRange := LongWord(rcRange shl 8);
      RcShiftLow;
    end;
    Dec(numBits);
  until numBits = 0;
  m := 1;
  repeat
    RcBit(@posAlignEncoder[m], 1);
    m := (m shl 1) + 1;
  until m >= kAlignTableSize;
end;

{ Flush }
procedure TLzmaEnc.Flush(nowPos: LongWord);
var
  i: Integer;
begin
  FFinished := True;
  if writeEndMark then WriteEndMarker(nowPos and pbMask);
  for i := 0 to 4 do RcShiftLow;   // RangeEnc_FlushData
  RcFlushStream;
end;

{ FillAlignPrices }
procedure TLzmaEnc.FillAlignPrices;
var
  i, pr, sym, m, bit, prob: LongWord;
  probs: PProb;
begin
  probs := @posAlignEncoder[0];
  for i := 0 to (kAlignTableSize div 2) - 1 do
  begin
    pr := 0;
    sym := i;
    m := 1;
    bit := sym and 1; sym := sym shr 1; Inc(pr, GP(probs[m], bit)); m := (m shl 1) + bit;
    bit := sym and 1; sym := sym shr 1; Inc(pr, GP(probs[m], bit)); m := (m shl 1) + bit;
    bit := sym and 1;                   Inc(pr, GP(probs[m], bit)); m := (m shl 1) + bit;
    prob := probs[m];
    alignPrices[i] := pr + GP0(prob);
    alignPrices[i + 8] := pr + GP1(prob);
  end;
end;

{ FillDistancesPrices }
procedure TLzmaEnc.FillDistancesPrices;
var
  tempPrices: array[0..kNumFullDistances - 1] of LongWord;
  i, lps, posSlot, footerBits, base, pr, m, sym, offset, bit, prob, slot, distTableSize2, delta, slotPrice: LongWord;
  probs: PProb;
  psp, dp: PLongWord;
begin
  matchPriceCount := 0;
  for i := kStartPosModelIndex div 2 to (kNumFullDistances div 2) - 1 do
  begin
    posSlot := CalcPosSlot2(i);
    footerBits := (posSlot shr 1) - 1;
    base := (2 or (posSlot and 1)) shl footerBits;
    probs := @posEncoders[base * 2];
    pr := 0;
    m := 1;
    sym := i;
    offset := LongWord(1) shl footerBits;
    Inc(base, i);
    if footerBits <> 0 then
      repeat
        bit := sym and 1;
        sym := sym shr 1;
        Inc(pr, GP(probs[m], bit));
        m := (m shl 1) + bit;
        Dec(footerBits);
      until footerBits = 0;
    prob := probs[m];
    tempPrices[base] := pr + GP0(prob);
    tempPrices[base + offset] := pr + GP1(prob);
  end;

  for lps := 0 to kNumLenToPosStates - 1 do
  begin
    distTableSize2 := (distTableSize + 1) shr 1;
    psp := @posSlotPrices[lps][0];
    probs := @posSlotEncoder[lps][0];
    for slot := 0 to distTableSize2 - 1 do
    begin
      sym := slot + (1 shl (kNumPosSlotBits - 1));
      bit := sym and 1; sym := sym shr 1; pr := GP(probs[sym], bit);
      bit := sym and 1; sym := sym shr 1; Inc(pr, GP(probs[sym], bit));
      bit := sym and 1; sym := sym shr 1; Inc(pr, GP(probs[sym], bit));
      bit := sym and 1; sym := sym shr 1; Inc(pr, GP(probs[sym], bit));
      bit := sym and 1; sym := sym shr 1; Inc(pr, GP(probs[sym], bit));
      prob := probs[slot + (1 shl (kNumPosSlotBits - 1))];
      psp[slot * 2] := pr + GP0(prob);
      psp[slot * 2 + 1] := pr + GP1(prob);
    end;
    delta := ((kEndPosModelIndex div 2 - 1) - kNumAlignBits) shl kNumBitPriceShiftBits;
    slot := kEndPosModelIndex div 2;
    while slot < distTableSize2 do
    begin
      Inc(psp[slot * 2], delta);
      Inc(psp[slot * 2 + 1], delta);
      Inc(delta, 1 shl kNumBitPriceShiftBits);
      Inc(slot);
    end;
    dp := @distancesPrices[lps][0];
    dp[0] := psp[0];
    dp[1] := psp[1];
    dp[2] := psp[2];
    dp[3] := psp[3];
    i := 4;
    while i < kNumFullDistances do
    begin
      slotPrice := psp[CalcPosSlot2(i)];
      dp[i] := slotPrice + tempPrices[i];
      dp[i + 1] := slotPrice + tempPrices[i + 1];
      Inc(i, 2);
    end;
  end;
end;

{ LzmaEnc_Init }
procedure TLzmaEnc.InitState;
var
  i: Integer;
begin
  FState := 0;
  FReps[0] := 1; FReps[1] := 1; FReps[2] := 1; FReps[3] := 1;
  // RangeEnc_Init
  rcRange := $FFFFFFFF;
  rcCache := 0;
  rcLow := 0;
  rcCacheSize := 0;
  rcBuf := @rcBufBase[0];
  rcBufLim := rcBuf + RC_BUF_SIZE;
  rcProcessed := 0;

  FillWord(posAlignEncoder, Length(posAlignEncoder), kProbInitValue);
  FillWord(isMatch, SizeOf(isMatch) div 2, kProbInitValue);
  FillWord(isRep0Long, SizeOf(isRep0Long) div 2, kProbInitValue);
  FillWord(isRep, Length(isRep), kProbInitValue);
  FillWord(isRepG0, Length(isRepG0), kProbInitValue);
  FillWord(isRepG1, Length(isRepG1), kProbInitValue);
  FillWord(isRepG2, Length(isRepG2), kProbInitValue);
  FillWord(posSlotEncoder, SizeOf(posSlotEncoder) div 2, kProbInitValue);
  FillWord(posEncoders, Length(posEncoders), kProbInitValue);
  FillWord(litProbs^, SizeInt($300) shl (lp + lc), kProbInitValue);
  FillWord(lenProbs, SizeOf(lenProbs) div 2, kProbInitValue);
  FillWord(repLenProbs, SizeOf(repLenProbs) div 2, kProbInitValue);

  FOptEnd := 0;
  FOptCur := 0;
  for i := 0 to kNumOpts - 1 do opt[i].price := kInfinityPrice;
  FAdditionalOffset := 0;
  pbMask := (LongWord(1) shl pb) - 1;
  lpMask := (LongWord($100) shl lp) - (LongWord($100) shr lc);
end;

{ LzmaEnc_InitPrices }
procedure TLzmaEnc.InitPrices;
begin
  if not fastMode then
  begin
    FillDistancesPrices;
    FillAlignPrices;
  end;
  lenEnc.tableSize := numFastBytes + 1 - LZMA_MATCH_LEN_MIN;
  repLenEnc.tableSize := lenEnc.tableSize;
  repLenEncCounter := REP_LEN_COUNT;
  LenPriceUpdateTables(@lenEnc, LongWord(1) shl pb, @lenProbs);
  LenPriceUpdateTables(@repLenEnc, LongWord(1) shl pb, @repLenProbs);
end;

{ LzmaEnc_SetProps + LzmaEnc_AllocAndInit + LzmaEnc_Prepare / LzmaEnc_MemPrepare }
constructor TLzmaEnc.Create(const P: TLzmaEncParams; AWriteEndMark: Boolean; ARead: TMfRead;
  AWrite: TEncWrite; DirectSrc: PByte; DirectLen: QWord);
var
  fb, i, mc: LongWord;
  d: QWord;
begin
  inherited Create;
  ValidateLzmaEncParams(P);
  MfConstruct(@mf);
  InitPriceTables(ProbPrices);
  OnWrite := AWrite;
  mf.Read := ARead;

  d := P.DictSize;
  if d > kLzmaMaxHistorySize then d := kLzmaMaxHistorySize;
  if DirectSrc <> nil then
  begin
    // reduceSize = srcLen (como 7-Zip): no cambia la salida, solo la memoria del match finder
    if d > DirectLen then
    begin
      d := DirectLen;
      if d < (1 shl 12) then d := 1 shl 12;
    end;
    mf.directInput := True;
    mf.buffer := DirectSrc;
    mf.directInputRem := DirectLen;
    mf.expectedDataSize := DirectLen;   // LzmaEnc_SetDataSize en LzmaEnc_MemPrepare
  end;
  dictSize := LongWord(d);

  if P.NumFastBytes < 5 then fb := 5
  else if P.NumFastBytes > LZMA_MATCH_LEN_MAX then fb := LZMA_MATCH_LEN_MAX
  else fb := P.NumFastBytes;
  numFastBytes := fb;
  lc := P.lc;
  lp := P.lp;
  pb := P.pb;
  fastMode := P.Algorithm = 0;
  writeEndMark := AWriteEndMark;
  case P.MatchFinder of
    mfBT2: begin mf.btMode := True; mf.numHashBytes := 2; end;
    mfBT3: begin mf.btMode := True; mf.numHashBytes := 3; end;
    mfBT4: begin mf.btMode := True; mf.numHashBytes := 4; end;
  else
    begin mf.btMode := False; mf.numHashBytes := 4; end;   // hc4 (y ht4 mapeado a hc4)
  end;
  // mc = 0: fórmula de LzmaEncProps_Normalize de FreeArc (usa fb sin recortar)
  mc := P.MatchFinderCycles;
  if mc = 0 then
    case P.MatchFinder of
      mfHT4: mc := LongWord(P.NumFastBytes) div 2;
      mfHC4: mc := 16 + LongWord(P.NumFastBytes) div 4;
    else
      mc := 16 + LongWord(P.NumFastBytes) div 2;
    end;
  if mc = 0 then mc := 1;
  mf.cutValue := mc;

  if mf.btMode then
  begin
    GetMatchesF := @Bt4GetMatches;
    SkipF := @Bt4Skip;
    if mf.numHashBytes = 2 then begin GetMatchesF := @Bt2GetMatches; SkipF := @Bt2Skip; end
    else if mf.numHashBytes = 3 then begin GetMatchesF := @Bt3GetMatches; SkipF := @Bt3Skip; end;
  end
  else
  begin
    GetMatchesF := @Hc4GetMatches;
    SkipF := @Hc4Skip;
  end;

  // LzmaEnc_AllocAndInit
  i := kEndPosModelIndex div 2;
  while (i < kDicLogSizeMax) and (dictSize > (LongWord(1) shl i)) do Inc(i);
  distTableSize := i * 2;
  FFinished := False;
  nowPos64 := 0;
  needInit := True;

  // LzmaEnc_Alloc
  SetLength(rcBufBase, RC_BUF_SIZE);
  lclp := lc + lp;
  litProbs := GetMem((SizeInt($300) * SizeOf(TProb)) shl lclp);
  d := dictSize;
  if (d = (QWord(2) shl 30)) or (d = (QWord(3) shl 30)) then Dec(d);
  MfCreate(@mf, LongWord(d), kNumOpts, numFastBytes, LZMA_MATCH_LEN_MAX + 1);

  InitState;
  InitPrices;
end;

destructor TLzmaEnc.Destroy;
begin
  MfFree(@mf);
  if litProbs <> nil then FreeMem(litProbs);
  inherited Destroy;
end;

function TLzmaEnc.AvailIn: QWord;
begin
  if needInit then Result := 0 else Result := MfAvail(@mf);
end;

{ LzmaEnc_CodeOneBlock (maxPackSize = 0): codifica ~128 KB o hasta el fin y hace Flush. }
procedure TLzmaEnc.CodeOneBlock;
var
  nowPos32, startPos32, dist, len, posState, oci, numPairs, st, posSlot, sym, bit, footerBits,
    base, pos2, m, processed: LongWord;
  probs, prob: PProb;
  data: PByte;
  curByte: LongWord;
begin
  if needInit then
  begin
    MfInit(@mf);
    needInit := False;
  end;
  if FFinished then Exit;

  nowPos32 := LongWord(nowPos64);
  startPos32 := nowPos32;

  if nowPos64 = 0 then
  begin
    if MfAvail(@mf) = 0 then
    begin
      Flush(nowPos32);
      Exit;
    end;
    ReadMatchDistances(numPairs);
    RcBit(@isMatch[0][0], 0);
    curByte := (mf.buffer - FAdditionalOffset)^;
    LitEncode(litProbs, curByte);
    Dec(FAdditionalOffset);
    Inc(nowPos32);
  end;

  if MfAvail(@mf) <> 0 then
    while True do
    begin
      if fastMode then
        len := GetOptimumFast
      else
      begin
        oci := FOptCur;
        if FOptEnd = oci then
          len := GetOptimum(nowPos32)
        else
        begin
          len := opt[oci].len;
          FBackRes := opt[oci].dist;
          FOptCur := oci + 1;
        end;
      end;

      posState := nowPos32 and pbMask;
      probs := @isMatch[FState][posState];
      dist := FBackRes;

      if dist = MARK_LIT then
      begin
        RcBit(probs, 0);
        data := mf.buffer - FAdditionalOffset;
        probs := LitProbsPtr(nowPos32, (data - 1)^);
        curByte := data^;
        st := FState;
        FState := kLiteralNextStates[st];
        if IsLitState(st) then
          LitEncode(probs, curByte)
        else
          LitEncodeMatched(probs, curByte, (data - FReps[0])^);
      end
      else
      begin
        RcBit(probs, 1);
        probs := @isRep[FState];
        if dist < LZMA_NUM_REPS then
        begin
          RcBit(probs, 1);
          probs := @isRepG0[FState];
          if dist = 0 then
          begin
            RcBit(probs, 0);
            probs := @isRep0Long[FState][posState];
            if len <> 1 then
              RcBit(probs, 1)
            else
            begin
              RcBit(probs, 0);
              FState := kShortRepNextStates[FState];
            end;
          end
          else
          begin
            RcBit(probs, 1);
            probs := @isRepG1[FState];
            if dist = 1 then
            begin
              RcBit(probs, 0);
              dist := FReps[1];
            end
            else
            begin
              RcBit(probs, 1);
              probs := @isRepG2[FState];
              if dist = 2 then
              begin
                RcBit(probs, 0);
                dist := FReps[2];
              end
              else
              begin
                RcBit(probs, 1);
                dist := FReps[3];
                FReps[3] := FReps[2];
              end;
              FReps[2] := FReps[1];
            end;
            FReps[1] := FReps[0];
            FReps[0] := dist;
          end;
          if len <> 1 then
          begin
            LenEncEncode(@repLenProbs, len - LZMA_MATCH_LEN_MIN, posState);
            Dec(repLenEncCounter);
            FState := kRepNextStates[FState];
          end;
        end
        else
        begin
          RcBit(probs, 0);
          FState := kMatchNextStates[FState];
          LenEncEncode(@lenProbs, len - LZMA_MATCH_LEN_MIN, posState);
          Dec(dist, LZMA_NUM_REPS);
          FReps[3] := FReps[2];
          FReps[2] := FReps[1];
          FReps[1] := FReps[0];
          FReps[0] := dist + 1;
          Inc(matchPriceCount);
          posSlot := CalcPosSlot(dist);
          sym := posSlot + (1 shl kNumPosSlotBits);
          if len < kNumLenToPosStates + 1 then probs := @posSlotEncoder[len - 2][0]
          else probs := @posSlotEncoder[kNumLenToPosStates - 1][0];
          repeat
            prob := probs + (sym shr kNumPosSlotBits);
            bit := (sym shr (kNumPosSlotBits - 1)) and 1;
            sym := sym shl 1;
            RcBit(prob, bit);
          until sym >= (1 shl (kNumPosSlotBits * 2));
          if dist >= kStartPosModelIndex then
          begin
            footerBits := (posSlot shr 1) - 1;
            if dist < kNumFullDistances then
            begin
              base := (2 or (posSlot and 1)) shl footerBits;
              RcTreeReverseEncode(@posEncoders[base], footerBits, dist);
            end
            else
            begin
              pos2 := LongWord((dist or $F) shl (32 - footerBits));
              repeat
                rcRange := rcRange shr 1;
                if (pos2 shr 31) <> 0 then rcLow := rcLow + rcRange;
                pos2 := LongWord(pos2 shl 1);
                if rcRange < kTopValue then
                begin
                  rcRange := LongWord(rcRange shl 8);
                  RcShiftLow;
                end;
              until pos2 = LongWord($F0000000);
              m := 1;
              bit := dist and 1; dist := dist shr 1; RcBit(@posAlignEncoder[m], bit); m := (m shl 1) + bit;
              bit := dist and 1; dist := dist shr 1; RcBit(@posAlignEncoder[m], bit); m := (m shl 1) + bit;
              bit := dist and 1; dist := dist shr 1; RcBit(@posAlignEncoder[m], bit); m := (m shl 1) + bit;
              bit := dist and 1;                     RcBit(@posAlignEncoder[m], bit);
            end;
          end;
        end;
      end;

      nowPos32 := LongWord(nowPos32 + len);
      Dec(FAdditionalOffset, len);

      if FAdditionalOffset = 0 then
      begin
        if not fastMode then
        begin
          if matchPriceCount >= 64 then
          begin
            FillAlignPrices;
            FillDistancesPrices;
            LenPriceUpdateTables(@lenEnc, LongWord(1) shl pb, @lenProbs);
          end;
          if repLenEncCounter <= 0 then
          begin
            repLenEncCounter := REP_LEN_COUNT;
            LenPriceUpdateTables(@repLenEnc, LongWord(1) shl pb, @repLenProbs);
          end;
        end;
        if MfAvail(@mf) = 0 then Break;
        processed := LongWord(nowPos32 - startPos32);
        if processed >= (1 shl 17) then
        begin
          Inc(nowPos64, processed);
          Exit;
        end;
      end;
    end;

  Inc(nowPos64, LongWord(nowPos32 - startPos32));
  Flush(nowPos32);
end;

{ ====================================================================== }
{ Parámetros (parse_LZMA de C_LZMA.cpp)                                    }
{ ====================================================================== }

function DefaultLzmaEncParams: TLzmaEncParams;
begin
  // LZMA_METHOD::LZMA_METHOD
  Result.DictSize := 64 shl 20;
  Result.HashSize := 0;
  Result.Algorithm := 1;
  Result.NumFastBytes := 32;
  Result.MatchFinder := mfHT4;
  Result.MatchFinderCycles := 0;
  Result.pb := 2;
  Result.lc := 3;
  Result.lp := 0;
end;

{ parseInt de Common.cpp: '=' opcional, solo dígitos }
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
    if n > QWord(High(Integer)) then Exit;
    Inc(i);
  end;
  if i <= Length(S) then Exit;
  V := Integer(n);
  Result := True;
end;

{ parseMem64 de Common.cpp: sufijo b/k/m/g; sin sufijo (o '^') = potencia de 2 }
function FaParseMem(const S: string; out V: QWord): Boolean;
var
  i: Integer;
  n: QWord;
  c: Char;
begin
  Result := False;
  V := 0;
  i := 1;
  if (i <= Length(S)) and (S[i] = '=') then Inc(i);
  if (i > Length(S)) or not (S[i] in ['0'..'9']) then Exit;
  n := 0;
  while (i <= Length(S)) and (S[i] in ['0'..'9']) do
  begin
    n := n * 10 + QWord(Ord(S[i]) - Ord('0'));
    if n > (QWord(1) shl 40) then Exit;
    Inc(i);
  end;
  if i <= Length(S) then c := S[i] else c := '^';
  case c of
    'b': V := n;
    'k': V := n shl 10;
    'm': V := n shl 20;
    'g': V := n shl 30;
    '^': begin if n > 62 then Exit; V := QWord(1) shl n; end;
  else
    Exit;
  end;
  Result := True;
end;

{ FindMatchFinder (strcasecmp) }
function FindMatchFinder(const S: string; out mf: TLzmaMatchFinder): Boolean;
var
  u: string;
begin
  u := LowerCase(S);
  Result := True;
  if u = 'bt2' then mf := mfBT2
  else if u = 'bt3' then mf := mfBT3
  else if u = 'bt4' then mf := mfBT4
  else if u = 'hc4' then mf := mfHC4
  else if u = 'ht4' then mf := mfHT4
  else Result := False;
end;

function ParseLzmaEncParams(const Params: TStringArray): TLzmaEncParams;
var
  k, n: Integer;
  p: string;
  optional, ok, mfSet: Boolean;
  m: QWord;
  f: TLzmaMatchFinder;
  R: TLzmaEncParams;

  procedure Profile(algo: Integer; defMf: TLzmaMatchFinder; fb, mc: Integer);
  begin
    R.Algorithm := algo;
    if not mfSet then begin R.MatchFinder := defMf; mfSet := True; end;
    R.NumFastBytes := fb;
    R.MatchFinderCycles := mc;
  end;

  function Unnamed: Boolean;
  begin
    // nombre de match finder, entero = numFastBytes, memoria = diccionario
    Result := True;
    if FindMatchFinder(p, f) then begin R.MatchFinder := f; mfSet := True; end
    else if FaParseInt(p, n) then R.NumFastBytes := n
    else if FaParseMem(p, m) then R.DictSize := m
    else Result := False;
  end;

begin
  if (Length(Params) = 0) or (Params[0] <> 'lzma') then
    raise ELzmaEncParams.Create('no es un método lzma');
  R := DefaultLzmaEncParams;
  mfSet := False;
  for k := 1 to High(Params) do
  begin
    p := Params[k];
    optional := (p <> '') and (p[1] = '*');
    if optional then Delete(p, 1, 1);
    ok := True;
    if p = '' then ok := False
    else if p[1] = 'd' then
    begin
      ok := FaParseMem(Copy(p, 2, MaxInt), m);
      if ok then R.DictSize := m;
    end
    else if p[1] = 'h' then
    begin
      if FaParseMem(Copy(p, 2, MaxInt), m) then R.HashSize := m
      else ok := Unnamed;          // "hc4", "ht4"
    end
    else if p[1] = 'a' then
    begin
      ok := FaParseInt(Copy(p, 2, MaxInt), n);
      if ok then R.Algorithm := n;
    end
    else if Copy(p, 1, 2) = 'fb' then
    begin
      ok := FaParseInt(Copy(p, 3, MaxInt), n);
      if ok then R.NumFastBytes := n;
    end
    else if Copy(p, 1, 2) = 'mc' then
    begin
      ok := FaParseInt(Copy(p, 3, MaxInt), n);
      if ok then R.MatchFinderCycles := n;
    end
    else if Copy(p, 1, 2) = 'lc' then
    begin
      ok := FaParseInt(Copy(p, 3, MaxInt), n);
      if ok then R.lc := n;
    end
    else if Copy(p, 1, 2) = 'lp' then
    begin
      ok := FaParseInt(Copy(p, 3, MaxInt), n);
      if ok then R.lp := n;
    end
    else if Copy(p, 1, 2) = 'pb' then
    begin
      ok := FaParseInt(Copy(p, 3, MaxInt), n);
      if ok then R.pb := n;
    end
    else if Copy(p, 1, 2) = 'mf' then
    begin
      if (Length(p) >= 3) and (p[3] = '=') then ok := FindMatchFinder(Copy(p, 4, MaxInt), f)
      else ok := FindMatchFinder(Copy(p, 3, MaxInt), f);
      if ok then begin R.MatchFinder := f; mfSet := True; end;
    end
    else if p = 'fastest' then Profile(0, mfHT4, 5, 1)
    else if p = 'fast' then Profile(0, mfHT4, 32, 0)
    else if p = 'normal' then Profile(1, mfHT4, 32, 0)
    else if p = 'max' then Profile(1, mfBT4, 128, 0)
    else if p = 'ultra' then Profile(1, mfBT4, 128, 128)
    else ok := Unnamed;
    if not ok and not optional then
      raise ELzmaEncParams.CreateFmt('parámetro lzma inválido: "%s"', [Params[k]]);
  end;
  if not mfSet then R.MatchFinder := mfHT4;   // match finder por defecto
  Result := R;
end;

procedure ValidateLzmaEncParams(const P: TLzmaEncParams);
begin
  if (P.lc < 0) or (P.lc > 8) or (P.lp < 0) or (P.lp > 4) or (P.pb < 0) or (P.pb > 4) then
    raise ELzmaEncParams.Create('lzma: lc/lp/pb fuera de rango (lc 0..8, lp 0..4, pb 0..4)');
  if P.DictSize = 0 then
    raise ELzmaEncParams.Create('lzma: diccionario nulo');
  if (P.Algorithm < 0) or (P.MatchFinderCycles < 0) then
    raise ELzmaEncParams.Create('lzma: parámetros negativos');
  if (Ord(P.MatchFinder) < Ord(Low(TLzmaMatchFinder))) or (Ord(P.MatchFinder) > Ord(High(TLzmaMatchFinder))) then
    raise ELzmaEncParams.Create('lzma: match finder desconocido');
end;

{ ====================================================================== }
{ TLzmaEncStage                                                            }
{ ====================================================================== }

constructor TLzmaEncStage.Create(ATarget: TOutStage; const P: TLzmaEncParams; WriteEndMark: Boolean);
begin
  // Todo lo que puede fallar (validación, memoria) va antes de adoptar ATarget: si el
  // constructor falla, FPC llama a Destroy y el destino se liberaría dos veces.
  FEnc := TLzmaEnc.Create(P, WriteEndMark, @ReadIn, @WriteOut, nil, 0);
  // El match finder puede adelantarse hasta ~2^17 + 2*(kNumOpts + 273) posiciones en un
  // CodeOneBlock, y lee cuando le quedan <= keepSizeAfter bytes: con este margen nunca
  // encuentra la entrada vacía antes de Finish.
  FThreshold := SizeInt(TLzmaEnc(FEnc).mf.keepSizeAfter) + (1 shl 17) + 4 * kNumOpts + 4 * LZMA_MATCH_LEN_MAX + 4096;
  inherited Create(ATarget);
end;

destructor TLzmaEncStage.Destroy;
begin
  FEnc.Free;
  inherited Destroy;
end;

function TLzmaEncStage.ReadIn(Buf: PByte; Size: SizeInt): SizeInt;
var
  n: SizeInt;
begin
  Result := 0;
  n := FPendLen - FPendPos;
  if n > 0 then
  begin
    if n > Size then n := Size;
    Move(FPend[FPendPos], Buf^, n);
    Inc(FPendPos, n);
    Inc(Result, n);
    Inc(Buf, n);
    Dec(Size, n);
  end;
  if (Size > 0) and (FExtLen > 0) then
  begin
    n := FExtLen;
    if n > Size then n := Size;
    Move(FExt^, Buf^, n);
    Inc(FExt, n);
    Dec(FExtLen, n);
    Inc(Result, n);
  end;
  if (Result = 0) and not FEof then
    raise Exception.Create('lzma: el match finder se quedó sin entrada (error interno)');
end;

procedure TLzmaEncStage.WriteOut(Buf: PByte; Size: SizeInt);
begin
  Emit(Buf, Size);
end;

procedure TLzmaEncStage.DoWrite(Buf: PByte; Count: SizeInt);
var
  n: SizeInt;
begin
  FExt := Buf;
  FExtLen := Count;
  try
    while not TLzmaEnc(FEnc).Finished
      and (SizeInt(TLzmaEnc(FEnc).AvailIn) + (FPendLen - FPendPos) + FExtLen >= FThreshold) do
      TLzmaEnc(FEnc).CodeOneBlock;
    if FExtLen > 0 then
    begin
      // guardar el resto (menos de FThreshold bytes en total)
      n := FPendLen - FPendPos;
      if (FPendPos > 0) and (n > 0) then Move(FPend[FPendPos], FPend[0], n);
      FPendPos := 0;
      FPendLen := n;
      if FPendLen + FExtLen > Length(FPend) then SetLength(FPend, FPendLen + FExtLen + 65536);
      Move(FExt^, FPend[FPendLen], FExtLen);
      Inc(FPendLen, FExtLen);
    end;
  finally
    FExt := nil;
    FExtLen := 0;
  end;
end;

procedure TLzmaEncStage.DoFinish;
begin
  FEof := True;
  while not TLzmaEnc(FEnc).Finished do TLzmaEnc(FEnc).CodeOneBlock;
  FPend := nil;
end;

{ ====================================================================== }
{ Memoria-a-memoria (LzmaEnc_MemEncode)                                    }
{ ====================================================================== }

type
  TMemOut = class
    Data: TBytes;
    Len: SizeInt;
    procedure Write(Buf: PByte; Size: SizeInt);
  end;

procedure TMemOut.Write(Buf: PByte; Size: SizeInt);
begin
  if Len + Size > Length(Data) then SetLength(Data, 2 * (Len + Size) + 4096);
  Move(Buf^, Data[Len], Size);
  Inc(Len, Size);
end;

function LzmaEncodeMem(Src: PByte; SrcLen: SizeInt; const P: TLzmaEncParams; WriteEndMark: Boolean): TBytes;
var
  o: TMemOut;
  e: TLzmaEnc;
  dummy: Byte;
begin
  if SrcLen < 0 then raise ELzmaEncParams.Create('lzma: tamaño negativo');
  if Src = nil then Src := @dummy;
  o := TMemOut.Create;
  e := nil;
  try
    SetLength(o.Data, SrcLen div 2 + 4096);
    e := TLzmaEnc.Create(P, WriteEndMark, nil, @o.Write, Src, QWord(SrcLen));
    while not e.Finished do e.CodeOneBlock;
    if e.nowPos64 <> QWord(SrcLen) then raise Exception.Create('lzma: error interno (tamaño)');
    Result := Copy(o.Data, 0, o.Len);
  finally
    e.Free;
    o.Free;
  end;
end;

end.
