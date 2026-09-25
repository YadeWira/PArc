{ LZ4 (codificador): método `lz4` de FreeArc (Compression/LZ4/C_LZ4.cpp, LZ4_METHOD::compress y
  DeCompressMem(COMPRESS)). Decodificador: parc_lz4.

  Stream: byte de versión (=1), escrito recién al leer el primer trozo (con entrada vacía no
  sale NADA, ni siquiera ese byte, como READ_LEN_OR_EOF del C); después, por cada trozo de
  BlockSize bytes (el último, lo que quede): Int32 LE largo comprimido + bloque LZ4, o si no
  comprime lo suficiente (OutSize >= InSize*MinCompression/100) Int32 LE -InSize + el trozo
  tal cual. Cada bloque se comprime por separado (sin diccionario del anterior).

  Los compresores NO son los de 2012 que trae FreeArc sino los de LZ4 1.10.0:
    c0 (default): LZ4_compress_default (aceleración 1): LZ4_compress_generic sin diccionario,
      tabla byU16 (hash4, 2^13) si el bloque tiene < 64KB+11 bytes, si no byU32 (hash5, 2^12).
      El hash5 es el de los builds de 64 bits; se usa también en 32 bits para que el archivo
      salga igual en todas las plataformas (el formato no depende del hash).
    hc / c<N> con N<>0: LZ4_compress_HC nivel 9 (LZ4HC_CLEVEL_DEFAULT): LZ4HC_compress_hashChain
      con 256 intentos y "pattern analysis" (sin chainSwap, sin diccionario, favorCompressionRatio).
  Ambos respetan las reglas del formato que exige también el decodificador de 2012 de FreeArc:
  los últimos 5 bytes son literales (LASTLITERALS) y el último match empieza al menos 12 bytes
  antes del final (MFLIMIT).

  Parámetros (parse_LZ4): hc, c<int>, b<mem> (BlockSize, 1mb), h<mem> (HashSize: solo lo usaba
  la implementación vieja; se acepta e ignora), N% (MinCompression, 100).

  Una diferencia deliberada con el C: un bloque comprimido más largo que su entrada se guarda
  siempre (el C solo lo hace con MinCompression>0; con lz4:hc:0% escribiría un bloque más
  grande que BlockSize, que su propio decodificador lee en un buffer de BlockSize bytes).
  Se asume little-endian (x86/x64): las lecturas de 16/32/64 bits son directas. }
unit parc_lz4enc;

{$mode objfpc}{$H+}
{$R-}{$Q-}
{$goto on}
{$pointermath on}
{$inline on}

interface

uses
  SysUtils, parc_outstream;

type
  ELz4EncParams = class(Exception);

  TLz4EncParams = record
    Compressor: Integer;       // 0 = rápido, otro = HC
    BlockSize: SizeInt;
    MinCompression: Integer;   // en %; 0 = no exigir nada
  end;

  TLz4EncStage = class(TOutStage)
  private
    FPar: TLz4EncParams;
    FBuf: array of Byte;       // trozo actual (crece con los datos hasta BlockSize)
    FLen: SizeInt;
    FOut: array of Byte;
    FStarted: Boolean;         // ya se escribió el byte de versión
    FCtx: Pointer;             // tablas del compresor (se reusan entre bloques)
    procedure FlushBlock;
  protected
    procedure DoWrite(Buf: PByte; Count: SizeInt); override;
    procedure DoFinish; override;
  public
    { Params = partes del método separadas por ':' con Params[0] = 'lz4' }
    constructor Create(ATarget: TOutStage; const Params: TStringArray);
    destructor Destroy; override;
  end;

{ parse_LZ4; parámetros inválidos -> ELz4EncParams }
function ParseLz4EncParams(const Params: TStringArray): TLz4EncParams;

{ True si la etapa ("lz4:..") tiene parámetros válidos. }
function Lz4EncAvailable(const Stage: string): Boolean;

{ LZ4_METHOD::DeCompressMem(COMPRESS) como lo llama 4x4 (*outputSize = SrcLen): Dst = byte de
  versión + UN bloque LZ4 con todo Src. False = no comprime (4x4 guarda el bloque tal cual). }
function Lz4EncodeMem(const Params: TStringArray; Src: PByte; SrcLen: SizeInt; out Dst: TBytes): Boolean;

{ LZ4_compressBound }
function Lz4CompressBound(N: SizeInt): SizeInt;

{ Compresores de bloque sueltos (para tests). Devuelven el largo del bloque, o 0 si no entra en
  DstCap (como limitedOutput de LZ4). }
function Lz4CompressFastBlock(Src: PByte; N: SizeInt; Dst: PByte; DstCap: SizeInt): SizeInt;
function Lz4CompressHCBlock(Src: PByte; N: SizeInt; Dst: PByte; DstCap: SizeInt): SizeInt;

implementation

uses
  parc_methods;

