{ Codificador PLZ (método `plz`, formato en parc_plz). Código propio de PArc, escrito desde la
  literatura pública de LZ77 (tablas hash, parseo voraz y perezoso, offsets repetidos, Huffman
  canónico limitado en largo); no deriva de Tornado ni de otro código de FreeArc.

  Búsqueda de matches:
  - una vía (niveles 1-2): tabla directa de entradas de 8 bytes (posición y los primeros 4 bytes
    de los datos, así un candidato que no coincide no toca la ventana); el lazo que recorre las
    posiciones sin match está en ensamblador x86-64 (parc_plz_x64.inc) con la misma salida que
    el Pascal;
  - filas (niveles 3-7): cada fila guarda las últimas `Ways` posiciones con ese hash, en orden de
    recencia, con un byte de etiqueta por entrada que se compara de a 8 (SWAR) antes de mirar
    los datos; fila, etiquetas y cabeza en la misma línea de caché.
  Antes de buscar se prueban los offsets repetidos. Parser: voraz con aceleración en zonas sin
  matches (1-2) o perezoso de 1 o 2 pasos con una ganancia aproximada en bits
  (largo*4 - bits del offset) (3-7), extendiendo cada match hacia atrás.
  Entropía: cada bloque parseado (256 KB) se codifica entero o partido (después de una
  secuencia) en trozos de 16-128 KB según una estimación de entropía en enteros; cada trozo
  lleva histogramas, Huffman limitado a 11 bits por alfabeto, y reuso de la tabla anterior o
  literales guardados cuando sale más barato; un bloque que no achica va guardado.
  Cada bloque se parsea sólo con los datos hasta su final, así la salida no depende de cómo
  llegan los datos (ni de los hilos): es la misma en streaming y en memoria, con y sin
  ensamblador y en cualquier plataforma (todo con enteros). }
unit parc_plzenc;

{$mode objfpc}{$H+}
{$modeswitch advancedrecords}
{$R-}{$Q-}
{$inline on}
{$pointermath on}

interface

uses
  SysUtils, parc_outstream, parc_plz;

type
  EPlzEncoder = class(Exception);

  TPlzEncParams = record
    Level: Integer;
    Window: LongWord;
    RowBits: Integer;     // log2 de la cantidad de filas del hash
    HashMem: Int64;       // memoria del hash pedida con h<mem> (0 = la del nivel)
    Ways: Integer;        // entradas por fila (potencia de 2, 1..64)
    Lazy: Integer;        // 0 = voraz, 1 o 2 pasos
    Nice: Integer;        // largo con el que se deja de buscar
    InsertAll: Boolean;   // insertar todas las posiciones de un match (si no, unas pocas)
    InsertMax: Integer;   // con InsertAll, en un match largo sólo las primeras y últimas (0 = todas)
    SkipShift: Integer;   // aceleración sin matches: paso 1 + fallos shr SkipShift (0 = sin)
    HashLen: Integer;     // bytes del hash (4..6)
    ShortBits: Integer;   // tabla corta de 4 bytes (log2 de entradas; 0 = sin)
    SplitMode: Integer;   // partir bloques: 0 nunca, 1 siempre, 2 sólo los binarios
    BinLazy: Integer;     // pasos perezosos de más en los bloques binarios
    BinHashLen: Integer;  // bytes del hash en los bloques binarios (perezosos; 0 = el de siempre)
    Bucket: Integer;      // una vía: entradas por hash (1 o 2; 2 sólo en los perezosos)
    BlockSize: Integer;
  end;

{ Parámetros de la etapa (Params[0] = 'plz'): nivel, ventana, h<mem>. Lanza EPlzEncoder si no
  son válidos. }
function ParsePlzEncParams(const Params: TStringArray): TPlzEncParams;
function PlzEncAvailable(const Stage: string): Boolean;
{ Ventana (lo que usa 4x4 como tamaño de bloque si no se le da b<mem>). }
function PlzDictionary(const Params: TStringArray): Int64;
{ Memoria del codificador. }
function PlzEncMemory(const P: TPlzEncParams; Streaming: Boolean): Int64;
{ Texto canónico de la etapa con la ventana limitada a Limit y el codificador a MemLim
  (0 = sin límite). }
function PlzCanon(const Params: TStringArray; Limit, MemLim: Int64): string;

{ Memoria a memoria (4x4): comprime Src entero. False si no achica (se guarda). }
function PlzEncodeMem(const Params: TStringArray; Src: PByte; SrcLen: SizeInt; out Dst: TBytes;
  Cache: TObject = nil): Boolean;

type
  TPlzEngine = class;

  TPlzEncStage = class(TOutStage)
  private
    FEng: TPlzEngine;
  protected
    procedure DoWrite(Buf: PByte; Count: SizeInt); override;
    procedure DoFinish; override;
  public
    constructor Create(ATarget: TOutStage; const Params: TStringArray);
    destructor Destroy; override;
  end;

  { Motores reusados entre bloques de 4x4 (las tablas ya reservadas). Uno por hilo a la vez. }
  TPlzEncCache = class
  private
    FLock: TRTLCriticalSection;
    FItems: array of TObject;
    FCount: Integer;
    function Take(const P: TPlzEncParams): TObject;
    procedure Put(E: TObject);
  public
    constructor Create;
    destructor Destroy; override;
  end;

  { Escritor de bits LSB primero. }
  TPlzBitWriter = record
    Data: TBytes;
    Len: SizeInt;
    Acc: QWord;
    N: LongWord;
    procedure Init(Cap: SizeInt);
    procedure Put(V: LongWord; Bits: LongWord); inline;
    procedure Flush;          // completa el último byte con ceros
    procedure Ensure(Extra: SizeInt);
  end;

  TPlzSeq = record
    LL, ML: LongWord;         // ML sin restar el mínimo
    Tok: LongWord;            // token: LLt*16 + MLt
    OC, ONB, OX: LongWord;    // código OFS (0..63), bits extra y su valor
    LXC, LXN, LXV: LongWord;  // código LLX, bits extra, valor (si LLt = 7)
    MXC, MXN, MXV: LongWord;  // código MLX (si MLt = 15)
  end;

  TPlzTabCodes = record
    Lens: TPlzLens;           // largos efectivos (0 para el símbolo de una tabla de un solo símbolo)
    Codes: array[0..255] of Word;
  end;
  PPlzTabCodes = ^TPlzTabCodes;
  { Histogramas de los 5 alfabetos de un tramo (para elegir dónde partir un bloque) }
  TPlzFreqs = record
    F: array[0..4, 0..255] of LongWord;
  end;
  PPlzSeq = ^TPlzSeq;

  { Estado de la evaluación de una posición del perezoso de una vía (PlzEval1, en ensamblador) }
  TPlzEval = record
    X, Base, IEnd: PByte;
    T64, TS: PQWord;
    HL, Ln, G: Int64;
    Rep0, Rep1, Rep2, Rep3: LongWord;
    Cur0, InsNext, C, HD, Dt, D2, Win, HShl, Sh, SSh, Bucket, Check2: LongWord;
  end;

  TPlzEngine = class
  private
    FEv: TPlzEval;
    P: TPlzEncParams;
    // datos
    FOwnBuf: TBytes;
    FBuf: PByte;              // FBuf[0] tiene la posición relativa FBufRel
    FBufRel: LongWord;
    FCap: SizeInt;            // capacidad final del búfer propio (streaming)
    FCur, FEnd: LongWord;     // posición relativa del próximo byte a parsear y fin de los datos
    FInsNext: LongWord;       // posiciones < FInsNext ya están en el hash (o se saltearon)
    FAnchor: PByte;           // comienzo de los literales pendientes (voraz de una vía)
    // hash
    FRowMem: TBytes;          // filas del hash: [etiquetas][cabeza][posiciones], alineadas a 32/64
    FRows: PByte;
    FRowBytes: SizeInt;
    FPosOff, FHeadOff, FTagGroups: Integer;
    FWayFull: QWord;
    FTab64: array of QWord;   // una vía: posición (bits 0-31) y los 4 primeros bytes (32-63)
    FTabS: array of QWord;    // tabla corta (hash de 4 bytes), mismo formato de entrada
    FShortSh: Integer;
    FShortOn: Boolean;        // el bloque actual usa la tabla corta
    FHashShl: Integer;        // 64 - 8 * bytes del hash del bloque actual (filas)
    FBin: Boolean;            // el bloque actual parece binario (WantShort)
    FLazyCur: Integer;        // pasos perezosos en este bloque
    FOne: Boolean;
    FWayMask: LongWord;
    FRowShift: Integer;
    FTagShift: Integer;
    // estado del stream
    FRep: array[0..3] of LongWord;
    FPrevLens: array[0..4] of TPlzLens;
    FHavePrev: array[0..4] of Boolean;
    // bloque
    FSeq: array of TPlzSeq;
    FNSeq: SizeInt;
    FLit: array of Byte;
    FNLit: SizeInt;
    FBW: array[0..5] of TPlzBitWriter;   // 0 = tablas, 1..4 = literales, 5 = secuencias
    FTC: array[0..4] of TPlzTabCodes;
    FPay: TBytes;
    FLeafF: array of TPlzFreqs;   // histogramas de las hojas del bloque
    FNodeF: array of TPlzFreqs;   // y de cada nodo del árbol de cortes
    FSplit: array[0..255] of Boolean;
    FLeafSeq, FLeafLit, FLeafRaw: array[0..64] of SizeInt;
    FOut: TBytes;             // salida acumulada (bloques)
    FOutLen: SizeInt;
    procedure Grow(Need: SizeInt);
    procedure Out8(B: Byte); inline;
    procedure OutVInt(V: LongWord);
    procedure OutBytes(Src: PByte; N: SizeInt);
    procedure ResetTables;
    procedure Rebase;
    procedure Slide;
    function HashOf(Ip: PByte; out Tag: Byte): LongWord; inline;
    procedure Insert(Ip: PByte; Cur: LongWord); inline;
    function FindAndInsert(Ip, IEnd: PByte; Cur: LongWord; Best: SizeInt; out Dist: LongWord): SizeInt;
    procedure AddSeq(Lit: PByte; LL: LongWord; Dist: LongWord; ML: LongWord);
    procedure FinishSeqs(Lo, Hi: SizeInt);
    procedure AddLits(Lit: PByte; N: SizeInt);
    procedure ParseFast(BS, BE: LongWord);
    procedure ParseFast1(BS, BE: LongWord);
    {$IF defined(CPUX86_64) and not defined(PARC_NOASM)}
    procedure RunGreedyAsm(Ip, IEnd: PByte);
    {$ENDIF}
    function WantShort(Ip, IEnd: PByte): Boolean;
    procedure ParseFastDual(Ip, IEnd: PByte);
    function FastMatch(Ip: PByte; Dist: LongWord; L: SizeInt; ILimit: PByte): PByte;
    procedure ParseLazy(BS, BE: LongWord);
    procedure PrefetchRow(Ip: PByte); inline;
    procedure InsertRange(A, B: PByte);
    procedure InsertRange2(A, B: PByte);
    function EvalAt(X, IEnd: PByte; out Ln: SizeInt; out Dt: LongWord; out G: LongInt): Boolean;
    procedure EncodeBlock(BS, BE: LongWord);
    {$IFDEF PLZ_CHECK}
    procedure CheckBlock(BS, BE: LongWord; const R: array of LongWord);
    {$ENDIF}
    procedure WriteBlock(Src: PByte; RawLen: SizeInt; SeqLo, SeqHi, LitLo, LitHi: SizeInt;
      Piece: Boolean; const SavedRep: array of LongWord; PF: Pointer; ExtraIn: Int64);
    function BestSplit(Node, Lo, Hi: Integer): Int64;
    procedure EmitPieces(Node, Lo, Hi: Integer; Src: PByte; const SavedRep: array of LongWord);
  public
    constructor Create(const AP: TPlzEncParams);
    procedure StartStream;
    { Memoria: comprime Src[0..Len) en FOut (encabezado, bloques y fin). }
    procedure EncodeAll(Src: PByte; Len: SizeInt);
    { Streaming: StartStream ya escribió el encabezado en FOut. }
    procedure Feed(Buf: PByte; Count: SizeInt);
    procedure Finish;
    property OutBuf: TBytes read FOut;
    property OutLen: SizeInt read FOutLen;
    procedure ClearOut;
  end;

implementation

{ Tamaño de memoria como en los métodos de FreeArc ("16mb", "512kb", "1g", "100b"; sin sufijo es
  una potencia de 2: "24" = 16mb). }
function ParseMem(const S: string; out Value: QWord): Boolean;
var
  i: Integer;
  Num: QWord;
  c: Char;
begin
  Result := False;
  i := 1;
  if (i > Length(S)) or not (S[i] in ['0'..'9']) then Exit;
  Num := 0;
  while (i <= Length(S)) and (S[i] in ['0'..'9']) do
  begin
    if Num > (High(QWord) div 10) then Exit;
    Num := Num * 10 + Ord(S[i]) - Ord('0');
    Inc(i);
  end;
  if i <= Length(S) then c := LowerCase(S[i]) else c := '^';
  case c of
    'b': Value := Num;
    'k': Value := Num shl 10;
    'm': Value := Num shl 20;
    'g': Value := Num shl 30;
    '^': begin
           if Num > 63 then Exit;
           Value := QWord(1) shl Num;
         end;
  else
    Exit;
  end;
  if (c <> '^') and (Num > (High(QWord) shr 30)) then Exit;
  Result := True;
end;

const
  KB = 1024;
  MB = 1024 * 1024;
  PRIME64 = QWord($9E3779B185EBCA87);

