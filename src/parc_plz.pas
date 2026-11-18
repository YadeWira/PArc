{ PLZ (método `plz`): códec LZ77 propio de PArc (reemplaza a Tornado). Este archivo tiene el
  formato, lo que comparten codificador y decodificador (códigos de valores, Huffman canónico,
  descripción de tablas) y el decodificador (etapa de streaming y memoria a memoria para 4x4).
  Código propio, escrito a partir de la literatura pública (LZ77, códigos de Huffman canónicos
  limitados en largo, offsets repetidos, literales en 4 streams); no deriva de Tornado.

  Stream:
    U8  versión (= 1)
    U32 LE ventana W (1 KB .. 1 GB): ningún match llega más atrás que W bytes
    bloques, cada uno con un byte de tipo:
      0  fin del stream
      1  guardado:   VInt n (1..PLZ_MAXBLOCK), n bytes
      2  repetido:   VInt n (1..PLZ_MAXBLOCK), 1 byte (se repite n veces)
      3  comprimido: VInt n (1..PLZ_MAXBLOCK), VInt c (largo del contenido), c bytes
    (VInt: LEB128, 7 bits por byte, el bit 7 sigue; a lo sumo 5 bytes.)

  Bloque comprimido:
    VInt nSeq, VInt nLit (literales del bloque; nLit <= n)
    U8 modos: bits 0-1 literales, 2-3 token, 4-5 LLX, 6-7 MLX;  U8: bits 0-1 OFS, el resto 0
      tabla:     0 = nueva (su descripción va en el stream de tablas), 1 = la del bloque anterior,
                 2 = sin uso en el bloque
      literales: 0 = Huffman con tabla nueva, 1 = Huffman con la anterior, 2 = no hay (nLit = 0),
                 3 = guardados (nLit bytes)
    stream de tablas (bits, si alguna tabla es nueva; termina en el byte siguiente)
    literales: Huffman: con nLit >= 1024, 4 streams: VInt largo de cada uno, y los streams; si
      no, 1 stream: VInt largo y el stream. El stream k (0..3) tiene los literales
      [k*q, min((k+1)*q, nLit)) con q = ceil(nLit/4).
    secuencias: el resto del bloque es su stream de bits.

  Cada secuencia: token (alfabeto de 128: LLt*16 + MLt), código OFS, si LLt = 7 un código LLX
  (largo de literales - 7), si MLt = 15 un código MLX (largo de match - 3 - 15); después los
  bits extra de LLX, MLX y OFS en ese orden. Largo de literales LL = LLt (< 7) o 7 + valor;
  largo del match ML = 3 + MLt (< 15) o 18 + valor. Se copian LL literales y después el match.
  Tras nSeq secuencias, los literales que quedan van al final del bloque, que tiene que medir n.

  Valores (LLX, MLX): v < 8 es el código v; si no, b = bsr(v), código 8 + 2(b-3) + bit b-1 de
  v, y b-1 bits extra (v sin sus dos bits altos). Alfabeto de 48.
  OFS: 0..3 = offsets repetidos rep0..rep3 (el usado pasa adelante); 4 + slot = offset nuevo
  d+1, con slot = d (d < 4) o 2b + bit b-1 de d (b = bsr(d)) y b-1 bits extra. Alfabeto de 64.
  Los reps arrancan en 1, 2, 3, 4 y siguen de bloque en bloque (sólo los reinicia el stream).

  Bits: LSB primero; los códigos de Huffman van invertidos (el primer bit del código es el bit
  más bajo). Largos 1..11 (canónicos: por largo y, a igual largo, por símbolo); una tabla con un
  solo símbolo lo codifica con 0 bits. Una tabla tiene que ser completa (Kraft = 1).
  Descripción de una tabla: 8 bits (cantidad de símbolos descriptos - 1), 15 x 3 bits largos de los códigos CL (alfabeto CL: 0..11 = largo,
  12 = repetir el anterior 3..6 veces (2 bits), 13 = ceros 3..10 (3 bits), 14 = ceros 11..138
  (7 bits)), y los símbolos CL con su Huffman (largo <= 7).

  El decodificador acota todo: un stream dañado da EArcCorrupt, nunca lee ni escribe fuera de
  sus búferes y nunca queda en un lazo sin fin. }
unit parc_plz;

{$mode objfpc}{$H+}
{$modeswitch advancedrecords}
{$R-}{$Q-}
{$inline on}
{$pointermath on}

interface

uses
  SysUtils, parc_bytes, parc_stream;

const
  PLZ_VERSION = 1;
  PLZ_MAXBLOCK = 1 shl 20;          // bytes originales de un bloque, como máximo
  PLZ_MINWINDOW = 1 shl 10;
  PLZ_MAXWINDOW = 1 shl 30;
  PLZ_MINMATCH = 3;
  PLZ_MAXCODELEN = 11;
  PLZ_TABLEBITS = 11;
  PLZ_TABLESIZE = 1 shl PLZ_TABLEBITS;

  PLZ_NLIT = 256;
  PLZ_NTOK = 128;
  PLZ_NLEN = 48;
  PLZ_NOFS = 64;

  { Índices de las tablas }
  PT_LIT = 0; PT_TOK = 1; PT_LLX = 2; PT_MLX = 3; PT_OFS = 4;
  PLZ_ALPHA: array[0..4] of Integer = (PLZ_NLIT, PLZ_NTOK, PLZ_NLEN, PLZ_NLEN, PLZ_NOFS);

  { Tipos de bloque }
  PB_END = 0; PB_RAW = 1; PB_RLE = 2; PB_COMP = 3;

  { Modos de tabla }
  PM_NEW = 0; PM_REUSE = 1; PM_NONE = 2; PM_RAW = 3;

  PLZ_LIT4 = 1024;      // desde cuántos literales van en 4 streams
  PLZ_PAD = 32;         // bytes de relleno detrás de los búferes de bits y de literales

  { Alfabeto de los largos de código (CL) }
  CL_N = 15;
  CL_MAXLEN = 7;