const
  LZ4_VERSION = 1;              // versión del formato de FreeArc (C_LZ4.cpp)
  MINMATCH = 4;
  LASTLITERALS = 5;
  MFLIMIT = 12;
  LZ4_MIN_LENGTH = MFLIMIT + 1;
  ML_BITS = 4;
  ML_MASK = 15;
  RUN_MASK = 15;
  DISTANCE_MAX = 65535;
  LZ4_MAX_INPUT_SIZE = $7E000000;
  LZ4_64K_LIMIT = 65536 + (MFLIMIT - 1);
  SKIP_TRIGGER = 6;
  LZ4_HASHLOG = 12;             // LZ4_MEMORY_USAGE (14) - 2

  // lz4hc
  HC_HASH_LOG = 15;
  HC_MAXD = 1 shl 16;
  HC_ATTEMPTS = 256;            // k_clTable[9]
  HC_BASE = 65536;              // LZ4HC_init_internal: los índices arrancan en 64 KB
  OPTIMAL_ML = (ML_MASK - 1) + MINMATCH;

type
  TFastCtx = record
    Table: array[0..(1 shl (LZ4_HASHLOG + 1)) - 1] of LongWord;
  end;
  PFastCtx = ^TFastCtx;

  THCCtx = record
    HashTable: array[0..(1 shl HC_HASH_LOG) - 1] of LongWord;
    ChainTable: array[0..HC_MAXD - 1] of Word;
    NextToUpdate: LongWord;
  end;
  PHCCtx = ^THCCtx;

  THCMatch = record
    Off, Len, Back: SizeInt;
  end;

function Lz4CompressBound(N: SizeInt): SizeInt;
begin
  if (N < 0) or (N > LZ4_MAX_INPUT_SIZE) then Exit(0);
  Result := N + N div 255 + 16;
end;

function Read16(P: PByte): Word; inline;
begin
  Result := unaligned(PWord(P)^);
end;

function Read32(P: PByte): LongWord; inline;
begin
  Result := unaligned(PLongWord(P)^);
end;

function Read64(P: PByte): QWord; inline;
begin
  Result := unaligned(PQWord(P)^);
end;

{ LZ4_count: bytes iguales desde pIn/pMatch sin pasar de pInLimit }
function Count(pIn, pMatch, pInLimit: PByte): SizeInt; inline;
var
  pStart: PByte;
  Diff: QWord;
begin
  pStart := pIn;
  while pIn < pInLimit - 7 do
  begin
    Diff := Read64(pIn) xor Read64(pMatch);
    if Diff = 0 then
    begin
      Inc(pIn, 8);
      Inc(pMatch, 8);
      Continue;
    end;
    Inc(pIn, BsfQWord(Diff) shr 3);
    Exit(pIn - pStart);
  end;
  while (pIn < pInLimit) and (pIn^ = pMatch^) do
  begin
    Inc(pIn);
    Inc(pMatch);
  end;
  Result := pIn - pStart;
end;

{ ------------------------------------------------------------------------------------------
  Compresor rápido: LZ4_compress_generic_validated (lz4.c) con noDict, noDictIssue,
  aceleración 1, limitedOutput (con DstCap >= LZ4_compressBound los chequeos no saltan nunca,
  así que es también el caso notLimited).
  ------------------------------------------------------------------------------------------ }

function HashFast(P: PByte; ByU16: Boolean): LongWord; inline;
begin
  if ByU16 then
    Result := LongWord(Read32(P) * LongWord(2654435761)) shr ((MINMATCH * 8) - (LZ4_HASHLOG + 1))
  else
    // LZ4_hash5 (little-endian)
    Result := LongWord(((Read64(P) shl 24) * QWord(889523592379)) shr (64 - LZ4_HASHLOG));
end;

function CompressFast(Ctx: PFastCtx; Src: PByte; N: SizeInt; Dst: PByte; DstCap: SizeInt): SizeInt;
var
  ByU16: Boolean;
  ip, anchor, forwardIp, match, mflimitPlusOne, matchlimit, iend: PByte;
  op, olimit, token: PByte;
  h, forwardH, cur, matchIndex: LongWord;
  step, searchMatchNb: LongInt;
  litLength, len, matchCode, lastRun: SizeInt;
label
  next_match, last_literals;
