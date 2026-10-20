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
  SysUtils, parc_outstream, parc_progress;

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
    { Hilos (no va en el string del método): 0 = automático (ThreadCount: PARC_THREADS o los
      núcleos), 1 = un hilo, >= 2 = match finder multihilo. Como FreeArc (mtMode = numThreads > 1
      y no fast), pero acá solo para bt4: los demás match finders siguen con un hilo. }
    NumThreads: Integer;
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
    // Multihilo: el hilo hash lee la entrada (ReadIn) mientras este hilo comprime
    FMt: Boolean;
    FInLock: TRTLCriticalSection;
    FInEvent: PRTLEvent;
    FInInit, FAbort, FWaiting: Boolean;
    FWant: SizeInt;
    FTotalIn: QWord;
    function ReadIn(Buf: PByte; Size: SizeInt): SizeInt;
    function ReadInMt(Buf: PByte; Size: SizeInt): SizeInt;
    procedure DoWriteMt(Buf: PByte; Count: SizeInt);
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

var
  { Solo para pruebas: umbral de normalización de las posiciones del match finder multihilo
    (kMtMaxValForNormalize del SDK). Con un valor chico (>= diccionario + 512 KB) se ejercita
    la normalización sin comprimir 4 GB; la salida no debe cambiar. }
  LzmaMtNormLimit: LongWord = $FFFFFFFF;
  { Solo para pruebas: cuántas veces arrancó el match finder multihilo. }
  LzmaMtStarts: LongInt = 0;

threadvar
  { En un hilo que ya es parte de una compresión paralela (los trabajos de 4x4), el modo
    automático usa un hilo: sin esto, cada bloque abriría 2 hilos y hasta 64 MB más. }
  LzmaSingleThreadHere: Boolean;

implementation

uses
  parc_parallel;


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
  kMtReadGrain = 1 shl 16;      // ReadInMt: bytes mínimos por despertar (salvo fin)

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
    mt: Pointer;                // PMtState con el match finder multihilo (si no, nil)
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
    FMt: Pointer;               // PMtState: match finder multihilo (bt4, NumThreads >= 2) o nil
    function CurAvail: LongWord; inline;
    procedure CodeOneBlockImpl;
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
    function IsMt: Boolean;
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
    if p^.blockSize > LongWord(High(SizeInt)) then raise EOutOfMemory.Create('lzma: not enough memory for the window');
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
    raise EOutOfMemory.Create('lzma: not enough memory for the match finder');
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
{ Largo de la coincidencia entre pb y cur a partir de len (sin pasar de lenLimit). Compara de
  a 8 bytes y ubica el primero distinto con bsf: el mismo resultado que el bucle de a byte del
  SDK, más rápido en coincidencias largas. Solo en little-endian (x86/x64). }
function MatchLen(pb, cur: PByte; len, lenLimit: LongWord): LongWord; inline;
{$IFDEF ENDIAN_LITTLE}
var
  x: QWord;
begin
  while len + 8 <= lenLimit do
  begin
    x := PQWord(pb + len)^ xor PQWord(cur + len)^;
    if x <> 0 then Exit(len + (BsfQWord(x) shr 3));
    Inc(len, 8);
  end;
{$ELSE}
begin
{$ENDIF}
  // (con <, no <>: igual cuando len <= lenLimit, y seguro si llega uno mayor)
  while (len < lenLimit) and (pb[len] = cur[len]) do Inc(len);
  Result := len;
end;

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
          len := MatchLen(pb, cur, len, lenLimit);
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
        len := MatchLen(pb, cur, len, lenLimit);
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
begin
  Result := MatchLen(cur - d2, cur, maxLen, lenLimit);
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
{ Match finder multihilo para bt4 (LzFindMt.c del SDK 26.03)               }
{                                                                          }
{ Dos hilos además del de compresión (LZ):                                 }
{   - HASH: lee la entrada, mueve el bloque de la ventana cuando hace      }
{     falta y, por bloques de hasta 128K posiciones, calcula con la tabla  }
{     hash de 4 bytes (la alta) la distancia a la posición anterior con el }
{     mismo hash ("heads"). Misma fórmula que Bt4GetMatches (la de PArc/   }
{     FreeArc, no la GetHeads4b del SDK 26.03).                            }
{   - BT: con esas distancias recorre e inserta en el árbol binario        }
{     (BtGetMatchesSpec con maxLen = 3) posición por posición y escribe    }
{     los pares en bloques de 64K u32: [n, avail, (n-1) u32 por posición]. }
{   - LZ (este): hash2/hash3 (el mismo "mixing" de Bt4GetMatches) y copia  }
{     del árbol solo los pares con len > el maxLen del mixing.             }
{ Salida idéntica byte a byte al finder de un hilo: BtGetMatchesSpec deja  }
{ el árbol igual que BtSkipMatchesSpec (el camino no depende de maxLen) y  }
{ sus pares con maxLen = m son justo los de maxLen = 3 con len > m; cada   }
{ tabla hash la actualiza un solo hilo, una vez por posición; el lenLimit  }
{ y los bytes disponibles son los de un hilo (el hilo hash lee hasta tener }
{ más de keepSizeAfter o el fin real del stream).                          }
{ Sincronización (como el SDK): por cada par productor/consumidor dos      }
{ semáforos (bloques libres / llenos) y una sección crítica que el         }
{ consumidor tiene tomada mientras usa punteros a la ventana; el hilo hash }
{ toma las dos para mover el bloque. El LZ la toma solo dentro de          }
{ CodeOneBlock (y la suelta mientras espera un bloque), así nunca queda    }
{ tomada entre llamadas ni se suelta desde otro hilo.                      }
{ Los hilos se crean al pedir el primer bloque y se paran y esperan en     }
{ Destroy (stopWriting + un bloque libre de más, como MtSync_StopWriting). }
{ ====================================================================== }