type
  TPlzLens = array[0..255] of Byte;
  THufDec = array[0..PLZ_TABLESIZE - 1] of Word;   // símbolo shl 4 or largo
  PHufDec = ^THufDec;

  { Lector de bits LSB primero sobre un búfer con PLZ_PAD bytes de relleno detrás de PEnd. }
  TPlzBitReader = record
    P, PStart, PEnd: PByte;
    Bits: QWord;
    Used: LongWord;        // bits ya consumidos de Bits (0..63) desde P
    Over: Boolean;         // se intentó leer pasado PEnd
    procedure Init(Src: PByte; Len: SizeInt);
    procedure Refill; inline;
    function Peek: LongWord; inline;
    procedure Skip(N: LongWord); inline;
    function Get(N: LongWord): LongWord; inline;   // N <= 32 (después de Refill, N <= 56 en total)
    { Bytes consumidos (redondeado arriba) }
    function Consumed: SizeInt;
  end;

  { Decodificador de bloques: estado que pasa de un bloque al siguiente (reps y tablas). }
  TPlzDecoder = class
  private
    FRep: array[0..3] of SizeUInt;
    FTab: array[0..4] of THufDec;
    FHave: array[0..4] of Boolean;
    FLit: array of Byte;
    FScratch: array of Byte;
    procedure ReadTables(var BR: TPlzBitReader; const Modes: array of Integer);
    procedure DecodeLiterals(Src: PByte; SrcLen: SizeInt; nLit: SizeInt; Tab: PHufDec);
  public
    Window: SizeUInt;
    constructor Create(AWindow: SizeUInt);
    { Decodifica el contenido de un bloque comprimido (Payload[0..PayLen)) en Dst[0..RawLen).
      Base = comienzo de la historia contigua (Dst - Base bytes antes de Dst son válidos);
      Tail/TailLen = la historia más vieja en otro tramo (ring), que termina en Tail+TailLen y
      va justo antes de Base; AbsPos = posición absoluta de Dst en el stream. }
    procedure DecodeBlock(Payload: PByte; PayLen: SizeInt; Dst: PByte; RawLen: SizeInt;
      Base: PByte; Tail: PByte; TailLen: SizeInt; AbsPos: Int64);
    function Scratch(Len: SizeInt): PByte;
  end;

  { Etapa de descompresión (streaming). }
  TPlzStage = class(TInStage)
  private
    FDec: TPlzDecoder;
    FRing: array of Byte;
    FRingCap: SizeInt;          // capacidad útil (sin el relleno)
    FRingMax: SizeInt;          // capacidad final: W + PLZ_MAXBLOCK
    FW: SizeInt;                // índice de escritura en el ring
    FTailEnd: SizeInt;          // fin de la historia vieja tras dar la vuelta (0 = no hay)
    FPos, FEnd: SizeInt;        // bytes por entregar: FRing[FPos..FEnd)
    FAbs: Int64;
    FStarted, FEof: Boolean;
    procedure Start;
    function NextBlock: Boolean;
  public
    destructor Destroy; override;
    function Read(Buf: PByte; Count: SizeInt): SizeInt; override;
  end;

{ Memoria a memoria (dentro de 4x4): Src es un stream entero que tiene que dar exactamente
  DstLen bytes y terminar justo en SrcLen. False si está dañado. }
function PlzDecodeMem(Src: PByte; SrcLen: SizeInt; Dst: PByte; DstLen: SizeInt): Boolean;

{ ---- compartido con el codificador ---- }

{ Código de un valor de LLX/MLX: devuelve el código y deja en NB los bits extra y en Extra su
  valor. }
function PlzLenCode(V: LongWord; out NB: LongWord; out Extra: LongWord): LongWord; inline;
{ Código OFS (sin los 4 reps) de la distancia D = offset - 1. }
function PlzOfsSlot(D: LongWord; out NB: LongWord; out Extra: LongWord): LongWord; inline;

{ Códigos canónicos (invertidos, para escribir LSB primero) de unos largos. Devuelve False si
  los largos no forman un código completo (salvo un solo símbolo). }
function PlzCanonCodes(const Lens: TPlzLens; N: Integer; out Codes: array of Word): Boolean;
{ Tabla de decodificación de unos largos; False si no son un código válido. }
function PlzBuildDecTable(const Lens: TPlzLens; N: Integer; var T: THufDec): Boolean;
{ Largos de Huffman limitados a MaxLen para las frecuencias dadas (determinista). Un solo
  símbolo usado: largo 1. Ninguno: todo 0. }
procedure PlzHuffLens(const Freq: array of LongWord; N: Integer; MaxLen: Integer; out Lens: TPlzLens);

function BitReverse(C: LongWord; N: Integer): LongWord; inline;

implementation

{ ---- utilidades ---- }

function Bsr32(V: LongWord): LongWord; inline;
begin
  Result := BsrDWord(V);
end;

function BitReverse(C: LongWord; N: Integer): LongWord;
var
  i: Integer;
begin
  Result := 0;
  for i := 1 to N do
  begin
    Result := (Result shl 1) or (C and 1);
    C := C shr 1;
  end;
end;

function PlzLenCode(V: LongWord; out NB: LongWord; out Extra: LongWord): LongWord;
var
  b: LongWord;
begin
  if V < 8 then
  begin
    NB := 0; Extra := 0;
    Exit(V);
  end;
  b := Bsr32(V);
  NB := b - 1;
  Extra := V and ((LongWord(1) shl NB) - 1);
  Result := 8 + 2 * (b - 3) + ((V shr NB) and 1);
