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
    FEncDone: Boolean;
    FOutBuf: array of Byte;
    FOutLen, FOutPos: SizeInt;
    FDone: Boolean;
    FState: Integer;
    FOrder, FMemSize, FMROrder: Integer;
    procedure InitTables;
    function  StOf(R: LongWord): PState;
    function  CtxOf(R: LongWord): PContext;
    function  BlkOf(R: LongWord): PMemBlk;
    function  NodeOf(R: LongWord): PBlkNode;
    function  OneOf(R: LongWord): PState;
    function  U2B(NU: LongWord): LongWord;
    procedure BListInsert(Indx: Integer; R: LongWord; NU: LongWord);
    function  BListRemove(Indx: Integer): LongWord;
    function  BListAvail(Indx: Integer): Boolean;
    procedure StopSubAllocator;
    function  StartSubAllocator(Size: LongWord): Boolean;
    procedure InitSubAllocator;
    procedure SplitBlock(pv: LongWord; OldIndx, NewIndx: LongWord);
    procedure GlueFreeBlocks;
    function  AllocUnitsRare(indx: LongWord): LongWord;
    function  AllocUnits(NU: LongWord): LongWord;
    function  AllocContext: LongWord;
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
    procedure AriDecNormalize;
    function  AriGetCurrentCount: LongWord;
    function  AriGetCurrentShiftCount(SHIFT: Integer): LongWord;
    procedure AriRemoveSubrange;
    procedure See2Init(p: PSee2; InitVal: LongWord);
    function  See2GetMean(p: PSee2): LongWord;
    procedure See2Update(p: PSee2);
    function  GetMean(Summ: LongWord; Shift, Rnd: Integer): LongWord;
    function  MakeEscFreq2(ctx: LongWord): PSee2;
    procedure SwapState(const a, b: PState);
    procedure StateCpy(const a, b: PState);
    procedure Update1(ctx: LongWord; p: LongWord);
    procedure Update2(ctx: LongWord; p: LongWord);
    procedure RefreshCtx(ctx: LongWord; OldNU: LongWord; Scale: Boolean);
    procedure Rescale(ctx: LongWord);
    function  CutOff(ctx: LongWord; Order: Integer): LongWord;
    function  RemoveBinConts(ctx: LongWord; Order: Integer): LongWord;
    procedure StartModelRare(_MaxOrder, _MRMethod: Integer);
    function  CreateSuccessors(Skip: Boolean; p: LongWord; pc: LongWord): LongWord;
    function  ReduceOrder(p: LongWord; pc: LongWord): LongWord;
    procedure UpdateModel(MinContext: LongWord);
    procedure RestoreModelRare(pc1: LongWord; MinContext: LongWord; FSuccessor: LongWord);
    procedure DecodeBinSymbol(ctx: LongWord);
    procedure DecodeSymbol1(ctx: LongWord);
    procedure DecodeSymbol2(ctx: LongWord);
    function  InByte: Integer;
    procedure Emit(b: Byte);
    procedure DecodeMore(ALimit: SizeInt);
    { --- lado encoder --- }
    function  EncInByte: Integer;
    procedure EncEmit(b: Byte);
    procedure EncSinkBuf(Buf: PByte; Count: SizeInt);
    procedure AriInitEncoder;
    procedure AriEncNormalize;
    procedure AriEncodeSymbol;
    procedure AriShiftEncodeSymbol(SHIFT: Integer);
    procedure AriFlushEncoder;
    procedure EncodeBinSymbol(ctx: LongWord; symbol: Integer);
    procedure EncodeSymbol1(ctx: LongWord; symbol: Integer);
    procedure EncodeSymbol2(ctx: LongWord; symbol: Integer);
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
  Result := (FCode - FLow) div FRange;
end;

function TPpmdEngine.AriGetCurrentShiftCount(SHIFT: Integer): LongWord;
begin
  FRange := FRange shr SHIFT;
  if FRange = 0 then Corrupt('ppmd: rango 0');
  Result := (FCode - FLow) div FRange;
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

function TPpmdEngine.GetMean(Summ: LongWord; Shift, Rnd: Integer): LongWord;
begin
  Result := (Summ + (LongWord(1) shl (Shift - Rnd))) shr Shift;
end;

function TPpmdEngine.MakeEscFreq2(ctx: LongWord): PSee2;
var
  t, row, col: LongWord;
