{ GRZip al comprimir (método `grzip` de FreeArc, Compression/GRZip/; GRZipII/libGRZip de
  I. Grebnov). Decodificador y formato del stream: parc_grzip.

  Port de GRZip_CompressBlock / GRZip_StoreBlock / GRZip_GetAdaptiveBlockSize y
  GRZipMTCompressor (C_GRZip.cpp), GRZip_LZP_Encode (LZP.c), GRZip_BWT_Encode con sus dos
  ordenamientos (BWT.c: "fast" por grupos y ternario con presupuesto AML, "strong" por
  duplicación de prefijos), GRZip_ST4_Encode (ST4.c), GRZip_MTF_Ari_Encode (MTF_Ari.c),
  GRZip_WFC_Ari_Encode (WFC_Ari.c) y GRZip_Rec_Test / GRZip_Rec_Encode (Rec_Flt.c).
  Todo es determinista (no hay qsort): la salida es la del C bloque por bloque, con la semántica
  del binario de 32 bits donde el C depende de ella (tabla hash de LZP, lecturas fuera del
  bloque). Diferencias posibles, solo en casos límite:
   - log10 de la RTL (Rec_Test, bloque adaptativo) puede diferir en 1 ulp del de la libc;
   - donde el C se saldría de su buffer de salida (MTF/WFC con miles de bytes 0xFF
     pendientes) acá el bloque sale guardado;
   - H[12] de los bloques -2 el C no lo escribe (queda lo que había en el buffer reciclado):
     acá es 0. El decodificador no lo lee.
  Cortes de bloque: GRZipMTCompressor::ReaderThread (C_GRZip.cpp:447) comprime lo que
  devuelva UNA lectura del callback, y Arc.exe devuelve lecturas parciales (bloques de ~7 MB
  con b8mb, cortes cerca de los límites de archivo). Acá se corta al llegar a BlockSize (como
  el C con lecturas completas); con los mismos cortes la salida es la de Arc.exe.

  Parámetros (parse_GRZIP): m1..m4, b<mem>, l<N>/l, h<N>, s, a, d, p, t<N>, i<N>, un entero
  sin nombre = largo mínimo de LZP y una memoria sin nombre = tamaño de bloque (sin sufijo es
  potencia de 2, como en el C). Todo queda en el Mode de cada bloque (libGRZip.h), con la
  aritmética de 32 bits del C: l>=32768 lo desborda (se rechaza), h>=256 se mete en l. }
unit parc_grzipenc;

{$mode objfpc}{$H+}
{$pointermath on}
{$R-}{$Q-}
{$macro on}

interface

uses
  Classes, SysUtils, Math, parc_outstream, parc_parallel;

type
  EGrzipEncParams = class(Exception);

  { GRZipMTCompressor: bloques de BlockSize bytes (o los que decida el bloque adaptativo)
    comprimidos en paralelo y escritos en orden. Memoria: hasta hilos+1 bloques en vuelo,
    cada uno ~11 veces su tamaño mientras se comprime (BWT strong). }
  TGrzipEncStage = class(TOutStage)
  private
    FMode: LongInt;
    FBlockSize: SizeInt;
    FAdaptive: Boolean;
    FCur: TBytes;               // bloque que se está llenando
    FLen: SizeInt;
    FPool: TJobPool;
    FQueue: array of TParallelJob;   // trabajos en vuelo, en orden
    FHead, FCount: Integer;
    procedure CutBlocks(Final: Boolean);
    procedure SubmitBlock(Size: SizeInt);
    procedure WriteOldest;
  protected
    procedure DoWrite(Buf: PByte; Count: SizeInt); override;
    procedure DoFinish; override;
  public
    constructor Create(ATarget: TOutStage; const Params: TStringArray);
    destructor Destroy; override;
  end;

{ parse_GRZIP + el armado del Mode de GRZipMTCompressor. EGrzipEncParams si no es válido. }
procedure ParseGrzipEncParams(const Params: TStringArray; out Mode: LongInt; out BlockSize: SizeInt;
  out Adaptive: Boolean);

{ Capacidad de salida que necesita GrzipCompressBlock para un bloque de Size bytes. }
function GrzipBlockOutCap(Size: SizeInt): SizeInt;

{ GRZip_CompressBlock: un bloque completo (encabezado de 28 bytes + datos) en Output, que tiene
  OutCap >= GrzipBlockOutCap(Size) bytes. Devuelve el largo escrito. }
function GrzipCompressBlock(Input: PByte; Size: LongInt; Output: PByte; OutCap: SizeInt; Mode: LongInt): LongInt;

{ GRZip_GetAdaptiveBlockSize: cuántos bytes del principio conviene comprimir juntos. }
function GrzipAdaptiveBlockSize(Input: PByte; Size: LongInt): LongInt;


implementation

const
  GRZ_MaxBlockSize = 8*1024*1024 - 512;
  GRZ_Log2MaxBlockSize = 23;
  LZP_MaxMatchLen = 32768;
  HDR = 28;
  MaxHashLog = 28;   // como parc_grzip: con más, el Arc.exe de 32 bits no puede reservar la tabla
  OUT_SLACK = 2*LZP_MaxMatchLen + 1024;

  GRZ_NOT_COMPRESSIBLE = -4;
  GRZ_FAST_BWT_FAILS = -5;

  GRZ_Disable_DeltaFlt = $1;
  GRZ_Compression_ST4 = $2;
  GRZ_Compression_MTF = $4;
  GRZ_BWTSorting_Fast = $8;
  StrongBWT_Flag = $40000000;

procedure PutI32(p: PByte; V: LongInt); inline;
var
  u: LongWord;
begin
  u := LongWord(V);
  p[0] := u and $FF; p[1] := (u shr 8) and $FF; p[2] := (u shr 16) and $FF; p[3] := u shr 24;
end;

{ Get_LZP_MinMatchLen / Get_LZP_HT_Size de libGRZip.h (división con signo, 1<<n módulo 32). }
function ModeMinLen(Mode: LongInt): LongInt; inline;
begin
  Result := (Mode div 65536) mod 32767;
end;

function ModeHTMask(Mode: LongInt): LongWord; inline;
begin
  Result := (LongWord(1) shl (((Mode div 256) mod 256) and 31)) - 1;
end;

{ ---------- LZP (LZP.c) ---------- }

const
  LZP_MatchFlag = $F2;
  LZP_RunFlag = $F3;
  LZP_XorFlag = $FF xor LZP_RunFlag;

{ GRZip_LZP_Encode. La tabla guarda offsets en Input (0 = vacío: siempre son >= 4) en vez de
  punteros: el C la dimensiona con sizeof(uint32) (LZP.c:46), bien en 32 bits y desbordada en
  64. La comparación previa de 4 bytes en MinLen-4 (LZP.c:78) en el C puede leer después del
  bloque; en ese caso el largo común no llega a MinLen de todos modos, así que acá se omite. }
function LzpEncCore(Input: PByte; Size: SizeInt; Output: PByte; MinLen: LongInt; HTMask: LongWord;
  Contexts: PLongWord): LongInt;
var
  ip, op, OutEnd, p, q, CmpOff: SizeInt;
  Ctx, h, ptr, Len: LongWord;
  Ch: Byte;
begin
  OutEnd := Size - 1;
  PLongWord(Output)^ := PLongWord(Input)^;
  Ctx := LongWord(Input[3]) or (LongWord(Input[2]) shl 8) or (LongWord(Input[1]) shl 16) or (LongWord(Input[0]) shl 24);
  ip := 4; op := 4;
  CmpOff := MinLen - 4;
  while (ip < Size) and (op < OutEnd) do
  begin
    h := ((Ctx shr 15) xor Ctx xor (Ctx shr 3)) and HTMask;
    ptr := Contexts[h];
    Contexts[h] := LongWord(ip);
    if ptr <> 0 then
    begin
      Len := 0;
      if (ip + CmpOff + 4 <= Size) and
         (PLongWord(Input + ip + CmpOff)^ = PLongWord(Input + SizeInt(ptr) + CmpOff)^) then
      begin
        p := ip; q := ptr;
        while (p < Size) and (Input[p] = Input[q]) do
        begin
          Inc(p); Inc(q); Inc(Len);
        end;
      end;
      if Len < LongWord(MinLen) then Len := 0;
      if Len <> 0 then
      begin
        Inc(ip, Len);
        Ctx := LongWord(Input[ip-1]) or (LongWord(Input[ip-2]) shl 8) or (LongWord(Input[ip-3]) shl 16) or (LongWord(Input[ip-4]) shl 24);
        Len := Len - LongWord(MinLen) + 1;
        Output[op] := LZP_MatchFlag; Inc(op);
        while Len > 254 do
        begin
          Output[op] := LZP_RunFlag; Inc(op);
          if op >= OutEnd then Exit(GRZ_NOT_COMPRESSIBLE);
          Dec(Len, 255);
        end;
        Output[op] := Byte(Len xor LZP_XorFlag); Inc(op);
      end
      else
      begin
        Ch := Input[ip]; Inc(ip);
        Output[op] := Ch; Inc(op);
        Ctx := (Ctx shl 8) or Ch;
        if Ch = LZP_MatchFlag then
        begin
          Output[op] := LZP_XorFlag; Inc(op);
        end;
      end;
    end
    else
    begin
      Ch := Input[ip]; Inc(ip);
      Output[op] := Ch; Inc(op);
      Ctx := (Ctx shl 8) or Ch;
    end;
  end;
  if op >= OutEnd then Exit(GRZ_NOT_COMPRESSIBLE);
  Result := op;
end;

function LzpEncode(Input: PByte; Size: SizeInt; Output: PByte; Mode: LongInt): LongInt;
var
  Contexts: PLongWord;
  Mask: LongWord;
begin
  Mask := ModeHTMask(Mode);
  Contexts := AllocMem((SizeInt(Mask) + 1) * SizeOf(LongWord));
  try
    Result := LzpEncCore(Input, Size, Output, ModeMinLen(Mode), Mask, Contexts);
  finally
    FreeMem(Contexts);
  end;
end;

{ ---------- filtro de registros (Rec_Flt.c) ---------- }

{ GRZip_Rec_Test: 0 = sin filtro; 1/2 = intercalar bytes de palabras de 2/4; 3/4 = además
  delta de palabras de 16/32 bits (little-endian). }
function RecTest(Input: PByte; Size: LongInt): LongInt;
var
  Freq0: array[0..255] of LongInt;
  Freq2: array[0..1, 0..255] of LongInt;
  Freq4: array[0..3, 0..255] of LongInt;
  i, j, Fr: LongInt;
  c: Byte;
  MinEntropy, Entropy: Double;
  Sum, SumDelta: Int64;
  Code16, MinCode16, Pred16, Delta16: Word;
  Code32, MinCode32, Pred32, Delta32: LongWord;