end;

function PlzOfsSlot(D: LongWord; out NB: LongWord; out Extra: LongWord): LongWord;
var
  b: LongWord;
begin
  if D < 4 then
  begin
    NB := 0; Extra := 0;
    Exit(D);
  end;
  b := Bsr32(D);
  NB := b - 1;
  Extra := D and ((LongWord(1) shl NB) - 1);
  Result := 2 * b + ((D shr NB) and 1);
end;

{ ---- Huffman ---- }

function PlzCanonCodes(const Lens: TPlzLens; N: Integer; out Codes: array of Word): Boolean;
var
  Count: array[0..PLZ_MAXCODELEN + 1] of LongWord;
  Next: array[0..PLZ_MAXCODELEN + 1] of LongWord;
  i, l, Used: Integer;
  Kraft: LongWord;
begin
  FillChar(Count, SizeOf(Count), 0);
  Used := 0;
  for i := 0 to N - 1 do
  begin
    Codes[i] := 0;
    if Lens[i] > PLZ_MAXCODELEN then Exit(False);
    if Lens[i] > 0 then begin Inc(Count[Lens[i]]); Inc(Used); end;
  end;
  if Used <= 1 then Exit(True);   // un símbolo: 0 bits; ninguno: sin uso
  Kraft := 0;
  for l := 1 to PLZ_MAXCODELEN do Inc(Kraft, Count[l] shl (PLZ_MAXCODELEN - l));
  if Kraft <> (LongWord(1) shl PLZ_MAXCODELEN) then Exit(False);
  Next[1] := 0;
  for l := 2 to PLZ_MAXCODELEN do Next[l] := (Next[l - 1] + Count[l - 1]) shl 1;
  for i := 0 to N - 1 do
    if Lens[i] > 0 then
    begin
      Codes[i] := BitReverse(Next[Lens[i]], Lens[i]);
      Inc(Next[Lens[i]]);
    end;
  Result := True;
end;

function PlzBuildDecTable(const Lens: TPlzLens; N: Integer; var T: THufDec): Boolean;
var
  Codes: array[0..255] of Word;
  i, Used, Single: Integer;
  k, Step: LongWord;
  E: Word;
begin
  Result := False;
  if not PlzCanonCodes(Lens, N, Codes) then Exit;
  Used := 0; Single := 0;
  for i := 0 to N - 1 do
    if Lens[i] > 0 then begin Inc(Used); Single := i; end;
  if Used = 0 then Exit;
  if Used = 1 then
  begin
    E := Word(Single shl 4);   // 0 bits
    for k := 0 to PLZ_TABLESIZE - 1 do T[k] := E;
    Exit(True);
  end;
  for i := 0 to N - 1 do
    if Lens[i] > 0 then
    begin
      E := Word((i shl 4) or Lens[i]);
      Step := LongWord(1) shl Lens[i];
      k := Codes[i];
      while k < PLZ_TABLESIZE do
      begin
        T[k] := E;
        Inc(k, Step);
      end;
    end;
  Result := True;
end;

{ Huffman por el método de dos colas sobre las frecuencias ordenadas, y después el límite de
  largo con el ajuste clásico de la cuenta por largo (el de varios codificadores deflate de
  dominio público): los códigos más largos que MaxLen pasan a MaxLen y se reparte el exceso de
  Kraft alargando códigos más cortos. Los largos se asignan otra vez por frecuencia. Todo con
  enteros y ordenamiento estable: el mismo resultado en cualquier plataforma. }
procedure PlzHuffLens(const Freq: array of LongWord; N: Integer; MaxLen: Integer; out Lens: TPlzLens);
var
  Sym: array[0..255] of Integer;          // símbolos usados, por frecuencia ascendente
  W: array[0..511] of QWord;              // pesos de hojas y nodos
  Parent: array[0..511] of Integer;
  Depth: array[0..511] of Integer;
  Cnt: array[0..63] of LongWord;
  nu, i, j, k, a, b, Leaf, Node, NNodes, l: Integer;
  Total: LongWord;
  Key: array[0..255] of QWord;
  t64: QWord;

  procedure SiftDown(Root, Cnt: Integer);
  var
    c: Integer;
    v: QWord;
  begin
    v := Key[Root];
    while True do
    begin
      c := 2 * Root + 1;
      if c >= Cnt then Break;
      if (c + 1 < Cnt) and (Key[c + 1] > Key[c]) then Inc(c);
      if Key[c] <= v then Break;
      Key[Root] := Key[c];
      Root := c;
    end;
    Key[Root] := v;
  end;

  function PickMin: Integer;
  begin
    if (Leaf < nu) and ((Node >= NNodes) or (W[Leaf] <= W[Node])) then
    begin
      Result := Leaf; Inc(Leaf);
    end
    else
    begin
      Result := Node; Inc(Node);
    end;
  end;

