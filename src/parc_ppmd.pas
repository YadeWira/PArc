{ parc_ppmd — decodificador PPMd de FreeArc en Pascal.

  Port del PPMd de FreeArc 0.67 (Compression/PPMD/{Model.cpp,SubAlloc.hpp,
  Coder.hpp,PPMdType.h}) que EMULA EL LAYOUT DE MEMORIA DE 32 BITS.

  ¿Por qué hay que emularlo y no hacer un "PPMd normal" en 64 bits?  Porque esta
  variante de PPMd guarda Successor/Suffix como PUNTEROS REALES (bajo
  #pragma pack(1)) y sus decisiones dependen de la posición absoluta en el heap:
      pText >= UnitsStart, (BYTE*)Successor >= UnitsStart,
      GetUsedMemory() < (SubAllocatorSize >> 1)
  El encoder real (arc.exe / unarc.i386) es 32-bit.  Con punteros de 8 bytes el
  layout cambia, esas decisiones se corren y el decoder produce bytes distintos
  (falla el CRC) sin ningún acceso inválido de por medio.  Guardando las
  referencias como offsets UInt32 desde la base del heap, los tamaños vuelven a
  ser los de 32 bits y el decoder es bit a bit el mismo que el i386.

  Ver ppmd-port/PLAN.md para el mapa completo y las dos trampas de la arena. }

unit parc_ppmd;

{$mode objfpc}{$H+}
{$GOTO ON}   { el port usa goto (fiel al C++); no depender del fpc.cfg }

interface

uses
  Classes, SysUtils, parc_bytes, parc_stream, parc_outstream;

type
  { Destino de los bytes que emite el range encoder (una o más llamadas por byte
    comprimido). Es lo que permite que el lado encoder trabaje en streaming. }
  TPpmdEmitProc = procedure(Buf: PByte; Count: SizeInt) of object;

  { Etapa de descompresión PPMd (metodo "ppmd:ORDER:MEM[:chunk]").
    Lee de ASource y entrega los bytes decodificados.  Si los parámetros son
    inválidos, el constructor lanza ANTES de tomar posesión de la fuente (si no,
    el destructor liberaría una fuente que es del llamador). }
  TPpmdStage = class(TInStage)
  private
    FEngine: TObject;
  public
    constructor Create(ASource: TInStage; AOrder: Integer; AMemSize: Int64;
                       AMRMethod: Integer; AChunk: Int64);
    destructor Destroy; override;
    function Read(Buf: PByte; Count: SizeInt): SizeInt; override;
  end;

  { Etapa de COMPRESIÓN PPMd (metodo "ppmd:ORDER:MEM[:chunk]").
    PPMd es solidario para todo el stream, así que acumula lo que le llega con
    Write (el escritor manda pedazos de cualquier tamaño, típicamente de 1 MB) y
    comprime entero en DoFinish, que es donde emite todo. }
  TPpmdEncStage = class(TOutStage)
  private
    FOrder, FMemSize, FMRMethod: Integer;
    FEngine: TObject;
    procedure StageSink(Buf: PByte; Count: SizeInt);
  protected
    procedure DoWrite(Buf: PByte; Count: SizeInt); override;
    procedure DoFinish; override;
  public
    constructor Create(ATarget: TOutStage; AOrder: Integer; AMemSize: Int64;
                       AMRMethod: Integer; AChunk: Int64);
    destructor Destroy; override;
  end;

{ Comprime un buffer entero y devuelve el stream tal cual lo lee ppmd_decompress
  de FreeArc (sin encabezado ni framing). }
function PpmdCompress(InBuf: PByte; InLen: SizeInt;
                      AOrder, AMemSize, AMRMethod: Integer;
                      out Compressed: TBytes): Boolean;

const
  PPMD_MRM_RESTART = 0;
  PPMD_MRM_FREEZE  = 1;

implementation

const
  PPMD_SIGNATURE = $84ACAF8F;
  MIN_O = 2;
  MAX_O = 128;
  MIN_MEM = 2048;
  UP_FREQ = 5;
  INT_BITS = 7;
  PERIOD_BITS = 7;
  TOT_BITS = INT_BITS + PERIOD_BITS;
  INTERVAL = 1 shl INT_BITS;
  BIN_SCALE = 1 shl TOT_BITS;
  MAX_FREQ = 124;
  O_BOUND = 9;
  TOP = 1 shl 24;
  BOT = 1 shl 15;
  MRM_RESTART = 0;
  MRM_FREEZE = 1;
  UNIT_SIZE = 12;
  N1 = 4;
  N2 = 4;
  N3 = 4;
  N4 = 26;
  N_INDEXES = N1 + N2 + N3 + N4;
  STATE_SIZE = 6;
  CTX_SIZE = 12;
  IN_BUF_SIZE = 65536;
  OUT_BUF_SIZE = 65536;

  EXP_ESCAPE: array[0..15] of Byte =
    (25, 14, 9, 7, 5, 5, 4, 4, 4, 3, 3, 3, 2, 2, 2, 2);
  INIT_BIN_ESC: array[0..7] of Word =
    ($3CDD, $1F3F, $59BF, $48F3, $64A1, $5ABC, $6632, $6051);

type
  PState = ^TState;
  TState = packed record
    Symbol: Byte;
    Freq: Byte;
    Succ: LongWord;          { offset en el heap; 0 = NULL }
  end;

  PContext = ^TContext;
  TContext = packed record
    NumStats: Byte;
    Flags: Byte;
    SummFreq: Word;
    Stats: LongWord;         { se solapa con STATE.Succ de oneState() }
    Suffix: LongWord;
  end;

  PMemBlk = ^TMemBlk;
  TMemBlk = packed record
    Stamp: LongWord;
    Next: LongWord;
    NU: LongWord;
  end;

  PBlkNode = ^TBlkNode;
  TBlkNode = packed record
    Stamp: LongWord;
    Next: LongWord;
  end;

  PSee2 = ^TSee2;
  TSee2 = packed record
    Summ: Word;
    Shift: Byte;
    Count: Byte;
  end;

  TPpmdEngine = class
  private
    FSource: TInStage;
    FHeap: PByte;
    FSubAllocatorSize: LongWord;
    FpText, FUnitsStart, FLoUnit, FHiUnit, FGlueCount: LongWord;
    FBList: array[0..N_INDEXES - 1] of TBlkNode;
    FIndx2Units: array[0..N_INDEXES - 1] of Byte;
    FUnits2Indx: array[0..127] of Byte;
    FNS2BSIndx: array[0..255] of Byte;
    FQTable: array[0..259] of Byte;
    FBinSumm: array[0..24, 0..63] of Word;
    FSEE2Cont: array[0..23, 0..31] of TSee2;
    FDummySEE2: TSee2;
    FCharMask: array[0..255] of Byte;
    FFoundState, FMaxContext, FMinContext: LongWord;
    FOrderFall, FRunLength, FInitRL, FMaxOrder, FMRMethod: Integer;
    FEscCount, FNumMasked, FPrevSuccess, FInitEsc, FPrintCount, FNs: Byte;
    FLow, FCode, FRange, FSubLow, FSubHigh, FSubScale: LongWord;
    FAllocFailed: Boolean;
    FInBuf: array[0..IN_BUF_SIZE - 1] of Byte;
    FInLen, FInPos: SizeInt;
    FEncIn: PByte;
    FEncInLen, FEncInPos: SizeInt;
    FEncSink: TPpmdEmitProc;
    FEncBuf: array[0..4095] of Byte;
    FEncBufLen: Integer;
    FEncDone: Boolean;
    FOutBuf: array of Byte;
    FOutLen, FOutPos: SizeInt;
    FDone: Boolean;
    FState: Integer;
    FOrder, FMemSize, FMROrder: Integer;
    procedure InitTables;
    function  StOf(R: LongWord): PState; inline;
    function  CtxOf(R: LongWord): PContext; inline;
    function  BlkOf(R: LongWord): PMemBlk; inline;
    function  NodeOf(R: LongWord): PBlkNode; inline;
    function  OneOf(R: LongWord): PState; inline;
    function  U2B(NU: LongWord): LongWord; inline;
    procedure BListInsert(Indx: Integer; R: LongWord; NU: LongWord); inline;
    function  BListRemove(Indx: Integer): LongWord; inline;
    function  BListAvail(Indx: Integer): Boolean; inline;
    procedure StopSubAllocator;
    function  StartSubAllocator(Size: LongWord): Boolean;
    procedure InitSubAllocator;
    procedure SplitBlock(pv: LongWord; OldIndx, NewIndx: LongWord);
    procedure GlueFreeBlocks;
    function  AllocUnitsRare(indx: LongWord): LongWord;
    function  AllocUnits(NU: LongWord): LongWord; inline;
    function  AllocContext: LongWord; inline;
    procedure UnitsCpy(Dest, Src: LongWord; NU: LongWord);
    function  ExpandUnits(OldPtr: LongWord; OldNU: LongWord): LongWord;
    function  ShrinkUnits(OldPtr: LongWord; OldNU, NewNU: LongWord): LongWord;
    procedure FreeUnits(ptr: LongWord; NU: LongWord);
    procedure SpecialFreeUnit(ptr: LongWord);
    function  MoveUnitsUp(OldPtr: LongWord; NU: LongWord): LongWord;
    procedure ExpandTextArea;
    function  GetUsedMemory: LongWord;
    procedure ClearMask;
    procedure AriInitDecoder;
    procedure AriDecNormalize; inline;
    function  AriGetCurrentCount: LongWord; inline;
    function  AriGetCurrentShiftCount(SHIFT: Integer): LongWord; inline;
    procedure AriRemoveSubrange; inline;
    procedure See2Init(p: PSee2; InitVal: LongWord);
    function  See2GetMean(p: PSee2): LongWord; inline;
    procedure See2Update(p: PSee2); inline;
    function  MakeEscFreq2(ctx: LongWord): PSee2; inline;
    procedure SwapState(const a, b: PState); inline;
    procedure StateCpy(const a, b: PState); inline;
    procedure RefreshCtx(ctx: LongWord; OldNU: LongWord; Scale: Boolean);
    procedure Rescale(ctx: LongWord);
    function  CutOff(ctx: LongWord; Order: Integer): LongWord;
    function  RemoveBinConts(ctx: LongWord; Order: Integer): LongWord;
    procedure StartModelRare(_MaxOrder, _MRMethod: Integer);
    function  CreateSuccessors(Skip: Boolean; p: LongWord; pc: LongWord): LongWord;
    function  ReduceOrder(p: LongWord; pc: LongWord): LongWord;
    procedure UpdateModel(MinContext: LongWord);
    function  UpdateModelAdd(pc1, MinContext, Successor, FFreq: LongWord; FSymbol: Byte): LongWord;
    procedure RestoreModelRare(pc1: LongWord; MinContext: LongWord; FSuccessor: LongWord);
    function  DecodeBinSymbol(ctx: LongWord): Integer;
    function  DecodeSymbol1(ctx: LongWord): Integer;
    procedure DecodeRare(r: Integer; ctx: LongWord);
    function  DecodeSymbol2(ctx: LongWord): Integer;
    function  InByte: Integer; inline;
    procedure Emit(b: Byte); inline;
    procedure DecodeMore(ALimit: SizeInt);
    { --- lado encoder --- }
    function  EncInByte: Integer;
    procedure EncEmit(b: Byte); inline;
    procedure EncFlush;
    procedure EncSinkBuf(Buf: PByte; Count: SizeInt);
    procedure AriInitEncoder;
    procedure AriEncNormalize; inline;
    procedure AriEncodeSymbol; inline;
    procedure AriShiftEncodeSymbol(SHIFT: Integer); inline;
    procedure AriFlushEncoder;
    procedure EncodeBinSymbol(ctx: LongWord; symbol: Integer);
    function  EncodeSymbol1(ctx: LongWord; symbol: Integer): Boolean;
    function  EncodeSymbol2(ctx: LongWord; symbol: Integer): Boolean;
    procedure EncodeOne(c: Integer);
  public
    constructor Create(ASource: TInStage; AOrder: Integer; AMemSize: Int64;
                       AMRMethod: Integer; AChunk: Int64);
    destructor Destroy; override;
    function Read(Buf: PByte; Count: SizeInt): SizeInt;
    { Comprime un buffer entero. El motor de este lado no usa FSource. }
    function Compress(InBuf: PByte; InLen: SizeInt; out Compressed: TBytes): Boolean;
    { API en streaming: el motor nunca guarda la entrada, sólo el modelo. }
    procedure SetEncSink(AProc: TPpmdEmitProc);
    procedure StartEncode;
    procedure EncodeBytes(Buf: PByte; Count: SizeInt);
    procedure FinishEncode;
  end;

{ parc_ppmd_arena.inc — submallocador de PPMd con layout de 32 bits.
  Métodos de TPpmdEngine (se incluye dentro de la sección implementation). }

{ --- tablas de constantes (equivale a PPMD_STARTUP) ------------------------ }

procedure TPpmdEngine.InitTables;
var
  i, k, m, Step: LongInt;
begin
  k := 1;
  for i := 0 to N1 - 1 do
  begin
    FIndx2Units[i] := k; Inc(k);
  end;
  Inc(k);
  for i := N1 to N1 + N2 - 1 do
  begin
    FIndx2Units[i] := k; Inc(k, 2);
  end;
  Inc(k);
  for i := N1 + N2 to N1 + N2 + N3 - 1 do
  begin
    FIndx2Units[i] := k; Inc(k, 3);
  end;
  Inc(k);
  for i := N1 + N2 + N3 to N_INDEXES - 1 do
  begin
    FIndx2Units[i] := k; Inc(k, 4);
  end;
  k := 0; i := 0;
  while k < 128 do
  begin
    if FIndx2Units[i] < k + 1 then Inc(i);
    FUnits2Indx[k] := i;
    Inc(k);
  end;
  FNS2BSIndx[0] := 0;
  FNS2BSIndx[1] := 2;
  for i := 2 to 10 do FNS2BSIndx[i] := 4;
  for i := 11 to 255 do FNS2BSIndx[i] := 6;
  for i := 0 to UP_FREQ - 1 do FQTable[i] := i;
  m := UP_FREQ; i := UP_FREQ; k := 1; Step := 1;
  while i < 260 do
  begin
    FQTable[i] := m;
    Dec(k);
    if k = 0 then
    begin
      Inc(Step); k := Step; Inc(m);
    end;
    Inc(i);
  end;
  PLongWord(@FDummySEE2)^ := PPMD_SIGNATURE;
end;

{ --- heap ---------------------------------------------------------------- }

function TPpmdEngine.StOf(R: LongWord): PState; inline;
begin
  Result := PState(FHeap + R);
end;

function TPpmdEngine.CtxOf(R: LongWord): PContext; inline;
begin
  Result := PContext(FHeap + R);
end;

function TPpmdEngine.BlkOf(R: LongWord): PMemBlk;
begin
  Result := PMemBlk(FHeap + R);
end;

function TPpmdEngine.NodeOf(R: LongWord): PBlkNode;
begin
  Result := PBlkNode(FHeap + R);
end;

function TPpmdEngine.OneOf(R: LongWord): PState;
begin
  Result := PState(FHeap + R + 2);
end;

function TPpmdEngine.U2B(NU: LongWord): LongWord;
begin
  Result := UNIT_SIZE * NU;
end;

{ --- free lists ---------------------------------------------------------- }

procedure TPpmdEngine.BListInsert(Indx: Integer; R: LongWord; NU: LongWord);
begin
  BlkOf(R)^.Next := FBList[Indx].Next;
  FBList[Indx].Next := R;
  BlkOf(R)^.Stamp := $FFFFFFFF;
  BlkOf(R)^.NU := NU;
  Inc(FBList[Indx].Stamp);
end;

function TPpmdEngine.BListRemove(Indx: Integer): LongWord;
begin
  Result := FBList[Indx].Next;
  FBList[Indx].Next := BlkOf(Result)^.Next;
  Dec(FBList[Indx].Stamp);
end;

function TPpmdEngine.BListAvail(Indx: Integer): Boolean;
begin
  Result := FBList[Indx].Next <> 0;
end;

procedure TPpmdEngine.StopSubAllocator;
begin
  if FHeap <> nil then
  begin
    FreeMem(FHeap);
    FHeap := nil;
  end;
  FSubAllocatorSize := 0;
end;

function TPpmdEngine.StartSubAllocator(Size: LongWord): Boolean;
begin
  if FSubAllocatorSize = Size then Exit(True);
  StopSubAllocator;
  GetMem(FHeap, Size);
  if FHeap = nil then Exit(False);
  FSubAllocatorSize := Size;
  FAllocFailed := False;
  Result := True;
end;

procedure TPpmdEngine.InitSubAllocator;
var
  Diff: LongWord;
begin
  FillChar(FBList, SizeOf(FBList), 0);
  FHiUnit := FSubAllocatorSize;
  FpText := 0;
  Diff := UNIT_SIZE * (FSubAllocatorSize div 8 div UNIT_SIZE * 7);
  FUnitsStart := FHiUnit - Diff;
  FLoUnit := FUnitsStart;
  FGlueCount := 0;
end;

procedure TPpmdEngine.SplitBlock(pv: LongWord; OldIndx, NewIndx: LongWord);
var
  i, k, UDiff, p: LongWord;
begin
  UDiff := FIndx2Units[OldIndx] - FIndx2Units[NewIndx];
  p := pv + U2B(FIndx2Units[NewIndx]);
  i := FUnits2Indx[UDiff - 1];
  if FIndx2Units[i] <> UDiff then
  begin
    Dec(i);
    k := FIndx2Units[i];
    BListInsert(i, p, k);
    Inc(p, U2B(k));
    Dec(UDiff, k);
  end;
  BListInsert(FUnits2Indx[UDiff - 1], p, UDiff);
end;

procedure TPpmdEngine.GlueFreeBlocks;
var
  i, k, sz, p, p1: LongWord;
  s0: TBlkNode;
  p0: PBlkNode;
begin
  if FLoUnit <> FHiUnit then FHeap[FLoUnit] := 0;
  s0.Stamp := 0;
  s0.Next := 0;
  p0 := @s0;
  for i := 0 to N_INDEXES - 1 do
    while BListAvail(i) do
    begin
      p := BListRemove(i);
      if BlkOf(p)^.NU = 0 then Continue;
      p1 := p + U2B(BlkOf(p)^.NU);
      while BlkOf(p1)^.Stamp = $FFFFFFFF do
      begin
        Inc(BlkOf(p)^.NU, BlkOf(p1)^.NU);
        BlkOf(p1)^.NU := 0;
        p1 := p + U2B(BlkOf(p)^.NU);
      end;
      { p0->link(p): p->next = p0->next; p0->next = p; p0 = p }
      { ¡NO "SIMPLIFICAR" ESTO!  Encadenar en orden (con p0 avanzando) y no
        anteponer en s0 cambia el ORDEN de los bloques en las free lists y, por
        lo tanto, QUÉ DIRECCIÓN devuelve después cada asignación.  Como las
        decisiones del modelo PPMd (restart, pText>=UnitsStart, GetUsedMemory)
        dependen de direcciones absolutas del heap, un orden distinto produce
        una divergencia silenciosa: el decoder "casi" anda y da CRC mal. }
      BlkOf(p)^.Next := p0^.Next;
      p0^.Next := p;
      p0 := NodeOf(p);
    end;
  while s0.Next <> 0 do
  begin
    p := s0.Next;
    s0.Next := BlkOf(p)^.Next;
    Dec(s0.Stamp);
    sz := BlkOf(p)^.NU;
    if sz = 0 then Continue;
    while sz > 128 do
    begin
      Dec(sz, 128);
      BListInsert(N_INDEXES - 1, p, 128);
      Inc(p, U2B(128));
    end;
    i := FUnits2Indx[sz - 1];
    if FIndx2Units[i] <> sz then
    begin
      Dec(i);
      k := sz - FIndx2Units[i];
      BListInsert(k - 1, p + U2B(sz - k), k);
    end;
    BListInsert(i, p, FIndx2Units[i]);
  end;
  FGlueCount := 1 shl 13;
end;

function TPpmdEngine.AllocUnitsRare(indx: LongWord): LongWord;
var
  i: LongWord;
begin
  i := indx;
  if FGlueCount = 0 then
  begin
    GlueFreeBlocks;
    if BListAvail(i) then Exit(BListRemove(i));
  end;
  repeat
    Inc(i);
    if i = N_INDEXES then
    begin
      Dec(FGlueCount);
      i := U2B(FIndx2Units[indx]);
      if FUnitsStart - FpText > i then
      begin
        Dec(FUnitsStart, i);
        Exit(FUnitsStart);
      end;
      FAllocFailed := True;
      Exit(0);
    end;
  until BListAvail(i);
  Result := BListRemove(i);
  SplitBlock(Result, i, indx);
end;

function TPpmdEngine.AllocUnits(NU: LongWord): LongWord;
var
  indx: LongWord;
begin
  indx := FUnits2Indx[NU - 1];
  if BListAvail(indx) then Exit(BListRemove(indx));
  Result := FLoUnit;
  Inc(FLoUnit, U2B(FIndx2Units[indx]));
  if FLoUnit <= FHiUnit then Exit;
  Dec(FLoUnit, U2B(FIndx2Units[indx]));
  Result := AllocUnitsRare(indx);
end;

function TPpmdEngine.AllocContext: LongWord;
begin
  if FHiUnit <> FLoUnit then
  begin
    Dec(FHiUnit, UNIT_SIZE);
    Exit(FHiUnit);
  end;
  if BListAvail(0) then Exit(BListRemove(0));
  Result := AllocUnitsRare(0);
end;

procedure TPpmdEngine.UnitsCpy(Dest, Src: LongWord; NU: LongWord);
begin
  if NU > 0 then Move(FHeap[Src], FHeap[Dest], NU * UNIT_SIZE);
end;

function TPpmdEngine.ExpandUnits(OldPtr: LongWord; OldNU: LongWord): LongWord;
var
  i0, i1: LongWord;
begin
  i0 := FUnits2Indx[OldNU - 1];
  i1 := FUnits2Indx[OldNU];
  if i0 = i1 then Exit(OldPtr);
  Result := AllocUnits(OldNU + 1);
  if Result <> 0 then
  begin
    UnitsCpy(Result, OldPtr, OldNU);
    BListInsert(i0, OldPtr, OldNU);
  end;
end;

function TPpmdEngine.ShrinkUnits(OldPtr: LongWord; OldNU, NewNU: LongWord): LongWord;
var
  i0, i1: LongWord;
begin
  i0 := FUnits2Indx[OldNU - 1];
  i1 := FUnits2Indx[NewNU - 1];
  if i0 = i1 then Exit(OldPtr);
  if BListAvail(i1) then
  begin
    Result := BListRemove(i1);
    UnitsCpy(Result, OldPtr, NewNU);
    BListInsert(i0, OldPtr, FIndx2Units[i0]);
  end
  else
  begin
    SplitBlock(OldPtr, i0, i1);
    Result := OldPtr;
  end;
end;

procedure TPpmdEngine.FreeUnits(ptr: LongWord; NU: LongWord);
var
  indx: LongWord;
begin
  indx := FUnits2Indx[NU - 1];
  BListInsert(indx, ptr, FIndx2Units[indx]);
end;

procedure TPpmdEngine.SpecialFreeUnit(ptr: LongWord);
begin
  if ptr <> FUnitsStart then
    BListInsert(0, ptr, 1)
  else
  begin
    PLongWord(FHeap + ptr)^ := $FFFFFFFF;
    Inc(FUnitsStart, UNIT_SIZE);
  end;
end;

function TPpmdEngine.MoveUnitsUp(OldPtr: LongWord; NU: LongWord): LongWord;
var
  indx, n, ptr: LongWord;
begin
  indx := FUnits2Indx[NU - 1];
  if (OldPtr > FUnitsStart + 16 * 1024) or (OldPtr > FBList[indx].Next) then
    Exit(OldPtr);
  ptr := BListRemove(indx);
  UnitsCpy(ptr, OldPtr, NU);
  n := FIndx2Units[indx];
  if OldPtr <> FUnitsStart then
    BListInsert(indx, OldPtr, n)
  else
    Inc(FUnitsStart, U2B(n));
  Result := ptr;
end;

procedure TPpmdEngine.ExpandTextArea;
var
  Count: array[0..N_INDEXES - 1] of LongWord;
  i: LongWord;
  head: TBlkNode;
  cur: PBlkNode;
begin
  FillChar(Count, SizeOf(Count), 0);
  while BlkOf(FUnitsStart)^.Stamp = $FFFFFFFF do
  begin
    Inc(Count[FUnits2Indx[BlkOf(FUnitsStart)^.NU - 1]]);
    i := FUnitsStart + U2B(BlkOf(FUnitsStart)^.NU);
    BlkOf(FUnitsStart)^.Stamp := 0;
    FUnitsStart := i;
  end;
  for i := 0 to N_INDEXES - 1 do
  begin
    if Count[i] = 0 then Continue;
    { ¡OJO! La lista se recorre DESDE LA CABEZA, y la cabeza (BList[i]) vive
      FUERA del heap: es un contador, no un bloque.  Por eso se copia a un
      TBlkNode local, se desenganchan los nodos con Stamp==0 sobre la copia y se
      escribe de vuelta.  No convertir esto en un recorrido "solo del heap":
      la cabeza es el primer nodo y además es la que lleva Stamp. }
    head := FBList[i];
    cur := @head;
    while Count[i] <> 0 do
    begin
      while (cur^.Next <> 0) and (BlkOf(cur^.Next)^.Stamp = 0) do
      begin
        cur^.Next := BlkOf(cur^.Next)^.Next;
        Dec(head.Stamp);
        Dec(Count[i]);
        if Count[i] = 0 then Break;
      end;
      if (Count[i] = 0) or (cur^.Next = 0) then Break;
      cur := NodeOf(cur^.Next);
    end;
    FBList[i] := head;
  end;
end;

function TPpmdEngine.GetUsedMemory: LongWord;
var
  i: LongWord;
begin
  Result := FSubAllocatorSize - (FHiUnit - FLoUnit) - (FUnitsStart - FpText);
  for i := 0 to N_INDEXES - 1 do
    Dec(Result, UNIT_SIZE * FIndx2Units[i] * FBList[i].Stamp);
end;

{ --- máscara de símbolos (CharMask) ------------------------------------- }

procedure TPpmdEngine.ClearMask;
begin
  FEscCount := 1;
  FillChar(FCharMask, SizeOf(FCharMask), 0);
  Inc(FPrintCount);   { PrintInfo es no-op, como en el original }
end;

{ parc_ppmd_model.inc — rango-coder + modelo PPMd (solo decodificación).
  Métodos de TPpmdEngine. Traducción directa de Model.cpp/Coder.hpp;
  el orden de operaciones importa (bit a bit), no "mejorar" nada. }

{ --- rango-coder (Coder.hpp) -------------------------------------------- }

procedure TPpmdEngine.AriInitDecoder;
var
  i: Integer;
begin
  FLow := 0; FCode := 0; FRange := $FFFFFFFF;
  for i := 0 to 3 do FCode := (FCode shl 8) or LongWord(InByte);
end;

procedure TPpmdEngine.AriDecNormalize;
begin
  while True do
  begin
    if (FLow xor (FLow + FRange)) < TOP then
      { sigue }
    else if FRange < BOT then
      FRange := (LongWord(0) - FLow) and (BOT - 1)
    else
      Break;
    FCode := (FCode shl 8) or LongWord(InByte);
    FRange := FRange shl 8;
    FLow := FLow shl 8;
  end;
end;

function TPpmdEngine.AriGetCurrentCount: LongWord;
begin
  if FSubScale = 0 then Corrupt('ppmd: escala 0');
  FRange := FRange div FSubScale;
  if FRange = 0 then Corrupt('ppmd: rango 0');
  Result := LongWord(FCode - FLow) div FRange;  { PARC: 32-bit div, no idiv r64 }
end;

function TPpmdEngine.AriGetCurrentShiftCount(SHIFT: Integer): LongWord;
begin
  FRange := FRange shr SHIFT;
  if FRange = 0 then Corrupt('ppmd: rango 0');
  Result := LongWord(FCode - FLow) div FRange;  { PARC: 32-bit div, no idiv r64 }
end;

procedure TPpmdEngine.AriRemoveSubrange;
begin
  Inc(FLow, FRange * FSubLow);
  FRange := FRange * (FSubHigh - FSubLow);
end;

{ --- SEE2 / helpers ------------------------------------------------------ }

procedure TPpmdEngine.See2Init(p: PSee2; InitVal: LongWord);
begin
  p^.Shift := PERIOD_BITS - 4;
  p^.Summ := Word(InitVal shl (PERIOD_BITS - 4));
  p^.Count := 7;
end;

function TPpmdEngine.See2GetMean(p: PSee2): LongWord;
var
  RetVal: LongWord;
begin
  RetVal := p^.Summ shr p^.Shift;
  p^.Summ := Word(p^.Summ - RetVal);
  Result := RetVal + LongWord(Ord(RetVal = 0));
end;

procedure TPpmdEngine.See2Update(p: PSee2);
begin
  if (p^.Shift < PERIOD_BITS) then
  begin
    Dec(p^.Count);
    if p^.Count = 0 then
    begin
      p^.Summ := Word(p^.Summ + p^.Summ);
      p^.Count := Byte(3 shl p^.Shift);
      Inc(p^.Shift);
    end;
  end;
end;

function TPpmdEngine.MakeEscFreq2(ctx: LongWord): PSee2;
var
  H: PByte;
  t, row, col: LongWord;
begin
  H := FHeap;
  if PContext(H + ctx)^.NumStats <> $FF then
  begin
    t := PContext(H + PContext(H + ctx)^.Suffix)^.NumStats;
    row := FQTable[PContext(H + ctx)^.NumStats + 2] - 3;
    col := Ord(PContext(H + ctx)^.SummFreq > 11 * (PContext(H + ctx)^.NumStats + 1));
    Inc(col, 2 * Ord(2 * PContext(H + ctx)^.NumStats < t + FNumMasked) + PContext(H + ctx)^.Flags);
    Result := @FSEE2Cont[row][col];
    FSubScale := See2GetMean(Result);
  end
  else
  begin
    Result := @FDummySEE2;
    FSubScale := 1;
  end;
end;

{ --- operaciones sobre STATES ------------------------------------------- }

procedure TPpmdEngine.SwapState(const a, b: PState);
var
  t1: Word;
  t2: LongWord;
begin
  t1 := PWord(a)^;  t2 := a^.Succ;
  PWord(a)^ := PWord(b)^;  a^.Succ := b^.Succ;
  PWord(b)^ := t1;         b^.Succ := t2;
end;

procedure TPpmdEngine.StateCpy(const a, b: PState);
begin
  PWord(a)^ := PWord(b)^;
  a^.Succ := b^.Succ;
end;

{ --- refresh / rescale -------------------------------------------------- }

procedure TPpmdEngine.RefreshCtx(ctx: LongWord; OldNU: LongWord; Scale: Boolean);
var
  i, EscFreq: LongInt;
  p: LongWord;
  sc: LongWord;
begin
  sc := Ord(Scale);
  i := CtxOf(ctx)^.NumStats;
  p := ShrinkUnits(CtxOf(ctx)^.Stats, OldNU, (LongWord(i) + 2) shr 1);
  CtxOf(ctx)^.Stats := p;
  CtxOf(ctx)^.Flags := (CtxOf(ctx)^.Flags and (byte($10) or byte($04 * sc)))
                      or (byte($08) * Ord(StOf(p)^.Symbol >= $40));
  EscFreq := LongInt(CtxOf(ctx)^.SummFreq) - StOf(p)^.Freq;
  StOf(p)^.Freq := (StOf(p)^.Freq + sc) shr sc;
  CtxOf(ctx)^.SummFreq := StOf(p)^.Freq;
  repeat
    Inc(p, STATE_SIZE);
    Dec(EscFreq, StOf(p)^.Freq);
    StOf(p)^.Freq := (StOf(p)^.Freq + sc) shr sc;
    Inc(CtxOf(ctx)^.SummFreq, StOf(p)^.Freq);
    CtxOf(ctx)^.Flags := CtxOf(ctx)^.Flags or (byte($08) * Ord(StOf(p)^.Symbol >= $40));
    Dec(i);
  until i = 0;
  EscFreq := (EscFreq + LongInt(sc)) shr sc;
  Inc(CtxOf(ctx)^.SummFreq, Word(EscFreq));
end;

procedure TPpmdEngine.Rescale(ctx: LongWord);
var
  H: PByte;
  i, EscFreq, Adder, OldNU: LongInt;
  p: LongWord;
  tmp: TState;
  ps, q: PState;
  C: PContext;
begin
  H := FHeap;
  i := PContext(H + ctx)^.NumStats;
  p := FFoundState;
  while p <> PContext(H + ctx)^.Stats do
  begin
    SwapState(PState(H + p), PState(H + p - STATE_SIZE));
    Dec(p, STATE_SIZE);
  end;
  Inc(PState(H + p)^.Freq, 4);
  Inc(PContext(H + ctx)^.SummFreq, 4);
  EscFreq := LongInt(PContext(H + ctx)^.SummFreq) - PState(H + p)^.Freq;
  if (FOrderFall <> 0) or (FMRMethod > MRM_FREEZE) then Adder := 1 else Adder := 0;
  PState(H + p)^.Freq := (PState(H + p)^.Freq + LongWord(Adder)) shr 1;
  PContext(H + ctx)^.SummFreq := PState(H + p)^.Freq;
  // Con punteros locales: el heap no se mueve y StOf relee FHeap en cada acceso
  C := PContext(FHeap + ctx);
  ps := PState(FHeap + p);
  repeat
    Inc(ps);
    Dec(EscFreq, ps^.Freq);
    ps^.Freq := (ps^.Freq + LongWord(Adder)) shr 1;
    Inc(C^.SummFreq, ps^.Freq);
    if ps^.Freq > (ps - 1)^.Freq then
    begin
      tmp := ps^;
      q := ps;
      repeat
        q^ := (q - 1)^;
        Dec(q);
      until not (tmp.Freq > (q - 1)^.Freq);
      q^ := tmp;
    end;
    Dec(i);
  until i = 0;
  p := LongWord(PByte(ps) - FHeap);
  if PState(H + p)^.Freq = 0 then
  begin
    repeat
      Inc(i);
      Dec(p, STATE_SIZE);
    until PState(H + p)^.Freq <> 0;
    Inc(EscFreq, i);
    OldNU := LongInt((PContext(H + ctx)^.NumStats + 2) shr 1);
    Dec(PContext(H + ctx)^.NumStats, Byte(i));
    if PContext(H + ctx)^.NumStats = 0 then
    begin
      StateCpy(@tmp, PState(H + PContext(H + ctx)^.Stats));
      tmp.Freq := Byte((2 * LongInt(tmp.Freq) + EscFreq - 1) div EscFreq);
      if tmp.Freq > MAX_FREQ div 3 then tmp.Freq := MAX_FREQ div 3;
      FreeUnits(PContext(H + ctx)^.Stats, LongWord(OldNU));
      StateCpy(PState(H + 2 + ctx), @tmp);
      PContext(H + ctx)^.Flags := (PContext(H + ctx)^.Flags and $10) or (byte($08) * Ord(tmp.Symbol >= $40));
      FFoundState := ctx + 2;
      Exit;
    end;
    PContext(H + ctx)^.Stats := ShrinkUnits(PContext(H + ctx)^.Stats, LongWord(OldNU),
                                   (PContext(H + ctx)^.NumStats + 2) shr 1);
    PContext(H + ctx)^.Flags := PContext(H + ctx)^.Flags and not byte($08);
    i := PContext(H + ctx)^.NumStats;
    p := PContext(H + ctx)^.Stats;
    PContext(H + ctx)^.Flags := PContext(H + ctx)^.Flags or (byte($08) * Ord(PState(H + p)^.Symbol >= $40));
    repeat
      Inc(p, STATE_SIZE);
      PContext(H + ctx)^.Flags := PContext(H + ctx)^.Flags or (byte($08) * Ord(PState(H + p)^.Symbol >= $40));
      Dec(i);
    until i = 0;
  end;
  EscFreq := EscFreq - (EscFreq shr 1);
  Inc(PContext(H + ctx)^.SummFreq, Word(EscFreq));
  PContext(H + ctx)^.Flags := PContext(H + ctx)^.Flags or $04;
  FFoundState := PContext(H + ctx)^.Stats;
end;

{ --- cutOff / removeBinConts ------------------------------------------- }

function TPpmdEngine.CutOff(ctx: LongWord; Order: Integer): LongWord;
var
  i, Order2: Integer;
  p, tmp: LongWord;
  remove: Boolean;
begin
  if CtxOf(ctx)^.NumStats = 0 then
  begin
    p := ctx + 2;                       { &oneState() }
    if StOf(p)^.Succ >= FUnitsStart then
    begin
      if Order < FMaxOrder then
        StOf(p)^.Succ := CutOff(StOf(p)^.Succ, Order + 1)
      else
        StOf(p)^.Succ := 0;
      if (StOf(p)^.Succ = 0) and (Order > O_BOUND) then
      begin
        SpecialFreeUnit(ctx);
        Exit(0);
      end;
      Exit(ctx);
    end
    else
    begin
      SpecialFreeUnit(ctx);
      Exit(0);
    end;
  end;
  CtxOf(ctx)^.Stats := MoveUnitsUp(CtxOf(ctx)^.Stats, (CtxOf(ctx)^.NumStats + 2) shr 1);
  tmp := (CtxOf(ctx)^.NumStats + 2) shr 1;
  i := CtxOf(ctx)^.NumStats;
  p := CtxOf(ctx)^.Stats + LongWord(i) * STATE_SIZE;
  while True do
  begin
    if StOf(p)^.Succ < FUnitsStart then
    begin
      StOf(p)^.Succ := 0;
      SwapState(StOf(p), StOf(CtxOf(ctx)^.Stats + LongWord(i) * STATE_SIZE));
      Dec(i);
    end
    else if Order < FMaxOrder then
      StOf(p)^.Succ := CutOff(StOf(p)^.Succ, Order + 1)
    else
      StOf(p)^.Succ := 0;
    if p = CtxOf(ctx)^.Stats then Break;
    Dec(p, STATE_SIZE);
  end;
  if (i <> CtxOf(ctx)^.NumStats) and (Order <> 0) then
  begin
    CtxOf(ctx)^.NumStats := Byte(i);
    p := CtxOf(ctx)^.Stats;
    if i < 0 then
    begin
      FreeUnits(p, LongWord(tmp));
      SpecialFreeUnit(ctx);
      Exit(0);
    end
    else if i = 0 then
    begin
      CtxOf(ctx)^.Flags := (CtxOf(ctx)^.Flags and $10) or (byte($08) * Ord(StOf(p)^.Symbol >= $40));
      StateCpy(OneOf(ctx), StOf(p));
      FreeUnits(p, LongWord(tmp));
      OneOf(ctx)^.Freq := (OneOf(ctx)^.Freq + 11) shr 3;
    end
    else
      RefreshCtx(ctx, LongWord(tmp), CtxOf(ctx)^.SummFreq > 16 * i);
  end;
  Result := ctx;
end;

function TPpmdEngine.RemoveBinConts(ctx: LongWord; Order: Integer): LongWord;
var
  p: LongWord;
begin
  if CtxOf(ctx)^.NumStats = 0 then
  begin
    p := ctx + 2;
    if (StOf(p)^.Succ >= FUnitsStart) and (Order < FMaxOrder) then
      StOf(p)^.Succ := RemoveBinConts(StOf(p)^.Succ, Order + 1)
    else
      StOf(p)^.Succ := 0;
    if (StOf(p)^.Succ = 0) and ((CtxOf(CtxOf(ctx)^.Suffix)^.NumStats = 0)
                              or (CtxOf(CtxOf(ctx)^.Suffix)^.Flags = $FF)) then
    begin
      FreeUnits(ctx, 1);
      Exit(0);
    end;
    Exit(ctx);
  end;
  p := CtxOf(ctx)^.Stats + LongWord(CtxOf(ctx)^.NumStats) * STATE_SIZE;
  while True do
  begin
    if (StOf(p)^.Succ >= FUnitsStart) and (Order < FMaxOrder) then
      StOf(p)^.Succ := RemoveBinConts(StOf(p)^.Succ, Order + 1)
    else
      StOf(p)^.Succ := 0;
    if p = CtxOf(ctx)^.Stats then Break;
    Dec(p, STATE_SIZE);
  end;
  Result := ctx;
end;

{ parc_ppmd_model2.inc — modelo PPMd, parte 2: sucesores, actualización y
  las tres rutinas de decodificación.  Traducción directa de Model.cpp. }

procedure TPpmdEngine.StartModelRare(_MaxOrder, _MRMethod: Integer);
var
  i, k, m: LongWord;
  pc: LongWord;
  st: LongWord;
begin
  FillChar(FCharMask, SizeOf(FCharMask), 0);
  FEscCount := 1; FPrintCount := 1;
  if _MaxOrder < 2 then
  begin
    FOrderFall := FMaxOrder;
    pc := FMaxContext;
    while CtxOf(pc)^.Suffix <> 0 do
    begin
      Dec(FOrderFall);
      pc := CtxOf(pc)^.Suffix;
    end;
    Exit;
  end;
  FOrderFall := _MaxOrder; FMaxOrder := _MaxOrder; FMRMethod := _MRMethod;
  InitSubAllocator;
  if FMaxOrder < 12 then FRunLength := -(FMaxOrder) - 1 else FRunLength := -13;
  FInitRL := FRunLength;
  FMaxContext := AllocContext;
  CtxOf(FMaxContext)^.Suffix := 0;
  CtxOf(FMaxContext)^.NumStats := 255;
  CtxOf(FMaxContext)^.SummFreq := 257;
  CtxOf(FMaxContext)^.Stats := AllocUnits(256 div 2);
  FPrevSuccess := 0;
  st := CtxOf(FMaxContext)^.Stats;
  for i := 0 to 255 do
  begin
    StOf(st + i * STATE_SIZE)^.Symbol := Byte(i);
    StOf(st + i * STATE_SIZE)^.Freq := 1;
    StOf(st + i * STATE_SIZE)^.Succ := 0;
  end;
  i := 0; m := 0;
  while m < 25 do
  begin
    while FQTable[i] = m do Inc(i);
    for k := 0 to 7 do
      FBinSumm[m][k] := BIN_SCALE - INIT_BIN_ESC[k] div (i + 1);
    k := 8;
    while k < 64 do
    begin
      Move(FBinSumm[m][0], FBinSumm[m][k], 8 * SizeOf(Word));
      Inc(k, 8);
    end;
    Inc(m);
  end;
  i := 0; m := 0;
  while m < 24 do
  begin
    while FQTable[i + 3] = m + 3 do Inc(i);
    See2Init(@FSEE2Cont[m][0], 2 * i + 5);
    for k := 1 to 31 do FSEE2Cont[m][k] := FSEE2Cont[m][0];
    Inc(m);
  end;
end;

{ PARC: búsqueda de símbolo en una función suelta y pequeña: dentro de UpdateModel /
  CreateSuccessors FPC volcaba p, H y sym a la pila y el bucle iba por memoria. }
function PpmdFindSym(p: PState; sym: Byte): PState;
begin
  while p^.Symbol <> sym do Inc(p);
  Result := p;
end;

function TPpmdEngine.CreateSuccessors(Skip: Boolean; p: LongWord; pc: LongWord): LongWord;
label
  NO_LOOP, LOOP_ENTRY;
var
  H: PByte;
  ct: TContext;
  ctOne: PState;
  UpBranch: LongWord;
  ps: array[0..MAX_O] of LongWord;
  n: Integer;
  cf, s0: LongWord;
  tmp: Byte;
  sym: Byte;
  pc1: LongWord;
begin
  H := FHeap;
  UpBranch := PState(H + FFoundState)^.Succ;
  n := 0;
  sym := PState(H + FFoundState)^.Symbol;
  if not Skip then
  begin
    ps[n] := FFoundState; Inc(n);
    if PContext(H + pc)^.Suffix = 0 then goto NO_LOOP;
  end;
  if p <> 0 then
  begin
    pc := PContext(H + pc)^.Suffix;
    goto LOOP_ENTRY;
  end;
  while True do
  begin
    pc := PContext(H + pc)^.Suffix;
    if PContext(H + pc)^.NumStats <> 0 then
    begin
      p := PContext(H + pc)^.Stats;
      p := LongWord(PByte(PpmdFindSym(PState(H + p), sym)) - H);
      if PState(H + p)^.Freq < MAX_FREQ - 9 then tmp := 1 else tmp := 0;
      Inc(PState(H + p)^.Freq, tmp);
      Inc(PContext(H + pc)^.SummFreq, tmp);
    end
    else
    begin
      p := pc + 2;
      if (PContext(H + PContext(H + pc)^.Suffix)^.NumStats = 0) and (PState(H + p)^.Freq < 24) then
        Inc(PState(H + p)^.Freq);
    end;
  LOOP_ENTRY:
    if PState(H + p)^.Succ <> UpBranch then
    begin
      pc := PState(H + p)^.Succ;
      Break;
    end;
    ps[n] := p; Inc(n);
    if PContext(H + pc)^.Suffix = 0 then Break;
  end;
NO_LOOP:
  if n = 0 then Exit(pc);
  { PARC: en cero sin llamar a FillChar (son 12 bytes) }
  PQWord(@ct)^ := 0;
  PLongWord(PByte(@ct) + 8)^ := 0;
  ctOne := PState(PByte(@ct) + 2);
  ct.NumStats := 0;
  if sym >= $40 then ct.Flags := $10 else ct.Flags := 0;
  sym := H[UpBranch];
  ctOne^.Symbol := sym;
  ctOne^.Succ := UpBranch + 1;
  if sym >= $40 then ct.Flags := ct.Flags or $08;
  if PContext(H + pc)^.NumStats <> 0 then
  begin
    p := PContext(H + pc)^.Stats;
    p := LongWord(PByte(PpmdFindSym(PState(H + p), sym)) - H);
    s0 := PContext(H + pc)^.SummFreq - PContext(H + pc)^.NumStats - (PState(H + p)^.Freq - 1);
    cf := PState(H + p)^.Freq - 1;
    if 2 * cf <= s0 then
    begin
      if 5 * cf > s0 then ctOne^.Freq := 2 else ctOne^.Freq := 1;
    end
    else
      ctOne^.Freq := Byte(1 + LongWord(cf + 2 * s0 - 3) div s0);
  end
  else
    ctOne^.Freq := PState(H + 2 + pc)^.Freq;
  repeat
    pc1 := AllocContext;
    if pc1 = 0 then Exit(0);
    PContext(H + pc1)^ := ct;
    PContext(H + pc1)^.Suffix := pc;
    Dec(n);
    PState(H + ps[n])^.Succ := pc1;
    pc := pc1;
  until n = 0;
  Result := pc;
end;

function TPpmdEngine.ReduceOrder(p: LongWord; pc: LongWord): LongWord;
label
  FROZEN, LOOP_ENTRY;
var
  H: PByte;
  ps: array[0..MAX_O] of LongWord;
  n: Integer;
  pc1, UpBranch, p1: LongWord;
  tmp, sym: Byte;
begin
  H := FHeap;
  pc1 := pc;
  UpBranch := FpText;
  n := 0;
  sym := PState(H + FFoundState)^.Symbol;
  ps[n] := FFoundState; Inc(n);
  PState(H + FFoundState)^.Succ := UpBranch;
  Inc(FOrderFall);
  if p <> 0 then
  begin
    pc := PContext(H + pc)^.Suffix;
    goto LOOP_ENTRY;
  end;
  while True do
  begin
    if PContext(H + pc)^.Suffix = 0 then
    begin
      if FMRMethod > MRM_FREEZE then
      begin
      FROZEN:
        repeat
          Dec(n);
          PState(H + ps[n])^.Succ := pc;
        until n = 0;
        FpText := 1;
        FOrderFall := 1;
      end;
      Exit(pc);
    end;
    pc := PContext(H + pc)^.Suffix;
    if PContext(H + pc)^.NumStats <> 0 then
    begin
      p := PContext(H + pc)^.Stats;
      p := LongWord(PByte(PpmdFindSym(PState(H + p), sym)) - H);
      if PState(H + p)^.Freq < MAX_FREQ - 9 then tmp := 2 else tmp := 0;
      Inc(PState(H + p)^.Freq, tmp);
      Inc(PContext(H + pc)^.SummFreq, tmp);
    end
    else
    begin
      p := pc + 2;
      if PState(H + p)^.Freq < 32 then Inc(PState(H + p)^.Freq);
    end;
  LOOP_ENTRY:
    if PState(H + p)^.Succ <> 0 then Break;
    ps[n] := p; Inc(n);
    PState(H + p)^.Succ := UpBranch;
    Inc(FOrderFall);
  end;
  if FMRMethod > MRM_FREEZE then
  begin
    pc := PState(H + p)^.Succ;
    goto FROZEN;
  end
  else if PState(H + p)^.Succ <= UpBranch then
  begin
    p1 := FFoundState;
    FFoundState := p;
    PState(H + p)^.Succ := CreateSuccessors(False, 0, pc);
    FFoundState := p1;
  end;
  if (FOrderFall = 1) and (pc1 = FMaxContext) then
  begin
    PState(H + FFoundState)^.Succ := PState(H + p)^.Succ;
    Dec(FpText);
  end;
  Result := PState(H + p)^.Succ;
end;

{ PARC: el bucle final de UpdateModel (agregar el símbolo a los contextos de pc1 hasta
  MinContext) va en un método aparte: con todo junto FPC volcaba casi todas las variables a
  la pila. Devuelve 0, o el pc1 donde falló la memoria (para RestoreModelRare). }
function TPpmdEngine.UpdateModelAdd(pc1, MinContext, Successor, FFreq: LongWord;
                                    FSymbol: Byte): LongWord;
var
  H: PByte;
  p: LongWord;
  ns1, ns, cf, sf, s0, sfc: LongWord;
  C: PContext;
  ps: PState;
  Flag: Byte;
begin
  H := FHeap;
  s0 := PContext(H + MinContext)^.SummFreq - PContext(H + MinContext)^.NumStats - FFreq;
  ns := PContext(H + MinContext)^.NumStats;
  if FSymbol >= $40 then Flag := $08 else Flag := 0;
  while pc1 <> MinContext do
  begin
    { PARC: puntero local al contexto (el heap no se mueve durante la llamada) }
    C := PContext(H + pc1);
    ns1 := C^.NumStats;
    if ns1 <> 0 then
    begin
      if (ns1 and 1) <> 0 then
      begin
        p := ExpandUnits(C^.Stats, (ns1 + 1) shr 1);
        if p = 0 then Exit(pc1);
        C^.Stats := p;
      end;
      if 3 * ns1 + 1 < ns then Inc(C^.SummFreq);
    end
    else
    begin
      p := AllocUnits(1);
      if p = 0 then Exit(pc1);
      ps := PState(H + p);
      StateCpy(ps, PState(H + 2 + pc1));
      C^.Stats := p;
      if ps^.Freq < MAX_FREQ div 4 - 1 then
        ps^.Freq := ps^.Freq + ps^.Freq
      else
        ps^.Freq := MAX_FREQ - 4;
      if ns > 2 then
        C^.SummFreq := ps^.Freq + FInitEsc + 1
      else
        C^.SummFreq := ps^.Freq + FInitEsc;
    end;
    sfc := C^.SummFreq;
    cf := 2 * FFreq * (sfc + 6);
    sf := s0 + sfc;
    if cf < 6 * sf then
    begin
      cf := 1 + Ord(cf > sf) + Ord(cf >= 4 * sf);
      C^.SummFreq := Word(sfc + 4);
    end
    else
    begin
      cf := 4 + Ord(cf > 9 * sf) + Ord(cf > 12 * sf) + Ord(cf > 15 * sf);
      C^.SummFreq := Word(sfc + cf);
    end;
    ns1 := Byte(C^.NumStats + 1);
    C^.NumStats := ns1;
    ps := PState(H + C^.Stats + ns1 * STATE_SIZE);
    ps^.Succ := Successor;
    ps^.Symbol := FSymbol;
    ps^.Freq := Byte(cf);
    C^.Flags := C^.Flags or Flag;
    pc1 := C^.Suffix;
  end;
  Result := 0;
end;

procedure TPpmdEngine.UpdateModel(MinContext: LongWord);
label
  RESTART_MODEL;
var
  H: PByte;
  p: LongWord;
  Successor, FSuccessor, pc, pc1: LongWord;
  cf, FFreq: LongWord;
  FSymbol: Byte;
begin
  H := FHeap;
  pc1 := FMaxContext;
  p := 0;      { en el C es STATE* p=NULL; ReduceOrder lo recibe tal cual }
  FFreq := PState(H + FFoundState)^.Freq;
  FSymbol := PState(H + FFoundState)^.Symbol;
  FSuccessor := PState(H + FFoundState)^.Succ;
  pc := PContext(H + MinContext)^.Suffix;
  if (FFreq < MAX_FREQ div 4) and (pc <> 0) then
  begin
    if PContext(H + pc)^.NumStats <> 0 then
    begin
      p := PContext(H + pc)^.Stats;
      if PState(H + p)^.Symbol <> FSymbol then
      begin
        p := LongWord(PByte(PpmdFindSym(PState(H + p) + 1, FSymbol)) - H);
        if PState(H + p)^.Freq >= PState(H + p - STATE_SIZE)^.Freq then
        begin
          SwapState(PState(H + p), PState(H + p - STATE_SIZE));
          Dec(p, STATE_SIZE);
        end;
      end;
      if PState(H + p)^.Freq < MAX_FREQ - 9 then cf := 2 else cf := 0;
      Inc(PState(H + p)^.Freq, cf);
      Inc(PContext(H + pc)^.SummFreq, cf);
    end
    else
    begin
      p := pc + 2;
      if PState(H + p)^.Freq < 32 then Inc(PState(H + p)^.Freq);
    end;
  end;
  if (FOrderFall = 0) and (FSuccessor <> 0) then
  begin
    PState(H + FFoundState)^.Succ := CreateSuccessors(True, p, MinContext);
    if PState(H + FFoundState)^.Succ = 0 then goto RESTART_MODEL;
    FMaxContext := PState(H + FFoundState)^.Succ;
    Exit;
  end;
  H[FpText] := FSymbol;
  Inc(FpText);
  Successor := FpText;
  if FpText >= FUnitsStart then goto RESTART_MODEL;
  if FSuccessor <> 0 then
  begin
    if FSuccessor < FUnitsStart then
      FSuccessor := CreateSuccessors(False, p, MinContext);
  end
  else
    FSuccessor := ReduceOrder(p, MinContext);
  if FSuccessor = 0 then goto RESTART_MODEL;
  Dec(FOrderFall);
  if FOrderFall = 0 then
  begin
    Successor := FSuccessor;
    if FMaxContext <> MinContext then Dec(FpText);
  end
  else if FMRMethod > MRM_FREEZE then
  begin
    Successor := FSuccessor;
    FpText := 0;
    FOrderFall := 0;
  end;
  pc1 := UpdateModelAdd(pc1, MinContext, Successor, FFreq, FSymbol);
  if pc1 <> 0 then goto RESTART_MODEL;
  FMaxContext := FSuccessor;
  Exit;
RESTART_MODEL:
  RestoreModelRare(pc1, MinContext, FSuccessor);
end;

procedure TPpmdEngine.RestoreModelRare(pc1: LongWord; MinContext: LongWord;
                                       FSuccessor: LongWord);
var
  pc, p: LongWord;
begin
  pc := FMaxContext;
  FpText := 0;
  while pc <> pc1 do
  begin
    Dec(CtxOf(pc)^.NumStats);
    if CtxOf(pc)^.NumStats = 0 then
    begin
      if StOf(CtxOf(pc)^.Stats)^.Symbol >= $40 then
        CtxOf(pc)^.Flags := (CtxOf(pc)^.Flags and $10) or $08
      else
        CtxOf(pc)^.Flags := CtxOf(pc)^.Flags and $10;
      p := CtxOf(pc)^.Stats;
      StateCpy(OneOf(pc), StOf(p));
      SpecialFreeUnit(p);
      OneOf(pc)^.Freq := (OneOf(pc)^.Freq + 11) shr 3;
    end
    else
      RefreshCtx(pc, (CtxOf(pc)^.NumStats + 3) shr 1, False);
    pc := CtxOf(pc)^.Suffix;
  end;
  while pc <> MinContext do
  begin
    if CtxOf(pc)^.NumStats = 0 then
      OneOf(pc)^.Freq := OneOf(pc)^.Freq - (OneOf(pc)^.Freq shr 1)
    else
    begin
      Inc(CtxOf(pc)^.SummFreq, 4);
      if CtxOf(pc)^.SummFreq > 128 + 4 * CtxOf(pc)^.NumStats then
        RefreshCtx(pc, (CtxOf(pc)^.NumStats + 2) shr 1, True);
    end;
    pc := CtxOf(pc)^.Suffix;
  end;
  if FMRMethod > MRM_FREEZE then
  begin
    FMaxContext := FSuccessor;
    if (FBList[1].Stamp and 1) = 0 then Inc(FGlueCount);
  end
  else if FMRMethod = MRM_FREEZE then
  begin
    while CtxOf(FMaxContext)^.Suffix <> 0 do FMaxContext := CtxOf(FMaxContext)^.Suffix;
    RemoveBinConts(FMaxContext, 0);
    FMRMethod := FMRMethod + 1;
    FGlueCount := 0;
    FOrderFall := FMaxOrder;
  end
  else if (FMRMethod = MRM_RESTART) or (GetUsedMemory < (FSubAllocatorSize shr 1)) then
  begin
    StartModelRare(FMaxOrder, FMRMethod);
    FEscCount := 0;
    FPrintCount := $FF;
  end
  else
  begin
    while CtxOf(FMaxContext)^.Suffix <> 0 do FMaxContext := CtxOf(FMaxContext)^.Suffix;
    repeat
      CutOff(FMaxContext, 0);
      ExpandTextArea;
    until GetUsedMemory <= 3 * (FSubAllocatorSize shr 2);
    FGlueCount := 0;
    FOrderFall := FMaxOrder;
  end;
end;

{ --- decodificación ------------------------------------------------------ }

{ PARC: DecodeBinSymbol/DecodeSymbol1 son "hojas" (no llaman a nada): con una sola llamada
  adentro (Corrupt, Rescale) FPC dejaba Self en la pila y lo releía en cada acceso a un campo.
  Lo raro se devuelve como código y lo hace DecodeRare en el llamador, en el mismo orden que
  antes (Rescale no toca FSubLow/FSubHigh/FSubScale ni el range coder). }
const
  PPMD_DEC_OK = 0;
  PPMD_DEC_RESCALE = 1;      { hay que llamar a Rescale(ctx) }
  PPMD_DEC_ERR_SCALE = 2;    { datos corruptos: escala 0 }
  PPMD_DEC_ERR_RANGE = 3;    { datos corruptos: rango 0 }

procedure TPpmdEngine.DecodeRare(r: Integer; ctx: LongWord);
begin
  case r of
    PPMD_DEC_RESCALE: Rescale(ctx);
    PPMD_DEC_ERR_SCALE: Corrupt('ppmd: escala 0');
  else
    Corrupt('ppmd: rango 0');
  end;
end;

function TPpmdEngine.DecodeBinSymbol(ctx: LongWord): Integer;
var
  H: PByte;
  c: PContext;
  rs: PState;
  bs: PWord;
  b, cnt: LongWord;
begin
  H := FHeap;
  c := PContext(H + ctx);
  rs := PState(H + ctx + 2);
  bs := @FBinSumm[FQTable[rs^.Freq - 1]]
                 [LongWord(FNS2BSIndx[PContext(H + c^.Suffix)^.NumStats] + FPrevSuccess + c^.Flags) +
                  LongWord((FRunLength shr 26) and $20)];
  FRange := FRange shr TOT_BITS;
  if FRange = 0 then Exit(PPMD_DEC_ERR_RANGE);
  cnt := LongWord(FCode - FLow) div FRange;
  b := bs^;
  Result := PPMD_DEC_OK;
  if cnt < b then
  begin
    FFoundState := ctx + 2;
    if rs^.Freq < 196 then Inc(rs^.Freq);
    FSubLow := 0; FSubHigh := b;
    bs^ := Word(b + INTERVAL - ((b + 32) shr PERIOD_BITS));
    FPrevSuccess := 1; Inc(FRunLength);
  end
  else
  begin
    FSubLow := b;
    b := Word(b - ((b + 32) shr PERIOD_BITS));
    bs^ := b;
    FSubHigh := BIN_SCALE;
    FInitEsc := EXP_ESCAPE[b shr 10];
    FCharMask[rs^.Symbol] := FEscCount;
    FNumMasked := 0; FPrevSuccess := 0; FFoundState := 0;
  end;
end;

function TPpmdEngine.DecodeSymbol1(ctx: LongWord): Integer;
var
  H: PByte;
  c: PContext;
  p: PState;
  i, count, HiCnt, scale: LongWord;
  Esc: Byte;
begin
  H := FHeap;
  c := PContext(H + ctx);
  p := PState(H + c^.Stats);
  HiCnt := p^.Freq;
  scale := c^.SummFreq;
  FSubScale := scale;
  if scale = 0 then Exit(PPMD_DEC_ERR_SCALE);
  FRange := FRange div scale;
  if FRange = 0 then Exit(PPMD_DEC_ERR_RANGE);
  count := LongWord(FCode - FLow) div FRange;
  Result := PPMD_DEC_OK;
  if count < HiCnt then
  begin
    FSubHigh := HiCnt;
    if 2 * HiCnt >= scale then FPrevSuccess := 1 else FPrevSuccess := 0;
    FFoundState := c^.Stats;
    Inc(p^.Freq, 4); Inc(HiCnt, 4);
    Inc(c^.SummFreq, 4);
    Inc(FRunLength, FPrevSuccess);
    FSubLow := 0;
    if HiCnt > MAX_FREQ then Result := PPMD_DEC_RESCALE;
    Exit;
  end;
  i := c^.NumStats;
  FPrevSuccess := 0;
  repeat
    Inc(p);
    Inc(HiCnt, p^.Freq);
    if HiCnt > count then
    begin
      FSubHigh := HiCnt;
      FSubLow := HiCnt - p^.Freq;
      { Update1 sin la llamada a Rescale }
      FFoundState := LongWord(PByte(p) - H);
      Inc(p^.Freq, 4);
      Inc(c^.SummFreq, 4);
      if p^.Freq > (p - 1)^.Freq then
      begin
        SwapState(p, p - 1);
        FFoundState := LongWord(PByte(p - 1) - H);
        if (p - 1)^.Freq > MAX_FREQ then Result := PPMD_DEC_RESCALE;
      end;
      Exit;
    end;
    Dec(i);
  until i = 0;
  FSubLow := HiCnt;
  Esc := FEscCount;
  FCharMask[p^.Symbol] := Esc;
  i := c^.NumStats;
  FNumMasked := Byte(i);
  FFoundState := 0;
  repeat
    Dec(p);
    FCharMask[p^.Symbol] := Esc;
    Dec(i);
  until i = 0;
  FSubHigh := scale;
end;

type
  PPState = ^PState;

function TPpmdEngine.DecodeSymbol2(ctx: LongWord): Integer;
var
  psee2c: PSee2;
  i, n, count, HiCnt, scale: LongWord;
  ps: array[0..255] of PState;     { en C es STATE* ps[256] }
  pps: PPState;
  pb: PState;
  H, Mask: PByte;
  c: PContext;
  Esc: Byte;
begin
  { PARC: hoja, como DecodeSymbol1 (el bucle de recolección va acá adentro: sin
    llamadas en el método, FPC deja todo en registros) }
  psee2c := MakeEscFreq2(ctx);
  H := FHeap;
  c := PContext(H + ctx);
  i := c^.NumStats - FNumMasked;
  Mask := @FCharMask[0];
  Esc := FEscCount;
  pb := PState(H + c^.Stats) - 1;
  pps := @ps[0];
  HiCnt := 0;
  n := i;
  repeat
    repeat
      Inc(pb);
    until Mask[pb^.Symbol] <> Esc;
    Inc(HiCnt, pb^.Freq);
    pps^ := pb;
    Inc(pps);
    Dec(n);
  until n = 0;
  scale := FSubScale + HiCnt;
  FSubScale := scale;
  if scale = 0 then Exit(PPMD_DEC_ERR_SCALE);
  FRange := FRange div scale;
  if FRange = 0 then Exit(PPMD_DEC_ERR_RANGE);
  count := LongWord(FCode - FLow) div FRange;
  Result := PPMD_DEC_OK;
  if count < HiCnt then
  begin
    pps := @ps[0];
    pb := pps^;
    HiCnt := pb^.Freq;
    while HiCnt <= count do
    begin
      Inc(pps);
      pb := pps^;
      Inc(HiCnt, pb^.Freq);
    end;
    FSubHigh := HiCnt;
    FSubLow := HiCnt - pb^.Freq;
    See2Update(psee2c);
    { Update2 sin la llamada a Rescale (Rescale no usa FEscCount ni FRunLength) }
    FFoundState := LongWord(PByte(pb) - H);
    Inc(pb^.Freq, 4);
    Inc(c^.SummFreq, 4);
    if pb^.Freq > MAX_FREQ then Result := PPMD_DEC_RESCALE;
    Inc(FEscCount);
    FRunLength := FInitRL;
  end
  else
  begin
    FSubLow := HiCnt;
    FSubHigh := scale;
    FNumMasked := c^.NumStats;
    pps := @ps[0];
    repeat
      Mask[pps^^.Symbol] := Esc;
      Inc(pps);
      Dec(i);
    until i = 0;
    psee2c^.Summ := Word(psee2c^.Summ + scale);
  end;
end;

{ --- entrada/salida y bucle principal ------------------------------------ }

function TPpmdEngine.InByte: Integer;
begin
  if FInPos >= FInLen then
  begin
    FInLen := FSource.Read(@FInBuf[0], SizeOf(FInBuf));
    FInPos := 0;
    if FInLen <= 0 then Exit(-1);
  end;
  Result := FInBuf[FInPos];
  Inc(FInPos);
end;

procedure TPpmdEngine.Emit(b: Byte);
begin
  if FOutLen >= Length(FOutBuf) then
    SetLength(FOutBuf, Length(FOutBuf) + OUT_BUF_SIZE);
  FOutBuf[FOutLen] := b;
  Inc(FOutLen);
end;

procedure TPpmdEngine.DecodeMore(ALimit: SizeInt);
label
  StopDecoding;
var
  H: PByte;
  r: Integer;
begin
  H := FHeap;
  if FDone then Exit;
  if FState = 0 then
  begin
    AriInitDecoder;
    StartModelRare(FMaxOrder, FMRMethod);
    FMinContext := FMaxContext;
    FNs := PContext(H + FMinContext)^.NumStats;
    FState := 1;
  end;
  while FOutLen < ALimit do
  begin
    prefetch(H[PContext(H + FMinContext)^.Suffix]);
    if FNs <> 0 then r := DecodeSymbol1(FMinContext) else r := DecodeBinSymbol(FMinContext);
    if r <> PPMD_DEC_OK then DecodeRare(r, FMinContext);
    if FFoundState <> 0 then prefetch(H[PState(H + FFoundState)^.Succ]);
    AriRemoveSubrange;
    while FFoundState = 0 do
    begin
      AriDecNormalize;
      repeat
        Inc(FOrderFall);
        FMinContext := PContext(H + FMinContext)^.Suffix;
        if FMinContext = 0 then goto StopDecoding;
      until PContext(H + FMinContext)^.NumStats <> FNumMasked;
      r := DecodeSymbol2(FMinContext);
      if r <> PPMD_DEC_OK then DecodeRare(r, FMinContext);
      if FFoundState <> 0 then prefetch(H[PState(H + FFoundState)^.Succ]);
      AriRemoveSubrange;
    end;
    Emit(PState(H + FFoundState)^.Symbol);
    if (FOrderFall = 0) and (PState(H + FFoundState)^.Succ >= FUnitsStart) then
      FMaxContext := PState(H + FFoundState)^.Succ
    else
    begin
      UpdateModel(FMinContext);
      if FEscCount = 0 then ClearMask;
    end;
    FMinContext := FMaxContext;
    FNs := PContext(H + FMinContext)^.NumStats;
    AriDecNormalize;
  end;
  Exit;
StopDecoding:
  FDone := True;
  FState := 2;
end;

function TPpmdEngine.Read(Buf: PByte; Count: SizeInt): SizeInt;
var
  n: SizeInt;
begin
  Result := 0;
  while Count > 0 do
  begin
    if FOutPos >= FOutLen then
    begin
      if FDone then Break;
      FOutPos := 0;
      FOutLen := 0;
      DecodeMore(OUT_BUF_SIZE);
      if FOutLen = 0 then Break;
    end;
    n := FOutLen - FOutPos;
    if n > Count then n := Count;
    Move(FOutBuf[FOutPos], Buf^, n);
    Inc(FOutPos, n);
    Inc(Buf, n);
    Dec(Count, n);
    Inc(Result, n);
  end;
end;

constructor TPpmdEngine.Create(ASource: TInStage; AOrder: Integer; AMemSize: Int64;
                               AMRMethod: Integer; AChunk: Int64);
begin
  inherited Create;
  FSource := ASource;
  FOrder := AOrder;
  FMemSize := AMemSize;
  FMROrder := AMRMethod;
  FMaxOrder := AOrder;
  FMRMethod := AMRMethod;
  SetLength(FOutBuf, OUT_BUF_SIZE);
  FOutLen := 0; FOutPos := 0; FInLen := 0; FInPos := 0;
  FDone := False; FState := 0;
  FAllocFailed := False;
  InitTables;
  SetLength(FOutBuf, OUT_BUF_SIZE);
  if not StartSubAllocator(LongWord(AMemSize)) then
  begin
    FAllocFailed := True;
    raise EOutOfMemory.Create('ppmd: not enough memory for the model');
  end;
end;

destructor TPpmdEngine.Destroy;
begin
  StopSubAllocator;
  inherited Destroy;
end;

{ --- TPpmdStage ---------------------------------------------------------- }

constructor TPpmdStage.Create(ASource: TInStage; AOrder: Integer; AMemSize: Int64;
                              AMRMethod: Integer; AChunk: Int64);
begin
  { Validar ANTES de inherited Create: si se lanza después, el destructor
    liberaría una fuente que todavía es del llamador. }
  if (AOrder < MIN_O) or (AOrder > MAX_O) then
    Corrupt('ppmd: orden fuera de rango');
  if AMemSize < MIN_MEM then
    Corrupt('ppmd: insufficient model memory');
  // El heap emula direcciones de 32 bits: el modelo tiene que caber en un offset UInt32
  if AMemSize > $FFFFFFFF - 4096 then
    Corrupt('ppmd: model memory too large');
  { El motor (que puede fallar al reservar la memoria del modelo) se crea ANTES de adoptar la
    fuente, por el mismo motivo: no es dueño de ASource, así que si falla no hay nada que liberar. }
  FEngine := TPpmdEngine.Create(ASource, AOrder, AMemSize, AMRMethod, AChunk);
  inherited Create(ASource);
end;

destructor TPpmdStage.Destroy;
begin
  FEngine.Free;
  inherited Destroy;
end;

function TPpmdStage.Read(Buf: PByte; Count: SizeInt): SizeInt;
begin
  Result := TPpmdEngine(FEngine).Read(Buf, Count);
end;

{ --- lado encoder --------------------------------------------------------- }
{ Espejo del decoder: mismas actualizaciones de modelo y misma elección de
  subrango, pero acá el símbolo decide y se ESCRIBE el subrango. Fuente:
  Model.cpp:441 (encodeBinSymbol), 483 (encodeSymbol1), 556 (encodeSymbol2),
  608 (EncodeFile) y Coder.hpp:64-89 (range encoder). }

function TPpmdEngine.EncInByte: Integer;
begin
  if FEncInPos >= FEncInLen then Exit(-1);
  Result := FEncIn[FEncInPos];
  Inc(FEncInPos);
end;

procedure TPpmdEngine.AriInitEncoder;
begin
  FLow := 0; FRange := $FFFFFFFF;
end;

procedure TPpmdEngine.AriEncNormalize;
begin
  while True do
  begin
    if (FLow xor (FLow + FRange)) < LongWord(TOP) then
      { sigue }
    else if FRange < LongWord(BOT) then
      FRange := (LongWord(0) - FLow) and (LongWord(BOT) - 1)
    else
      Break;
    EncEmit(Byte(FLow shr 24));
    FRange := FRange shl 8;
    FLow := FLow shl 8;
  end;
end;

procedure TPpmdEngine.AriEncodeSymbol;
begin
  FRange := FRange div FSubScale;
  Inc(FLow, FSubLow * FRange);
  FRange := FRange * (FSubHigh - FSubLow);
end;

procedure TPpmdEngine.AriShiftEncodeSymbol(SHIFT: Integer);
begin
  FRange := FRange shr SHIFT;
  Inc(FLow, FSubLow * FRange);
  FRange := FRange * (FSubHigh - FSubLow);
end;

procedure TPpmdEngine.AriFlushEncoder;
var
  i: Integer;
begin
  for i := 0 to 3 do
  begin
    EncEmit(Byte(FLow shr 24));
    FLow := FLow shl 8;
  end;
end;

procedure TPpmdEngine.EncEmit(b: Byte);
begin
  { PARC: los bytes del range coder se juntan y salen de a bloques (antes: una llamada
    por método-puntero por byte). EncFlush los entrega en el mismo orden. }
  FEncBuf[FEncBufLen] := b;
  Inc(FEncBufLen);
  if FEncBufLen = SizeOf(FEncBuf) then EncFlush;
end;

procedure TPpmdEngine.EncFlush;
begin
  if FEncBufLen > 0 then
  begin
    if Assigned(FEncSink) then FEncSink(@FEncBuf[0], FEncBufLen);
    FEncBufLen := 0;
  end;
end;

procedure TPpmdEngine.EncSinkBuf(Buf: PByte; Count: SizeInt);
var
  i: SizeInt;
begin
  for i := 0 to Count - 1 do Emit(Buf[i]);
end;

procedure TPpmdEngine.SetEncSink(AProc: TPpmdEmitProc);
begin
  FEncSink := AProc;
end;

procedure TPpmdEngine.EncodeBinSymbol(ctx: LongWord; symbol: Integer);
var
  H: PByte;
  c: PContext;
  rs: PState;
  bs: PWord;
  b: LongWord;
begin
  H := FHeap;
  c := PContext(H + ctx);
  rs := PState(H + ctx + 2);
  bs := @FBinSumm[FQTable[rs^.Freq - 1]]
                 [LongWord(FNS2BSIndx[PContext(H + c^.Suffix)^.NumStats] + FPrevSuccess + c^.Flags) +
                  LongWord((FRunLength shr 26) and $20)];
  b := bs^;
  if Integer(rs^.Symbol) = symbol then
  begin
    FFoundState := ctx + 2;
    if rs^.Freq < 196 then Inc(rs^.Freq);
    FSubLow := 0; FSubHigh := b;
    bs^ := Word(b + INTERVAL - ((b + 32) shr PERIOD_BITS));
    FPrevSuccess := 1; Inc(FRunLength);
  end
  else
  begin
    FSubLow := b;
    b := Word(b - ((b + 32) shr PERIOD_BITS));
    bs^ := b;
    FSubHigh := BIN_SCALE;
    FInitEsc := EXP_ESCAPE[b shr 10];
    FCharMask[rs^.Symbol] := FEscCount;
    FNumMasked := 0; FPrevSuccess := 0; FFoundState := 0;
  end;
end;

{ PARC: EncodeSymbol1/EncodeSymbol2 son hojas como DecodeSymbol1: devuelven True si hay que
  llamar a Rescale(ctx), y EncodeOne lo hace enseguida. }
function TPpmdEngine.EncodeSymbol1(ctx: LongWord; symbol: Integer): Boolean;
var
  H: PByte;
  c: PContext;
  p: PState;
  i, LoCnt, scale: LongWord;
  Esc: Byte;
begin
  H := FHeap;
  c := PContext(H + ctx);
  p := PState(H + c^.Stats);
  scale := c^.SummFreq;
  FSubScale := scale;
  if Integer(p^.Symbol) = symbol then
  begin
    FSubHigh := p^.Freq;
    if 2 * LongWord(p^.Freq) >= scale then FPrevSuccess := 1 else FPrevSuccess := 0;
    FFoundState := c^.Stats;
    Inc(p^.Freq, 4); Inc(c^.SummFreq, 4);
    Inc(FRunLength, FPrevSuccess);
    FSubLow := 0;
    Exit(p^.Freq > MAX_FREQ);
  end;
  Result := False;
  LoCnt := p^.Freq;
  i := c^.NumStats; FPrevSuccess := 0;
  while True do
  begin
    Inc(p);
    if Integer(p^.Symbol) = symbol then Break;
    Inc(LoCnt, p^.Freq);
    if i = 1 then
    begin
      FSubLow := LoCnt;
      Esc := FEscCount;
      FCharMask[p^.Symbol] := Esc;
      i := c^.NumStats;
      FNumMasked := Byte(i);
      FFoundState := 0;
      repeat
        Dec(p);
        FCharMask[p^.Symbol] := Esc;
        Dec(i);
      until i = 0;
      FSubHigh := scale;
      Exit;
    end;
    Dec(i);
  end;
  FSubLow := LoCnt;
  FSubHigh := LoCnt + p^.Freq;
  { Update1 sin la llamada a Rescale }
  FFoundState := LongWord(PByte(p) - H);
  Inc(p^.Freq, 4);
  Inc(c^.SummFreq, 4);
  if p^.Freq > (p - 1)^.Freq then
  begin
    SwapState(p, p - 1);
    FFoundState := LongWord(PByte(p - 1) - H);
    Result := (p - 1)^.Freq > MAX_FREQ;
  end;
end;


function TPpmdEngine.EncodeSymbol2(ctx: LongWord; symbol: Integer): Boolean;
var
  psee2c: PSee2;
  H, Mask: PByte;
  c: PContext;
  p, Found: PState;
  i, LoCnt: LongWord;
  Sym, Esc: Byte;
begin
  psee2c := MakeEscFreq2(ctx);          { fija FSubScale }
  H := FHeap;
  c := PContext(H + ctx);
  Mask := @FCharMask[0];
  Esc := FEscCount;
  i := c^.NumStats - FNumMasked;
  p := PState(H + c^.Stats) - 1;
  LoCnt := 0;
  Result := False;
  while True do
  begin
    repeat
      Inc(p);
      Sym := p^.Symbol;
    until Mask[Sym] <> Esc;
    Mask[Sym] := Esc;
    if Integer(Sym) = symbol then Break;
    Inc(LoCnt, p^.Freq);
    if i = 1 then
    begin
      { escape }
      FSubLow := LoCnt;
      FSubScale := FSubScale + LoCnt;
      FSubHigh := FSubScale;
      psee2c^.Summ := Word(psee2c^.Summ + FSubScale);
      FNumMasked := c^.NumStats;
      Exit;
    end;
    Dec(i);
  end;
  FSubLow := LoCnt;
  Found := p;
  Inc(LoCnt, p^.Freq);
  FSubHigh := LoCnt;
  Dec(i);
  while i <> 0 do
  begin
    repeat
      Inc(p);
    until Mask[p^.Symbol] <> Esc;
    Inc(LoCnt, p^.Freq);
    Dec(i);
  end;
  FSubScale := FSubScale + LoCnt;
  See2Update(psee2c);
  { Update2 sin la llamada a Rescale (Rescale no usa FEscCount ni FRunLength) }
  FFoundState := LongWord(PByte(Found) - H);
  Inc(Found^.Freq, 4);
  Inc(c^.SummFreq, 4);
  Result := Found^.Freq > MAX_FREQ;
  Inc(FEscCount);
  FRunLength := FInitRL;
end;

procedure TPpmdEngine.EncodeOne(c: Integer);
var
  H: PByte;
  ns: Byte;
begin
  H := FHeap;
  if FEncDone then Exit;
  ns := FNs;
  { PARC: precarga del sufijo (escape y BinSumm lo leen) }
  prefetch(H[PContext(H + FMinContext)^.Suffix]);
  if ns <> 0 then
  begin
    if EncodeSymbol1(FMinContext, c) then Rescale(FMinContext);
    if FFoundState <> 0 then prefetch(H[PState(H + FFoundState)^.Succ]);
    AriEncodeSymbol;
  end
  else
  begin
    EncodeBinSymbol(FMinContext, c);
    if FFoundState <> 0 then prefetch(H[PState(H + FFoundState)^.Succ]);
    AriShiftEncodeSymbol(TOT_BITS);
  end;
  while FFoundState = 0 do
  begin
    AriEncNormalize;
    repeat
      Inc(FOrderFall);
      FMinContext := PContext(H + FMinContext)^.Suffix;
      if FMinContext = 0 then
      begin
        { Fin de la entrada alcanzado dentro del escape: en el C esto es el
          goto STOP_ENCODING de EncodeFile. }
        FEncDone := True;
        Exit;
      end;
    until PContext(H + FMinContext)^.NumStats <> FNumMasked;
    if EncodeSymbol2(FMinContext, c) then Rescale(FMinContext);
    if FFoundState <> 0 then prefetch(H[PState(H + FFoundState)^.Succ]);
    AriEncodeSymbol;
  end;
  if (FOrderFall = 0) and (PState(H + FFoundState)^.Succ >= FUnitsStart) then
    FMaxContext := PState(H + FFoundState)^.Succ
  else
  begin
    UpdateModel(FMinContext);
    if FEscCount = 0 then ClearMask;
  end;
  FMinContext := FMaxContext;
  FNs := PContext(H + FMinContext)^.NumStats;
  AriEncNormalize;
end;

procedure TPpmdEngine.StartEncode;
begin
  FEncBufLen := 0;
  FEncDone := False;
  AriInitEncoder;
  StartModelRare(FMaxOrder, FMRMethod);
  FMinContext := FMaxContext;
  FNs := CtxOf(FMinContext)^.NumStats;
end;

procedure TPpmdEngine.EncodeBytes(Buf: PByte; Count: SizeInt);
var
  i: SizeInt;
begin
  for i := 0 to Count - 1 do
  begin
    if FEncDone then Break;
    EncodeOne(Buf[i]);
  end;
  EncFlush;
end;

procedure TPpmdEngine.FinishEncode;
begin
  { El fin de la entrada se codifica como símbolo (EOF = -1), igual que EncodeFile. }
  EncodeOne(-1);
  AriFlushEncoder;
  EncFlush;
end;

function TPpmdEngine.Compress(InBuf: PByte; InLen: SizeInt;
                              out Compressed: TBytes): Boolean;
begin
  Result := False;
  FOutLen := 0; FOutPos := 0;
  FEncSink := @EncSinkBuf;
  try
    StartEncode;
    if InLen > 0 then EncodeBytes(InBuf, InLen);
    FinishEncode;
  finally
    FEncSink := nil;
  end;
  SetLength(Compressed, FOutLen);
  if FOutLen > 0 then Move(FOutBuf[0], Compressed[0], FOutLen);
  Result := True;
end;


function PpmdCompress(InBuf: PByte; InLen: SizeInt;
                      AOrder, AMemSize, AMRMethod: Integer;
                      out Compressed: TBytes): Boolean;
var
  eng: TPpmdEngine;
begin
  Result := False;
  eng := TPpmdEngine.Create(nil, AOrder, AMemSize, AMRMethod, 1 shl 22);
  try
    Result := eng.Compress(InBuf, InLen, Compressed);
  finally
    eng.Free;
  end;
end;


{ --- TPpmdEncStage ------------------------------------------------------- }

constructor TPpmdEncStage.Create(ATarget: TOutStage; AOrder: Integer;
                                 AMemSize: Int64; AMRMethod: Integer; AChunk: Int64);
begin
  { Misma validación y mismo orden que TPpmdStage: validar y crear el motor ANTES
    de inherited Create, para que un fallo no deje una cadena a medio adoptar. }
  if (AOrder < MIN_O) or (AOrder > MAX_O) then
    Corrupt('ppmd: orden fuera de rango');
  if AMemSize < MIN_MEM then
    Corrupt('ppmd: insufficient model memory');
  if AMemSize > $FFFFFFFF - 4096 then
    Corrupt('ppmd: model memory too large');
  FOrder := AOrder; FMemSize := AMemSize; FMRMethod := AMRMethod;
  FEngine := TPpmdEngine.Create(nil, AOrder, AMemSize, AMRMethod, AChunk);
  TPpmdEngine(FEngine).SetEncSink(@StageSink);
  TPpmdEngine(FEngine).StartEncode;
  inherited Create(ATarget);
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
begin
  if Count > 0 then TPpmdEngine(FEngine).EncodeBytes(Buf, Count);
end;

procedure TPpmdEncStage.DoFinish;
begin
  TPpmdEngine(FEngine).FinishEncode;
end;

end.
