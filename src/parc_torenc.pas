{ Codificador Tornado (método "tor" de FreeArc, Compression/Tornado/): la contraparte de
  parc_tornado. Traducción de tor_compress (Tornado.cpp) tal como lo compila FreeArc, es decir
  SIN FULL_COMPILE: solo las combinaciones (MatchFinder, Coder) del bloque #else de
  tor_compress, que son las de los presets -1..-16 (+ -5:c3). Cualquier otra combinación de
  parámetros FreeArc la rechaza con FREEARC_ERRCODE_INVALID_COMPRESSOR, y acá también.
  Stream: byte codificador, byte minlen, U32 LE buffer, y el bitstream del codificador
  terminado con (IMPOSSIBLE_LEN, IMPOSSIBLE_DIST).
  El resultado es byte a byte el del C con los mismos parámetros. Para eso se reproducen
  también sus efectos "laterales": el buffer se reserva en cero (BigAlloc = mmap/VirtualAlloc)
  y los hashes leen hasta ~10 bytes pasado bufend; al deslizar la ventana solo se mueve
  [buf+shift, bufend) (lo de más allá queda viejo); las lecturas son siempre completas (como
  read_data de FreeArc) y el lazo principal se corta exactamente donde el C llama a "read".
  Las tablas de hash guardan offsets desde buf (como el C de 64 bits: fromPtr/toPtr). }
unit parc_torenc;

{$mode objfpc}{$H+}
{$R-}{$Q-}
{$inline on}
{$goto on}
{$pointermath on}

interface

uses
  SysUtils, parc_outstream;

type
  ETorEncoder = class(Exception);

  { PackMethod (Tornado.cpp) }
  TTorMethod = record
    Number, EncodingMethod: Integer;
    FindTables: Boolean;
    HashRowWidth: Integer;
    HashSize: LongWord;
    MatchFinder: Integer;
    Buffer: LongWord;
    MatchParser, Hash3, Shift, UpdateStep: Integer;
    AuxHashSize: LongWord;
    AuxHashRowWidth, FastBytes: Integer;
  end;

  { Etapa de compresión tor. Params = la etapa partida por ':' (Params[0]='tor'). }
  TTorEncStage = class(TOutStage)
  private
    FEngine: TObject;
    procedure EmitOut(P: PByte; N: SizeInt);
  protected
    procedure DoWrite(Buf: PByte; Count: SizeInt); override;
    procedure DoFinish; override;
  public
    constructor Create(ATarget: TOutStage; const Params: TStringArray);
    destructor Destroy; override;
  end;

{ parse_TORNADO (C_Tornado.cpp) + validación. Devuelve '' si el método es válido y
  soportado (M queda como lo dejó parse_TORNADO, antes de los ajustes de tor_compress0),
  o el motivo del rechazo. }
function ParseTorEncParams(const Params: TStringArray; out M: TTorMethod): string;
{ True si la etapa ("tor:..") se puede comprimir. }
function TorEncAvailable(const Stage: string): Boolean;
{ TORNADO_METHOD::GetDictionary: m.buffer tal como se parseó (es el BlockSize que usa 4x4
  cuando no se le da b<mem>). -1 si los parámetros no son válidos. }
function TorDictionary(const Params: TStringArray): Int64;
{ TORNADO_METHOD::DeCompressMem(COMPRESS) con compress_all_at_once=1 (así lo llama 4x4):
  comprime Src entero de una vez. False si la salida no entra en DstCap bytes (el C devuelve
  FREEARC_ERRCODE_OUTBLOCK_TOO_SMALL y 4x4 guarda el bloque sin comprimir). Lanza
  ETorEncoder si los parámetros no son válidos o si SrcLen supera el buffer (el C solo
  comprimiría los primeros m.buffer bytes). }
function TorEncodeMem(const Params: TStringArray; Src: PByte; SrcLen: SizeInt; DstCap: SizeInt;
  out Dst: TBytes): Boolean;

implementation

uses
  parc_methods, parc_progress;

const
  kb = 1024;
  mb = 1024 * 1024;
  gb = 1024 * 1024 * 1024;
  // Tornado.cpp / MatchFinder.cpp / LZ77_Coder.cpp / DataTables.cpp / OptimalParsing.cpp
  LOOKAHEAD = 256;
  MAX_HASHED_BYTES = 12;
  LARGE_BUFFER_SIZE = 256 * kb;
  TABLE_DIST = 256 * 1024;
  TABLE_SHIFT = 128;
  MAX_TABLE_ROW = 64;
  IMPOSSIBLE_LEN = $3FFFFFFF;       // INT_MAX/2
  IMPOSSIBLE_DIST = $3FFFFFFF;
  REPDIST_CODES = 4;
  LEN_CODES = 16;
  DIST_CODES = 32 + REPDIST_CODES;
  EOB_CODE = 256 + LEN_CODES * DIST_CODES;   // 832
  REPCHAR = EOB_CODE + 1;
  CODES = EOB_CODE + 10;
  MAXHUF = 2048;
  HUFBLOCKSIZE = 5000;
  RANGE_BITS = 14;
  RANGE_ = 1 shl RANGE_BITS;
  MAX_MATCHES = 2048 + 256 + 16;
  OPTIMAL_WINDOW = 32 * kb;
  OPT_MIN_LEN = 2;                  // OPTIMAL_PARSER_MIN_MATCH_LEN
  MAX_PRICE = High(LongWord);
  PAD_AFTER = 64 * kb;              // ceros extra tras buf+buffer+LOOKAHEAD (ver TBTMF)

  // enum de Tornado.cpp
  GREEDY = 1; LAZY = 2; OPTIMAL = 4;
  NON_CACHING_MF = 0; CYCLED_MF5 = 5; CYCLED_MF7 = 7;
  CACHING_MF4 = 14; CACHING_MF5 = 15; CACHING_MF6 = 16; BT_MF5 = 25;

  K1 = LongWord(123456791);
  K2 = LongWord(789567123);
  K3 = LongWord(234567913);

  { std_Tornado_method[] (Tornado.cpp:55) }
  StdMethods: array[0..16] of TTorMethod = (
    (Number: 0; EncodingMethod: 0; FindTables: False; HashRowWidth: 0; HashSize: 0; MatchFinder: 0; Buffer: 1*mb; MatchParser: 0; Hash3: 0; Shift: 0; UpdateStep: 999; AuxHashSize: 0; AuxHashRowWidth: 0; FastBytes: 128),
    (Number: 1; EncodingMethod: 1; FindTables: False; HashRowWidth: 1; HashSize: 16*kb; MatchFinder: 0; Buffer: 1*mb; MatchParser: 1; Hash3: 0; Shift: 0; UpdateStep: 999; AuxHashSize: 0; AuxHashRowWidth: 0; FastBytes: 128),
    (Number: 2; EncodingMethod: 2; FindTables: False; HashRowWidth: 1; HashSize: 64*kb; MatchFinder: 0; Buffer: 2*mb; MatchParser: 1; Hash3: 0; Shift: 0; UpdateStep: 999; AuxHashSize: 0; AuxHashRowWidth: 0; FastBytes: 128),
    (Number: 3; EncodingMethod: 3; FindTables: True; HashRowWidth: 2; HashSize: 128*kb; MatchFinder: 0; Buffer: 4*mb; MatchParser: 1; Hash3: 0; Shift: 0; UpdateStep: 999; AuxHashSize: 0; AuxHashRowWidth: 0; FastBytes: 128),
    (Number: 4; EncodingMethod: 3; FindTables: True; HashRowWidth: 2; HashSize: 2*mb; MatchFinder: 14; Buffer: 8*mb; MatchParser: 1; Hash3: 0; Shift: 0; UpdateStep: 999; AuxHashSize: 0; AuxHashRowWidth: 0; FastBytes: 128),
    (Number: 5; EncodingMethod: 4; FindTables: True; HashRowWidth: 4; HashSize: 8*mb; MatchFinder: 14; Buffer: 16*mb; MatchParser: 2; Hash3: 1; Shift: 0; UpdateStep: 999; AuxHashSize: 0; AuxHashRowWidth: 0; FastBytes: 128),
    (Number: 6; EncodingMethod: 4; FindTables: True; HashRowWidth: 8; HashSize: 32*mb; MatchFinder: 14; Buffer: 64*mb; MatchParser: 2; Hash3: 1; Shift: 0; UpdateStep: 4; AuxHashSize: 0; AuxHashRowWidth: 0; FastBytes: 128),
    (Number: 7; EncodingMethod: 4; FindTables: True; HashRowWidth: 32; HashSize: 128*mb; MatchFinder: 5; Buffer: 256*mb; MatchParser: 2; Hash3: 2; Shift: 0; UpdateStep: 1; AuxHashSize: 128*kb; AuxHashRowWidth: 4; FastBytes: 128),
    (Number: 8; EncodingMethod: 4; FindTables: True; HashRowWidth: 128; HashSize: 512*mb; MatchFinder: 5; Buffer: 1*gb; MatchParser: 2; Hash3: 2; Shift: 0; UpdateStep: 1; AuxHashSize: 128*kb; AuxHashRowWidth: 4; FastBytes: 128),
    (Number: 9; EncodingMethod: 4; FindTables: True; HashRowWidth: 256; HashSize: 2*LongWord(gb); MatchFinder: 5; Buffer: 1*gb; MatchParser: 2; Hash3: 2; Shift: 0; UpdateStep: 1; AuxHashSize: 512*kb; AuxHashRowWidth: 4; FastBytes: 128),
    (Number: 10; EncodingMethod: 4; FindTables: True; HashRowWidth: 256; HashSize: 2*LongWord(gb); MatchFinder: 7; Buffer: 1*gb; MatchParser: 2; Hash3: 2; Shift: 0; UpdateStep: 1; AuxHashSize: 16*mb; AuxHashRowWidth: 128; FastBytes: 128),
    (Number: 11; EncodingMethod: 4; FindTables: True; HashRowWidth: 8; HashSize: 256*mb; MatchFinder: 15; Buffer: 128*mb; MatchParser: 4; Hash3: 1; Shift: 0; UpdateStep: 1; AuxHashSize: 64*kb; AuxHashRowWidth: 1; FastBytes: 16),
    (Number: 12; EncodingMethod: 4; FindTables: True; HashRowWidth: 16; HashSize: 256*mb; MatchFinder: 15; Buffer: 128*mb; MatchParser: 4; Hash3: 1; Shift: 0; UpdateStep: 1; AuxHashSize: 64*kb; AuxHashRowWidth: 1; FastBytes: 32),
    (Number: 13; EncodingMethod: 4; FindTables: True; HashRowWidth: 24; HashSize: 384*mb; MatchFinder: 15; Buffer: 128*mb; MatchParser: 4; Hash3: 1; Shift: 0; UpdateStep: 1; AuxHashSize: 128*kb; AuxHashRowWidth: 1; FastBytes: 64),
    (Number: 14; EncodingMethod: 4; FindTables: True; HashRowWidth: 32; HashSize: 512*mb; MatchFinder: 16; Buffer: 128*mb; MatchParser: 4; Hash3: 2; Shift: 0; UpdateStep: 1; AuxHashSize: 2*mb; AuxHashRowWidth: 2; FastBytes: 64),
    (Number: 15; EncodingMethod: 4; FindTables: True; HashRowWidth: 64; HashSize: 512*mb; MatchFinder: 16; Buffer: 128*mb; MatchParser: 4; Hash3: 2; Shift: 0; UpdateStep: 1; AuxHashSize: 2*mb; AuxHashRowWidth: 4; FastBytes: 128),
    (Number: 16; EncodingMethod: 4; FindTables: True; HashRowWidth: 128; HashSize: 128*mb; MatchFinder: 25; Buffer: 128*mb; MatchParser: 4; Hash3: 2; Shift: 0; UpdateStep: 1; AuxHashSize: 4*mb; AuxHashRowWidth: 8; FastBytes: 512));
  DEFAULT_METHOD = 5;

  { Bits extra de LZ77_Coder.cpp }
  ExtraLBits: array[0..7] of LongWord = (0, 0, 0, 1, 2, 4, 8, 30);
  ExtraLBits2: array[0..15] of LongWord = (0, 0, 0, 0, 0, 0, 0, 1, 1, 2, 2, 3, 3, 4, 8, 30);
  ExtraDBits: array[0..31] of LongWord = (4, 4, 5, 5, 5, 6, 6, 7, 7, 8, 8, 9, 9, 10, 10, 11, 11, 12, 12,
    13, 13, 14, 14, 15, 15, 16, 17, 18, 19, 21, 23, 30);

  VLE_SIZE = 1024 + 16384 + 1;

type
  TVle = record
    Code: array[0..VLE_SIZE - 1] of Byte;
    Extra, Base: array[0..255] of LongWord;
  end;

var
  Lc, Lc2, Dc: TVle;          // lc, lc2, dc de LZ77_Coder.cpp
  PriceTab: array[0..RANGE_] of LongWord;   // PRICE_SCALE(log2(RANGE/cnt)) por cnt

{ ---------------------------------------------------------------------------------------- }
{ Utilidades (Common.h)                                                                     }
{ ---------------------------------------------------------------------------------------- }

function V16(p: PByte): LongWord; inline;
begin
  Result := PWord(p)^;
end;

function V16s(p: PByte): Integer; inline;
begin
  Result := SmallInt(PWord(p)^);
end;

function V24(p: PByte): LongWord; inline;
begin
  Result := PLongWord(p)^ and $FFFFFF;
end;

function V32(p: PByte): LongWord; inline;
begin
  Result := PLongWord(p)^;
end;

{ Producto de 32 bits (el C multiplica uint*int en 32 bits). }
function Mul32(a, b: LongWord): LongWord; inline;
begin
  Result := a * b;
end;

{ lb (Common.h): parte entera de log2, n>0 }
function lb(n: QWord): Integer; inline;
begin
  Result := BsrQWord(n);
end;

function RoundupPow2(n: LongWord): LongWord;   // roundup_to_power_of(n,2)
begin
  if n = 0 then Exit(0);
  Dec(n);
  if n = 0 then Exit(1);
  Result := LongWord(2) shl lb(n);
end;

function MinI(a, b: Int64): Int64; inline;
begin
  if a < b then Result := a else Result := b;
end;

function MaxI(a, b: Int64): Int64; inline;
begin
  if a > b then Result := a else Result := b;
end;

{ ChangePair (MatchFinder.cpp): bigDist/64 > smallDist }
function ChangePair(smallDist, bigDist: LongWord): Boolean; inline;
begin
  Result := (bigDist div 64) > smallDist;
end;

{ hashx (MatchFinder.cpp) }
function HashX(len: LongWord; p: PByte; Shift, Mask: LongWord): LongWord; inline;
begin
  case len of
    4: Result := (Mul32(V32(p), K1) shr Shift) and Mask;
    5: Result := (LongWord(Mul32(V32(p), K1) + Mul32(V32(p + 1), K2)) shr Shift) and Mask;
    6: Result := (LongWord(Mul32(V32(p), K1) + Mul32(V32(p + 2), K2)) shr Shift) and Mask;
  else
    Result := (LongWord(Mul32(V32(p), K1) + Mul32(V32(p + 3), K2)) shr Shift) and Mask;
  end;
end;

{ accept_len_dist }
function AcceptLenDist(len, dist: LongWord): Boolean; inline;
begin
  case len of
    4: Result := dist < 48 * kb;
    5: Result := dist < 192 * kb;
    6: Result := dist < 1 * mb;
    7: Result := dist < 12 * mb;
  else
    Result := True;
  end;
end;

{ accept_match: len o 0 }
function AcceptMatch(len: LongWord; p, q, bufend: PByte): LongWord;
var
  ok: Boolean;
