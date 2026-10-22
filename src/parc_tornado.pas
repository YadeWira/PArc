{ Decodificador Tornado (método "tor" de FreeArc, Compression/Tornado/).
  Stream: byte codificador (1 bytes, 2 bits, 3 huffman, 4 aritmético), byte minlen, U32 LE
  bufsize, y el bitstream del codificador. Termina con el código especial
  (IMPOSSIBLE_LEN, IMPOSSIBLE_DIST); otros códigos especiales describen tablas "diffeadas"
  (DataTables.cpp) que se deshacen justo antes de entregar cada tramo y se rehacen después,
  porque el buffer circular guarda los datos diffeados y los matches los referencian así.
  Se respeta exactamente WRITE_DATA_IF (Tornado.cpp): cuándo se escribe, el undiff/diff de
  las tablas, tables.shift al volver al inicio del buffer y PAD_FOR_TABLES.
  AllAtOnce reproduce compress_all_at_once=1 (FreeArc lo activa dentro de 4x4). }
unit parc_tornado;

{$mode objfpc}{$H+}
{$R-}{$Q-}
{$inline on}

interface

uses
  SysUtils, parc_stream;

type
  TTornadoTable = record
    Typ: SizeInt;       // largo de fila (1..MAX_TABLE_ROW)
    Start: SizeInt;     // índice relativo a outbuf (puede ser negativo, dentro del PAD)
    Len: SizeInt;       // cantidad de filas
  end;

  TTornadoStage = class(TInStage)
  private
    FAllAtOnce, FInit, FPending, FAtEnd, FDone: Boolean;
    // --- Entrada (InputByteStream) ---
    FIn: array of Byte;
    FInPos, FInEnd, FInLim: SizeInt;
    FInEof: Boolean;
    // --- Parámetros del stream ---
    FMethod, FMinLen: LongWord;
    FHdrBufSize: Int64;          // _bufsize del encabezado
    // --- LZ77_ByteDecoder ---
    FFlags, FFlagPos: LongWord;
    // --- InputBitStream ---
    FBitBuf: QWord;
    FBitCount: Integer;
    // --- HuffmanTree (decodificador) ---
    FHufCounter: array[0..2047] of LongWord;     // MAXHUF
    FHufBits: array[0..2047] of Byte;
    FHufFast: array[0..2047] of SmallInt;        // 1 shl FAST_BITS
    FHufIndex: array of Word;
    FHufMaxBits, FHufMaxSoFar: Integer;
    FHufMask: LongWord;          // (1 shl FHufMaxBits) - 1
    FHufBlock: SizeInt;          // símbolos desde el último EOB (validación extra)
    FNCnt, FNLeft, FNRight, FNBits, FNCode: array[0..2 * 2048 + 3] of LongWord;   // nodos del árbol
    FRest: array[0..2047] of QWord;
    // --- TRangeDecoder + TCounter ---
    FRange, FCode: LongWord;
    FACnt, FACum, FALive: array[0..2047] of LongWord;   // NUM
    FAIndex: array[0..2047] of Word;                    // INDEXES
    FARemainder: LongWord;
    // --- LZ77_Decoder ---
    FPrevDists: array[0..127] of LongInt;
    FPrev: Integer;
    // --- Buffer circular de salida ---
    FMem: PByte;
    FOut: PByte;                 // outbuf = FMem + PAD_FOR_TABLES
    FBufSize: SizeInt;           // tornado_decompressor_outbuf_size(_bufsize)
    FOutput, FWriteStart, FWriteEnd: SizeInt;
    FOffset: QWord;
    FOffsetOverflow: Boolean;
    FMatchLeft: LongWord;        // match lento cortado por una escritura
    FMatchSrc: SizeInt;
    FPendLen, FPendDist: LongWord;   // match que el lazo rápido deja para Special
    // --- Tramo pendiente de entregar ---
    FChunk: PByte;
    FChunkLen: SizeInt;
    // --- DataTables ---
    FTables: array of TTornadoTable;
    FTabCount, FTabCap: SizeInt;
    FBaseData, FOriginal: array[0..255] of Byte;
    FBaseDataBytes: SizeInt;

    procedure Init;
    procedure Refill;
    function Get8: LongWord; inline;
    function Get16: LongWord; inline;
    function Get24: LongWord; inline;
    function Get32: LongWord; inline;
    function GetBitsBit(n: Integer): LongWord; inline;
    procedure HufBuildTree(RescaleMode: Integer);
    function HufDecode: LongWord; inline;
    procedure ArithRescale;
    function ArithGetCount(Bits: Integer): LongWord; inline;
    procedure ArithUpdate(Cum, Cnt: LongWord); inline;
    function ArithDecode: LongWord; inline;
    function ArithGetBits(n: Integer): LongWord;
    procedure LZMatch(x: LongWord; out Len, Dist: LongWord);
    function NextByte(out Len, Dist: LongWord): Boolean; inline;
    function NextBit(out Len, Dist: LongWord): Boolean; inline;
    procedure TabAdd(Typ: SizeInt; Start: SizeInt; Len: SizeInt);
    procedure TabProcess(Undiff: Boolean; WriteEnd: SizeInt);
    procedure TabUndiffAll(WriteStart, WriteEnd: SizeInt);
    procedure TabDiffAll(WriteStart, WriteEnd: SizeInt);
    procedure TabShift(OldPos: SizeInt);
    procedure StartWrite;
    procedure EndWrite;
    function SlowCopy(var o: SizeInt; p: SizeInt): Boolean;
    function Special(len, dist: LongWord; var o: SizeInt): Boolean;
    procedure Run;
    procedure RunHuf;
    procedure RunArith;
    function RunHufFast: Integer;
    function RunByteFast: Integer;
    function RunBitFast: Integer;
    function RunHufFastPas: Integer;
    function RunArithFast: Integer;
    function RunArithFastPas: Integer;
  public
    constructor Create(ASource: TInStage; AllAtOnce: Boolean = False);
    destructor Destroy; override;
    function Read(Buf: PByte; Count: SizeInt): SizeInt; override;
    { Siguiente tramo tal como lo escribiría el C (puede tener largo 0); False al terminar. }
    function NextChunk(out P: PByte; out Len: SizeInt): Boolean;
  end;

{ Memoria a memoria, como TORNADO_METHOD::DeCompressMem dentro de 4x4 (AllAtOnce=True).
  False si la salida no entra en DstCap (FREEARC_ERRCODE_OUTBLOCK_TOO_SMALL; DstLen = lo escrito
  hasta ahí). Datos corruptos: EArcCorrupt. }
function TornadoDecodeMem(Src: PByte; SrcLen: SizeInt; Dst: PByte; DstCap: SizeInt; out DstLen: SizeInt): Boolean;

implementation

uses
  parc_bytes;

const
  // LZ77_Coder.cpp
  IMPOSSIBLE_LEN  = $3FFFFFFF;   // INT_MAX/2
  IMPOSSIBLE_DIST = $3FFFFFFF;
  REPDIST_CODES = 4;
  LEN_CODES = 16;
  EOB_CODE = 256 + LEN_CODES * (32 + REPDIST_CODES);   // 832
  REPCHAR = EOB_CODE + 1;
  CODES = EOB_CODE + 10;
  // DataTables.cpp
  MAX_TABLE_ROW = 64;            // máximo que genera el compresor (el C acepta hasta 256)
  PAD_FOR_TABLES = 256 * 2;
  // Compression.h
  LARGE_BUFFER_SIZE = 256 * 1024;
  HUGE_BUFFER_SIZE = 8 * 1024 * 1024;
  // EntropyCoder.cpp
  MAXHUF = 2048;
  FAST_BITS = 11;
  HUFBLOCKSIZE = 5000;
  HUF_CHUNKS = 250;
  NUM = 2048;
  INDEXES = 2048;
  RANGE_BITS = 14;
  RANGE = 1 shl RANGE_BITS;
  // Entrada
  IN_BUF = 1 shl 16;
  MAX_OVERRUN = 64;              // bytes que se toleran leer después del fin (el C lee basura)

  extra_lbits: array[0..7] of Byte = (0, 0, 0, 1, 2, 4, 8, 30);
  extra_lbits2: array[0..15] of Byte = (0, 0, 0, 0, 0, 0, 0, 1, 1, 2, 2, 3, 3, 4, 8, 30);
  extra_dbits: array[0..31] of Byte = (4, 4, 5, 5, 5, 6, 6, 7, 7, 8, 8, 9, 9, 10, 10, 11, 11, 12,
    12, 13, 13, 14, 14, 15, 15, 16, 17, 18, 19, 21, 23, 30);

var
  lc_base: array[0..7] of LongWord;
  lc2_base: array[0..15] of LongWord;
  dc_base: array[0..31] of LongWord;

{ VLE::VLE y DistanceCoder::DistanceCoder (LZ77_Coder.cpp): solo base_value, que es lo que usa
  el decodificador. }
procedure InitTables;
var
  code: Integer;
  v, dist: LongWord;
begin
  v := 0;
  for code := 0 to 7 do begin lc_base[code] := v; Inc(v, LongWord(1) shl extra_lbits[code]); end;
  v := 0;
  for code := 0 to 15 do begin lc2_base[code] := v; Inc(v, LongWord(1) shl extra_lbits2[code]); end;
  dist := 0; code := 0;
  while dist < 512 do
  begin
    dc_base[code] := dist; Inc(dist, LongWord(1) shl extra_dbits[code]); Inc(code);
  end;
  dist := dist shr 8;
  while dist < 512 do
  begin
    dc_base[code] := dist shl 8; Inc(dist, LongWord(1) shl (extra_dbits[code] - 8)); Inc(code);
  end;
  dist := dist shr 8;
  while code < 32 do
  begin
    dc_base[code] := dist shl 16; Inc(dist, LongWord(1) shl (extra_dbits[code] - 16)); Inc(code);
  end;