begin
  if CtxOf(ctx)^.NumStats <> $FF then
  begin
    t := CtxOf(CtxOf(ctx)^.Suffix)^.NumStats;
    row := FQTable[CtxOf(ctx)^.NumStats + 2] - 3;
    col := Ord(CtxOf(ctx)^.SummFreq > 11 * (CtxOf(ctx)^.NumStats + 1));
    Inc(col, 2 * Ord(2 * CtxOf(ctx)^.NumStats < t + FNumMasked) + CtxOf(ctx)^.Flags);
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

procedure TPpmdEngine.Update1(ctx: LongWord; p: LongWord);
begin
  FFoundState := p;
  Inc(StOf(p)^.Freq, 4);
  Inc(CtxOf(ctx)^.SummFreq, 4);
  if StOf(p)^.Freq > StOf(p - STATE_SIZE)^.Freq then
  begin
    SwapState(StOf(p), StOf(p - STATE_SIZE));
    FFoundState := p - STATE_SIZE;
    if StOf(p - STATE_SIZE)^.Freq > MAX_FREQ then Rescale(ctx);
  end;
end;

procedure TPpmdEngine.Update2(ctx: LongWord; p: LongWord);
begin
  FFoundState := p;
  Inc(StOf(p)^.Freq, 4);
  Inc(CtxOf(ctx)^.SummFreq, 4);
  if StOf(p)^.Freq > MAX_FREQ then Rescale(ctx);
  Inc(FEscCount);
  FRunLength := FInitRL;
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
  i, EscFreq, Adder, OldNU: LongInt;
  p, p1: LongWord;
  tmp: TState;
begin
  i := CtxOf(ctx)^.NumStats;
  p := FFoundState;
  while p <> CtxOf(ctx)^.Stats do
  begin
    SwapState(StOf(p), StOf(p - STATE_SIZE));
    Dec(p, STATE_SIZE);
  end;
  Inc(StOf(p)^.Freq, 4);
  Inc(CtxOf(ctx)^.SummFreq, 4);
  EscFreq := LongInt(CtxOf(ctx)^.SummFreq) - StOf(p)^.Freq;
  if (FOrderFall <> 0) or (FMRMethod > MRM_FREEZE) then Adder := 1 else Adder := 0;
  StOf(p)^.Freq := (StOf(p)^.Freq + LongWord(Adder)) shr 1;
  CtxOf(ctx)^.SummFreq := StOf(p)^.Freq;
  repeat
    Inc(p, STATE_SIZE);
    Dec(EscFreq, StOf(p)^.Freq);
    StOf(p)^.Freq := (StOf(p)^.Freq + LongWord(Adder)) shr 1;
    Inc(CtxOf(ctx)^.SummFreq, StOf(p)^.Freq);
    if StOf(p)^.Freq > StOf(p - STATE_SIZE)^.Freq then
    begin
      StateCpy(@tmp, StOf(p));
      p1 := p;
      repeat
        StateCpy(StOf(p1), StOf(p1 - STATE_SIZE));
        Dec(p1, STATE_SIZE);
      until not (tmp.Freq > StOf(p1 - STATE_SIZE)^.Freq);
      StateCpy(StOf(p1), @tmp);
    end;
    Dec(i);
  until i = 0;
  if StOf(p)^.Freq = 0 then
  begin
    repeat
      Inc(i);
      Dec(p, STATE_SIZE);
    until StOf(p)^.Freq <> 0;
    Inc(EscFreq, i);
    OldNU := LongInt((CtxOf(ctx)^.NumStats + 2) shr 1);
    Dec(CtxOf(ctx)^.NumStats, Byte(i));
    if CtxOf(ctx)^.NumStats = 0 then
    begin
      StateCpy(@tmp, StOf(CtxOf(ctx)^.Stats));
      tmp.Freq := Byte((2 * LongInt(tmp.Freq) + EscFreq - 1) div EscFreq);
      if tmp.Freq > MAX_FREQ div 3 then tmp.Freq := MAX_FREQ div 3;
      FreeUnits(CtxOf(ctx)^.Stats, LongWord(OldNU));
      StateCpy(OneOf(ctx), @tmp);
      CtxOf(ctx)^.Flags := (CtxOf(ctx)^.Flags and $10) or (byte($08) * Ord(tmp.Symbol >= $40));
      FFoundState := ctx + 2;
      Exit;
    end;
    CtxOf(ctx)^.Stats := ShrinkUnits(CtxOf(ctx)^.Stats, LongWord(OldNU),
                                   (CtxOf(ctx)^.NumStats + 2) shr 1);
    CtxOf(ctx)^.Flags := CtxOf(ctx)^.Flags and not byte($08);
    i := CtxOf(ctx)^.NumStats;
    p := CtxOf(ctx)^.Stats;
    CtxOf(ctx)^.Flags := CtxOf(ctx)^.Flags or (byte($08) * Ord(StOf(p)^.Symbol >= $40));
    repeat
      Inc(p, STATE_SIZE);
      CtxOf(ctx)^.Flags := CtxOf(ctx)^.Flags or (byte($08) * Ord(StOf(p)^.Symbol >= $40));
      Dec(i);
    until i = 0;
  end;
  EscFreq := EscFreq - (EscFreq shr 1);
  Inc(CtxOf(ctx)^.SummFreq, Word(EscFreq));
  CtxOf(ctx)^.Flags := CtxOf(ctx)^.Flags or $04;
  FFoundState := CtxOf(ctx)^.Stats;
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