begin
  ok := (p <= bufend) and (V32(p) = V32(q));
  case len of
    4: ok := ok and (p - q < 48 * kb);
    5: ok := ok and (p - q < 192 * kb) and (p[4] = q[4]);
    6: ok := ok and (p - q < 1 * mb) and (V16(p + 4) = V16(q + 4));
    7: ok := ok and (p - q < 12 * mb) and (V24(p + 4) = V24(q + 4));
    8: ok := ok and (V32(p + 4) = V32(q + 4));
    9: ok := ok and (V32(p + 4) = V32(q + 4)) and (p[8] = q[8]);
  else
    ok := ok and (V32(p + 4) = V32(q + 4)) and (V16(p + 8) = V16(q + 8));
  end;
  if ok then Result := len else Result := 0;
end;

{ accept_optimal_match }
function AcceptOptimalMatch(len: LongWord; p, q, bufend: PByte): Boolean;
begin
  Result := (p <= bufend) and (V32(p) = V32(q));
  if not Result then Exit;
  case len of
    4: ;
    5: Result := p[4] = q[4];
    6: Result := V16(p + 4) = V16(q + 4);
    7: Result := V24(p + 4) = V24(q + 4);
    8: Result := V32(p + 4) = V32(q + 4);
    9: Result := (V32(p + 4) = V32(q + 4)) and (p[8] = q[8]);
  else
    Result := (V32(p + 4) = V32(q + 4)) and (V16(p + 8) = V16(q + 8));
  end;
end;

{ check_match_len }
function CheckMatchLen(p, q: PByte; maxLen: LongWord): LongWord;
begin
  Result := 0;
  while V32(p + Result) = V32(q + Result) do
  begin
    Inc(Result, 4);
    if Result >= maxLen then Exit(maxLen);
  end;
  while (p[Result] = q[Result]) and (Result < maxLen) do Inc(Result);
end;

{ ---------------------------------------------------------------------------------------- }
{ Match finders (MatchFinder.cpp). Métodos virtuales en lugar de templates.                 }
{ ---------------------------------------------------------------------------------------- }

type
  TMF = class
  public
    Base: PByte;            // buf: las tablas guardan offsets desde acá
    Q: PByte;               // último match encontrado
    MinLen: LongWord;       // min_length()
    function FindMatchLen(p, bufend: PByte; prevlen: LongWord): LongWord; virtual; abstract;
    function MatchPtr: PByte; virtual;
    procedure UpdateHash(p: PByte; len, step: LongWord); virtual; abstract;
    procedure UpdateHash1(p: PByte); virtual; abstract;
    function FindAllMatches(p, bufend: PByte; m: PLongWord): PLongWord; virtual;
    procedure ClearHash(buf: PByte); virtual; abstract;
    procedure ShiftHash(buf: PByte; shift: LongWord); virtual; abstract;
    procedure InvalidateMatch; virtual;
  end;

  { BaseMatchFinder }
  TBaseMF = class(TMF)
  public
    HashSize, HashShift, HashMask: LongWord;
    HT: PLongWord;
    RowWidth: Integer;
    constructor Create(buf: PByte; AHashSize: LongWord; row: Integer);
    destructor Destroy; override;
    function Hash(x: LongWord): LongWord; inline;
    procedure ClearHash(buf: PByte); override;
    procedure ShiftHash(buf: PByte; shift: LongWord); override;
    procedure UpdateHash1(p: PByte); override;
  end;

  TMF1 = class(TBaseMF)
    function FindMatchLen(p, bufend: PByte; prevlen: LongWord): LongWord; override;
    procedure UpdateHash(p: PByte; len, step: LongWord); override;
  end;

  TMF2 = class(TBaseMF)
    function FindMatchLen(p, bufend: PByte; prevlen: LongWord): LongWord; override;
    procedure UpdateHash(p: PByte; len, step: LongWord); override;
  end;

  { MatchFinderN<N> }
  TMFN = class(TBaseMF)
    N: LongWord;
    constructor Create(buf: PByte; AHashSize: LongWord; row: Integer; AN: LongWord);
    function FindAllMatches(p, bufend: PByte; m: PLongWord): PLongWord; override;
    function FindMatchLen(p, bufend: PByte; prevlen: LongWord): LongWord; override;
    procedure UpdateHash1(p: PByte); override;
    procedure UpdateHash(p: PByte; len, step: LongWord); override;
  end;

  { ExactMatchFinder<N> }
  TExactMF = class(TBaseMF)
    N: LongWord;
    constructor Create(buf: PByte; AHashSize: LongWord; row: Integer; AN: LongWord);
    function FindAllMatches(p, bufend: PByte; m: PLongWord): PLongWord; override;
    function FindMatchLen(p, bufend: PByte; prevlen: LongWord): LongWord; override;
    procedure UpdateHash1(p: PByte); override;
    procedure UpdateHash(p: PByte; len, step: LongWord); override;
  end;

  { CachingMatchFinder<N> }
  TCachingMF = class(TMF)
    N, HashShift, HashSize: LongWord;
    RowWidth, Row2, RowUp: Integer;
    HT: PLongWord;
    constructor Create(buf: PByte; AHashSize: LongWord; row: Integer; AN: LongWord);
    destructor Destroy; override;
    function Key(p: PByte): LongWord; inline;
    function FindAllMatches(p, bufend: PByte; m: PLongWord): PLongWord; override;
    function FindMatchLen(p, bufend: PByte; prevlen: LongWord): LongWord; override;
    procedure UpdateHash1(p: PByte); override;
    procedure UpdateHash(p: PByte; len, step: LongWord); override;
    procedure ClearHash(buf: PByte); override;
    procedure ShiftHash(buf: PByte; shift: LongWord); override;
  end;

  { CycledCachingMatchFinder<N> }
  TCycledMF = class(TMF)
    N, HashShift, HashSize, HeadSize: LongWord;
    RowWidth: Integer;
    HT: PLongWord;
    Head: PByte;
    constructor Create(buf: PByte; AHashSize: LongWord; row: Integer; AN: LongWord);
    destructor Destroy; override;
    function Key(p: PByte): LongWord; inline;
    function FindAllMatches(p, bufend: PByte; m: PLongWord): PLongWord; override;
    function FindMatchLen(p, bufend: PByte; prevlen: LongWord): LongWord; override;
    procedure UpdateHash1(p: PByte); override;
    procedure UpdateHash(p: PByte; len, step: LongWord); override;
    procedure ClearHash(buf: PByte); override;
    procedure ShiftHash(buf: PByte; shift: LongWord); override;
  end;

  { BinaryTreeMatchFinder<N> (solo find_all_matches: se usa únicamente con el parser óptimo) }
  TBTMF = class(TBaseMF)
    N, DictSize: LongWord;
    MaxDepth: Integer;
    BT: PLongWord;
    AllocEnd: PByte;         // fin de la memoria del buffer (tope de seguridad, ver FindAllMatches)
    constructor Create(buf: PByte; ADictSize, AHashSize: LongWord; AMaxDepth: Integer; AN: LongWord; AAllocEnd: PByte);
    destructor Destroy; override;
    function FindAllMatches(p, bufend: PByte; m: PLongWord): PLongWord; override;
    function FindMatchLen(p, bufend: PByte; prevlen: LongWord): LongWord; override;
    procedure UpdateHash(p: PByte; len, step: LongWord); override;
    procedure ClearHash(buf: PByte); override;
    procedure ShiftHash(buf: PByte; shift: LongWord); override;
  end;

  { LazyMatching<MF> }
  TLazyMF = class(TMF)
    MF: TMF;
    NextLen: LongWord;
    PrevQ, NextQ: PByte;
    constructor Create(AMF: TMF);
    destructor Destroy; override;
    function MatchPtr: PByte; override;
    function FindMatchLen(p, bufend: PByte; prevlen: LongWord): LongWord; override;
    procedure UpdateHash(p: PByte; len, step: LongWord); override;
    procedure UpdateHash1(p: PByte); override;
    procedure ClearHash(buf: PByte); override;
    procedure ShiftHash(buf: PByte; shift: LongWord); override;
    procedure InvalidateMatch; override;
  end;

  { Hash3<MF, HASH3_LOG, HASH2_LOG, FULL_UPDATE> }
  THash3MF = class(TMF)
    MF: TMF;
    Log3, Log2: Integer;
    FullUpdate: Boolean;
    HashSize3, HashSize2: LongWord;
    HT3, HT2: PLongWord;
    constructor Create(AMF: TMF; ALog3, ALog2: Integer; AFull: Boolean; buf: PByte);
    destructor Destroy; override;
    function H3(x: LongWord): LongWord; inline;
    function H2(x: LongWord): LongWord; inline;
    function FindAllMatches(p, bufend: PByte; m: PLongWord): PLongWord; override;
    function FindMatchLen(p, bufend: PByte; prevlen: LongWord): LongWord; override;
    procedure UpdateHash1(p: PByte); override;
    procedure UpdateHash(p: PByte; len, step: LongWord); override;
    procedure ClearHash(buf: PByte); override;
    procedure ShiftHash(buf: PByte; shift: LongWord); override;
    procedure InvalidateMatch; override;
  end;

  { CombineMF<MF1, MF2> }
  TCombineMF = class(TMF)
    MF1, MF2: TMF;
    constructor Create(A1, A2: TMF);
    destructor Destroy; override;
    function FindAllMatches(p, bufend: PByte; m: PLongWord): PLongWord; override;
    function FindMatchLen(p, bufend: PByte; prevlen: LongWord): LongWord; override;
    procedure UpdateHash1(p: PByte); override;
    procedure UpdateHash(p: PByte; len, step: LongWord); override;
    procedure ClearHash(buf: PByte); override;
    procedure ShiftHash(buf: PByte; shift: LongWord); override;
    procedure InvalidateMatch; override;
  end;

function AllocTable(n: QWord): PLongWord;
var
  Lim: QWord;
begin
  // En 32 bits n*4 puede no caber en SizeInt: mejor fallar que reservar de menos
  Lim := High(SizeInt);
  if n > Lim div SizeOf(LongWord) then OutOfMemoryError;
  Result := GetMem(SizeInt(n * SizeOf(LongWord)));
  if Result = nil then OutOfMemoryError;
end;

{ TMF }

function TMF.MatchPtr: PByte;
begin
  Result := Q;
end;

function TMF.FindAllMatches(p, bufend: PByte; m: PLongWord): PLongWord;
begin
  Result := m;
end;

procedure TMF.InvalidateMatch;
begin
end;

{ TBaseMF }

constructor TBaseMF.Create(buf: PByte; AHashSize: LongWord; row: Integer);
begin
  inherited Create;
  Base := buf;
  MinLen := 4;
  RowWidth := row;
  HashSize := (LongWord(1) shl lb(AHashSize)) div SizeOf(LongWord);
  HashShift := 32 - lb(HashSize);
  HashMask := (HashSize - 1) and not (RoundupPow2(row) - 1);
  HT := AllocTable(HashSize);
  ClearHash(buf);     // virtual: BinaryTreeMatchFinder pone 0, el resto buf+1
end;

destructor TBaseMF.Destroy;
begin
  FreeMem(HT);
  inherited Destroy;
end;

function TBaseMF.Hash(x: LongWord): LongWord;
begin
  Result := (Mul32(x, K1) shr HashShift) and HashMask;
end;

procedure TBaseMF.ClearHash(buf: PByte);
var
  i: SizeInt;
begin
  for i := 0 to SizeInt(HashSize) - 1 do HT[i] := 1;     // fromPtr(buf+1)
end;

procedure TBaseMF.ShiftHash(buf: PByte; shift: LongWord);
var
  i: SizeInt;
begin
  for i := 0 to SizeInt(HashSize) - 1 do
    if HT[i] > shift then HT[i] := HT[i] - shift else HT[i] := 1;
end;

procedure TBaseMF.UpdateHash1(p: PByte);
begin
  raise ETorEncoder.Create('tor: update_hash1 no disponible');
end;

{ TMF1 (MatchFinder1) }

function TMF1.FindMatchLen(p, bufend: PByte; prevlen: LongWord): LongWord;
var
  h, len: LongWord;
begin
  h := Hash(V32(p));
  Q := Base + HT[h];
  HT[h] := p - Base;
  if V32(p) = V32(Q) then
  begin
    len := MinLen - 1;
    while (p + len + 4 < bufend) and (V32(p + len) = V32(Q + len)) do Inc(len, 4);
    while (p + len < bufend) and (p[len] = Q[len]) do Inc(len);
    Result := len;
  end
  else
    Result := MinLen - 1;
end;

procedure TMF1.UpdateHash(p: PByte; len, step: LongWord);
begin
  // El modo más rápido no actualiza el hash
end;

{ TMF2 (MatchFinder2) }

function TMF2.FindMatchLen(p, bufend: PByte; prevlen: LongWord): LongWord;
var
  h, len, len1: LongWord;
  q1: PByte;
begin
  h := Hash(V32(p));
  q1 := Base + HT[h + 1];  HT[h + 1] := HT[h];
  Q := Base + HT[h];       HT[h] := p - Base;
  if V32(p) = V32(Q) then
  begin
    len := MinLen - 1;
    while (p + len + 4 < bufend) and (V32(p + len) = V32(Q + len)) do Inc(len, 4);
    while (p + len < bufend) and (p[len] = Q[len]) do Inc(len);
    if p[len] = q1[len] then
    begin
      len1 := 0;
      while (p + len1 < bufend) and (p[len1] = q1[len1]) do Inc(len1);
      if len1 > len then begin len := len1; Q := q1; end;
    end;
    Result := len;
  end
  else if V32(p) = V32(q1) then
  begin
    Q := q1;
    len := MinLen - 1;
    while (p + len + 4 < bufend) and (V32(p + len) = V32(Q + len)) do Inc(len, 4);
    while (p + len < bufend) and (p[len] = Q[len]) do Inc(len);
    Result := len;
  end
  else
    Result := MinLen - 1;
end;

procedure TMF2.UpdateHash(p: PByte; len, step: LongWord);
var
  h: LongWord;
begin
  h := Hash(V32(p + 1));  HT[h + 1] := HT[h];  HT[h] := (p + 1) - Base;
  Inc(p, len);
  h := Hash(V32(p - 2));  HT[h + 1] := HT[h];  HT[h] := (p - 2) - Base;
  h := Hash(V32(p - 1));  HT[h + 1] := HT[h];  HT[h] := (p - 1) - Base;
end;

{ TMFN (MatchFinderN<N>) }

constructor TMFN.Create(buf: PByte; AHashSize: LongWord; row: Integer; AN: LongWord);
begin
  inherited Create(buf, AHashSize, row);
  N := AN;
  MinLen := AN;
  ClearHash(buf);
end;

function TMFN.FindAllMatches(p, bufend: PByte; m: PLongWord): PLongWord;
var
  maxLen, h, x0, x1, len: LongWord;
  qq: PByte;
  j: Integer;
begin
  maxLen := MinLen - 1;
  h := HashX(N, p, HashShift, HashMask);
  x0 := HT[h];  HT[h] := p - Base;
  qq := Base + x0;
  if V32(p) = V32(qq) then
  begin
    len := 4;
    while (p + len + 4 <= bufend) and (V32(p + len) = V32(qq + len)) do Inc(len, 4);
    while (p + len < bufend) and (p[len] = qq[len]) do Inc(len);
    if len >= MinLen then
    begin
      maxLen := len;
      m^ := len; Inc(m); m^ := p - qq; Inc(m);
    end;
  end;
  j := 1;
  while j < RowWidth do
  begin
    x1 := HT[h + j];  HT[h + j] := x0;
    qq := Base + x1;
    if p[maxLen] = qq[maxLen] then
    begin
      len := 0;
      while (p + len < bufend) and (p[len] = qq[len]) do Inc(len);
      if len >= maxLen then
      begin
        maxLen := len;
        m^ := len; Inc(m); m^ := p - qq; Inc(m);
      end;
    end;
    Inc(j);
    x0 := x1;
  end;
  Result := m;