begin
  FillChar(Freq0, SizeOf(Freq0), 0);
  FillChar(Freq2, SizeOf(Freq2), 0);
  FillChar(Freq4, SizeOf(Freq4), 0);
  for i := 0 to Size - 1 do
  begin
    c := Input[i];
    Inc(Freq0[c]); Inc(Freq2[i and 1, c]); Inc(Freq4[i and 3, c]);
  end;
  Result := 0;
  MinEntropy := 0;
  for i := 0 to 255 do
  begin
    Fr := Freq0[i];
    if Fr <> 0 then MinEntropy := MinEntropy - Fr * log10(Double(Fr) / Size);
  end;
  MinEntropy := MinEntropy * 0.93;
  Entropy := 0;
  for j := 0 to 1 do
    for i := 0 to 255 do
    begin
      Fr := Freq2[j, i];
      if Fr <> 0 then Entropy := Entropy - Fr * log10(2 * Double(Fr) / Size);
    end;
  if Entropy < MinEntropy then
  begin
    MinEntropy := 0.95 * Entropy;
    Result := 1;
  end;
  Entropy := 0;
  for j := 0 to 3 do
    for i := 0 to 255 do
    begin
      Fr := Freq4[j, i];
      if Fr <> 0 then Entropy := Entropy - Fr * log10(4 * Double(Fr) / Size);
    end;
  if Entropy < MinEntropy then Result := 2;

  if Result = 1 then
  begin
    Sum := 0; SumDelta := 0; MinCode16 := $FFFF; Pred16 := 0;
    for i := 0 to (Size shr 1) - 1 do
    begin
      Code16 := PWord(Input)[i];
      if Code16 < MinCode16 then MinCode16 := Code16;
      Inc(Sum, Code16);
      Delta16 := Word(Code16 - Pred16); Pred16 := Code16;
      if (Delta16 and $8000) <> 0 then Delta16 := Word((not Delta16) shl 1) or 1 else Delta16 := Word(Delta16 shl 1);
      Inc(SumDelta, Delta16);
    end;
    // MinCode*(Size>>1) es int*int en el C: se desborda a 32 bits con signo (Rec_Flt.c:110)
    if Sum - Int64(LongInt(LongWord(MinCode16) * LongWord(Size shr 1))) > SumDelta + (SumDelta shr 4) then Result := 3;
  end;
  if Result = 2 then
  begin
    Sum := 0; SumDelta := 0; MinCode32 := $FFFFFFFF; Pred32 := 0;
    for i := 0 to (Size shr 2) - 1 do
    begin
      Code32 := PLongWord(Input)[i];
      if Code32 < MinCode32 then MinCode32 := Code32;
      Inc(Sum, Code32);
      Delta32 := LongWord(Code32 - Pred32); Pred32 := Code32;
      if (Delta32 and $80000000) <> 0 then Delta32 := LongWord((not Delta32) shl 1) or 1 else Delta32 := LongWord(Delta32 shl 1);
      Inc(SumDelta, Delta32);
    end;
    // uint32*int: producto sin signo módulo 2^32 (Rec_Flt.c:131)
    if Sum - Int64(LongWord(MinCode32 * LongWord(Size shr 2))) > SumDelta + (SumDelta shr 4) then Result := 4;
  end;
end;

{ GRZip_Rec_Encode. }
procedure RecEncode(Input: PByte; Size: LongInt; Output: PByte; Mode: LongInt);
var
  NumRecords, P1, P2, P3, i, r, k: LongInt;
  Delta16, Code16, Pred16: Word;
  Delta32, Code32, Pred32: LongWord;
begin
  case Mode of
    3:
      begin
        NumRecords := Size shr 1;
        Pred16 := 0;
        for r := 0 to NumRecords - 1 do
        begin
          Code16 := PWord(Input)[r];
          Delta16 := Word(Code16 - Pred16); Pred16 := Code16;
          if (Delta16 and $8000) <> 0 then Delta16 := Word((not Delta16) shl 1) or 1 else Delta16 := Word(Delta16 shl 1);
          Output[r + NumRecords] := Byte(Delta16);
          Output[r] := Byte(Delta16 shr 8);
        end;
        r := NumRecords;
        for i := 2*NumRecords to Size - 1 do
        begin
          Output[r + NumRecords] := Input[i];
          Inc(r);
        end;
      end;
    4:
      begin
        NumRecords := Size shr 2;
        P1 := NumRecords; P2 := 2*NumRecords; P3 := 3*NumRecords;
        Pred32 := 0;
        for r := 0 to NumRecords - 1 do
        begin
          Code32 := PLongWord(Input)[r];
          Delta32 := LongWord(Code32 - Pred32); Pred32 := Code32;
          if (Delta32 and $80000000) <> 0 then Delta32 := LongWord((not Delta32) shl 1) or 1 else Delta32 := LongWord(Delta32 shl 1);
          Output[r + P1] := Byte(Delta32);
          Output[r + P2] := Byte(Delta32 shr 8);
          Output[r + P3] := Byte(Delta32 shr 16);
          Output[r] := Byte(Delta32 shr 24);
        end;
        r := NumRecords;
        for i := 4*NumRecords to Size - 1 do
        begin
          Output[r + P3] := Input[i];
          Inc(r);
        end;
      end;
    1, 2:
      begin
        if Mode = 1 then P1 := 2 else P1 := 4;
        r := 0;
        for k := 0 to P1 - 1 do
        begin
          i := k;
          while i < Size do
          begin
            Output[r] := Input[i]; Inc(r); Inc(i, P1);
          end;
        end;
      end;
  end;
end;

{ ---------- ST4 (ST4.c) ---------- }

{ GRZip_ST4_Encode, en el lugar (Input = Output). Size >= 8. Los núcleos (St4Core,
  StrongBwtCore, FastBwtCore) no tienen try/finally: en esas funciones FPC no deja variables
  en registros. }
function St4Core(Input: PByte; Size: LongInt; Counter: PLongInt; Context: PLongWord): LongInt;
var
  FBP, i: LongInt;
  W: LongWord;
  c: Byte;
begin
  W := LongWord(Input[Size-1]) shl 8;
  for i := 0 to Size - 1 do
  begin
    W := (W shr 8) or (LongWord(Input[i]) shl 8);
    Inc(Counter[W]);
  end;
  W := 0;
  for i := 0 to 65535 do
  begin
    Inc(W, LongWord(Counter[i]));
    Counter[i] := LongInt(W) - Counter[i];
  end;
  W := (LongWord(Input[Size-4]) shl 8) or Input[Size-5];
  if W = $FFFF then FBP := Size - 1 else FBP := Counter[W + 1] - 1;
  W := (LongWord(Input[Size-1]) shl 24) or (LongWord(Input[Size-2]) shl 16) or (LongWord(Input[Size-3]) shl 8) or Input[Size-4];
  for i := 0 to Size - 1 do
  begin
    c := Input[i];
    Context[Counter[W and $FFFF]] := (W and $FFFF0000) or c;
    Inc(Counter[W and $FFFF]);
    W := (W shr 8) or (LongWord(c) shl 24);
  end;
  i := Size - 1;
  while i >= FBP do
  begin
    Dec(Counter[Context[i] shr 16]);
    Input[Counter[Context[i] shr 16]] := Byte(Context[i]);
    Dec(i);
  end;
  FBP := Counter[Context[FBP] shr 16];
  while i >= 0 do
  begin
    Dec(Counter[Context[i] shr 16]);
    Input[Counter[Context[i] shr 16]] := Byte(Context[i]);
    Dec(i);
  end;
  Result := FBP;
end;

function St4Encode(Input: PByte; Size: LongInt): LongInt;
var
  Counter: PLongInt;
  Context: PLongWord;
begin
  Counter := AllocMem(65536 * SizeOf(LongInt));
  Context := nil;
  try
    GetMem(Context, SizeInt(Size) * SizeOf(LongWord));
    Result := St4Core(Input, Size, Counter, Context);
  finally
    if Context <> nil then FreeMem(Context);
    FreeMem(Counter);
  end;
end;

{ ---------- BWT (BWT.c) ---------- }

const
  BWT_MinQSort = 20;
  BWT_MedTrh = 96;
  FastBWT_MaxQSortDepth = 32;
  FastBWT_QSortStackSize = 1024;
  FastBWT_NumOverShoot = 80;
  NG = 8;   // FastBWT_NumGroups
  StrongBWT_TSortStackSize = 3*65536;
  StrongBWT_CMask = $3FFFFFFF;
  StrongBWT_SMask = $40000000;

function Med3(MA, MB, MC: LongWord): LongWord; inline;
var
  MT: LongWord;
begin
  if MA > MB then begin MT := MA; MA := MB; MB := MT; end;
  if MB > MC then
  begin
    MB := MC;
    if MA > MB then MB := MA;
  end;
  Result := MB;
end;

{ --- strong --- }

// StrongBWT_SimpleCMP
function StrongCmp(Group: PLongWord; i1, i2: LongInt): Boolean; inline;
var
  C1, C2: LongWord;
begin
  C1 := Group[i1]; C2 := Group[i2];
  while C1 = C2 do
  begin
    Inc(i1, 2); Inc(i2, 2);
    C1 := Group[i1]; C2 := Group[i2];
  end;
  Result := C1 > C2;
end;

procedure StrongSetRanks(Index: PLongInt; Group: PLongWord; Lo, Hi: LongInt); inline;
var
  i: LongInt;
begin
  for i := Lo to Hi do
    Group[Index[i]] := (Group[Index[i]] and $FF000000) or LongWord(i);
end;

// StrongBWT_ShellSort
procedure StrongShellSort(Index: PLongInt; Group: PLongWord; Lo, Hi, d: LongInt);
var
  i, j, s, h, n: LongInt;
begin
  if Lo = Hi then
  begin
    Group[Index[Lo]] := (Group[Index[Lo]] and $FF000000) or LongWord(Lo);
    Exit;
  end;
  h := 1; n := Hi - Lo + 1;
  while h < n do h := h*3 + 1;
  repeat
    h := h div 3;
    for i := Lo + h to Hi do
    begin
      s := Index[i] + d;
      j := i;
      while StrongCmp(Group, Index[j-h] + d, s) do
      begin
        Index[j] := Index[j-h];
        Dec(j, h);
        if j < h + Lo then Break;
      end;
      Index[j] := s - d;
    end;
  until h = 1;
  StrongSetRanks(Index, Group, Lo, Hi);
end;

// StrongBWT_ShellSortDeph2
procedure StrongShellSortD2(Index: PLongInt; Group: PLongWord; Lo, Hi: LongInt);
var
  i, j, s, g, k: LongInt;
const
  Gaps: array[0..2] of LongInt = (13, 4, 1);