const
  kMtHashBlockSize = LongWord(1) shl 17;
  kMtHashNumBlocks = 2;
  kMtBtBlockSize = LongWord(1) shl 16;
  { Bloques BT: el SDK usa 16 (4 MB); con más, el hilo BT se adelanta más y el LZ espera menos
    cuando los dos se desparejan por tramos (div40, 64mb:bt4:128: 16 -> 0.8 s de espera del
    LZ, 256 -> 0.25 s). No cambia la salida. Se elige por diccionario (MtBtNumBlocks). }
  kMtBtNumBlocksMin = 16;
  kMtBtNumBlocksMax = 256;
  kMtHashBufferSize = kMtHashBlockSize * kMtHashNumBlocks;
  kMtCacheLine = 128;

type
  { Semáforo contador con un solo hilo que espera (cada uno tiene un único consumidor).
    RTLEvent es de auto-reset con memoria en Unix (isset + cond) y en Windows (CreateEvent
    auto-reset): un Set sin nadie esperando despierta al próximo WaitFor, así no se pierde. }
  TMtSem = record
    cs: TRTLCriticalSection;
    count: Integer;
    ev: PRTLEvent;
  end;

  TMtSync = record
    cs: TRTLCriticalSection;     // "buffer lock" del consumidor
    freeSem, filledSem: TMtSem;
    stopWriting: Boolean;
    created: Boolean;
    thread: TThreadID;
    numTaken: LongWord;          // bloques pedidos por el consumidor (índice del próximo)
  end;

  PMtState = ^TMtState;
  TMtState = record
    { LZ }
    lz: PMatchFinder;            // el mf del codificador: buffer = puntero actual, pos = lzPos
    btBuf: PLongWord;
    btBufPos, btBufPosLimit: PLongWord;
    btNumAvailBytes: LongWord;
    btNumBlocks: LongWord;       // potencia de 2
    started, failed: Boolean;
    initOk: Boolean;
    pad0: array[0..kMtCacheLine - 1] of Byte;
    btSync: TMtSync;
    pad1: array[0..kMtCacheLine - 1] of Byte;
    { BT }
    hashBuf: PLongWord;          // hashBuf + btBuf en un solo bloque
    hashBufPos, hashBufPosLimit, hashNumAvail: LongWord;
    son: PLongWord;
    matchMaxLen, pos, cyclicBufferPos, cyclicBufferSize, cutValue: LongWord;
    buffer: PByte;
    pad2: array[0..kMtCacheLine - 1] of Byte;
    hashSync: TMtSync;
    pad3: array[0..kMtCacheLine - 1] of Byte;
    { hash: el CMatchFinder "de verdad" (ventana, lectura, tabla hash alta) }
    hmf: TMatchFinder;
  end;

procedure MtSemInit(var s: TMtSem; n: Integer);
begin
  InitCriticalSection(s.cs);
  s.count := n;
  s.ev := RTLEventCreate;
end;

procedure MtSemDone(var s: TMtSem);
begin
  if s.ev = nil then Exit;
  RTLEventDestroy(s.ev);
  s.ev := nil;
  DoneCriticalSection(s.cs);
end;

procedure MtSemWait(var s: TMtSem);
begin
  EnterCriticalSection(s.cs);
  while s.count = 0 do
  begin
    LeaveCriticalSection(s.cs);
    RTLEventWaitFor(s.ev);
    EnterCriticalSection(s.cs);
  end;
  Dec(s.count);
  LeaveCriticalSection(s.cs);
end;

procedure MtSemRelease(var s: TMtSem);
begin
  EnterCriticalSection(s.cs);
  Inc(s.count);
  LeaveCriticalSection(s.cs);
  RTLEventSetEvent(s.ev);
end;

procedure MtSyncInit(var p: TMtSync; numBlocks: Integer);
begin
  InitCriticalSection(p.cs);
  MtSemInit(p.freeSem, numBlocks);
  MtSemInit(p.filledSem, 0);
  p.stopWriting := False;
  p.created := False;
  p.numTaken := 0;
end;

procedure MtSyncDone(var p: TMtSync);
begin
  if p.freeSem.ev = nil then Exit;
  MtSemDone(p.freeSem);
  MtSemDone(p.filledSem);
  DoneCriticalSection(p.cs);
end;

{ MtSync_GetNextBlock del lado consumidor. Se llama con p.cs tomada; la suelta mientras
  espera (el hilo hash puede mover la ventana) y la vuelve a tomar. first: el primer bloque
  (no hay uno anterior que liberar). Devuelve el índice del bloque. }