begin
  Result := 0;
  if (N < 0) or (N > LZ4_MAX_INPUT_SIZE) then Exit;
  if N = 0 then
  begin
    // bloque vacío: un token 0
    if DstCap <= 0 then Exit;
    Dst[0] := 0;
    Exit(1);
  end;
  FillChar(Ctx^.Table, SizeOf(Ctx^.Table), 0);   // LZ4_initStream
  ByU16 := N < LZ4_64K_LIMIT;
  ip := Src;
  anchor := Src;
  iend := Src + N;
  mflimitPlusOne := iend - MFLIMIT + 1;
  matchlimit := iend - LASTLITERALS;
  op := Dst;
  olimit := Dst + DstCap;
  match := nil;
  token := nil;

  if N < LZ4_MIN_LENGTH then goto last_literals;

  // Primer byte
  Ctx^.Table[HashFast(ip, ByU16)] := 0;
  Inc(ip);
  forwardH := HashFast(ip, ByU16);

  while True do
  begin
    // Buscar un match (con saltos crecientes sobre datos que no comprimen)
    forwardIp := ip;
    step := 1;
    searchMatchNb := 1 shl SKIP_TRIGGER;
    repeat
      h := forwardH;
      cur := LongWord(forwardIp - Src);
      matchIndex := Ctx^.Table[h];
      ip := forwardIp;
      Inc(forwardIp, step);
      step := searchMatchNb shr SKIP_TRIGGER;
      Inc(searchMatchNb);
      if forwardIp > mflimitPlusOne then goto last_literals;
      match := Src + matchIndex;
      forwardH := HashFast(forwardIp, ByU16);
      Ctx^.Table[h] := cur;
      // byU16: con DISTANCE_MAX = 65535 la distancia no hace falta chequearla
      if (not ByU16) and (matchIndex + DISTANCE_MAX < cur) then Continue;
      if Read32(match) = Read32(ip) then Break;
    until False;

    // Extender hacia atrás
    if (match > Src) and (ip[-1] = match[-1]) then
      repeat
        Dec(ip);
        Dec(match);
      until not ((ip > anchor) and (match > Src) and (ip[-1] = match[-1]));

    // Literales
    litLength := ip - anchor;
    token := op;
    Inc(op);
    if op + litLength + (2 + 1 + LASTLITERALS) + (litLength div 255) > olimit then Exit(0);
    if litLength >= RUN_MASK then
    begin
      len := litLength - RUN_MASK;
      token^ := RUN_MASK shl ML_BITS;
      while len >= 255 do
      begin
        op^ := 255; Inc(op);
        Dec(len, 255);
      end;
      op^ := Byte(len); Inc(op);
    end
    else
      token^ := Byte(litLength shl ML_BITS);
    Move(anchor^, op^, litLength);
    Inc(op, litLength);

next_match:
    // Offset
    op[0] := Byte(ip - match);
    op[1] := Byte((ip - match) shr 8);
    Inc(op, 2);
    // Largo del match
    matchCode := Count(ip + MINMATCH, match + MINMATCH, matchlimit);
    Inc(ip, matchCode + MINMATCH);
    if op + (1 + LASTLITERALS) + (matchCode + 240) div 255 > olimit then Exit(0);
    if matchCode >= ML_MASK then
    begin
      token^ := token^ + ML_MASK;
      Dec(matchCode, ML_MASK);
      while matchCode >= 255 do
      begin
        op^ := 255; Inc(op);
        Dec(matchCode, 255);
      end;
      op^ := Byte(matchCode); Inc(op);
    end
    else
      token^ := token^ + Byte(matchCode);

    anchor := ip;
    if ip >= mflimitPlusOne then Break;

    // Llenar la tabla
    Ctx^.Table[HashFast(ip - 2, ByU16)] := LongWord(ip - 2 - Src);

    // Probar la posición siguiente
    h := HashFast(ip, ByU16);
    cur := LongWord(ip - Src);
    matchIndex := Ctx^.Table[h];
    match := Src + matchIndex;
    Ctx^.Table[h] := cur;
    if (ByU16 or (matchIndex + DISTANCE_MAX >= cur)) and (Read32(match) = Read32(ip)) then
    begin
      token := op;
      token^ := 0;
      Inc(op);
      goto next_match;
    end;

    Inc(ip);
    forwardH := HashFast(ip, ByU16);
  end;

last_literals:
  lastRun := iend - anchor;
  if op + lastRun + 1 + ((lastRun + 255 - RUN_MASK) div 255) > olimit then Exit(0);
  if lastRun >= RUN_MASK then
  begin
    len := lastRun - RUN_MASK;
    op^ := RUN_MASK shl ML_BITS; Inc(op);
    while len >= 255 do
    begin
      op^ := 255; Inc(op);
      Dec(len, 255);
    end;
    op^ := Byte(len); Inc(op);
  end
  else
  begin
    op^ := Byte(lastRun shl ML_BITS); Inc(op);
  end;
  Move(anchor^, op^, lastRun);
  Inc(op, lastRun);
  Result := op - Dst;
end;

{ ------------------------------------------------------------------------------------------
  Compresor HC: LZ4HC_compress_hashChain (lz4hc.c) nivel 9, un solo segmento (prefixStart =
  src, dictLimit = lowLimit = 64 KB, sin extDict ni dictCtx: esas ramas no pueden darse).
  Las posiciones se manejan como índices: índice = HC_BASE + (p - Src).
  ------------------------------------------------------------------------------------------ }