end;

{ Lector sin copia sobre un buffer ajeno (para TornadoDecodeMem). }
type
  TPtrStage = class(TInStage)
  private
    FP: PByte;
    FLeft: SizeInt;
  public
    constructor Create(P: PByte; Len: SizeInt);
    function Read(Buf: PByte; Count: SizeInt): SizeInt; override;
  end;

constructor TPtrStage.Create(P: PByte; Len: SizeInt);
begin
  inherited Create(nil);
  FP := P;
  FLeft := Len;
end;

function TPtrStage.Read(Buf: PByte; Count: SizeInt): SizeInt;
begin
  Result := FLeft;
  if Result > Count then Result := Count;
  if Result <= 0 then Exit(0);
  Move(FP^, Buf^, Result);
  Inc(FP, Result);
  Dec(FLeft, Result);
end;

{ ---------------------------------------------------------------------------------------------- }

constructor TTornadoStage.Create(ASource: TInStage; AllAtOnce: Boolean);
begin
  // Nada que pueda fallar acá: el encabezado se lee en el primer Read (ver parc_lzma sobre la
  // doble liberación de la fuente si el constructor lanza)
  inherited Create(ASource);
  FAllAtOnce := AllAtOnce;
end;

destructor TTornadoStage.Destroy;
begin
  if FMem <> nil then FreeMem(FMem);
  inherited Destroy;
end;

{ ---- InputByteStream (EntropyCoder.cpp) ---- }

{ InputByteStream::fill. El C sigue leyendo basura después del fin de los datos; acá se leen
  ceros y, pasado MAX_OVERRUN, se declara el stream truncado (evita bucles infinitos). }
procedure TTornadoStage.Refill;
var
  n: SizeInt;
begin
  if not FInEof then
  begin
    n := FInEnd - FInPos;
    if n > 0 then Move(FIn[FInPos], FIn[0], n) else n := 0;
    FInEnd := n; FInPos := 0;
    repeat
      n := Source.Read(@FIn[FInEnd], IN_BUF - FInEnd);
      if n <= 0 then begin FInEof := True; Break; end;
      Inc(FInEnd, n);
    until FInEnd >= 4;
    if FInEof then
    begin
      FillChar(FIn[FInEnd], MAX_OVERRUN + 8, 0);
      FInLim := FInEnd + MAX_OVERRUN;
    end
    else
      FInLim := FInEnd - 4;
  end;
  if FInPos > FInLim then Corrupt('tor: datos truncados');
end;

function TTornadoStage.Get8: LongWord;
begin
  if FInPos > FInLim then Refill;
  Result := FIn[FInPos];
  Inc(FInPos);
end;

function TTornadoStage.Get16: LongWord;
begin
  if FInPos > FInLim then Refill;
  Result := LongWord(FIn[FInPos]) or (LongWord(FIn[FInPos + 1]) shl 8);
  Inc(FInPos, 2);
end;

function TTornadoStage.Get24: LongWord;
begin
  if FInPos > FInLim then Refill;
  Result := LongWord(FIn[FInPos]) or (LongWord(FIn[FInPos + 1]) shl 8) or (LongWord(FIn[FInPos + 2]) shl 16);
  Inc(FInPos, 3);
end;

function TTornadoStage.Get32: LongWord;
begin
  if FInPos > FInLim then Refill;
  Result := {$IFDEF ENDIAN_LITTLE}PLongWord(@FIn[FInPos])^{$ELSE}LongWord(FIn[FInPos]) or
    (LongWord(FIn[FInPos + 1]) shl 8) or (LongWord(FIn[FInPos + 2]) shl 16) or (LongWord(FIn[FInPos + 3]) shl 24){$ENDIF};
  Inc(FInPos, 4);
end;

{ ---- InputBitStream (EntropyCoder.cpp) ---- }

{ InputBitStream::needbits + dumpbits (n <= 30 en todos los usos). Get32 va escrito a mano:
  FPC no expande un inline dentro de otro (lo mismo en HufDecode). }
function TTornadoStage.GetBitsBit(n: Integer): LongWord;
begin
  if FBitCount <= 32 then
  begin
    if FInPos > FInLim then Refill;
    FBitBuf := FBitBuf or (QWord({$IFDEF ENDIAN_LITTLE}PLongWord(@FIn[FInPos])^{$ELSE}LongWord(FIn[FInPos]) or
      (LongWord(FIn[FInPos + 1]) shl 8) or (LongWord(FIn[FInPos + 2]) shl 16) or (LongWord(FIn[FInPos + 3]) shl 24){$ENDIF}) shl FBitCount);
    Inc(FInPos, 4);
    Inc(FBitCount, 32);
  end;
  Result := LongWord(FBitBuf) and ((LongWord(1) shl n) - 1);
  FBitBuf := FBitBuf shr n;
  Dec(FBitCount, n);
end;

{ ---- HuffmanTree / HuffmanDecoder (EntropyCoder.cpp) ---- }

{ HuffmanTree::build_tree, rama Decoder. Diferencias (solo afectan datos corruptos):
  maxbits es el máximo real de bits (el C toma bits del símbolo menos frecuente, que en un árbol
  de Huffman válido es lo mismo) y se exige <= 30; las claves de orden van en 64 bits.
  Los nodos van en arreglos separados (FNCnt/FNLeft/FNRight/FNBits/FNCode) y los lazos con
  punteros: se reconstruye cada HUFBLOCKSIZE símbolos. }
procedure TTornadoStage.HufBuildTree(RescaleMode: Integer);
var
  places: array[0..HUF_CHUNKS] of LongInt;
  b, i, j, k, p1, p2, p3, r, n, sbits, maxbits, factor: SizeInt;
  c, c1, c2, bb, code, scode, step: LongWord;
  key: QWord;
  cnt, pcnt, plf, prt, pbits, pcode: PLongWord;
  fast: PSmallInt;
  idx: PWord;
begin
  n := CODES;
  b := n;
  cnt := @FHufCounter[0];
  pcnt := @FNCnt[0];
  plf := @FNLeft[0];
  prt := @FNRight[0];
  pbits := @FNBits[0];
  pcode := @FNCode[0];
  FillChar(places, SizeOf(places), 0);
  for i := 0 to n - 1 do
  begin
    c := cnt[i];
    if c < HUF_CHUNKS then Inc(places[c + 1]);
  end;
  for i := 0 to HUF_CHUNKS - 1 do Inc(places[i + 1], places[i]);
  r := 0;
  for i := 0 to n - 1 do
  begin
    c := cnt[i];
    if c < HUF_CHUNKS then
    begin
      k := places[c];
      places[c] := k + 1;
      pcnt[k] := c;
      plf[k] := i;
    end
    else
    begin
      FRest[r] := QWord(c) * MAXHUF + QWord(i);
      Inc(r);
    end;
  end;
  // Orden por (contador, índice): claves únicas, así que cualquier orden da lo mismo que qsort
  for i := 1 to r - 1 do
  begin
    key := FRest[i];
    j := i - 1;
    while (j >= 0) and (FRest[j] > key) do
    begin
      FRest[j + 1] := FRest[j];
      Dec(j);
    end;
    FRest[j + 1] := key;
  end;
  k := places[HUF_CHUNKS];
  for i := 0 to r - 1 do
  begin
    pcnt[k + i] := LongWord(FRest[i] div MAXHUF);
    plf[k + i] := FRest[i] mod MAXHUF;
  end;

  for i := 0 to b + 3 do pcnt[b + i] := High(LongInt);   // centinelas INT_MAX
  p1 := 0; p2 := b + 2; p3 := b + 2;
  while not ((p1 = b) and (p3 - p2 = 1)) do
  begin
    c1 := pcnt[p1];
    c2 := pcnt[p2];
    if pcnt[p1 + 1] < c2 then
    begin
      pcnt[p3] := c1 + pcnt[p1 + 1];
      plf[p3] := p1; prt[p3] := p1 + 1;
      Inc(p1, 2);
    end
    else if c1 > pcnt[p2 + 1] then
    begin
      pcnt[p3] := c2 + pcnt[p2 + 1];
      plf[p3] := p2; prt[p3] := p2 + 1;
      Inc(p2, 2);
    end
    else
    begin
      pcnt[p3] := c1 + c2;
      plf[p3] := p1; prt[p3] := p2;
      Inc(p1); Inc(p2);
    end;
    Inc(p3);
  end;

  pbits[p2] := 0;
  pcode[p2] := 0;
  maxbits := 0;
  for i := p2 downto b + 2 do
  begin
    bb := pbits[i];
    if bb >= 31 then Corrupt('tor: huffman tree too deep');
    code := pcode[i];
    pbits[plf[i]] := bb + 1;
    pcode[plf[i]] := code;
    pbits[prt[i]] := bb + 1;
    pcode[prt[i]] := code + (LongWord(1) shl bb);
  end;
  for i := 0 to b - 1 do
    if SizeInt(pbits[i]) > maxbits then maxbits := pbits[i];
  // Un stream válido no pasa de ~23 bits (contadores acotados por HUFBLOCKSIZE y el rescale);
  // el tope limita la tabla index[] a 128MB con datos corruptos
  if maxbits > 26 then Corrupt('tor: huffman tree too deep');
  FHufMaxBits := maxbits;
  FHufMask := (LongWord(1) shl maxbits) - 1;
  if maxbits > FHufMaxSoFar then
  begin
    FHufMaxSoFar := maxbits;
    SetLength(FHufIndex, 1 shl maxbits);
  end;
  fast := @FHufFast[0];
  idx := @FHufIndex[0];
  for i := 0 to b - 1 do
  begin
    k := plf[i];
    sbits := pbits[i];
    scode := pcode[i];
    FHufBits[k] := sbits;
    step := LongWord(1) shl sbits;
    if sbits <= FAST_BITS then
    begin
      while scode < (1 shl FAST_BITS) do
      begin
        fast[scode] := k;
        Inc(scode, step);
      end;
    end
    else
    begin
      fast[scode and ((1 shl FAST_BITS) - 1)] := -1;
      while scode < (LongWord(1) shl maxbits) do
      begin
        idx[scode] := k;
        Inc(scode, step);
      end;
    end;
  end;
  // rescale(FACTOR); el 6 (rescale_mode 3) es el de todos los bloques salvo el primero
  case RescaleMode of
    0: factor := 2;  1: factor := 3;  2: factor := 4;  3: factor := 6;
    4: factor := 8;  5: factor := 10; 6: factor := 12; 7: factor := 16;
  else
    factor := 0;
  end;
  if factor = 6 then
    for i := 0 to n - 1 do
    begin
      c := cnt[i];
      if (c > 1) and (c < 6) then cnt[i] := c - 1
      else cnt[i] := c - c div 6;
    end
  else if factor > 0 then
    for i := 0 to n - 1 do
    begin
      c := cnt[i];
      if (c > 1) and (c < LongWord(factor)) then cnt[i] := c - 1
      else cnt[i] := c - c div LongWord(factor);
    end;