function MtSyncGetNextBlock(var p: TMtSync; first: Boolean): LongWord;
begin
  LeaveCriticalSection(p.cs);
  if first then
    Result := 0
  else
  begin
    Inc(p.numTaken);
    Result := p.numTaken;
    MtSemRelease(p.freeSem);
  end;
  MtSemWait(p.filledSem);
  EnterCriticalSection(p.cs);
end;

{ ---------- hilo HASH ---------- }

procedure MtGetHeads4(p: PByte; pos: LongWord; hash: PLongWord; hashMask: LongWord;
  heads: PLongWord; numHeads: LongWord; crc: PLongWord);
var
  crc0, crc1: array[0..255] of LongWord;
  i, v: LongWord;
begin
  // (crc[p0] xor p1 xor p2 shl 8 xor crc[p3] shl 5) and hashMask, con hashMask >= $FFFF
  for i := 0 to 255 do
  begin
    crc0[i] := crc[i] and hashMask;
    crc1[i] := LongWord(crc[i] shl kLzHash_CrcShift_1) and hashMask;
  end;
  while numHeads <> 0 do
  begin
    v := crc0[p[0]] xor crc1[p[3]] xor p[1] xor (LongWord(p[2]) shl 8);
    Inc(p);
    heads^ := LongWord(pos - hash[v]);
    Inc(heads);
    hash[v] := pos;
    pos := LongWord(pos + 1);
    Dec(numHeads);
  end;
end;

function MtHashThreadFunc(param: Pointer): PtrInt;
var
  mt: PMtState;
  mf: PMatchFinder;
  blockIndex, num, subValue: LongWord;
  heads: PLongWord;
  before: PByte;
  offset: PtrInt;
begin
  Result := 0;
  mt := PMtState(param);
  mf := @mt^.hmf;
  // MatchFinder_Init_HighHash (la baja la inicializa el hilo LZ)
  FillDWord((mf^.hash + mf^.fixedHashSize)^, SizeInt(mf^.hashMask) + 1, 0);
  blockIndex := 0;
  while True do
  begin
    if MfNeedMove(mf) then
    begin
      EnterCriticalSection(mt^.btSync.cs);
      EnterCriticalSection(mt^.hashSync.cs);
      before := mf^.buffer;
      MfMoveBlock(mf);
      offset := before - mf^.buffer;
      mt^.lz^.buffer := mt^.lz^.buffer - offset;
      mt^.buffer := mt^.buffer - offset;
      LeaveCriticalSection(mt^.hashSync.cs);
      LeaveCriticalSection(mt^.btSync.cs);
      Continue;
    end;
    MtSemWait(mt^.hashSync.freeSem);
    if mt^.hashSync.stopWriting then Break;
    // MatchFinder_ReadIfRequired
    if mf^.keepSizeAfter >= MfAvail(mf) then
      try
        MfReadBlock(mf);
      except
        // No debería pasar (ReadIn no falla en multihilo): se corta el stream y el hilo LZ
        // lanza el error al tomar el próximo bloque
        mt^.failed := True;
        mf^.streamEndWasReached := True;
      end;
    heads := mt^.hashBuf + (blockIndex and (kMtHashNumBlocks - 1)) * kMtHashBlockSize;
    Inc(blockIndex);
    num := MfAvail(mf);
    heads[0] := 2;
    heads[1] := num;
    { heads[1] < numHashBytes: fin del stream; el hilo BT avanza esos bytes sin hash y los
      bloques siguientes son (2, 0) }
    if num >= mf^.numHashBytes then
    begin
      num := num - mf^.numHashBytes + 1;
      if num > kMtHashBlockSize - 2 then num := kMtHashBlockSize - 2;
      if mf^.pos > LzmaMtNormLimit - num then
      begin
        subValue := LongWord(mf^.pos - mf^.historySize - 1);
        mf^.pos := LongWord(mf^.pos - subValue);
        mf^.streamPos := LongWord(mf^.streamPos - subValue);
        MfNormalize3(subValue, mf^.hash + mf^.fixedHashSize, PtrUInt(mf^.hashMask) + 1);
      end;
      heads[0] := 2 + num;
      MtGetHeads4(mf^.buffer, mf^.pos, mf^.hash + mf^.fixedHashSize, mf^.hashMask, heads + 2,
        num, @mf^.crc[0]);
    end;
    mf^.pos := LongWord(mf^.pos + num);
    Inc(mf^.buffer, num);
    MtSemRelease(mt^.hashSync.filledSem);
  end;
end;

{ ---------- hilo BT ---------- }

{ BtGetMatches (versión por posición, sin GetMatchesSpecN_2). Con hashSync.cs tomada. }
procedure MtBtGetMatches(mt: PMtState; d: PLongWord);
var
  numProcessed, curPos, limit, avail, availSum, bi, k, size, size2, pos, cyc, cycSize,
    lenLimit, subValue, delta, curMatch, num, processed: LongWord;
  h, sd: PLongWord;
  cur: PByte;