begin
  FillChar(Lens, SizeOf(Lens), 0);
  nu := 0;
  for i := 0 to N - 1 do
    if Freq[i] > 0 then begin Sym[nu] := i; Inc(nu); end;
  if nu = 0 then Exit;
  if nu = 1 then begin Lens[Sym[0]] := 1; Exit; end;
  // Ordenar por frecuencia ascendente y, a igual frecuencia, por símbolo: claves
  // (frecuencia shl 9) or símbolo, todas distintas, con heapsort (sin depender de la entrada)
  for i := 0 to nu - 1 do Key[i] := (QWord(Freq[Sym[i]]) shl 9) or QWord(Sym[i]);
  for i := nu div 2 - 1 downto 0 do SiftDown(i, nu);
  for i := nu - 1 downto 1 do
  begin
    t64 := Key[0]; Key[0] := Key[i]; Key[i] := t64;
    SiftDown(0, i);
  end;
  for i := 0 to nu - 1 do Sym[i] := Integer(Key[i] and 511);
  for i := 0 to nu - 1 do W[i] := Freq[Sym[i]];
  // Nodos internos en W[nu..2n-2]
  Leaf := 0; Node := nu; NNodes := nu;
  for k := 0 to nu - 2 do
  begin
    a := PickMin;
    b := PickMin;
    W[NNodes] := W[a] + W[b];
    Parent[a] := NNodes;
    Parent[b] := NNodes;
    Inc(NNodes);
  end;
  // Profundidades desde la raíz
  Depth[NNodes - 1] := 0;
  for k := NNodes - 2 downto 0 do Depth[k] := Depth[Parent[k]] + 1;
  FillChar(Cnt, SizeOf(Cnt), 0);
  for i := 0 to nu - 1 do
  begin
    l := Depth[i];
    if l > MaxLen then l := MaxLen;
    Inc(Cnt[l]);
  end;
  // Ajuste de Kraft
  Total := 0;
  for l := 1 to MaxLen do Inc(Total, Cnt[l] shl (MaxLen - l));
  while Total > (LongWord(1) shl MaxLen) do
  begin
    Dec(Cnt[MaxLen]);
    for l := MaxLen - 1 downto 1 do
      if Cnt[l] > 0 then
      begin
        Dec(Cnt[l]);
        Inc(Cnt[l + 1], 2);
        Break;
      end;
    Dec(Total);
  end;
  // Asignar: los más frecuentes (al final de Sym) reciben los largos más cortos
  k := nu - 1;
  for l := 1 to MaxLen do
    for j := 1 to Cnt[l] do
    begin
      Lens[Sym[k]] := l;
      Dec(k);
    end;
end;

{ ---- lector de bits ---- }

procedure TPlzBitReader.Init(Src: PByte; Len: SizeInt);
begin
  PStart := Src;
  P := Src;
  PEnd := Src + Len;
  Used := 0;
  Over := False;
  Bits := PQWord(P)^;
end;

procedure TPlzBitReader.Refill;
begin
  Inc(P, Used shr 3);
  Used := Used and 7;
  if P > PEnd then
  begin
    // Se pasó: el stream está dañado. Se queda leyendo el relleno (ceros) y se avisa al final
    Over := True;
    P := PEnd;
  end;
  Bits := PQWord(P)^ shr Used;
end;

function TPlzBitReader.Peek: LongWord;
begin
  Result := LongWord(Bits);
end;

procedure TPlzBitReader.Skip(N: LongWord);
begin
  Bits := Bits shr N;
  Inc(Used, N);
end;

function TPlzBitReader.Get(N: LongWord): LongWord;
begin
  Result := LongWord(Bits) and ((LongWord(1) shl N) - 1);
  if N = 32 then Result := LongWord(Bits);
  Bits := Bits shr N;
  Inc(Used, N);
end;

function TPlzBitReader.Consumed: SizeInt;
begin
  Result := (P - PStart) + SizeInt((Used + 7) shr 3);
end;

{ ---- lectura de encabezados ---- }

function ReadVIntStage(S: TInStage): SizeInt;
var
  b: Byte;
  Sh: Integer;
  V: QWord;
begin
  V := 0; Sh := 0;
  repeat
    if S.Read(@b, 1) <> 1 then Corrupt('plz: truncated stream');
    if Sh > 28 then Corrupt('plz: bad number');
    V := V or (QWord(b and $7F) shl Sh);
    Inc(Sh, 7);
  until b < $80;
  if V > $7FFFFFFF then Corrupt('plz: bad number');
  Result := SizeInt(V);
end;

function ReadVIntMem(var P: PByte; PEnd: PByte; out V: SizeInt): Boolean;
var
  b: Byte;
  Sh: Integer;
  Q: QWord;
begin
  Result := False;
  Q := 0; Sh := 0;
  repeat
    if P >= PEnd then Exit;
    if Sh > 28 then Exit;
    b := P^;
    Inc(P);
    Q := Q or (QWord(b and $7F) shl Sh);
    Inc(Sh, 7);
  until b < $80;
  if Q > $7FFFFFFF then Exit;
  V := SizeInt(Q);
  Result := True;
end;

function ValidWindow(W: LongWord): Boolean; inline;
begin
  Result := (W >= PLZ_MINWINDOW) and (W <= PLZ_MAXWINDOW);
end;

{ ---- descripción de tablas ---- }

function ReadTableLens(var BR: TPlzBitReader; N: Integer; out Lens: TPlzLens): Boolean;
var
  ClLens: TPlzLens;
  ClTab: THufDec;
  Cnt, i, k, r: Integer;
  e: Word;
  Prev: Integer;
begin
  Result := False;
  FillChar(Lens, SizeOf(Lens), 0);
  FillChar(ClLens, SizeOf(ClLens), 0);
  BR.Refill;
  Cnt := BR.Get(8) + 1;
  if Cnt > N then Exit;
  for i := 0 to CL_N - 1 do
  begin
    if i mod 8 = 0 then BR.Refill;
    ClLens[i] := BR.Get(3);
  end;
  // El alfabeto CL usa una tabla de 11 bits con códigos de hasta 7
  if not PlzBuildDecTable(ClLens, CL_N, ClTab) then Exit;
  i := 0;
  Prev := -1;
  while i < Cnt do
  begin
    BR.Refill;
    e := ClTab[BR.Peek and (PLZ_TABLESIZE - 1)];
    BR.Skip(e and 15);
    k := e shr 4;
    case k of
      0..PLZ_MAXCODELEN:
        begin
          Lens[i] := k; Prev := k; Inc(i);
        end;
      12:
        begin
          if Prev < 0 then Exit;
          r := 3 + BR.Get(2);
          if i + r > Cnt then Exit;
          while r > 0 do begin Lens[i] := Prev; Inc(i); Dec(r); end;
        end;
      13, 14:
        begin
          if k = 13 then r := 3 + BR.Get(3) else r := 11 + BR.Get(7);
          if i + r > Cnt then Exit;
          while r > 0 do begin Lens[i] := 0; Inc(i); Dec(r); end;
          Prev := 0;
        end;
    else
      Exit;
    end;
  end;
  Result := not BR.Over;