{ ---- niveles ---- }

type
  TPlzLevel = record
    Window: LongWord;
    RowBits, Ways, Lazy, Nice, SkipShift, HashLen: Integer;
    InsertAll: Boolean;
    InsertMax: Integer;
    ShortBits: Integer;
  end;

const
  { Niveles (medidos contra Tornado en TILIN y los sets de prueba, ver docs/ESTADO.md):
    1-2 voraces con tabla directa (la clase de tor:3 y tor:4), 3-4 perezosos de un paso (tor:5 y
    tor:6), 5-7 perezosos de dos pasos con filas más anchas (más lentos, más chicos). }
  PLZ_MAXLEVEL = 7;
  LEVELS: array[1..PLZ_MAXLEVEL] of TPlzLevel = (
    (Window:  8 * MB; RowBits: 17; Ways:  1; Lazy: 0; Nice:  32; SkipShift: 4; HashLen: 6; InsertAll: False; InsertMax: 0; ShortBits: 16),
    (Window:  8 * MB; RowBits: 20; Ways:  1; Lazy: 0; Nice:  32; SkipShift: 8; HashLen: 6; InsertAll: False; InsertMax: 0; ShortBits: 12),
    (Window: 16 * MB; RowBits: 18; Ways:  4; Lazy: 1; Nice:  48; SkipShift: 6; HashLen: 5; InsertAll: True; InsertMax: 4; ShortBits: 12),
    (Window: 64 * MB; RowBits: 18; Ways:  8; Lazy: 1; Nice:  64; SkipShift: 7; HashLen: 5; InsertAll: True; InsertMax: 16; ShortBits: 16),
    (Window: 64 * MB; RowBits: 18; Ways: 16; Lazy: 2; Nice:  96; SkipShift: 7; HashLen: 5; InsertAll: True; InsertMax: 16; ShortBits: 0),
    (Window: 64 * MB; RowBits: 18; Ways: 32; Lazy: 2; Nice: 128; SkipShift: 0; HashLen: 5; InsertAll: True; InsertMax: 0; ShortBits: 0),
    (Window: 64 * MB; RowBits: 18; Ways: 64; Lazy: 2; Nice: 256; SkipShift: 0; HashLen: 4; InsertAll: True; InsertMax: 0; ShortBits: 0));
  DEFAULT_LEVEL = 3;
  DEFAULT_BLOCK = 256 * KB;

{ Bytes de una fila: etiquetas (al menos 8), la cabeza (8 con relleno) y las posiciones,
  redondeado a 32 o a 64 (una fila no cruza líneas de caché innecesariamente). Una vía:
  entradas de 8 bytes (posición y los primeros 4 bytes de los datos). }
function RowBytesFor(Ways: Integer): Integer;
var
  t: Integer;
begin
  if Ways = 1 then Exit(8);
  t := Ways;
  if t < 8 then t := 8;
  Result := t + 8 + 4 * Ways;
  if Result <= 32 then Result := 32
  else Result := (Result + 63) and not 63;
end;

function ParsePlzEncParams(const Params: TStringArray): TPlzEncParams;
var
  k, L, v: Integer;
  s: string;
  m: QWord;
  HaveWin: Boolean;
  Win: QWord;
  Lv: TPlzLevel;
  Rows: Int64;
  Ov: array['a'..'z'] of Integer;   // parámetros de ajuste dados (-1 = el del nivel)
  c: Char;
  BlockMem: QWord;

  function Num(const T: string; Lo, Hi: Integer): Integer;
  begin
    Result := StrToIntDef(T, -1);
    if (Result < Lo) or (Result > Hi) then
      raise EPlzEncoder.CreateFmt('plz: bad parameter "%s"', [s]);
  end;

begin
  L := DEFAULT_LEVEL;
  HaveWin := False;
  Win := 0;
  BlockMem := 0;
  for c := 'a' to 'z' do Ov[c] := -1;
  Result := Default(TPlzEncParams);
  for k := 1 to High(Params) do
  begin
    s := LowerCase(Params[k]);
    if s = '' then Continue;
    if (s[1] in ['0'..'9']) and (StrToIntDef(s, -1) >= 0) then
      L := StrToIntDef(s, -1)
    else if (s[1] in ['0'..'9']) and ParseMem(s, m) then
    begin
      Win := m; HaveWin := True;
    end
    else if (s[1] = 'd') and ParseMem(Copy(s, 2, MaxInt), m) then
    begin
      Win := m; HaveWin := True;
    end
    else if (s[1] = 'h') and ParseMem(Copy(s, 2, MaxInt), m) then
    begin
      if (m < 4 * KB) or (m > QWord(1) shl 32) then raise EPlzEncoder.CreateFmt('plz: bad hash size "%s"', [s]);
      Result.HashMem := m;
    end
    else if (s[1] = 'b') and ParseMem(Copy(s, 2, MaxInt), m) then
    begin
      if (m < 16 * KB) or (m > PLZ_MAXBLOCK) then raise EPlzEncoder.CreateFmt('plz: bad block size "%s"', [s]);
      BlockMem := m;
    end
    else if (Length(s) > 1) and (s[1] in ['w', 'z', 'n', 'i', 'k', 'x', 'y', 'q', 'u', 'v', 'g']) then
    begin
      case s[1] of
        'w': begin v := Num(Copy(s, 2, MaxInt), 1, 64); if v and (v - 1) <> 0 then Num('-', 0, 0); end;
        'z': v := Num(Copy(s, 2, MaxInt), 0, 2);
        'n': v := Num(Copy(s, 2, MaxInt), 8, 4096);
        'i': v := Num(Copy(s, 2, MaxInt), 0, 65536);
        'k': v := Num(Copy(s, 2, MaxInt), 0, 31);
        'y': v := Num(Copy(s, 2, MaxInt), 0, 22);
        'q': v := Num(Copy(s, 2, MaxInt), 0, 2);
        'u': v := Num(Copy(s, 2, MaxInt), 0, 2);
        'v': v := Num(Copy(s, 2, MaxInt), 0, 7);
        'g': v := Num(Copy(s, 2, MaxInt), 1, 2);
      else
        v := Num(Copy(s, 2, MaxInt), 4, 7);
      end;
      Ov[s[1]] := v;
    end
    else
      raise EPlzEncoder.CreateFmt('plz: unknown parameter "%s"', [Params[k]]);
  end;
  if (L < 1) or (L > PLZ_MAXLEVEL) then raise EPlzEncoder.CreateFmt('plz: level must be 1..%d', [PLZ_MAXLEVEL]);
  Lv := LEVELS[L];
  Result.Level := L;
  if HaveWin then
  begin
    if Win < PLZ_MINWINDOW then Win := PLZ_MINWINDOW;
    if Win > PLZ_MAXWINDOW then raise EPlzEncoder.Create('plz: window too large (max 1gb)');
    Result.Window := Win;
  end
  else
    Result.Window := Lv.Window;
  Result.Ways := Lv.Ways;
  if Ov['w'] >= 0 then Result.Ways := Ov['w'];
  Result.RowBits := Lv.RowBits;
  if Result.HashMem > 0 then
  begin
    Rows := Result.HashMem div RowBytesFor(Result.Ways);
    Result.RowBits := 8;
    while (Result.RowBits < 28) and ((Int64(1) shl (Result.RowBits + 1)) <= Rows) do Inc(Result.RowBits);
  end;
  Result.Lazy := Lv.Lazy;
  if Ov['z'] >= 0 then Result.Lazy := Ov['z'];
  Result.Nice := Lv.Nice;
  if Ov['n'] >= 0 then Result.Nice := Ov['n'];
  Result.InsertAll := Lv.InsertAll;
  Result.InsertMax := Lv.InsertMax;
  if Ov['i'] >= 0 then
  begin
    Result.InsertAll := Ov['i'] >= 1;
    if Ov['i'] >= 2 then Result.InsertMax := Ov['i'] else Result.InsertMax := 0;
  end;
  Result.SkipShift := Lv.SkipShift;
  if Ov['k'] >= 0 then Result.SkipShift := Ov['k'];
  Result.HashLen := Lv.HashLen;
  if Ov['x'] >= 0 then Result.HashLen := Ov['x'];
  Result.ShortBits := Lv.ShortBits;
  if Ov['y'] >= 0 then Result.ShortBits := Ov['y'];
  Result.SplitMode := 1;
  Result.BinLazy := 0;
  if Ov['u'] >= 0 then Result.BinLazy := Ov['u'];
  Result.BinHashLen := 0;
  if Ov['v'] >= 0 then Result.BinHashLen := Ov['v'];
  Result.Bucket := 1;
  if Ov['g'] >= 0 then Result.Bucket := Ov['g'];
  if (Result.Ways <> 1) or (Result.Lazy = 0) then Result.Bucket := 1;
  if Ov['q'] >= 0 then Result.SplitMode := Ov['q'];
  Result.BlockSize := DEFAULT_BLOCK;
  if BlockMem > 0 then Result.BlockSize := BlockMem;
end;

{ Lo que se aparta del nivel, en el orden canónico (para el texto guardado). }
function TuningSuffix(const P: TPlzEncParams): string;
var
  Lv: TPlzLevel;
  I: Integer;
begin
  Lv := LEVELS[P.Level];
  Result := '';
  if P.Ways <> Lv.Ways then Result := Result + ':w' + IntToStr(P.Ways);
  if P.Lazy <> Lv.Lazy then Result := Result + ':z' + IntToStr(P.Lazy);
  if P.Nice <> Lv.Nice then Result := Result + ':n' + IntToStr(P.Nice);
  if (P.InsertAll <> Lv.InsertAll) or (P.InsertMax <> Lv.InsertMax) then
  begin
    if not P.InsertAll then I := 0 else if P.InsertMax = 0 then I := 1 else I := P.InsertMax;
    Result := Result + ':i' + IntToStr(I);
  end;
  if P.SkipShift <> Lv.SkipShift then Result := Result + ':k' + IntToStr(P.SkipShift);
  if P.HashLen <> Lv.HashLen then Result := Result + ':x' + IntToStr(P.HashLen);
  if P.ShortBits <> Lv.ShortBits then Result := Result + ':y' + IntToStr(P.ShortBits);
  if P.SplitMode <> 1 then Result := Result + ':q' + IntToStr(P.SplitMode);
  if P.BinLazy <> 0 then Result := Result + ':u' + IntToStr(P.BinLazy);
  if P.BinHashLen <> 0 then Result := Result + ':v' + IntToStr(P.BinHashLen);
  if P.Bucket <> 1 then Result := Result + ':g' + IntToStr(P.Bucket);
  if P.BlockSize <> DEFAULT_BLOCK then Result := Result + ':b' + IntToStr(P.BlockSize div KB) + 'kb';
end;

function PlzEncAvailable(const Stage: string): Boolean;
begin
  try
    ParsePlzEncParams(Stage.Split([':']));
    Result := True;
  except
    on EPlzEncoder do Result := False;
  end;
end;

function PlzDictionary(const Params: TStringArray): Int64;
begin
  try
    Result := ParsePlzEncParams(Params).Window;
  except
    on EPlzEncoder do Result := -1;
  end;
end;

function HashBytes(const P: TPlzEncParams): Int64;
begin
  Result := (Int64(1) shl P.RowBits) * RowBytesFor(P.Ways);
end;

function PlzEncMemory(const P: TPlzEncParams; Streaming: Boolean): Int64;
begin
  Result := HashBytes(P) * P.Bucket + 3 * DEFAULT_BLOCK;
  if P.ShortBits > 0 then Inc(Result, Int64(8) shl P.ShortBits);
  if Streaming then Inc(Result, 2 * Int64(P.Window) + 16 * MB);
end;

function ShowMemP(M: Int64): string;
begin
  if (M >= MB) and (M mod MB = 0) then Result := IntToStr(M div MB) + 'mb'
  else if (M >= KB) and (M mod KB = 0) then Result := IntToStr(M div KB) + 'kb'
  else Result := IntToStr(M) + 'b';
end;

function PlzCanon(const Params: TStringArray; Limit, MemLim: Int64): string;
var
  P: TPlzEncParams;
  W, H, DefH: Int64;
begin
  try
    P := ParsePlzEncParams(Params);
  except
    on EPlzEncoder do Exit(string.Join(':', Params));
  end;
  W := P.Window;
  // La ventana no pasa del tamaño de los datos (redondeado arriba a 64 KB)
  if (Limit > 0) and (W > Limit) then
  begin
    W := (Limit + 65535) and not Int64(65535);
    if W < PLZ_MINWINDOW then W := PLZ_MINWINDOW;
  end;
  H := HashBytes(P);
  DefH := (Int64(1) shl LEVELS[P.Level].RowBits) * RowBytesFor(P.Ways);
  if P.Ways <> LEVELS[P.Level].Ways then DefH := -1;   // con w<n>, el hash siempre explícito
  // -lc: ventana (streaming, ~1,5 veces) + hash dentro del límite
  if MemLim > 0 then
    while (W * 3 div 2 + H > MemLim) and ((W > 256 * KB) or (H > 64 * KB)) do
      if (H >= W) and (H > 64 * KB) then H := H div 2
      else if W > 256 * KB then W := W div 2
      else H := H div 2;
  Result := 'plz:' + IntToStr(P.Level) + ':' + ShowMemP(W);
  if H <> DefH then Result := Result + ':h' + ShowMemP(H);
  Result := Result + TuningSuffix(P);
end;

{ ---- escritor de bits ---- }

procedure TPlzBitWriter.Init(Cap: SizeInt);
begin
  if Length(Data) < Cap + 16 then SetLength(Data, Cap + 16);
  Len := 0;
  Acc := 0;
  N := 0;