end;

function TMFN.FindMatchLen(p, bufend: PByte; prevlen: LongWord): LongWord;
var
  len, h, x0, x1, len1: LongWord;
  q1: PByte;
  j: Integer;
begin
  len := MinLen - 1;
  h := HashX(N, p, HashShift, HashMask);
  x0 := HT[h];  HT[h] := p - Base;
  Q := Base + x0;
  if V32(p) = V32(Q) then
  begin
    len := MinLen;
    while (p + len + 4 <= bufend) and (V32(p + len) = V32(Q + len)) do Inc(len, 4);
    while (p + len < bufend) and (p[len] = Q[len]) do Inc(len);
    if not AcceptLenDist(len, p - Q) then len := MinLen - 1;
  end;
  j := 1;
  while j < RowWidth do
  begin
    x1 := HT[h + j];  HT[h + j] := x0;
    q1 := Base + x1;
    if V32(p + len + 1 - MinLen) = V32(q1 + len + 1 - MinLen) then
    begin
      len1 := 0;
      while (p + len1 < bufend) and (p[len1] = q1[len1]) do Inc(len1);
      if (len1 > len) and not ((len1 = len + 1) and ChangePair(p - Q, p - q1)) and AcceptLenDist(len1, p - q1) then
      begin
        len := len1;  Q := q1;
      end;
    end;
    Inc(j);
    x0 := x1;
  end;
  Result := len;
end;

procedure TMFN.UpdateHash1(p: PByte);
var
  h: LongWord;
  j: Integer;
begin
  h := HashX(N, p, HashShift, HashMask);
  j := RowWidth - 1;
  while j > 0 do
  begin
    HT[h + j] := HT[h + j - 1];
    Dec(j);
  end;
  HT[h] := p - Base;
end;

procedure TMFN.UpdateHash(p: PByte; len, step: LongWord);
var
  i: LongWord;
begin
  if len > 1 then UpdateHash1(p + 1);
  i := 2;
  while i < len - 1 do begin UpdateHash1(p + i); Inc(i, step); end;
  if len > 3 then UpdateHash1(p + len - 1);
end;

{ TExactMF (ExactMatchFinder<N>) }

constructor TExactMF.Create(buf: PByte; AHashSize: LongWord; row: Integer; AN: LongWord);
begin
  inherited Create(buf, AHashSize, row);
  N := AN;
  MinLen := AN;
  ClearHash(buf);
end;

function TExactMF.FindAllMatches(p, bufend: PByte; m: PLongWord): PLongWord;
var
  h, x0, x1: LongWord;
  qq: PByte;
  j: Integer;
begin
  h := HashX(N, p, HashShift, HashMask);
  x0 := p - Base;
  j := 0;
  while j < RowWidth do
  begin
    x1 := HT[h + j];  HT[h + j] := x0;
    qq := Base + x1;
    if AcceptOptimalMatch(N, p, qq, bufend) then
    begin
      m^ := N; Inc(m); m^ := p - qq; Inc(m);
      Exit(m);
    end;
    Inc(j);
    x0 := x1;
  end;
  Result := m;
end;

function TExactMF.FindMatchLen(p, bufend: PByte; prevlen: LongWord): LongWord;
var
  h, x0, x1: LongWord;
  q1: PByte;
  j: Integer;
begin
  h := HashX(N, p, HashShift, HashMask);
  x0 := p - Base;
  j := 0;
  while j < RowWidth do
  begin
    x1 := HT[h + j];  HT[h + j] := x0;
    q1 := Base + x1;
    if not AcceptLenDist(N, p - q1) then Exit(MinLen - 1);
    if AcceptOptimalMatch(N, p, q1, bufend) then
    begin
      Q := q1;
      Exit(N);
    end;
    Inc(j);
    x0 := x1;
  end;
  Result := MinLen - 1;
end;

procedure TExactMF.UpdateHash1(p: PByte);
begin
  HT[HashX(N, p, HashShift, HashMask)] := p - Base;
end;

procedure TExactMF.UpdateHash(p: PByte; len, step: LongWord);
var
  i: LongWord;
begin
  if len > 1 then UpdateHash1(p + 1);
  i := 2;
  while i < len - 1 do begin UpdateHash1(p + i); Inc(i, step); end;
  if len > 3 then UpdateHash1(p + len - 1);
end;

{ TCachingMF (CachingMatchFinder<N>) }

constructor TCachingMF.Create(buf: PByte; AHashSize: LongWord; row: Integer; AN: LongWord);
var
  rows: LongWord;
begin
  inherited Create;
  Base := buf;
  N := AN;
  MinLen := AN;
  RowWidth := row;
  // Simulate 2gb:256 hash with 2040mb:255 one :)
  if (AHashSize = 2 * LongWord(gb)) and (RowWidth = (1 shl lb(RowWidth))) then Dec(RowWidth);
  Row2 := RowWidth * 2;
  RowUp := RowWidth + (RowWidth mod 2);
  rows := LongWord(1) shl lb(AHashSize div LongWord(SizeOf(LongWord) * Row2));
  HashSize := rows * LongWord(Row2);
  HT := AllocTable(HashSize);
  HashShift := 32 - lb(rows);
  ClearHash(buf);
end;

destructor TCachingMF.Destroy;
begin
  FreeMem(HT);
  inherited Destroy;
end;

function TCachingMF.Key(p: PByte): LongWord;
begin
  Result := V32(p + N - 1);
end;

procedure TCachingMF.ClearHash(buf: PByte);
var
  i: SizeInt;
  k: LongWord;
begin
  k := Key(buf + 1);
  i := 0;
  while i < SizeInt(HashSize) do
  begin
    HT[i] := 1;
    HT[i + 1] := k;
    Inc(i, 2);
  end;
end;

procedure TCachingMF.ShiftHash(buf: PByte; shift: LongWord);
var
  i: SizeInt;
begin
  i := 0;
  while i < SizeInt(HashSize) do
  begin
    if HT[i] > shift then HT[i] := HT[i] - shift else HT[i] := 1;
    Inc(i, 2);
  end;
end;

function TCachingMF.FindAllMatches(p, bufend: PByte; m: PLongWord): PLongWord;
label
  len4, len5, len6, len7;
var
  len, len1, x0, x1, v0, v1, t, k: LongWord;
  table, tabend: PLongWord;
  q1: PByte;
begin
  table := HT + HashX(N, p, HashShift, $FFFFFFFF) * LongWord(Row2);
  tabend := table + Row2;
  x1 := p - Base;
  v1 := Key(p);
  k := v1;
  q1 := nil;
  while table <> tabend do
  begin
    x0 := x1; x1 := table^; table^ := x0; Inc(table);
    v0 := v1; v1 := table^; table^ := v0; Inc(table);
    t := v1 xor k;
    if (t and $FF) = 0 then
    begin
      q1 := Base + x1;
      if (t = 0) and AcceptOptimalMatch(N + 3, p, q1, bufend) then goto len7
      else if ((t and $FF00) <> 0) and AcceptOptimalMatch(N, p, q1, bufend) then
        begin m^ := N; Inc(m); m^ := p - q1; Inc(m); goto len4; end
      else if ((t and $FF0000) <> 0) and AcceptOptimalMatch(N + 1, p, q1, bufend) then
        begin m^ := N + 1; Inc(m); m^ := p - q1; Inc(m); goto len5; end
      else if AcceptOptimalMatch(N + 2, p, q1, bufend) then
        begin m^ := N + 2; Inc(m); m^ := p - q1; Inc(m); goto len6; end;
    end;
  end;
  Exit(m);

len4:
  while table <> tabend do
  begin
    x0 := x1; x1 := table^; table^ := x0; Inc(table);
    v0 := v1; v1 := table^; table^ := v0; Inc(table);
    t := v1 xor k;
    if (t and $FFFF) = 0 then
    begin
      q1 := Base + x1;
      if (t = 0) and AcceptOptimalMatch(N + 3, p, q1, bufend) then goto len7
      else if ((t and $FF0000) <> 0) and AcceptOptimalMatch(N + 1, p, q1, bufend) then
        begin m^ := N + 1; Inc(m); m^ := p - q1; Inc(m); goto len5; end
      else if AcceptOptimalMatch(N + 2, p, q1, bufend) then
        begin m^ := N + 2; Inc(m); m^ := p - q1; Inc(m); goto len6; end;
    end;
  end;
  Exit(m);

len5:
  while table <> tabend do
  begin
    x0 := x1; x1 := table^; table^ := x0; Inc(table);
    v0 := v1; v1 := table^; table^ := v0; Inc(table);
    t := v1 xor k;
    if (t and $FFFFFF) = 0 then
    begin
      q1 := Base + x1;
      if (t = 0) and AcceptOptimalMatch(N + 3, p, q1, bufend) then goto len7
      else if AcceptOptimalMatch(N + 2, p, q1, bufend) then
        begin m^ := N + 2; Inc(m); m^ := p - q1; Inc(m); goto len6; end;
    end;
  end;
  Exit(m);

len6:
  while table <> tabend do
  begin
    x0 := x1; x1 := table^; table^ := x0; Inc(table);
    v0 := v1; v1 := table^; table^ := v0; Inc(table);
    t := v1 xor k;
    q1 := Base + x1;
    if (t = 0) and AcceptOptimalMatch(N + 3, p, q1, bufend) then goto len7;
  end;
  Exit(m);

len7:
  len := N + 3;
  while (p + len < bufend) and (V32(p + len) = V32(q1 + len)) do Inc(len, 4);
  while (p + len < bufend) and (p[len] = q1[len]) do Inc(len);
  m^ := len; Inc(m); m^ := p - q1; Inc(m);
  while table <> tabend do
  begin
    x0 := x1; x1 := table^; table^ := x0; Inc(table);
    v0 := v1; v1 := table^; table^ := v0; Inc(table);
    t := v1 xor k;
    q1 := Base + x1;
    if (t = 0) and (p[len] = q1[len]) and (V32(p) = V32(q1)) then
    begin
      len1 := 4;
      while (p + len1 < bufend) and (V32(p + len1) = V32(q1 + len1)) do Inc(len1, 4);
      while (p + len1 < bufend) and (p[len1] = q1[len1]) do Inc(len1);
      if len1 > len then
      begin
        len := len1;
        m^ := len; Inc(m); m^ := p - q1; Inc(m);
      end;
    end;
  end;
  Result := m;
end;

function TCachingMF.FindMatchLen(p, bufend: PByte; prevlen: LongWord): LongWord;
label
  len4, len5, len6, len7;
var
  len, len1, x0, x1, v0, v1, t, k: LongWord;
  table, tabend: PLongWord;
  q1: PByte;
begin
  table := HT + HashX(N, p, HashShift, $FFFFFFFF) * LongWord(Row2);
  tabend := table + Row2;
  x1 := p - Base;
  v1 := Key(p);
  k := v1;
  while table <> tabend do
  begin
    x0 := x1; x1 := table^; table^ := x0; Inc(table);
    v0 := v1; v1 := table^; table^ := v0; Inc(table);
    t := v1 xor k;
    if (t and $FF) = 0 then
    begin
      if t = 0 then goto len7
      else if (t and $FF00) <> 0 then goto len4
      else if (t and $FF0000) <> 0 then goto len5
      else goto len6;
    end;
  end;
  Exit(MinLen - 1);

len4:
  Q := Base + x1;
  while table <> tabend do
  begin
    x0 := x1; x1 := table^; table^ := x0; Inc(table);
    v0 := v1; v1 := table^; table^ := v0; Inc(table);
    t := v1 xor k;
    if (t and $FFFF) = 0 then
    begin
      if t = 0 then goto len7
      else if (t and $FF0000) <> 0 then goto len5
      else goto len6;
    end;
  end;
  Exit(AcceptMatch(N, p, Q, bufend));

len5:
  Q := Base + x1;
  while table <> tabend do
  begin
    x0 := x1; x1 := table^; table^ := x0; Inc(table);
    v0 := v1; v1 := table^; table^ := v0; Inc(table);
    t := v1 xor k;
    if (t and $FFFFFF) = 0 then
    begin
      if t = 0 then goto len7 else goto len6;
    end;
  end;
  Exit(AcceptMatch(N + 1, p, Q, bufend));

len6:
  Q := Base + x1;
  while table <> tabend do
  begin
    x0 := x1; x1 := table^; table^ := x0; Inc(table);
    v0 := v1; v1 := table^; table^ := v0; Inc(table);
    t := v1 xor k;
    if t = 0 then goto len7;
  end;
  Exit(AcceptMatch(N + 2, p, Q, bufend));

len7:
  Q := Base + x1;
  len := MinLen - 1;
  if V32(p) = V32(Q) then
  begin
    len := MinI(MinLen - 1, 4);
    while (p + len < bufend) and (V32(p + len) = V32(Q + len)) do Inc(len, 4);
    while (p + len < bufend) and (p[len] = Q[len]) do Inc(len);
  end;
  while table <> tabend do
  begin
    x0 := x1; x1 := table^; table^ := x0; Inc(table);
    v0 := v1; v1 := table^; table^ := v0; Inc(table);
    t := v1 xor k;
    q1 := Base + x1;
    if (t = 0) and (p[len] = q1[len]) and (V32(p) = V32(q1)) then
    begin
      len1 := MinI(MinLen - 1, 4);
      while (p + len1 < bufend) and (V32(p + len1) = V32(q1 + len1)) do Inc(len1, 4);
      while (p + len1 < bufend) and (p[len1] = q1[len1]) do Inc(len1);
      if len1 > len then begin len := len1; Q := q1; end;
    end;
  end;
  Result := len;
end;

procedure TCachingMF.UpdateHash1(p: PByte);
var
  h: SizeInt;
  j: Integer;
begin
  h := SizeInt(HashX(N, p, HashShift, $FFFFFFFF)) * Row2;
  j := RowUp - 2;
  while j <> 0 do    // for (int j=hash_row_width_up; j-=2; )
  begin
    HT[h + j] := HT[h + j - 2];
    HT[h + j + 1] := HT[h + j - 1];
    Dec(j, 2);
  end;
  HT[h] := p - Base;
  HT[h + 1] := Key(p);
end;

procedure TCachingMF.UpdateHash(p: PByte; len, step: LongWord);
var
  i: LongWord;
begin
  if len > 1 then UpdateHash1(p + 1);
  i := 2;
  while i < len - 1 do begin UpdateHash1(p + i); Inc(i, step); end;
  if len > 3 then UpdateHash1(p + len - 1);
end;

{ TCycledMF (CycledCachingMatchFinder<N>) }

constructor TCycledMF.Create(buf: PByte; AHashSize: LongWord; row: Integer; AN: LongWord);
begin
  inherited Create;
  Base := buf;
  N := AN;
  MinLen := AN;
  RowWidth := row;
  if (AHashSize = 2 * LongWord(gb)) and (RowWidth = (1 shl lb(RowWidth))) then Dec(RowWidth);
  HeadSize := LongWord(1) shl lb(AHashSize div LongWord(SizeOf(LongWord) * RowWidth * 2));
  Head := GetMem(HeadSize);
  if Head = nil then OutOfMemoryError;
  HashSize := HeadSize * LongWord(RowWidth) * 2;
  HT := AllocTable(HashSize);
  HashShift := 32 - lb(HeadSize);
  ClearHash(buf);
end;

destructor TCycledMF.Destroy;
begin
  FreeMem(HT);
  FreeMem(Head);
  inherited Destroy;
end;