function HashHC(P: PByte): LongWord; inline;
begin
  Result := LongWord(Read32(P) * LongWord(2654435761)) shr ((MINMATCH * 8) - HC_HASH_LOG);
end;

{ LZ4HC_Insert: actualiza las cadenas hasta ip (excluido) }
procedure HCInsert(Ctx: PHCCtx; Src, ip: PByte); inline;
var
  target, idx, h, delta: LongWord;
begin
  target := LongWord(ip - Src) + HC_BASE;
  idx := Ctx^.NextToUpdate;
  while idx < target do
  begin
    h := HashHC(Src + (idx - HC_BASE));
    delta := idx - Ctx^.HashTable[h];
    if delta > DISTANCE_MAX then delta := DISTANCE_MAX;
    Ctx^.ChainTable[Word(idx)] := Word(delta);
    Ctx^.HashTable[h] := idx;
    Inc(idx);
  end;
  Ctx^.NextToUpdate := target;
end;

{ LZ4HC_countBack: <= 0, bytes iguales antes de ip/match }
function CountBack(ip, match, iMin, mMin: PByte): SizeInt; inline;
var
  back, lim: SizeInt;
begin
  back := 0;
  lim := iMin - ip;
  if mMin - match > lim then lim := mMin - match;
  while (back > lim) and (ip[back - 1] = match[back - 1]) do Dec(back);
  Result := back;
end;

{ LZ4HC_countPattern: bytes desde ip que siguen el patrón periódico (período 1, 2 o 4) }
function CountPattern(ip, iEnd: PByte; Pattern: LongWord): SizeInt;
var
  iStart: PByte;
  pb: LongWord;
begin
  iStart := ip;
  while (ip + 4 <= iEnd) and (Read32(ip) = Pattern) do Inc(ip, 4);
  pb := Pattern;
  while (ip < iEnd) and (ip^ = Byte(pb)) do
  begin
    Inc(ip);
    pb := pb shr 8;
  end;
  Result := ip - iStart;
end;

{ LZ4HC_reverseCountPattern }
function ReverseCountPattern(ip, iLow: PByte; Pattern: LongWord): SizeInt;
var
  iStart: PByte;
  k: Integer;
begin
  iStart := ip;
  while (ip >= iLow + 4) and (Read32(ip - 4) = Pattern) do Dec(ip, 4);
  k := 3;   // el último byte del patrón en memoria
  while (k >= 0) and (ip > iLow) and (ip[-1] = Byte(Pattern shr (8 * k))) do
  begin
    Dec(ip);
    Dec(k);
  end;
  Result := iStart - ip;
end;

{ LZ4HC_InsertAndGetWiderMatch con chainSwap=0, noDictCtx, favorCompressionRatio }
function InsertAndGetWiderMatch(Ctx: PHCCtx; Src, ip, iLowLimit, iHighLimit: PByte;
  longest: SizeInt; PatternAnalysis: Boolean): THCMatch;
type
  TRepeat = (repUntested, repNot, repConfirmed);
var
  ipIndex, lowestMatchIndex, matchIndex, pattern, distNextMatch, mci, newMatchIndex,
    distToNextPattern, lowBound: LongWord;
  lookBackLength, nbAttempts, matchLength, back, offset, sBack: SizeInt;
  srcPatternLength, forwardPatternLength, backLength, currentSegmentLength, maxML: SizeInt;
  matchPtr: PByte;
  rep: TRepeat;