begin
  numProcessed := 0;
  curPos := 2;
  limit := kMtBtBlockSize - mt^.matchMaxLen * 2;
  d[1] := mt^.hashNumAvail;
  cycSize := mt^.cyclicBufferSize;
  while curPos < limit do
  begin
    if mt^.hashBufPos = mt^.hashBufPosLimit then
    begin
      bi := MtSyncGetNextBlock(mt^.hashSync, mt^.hashBufPosLimit = 0);
      k := (bi and (kMtHashNumBlocks - 1)) * kMtHashBlockSize;
      h := mt^.hashBuf + k;
      avail := h[1];
      mt^.hashBufPosLimit := k + h[0];
      mt^.hashNumAvail := avail;
      mt^.hashBufPos := k + 2;
      availSum := numProcessed + avail;
      if availSum < numProcessed then availSum := LongWord($FFFFFFFF);
      d[1] := availSum;
      if avail >= 4 then Continue;
      // fin del stream: avail bytes sin hash, sin tocar pos ni el árbol
      mt^.hashNumAvail := 0;
      d[0] := curPos + avail;
      Inc(d, curPos);
      while avail <> 0 do
      begin
        d^ := 0;
        Inc(d);
        Dec(avail);
      end;
      Exit;
    end;
    size := mt^.hashBufPosLimit - mt^.hashBufPos;
    pos := mt^.pos;
    cyc := mt^.cyclicBufferPos;
    lenLimit := mt^.matchMaxLen;
    if lenLimit >= mt^.hashNumAvail then lenLimit := mt^.hashNumAvail;
    size2 := mt^.hashNumAvail - lenLimit + 1;
    if size2 < size then size := size2;
    size2 := cycSize - cyc;
    if size2 < size then size := size2;
    if pos > LzmaMtNormLimit - size then
    begin
      subValue := LongWord(pos - cycSize);
      pos := LongWord(pos - subValue);
      mt^.pos := pos;
      MfNormalize3(subValue, mt^.son, PtrUInt(cycSize) * 2);
    end;
    cur := mt^.buffer;
    processed := 0;
    while (curPos < limit) and (size <> 0) do
    begin
      delta := mt^.hashBuf[mt^.hashBufPos];
      Inc(mt^.hashBufPos);
      // distancia fuera de la ventana (o entrada vacía / normalizada): sin candidato, como
      // el cmCheck de un hilo
      if (delta < cycSize) and (delta < pos) then curMatch := LongWord(pos - delta) else curMatch := 0;
      sd := d + curPos;
      num := LongWord(BtGetMatchesSpec(lenLimit, curMatch, pos, cur, mt^.son, cyc, cycSize,
        mt^.cutValue, sd + 1, 3) - sd);
      sd^ := num - 1;
      Inc(curPos, num);
      Inc(cyc);
      pos := LongWord(pos + 1);
      Inc(cur);
      Inc(processed);
      Dec(size);
    end;
    Inc(numProcessed, processed);
    Dec(mt^.hashNumAvail, processed);
    mt^.pos := pos;
    mt^.buffer := cur;
    if cyc = cycSize then cyc := 0;
    mt^.cyclicBufferPos := cyc;
  end;
  d[0] := curPos;
end;

function MtBtThreadFunc(param: Pointer): PtrInt;
var
  mt: PMtState;
  blockIndex: LongWord;
begin
  Result := 0;
  mt := PMtState(param);
  blockIndex := 0;
  while True do
  begin
    MtSemWait(mt^.btSync.freeSem);
    if mt^.btSync.stopWriting then Break;
    EnterCriticalSection(mt^.hashSync.cs);
    MtBtGetMatches(mt, mt^.btBuf + (blockIndex and (mt^.btNumBlocks - 1)) * kMtBtBlockSize);
    LeaveCriticalSection(mt^.hashSync.cs);
    Inc(blockIndex);
    MtSemRelease(mt^.btSync.filledSem);
  end;
end;

{ ---------- ciclo de vida ---------- }

{ ¿Hay hilos? En Unix hace falta cthreads en el programa (sin él BeginThread aborta con el
  error 232): el gestor de hilos vacío no tiene InitManager. Sin hilos: un hilo. }
function MtThreadsAvailable: Boolean;
{$IFDEF UNIX}
var
  tm: TThreadManager;
begin
  GetThreadManager(tm);
  Result := Assigned(tm.InitManager);
end;
{$ELSE}
begin
  Result := True;
end;
{$ENDIF}

{ Bloques BT para un diccionario: el buffer (bloques * 256 KB) ~ del tamaño del diccionario,
  entre 4 MB y 64 MB (en memoria total es < 10% de lo que ya usa bt4). }
function MtBtNumBlocks(dictSize: LongWord): LongWord;
begin
  Result := kMtBtNumBlocksMin;
  while (Result < kMtBtNumBlocksMax) and (QWord(Result) * kMtBtBlockSize * 4 < dictSize) do
    Result := Result * 2;
end;

{ MatchFinderMt_Create (después de MfCreate con los keep ampliados). Lanza EOutOfMemory. }
function MtCreate(lz: PMatchFinder; btNumBlocks: LongWord): PMtState;
begin
  Result := AllocMem(SizeOf(TMtState));
  try
    Result^.btNumBlocks := btNumBlocks;
    Result^.hashBuf := GetMem(SizeInt(kMtHashBufferSize + btNumBlocks * kMtBtBlockSize) * SizeOf(LongWord));
    Result^.btBuf := Result^.hashBuf + kMtHashBufferSize;
    MtSyncInit(Result^.hashSync, kMtHashNumBlocks);
    MtSyncInit(Result^.btSync, btNumBlocks);
    Result^.initOk := True;
  except
    if Result^.hashBuf <> nil then FreeMem(Result^.hashBuf);
    FreeMem(Result);
    raise;
  end;
  Result^.lz := lz;
  lz^.mt := Result;