function TCycledMF.Key(p: PByte): LongWord;
begin
  Result := V32(p + N - 1);
end;

procedure TCycledMF.ClearHash(buf: PByte);
begin
  FillChar(HT^, SizeInt(HashSize) * SizeOf(LongWord), 0);
  FillChar(Head^, HeadSize, 0);
end;

procedure TCycledMF.ShiftHash(buf: PByte; shift: LongWord);
var
  i: SizeInt;
begin
  i := 0;
  while i < SizeInt(HashSize) do
  begin
    if HT[i] > shift then HT[i] := HT[i] - shift else HT[i] := 0;
    Inc(i, 2);
  end;
end;

function TCycledMF.FindAllMatches(p, bufend: PByte; m: PLongWord): PLongWord;
var
  len: LongWord;
begin
  len := FindMatchLen(p, bufend, 0);
  if len >= MinLen then
  begin
    m^ := len; Inc(m); m^ := p - Q; Inc(m);
  end;
  Result := m;
end;

function TCycledMF.FindMatchLen(p, bufend: PByte; prevlen: LongWord): LongWord;
label
  len4, len5, len6, len7;
var
  len, len1, h, i, x1, v1, t, k: LongWord;
  rowstart, rowend, table, tabend: PLongWord;
  q1: PByte;
begin
  h := HashX(N, p, HashShift, $FFFFFFFF);
  if Head[h] = 0 then Head[h] := Byte(RowWidth - 1) else Head[h] := Head[h] - 1;
  i := Head[h];
  rowstart := HT + SizeInt(h) * RowWidth * 2;
  rowend := rowstart + RowWidth * 2;
  table := rowstart + i * 2;
  tabend := table;
  k := Key(p);
  table^ := p - Base; Inc(table);
  table^ := k; Inc(table);
  if table = rowend then table := rowstart;
  x1 := 0;

  while table <> tabend do
  begin
    x1 := table^; Inc(table); if x1 = 0 then Break;
    v1 := table^; Inc(table);
    if table = rowend then table := rowstart;
    t := v1 xor k;
    if (t and $FF) = 0 then
    begin
      if t = 0 then goto len7
      else if (t and $FF00) <> 0 then goto len4
      else if (t and $FF0000) <> 0 then goto len5
      else goto len6;
    end;
  end;
  Exit(MinLen - 1);

len4:
  Q := Base + x1;
  while table <> tabend do
  begin
    x1 := table^; Inc(table); if x1 = 0 then Break;
    v1 := table^; Inc(table);
    if table = rowend then table := rowstart;
    t := v1 xor k;
    if (t and $FFFF) = 0 then
    begin
      if t = 0 then goto len7
      else if (t and $FF0000) <> 0 then
        begin if not ChangePair(p - Q, p - (Base + x1)) then goto len5; end
      else goto len6;
    end;
  end;
  Exit(AcceptMatch(N, p, Q, bufend));

len5:
  Q := Base + x1;
  while table <> tabend do
  begin
    x1 := table^; Inc(table); if x1 = 0 then Break;
    v1 := table^; Inc(table);
    if table = rowend then table := rowstart;
    t := v1 xor k;
    if (t and $FFFFFF) = 0 then
    begin
      if t = 0 then goto len7
      else if not ChangePair(p - Q, p - (Base + x1)) then goto len6;
    end;
  end;
  Exit(AcceptMatch(N + 1, p, Q, bufend));

len6:
  Q := Base + x1;
  while table <> tabend do
  begin
    x1 := table^; Inc(table); if x1 = 0 then Break;
    v1 := table^; Inc(table);
    if table = rowend then table := rowstart;
    t := v1 xor k;
    if t = 0 then
    begin
      q1 := Base + x1;
      if (V32(p + N) = V32(q1 + N)) or not ChangePair(p - Q, p - q1) then goto len7;
    end;
  end;
  Exit(AcceptMatch(N + 2, p, Q, bufend));

len7:
  len := MinLen - 1;
  Q := Base + x1;
  if V32(p) = V32(Q) then
  begin
    len := MinI(MinLen - 1, 4);
    while (p + len < bufend) and (V32(p + len) = V32(Q + len)) do Inc(len, 4);
    while (p + len < bufend) and (p[len] = Q[len]) do Inc(len);
  end;
  while table <> tabend do
  begin
    x1 := table^; Inc(table); if x1 = 0 then Break;
    v1 := table^; Inc(table);
    if table = rowend then table := rowstart;
    t := v1 xor k;
    q1 := Base + x1;
    if (t = 0) and (p[len] = q1[len]) and (V32(p) = V32(q1)) then
    begin
      len1 := MinI(MinLen - 1, 4);
      while (p + len1 < bufend) and (V32(p + len1) = V32(q1 + len1)) do Inc(len1, 4);
      while (p + len1 < bufend) and (p[len1] = q1[len1]) do Inc(len1);
      if (len1 > len) and not ((len1 = len + 1) and ChangePair(p - Q, p - q1)) then
      begin
        len := len1; Q := q1;
      end;
    end;
  end;
  Result := len;
end;

procedure TCycledMF.UpdateHash1(p: PByte);
var
  h, i: LongWord;
  table: PLongWord;
begin
  h := HashX(N, p, HashShift, $FFFFFFFF);
  if Head[h] = 0 then Head[h] := Byte(RowWidth - 1) else Head[h] := Head[h] - 1;
  i := Head[h];
  table := HT + (SizeInt(h) * RowWidth + i) * 2;
  table[0] := p - Base;
  table[1] := Key(p);
end;

procedure TCycledMF.UpdateHash(p: PByte; len, step: LongWord);
var
  i: LongWord;
begin
  i := 1;
  while i < len do begin UpdateHash1(p + i); Inc(i); end;
end;

{ TBTMF (BinaryTreeMatchFinder<N>) }

constructor TBTMF.Create(buf: PByte; ADictSize, AHashSize: LongWord; AMaxDepth: Integer; AN: LongWord; AAllocEnd: PByte);
begin
  inherited Create(buf, AHashSize, 1);
  N := AN;
  MinLen := AN;
  DictSize := ADictSize;
  MaxDepth := AMaxDepth;
  AllocEnd := AAllocEnd;
  BT := AllocTable(2 * QWord(DictSize));
  ClearHash(buf);
end;

destructor TBTMF.Destroy;
begin
  FreeMem(BT);
  inherited Destroy;
end;

procedure TBTMF.ClearHash(buf: PByte);
begin
  FillChar(HT^, SizeInt(HashSize) * SizeOf(LongWord), 0);   // kEmptyHashValue
end;

procedure TBTMF.ShiftHash(buf: PByte; shift: LongWord);
var
  i: SizeInt;
begin
  for i := 0 to SizeInt(HashSize) - 1 do
    if HT[i] > shift then HT[i] := HT[i] - shift else HT[i] := 0;
  for i := SizeInt(shift) * 2 to SizeInt(DictSize) * 2 - 1 do
    if BT[i] > shift then BT[i - SizeInt(shift) * 2] := BT[i] - shift
    else BT[i - SizeInt(shift) * 2] := 0;
end;

function TBTMF.FindAllMatches(p, bufend: PByte; m: PLongWord): PLongWord;
var
  depth: Integer;
  maxLen, h, nn, len0, len1, lenLimit, len, safe: LongWord;
  ptr0, ptr1, pair: PLongWord;
  qq: PByte;
begin
  depth := MaxDepth;
  maxLen := MinLen - 1;
  h := HashX(N, p, HashShift, $FFFFFFFF);
  nn := HT[h];
  HT[h] := p - Base;
  ptr1 := BT + SizeInt(p - Base) * 2;
  ptr0 := ptr1 + 1;
  len0 := 0; len1 := 0;
  lenLimit := LongWord(bufend - p);   // cerca del final p>bufend y queda "negativo" como en el C
  // Tope de seguridad que el C no tiene: no comparar más allá de la memoria reservada
  // (el C leería basura del heap; solo puede pasar en los últimos bytes de la entrada)
  safe := LongWord(AllocEnd - p);
  while True do
  begin
    if (depth = 0) or (nn = 0) then
    begin
      ptr0^ := 0; ptr1^ := 0;
      Break;
    end;
    Dec(depth);
    pair := BT + SizeInt(nn) * 2;
    qq := Base + nn;
    if len0 < len1 then len := len0 else len := len1;
    if qq[len] = p[len] then
    begin
      Inc(len);
      if (len <> lenLimit) and (len < safe) and (qq[len] = p[len]) then
        repeat
          Inc(len);
        until (len = lenLimit) or (len >= safe) or (qq[len] <> p[len]);
      if len > maxLen then
      begin
        maxLen := len;
        m^ := len; Inc(m); m^ := p - qq; Inc(m);
        if len = lenLimit then
        begin
          ptr1^ := pair[0]; ptr0^ := pair[1];
          Break;
        end;
      end;
    end;
    if qq[len] < p[len] then
    begin
      ptr1^ := nn; ptr1 := pair + 1; nn := ptr1^; len1 := len;
    end
    else
    begin
      ptr0^ := nn; ptr0 := pair; nn := ptr0^; len0 := len;
    end;
  end;
  Result := m;
end;

function TBTMF.FindMatchLen(p, bufend: PByte; prevlen: LongWord): LongWord;
begin
  raise ETorEncoder.Create('tor: BinaryTreeMatchFinder solo con el parser óptimo');
end;

procedure TBTMF.UpdateHash(p: PByte; len, step: LongWord);
begin
  raise ETorEncoder.Create('tor: BinaryTreeMatchFinder solo con el parser óptimo');
end;

{ TLazyMF (LazyMatching<MF>) }

constructor TLazyMF.Create(AMF: TMF);
begin
  inherited Create;
  MF := AMF;
  Base := AMF.Base;
  MinLen := AMF.MinLen;
  NextLen := 0;
end;

destructor TLazyMF.Destroy;
begin
  MF.Free;
  inherited Destroy;
end;

function TLazyMF.MatchPtr: PByte;
begin
  Result := PrevQ;
end;

procedure TLazyMF.ClearHash(buf: PByte);
begin
  MF.ClearHash(buf);
  NextLen := 0;
end;

procedure TLazyMF.ShiftHash(buf: PByte; shift: LongWord);
begin
  MF.ShiftHash(buf, shift);
  Dec(NextQ, shift);
end;

function TLazyMF.FindMatchLen(p, bufend: PByte; prevlen: LongWord): LongWord;
var
  plen, nextdist, prevdist: LongWord;
begin
  if NextLen = 0 then
  begin
    NextLen := MF.FindMatchLen(p, bufend, prevlen);
    NextQ := MF.MatchPtr;
  end;
  plen := NextLen;
  PrevQ := NextQ;
  NextLen := MF.FindMatchLen(p + 1, bufend, plen);
  NextQ := MF.MatchPtr;
  nextdist := LongWord(p + 1 - NextQ);
  prevdist := LongWord(p - PrevQ);
  // Extender el match de p+1 un byte hacia atrás si es mejor que el de p
  if (NextLen >= MinLen) and (NextQ[-1] = p^) and
     ((NextLen + 1 >= plen) and (nextdist < prevdist) or
      (NextLen + 1 = plen + 1) and not ChangePair(prevdist, nextdist) or
      (NextLen + 1 > plen + 1) or
      (NextLen + 1 + 1 >= plen) and (plen >= MinLen) and ChangePair(nextdist, prevdist)) then
  begin
    PrevQ := NextQ - 1;
    Exit(NextLen + 1);
  end;
  // Truncar el match actual si el de la próxima posición es mejor (algoritmo de LZMA)
  if (NextLen >= plen) and (nextdist < prevdist div 4) or
     (NextLen = plen + 1) and not ChangePair(prevdist, nextdist) or
     (NextLen > plen + 1) or
     (NextLen + 1 >= plen) and (plen >= MinLen) and ChangePair(nextdist, prevdist) then
    Result := MinLen - 1
  else
    Result := plen;
end;

procedure TLazyMF.UpdateHash(p: PByte; len, step: LongWord);
begin
  MF.UpdateHash(p + 1, len - 1, step);
  NextLen := 0;
end;

procedure TLazyMF.UpdateHash1(p: PByte);
begin
  raise ETorEncoder.Create('tor: LazyMatching::update_hash1 no existe');
end;

procedure TLazyMF.InvalidateMatch;
begin
  MF.InvalidateMatch;
  NextLen := MinLen - 1;   // no 0: p ya está en el hash
end;

{ THash3MF }

constructor THash3MF.Create(AMF: TMF; ALog3, ALog2: Integer; AFull: Boolean; buf: PByte);
begin
  inherited Create;
  MF := AMF;
  Base := buf;
  MinLen := 2;
  Log3 := ALog3; Log2 := ALog2; FullUpdate := AFull;
  HashSize3 := LongWord(1) shl ALog3;
  HashSize2 := LongWord(1) shl ALog2;
  HT3 := AllocTable(HashSize3);
  HT2 := AllocTable(HashSize2);
  // clear_hash3
  FillDWord(HT3^, HashSize3, 1);
  FillDWord(HT2^, HashSize2, 1);
end;

destructor THash3MF.Destroy;
begin
  FreeMem(HT3);
  FreeMem(HT2);
  MF.Free;
  inherited Destroy;
end;

function THash3MF.H3(x: LongWord): LongWord;
begin
  Result := Mul32(x, K3) shr (32 - Log3);
end;

function THash3MF.H2(x: LongWord): LongWord;
begin
  Result := Mul32(x, K1) shr (32 - Log2);
end;

procedure THash3MF.ClearHash(buf: PByte);
begin
  MF.ClearHash(buf);
  FillDWord(HT3^, HashSize3, 1);
  FillDWord(HT2^, HashSize2, 1);
end;

procedure THash3MF.ShiftHash(buf: PByte; shift: LongWord);
var
  i: SizeInt;
begin
  MF.ShiftHash(buf, shift);
  for i := 0 to SizeInt(HashSize3) - 1 do
    if HT3[i] > shift then HT3[i] := HT3[i] - shift else HT3[i] := 1;
  for i := 0 to SizeInt(HashSize2) - 1 do
    if HT2[i] > shift then HT2[i] := HT2[i] - shift else HT2[i] := 1;
end;

function THash3MF.FindAllMatches(p, bufend: PByte; m: PLongWord): PLongWord;
var
  h: LongWord;
  qq: PByte;
begin
  h := H2(V16(p));
  qq := Base + HT2[h];  HT2[h] := p - Base;
  if (p + 2 <= bufend) and (V16(p) = V16(qq)) then
  begin
    m^ := 2; Inc(m); m^ := p - qq; Inc(m);
  end;
  h := H3(V24(p));
  qq := Base + HT3[h];  HT3[h] := p - Base;
  if (p + 3 <= bufend) and (V24(p) = V24(qq)) then
  begin
    m^ := 3; Inc(m); m^ := p - qq; Inc(m);
  end;
  Result := MF.FindAllMatches(p, bufend, m);
end;

function THash3MF.FindMatchLen(p, bufend: PByte; prevlen: LongWord): LongWord;
var
  len, h: LongWord;
begin
  len := MF.FindMatchLen(p, bufend, prevlen);
  Q := MF.MatchPtr;
  // Si no se encontró match largo, probar con 2/3 bytes
  if len < MF.MinLen then
  begin
    h := H3(V24(p));
    Q := Base + HT3[h];  HT3[h] := p - Base;
    if (p - Q < 6 * kb) and (p + 3 <= bufend) and (V24(p) = V24(Q)) then
    begin
      HT2[H2(V16(p))] := p - Base;
      Exit(3);
    end
    else
    begin
      h := H2(V16(p));
      Q := Base + HT2[h];  HT2[h] := p - Base;
      if (p - Q < 256) and (p + 2 <= bufend) and (V16(p) = V16(Q)) then Exit(2)
      else Exit(MinLen - 1);
    end;
  end;
  HT3[H3(V24(p))] := p - Base;
  HT2[H2(V16(p))] := p - Base;
  Result := len;