begin
  ipIndex := LongWord(ip - Src) + HC_BASE;
  if HC_BASE + (DISTANCE_MAX + 1) > ipIndex then lowestMatchIndex := HC_BASE
  else lowestMatchIndex := ipIndex - DISTANCE_MAX;
  lookBackLength := ip - iLowLimit;
  nbAttempts := HC_ATTEMPTS;
  pattern := Read32(ip);
  rep := repUntested;
  srcPatternLength := 0;
  offset := 0;
  sBack := 0;

  HCInsert(Ctx, Src, ip);
  matchIndex := Ctx^.HashTable[HashHC(ip)];

  while (matchIndex >= lowestMatchIndex) and (nbAttempts > 0) do
  begin
    Dec(nbAttempts);
    matchPtr := Src + (matchIndex - HC_BASE);
    if Read16(iLowLimit + longest - 1) = Read16(matchPtr - lookBackLength + longest - 1) then
      if Read32(matchPtr) = pattern then
      begin
        if lookBackLength <> 0 then back := CountBack(ip, matchPtr, iLowLimit, Src) else back := 0;
        matchLength := MINMATCH + Count(ip + MINMATCH, matchPtr + MINMATCH, iHighLimit);
        Dec(matchLength, back);
        if matchLength > longest then
        begin
          longest := matchLength;
          offset := ipIndex - matchIndex;
          sBack := back;
        end;
      end;

    distNextMatch := Ctx^.ChainTable[Word(matchIndex)];
    if PatternAnalysis and (distNextMatch = 1) then
    begin
      mci := matchIndex - 1;
      // ¿un patrón repetido?
      if rep = repUntested then
      begin
        if ((pattern and $FFFF) = (pattern shr 16)) and ((pattern and $FF) = (pattern shr 24)) then
        begin
          rep := repConfirmed;
          srcPatternLength := CountPattern(ip + 4, iHighLimit, pattern) + 4;
        end
        else
          rep := repNot;
      end;
      // (LZ4HC_protectDictEnd siempre se cumple sin diccionario externo)
      if (rep = repConfirmed) and (mci >= lowestMatchIndex) then
      begin
        matchPtr := Src + (mci - HC_BASE);
        if Read32(matchPtr) = pattern then
        begin
          forwardPatternLength := CountPattern(matchPtr + 4, iHighLimit, pattern) + 4;
          backLength := ReverseCountPattern(matchPtr, Src, pattern);
          // No ir más atrás que lowestMatchIndex
          if SizeInt(mci) - backLength > SizeInt(lowestMatchIndex) then lowBound := mci - LongWord(backLength)
          else lowBound := lowestMatchIndex;
          backLength := mci - lowBound;
          currentSegmentLength := backLength + forwardPatternLength;
          if (currentSegmentLength >= srcPatternLength) and (forwardPatternLength <= srcPatternLength) then
          begin
            // mejor posición: patrón completo, quizá seguido de más match
            newMatchIndex := mci + LongWord(forwardPatternLength) - LongWord(srcPatternLength);
            matchIndex := newMatchIndex;
          end
          else
          begin
            // la posición más lejana del segmento
            newMatchIndex := mci - LongWord(backLength);
            matchIndex := newMatchIndex;
            if lookBackLength = 0 then
            begin
              maxML := currentSegmentLength;
              if srcPatternLength < maxML then maxML := srcPatternLength;
              if longest < maxML then
              begin
                if (ip - Src) + HC_BASE - SizeInt(matchIndex) > DISTANCE_MAX then Break;
                longest := maxML;
                offset := ipIndex - matchIndex;
              end;
              distToNextPattern := Ctx^.ChainTable[Word(matchIndex)];
              if distToNextPattern > matchIndex then Break;
              Dec(matchIndex, distToNextPattern);
            end;
          end;
          Continue;
        end;
      end;
    end;

    // seguir la cadena
    Dec(matchIndex, Ctx^.ChainTable[Word(matchIndex)]);
  end;

  Result.Len := longest;
  Result.Off := offset;
  Result.Back := sBack;
end;

{ LZ4HC_encodeSequence (limitedOutput). False = no entra. }
function EncodeSequence(var ip, op, anchor: PByte; MatchLength, Offset: SizeInt; oend: PByte): Boolean; inline;
var
  token: PByte;
  length: SizeInt;
begin
  Result := False;
  token := op;
  Inc(op);
  length := ip - anchor;
  if op + (length div 255) + length + (2 + 1 + LASTLITERALS) > oend then Exit;
  if length >= RUN_MASK then
  begin
    token^ := RUN_MASK shl ML_BITS;
    Dec(length, RUN_MASK);
    while length >= 255 do
    begin
      op^ := 255; Inc(op);
      Dec(length, 255);
    end;
    op^ := Byte(length); Inc(op);
  end
  else
    token^ := Byte(length shl ML_BITS);
  length := ip - anchor;
  Move(anchor^, op^, length);
  Inc(op, length);
  op[0] := Byte(Offset);
  op[1] := Byte(Offset shr 8);
  Inc(op, 2);
  length := MatchLength - MINMATCH;
  if op + (length div 255) + (1 + LASTLITERALS) > oend then Exit;
  if length >= ML_MASK then
  begin
    token^ := token^ + ML_MASK;
    Dec(length, ML_MASK);
    while length >= 255 do
    begin
      op^ := 255; Inc(op);
      Dec(length, 255);
    end;
    op^ := Byte(length); Inc(op);
  end
  else
    token^ := token^ + Byte(length);
  Inc(ip, MatchLength);
  anchor := ip;
  Result := True;
end;

function CompressHC(Ctx: PHCCtx; Src: PByte; N: SizeInt; Dst: PByte; DstCap: SizeInt): SizeInt;
var
  ip, anchor, iend, mfLim, matchlimit, op, oend, start0, start2, start3: PByte;
  m0, m1, m2, m3: THCMatch;
  new_ml, correction: SizeInt;
  lastRunSize, acc: SizeInt;
label
  Search2, Search3, last_literals;
