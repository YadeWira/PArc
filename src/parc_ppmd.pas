{ parc_ppmd — compresor y descompresor PPMd (método "ppmd").

  Credits: LZMA SDK (Igor Pavlov, public domain), based on PPMd var.H/var.I (Dmitry Shkarin,
  public domain).

  Traducción a Pascal del LZMA SDK (Igor Pavlov, dominio público), basado en PPMd var.H/var.I
  (Dmitry Shkarin, dominio público). Es la variante I (Ppmd8.c, Ppmd8Enc.c, Ppmd8Dec.c):
  PPMdI rev.1 con el range coder sin acarreo de Subbotin y los métodos de recuperación
  "restart" y "cut-off" cuando se llena la memoria (sin "freeze", igual que 7-Zip). El modelo
  es bit a bit el del SDK (tests/ppmd.sh lo compara con una compilación del C original).
  Ningún código de este unit viene de FreeArc.

  Se probó también la variante H (Ppmd7, la del 7z): en texto comprime ~0,3 % peor que la I
  y no es más rápida, así que quedó solo la I.

  Formato del stream (también en docs/formato/FORMATO-PARC.md, "Stream ppmd"):
    byte 0     'P' ($50)
    byte 1     variante: 'I' ($49) (otro valor: stream de otra versión, se rechaza)
    byte 2     orden máximo (2..64)
    byte 3     método de recuperación: 0 = restart, 1 = cut-off
    bytes 4-7  memoria del modelo en bytes, UInt32 little-endian
    resto      datos del range coder, terminados con la marca de fin de PPMd (un escape
               desde el contexto de orden -1): el stream no necesita el tamaño original.
  El decodificador exige que la cabecera coincida con los parámetros del método (los mismos
  que usó el compresor) y, al final, que el range coder cierre exacto (Code = 0) sin haber
  leído de más. Cualquier otra cosa es EArcCorrupt. Con datos dañados el modelo no lee ni
  escribe fuera de su memoria (evoluciona igual que el del compresor con otra entrada: los
  símbolos decodificados siempre son símbolos del contexto) y el range coder no puede quedar en
  un bucle: cada símbolo termina en un byte, en la marca de fin o en un error, y la lectura
  pasado el final del stream se corta a los MAX_OVERREAD bytes. }

unit parc_ppmd;

{$mode objfpc}{$H+}
{$POINTERMATH ON}
{$INLINE ON}
{$R-}{$Q-}
{ x86-64: el paso de un símbolo en ensamblador (parc_ppmd8_x64.inc), bit a bit igual al Pascal;
  en otras CPU, o con -dPARC_NOASM, todo en Pascal. }
{$IF defined(CPUX86_64) and not defined(PARC_NOASM)}{$DEFINE PPMD_ASM}{$ENDIF}

interface

uses
  Classes, SysUtils, parc_bytes, parc_stream, parc_outstream;

const
  PPMD_RESTORE_RESTART = 0;    // memoria llena: se reinicia el modelo
  PPMD_RESTORE_CUTOFF  = 1;    // memoria llena: se podan los contextos
  PPMD_MIN_ORDER = 2;
  PPMD_MAX_ORDER = 64;
  PPMD_MIN_MEM = 1 shl 11;
  PPMD_MAX_MEM = $FFFFFFFF - 12 * 3;
  PPMD_HEADER_SIZE = 8;

type
  { Etapa de descompresión PPMd. Si los parámetros son inválidos, el constructor lanza ANTES de
    tomar posesión de la fuente (si no, el destructor liberaría una fuente que es del llamador). }
  TPpmdStage = class(TInStage)
  private
    FEngine: TObject;
    FStarted: Boolean;
    procedure Start;
  public
    constructor Create(ASource: TInStage; AOrder: Integer; AMemSize: Int64; ARestore: Integer);
    destructor Destroy; override;
    function Read(Buf: PByte; Count: SizeInt): SizeInt; override;
  end;

  { Etapa de compresión PPMd: codifica a medida que le llegan los bytes (no acumula el bloque). }
  TPpmdEncStage = class(TOutStage)
  private
    FEngine: TObject;
    procedure StageSink(Buf: PByte; Count: SizeInt);
  protected
    procedure DoWrite(Buf: PByte; Count: SizeInt); override;
    procedure DoFinish; override;
  public
    constructor Create(ATarget: TOutStage; AOrder: Integer; AMemSize: Int64; ARestore: Integer);
    destructor Destroy; override;
  end;

{ Valida los parámetros; '' si están bien, si no el motivo. }
function PpmdCheckParams(AOrder: Integer; AMemSize: Int64; ARestore: Integer): string;

{ Comprime un buffer entero al stream de arriba (con cabecera y marca de fin). }
function PpmdCompress(InBuf: PByte; InLen: SizeInt; AOrder: Integer; AMemSize: Int64;
                      ARestore: Integer; out Compressed: TBytes): Boolean;

implementation

{ ================================================================================ }
{ Común (Ppmd.h)                                                                    }
{ ================================================================================ }

const
  PPMD_INT_BITS = 7;
  PPMD_PERIOD_BITS = 7;
  PPMD_BIN_SCALE = 1 shl (PPMD_INT_BITS + PPMD_PERIOD_BITS);
  PPMD_N1 = 4; PPMD_N2 = 4; PPMD_N3 = 4;
  PPMD_N4 = (128 + 3 - 1 * PPMD_N1 - 2 * PPMD_N2 - 3 * PPMD_N3) div 4;
  PPMD_NUM_INDEXES = PPMD_N1 + PPMD_N2 + PPMD_N3 + PPMD_N4;   // 38

  MAX_FREQ = 124;
  UNIT_SIZE = 12;
  kTopValue = UInt32(1) shl 24;
  kBot = UInt32(1) shl 15;

  kExpEscape: array[0..15] of Byte = (25, 14, 9, 7, 5, 5, 4, 4, 4, 3, 3, 3, 2, 2, 2, 2);
  kInitBinEsc: array[0..7] of Word = ($3CDD, $1F3F, $59BF, $48F3, $64A1, $5ABC, $6632, $6051);

  IO_BUF = 64 * 1024;
  MAX_OVERREAD = 8;   // bytes "fantasma" (0) que el decodificador tolera pasado el fin

type
  { Contextos SEE de los contextos con símbolos enmascarados }
  PSee = ^TSee;
  TSee = packed record
    Summ: Word;     // frecuencia
    Shift: Byte;    // velocidad de cambio de Summ
    Count: Byte;    // cuenta hasta el próximo cambio de Shift
  end;

  { Símbolo de un contexto: 6 bytes; Successor (UInt32) partido en dos mitades de 16 bits }
  PState = ^TState;
  TState = packed record
    Symbol: Byte;
    Freq: Byte;
    Successor0: Word;
    Successor1: Word;
  end;

  { Lectura y escritura de bytes del range coder (con buffer) }
  TPpmdEmitProc = procedure(Buf: PByte; Count: SizeInt) of object;
  PPpmdIO = ^TPpmdIO;
  TPpmdIO = record
    InPos, InEnd: PByte;
    Src: TInStage;
    Overread: Integer;
    OutPos, OutEnd: PByte;
    Sink: TPpmdEmitProc;
    Buf: array[0..IO_BUF - 1] of Byte;
  end;

{ Successor: siempre como dos mitades de 16 bits (la representación es interna; nunca va al
  stream, así que el orden de bytes de la máquina no importa) }
function GetSucc(s: PState): UInt32; inline;
begin
  Result := UInt32(s^.Successor0) or (UInt32(s^.Successor1) shl 16);
end;

procedure SetSucc(s: PState; v: UInt32); inline;
begin
  s^.Successor0 := Word(v);
  s^.Successor1 := Word(v shr 16);
end;

procedure SwapStates(a, b: PState); inline;
var
  t: TState;
begin
  t := a^;
  a^ := b^;
  b^ := t;
end;

{ Ppmd_See_UPDATE }
procedure SeeUpdate(see: PSee); inline;
begin
  if see^.Shift < PPMD_PERIOD_BITS then
  begin
    Dec(see^.Count);
    if see^.Count = 0 then
    begin
      see^.Summ := Word(see^.Summ shl 1);
      see^.Count := Byte(3 shl see^.Shift);
      Inc(see^.Shift);
    end;
  end;
end;

{ MEM_12_CPY: copia num unidades de 12 bytes }
procedure Mem12Cpy(dest, src: Pointer; num: Cardinal); inline;
var
  d, z: PUInt32;
begin
  d := dest; z := src;
  repeat
    d[0] := z[0]; d[1] := z[1]; d[2] := z[2];
    Inc(z, 3); Inc(d, 3);
    Dec(num);
  until num = 0;
end;

function IORefill(io: PPpmdIO): Byte;
var
  n: SizeInt;
begin
  n := io^.Src.Read(@io^.Buf[0], IO_BUF);
  if n <= 0 then
  begin
    Inc(io^.Overread);
    if io^.Overread > MAX_OVERREAD then Corrupt('ppmd: truncated stream');
    Exit(0);
  end;
  io^.InPos := @io^.Buf[1];
  io^.InEnd := @io^.Buf[n];
  Result := io^.Buf[0];
end;

function IOReadByte(io: PPpmdIO): Byte; inline;
begin
  if io^.InPos < io^.InEnd then
  begin
    Result := io^.InPos^;
    Inc(io^.InPos);
  end
  else
    Result := IORefill(io);
end;