begin
  if Hi = Lo then
  begin
    Group[Index[Lo]] := (Group[Index[Lo]] and $FF000000) or LongWord(Lo);
    Exit;
  end;
  for k := 0 to 2 do
  begin
    g := Gaps[k];
    if (g > 1) and (Hi - Lo <= g) then Continue;   // if (Hi-Lo>13) / if (Hi-Lo>4)
    for i := Lo + g to Hi do
    begin
      s := Index[i] + 2;
      j := i - g;
      while StrongCmp(Group, Index[j] + 2, s) do
      begin
        Index[j+g] := Index[j];
        Dec(j, g);
        if j < Lo then Break;
      end;
      Index[j+g] := s - 2;
    end;
  end;
  StrongSetRanks(Index, Group, Lo, Hi);
end;

procedure VSwap(Index: PLongInt; S1, S2, Num: LongInt); inline;
var
  t: LongInt;
begin
  while Num <> 0 do
  begin
    t := Index[S1]; Index[S1] := Index[S2]; Index[S2] := t;
    Inc(S1); Inc(S2); Dec(Num);
  end;
end;

// StrongBWT_TernarySort (Stack: BGroups, 3*65536+3 lugares en el C)
procedure StrongTernarySort(Index: PLongInt; Group: PLongWord; Lo, Hi: LongInt; Stack: PLongInt);
var
  A, B, C, D, N, M, Dep, sp, t: LongInt;
  Med, Med1, Med2, Med3v, v: LongWord;
begin
  sp := 0;
  Stack[sp] := Lo; Stack[sp+1] := Hi; Stack[sp+2] := 2; Inc(sp, 3);
  while sp <> 0 do
  begin
    Dec(sp, 3); Lo := Stack[sp]; Hi := Stack[sp+1]; Dep := Stack[sp+2];
    if Hi < Lo then Continue;
    if (Hi - Lo < BWT_MinQSort) or (sp >= StrongBWT_TSortStackSize) then
    begin
      StrongShellSort(Index, Group, Lo, Hi, Dep);
      Continue;
    end;
    if Hi - Lo < BWT_MedTrh then
      Med := Med3(Group[Index[(Lo+Hi) shr 1]+Dep], Group[Index[Lo]+Dep], Group[Index[Hi]+Dep])
    else
    begin
      M := (Hi + Lo) shr 1;
      N := (Hi - Lo) shr 3;
      Med1 := Med3(Group[Index[Lo]+Dep], Group[Index[Lo+N]+Dep], Group[Index[Lo+N+N]+Dep]);
      Med2 := Med3(Group[Index[M-N]+Dep], Group[Index[M]+Dep], Group[Index[M+N]+Dep]);
      Med3v := Med3(Group[Index[Hi-N-N]+Dep], Group[Index[Hi-N]+Dep], Group[Index[Hi]+Dep]);
      Med := Med3(Med1, Med2, Med3v);
    end;
    A := Lo; B := Lo; C := Hi; D := Hi;
    while True do
    begin
      while B <= C do
      begin
        v := Group[Index[B]+Dep];
        if v = Med then
        begin
          t := Index[A]; Index[A] := Index[B]; Index[B] := t;
          Inc(A); Inc(B);
          Continue;
        end;
        if v > Med then Break;
        Inc(B);
      end;
      while B <= C do
      begin
        v := Group[Index[C]+Dep];
        if v = Med then
        begin
          t := Index[C]; Index[C] := Index[D]; Index[D] := t;
          Dec(D); Dec(C);
          Continue;
        end;
        if v < Med then Break;
        Dec(C);
      end;
      if B > C then Break;
      t := Index[B]; Index[B] := Index[C]; Index[C] := t;
      Inc(B); Dec(C);
    end;
    if D < A then
    begin
      Stack[sp] := Lo; Stack[sp+1] := Hi; Stack[sp+2] := Dep + 2; Inc(sp, 3);
      Continue;
    end;
    N := Min(A - Lo, B - A); VSwap(Index, Lo, B - N, N);
    M := Min(Hi - D, D - C); VSwap(Index, B, Hi - M + 1, M);
    N := Lo + B - A;
    M := Hi - (D - C);
    Stack[sp] := M + 1; Stack[sp+1] := Hi; Stack[sp+2] := Dep; Inc(sp, 3);
    Stack[sp] := N; Stack[sp+1] := M; Stack[sp+2] := Dep + 2; Inc(sp, 3);
    Stack[sp] := Lo; Stack[sp+1] := N - 1; Stack[sp+2] := Dep; Inc(sp, 3);
  end;
end;

function StrongBwtCore(Input: PByte; Size: LongInt; Output: PByte; Group: PLongWord; Index, Buckets, BGroups: PLongInt): LongInt;
var
  RunOrder, BigDone: array[0..255] of Byte;
  CopyStart, CopyEnd: array[0..255] of LongInt;
  LB, S, c, sch: Byte;
  i, h, j, k, Lo, Hi: LongInt;
  W, Ps: LongWord;

  function BFreq(Bt: LongInt): LongInt; inline;
  begin
    Result := Buckets[(Bt + 1) shl 8] - Buckets[Bt shl 8];
  end;

begin
  LB := Input[Size-1]; W := LongWord(LB) shl 8; Inc(Buckets[W]);
  for i := Size - 2 downto 0 do
  begin
    W := (W shr 8) or (LongWord(Input[i]) shl 8);
    Inc(Buckets[W]);
  end;
  BGroups[0] := Buckets[0];
  for i := 1 to 65536 do
  begin
    Inc(Buckets[i], Buckets[i-1]);
    BGroups[i] := Buckets[i];
  end;
  W := LongWord(LB) shl 8;
  for i := Size - 2 downto 0 do
  begin
    W := (W shr 8) or (LongWord(Input[i]) shl 8);
    Group[i] := LongWord(BGroups[W]) or (LongWord(Input[i]) shl 24);
    Index[Buckets[W]] := i;
    Dec(Buckets[W]);
  end;
  Group[Size] := 0;
  Group[Size-1] := LongWord(Buckets[LongWord(LB) shl 8]) or (LongWord(LB) shl 24);
  Index[0] := Size;
  Index[Buckets[LongWord(LB) shl 8]] := Size - 1;
  Dec(Buckets[LongWord(LB) shl 8]);

  for i := 0 to 255 do
  begin
    RunOrder[i] := i; BigDone[i] := 0;
  end;
  h := 364;
  repeat
    h := h div 3;
    for i := h to 255 do
    begin
      sch := RunOrder[i];
      j := i;
      while BFreq(RunOrder[j-h]) > BFreq(sch) do
      begin
        RunOrder[j] := RunOrder[j-h];
        Dec(j, h);
        if j < h then Break;
      end;
      RunOrder[j] := sch;
    end;
  until h = 1;

  h := 0;
  while BFreq(RunOrder[h]) = 0 do Inc(h);

  while h < 256 do
  begin
    S := RunOrder[h];
    for j := 0 to 255 do
      if j <> S then
      begin
        k := (LongInt(S) shl 8) or j;
        Lo := Buckets[k] + 1;
        Hi := Buckets[k+1] and StrongBWT_CMask;
        if (LongInt(LB) shl 8) = k then Inc(Lo);
        if (Lo < StrongBWT_SMask) and (Hi >= Lo) then
          if Hi - Lo > BWT_MinQSort then
            StrongTernarySort(Index, Group, Lo, Hi, BGroups)
          else
            StrongShellSortD2(Index, Group, Lo, Hi);
      end;

    for j := 0 to 255 do
    begin
      CopyStart[j] := (Buckets[(j shl 8) + S] and StrongBWT_CMask) + 1;
      if (LongInt(LB) shl 8) = (j shl 8) + S then Inc(CopyStart[j]);
      Buckets[(j shl 8) + S] := Buckets[(j shl 8) + S] or StrongBWT_SMask;
      CopyEnd[j] := Buckets[(j shl 8) + S + 1] and StrongBWT_CMask;
    end;

    j := (Buckets[LongInt(S) shl 8] and StrongBWT_CMask) + 1;
    while j < CopyStart[S] do
    begin
      k := Index[j] - 1;
      if k >= 0 then
      begin
        c := Group[k] shr 24;
        if BigDone[c] = 0 then
        begin
          Group[k] := (Group[k] and $FF000000) or LongWord(CopyStart[c]);
          Index[CopyStart[c]] := k;
          Inc(CopyStart[c]);
        end;
      end;
      Inc(j);
    end;

    j := Buckets[(LongInt(S) + 1) shl 8] and StrongBWT_CMask;
    while j > CopyEnd[S] do
    begin
      k := Index[j] - 1;
      if k >= 0 then
      begin
        c := Group[k] shr 24;
        if BigDone[c] = 0 then
        begin
          Group[k] := (Group[k] and $FF000000) or LongWord(CopyEnd[c]);
          Index[CopyEnd[c]] := k;
          Dec(CopyEnd[c]);
        end;
      end;
      Dec(j);
    end;
    BigDone[S] := 1;
    Inc(h);
  end;

  LB := Group[0] shr 24;
  W := Group[0] and $FFFFFF;
  for i := 1 to Size do
  begin
    Ps := Group[i] and $FFFFFF;
    c := Group[i] shr 24;
    if Ps < W then Output[Ps] := LB else Output[Ps-1] := LB;
    LB := c;
  end;
  Result := LongInt(W);
end;

{ GRZip_StrongBWT_Encode (Input = Output permitido). Devuelve el índice primario. }
function StrongBwtEncode(Input: PByte; Size: LongInt; Output: PByte): LongInt;
var
  Group: PLongWord;
  Index, Buckets, BGroups: PLongInt;
begin
  Group := nil; Index := nil; Buckets := nil; BGroups := nil;
  try
    // + relleno en cero: StrongCmp nunca pasa de Group[Size] con datos reales
    Group := AllocMem((SizeInt(Size) + 8) * SizeOf(LongWord));
    Index := AllocMem((SizeInt(Size) + 1) * SizeOf(LongInt));
    Buckets := AllocMem((65536 + 1) * SizeOf(LongInt));
    // el C reserva 3*65536+3 y puede escribir hasta 5 más allá (BWT.c:201 y 286): margen
    BGroups := AllocMem((StrongBWT_TSortStackSize + 16) * SizeOf(LongInt));
    Result := StrongBwtCore(Input, Size, Output, Group, Index, Buckets, BGroups);
  finally
    if BGroups <> nil then FreeMem(BGroups);
    if Buckets <> nil then FreeMem(Buckets);
    if Index <> nil then FreeMem(Index);
    if Group <> nil then FreeMem(Group);
  end;
end;

{ --- fast --- }

{ FastBWT_SimpleCmp: palabras de 32 bits (lectura no alineada, little-endian) hacia atrás de
  a 8, dando la vuelta al llegar al principio; cada vuelta de 32 bytes iguales gasta 1 de AML. }