end;

{ ---- TPlzDecoder ---- }

constructor TPlzDecoder.Create(AWindow: SizeUInt);
begin
  inherited Create;
  Window := AWindow;
  FRep[0] := 1; FRep[1] := 2; FRep[2] := 3; FRep[3] := 4;
end;

function TPlzDecoder.Scratch(Len: SizeInt): PByte;
begin
  if Length(FScratch) < Len + PLZ_PAD then
  begin
    FScratch := nil;
    SetLength(FScratch, Len + Len div 4 + PLZ_PAD);
  end;
  FillChar(FScratch[Len], PLZ_PAD, 0);
  Result := @FScratch[0];
end;

procedure TPlzDecoder.ReadTables(var BR: TPlzBitReader; const Modes: array of Integer);
var
  t: Integer;
  Lens: TPlzLens;
begin
  for t := 0 to 4 do
    case Modes[t] of
      PM_NEW:
        begin
          if not ReadTableLens(BR, PLZ_ALPHA[t], Lens) then Corrupt('plz: bad table');
          if not PlzBuildDecTable(Lens, PLZ_ALPHA[t], FTab[t]) then Corrupt('plz: bad table');
          FHave[t] := True;
        end;
      PM_REUSE:
        if not FHave[t] then Corrupt('plz: no table to reuse');
    end;
end;

procedure TPlzDecoder.DecodeLiterals(Src: PByte; SrcLen: SizeInt; nLit: SizeInt; Tab: PHufDec);
var
  R: array[0..3] of TPlzBitReader;
  Cnt: array[0..3] of SizeInt;
  O: array[0..3] of PByte;
  Sz: array[0..3] of SizeInt;
  NS, k, j: Integer;
  q, Pos, n: SizeInt;
  e: LongWord;
  P: PByte;
  b0, b1, b2, b3: QWord;
  u0, u1, u2, u3: LongWord;
  o0, o1, o2, o3: PByte;
begin
  if nLit >= PLZ_LIT4 then NS := 4 else NS := 1;
  P := Src;
  for k := 0 to NS - 1 do
    if not ReadVIntMem(P, Src + SrcLen, Sz[k]) then Corrupt('plz: bad literal section');
  Pos := P - Src;
  q := (nLit + NS - 1) div NS;
  for k := 0 to NS - 1 do
  begin
    if (Sz[k] < 0) or (Sz[k] > SrcLen - Pos) then Corrupt('plz: bad literal stream size');
    R[k].Init(Src + Pos, Sz[k]);
    Inc(Pos, Sz[k]);
    Cnt[k] := nLit - k * q;
    if Cnt[k] > q then Cnt[k] := q;
    if Cnt[k] < 0 then Cnt[k] := 0;
    O[k] := @FLit[k * q];
  end;
  if Pos <> SrcLen then Corrupt('plz: bad literal section');
  if NS = 4 then
  begin
    // Los cuatro streams a la par: 5 símbolos de hasta 11 bits por recarga
    n := Cnt[3] div 5;
    o0 := O[0]; o1 := O[1]; o2 := O[2]; o3 := O[3];
    for j := 1 to n do
    begin
      R[0].Refill; R[1].Refill; R[2].Refill; R[3].Refill;
      b0 := R[0].Bits; b1 := R[1].Bits; b2 := R[2].Bits; b3 := R[3].Bits;
      u0 := R[0].Used; u1 := R[1].Used; u2 := R[2].Used; u3 := R[3].Used;
      for k := 0 to 4 do
      begin
        e := Tab^[b0 and (PLZ_TABLESIZE - 1)]; o0^ := Byte(e shr 4); Inc(o0); b0 := b0 shr (e and 15); Inc(u0, e and 15);
        e := Tab^[b1 and (PLZ_TABLESIZE - 1)]; o1^ := Byte(e shr 4); Inc(o1); b1 := b1 shr (e and 15); Inc(u1, e and 15);
        e := Tab^[b2 and (PLZ_TABLESIZE - 1)]; o2^ := Byte(e shr 4); Inc(o2); b2 := b2 shr (e and 15); Inc(u2, e and 15);
        e := Tab^[b3 and (PLZ_TABLESIZE - 1)]; o3^ := Byte(e shr 4); Inc(o3); b3 := b3 shr (e and 15); Inc(u3, e and 15);
      end;
      R[0].Bits := b0; R[1].Bits := b1; R[2].Bits := b2; R[3].Bits := b3;
      R[0].Used := u0; R[1].Used := u1; R[2].Used := u2; R[3].Used := u3;
    end;
    O[0] := o0; O[1] := o1; O[2] := o2; O[3] := o3;
    for k := 0 to 3 do Dec(Cnt[k], 5 * n);
  end;
  // Lo que queda, de a uno
  for k := 0 to NS - 1 do
  begin
    P := O[k];
    while Cnt[k] > 0 do
    begin
      R[k].Refill;
      e := Tab^[R[k].Bits and (PLZ_TABLESIZE - 1)];
      P^ := Byte(e shr 4);
      Inc(P);
      R[k].Skip(e and 15);
      Dec(Cnt[k]);
    end;
    R[k].Refill;
    if R[k].Over or (R[k].Consumed <> Sz[k]) then Corrupt('plz: bad literal stream');
  end;