function TPpmdEngine.CreateSuccessors(Skip: Boolean; p: LongWord; pc: LongWord): LongWord;
label
  NO_LOOP, LOOP_ENTRY;
var
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
  UpBranch := StOf(FFoundState)^.Succ;
  n := 0;
  sym := StOf(FFoundState)^.Symbol;
  if not Skip then
  begin
    ps[n] := FFoundState; Inc(n);
    if CtxOf(pc)^.Suffix = 0 then goto NO_LOOP;
  end;
  if p <> 0 then
  begin
    pc := CtxOf(pc)^.Suffix;
    goto LOOP_ENTRY;
  end;
  while True do
  begin
    pc := CtxOf(pc)^.Suffix;
    if CtxOf(pc)^.NumStats <> 0 then
    begin
      p := CtxOf(pc)^.Stats;
      if StOf(p)^.Symbol <> sym then
        repeat
          Inc(p, STATE_SIZE);
          tmp := StOf(p)^.Symbol;
        until tmp = sym;
      if StOf(p)^.Freq < MAX_FREQ - 9 then tmp := 1 else tmp := 0;
      Inc(StOf(p)^.Freq, tmp);
      Inc(CtxOf(pc)^.SummFreq, tmp);
    end
    else
    begin
      p := pc + 2;
      if (CtxOf(CtxOf(pc)^.Suffix)^.NumStats = 0) and (StOf(p)^.Freq < 24) then
        Inc(StOf(p)^.Freq);
    end;
  LOOP_ENTRY:
    if StOf(p)^.Succ <> UpBranch then
    begin
      pc := StOf(p)^.Succ;
      Break;
    end;
    ps[n] := p; Inc(n);
    if CtxOf(pc)^.Suffix = 0 then Break;
  end;
NO_LOOP:
  if n = 0 then Exit(pc);
  FillChar(ct, SizeOf(ct), 0);
  ctOne := PState(PByte(@ct) + 2);
  ct.NumStats := 0;
  if sym >= $40 then ct.Flags := $10 else ct.Flags := 0;
  sym := FHeap[UpBranch];
  ctOne^.Symbol := sym;
  ctOne^.Succ := UpBranch + 1;
  if sym >= $40 then ct.Flags := ct.Flags or $08;
  if CtxOf(pc)^.NumStats <> 0 then
  begin
    p := CtxOf(pc)^.Stats;
    if StOf(p)^.Symbol <> sym then
      repeat
        Inc(p, STATE_SIZE);
        tmp := StOf(p)^.Symbol;
      until tmp = sym;
    s0 := CtxOf(pc)^.SummFreq - CtxOf(pc)^.NumStats - (StOf(p)^.Freq - 1);
    cf := StOf(p)^.Freq - 1;
    if 2 * cf <= s0 then
    begin
      if 5 * cf > s0 then ctOne^.Freq := 2 else ctOne^.Freq := 1;
    end
    else
      ctOne^.Freq := Byte(1 + (cf + 2 * s0 - 3) div s0);
  end
  else
    ctOne^.Freq := OneOf(pc)^.Freq;
  repeat
    pc1 := AllocContext;
    if pc1 = 0 then Exit(0);
    CtxOf(pc1)^ := ct;
    CtxOf(pc1)^.Suffix := pc;
    Dec(n);
    StOf(ps[n])^.Succ := pc1;
    pc := pc1;
  until n = 0;
  Result := pc;