function FastCmp(C1, C2: PLongWord; Size: SizeInt; Base: PLongWord; AML: PLongInt): Boolean; inline;
var
  k: SizeInt;
begin
  Result := False;
  while True do
  begin
    k := 0;
    while (k > -8) and (C1[k] = C2[k]) do Dec(k);
    if k > -8 then
    begin
      Result := C1[k] > C2[k];
      Break;
    end;
    Dec(C1, 8); Dec(C2, 8);
    if C1 < Base then C1 := PLongWord(PByte(C1) + Size);
    if C2 < Base then C2 := PLongWord(PByte(C2) + Size);
    Dec(AML^);
    if AML^ < 0 then Break;
  end;
end;

// FastBWT_ShellSortDeph2
procedure FastShellSortD2(Index: PLongInt; Input: PByte; Lo, Hi: LongInt; Size: SizeInt; AML: PLongInt);
var
  i, j, Idx, g, k: LongInt;
  Ptr: PLongWord;
const
  Gaps: array[0..2] of LongInt = (13, 4, 1);
begin
  for k := 0 to 2 do
  begin
    g := Gaps[k];
    if (g > 1) and (Hi - Lo <= g) then Continue;
    for i := Lo + g to Hi do
    begin
      Idx := Index[i];
      Ptr := PLongWord(Input + Idx - 4);
      j := i - g;
      while FastCmp(PLongWord(Input + Index[j] - 4), Ptr, Size, PLongWord(Input), AML) do
      begin
        Index[j+g] := Index[j];
        Dec(j, g);
        if j < Lo then Break;
      end;
      Index[j+g] := Idx;
      if AML^ < 0 then Exit;
    end;
  end;
end;

// FastBWT_ShellSort
procedure FastShellSort(Index: PLongInt; Input: PByte; Lo, Hi, d: LongInt; Size: SizeInt; AML: PLongInt);
var
  i, j, h, n, Idx: LongInt;
  Ptr: PLongWord;
begin
  h := 1; n := Hi - Lo + 1;
  while h < n do h := h*3 + 1;
  repeat
    h := h div 3;
    for i := Lo + h to Hi do
    begin
      Idx := Index[i];
      Ptr := PLongWord(Input + Idx + d);
      j := i;
      while FastCmp(PLongWord(Input + Index[j-h] + d), Ptr, Size, PLongWord(Input), AML) do
      begin
        Index[j] := Index[j-h];
        Dec(j, h);
        if j < h + Lo then Break;
      end;
      Index[j] := Idx;
      if AML^ < 0 then Exit;
    end;
  until h = 1;
end;

// FastBWT_TernarySort
procedure FastTernarySort(Index: PLongInt; Input: PByte; Lo, Hi: LongInt; Size: SizeInt; AML: PLongInt);
var
  Stack: array[0..4*FastBWT_QSortStackSize-1] of LongInt;   // el C: 1024 (no llega)
  NextLo, NextHi, NextDepth: array[0..2] of LongInt;
  A, B, C, D, N, M, Dep, sp, t: LongInt;
  Med, Med1, Med2, Med3v, v: LongWord;

  procedure NSwap(N1, N2: Integer); inline;
  var
    x: LongInt;
  begin
    x := NextLo[N1]; NextLo[N1] := NextLo[N2]; NextLo[N2] := x;
    x := NextHi[N1]; NextHi[N1] := NextHi[N2]; NextHi[N2] := x;
    x := NextDepth[N1]; NextDepth[N1] := NextDepth[N2]; NextDepth[N2] := x;
  end;

begin
  sp := 0;
  Stack[0] := Lo; Stack[1] := Hi; Stack[2] := -4; sp := 3;
  while sp <> 0 do
  begin
    Dec(sp, 3); Lo := Stack[sp]; Hi := Stack[sp+1]; Dep := Stack[sp+2];
    if Hi <= Lo then Continue;
    if (Hi - Lo < BWT_MinQSort) or (Dep <= -FastBWT_MaxQSortDepth) then
    begin
      FastShellSort(Index, Input, Lo, Hi, Dep, Size, AML);
      if AML^ < 0 then Exit;
      Continue;
    end;
    if Hi - Lo < BWT_MedTrh then
      Med := Med3(PLongWord(Input + Index[(Lo+Hi) shr 1] + Dep)^,
                  PLongWord(Input + Index[Lo] + Dep)^,
                  PLongWord(Input + Index[Hi] + Dep)^)
    else
    begin
      M := (Hi + Lo) shr 1;
      N := (Hi - Lo) shr 3;
      Med1 := Med3(PLongWord(Input + Index[Lo] + Dep)^, PLongWord(Input + Index[Lo+N] + Dep)^,
                   PLongWord(Input + Index[Lo+N+N] + Dep)^);
      Med2 := Med3(PLongWord(Input + Index[M-N] + Dep)^, PLongWord(Input + Index[M] + Dep)^,
                   PLongWord(Input + Index[M+N] + Dep)^);
      Med3v := Med3(PLongWord(Input + Index[Hi-N-N] + Dep)^, PLongWord(Input + Index[Hi-N] + Dep)^,
                    PLongWord(Input + Index[Hi] + Dep)^);
      Med := Med3(Med1, Med2, Med3v);
    end;
    A := Lo; B := Lo; C := Hi; D := Hi;
    while True do
    begin
      while B <= C do
      begin
        v := PLongWord(Input + Index[B] + Dep)^;
        if v = Med then
        begin
          t := Index[A]; Index[A] := Index[B]; Index[B] := t;
          Inc(A); Inc(B);
          Continue;
        end;
        if v > Med then Break;
        Inc(B);
      end;
      while B <= C do
      begin
        v := PLongWord(Input + Index[C] + Dep)^;
        if v = Med then
        begin
          t := Index[C]; Index[C] := Index[D]; Index[D] := t;
          Dec(D); Dec(C);
          Continue;
        end;
        if v < Med then Break;
        Dec(C);
      end;
      if B > C then Break;
      t := Index[B]; Index[B] := Index[C]; Index[C] := t;
      Inc(B); Dec(C);
    end;
    if D < A then
    begin
      Stack[sp] := Lo; Stack[sp+1] := Hi; Stack[sp+2] := Dep - 4; Inc(sp, 3);
      Continue;
    end;
    N := Min(A - Lo, B - A); VSwap(Index, Lo, B - N, N);
    M := Min(Hi - D, D - C); VSwap(Index, B, Hi - M + 1, M);
    N := Lo + B - A - 1;
    M := Hi - (D - C) + 1;
    NextLo[0] := Lo;    NextHi[0] := N;     NextDepth[0] := Dep;
    NextLo[1] := M;     NextHi[1] := Hi;    NextDepth[1] := Dep;
    NextLo[2] := N + 1; NextHi[2] := M - 1; NextDepth[2] := Dep - 4;
    if NextHi[0] - NextLo[0] < NextHi[2] - NextLo[2] then NSwap(0, 2);
    if NextHi[0] - NextLo[0] < NextHi[1] - NextLo[1] then NSwap(0, 1);
    if NextHi[1] - NextLo[1] < NextHi[2] - NextLo[2] then NSwap(1, 2);
    for t := 0 to 2 do
    begin
      Stack[sp] := NextLo[t]; Stack[sp+1] := NextHi[t]; Stack[sp+2] := NextDepth[t]; Inc(sp, 3);
    end;
  end;
end;

type
  { Estado de la mezcla de los 8 grupos (GRZip_FastBWT_Encode: TreeReBuild / TreeUpdateFast). }
  TFastMerge = record
    Lo, Hi: array[0..NG-1] of LongInt;       // SmallBucketLo / SmallBucketHi
    PtrHash: array[0..NG-1] of PLongWord;
    Winner: array[0..NG-2] of Byte;
    Input: PByte;
    Size: SizeInt;
    AML: LongInt;
  end;

// FastBWT_Match
procedure FMatch(var F: TFastMerge; G0, G1, Win: Integer);
begin
  if F.Lo[G0] >= F.Hi[G0] then F.Winner[Win] := G1
  else if F.Lo[G1] >= F.Hi[G1] then F.Winner[Win] := G0
  else if FastCmp(F.PtrHash[G1], F.PtrHash[G0], F.Size, PLongWord(F.Input), @F.AML) then F.Winner[Win] := G0
  else F.Winner[Win] := G1;
end;

// FastBWT_MatchFast
procedure FMatchFast(var F: TFastMerge; G0, G1, Win: Integer);
begin
  if FastCmp(F.PtrHash[G1], F.PtrHash[G0], F.Size, PLongWord(F.Input), @F.AML) then F.Winner[Win] := G0
  else F.Winner[Win] := G1;
end;

procedure TreeReBuild(var F: TFastMerge);
begin
  FMatch(F, 0, 1, 0); FMatch(F, 2, 3, 1);
  FMatch(F, F.Winner[0], F.Winner[1], 4);
  FMatch(F, 4, 5, 2); FMatch(F, 6, 7, 3);
  FMatch(F, F.Winner[2], F.Winner[3], 5);
  FMatch(F, F.Winner[4], F.Winner[5], 6);
end;

procedure TreeUpdateFast(var F: TFastMerge; PredWinner: Integer);
begin
  case PredWinner of
    0, 1:
      begin
        FMatchFast(F, 0, 1, 0);
        FMatchFast(F, F.Winner[0], F.Winner[1], 4);
      end;
    2, 3:
      begin
        FMatchFast(F, 2, 3, 1);
        FMatchFast(F, F.Winner[0], F.Winner[1], 4);
      end;
    4, 5:
      begin
        FMatchFast(F, 4, 5, 2);
        FMatchFast(F, F.Winner[2], F.Winner[3], 5);
      end;
  else
    begin
      FMatchFast(F, 6, 7, 3);
      FMatchFast(F, F.Winner[2], F.Winner[3], 5);
    end;
  end;
  FMatchFast(F, F.Winner[4], F.Winner[5], 6);
end;

{ GRZip_FastBWT_Encode. Input apunta a FastBWT_NumOverShoot bytes después del principio del
  buffer preparado por FastBwtInit (lee Input[-80..Size+3]). Size múltiplo de 8.
  Index[Size] el C lo lee sin inicializar (BWT.c:910/925/941, un grupo que se acaba): acá es 0,
  como en la memoria recién pedida al sistema (mmap / VirtualAlloc). }
function FastBwtCore(Input: PByte; Size: LongInt; Output: PByte; BigBucket, Index: PLongInt): LongInt;
var
  GroupsFreq: array[0..NG-1, 0..255] of LongInt;
  BucketStart: array[0..255] of LongInt;
  F: TFastMerge;
  GroupSize, i, j, Cum, Lo, Hi, Min, tmp: LongInt;
  GNum, PB, c: Byte;
  Indx, Ptr: LongWord;