end;

{ HuffmanDecoder::decode }
function TTornadoStage.HufDecode: LongWord;
var
  c: LongWord;
  x: Integer;
begin
  while True do
  begin
    // needbits(maxbits), escrito a mano
    if FBitCount <= 32 then
    begin
      if FInPos > FInLim then Refill;
      FBitBuf := FBitBuf or (QWord({$IFDEF ENDIAN_LITTLE}PLongWord(@FIn[FInPos])^{$ELSE}LongWord(FIn[FInPos]) or
        (LongWord(FIn[FInPos + 1]) shl 8) or (LongWord(FIn[FInPos + 2]) shl 16) or (LongWord(FIn[FInPos + 3]) shl 24){$ENDIF}) shl FBitCount);
      Inc(FInPos, 4);
      Inc(FBitCount, 32);
    end;
    c := LongWord(FBitBuf) and ((LongWord(1) shl FHufMaxBits) - 1);
    x := FHufFast[c and ((1 shl FAST_BITS) - 1)];
    if x < 0 then x := FHufIndex[c];
    FBitBuf := FBitBuf shr FHufBits[x];
    Dec(FBitCount, FHufBits[x]);
    if x <> EOB_CODE then Break;
    HufBuildTree(GetBitsBit(3));
    FHufBlock := 0;
  end;
  Inc(FHufCounter[x]);
  // El compresor emite EOB cada HUFBLOCKSIZE símbolos; sin este límite un stream corrupto
  // podría desbordar los contadores
  Inc(FHufBlock);
  if FHufBlock > 2 * HUFBLOCKSIZE then Corrupt('tor: huffman block without EOB');
  Result := x;
end;

{ ---- TRangeDecoder / TCounter / ArithDecoder (EntropyCoder.cpp) ---- }

{ TCounter::Rescale, rama Decoder }
procedure TTornadoStage.ArithRescale;
var
  total, hi, lv: LongWord;
  s, ind: Integer;
begin
  total := 0;
  FARemainder := RANGE;
  ind := 0;
  for s := 0 to CODES - 1 do
  begin
    lv := FALive[s];
    FACnt[s] := lv;
    FACum[s] := total;
    Inc(total, lv);
    if (lv > 1) and (lv < 6) then Dec(lv) else Dec(lv, lv div 6);
    FALive[s] := lv;
    Dec(FARemainder, lv);
    // index[ind] = primer símbolo cuyo rango llega a RANGE/INDEXES*ind
    hi := total - 1;                  // = cum[s]+cnt[s]-1
    while (ind < INDEXES) and (LongWord(ind) * (RANGE div INDEXES) <= hi) do
    begin
      FAIndex[ind] := s;
      Inc(ind);
    end;
  end;
end;

{ TRangeDecoder::GetCount (el C hace exit(1) si count se sale de rango) }
function TTornadoStage.ArithGetCount(Bits: Integer): LongWord;
begin
  FRange := FRange shr Bits;
  Result := FCode div FRange;
  if Result >= (LongWord(1) shl Bits) then Corrupt('tor: arithmetic decoder error');
end;

{ TRangeDecoder::Update }
procedure TTornadoStage.ArithUpdate(Cum, Cnt: LongWord);
begin
  FCode := FCode - Cum * FRange;
  FRange := FRange * Cnt;
  while FRange < (1 shl 24) do
  begin
    FRange := FRange shl 8;
    if FInPos > FInLim then Refill;
    FCode := (FCode shl 8) + FIn[FInPos];
    Inc(FInPos);
  end;
end;

{ ArithDecoder::decode + TCounter::Decode/Inc }
function TTornadoStage.ArithDecode: LongWord;
var
  count, s: LongWord;
begin
  // GetCount(RANGE_BITS) y Update escritos a mano (FPC no expande inline dentro de inline)
  FRange := FRange shr RANGE_BITS;
  count := FCode div FRange;
  if count >= RANGE then Corrupt('tor: arithmetic decoder error');
  s := FAIndex[count div (RANGE div INDEXES)];
  while FACum[s] + FACnt[s] - 1 < count do Inc(s);   // termina: sum(cnt) = RANGE > count
  FCode := FCode - FACum[s] * FRange;
  FRange := FRange * FACnt[s];
  while FRange < (1 shl 24) do
  begin
    FRange := FRange shl 8;
    if FInPos > FInLim then Refill;
    FCode := (FCode shl 8) + FIn[FInPos];
    Inc(FInPos);
  end;
  Inc(FALive[s]);
  Dec(FARemainder);
  if FARemainder = 0 then ArithRescale;
  Result := s;
end;

{ ArithDecoder::getbits. GetCount/Update escritos a mano para que se expanda en LZMatch.
  Con n=0 GetCount+Update no cambian el estado (range ya está normalizado): solo queda el
  control de rango de GetCount. }
function TTornadoStage.ArithGetBits(n: Integer): LongWord;
var
  x1, x2: LongWord;
begin
  if n = 0 then
  begin
    if FCode >= FRange then Corrupt('tor: arithmetic decoder error');
    Exit(0);
  end;
  if n <= 24 then
  begin
    Result := ArithGetCount(n);
    ArithUpdate(Result, 1);
  end
  else
  begin
    x1 := ArithGetCount(15);
    ArithUpdate(x1, 1);
    x2 := ArithGetCount(n - 15);
    ArithUpdate(x2, 1);
    Result := (x2 shl 15) + x1;
  end;
end;

{ tor_decompress + constructores de los decodificadores (Tornado.cpp, EntropyCoder.cpp). }
procedure TTornadoStage.Init;
var
  hdr: array[0..1] of Byte;
  bs: LongWord;
  s, i: Integer;
begin
  FInit := True;
  if not Source.ReadExactOrEof(@hdr[0], 2) then Corrupt('tor: empty stream');
  bs := Source.ReadU32;
  FMethod := hdr[0];
  FMinLen := hdr[1];
  if (FMethod < 1) or (FMethod > 4) then Corrupt('tor: codificador desconocido');
  // _bufsize es int en el C; negativo no tiene sentido
  if bs > LongWord(High(LongInt)) then Corrupt('tor: invalid buffer size');
  FHdrBufSize := bs;
  // tornado_decompressor_outbuf_size
  if FAllAtOnce then FBufSize := SizeInt(bs) + SizeInt(bs div 8) + 512
  else if bs > LARGE_BUFFER_SIZE then FBufSize := bs
  else FBufSize := LARGE_BUFFER_SIZE;
  FMem := GetMem(FBufSize + PAD_FOR_TABLES * 2);
  FillChar(FMem^, PAD_FOR_TABLES, 0);
  FillChar(FMem[FBufSize + PAD_FOR_TABLES], PAD_FOR_TABLES, 0);
  FOut := FMem + PAD_FOR_TABLES;
  FOutput := 0;
  FWriteStart := 0;
  if FBufSize < HUGE_BUFFER_SIZE then FWriteEnd := FBufSize else FWriteEnd := HUGE_BUFFER_SIZE;
  if FAllAtOnce then FWriteEnd := FBufSize + 1;
  FTabCap := 10000;
  SetLength(FTables, FTabCap);

  SetLength(FIn, IN_BUF + MAX_OVERRUN + 16);
  FInPos := 0; FInEnd := 0; FInLim := -1;

  case FMethod of
    1: FFlagPos := 1;
    3:
      begin
        // HuffmanTree::init
        for s := 0 to CODES - 1 do FHufCounter[s] := 1;
        HufBuildTree(0);
      end;
    4:
      begin
        // TCounter::TCounter
        for s := 0 to CODES - 1 do
        begin
          FALive[s] := RANGE div CODES;
          if s < RANGE - RANGE div CODES * CODES then Inc(FALive[s]);
        end;
        ArithRescale;
        // TRangeDecoder::TRangeDecoder
        FRange := $FFFFFFFF;
        for i := 0 to 4 do FCode := (FCode shl 8) + Get8;
      end;
  end;
  // LZ77_Decoder::LZ77_Decoder
  for i := 0 to REPDIST_CODES - 1 do FPrevDists[i] := 0;
  FPrev := REPDIST_CODES;
end;

{ ---- Decodificadores LZ77 (LZ77_Coder.cpp) ---- }

{ LZ77_Decoder<HuffmanDecoder|ArithDecoder>: getlen + getdist para un código x >= 256
  (is_literal/getchar están en Run). }