procedure IOFlush(io: PPpmdIO);
begin
  if io^.OutPos > PByte(@io^.Buf[0]) then
    io^.Sink(@io^.Buf[0], io^.OutPos - PByte(@io^.Buf[0]));
  io^.OutPos := @io^.Buf[0];
end;

procedure IOWriteByte(io: PPpmdIO; b: Byte); inline;
begin
  io^.OutPos^ := b;
  Inc(io^.OutPos);
  if io^.OutPos >= io^.OutEnd then IOFlush(io);
end;

{ Tablas Indx2Units / Units2Indx (iguales en H e I) }
procedure InitUnitTables(Indx2Units, Units2Indx: PByte);
var
  i, k, step: Cardinal;
begin
  k := 0;
  for i := 0 to PPMD_NUM_INDEXES - 1 do
  begin
    if i >= 12 then step := 4 else step := (i shr 2) + 1;
    repeat
      Units2Indx[k] := Byte(i);
      Inc(k);
      Dec(step);
    until step = 0;
    Indx2Units[i] := Byte(k);
  end;
end;

function U2B(nu: Cardinal): UInt32; inline;
begin
  Result := UInt32(nu) * UNIT_SIZE;
end;

function HiBits3(sym: Cardinal): Cardinal; inline;
begin
  Result := ((sym + $C0) shr (8 - 3)) and (1 shl 3);
end;

function HiBits4(sym: Cardinal): Cardinal; inline;
begin
  Result := ((sym + $C0) shr (8 - 4)) and (1 shl 4);
end;

const
  PPMD_SYM_END = -1;
  PPMD_SYM_ERROR = -2;

{ ================================================================================ }
{ Modelo (Ppmd8.c), codificador (Ppmd8Enc.c) y decodificador (Ppmd8Dec.c)            }
{ ================================================================================ }

const
  FLAG_RESCALED  = 1 shl 2;
  FLAG_PREV_HIGH = 1 shl 4;
  EMPTY_NODE8 = $FFFFFFFF;

type
  PCtx8 = ^TCtx8;
  TCtx8 = packed record
    NumStats: Byte;    // número de símbolos - 1
    Flags: Byte;
    SummFreq: Word;    // unión con State2 (Symbol, Freq)
    Stats: UInt32;     // unión con State4 (Successor0/1)
    Suffix: UInt32;
  end;

  PNode8 = ^TNode8;
  TNode8 = packed record
    Stamp: UInt32;
    Next: UInt32;
    NU: UInt32;
  end;

  PPpmd8 = ^TPpmd8;
  TPpmd8 = record
    MinContext, MaxContext: PCtx8;
    FoundState: PState;
    OrderFall, InitEsc, PrevSuccess, MaxOrder, RestoreMethod: Cardinal;
    RunLength, InitRL: Int32;
    Size, GlueCount, AlignOffset: UInt32;
    Base, LoUnit, HiUnit, Text, UnitsStart: PByte;
    RcRange, RcCode, RcLow: UInt32;
    Indx2Units: array[0..PPMD_NUM_INDEXES + 1] of Byte;
    Units2Indx: array[0..127] of Byte;
    FreeList: array[0..PPMD_NUM_INDEXES - 1] of UInt32;
    Stamps: array[0..PPMD_NUM_INDEXES - 1] of UInt32;
    NS2BSIndx: array[0..255] of Byte;
    NS2Indx: array[0..259] of Byte;
    ExpEscape: array[0..15] of Byte;
    DummySee: TSee;
    See: array[0..23, 0..31] of TSee;
    BinSumm: array[0..24, 0..63] of Word;
    CharMask: array[0..255] of Byte;
    CutChanges: UInt32;   // cambios de la última pasada de CutOff (ver P8RestoreModel)
    IO: TPpmdIO;
  end;

function P8Ctx(p: PPpmd8; ref: UInt32): PCtx8; inline;
begin
  Result := PCtx8(p^.Base + ref);
end;

function P8Ref(p: PPpmd8; ptr: Pointer): UInt32; inline;
begin
  Result := UInt32(PByte(ptr) - p^.Base);
end;

function P8Stats(p: PPpmd8; c: PCtx8): PState; inline;
begin
  Result := PState(p^.Base + c^.Stats);
end;

function OneState8(c: PCtx8): PState; inline;
begin
  Result := PState(PByte(c) + 2);
end;

procedure P8Construct(p: PPpmd8);
var
  i, k, m: Cardinal;
begin
  p^.Base := nil;
  InitUnitTables(@p^.Indx2Units[0], @p^.Units2Indx[0]);
  p^.NS2BSIndx[0] := 0 shl 1;
  p^.NS2BSIndx[1] := 1 shl 1;
  FillChar(p^.NS2BSIndx[2], 9, 2 shl 1);
  FillChar(p^.NS2BSIndx[11], 256 - 11, 3 shl 1);
  for i := 0 to 4 do p^.NS2Indx[i] := Byte(i);
  m := 5; k := 1;
  for i := 5 to 259 do
  begin
    p^.NS2Indx[i] := Byte(m);
    Dec(k);
    if k = 0 then
    begin
      Inc(m);
      k := m - 4;
    end;
  end;
  Move(kExpEscape[0], p^.ExpEscape[0], 16);
end;

procedure P8InsertNode(p: PPpmd8; node: Pointer; indx: Cardinal); inline;
begin
  PNode8(node)^.Stamp := EMPTY_NODE8;
  PNode8(node)^.Next := p^.FreeList[indx];
  PNode8(node)^.NU := p^.Indx2Units[indx];
  p^.FreeList[indx] := P8Ref(p, node);
  Inc(p^.Stamps[indx]);
end;

function P8RemoveNode(p: PPpmd8; indx: Cardinal): Pointer; inline;
var
  node: PNode8;
begin
  node := PNode8(p^.Base + p^.FreeList[indx]);
  p^.FreeList[indx] := node^.Next;
  Dec(p^.Stamps[indx]);
  Result := node;
end;

procedure P8SplitBlock(p: PPpmd8; ptr: Pointer; oldIndx, newIndx: Cardinal);
var
  i, k, nu: Cardinal;
begin
  nu := Cardinal(p^.Indx2Units[oldIndx]) - p^.Indx2Units[newIndx];
  ptr := PByte(ptr) + U2B(p^.Indx2Units[newIndx]);
  i := p^.Units2Indx[nu - 1];
  if p^.Indx2Units[i] <> nu then
  begin
    Dec(i);
    k := p^.Indx2Units[i];
    P8InsertNode(p, PByte(ptr) + U2B(k), nu - k - 1);
  end;
  P8InsertNode(p, ptr, i);
end;

procedure P8GlueFreeBlocks(p: PPpmd8);
var
  n, next: UInt32;
  prev: PUInt32;
  node, node2: PNode8;
  nu: UInt32;
  i, k: Cardinal;
begin
  n := 0;
  p^.GlueCount := 1 shl 13;
  FillChar(p^.Stamps, SizeOf(p^.Stamps), 0);
  // guarda en LoUnit
  if p^.LoUnit <> p^.HiUnit then PNode8(p^.LoUnit)^.Stamp := 0;

  // Pegar bloques libres
  prev := @n;
  for i := 0 to PPMD_NUM_INDEXES - 1 do
  begin
    next := p^.FreeList[i];
    p^.FreeList[i] := 0;
    while next <> 0 do
    begin
      node := PNode8(p^.Base + next);
      nu := node^.NU;
      prev^ := next;
      next := node^.Next;
      if nu <> 0 then
      begin
        prev := @node^.Next;
        while True do
        begin
          node2 := node + nu;
          if node2^.Stamp <> EMPTY_NODE8 then Break;
          nu := nu + node2^.NU;
          node2^.NU := 0;
          node^.NU := nu;
        end;
      end;
    end;
  end;
  prev^ := 0;

  // Llenar las listas de libres
  while n <> 0 do
  begin
    node := PNode8(p^.Base + n);
    nu := node^.NU;
    n := node^.Next;
    if nu = 0 then Continue;
    while nu > 128 do
    begin
      P8InsertNode(p, node, PPMD_NUM_INDEXES - 1);
      Dec(nu, 128);
      Inc(node, 128);
    end;
    i := p^.Units2Indx[nu - 1];
    if p^.Indx2Units[i] <> nu then
    begin
      Dec(i);
      k := p^.Indx2Units[i];
      P8InsertNode(p, node + k, nu - k - 1);
    end;
    P8InsertNode(p, node, i);
  end;
end;

function P8AllocUnitsRare(p: PPpmd8; indx: Cardinal): Pointer;
var
  i: Cardinal;
  numBytes: UInt32;
  us: PByte;
begin
  if p^.GlueCount = 0 then
  begin
    P8GlueFreeBlocks(p);
    if p^.FreeList[indx] <> 0 then Exit(P8RemoveNode(p, indx));
  end;
  i := indx;
  repeat
    Inc(i);
    if i = PPMD_NUM_INDEXES then
    begin
      numBytes := U2B(p^.Indx2Units[indx]);
      us := p^.UnitsStart;
      Dec(p^.GlueCount);
      if UInt32(us - p^.Text) > numBytes then
      begin
        p^.UnitsStart := us - numBytes;
        Exit(p^.UnitsStart);
      end;
      Exit(nil);
    end;
  until p^.FreeList[i] <> 0;
  Result := P8RemoveNode(p, i);
  P8SplitBlock(p, Result, i, indx);
end;