begin
  GroupSize := Size div NG;
  F.Input := Input;
  F.Size := Size;
  // (sint32)(((float)Size)*0.35): float por double -> double
  F.AML := Trunc(Double(Single(Size)) * 0.35);
  FillChar(GroupsFreq, SizeOf(GroupsFreq), 0);

  i := Size - 1;
  while i > 0 do
  begin
    for j := 0 to NG - 1 do Inc(GroupsFreq[j, Input[i-j]]);
    Inc(BigBucket[(LongInt(Input[i-NG+1]) shl 8) or Input[i-NG]]);
    Dec(i, NG);
  end;

  Cum := 0;
  for i := 0 to NG - 1 do
  begin
    F.Lo[i] := Cum;
    Inc(Cum, GroupSize);
    F.Hi[i] := Cum;
  end;

  Cum := F.Lo[NG-1];
  for i := 0 to 65535 do
  begin
    Inc(Cum, BigBucket[i]);
    BigBucket[i] := Cum - BigBucket[i];
  end;

  i := 0;
  while i < Size do
  begin
    tmp := (LongInt(Input[i]) shl 8) or Input[i-1];
    Index[BigBucket[tmp]] := i;
    Inc(BigBucket[tmp]);
    Inc(i, NG);
  end;

  Lo := F.Lo[NG-1];
  for i := 0 to 65535 do
  begin
    Hi := BigBucket[i] - 1;
    if Lo < Hi then
      if Hi - Lo > BWT_MinQSort then
        FastTernarySort(Index, Input, Lo, Hi, Size, @F.AML)
      else
        FastShellSortD2(Index, Input, Lo, Hi, Size, @F.AML);
    if F.AML < 0 then Exit(GRZ_FAST_BWT_FAILS);
    Lo := Hi + 1;
  end;

  for i := NG - 2 downto 0 do
  begin
    Cum := F.Lo[i];
    for j := 0 to 255 do
    begin
      BucketStart[j] := Cum;
      Inc(Cum, GroupsFreq[i, j]);
    end;
    for Lo := F.Lo[i+1] to F.Hi[i+1] - 1 do
    begin
      tmp := Index[Lo];
      c := Input[tmp+1];
      Index[Lo] := LongInt(LongWord(tmp) or (LongWord(c) shl 24));
      Index[BucketStart[c]] := tmp + 1;
      Inc(BucketStart[c]);
    end;
  end;

  for Lo := F.Lo[0] to F.Hi[0] - 1 do
  begin
    tmp := Index[Lo];
    Index[Lo] := LongInt(LongWord(tmp) or (LongWord(Input[tmp+1]) shl 24));
  end;

  Cum := 0;
  for i := 0 to 255 do
  begin
    BucketStart[i] := Cum;
    for j := 0 to NG - 1 do Inc(Cum, GroupsFreq[j, i]);
  end;

  FillChar(Output^, Size, $FF);

  for i := 0 to NG - 1 do
    F.PtrHash[i] := PLongWord(Input + (LongWord(Index[F.Lo[i]]) and $FFFFFF) - 3);

  F.AML := Trunc(Double(Single(Size)) * 1.15);

  // Cum queda con el total de arriba, como en el C, si no aparece Size-1 (siempre aparece)
  i := 0;
  while True do
  begin
    Min := F.Hi[0] - F.Lo[0];
    for j := 1 to NG - 1 do
    begin
      tmp := F.Hi[j] - F.Lo[j];
      if tmp < Min then Min := tmp;
    end;
    if Min <= 0 then Break;
    j := i + Min;
    while i < j do
    begin
      TreeReBuild(F);
      if F.AML < 0 then Exit(GRZ_FAST_BWT_FAILS);
      while (i < j) and (Output[i] = $FF) do
      begin
        GNum := F.Winner[NG-2];
        Indx := LongWord(F.Lo[GNum]); Inc(F.Lo[GNum]);
        Ptr := LongWord(Index[Indx]);
        PB := Ptr shr 24;
        Output[i] := PB;
        if (Ptr and $FFFFFF) = LongWord(Size - 1) then Cum := i;
        F.PtrHash[GNum] := PLongWord(Input + (LongWord(Index[Indx+1]) and $FFFFFF) - 3);
        Ptr := LongWord(BucketStart[PB]); Inc(BucketStart[PB]);
        if LongWord(i) < Ptr then Output[Ptr] := (GNum + NG - 1) and (NG - 1);
        TreeUpdateFast(F, GNum);
        if F.AML < 0 then Exit(GRZ_FAST_BWT_FAILS);
        Inc(i);
      end;
      while (i < j) and (Output[i] <> $FF) do
      begin
        GNum := Output[i];
        Indx := LongWord(F.Lo[GNum]); Inc(F.Lo[GNum]);
        Ptr := LongWord(Index[Indx]);
        PB := Ptr shr 24;
        Output[i] := PB;
        if (Ptr and $FFFFFF) = LongWord(Size - 1) then Cum := i;
        F.PtrHash[GNum] := PLongWord(Input + (LongWord(Index[Indx+1]) and $FFFFFF) - 3);
        Ptr := LongWord(BucketStart[PB]); Inc(BucketStart[PB]);
        if LongWord(i) < Ptr then Output[Ptr] := (GNum + NG - 1) and (NG - 1);
        Inc(i);
      end;
    end;
  end;
  while i < Size do
  begin
    TreeReBuild(F);
    if F.AML < 0 then Exit(GRZ_FAST_BWT_FAILS);
    GNum := F.Winner[NG-2];
    Indx := LongWord(F.Lo[GNum]); Inc(F.Lo[GNum]);
    Ptr := LongWord(Index[Indx]);
    Output[i] := Ptr shr 24;
    if (Ptr and $FFFFFF) = LongWord(Size - 1) then Cum := i;
    F.PtrHash[GNum] := PLongWord(Input + (LongWord(Index[Indx+1]) and $FFFFFF) - 3);
    Inc(i);
  end;
  if F.AML < 0 then Result := GRZ_FAST_BWT_FAILS else Result := Cum;
end;

function FastBwtEncode(Input: PByte; Size: LongInt; Output: PByte): LongInt;
var
  BigBucket, Index: PLongInt;
begin
  BigBucket := nil; Index := nil;
  try
    BigBucket := AllocMem(65536 * SizeOf(LongInt));
    Index := AllocMem((SizeInt(Size) + 1) * SizeOf(LongInt));
    Result := FastBwtCore(Input, Size, Output, BigBucket, Index);
  finally
    if Index <> nil then FreeMem(Index);
    if BigBucket <> nil then FreeMem(BigBucket);
  end;
end;

// GRZip_BWT_FastBWT_Init / GRZip_BWT_FastBWT_Done: el bloque invertido con 80 bytes de vuelta
procedure FastBwtReverse(Input: PByte; Size: LongInt);
var
  i, Mid, Last: LongInt;
  C0: Byte;
begin
  Mid := (Size + FastBWT_NumOverShoot) shr 1;
  Last := Size + FastBWT_NumOverShoot - 1;
  for i := 0 to Mid - 1 do
  begin
    C0 := Input[i];
    Input[i] := Input[Last - i];
    Input[Last - i] := C0;
  end;
end;

procedure FastBwtInit(Input: PByte; Size: LongInt);
var
  i: LongInt;
begin
  for i := 0 to FastBWT_NumOverShoot - 1 do Input[Size + i] := Input[i];
  FastBwtReverse(Input, Size);
  for i := 0 to 3 do Input[Size + FastBWT_NumOverShoot + i] := Input[FastBWT_NumOverShoot + i];
end;

{ GRZip_BWT_Encode con Input = Output (el caso de GRZip_CompressBlock). Input tiene lugar para
  Size+84 bytes. Fast: si se pasa del presupuesto AML, strong. }
function BwtEncode(Input: PByte; Size: LongInt; Fast: Boolean): LongInt;
var
  Buf: PByte;
begin
  if Fast then
  begin
    GetMem(Buf, Size);
    try
      FastBwtInit(Input, Size);
      Result := FastBwtEncode(Input + FastBWT_NumOverShoot, Size, Buf);
      if Result <> GRZ_FAST_BWT_FAILS then
      begin
        Move(Buf^, Input^, Size);
        Exit;
      end;
    finally
      FreeMem(Buf);
    end;
    FastBwtReverse(Input, Size);   // FastBWT_Done
  end;
  Result := StrongBwtEncode(Input, Size, Input) or StrongBWT_Flag;
end;

{ ---------- MTF/WFC + aritmético (MTF_Ari.c / WFC_Ari.c) ---------- }

const
  Model_MaxFreq = 2048;
  ModelL0_0MaxFreq = 58;
  ModelL0_1MaxFreq = 62;
  ModelL0_2MaxFreq = 204;
  WFC_Val0 = 131072;
  GrNum2GrBegin: array[0..6] of LongWord = (3, 5, 9, 17, 33, 65, 129);

type
  TEncModels = record
    Model_L0_0: array[0..4] of LongWord;
    Model_L0_1: array[0..255, 0..4] of LongWord;
    Model_L0_2: array[0..4*256-1, 0..4] of LongWord;
    Model_L1_0: array[0..7] of LongWord;
    Model_L1_1: array[0..7, 0..7] of LongWord;
    Model_L2_0: array[0..7, 0..127] of LongWord;
    Model_Log2RLE_0: array[0..63, 0..GRZ_Log2MaxBlockSize] of LongWord;
    Model_Log2RLE_1: array[0..255, 0..GRZ_Log2MaxBlockSize] of LongWord;
    Model_Log2RLE_2: array[0..GRZ_Log2MaxBlockSize, 0..GRZ_Log2MaxBlockSize] of LongWord;
    MTF_List: array[0..255] of LongWord;
    WFC_List, Char2Index, CharWeight: array[0..256] of LongInt;
    WFCBuf: PByte;
  end;
  PEncModels = ^TEncModels;

var
  // WFC_MTF.h: WFCMTF_Rank2GrNum / Rank2GrPos / Rank2Mask (se arman en initialization)
  Rank2GrNum, Rank2GrPos, Rank2Mask: array[0..255] of LongWord;

{ Init_Models (MTF_Ari.c) + WFC_Init (WFC_Ari.c). }
procedure InitEncModels(M: PEncModels);
var
  i, j: Integer;