end;

procedure TPlzDecoder.DecodeBlock(Payload: PByte; PayLen: SizeInt; Dst: PByte; RawLen: SizeInt;
  Base: PByte; Tail: PByte; TailLen: SizeInt; AbsPos: Int64);
var
  Q, QE: PByte;
  nSeq, nLit, LitLen, i: SizeInt;
  m0, m1: Byte;
  Modes: array[0..4] of Integer;
  TB: TPlzBitReader;
  Pos: SizeInt;
  // secuencias
  SR: TPlzBitReader;
  Bits: QWord;
  Used: LongWord;
  P: PByte;
  TokT, OfsT, LlxT, MlxT: PHufDec;
  e: LongWord;
  tok, oc, ll, ml, nb, slot, b: LongWord;
  off, r0, r1, r2, r3: SizeUInt;
  op, oend, lp, lend, src: PByte;
  Hist: SizeUInt;            // bytes de historia contigua antes de op
  Win: SizeUInt;
  c: SizeInt;
  s: SizeInt;
begin
  Q := Payload;
  QE := Payload + PayLen;
  if not ReadVIntMem(Q, QE, nSeq) or not ReadVIntMem(Q, QE, nLit) or (QE - Q < 2) then
    Corrupt('plz: bad block header');
  m0 := Q[0];
  m1 := Q[1];
  Inc(Q, 2);
  if (nLit > RawLen) or (nSeq > RawLen) or (m1 and $FC <> 0) then Corrupt('plz: bad block header');
  Modes[PT_LIT] := m0 and 3;
  Modes[PT_TOK] := (m0 shr 2) and 3;
  Modes[PT_LLX] := (m0 shr 4) and 3;
  Modes[PT_MLX] := (m0 shr 6) and 3;
  Modes[PT_OFS] := m1 and 3;
  for i := 1 to 4 do
    if Modes[i] = PM_RAW then Corrupt('plz: bad table mode');
  if (Modes[PT_LIT] = PM_NONE) <> (nLit = 0) then Corrupt('plz: bad literal mode');
  if (nSeq > 0) and ((Modes[PT_TOK] = PM_NONE) or (Modes[PT_OFS] = PM_NONE)) then
    Corrupt('plz: bad table mode');
  Pos := Q - Payload;
  // Tablas
  if (Modes[0] = PM_NEW) or (Modes[1] = PM_NEW) or (Modes[2] = PM_NEW) or (Modes[3] = PM_NEW) or
     (Modes[4] = PM_NEW) then
  begin
    TB.Init(Payload + Pos, PayLen - Pos);
    ReadTables(TB, Modes);
    TB.Refill;
    if TB.Over then Corrupt('plz: bad table');
    Inc(Pos, TB.Consumed);
    if Pos > PayLen then Corrupt('plz: bad table');
  end
  else
    ReadTables(TB, Modes);   // sólo comprueba los reusos
  // Literales
  if Length(FLit) < PLZ_MAXBLOCK + PLZ_PAD then SetLength(FLit, PLZ_MAXBLOCK + PLZ_PAD);
  if nLit > 0 then
  begin
    if Modes[PT_LIT] = PM_RAW then
    begin
      if nLit > PayLen - Pos then Corrupt('plz: bad literal section');
      Move(Payload[Pos], FLit[0], nLit);
      Inc(Pos, nLit);
    end
    else
    begin
      Q := Payload + Pos;
      if not ReadVIntMem(Q, QE, LitLen) then Corrupt('plz: bad literal section');
      Pos := Q - Payload;
      if (LitLen < 0) or (LitLen > PayLen - Pos) then Corrupt('plz: bad literal section');
      DecodeLiterals(Payload + Pos, LitLen, nLit, @FTab[PT_LIT]);
      Inc(Pos, LitLen);
    end;
  end;
  // Secuencias
  op := Dst;
  oend := Dst + RawLen;
  lp := @FLit[0];
  lend := lp + nLit;
  r0 := FRep[0]; r1 := FRep[1]; r2 := FRep[2]; r3 := FRep[3];
  Win := Window;
  if nSeq > 0 then
  begin
    SR.Init(Payload + Pos, PayLen - Pos);
    TokT := @FTab[PT_TOK];
    OfsT := @FTab[PT_OFS];
    LlxT := @FTab[PT_LLX];
    MlxT := @FTab[PT_MLX];
    P := SR.P;
    Used := 0;
    Bits := 0;
    for s := 1 to nSeq do
    begin
      // recarga
      Inc(P, Used shr 3);
      Used := Used and 7;
      if P > SR.PEnd then begin SR.Over := True; P := SR.PEnd; end;
      Bits := PQWord(P)^ shr Used;
      e := TokT^[Bits and (PLZ_TABLESIZE - 1)];
      Bits := Bits shr (e and 15); Inc(Used, e and 15);
      tok := e shr 4;
      e := OfsT^[Bits and (PLZ_TABLESIZE - 1)];
      Bits := Bits shr (e and 15); Inc(Used, e and 15);
      oc := e shr 4;
      ll := tok shr 4;
      ml := tok and 15;
      if (ll = 7) or (ml = 15) then
      begin
        if ll = 7 then
        begin
          if Modes[PT_LLX] = PM_NONE then Corrupt('plz: bad sequence');
          e := LlxT^[Bits and (PLZ_TABLESIZE - 1)];
          Bits := Bits shr (e and 15); Inc(Used, e and 15);
          ll := e shr 4;      // código; los extra van después
        end;
        if ml = 15 then
        begin
          if Modes[PT_MLX] = PM_NONE then Corrupt('plz: bad sequence');
          // hasta 11 + 11 + 11 + 11 = 44 bits usados desde la recarga
          e := MlxT^[Bits and (PLZ_TABLESIZE - 1)];
          Bits := Bits shr (e and 15); Inc(Used, e and 15);
          ml := e shr 4;
        end;
        // extra de LLX
        if tok shr 4 = 7 then
        begin
          Inc(P, Used shr 3); Used := Used and 7;
          if P > SR.PEnd then begin SR.Over := True; P := SR.PEnd; end;
          Bits := PQWord(P)^ shr Used;
          if ll >= 8 then
          begin
            b := (ll - 8) shr 1 + 3;
            nb := b - 1;
            ll := ((2 or (ll and 1)) shl nb) + (LongWord(Bits) and ((LongWord(1) shl nb) - 1));
            Bits := Bits shr nb; Inc(Used, nb);
          end;
          Inc(ll, 7);
        end;
        if tok and 15 = 15 then
        begin
          Inc(P, Used shr 3); Used := Used and 7;
          if P > SR.PEnd then begin SR.Over := True; P := SR.PEnd; end;
          Bits := PQWord(P)^ shr Used;
          if ml >= 8 then
          begin
            b := (ml - 8) shr 1 + 3;
            nb := b - 1;
            ml := ((2 or (ml and 1)) shl nb) + (LongWord(Bits) and ((LongWord(1) shl nb) - 1));
            Bits := Bits shr nb; Inc(Used, nb);
          end;
          Inc(ml, 15);
        end;
        Inc(P, Used shr 3); Used := Used and 7;
        if P > SR.PEnd then begin SR.Over := True; P := SR.PEnd; end;
        Bits := PQWord(P)^ shr Used;
      end;
      Inc(ml, PLZ_MINMATCH);
      // offset
      if oc < 4 then
      begin
        case oc of
          0: off := r0;
          1: begin off := r1; r1 := r0; r0 := off; end;
          2: begin off := r2; r2 := r1; r1 := r0; r0 := off; end;
        else
          begin off := r3; r3 := r2; r2 := r1; r1 := r0; r0 := off; end;
        end;
      end
      else
      begin
        slot := oc - 4;
        if slot < 4 then off := slot + 1
        else
        begin
          nb := (slot shr 1) - 1;
          off := ((SizeUInt(2) or (slot and 1)) shl nb) + (LongWord(Bits) and ((LongWord(1) shl nb) - 1)) + 1;
          Bits := Bits shr nb; Inc(Used, nb);
        end;
        r3 := r2; r2 := r1; r1 := r0; r0 := off;
      end;
      // Comprobaciones
      if (SizeUInt(lend - lp) < ll) or (SizeUInt(oend - op) < SizeUInt(ll) + ml) then
        Corrupt('plz: bad sequence');
      // literales
      if (ll <= 16) and (oend - op >= 32) then
      begin
        PQWord(op)^ := PQWord(lp)^;
        PQWord(op + 8)^ := PQWord(lp + 8)^;
      end
      else
        Move(lp^, op^, ll);
      Inc(op, ll);
      Inc(lp, ll);
      // match: en la historia contigua (off <= op - Base; ahí siempre hay off bytes
      // producidos antes) o en la vieja del ring
      Hist := op - Base;
      if off <= Hist then
      begin
        if off > Win then Corrupt('plz: bad offset');
        src := op - off;
        if (off >= 8) and (oend - op >= SizeInt(ml) + 16) then
        begin
          c := ml;
          repeat
            PQWord(op)^ := PQWord(src)^;
            PQWord(op + 8)^ := PQWord(src + 8)^;
            Inc(op, 16); Inc(src, 16); Dec(c, 16);
          until c <= 0;
          Inc(op, c);   // c <= 0: lo que se copió de más
        end
        else if off >= ml then
        begin
          // cerca del final del bloque, sin solaparse: una copia común
          Move(src^, op^, ml);
          Inc(op, ml);
        end
        else
        begin
          c := ml;
          repeat op^ := src^; Inc(op); Inc(src); Dec(c); until c = 0;
        end;
      end
      else
      begin
        // Parte en la historia vieja del ring
        if (off > Win) or (Int64(off) > AbsPos + (op - Dst)) or (off - Hist > SizeUInt(TailLen)) then
          Corrupt('plz: bad offset');
        src := Tail + TailLen - (off - Hist);
        c := ml;
        repeat
          op^ := src^;
          Inc(op); Inc(src); Dec(c);
          if src = Tail + TailLen then src := Base;
        until c = 0;
      end;
    end;
    // El stream de secuencias tiene que terminar justo
    Inc(P, Used shr 3); Used := Used and 7;
    if P > SR.PEnd then SR.Over := True;
    if SR.Over or ((P - SR.PStart) + SizeInt((Used + 7) shr 3) <> PayLen - Pos) then
      Corrupt('plz: bad sequence stream');
  end
  else if Pos <> PayLen then
    Corrupt('plz: bad block size');
  FRep[0] := r0; FRep[1] := r1; FRep[2] := r2; FRep[3] := r3;
  // Literales finales
  c := lend - lp;
  if c <> oend - op then Corrupt('plz: bad block size');
  Move(lp^, op^, c);