end;

procedure THash3MF.UpdateHash1(p: PByte);
begin
  HT3[H3(V24(p))] := p - Base;
  if FullUpdate then HT2[H2(V16(p))] := p - Base;
end;

procedure THash3MF.UpdateHash(p: PByte; len, step: LongWord);
var
  i: LongWord;
begin
  MF.UpdateHash(p, len, step);
  if FullUpdate then
  begin
    i := 1;
    while i < len do begin UpdateHash1(p + i); Inc(i); end;
  end
  else
  begin
    if len > 1 then UpdateHash1(p + 1);
    if len > 3 then UpdateHash1(p + len - 1);
  end;
end;

procedure THash3MF.InvalidateMatch;
begin
  MF.InvalidateMatch;
end;

{ TCombineMF }

constructor TCombineMF.Create(A1, A2: TMF);
begin
  inherited Create;
  MF1 := A1; MF2 := A2;
  Base := A1.Base;
  if A1.MinLen < A2.MinLen then MinLen := A1.MinLen else MinLen := A2.MinLen;
end;

destructor TCombineMF.Destroy;
begin
  MF1.Free;
  MF2.Free;
  inherited Destroy;
end;

function TCombineMF.FindAllMatches(p, bufend: PByte; m: PLongWord): PLongWord;
begin
  m := MF2.FindAllMatches(p, bufend, m);
  Result := MF1.FindAllMatches(p, bufend, m);
end;

function TCombineMF.FindMatchLen(p, bufend: PByte; prevlen: LongWord): LongWord;
var
  len1, len2: LongWord;
  q1, q2: PByte;
begin
  len1 := MF1.FindMatchLen(p, bufend, prevlen);
  q1 := MF1.MatchPtr;
  if len1 > MF1.MinLen then
  begin
    MF2.UpdateHash1(p);
    Q := q1;
    Exit(len1);
  end;
  len2 := MF2.FindMatchLen(p, bufend, prevlen);
  q2 := MF2.MatchPtr;
  if (len1 >= MF1.MinLen) and (len1 > len2) and
     not ((len2 >= MF2.MinLen) and (len1 = len2 + 1) and ChangePair(p - q2, p - q1)) then
  begin
    Q := q1; Result := len1;
  end
  else
  begin
    Q := q2; Result := len2;
  end;
end;

procedure TCombineMF.ClearHash(buf: PByte);
begin
  MF1.ClearHash(buf);
  MF2.ClearHash(buf);
end;

procedure TCombineMF.ShiftHash(buf: PByte; shift: LongWord);
begin
  MF1.ShiftHash(buf, shift);
  MF2.ShiftHash(buf, shift);
  Dec(Q, shift);
end;

procedure TCombineMF.UpdateHash1(p: PByte);
begin
  MF1.UpdateHash1(p);
  MF2.UpdateHash1(p);
end;

procedure TCombineMF.UpdateHash(p: PByte; len, step: LongWord);
begin
  MF1.UpdateHash(p, len, step);
  MF2.UpdateHash(p, len, step);
end;

procedure TCombineMF.InvalidateMatch;
begin
  MF1.InvalidateMatch;
  MF2.InvalidateMatch;
end;

{ ---------------------------------------------------------------------------------------- }
{ Codificadores (EntropyCoder.cpp + LZ77_Coder.cpp). Uno solo con el tipo en Kind:          }
{ 1 LZ77_ByteCoder, 2 LZ77_BitCoder, 3 LZ77_Coder<HuffmanEncoder>, 4 LZ77_Coder<ArithCoder> }
{ (LZ77_DynamicCoder es exactamente elegir uno de estos cuatro en tiempo de ejecución).     }
{ ---------------------------------------------------------------------------------------- }

type
  TTorEmit = procedure(P: PByte; N: SizeInt) of object;

  THufNode = record
    Cnt, Code: LongWord;
    Left, Right: Word;
    Bits: Byte;
  end;

  TTorCoder = class
  public
    Kind: Integer;
    SupportTables, SupportRepdist: Boolean;
    // OutputByteStream
    Out: array of Byte;
    O: SizeInt;
    Anchor: SizeInt;             // -1 = &garbage
    OnEmit: TTorEmit;
    CanFlush: Boolean;
    // LZ77_ByteCoder
    Flags, FlagBit: LongWord;
    // OutputBitStream
    BitBuf: QWord;
    BitCount: Integer;
    // HuffmanTree (Encoder)
    HufCounter: array[0..MAXHUF - 1] of LongWord;
    HufBits: array[0..MAXHUF - 1] of Byte;
    HufCode: array[0..MAXHUF - 1] of LongWord;
    HufN, HufRemainder: Integer;
    Nodes: array[0..2 * MAXHUF + 3] of THufNode;
    Rest: array[0..MAXHUF - 1] of LongWord;     // code[] reusado como temporal en el C
    // TRangeCoder
    Low: Int64;
    Range, RBuffer, Help: LongWord;
    // TCounter<Encoder>
    ACnt, ACum, ALive, APrice: array[0..2047] of LongWord;
    AN, ARemainder: LongWord;
    // LZ77_Coder
    PrevDist0, PrevDist1, PrevDist2, PrevDist3: LongInt;

    constructor Create(AKind: Integer; InitCap: SizeInt);
    procedure EnsureOut(n: SizeInt); inline;
    procedure Grow(n: SizeInt);
    procedure Put8(c: LongWord); inline;
    procedure Put16(c: LongWord); inline;
    procedure Put24(c: LongWord); inline;
    procedure Put32(c: LongWord); inline;
    procedure PutBits(n: Integer; x: LongWord); inline;
    procedure HufBuildTree(RescaleMode: Integer);
    procedure HufEncode(x: LongWord);
    procedure ShiftLow;
    procedure RcEncode(cum, cnt: LongWord; bits: Integer); inline;
    procedure ARescale;
    procedure AriEncode(x: LongWord); inline;
    procedure Sym(x: LongWord); inline;
    procedure SymLowerBits(n: Integer; x: LongWord); inline;
    procedure EncodeMatch(len, dist: LongInt);
    { encode(len, current, match, MINLEN); Dist = current-match. True = match codificado. }
    function Encode(Len: LongInt; Cur: PByte; Dist: LongWord; MinLen: LongInt): Boolean;
    procedure EncodeTable(Typ, Len: Integer);
    procedure AfterShift;
    procedure Flush;
    procedure Finish;
    // Precios (parser óptimo)
    function Price(x: LongWord; extra: LongWord): LongWord; inline;
    function LitPrice(c: LongWord): LongWord; inline;
    function MatchPrice(len: LongInt; dist: LongWord): LongWord;
    function RepdistPrice(len: LongInt; i: LongWord): LongWord; inline;
    function PriceLenDcode(len: LongInt; dcode, dbits: LongWord): LongWord; inline;
  end;

function LcCode(const V: TVle; len: LongWord; Elements: LongWord): LongWord; inline;
begin
  if len > 600 then Result := Elements - 1 else Result := V.Code[len];
end;

function DcCode(dist: LongWord): LongWord; inline;
begin
  if dist < 512 then Result := Dc.Code[dist]
  else if dist < 512 * 256 then Result := Dc.Code[512 + (dist shr 8)]
  else Result := Dc.Code[1024 + (dist shr 16)];
end;

function Mask(x: LongWord; n: Integer): LongWord; inline;
begin
  Result := x and ((LongWord(1) shl n) - 1);
end;

constructor TTorCoder.Create(AKind: Integer; InitCap: SizeInt);
var
  s: Integer;
begin
  inherited Create;
  Kind := AKind;
  SupportTables := Kind >= 3;
  SupportRepdist := Kind >= 3;
  if InitCap < 64 * kb then InitCap := 64 * kb;
  SetLength(Out, InitCap);
  O := 0;
  Anchor := -1;
  // LZ77_ByteCoder: flags=0, flagbit=0 (el primer encode abre la palabra de banderas)
  Flags := 0; FlagBit := 0;
  BitBuf := 0; BitCount := 0;
  PrevDist0 := -1; PrevDist1 := -1; PrevDist2 := -1; PrevDist3 := -1;
  if Kind = 3 then
  begin
    // HuffmanTree::init(Encoder, CODES)
    HufN := CODES;
    for s := 0 to HufN - 1 do HufCounter[s] := 1;
    HufBuildTree(0);
    HufRemainder := HUFBLOCKSIZE div 4;
  end
  else if Kind = 4 then
  begin
    Low := 0; Range := $FFFFFFFF; RBuffer := 0; Help := 0;
    // TCounter(n)
    AN := CODES;
    for s := 0 to AN - 1 do
      if LongWord(s) < RANGE_ - (RANGE_ div AN) * AN then ALive[s] := RANGE_ div AN + 1
      else ALive[s] := RANGE_ div AN;
    ARescale;
  end;
end;

procedure TTorCoder.Grow(n: SizeInt);
var
  NewLen: SizeInt;
begin
  NewLen := Length(Out) * 2;
  if NewLen < O + n + 64 * kb then NewLen := O + n + 64 * kb;
  SetLength(Out, NewLen);
end;

procedure TTorCoder.EnsureOut(n: SizeInt);
begin
  if O + n + 16 > Length(Out) then Grow(n + 16);
end;

procedure TTorCoder.Put8(c: LongWord);
begin
  Out[O] := Byte(c);
  Inc(O);
end;

procedure TTorCoder.Put16(c: LongWord);
begin
  PWord(@Out[O])^ := Word(c);
  Inc(O, 2);
end;

procedure TTorCoder.Put24(c: LongWord);
begin
  PLongWord(@Out[O])^ := c;     // setvalue32 + advance(3), como el C
  Inc(O, 3);
end;

procedure TTorCoder.Put32(c: LongWord);
begin
  PLongWord(@Out[O])^ := c;
  Inc(O, 4);
end;

{ OutputBitStream::putbits (versión de 64 bits; el stream de bytes es el mismo que el de 32) }
procedure TTorCoder.PutBits(n: Integer; x: LongWord);
begin
  BitBuf := BitBuf or (QWord(x) shl BitCount);
  Inc(BitCount, n);
  if BitCount >= 64 then
  begin
    PQWord(@Out[O])^ := BitBuf;
    Inc(O, 8);
    Dec(BitCount, 64);
    BitBuf := QWord(x) shr (n - BitCount);
  end;
end;

{ HuffmanTree::build_tree, solo la parte del codificador }
procedure TTorCoder.HufBuildTree(RescaleMode: Integer);
const
  CHUNKS = 250;
  FENCE = $7FFFFFFF;   // INT_MAX
var
  places: array[0..CHUNKS] of Integer;
  b, i, j, p, p1, p2, p3, nr: Integer;
  s: LongWord;
  factor: LongWord;
  tmp: LongWord;
begin
  b := 0;
  for i := 0 to CHUNKS do places[i] := 0;
  for i := 0 to HufN - 1 do
  begin
    if HufCounter[i] < CHUNKS then Inc(places[HufCounter[i] + 1]);
    Inc(b);
  end;
  for i := 0 to CHUNKS - 1 do Inc(places[i + 1], places[i]);
  nr := 0;
  for i := 0 to HufN - 1 do
    if HufCounter[i] < CHUNKS then
    begin
      p := places[HufCounter[i]];
      Inc(places[HufCounter[i]]);
      Nodes[p].Cnt := HufCounter[i];
      Nodes[p].Left := i;
    end
    else
    begin
      rest[nr] := HufCounter[i] * MAXHUF + LongWord(i);   // make_node
      Inc(nr);
    end;
  // Orden estable por (contador, índice): las claves son distintas, cualquier sort sirve
  for i := 1 to nr - 1 do
  begin
    tmp := rest[i];
    j := i - 1;
    while (j >= 0) and (rest[j] > tmp) do
    begin
      rest[j + 1] := rest[j];
      Dec(j);
    end;
    rest[j + 1] := tmp;
  end;
  for i := 0 to nr - 1 do
  begin
    p := i + places[CHUNKS];
    Nodes[p].Cnt := rest[i] div MAXHUF;
    Nodes[p].Left := rest[i] mod MAXHUF;
  end;
  for i := 0 to b + 3 do Nodes[b + i].Cnt := FENCE;
  p1 := 0; p2 := b + 2; p3 := b + 2;
  while not ((p1 = b) and (p3 - p2 = 1)) do
  begin
    if Nodes[p1 + 1].Cnt < Nodes[p2].Cnt then
    begin
      Nodes[p3].Cnt := Nodes[p1].Cnt + Nodes[p1 + 1].Cnt;
      Nodes[p3].Left := p1;
      Nodes[p3].Right := p1 + 1;
      Inc(p1, 2);
    end
    else if Nodes[p1].Cnt > Nodes[p2 + 1].Cnt then
    begin
      Nodes[p3].Cnt := Nodes[p2].Cnt + Nodes[p2 + 1].Cnt;
      Nodes[p3].Left := p2;
      Nodes[p3].Right := p2 + 1;
      Inc(p2, 2);
    end
    else
    begin
      Nodes[p3].Cnt := Nodes[p1].Cnt + Nodes[p2].Cnt;
      Nodes[p3].Left := p1;
      Nodes[p3].Right := p2;
      Inc(p1); Inc(p2);
    end;
    Inc(p3);
  end;
  Nodes[p2].Bits := 0;
  Nodes[p2].Code := 0;
  i := p2;
  while i >= b + 2 do
  begin
    Nodes[Nodes[i].Left].Bits := Nodes[i].Bits + 1;
    Nodes[Nodes[i].Left].Code := Nodes[i].Code;
    Nodes[Nodes[i].Right].Bits := Nodes[i].Bits + 1;
    Nodes[Nodes[i].Right].Code := Nodes[i].Code + (LongWord(1) shl Nodes[i].Bits);
    Dec(i);
  end;
  for i := 0 to b - 1 do
  begin
    s := Nodes[i].Left;
    HufBits[s] := Nodes[i].Bits;
    HufCode[s] := Nodes[i].Code;
  end;
  // rescale(FACTOR)
  case RescaleMode of
    0: factor := 2;
    1: factor := 3;
    2: factor := 4;
    3: factor := 6;
    4: factor := 8;
    5: factor := 10;
    6: factor := 12;
    7: factor := 16;
  else
    factor := 0;
  end;
  if factor <> 0 then
    for i := 0 to HufN - 1 do
      if (HufCounter[i] > 1) and (HufCounter[i] < factor) then Dec(HufCounter[i])
      else Dec(HufCounter[i], HufCounter[i] div factor);
end;

{ HuffmanEncoder::encode }
procedure TTorCoder.HufEncode(x: LongWord);
begin
  Dec(HufRemainder);
  if HufRemainder = 0 then
  begin
    PutBits(HufBits[EOB_CODE], HufCode[EOB_CODE]);
    PutBits(3, 3);                  // rescale_mode = 3
    HufBuildTree(3);
    HufRemainder := HUFBLOCKSIZE;
  end;
  Inc(HufCounter[x]);
  PutBits(HufBits[x], HufCode[x]);
end;

{ TRangeCoder::ShiftLow }
procedure TTorCoder.ShiftLow;
var
  c: LongWord;
begin
  if (Low xor Int64($FF000000)) >= (1 shl 24) then
  begin
    c := LongWord(Low shr 32);
    EnsureOut(SizeInt(Help) + 1);
    Put8(RBuffer + c);
    c := c + 255;
    while Help > 0 do
    begin
      Put8(c);
      Dec(Help);
    end;
    RBuffer := LongWord(Low) shr 24;
  end
  else
    Inc(Help);
  Low := Int64(LongWord(LongWord(Low) shl 8));