begin
  Result := 0;
  if (N < 0) or (N > LZ4_MAX_INPUT_SIZE) then Exit;
  // LZ4HC_init_internal sobre tablas limpias
  FillChar(Ctx^.HashTable, SizeOf(Ctx^.HashTable), 0);
  FillChar(Ctx^.ChainTable, SizeOf(Ctx^.ChainTable), $FF);
  Ctx^.NextToUpdate := HC_BASE;

  ip := Src;
  anchor := ip;
  iend := ip + N;
  mfLim := iend - MFLIMIT;
  matchlimit := iend - LASTLITERALS;
  op := Dst;
  oend := Dst + DstCap;
  start2 := nil;
  start3 := nil;

  if N < LZ4_MIN_LENGTH then goto last_literals;

  while ip <= mfLim do
  begin
    m1 := InsertAndGetWiderMatch(Ctx, Src, ip, ip, matchlimit, MINMATCH - 1, True);
    if m1.Len < MINMATCH then
    begin
      Inc(ip);
      Continue;
    end;

    // por si se saltea demasiado
    start0 := ip;
    m0 := m1;

Search2:
    if ip + m1.Len <= mfLim then
    begin
      start2 := ip + m1.Len - 2;
      m2 := InsertAndGetWiderMatch(Ctx, Src, start2, ip, matchlimit, m1.Len, True);
      Inc(start2, m2.Back);
    end
    else
    begin
      m2.Len := 0; m2.Off := 0; m2.Back := 0;
    end;

    if m2.Len <= m1.Len then
    begin
      // no hay uno mejor: codificar ML1 ya
      if not EncodeSequence(ip, op, anchor, m1.Len, m1.Off, oend) then Exit(0);
      Continue;
    end;

    if start0 < ip then
      if start2 < ip + m0.Len then
      begin
        // ML1 entre ML0 (el ML1 original) y ML2
        ip := start0;
        m1 := m0;
      end;

    if start2 - ip < 3 then
    begin
      // el primer match es muy corto: se descarta
      ip := start2;
      m1 := m2;
      goto Search2;
    end;

Search3:
    if start2 - ip < OPTIMAL_ML then
    begin
      new_ml := m1.Len;
      if new_ml > OPTIMAL_ML then new_ml := OPTIMAL_ML;
      if ip + new_ml > start2 + m2.Len - MINMATCH then
        new_ml := (start2 - ip) + m2.Len - MINMATCH;
      correction := new_ml - (start2 - ip);
      if correction > 0 then
      begin
        Inc(start2, correction);
        Dec(m2.Len, correction);
      end;
    end;

    if start2 + m2.Len <= mfLim then
    begin
      start3 := start2 + m2.Len - 3;
      m3 := InsertAndGetWiderMatch(Ctx, Src, start3, start2, matchlimit, m2.Len, True);
      Inc(start3, m3.Back);
    end
    else
    begin
      m3.Len := 0; m3.Off := 0; m3.Back := 0;
    end;

    if m3.Len <= m2.Len then
    begin
      // no hay uno mejor: codificar ML1 y ML2
      if start2 < ip + m1.Len then m1.Len := start2 - ip;
      if not EncodeSequence(ip, op, anchor, m1.Len, m1.Off, oend) then Exit(0);
      ip := start2;
      if not EncodeSequence(ip, op, anchor, m2.Len, m2.Off, oend) then Exit(0);
      Continue;
    end;

    if start3 < ip + m1.Len + 3 then
    begin
      // no hay lugar para el match 2: se saca
      if start3 >= ip + m1.Len then
      begin
        // Seq1 se puede escribir ya; Seq2 se saca y Seq3 pasa a ser Seq1
        if start2 < ip + m1.Len then
        begin
          correction := (ip + m1.Len) - start2;
          Inc(start2, correction);
          Dec(m2.Len, correction);
          if m2.Len < MINMATCH then
          begin
            start2 := start3;
            m2 := m3;
          end;
        end;
        if not EncodeSequence(ip, op, anchor, m1.Len, m1.Off, oend) then Exit(0);
        ip := start3;
        m1 := m3;
        start0 := start2;
        m0 := m2;
        goto Search2;
      end;
      start2 := start3;
      m2 := m3;
      goto Search3;
    end;

    // Tres matches crecientes: escribir ML1 decidiendo su largo
    if start2 < ip + m1.Len then
    begin
      if start2 - ip < OPTIMAL_ML then
      begin
        if m1.Len > OPTIMAL_ML then m1.Len := OPTIMAL_ML;
        if ip + m1.Len > start2 + m2.Len - MINMATCH then
          m1.Len := (start2 - ip) + m2.Len - MINMATCH;
        correction := m1.Len - (start2 - ip);
        if correction > 0 then
        begin
          Inc(start2, correction);
          Dec(m2.Len, correction);
        end;
      end
      else
        m1.Len := start2 - ip;
    end;
    if not EncodeSequence(ip, op, anchor, m1.Len, m1.Off, oend) then Exit(0);
    // ML2 pasa a ML1, ML3 a ML2, y se busca un ML3 nuevo
    ip := start2; m1 := m2;
    start2 := start3; m2 := m3;
    goto Search3;
  end;