end;

{ ---- TPlzStage ---- }

destructor TPlzStage.Destroy;
begin
  FDec.Free;
  inherited Destroy;
end;

procedure TPlzStage.Start;
var
  Hdr: array[0..4] of Byte;
  W: LongWord;
begin
  FStarted := True;
  Source.ReadExact(@Hdr[0], 5);
  if Hdr[0] <> PLZ_VERSION then Corrupt('plz: unknown stream version');
  W := LongWord(Hdr[1]) or (LongWord(Hdr[2]) shl 8) or (LongWord(Hdr[3]) shl 16) or (LongWord(Hdr[4]) shl 24);
  if not ValidWindow(W) then Corrupt('plz: bad window');
  FDec := TPlzDecoder.Create(W);
  FRingMax := SizeInt(W) + PLZ_MAXBLOCK;
  // El ring crece con los datos (un stream chico no reserva toda la ventana)
  FRingCap := 4 * PLZ_MAXBLOCK;
  if FRingCap > FRingMax then FRingCap := FRingMax;
  SetLength(FRing, FRingCap + PLZ_PAD);
end;

function TPlzStage.NextBlock: Boolean;
var
  T: Byte;
  n, c: SizeInt;
  Cap: SizeInt;
  Pay: PByte;
  Tail: PByte;
  TailLen: SizeInt;