procedure TTornadoStage.LZMatch(x: LongWord; out Len, Dist: LongWord);
var
  lcode, l: LongWord;
  dcode, d: LongInt;
begin
  if x = REPCHAR then
  begin
    Len := 1;
    Dist := LongWord(FPrevDists[FPrev - 1]);
    Exit;
  end;
  // EOB no llega acá con huffman; con aritmético y los códigos de reserva el C indexaría las
  // tablas de distancias fuera de rango
  if x >= EOB_CODE then Corrupt('tor: invalid code');
  // getlen
  lcode := x mod LEN_CODES;
  if FMethod = 4 then l := lc2_base[lcode] + ArithGetBits(extra_lbits2[lcode])
  else l := lc2_base[lcode] + GetBitsBit(extra_lbits2[lcode]);
  if l > 100 then
  begin
    if l <= 104 then Len := l - 100 + IMPOSSIBLE_LEN
    else Len := l - 4 + FMinLen;
  end
  else
    Len := l + FMinLen;
  // getdist
  dcode := LongInt(x - 256) div LEN_CODES - REPDIST_CODES;
  if dcode < 0 then
  begin
    case dcode of
      -4: d := FPrevDists[FPrev - 1];
      -3:
        begin
          d := FPrevDists[FPrev - 2];
          FPrevDists[FPrev - 2] := FPrevDists[FPrev - 1];
          FPrevDists[FPrev - 1] := d;
        end;
      -2:
        begin
          d := FPrevDists[FPrev - 3];
          FPrevDists[FPrev - 3] := FPrevDists[FPrev - 2];
          FPrevDists[FPrev - 2] := FPrevDists[FPrev - 1];
          FPrevDists[FPrev - 1] := d;
        end;
    else
      begin
        d := FPrevDists[FPrev - 4];
        FPrevDists[FPrev - 4] := FPrevDists[FPrev - 3];
        FPrevDists[FPrev - 3] := FPrevDists[FPrev - 2];
        FPrevDists[FPrev - 2] := FPrevDists[FPrev - 1];
        FPrevDists[FPrev - 1] := d;
      end;
    end;
    Dist := LongWord(d);
    Exit;
  end;
  if FMethod = 4 then d := LongInt(dc_base[dcode] + ArithGetBits(extra_dbits[dcode]) + 1)
  else d := LongInt(dc_base[dcode] + GetBitsBit(extra_dbits[dcode]) + 1);
  if FPrev = Length(FPrevDists) then
  begin
    FPrevDists[0] := FPrevDists[Length(FPrevDists) - 3];
    FPrevDists[1] := FPrevDists[Length(FPrevDists) - 2];
    FPrevDists[2] := FPrevDists[Length(FPrevDists) - 1];
    FPrev := REPDIST_CODES - 1;
  end;
  FPrevDists[FPrev] := d;
  Inc(FPrev);
  Dist := LongWord(d);
end;

{ LZ77_ByteDecoder }
function TTornadoStage.NextByte(out Len, Dist: LongWord): Boolean;
var
  x, l, d: LongWord;
begin
  Dec(FFlagPos);
  if FFlagPos <> 0 then FFlags := FFlags shr 2
  else
  begin
    FFlagPos := 16;
    FFlags := Get32;
  end;
  if (FFlags and 3) = 0 then
  begin
    Len := Get8;
    Exit(True);
  end;
  Result := False;
  case FFlags and 3 of
    1: begin x := Get16; l := x shr 12; d := x and $FFF; end;
    2: begin x := Get24; l := x shr 18; d := x and $3FFFF; end;
  else
    begin
      l := Get8;
      if l = 255 then
      begin
        d := Get8 shl 24;
        l := Get8;
      end
      else
        d := 0;
      if l = 254 then
      begin
        l := Get24 shl 8;
        l := l + Get8;
      end;
      d := d + Get24;
    end;
  end;
  Len := FMinLen + l;
  Dist := d;
end;

{ LZ77_BitDecoder }
function TTornadoStage.NextBit(out Len, Dist: LongWord): Boolean;
var
  x, lcode, dcode: LongWord;
begin
  x := GetBitsBit(9);
  if x < 256 then
  begin
    Len := x;
    Exit(True);
  end;
  Result := False;
  lcode := (x shr 5) - 8;
  Len := FMinLen + lc_base[lcode] + GetBitsBit(extra_lbits[lcode]);
  dcode := x and 31;
  Dist := dc_base[dcode] + GetBitsBit(extra_dbits[dcode]);
end;

{ ---- DataTables (DataTables.cpp) ---- }

{ diff_table / undiff_table: índices relativos a outbuf, orden de bytes LSB primero. }
procedure DiffTable(Base: PByte; N, Start, Len: SizeInt);
var
  r, i, e: SizeInt;
  prev, v: LongWord;
  carry, newcarry, t: Integer;
begin
  e := Start + N * Len;
  case N of
    2:
      begin
        r := Start;
        prev := Base[r] or (LongWord(Base[r + 1]) shl 8);
        Inc(r, 2);
        while r < e do
        begin
          v := Base[r] or (LongWord(Base[r + 1]) shl 8);
          t := Integer((v - prev) and $FFFF);
          Base[r] := Byte(t); Base[r + 1] := Byte(t shr 8);
          prev := v;
          Inc(r, 2);
        end;
      end;
    4:
      begin
        r := Start;
        prev := PLongWord(Base + r)^;
        Inc(r, 4);
        while r < e do
        begin
          v := PLongWord(Base + r)^;
          PLongWord(Base + r)^ := v - prev;
          prev := v;
          Inc(r, 4);
        end;
      end;
  else
    begin
      r := e;
      Dec(r, N);
      while r > Start do
      begin
        carry := 0;
        for i := 0 to N - 1 do
        begin
          t := Base[r + i - N] + carry;
          if Base[r + i] < t then newcarry := 1 else newcarry := 0;
          Base[r + i] := Byte(Base[r + i] - t);
          carry := newcarry;
        end;
        Dec(r, N);
      end;
    end;
  end;
end;

procedure UndiffTable(Base: PByte; N, Start, Len: SizeInt);
var
  r, i, e: SizeInt;
  v: LongWord;
  carry, t: Integer;
begin
  e := Start + N * Len;
  case N of
    2:
      begin
        r := Start;
        v := Base[r] or (LongWord(Base[r + 1]) shl 8);
        Inc(r, 2);
        while r < e do
        begin
          v := (v + (Base[r] or (LongWord(Base[r + 1]) shl 8))) and $FFFF;
          Base[r] := Byte(v); Base[r + 1] := Byte(v shr 8);
          Inc(r, 2);
        end;
      end;
    4:
      begin
        r := Start;
        v := PLongWord(Base + r)^;
        Inc(r, 4);
        while r < e do
        begin
          v := v + PLongWord(Base + r)^;
          PLongWord(Base + r)^ := v;
          Inc(r, 4);
        end;
      end;
  else
    begin
      r := Start + N;
      while r < e do
      begin
        carry := 0;
        for i := 0 to N - 1 do
        begin
          t := Base[r + i] + Base[r + i - N] + carry;
          Base[r + i] := Byte(t);
          carry := t div 256;
        end;
        Inc(r, N);
      end;
    end;
  end;
end;

{ DataTables::add }
procedure TTornadoStage.TabAdd(Typ: SizeInt; Start: SizeInt; Len: SizeInt);
begin
  if FTabCount >= FTabCap then
  begin
    FTabCap := FTabCap * 2;
    SetLength(FTables, FTabCap);
  end;
  FTables[FTabCount].Typ := Typ;
  FTables[FTabCount].Start := Start;
  FTables[FTabCount].Len := Len;
  Inc(FTabCount);
end;

{ DataTables::process_tables }
procedure TTornadoStage.TabProcess(Undiff: Boolean; WriteEnd: SizeInt);
var
  k, n, lim: SizeInt;
begin
  // Sin `with`: el campo Len taparía la variable local
  for k := 0 to FTabCount - 1 do
  begin
    // Se trunca la cantidad de elementos si la tabla sigue después de WriteEnd
    n := FTables[k].Len;
    lim := 1 + (WriteEnd - FTables[k].Start) div FTables[k].Typ;
    if lim < n then n := lim;
    if Undiff then UndiffTable(FOut, FTables[k].Typ, FTables[k].Start, n)
    else DiffTable(FOut, FTables[k].Typ, FTables[k].Start, n);
  end;
end;

{ DataTables::undiff_tables }
procedure TTornadoStage.TabUndiffAll(WriteStart, WriteEnd: SizeInt);
begin
  if (FTabCount > 0) and (FTables[0].Start < WriteStart) then
  begin
    FBaseDataBytes := WriteStart - FTables[0].Start;
    if FTables[0].Typ < FBaseDataBytes then FBaseDataBytes := FTables[0].Typ;
    Move(FOut[FTables[0].Start], FOriginal[0], FBaseDataBytes);
    Move(FBaseData[0], FOut[FTables[0].Start], FBaseDataBytes);
  end;
  TabProcess(True, WriteEnd);
end;

{ DataTables::diff_tables }
procedure TTornadoStage.TabDiffAll(WriteStart, WriteEnd: SizeInt);
var
  p: TTornadoTable;
  processed: SizeInt;
begin
  if FTabCount > 0 then
  begin
    p := FTables[FTabCount - 1];
    processed := (WriteEnd - p.Start) div p.Typ;
    if processed < p.Len then
    begin
      // Quedan dos elementos más: uno como base del undiff y otro que puede estar partido
      processed := processed - 2;
      if processed < 0 then processed := 0;
      Inc(p.Start, processed * p.Typ);
      Dec(p.Len, processed);
      Move(FOut[p.Start], FBaseData[0], p.Typ);
      TabProcess(False, WriteEnd);
      if FTables[0].Start < WriteStart then
        Move(FOriginal[0], FOut[FTables[0].Start], FBaseDataBytes);
      FTables[0] := p;
      FTabCount := 1;
      Exit;
    end;
  end;
  TabProcess(False, WriteEnd);
  if (FTabCount > 0) and (FTables[0].Start < WriteStart) then
    Move(FOriginal[0], FOut[FTables[0].Start], FBaseDataBytes);
  FTabCount := 0;