end;

{ Para los hilos (MtSync_StopWriting + exit) y libera. El lector de la entrada no debe quedar
  bloqueado: el llamador ya marcó EOF o abortó la lectura. }
procedure MtDestroy(mt: PMtState);
begin
  if mt = nil then Exit;
  if mt^.btSync.created then
  begin
    // el hilo BT ve stopWriting en su próximo Wait(free); para terminar el bloque en curso
    // puede necesitar bloques del hilo hash, que sigue vivo
    mt^.btSync.stopWriting := True;
    MtSemRelease(mt^.btSync.freeSem);
    WaitForThreadTerminate(mt^.btSync.thread, 0);
    CloseThread(mt^.btSync.thread);
    mt^.btSync.created := False;
  end;
  if mt^.hashSync.created then
  begin
    mt^.hashSync.stopWriting := True;
    MtSemRelease(mt^.hashSync.freeSem);
    WaitForThreadTerminate(mt^.hashSync.thread, 0);
    CloseThread(mt^.hashSync.thread);
    mt^.hashSync.created := False;
  end;
  if mt^.initOk then
  begin
    MtSyncDone(mt^.btSync);
    MtSyncDone(mt^.hashSync);
  end;
  if mt^.lz <> nil then mt^.lz^.mt := nil;
  if mt^.hashBuf <> nil then FreeMem(mt^.hashBuf);
  FreeMem(mt);
end;

{ MatchFinderMt_Init: sin leer datos (los lee el hilo hash). lz = el mf del codificador,
  ya creado; hmf es una copia (mismos hash/son/bufBase). }
procedure MtInit(mt: PMtState);
var
  lz, mf: PMatchFinder;
begin
  lz := mt^.lz;
  mt^.hmf := lz^;
  mt^.hmf.mt := nil;
  mf := @mt^.hmf;
  // MatchFinder_Init_4
  if not mf^.directInput then mf^.buffer := mf^.bufBase;
  mf^.pos := 1;
  mf^.streamPos := 1;
  mf^.streamEndWasReached := False;
  // MatchFinder_Init_LowHash
  FillDWord(mf^.hash^, mf^.fixedHashSize, 0);
  // LZ
  lz^.buffer := mf^.buffer;
  lz^.pos := 1;
  mt^.btBufPos := nil;
  mt^.btBufPosLimit := nil;
  mt^.btNumAvailBytes := 0;
  // BT
  mt^.hashBufPos := 0;
  mt^.hashBufPosLimit := 0;
  mt^.hashNumAvail := 0;
  mt^.son := mf^.son;
  mt^.matchMaxLen := mf^.matchMaxLen;
  mt^.pos := 1;
  mt^.cyclicBufferPos := 1;
  mt^.cyclicBufferSize := mf^.cyclicBufferSize;
  mt^.cutValue := mf^.cutValue;
  mt^.buffer := mf^.buffer;
end;

procedure MtStart(mt: PMtState);
var
  tid: TThreadID;
begin
  mt^.started := True;
  InterLockedIncrement(LzmaMtStarts);
  mt^.hashSync.thread := BeginThread(@MtHashThreadFunc, mt, tid);
  if mt^.hashSync.thread = TThreadID(0) then raise Exception.Create('lzma: could not create a thread');
  mt^.hashSync.created := True;
  mt^.btSync.thread := BeginThread(@MtBtThreadFunc, mt, tid);
  if mt^.btSync.thread = TThreadID(0) then raise Exception.Create('lzma: could not create a thread');
  mt^.btSync.created := True;
end;

{ MatchFinderMt_GetNextBlock_Bt. Con btSync.cs tomada (dentro de CodeOneBlock). }
function MtGetNextBlockBt(mt: PMtState): LongWord;
var
  bi, numItems, subValue: LongWord;
  bt: PLongWord;
  first: Boolean;
  lz: PMatchFinder;
begin
  first := not mt^.started;
  if first then MtStart(mt);
  bi := MtSyncGetNextBlock(mt^.btSync, first);
  if mt^.failed then raise Exception.Create('lzma: error al leer la entrada (match finder)');
  bt := mt^.btBuf + (bi and (mt^.btNumBlocks - 1)) * kMtBtBlockSize;
  numItems := bt[0];
  if (numItems < 2) or (numItems > kMtBtBlockSize) then
    raise Exception.Create('lzma: error interno (match finder multihilo)');
  mt^.btBufPosLimit := bt + numItems;
  mt^.btNumAvailBytes := bt[1];
  mt^.btBufPos := bt + 2;
  lz := mt^.lz;
  if lz^.pos >= LzmaMtNormLimit - kMtBtBlockSize then
  begin
    subValue := LongWord(lz^.pos - lz^.historySize - 1);
    lz^.pos := LongWord(lz^.pos - subValue);
    MfNormalize3(subValue, lz^.hash, lz^.fixedHashSize);
  end;
  Result := mt^.btNumAvailBytes;