function P8AllocUnits(p: PPpmd8; indx: Cardinal): Pointer; inline;
var
  numBytes: UInt32;
  lo: PByte;
begin
  if p^.FreeList[indx] <> 0 then Exit(P8RemoveNode(p, indx));
  numBytes := U2B(p^.Indx2Units[indx]);
  lo := p^.LoUnit;
  if UInt32(p^.HiUnit - lo) >= numBytes then
  begin
    p^.LoUnit := lo + numBytes;
    Exit(lo);
  end;
  Result := P8AllocUnitsRare(p, indx);
end;

function P8ShrinkUnits(p: PPpmd8; oldPtr: Pointer; oldNU, newNU: Cardinal): Pointer;
var
  i0, i1: Cardinal;
begin
  i0 := p^.Units2Indx[oldNU - 1];
  i1 := p^.Units2Indx[newNU - 1];
  if i0 = i1 then Exit(oldPtr);
  if p^.FreeList[i1] <> 0 then
  begin
    Result := P8RemoveNode(p, i1);
    Mem12Cpy(Result, oldPtr, newNU);
    P8InsertNode(p, oldPtr, i0);
    Exit;
  end;
  P8SplitBlock(p, oldPtr, i0, i1);
  Result := oldPtr;
end;

procedure P8FreeUnits(p: PPpmd8; ptr: Pointer; nu: Cardinal); inline;
begin
  P8InsertNode(p, ptr, p^.Units2Indx[nu - 1]);
end;

procedure P8SpecialFreeUnit(p: PPpmd8; ptr: Pointer);
begin
  if PByte(ptr) <> p^.UnitsStart then
    P8InsertNode(p, ptr, 0)
  else
    Inc(p^.UnitsStart, UNIT_SIZE);
end;

procedure P8ExpandTextArea(p: PPpmd8);
var
  count: array[0..PPMD_NUM_INDEXES - 1] of UInt32;
  i: Cardinal;
  node: PNode8;
  nu, cnt, n: UInt32;
  prev: PUInt32;
begin
  FillChar(count, SizeOf(count), 0);
  if p^.LoUnit <> p^.HiUnit then PNode8(p^.LoUnit)^.Stamp := 0;

  node := PNode8(p^.UnitsStart);
  while node^.Stamp = EMPTY_NODE8 do
  begin
    nu := node^.NU;
    node^.Stamp := 0;
    Inc(count[p^.Units2Indx[nu - 1]]);
    Inc(node, nu);
  end;
  if PByte(node) <> p^.UnitsStart then Inc(p^.CutChanges);
  p^.UnitsStart := PByte(node);

  for i := 0 to PPMD_NUM_INDEXES - 1 do
  begin
    cnt := count[i];
    if cnt = 0 then Continue;
    prev := @p^.FreeList[i];
    n := prev^;
    Dec(p^.Stamps[i], cnt);
    while True do
    begin
      node := PNode8(p^.Base + n);
      n := node^.Next;
      if node^.Stamp <> 0 then
      begin
        prev := @node^.Next;
        Continue;
      end;
      prev^ := n;
      Dec(cnt);
      if cnt = 0 then Break;
    end;
  end;
end;

procedure P8RestartModel(p: PPpmd8);
var
  i, k, m, r: Cardinal;
  mc: PCtx8;
  s: PState;
  see: PSee;
  val: Word;
  summ: Cardinal;
begin
  FillChar(p^.FreeList, SizeOf(p^.FreeList), 0);
  FillChar(p^.Stamps, SizeOf(p^.Stamps), 0);
  p^.Text := p^.Base + p^.AlignOffset;
  p^.HiUnit := p^.Text + p^.Size;
  p^.LoUnit := p^.HiUnit - p^.Size div 8 div UNIT_SIZE * 7 * UNIT_SIZE;
  p^.UnitsStart := p^.LoUnit;
  p^.GlueCount := 0;

  p^.OrderFall := p^.MaxOrder;
  if p^.MaxOrder < 12 then p^.InitRL := -Int32(p^.MaxOrder) - 1
  else p^.InitRL := -12 - 1;
  p^.RunLength := p^.InitRL;
  p^.PrevSuccess := 0;

  Dec(p^.HiUnit, UNIT_SIZE);
  mc := PCtx8(p^.HiUnit);
  s := PState(p^.LoUnit);
  Inc(p^.LoUnit, U2B(256 div 2));
  p^.MaxContext := mc;
  p^.MinContext := mc;
  p^.FoundState := s;
  mc^.Flags := 0;
  mc^.NumStats := 256 - 1;
  mc^.SummFreq := 256 + 1;
  mc^.Stats := P8Ref(p, s);
  mc^.Suffix := 0;
  for i := 0 to 255 do
  begin
    s^.Symbol := Byte(i);
    s^.Freq := 1;
    SetSucc(s, 0);
    Inc(s);
  end;

  i := 0;
  for m := 0 to 24 do
  begin
    while p^.NS2Indx[i] = m do Inc(i);
    for k := 0 to 7 do
    begin
      val := Word(PPMD_BIN_SCALE - kInitBinEsc[k] div (i + 1));
      r := 0;
      while r < 64 do
      begin
        p^.BinSumm[m, k + r] := val;
        Inc(r, 8);
      end;
    end;
  end;

  i := 0;
  for m := 0 to 23 do
  begin
    while p^.NS2Indx[i + 3] = m + 3 do Inc(i);
    see := @p^.See[m, 0];
    summ := (2 * i + 5) shl (PPMD_PERIOD_BITS - 4);
    for k := 0 to 31 do
    begin
      see^.Summ := Word(summ);
      see^.Shift := PPMD_PERIOD_BITS - 4;
      see^.Count := 7;
      Inc(see);
    end;
  end;

  p^.DummySee.Summ := 0;
  p^.DummySee.Shift := PPMD_PERIOD_BITS;
  p^.DummySee.Count := 64;
end;

procedure P8Init(p: PPpmd8; maxOrder, restoreMethod: Cardinal);
begin
  p^.MaxOrder := maxOrder;
  p^.RestoreMethod := restoreMethod;
  P8RestartModel(p);
end;

{ Refresh: se quitaron símbolos del contexto; recalcula frecuencias y flags }
procedure P8Refresh(p: PPpmd8; ctx: PCtx8; oldNU, scale: Cardinal);
var
  i, escFreq, sumFreq, flags, freq: Cardinal;
  s: PState;
begin
  i := ctx^.NumStats;
  s := PState(P8ShrinkUnits(p, P8Stats(p, ctx), oldNU, (i + 2) shr 1));
  ctx^.Stats := P8Ref(p, s);
  scale := scale or Ord(ctx^.SummFreq >= (UInt32(1) shl 15));

  flags := Cardinal(s^.Symbol) + $C0;
  freq := s^.Freq;
  escFreq := Cardinal(ctx^.SummFreq) - freq;
  freq := (freq + scale) shr scale;
  sumFreq := freq;
  s^.Freq := Byte(freq);

  repeat
    Inc(s);
    freq := s^.Freq;
    escFreq := escFreq - freq;
    freq := (freq + scale) shr scale;
    sumFreq := sumFreq + freq;
    s^.Freq := Byte(freq);
    flags := flags or (Cardinal(s^.Symbol) + $C0);
    Dec(i);
  until i = 0;

  ctx^.SummFreq := Word(sumFreq + ((escFreq + scale) shr scale));
  ctx^.Flags := Byte((ctx^.Flags and (FLAG_PREV_HIGH + FLAG_RESCALED * scale))
    + ((flags shr (8 - 3)) and (1 shl 3)));
end;

{ CutOff: poda los contextos (método de recuperación "cut-off") }
function P8CutOff(p: PPpmd8; ctx: PCtx8; order: Cardinal): UInt32;
var
  ns: Integer;
  nu, indx: Cardinal;
  stats, s, s2: PState;
  successor, successor2: UInt32;
  ptr: Pointer;
  sym: Byte;