end;

{ DataTables::shift (new_pos = outbuf = índice 0) }
procedure TTornadoStage.TabShift(OldPos: SizeInt);
var
  k, old: SizeInt;
begin
  for k := 0 to FTabCount - 1 do
  begin
    old := FTables[k].Start;
    Dec(FTables[k].Start, OldPos);
    // Los primeros bytes de la tabla (del tramo anterior) van *antes* del inicio del buffer
    if FTables[k].Start < 0 then
    begin
      if FTables[k].Start < -PAD_FOR_TABLES then Corrupt('tor: tabla fuera del buffer');
      Move(FOut[old], FOut[FTables[k].Start], -FTables[k].Start);
    end;
  end;
end;

{ ---- Bucle principal (tor_decompress0, Tornado.cpp) ---- }

{ Primera mitad de WRITE_DATA_IF: undiff y entrega del tramo [write_start, output). }
procedure TTornadoStage.StartWrite;
begin
  TabUndiffAll(FWriteStart, FOutput);
  FChunk := FOut + FWriteStart;
  FChunkLen := FOutput - FWriteStart;
  FPending := True;
end;

{ Segunda mitad de WRITE_DATA_IF, cuando el consumidor ya copió el tramo. }
procedure TTornadoStage.EndWrite;
var
  n: SizeInt;
begin
  TabDiffAll(FWriteStart, FOutput);
  FWriteStart := FOutput;
  if FOutput >= FBufSize then
  begin
    FOffsetOverflow := FOffsetOverflow or (FOffset > (QWord(1) shl 63));
    Inc(FOffset, QWord(FOutput));
    Dec(FWriteStart, FOutput);
    Dec(FWriteEnd, FOutput);
    TabShift(FOutput);
    FOutput := 0;
  end;
  if FWriteStart >= FWriteEnd then
  begin
    n := FBufSize - FWriteStart;
    if n > HUGE_BUFFER_SIZE then n := HUGE_BUFFER_SIZE;
    FWriteEnd := FWriteStart + n;
  end;
end;

{ Copia de un match simple (tor_decompress0): origen y destino dentro del buffer, sin cruzar
  write_end. Con solapamiento (dist < len) tiene que ser byte a byte. }
procedure CopyMatch(d: PByte; dist, len: SizeInt); inline;
var
  s: PByte;
  i: SizeInt;
begin
  s := d - dist;
  if (dist >= len) and (len >= 16) then Move(s^, d^, len)
  else
    for i := 0 to len - 1 do d[i] := s[i];
end;

{ Copia de un match lento (en el C, byte a byte): FMatchLeft bytes desde p, que da la vuelta al
  buffer circular, sin pasar de write_end. Va por tramos con Move, cortados donde el origen da la
  vuelta, en write_end y, si el origen está detrás y se solapa, cada `distancia` bytes: el
  resultado es el mismo que byte a byte. True si llegó a write_end (quedó un tramo pendiente). }
function TTornadoStage.SlowCopy(var o: SizeInt; p: SizeInt): Boolean;
var
  n, lim: SizeInt;
begin
  repeat
    n := FMatchLeft;
    lim := FWriteEnd - o;
    if lim < 1 then lim := 1;
    if n > lim then n := lim;
    if n > FBufSize - p then n := FBufSize - p;
    if (p < o) and (o - p < n) then n := o - p;
    Move(FOut[p], FOut[o], n);
    Inc(o, n);
    Inc(p, n);
    if p = FBufSize then p := 0;
    Dec(FMatchLeft, n);
    if o >= FWriteEnd then
    begin
      FOutput := o; FMatchSrc := p;
      StartWrite;
      Exit(True);
    end;
  until FMatchLeft = 0;
  Result := False;
end;

{ Resto de la rama "match" de tor_decompress0: match lento, fin de datos o tabla.
  True si hay que salir de Run (quedó un tramo pendiente de escritura). }
function TTornadoStage.Special(len, dist: LongWord; var o: SizeInt): Boolean;
var
  p: SizeInt;
begin
  Result := False;
  if len < IMPOSSIBLE_LEN then
  begin
    // Validaciones del C, más len=0 y dist=0 (el C copiaría basura o daría la vuelta a len)
    if (len = 0) or (dist = 0) or (SizeInt(dist) > FBufSize) or (Int64(len) > 2 * FHdrBufSize) or
       ((QWord(o) + FOffset < dist) and not FOffsetOverflow) then
      Corrupt('tor: invalid match');
    // Match lento: origen antes del inicio del buffer, que da la vuelta, o que cruza write_end
    if o >= SizeInt(dist) then p := o - SizeInt(dist) else p := o - SizeInt(dist) + FBufSize;
    FMatchLeft := len;
    if SlowCopy(o, p) then Exit(True);
  end
  else if (len = IMPOSSIBLE_LEN) and (dist = IMPOSSIBLE_DIST) then
  begin
    // Fin de datos
    FOutput := o;
    StartWrite;
    FAtEnd := True;
    Exit(True);
  end
  else
  begin
    // Tabla diffeada: len = largo de fila, dist = cantidad de filas
    Dec(len, IMPOSSIBLE_LEN);
    if (len = 0) or (QWord(dist) * len > QWord(2 * FHdrBufSize)) then Corrupt('tor: invalid table');
    if len > MAX_TABLE_ROW then Corrupt('tor: invalid table');
    TabAdd(len, o, dist);
    if (FTabCount = FTabCap) and not FAllAtOnce then
    begin
      FOutput := o;
      StartWrite;
      Exit(True);
    end;
  end;
end;

const
  TD_MARGIN = 32;     // bytes de entrada: más de lo que puede leer un símbolo con largo y distancia
  // Resultado del lazo rápido
  TDR_SLOW = 0; TDR_SPECIAL = 1; TDR_WRITE = 2; TDR_BADCODE = 3; TDR_BADARITH = 4; TDR_BADBLOCK = 5;

{ Decodifica hasta que haga falta escribir (FPending) o termine el stream. Un bucle por
  codificador (en el C, una instancia del template tor_decompress0 por cada uno). }
procedure TTornadoStage.Run;
var
  len, dist: LongWord;
  o, we: SizeInt;
  r: Integer;
  lit: Boolean;
begin
  // Continuar un match lento cortado por una escritura
  if FMatchLeft > 0 then
  begin
    o := FOutput;
    if SlowCopy(o, FMatchSrc) then Exit;
    FOutput := o;
  end;

  o := FOutput;
  we := FWriteEnd;
  case FMethod of
    1, 2:
      repeat
        // El lazo rápido mientras se pueda; cuando no, un símbolo por el camino general
        if FMethod = 1 then r := RunByteFast else r := RunBitFast;
        if r = TDR_SPECIAL then
        begin
          o := FOutput;
          if Special(FPendLen, FPendDist, o) then Exit;
          FOutput := o;
          Continue;
        end;
        o := FOutput;
        if r = TDR_WRITE then Break;
        if FMethod = 1 then lit := NextByte(len, dist) else lit := NextBit(len, dist);
        if lit then
        begin
          FOut[o] := Byte(len);
          Inc(o);
          FOutput := o;
          if o >= we then Break;
        end
        // Match simple (>99% de los casos): `output-outbuf>=dist && write_end-output>len`
        else if (SizeInt(dist) <= o) and (we - o > SizeInt(len)) and (dist <> 0) then
        begin
          CopyMatch(FOut + o, dist, len);
          Inc(o, len);
          FOutput := o;
        end
        else if Special(len, dist, o) then Exit
        else FOutput := o;
      until False;
    3:
      begin
        FOutput := o;
        RunHuf;
        Exit;
      end;
  else
    begin
      FOutput := o;
      RunArith;
      Exit;
    end;
  end;
  // Un literal llegó a write_end
  FOutput := o;
  StartWrite;
end;

{ Lazos rápidos de LZ77_ByteDecoder (c1) y LZ77_BitDecoder (c2), como los de Huffman y
  aritmético (parc_tordec.inc): sin llamadas, con la entrada, la salida y las banderas o el
  flujo de bits en variables locales, y solo mientras queden TD_MARGIN bytes de entrada antes
  de FInLim y el match sea simple. Lo demás va por NextByte/NextBit y Special, el camino de
  siempre: mismos resultados y mismos errores con datos corruptos. }
function TTornadoStage.RunByteFast: Integer;
var
  op, oend, ip, ilsafe, src: PByte;
  flags, x, l, d, len, dist: LongWord;
  fpos: LongInt;
  k: SizeInt;