end;

function TPpmdEngine.ReduceOrder(p: LongWord; pc: LongWord): LongWord;
label
  FROZEN, LOOP_ENTRY;
var
  ps: array[0..MAX_O] of LongWord;
  n: Integer;
  pc1, UpBranch, p1: LongWord;
  tmp, sym: Byte;
begin
  pc1 := pc;
  UpBranch := FpText;
  n := 0;
  sym := StOf(FFoundState)^.Symbol;
  ps[n] := FFoundState; Inc(n);
  StOf(FFoundState)^.Succ := UpBranch;
  Inc(FOrderFall);
  if p <> 0 then
  begin
    pc := CtxOf(pc)^.Suffix;
    goto LOOP_ENTRY;
  end;
  while True do
  begin
    if CtxOf(pc)^.Suffix = 0 then
    begin
      if FMRMethod > MRM_FREEZE then
      begin
      FROZEN:
        repeat
          Dec(n);
          StOf(ps[n])^.Succ := pc;
        until n = 0;
        FpText := 1;
        FOrderFall := 1;
      end;
      Exit(pc);
    end;
    pc := CtxOf(pc)^.Suffix;
    if CtxOf(pc)^.NumStats <> 0 then
    begin
      p := CtxOf(pc)^.Stats;
      if StOf(p)^.Symbol <> sym then
        repeat
          Inc(p, STATE_SIZE);
          tmp := StOf(p)^.Symbol;
        until tmp = sym;
      if StOf(p)^.Freq < MAX_FREQ - 9 then tmp := 2 else tmp := 0;
      Inc(StOf(p)^.Freq, tmp);
      Inc(CtxOf(pc)^.SummFreq, tmp);
    end
    else
    begin
      p := pc + 2;
      if StOf(p)^.Freq < 32 then Inc(StOf(p)^.Freq);
    end;
  LOOP_ENTRY:
    if StOf(p)^.Succ <> 0 then Break;
    ps[n] := p; Inc(n);
    StOf(p)^.Succ := UpBranch;
    Inc(FOrderFall);
  end;
  if FMRMethod > MRM_FREEZE then
  begin
    pc := StOf(p)^.Succ;
    goto FROZEN;
  end
  else if StOf(p)^.Succ <= UpBranch then
  begin
    p1 := FFoundState;
    FFoundState := p;
    StOf(p)^.Succ := CreateSuccessors(False, 0, pc);
    FFoundState := p1;
  end;
  if (FOrderFall = 1) and (pc1 = FMaxContext) then
  begin
    StOf(FFoundState)^.Succ := StOf(p)^.Succ;
    Dec(FpText);
  end;
  Result := StOf(p)^.Succ;
end;

procedure TPpmdEngine.UpdateModel(MinContext: LongWord);
label
  RESTART_MODEL;
var
  p: LongWord;
  Successor, FSuccessor, pc, pc1: LongWord;
  ns1, ns, cf, sf, s0, FFreq: LongWord;
  Flag, sym, FSymbol: Byte;