begin
  Result := False;
  if FEof then Exit;
  if Source.Read(@T, 1) <> 1 then Corrupt('plz: truncated stream');
  if T = PB_END then
  begin
    FEof := True;
    Exit;
  end;
  if T > PB_COMP then Corrupt('plz: bad block type');
  n := ReadVIntStage(Source);
  if (n < 1) or (n > PLZ_MAXBLOCK) then Corrupt('plz: bad block size');
  // Lugar en el ring: crece mientras no llegó a W + PLZ_MAXBLOCK; después da la vuelta
  if FW + n > FRingCap then
  begin
    if FRingCap < FRingMax then
    begin
      Cap := FRingCap * 2;
      while Cap < FW + n do Cap := Cap * 2;
      if Cap > FRingMax then Cap := FRingMax;
      SetLength(FRing, Cap + PLZ_PAD);
      FRingCap := Cap;
    end;
    if FW + n > FRingCap then
    begin
      FTailEnd := FW;
      FW := 0;
    end;
  end;
  if FTailEnd > 0 then
  begin
    Tail := @FRing[0];
    TailLen := FTailEnd;
  end
  else
  begin
    Tail := nil;
    TailLen := 0;
  end;
  case T of
    PB_RAW: Source.ReadExact(@FRing[FW], n);
    PB_RLE:
      begin
        Source.ReadExact(@FRing[FW], 1);
        FillChar(FRing[FW + 1], n - 1, FRing[FW]);
      end;
    PB_COMP:
      begin
        c := ReadVIntStage(Source);
        if (c < 1) or (c > PLZ_MAXBLOCK + PLZ_MAXBLOCK div 2) then Corrupt('plz: bad block size');
        Pay := FDec.Scratch(c);
        Source.ReadExact(Pay, c);
        FDec.DecodeBlock(Pay, c, @FRing[FW], n, @FRing[0], Tail, TailLen, FAbs);
      end;
  end;
  FPos := FW;
  FEnd := FW + n;
  Inc(FW, n);
  Inc(FAbs, n);
  Result := True;
end;

function TPlzStage.Read(Buf: PByte; Count: SizeInt): SizeInt;
var
  n: SizeInt;
begin
  Result := 0;
  if not FStarted then Start;
  while Count > 0 do
  begin
    if FPos = FEnd then
      if not NextBlock then Break;
    n := FEnd - FPos;
    if n > Count then n := Count;
    Move(FRing[FPos], Buf^, n);
    Inc(FPos, n);
    Inc(Buf, n);
    Dec(Count, n);
    Inc(Result, n);
    if Result > 0 then Break;    // devolver lo que hay: el que llama pide más si quiere
  end;
end;

{ ---- memoria a memoria ---- }

function PlzDecodeMem(Src: PByte; SrcLen: SizeInt; Dst: PByte; DstLen: SizeInt): Boolean;
var
  P, PEnd: PByte;
  W: LongWord;
  Dec: TPlzDecoder;
  T: Byte;
  n, c: SizeInt;
  Done: SizeInt;
  Pay: PByte;
begin
  Result := False;
  if SrcLen < 6 then Exit;
  P := Src;
  PEnd := Src + SrcLen;
  if P[0] <> PLZ_VERSION then Exit;
  W := LongWord(P[1]) or (LongWord(P[2]) shl 8) or (LongWord(P[3]) shl 16) or (LongWord(P[4]) shl 24);
  if not ValidWindow(W) then Exit;
  Inc(P, 5);
  Dec := TPlzDecoder.Create(W);
  try
    Done := 0;
    try
      while True do
      begin
        if P >= PEnd then Exit;
        T := P^;
        Inc(P);
        if T = PB_END then Break;
        if T > PB_COMP then Exit;
        if not ReadVIntMem(P, PEnd, n) then Exit;
        if (n < 1) or (n > PLZ_MAXBLOCK) or (n > DstLen - Done) then Exit;
        case T of
          PB_RAW:
            begin
              if n > PEnd - P then Exit;
              Move(P^, Dst[Done], n);
              Inc(P, n);
            end;
          PB_RLE:
            begin
              if P >= PEnd then Exit;
              FillChar(Dst[Done], n, P^);
              Inc(P);
            end;
          PB_COMP:
            begin
              if not ReadVIntMem(P, PEnd, c) then Exit;
              if (c < 1) or (c > PEnd - P) then Exit;
              // El contenido se copia a un búfer con relleno: el lector de bits lee de a 8 bytes
              Pay := Dec.Scratch(c);
              Move(P^, Pay^, c);
              Inc(P, c);
              Dec.DecodeBlock(Pay, c, Dst + Done, n, Dst, nil, 0, Done);
            end;
        end;
        Inc(Done, n);
      end;
      Result := (P = PEnd) and (Done = DstLen);
    except
      on EArcCorrupt do Result := False;
    end;
  finally
    Dec.Free;
  end;
end;

end.