end;

procedure TPlzBitWriter.Ensure(Extra: SizeInt);
begin
  if Len + Extra + 16 > Length(Data) then SetLength(Data, (Len + Extra + 16) * 2);
end;

procedure TPlzBitWriter.Put(V: LongWord; Bits: LongWord);
begin
  Acc := Acc or (QWord(V) shl N);
  Inc(N, Bits);
  if N >= 32 then
  begin
    PLongWord(@Data[Len])^ := NtoLE(LongWord(Acc));
    Inc(Len, 4);
    Acc := Acc shr 32;
    Dec(N, 32);
  end;
end;

procedure TPlzBitWriter.Flush;
begin
  while N > 0 do
  begin
    Data[Len] := Byte(Acc);
    Inc(Len);
    Acc := Acc shr 8;
    if N >= 8 then Dec(N, 8) else N := 0;
  end;
  Acc := 0;
end;


{ ---- descripción de tablas ---- }

type
  TClSyms = record
    Syms, Ext: array[0..300] of Byte;
    NS, Cnt: Integer;
    Lens: TPlzLens;
    Codes: array[0..CL_N - 1] of Word;
    Single: Boolean;
  end;

procedure BuildClSyms(const Lens: TPlzLens; N: Integer; out C: TClSyms);
var
  i, r, k, Prev, Used: Integer;
  Freq: array[0..CL_N - 1] of LongWord;
begin
  C.Cnt := N;
  while (C.Cnt > 1) and (Lens[C.Cnt - 1] = 0) do Dec(C.Cnt);
  C.NS := 0;
  i := 0;
  Prev := -1;
  while i < C.Cnt do
  begin
    r := 1;
    while (i + r < C.Cnt) and (Lens[i + r] = Lens[i]) do Inc(r);
    if Lens[i] = 0 then
    begin
      if r >= 11 then
      begin
        if r > 138 then r := 138;
        C.Syms[C.NS] := 14; C.Ext[C.NS] := r - 11;
      end
      else if r >= 3 then
      begin
        C.Syms[C.NS] := 13; C.Ext[C.NS] := r - 3;
      end
      else
      begin
        C.Syms[C.NS] := 0; C.Ext[C.NS] := 0; r := 1;
      end;
      Inc(C.NS);
      Prev := 0;
      Inc(i, r);
    end
    else if (Lens[i] = Prev) and (r >= 3) then
    begin
      if r > 6 then r := 6;
      C.Syms[C.NS] := 12; C.Ext[C.NS] := r - 3;
      Inc(C.NS);
      Inc(i, r);
    end
    else
    begin
      C.Syms[C.NS] := Lens[i]; C.Ext[C.NS] := 0;
      Inc(C.NS);
      Prev := Lens[i];
      Inc(i);
    end;
  end;
  FillChar(Freq, SizeOf(Freq), 0);
  for k := 0 to C.NS - 1 do Inc(Freq[C.Syms[k]]);
  PlzHuffLens(Freq, CL_N, CL_MAXLEN, C.Lens);
  PlzCanonCodes(C.Lens, CL_N, C.Codes);
  Used := 0;
  for k := 0 to CL_N - 1 do if C.Lens[k] > 0 then Inc(Used);
  C.Single := Used = 1;
end;

function ClExtraBits(Sym: Integer): Integer; inline;
begin
  case Sym of
    12: Result := 2;
    13: Result := 3;
    14: Result := 7;
  else
    Result := 0;
  end;
end;

function TableDescBits(const Lens: TPlzLens; N: Integer): Int64;
var
  C: TClSyms;
  k: Integer;
begin
  BuildClSyms(Lens, N, C);
  Result := 8 + 3 * CL_N;
  for k := 0 to C.NS - 1 do
  begin
    if not C.Single then Inc(Result, C.Lens[C.Syms[k]]);
    Inc(Result, ClExtraBits(C.Syms[k]));
  end;
end;

procedure WriteTableLens(var BW: TPlzBitWriter; const Lens: TPlzLens; N: Integer);
var
  C: TClSyms;
  k: Integer;
begin
  BuildClSyms(Lens, N, C);
  BW.Ensure(64 + C.NS * 4);
  BW.Put(C.Cnt - 1, 8);
  for k := 0 to CL_N - 1 do BW.Put(C.Lens[k], 3);
  for k := 0 to C.NS - 1 do
  begin
    if not C.Single then BW.Put(C.Codes[C.Syms[k]], C.Lens[C.Syms[k]]);
    if ClExtraBits(C.Syms[k]) > 0 then BW.Put(C.Ext[k], ClExtraBits(C.Syms[k]));
  end;
end;

{ Largos efectivos y códigos de una tabla (0 bits si tiene un solo símbolo). }
procedure MakeTabCodes(const Lens: TPlzLens; N: Integer; out T: TPlzTabCodes);
var
  i, Used: Integer;
begin
  T.Lens := Lens;
  PlzCanonCodes(Lens, N, T.Codes);
  Used := 0;
  for i := 0 to N - 1 do if Lens[i] > 0 then Inc(Used);
  if Used = 1 then
    for i := 0 to N - 1 do begin T.Lens[i] := 0; T.Codes[i] := 0; end;
end;

function DataBits(const Freq: array of LongWord; const Lens: TPlzLens; N: Integer): Int64;
var
  i, Used: Integer;
begin
  Result := 0;
  Used := 0;
  for i := 0 to N - 1 do if Lens[i] > 0 then Inc(Used);
  for i := 0 to N - 1 do
    if Freq[i] > 0 then
    begin
      if Lens[i] = 0 then Exit(High(Int64) div 4);   // el símbolo no está en la tabla
      if Used > 1 then Inc(Result, Int64(Freq[i]) * Lens[i]);
    end;
end;

{ ---- coincidencias ---- }

function MatchLen(A, B, AEnd: PByte): SizeInt; inline;
var
  S: PByte;
  X: QWord;
begin
  S := A;
  while A + 8 <= AEnd do
  begin
    X := PQWord(A)^ xor PQWord(B)^;
    if X <> 0 then Exit(A - S + SizeInt(BsfQWord(X) shr 3));
    Inc(A, 8); Inc(B, 8);
  end;
  while (A < AEnd) and (A^ = B^) do begin Inc(A); Inc(B); end;
  Result := A - S;
end;

function HighBit(V: LongWord): LongWord; inline;
begin
  Result := BsrDWord(V);
end;

{ ---- búsqueda del voraz de una vía ---- }

type
  { Estado de PlzScanFast1 (los offsets los usa el ensamblador) }
  TPlzScan = record
    Ip, ILimit, Base: PByte;
    T64: PQWord;
    Cur0, Win, R0, Miss, H, Sh, HSh, Skip, Dist: LongWord;
    TS: PQWord;               // tabla corta (PlzScanDual)
    SSh, Dist2: LongWord;     // su desplazamiento y la distancia de su candidato (0 = no hay)
  end;

type
  { Estado de PlzGreedy (el voraz de una vía entero en ensamblador; offsets usados por el asm) }
  TPlzGreedy = record
    Ip, ILimit, IEnd, Base, Anchor, MStart, Lit: PByte;
    Seq: Pointer;
    T64, TS: PQWord;
    CurLen: Int64;
    Cur0, Win, Sh, HSh, SSh, Skip, Rep0, Rep1, Rep2, Rep3, CurDist, Dist2: LongWord;
  end;

const
  PLZ_SEQSIZE = SizeOf(TPlzSeq);

{$IF defined(CPUX86_64) and not defined(PARC_NOASM)}
{$DEFINE PLZ_ASM}
{$I parc_plz_x64.inc}
{$ASMMODE DEFAULT}
{$ELSE}
{ Recorre posiciones actualizando la tabla directa hasta que el rep0 (1) o la entrada de la
  tabla (2, distancia en Dist) coinciden en 4 bytes, o hasta ILimit (0). }
function PlzScanFast1(var S: TPlzScan): LongInt;
var
  Ip, Base: PByte;
  T64: PQWord;
  V4, H, D, Rel, Miss: LongWord;
  E: QWord;
begin
  Ip := S.Ip; H := S.H; Miss := S.Miss; Base := S.Base; T64 := S.T64;
  repeat
    V4 := PLongWord(Ip)^;
    E := T64[H];
    Rel := LongWord(PtrUInt(Ip - Base)) + S.Cur0;
    T64[H] := (QWord(V4) shl 32) or Rel;
    if (S.R0 <= LongWord(PtrUInt(Ip - Base))) and (PLongWord(Ip - S.R0)^ = V4) then
    begin
      Result := 1;
      Break;
    end;
    D := Rel - LongWord(E);
    if (LongWord(E shr 32) = V4) and (LongWord(E) <> 0) and (D <= S.Win) then
    begin
      S.Dist := D;
      Result := 2;
      Break;
    end;
    Inc(Miss);
    Inc(Ip, 1 + (Miss shr S.Skip));
    if Ip >= S.ILimit then
    begin
      Result := 0;
      Break;
    end;
    H := LongWord(((PQWord(Ip)^ shl S.HSh) * PRIME64) shr 32) shr S.Sh;
    prefetch(T64[H]);
  until False;
  S.Ip := Ip; S.H := H; S.Miss := Miss;
end;

{ Como PlzScanFast1, también con la tabla corta (hash de 4 bytes): devuelve 2 si la principal o la
  corta coinciden en 4 bytes (Dist y Dist2, 0 = ese candidato no está). }
function PlzScanDual(var S: TPlzScan): LongInt;
var
  Ip, Base: PByte;
  T64, TS: PQWord;
  V4, H, HS, D, D2, Rel, Miss: LongWord;
  E, ES: QWord;
begin
  Ip := S.Ip; H := S.H; Miss := S.Miss; Base := S.Base; T64 := S.T64; TS := S.TS;
  repeat
    V4 := PLongWord(Ip)^;
    HS := LongWord(V4 * LongWord(2654435761)) shr S.SSh;
    E := T64[H];
    ES := TS[HS];
    Rel := LongWord(PtrUInt(Ip - Base)) + S.Cur0;
    T64[H] := (QWord(V4) shl 32) or Rel;
    TS[HS] := (QWord(V4) shl 32) or Rel;
    if (S.R0 <= LongWord(PtrUInt(Ip - Base))) and (PLongWord(Ip - S.R0)^ = V4) then
    begin
      Result := 1;
      Break;
    end;
    D := Rel - LongWord(E);
    if not ((LongWord(E shr 32) = V4) and (LongWord(E) <> 0) and (D <= S.Win)) then D := 0;
    D2 := Rel - LongWord(ES);
    if not ((LongWord(ES shr 32) = V4) and (LongWord(ES) <> 0) and (D2 <= S.Win)) then D2 := 0;
    if (D or D2) <> 0 then
    begin
      S.Dist := D;
      S.Dist2 := D2;
      Result := 2;
      Break;
    end;
    Inc(Miss);
    Inc(Ip, 1 + (Miss shr S.Skip));
    if Ip >= S.ILimit then
    begin
      Result := 0;
      Break;
    end;
    H := LongWord(((PQWord(Ip)^ shl S.HSh) * PRIME64) shr 32) shr S.Sh;
    prefetch(T64[H]);
  until False;
  S.Ip := Ip; S.H := H; S.Miss := Miss;
end;
{$ENDIF}

{ ---- TPlzEngine ---- }

{ Filas del hash que usa de verdad el motor: con una ventana chica (datos chicos: la ventana
  ya viene limitada al bloque) no hace falta un hash más grande que ~2 entradas por posición;
  reservarlo y ponerlo en cero costaba más que comprimir. Depende sólo de los parámetros. }
function EffRowBits(const P: TPlzEncParams): Integer;
begin
  Result := P.RowBits;
  while (Result > 12) and ((Int64(1) shl (Result - 1)) * P.Ways >= 2 * Int64(P.Window)) do Dec(Result);
end;

constructor TPlzEngine.Create(const AP: TPlzEncParams);
var
  Rows: SizeInt;
begin
  inherited Create;
  P := AP;
  P.RowBits := EffRowBits(AP);
  Rows := SizeInt(1) shl P.RowBits;
  FOne := P.Ways = 1;
  if FOne then
    SetLength(FTab64, Rows * P.Bucket)
  else
  begin
    FRowBytes := RowBytesFor(P.Ways);
    SetLength(FRowMem, Rows * FRowBytes + 64);
    FRows := PByte((PtrUInt(@FRowMem[0]) + 63) and not PtrUInt(63));
    FTagGroups := (P.Ways + 7) div 8;
    FHeadOff := FTagGroups * 8;
    FPosOff := FHeadOff + 8;
    if P.Ways >= 64 then FWayFull := High(QWord) else FWayFull := (QWord(1) shl P.Ways) - 1;
  end;
  FWayMask := P.Ways - 1;
  FRowShift := 32 - P.RowBits;
  if P.ShortBits > 0 then
  begin
    SetLength(FTabS, SizeInt(1) shl P.ShortBits);
    FShortSh := 32 - P.ShortBits;
  end;
  if P.RowBits <= 24 then FTagShift := 24 - P.RowBits else FTagShift := 0;
  SetLength(FSeq, P.BlockSize div PLZ_MINMATCH + 16);
  SetLength(FLit, P.BlockSize + 2 * PLZ_PAD);
  SetLength(FPay, P.BlockSize + P.BlockSize div 2 + 1024);
end;

procedure TPlzEngine.ResetTables;
begin
  if Length(FRowMem) > 0 then FillChar(FRowMem[0], Length(FRowMem), 0);
  if Length(FTab64) > 0 then FillChar(FTab64[0], Length(FTab64) * SizeOf(QWord), 0);
  if Length(FTabS) > 0 then FillChar(FTabS[0], Length(FTabS) * SizeOf(QWord), 0);