last_literals:
  lastRunSize := iend - anchor;
  if op + 1 + ((lastRunSize + 255 - RUN_MASK) div 255) + lastRunSize > oend then Exit(0);
  if lastRunSize >= RUN_MASK then
  begin
    acc := lastRunSize - RUN_MASK;
    op^ := RUN_MASK shl ML_BITS; Inc(op);
    while acc >= 255 do
    begin
      op^ := 255; Inc(op);
      Dec(acc, 255);
    end;
    op^ := Byte(acc); Inc(op);
  end
  else
  begin
    op^ := Byte(lastRunSize shl ML_BITS); Inc(op);
  end;
  Move(anchor^, op^, lastRunSize);
  Inc(op, lastRunSize);
  Result := op - Dst;
end;

{ Contextos }

function NewCtx(Compressor: Integer): Pointer;
begin
  if Compressor <> 0 then Result := GetMem(SizeOf(THCCtx))
  else Result := GetMem(SizeOf(TFastCtx));
end;

function CompressBlock(Compressor: Integer; Ctx: Pointer; Src: PByte; N: SizeInt; Dst: PByte;
  DstCap: SizeInt): SizeInt;
begin
  if Compressor <> 0 then Result := CompressHC(PHCCtx(Ctx), Src, N, Dst, DstCap)
  else Result := CompressFast(PFastCtx(Ctx), Src, N, Dst, DstCap);
end;

function Lz4CompressFastBlock(Src: PByte; N: SizeInt; Dst: PByte; DstCap: SizeInt): SizeInt;
var
  Ctx: Pointer;
begin
  Ctx := NewCtx(0);
  try
    Result := CompressBlock(0, Ctx, Src, N, Dst, DstCap);
  finally
    FreeMem(Ctx);
  end;
end;

function Lz4CompressHCBlock(Src: PByte; N: SizeInt; Dst: PByte; DstCap: SizeInt): SizeInt;
var
  Ctx: Pointer;
begin
  Ctx := NewCtx(2);
  try
    Result := CompressBlock(2, Ctx, Src, N, Dst, DstCap);
  finally
    FreeMem(Ctx);
  end;
end;

{ Parámetros }

{ parseInt de FreeArc: '=' inicial opcional y solo dígitos (al menos uno) }
function FaParseInt(const S: string; out V: Int64): Boolean;
var
  i: Integer;
begin
  Result := False;
  V := 0;
  i := 1;
  if (i <= Length(S)) and (S[i] = '=') then Inc(i);
  if i > Length(S) then Exit;
  while i <= Length(S) do
  begin
    if not (S[i] in ['0'..'9']) then Exit;
    if V > High(LongInt) then Exit;
    V := V * 10 + Ord(S[i]) - Ord('0');
    Inc(i);
  end;
  Result := V <= High(LongInt);
end;

function ParseLz4EncParams(const Params: TStringArray): TLz4EncParams;
var
  k: Integer;
  p: string;
  m: QWord;
  n: Int64;
  ok: Boolean;
begin
  if (Length(Params) = 0) or (Params[0] <> 'lz4') then
    raise ELz4EncParams.Create('lz4: no es el método lz4');
  // LZ4_METHOD::LZ4_METHOD
  Result.Compressor := 0;
  Result.BlockSize := 1 shl 20;
  Result.MinCompression := 100;
  for k := 1 to High(Params) do
  begin
    p := Params[k];
    ok := False;
    if p = 'hc' then
    begin
      Result.Compressor := 2;
      ok := True;
    end
    else if (p <> '') and (p[1] = 'c') then
    begin
      ok := FaParseInt(Copy(p, 2, MaxInt), n);
      if ok then Result.Compressor := Integer(n);
    end
    else if (p <> '') and (p[1] = 'b') then
    begin
      ok := ParseMem(Copy(p, 2, MaxInt), m);
      // BlockSize=0: el C lee 0 bytes, lo toma como fin y descarta todo el stream
      if ok and ((m = 0) or (m > LZ4_MAX_INPUT_SIZE)) then
        raise ELz4EncParams.CreateFmt('lz4: tamaño de bloque inválido "%s"', [p]);
      if ok then Result.BlockSize := SizeInt(m);
    end
    else if (p <> '') and (p[1] = 'h') then
      ok := ParseMem(Copy(p, 2, MaxInt), m)      // HashSize: no lo usa LZ4 1.10
    else if (p <> '') and (p[Length(p)] = '%') then
    begin
      ok := FaParseInt(Copy(p, 1, Length(p) - 1), n);
      if ok then Result.MinCompression := Integer(n);
    end;
    if not ok then raise ELz4EncParams.CreateFmt('lz4: parámetro inválido "%s"', [p]);
  end;
end;