end;

{ MatchFinderMt_GetNumAvailableBytes }
function MtAvail(mt: PMtState): LongWord; inline;
begin
  if mt^.btBufPos <> mt^.btBufPosLimit then
    Result := mt^.btNumAvailBytes
  else
    Result := MtGetNextBlockBt(mt);
end;

{ Bt4GetMatches con el árbol ya hecho por el hilo BT: el mismo mixing de hash2/hash3 y los
  pares del árbol con len > maxLen del mixing. }
function MtBt4GetMatches(p: PMatchFinder; distances: PLongWord): PLongWord;
var
  mt: PMtState;
  bt, btLim: PLongWord;
  len, avail, lenLimit, h2, h3, d2, d3, pos, mmm, maxLen, temp: LongWord;
  cur: PByte;
  hash: PLongWord;
begin
  mt := PMtState(p^.mt);
  if mt^.btBufPos = mt^.btBufPosLimit then MtGetNextBlockBt(mt);
  bt := mt^.btBufPos;
  len := bt^;
  Inc(bt);
  btLim := bt + len;
  mt^.btBufPos := btLim;
  avail := mt^.btNumAvailBytes;
  mt^.btNumAvailBytes := avail - 1;
  lenLimit := p^.matchMaxLen;
  if avail < lenLimit then lenLimit := avail;
  cur := p^.buffer;
  if lenLimit >= 4 then
  begin
    temp := p^.crc[cur[0]] xor cur[1];
    h2 := temp and (kHash2Size - 1);
    temp := temp xor (LongWord(cur[2]) shl 8);
    h3 := temp and (kHash3Size - 1);
    hash := p^.hash;
    pos := p^.pos;
    d2 := LongWord(pos - hash[h2]);
    d3 := LongWord(pos - hash[kFix3HashSize + h3]);
    hash[h2] := pos;
    hash[kFix3HashSize + h3] := pos;
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
      Break;
    until True;
    // pares del árbol (len crecientes): los de len > maxLen
    while (bt <> btLim) and (bt[0] <= maxLen) do Inc(bt, 2);
    while bt <> btLim do
    begin
      distances[0] := bt[0];
      distances[1] := bt[1];
      Inc(distances, 2);
      Inc(bt, 2);
    end;
  end;
  p^.buffer := cur + 1;
  p^.pos := LongWord(p^.pos + 1);
  Result := distances;
end;

procedure MtBt4Skip(p: PMatchFinder; num: LongWord);
var
  mt: PMtState;
  avail, h2, h3, temp, lenLimit: LongWord;
  cur: PByte;
begin
  mt := PMtState(p^.mt);
  repeat
    if mt^.btBufPos = mt^.btBufPosLimit then MtGetNextBlockBt(mt);
    avail := mt^.btNumAvailBytes;
    mt^.btNumAvailBytes := avail - 1;
    lenLimit := p^.matchMaxLen;
    if avail < lenLimit then lenLimit := avail;
    cur := p^.buffer;
    if lenLimit >= 4 then
    begin
      temp := p^.crc[cur[0]] xor cur[1];
      h2 := temp and (kHash2Size - 1);
      temp := temp xor (LongWord(cur[2]) shl 8);
      h3 := temp and (kHash3Size - 1);
      p^.hash[h2] := p^.pos;
      p^.hash[kFix3HashSize + h3] := p^.pos;
    end;
    Inc(mt^.btBufPos, mt^.btBufPos^ + 1);
    p^.buffer := cur + 1;
    p^.pos := LongWord(p^.pos + 1);
    Dec(num);
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

{ GetNumAvailableBytes }
function TLzmaEnc.CurAvail: LongWord;
begin
  if FMt = nil then Result := MfAvail(@mf) else Result := MtAvail(PMtState(FMt));
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
  FNumAvail := CurAvail;
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
    len := MatchLen(data2, data, len, numAvail);
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
        len := MatchLen(data2, data, len, limit);
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
      len := MatchLen(data2, data, len, numAvail);
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
        len2 := MatchLen(data2, data, len2, limit);
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
            len2 := MatchLen(data2, data, len2, limit);
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
    len := MatchLen(data2, data, len, numAvail);
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
    // FreeArc (LzmaEnc.c:1568) poda el match principal según su longitud y distancia:
    // cuanto más largo, más lejos tiene que estar para que valga la pena.
    case mainLen of
      2: if mainDist >= (128) then mainLen := 1;
      3: if mainDist >= (2048) then mainLen := 1;
      4: if mainDist >= (64 shl 10) then mainLen := 1;
      5: if mainDist >= (2 shl 20) then mainLen := 1;
      6: if mainDist >= (12 shl 20) then mainLen := 1;
    end;
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
    while (len < limit) and (data[len] = data2[len]) do Inc(len);
    // FreeArc: acepta el literal aunque el match con rep esté casi tan largo, si el
    // match principal está lejos (mismo criterio que más arriba con repLen).
    if (len >= limit)
      or ((len + 1 >= limit) and (mainDist >= (1 shl 9)))
      or ((len + 2 >= limit) and (mainDist >= (1 shl 15))) then Exit(1);
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
const
  kMtMinMemSize = 256 shl 10;