end;

procedure TPlzEngine.StartStream;
var
  i: Integer;
begin
  ResetTables;
  FRep[0] := 1; FRep[1] := 2; FRep[2] := 3; FRep[3] := 4;
  for i := 0 to 4 do FHavePrev[i] := False;
  FBufRel := 1;
  FCur := 1;
  FEnd := 1;
  FInsNext := 1;
  FOutLen := 0;
  FBuf := nil;
  // Encabezado: versión y ventana
  Out8(PLZ_VERSION);
  Out8(Byte(P.Window)); Out8(Byte(P.Window shr 8)); Out8(Byte(P.Window shr 16)); Out8(Byte(P.Window shr 24));
end;

procedure TPlzEngine.Grow(Need: SizeInt);
var
  n: SizeInt;
begin
  if FOutLen + Need <= Length(FOut) then Exit;
  n := Length(FOut) * 2;
  if n < FOutLen + Need then n := FOutLen + Need;
  if n < 64 * KB then n := 64 * KB;
  SetLength(FOut, n);
end;

procedure TPlzEngine.Out8(B: Byte);
begin
  if FOutLen >= Length(FOut) then Grow(1);
  FOut[FOutLen] := B;
  Inc(FOutLen);
end;

procedure TPlzEngine.OutVInt(V: LongWord);
begin
  while V >= $80 do
  begin
    Out8(Byte(V) or $80);
    V := V shr 7;
  end;
  Out8(Byte(V));
end;

procedure TPlzEngine.OutBytes(Src: PByte; N: SizeInt);
begin
  if N <= 0 then Exit;
  Grow(N);
  Move(Src^, FOut[FOutLen], N);
  Inc(FOutLen, N);
end;

procedure TPlzEngine.ClearOut;
begin
  FOutLen := 0;
end;

function TPlzEngine.HashOf(Ip: PByte; out Tag: Byte): LongWord;
var
  H: LongWord;
begin
  // los HashLen bytes de Ip arriba de un QWord, por un primo de 64 bits: los 32 bits altos
  H := LongWord(((PQWord(Ip)^ shl FHashShl) * PRIME64) shr 32);
  Tag := Byte(H shr FTagShift);
  Result := H shr FRowShift;
end;

procedure TPlzEngine.Insert(Ip: PByte; Cur: LongWord);
var
  Row, Hd: LongWord;
  Tag: Byte;
  R: PByte;
begin
  Row := HashOf(Ip, Tag);
  if FOne then
  begin
    if P.Bucket = 2 then
    begin
      FTab64[2 * Row + 1] := FTab64[2 * Row];
      FTab64[2 * Row] := (QWord(PLongWord(Ip)^) shl 32) or Cur;
    end
    else
      FTab64[Row] := (QWord(PLongWord(Ip)^) shl 32) or Cur;
    if FShortOn then
      FTabS[LongWord(PLongWord(Ip)^ * LongWord(2654435761)) shr FShortSh] := (QWord(PLongWord(Ip)^) shl 32) or Cur;
    Exit;
  end;
  R := FRows + SizeInt(Row) * FRowBytes;
  Hd := (R[FHeadOff] - 1) and FWayMask;
  R[FHeadOff] := Hd;
  R[Hd] := Tag;
  PLongWord(R + FPosOff)[Hd] := Cur;
  if FShortOn then
    FTabS[LongWord(PLongWord(Ip)^ * LongWord(2654435761)) shr FShortSh] := (QWord(PLongWord(Ip)^) shl 32) or Cur;
end;

{ Busca en la fila de Ip un match más largo que Best (hasta IEnd) e inserta Ip. Devuelve el
  largo (o Best si no hay uno mejor) y en Dist su distancia. }
function TPlzEngine.FindAndInsert(Ip, IEnd: PByte; Cur: LongWord; Best: SizeInt; out Dist: LongWord): SizeInt;
var
  Row, Hd, Idx, k, C, D: LongWord;
  Tag: Byte;
  Cp, R: PByte;
  L, MaxL: SizeInt;
  E, E2, Bc, M, V, F: QWord;
  g: Integer;
  Pos: PLongWord;
begin
  Dist := 0;
  Row := HashOf(Ip, Tag);
  if FOne then
  begin
    if P.Bucket = 2 then
    begin
      // dos entradas por hash, la más nueva primero
      E := FTab64[2 * Row];
      E2 := FTab64[2 * Row + 1];
      FTab64[2 * Row + 1] := E;
      FTab64[2 * Row] := (QWord(PLongWord(Ip)^) shl 32) or Cur;
      D := Cur - LongWord(E);
      if (LongWord(E) <> 0) and (D <= P.Window) and (LongWord(E shr 32) = PLongWord(Ip)^) then
      begin
        L := 4 + MatchLen(Ip + 4, Ip - D + 4, IEnd);
        if L > Best then begin Best := L; Dist := D; end;
      end;
      D := Cur - LongWord(E2);
      // la segunda entrada sólo se mira en los bloques binarios (en texto cuesta más de lo que da)
      if FBin and (LongWord(E2) <> 0) and (D <= P.Window) and (LongWord(E2 shr 32) = PLongWord(Ip)^) then
      begin
        L := 4 + MatchLen(Ip + 4, Ip - D + 4, IEnd);
        if L > Best then begin Best := L; Dist := D; end;
      end;
    end
    else
    begin
      E := FTab64[Row];
      FTab64[Row] := (QWord(PLongWord(Ip)^) shl 32) or Cur;
      D := Cur - LongWord(E);
      if (LongWord(E) <> 0) and (D <= P.Window) and (LongWord(E shr 32) = PLongWord(Ip)^) then
      begin
        L := 4 + MatchLen(Ip + 4, Ip - D + 4, IEnd);
        if L > Best then begin Best := L; Dist := D; end;
      end;
    end;
    if FShortOn then
    begin
      // tabla corta (4 bytes): gana si es más larga, o igual de larga y más cerca
      Row := LongWord(PLongWord(Ip)^ * LongWord(2654435761)) shr FShortSh;
      E := FTabS[Row];
      FTabS[Row] := (QWord(PLongWord(Ip)^) shl 32) or Cur;
      D := Cur - LongWord(E);
      if (LongWord(E) <> 0) and (D <= P.Window) and (D <> Dist) and (LongWord(E shr 32) = PLongWord(Ip)^) then
      begin
        L := 4 + MatchLen(Ip + 4, Ip - D + 4, IEnd);
        if (L > Best) or ((L = Best) and (Dist <> 0) and (D < Dist)) then begin Best := L; Dist := D; end;
      end;
    end;
    Exit(Best);
  end;
  R := FRows + SizeInt(Row) * FRowBytes;
  Hd := R[FHeadOff];
  MaxL := IEnd - Ip;
  // Candidatos con la misma etiqueta: comparación de 8 etiquetas a la vez (SWAR); un falso
  // positivo sólo cuesta mirar los datos. Bit k de M = entrada física k.
  Bc := QWord(Tag) * QWord($0101010101010101);
  M := 0;
  for g := 0 to FTagGroups - 1 do
  begin
    V := PQWord(R + 8 * g)^ xor Bc;
    F := (V - QWord($0101010101010101)) and not V and QWord($8080808080808080);
    M := M or ((((F shr 7) * QWord($0102040810204080)) shr 56) shl (8 * g));
  end;
  M := M and FWayFull;
  // en orden de recencia: la más nueva es la de la cabeza
  if Hd <> 0 then M := ((M shr Hd) or (M shl (LongWord(P.Ways) - Hd))) and FWayFull;
  Pos := PLongWord(R + FPosOff);
  while M <> 0 do
  begin
    k := BsfQWord(M);
    M := M and (M - 1);
    Idx := (Hd + k) and FWayMask;
    C := Pos[Idx];
    if C = 0 then Break;
    D := Cur - C;
    if D > P.Window then Break;
    Cp := Ip - D;
    if Best >= MaxL then Break;
    if Cp[Best] <> Ip[Best] then Continue;
    L := MatchLen(Ip, Cp, IEnd);
    if L > Best then
    begin
      Best := L;
      Dist := D;
      if L >= P.Nice then Break;
    end;
  end;
  Hd := (Hd - 1) and FWayMask;
  R[FHeadOff] := Hd;
  R[Hd] := Tag;
  Pos[Hd] := Cur;
  if FShortOn then
  begin
    Row := LongWord(PLongWord(Ip)^ * LongWord(2654435761)) shr FShortSh;
    E := FTabS[Row];
    FTabS[Row] := (QWord(PLongWord(Ip)^) shl 32) or Cur;
    D := Cur - LongWord(E);
    if (LongWord(E) <> 0) and (D <= P.Window) and (D <> Dist) and (LongWord(E shr 32) = PLongWord(Ip)^) then
    begin
      L := 4 + MatchLen(Ip + 4, Ip - D + 4, IEnd);
      if (L > Best) or ((L = Best) and (Dist <> 0) and (D < Dist)) then begin Best := L; Dist := D; end;
    end;
  end;
  Result := Best;
end;

procedure TPlzEngine.AddLits(Lit: PByte; N: SizeInt);
begin
  if N <= 0 then Exit;
  Move(Lit^, FLit[FNLit], N);
  Inc(FNLit, N);
end;

{ Agrega una secuencia en forma cruda: LL, ML y, en OC, el rep usado (0..3) o 4 con la
  distancia en OX; los códigos los calcula FinishSeqs para todo el bloque. Los reps se
  actualizan acá (el parser los usa). }
procedure TPlzEngine.AddSeq(Lit: PByte; LL: LongWord; Dist: LongWord; ML: LongWord);
var
  S: ^TPlzSeq;
  R0, R1, R2: LongWord;
begin
  if LL > 0 then
  begin
    if (LL <= 16) and (LL + ML >= 16) then
    begin
      // los 16 bytes leídos están antes del final del match (dentro de los datos)
      PQWord(@FLit[FNLit])^ := PQWord(Lit)^;
      PQWord(@FLit[FNLit + 8])^ := PQWord(Lit + 8)^;
    end
    else
      Move(Lit^, FLit[FNLit], LL);
    Inc(FNLit, LL);
  end;
  S := @FSeq[FNSeq];
  Inc(FNSeq);
  S^.LL := LL;
  S^.ML := ML;
  R0 := FRep[0];
  if Dist = R0 then
    S^.OC := 0
  else
  begin
    R1 := FRep[1];
    FRep[0] := Dist;
    FRep[1] := R0;
    if Dist = R1 then
      S^.OC := 1
    else
    begin
      R2 := FRep[2];
      FRep[2] := R1;
      if Dist = R2 then
        S^.OC := 2
      else
      begin
        if Dist = FRep[3] then S^.OC := 3
        else
        begin
          S^.OC := 4;
          S^.OX := Dist;
        end;
        FRep[3] := R2;
      end;
    end;
  end;
end;

{ Los códigos de las secuencias [Lo, Hi) (token, LLX, MLX, slot y bits extra del offset). }
procedure TPlzEngine.FinishSeqs(Lo, Hi: SizeInt);
var
  S: ^TPlzSeq;
  j: SizeInt;
  NB, X, LLt, MLt, LL, ML: LongWord;
begin
  for j := Lo to Hi - 1 do
  begin
    S := @FSeq[j];
    LL := S^.LL;
    ML := S^.ML;
    LLt := LL;
    if LLt >= 7 then
    begin
      LLt := 7;
      S^.LXC := PlzLenCode(LL - 7, NB, X);
      S^.LXN := NB; S^.LXV := X;
    end;
    MLt := ML - PLZ_MINMATCH;
    if MLt >= 15 then
    begin
      MLt := 15;
      S^.MXC := PlzLenCode(ML - PLZ_MINMATCH - 15, NB, X);
      S^.MXN := NB; S^.MXV := X;
    end;
    S^.Tok := LLt * 16 + MLt;
    if S^.OC < 4 then
    begin
      S^.ONB := 0; S^.OX := 0;
    end
    else
    begin
      // slot de la distancia d = Dist - 1 (ver PlzOfsSlot)
      X := S^.OX - 1;
      if X < 4 then
      begin
        S^.OC := 4 + X; S^.ONB := 0; S^.OX := 0;
      end
      else
      begin
        NB := BsrDWord(X);
        S^.OC := 4 + 2 * NB + ((X shr (NB - 1)) and 1);
        S^.ONB := NB - 1;
        S^.OX := X and ((LongWord(1) shl (NB - 1)) - 1);
      end;
    end;
  end;
end;

{ Match encontrado en el voraz de una vía (fuera del lazo, para que el lazo de los fallos
  quede con pocas variables): extiende hacia atrás, agrega la secuencia, inserta un par de
  posiciones del match y devuelve dónde sigue. }
function TPlzEngine.FastMatch(Ip: PByte; Dist: LongWord; L: SizeInt; ILimit: PByte): PByte;
var
  Cp, q, Base: PByte;
  H2, Sh, HSh, Cur0: LongWord;