begin
  pc1 := FMaxContext;
  p := 0;      { en el C es STATE* p=NULL; ReduceOrder lo recibe tal cual }
  FFreq := StOf(FFoundState)^.Freq;
  FSymbol := StOf(FFoundState)^.Symbol;
  FSuccessor := StOf(FFoundState)^.Succ;
  pc := CtxOf(MinContext)^.Suffix;
  if (FFreq < MAX_FREQ div 4) and (pc <> 0) then
  begin
    if CtxOf(pc)^.NumStats <> 0 then
    begin
      p := CtxOf(pc)^.Stats;
      if StOf(p)^.Symbol <> FSymbol then
      begin
        repeat
          Inc(p, STATE_SIZE);
          sym := StOf(p)^.Symbol;
        until sym = FSymbol;
        if StOf(p)^.Freq >= StOf(p - STATE_SIZE)^.Freq then
        begin
          SwapState(StOf(p), StOf(p - STATE_SIZE));
          Dec(p, STATE_SIZE);
        end;
      end;
      if StOf(p)^.Freq < MAX_FREQ - 9 then cf := 2 else cf := 0;
      Inc(StOf(p)^.Freq, cf);
      Inc(CtxOf(pc)^.SummFreq, cf);
    end
    else
    begin
      p := pc + 2;
      if StOf(p)^.Freq < 32 then Inc(StOf(p)^.Freq);
    end;
  end;
  if (FOrderFall = 0) and (FSuccessor <> 0) then
  begin
    StOf(FFoundState)^.Succ := CreateSuccessors(True, p, MinContext);
    if StOf(FFoundState)^.Succ = 0 then goto RESTART_MODEL;
    FMaxContext := StOf(FFoundState)^.Succ;
    Exit;
  end;
  FHeap[FpText] := FSymbol;
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
  s0 := CtxOf(MinContext)^.SummFreq - CtxOf(MinContext)^.NumStats - FFreq;
  ns := CtxOf(MinContext)^.NumStats;
  if FSymbol >= $40 then Flag := $08 else Flag := 0;
  while pc1 <> MinContext do
  begin
    ns1 := CtxOf(pc1)^.NumStats;
    if ns1 <> 0 then
    begin
      if (ns1 and 1) <> 0 then
      begin
        p := ExpandUnits(CtxOf(pc1)^.Stats, (ns1 + 1) shr 1);
        if p = 0 then goto RESTART_MODEL;
        CtxOf(pc1)^.Stats := p;
      end;
      if 3 * ns1 + 1 < ns then Inc(CtxOf(pc1)^.SummFreq);
    end
    else
    begin
      p := AllocUnits(1);
      if p = 0 then goto RESTART_MODEL;
      StateCpy(StOf(p), OneOf(pc1));
      CtxOf(pc1)^.Stats := p;
      if StOf(p)^.Freq < MAX_FREQ div 4 - 1 then
        StOf(p)^.Freq := StOf(p)^.Freq + StOf(p)^.Freq
      else
        StOf(p)^.Freq := MAX_FREQ - 4;
      if ns > 2 then
        CtxOf(pc1)^.SummFreq := StOf(p)^.Freq + FInitEsc + 1
      else
        CtxOf(pc1)^.SummFreq := StOf(p)^.Freq + FInitEsc;
    end;
    cf := 2 * FFreq * (CtxOf(pc1)^.SummFreq + 6);
    sf := s0 + CtxOf(pc1)^.SummFreq;
    if cf < 6 * sf then
    begin
      cf := 1 + Ord(cf > sf) + Ord(cf >= 4 * sf);
      Inc(CtxOf(pc1)^.SummFreq, 4);
    end
    else
    begin
      cf := 4 + Ord(cf > 9 * sf) + Ord(cf > 12 * sf) + Ord(cf > 15 * sf);
      Inc(CtxOf(pc1)^.SummFreq, cf);
    end;
    Inc(CtxOf(pc1)^.NumStats);
    p := CtxOf(pc1)^.Stats + LongWord(CtxOf(pc1)^.NumStats) * STATE_SIZE;
    StOf(p)^.Succ := Successor;
    StOf(p)^.Symbol := FSymbol;
    StOf(p)^.Freq := Byte(cf);
    CtxOf(pc1)^.Flags := CtxOf(pc1)^.Flags or Flag;
    pc1 := CtxOf(pc1)^.Suffix;
  end;
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

procedure TPpmdEngine.DecodeBinSymbol(ctx: LongWord);
var
  indx: LongWord;
  rs: LongWord;
  bs: PWord;
begin
  indx := FNS2BSIndx[CtxOf(CtxOf(ctx)^.Suffix)^.NumStats] + FPrevSuccess + CtxOf(ctx)^.Flags;
  rs := ctx + 2;
  bs := @FBinSumm[FQTable[StOf(rs)^.Freq - 1]]
                 [indx + LongWord((FRunLength shr 26) and $20)];
  if AriGetCurrentShiftCount(TOT_BITS) < bs^ then
  begin
    FFoundState := rs;
    if StOf(rs)^.Freq < 196 then Inc(StOf(rs)^.Freq);
    FSubLow := 0; FSubHigh := bs^;
    bs^ := bs^ + Word(INTERVAL - GetMean(bs^, PERIOD_BITS, 2));
    FPrevSuccess := 1; Inc(FRunLength);
  end
  else
  begin
    FSubLow := bs^;
    bs^ := bs^ - Word(GetMean(bs^, PERIOD_BITS, 2));
    FSubHigh := BIN_SCALE;
    FInitEsc := EXP_ESCAPE[bs^ shr 10];
    FCharMask[StOf(rs)^.Symbol] := FEscCount;
    FNumMasked := 0; FPrevSuccess := 0; FFoundState := 0;
  end;