var
  fb, i, mc: LongWord;
  d: QWord;
  nt: Integer;
  nb: LongWord;
  useMt: Boolean;
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
  // Multihilo como FreeArc (mtMode = numThreads > 1 y no fast), solo para bt4. En memoria,
  // solo si el bloque lo justifica (crear los hilos y 5 MB de buffers cuesta ~ms). La salida
  // es la misma con o sin hilos.
  nt := P.NumThreads;
  if nt = 0 then
    if LzmaSingleThreadHere then nt := 1 else nt := ThreadCount(2);
  useMt := (nt >= 2) and (P.MatchFinder = mfBT4) and not fastMode
    and ((DirectSrc = nil) or (DirectLen >= kMtMinMemSize)) and MtThreadsAvailable;
  if useMt then
    try
      // el hilo hash va hasta kMtHashBufferSize + (bloques BT) * kMtBtBlockSize posiciones
      // delante del LZ: la ventana conserva eso de más
      nb := MtBtNumBlocks(LongWord(d));
      MfCreate(@mf, LongWord(d), kNumOpts + kMtHashBufferSize + nb * kMtBtBlockSize, numFastBytes,
        LZMA_MATCH_LEN_MAX + 1 + kMtHashBlockSize);
      FMt := MtCreate(@mf, nb);
      GetMatchesF := @MtBt4GetMatches;
      SkipF := @MtBt4Skip;
    except
      // sin memoria para los buffers de más (o ventana demasiado grande): un hilo
      on EOutOfMemory do useMt := False;
      on ELzmaEncParams do useMt := False;
    end;
  if not useMt then
  begin
    MfFree(@mf);
    MfCreate(@mf, LongWord(d), kNumOpts, numFastBytes, LZMA_MATCH_LEN_MAX + 1);
  end;

  InitState;
  InitPrices;
end;

destructor TLzmaEnc.Destroy;
begin
  // primero los hilos (usan la ventana, el hash y el árbol)
  MtDestroy(PMtState(FMt));
  FMt := nil;
  MfFree(@mf);
  if litProbs <> nil then FreeMem(litProbs);
  inherited Destroy;
end;

function TLzmaEnc.AvailIn: QWord;
begin
  if needInit or (FMt <> nil) then Result := 0 else Result := MfAvail(@mf);
end;

function TLzmaEnc.IsMt: Boolean;
begin
  Result := FMt <> nil;
end;

procedure TLzmaEnc.CodeOneBlock;
begin
  // Cancelación cada ~128 KB de entrada: en :max un Write grande (o un bloque de 4x4, en un
  // hilo del pool) son segundos sin emitir nada
  CheckCancel;
  if FMt = nil then
    CodeOneBlockImpl
  else
  begin
    // Multihilo: el "buffer lock" del LZ (btSync.cs) solo mientras se usan punteros a la
    // ventana; MtGetNextBlockBt lo suelta al esperar un bloque
    EnterCriticalSection(PMtState(FMt)^.btSync.cs);
    try
      CodeOneBlockImpl;
    finally
      LeaveCriticalSection(PMtState(FMt)^.btSync.cs);
    end;
  end;
end;

{ LzmaEnc_CodeOneBlock (maxPackSize = 0): codifica ~128 KB o hasta el fin y hace Flush. }
procedure TLzmaEnc.CodeOneBlockImpl;
var
  nowPos32, startPos32, dist, len, posState, oci, numPairs, st, posSlot, sym, bit, footerBits,
    base, pos2, m, processed: LongWord;
  probs, prob: PProb;
  data: PByte;
  curByte: LongWord;
begin
  if needInit then
  begin
    if FMt <> nil then MtInit(PMtState(FMt)) else MfInit(@mf);
    needInit := False;
  end;
  if FFinished then Exit;

  nowPos32 := LongWord(nowPos64);
  startPos32 := nowPos32;

  if nowPos64 = 0 then
  begin
    if CurAvail = 0 then
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

  if CurAvail <> 0 then
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
        if CurAvail = 0 then Break;
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
  Result.NumThreads := 0;
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
    raise ELzmaEncParams.Create('not an lzma method');
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
      raise ELzmaEncParams.CreateFmt('invalid lzma parameter: "%s"', [Params[k]]);
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
  if (P.Algorithm < 0) or (P.MatchFinderCycles < 0) or (P.NumThreads < 0) then
    raise ELzmaEncParams.Create('lzma: negative parameters');
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
  InitCriticalSection(FInLock);
  FInEvent := RTLEventCreate;
  FInInit := True;
  FEnc := TLzmaEnc.Create(P, WriteEndMark, @ReadIn, @WriteOut, nil, 0);
  FMt := TLzmaEnc(FEnc).IsMt;
  // El match finder puede adelantarse hasta ~2^17 + 2*(kNumOpts + 273) posiciones en un
  // CodeOneBlock, y lee cuando le quedan <= keepSizeAfter bytes: con este margen nunca
  // encuentra la entrada vacía antes de Finish.
  FThreshold := SizeInt(TLzmaEnc(FEnc).mf.keepSizeAfter) + (1 shl 17) + 4 * kNumOpts + 4 * LZMA_MATCH_LEN_MAX + 4096;
  { Multihilo: para dar el bloque BT que contiene la última posición que mira el LZ, el hilo
    BT puede necesitar hasta kMtBtBlockSize posiciones más, y el bloque hash de la última de
    esas se calcula recién con más de keepSizeAfter bytes leídos (keepSizeAfter ya incluye
    kMtHashBlockSize); ReadInMt además espera de a kMtReadGrain. Si el LZ esperara un bloque
    que depende de entrada que todavía no llegó, se colgaría (la entrada la trae este hilo).
    Los 8 MB de más no hacen falta para eso: son la holgura para que los hilos hash/BT se
    adelanten al LZ (div40, 64mb:bt4:128: ~0.8 s más con 256 KB). La salida no cambia. }
  if FMt then Inc(FThreshold, kMtBtBlockSize + kMtHashBlockSize + 2 * kMtReadGrain + (8 shl 20));
  inherited Create(ATarget);