end;

procedure TTorCoder.RcEncode(cum, cnt: LongWord; bits: Integer);
begin
  Range := Range shr bits;
  Low := Low + Int64(LongWord(cum * Range));
  Range := Range * cnt;
  while Range < (1 shl 24) do
  begin
    Range := Range shl 8;
    ShiftLow;
  end;
end;

{ TCounter::Rescale (los precios solo los usa el parser óptimo) }
procedure TTorCoder.ARescale;
var
  total, s, l: LongWord;
begin
  total := 0;
  ARemainder := RANGE_;
  for s := 0 to AN - 1 do
  begin
    ACnt[s] := ALive[s];
    ACum[s] := total;
    Inc(total, ACnt[s]);
    l := ALive[s];
    if (l > 1) and (l < 6) then Dec(l) else Dec(l, l div 6);
    ALive[s] := l;
    Dec(ARemainder, l);
    APrice[s] := PriceTab[ACnt[s]];
  end;
end;

procedure TTorCoder.AriEncode(x: LongWord);
begin
  RcEncode(ACum[x], ACnt[x], RANGE_BITS);
  Inc(ALive[x]);
  Dec(ARemainder);
  if ARemainder = 0 then ARescale;
end;

procedure TTorCoder.Sym(x: LongWord);
begin
  if Kind = 3 then HufEncode(x) else AriEncode(x);
end;

{ Coder::putlowerbits }
procedure TTorCoder.SymLowerBits(n: Integer; x: LongWord);
begin
  if Kind = 3 then
    PutBits(n, Mask(x, n))
  else if n <= 24 then
    RcEncode(Mask(x, n), 1, n)
  else
  begin
    RcEncode(Mask(x, 15), 1, 15);
    x := x shr 15;
    Dec(n, 15);
    RcEncode(Mask(x, n), 1, n);
  end;
end;

{ LZ77_Coder::encode_match }
procedure TTorCoder.EncodeMatch(len, dist: LongInt);
var
  dcode, dbits, dbase, x, y, lcode, lbits, lbase: LongWord;
begin
  dbase := 0;
  x := LongWord(PrevDist0); PrevDist0 := dist;
  if LongWord(dist) = x then begin dcode := 0; dbits := 0; end
  else
  begin
    y := LongWord(PrevDist1); PrevDist1 := LongInt(x);
    if LongWord(dist) = y then begin dcode := 1; dbits := 0; end
    else
    begin
      x := LongWord(PrevDist2); PrevDist2 := LongInt(y);
      if LongWord(dist) = x then begin dcode := 2; dbits := 0; end
      else
      begin
        y := LongWord(PrevDist3); PrevDist3 := LongInt(x);
        if LongWord(dist) = y then begin dcode := 3; dbits := 0; end
        else
        begin
          dcode := DcCode(LongWord(dist));
          dbits := Dc.Extra[dcode];
          dbase := Dc.Base[dcode];
          Inc(dcode, REPDIST_CODES);
        end;
      end;
    end;
  end;
  // Largos 101..104 representan tablas (y anulan prevdist0)
  if len > 100 then
  begin
    if len > IMPOSSIBLE_LEN then
    begin
      PrevDist0 := -1;
      if len <= IMPOSSIBLE_LEN + 4 then len := len - (IMPOSSIBLE_LEN - 100);
    end
    else
      len := len + 4;
  end;
  lcode := LcCode(Lc2, LongWord(len), 16);
  lbits := Lc2.Extra[lcode];
  lbase := Lc2.Base[lcode];
  Sym(256 + dcode * 16 + lcode);
  SymLowerBits(lbits, LongWord(len) - lbase);
  SymLowerBits(dbits, LongWord(dist) - dbase);
end;

function TTorCoder.Encode(Len: LongInt; Cur: PByte; Dist: LongWord; MinLen: LongInt): Boolean;
var
  l, lcode, lbits, lbase, dcode, dbits, dbase: LongWord;
begin
  case Kind of
    1:
      begin
        // LZ77_ByteCoder::encode
        FlagBit := FlagBit shl 2;
        if FlagBit = 0 then
        begin
          if Anchor >= 0 then PLongWord(@Out[Anchor])^ := Flags;
          Flags := 0; FlagBit := 1;
          Anchor := O; Inc(O, 4);
        end;
        if Len < MinLen then
        begin
          Put8(Cur^);
          Exit(False);
        end;
        if (Len < MinLen + 16) and (Dist < (1 shl 12)) then
        begin
          Put16((LongWord(Len - MinLen) shl 12) + Dist);
          Inc(Flags, FlagBit);
        end
        else if (Len < MinLen + 64) and (Dist < (1 shl 18)) then
        begin
          Put24((LongWord(Len - MinLen) shl 18) + Dist);
          Inc(Flags, FlagBit * 2);
        end
        else
        begin
          Dec(Len, MinLen);
          if Dist >= (1 shl 24) then begin Put8(255); Put8(Dist shr 24); end;
          if Len >= 254 then begin Put8(254); Put24(LongWord(Len) shr 8); Len := Len mod 256; end;
          Put32(LongWord(Len) + (Dist shl 8));
          Inc(Flags, FlagBit * 3);
        end;
        Result := True;
      end;
    2:
      begin
        // LZ77_BitCoder::encode
        Dec(Len, MinLen);
        if Len < 0 then
        begin
          PutBits(9, Cur^);
          Exit(False);
        end;
        l := LongWord(Len);
        lcode := LcCode(Lc, l, 8);
        lbits := Lc.Extra[lcode];
        lbase := Lc.Base[lcode];
        dcode := DcCode(Dist);
        dbits := Dc.Extra[dcode];
        dbase := Dc.Base[dcode];
        PutBits(9, 256 + (lcode shl 5) + dcode);
        PutBits(lbits, Mask(l - lbase, lbits));
        PutBits(dbits, Mask(Dist - dbase, dbits));
        Result := True;
      end;
  else
    begin
      // LZ77_Coder::encode
      Dec(Len, MinLen);
      if Len < 0 then
      begin
        if (PrevDist0 >= 0) and (Cur^ = Cur[-PrevDist0 - 1]) then Sym(REPCHAR)
        else Sym(Cur^);
        Exit(False);
      end;
      EncodeMatch(Len, LongInt(Dist) - 1);
      Result := True;
    end;
  end;
end;

procedure TTorCoder.EncodeTable(Typ, Len: Integer);
begin
  EncodeMatch(IMPOSSIBLE_LEN + Typ, Len - 1);
end;

procedure TTorCoder.AfterShift;
begin
  if Kind >= 3 then PrevDist0 := -1;
end;

{ OutputByteStream::flush: entrega lo acumulado salvo los últimos 512 bytes (la palabra de
  banderas del bytecoder puede estar ahí). Cuándo se entrega no cambia el stream. }
procedure TTorCoder.Flush;
var
  n: SizeInt;
begin
  if not CanFlush then Exit;
  if O > 512 + 256 * kb then
  begin
    n := (O - 512) and not SizeInt(4095);
    OnEmit(@Out[0], n);
    Move(Out[n], Out[0], O - n);
    Dec(O, n);
    if Anchor >= 0 then Dec(Anchor, n);
  end;
end;

procedure TTorCoder.Finish;
var
  i: Integer;
begin
  EnsureOut(64);
  case Kind of
    1: if Anchor >= 0 then PLongWord(@Out[Anchor])^ := Flags;
    2, 3:
      while BitCount > 0 do
      begin
        Put8(LongWord(BitBuf));
        BitBuf := BitBuf shr 8;
        Dec(BitCount, 8);
      end;
    4:
      for i := 1 to 5 do ShiftLow;
  end;
  if CanFlush and (O > 0) then
  begin
    OnEmit(@Out[0], O);
    O := 0;
  end;
end;

function TTorCoder.Price(x: LongWord; extra: LongWord): LongWord;
begin
  if Kind = 4 then Result := APrice[x] + extra * 1024
  else Result := HufBits[x] + extra;
end;

function TTorCoder.LitPrice(c: LongWord): LongWord;
begin
  case Kind of
    1: Result := 10;
    2: Result := 9;
  else
    Result := Price(c, 0);
  end;
end;

function TTorCoder.PriceLenDcode(len: LongInt; dcode, dbits: LongWord): LongWord;
var
  lcode: LongWord;
begin
  lcode := LcCode(Lc2, LongWord(len), 16);
  Result := Price(256 + dcode * 16 + lcode, Lc2.Extra[lcode] + dbits);
end;

function TTorCoder.MatchPrice(len: LongInt; dist: LongWord): LongWord;
var
  lcode, dcode: LongWord;
begin
  case Kind of
    1:
      if (len < 16) and (LongInt(dist) < (1 shl 12)) then Result := 18
      else if (len < 64) and (LongInt(dist) < (1 shl 18)) then Result := 26
      else
      begin
        Result := 34;
        if LongInt(dist) >= (1 shl 24) then Inc(Result, 16);
        if len >= 254 then Inc(Result, 32);
      end;
    2:
      begin
        lcode := LcCode(Lc, LongWord(len), 8);
        dcode := DcCode(dist);
        Result := 9 + Lc.Extra[lcode] + Dc.Extra[dcode];
      end;
  else
    begin
      dcode := DcCode(dist);
      Result := PriceLenDcode(len, dcode + REPDIST_CODES, Dc.Extra[dcode]);
    end;
  end;
end;

function TTorCoder.RepdistPrice(len: LongInt; i: LongWord): LongWord;
begin
  Result := PriceLenDcode(len, i, 0);
end;

{ ---------------------------------------------------------------------------------------- }
{ Motor: tor_compress_chunk / tor_compress_chunk_optimal / read_next_chunk, reanudable en   }
{ cada punto donde el C llama al callback "read".                                           }
{ ---------------------------------------------------------------------------------------- }

type
  TOptInfo = record
    len: LongInt;
    dist: LongWord;
    prevdist: array[0..REPDIST_CODES - 1] of LongWord;
  end;

  TEngState = (esFirst, esRead, esDone);

  TTorEngine = class
  public
    M: TTorMethod;
    Combo: Integer;
    Optimal, AllAtOnce: Boolean;
    MF: TMF;
    C: TTorCoder;
    Mem, Buf: PByte;
    BufAlloc: SizeInt;
    State: TEngState;
    // Lectura pendiente: el C pidió ReadWant bytes en ReadDst
    ReadDst: PByte;
    ReadWant, ReadGot: SizeInt;
    // tor_compress_chunk
    P, BufEnd, MatchEnd, ReadPoint: PByte;
    Bytes, Chunk: SizeInt;
    TableEnd, LastFound: PByte;
    LastChecked: array[0..MAX_TABLE_ROW - 1, 0..MAX_TABLE_ROW - 1] of PByte;
    UseTables: Boolean;
    // OptimalParser
    X: array of TOptInfo;
    Prices: array of LongWord;
    Stack: array of LongWord;
    BaseP, LastP, EndBuf, Silence: PByte;
    Matches: array of LongWord;

    constructor Create(const AM: TTorMethod; ACombo: Integer; AAllAtOnce: Boolean; OutCap: SizeInt);
    destructor Destroy; override;
    procedure Resume;               // la lectura pendiente terminó con ReadGot bytes
    procedure Start;
    procedure Run(Resuming: Boolean);
    procedure RunOptimal(Resuming: Boolean);
    function ReadPart1: Boolean;    // True = hay que esperar datos
    procedure ReadPart2;
    procedure FinishStream;
    function CheckForDataTable(N: Integer; out Typ, Items: Integer): Boolean;
    function CheckTable(N: Integer): Boolean;
    // OptimalParser
    procedure StartBlock(ABaseP: PByte);
    procedure EncodeBlock(EndP: PByte);
    procedure Evaluate(pp: PByte; len: LongInt; dist: LongWord; NewPrice: LongWord); inline;
    function EvalLitRep(pp: PByte): LongInt;
    function EvalMatches(pp: PByte; len: LongInt; mm, me: PLongWord): LongInt;
  end;

{ Combinaciones de tor_compress sin FULL_COMPILE (Tornado.cpp:413) }
function SelectCombo(const m: TTorMethod): Integer;
begin
  Result := 0;
  with m do
    if (EncodingMethod = 1) and (HashRowWidth = 1) and (Hash3 = 0) and (MatchFinder = NON_CACHING_MF) and (MatchParser = GREEDY) or
       (EncodingMethod = 0) then Result := 1
    else if (EncodingMethod = 2) and (HashRowWidth = 1) and (Hash3 = 0) and (MatchFinder = NON_CACHING_MF) and (MatchParser = GREEDY) then Result := 2
    else if (EncodingMethod = 3) and (HashRowWidth = 2) and (Hash3 = 0) and (MatchFinder = NON_CACHING_MF) and (MatchParser = GREEDY) then Result := 3
    else if (EncodingMethod = 3) and (Hash3 = 0) and (MatchFinder = CACHING_MF4) and (MatchParser = GREEDY) then Result := 4
    else if (EncodingMethod = 4) and (Hash3 = 1) and (MatchFinder = CACHING_MF4) and (MatchParser = LAZY) then Result := 5
    else if (EncodingMethod = 3) and (Hash3 = 1) and (MatchFinder = CACHING_MF4) and (MatchParser = LAZY) then Result := 6
    else if (Hash3 = 2) and (MatchFinder = CYCLED_MF5) and (MatchParser = LAZY) then Result := 7
    else if (Hash3 = 2) and (MatchFinder = CYCLED_MF7) and (MatchParser = LAZY) then Result := 8
    else if (Hash3 = 1) and (MatchFinder = CACHING_MF5) and (MatchParser = OPTIMAL) and (EncodingMethod = 4) then Result := 9
    else if (Hash3 = 2) and (MatchFinder = CACHING_MF6) and (MatchParser = OPTIMAL) and (EncodingMethod = 4) then Result := 10
    else if (Hash3 = 2) and (MatchFinder = CACHING_MF6) and (MatchParser = OPTIMAL) then Result := 11
    else if (Hash3 = 2) and (MatchFinder = BT_MF5) and (MatchParser = OPTIMAL) then Result := 12;
end;

{ Ajustes de tor_compress0 / tor_compress0_optimal (bytes_to_compress = -1) }
procedure AdjustMethod(var m: TTorMethod; Opt: Boolean);
begin
  if m.Buffer < 32 * kb then m.Buffer := 32 * kb;
  m.Buffer := (m.Buffer + 4095) and not LongWord(4095);
  if m.HashSize div 8 > m.Buffer then m.HashSize := LongWord(1) shl lb(QWord(m.Buffer) * 8);
  if m.AuxHashSize div 8 > m.Buffer then m.AuxHashSize := LongWord(1) shl lb(QWord(m.Buffer) * 8);
  if m.Shift = 0 then
    if Opt then m.Shift := m.Buffer div 16
    else if m.HashRowWidth > 4 then m.Shift := m.Buffer div 4
    else if m.HashRowWidth > 2 then m.Shift := m.Buffer div 2
    else if m.HashSize >= 512 * kb then m.Shift := (m.Buffer div 4) * 3
    else m.Shift := -1;
end;

function CoderKind(Combo, Enc: Integer): Integer;
begin
  case Combo of
    1: Result := 1;
    2: Result := 2;
    3, 4, 6: Result := 3;
    5, 9, 10: Result := 4;
  else
    Result := Enc;   // LZ77_DynamicCoder
  end;
end;

{ El match finder de cada combinación (se construye después de la primera lectura, como en
  tor_compress_chunk: CachingMatchFinder::clear_hash lee key(buf+1)). }