begin
  Base := FBuf;
  Cur0 := FBufRel;
  Cp := Ip - Dist;
  while (Ip > FAnchor) and (Cp > Base) and (Ip[-1] = Cp[-1]) do
  begin
    Dec(Ip); Dec(Cp); Inc(L);
  end;
  AddSeq(FAnchor, Ip - FAnchor, Dist, L);
  q := Ip + L;
  Sh := FRowShift;
  HSh := 64 - 8 * P.HashLen;
  Cp := Ip + 2;
  if Cp < ILimit then
  begin
    H2 := LongWord(((PQWord(Cp)^ shl HSh) * PRIME64) shr 32) shr Sh;
    FTab64[H2] := (QWord(PLongWord(Cp)^) shl 32) or (LongWord(Cp - Base) + Cur0);
  end;
  Cp := q - 1;
  if (Cp > Ip + 2) and (Cp < ILimit) then
  begin
    H2 := LongWord(((PQWord(Cp)^ shl HSh) * PRIME64) shr 32) shr Sh;
    FTab64[H2] := (QWord(PLongWord(Cp)^) shl 32) or (LongWord(Cp - Base) + Cur0);
  end;
  if FShortOn then
  begin
    Cp := q - 2;
    if (Cp > Ip) and (Cp < ILimit) then
    begin
      H2 := LongWord(PLongWord(Cp)^ * LongWord(2654435761)) shr FShortSh;
      FTabS[H2] := (QWord(PLongWord(Cp)^) shl 32) or (LongWord(Cp - Base) + Cur0);
    end;
  end;
  FAnchor := q;
  Result := q;
end;

{ Voraz con tabla directa (una vía), el lazo más usado de los niveles rápidos. La búsqueda
  hasta el próximo candidato (PlzScanFast1) está en ensamblador en x86-64; el match se procesa
  en Pascal (FastMatch). }
{ ¿Conviene la tabla corta en este bloque? Datos binarios con estructura (fuentes, imágenes,
  audio) repiten tramos cortos que el hash de 5-6 bytes no ve; en texto sólo cuesta tiempo.
  Medida barata y determinista sobre una muestra del bloque: la proporción de bytes que no son
  texto (fuera de 9..13 y 32..126). }
function TPlzEngine.WantShort(Ip, IEnd: PByte): Boolean;
var
  n, bin: SizeInt;
  c: Byte;
begin
  n := 0; bin := 0;
  while Ip < IEnd do
  begin
    c := Ip^;
    if (c > 126) or ((c < 32) and not (c in [9..13])) then Inc(bin);
    Inc(n);
    Inc(Ip, 251);
  end;
  Result := (n > 0) and (bin * 8 > n);   // más de 1/8 binario
end;

{ Voraz de una vía con además la tabla corta (4 bytes): en cada posición, el mejor de rep0, la
  tabla principal y la corta. }
procedure TPlzEngine.ParseFastDual(Ip, IEnd: PByte);
var
  S: TPlzScan;
  L, LS: SizeInt;
  r: LongInt;
  Dist: LongWord;
begin
  S.Base := FBuf;
  S.Cur0 := FBufRel;
  S.Ip := Ip;
  S.ILimit := IEnd - 8;
  S.T64 := @FTab64[0];
  S.TS := @FTabS[0];
  S.SSh := FShortSh;
  S.Win := P.Window;
  S.Sh := FRowShift;
  S.HSh := 64 - 8 * P.HashLen;
  S.Skip := P.SkipShift;
  if S.Skip = 0 then S.Skip := 31;
  S.Miss := 0;
  S.Dist := 0; S.Dist2 := 0;
  while S.Ip < S.ILimit do
  begin
    S.H := LongWord(((PQWord(S.Ip)^ shl S.HSh) * PRIME64) shr 32) shr S.Sh;
    S.R0 := FRep[0];
    r := PlzScanDual(S);
    if r = 0 then Break;
    if r = 1 then
    begin
      L := 4 + MatchLen(S.Ip + 4, S.Ip - S.R0 + 4, IEnd);
      Dist := S.R0;
    end
    else
    begin
      L := 0; Dist := 0;
      if S.Dist <> 0 then
      begin
        L := 4 + MatchLen(S.Ip + 4, S.Ip - S.Dist + 4, IEnd);
        Dist := S.Dist;
      end;
      if (S.Dist2 <> 0) and (S.Dist2 <> S.Dist) then
      begin
        LS := 4 + MatchLen(S.Ip + 4, S.Ip - S.Dist2 + 4, IEnd);
        // la corta gana si es más larga, o igual de larga y más cerca
        if (LS > L) or ((LS = L) and (S.Dist2 < Dist)) then
        begin
          L := LS;
          Dist := S.Dist2;
        end;
      end;
    end;
    S.Ip := FastMatch(S.Ip, Dist, L, S.ILimit);
    S.Miss := 0;
  end;
  AddLits(FAnchor, IEnd - FAnchor);
end;

{ Voraz con tabla directa (una vía), el lazo más usado de los niveles rápidos. La búsqueda
  hasta el próximo candidato (PlzScanFast1) está en ensamblador en x86-64; el match se procesa
  en Pascal (FastMatch). }
{$IFDEF PLZ_ASM}
procedure TPlzEngine.RunGreedyAsm(Ip, IEnd: PByte);
var
  G: TPlzGreedy;
begin
  G.Ip := Ip;
  G.IEnd := IEnd;
  G.ILimit := IEnd - 8;
  G.Base := FBuf;
  G.Anchor := FAnchor;
  G.Lit := @FLit[FNLit];
  G.Seq := @FSeq[FNSeq];
  G.T64 := @FTab64[0];
  if FShortOn then G.TS := @FTabS[0] else G.TS := nil;
  G.Cur0 := FBufRel;
  G.Win := P.Window;
  G.Sh := FRowShift;
  G.HSh := 64 - 8 * P.HashLen;
  G.SSh := FShortSh;
  G.Skip := P.SkipShift;
  if G.Skip = 0 then G.Skip := 31;
  G.Rep0 := FRep[0]; G.Rep1 := FRep[1]; G.Rep2 := FRep[2]; G.Rep3 := FRep[3];
  G.CurLen := 0; G.CurDist := 0; G.Dist2 := 0; G.MStart := nil;
  PlzGreedy(G);
  FRep[0] := G.Rep0; FRep[1] := G.Rep1; FRep[2] := G.Rep2; FRep[3] := G.Rep3;
  FNLit := G.Lit - PByte(@FLit[0]);
  FNSeq := (PByte(G.Seq) - PByte(@FSeq[0])) div PLZ_SEQSIZE;
  FAnchor := G.Anchor;
  AddLits(FAnchor, IEnd - FAnchor);
end;
{$ENDIF}

procedure TPlzEngine.ParseFast1(BS, BE: LongWord);
var
  S: TPlzScan;
  IEnd: PByte;
  L: SizeInt;
  r: LongInt;
begin
  S.Base := FBuf;
  S.Cur0 := FBufRel;
  S.Ip := FBuf + (BS - FBufRel);
  IEnd := FBuf + (BE - FBufRel);
  S.ILimit := IEnd - 8;
  FAnchor := S.Ip;
  S.T64 := @FTab64[0];
  S.Win := P.Window;
  S.Sh := FRowShift;
  S.HSh := 64 - 8 * P.HashLen;
  S.Skip := P.SkipShift;
  if S.Skip = 0 then S.Skip := 31;
  S.Miss := 0;
  S.Dist := 0;
  FShortOn := (Length(FTabS) > 0) and FBin;
  {$IFDEF PLZ_ASM}
  RunGreedyAsm(S.Ip, IEnd);
  Exit;
  {$ENDIF}
  if FShortOn then
  begin
    ParseFastDual(S.Ip, IEnd);
    Exit;
  end;
  while S.Ip < S.ILimit do
  begin
    S.H := LongWord(((PQWord(S.Ip)^ shl S.HSh) * PRIME64) shr 32) shr S.Sh;
    S.R0 := FRep[0];
    r := PlzScanFast1(S);
    if r = 0 then Break;
    if r = 1 then
    begin
      L := 4 + MatchLen(S.Ip + 4, S.Ip - S.R0 + 4, IEnd);
      S.Ip := FastMatch(S.Ip, S.R0, L, S.ILimit);
    end
    else
    begin
      L := 4 + MatchLen(S.Ip + 4, S.Ip - S.Dist + 4, IEnd);
      S.Ip := FastMatch(S.Ip, S.Dist, L, S.ILimit);
    end;
    S.Miss := 0;
  end;
  AddLits(FAnchor, IEnd - FAnchor);
end;

{ Voraz, con aceleración: sin matches el paso crece (1 + fallos shr SkipShift). }
procedure TPlzEngine.ParseFast(BS, BE: LongWord);
var
  Ip, IEnd, ILimit, Anchor, Lowest, Cp, q: PByte;
  Cur, Dist, R0, R1, RD, H, C, D: LongWord;
  L, RL: SizeInt;
  Miss: LongWord;
  Step: SizeInt;
  OneWay: Boolean;
  HShl: Integer;
  V4, Win: LongWord;
  RowSh: Integer;
  T64: PQWord;
  E: QWord;
begin
  OneWay := FOne;
  Win := P.Window;
  RowSh := FRowShift;
  T64 := nil;
  if OneWay then T64 := @FTab64[0];
  HShl := 64 - 8 * P.HashLen;
  Dist := 0;
  Ip := FBuf + (BS - FBufRel);
  IEnd := FBuf + (BE - FBufRel);
  ILimit := IEnd - 8;
  Anchor := Ip;
  Lowest := FBuf;
  Miss := 0;
  while Ip < ILimit do
  begin
    Cur := LongWord(Ip - FBuf) + FBufRel;
    // rep0 y rep1
    RL := 0;
    RD := 0;
    R0 := FRep[0];
    if (R0 <= LongWord(Ip - Lowest)) and (PLongWord(Ip - R0)^ = PLongWord(Ip)^) then
    begin
      RL := 4 + MatchLen(Ip + 4, Ip - R0 + 4, IEnd);
      RD := R0;
    end
    else
    begin
      R1 := FRep[1];
      if (R1 <= LongWord(Ip - Lowest)) and (PLongWord(Ip - R1)^ = PLongWord(Ip)^) then
      begin
        RL := 4 + MatchLen(Ip + 4, Ip - R1 + 4, IEnd);
        RD := R1;
      end;
    end;
    if RL >= 8 then
    begin
      // un rep largo: no se busca en el hash
      L := RL;
      Dist := RD;
      Insert(Ip, Cur);
    end
    else
    begin
      if OneWay then
      begin
        // tabla directa: una entrada por hash, sin etiqueta
        V4 := PLongWord(Ip)^;
        H := LongWord(((PQWord(Ip)^ shl HShl) * PRIME64) shr 32) shr RowSh;
        E := T64[H];
        T64[H] := (QWord(V4) shl 32) or Cur;
        L := 3;
        D := Cur - LongWord(E);
        // los 4 bytes guardados en la entrada: sin leer los datos del candidato
        if (LongWord(E shr 32) = V4) and (LongWord(E) <> 0) and (D <= Win) then
        begin
          L := 4 + MatchLen(Ip + 4, Ip - D + 4, IEnd);
          Dist := D;
        end;
      end
      else
        L := FindAndInsert(Ip, IEnd, Cur, 3, Dist);
      if (RL > 0) and (RL + 1 >= L) then
      begin
        L := RL;
        Dist := RD;
      end;
    end;
    if L < 4 then
    begin
      Inc(Miss);
      Step := 1;
      if P.SkipShift > 0 then Inc(Step, Miss shr P.SkipShift);
      Inc(Ip, Step);
      Continue;
    end;
    Miss := 0;
    // extender hacia atrás sobre los literales pendientes
    Cp := Ip - Dist;
    while (Ip > Anchor) and (Cp > Lowest) and (Ip[-1] = Cp[-1]) do
    begin
      Dec(Ip); Dec(Cp); Inc(L);
    end;
    AddSeq(Anchor, Ip - Anchor, Dist, L);
    // posiciones dentro del match
    q := Ip + L;
    if P.InsertAll then
    begin
      Cp := Ip + 1;
      while (Cp < q) and (Cp < ILimit) do
      begin
        Insert(Cp, LongWord(Cp - FBuf) + FBufRel);
        Inc(Cp);
      end;
    end
    else
    begin
      if Ip + 2 < ILimit then Insert(Ip + 2, LongWord(Ip + 2 - FBuf) + FBufRel);
      if (q - 2 > Ip + 2) and (q - 2 < ILimit) then Insert(q - 2, LongWord(q - 2 - FBuf) + FBufRel);
      if (q - 1 > Ip + 2) and (q - 1 < ILimit) then Insert(q - 1, LongWord(q - 1 - FBuf) + FBufRel);
    end;
    Ip := q;
    Anchor := Ip;
  end;
  AddLits(Anchor, IEnd - Anchor);
end;

procedure TPlzEngine.PrefetchRow(Ip: PByte);
var
  Tag: Byte;
  Row: LongWord;
begin
  Row := HashOf(Ip, Tag);
  if FOne then prefetch(FTab64[Row * LongWord(P.Bucket)])
  else prefetch((FRows + SizeInt(Row) * FRowBytes)^);
end;

{ Inserta las posiciones [A, B) (todas, o las primeras y últimas InsertMax si son muchas),
  adelantando la carga de las filas. }
procedure TPlzEngine.InsertRange(A, B: PByte);
var
  Lim: SizeInt;
begin
  Lim := P.InsertMax;
  if (Lim > 0) and (B - A > 2 * Lim) then
  begin
    InsertRange2(A, A + Lim);
    InsertRange2(B - Lim, B);
  end
  else
    InsertRange2(A, B);
end;

procedure TPlzEngine.InsertRange2(A, B: PByte);
var
  X, Pf: PByte;
begin
  X := A;
  Pf := A + 8;
  while X < B do
  begin
    if Pf < B then begin PrefetchRow(Pf); Inc(Pf); end;
    Insert(X, LongWord(X - FBuf) + FBufRel);
    Inc(X);
  end;
end;