begin
  Result := TDR_SLOW;
  op := FOut + FOutput;
  oend := FOut + FWriteEnd;
  ip := PByte(FIn) + FInPos;
  ilsafe := PByte(FIn) + FInLim - TD_MARGIN;
  flags := FFlags;
  fpos := FFlagPos;
  repeat
    if ip > ilsafe then Break;
    Dec(fpos);
    if fpos <> 0 then flags := flags shr 2
    else
    begin
      fpos := 16;
      flags := PLongWord(ip)^;
      Inc(ip, 4);
    end;
    case flags and 3 of
      0:
        begin
          op^ := ip^;
          Inc(ip);
          Inc(op);
          if op >= oend then begin Result := TDR_WRITE; Break; end;
          Continue;
        end;
      1:
        begin
          x := PWord(ip)^;
          Inc(ip, 2);
          l := x shr 12;
          d := x and $FFF;
        end;
      2:
        begin
          x := PLongWord(ip)^ and $FFFFFF;
          Inc(ip, 3);
          l := x shr 18;
          d := x and $3FFFF;
        end;
    else
      begin
        l := ip^;
        Inc(ip);
        if l = 255 then
        begin
          d := LongWord(ip[0]) shl 24;
          l := ip[1];
          Inc(ip, 2);
        end
        else
          d := 0;
        if l = 254 then
        begin
          l := ((PLongWord(ip)^ and $FFFFFF) shl 8) + ip[3];
          Inc(ip, 4);
        end;
        d := d + (PLongWord(ip)^ and $FFFFFF);
        Inc(ip, 3);
      end;
    end;
    len := FMinLen + l;
    dist := d;
    if (SizeInt(dist) <= op - FOut) and (oend - op > SizeInt(len)) and (dist <> 0) then
    begin
      src := op - dist;
      k := 0;
      if dist >= 8 then
        while k + 8 <= SizeInt(len) do
        begin
          PQWord(op + k)^ := PQWord(src + k)^;
          Inc(k, 8);
        end;
      while k < SizeInt(len) do
      begin
        op[k] := src[k];
        Inc(k);
      end;
      Inc(op, len);
    end
    else
    begin
      FPendLen := len;
      FPendDist := dist;
      Result := TDR_SPECIAL;
      Break;
    end;
  until False;
  FOutput := op - FOut;
  FInPos := ip - PByte(FIn);
  FFlags := flags;
  FFlagPos := fpos;
end;

function TTornadoStage.RunBitFast: Integer;
var
  op, oend, ip, ilsafe, src: PByte;
  bb: QWord;
  bc: LongInt;
  x, n, len, dist, lcode: LongWord;
  k: SizeInt;
begin
  Result := TDR_SLOW;
  op := FOut + FOutput;
  oend := FOut + FWriteEnd;
  ip := PByte(FIn) + FInPos;
  ilsafe := PByte(FIn) + FInLim - TD_MARGIN;
  bb := FBitBuf;
  bc := FBitCount;
  repeat
    if ip > ilsafe then Break;
    // getbits(9)
    if bc <= 32 then
    begin
      bb := bb or (QWord(PLongWord(ip)^) shl bc);
      Inc(ip, 4);
      Inc(bc, 32);
    end;
    x := LongWord(bb) and 511;
    bb := bb shr 9;
    Dec(bc, 9);
    if x < 256 then
    begin
      op^ := Byte(x);
      Inc(op);
      if op >= oend then begin Result := TDR_WRITE; Break; end;
      Continue;
    end;
    lcode := (x shr 5) - 8;
    n := extra_lbits[lcode];
    if bc <= 32 then
    begin
      bb := bb or (QWord(PLongWord(ip)^) shl bc);
      Inc(ip, 4);
      Inc(bc, 32);
    end;
    len := FMinLen + lc_base[lcode] + (LongWord(bb) and ((LongWord(1) shl n) - 1));
    bb := bb shr n;
    Dec(bc, n);
    x := x and 31;
    n := extra_dbits[x];
    if bc <= 32 then
    begin
      bb := bb or (QWord(PLongWord(ip)^) shl bc);
      Inc(ip, 4);
      Inc(bc, 32);
    end;
    dist := dc_base[x] + (LongWord(bb) and ((LongWord(1) shl n) - 1));
    bb := bb shr n;
    Dec(bc, n);
    if (SizeInt(dist) <= op - FOut) and (oend - op > SizeInt(len)) and (dist <> 0) then
    begin
      src := op - dist;
      k := 0;
      if dist >= 8 then
        while k + 8 <= SizeInt(len) do
        begin
          PQWord(op + k)^ := PQWord(src + k)^;
          Inc(k, 8);
        end;
      while k < SizeInt(len) do
      begin
        op[k] := src[k];
        Inc(k);
      end;
      Inc(op, len);
    end
    else
    begin
      FPendLen := len;
      FPendDist := dist;
      Result := TDR_SPECIAL;
      Break;
    end;
  until False;
  FOutput := op - FOut;
  FInPos := ip - PByte(FIn);
  FBitBuf := bb;
  FBitCount := bc;
end;

{$macro on}
{$define TD_NAME := RunHuf}
{$define TD_FAST := RunHufFast}
{$define TD_FASTPAS := RunHufFastPas}
{$I parc_tordec.inc}
{$define TD_NAME := RunArith}
{$define TD_FAST := RunArithFast}
{$define TD_FASTPAS := RunArithFastPas}
{$define TD_ARITH}
{$I parc_tordec.inc}
{$undef TD_ARITH}
{$macro off}

{ Lazo rápido del codificador aritmético. En x86_64 va en ensamblador: es el mismo algoritmo que
  RunArithFastPas (parc_tordec.inc), pero con range/code, la entrada y la salida en registros
  (FPC las deja en la pila, y en este lazo cada símbolo depende del anterior). Mismas condiciones
  para hacer un símbolo acá y mismos resultados (TDR_*). Con PARC_NOASM, o en otras CPU, va la
  versión en Pascal. Registros: r15 Self, r14 salida, r13 write_end, r12 entrada, rbx límite de
  la entrada, r11d range, r10d code, r9 outbuf. }
function TTornadoStage.RunArithFast: Integer;
{$IF defined(CPUX86_64) and not defined(PARC_NOASM)}
var
  me: TTornadoStage;
  op, oend, ip, ilsafe, outb: PByte;
  plb, pxl, pdb, pxd: Pointer;
  rng, cod, sym, lval, dco, pendlen, penddist: LongWord;
  res: LongInt;