end;

procedure TPpmdEngine.DecodeSymbol1(ctx: LongWord);
var
  i, count, HiCnt: LongWord;
  p: LongWord;
begin
  p := CtxOf(ctx)^.Stats;
  HiCnt := StOf(p)^.Freq;
  FSubScale := CtxOf(ctx)^.SummFreq;
  count := AriGetCurrentCount;
  if count < HiCnt then
  begin
    FSubHigh := HiCnt;
    if 2 * HiCnt >= FSubScale then FPrevSuccess := 1 else FPrevSuccess := 0;
    FFoundState := p;
    Inc(StOf(p)^.Freq, 4); Inc(HiCnt, 4);
    Inc(CtxOf(ctx)^.SummFreq, 4);
    Inc(FRunLength, FPrevSuccess);
    if HiCnt > MAX_FREQ then Rescale(ctx);
    FSubLow := 0;
    Exit;
  end;
  i := CtxOf(ctx)^.NumStats;
  FPrevSuccess := 0;
  while True do
  begin
    Inc(p, STATE_SIZE);
    Inc(HiCnt, StOf(p)^.Freq);
    if HiCnt <= count then
    begin
      Dec(i);
      if i = 0 then
      begin
        FSubLow := HiCnt;
        FCharMask[StOf(p)^.Symbol] := FEscCount;
        i := CtxOf(ctx)^.NumStats;
        FNumMasked := Byte(i);
        FFoundState := 0;
        repeat
          Dec(p, STATE_SIZE);
          FCharMask[StOf(p)^.Symbol] := FEscCount;
          Dec(i);
        until i = 0;
        FSubHigh := FSubScale;
        Exit;
      end;
    end
    else
    begin
      FSubHigh := HiCnt;
      FSubLow := HiCnt - StOf(p)^.Freq;
      Update1(ctx, p);
      Exit;
    end;
  end;
end;

procedure TPpmdEngine.DecodeSymbol2(ctx: LongWord);
var
  psee2c: PSee2;
  i, count, HiCnt, n: LongWord;
  ps: array[0..255] of LongWord;   { en C es STATE* ps[256] }
  pb: PState;
  Sym: Byte;