{ Mejor match en X (reps primero, después el hash, que inserta X). False si no hay. }
function TPlzEngine.EvalAt(X, IEnd: PByte; out Ln: SizeInt; out Dt: LongWord; out G: LongInt): Boolean;
var
  i: Integer;
  R, C, Avail, V3: LongWord;
  RL, HL: SizeInt;
  RB: SizeInt;
  RD, HD: LongWord;
  GR, GH: LongInt;
begin
  {$IFDEF PLZ_ASM}
  if FOne then
  begin
    FEv.X := X;
    FEv.Rep0 := FRep[0]; FEv.Rep1 := FRep[1]; FEv.Rep2 := FRep[2]; FEv.Rep3 := FRep[3];
    FEv.InsNext := FInsNext;
    Result := PlzEval1(FEv) <> 0;
    FInsNext := FEv.InsNext;
    if Result then
    begin
      Ln := FEv.Ln; Dt := FEv.Dt; G := FEv.G;
    end;
    Exit;
  end;
  {$ENDIF}
  C := LongWord(X - FBuf) + FBufRel;
  RB := 0; RD := 0; GR := -1000;
  Avail := LongWord(X - FBuf);
  V3 := PLongWord(X)^ and $FFFFFF;
  for i := 0 to 3 do
  begin
    R := FRep[i];
    if (R <= Avail) and ((PLongWord(X - R)^ and $FFFFFF) = V3) then
    begin
      RL := 3 + MatchLen(X + 3, X - R + 3, IEnd);
      if RL * 4 - i > GR then
      begin
        GR := RL * 4 - i;
        RB := RL; RD := R;
      end;
    end;
  end;
  HL := 0;
  HD := 0;
  if C >= FInsNext then
  begin
    if X + 9 < IEnd then PrefetchRow(X + 1);
    HL := FindAndInsert(X, IEnd, C, 3, HD);
    FInsNext := C + 1;
  end;
  if HL >= 4 then GH := HL * 4 - LongInt(HighBit(HD + 3)) else GH := -1000;
  if (RB = 0) and (HL < 4) then Exit(False);
  if GR >= GH then
  begin
    Ln := RB; Dt := RD; G := GR;
  end
  else
  begin
    Ln := HL; Dt := HD; G := GH;
  end;
  Result := True;
end;

{ Perezoso: en cada posición, el mejor entre los reps y la fila del hash; después se mira si
  empezar 1 (o 2) bytes más adelante da más ganancia (largo*4 - bits del offset). }
procedure TPlzEngine.ParseLazy(BS, BE: LongWord);
var
  Ip, IEnd, ILimit, Anchor, Lowest, Cp, q, Np, InsFrom, InsTo: PByte;
  L, L2: SizeInt;
  Dist, D2: LongWord;
  Gain, Gain2: LongInt;
  Miss: LongWord;
  Step: SizeInt;
  Depth: Integer;
begin
  Ip := FBuf + (BS - FBufRel);
  IEnd := FBuf + (BE - FBufRel);
  ILimit := IEnd - 8;
  Anchor := Ip;
  Lowest := FBuf;
  Miss := 0;
  Dist := 0;
  if FOne then
  begin
    FEv.Base := FBuf; FEv.IEnd := IEnd; FEv.T64 := @FTab64[0];
    if FShortOn then FEv.TS := @FTabS[0] else FEv.TS := nil;
    FEv.Cur0 := FBufRel; FEv.Win := P.Window; FEv.HShl := FHashShl; FEv.Sh := FRowShift;
    FEv.SSh := FShortSh; FEv.Bucket := P.Bucket; FEv.Check2 := Ord(FBin);
  end;
  while Ip < ILimit do
  begin
    if not EvalAt(Ip, IEnd, L, Dist, Gain) then
    begin
      Inc(Miss);
      Step := 1;
      if P.SkipShift > 0 then Inc(Step, Miss shr P.SkipShift);
      Inc(Ip, Step);
      Continue;
    end;
    Miss := 0;
    // perezoso
    if L < P.Nice then
    begin
      Depth := 0;
      while Depth < FLazyCur do
      begin
        Np := Ip + 1 + Depth;
        if Np >= ILimit then Break;
        if EvalAt(Np, IEnd, L2, D2, Gain2) and (Gain2 > Gain + 4 + 3 * Depth) then
        begin
          Ip := Np;
          L := L2; Dist := D2; Gain := Gain2;
          Depth := 0;
          if L >= P.Nice then Break;
        end
        else
          Inc(Depth);
      end;
    end;
    // extender hacia atrás
    Cp := Ip - Dist;
    while (Ip > Anchor) and (Cp > Lowest) and (Ip[-1] = Cp[-1]) do
    begin
      Dec(Ip); Dec(Cp); Inc(L);
    end;
    AddSeq(Anchor, Ip - Anchor, Dist, L);
    q := Ip + L;
    InsFrom := FBuf + (FInsNext - FBufRel);
    if InsFrom < Ip + 1 then InsFrom := Ip + 1;
    InsTo := q;
    if InsTo > ILimit then InsTo := ILimit;
    if P.InsertAll then
    begin
      if InsFrom < InsTo then InsertRange(InsFrom, InsTo);
    end
    else
    begin
      if (q - 2 >= InsFrom) and (q - 2 < ILimit) then Insert(q - 2, LongWord(q - 2 - FBuf) + FBufRel);
      if (q - 1 >= InsFrom) and (q - 1 < ILimit) then Insert(q - 1, LongWord(q - 1 - FBuf) + FBufRel);
    end;
    FInsNext := LongWord(q - FBuf) + FBufRel;
    Ip := q;
    Anchor := Ip;
  end;
  AddLits(Anchor, IEnd - Anchor);
end;

{$IFDEF PLZ_CHECK}
procedure TPlzEngine.CheckBlock(BS, BE: LongWord; const R: array of LongWord);
var
  i, k, lp: SizeInt;
  Pos: SizeInt;
  Src: PByte;
  Rep: array[0..3] of LongWord;
  D: LongWord;
  S: TPlzSeq;
begin
  Src := FBuf + (BS - FBufRel);
  Rep[0] := R[0]; Rep[1] := R[1]; Rep[2] := R[2]; Rep[3] := R[3];
  Pos := 0; lp := 0;
  for i := 0 to FNSeq - 1 do
  begin
    S := FSeq[i];
    for k := 0 to S.LL - 1 do
    begin
      if FLit[lp] <> Src[Pos] then begin WriteLn(StdErr, 'CHECK lit ', BS, ' seq ', i, ' pos ', Pos); Halt(9); end;
      Inc(lp); Inc(Pos);
    end;
    if S.OC < 4 then
    begin
      D := Rep[S.OC];
      for k := S.OC downto 1 do Rep[k] := Rep[k - 1];
      Rep[0] := D;
    end
    else
    begin
      if S.OC - 4 < 4 then D := S.OC - 4 + 1
      else D := ((LongWord(2) or ((S.OC - 4) and 1)) shl S.ONB) + S.OX + 1;
      Rep[3] := Rep[2]; Rep[2] := Rep[1]; Rep[1] := Rep[0]; Rep[0] := D;
    end;
    if (D = 0) or (D > P.Window) or (D > LongWord(Pos) + (BS - FBufRel)) then begin WriteLn(StdErr, 'CHECK dist ', D, ' blk ', BS, ' seq ', i); Halt(9); end;
    for k := 0 to S.ML - 1 do
    begin
      if Src[Pos + k - SizeInt(D)] <> Src[Pos + k] then begin WriteLn(StdErr, 'CHECK match blk ', BS, ' seq ', i, ' pos ', Pos, ' d ', D, ' ml ', S.ML, ' k ', k, ' oc ', S.OC); Halt(9); end;
    end;
    Inc(Pos, S.ML);
  end;
  while lp < FNLit do
  begin
    if FLit[lp] <> Src[Pos] then begin WriteLn(StdErr, 'CHECK last lit ', BS); Halt(9); end;
    Inc(lp); Inc(Pos);
  end;
  if Pos <> BE - BS then begin WriteLn(StdErr, 'CHECK len ', Pos, ' ', BE - BS); Halt(9); end;
end;
{$ENDIF}

{ ---- partir bloques ----
  Cada bloque parseado (256 KB) se puede codificar en trozos con sus propias tablas, cortando
  después de una secuencia: hojas de ~16 KB y un árbol binario sobre ellas; en cada nodo se
  compara el costo estimado (entropía en punto fijo, con un bit como mínimo por símbolo, y un
  costo por tabla) de codificarlo entero contra el de sus dos mitades. Datos parejos quedan en
  un bloque; los que cambian (archivos chicos distintos uno tras otro) adaptan sus tablas.
  Sólo enteros: la misma decisión en cualquier plataforma. }

procedure ByteHist(P: PByte; N: SizeInt; var F: array of LongWord); forward;

const
  LEAF_BYTES = 32 * KB;
  MAX_LEAVES = 64;

var
  LOG2TAB: array[0..4095] of LongWord;   // log2(i) * 4096 (i >= 1), sólo con enteros

procedure InitLog2;
var
  i, k: Integer;
  m: QWord;
  b, frac: LongWord;
begin
  LOG2TAB[0] := 0;
  for i := 1 to 4095 do
  begin
    b := BsrDWord(LongWord(i));
    m := QWord(i) shl (31 - b);           // mantisa en [2^31, 2^32)
    frac := 0;
    for k := 1 to 12 do
    begin
      m := (m * m) shr 31;
      if m >= (QWord(1) shl 32) then
      begin
        m := m shr 1;
        frac := frac or (LongWord(1) shl (12 - k));
      end;
    end;
    LOG2TAB[i] := (b shl 12) or frac;
  end;
end;

function Log2Fix(x: LongWord): LongWord; inline;
var
  b: LongWord;
begin
  if x < 4096 then Exit(LOG2TAB[x]);
  b := BsrDWord(x) - 11;
  Result := (b shl 12) + LOG2TAB[x shr b];
end;

{ Bits estimados de un alfabeto con estas frecuencias (0 si no se usa). }
function EstBits(const F: array of LongWord; N: Integer; IsLit: Boolean): Int64;
var
  i, Used: Integer;
  Tot: Int64;
  LN, Lf, c: LongWord;
begin
  Tot := 0;
  Used := 0;
  for i := 0 to N - 1 do Inc(Tot, F[i]);
  if Tot = 0 then Exit(0);
  LN := Log2Fix(LongWord(Tot));
  Result := 0;
  for i := 0 to N - 1 do
    if F[i] > 0 then
    begin
      Inc(Used);
      Lf := Log2Fix(F[i]);
      c := LN - Lf;
      if c < 4096 then c := 4096;      // Huffman: al menos un bit por símbolo
      Inc(Result, Int64(F[i]) * c);
    end;
  Result := Result shr 12;
  if Used <= 1 then Result := 0;
  Inc(Result, 24 + 4 * Used);           // la descripción de la tabla, aproximada
  if IsLit and (Result > Tot * 8) then Result := Tot * 8;
end;

function FreqsCost(const F: TPlzFreqs): Int64;
var
  t: Integer;
begin
  Result := 48;   // encabezado del bloque
  for t := 0 to 4 do Inc(Result, EstBits(F.F[t], PLZ_ALPHA[t], t = PT_LIT));
end;

{ Costo mínimo de las hojas [Lo, Hi) partiendo en mitades; deja en F el histograma del tramo
  y en FSplit[Node] si conviene partirlo. }
function TPlzEngine.BestSplit(Node, Lo, Hi: Integer): Int64;
var
  Mid, t, i: Integer;
  Whole, Parts: Int64;
  F, A, B: ^TPlzFreqs;
begin
  F := @FNodeF[Node];
  if Hi - Lo = 1 then
  begin
    F^ := FLeafF[Lo];
    FSplit[Node] := False;
    Exit(FreqsCost(F^));
  end;
  Mid := (Lo + Hi) div 2;
  Parts := BestSplit(2 * Node, Lo, Mid);
  Inc(Parts, BestSplit(2 * Node + 1, Mid, Hi));
  A := @FNodeF[2 * Node];
  B := @FNodeF[2 * Node + 1];
  for t := 0 to 4 do
    for i := 0 to PLZ_ALPHA[t] - 1 do F^.F[t][i] := A^.F[t][i] + B^.F[t][i];
  Whole := FreqsCost(F^);
  FSplit[Node] := Parts < Whole;
  if FSplit[Node] then Result := Parts else Result := Whole;
end;

procedure TPlzEngine.EmitPieces(Node, Lo, Hi: Integer; Src: PByte; const SavedRep: array of LongWord);
var
  Mid: Integer;
begin
  if FSplit[Node] then
  begin
    Mid := (Lo + Hi) div 2;
    EmitPieces(2 * Node, Lo, Mid, Src, SavedRep);
    EmitPieces(2 * Node + 1, Mid, Hi, Src, SavedRep);
  end
  else
    WriteBlock(Src + FLeafRaw[Lo], FLeafRaw[Hi] - FLeafRaw[Lo], FLeafSeq[Lo], FLeafSeq[Hi],
      FLeafLit[Lo], FLeafLit[Hi], True, SavedRep, @FNodeF[Node], 0);
end;

procedure TPlzEngine.EncodeBlock(BS, BE: LongWord);
var
  Saved: array[0..3] of LongWord;
  NL, k, t: Integer;
  j, Raw, Lit, RawLen: SizeInt;
  S: ^TPlzSeq;
  F: TPlzFreqs;
  Total, Extra: Int64;
  Src: PByte;