function BuildMF(const m: TTorMethod; Combo: Integer; buf, AllocEnd: PByte): TMF;
begin
  case Combo of
    1, 2: Result := TMF1.Create(buf, m.HashSize, m.HashRowWidth);
    3: Result := TMF2.Create(buf, m.HashSize, m.HashRowWidth);
    4: Result := TCachingMF.Create(buf, m.HashSize, m.HashRowWidth, 4);
    5, 6: Result := TLazyMF.Create(THash3MF.Create(TCachingMF.Create(buf, m.HashSize, m.HashRowWidth, 4), 14, 10, False, buf));
    7: Result := TLazyMF.Create(THash3MF.Create(TCombineMF.Create(
                   TCycledMF.Create(buf, m.HashSize, m.HashRowWidth, 5),
                   TExactMF.Create(buf, m.AuxHashSize, m.AuxHashRowWidth, 4)), 16, 12, True, buf));
    8: Result := TLazyMF.Create(THash3MF.Create(TCombineMF.Create(
                   TCycledMF.Create(buf, m.HashSize, m.HashRowWidth, 7),
                   TCycledMF.Create(buf, m.AuxHashSize, m.AuxHashRowWidth, 4)), 16, 12, True, buf));
    9: Result := TCombineMF.Create(TCachingMF.Create(buf, m.HashSize, m.HashRowWidth, 5),
                   THash3MF.Create(TExactMF.Create(buf, m.AuxHashSize, m.AuxHashRowWidth, 4), 14, 10, False, buf));
    10, 11: Result := TCombineMF.Create(TCachingMF.Create(buf, m.HashSize, m.HashRowWidth, 6),
                   THash3MF.Create(TMFN.Create(buf, m.AuxHashSize, m.AuxHashRowWidth, 4), 16, 12, True, buf));
  else
    Result := TCombineMF.Create(TBTMF.Create(buf, m.Buffer, m.HashSize, m.HashRowWidth, 5, AllocEnd),
                   THash3MF.Create(TExactMF.Create(buf, m.AuxHashSize, m.AuxHashRowWidth, 4), 16, 12, True, buf));
  end;
end;

constructor TTorEngine.Create(const AM: TTorMethod; ACombo: Integer; AAllAtOnce: Boolean; OutCap: SizeInt);
var
  i, j: Integer;
begin
  inherited Create;
  M := AM;
  Combo := ACombo;
  Optimal := Combo >= 9;
  AllAtOnce := AAllAtOnce;
  AdjustMethod(M, Optimal);
  // BigAlloc(m.buffer+LOOKAHEAD) en cero, más un margen propio
  BufAlloc := SizeInt(M.Buffer) + LOOKAHEAD + PAD_AFTER;
  Mem := GetMem(BufAlloc);
  if Mem = nil then OutOfMemoryError;
  FillChar(Mem^, BufAlloc, 0);
  Buf := Mem;
  if AllAtOnce then Chunk := M.Buffer
  else if M.Shift > 0 then Chunk := MinI(M.Shift, LARGE_BUFFER_SIZE)
  else Chunk := MinI(M.Buffer, LARGE_BUFFER_SIZE);
  C := TTorCoder.Create(CoderKind(Combo, M.EncodingMethod), OutCap);
  C.CanFlush := not AllAtOnce;
  if Optimal then C.SupportTables := False;   // OptimalParser::support_tables = FALSE
  UseTables := C.SupportTables and M.FindTables;
  for i := 0 to MAX_TABLE_ROW - 1 do
    for j := 0 to MAX_TABLE_ROW - 1 do LastChecked[i, j] := Buf;
  if Optimal then
  begin
    SetLength(X, OPTIMAL_WINDOW + 2);
    SetLength(Prices, OPTIMAL_WINDOW + 1);
    SetLength(Stack, OPTIMAL_WINDOW * 2);
    SetLength(Matches, MAX_MATCHES * 2 + 16);
  end;
  // Todo lo grande se reserva acá (antes de adoptar el destino). El C construye el MF
  // después de la primera lectura; el estado es el mismo salvo las claves de
  // CachingMatchFinder::clear_hash (key(buf+1)), que Start recalcula.
  MF := BuildMF(M, Combo, Buf, Mem + BufAlloc);
  State := esFirst;
  ReadDst := Buf;
  ReadWant := Chunk;
  ReadGot := 0;
end;

destructor TTorEngine.Destroy;
begin
  MF.Free;
  C.Free;
  FreeMem(Mem);
  inherited Destroy;
end;

procedure TTorEngine.Resume;
begin
  case State of
    esFirst: Start;
    esRead:
      if Optimal then RunOptimal(True) else Run(True);
  end;
end;

procedure TTorEngine.Start;
label
  finished;
begin
  Bytes := ReadGot;
  BufEnd := Buf + Bytes;
  MatchEnd := BufEnd - MinI(MAX_HASHED_BYTES, Bytes);
  if AllAtOnce then ReadPoint := BufEnd else ReadPoint := BufEnd - MinI(LOOKAHEAD, Bytes);
  if Combo in [4, 5, 6, 9, 10, 11] then MF.ClearHash(Buf);   // CachingMatchFinder: key(buf+1)
  if UseTables then TableEnd := Buf else TableEnd := Buf + M.Buffer + LOOKAHEAD;
  LastFound := Buf;
  // Cabecera: encoding_method, minlen, buffer
  C.Put8(M.EncodingMethod);
  C.Put8(MF.MinLen);
  C.Put32(M.Buffer);
  // Los primeros 4 bytes van como literales
  P := Buf;
  while P < Buf + 4 do
  begin
    if P >= BufEnd then goto finished;
    C.Encode(0, P, P - Buf, MF.MinLen);
    Inc(P);
  end;
  if Optimal then
  begin
    StartBlock(P);
    Silence := Buf;
    RunOptimal(False);
  end
  else
    Run(False);
  Exit;
finished:
  FinishStream;
end;

{ Primera mitad de read_next_chunk: deslizar la ventana y pedir datos. False = terminar. }
function TTorEngine.ReadPart1: Boolean;
var
  sh: SizeInt;
  i, j: Integer;
begin
  if (Bytes = 0) or AllAtOnce then Exit(False);
  if BufEnd - Buf > SizeInt(M.Buffer) - LOOKAHEAD then
  begin
    if Optimal then EncodeBlock(P);      // coder.before_shift
    if M.Shift = -1 then
    begin
      sh := P - (Buf + 2);
      Move((Buf + sh)^, Buf^, BufEnd - (Buf + sh));
      MF.ClearHash(Buf);
    end
    else
    begin
      sh := M.Shift;
      Move((Buf + sh)^, Buf^, BufEnd - (Buf + sh));
      MF.ShiftHash(Buf, sh);
    end;
    Dec(P, sh);
    Dec(BufEnd, sh);
    if UseTables then
    begin
      if TableEnd > Buf + sh then Dec(TableEnd, sh) else TableEnd := Buf;
      if LastFound > Buf + sh then Dec(LastFound, sh) else LastFound := Buf;
      for i := 0 to MAX_TABLE_ROW - 1 do
        for j := 0 to MAX_TABLE_ROW - 1 do LastChecked[i, j] := Buf;
    end;
    MF.InvalidateMatch;
    C.AfterShift;
    if Optimal then StartBlock(P);       // coder.after_shift
  end;
  ReadDst := BufEnd;
  ReadWant := MinI(Chunk, (Buf + M.Buffer) - BufEnd);
  ReadGot := 0;
  State := esRead;
  Result := True;
end;

{ Segunda mitad de read_next_chunk (y el recálculo de matchend del llamador). }
procedure TTorEngine.ReadPart2;
begin
  Bytes := ReadGot;
  Inc(BufEnd, Bytes);
  if Bytes = 0 then ReadPoint := BufEnd else ReadPoint := BufEnd - LOOKAHEAD;
  C.Flush;
  MatchEnd := BufEnd - MinI(MAX_HASHED_BYTES, BufEnd - Buf);
end;

procedure TTorEngine.FinishStream;
begin
  C.EnsureOut(64);
  C.Encode(IMPOSSIBLE_LEN, Buf, IMPOSSIBLE_DIST, MF.MinLen);
  C.Finish;
  State := esDone;
end;

{ DataTables.cpp: diff_table para N=2 y N=4 (los únicos que genera el compresor) }
procedure DiffTable(N: Integer; Start: PByte; Len: Integer);
var
  r, e: PByte;
  prev16, v16: Word;
  prev32, v32_: LongWord;
begin
  r := Start;
  e := Start + N * Len;
  if N = 2 then
  begin
    prev16 := PWord(r)^;
    while True do
    begin
      Inc(r, 2);
      if not (r < e) then Break;
      v16 := PWord(r)^;
      PWord(r)^ := Word(v16 - prev16);
      prev16 := v16;
    end;
  end
  else
  begin
    prev32 := PLongWord(r)^;
    while True do
    begin
      Inc(r, 4);
      if not (r < e) then Break;
      v32_ := PLongWord(r)^;
      PLongWord(r)^ := v32_ - prev32;
      prev32 := v32_;
    end;
  end;
end;

{ check_for_data_table (DataTables.cpp:84) }
function TTorEngine.CheckForDataTable(N: Integer; out Typ, Items: Integer): Boolean;
var
  last: ^PByte;
  t, lastpoint: PByte;
  lensum, len, dir, lenminus, diff: Integer;
  itemlb, difflb: LongWord;
begin
  Result := False;
  last := @LastChecked[N, (P - Buf) mod N];
  if last^ > P then Exit;
  t := P - 2;
  lensum := 600; len := 0; lenminus := 0;
  if V16s(t + N) - V16s(t) < 0 then dir := -1 else dir := 1;
  t := t + N;
  lastpoint := t;
  while t + 2 <= BufEnd do
  begin
    diff := V16s(t) - V16s(t - N);
    itemlb := lb(1 + Abs(V16s(t)));
    difflb := lb(1 + Abs(diff));
    if itemlb > 10 then Dec(itemlb);
    if (dir < 0) and (diff < 0) and (difflb < itemlb) then Inc(len)
    else if (dir > 0) and (diff > 0) and (difflb < itemlb) then Inc(len)
    else if diff = 0 then Inc(lenminus)
    else
    begin
      if len > 3 then lastpoint := t;
      lensum := lensum - lensum div 8;
      lensum := lensum + MinI(len, 10) * 30;
      if diff < 0 then dir := -1 else dir := 1;
      len := 0;
      if lensum < 500 then Break;
    end;
    t := t + N;
  end;
  last^ := t;
  if (t - P > N * (40 + lenminus)) and (lastpoint - P > MaxI(N, 20)) then
  begin
    Typ := N;
    Items := (lastpoint - P) div Typ;
    DiffTable(Typ, P, Items);
    TableEnd := P + Typ * Items;
    Result := True;
  end;
end;

{ CHECK_FOR_DATA_TABLE(N) (Tornado.cpp:111). True = tabla encontrada y codificada. }
function TTorEngine.CheckTable(N: Integer): Boolean;
var
  Typ, Items: Integer;
begin
  Result := False;
  if (P[-1] = P[N - 1]) and
     (LongWord(Integer(P[N - 1]) - Integer(P[2 * N - 1]) + 4) <= 2 * 4) and
     (LongWord(Integer(P[2 * N - 1]) - Integer(P[3 * N - 1]) + 4) <= 2 * 4) and
     (V32(P + 2 * N - 4) <> V32(P + N - 4)) then
    if CheckForDataTable(N, Typ, Items) then
    begin
      C.EncodeTable(Typ, Items);
      MF.InvalidateMatch;     // el diff cambió los datos: invalidar el match del lazy MF
      Result := True;
    end;
end;

{ Lazo principal de tor_compress_chunk (greedy y lazy) }
procedure TTorEngine.Run(Resuming: Boolean);
label
  finished;
var
  len: LongWord;
  q: PByte;
  SkipRead, found: Boolean;
  Tick: LongWord;
begin
  Tick := 0;
  SkipRead := False;
  if Resuming then
  begin
    ReadPart2;
    if not (P < BufEnd) then goto finished;
    SkipRead := True;      // tras leer, el C codifica al menos un elemento antes de volver a mirar
  end;
  while True do
  begin
    if not SkipRead and (P >= ReadPoint) then
    begin
      if not ReadPart1 then goto finished;
      Exit;   // esperar datos
    end;
    SkipRead := False;
    // Cancelación: un bloque de 4x4:tor (en un hilo del pool) son segundos sin volver
    Inc(Tick);
    if Tick and $FFFF = 0 then CheckCancel;
    if C.O + 4096 > Length(C.Out) then C.Grow(4096);
    // Tablas que conviene restar
    if UseTables and (P > TableEnd) then
    begin
      found := False;
      if MF.MinLen < 4 then found := CheckTable(2);
      if not found then found := CheckTable(4);
      if found then LastFound := TableEnd
      else if P - LastFound > TABLE_DIST then TableEnd := P + TABLE_SHIFT;
    end;
    len := MF.FindMatchLen(P, MatchEnd, 0);
    q := MF.MatchPtr;
    if not C.Encode(LongInt(len), P, LongWord(P - q), MF.MinLen) then
      Inc(P)
    else
    begin
      MF.UpdateHash(P, len, M.UpdateStep);
      Inc(P, len);
    end;
  end;
finished:
  FinishStream;
end;

{ OptimalParser (OptimalParsing.cpp) }

procedure TTorEngine.StartBlock(ABaseP: PByte);
var
  i: Integer;
begin
  BaseP := ABaseP;
  EndBuf := Buf + M.Buffer;
  LastP := BaseP + MinI(EndBuf - BaseP, OPTIMAL_WINDOW);
  Prices[0] := 0;
  for i := 1 to OPTIMAL_WINDOW do Prices[i] := MAX_PRICE;
  for i := 0 to REPDIST_CODES - 1 do X[0].prevdist[i] := High(LongWord);
end;

procedure TTorEngine.EncodeBlock(EndP: PByte);
var
  sp, i: SizeInt;
  pp: PByte;
  len: LongInt;
  dist: LongWord;
begin
  if EndP = BaseP then Exit;
  sp := 0;
  i := EndP - BaseP;
  while i > 0 do
  begin
    Stack[sp] := X[i].dist; Inc(sp);
    Stack[sp] := LongWord(X[i].len); Inc(sp);
    Dec(i, X[i].len);
  end;
  pp := BaseP;
  while sp > 0 do
  begin
    Dec(sp); len := LongInt(Stack[sp]);
    Dec(sp); dist := Stack[sp];
    if C.O + 4096 > Length(C.Out) then C.Grow(4096);
    C.Encode(len, pp, dist, OPT_MIN_LEN);
    Inc(pp, len);
  end;
end;

procedure TTorEngine.Evaluate(pp: PByte; len: LongInt; dist: LongWord; NewPrice: LongWord);
var
  dst: SizeInt;
begin
  dst := (pp - BaseP) + len;
  if Prices[dst] > NewPrice then
  begin
    Prices[dst] := NewPrice;
    X[dst].len := len;
    X[dst].dist := dist;
  end;
end;

{ evaluate_literal_and_repdist }
function TTorEngine.EvalLitRep(pp: PByte): LongInt;
var
  len, j: LongInt;
  src, dst: SizeInt;
  price, dist, match_len: LongWord;
  pd: PLongWord;
  i: Integer;