begin
  ns := ctx^.NumStats;
  if ns = 0 then
  begin
    s := OneState8(ctx);
    successor := GetSucc(s);
    if (p^.Base + successor) >= p^.UnitsStart then
    begin
      if order < p^.MaxOrder then
        successor := P8CutOff(p, P8Ctx(p, successor), order + 1)
      else
        successor := 0;
      if successor <> GetSucc(s) then Inc(p^.CutChanges);
      SetSucc(s, successor);
      if (successor <> 0) or (order <= 9) then   // O_BOUND
        Exit(P8Ref(p, ctx));
    end;
    P8SpecialFreeUnit(p, ctx);
    Inc(p^.CutChanges);
    Exit(0);
  end;

  nu := (Cardinal(ns) + 2) shr 1;
  // mover Stats hacia arriba si está cerca de UnitsStart
  indx := p^.Units2Indx[nu - 1];
  stats := P8Stats(p, ctx);
  if (UInt32(PByte(stats) - p^.UnitsStart) <= (1 shl 14))
     and (ctx^.Stats <= p^.FreeList[indx]) then
  begin
    ptr := P8RemoveNode(p, indx);
    ctx^.Stats := P8Ref(p, ptr);
    Mem12Cpy(ptr, stats, nu);
    Inc(p^.CutChanges);
    if PByte(stats) <> p^.UnitsStart then
      P8InsertNode(p, stats, indx)
    else
      Inc(p^.UnitsStart, U2B(p^.Indx2Units[indx]));
    stats := PState(ptr);
  end;

  s := stats + Cardinal(ns);
  repeat
    successor := GetSucc(s);
    if (p^.Base + successor) < p^.UnitsStart then
    begin
      s2 := stats + Cardinal(ns);
      Dec(ns);
      if order <> 0 then
      begin
        if s <> s2 then s^ := s2^;
        Inc(p^.CutChanges);
      end
      else
      begin
        // en la raíz el símbolo no se quita: solo pasa al final con sucesor nulo
        if (s <> s2) or (successor <> 0) then Inc(p^.CutChanges);
        SwapStates(s, s2);
        SetSucc(s2, 0);
      end;
    end
    else
    begin
      if order < p^.MaxOrder then
        successor2 := P8CutOff(p, P8Ctx(p, successor), order + 1)
      else
        successor2 := 0;
      if successor2 <> successor then Inc(p^.CutChanges);
      SetSucc(s, successor2);
    end;
    Dec(s);
  until PtrUInt(s) < PtrUInt(stats);

  if (ns <> ctx^.NumStats) and (order <> 0) then
  begin
    if ns < 0 then
    begin
      P8FreeUnits(p, stats, nu);
      P8SpecialFreeUnit(p, ctx);
      Exit(0);
    end;
    ctx^.NumStats := Byte(ns);
    if ns = 0 then
    begin
      sym := stats^.Symbol;
      ctx^.Flags := Byte((ctx^.Flags and FLAG_PREV_HIGH) + HiBits3(sym));
      OneState8(ctx)^.Symbol := sym;
      OneState8(ctx)^.Freq := Byte((Cardinal(stats^.Freq) + 11) shr 3);
      OneState8(ctx)^.Successor0 := stats^.Successor0;
      OneState8(ctx)^.Successor1 := stats^.Successor1;
      P8FreeUnits(p, stats, nu);
    end
    else
      P8Refresh(p, ctx, nu, Ord(Cardinal(ctx^.SummFreq) > 16 * Cardinal(ns)));
  end;
  Result := P8Ref(p, ctx);
end;

function P8GetUsedMemory(p: PPpmd8): UInt32;
var
  v: UInt32;
  i: Cardinal;
begin
  v := 0;
  for i := 0 to PPMD_NUM_INDEXES - 1 do
    v := v + p^.Stamps[i] * p^.Indx2Units[i];
  Result := p^.Size - UInt32(p^.HiUnit - p^.LoUnit) - UInt32(p^.UnitsStart - p^.Text) - U2B(v);
end;

procedure P8RestoreModel(p: PPpmd8; ctxError: PCtx8);
var
  c: PCtx8;
  s: PState;
begin
  p^.Text := p^.Base + p^.AlignOffset;

  // quitar el último símbolo de los contextos [MaxContext .. ctxError)
  c := p^.MaxContext;
  while c <> ctxError do
  begin
    Dec(c^.NumStats);
    if c^.NumStats = 0 then
    begin
      s := P8Stats(p, c);
      c^.Flags := Byte((c^.Flags and FLAG_PREV_HIGH) + HiBits3(s^.Symbol));
      OneState8(c)^.Symbol := s^.Symbol;
      OneState8(c)^.Freq := Byte((Cardinal(s^.Freq) + 11) shr 3);
      OneState8(c)^.Successor0 := s^.Successor0;
      OneState8(c)^.Successor1 := s^.Successor1;
      P8SpecialFreeUnit(p, s);
    end
    else
      P8Refresh(p, c, (Cardinal(c^.NumStats) + 3) shr 1, 0);
    c := P8Ctx(p, c^.Suffix);
  end;

  // subir la frecuencia de escape de [ctxError .. MinContext)
  while c <> p^.MinContext do
  begin
    if c^.NumStats = 0 then
      OneState8(c)^.Freq := Byte((Cardinal(OneState8(c)^.Freq) + 1) shr 1)
    else
    begin
      c^.SummFreq := Word(c^.SummFreq + 4);
      if c^.SummFreq > 128 + 4 * Cardinal(c^.NumStats) then
        P8Refresh(p, c, (Cardinal(c^.NumStats) + 2) shr 1, 1);
    end;
    c := P8Ctx(p, c^.Suffix);
  end;

  if (p^.RestoreMethod = PPMD_RESTORE_RESTART) or (P8GetUsedMemory(p) < (p^.Size shr 1)) then
    P8RestartModel(p)
  else
  begin
    while p^.MaxContext^.Suffix <> 0 do
      p^.MaxContext := P8Ctx(p, p^.MaxContext^.Suffix);
    { El SDK repite hasta bajar de 3/4, pero si el modelo ya no cambia (memoria chica, o lo
      que queda son contextos que CutOff conserva) eso es un bucle sin fin: también en el
      decodificador, con un stream armado a propósito. Una pasada sin ningún cambio deja todo
      igual para la siguiente, así que ahí se reinicia el modelo: mismo resultado que el SDK
      siempre que el SDK termina. }
    while True do
    begin
      p^.CutChanges := 0;
      P8CutOff(p, p^.MaxContext, 0);
      P8ExpandTextArea(p);
      if P8GetUsedMemory(p) <= 3 * (p^.Size shr 2) then
      begin
        p^.GlueCount := 0;
        p^.OrderFall := p^.MaxOrder;
        Break;
      end;
      if p^.CutChanges = 0 then
      begin
        P8RestartModel(p);
        Break;
      end;
    end;
  end;
  p^.MinContext := p^.MaxContext;
end;

{$IFDEF PPMD_ASM}
{ En ensamblador (parc_ppmd8_x64.inc, al final del modelo) }
function P8CreateSuccessors(p: PPpmd8; skip: Boolean; s1: PState; c: PCtx8): PCtx8; forward;
procedure P8UpdateModel(p: PPpmd8); forward;

{ AllocUnits sin "inline", para llamarla desde el ensamblador }
function P8AllocUnitsF(p: PPpmd8; indx: Cardinal): Pointer;
begin
  Result := P8AllocUnits(p, indx);
end;
{$ENDIF}

{$IFNDEF PPMD_ASM}
function P8CreateSuccessors(p: PPpmd8; skip: Boolean; s1: PState; c: PCtx8): PCtx8;
var
  upBranch, successor: UInt32;
  newSym, newFreq, flags, sym: Byte;
  numPs: Cardinal;
  ps: array[0..255] of PState;
  s: PState;
  c1: PCtx8;
  cf, s0, temp: UInt32;
begin
  upBranch := GetSucc(p^.FoundState);
  numPs := 0;
  if not skip then
  begin
    ps[0] := p^.FoundState;
    numPs := 1;
  end;

  while c^.Suffix <> 0 do
  begin
    c := P8Ctx(p, c^.Suffix);
    if s1 <> nil then
    begin
      s := s1;
      s1 := nil;
    end
    else if c^.NumStats <> 0 then
    begin
      sym := p^.FoundState^.Symbol;
      s := P8Stats(p, c);
      while s^.Symbol <> sym do Inc(s);
      if s^.Freq < MAX_FREQ - 9 then
      begin
        Inc(s^.Freq);
        c^.SummFreq := Word(c^.SummFreq + 1);
      end;
    end
    else
    begin
      temp := Ord(P8Ctx(p, c^.Suffix)^.NumStats = 0);
      s := OneState8(c);
      s^.Freq := Byte(s^.Freq + (temp and UInt32(Ord(s^.Freq < 24))));
    end;
    successor := GetSucc(s);
    if successor <> upBranch then
    begin
      c := P8Ctx(p, successor);
      if numPs = 0 then Exit(c);
      Break;
    end;
    ps[numPs] := s;
    Inc(numPs);
  end;

  newSym := (p^.Base + upBranch)^;
  Inc(upBranch);
  flags := Byte(HiBits4(p^.FoundState^.Symbol) + HiBits3(newSym));

  if c^.NumStats = 0 then
    newFreq := OneState8(c)^.Freq
  else
  begin
    s := P8Stats(p, c);
    while s^.Symbol <> newSym do Inc(s);
    cf := UInt32(s^.Freq) - 1;
    s0 := UInt32(c^.SummFreq) - c^.NumStats - cf;
    if 2 * cf <= s0 then
      newFreq := Byte(1 + Ord(5 * cf > s0))
    else
      newFreq := Byte(1 + (cf + 2 * s0 - 3) div s0);
  end;

  repeat
    if p^.HiUnit <> p^.LoUnit then
    begin
      Dec(p^.HiUnit, UNIT_SIZE);
      c1 := PCtx8(p^.HiUnit);
    end
    else if p^.FreeList[0] <> 0 then
      c1 := PCtx8(P8RemoveNode(p, 0))
    else
    begin
      c1 := PCtx8(P8AllocUnitsRare(p, 0));
      if c1 = nil then Exit(nil);
    end;
    c1^.Flags := flags;
    c1^.NumStats := 0;
    OneState8(c1)^.Symbol := newSym;
    OneState8(c1)^.Freq := newFreq;
    SetSucc(OneState8(c1), upBranch);
    c1^.Suffix := P8Ref(p, c);
    Dec(numPs);
    SetSucc(ps[numPs], P8Ref(p, c1));
    c := c1;
  until numPs = 0;
  Result := c;
end;

{$ENDIF}

function P8ReduceOrder(p: PPpmd8; s1: PState; c: PCtx8): PCtx8;
var
  s, s2: PState;
  c1, successorCtx: PCtx8;
  upBranch, successor: UInt32;