begin
  Saved[0] := FRep[0]; Saved[1] := FRep[1]; Saved[2] := FRep[2]; Saved[3] := FRep[3];
  FNSeq := 0;
  FNLit := 0;
  // Filas: en un bloque binario el hash es de 4 bytes (ver WantShort)
  FBin := WantShort(FBuf + (BS - FBufRel), FBuf + (BE - FBufRel));
  FShortOn := (Length(FTabS) > 0) and FBin;
  FLazyCur := P.Lazy;
  if FBin then Inc(FLazyCur, P.BinLazy);
  FHashShl := 64 - 8 * P.HashLen;
  if (P.Lazy > 0) and FBin then
  begin
    if P.BinHashLen > 0 then FHashShl := 64 - 8 * P.BinHashLen;
  end;
  if P.Lazy > 0 then ParseLazy(BS, BE)
  else if FOne then ParseFast1(BS, BE)
  else ParseFast(BS, BE);
  FinishSeqs(0, FNSeq);
  {$IFDEF PLZ_CHECK}
  CheckBlock(BS, BE, Saved);
  {$ENDIF}
  Src := FBuf + (BS - FBufRel);
  RawLen := BE - BS;
  // Hojas de ~16 KB, cortadas después de una secuencia
  NL := 0;
  if (RawLen >= 2 * LEAF_BYTES) and (FNSeq > 0) and ((P.SplitMode = 1) or ((P.SplitMode = 2) and FBin)) then
  begin
    if Length(FLeafF) < MAX_LEAVES then SetLength(FLeafF, MAX_LEAVES);
    FLeafSeq[0] := 0; FLeafLit[0] := 0; FLeafRaw[0] := 0;
    Raw := 0; Lit := 0; Extra := 0;
    for j := 0 to FNSeq - 1 do
    begin
      S := @FSeq[j];
      Inc(Raw, S^.LL + S^.ML);
      Inc(Lit, S^.LL);
      if (Raw - FLeafRaw[NL] >= LEAF_BYTES) and (NL < MAX_LEAVES - 1) and (RawLen - Raw >= LEAF_BYTES div 2) then
      begin
        Inc(NL);
        FLeafSeq[NL] := j + 1; FLeafLit[NL] := Lit; FLeafRaw[NL] := Raw;
      end;
    end;
    Inc(NL);
    FLeafSeq[NL] := FNSeq; FLeafLit[NL] := FNLit; FLeafRaw[NL] := RawLen;
  end;
  if NL < 2 then
  begin
    WriteBlock(Src, RawLen, 0, FNSeq, 0, FNLit, False, Saved, nil, 0);
    Exit;
  end;
  // Histogramas por hoja
  for k := 0 to NL - 1 do
  begin
    FillChar(FLeafF[k], SizeOf(TPlzFreqs), 0);
    ByteHist(@FLit[FLeafLit[k]], FLeafLit[k + 1] - FLeafLit[k], FLeafF[k].F[PT_LIT]);
    for j := FLeafSeq[k] to FLeafSeq[k + 1] - 1 do
    begin
      S := @FSeq[j];
      Inc(FLeafF[k].F[PT_TOK][S^.Tok]);
      Inc(FLeafF[k].F[PT_OFS][S^.OC]);
      Inc(Extra, S^.ONB);
      if S^.Tok >= 7 * 16 then begin Inc(FLeafF[k].F[PT_LLX][S^.LXC]); Inc(Extra, S^.LXN); end;
      if S^.Tok and 15 = 15 then begin Inc(FLeafF[k].F[PT_MLX][S^.MXC]); Inc(Extra, S^.MXN); end;
    end;
  end;
  if Length(FNodeF) < 4 * MAX_LEAVES then SetLength(FNodeF, 4 * MAX_LEAVES);
  Total := BestSplit(1, 0, NL) + Extra;
  if not FSplit[1] then
  begin
    WriteBlock(Src, RawLen, 0, FNSeq, 0, FNLit, False, Saved, @FNodeF[1], Extra);
    Exit;
  end;
  // Partido: si en total no achica, el bloque entero va guardado (como en WriteBlock)
  if Total div 8 >= RawLen then
  begin
    FRep[0] := Saved[0]; FRep[1] := Saved[1]; FRep[2] := Saved[2]; FRep[3] := Saved[3];
    Out8(PB_RAW);
    OutVInt(RawLen);
    OutBytes(Src, RawLen);
    Exit;
  end;
  EmitPieces(1, 0, NL, Src, Saved);
end;

{ Codifica Lit[0..N) con la tabla Cd en O; devuelve los bytes escritos. O necesita N*11/8+16. }
function EncodeLitStream(Lit: PByte; N: SizeInt; Cd: PPlzTabCodes; O: PByte): SizeInt;
var
  Acc: QWord;
  NBits, c: LongWord;
  O0: PByte;
begin
  O0 := O;
  Acc := 0; NBits := 0;
  // De a 5 símbolos (hasta 55 bits) entre vaciados de a bytes
  while N >= 5 do
  begin
    c := Lit[0]; Acc := Acc or (QWord(Cd^.Codes[c]) shl NBits); Inc(NBits, Cd^.Lens[c]);
    c := Lit[1]; Acc := Acc or (QWord(Cd^.Codes[c]) shl NBits); Inc(NBits, Cd^.Lens[c]);
    c := Lit[2]; Acc := Acc or (QWord(Cd^.Codes[c]) shl NBits); Inc(NBits, Cd^.Lens[c]);
    c := Lit[3]; Acc := Acc or (QWord(Cd^.Codes[c]) shl NBits); Inc(NBits, Cd^.Lens[c]);
    c := Lit[4]; Acc := Acc or (QWord(Cd^.Codes[c]) shl NBits); Inc(NBits, Cd^.Lens[c]);
    PQWord(O)^ := NtoLE(Acc);
    Inc(O, NBits shr 3);
    Acc := Acc shr (NBits and not 7);
    NBits := NBits and 7;
    Inc(Lit, 5);
    Dec(N, 5);
  end;
  while N > 0 do
  begin
    c := Lit[0]; Acc := Acc or (QWord(Cd^.Codes[c]) shl NBits); Inc(NBits, Cd^.Lens[c]);
    PQWord(O)^ := NtoLE(Acc);
    Inc(O, NBits shr 3);
    Acc := Acc shr (NBits and not 7);
    NBits := NBits and 7;
    Inc(Lit);
    Dec(N);
  end;
  PQWord(O)^ := NtoLE(Acc);
  Inc(O, (NBits + 7) shr 3);
  Result := O - O0;
end;

{ Codifica las secuencias en O (necesita 16 bytes por secuencia + 16). }
function EncodeSeqStream(S: PPlzSeq; N: SizeInt; TT, TO_, TL, TM: PPlzTabCodes; O: PByte): SizeInt;
var
  Acc: QWord;
  NBits, c, Tok: LongWord;
  O0: PByte;
begin
  O0 := O;
  Acc := 0; NBits := 0;
  while N > 0 do
  begin
    Tok := S^.Tok;
    Acc := Acc or (QWord(TT^.Codes[Tok]) shl NBits); Inc(NBits, TT^.Lens[Tok]);
    c := S^.OC;
    Acc := Acc or (QWord(TO_^.Codes[c]) shl NBits); Inc(NBits, TO_^.Lens[c]);
    if (Tok shr 4 = 7) or (Tok and 15 = 15) then
    begin
      if Tok shr 4 = 7 then
      begin
        c := S^.LXC;
        Acc := Acc or (QWord(TL^.Codes[c]) shl NBits); Inc(NBits, TL^.Lens[c]);
      end;
      if Tok and 15 = 15 then
      begin
        c := S^.MXC;
        Acc := Acc or (QWord(TM^.Codes[c]) shl NBits); Inc(NBits, TM^.Lens[c]);
      end;
      PQWord(O)^ := NtoLE(Acc); Inc(O, NBits shr 3); Acc := Acc shr (NBits and not 7); NBits := NBits and 7;
      if Tok shr 4 = 7 then
      begin
        Acc := Acc or (QWord(S^.LXV) shl NBits); Inc(NBits, S^.LXN);
      end;
      if Tok and 15 = 15 then
      begin
        Acc := Acc or (QWord(S^.MXV) shl NBits); Inc(NBits, S^.MXN);
      end;
      PQWord(O)^ := NtoLE(Acc); Inc(O, NBits shr 3); Acc := Acc shr (NBits and not 7); NBits := NBits and 7;
    end;
    Acc := Acc or (QWord(S^.OX) shl NBits); Inc(NBits, S^.ONB);
    PQWord(O)^ := NtoLE(Acc); Inc(O, NBits shr 3); Acc := Acc shr (NBits and not 7); NBits := NBits and 7;
    Inc(S);
    Dec(N);
  end;
  PQWord(O)^ := NtoLE(Acc);
  Inc(O, (NBits + 7) shr 3);
  Result := O - O0;
end;

{ Histograma de N bytes en F (que se suma), en cuatro tablas para no encadenar incrementos. }
procedure ByteHist(P: PByte; N: SizeInt; var F: array of LongWord);
var
  F1, F2, F3: array[0..255] of LongWord;
  i: Integer;
begin
  FillChar(F1, SizeOf(F1), 0); FillChar(F2, SizeOf(F2), 0); FillChar(F3, SizeOf(F3), 0);
  while N >= 4 do
  begin
    Inc(F[P[0]]);
    Inc(F1[P[1]]);
    Inc(F2[P[2]]);
    Inc(F3[P[3]]);
    Inc(P, 4);
    Dec(N, 4);
  end;
  while N > 0 do begin Inc(F[P[0]]); Inc(P); Dec(N); end;
  for i := 0 to 255 do Inc(F[i], F1[i] + F2[i] + F3[i]);
end;

procedure TPlzEngine.WriteBlock(Src: PByte; RawLen: SizeInt; SeqLo, SeqHi, LitLo, LitHi: SizeInt;
  Piece: Boolean; const SavedRep: array of LongWord; PF: Pointer; ExtraIn: Int64);
var
  Freq: array[0..4] of array[0..255] of LongWord;
  F1, F2, F3: array[0..255] of LongWord;
  NewLens: array[0..4] of TPlzLens;
  Mode: array[0..4] of Integer;
  Extra: Int64;
  i, t, k, NS: Integer;
  j: SizeInt;
  S: ^TPlzSeq;
  X: LongWord;
  CostNew, CostReuse, CostRaw, CostLit, Total: Int64;
  q, Lo, Hi: SizeInt;
  PayLen: SizeInt;
  AllSame, Used: Boolean;
  m0, m1: Byte;
  LitSz: array[0..3] of SizeInt;
  BW: ^TPlzBitWriter;
  Tmp: array[0..15] of Byte;
  TmpN: Integer;
  // escritor de bits en registros
  Acc: QWord;
  NBits: LongWord;
  O, LitP: PByte;
  Cd: ^TPlzTabCodes;
  TT, TO_, TL, TM: ^TPlzTabCodes;
  c: LongWord;
  NSeq, NLit: SizeInt;

  procedure PutPay(Src2: PByte; N: SizeInt);
  begin
    if PayLen + N > Length(FPay) then SetLength(FPay, (PayLen + N) * 2);
    if N > 0 then Move(Src2^, FPay[PayLen], N);
    Inc(PayLen, N);
  end;

  procedure PutPayVInt(V: LongWord);
  begin
    TmpN := 0;
    while V >= $80 do
    begin
      Tmp[TmpN] := Byte(V) or $80; Inc(TmpN);
      V := V shr 7;
    end;
    Tmp[TmpN] := Byte(V); Inc(TmpN);
    PutPay(@Tmp[0], TmpN);
  end;

  procedure StoreRaw;
  begin
    FRep[0] := SavedRep[0]; FRep[1] := SavedRep[1]; FRep[2] := SavedRep[2]; FRep[3] := SavedRep[3];
    Out8(PB_RAW);
    OutVInt(RawLen);
    OutBytes(Src, RawLen);
  end;