begin
  me := Self;
  outb := FOut;
  op := FOut + FOutput;
  oend := FOut + FWriteEnd;
  ip := PByte(FIn) + FInPos;
  ilsafe := PByte(FIn) + FInLim - TD_MARGIN;
  rng := FRange;
  cod := FCode;
  plb := @lc2_base[0];
  pxl := @extra_lbits2[0];
  pdb := @dc_base[0];
  pxd := @extra_dbits[0];
  res := TDR_SLOW;
  sym := 0; lval := 0; dco := 0; pendlen := 0; penddist := 0;
  asm
    movq    me, %r15
    movq    op, %r14
    movq    oend, %r13
    movq    ip, %r12
    movq    ilsafe, %rbx
    movl    rng, %r11d
    movl    cod, %r10d
    movq    outb, %r9
  .Lta_loop:
    cmpq    %rbx, %r12
    ja      .Lta_slow
    cmpl    $1, TTornadoStage.FARemainder(%r15)
    jbe     .Lta_slow
    // ---- ArithDecode ----
    shrl    $14, %r11d                  // range >>= RANGE_BITS
    movl    %r10d, %eax
    xorl    %edx, %edx
    divl    %r11d                       // count = code / range
    cmpl    $16384, %eax                // count >= RANGE
    jae     .Lta_badarith
    movl    %eax, %ecx
    shrl    $3, %ecx                    // count div (RANGE div INDEXES)
    movzwl  TTornadoStage.FAIndex(%r15,%rcx,2), %esi
  .Lta_srch:
    movl    TTornadoStage.FACum(%r15,%rsi,4), %ecx
    movl    TTornadoStage.FACnt(%r15,%rsi,4), %edi
    leal    -1(%ecx,%edi), %edx
    cmpl    %eax, %edx
    jae     .Lta_found
    incl    %esi
    jmp     .Lta_srch
  .Lta_found:
    imull   %r11d, %ecx
    subl    %ecx, %r10d                 // code -= cum*range
    imull   %edi, %r11d                 // range *= cnt
  .Lta_n1:
    cmpl    $0x1000000, %r11d
    jae     .Lta_n1d
    shll    $8, %r11d
    shll    $8, %r10d
    movzbl  (%r12), %ecx
    addl    %ecx, %r10d
    incq    %r12
    jmp     .Lta_n1
  .Lta_n1d:
    incl    TTornadoStage.FALive(%r15,%rsi,4)
    decl    TTornadoStage.FARemainder(%r15)
    cmpl    $256, %esi
    jae     .Lta_match
    // ---- literal ----
    movb    %sil, (%r14)
    incq    %r14
    cmpq    %r13, %r14
    jb      .Lta_loop
    movl    $2, res                     // TDR_WRITE
    jmp     .Lta_save

    // ---- getbits(n): ecx = n (0..30) -> eax; edx = 0 bien, 1 error. Toca eax, ecx, edx ----
  .Lta_getbits:
    testl   %ecx, %ecx
    jnz     .Lta_gb1
    xorl    %eax, %eax
    xorl    %edx, %edx
    cmpl    %r11d, %r10d                // n=0: solo el control code < range
    setae   %dl
    ret
  .Lta_gb1:
    cmpl    $24, %ecx
    ja      .Lta_gb2
    shrl    %cl, %r11d
    movl    %r10d, %eax
    xorl    %edx, %edx
    divl    %r11d
    movl    $1, %edx
    shll    %cl, %edx
    cmpl    %edx, %eax
    jae     .Lta_gberr
    movl    %eax, %edx
    imull   %r11d, %edx
    subl    %edx, %r10d
  .Lta_gbn:
    cmpl    $0x1000000, %r11d
    jae     .Lta_gbok
    shll    $8, %r11d
    shll    $8, %r10d
    movzbl  (%r12), %edx
    addl    %edx, %r10d
    incq    %r12
    jmp     .Lta_gbn
  .Lta_gbok:
    xorl    %edx, %edx
    ret
  .Lta_gberr:
    movl    $1, %edx
    ret
  .Lta_gb2:
    // n > 24: 15 bits y después n-15 (ArithGetBits)
    pushq   %rcx
    movl    $15, %ecx
    call    .Lta_gb1
    popq    %rcx
    testl   %edx, %edx
    jnz     .Lta_gberr
    pushq   %rax
    subl    $15, %ecx
    call    .Lta_gb1
    popq    %rcx
    testl   %edx, %edx
    jnz     .Lta_gberr
    shll    $15, %eax
    addl    %ecx, %eax
    xorl    %edx, %edx
    ret

    // ---- LZMatch ----
  .Lta_match:
    movl    %esi, sym
    cmpl    $833, %esi                  // REPCHAR
    jne     .Lta_nrep
    movl    $1, %edi                    // len = 1, dist = prevdists[prev-1]
    movslq  TTornadoStage.FPrev(%r15), %rcx
    decq    %rcx
    leaq    TTornadoStage.FPrevDists(%r15), %rdx
    movl    (%rdx,%rcx,4), %r8d
    jmp     .Lta_copy
  .Lta_nrep:
    cmpl    $832, %esi                  // >= EOB_CODE
    jae     .Lta_badcode
    // getlen
    movl    %esi, %eax
    andl    $15, %eax                   // lcode
    movq    pxl, %rdx
    movzbl  (%rdx,%rax), %ecx           // extra_lbits2[lcode]
    movq    plb, %rdx
    movl    (%rdx,%rax,4), %eax
    movl    %eax, lval                  // lc2_base[lcode]
    call    .Lta_getbits
    testl   %edx, %edx
    jnz     .Lta_badarith
    addl    lval, %eax                  // l
    cmpl    $100, %eax
    jbe     .Lta_l1
    cmpl    $104, %eax
    ja      .Lta_l2
    addl    $1073741723, %eax           // l - 100 + IMPOSSIBLE_LEN
    jmp     .Lta_lset
  .Lta_l2:
    subl    $4, %eax
  .Lta_l1:
    addl    TTornadoStage.FMinLen(%r15), %eax
  .Lta_lset:
    movl    %eax, %edi                  // len
    // getdist
    movl    sym, %eax
    shrl    $4, %eax
    subl    $20, %eax                   // dcode = (x-256) div 16 - REPDIST_CODES
    js      .Lta_rep
    movl    %eax, dco
    movq    pxd, %rdx
    movzbl  (%rdx,%rax), %ecx           // extra_dbits[dcode]
    call    .Lta_getbits
    testl   %edx, %edx
    jnz     .Lta_badarith
    movl    dco, %ecx
    movq    pdb, %rdx
    addl    (%rdx,%rcx,4), %eax
    incl    %eax                        // d = dc_base[dcode] + bits + 1
    movl    %eax, %r8d
    leaq    TTornadoStage.FPrevDists(%r15), %rdx
    movslq  TTornadoStage.FPrev(%r15), %rcx
    cmpq    $128, %rcx                  // Length(FPrevDists)
    jne     .Lta_pd1
    movl    500(%rdx), %eax
    movl    %eax, (%rdx)
    movl    504(%rdx), %eax
    movl    %eax, 4(%rdx)
    movl    508(%rdx), %eax
    movl    %eax, 8(%rdx)
    movl    $3, %ecx                    // REPDIST_CODES-1
  .Lta_pd1:
    movl    %r8d, (%rdx,%rcx,4)
    incl    %ecx
    movl    %ecx, TTornadoStage.FPrev(%r15)
    jmp     .Lta_copy
  .Lta_rep:
    // dcode -4..-1: d = prevdists[prev-1-j] (j = dcode+4) y rotar hasta el final
    addl    $4, %eax
    leaq    TTornadoStage.FPrevDists(%r15), %rdx
    movslq  TTornadoStage.FPrev(%r15), %rsi
    decq    %rsi                        // prev-1
    movq    %rsi, %rcx
    subq    %rax, %rcx                  // prev-1-j
    movl    (%rdx,%rcx,4), %r8d
  .Lta_rot:
    cmpq    %rsi, %rcx
    jae     .Lta_rotd
    movl    4(%rdx,%rcx,4), %eax
    movl    %eax, (%rdx,%rcx,4)
    incq    %rcx
    jmp     .Lta_rot
  .Lta_rotd:
    movl    %r8d, (%rdx,%rsi,4)

    // ---- copia: edi = len, r8d = dist ----
  .Lta_copy:
    testl   %r8d, %r8d
    jz      .Lta_spec
    movq    %r14, %rax
    subq    %r9, %rax                   // output - outbuf
    movl    %r8d, %ecx
    cmpq    %rax, %rcx
    ja      .Lta_spec
    movq    %r13, %rax
    subq    %r14, %rax                  // write_end - output
    movl    %edi, %edx
    cmpq    %rdx, %rax
    jle     .Lta_spec
    movq    %r14, %rsi
    subq    %rcx, %rsi                  // origen
    movq    %rdx, %rax                  // bytes que faltan
    cmpq    $16, %rcx
    jb      .Lta_c8
  .Lta_c16:
    cmpq    $16, %rax
    jb      .Lta_c8
    movdqu  (%rsi), %xmm0
    movdqu  %xmm0, (%r14)
    addq    $16, %rsi
    addq    $16, %r14
    subq    $16, %rax
    jmp     .Lta_c16
  .Lta_c8:
    cmpq    $8, %rcx
    jb      .Lta_c1
  .Lta_c8l:
    cmpq    $8, %rax
    jb      .Lta_c1
    movq    (%rsi), %rdx
    movq    %rdx, (%r14)
    addq    $8, %rsi
    addq    $8, %r14
    subq    $8, %rax
    jmp     .Lta_c8l
  .Lta_c1:
    testq   %rax, %rax
    jz      .Lta_loop
  .Lta_c1l:
    movb    (%rsi), %dl
    movb    %dl, (%r14)
    incq    %rsi
    incq    %r14
    decq    %rax
    jnz     .Lta_c1l
    jmp     .Lta_loop

  .Lta_spec:
    movl    %edi, pendlen
    movl    %r8d, penddist
    movl    $1, res                     // TDR_SPECIAL
    jmp     .Lta_save
  .Lta_slow:
    movl    $0, res                     // TDR_SLOW
  .Lta_save:
    movq    %r14, op
    movq    %r12, ip
    movl    %r11d, rng
    movl    %r10d, cod
    jmp     .Lta_end
  .Lta_badarith:
    movl    $4, res                     // TDR_BADARITH
    jmp     .Lta_end
  .Lta_badcode:
    movl    $3, res                     // TDR_BADCODE
  .Lta_end:
  end ['rax', 'rbx', 'rcx', 'rdx', 'rsi', 'rdi', 'r8', 'r9', 'r10', 'r11', 'r12', 'r13', 'r14', 'r15', 'xmm0'];
  Result := res;
  if res <= TDR_WRITE then
  begin
    FOutput := op - FOut;
    FInPos := ip - PByte(FIn);
    FRange := rng;
    FCode := cod;
    if res = TDR_SPECIAL then
    begin
      FPendLen := pendlen;
      FPendDist := penddist;
    end;
  end;
end;
{$ELSE}
begin
  Result := RunArithFastPas;
end;
{$ENDIF}

{ Lazo rápido del codificador Huffman, igual que RunArithFast: en x86_64 en ensamblador (mismo
  algoritmo que RunHufFastPas, con el bitbuf, la entrada y la salida en registros), si no la
  versión en Pascal. Registros: r15 Self, r14 salida, r13 write_end, r12 entrada, rbx límite de
  la entrada, r11 bitbuf, r10d bitcount, r9 outbuf. }
function TTornadoStage.RunHufFast: Integer;
{$IF defined(CPUX86_64) and not defined(PARC_NOASM)}
var
  me: TTornadoStage;
  op, oend, ip, ilsafe, outb: PByte;
  plb, pxl, pdb, pxd: Pointer;
  bb: QWord;
  bc: LongInt;
  sym, pendlen, penddist: LongWord;
  res: LongInt;
  hidx: Pointer;