begin
  s := nil;
  c1 := c;
  upBranch := P8Ref(p, p^.Text);
  SetSucc(p^.FoundState, upBranch);
  Inc(p^.OrderFall);

  while True do
  begin
    if s1 <> nil then
    begin
      c := P8Ctx(p, c^.Suffix);
      s := s1;
      s1 := nil;
    end
    else
    begin
      if c^.Suffix = 0 then Exit(c);
      c := P8Ctx(p, c^.Suffix);
      if c^.NumStats <> 0 then
      begin
        s := P8Stats(p, c);
        if s^.Symbol <> p^.FoundState^.Symbol then
          repeat
            Inc(s);
          until s^.Symbol = p^.FoundState^.Symbol;
        if s^.Freq < MAX_FREQ - 9 then
        begin
          s^.Freq := Byte(s^.Freq + 2);
          c^.SummFreq := Word(c^.SummFreq + 2);
        end;
      end
      else
      begin
        s := OneState8(c);
        s^.Freq := Byte(s^.Freq + Ord(s^.Freq < 32));
      end;
    end;
    if GetSucc(s) <> 0 then Break;
    SetSucc(s, upBranch);
    Inc(p^.OrderFall);
  end;

  if GetSucc(s) <= upBranch then
  begin
    s2 := p^.FoundState;
    p^.FoundState := s;
    successorCtx := P8CreateSuccessors(p, False, nil, c);
    if successorCtx = nil then
      SetSucc(s, 0)
    else
      SetSucc(s, P8Ref(p, successorCtx));
    p^.FoundState := s2;
  end;

  successor := GetSucc(s);
  if (p^.OrderFall = 1) and (c1 = p^.MaxContext) then
  begin
    SetSucc(p^.FoundState, successor);
    Dec(p^.Text);
  end;
  if successor = 0 then Exit(nil);
  Result := P8Ctx(p, successor);
end;

{$IFNDEF PPMD_ASM}
{ Primera parte de UpdateModel: frecuencia del símbolo en el contexto sufijo. Devuelve su
  estado (o nil). Aparte para que FPC deje la búsqueda en registros. }
function P8UpdateSuffixFreq(p: PPpmd8): PState;
var
  c: PCtx8;
  s: PState;
  sym: Byte;
begin
  Result := nil;
  if (p^.FoundState^.Freq < MAX_FREQ div 4) and (p^.MinContext^.Suffix <> 0) then
  begin
    c := P8Ctx(p, p^.MinContext^.Suffix);
    if c^.NumStats = 0 then
    begin
      s := OneState8(c);
      if s^.Freq < 32 then Inc(s^.Freq);
    end
    else
    begin
      sym := p^.FoundState^.Symbol;
      s := P8Stats(p, c);
      if s^.Symbol <> sym then
      begin
        repeat
          Inc(s);
        until s^.Symbol = sym;
        if s[0].Freq >= s[-1].Freq then
        begin
          SwapStates(@s[0], @s[-1]);
          Dec(s);
        end;
      end;
      if s^.Freq < MAX_FREQ - 9 then
      begin
        s^.Freq := Byte(s^.Freq + 2);
        c^.SummFreq := Word(c^.SummFreq + 2);
      end;
    end;
    Result := s;
  end;
end;

procedure P8UpdateModel(p: PPpmd8);
var
  maxSuccessor, minSuccessor, sum, cf, sf: UInt32;
  c, cs: PCtx8;
  s0, ns, fFreq, ns1, oldNU, i, freq: Cardinal;
  flag, fSymbol: Byte;
  s: PState;
  text: PByte;
  ptr, oldPtr: Pointer;
begin
  minSuccessor := GetSucc(p^.FoundState);
  fFreq := p^.FoundState^.Freq;
  fSymbol := p^.FoundState^.Symbol;
  s := P8UpdateSuffixFreq(p);

  c := p^.MaxContext;
  if (p^.OrderFall = 0) and (minSuccessor <> 0) then
  begin
    cs := P8CreateSuccessors(p, True, s, p^.MinContext);
    if cs = nil then
    begin
      SetSucc(p^.FoundState, 0);
      P8RestoreModel(p, c);
      Exit;
    end;
    SetSucc(p^.FoundState, P8Ref(p, cs));
    p^.MinContext := cs;
    p^.MaxContext := cs;
    Exit;
  end;

  text := p^.Text;
  text^ := p^.FoundState^.Symbol;
  Inc(text);
  p^.Text := text;
  if text >= p^.UnitsStart then
  begin
    P8RestoreModel(p, c);
    Exit;
  end;
  maxSuccessor := P8Ref(p, text);

  if minSuccessor = 0 then
  begin
    cs := P8ReduceOrder(p, s, p^.MinContext);
    if cs = nil then
    begin
      P8RestoreModel(p, c);
      Exit;
    end;
    minSuccessor := P8Ref(p, cs);
  end
  else if (p^.Base + minSuccessor) < p^.UnitsStart then
  begin
    cs := P8CreateSuccessors(p, False, s, p^.MinContext);
    if cs = nil then
    begin
      P8RestoreModel(p, c);
      Exit;
    end;
    minSuccessor := P8Ref(p, cs);
  end;

  Dec(p^.OrderFall);
  if p^.OrderFall = 0 then
  begin
    maxSuccessor := minSuccessor;
    if p^.MaxContext <> p^.MinContext then Dec(p^.Text);
  end;

  flag := Byte(HiBits3(fSymbol));
  ns := p^.MinContext^.NumStats;
  s0 := Cardinal(p^.MinContext^.SummFreq) - ns - fFreq;

  while c <> p^.MinContext do
  begin
    ns1 := c^.NumStats;
    if ns1 <> 0 then
    begin
      if (ns1 and 1) <> 0 then
      begin
        // crecer una unidad
        oldNU := (ns1 + 1) shr 1;
        i := p^.Units2Indx[oldNU - 1];
        if i <> p^.Units2Indx[oldNU] then
        begin
          ptr := P8AllocUnits(p, i + 1);
          if ptr = nil then
          begin
            P8RestoreModel(p, c);
            Exit;
          end;
          oldPtr := P8Stats(p, c);
          Mem12Cpy(ptr, oldPtr, oldNU);
          P8InsertNode(p, oldPtr, i);
          c^.Stats := P8Ref(p, ptr);
        end;
      end;
      sum := c^.SummFreq;
      sum := sum + UInt32(Ord(3 * ns1 + 1 < ns));
    end
    else
    begin
      s := PState(P8AllocUnits(p, 0));
      if s = nil then
      begin
        P8RestoreModel(p, c);
        Exit;
      end;
      freq := OneState8(c)^.Freq;
      s^.Symbol := OneState8(c)^.Symbol;
      s^.Successor0 := OneState8(c)^.Successor0;
      s^.Successor1 := OneState8(c)^.Successor1;
      c^.Stats := P8Ref(p, s);
      if freq < MAX_FREQ div 4 - 1 then freq := freq shl 1
      else freq := MAX_FREQ - 4;
      s^.Freq := Byte(freq);
      sum := UInt32(freq + p^.InitEsc + Ord(ns > 2));
    end;

    s := P8Stats(p, c) + ns1 + 1;
    cf := 2 * (sum + 6) * UInt32(fFreq);
    sf := UInt32(s0) + sum;
    s^.Symbol := fSymbol;
    c^.NumStats := Byte(ns1 + 1);
    SetSucc(s, maxSuccessor);
    c^.Flags := c^.Flags or flag;
    if cf < 6 * sf then
    begin
      cf := 1 + Ord(cf > sf) + Ord(cf >= 4 * sf);
      Inc(sum, 4);
    end
    else
    begin
      cf := 4 + Ord(cf > 9 * sf) + Ord(cf > 12 * sf) + Ord(cf > 15 * sf);
      Inc(sum, cf);
    end;
    c^.SummFreq := Word(sum);
    s^.Freq := Byte(cf);
    c := P8Ctx(p, c^.Suffix);
  end;
  p^.MinContext := P8Ctx(p, minSuccessor);
  p^.MaxContext := p^.MinContext;
end;

{$ENDIF}

procedure P8Rescale(p: PPpmd8);
var
  i, adder, sumFreq, escFreq, freq, numStats, numStatsNew, n0, n1: Cardinal;
  stats, s, s1: PState;
  tmp: TState;
  mc: PCtx8;