begin
  if RawLen <= 0 then Exit;
  NSeq := SeqHi - SeqLo;
  NLit := LitHi - LitLo;
  if PF <> nil then
  begin
    // histogramas ya hechos por EncodeBlock (hojas y nodos)
    Move(PF^, Freq, SizeOf(Freq));
    Extra := ExtraIn;
  end
  else
  begin
    FillChar(Freq, SizeOf(Freq), 0);
    ByteHist(@FLit[LitLo], NLit, Freq[PT_LIT]);
    Extra := 0;
    for j := SeqLo to SeqHi - 1 do
    begin
      S := @FSeq[j];
      Inc(Freq[PT_TOK][S^.Tok]);
      Inc(Freq[PT_OFS][S^.OC]);
      Inc(Extra, S^.ONB);
      if S^.Tok >= 7 * 16 then begin Inc(Freq[PT_LLX][S^.LXC]); Inc(Extra, S^.LXN); end;
      if S^.Tok and 15 = 15 then begin Inc(Freq[PT_MLX][S^.MXC]); Inc(Extra, S^.MXN); end;
    end;
  end;
  // Modos de las tablas
  Total := 16 * 8 + Extra;
  for t := 0 to 4 do
  begin
    Used := False;
    for i := 0 to PLZ_ALPHA[t] - 1 do if Freq[t][i] > 0 then begin Used := True; Break; end;
    if not Used then
    begin
      Mode[t] := PM_NONE;
      Continue;
    end;
    // Primero lo barato: reusar la tabla anterior (costo exacto) o, para los literales,
    // guardarlos, contra una estimación de la tabla nueva; la tabla nueva se arma sólo si hace falta
    if FHavePrev[t] then CostReuse := DataBits(Freq[t], FPrevLens[t], PLZ_ALPHA[t])
    else CostReuse := High(Int64) div 4;
    CostNew := EstBits(Freq[t], PLZ_ALPHA[t], False);
    CostRaw := High(Int64) div 4;
    if t = PT_LIT then CostRaw := Int64(NLit) * 8;
    if CostReuse <= CostNew then
    begin
      Mode[t] := PM_REUSE;
      CostLit := CostReuse;
    end
    else if CostRaw <= CostNew + 32 then
    begin
      Mode[t] := PM_RAW;
      CostLit := CostRaw;
    end
    else
    begin
      PlzHuffLens(Freq[t], PLZ_ALPHA[t], PLZ_MAXCODELEN, NewLens[t]);
      CostNew := TableDescBits(NewLens[t], PLZ_ALPHA[t]) + DataBits(Freq[t], NewLens[t], PLZ_ALPHA[t]);
      if CostReuse <= CostNew then
      begin
        Mode[t] := PM_REUSE;
        CostLit := CostReuse;
      end
      else
      begin
        Mode[t] := PM_NEW;
        CostLit := CostNew;
      end;
      if CostRaw <= CostLit + 32 then
      begin
        Mode[t] := PM_RAW;
        CostLit := CostRaw;
      end;
    end;
    Inc(Total, CostLit);
  end;
  // Si la estimación ya no achica: guardado (un trozo de un bloque partido va siempre comprimido:
  // EncodeBlock ya decidió que el bloque entero achica)
  if (Total div 8 >= RawLen) and not Piece then
  begin
    StoreRaw;
    Exit;
  end;
  // Contenido
  PayLen := 0;
  PutPayVInt(NSeq);
  PutPayVInt(NLit);
  m0 := Mode[PT_LIT] or (Mode[PT_TOK] shl 2) or (Mode[PT_LLX] shl 4) or (Mode[PT_MLX] shl 6);
  m1 := Mode[PT_OFS];
  PutPay(@m0, 1);
  PutPay(@m1, 1);
  // tablas
  BW := @FBW[0];
  BW^.Init(1024);
  for t := 0 to 4 do
    if Mode[t] = PM_NEW then
    begin
      WriteTableLens(BW^, NewLens[t], PLZ_ALPHA[t]);
      FPrevLens[t] := NewLens[t];
    end;
  BW^.Flush;
  PutPay(@BW^.Data[0], BW^.Len);
  for t := 0 to 4 do
    if Mode[t] in [PM_NEW, PM_REUSE] then MakeTabCodes(FPrevLens[t], PLZ_ALPHA[t], FTC[t]);
  // literales
  if Mode[PT_LIT] = PM_RAW then
    PutPay(@FLit[LitLo], NLit)
  else if NLit > 0 then
  begin
    if NLit >= PLZ_LIT4 then NS := 4 else NS := 1;
    q := (NLit + NS - 1) div NS;
    Cd := @FTC[PT_LIT];
    for k := 0 to NS - 1 do
    begin
      BW := @FBW[1 + k];
      Lo := k * q;
      Hi := Lo + q;
      if Hi > NLit then Hi := NLit;
      if Lo > Hi then Lo := Hi;
      BW^.Init((Hi - Lo) * 2 + 16);
      BW^.Len := EncodeLitStream(@FLit[LitLo + Lo], Hi - Lo, Cd, @BW^.Data[0]);
      LitSz[k] := BW^.Len;
    end;
    Lo := 0;
    for k := 0 to NS - 1 do Inc(Lo, LitSz[k]);
    // largo de la sección: los VInt de cada stream y los streams
    q := 0;
    for k := 0 to NS - 1 do
    begin
      X := LitSz[k];
      repeat Inc(q); X := X shr 7; until X = 0;
    end;
    PutPayVInt(Lo + q);
    for k := 0 to NS - 1 do PutPayVInt(LitSz[k]);
    for k := 0 to NS - 1 do PutPay(@FBW[1 + k].Data[0], LitSz[k]);
  end;
  // secuencias
  if NSeq > 0 then
  begin
    BW := @FBW[5];
    BW^.Init(NSeq * 16 + 16);
    BW^.Len := EncodeSeqStream(@FSeq[SeqLo], NSeq, @FTC[PT_TOK], @FTC[PT_OFS], @FTC[PT_LLX], @FTC[PT_MLX], @BW^.Data[0]);
    PutPay(@BW^.Data[0], BW^.Len);
  end;
  if (PayLen >= RawLen) and not Piece then
  begin
    // No achicó: guardado; las tablas nuevas no llegan al decodificador
    StoreRaw;
    for t := 0 to 4 do
      if Mode[t] = PM_NEW then FHavePrev[t] := False;
    Exit;
  end;
  for t := 0 to 4 do
    if Mode[t] = PM_NEW then FHavePrev[t] := True;
  // Un bloque de un solo byte repetido
  if (PayLen < 32) and not Piece then
  begin
    AllSame := True;
    for j := 1 to RawLen - 1 do
      if Src[j] <> Src[0] then begin AllSame := False; Break; end;
    if AllSame then
    begin
      // el decodificador no toca reps ni tablas en un bloque RLE
      FRep[0] := SavedRep[0]; FRep[1] := SavedRep[1]; FRep[2] := SavedRep[2]; FRep[3] := SavedRep[3];
      for t := 0 to 4 do
        if Mode[t] = PM_NEW then FHavePrev[t] := False;
      Out8(PB_RLE);
      OutVInt(RawLen);
      Out8(Src[0]);
      Exit;
    end;
  end;
  Out8(PB_COMP);
  OutVInt(RawLen);
  OutVInt(PayLen);
  OutBytes(@FPay[0], PayLen);
end;

{ ---- memoria y streaming ---- }

procedure TPlzEngine.EncodeAll(Src: PByte; Len: SizeInt);
var
  BE: LongWord;
begin
  FBuf := Src;
  FBufRel := 1;
  FCur := 1;
  FEnd := 1 + LongWord(Len);
  FInsNext := 1;
  while FCur < FEnd do
  begin
    BE := FCur + LongWord(P.BlockSize);
    if (BE > FEnd) or (BE < FCur) then BE := FEnd;
    EncodeBlock(FCur, BE);
    FCur := BE;
  end;
  Out8(PB_END);
end;

procedure TPlzEngine.Rebase;
var
  Delta, E: LongWord;
  i: SizeInt;
  k: Integer;
  Pp: PLongWord;
begin
  // Las posiciones relativas se acercan a 2^31: se restan todas (lo anterior al búfer se borra)
  Delta := FBufRel - 1;
  if Delta = 0 then Exit;
  if FRows <> nil then
    for i := 0 to (SizeInt(1) shl P.RowBits) - 1 do
    begin
      Pp := PLongWord(FRows + i * FRowBytes + FPosOff);
      for k := 0 to P.Ways - 1 do
      begin
        E := Pp[k];
        if E < FBufRel then Pp[k] := 0 else Pp[k] := E - Delta;
      end;
    end;
  for i := 0 to High(FTabS) do
  begin
    E := LongWord(FTabS[i]);
    if E < FBufRel then FTabS[i] := 0 else FTabS[i] := (FTabS[i] and QWord($FFFFFFFF00000000)) or (E - Delta);
  end;
  for i := 0 to High(FTab64) do
  begin
    E := LongWord(FTab64[i]);
    if E < FBufRel then FTab64[i] := 0 else FTab64[i] := (FTab64[i] and QWord($FFFFFFFF00000000)) or (E - Delta);
  end;
  Dec(FBufRel, Delta);
  Dec(FCur, Delta);
  Dec(FEnd, Delta);
  if FInsNext > Delta then Dec(FInsNext, Delta) else FInsNext := 1;
end;

procedure TPlzEngine.Slide;
var
  Keep: LongWord;
  n: SizeInt;
begin
  // Se conserva la ventana antes de FCur (y lo que falta parsear)
  if FCur - FBufRel <= P.Window then Exit;
  Keep := FCur - P.Window;
  n := FEnd - Keep;
  Move(FBuf[Keep - FBufRel], FBuf[0], n);
  FBufRel := Keep;
  if FEnd > $7F000000 then Rebase;
end;

procedure TPlzEngine.Feed(Buf: PByte; Count: SizeInt);
var
  n, Used, NewLen: SizeInt;
begin
  if FCap = 0 then
  begin
    // Ventana + lo mismo (al menos 16 MB) por delante: cada deslizamiento mueve W bytes cada
    // >= W bytes de entrada (con W/2 eran dos copias por byte)
    FCap := SizeInt(P.Window);
    if FCap < 16 * MB then FCap := 16 * MB;
    Inc(FCap, SizeInt(P.Window));
  end;
  while Count > 0 do
  begin
    Used := FEnd - FBufRel;
    if Used = FCap then
    begin
      Slide;
      Used := FEnd - FBufRel;
    end;
    // El búfer crece con los datos hasta FCap
    if Used = Length(FOwnBuf) then
    begin
      NewLen := Length(FOwnBuf) * 2;
      if NewLen < 4 * P.BlockSize then NewLen := 4 * P.BlockSize;
      if NewLen > FCap then NewLen := FCap;
      SetLength(FOwnBuf, NewLen);
      FBuf := @FOwnBuf[0];
    end;
    n := Length(FOwnBuf) - Used;
    if n > Count then n := Count;
    Move(Buf^, FOwnBuf[Used], n);
    Inc(FEnd, n);
    Inc(Buf, n);
    Dec(Count, n);
    while FEnd - FCur >= LongWord(P.BlockSize) do
    begin
      EncodeBlock(FCur, FCur + LongWord(P.BlockSize));
      Inc(FCur, P.BlockSize);
    end;
  end;
end;

procedure TPlzEngine.Finish;
begin
  if FEnd > FCur then
  begin
    EncodeBlock(FCur, FEnd);
    FCur := FEnd;
  end;
  Out8(PB_END);
end;

{ ---- etapa ---- }

constructor TPlzEncStage.Create(ATarget: TOutStage; const Params: TStringArray);
var
  P: TPlzEncParams;
begin
  try
    P := ParsePlzEncParams(Params);
  except
    on E: EPlzEncoder do
    begin
      ATarget.Free;
      raise;
    end;
  end;
  inherited Create(ATarget);
  FEng := TPlzEngine.Create(P);
  FEng.StartStream;
end;

destructor TPlzEncStage.Destroy;
begin
  FEng.Free;
  inherited Destroy;
end;

procedure TPlzEncStage.DoWrite(Buf: PByte; Count: SizeInt);
begin
  FEng.Feed(Buf, Count);
  if FEng.OutLen > 0 then
  begin
    Emit(@FEng.OutBuf[0], FEng.OutLen);
    FEng.ClearOut;
  end;
end;

procedure TPlzEncStage.DoFinish;
begin
  FEng.Finish;
  if FEng.OutLen > 0 then
  begin
    Emit(@FEng.OutBuf[0], FEng.OutLen);
    FEng.ClearOut;
  end;
  inherited DoFinish;
end;

{ ---- caché de motores (4x4) ---- }

constructor TPlzEncCache.Create;
begin
  inherited Create;
  InitCriticalSection(FLock);
end;

destructor TPlzEncCache.Destroy;
var
  i: Integer;
begin
  for i := 0 to FCount - 1 do FItems[i].Free;
  DoneCriticalSection(FLock);
  inherited Destroy;
end;

function TPlzEncCache.Take(const P: TPlzEncParams): TObject;
var
  i: Integer;
  E: TPlzEngine;
begin
  Result := nil;
  EnterCriticalSection(FLock);
  try
    for i := FCount - 1 downto 0 do
    begin
      E := TPlzEngine(FItems[i]);
      if (E.P.RowBits = EffRowBits(P)) and (E.P.Ways = P.Ways) and (E.P.BlockSize = P.BlockSize) and (E.P.Bucket = P.Bucket) and
         ((Length(E.FTabS) > 0) = ((P.ShortBits > 0) and (P.Ways = 1))) and
         ((Length(E.FTabS) = 0) or (E.P.ShortBits = P.ShortBits)) then
      begin
        Result := E;
        FItems[i] := FItems[FCount - 1];
        Dec(FCount);
        Break;
      end;
    end;
  finally
    LeaveCriticalSection(FLock);
  end;
end;

procedure TPlzEncCache.Put(E: TObject);
begin
  EnterCriticalSection(FLock);
  try
    if FCount < 32 then
    begin
      if FCount >= Length(FItems) then SetLength(FItems, FCount + 8);
      FItems[FCount] := E;
      Inc(FCount);
      E := nil;
    end;
  finally
    LeaveCriticalSection(FLock);
  end;
  E.Free;
end;

function PlzEncodeMem(const Params: TStringArray; Src: PByte; SrcLen: SizeInt; out Dst: TBytes;
  Cache: TObject): Boolean;
var
  P: TPlzEncParams;
  E: TPlzEngine;
begin
  Dst := nil;
  P := ParsePlzEncParams(Params);
  E := nil;
  if Cache <> nil then E := TPlzEngine(TPlzEncCache(Cache).Take(P));
  if E = nil then E := TPlzEngine.Create(P)
  else begin E.P := P; E.P.RowBits := EffRowBits(P); end;   // mismas tablas; la ventana y el resto pueden cambiar
  try
    E.StartStream;
    E.EncodeAll(Src, SrcLen);
    Result := E.OutLen < SrcLen;
    if Result then
    begin
      SetLength(Dst, E.OutLen);
      Move(E.OutBuf[0], Dst[0], E.OutLen);
    end;
    E.ClearOut;
  finally
    if Cache <> nil then TPlzEncCache(Cache).Put(E) else E.Free;
  end;
end;

initialization
  InitLog2;
end.