begin
  with M^ do
  begin
    for i := 0 to 255 do MTF_List[i] := i;
    Model_L0_0[0] := 1; Model_L0_0[1] := 1; Model_L0_0[2] := 1; Model_L0_0[3] := 1;
    Model_L0_0[4] := 4;
    for i := 0 to 7 do Model_L1_0[i] := Model_MaxFreq shr 1;
    FillChar(Model_L0_1, SizeOf(Model_L0_1), 0);
    FillChar(Model_L0_2, SizeOf(Model_L0_2), 0);
    for i := 0 to 7 do for j := 0 to 127 do Model_L2_0[i, j] := Model_MaxFreq shr 1;
    FillChar(Model_L1_1, SizeOf(Model_L1_1), 0);   // la fila 7 el C no la inicializa (no se usa)
    for i := 0 to 6 do for j := 0 to 7 do Model_L1_1[i, j] := Model_MaxFreq shr 1;
    for j := 0 to 63 do for i := 0 to GRZ_Log2MaxBlockSize do Model_Log2RLE_0[j, i] := Model_MaxFreq shr 1;
    for j := 0 to GRZ_Log2MaxBlockSize do for i := 0 to GRZ_Log2MaxBlockSize do Model_Log2RLE_2[j, i] := Model_MaxFreq shr 1;
    for j := 0 to 255 do for i := 0 to GRZ_Log2MaxBlockSize do Model_Log2RLE_1[j, i] := Model_MaxFreq shr 1;
    for i := 0 to 256 do
    begin
      WFC_List[i] := i;
      Char2Index[i] := i;
      CharWeight[i] := 0;
    end;
    CharWeight[256] := -1;
  end;
end;

{ WFC_Ari.c: Update_Weight0(Ch) + Update_Weight_Full(WFC_Val<k>, WFC_Pos<k> = 2^(k-1)) con
  WFCBuf[Pos] = Ch ya guardado. }
// Update_Weight_Full(WVAL, WPOS) de WFC_Ari.c (WPOS/WVAL se redefinen en cada uso)
{$define WFC_UPD :=
  if Pos >= WPOS then
  begin
    c := Buf[Pos - WPOS];
    W := CW[c] - WVAL;
    CW[c] := W;
    if c <> Ch then
    begin
      j := C2I[c];
      List := @WL[j + 1];
      while CW[List^] > W do
      begin
        List[-1] := List^;
        C2I[List^] := j;
        Inc(j);
        Inc(List);
      end;
      WL[j] := c;
      C2I[c] := j;
    end;
  end}

procedure WfcUpdate(M: PEncModels; Ch: LongInt; Pos: SizeInt);
var
  c, j, W: LongInt;
  List, WL, C2I, CW: PLongInt;
  Buf: PByte;
begin
  WL := @M^.WFC_List[0]; C2I := @M^.Char2Index[0]; CW := @M^.CharWeight[0]; Buf := M^.WFCBuf;
  // Update_Weight0
  Inc(CW[Ch], WFC_Val0);
  j := C2I[Ch];
  while j > 0 do
  begin
    c := WL[j-1];
    WL[j] := c;
    C2I[c] := j;
    Dec(j);
  end;
  WL[0] := Ch;
  C2I[Ch] := 0;
  {$define WPOS := 1}{$define WVAL := 114688} WFC_UPD;
  {$define WPOS := 2}{$define WVAL := 7272} WFC_UPD;
  {$define WPOS := 4}{$define WVAL := 4240} WFC_UPD;
  {$define WPOS := 8}{$define WVAL := 2364} WFC_UPD;
  {$define WPOS := 16}{$define WVAL := 1263} WFC_UPD;
  {$define WPOS := 32}{$define WVAL := 649} WFC_UPD;
  {$define WPOS := 64}{$define WVAL := 320} WFC_UPD;
  {$define WPOS := 128}{$define WVAL := 153} WFC_UPD;
  {$define WPOS := 256}{$define WVAL := 70} WFC_UPD;
  {$define WPOS := 512}{$define WVAL := 31} WFC_UPD;
  {$define WPOS := 1024}{$define WVAL := 14} WFC_UPD;
  {$define WPOS := 2048}{$define WVAL := 8} WFC_UPD;
end;

{ Codificador de rango del C (ARI_ShiftLow / ARI_Encode), como macros sobre variables locales.
  Low es sint64; "(uint32)(Low)<<8" es un desplazamiento de 32 bits. HardEnd: tope real del
  buffer (el C solo mira OutputEnd una vez por símbolo; ver AriEncCore). }
{$define ARI_SHIFTLOW :=
  begin
    if (Low xor $FF000000) > $FFFFFF then
    begin
      Output[op] := Byte(Cache + LongWord(Low shr 32)); Inc(op);
      if FFNum <> 0 then
      begin
        FFb := Byte($FF + LongWord(Low shr 32));
        repeat
          Output[op] := FFb; Inc(op); Dec(FFNum);
        until FFNum = 0;
      end;
      Cache := LongWord(Low) shr 24;
    end
    else
      Inc(FFNum);
    Low := LongWord(LongWord(Low) shl 8);
  end}
{$define ARI_ENCODE :=
  begin
    Range := Range div ATot;
    Low := Low + LongWord(ACum * Range);
    Range := LongWord(Range * AFr);
    while Range < (1 shl 24) do
    begin
      ARI_SHIFTLOW;
      Range := LongWord(Range shl 8);
    end;
  end}
// ARI_Encode_0 / ARI_Encode_1 con probabilidad AFr0/2048 de 0 (Range/2048: el C lo compila
// como desplazamiento; con ATot variable FPC haría una división)
{$define ARI_ENCBIN :=
  begin
    Range := Range shr 11;
    Low := Low + LongWord(ACum * Range);
    Range := LongWord(Range * AFr);
    while Range < (1 shl 24) do
    begin
      ARI_SHIFTLOW;
      Range := LongWord(Range shl 8);
    end;
  end}
{$define ARI_ENC0 := begin AFr := AFr0; ACum := 0; ARI_ENCBIN; end}
{$define ARI_ENC1 := begin AFr := Model_MaxFreq - AFr0; ACum := AFr0; ARI_ENCBIN; end}
// Update_Model_L0
{$define UPDATE_L0 :=
  begin
    if Model_L0_0[4] > ModelL0_0MaxFreq then
    begin
      Model_L0_0[0] := (Model_L0_0[0] + 1) shr 1;
      Model_L0_0[1] := (Model_L0_0[1] + 1) shr 1;
      Model_L0_0[2] := (Model_L0_0[2] + 1) shr 1;
      Model_L0_0[3] := (Model_L0_0[3] + 1) shr 1;
      Model_L0_0[4] := Model_L0_0[0] + Model_L0_0[1] + Model_L0_0[2] + Model_L0_0[3];
    end;
    if VCtx[4] > ModelL0_1MaxFreq then
    begin
      VCtx[0] := VCtx[0] shr 1; VCtx[1] := VCtx[1] shr 1;
      VCtx[2] := VCtx[2] shr 1; VCtx[3] := VCtx[3] shr 1;
      VCtx[4] := VCtx[0] + VCtx[1] + VCtx[2] + VCtx[3];
    end;
    if UCtx[4] > ModelL0_2MaxFreq then
    begin
      UCtx[0] := UCtx[0] shr 1; UCtx[1] := UCtx[1] shr 1;
      UCtx[2] := UCtx[2] shr 1; UCtx[3] := UCtx[3] shr 1;
      UCtx[4] := UCtx[0] + UCtx[1] + UCtx[2] + UCtx[3];
    end;
  end}

{ GRZip_MTF_Ari_Encode / GRZip_WFC_Ari_Encode: el mismo modelo, solo cambia cómo el byte se
  traduce a un rango. Devuelve el largo o GRZ_NOT_COMPRESSIBLE (salida >= Size-24 antes de un
  símbolo, como el C; o, acá, si los bytes pendientes no entrarían en OutCap). }
function AriEncCore(M: PEncModels; Input: PByte; Size: SizeInt; Output: PByte; OutCap: SizeInt; WFC: Boolean): LongInt;
var
  Low: Int64;
  Range, FFNum, Cache, AFr, ACum, ATot, AFr0: LongWord;
  FFb: Byte;
  ip, op, OutEnd, HardEnd, WFCBufPos: SizeInt;
  VCtx, UCtx: PLongWord;
  CtxRLE, CtxL0, CtxL1, CtxL2, i, GrNum, GrPos, MaskG, Tmp: LongInt;
  Mask, Log2RunSize, RunSize, Rank, PredChar, Ch, Cum: LongWord;