begin
  len := OPT_MIN_LEN;
  src := pp - BaseP;
  price := Prices[src];
  Evaluate(pp, 1, 0, price + C.LitPrice(pp^));
  if not C.SupportRepdist or (src = 0) then Exit(len);
  dist := X[src].dist;
  if dist = 0 then
  begin
    pd := @X[src - 1].prevdist[0];
    dist := pd^; Inc(pd);
  end
  else
  begin
    dst := src - X[src].len;
    pd := @X[dst].prevdist[0];
  end;
  for i := 0 to REPDIST_CODES - 1 do
  begin
    X[src].prevdist[i] := dist;
    if Int64(dist) > (pp - Buf) then Break;
    if pp[len - 1] = (pp - dist)[len - 1] then
    begin
      match_len := CheckMatchLen(pp, pp - dist, LongWord(LastP - pp));
      while LongWord(len) <= match_len do
      begin
        Evaluate(pp, len, dist, price + C.RepdistPrice(len - OPT_MIN_LEN, i));
        Inc(len);
      end;
      if len > M.FastBytes then
      begin
        for j := i + 1 to REPDIST_CODES - 1 do
        begin
          X[src].prevdist[j] := pd^; Inc(pd);
        end;
        Break;
      end;
    end;
    dist := pd^; Inc(pd);
  end;
  Result := len;
end;

function TTorEngine.EvalMatches(pp: PByte; len: LongInt; mm, me: PLongWord): LongInt;
var
  price, dist: LongWord;
  match_len, lim: Int64;
begin
  if mm < me then
  begin
    price := Prices[pp - BaseP];
    repeat
      match_len := LongInt(mm^); Inc(mm);
      dist := mm^; Inc(mm);
      lim := MinI(match_len, LastP - pp);
      while len <= lim do
      begin
        Evaluate(pp, len, dist, price + C.MatchPrice(len - OPT_MIN_LEN, dist));
        Inc(len);
      end;
    until not (mm < me);
  end;
  Result := len;
end;

{ Lazo principal de tor_compress_chunk_optimal }
procedure TTorEngine.RunOptimal(Resuming: Boolean);
label
  finished, blockend;
var
  len: LongInt;
  me: PLongWord;
  SkipRead: Boolean;
begin
  SkipRead := False;
  if Resuming then
  begin
    ReadPart2;
    if not (P < BufEnd) then goto blockend;    // res==0 -> break
    Silence := Buf;
    SkipRead := True;
  end;
  while True do
  begin
    if not SkipRead and (P >= ReadPoint) then
    begin
      if not ReadPart1 then goto blockend;
      Exit;
    end;
    SkipRead := False;
    if P >= LastP then
    begin
      CheckCancel;
      EncodeBlock(P);
      Silence := Buf;
      StartBlock(P);
    end;
    if P >= Silence then
    begin
      len := EvalLitRep(P);
      if len <= M.FastBytes then
      begin
        me := MF.FindAllMatches(P, MatchEnd, @Matches[0]);
        len := EvalMatches(P, len, @Matches[0], me);
      end;
      if len > M.FastBytes then Silence := P + len - 1;
    end;
    Inc(P);
  end;
blockend:
  EncodeBlock(P);
finished:
  FinishStream;
end;

{ ---------------------------------------------------------------------------------------- }
{ Parámetros                                                                                }
{ ---------------------------------------------------------------------------------------- }

{ parseInt (Common.cpp:221): '=' opcional y solo dígitos }
function CParseInt(const S: string; out V: Int64): Boolean;
var
  i: Integer;
begin
  V := 0;
  i := 1;
  if (i <= Length(S)) and (S[i] = '=') then Inc(i);
  if i > Length(S) then Exit(False);
  while (i <= Length(S)) and (S[i] in ['0'..'9']) do
  begin
    V := V * 10 + Ord(S[i]) - Ord('0');
    if V > High(LongInt) then Exit(False);
    Inc(i);
  end;
  Result := i > Length(S);
end;

function CParseMem(const S: string; out V: Int64): Boolean;
var
  q: QWord;
begin
  Result := ParseMem(S, q) and (q <= High(LongWord));
  if Result then V := q else V := 0;
end;

{ Tabla de la memoria necesaria de cada MF: el C sin validar tiene UB (lb(0), shift de 32,
  división por cero, lazo infinito); acá esos casos se rechazan. }
function CheckBase(AHashSize: LongWord; row: Integer; const What: string; AllowZeroRow: Boolean = False): string;
var
  hs: QWord;
begin
  Result := '';
  if (row < 0) or (row = 0) and not AllowZeroRow then Exit(What + ': largo de fila < 1');
  if AHashSize < 8 then Exit(What + ': hash demasiado chico');
  hs := (QWord(1) shl lb(AHashSize)) div 4;
  if hs < RoundupPow2(row) then Exit(What + ': la fila no entra en el hash');
end;

function CheckCaching(AHashSize: LongWord; row: Integer; const What: string): string;
var
  r: Integer;
begin
  Result := '';
  if row < 1 then Exit(What + ': largo de fila < 1');
  r := row;
  if (AHashSize = 2 * LongWord(gb)) and (r = (1 shl lb(r))) then Dec(r);
  if AHashSize div LongWord(8 * r) < 2 then Exit(What + ': hash demasiado chico para esa fila');
end;

function ValidateMethod(const m0: TTorMethod; out Combo: Integer): string;
var
  m: TTorMethod;
begin
  Result := '';
  Combo := SelectCombo(m0);
  if Combo = 0 then Exit('combinación de parámetros que FreeArc no compila (FREEARC_ERRCODE_INVALID_COMPRESSOR)');
  if (m0.EncodingMethod < 1) or (m0.EncodingMethod > 4) then
    Exit('codificador c' + IntToStr(m0.EncodingMethod) + ' no válido (c0 genera un stream que el C no descomprime)');
  if m0.Buffer > gb then Exit('buffer > 1gb (el DistanceCoder del C no cubre distancias mayores)');
  m := m0;
  AdjustMethod(m, Combo >= 9);
  case Combo of
    1, 2, 3: Result := CheckBase(m.HashSize, m.HashRowWidth, 'h/l');
    4, 5, 6, 9, 10, 11: Result := CheckCaching(m.HashSize, m.HashRowWidth, 'h/l');
    // CycledCachingMatchFinder con l>256: Head[] es de bytes y el C trunca el índice de la
    // cabeza (sin FULL_COMPILE no lo rechaza); acá se trunca igual (TCycledMF.FindMatchLen)
    7, 8: Result := CheckCaching(m.HashSize, m.HashRowWidth, 'h/l');
    12:
      begin
        if m.HashRowWidth < 0 then Exit('l<0');
        Result := CheckBase(m.HashSize, 1, 'h');
      end;
  end;
  if Result <> '' then Exit;
  case Combo of
    // ExactMatchFinder/MatchFinderN aceptan fila 0 (nunca encuentran nada, pero no rompen)
    7, 9, 10, 11, 12: Result := CheckBase(m.AuxHashSize, m.AuxHashRowWidth, 'ah/al', True);
    8: Result := CheckCaching(m.AuxHashSize, m.AuxHashRowWidth, 'ah/al');
  end;
  if Result <> '' then Exit;
  // update_step=0: lazo infinito en update_hash del C (solo en los MF que lo usan)
  if (Combo in [4, 5, 6, 7]) and (m.UpdateStep < 1) then Exit('u0 cuelga al compresor del C');
  // find_all_matches no puede pasarse de MAX_MATCHES pares
  if (Combo >= 9) and (Int64(m.HashRowWidth) + m.AuxHashRowWidth + 16 > MAX_MATCHES) then
    Exit('l+al demasiado grande para el parser óptimo');
end;

function ParseTorEncParams(const Params: TStringArray; out M: TTorMethod): string;
var
  k: Integer;
  p: string;
  v: Int64;
  ok: Boolean;
  Combo: Integer;
begin
  M := StdMethods[DEFAULT_METHOD];
  if (Length(Params) = 0) or (Params[0] <> 'tor') then Exit('no es el método tor');
  for k := 1 to High(Params) do
  begin
    p := Params[k];
    ok := True;
    if p <> '' then
      case p[1] of
        'b': begin ok := CParseMem(Copy(p, 2, MaxInt), v); M.Buffer := v; end;
        'h': begin ok := CParseMem(Copy(p, 2, MaxInt), v); M.HashSize := v; end;
        'l': begin ok := CParseInt(Copy(p, 2, MaxInt), v); M.HashRowWidth := v; end;
        'c': begin ok := CParseInt(Copy(p, 2, MaxInt), v); M.EncodingMethod := v; end;
        'p': begin ok := CParseInt(Copy(p, 2, MaxInt), v); M.MatchParser := v; end;
        'x': begin ok := CParseInt(Copy(p, 2, MaxInt), v); M.MatchFinder := v; end;
        's': begin ok := CParseInt(Copy(p, 2, MaxInt), v); M.Hash3 := v; end;
        'u': begin ok := CParseInt(Copy(p, 2, MaxInt), v); M.UpdateStep := v; end;
        't': begin ok := CParseInt(Copy(p, 2, MaxInt), v); M.FindTables := v <> 0; end;
      else
        if (Length(p) >= 2) and (p[1] = 'a') and (p[2] = 'h') then
          begin ok := CParseMem(Copy(p, 3, MaxInt), v); M.AuxHashSize := v; end
        else if (Length(p) >= 2) and (p[1] = 'a') and (p[2] = 'l') then
          begin ok := CParseInt(Copy(p, 3, MaxInt), v); M.AuxHashRowWidth := v; end
        else if (Length(p) >= 2) and (p[1] = 'f') and (p[2] = 'b') then
          begin ok := CParseInt(Copy(p, 3, MaxInt), v); M.FastBytes := v; end
        else if CParseInt(p, v) and (v <= High(StdMethods)) then
          M := StdMethods[v]                          // número de preset
        else
          begin ok := CParseMem(p, v); M.Buffer := v; end;   // si no, el buffer
      end
    else
      ok := False;
    if not ok then Exit('parámetro inválido "' + p + '"');
  end;
  Result := ValidateMethod(M, Combo);
end;

function TorEncAvailable(const Stage: string): Boolean;
var
  M: TTorMethod;
begin
  Result := ParseTorEncParams(Stage.Split([':']), M) = '';
end;

function TorDictionary(const Params: TStringArray): Int64;
var
  M: TTorMethod;
begin
  if ParseTorEncParams(Params, M) <> '' then Exit(-1);
  Result := M.Buffer;
end;

function CreateEngine(const Params: TStringArray; AllAtOnce: Boolean; OutCap: SizeInt): TTorEngine;
var
  M: TTorMethod;
  Err: string;
  Combo: Integer;
begin
  Err := ParseTorEncParams(Params, M);
  if Err <> '' then raise ETorEncoder.Create('tor: ' + Err);
  ValidateMethod(M, Combo);
  Result := TTorEngine.Create(M, Combo, AllAtOnce, OutCap);
end;

{ ---------------------------------------------------------------------------------------- }
{ TTorEncStage                                                                              }
{ ---------------------------------------------------------------------------------------- }

constructor TTorEncStage.Create(ATarget: TOutStage; const Params: TStringArray);
var
  E: TTorEngine;
begin
  // Validar y reservar antes de adoptar el destino
  E := CreateEngine(Params, False, 1 * mb);
  inherited Create(ATarget);
  FEngine := E;
  E.C.OnEmit := @EmitOut;
end;

destructor TTorEncStage.Destroy;
begin
  FEngine.Free;
  inherited Destroy;
end;

procedure TTorEncStage.EmitOut(P: PByte; N: SizeInt);
begin
  Emit(P, N);
end;

procedure TTorEncStage.DoWrite(Buf: PByte; Count: SizeInt);
var
  E: TTorEngine;
  n: SizeInt;
begin
  E := TTorEngine(FEngine);
  while Count > 0 do
  begin
    if E.State = esDone then raise ETorEncoder.Create('tor: datos después del final');
    if E.ReadGot = E.ReadWant then begin E.Resume; Continue; end;
    n := E.ReadWant - E.ReadGot;
    if n > Count then n := Count;
    Move(Buf^, (E.ReadDst + E.ReadGot)^, n);
    Inc(E.ReadGot, n);
    Inc(Buf, n);
    Dec(Count, n);
    // Las lecturas de FreeArc son completas: el C sigue solo cuando el pedido se llenó
    if E.ReadGot = E.ReadWant then E.Resume;
  end;
end;

procedure TTorEncStage.DoFinish;
var
  E: TTorEngine;
begin
  E := TTorEngine(FEngine);
  // Fin de los datos: la lectura pendiente vuelve corta y las siguientes con 0
  while E.State <> esDone do E.Resume;
end;

{ ---------------------------------------------------------------------------------------- }

function TorEncodeMem(const Params: TStringArray; Src: PByte; SrcLen: SizeInt; DstCap: SizeInt;
  out Dst: TBytes): Boolean;
var
  E: TTorEngine;
begin
  Dst := nil;
  E := CreateEngine(Params, True, SrcLen + SrcLen div 4 + 4096);
  try
    if SrcLen > SizeInt(E.M.Buffer) then
      raise ETorEncoder.CreateFmt('tor: bloque de %d bytes mayor que el buffer (%d)', [SrcLen, E.M.Buffer]);
    if SrcLen > 0 then Move(Src^, E.Buf^, SrcLen);
    E.ReadGot := SrcLen;
    E.Resume;
    if E.State <> esDone then raise ETorEncoder.Create('tor: estado interno inesperado');
    Result := E.C.O <= DstCap;
    if Result then Dst := Copy(E.C.Out, 0, E.C.O);
  finally
    E.Free;
  end;
end;

{ ---------------------------------------------------------------------------------------- }

{ VLE::VLE }
procedure InitVle(var V: TVle; const Extra: array of LongWord);
var
  value, code, n: LongWord;
begin
  FillChar(V, SizeOf(V), 0);
  value := 0;
  for code := 0 to High(Extra) do
  begin
    V.Extra[code] := Extra[code];
    V.Base[code] := value;
    n := 0;
    while n < (QWord(1) shl Extra[code]) do
    begin
      if value >= VLE_SIZE then Break;
      V.Code[value] := code;
      Inc(value);
      Inc(n);
    end;
  end;
end;

{ DistanceCoder::DistanceCoder }
procedure InitDc;
var
  dist, code, n: LongWord;
begin
  FillChar(Dc, SizeOf(Dc), 0);
  dist := 0; code := 0;
  while dist < 512 do
  begin
    Dc.Extra[code] := ExtraDBits[code];
    Dc.Base[code] := dist;
    for n := 1 to LongWord(1) shl ExtraDBits[code] do
    begin
      Dc.Code[dist] := code;
      Inc(dist);
    end;
    Inc(code);
  end;
  dist := dist shr 8;
  while dist < 512 do
  begin
    Dc.Extra[code] := ExtraDBits[code];
    Dc.Base[code] := dist shl 8;
    for n := 1 to LongWord(1) shl (ExtraDBits[code] - 8) do
    begin
      Dc.Code[512 + dist] := code;
      Inc(dist);
    end;
    Inc(code);
  end;
  dist := dist shr 8;
  while code < 32 do
  begin
    Dc.Extra[code] := ExtraDBits[code];
    Dc.Base[code] := dist shl 16;
    n := 0;
    while n < (LongWord(1) shl (ExtraDBits[code] - 16)) do
    begin
      if 1024 + dist >= VLE_SIZE then Break;
      Dc.Code[1024 + dist] := code;
      Inc(dist);
      Inc(n);
    end;
    Inc(code);
  end;
end;

{ PRICE_SCALE(log2(RANGE/cnt)) = round(log2(16384/cnt)*1024). Nunca cae en .5 exacto
  (2^(impar/2048) es irracional), así que el redondeo no depende de la libm. }
procedure InitPrices;
var
  c: Integer;
begin
  PriceTab[0] := 0;
  for c := 1 to RANGE_ do
    PriceTab[c] := Trunc(Ln(RANGE_ / c) / Ln(2.0) * 1024 + 0.5);
end;

initialization
  InitVle(Lc, ExtraLBits);
  InitVle(Lc2, ExtraLBits2);
  InitDc;
  InitPrices;
end.