begin
  psee2c := MakeEscFreq2(ctx);
  i := CtxOf(ctx)^.NumStats - FNumMasked;
  n := 0; HiCnt := 0;
  pb := PState(FHeap + CtxOf(ctx)^.Stats - STATE_SIZE);  { p := Stats-1 }
  repeat
    repeat
      Inc(pb);                     { ++p }
      Sym := pb^.Symbol;           { p[1] antes del ++, equivalente }
    until FCharMask[Sym] <> FEscCount;
    Inc(HiCnt, pb^.Freq);
    ps[n] := LongWord(PByte(pb) - FHeap);
    Inc(n);
  until n = i;
  Inc(FSubScale, HiCnt);
  count := AriGetCurrentCount;
  n := 0;
  pb := StOf(ps[0]);
  if count < HiCnt then
  begin
    HiCnt := 0;
    repeat
      Inc(HiCnt, pb^.Freq);
      if HiCnt > count then Break;
      Inc(n);
      pb := StOf(ps[n]);
    until False;
    FSubHigh := HiCnt;
    FSubLow := HiCnt - pb^.Freq;
    See2Update(psee2c);
    Update2(ctx, LongWord(PByte(pb) - FHeap));
  end
  else
  begin
    FSubLow := HiCnt;
    FSubHigh := FSubScale;
    i := CtxOf(ctx)^.NumStats - FNumMasked;
    FNumMasked := CtxOf(ctx)^.NumStats;
    n := 0;
    repeat
      FCharMask[StOf(ps[n])^.Symbol] := FEscCount;
      Inc(n);
      Dec(i);
    until i = 0;
    psee2c^.Summ := Word(psee2c^.Summ + FSubScale);
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
begin
  if FDone then Exit;
  if FState = 0 then
  begin
    AriInitDecoder;
    StartModelRare(FMaxOrder, FMRMethod);
    FMinContext := FMaxContext;
    FNs := CtxOf(FMinContext)^.NumStats;
    FState := 1;
  end;
  while FOutLen < ALimit do
  begin
    if FNs <> 0 then DecodeSymbol1(FMinContext) else DecodeBinSymbol(FMinContext);
    AriRemoveSubrange;
    while FFoundState = 0 do
    begin
      AriDecNormalize;
      repeat
        Inc(FOrderFall);
        FMinContext := CtxOf(FMinContext)^.Suffix;
        if FMinContext = 0 then goto StopDecoding;
      until CtxOf(FMinContext)^.NumStats <> FNumMasked;
      DecodeSymbol2(FMinContext);
      AriRemoveSubrange;
    end;
    Emit(StOf(FFoundState)^.Symbol);
    if (FOrderFall = 0) and (StOf(FFoundState)^.Succ >= FUnitsStart) then
      FMaxContext := StOf(FFoundState)^.Succ
    else
    begin
      UpdateModel(FMinContext);
      if FEscCount = 0 then ClearMask;
    end;
    FMinContext := FMaxContext;
    FNs := CtxOf(FMinContext)^.NumStats;
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
    raise EOutOfMemory.Create('ppmd: no hay memoria para el modelo');
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
    Corrupt('ppmd: memoria del modelo insuficiente');
  // El heap emula direcciones de 32 bits: el modelo tiene que caber en un offset UInt32
  if AMemSize > $FFFFFFFF - 4096 then
    Corrupt('ppmd: memoria del modelo demasiado grande');
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
  if Assigned(FEncSink) then FEncSink(@b, 1);
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
  indx, rs: LongWord;
  bs: PWord;
begin
  indx := FNS2BSIndx[CtxOf(CtxOf(ctx)^.Suffix)^.NumStats] + FPrevSuccess + CtxOf(ctx)^.Flags;
  rs := ctx + 2;
  bs := @FBinSumm[FQTable[StOf(rs)^.Freq - 1]]
                 [indx + LongWord((FRunLength shr 26) and $20)];
  if Integer(StOf(rs)^.Symbol) = symbol then
  begin
    FFoundState := rs;
    if StOf(rs)^.Freq < 196 then Inc(StOf(rs)^.Freq);
    FSubLow := 0; FSubHigh := bs^;
    bs^ := bs^ + Word(INTERVAL - GetMean(bs^, PERIOD_BITS, 2));
    FPrevSuccess := 1; Inc(FRunLength);
  end
  else
  begin
    FSubLow := bs^;
    bs^ := bs^ - Word(GetMean(bs^, PERIOD_BITS, 2));
    FSubHigh := BIN_SCALE;
    FInitEsc := EXP_ESCAPE[bs^ shr 10];
    FCharMask[StOf(rs)^.Symbol] := FEscCount;
    FNumMasked := 0; FPrevSuccess := 0; FFoundState := 0;
  end;
end;

procedure TPpmdEngine.EncodeSymbol1(ctx: LongWord; symbol: Integer);
var
  i, LoCnt: LongWord;
  p: LongWord;
begin
  p := CtxOf(ctx)^.Stats;
  FSubScale := CtxOf(ctx)^.SummFreq;
  if Integer(StOf(p)^.Symbol) = symbol then
  begin
    FSubHigh := StOf(p)^.Freq;
    if 2 * FSubHigh >= FSubScale then FPrevSuccess := 1 else FPrevSuccess := 0;
    FFoundState := p;
    Inc(StOf(p)^.Freq, 4); Inc(CtxOf(ctx)^.SummFreq, 4);
    Inc(FRunLength, FPrevSuccess);
    if StOf(p)^.Freq > MAX_FREQ then Rescale(ctx);
    FSubLow := 0;
    Exit;
  end;
  LoCnt := StOf(p)^.Freq;
  i := CtxOf(ctx)^.NumStats; FPrevSuccess := 0;
  while True do
  begin
    Inc(p, STATE_SIZE);
    if Integer(StOf(p)^.Symbol) = symbol then Break;
    Inc(LoCnt, StOf(p)^.Freq);
    if i = 1 then
    begin
      FSubLow := LoCnt;
      FCharMask[StOf(p)^.Symbol] := FEscCount;
      i := CtxOf(ctx)^.NumStats;
      FNumMasked := Byte(i);
      FFoundState := 0;
      repeat
        Dec(p, STATE_SIZE);
        FCharMask[StOf(p)^.Symbol] := FEscCount;
        Dec(i);
      until i = 0;
      FSubHigh := FSubScale;
      Exit;
    end;
    Dec(i);
  end;
  FSubLow := LoCnt;
  FSubHigh := LoCnt + StOf(p)^.Freq;
  Update1(ctx, p);