begin
  stats := P8Stats(p, p^.MinContext);
  s := p^.FoundState;
  if s <> stats then
  begin
    tmp := s^;
    repeat
      s[0] := s[-1];
      Dec(s);
    until s = stats;
    s^ := tmp;
  end;

  sumFreq := s^.Freq;
  escFreq := Cardinal(p^.MinContext^.SummFreq) - sumFreq;
  adder := Ord(p^.OrderFall <> 0);
  sumFreq := (sumFreq + 4 + adder) shr 1;
  i := p^.MinContext^.NumStats;
  s^.Freq := Byte(sumFreq);

  repeat
    Inc(s);
    freq := s^.Freq;
    escFreq := escFreq - freq;
    freq := (freq + adder) shr 1;
    sumFreq := sumFreq + freq;
    s^.Freq := Byte(freq);
    if freq > s[-1].Freq then
    begin
      tmp := s^;
      s1 := s;
      repeat
        s1[0] := s1[-1];
        Dec(s1);
      until (s1 = stats) or (freq <= s1[-1].Freq);
      s1^ := tmp;
    end;
    Dec(i);
  until i = 0;

  if s^.Freq = 0 then
  begin
    i := 0;
    repeat
      Inc(i);
      Dec(s);
    until s^.Freq <> 0;
    escFreq := escFreq + i;
    mc := p^.MinContext;
    numStats := mc^.NumStats;
    numStatsNew := numStats - i;
    mc^.NumStats := Byte(numStatsNew);
    n0 := (numStats + 2) shr 1;

    if numStatsNew = 0 then
    begin
      freq := (2 * Cardinal(stats^.Freq) + escFreq - 1) div escFreq;
      if freq > MAX_FREQ div 3 then freq := MAX_FREQ div 3;
      mc^.Flags := Byte((mc^.Flags and FLAG_PREV_HIGH) + HiBits3(stats^.Symbol));
      s := OneState8(mc);
      s^ := stats^;
      s^.Freq := Byte(freq);
      p^.FoundState := s;
      P8InsertNode(p, stats, p^.Units2Indx[n0 - 1]);
      Exit;
    end;

    n1 := (numStatsNew + 2) shr 1;
    if n0 <> n1 then
      mc^.Stats := P8Ref(p, P8ShrinkUnits(p, stats, n0, n1));
  end;

  mc := p^.MinContext;
  mc^.SummFreq := Word(sumFreq + escFreq - (escFreq shr 1));
  mc^.Flags := mc^.Flags or FLAG_RESCALED;
  p^.FoundState := P8Stats(p, mc);
end;

function P8MakeEscFreq(p: PPpmd8; numMasked1: Cardinal; out escFreq: UInt32): PSee; inline;
var
  mc: PCtx8;
  numStats, summ, r: Cardinal;
begin
  mc := p^.MinContext;
  numStats := mc^.NumStats;
  if numStats <> $FF then
  begin
    Result := @p^.See[Cardinal(p^.NS2Indx[numStats + 2]) - 3, 0];
    Inc(Result, Ord(Cardinal(mc^.SummFreq) > 11 * (numStats + 1))
      + 2 * Ord(2 * numStats < Cardinal(P8Ctx(p, mc^.Suffix)^.NumStats) + numMasked1)
      + mc^.Flags);
    summ := Result^.Summ;
    r := summ shr Result^.Shift;
    Result^.Summ := Word(summ - r);
    escFreq := r + Ord(r = 0);
  end
  else
  begin
    Result := @p^.DummySee;
    escFreq := 1;
  end;
end;

procedure P8NextContext(p: PPpmd8); inline;
var
  c: PCtx8;
begin
  c := P8Ctx(p, GetSucc(p^.FoundState));
  if (p^.OrderFall = 0) and (PByte(c) >= p^.UnitsStart) then
  begin
    p^.MinContext := c;
    p^.MaxContext := c;
  end
  else
    P8UpdateModel(p);
end;

procedure P8Update1(p: PPpmd8);
var
  s: PState;
  freq: Cardinal;
begin
  s := p^.FoundState;
  freq := Cardinal(s^.Freq) + 4;
  p^.MinContext^.SummFreq := Word(p^.MinContext^.SummFreq + 4);
  s^.Freq := Byte(freq);
  if freq > s[-1].Freq then
  begin
    SwapStates(@s[0], @s[-1]);
    Dec(s);
    p^.FoundState := s;
    if freq > MAX_FREQ then P8Rescale(p);
  end;
  P8NextContext(p);
end;

procedure P8Update1_0(p: PPpmd8);
var
  s: PState;
  mc: PCtx8;
  freq, summFreq: Cardinal;
begin
  s := p^.FoundState;
  mc := p^.MinContext;
  freq := s^.Freq;
  summFreq := mc^.SummFreq;
  p^.PrevSuccess := Ord(2 * freq >= summFreq);
  Inc(p^.RunLength, Int32(p^.PrevSuccess));
  mc^.SummFreq := Word(summFreq + 4);
  freq := freq + 4;
  s^.Freq := Byte(freq);
  if freq > MAX_FREQ then P8Rescale(p);
  P8NextContext(p);
end;

procedure P8Update2(p: PPpmd8);
var
  s: PState;
  freq: Cardinal;
begin
  s := p^.FoundState;
  freq := Cardinal(s^.Freq) + 4;
  p^.RunLength := p^.InitRL;
  p^.MinContext^.SummFreq := Word(p^.MinContext^.SummFreq + 4);
  s^.Freq := Byte(freq);
  if freq > MAX_FREQ then P8Rescale(p);
  P8UpdateModel(p);
end;

function P8GetBinSumm(p: PPpmd8): PWord; inline;
begin
  Result := @p^.BinSumm[p^.NS2Indx[Cardinal(OneState8(p^.MinContext)^.Freq) - 1],
    p^.PrevSuccess + ((UInt32(p^.RunLength) shr 26) and $20)
    + p^.NS2BSIndx[P8Ctx(p, p^.MinContext^.Suffix)^.NumStats]
    + p^.MinContext^.Flags];
end;

{ --- range coder sin acarreo (Subbotin) ---
  La normalización tiene el caso común (no hace falta) en línea y el bucle aparte: FPC asigna
  mejor los registros si las funciones calientes no tienen llamadas en el medio. }

procedure P8RcNormEncSlow(p: PPpmd8);
begin
  while True do
  begin
    if (p^.RcLow xor (p^.RcLow + p^.RcRange)) >= kTopValue then
    begin
      if p^.RcRange >= kBot then Break;
      p^.RcRange := (0 - p^.RcLow) and (kBot - 1);
    end;
    IOWriteByte(@p^.IO, Byte(p^.RcLow shr 24));
    p^.RcRange := p^.RcRange shl 8;
    p^.RcLow := p^.RcLow shl 8;
  end;
end;

procedure P8RcFlush(p: PPpmd8);
var
  i: Integer;
begin
  for i := 0 to 3 do
  begin
    IOWriteByte(@p^.IO, Byte(p^.RcLow shr 24));
    p^.RcLow := p^.RcLow shl 8;
  end;
end;

function P8RcInitDec(p: PPpmd8): Boolean;
var
  i: Integer;
begin
  p^.RcCode := 0;
  p^.RcRange := $FFFFFFFF;
  p^.RcLow := 0;
  for i := 0 to 3 do
    p^.RcCode := (p^.RcCode shl 8) or IOReadByte(@p^.IO);
  Result := p^.RcCode < $FFFFFFFF;
end;

procedure P8RcNormDecSlow(p: PPpmd8);
begin
  while True do
  begin
    if (p^.RcLow xor (p^.RcLow + p^.RcRange)) >= kTopValue then
    begin
      if p^.RcRange >= kBot then Break;
      p^.RcRange := (0 - p^.RcLow) and (kBot - 1);
    end;
    p^.RcCode := (p^.RcCode shl 8) or IOReadByte(@p^.IO);
    p^.RcRange := p^.RcRange shl 8;
    p^.RcLow := p^.RcLow shl 8;
  end;
end;

{$IFDEF PPMD_ASM}
{$I parc_ppmd8_x64.inc}
{$ELSE}
{ --- paso de un símbolo en Pascal (en x86-64 está en parc_ppmd8_x64.inc) --- }

procedure P8RcNormEnc(p: PPpmd8); inline;
begin
  if ((p^.RcLow xor (p^.RcLow + p^.RcRange)) < kTopValue) or (p^.RcRange < kBot) then
    P8RcNormEncSlow(p);
end;

procedure P8RcEncode(p: PPpmd8; start, size, total: UInt32); inline;
var
  r: UInt32;
begin
  r := p^.RcRange div total;
  p^.RcLow := p^.RcLow + start * r;
  p^.RcRange := r * size;
end;

{ Enmascara los símbolos de Stats (s2 = primero, s = último) }
procedure ZeroMask(mask: PByte; s2, s: PState); inline;
var
  sym0, sym1: Cardinal;
begin
  mask[s^.Symbol] := 0;
  repeat
    sym0 := s2[0].Symbol;
    sym1 := s2[1].Symbol;
    Inc(s2, 2);
    mask[sym0] := 0;
    mask[sym1] := 0;
  until s2 >= s;
end;

{ Máscara nueva con los símbolos del primer contexto }
procedure MaskStats(mask: PByte; s2, s: PState); inline;
begin
  FillChar(mask^, 256, $FF);
  ZeroMask(mask, s2, s);
end;

{ Primer contexto (con más de un símbolo). True si codificó el símbolo; si no, codificó el
  escape y dejó la máscara lista. }
function P8EncodeFirst(p: PPpmd8; symbol: Integer): Boolean;
var
  mc: PCtx8;
  s: PState;
  sum, summFreq: UInt32;
  i: Cardinal;
begin
  mc := p^.MinContext;
  s := P8Stats(p, mc);
  summFreq := mc^.SummFreq;
  if summFreq > p^.RcRange then summFreq := p^.RcRange;
  if s^.Symbol = symbol then
  begin
    P8RcEncode(p, 0, s^.Freq, summFreq);
    P8RcNormEnc(p);
    p^.FoundState := s;
    P8Update1_0(p);
    Exit(True);
  end;
  p^.PrevSuccess := 0;
  sum := s^.Freq;
  i := mc^.NumStats;
  repeat
    Inc(s);
    if s^.Symbol = symbol then
    begin
      P8RcEncode(p, sum, s^.Freq, summFreq);
      P8RcNormEnc(p);
      p^.FoundState := s;
      P8Update1(p);
      Exit(True);
    end;
    sum := sum + s^.Freq;
    Dec(i);
  until i = 0;
  P8RcEncode(p, sum, summFreq - sum, summFreq);
  MaskStats(@p^.CharMask[0], P8Stats(p, mc), s);
  Result := False;