begin
  OutEnd := Size - 24;
  HardEnd := OutCap - 256;
  Low := 0; FFNum := 0; Cache := 0; Range := $FFFFFFFF;
  CtxRLE := 0; CtxL0 := 0; CtxL1 := 0;
  WFCBufPos := 0;
  Ch := 0; Mask := 0;
  ip := 0; op := 0;
  with M^ do
  begin
    while ip < Size do
    begin
      if (op >= OutEnd) or (op + SizeInt(FFNum) >= HardEnd) then Exit(GRZ_NOT_COMPRESSIBLE);
      PredChar := Ch; Ch := Input[ip]; Inc(ip);
      RunSize := 1;
      while (ip < Size) and (Input[ip] = Ch) do
      begin
        Inc(RunSize); Inc(ip);
      end;

      if not WFC then
      begin
        Rank := 0;
        while MTF_List[Rank] <> Ch do Inc(Rank);
        if Rank <> 0 then
        begin
          Move(MTF_List[0], MTF_List[1], Rank * SizeOf(LongWord));
          MTF_List[0] := Ch;
        end;
      end
      else
      begin
        WFCBuf[WFCBufPos] := Ch;
        Rank := LongWord(Char2Index[Ch]);
        WfcUpdate(M, Ch, WFCBufPos);
        Inc(WFCBufPos);
      end;
      Rank := (Rank - 1) and $FF;

      VCtx := @Model_L0_1[PredChar, 0];
      UCtx := @Model_L0_2[4*CtxL0 + (CtxRLE and 3), 0];
      if Rank < 3 then
      begin
        Cum := 0;
        for i := 0 to LongInt(Rank) - 1 do Inc(Cum, UCtx[i] + VCtx[i] + Model_L0_0[i]);
        AFr := Model_L0_0[Rank] + UCtx[Rank] + VCtx[Rank];
        ACum := Cum;
        ATot := Model_L0_0[4] + UCtx[4] + VCtx[4];
        ARI_ENCODE;
        Inc(Model_L0_0[Rank], 2); Inc(UCtx[Rank], 2); Inc(VCtx[Rank], 2);
        Inc(Model_L0_0[4], 2); Inc(UCtx[4], 2); Inc(VCtx[4], 2);
        UPDATE_L0;
      end
      else
      begin
        AFr := Model_L0_0[3] + UCtx[3] + VCtx[3];
        ATot := Model_L0_0[4] + UCtx[4] + VCtx[4];
        ACum := ATot - AFr;
        ARI_ENCODE;
        Inc(Model_L0_0[3], 2); Inc(UCtx[3], 2); Inc(VCtx[3], 2);
        Inc(Model_L0_0[4], 2); Inc(UCtx[4], 2); Inc(VCtx[4], 2);
        UPDATE_L0;

        GrNum := Rank2GrNum[Rank];
        GrPos := Rank2GrPos[Rank];
        MaskG := Rank2Mask[Rank];
        VCtx := @Model_L1_0[0];
        UCtx := @Model_L1_1[CtxL1, 0];
        CtxL1 := GrNum;
        for i := 0 to GrNum - 1 do
        begin
          AFr0 := (VCtx[0] + UCtx[0]) shr 1;
          ARI_ENC1;
          Dec(VCtx[0], VCtx[0] shr 4);
          Dec(UCtx[0], UCtx[0] shr 6);
          Inc(VCtx); Inc(UCtx);
        end;
        if GrNum <> 6 then
        begin
          AFr0 := (VCtx[0] + UCtx[0]) shr 1;
          ARI_ENC0;
          Inc(VCtx[0], (Model_MaxFreq - VCtx[0]) shr 4);
          Inc(UCtx[0], (Model_MaxFreq - UCtx[0]) shr 6);
        end;
        VCtx := @Model_L2_0[GrNum, 0];
        CtxL2 := 1;
        for i := 0 to GrNum do
        begin
          AFr0 := VCtx[CtxL2];
          if (GrPos and MaskG) <> 0 then
          begin
            ARI_ENC1;
            Dec(VCtx[CtxL2], VCtx[CtxL2] shr 7);
            CtxL2 := (CtxL2 shl 1) or 1;
          end
          else
          begin
            ARI_ENC0;
            Inc(VCtx[CtxL2], (Model_MaxFreq - VCtx[CtxL2]) shr 7);
            CtxL2 := CtxL2 shl 1;
          end;
          MaskG := MaskG shr 1;
        end;
      end;

      if Rank > 3 then Rank := 3;
      CtxL0 := ((CtxL0 shl 2) or LongInt(Rank)) and $FF;

      Tmp := RunSize;
      if Tmp = 1 then Log2RunSize := 0
      else
      begin
        Log2RunSize := 1; Mask := 1;
        while True do
        begin
          Tmp := Tmp shr 1;
          if Tmp = 1 then Break;
          Inc(Log2RunSize); Mask := Mask shl 1;
        end;
      end;

      VCtx := @Model_Log2RLE_0[CtxRLE + 16*LongInt(Rank), 0];
      UCtx := @Model_Log2RLE_1[Ch, 0];
      for i := 1 to LongInt(Log2RunSize) do
      begin
        AFr0 := (VCtx[0] + UCtx[0]) shr 1;
        ARI_ENC1;
        Dec(VCtx[0], VCtx[0] shr 6);
        Dec(UCtx[0], UCtx[0] shr 3);
        Inc(VCtx); Inc(UCtx);
      end;
      AFr0 := (VCtx[0] + UCtx[0]) shr 1;
      ARI_ENC0;
      Inc(VCtx[0], (Model_MaxFreq - VCtx[0]) shr 6);
      Inc(UCtx[0], (Model_MaxFreq - UCtx[0]) shr 3);

      if Log2RunSize < 2 then CtxRLE := (CtxRLE shl 1) and $F
      else CtxRLE := ((CtxRLE shl 1) or 1) and $F;

      VCtx := @Model_Log2RLE_2[Log2RunSize, 0];
      for i := 1 to LongInt(Log2RunSize) do
      begin
        AFr0 := VCtx[0];
        if (RunSize and Mask) <> 0 then
        begin
          ARI_ENC1;
          Dec(VCtx[0], VCtx[0] shr 6);
        end
        else
        begin
          ARI_ENC0;
          Inc(VCtx[0], (Model_MaxFreq - VCtx[0]) shr 6);
        end;
        Mask := Mask shr 1;
        Inc(VCtx);
      end;
    end;

    // Fin de bloque: rango 3, grupo 6 y posición 127
    VCtx := @Model_L0_1[Ch, 0];
    UCtx := @Model_L0_2[4*CtxL0 + (CtxRLE and 3), 0];
    AFr := Model_L0_0[3] + UCtx[3] + VCtx[3];
    ATot := Model_L0_0[4] + UCtx[4] + VCtx[4];
    ACum := ATot - AFr;
    ARI_ENCODE;
    Inc(Model_L0_0[3], 2); Inc(UCtx[3], 2); Inc(VCtx[3], 2);
    Inc(Model_L0_0[4], 2); Inc(UCtx[4], 2); Inc(VCtx[4], 2);
    UPDATE_L0;
    VCtx := @Model_L1_0[0];
    UCtx := @Model_L1_1[CtxL1, 0];
    for i := 0 to 5 do
    begin
      AFr0 := (VCtx[0] + UCtx[0]) shr 1;
      ARI_ENC1;
      Dec(VCtx[0], VCtx[0] shr 4);
      Dec(UCtx[0], UCtx[0] shr 6);
      Inc(VCtx); Inc(UCtx);
    end;
    VCtx := @Model_L2_0[6, 0];
    CtxL2 := 1;
    for i := 0 to 6 do
    begin
      AFr0 := VCtx[CtxL2];
      ARI_ENC1;
      Dec(VCtx[CtxL2], VCtx[CtxL2] shr 7);
      CtxL2 := (CtxL2 shl 1) or 1;
    end;
  end;
  if op + SizeInt(FFNum) + 8 >= OutCap then Exit(GRZ_NOT_COMPRESSIBLE);
  Range := Range shr 1;
  Low := Low + Range;
  for i := 1 to 5 do ARI_SHIFTLOW;
  Result := op;
end;

function AriEncode(Input: PByte; Size: SizeInt; Output: PByte; OutCap: SizeInt; WFC: Boolean): LongInt;
var
  M: PEncModels;
begin
  New(M);
  M^.WFCBuf := nil;
  try
    InitEncModels(M);
    if WFC then GetMem(M^.WFCBuf, Size + 1);
    Result := AriEncCore(M, Input, Size, Output, OutCap, WFC);
  finally
    if M^.WFCBuf <> nil then FreeMem(M^.WFCBuf);
    Dispose(M);
  end;
end;

{ ---------- un bloque (C_GRZip.cpp) ---------- }

// GRZip_StoreBlock (H[0] ya lo escribió GRZip_CompressBlock)
function StoreBlock(Input: PByte; Size: LongInt; Output: PByte; Mode: LongInt): LongInt;
begin
  PutI32(Output + 4, -1);
  PutI32(Output + 8, (Mode div 256) * 256);   // DisableAllButLZP
  PutI32(Output + 12, 0);
  PutI32(Output + 16, Size);
  if Size > 0 then Move(Input^, Output[HDR], Size);
  PutI32(Output + 20, 0);
  PutI32(Output + 24, 0);
  Result := Size + HDR;
end;

function GrzipBlockOutCap(Size: SizeInt): SizeInt;
begin
  Result := Size + OUT_SLACK;
end;

function GrzipCompressBlock(Input: PByte; Size: LongInt; Output: PByte; OutCap: SizeInt; Mode: LongInt): LongInt;
var
  SSize, RecMode, NewSize, Part, R, k, nParts: LongInt;
  Buffer, LZPBuffer: PByte;
begin
  SSize := Size;
  PutI32(Output, Size);
  if (Size < 32) or (Size > GRZ_MaxBlockSize) then Exit(StoreBlock(Input, Size, Output, 0));
  if Size < 1024 then Mode := Mode or GRZ_Compression_ST4;

  if (Size > 1024) and ((Mode and GRZ_Disable_DeltaFlt) = 0) then
  begin
    RecMode := RecTest(Input, Size);
    if RecMode <> 0 then
    begin
      // 2 (RecMode impar) o 4 sub-bloques, comprimidos sin volver a probar el filtro
      GetMem(Buffer, SizeInt(Size) + LZP_MaxMatchLen);
      try
        RecEncode(Input, Size, Buffer, RecMode);
        Mode := Mode + GRZ_Disable_DeltaFlt;
        if (RecMode and 1) = 1 then nParts := 2 else nParts := 4;
        Part := Size div nParts;   // Size>>1 / Size>>2
        NewSize := 0;
        for k := 0 to nParts - 1 do
        begin
          if k = nParts - 1 then
            R := GrzipCompressBlock(Buffer + k*Part, Size - k*Part, Output + HDR + NewSize, OutCap - HDR - NewSize, Mode)
          else
            R := GrzipCompressBlock(Buffer + k*Part, Part, Output + HDR + NewSize, OutCap - HDR - NewSize, Mode);
          Inc(NewSize, R);
        end;
      finally
        FreeMem(Buffer);
      end;
      if NewSize >= Size then Exit(StoreBlock(Input, Size, Output, 0));
      PutI32(Output + 4, -2);
      PutI32(Output + 8, RecMode);
      PutI32(Output + 12, 0);   // el C no lo escribe (C_GRZip.cpp:125): basura del buffer reciclado
      PutI32(Output + 16, NewSize);
      PutI32(Output + 20, 0);
      PutI32(Output + 24, 0);
      Exit(NewSize + HDR);
    end;
  end;

  GetMem(LZPBuffer, SizeInt(Size) + LZP_MaxMatchLen);
  try
    if (Mode div 256) <> 0 then   // LZP_Enabled
    begin
      R := LzpEncode(Input, Size, LZPBuffer, Mode);
      if R = GRZ_NOT_COMPRESSIBLE then
      begin
        Mode := Mode mod 256;   // Disable_LZP
        Move(Input^, LZPBuffer^, Size);
        PutI32(Output + 8, Size);
      end
      else
      begin
        PutI32(Output + 8, R);
        Size := R;
      end;
    end
    else
    begin
      Move(Input^, LZPBuffer^, Size);
      PutI32(Output + 8, Size);
    end;
    FillChar(LZPBuffer[Size], 8, 0);
    Size := (Size + 7) and not 7;

    if (Mode and GRZ_Compression_ST4) <> 0 then R := St4Encode(LZPBuffer, Size)
    else R := BwtEncode(LZPBuffer, Size, (Mode and GRZ_BWTSorting_Fast) <> 0);
    PutI32(Output + 12, R);

    R := AriEncode(LZPBuffer, Size, Output + HDR, OutCap - HDR, (Mode and GRZ_Compression_MTF) = 0);
    if R = GRZ_NOT_COMPRESSIBLE then
    begin
      if (Mode div 256) <> 0 then
      begin
        R := LzpEncode(Input, SSize, LZPBuffer, Mode);
        Exit(StoreBlock(LZPBuffer, R, Output, Mode));
      end;
      Exit(StoreBlock(Input, SSize, Output, 0));
    end;
    PutI32(Output + 4, Mode);
    PutI32(Output + 16, R);
    PutI32(Output + 20, 0);
    PutI32(Output + 24, 0);
    Result := R + HDR;
  finally
    FreeMem(LZPBuffer);
  end;
end;

function GrzipAdaptiveBlockSize(Input: PByte; Size: LongInt): LongInt;
const
  ABS_MinBlockSize = 24*1024;