begin
  me := Self;
  hidx := Pointer(FHufIndex);     // HufBuildTree no corre dentro de este lazo
  outb := FOut;
  op := FOut + FOutput;
  oend := FOut + FWriteEnd;
  ip := PByte(FIn) + FInPos;
  ilsafe := PByte(FIn) + FInLim - TD_MARGIN;
  bb := FBitBuf;
  bc := FBitCount;
  plb := @lc2_base[0];
  pxl := @extra_lbits2[0];
  pdb := @dc_base[0];
  pxd := @extra_dbits[0];
  res := TDR_SLOW;
  sym := 0; pendlen := 0; penddist := 0;
  asm
    movq    me, %r15
    movq    op, %r14
    movq    oend, %r13
    movq    ip, %r12
    movq    ilsafe, %rbx
    movq    bb, %r11
    movl    bc, %r10d
    movq    outb, %r9
  .Lth_loop:
    cmpq    %rbx, %r12
    ja      .Lth_slow
    // ---- HufDecode (needbits; el EOB no se consume: va por el camino general) ----
    cmpl    $32, %r10d
    jg      .Lth_nb1
    movl    (%r12), %eax
    movl    %r10d, %ecx
    shlq    %cl, %rax
    orq     %rax, %r11
    addq    $4, %r12
    addl    $32, %r10d
  .Lth_nb1:
    movl    %r11d, %eax
    andl    TTornadoStage.FHufMask(%r15), %eax
    movl    %eax, %ecx
    andl    $2047, %ecx                 // (1 shl FAST_BITS) - 1
    movswl  TTornadoStage.FHufFast(%r15,%rcx,2), %esi
    testl   %esi, %esi
    jns     .Lth_got
    movq    hidx, %rdx
    movzwl  (%rdx,%rax,2), %esi
  .Lth_got:
    cmpl    $832, %esi                  // EOB_CODE
    je      .Lth_slow
    movzbl  TTornadoStage.FHufBits(%r15,%rsi), %ecx
    shrq    %cl, %r11
    subl    %ecx, %r10d
    incl    TTornadoStage.FHufCounter(%r15,%rsi,4)
    incq    TTornadoStage.FHufBlock(%r15)
    cmpq    $10000, TTornadoStage.FHufBlock(%r15)   // 2*HUFBLOCKSIZE
    jg      .Lth_badblock
    cmpl    $256, %esi
    jae     .Lth_match
    // ---- literal ----
    movb    %sil, (%r14)
    incq    %r14
    cmpq    %r13, %r14
    jb      .Lth_loop
    movl    $2, res                     // TDR_WRITE
    jmp     .Lth_save

    // ---- getbits(n): ecx = n (0..30) -> eax. Toca eax, ecx, edx ----
  .Lth_getbits:
    cmpl    $32, %r10d
    jg      .Lth_gb1
    movl    %ecx, %edx
    movl    (%r12), %eax
    movl    %r10d, %ecx
    shlq    %cl, %rax
    orq     %rax, %r11
    addq    $4, %r12
    addl    $32, %r10d
    movl    %edx, %ecx
  .Lth_gb1:
    movl    $1, %eax
    shll    %cl, %eax
    decl    %eax
    andl    %r11d, %eax
    shrq    %cl, %r11
    subl    %ecx, %r10d
    ret

    // ---- LZMatch ----
  .Lth_match:
    movl    %esi, sym
    cmpl    $833, %esi                  // REPCHAR
    jne     .Lth_nrep
    movl    $1, %edi                    // len = 1, dist = prevdists[prev-1]
    movslq  TTornadoStage.FPrev(%r15), %rcx
    decq    %rcx
    leaq    TTornadoStage.FPrevDists(%r15), %rdx
    movl    (%rdx,%rcx,4), %r8d
    jmp     .Lth_copy
  .Lth_nrep:
    cmpl    $832, %esi                  // >= EOB_CODE
    jae     .Lth_badcode
    // getlen
    movl    %esi, %edi
    andl    $15, %edi                   // lcode
    movq    pxl, %rdx
    movzbl  (%rdx,%rdi), %ecx           // extra_lbits2[lcode]
    call    .Lth_getbits
    movq    plb, %rdx
    addl    (%rdx,%rdi,4), %eax         // l = lc2_base[lcode] + bits
    cmpl    $100, %eax
    jbe     .Lth_l1
    cmpl    $104, %eax
    ja      .Lth_l2
    addl    $1073741723, %eax           // l - 100 + IMPOSSIBLE_LEN
    jmp     .Lth_lset
  .Lth_l2:
    subl    $4, %eax
  .Lth_l1:
    addl    TTornadoStage.FMinLen(%r15), %eax
  .Lth_lset:
    movl    %eax, %edi                  // len
    // getdist
    movl    sym, %esi
    shrl    $4, %esi
    subl    $20, %esi                   // dcode = (x-256) div 16 - REPDIST_CODES
    js      .Lth_rep
    movq    pxd, %rdx
    movzbl  (%rdx,%rsi), %ecx           // extra_dbits[dcode]
    call    .Lth_getbits
    movq    pdb, %rdx
    addl    (%rdx,%rsi,4), %eax
    incl    %eax                        // d = dc_base[dcode] + bits + 1
    movl    %eax, %r8d
    leaq    TTornadoStage.FPrevDists(%r15), %rdx
    movslq  TTornadoStage.FPrev(%r15), %rcx
    cmpq    $128, %rcx                  // Length(FPrevDists)
    jne     .Lth_pd1
    movl    500(%rdx), %eax
    movl    %eax, (%rdx)
    movl    504(%rdx), %eax
    movl    %eax, 4(%rdx)
    movl    508(%rdx), %eax
    movl    %eax, 8(%rdx)
    movl    $3, %ecx                    // REPDIST_CODES-1
  .Lth_pd1:
    movl    %r8d, (%rdx,%rcx,4)
    incl    %ecx
    movl    %ecx, TTornadoStage.FPrev(%r15)
    jmp     .Lth_copy
  .Lth_rep:
    // dcode -4..-1: d = prevdists[prev-1-j] (j = dcode+4) y rotar hasta el final
    addl    $4, %esi
    leaq    TTornadoStage.FPrevDists(%r15), %rdx
    movslq  TTornadoStage.FPrev(%r15), %rax
    decq    %rax                        // prev-1
    movq    %rax, %rcx
    subq    %rsi, %rcx                  // prev-1-j
    movl    (%rdx,%rcx,4), %r8d
  .Lth_rot:
    cmpq    %rax, %rcx
    jae     .Lth_rotd
    movl    4(%rdx,%rcx,4), %esi
    movl    %esi, (%rdx,%rcx,4)
    incq    %rcx
    jmp     .Lth_rot
  .Lth_rotd:
    movl    %r8d, (%rdx,%rax,4)

    // ---- copia: edi = len, r8d = dist ----
  .Lth_copy:
    testl   %r8d, %r8d
    jz      .Lth_spec
    movq    %r14, %rax
    subq    %r9, %rax                   // output - outbuf
    movl    %r8d, %ecx
    cmpq    %rax, %rcx
    ja      .Lth_spec
    movq    %r13, %rax
    subq    %r14, %rax                  // write_end - output
    movl    %edi, %edx
    cmpq    %rdx, %rax
    jle     .Lth_spec
    movq    %r14, %rsi
    subq    %rcx, %rsi                  // origen
    movq    %rdx, %rax                  // bytes que faltan
    cmpq    $16, %rcx
    jb      .Lth_c8
  .Lth_c16:
    cmpq    $16, %rax
    jb      .Lth_c8
    movdqu  (%rsi), %xmm0
    movdqu  %xmm0, (%r14)
    addq    $16, %rsi
    addq    $16, %r14
    subq    $16, %rax
    jmp     .Lth_c16
  .Lth_c8:
    cmpq    $8, %rcx
    jb      .Lth_c1
  .Lth_c8l:
    cmpq    $8, %rax
    jb      .Lth_c1
    movq    (%rsi), %rdx
    movq    %rdx, (%r14)
    addq    $8, %rsi
    addq    $8, %r14
    subq    $8, %rax
    jmp     .Lth_c8l
  .Lth_c1:
    testq   %rax, %rax
    jz      .Lth_loop
  .Lth_c1l:
    movb    (%rsi), %dl
    movb    %dl, (%r14)
    incq    %rsi
    incq    %r14
    decq    %rax
    jnz     .Lth_c1l
    jmp     .Lth_loop

  .Lth_spec:
    movl    %edi, pendlen
    movl    %r8d, penddist
    movl    $1, res                     // TDR_SPECIAL
    jmp     .Lth_save
  .Lth_slow:
    movl    $0, res                     // TDR_SLOW
  .Lth_save:
    movq    %r14, op
    movq    %r12, ip
    movq    %r11, bb
    movl    %r10d, bc
    jmp     .Lth_end
  .Lth_badblock:
    movl    $5, res                     // TDR_BADBLOCK
    jmp     .Lth_end
  .Lth_badcode:
    movl    $3, res                     // TDR_BADCODE
  .Lth_end:
  end ['rax', 'rbx', 'rcx', 'rdx', 'rsi', 'rdi', 'r8', 'r9', 'r10', 'r11', 'r12', 'r13', 'r14', 'r15', 'xmm0'];
  Result := res;
  if res <= TDR_WRITE then
  begin
    FOutput := op - FOut;
    FInPos := ip - PByte(FIn);
    FBitBuf := bb;
    FBitCount := bc;
    if res = TDR_SPECIAL then
    begin
      FPendLen := pendlen;
      FPendDist := penddist;
    end;
  end;
end;
{$ELSE}
begin
  Result := RunHufFastPas;
end;
{$ENDIF}

function TTornadoStage.NextChunk(out P: PByte; out Len: SizeInt): Boolean;
begin
  if not FInit then Init;
  if FPending then
  begin
    FPending := False;
    FChunkLen := 0;
    if FAtEnd then FDone := True else EndWrite;
  end;
  if FDone then Exit(False);
  Run;
  P := FChunk;
  Len := FChunkLen;
  Result := True;
end;

function TTornadoStage.Read(Buf: PByte; Count: SizeInt): SizeInt;
begin
  Result := 0;
  if Count <= 0 then Exit;
  if not FInit then Init;
  while FChunkLen = 0 do
  begin
    if FPending then
    begin
      FPending := False;
      if FAtEnd then FDone := True else EndWrite;
    end;
    if FDone then Exit(0);
    Run;
  end;
  Result := FChunkLen;
  if Result > Count then Result := Count;
  Move(FChunk^, Buf^, Result);
  Inc(FChunk, Result);
  Dec(FChunkLen, Result);
end;

function TornadoDecodeMem(Src: PByte; SrcLen: SizeInt; Dst: PByte; DstCap: SizeInt; out DstLen: SizeInt): Boolean;
var
  st: TTornadoStage;
  p: PByte;
  n: SizeInt;
begin
  DstLen := 0;
  st := TTornadoStage.Create(TPtrStage.Create(Src, SrcLen), True);
  try
    while st.NextChunk(p, n) do
    begin
      // ReadWriteMem (CompressionLibrary.cpp): si el tramo no entra, FREEARC_ERRCODE_OUTBLOCK_TOO_SMALL
      if n > DstCap - DstLen then Exit(False);
      if n > 0 then Move(p^, Dst[DstLen], n);
      Inc(DstLen, n);
    end;
    Result := True;
  finally
    st.Free;
  end;
end;

initialization
  InitTables;
end.