end;

{ Contexto binario (un símbolo) }
function P8EncodeBin(p: PPpmd8; symbol: Integer): Boolean;
var
  mc, c: PCtx8;
  s: PState;
  prob: PWord;
  pr, bound, freq: UInt32;
begin
  mc := p^.MinContext;
  prob := P8GetBinSumm(p);
  s := OneState8(mc);
  pr := prob^;
  bound := (p^.RcRange shr 14) * pr;
  pr := pr - ((pr + (1 shl (PPMD_PERIOD_BITS - 2))) shr PPMD_PERIOD_BITS);
  if s^.Symbol = symbol then
  begin
    prob^ := Word(pr + (1 shl PPMD_INT_BITS));
    p^.RcRange := bound;
    P8RcNormEnc(p);
    freq := s^.Freq;
    c := P8Ctx(p, GetSucc(s));
    p^.FoundState := s;
    p^.PrevSuccess := 1;
    Inc(p^.RunLength);
    s^.Freq := Byte(freq + Ord(freq < 196));
    if (p^.OrderFall = 0) and (PByte(c) >= p^.UnitsStart) then
    begin
      p^.MinContext := c;
      p^.MaxContext := c;
    end
    else
      P8UpdateModel(p);
    Exit(True);
  end;
  prob^ := Word(pr);
  p^.InitEsc := p^.ExpEscape[pr shr 10];
  p^.RcLow := p^.RcLow + bound;
  p^.RcRange := (p^.RcRange and not UInt32(PPMD_BIN_SCALE - 1)) - bound;
  FillChar(p^.CharMask, 256, $FF);
  p^.CharMask[s^.Symbol] := 0;
  p^.PrevSuccess := 0;
  Result := False;
end;

{ Contextos sufijo, con los símbolos ya vistos enmascarados }
procedure P8EncodeMasked(p: PPpmd8; symbol: Integer);
var
  mask: PByte;
  s: PState;
  sum, escFreq, low, freq, total: UInt32;
  i, numMasked, num2, cur, sym0, sym1: Cardinal;
  mc: PCtx8;
  see: PSee;
begin
  mask := @p^.CharMask[0];
  while True do
  begin
    P8RcNormEnc(p);
    mc := p^.MinContext;
    numMasked := mc^.NumStats;
    repeat
      Inc(p^.OrderFall);
      if mc^.Suffix = 0 then Exit;   // marca de fin (symbol = -1)
      mc := P8Ctx(p, mc^.Suffix);
    until mc^.NumStats <> numMasked;

    p^.MinContext := mc;
    see := P8MakeEscFreq(p, numMasked, escFreq);

    s := P8Stats(p, mc);
    sum := 0;
    i := Cardinal(mc^.NumStats) + 1;
    repeat
      cur := s^.Symbol;
      if Integer(cur) = symbol then
      begin
        low := sum;
        freq := s^.Freq;
        SeeUpdate(see);
        p^.FoundState := s;
        sum := sum + escFreq;
        num2 := i shr 1;
        i := i and 1;
        sum := sum + (freq and (0 - UInt32(i)));
        if num2 <> 0 then
        begin
          Inc(s, i);
          repeat
            sym0 := s[0].Symbol;
            sym1 := s[1].Symbol;
            Inc(s, 2);
            sum := sum + (s[-2].Freq and mask[sym0]);
            sum := sum + (s[-1].Freq and mask[sym1]);
            Dec(num2);
          until num2 = 0;
        end;
        if sum > p^.RcRange then sum := p^.RcRange;
        P8RcEncode(p, low, freq, sum);
        P8RcNormEnc(p);
        P8Update2(p);
        Exit;
      end;
      sum := sum + (s^.Freq and mask[cur]);
      Inc(s);
      Dec(i);
    until i = 0;

    total := sum + escFreq;
    see^.Summ := Word(see^.Summ + total);
    if total > p^.RcRange then total := p^.RcRange;
    P8RcEncode(p, sum, total - sum, total);

    Dec(s);
    ZeroMask(mask, P8Stats(p, p^.MinContext), s);
  end;
end;

{ symbol = -1: marca de fin }
procedure P8EncodeSymbol(p: PPpmd8; symbol: Integer);
var
  done: Boolean;
begin
  if p^.MinContext^.NumStats <> 0 then done := P8EncodeFirst(p, symbol)
  else done := P8EncodeBin(p, symbol);
  if not done then P8EncodeMasked(p, symbol);
end;

procedure P8RcNormDec(p: PPpmd8); inline;
begin
  if ((p^.RcLow xor (p^.RcLow + p^.RcRange)) < kTopValue) or (p^.RcRange < kBot) then
    P8RcNormDecSlow(p);
end;

procedure P8RcDecode(p: PPpmd8; start, size: UInt32); inline;
begin
  start := start * p^.RcRange;
  p^.RcLow := p^.RcLow + start;
  p^.RcCode := p^.RcCode - start;
  p^.RcRange := p^.RcRange * size;
end;

const
  PPMD_SYM_ESC = -3;   // interno: escape del primer contexto, sigue con los sufijos

function P8DecodeFirst(p: PPpmd8): Integer;
var
  mc: PCtx8;
  s: PState;
  count, hiCnt, summFreq, r: UInt32;
  i: Cardinal;
begin
  mc := p^.MinContext;
  s := P8Stats(p, mc);
  summFreq := mc^.SummFreq;
  r := p^.RcRange;
  if summFreq > r then summFreq := r;
  r := r div summFreq;
  p^.RcRange := r;
  count := p^.RcCode div r;
  hiCnt := count;
  count := count - s^.Freq;
  if Int32(count) < 0 then
  begin
    P8RcDecode(p, 0, s^.Freq);
    P8RcNormDec(p);
    p^.FoundState := s;
    Result := s^.Symbol;
    P8Update1_0(p);
    Exit;
  end;
  p^.PrevSuccess := 0;
  i := mc^.NumStats;
  repeat
    Inc(s);
    count := count - s^.Freq;
    if Int32(count) < 0 then
    begin
      P8RcDecode(p, (hiCnt - count) - s^.Freq, s^.Freq);
      P8RcNormDec(p);
      p^.FoundState := s;
      Result := s^.Symbol;
      P8Update1(p);
      Exit;
    end;
    Dec(i);
  until i = 0;

  if hiCnt >= summFreq then Exit(PPMD_SYM_ERROR);
  hiCnt := hiCnt - count;
  P8RcDecode(p, hiCnt, summFreq - hiCnt);
  MaskStats(@p^.CharMask[0], P8Stats(p, mc), s);
  Result := PPMD_SYM_ESC;
end;

function P8DecodeBin(p: PPpmd8): Integer;
var
  mc, c: PCtx8;
  s: PState;
  prob: PWord;
  pr, size0, freq: UInt32;
begin
  mc := p^.MinContext;
  s := OneState8(mc);
  prob := P8GetBinSumm(p);
  pr := prob^;
  size0 := (p^.RcRange shr 14) * pr;
  pr := pr - ((pr + (1 shl (PPMD_PERIOD_BITS - 2))) shr PPMD_PERIOD_BITS);
  if p^.RcCode < size0 then
  begin
    prob^ := Word(pr + (1 shl PPMD_INT_BITS));
    p^.RcRange := size0;
    P8RcNormDec(p);
    freq := s^.Freq;
    c := P8Ctx(p, GetSucc(s));
    Result := s^.Symbol;
    p^.FoundState := s;
    p^.PrevSuccess := 1;
    Inc(p^.RunLength);
    s^.Freq := Byte(freq + Ord(freq < 196));
    if (p^.OrderFall = 0) and (PByte(c) >= p^.UnitsStart) then
    begin
      p^.MinContext := c;
      p^.MaxContext := c;
    end
    else
      P8UpdateModel(p);
    Exit;
  end;
  prob^ := Word(pr);
  p^.InitEsc := p^.ExpEscape[pr shr 10];
  p^.RcLow := p^.RcLow + size0;
  p^.RcCode := p^.RcCode - size0;
  p^.RcRange := (p^.RcRange and not UInt32(PPMD_BIN_SCALE - 1)) - size0;
  FillChar(p^.CharMask, 256, $FF);
  p^.CharMask[s^.Symbol] := 0;
  p^.PrevSuccess := 0;
  Result := PPMD_SYM_ESC;
end;

function P8DecodeMasked(p: PPpmd8): Integer;
var
  mask: PByte;
  s, s2: PState;
  numMasked, num, num2, sym0, sym1: Cardinal;
  count, hiCnt, freqSum, freqSum2: UInt32;
  mc: PCtx8;
  see: PSee;