var
  TotFreq, Freq: array[0..255] of LongInt;
  i, Pos, BlockSize, Sum, Fr: LongInt;
  AvgSize, RealSize: Double;
begin
  if Size <= ABS_MinBlockSize then Exit(Size);
  FillChar(TotFreq, SizeOf(TotFreq), 0);
  for i := 0 to ABS_MinBlockSize - 1 do Inc(TotFreq[Input[i]]);
  Pos := ABS_MinBlockSize;
  BlockSize := ABS_MinBlockSize div 2;
  while Pos + BlockSize < Size do
  begin
    FillChar(Freq, SizeOf(Freq), 0);
    Sum := BlockSize + (Pos shr 1);
    for i := Pos to Pos + BlockSize - 1 do Inc(Freq[Input[i]]);
    AvgSize := 0; RealSize := 0;
    for i := 0 to 255 do
      if Freq[i] <> 0 then
      begin
        Fr := Freq[i];
        RealSize := RealSize - Fr * log10(Double(Fr) / BlockSize);
        AvgSize := AvgSize - Fr * log10(Double(Fr + (TotFreq[i] shr 1)) / Sum);
      end;
    if AvgSize > 1.25 * RealSize then
    begin
      if BlockSize < 256 then Exit(Pos);
      BlockSize := BlockSize shr 1;
      Continue;
    end;
    for i := 0 to 255 do Inc(TotFreq[i], Freq[i]);
    Inc(Pos, BlockSize);
  end;
  Result := Size;
end;

{ ---------- parámetros ---------- }

{ parseInt / parseMem64 de Compression/Common.cpp (parseMem sin sufijo = potencia de 2). }
function CParseInt(const S: string; out V: QWord): Boolean;
var
  i: Integer;
begin
  V := 0;
  i := 1;
  if (i <= Length(S)) and (S[i] = '=') then Inc(i);
  if i > Length(S) then Exit(False);
  while (i <= Length(S)) and (S[i] in ['0'..'9']) do
  begin
    V := V * 10 + QWord(Ord(S[i]) - Ord('0'));
    Inc(i);
  end;
  Result := i > Length(S);
end;

function CParseMem(const S: string; out V: QWord): Boolean;
var
  i: Integer;
  n: QWord;
  c: Char;
begin
  V := 0;
  i := 1;
  if (i <= Length(S)) and (S[i] = '=') then Inc(i);
  if (i > Length(S)) or not (S[i] in ['0'..'9']) then Exit(False);
  n := 0;
  while (i <= Length(S)) and (S[i] in ['0'..'9']) do
  begin
    n := n * 10 + QWord(Ord(S[i]) - Ord('0'));
    Inc(i);
  end;
  if i > Length(S) then c := '^' else c := S[i];
  Result := True;
  case c of
    'b': V := n;
    'k': V := n shl 10;
    'm': V := n shl 20;
    'g': V := n shl 30;
    '^': if n < 64 then V := QWord(1) shl n else V := 0;
  else
    Result := False;
  end;
end;

procedure ParseGrzipEncParams(const Params: TStringArray; out Mode: LongInt; out BlockSize: SizeInt;
  out Adaptive: Boolean);
var
  k: Integer;
  p: string;
  v, Bs: QWord;
  Method, EnableLZP, MinMatchLen, HashSizeLog, Alt, Delta: LongInt;
  s: LongInt;

  procedure Bad;
  begin
    raise EGrzipEncParams.CreateFmt('grzip: invalid parameter "%s"', [p]);
  end;

begin
  if (Length(Params) = 0) or (Params[0] <> 'grzip') then
    raise EGrzipEncParams.Create('grzip: not the method grzip');
  // GRZIP_METHOD::GRZIP_METHOD
  Method := 1; Bs := 8 shl 20; EnableLZP := 1; MinMatchLen := 32; HashSizeLog := 15;
  Alt := 0; Adaptive := False; Delta := 0;
  for k := 1 to High(Params) do
  begin
    p := Params[k];
    if Length(p) = 1 then
    begin
      case p[1] of
        's': begin Alt := 1; Continue; end;
        'a': begin Adaptive := True; Continue; end;
        'l': begin EnableLZP := 0; Continue; end;
        'd': begin Delta := 1; Continue; end;
        'p': begin Adaptive := False; EnableLZP := 0; Delta := 1; Continue; end;
      end;
    end
    else if p <> '' then
      case p[1] of
        'm', 'l', 'h', 't', 'i':
          begin
            if not CParseInt(Copy(p, 2, MaxInt), v) then Bad;
            case p[1] of   // parseInt devuelve MemSize y se guarda en int
              'm': Method := LongInt(v);
              'l': MinMatchLen := LongInt(v);
              'h': HashSizeLog := LongInt(v);
            end;
            Continue;
          end;
        'b':
          begin
            if not CParseMem(Copy(p, 2, MaxInt), Bs) then Bad;
            Continue;
          end;
      end;
    // Sin nombre: entero = MinMatchLen, si no, BlockSize
    if CParseInt(p, v) then
      MinMatchLen := LongInt(v)
    else if CParseMem(p, v) then
      Bs := v
    else
      Bad;
  end;
  // GRZipMTCompressor::GRZipMTCompressor
  case Method of
    1: Mode := 0;
    2: Mode := GRZ_Compression_MTF;
    3: Mode := GRZ_Compression_ST4;
    4: Mode := GRZ_Compression_ST4 + GRZ_Compression_MTF;
  else
    raise EGrzipEncParams.CreateFmt('grzip: invalid m%d method', [Method]);
  end;
  if EnableLZP <> 0 then
    Mode := LongInt(LongWord(Mode) + LongWord(HashSizeLog) * 256 + LongWord(MinMatchLen) * 65536);
  if Alt = 0 then Mode := Mode + GRZ_BWTSorting_Fast;
  if Delta = 0 then Mode := Mode + GRZ_Disable_DeltaFlt;
  if (Mode div 256) <> 0 then
  begin
    // validación: el C con esto no funciona (l>=32768 hace negativo el Mode; h>28 no se puede reservar)
    s := ((Mode div 256) mod 256) and 31;
    if (Mode < 0) or (s > MaxHashLog) then
      raise EGrzipEncParams.Create('grzip: LZP parameters out of range (l<32768, h<=28)');
  end;
  if Bs > GRZ_MaxBlockSize then Bs := GRZ_MaxBlockSize;
  if Bs = 0 then raise EGrzipEncParams.Create('grzip: block size 0');   // el C no avanzaría
  BlockSize := Bs;
end;

{ ---------- stream (GRZipMTCompressor) ---------- }

type
  TGrzipEncJob = class(TParallelJob)
  public
    InBuf: TBytes;
    Mode: LongInt;
    procedure Process; override;
  end;

// GRZipMTCompressor::Process
procedure TGrzipEncJob.Process;
begin
  SetLength(OutBuf, GrzipBlockOutCap(Length(InBuf)));
  OutSize := GrzipCompressBlock(PByte(InBuf), Length(InBuf), PByte(OutBuf), Length(OutBuf), Mode);
  InBuf := nil;
end;

constructor TGrzipEncStage.Create(ATarget: TOutStage; const Params: TStringArray);
var
  Mode: LongInt;
  Bs: SizeInt;
  Adapt: Boolean;
  Threads: Integer;
begin
  ParseGrzipEncParams(Params, Mode, Bs, Adapt);   // antes de adoptar ATarget
  inherited Create(ATarget);
  FMode := Mode;
  FBlockSize := Bs;
  FAdaptive := Adapt;
  // ~11 veces el bloque por hilo (BWT strong): tope de 8 hilos
  Threads := ThreadCount(8);
  SetLength(FQueue, Threads + 1);
  FPool := TJobPool.Create(Threads, Threads + 1);
end;

destructor TGrzipEncStage.Destroy;
var
  i: Integer;
begin
  FPool.Free;
  for i := 0 to FCount - 1 do FQueue[(FHead + i) mod Length(FQueue)].Free;
  inherited Destroy;
end;

procedure TGrzipEncStage.WriteOldest;
var
  Job: TParallelJob;
begin
  Job := FQueue[FHead];
  FHead := (FHead + 1) mod Length(FQueue);
  Dec(FCount);
  try
    FPool.WaitJob(Job);
    Emit(PByte(Job.OutBuf), Job.OutSize);
  finally
    Job.Free;
  end;
end;

procedure TGrzipEncStage.SubmitBlock(Size: SizeInt);
var
  Job: TGrzipEncJob;
begin
  if FCount = Length(FQueue) then WriteOldest;
  Job := TGrzipEncJob.Create;
  Job.Mode := FMode;
  Job.InBuf := Copy(FCur, 0, Size);
  FQueue[(FHead + FCount) mod Length(FQueue)] := Job;
  Inc(FCount);
  FPool.Submit(Job);
end;

{ GRZipMTCompressor::ReaderThread: un bloque sale cuando hay BlockSize bytes (o al final); con
  'a' solo los primeros GRZip_GetAdaptiveBlockSize bytes, y el resto queda para el próximo. }
procedure TGrzipEncStage.CutBlocks(Final: Boolean);
var
  n: SizeInt;
begin
  while (FLen > 0) and (Final or (FLen = FBlockSize)) do
  begin
    if FAdaptive then n := GrzipAdaptiveBlockSize(PByte(FCur), FLen) else n := FLen;
    SubmitBlock(n);
    if n < FLen then Move(FCur[n], FCur[0], FLen - n);
    Dec(FLen, n);
  end;
end;

procedure TGrzipEncStage.DoWrite(Buf: PByte; Count: SizeInt);
var
  n: SizeInt;
begin
  if Length(FCur) = 0 then SetLength(FCur, FBlockSize);
  while Count > 0 do
  begin
    n := FBlockSize - FLen;
    if n > Count then n := Count;
    Move(Buf^, FCur[FLen], n);
    Inc(FLen, n);
    Inc(Buf, n);
    Dec(Count, n);
    CutBlocks(False);
  end;
end;

procedure TGrzipEncStage.DoFinish;
begin
  CutBlocks(True);
  FCur := nil;
  while FCount > 0 do WriteOldest;
end;

procedure InitRankTables;
var
  r, g: LongInt;
begin
  for r := 0 to 255 do
  begin
    Rank2GrNum[r] := 0; Rank2GrPos[r] := 0; Rank2Mask[r] := 0;
    if r >= 3 then
    begin
      g := 6;
      while (g > 0) and (LongWord(r) < GrNum2GrBegin[g]) do Dec(g);
      Rank2GrNum[r] := g;
      Rank2GrPos[r] := LongWord(r) - GrNum2GrBegin[g];
      Rank2Mask[r] := LongWord(1) shl g;
    end;
  end;
end;

initialization
  InitRankTables;
end.