end;

destructor TLzmaEncStage.Destroy;
begin
  if FInInit then
  begin
    // que el hilo hash no quede esperando entrada que ya no va a llegar
    EnterCriticalSection(FInLock);
    FAbort := True;
    LeaveCriticalSection(FInLock);
    RTLEventSetEvent(FInEvent);
  end;
  FEnc.Free;
  if FInInit then
  begin
    RTLEventDestroy(FInEvent);
    DoneCriticalSection(FInLock);
  end;
  inherited Destroy;
end;

function TLzmaEncStage.ReadIn(Buf: PByte; Size: SizeInt): SizeInt;
var
  n: SizeInt;
begin
  if FMt then Exit(ReadInMt(Buf, Size));
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
    raise Exception.Create('lzma: match finder ran out of input (internal error)');
end;

procedure TLzmaEncStage.WriteOut(Buf: PByte; Size: SizeInt);
begin
  Emit(Buf, Size);
end;

{ Multihilo: la llama el hilo hash. Espera hasta tener min(Size, kMtReadGrain) bytes (o el
  fin / aborto) para no despertarse por cada Write chico. Los datos (FPend y el buffer del
  llamador durante DoWrite) se tocan solo con FInLock tomado. }
function TLzmaEncStage.ReadInMt(Buf: PByte; Size: SizeInt): SizeInt;
var
  n, want, avail: SizeInt;
begin
  Result := 0;
  want := Size;
  if want > kMtReadGrain then want := kMtReadGrain;
  EnterCriticalSection(FInLock);
  try
    while True do
    begin
      if FAbort then Exit(0);
      avail := (FPendLen - FPendPos) + FExtLen;
      if (avail >= want) or FEof then Break;
      FWant := want;
      FWaiting := True;
      LeaveCriticalSection(FInLock);
      RTLEventWaitFor(FInEvent);
      EnterCriticalSection(FInLock);
      FWaiting := False;
    end;
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
  finally
    LeaveCriticalSection(FInLock);
  end;
end;

procedure TLzmaEncStage.DoWriteMt(Buf: PByte; Count: SizeInt);
var
  n: SizeInt;
  wake: Boolean;
begin
  EnterCriticalSection(FInLock);
  FExt := Buf;
  FExtLen := Count;
  Inc(FTotalIn, Count);
  wake := FWaiting and ((FPendLen - FPendPos) + FExtLen >= FWant);
  LeaveCriticalSection(FInLock);
  if wake then RTLEventSetEvent(FInEvent);
  try
    while not TLzmaEnc(FEnc).Finished
      and (FTotalIn - TLzmaEnc(FEnc).nowPos64 >= QWord(FThreshold)) do
      TLzmaEnc(FEnc).CodeOneBlock;
  finally
    // el buffer del llamador deja de valer: lo que el hilo hash no tomó se copia a FPend
    EnterCriticalSection(FInLock);
    try
      if FExtLen > 0 then
      begin
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
      LeaveCriticalSection(FInLock);
    end;
  end;
end;

procedure TLzmaEncStage.DoWrite(Buf: PByte; Count: SizeInt);
var
  n: SizeInt;
begin
  if FMt then begin DoWriteMt(Buf, Count); Exit; end;
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
  if FMt then
  begin
    EnterCriticalSection(FInLock);
    FEof := True;
    LeaveCriticalSection(FInLock);
    RTLEventSetEvent(FInEvent);
    while not TLzmaEnc(FEnc).Finished do TLzmaEnc(FEnc).CodeOneBlock;
    Exit;   // FPend lo puede estar leyendo el hilo hash: se libera con la etapa
  end;
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
  if SrcLen < 0 then raise ELzmaEncParams.Create('lzma: negative size');
  if Src = nil then Src := @dummy;
  o := TMemOut.Create;
  e := nil;
  try
    SetLength(o.Data, SrcLen div 2 + 4096);
    e := TLzmaEnc.Create(P, WriteEndMark, nil, @o.Write, Src, QWord(SrcLen));
    while not e.Finished do e.CodeOneBlock;
    if e.nowPos64 <> QWord(SrcLen) then raise Exception.Create('lzma: internal error (size)');
    Result := Copy(o.Data, 0, o.Len);
  finally
    e.Free;
    o.Free;
  end;
end;

end.