function Lz4EncAvailable(const Stage: string): Boolean;
begin
  try
    ParseLz4EncParams(Stage.Split([':']));
    Result := True;
  except
    on ELz4EncParams do Result := False;
  end;
end;

{ ¿No comprimió lo suficiente? (la condición del C, en double) }
function TooBig(OutSize, InSize: SizeInt; MinCompression: Integer): Boolean;
begin
  Result := (OutSize <= 0) or
            ((MinCompression > 0) and (OutSize >= (Double(InSize) * MinCompression) / 100)) or
            (OutSize > InSize);   // ver el comentario de la unidad
end;

function Lz4EncodeMem(const Params: TStringArray; Src: PByte; SrcLen: SizeInt; out Dst: TBytes): Boolean;
var
  Par: TLz4EncParams;
  Ctx: Pointer;
  Cap, OutSize: SizeInt;
begin
  Dst := nil;
  Par := ParseLz4EncParams(Params);
  if (SrcLen <= 0) or (SrcLen > LZ4_MAX_INPUT_SIZE) then Exit(False);
  // DeCompressMem: rápido = LZ4_compress_limitedOutput(.., *outputSize-1) con *outputSize=SrcLen;
  // HC = LZ4_compressHC sin límite (el control de tamaño viene después)
  if Par.Compressor <> 0 then Cap := Lz4CompressBound(SrcLen) else Cap := SrcLen - 1;
  SetLength(Dst, 1 + Lz4CompressBound(SrcLen));
  Ctx := NewCtx(Par.Compressor);
  try
    OutSize := CompressBlock(Par.Compressor, Ctx, Src, SrcLen, @Dst[1], Cap);
  finally
    FreeMem(Ctx);
  end;
  // El C compara con el byte de versión incluido
  if (OutSize <= 0) or TooBig(OutSize + 1, SrcLen, Par.MinCompression) then
  begin
    Dst := nil;
    Exit(False);
  end;
  Dst[0] := LZ4_VERSION;
  SetLength(Dst, OutSize + 1);
  Result := True;
end;

{ TLz4EncStage }

constructor TLz4EncStage.Create(ATarget: TOutStage; const Params: TStringArray);
var
  Par: TLz4EncParams;
begin
  // Validar ANTES de inherited Create (si falla, Destroy ve FTarget=nil)
  Par := ParseLz4EncParams(Params);
  FPar := Par;
  inherited Create(ATarget);
end;

destructor TLz4EncStage.Destroy;
begin
  if FCtx <> nil then FreeMem(FCtx);
  inherited Destroy;
end;

procedure TLz4EncStage.FlushBlock;
var
  OutSize, Cap: SizeInt;
begin
  if FLen = 0 then Exit;
  if not FStarted then
  begin
    // el C escribe la versión recién después de leer el primer trozo
    FStarted := True;
    FOut := nil;
    SetLength(FOut, 1);
    FOut[0] := LZ4_VERSION;
    Emit(@FOut[0], 1);
  end;
  if FCtx = nil then FCtx := NewCtx(FPar.Compressor);
  if Length(FOut) < Lz4CompressBound(FLen) then SetLength(FOut, Lz4CompressBound(FLen));
  // rápido: LZ4_compress_limitedOutput(In, Out, InSize, InSize); HC: LZ4_compressHC sin límite
  if FPar.Compressor <> 0 then Cap := Lz4CompressBound(FLen) else Cap := FLen;
  OutSize := CompressBlock(FPar.Compressor, FCtx, @FBuf[0], FLen, @FOut[0], Cap);
  if TooBig(OutSize, FLen, FPar.MinCompression) then
  begin
    // bloque guardado: largo negativo
    EmitU32(LongWord(-LongInt(FLen)));
    Emit(@FBuf[0], FLen);
  end
  else
  begin
    EmitU32(LongWord(OutSize));
    Emit(@FOut[0], OutSize);
  end;
  FLen := 0;
end;

procedure TLz4EncStage.DoWrite(Buf: PByte; Count: SizeInt);
var
  n, NewCap: SizeInt;
begin
  while Count > 0 do
  begin
    n := FPar.BlockSize - FLen;
    if n > Count then n := Count;
    if FLen + n > Length(FBuf) then
    begin
      NewCap := 2 * Length(FBuf);
      if NewCap < FLen + n then NewCap := FLen + n;
      if NewCap < 1 shl 16 then NewCap := 1 shl 16;
      if NewCap > FPar.BlockSize then NewCap := FPar.BlockSize;
      SetLength(FBuf, NewCap);
    end;
    Move(Buf^, FBuf[FLen], n);
    Inc(FLen, n);
    Inc(Buf, n);
    Dec(Count, n);
    if FLen = FPar.BlockSize then FlushBlock;
  end;
end;

procedure TLz4EncStage.DoFinish;
begin
  FlushBlock;
end;

end.
