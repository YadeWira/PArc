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

  THufNode = record
    Cnt, Code: LongWord;
    Left, Right: Word;
    Bits: Byte;
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
    FHufBlock: SizeInt;          // símbolos desde el último EOB (validación extra)
    FNodes: array[0..2 * 2048 + 3] of THufNode;
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
    function Special(len, dist: LongWord; var o: SizeInt): Boolean;
    procedure Run;
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
  de Huffman válido es lo mismo) y se exige <= 30; las claves de orden van en 64 bits. }
procedure TTornadoStage.HufBuildTree(RescaleMode: Integer);
var
  places: array[0..HUF_CHUNKS] of Integer;
  b, i, j, p, p1, p2, p3, r, n, s, sbits, maxbits, factor: Integer;
  scode: LongWord;
  key: QWord;
begin
  n := CODES;
  b := 0;
  for i := 0 to HUF_CHUNKS do places[i] := 0;
  for i := 0 to n - 1 do
  begin
    if FHufCounter[i] < HUF_CHUNKS then Inc(places[FHufCounter[i] + 1]);
    Inc(b);
  end;
  for i := 0 to HUF_CHUNKS - 1 do Inc(places[i + 1], places[i]);
  r := 0;
  for i := 0 to n - 1 do
    if FHufCounter[i] < HUF_CHUNKS then
    begin
      p := places[FHufCounter[i]];
      Inc(places[FHufCounter[i]]);
      FNodes[p].Cnt := FHufCounter[i];
      FNodes[p].Left := i;
    end
    else
    begin
      FRest[r] := QWord(FHufCounter[i]) * MAXHUF + QWord(i);
      Inc(r);
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
  for i := 0 to r - 1 do
  begin
    p := i + places[HUF_CHUNKS];
    FNodes[p].Cnt := LongWord(FRest[i] div MAXHUF);
    FNodes[p].Left := FRest[i] mod MAXHUF;
  end;

  for i := 0 to b + 3 do FNodes[b + i].Cnt := High(LongInt);   // centinelas INT_MAX
  p1 := 0; p2 := b + 2; p3 := b + 2;
  while not ((p1 = b) and (p3 - p2 = 1)) do
  begin
    if FNodes[p1 + 1].Cnt < FNodes[p2].Cnt then
    begin
      FNodes[p3].Cnt := FNodes[p1].Cnt + FNodes[p1 + 1].Cnt;
      FNodes[p3].Left := p1; FNodes[p3].Right := p1 + 1;
      Inc(p1, 2);
    end
    else if FNodes[p1].Cnt > FNodes[p2 + 1].Cnt then
    begin
      FNodes[p3].Cnt := FNodes[p2].Cnt + FNodes[p2 + 1].Cnt;
      FNodes[p3].Left := p2; FNodes[p3].Right := p2 + 1;
      Inc(p2, 2);
    end
    else
    begin
      FNodes[p3].Cnt := FNodes[p1].Cnt + FNodes[p2].Cnt;
      FNodes[p3].Left := p1; FNodes[p3].Right := p2;
      Inc(p1); Inc(p2);
    end;
    Inc(p3);
  end;

  FNodes[p2].Bits := 0;
  FNodes[p2].Code := 0;
  maxbits := 0;
  for i := p2 downto b + 2 do
  begin
    if FNodes[i].Bits >= 31 then Corrupt('tor: árbol de huffman demasiado profundo');
    FNodes[FNodes[i].Left].Bits := FNodes[i].Bits + 1;
    FNodes[FNodes[i].Left].Code := FNodes[i].Code;
    FNodes[FNodes[i].Right].Bits := FNodes[i].Bits + 1;
    FNodes[FNodes[i].Right].Code := FNodes[i].Code + (LongWord(1) shl FNodes[i].Bits);
  end;
  for i := 0 to b - 1 do
    if FNodes[i].Bits > maxbits then maxbits := FNodes[i].Bits;
  // Un stream válido no pasa de ~23 bits (contadores acotados por HUFBLOCKSIZE y el rescale);
  // el tope limita la tabla index[] a 128MB con datos corruptos
  if maxbits > 26 then Corrupt('tor: árbol de huffman demasiado profundo');
  FHufMaxBits := maxbits;
  if maxbits > FHufMaxSoFar then
  begin
    FHufMaxSoFar := maxbits;
    SetLength(FHufIndex, 1 shl maxbits);
  end;
  for i := 0 to b - 1 do
  begin
    s := FNodes[i].Left;
    sbits := FNodes[i].Bits;
    scode := FNodes[i].Code;
    FHufBits[s] := sbits;
    if sbits <= FAST_BITS then
    begin
      for j := 0 to (1 shl (FAST_BITS - sbits)) - 1 do
        FHufFast[scode + (LongWord(j) shl sbits)] := s;
    end
    else
    begin
      FHufFast[scode and ((1 shl FAST_BITS) - 1)] := -1;
      for j := 0 to (1 shl (maxbits - sbits)) - 1 do
        FHufIndex[scode + (LongWord(j) shl sbits)] := s;
    end;
  end;
  // rescale(FACTOR)
  case RescaleMode of
    0: factor := 2;  1: factor := 3;  2: factor := 4;  3: factor := 6;
    4: factor := 8;  5: factor := 10; 6: factor := 12; 7: factor := 16;
  else
    factor := 0;
  end;
  if factor > 0 then
    for s := 0 to n - 1 do
      if (FHufCounter[s] > 1) and (FHufCounter[s] < LongWord(factor)) then Dec(FHufCounter[s])
      else Dec(FHufCounter[s], FHufCounter[s] div LongWord(factor));
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
  if FHufBlock > 2 * HUFBLOCKSIZE then Corrupt('tor: bloque huffman sin EOB');
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
  if Result >= (LongWord(1) shl Bits) then Corrupt('tor: error en el decodificador aritmético');
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
  if count >= RANGE then Corrupt('tor: error en el decodificador aritmético');
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
    if FCode >= FRange then Corrupt('tor: error en el decodificador aritmético');
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
  if not Source.ReadExactOrEof(@hdr[0], 2) then Corrupt('tor: stream vacío');
  bs := Source.ReadU32;
  FMethod := hdr[0];
  FMinLen := hdr[1];
  if (FMethod < 1) or (FMethod > 4) then Corrupt('tor: codificador desconocido');
  // _bufsize es int en el C; negativo no tiene sentido
  if bs > LongWord(High(LongInt)) then Corrupt('tor: tamaño de buffer inválido');
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
  if x >= EOB_CODE then Corrupt('tor: código inválido');
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
      Corrupt('tor: match inválido');
    // Match lento: origen antes del inicio del buffer, que da la vuelta, o que cruza write_end
    if o >= SizeInt(dist) then p := o - SizeInt(dist) else p := o - SizeInt(dist) + FBufSize;
    FMatchLeft := len;
    repeat
      FOut[o] := FOut[p];
      Inc(o); Inc(p);
      if p = FBufSize then p := 0;
      Dec(FMatchLeft);
      if o >= FWriteEnd then
      begin
        FOutput := o; FMatchSrc := p;
        StartWrite;
        Exit(True);
      end;
    until FMatchLeft = 0;
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
    if (len = 0) or (QWord(dist) * len > QWord(2 * FHdrBufSize)) then Corrupt('tor: tabla inválida');
    if len > MAX_TABLE_ROW then Corrupt('tor: tabla inválida');
    TabAdd(len, o, dist);
    if (FTabCount = FTabCap) and not FAllAtOnce then
    begin
      FOutput := o;
      StartWrite;
      Exit(True);
    end;
  end;