end;

procedure TPpmdEngine.EncodeSymbol2(ctx: LongWord; symbol: Integer);
var
  psee2c: PSee2;
  i, LoCnt: LongWord;
  p, p2: LongWord;
  Sym: Byte;
begin
  psee2c := MakeEscFreq2(ctx);          { fija FSubScale }
  LoCnt := 0;
  i := CtxOf(ctx)^.NumStats - FNumMasked;
  p := CtxOf(ctx)^.Stats - STATE_SIZE;  { Stats-1 }
  while True do
  begin
    repeat
      Inc(p, STATE_SIZE);
      Sym := StOf(p)^.Symbol;
    until FCharMask[Sym] <> FEscCount;
    FCharMask[Sym] := FEscCount;
    if Integer(Sym) = symbol then Break;
    Inc(LoCnt, StOf(p)^.Freq);
    if i = 1 then
    begin
      FSubLow := LoCnt;
      FSubScale := FSubScale + LoCnt;
      FSubHigh := FSubScale;
      psee2c^.Summ := Word(psee2c^.Summ + FSubScale);
      FNumMasked := CtxOf(ctx)^.NumStats;
      Exit;
    end;
    Dec(i);
  end;
  { símbolo encontrado }
  FSubLow := LoCnt;
  Inc(LoCnt, StOf(p)^.Freq);
  FSubHigh := LoCnt;
  p2 := p;
  Dec(i);
  while i <> 0 do
  begin
    repeat
      Inc(p2, STATE_SIZE);
      Sym := StOf(p2)^.Symbol;
    until FCharMask[Sym] <> FEscCount;
    Inc(LoCnt, StOf(p2)^.Freq);
    Dec(i);
  end;
  FSubScale := FSubScale + LoCnt;
  See2Update(psee2c);
  Update2(ctx, p);
end;

procedure TPpmdEngine.EncodeOne(c: Integer);
var
  ns: Byte;
begin
  if FEncDone then Exit;
  ns := FNs;
  if ns <> 0 then
  begin
    EncodeSymbol1(FMinContext, c);
    AriEncodeSymbol;
  end
  else
  begin
    EncodeBinSymbol(FMinContext, c);
    AriShiftEncodeSymbol(TOT_BITS);
  end;
  while FFoundState = 0 do
  begin
    AriEncNormalize;
    repeat
      Inc(FOrderFall);
      FMinContext := CtxOf(FMinContext)^.Suffix;
      if FMinContext = 0 then
      begin
        { Fin de la entrada alcanzado dentro del escape: en el C esto es el
          goto STOP_ENCODING de EncodeFile. }
        FEncDone := True;
        Exit;
      end;
    until CtxOf(FMinContext)^.NumStats <> FNumMasked;
    EncodeSymbol2(FMinContext, c);
    AriEncodeSymbol;
  end;
  if (FOrderFall = 0) and (StOf(FFoundState)^.Succ >= FUnitsStart) then
    FMaxContext := StOf(FFoundState)^.Succ
  else
  begin
    UpdateModel(FMinContext);
    if FEscCount = 0 then ClearMask;
  end;
  FMinContext := FMaxContext;
  FNs := CtxOf(FMinContext)^.NumStats;
  AriEncNormalize;
end;

procedure TPpmdEngine.StartEncode;
begin
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
    if FEncDone then Exit;
    EncodeOne(Buf[i]);
  end;
end;

procedure TPpmdEngine.FinishEncode;
begin
  { El fin de la entrada se codifica como símbolo (EOF = -1), igual que EncodeFile. }
  EncodeOne(-1);
  AriFlushEncoder;
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
    Corrupt('ppmd: memoria del modelo insuficiente');
  if AMemSize > $FFFFFFFF - 4096 then
    Corrupt('ppmd: memoria del modelo demasiado grande');
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