begin
  mask := @p^.CharMask[0];
  while True do
  begin
    P8RcNormDec(p);
    mc := p^.MinContext;
    numMasked := mc^.NumStats;
    repeat
      Inc(p^.OrderFall);
      if mc^.Suffix = 0 then Exit(PPMD_SYM_END);
      mc := P8Ctx(p, mc^.Suffix);
    until mc^.NumStats <> numMasked;

    s := P8Stats(p, mc);
    num := Cardinal(mc^.NumStats) + 1;
    num2 := num shr 1;
    num := num and 1;
    hiCnt := (s^.Freq and UInt32(mask[s^.Symbol])) and (0 - UInt32(num));
    Inc(s, num);
    p^.MinContext := mc;
    repeat
      sym0 := s[0].Symbol;
      sym1 := s[1].Symbol;
      Inc(s, 2);
      hiCnt := hiCnt + (s[-2].Freq and UInt32(mask[sym0]));
      hiCnt := hiCnt + (s[-1].Freq and UInt32(mask[sym1]));
      Dec(num2);
    until num2 = 0;

    see := P8MakeEscFreq(p, numMasked, freqSum);
    freqSum := freqSum + hiCnt;
    freqSum2 := freqSum;
    if freqSum2 > p^.RcRange then freqSum2 := p^.RcRange;
    p^.RcRange := p^.RcRange div freqSum2;
    count := p^.RcCode div p^.RcRange;

    if count < hiCnt then
    begin
      s := P8Stats(p, p^.MinContext);
      hiCnt := count;
      repeat
        count := count - (s^.Freq and UInt32(mask[s^.Symbol]));
        Inc(s);
      until Int32(count) < 0;
      Dec(s);
      P8RcDecode(p, (hiCnt - count) - s^.Freq, s^.Freq);
      P8RcNormDec(p);
      SeeUpdate(see);
      p^.FoundState := s;
      Result := s^.Symbol;
      P8Update2(p);
      Exit;
    end;

    if count >= freqSum2 then Exit(PPMD_SYM_ERROR);
    P8RcDecode(p, hiCnt, freqSum2 - hiCnt);
    see^.Summ := Word(see^.Summ + freqSum);

    s := P8Stats(p, p^.MinContext);
    s2 := s + Cardinal(p^.MinContext^.NumStats) + 1;
    repeat
      mask[s^.Symbol] := 0;
      Inc(s);
    until s = s2;
  end;
end;

function P8DecodeSymbol(p: PPpmd8): Integer;
begin
  if p^.MinContext^.NumStats <> 0 then Result := P8DecodeFirst(p)
  else Result := P8DecodeBin(p);
  if Result = PPMD_SYM_ESC then Result := P8DecodeMasked(p);
end;
{$ENDIF}   // PPMD_ASM

{ ================================================================================ }
{ Motor y etapas                                                                    }
{ ================================================================================ }

function PpmdCheckParams(AOrder: Integer; AMemSize: Int64; ARestore: Integer): string;
begin
  Result := '';
  if (AOrder < PPMD_MIN_ORDER) or (AOrder > PPMD_MAX_ORDER) then
    Exit(Format('order %d out of range (%d..%d)', [AOrder, PPMD_MIN_ORDER, PPMD_MAX_ORDER]));
  if (AMemSize < PPMD_MIN_MEM) or (AMemSize > PPMD_MAX_MEM) then
    Exit(Format('memory %d out of range (%d..%d)', [AMemSize, Int64(PPMD_MIN_MEM), Int64(PPMD_MAX_MEM)]));
  if (ARestore <> PPMD_RESTORE_RESTART) and (ARestore <> PPMD_RESTORE_CUTOFF) then
    Exit(Format('unknown restore method %d', [ARestore]));
end;

procedure MakeHeader(out H: array of Byte; AOrder: Integer; AMem: UInt32; ARestore: Integer);
begin
  H[0] := Ord('P');
  H[1] := Ord('I');
  H[2] := Byte(AOrder);
  H[3] := Byte(ARestore);
  H[4] := Byte(AMem);
  H[5] := Byte(AMem shr 8);
  H[6] := Byte(AMem shr 16);
  H[7] := Byte(AMem shr 24);
end;

type
  { El modelo con su memoria }
  TPpmdEngine = class
  public
    Order, Restore: Integer;
    Mem: UInt32;
    P: PPpmd8;
    Heap: Pointer;
    Done: Boolean;
    constructor Create(AOrder: Integer; AMem: UInt32; ARestore: Integer);
    destructor Destroy; override;
  end;

constructor TPpmdEngine.Create(AOrder: Integer; AMem: UInt32; ARestore: Integer);
var
  align: UInt32;
begin
  inherited Create;
  Order := AOrder;
  Restore := ARestore;
  Mem := AMem;
  align := (4 - AMem) and 3;
  New(P);
  FillChar(P^, SizeOf(P^), 0);
  Heap := GetMem(PtrUInt(align) + AMem);
  P8Construct(P);
  P^.Base := Heap;
  P^.AlignOffset := align;
  P^.Size := AMem;
  P8Init(P, AOrder, ARestore);
  P^.IO.OutPos := @P^.IO.Buf[0];
  P^.IO.OutEnd := @P^.IO.Buf[IO_BUF - 1] + 1;
end;

destructor TPpmdEngine.Destroy;
begin
  if P <> nil then Dispose(P);
  FreeMem(Heap);
  inherited Destroy;
end;

{ TPpmdStage }

constructor TPpmdStage.Create(ASource: TInStage; AOrder: Integer; AMemSize: Int64; ARestore: Integer);
var
  Err: string;
begin
  // Todo lo que puede fallar va antes de inherited Create (que toma posesión de ASource)
  Err := PpmdCheckParams(AOrder, AMemSize, ARestore);
  if Err <> '' then raise EArcCorrupt.Create('ppmd: ' + Err);
  FEngine := TPpmdEngine.Create(AOrder, UInt32(AMemSize), ARestore);
  inherited Create(ASource);
end;

{ Cabecera e inicio del range coder: en el primer Read }
procedure TPpmdStage.Start;
var
  H, Want: array[0..PPMD_HEADER_SIZE - 1] of Byte;
  E: TPpmdEngine;
begin
  E := TPpmdEngine(FEngine);
  Source.ReadExact(@H[0], PPMD_HEADER_SIZE);
  MakeHeader(Want, E.Order, E.Mem, E.Restore);
  if not CompareMem(@H[0], @Want[0], PPMD_HEADER_SIZE) then
    Corrupt('ppmd: stream header does not match the method');
  E.P^.IO.Src := Source;
  if not P8RcInitDec(E.P) then Corrupt('ppmd: bad range coder start');
  FStarted := True;
end;

destructor TPpmdStage.Destroy;
begin
  FEngine.Free;
  inherited Destroy;
end;

function TPpmdStage.Read(Buf: PByte; Count: SizeInt): SizeInt;
var
  E: TPpmdEngine;
  p: PPpmd8;
  sym: Integer;
  n: SizeInt;
begin
  E := TPpmdEngine(FEngine);
  if E.Done or (Count <= 0) then Exit(0);
  if not FStarted then Start;
  p := E.P;
  n := 0;
  sym := 0;
  while n < Count do
  begin
    sym := P8DecodeSymbol(p);
    if sym < 0 then Break;
    Buf[n] := Byte(sym);
    Inc(n);
  end;
  if sym < 0 then
  begin
    if sym <> PPMD_SYM_END then Corrupt('ppmd: bad data');
    if (p^.RcCode <> 0) or (p^.IO.Overread <> 0) then Corrupt('ppmd: bad end of stream');
    E.Done := True;
  end;
  Result := n;
end;

{ TPpmdEncStage }

constructor TPpmdEncStage.Create(ATarget: TOutStage; AOrder: Integer; AMemSize: Int64; ARestore: Integer);
var
  Err: string;
  E: TPpmdEngine;
begin
  Err := PpmdCheckParams(AOrder, AMemSize, ARestore);
  if Err <> '' then raise Exception.Create('ppmd: ' + Err);
  E := TPpmdEngine.Create(AOrder, UInt32(AMemSize), ARestore);
  FEngine := E;
  inherited Create(ATarget);
  E.P^.IO.Sink := @StageSink;
  MakeHeader(E.P^.IO.Buf, AOrder, UInt32(AMemSize), ARestore);
  Inc(E.P^.IO.OutPos, PPMD_HEADER_SIZE);
  E.P^.RcLow := 0;
  E.P^.RcRange := $FFFFFFFF;
end;

destructor TPpmdEncStage.Destroy;
begin
  FEngine.Free;
  inherited Destroy;
end;

procedure TPpmdEncStage.StageSink(Buf: PByte; Count: SizeInt);
begin
  Emit(Buf, Count);
end;

procedure TPpmdEncStage.DoWrite(Buf: PByte; Count: SizeInt);
var
  p: PPpmd8;
  i: SizeInt;
begin
  p := TPpmdEngine(FEngine).P;
  for i := 0 to Count - 1 do P8EncodeSymbol(p, Buf[i]);
end;

procedure TPpmdEncStage.DoFinish;
var
  p: PPpmd8;
begin
  p := TPpmdEngine(FEngine).P;
  P8EncodeSymbol(p, -1);   // marca de fin
  P8RcFlush(p);
  IOFlush(@p^.IO);
end;

function PpmdCompress(InBuf: PByte; InLen: SizeInt; AOrder: Integer; AMemSize: Int64;
  ARestore: Integer; out Compressed: TBytes): Boolean;
var
  Sink: TMemSink;
  St: TPpmdEncStage;
begin
  Compressed := nil;
  if PpmdCheckParams(AOrder, AMemSize, ARestore) <> '' then Exit(False);
  Sink := TMemSink.Create;
  St := TPpmdEncStage.Create(Sink, AOrder, AMemSize, ARestore);
  try
    St.Write(InBuf, InLen);
    St.Finish;
    Compressed := Sink.Bytes;
  finally
    St.Free;   // libera también Sink
  end;
  Result := True;
end;

end.