end;

{ Decodifica hasta que haga falta escribir (FPending) o termine el stream. Un bucle por
  codificador (en el C, una instancia del template tor_decompress0 por cada uno). }
procedure TTornadoStage.Run;
var
  len, dist, x: LongWord;
  o, we, p: SizeInt;
begin
  // Continuar un match lento cortado por una escritura
  if FMatchLeft > 0 then
  begin
    o := FOutput; p := FMatchSrc;
    repeat
      FOut[o] := FOut[p];
      Inc(o); Inc(p);
      if p = FBufSize then p := 0;
      Dec(FMatchLeft);
      if o >= FWriteEnd then
      begin
        FOutput := o; FMatchSrc := p;
        StartWrite;
        Exit;
      end;
    until FMatchLeft = 0;
    FOutput := o;
  end;

  o := FOutput;
  we := FWriteEnd;
  case FMethod of
    1:
      repeat
        if NextByte(len, dist) then
        begin
          FOut[o] := Byte(len);
          Inc(o);
          if o >= we then Break;
        end
        // Match simple (>99% de los casos): `output-outbuf>=dist && write_end-output>len`
        else if (SizeInt(dist) <= o) and (we - o > SizeInt(len)) and (dist <> 0) then
        begin
          CopyMatch(FOut + o, dist, len);
          Inc(o, len);
        end
        else if Special(len, dist, o) then Exit;
      until False;
    2:
      repeat
        if NextBit(len, dist) then
        begin
          FOut[o] := Byte(len);
          Inc(o);
          if o >= we then Break;
        end
        else if (SizeInt(dist) <= o) and (we - o > SizeInt(len)) and (dist <> 0) then
        begin
          CopyMatch(FOut + o, dist, len);
          Inc(o, len);
        end
        else if Special(len, dist, o) then Exit;
      until False;
    3:
      repeat
        x := HufDecode;
        if x < 256 then
        begin
          FOut[o] := Byte(x);
          Inc(o);
          if o >= we then Break;
          Continue;
        end;
        LZMatch(x, len, dist);
        if (SizeInt(dist) <= o) and (we - o > SizeInt(len)) and (dist <> 0) then
        begin
          CopyMatch(FOut + o, dist, len);
          Inc(o, len);
        end
        else if Special(len, dist, o) then Exit;
      until False;
  else
    repeat
      x := ArithDecode;
      if x < 256 then
      begin
        FOut[o] := Byte(x);
        Inc(o);
        if o >= we then Break;
        Continue;
      end;
      LZMatch(x, len, dist);
      if (SizeInt(dist) <= o) and (we - o > SizeInt(len)) and (dist <> 0) then
      begin
        CopyMatch(FOut + o, dist, len);
        Inc(o, len);
      end
      else if Special(len, dist, o) then Exit;
    until False;
  end;
  // Un literal llegó a write_end
  FOutput := o;
  StartWrite;
end;

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
