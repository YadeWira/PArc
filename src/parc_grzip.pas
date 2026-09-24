{ GRZip (método `grzip` de FreeArc, Compression/GRZip/; GRZipII/libGRZip de I. Grebnov).
  Solo decodificación.

  STREAM (GRZipMTDecompressor en C_GRZip.cpp): secuencia de bloques hasta EOF, sin encabezado
  global. Cada bloque = encabezado de 28 bytes (7 x Int32 LE) + H[16] bytes de datos:
    H[0]  tamaño original del bloque (lo que devuelve la descompresión)
    H[4]  Mode: -1 = guardado, -2 = filtro de registros, otro = flags (ver abajo)
    H[8]  guardado: Mode de LZP (0 = copia literal; si no, datos LZP sin BWT)
          -2: RecMode (1..4); normal: tamaño de la salida de LZP (= entrada del BWT/ST4)
    H[12] normal: índice primario del BWT/ST4 (BWT "strong": bit 30 encendido)
    H[16] tamaño de los datos que siguen al encabezado
    H[20], H[24]  reservados, deben ser 0 (única "verificación" del formato)
  Mode (libGRZip.h): bit0 = sin filtro delta (no afecta a la decodificación), bit1 = ST4 (si no,
  BWT), bit2 = MTF (si no, WFC), bit3 = BWT rápido (tampoco afecta: lo dice el bit 30 de H[12]),
  (Mode/256)%256 = log2 de la tabla hash de LZP, Mode/65536%32767 = largo mínimo de LZP;
  Mode/256 = 0: sin LZP.
  Bloque normal: datos = MTF/WFC + aritmético de ((H[8]+7) and not 7) bytes (la salida de LZP
  rellenada con ceros a múltiplo de 8), después BWT/ST4 inverso y LZP inverso -> H[0] bytes.
  Bloque -2 (GRZip_Rec_Encode, datos con estructura de 2/4 bytes): los datos son 2 (RecMode
  impar) o 4 (par) sub-bloques completos con su propio encabezado, que descomprimen a las
  partes Size/2 + resto o Size/4 x3 + resto; después se deshace el filtro (1,2: intercalado de
  bytes; 3,4: delta de palabras de 16/32 bits LE).
  Parámetros del método (parse_GRZIP): m1..m4 = BWT+WFC, BWT+MTF, ST4+WFC, ST4+MTF;
  l<N> largo mínimo LZP, h<N> log2 del hash, l = sin LZP, b<mem> tamaño de bloque (default 8mb,
  tope GRZ_MaxBlockSize), s = BWT alternativo, a = bloque adaptativo, d = filtro delta,
  p = d sin LZP ni a, t/i hilos/buffers. Todo eso queda en el Mode de cada bloque: al
  decodificador solo le importa b, que dimensiona los buffers (BlockSize+LZP_MaxMatchLen).
  4x4:grzip usa el DeCompressMem por defecto (el mismo stream en memoria): GrzipDecodeMem.

  Las validaciones que el C no hace (índices del BWT/ST4, rangos del aritmético, tamaños) están
  marcadas "validación"; con datos válidos no cambian nada. }
unit parc_grzip;

{$mode objfpc}{$H+}
{$modeswitch advancedrecords}
{$pointermath on}
{$R-}{$Q-}

interface

uses
  Classes, SysUtils, parc_bytes, parc_stream, parc_parallel;

type
  { Un bloque del stream: se decodifica en un hilo del pool y se entrega en orden. }
  TGrzipJob = class(TParallelJob)
  public
    InBuf: TBytes;
    procedure Process; override;
  end;

  { Como GRZipMTDecompressor: bloques en paralelo con la salida en orden (parc_parallel). }
  TGrzipStage = class(TParallelBlockStage)
  private
    FLimit: SizeInt;              // BlockSize+LZP_MaxMatchLen: tamaño de los buffers del C
  protected
    function ReadJob: TParallelJob; override;
  public
    constructor Create(ASource: TInStage; const Params: TStringArray);
  end;

{ Stream grzip completo en memoria (4x4:grzip). True si decodifica exactamente DstLen bytes;
  datos corruptos -> EArcCorrupt. }
function GrzipDecodeMem(Src: PByte; SrcLen: SizeInt; Dst: PByte; DstLen: SizeInt; const Params: TStringArray): Boolean;


implementation

uses
  parc_os;

const
  GRZ_MaxBlockSize = 8*1024*1024 - 512;
  GRZ_Log2MaxBlockSize = 23;
  LZP_MaxMatchLen = 32768;
  HDR = 28;
  StrongBWT_Flag = $40000000;
  MaxHashLog = 28;   // validación: con más, el Arc.exe de 32 bits no puede reservar la tabla

  Model_MaxFreq = 2048;
  ModelL0_0MaxFreq = 58;
  ModelL0_1MaxFreq = 62;
  ModelL0_2MaxFreq = 204;

  // WFC_MTF.h. Log2RLESize tiene 24 lugares y 23 valores: el [23] es 0 (como en el C).
  GrNum2GrBegin: array[0..6] of LongWord = (3, 5, 9, 17, 33, 65, 129);
  Log2RLESize: array[0..GRZ_Log2MaxBlockSize] of LongWord = (1, 2, 4, 8, 16, 32, 64, 128, 256,
    512, 1024, 2048, 4096, 8192, 16384, 32768, 65536, 131072, 262144, 524288, 1048576, 2097152,
    4194304, 0);

  // WFC_Ari.c: pesos que se restan cuando un símbolo queda a distancia WFC_Pos<k> = 2^(k-1)
  WFC_Val0 = 131072;
  WFC_Val: array[1..12] of LongInt = (114688, 7272, 4240, 2364, 1263, 649, 320, 153, 70, 31, 14, 8);

function GetI32(p: PByte): LongInt; inline;
begin
  Result := LongInt(LongWord(p[0]) or (LongWord(p[1]) shl 8) or (LongWord(p[2]) shl 16) or (LongWord(p[3]) shl 24));
end;

{ ---------- MTF/WFC + aritmético (MTF_Ari.c / WFC_Ari.c) ---------- }

{ Decodificador de rango del C (ARI_GetFreq / ARI_Decode / ARI_Decode_0 / ARI_Decode_1), como
  macros sobre variables locales Code, Range y AP para que FPC las deje en registros.
  La entrada se copia a un buffer con PAD ceros al final: la normalización no verifica
  límites y el bucle de símbolos comprueba una vez por símbolo que AP no se pasó más de
  ARI_SLACK bytes del final (el C lee lo que haya en su buffer; un stream válido no depende
  de eso). Un símbolo consume como mucho ~62 decodificaciones x 3 bytes < PAD - ARI_SLACK.
  ARI_BIT: bit con probabilidad AFr/2048 de ser 0. En vez de "Code div Range < AFr" usa
  "Code < AFr*Range" (equivalente, sin división; AFr*Range < 2^32). }
{$macro on}
{$define ARI_NORM :=
  while Range < (1 shl 24) do
  begin
    Code := (Code shl 8) or AP^;
    Inc(AP);
    Range := Range shl 8;
  end}
{$define ARI_BIT :=
  begin
    Range := Range shr 11;
    if Code < AFr * Range then
    begin
      Range := Range * AFr;
      ABit := 0;
    end
    else
    begin
      Dec(Code, AFr * Range);
      Range := Range * (Model_MaxFreq - AFr);
      ABit := 1;
    end;
    ARI_NORM;
  end}

const
  ARI_PAD = 512;
  ARI_SLACK = 16;

type
  TModels = record
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
    // WFC (WFC_Init): WFC_List[256] = 256 es un centinela con peso -1
    WFC_List, Char2Index, CharWeight: array[0..256] of LongInt;
    WFCBuf: PByte;
  end;
  PModels = ^TModels;

{ Init_Models (MTF_Ari.c) + WFC_Init (WFC_Ari.c). }
procedure InitModels(M: PModels);
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
    CharWeight[256] := -1;   // los pesos reales vuelven exactamente a 0, nunca bajan
  end;
end;

{ WFC_Ari.c: WFC_List[Rank] -> byte, y Update_Weight0 + Update_Weight_Full(WFC_Val<k>, WFC_Pos<k>)
  con WFC_Pos<k> = 2^(k-1). Pos = WFCBufPos (el byte nuevo se guarda en WFCBuf[Pos]). }
function WfcSymbol(M: PModels; Rank: LongWord; Pos: SizeInt): LongWord;
var
  Ch, c: LongInt;
  j, k, W: LongInt;
  List: PLongInt;
begin
  with M^ do
  begin
    Ch := WFC_List[Rank];
    WFCBuf[Pos] := Ch;
    // Update_Weight0
    Inc(CharWeight[Ch], WFC_Val0);
    j := Char2Index[Ch];
    while j > 0 do
    begin
      c := WFC_List[j-1];
      WFC_List[j] := c;
      Char2Index[c] := j;
      Dec(j);
    end;
    WFC_List[0] := Ch;
    Char2Index[Ch] := 0;
    for k := 1 to 12 do
    begin
      if Pos < (SizeInt(1) shl (k - 1)) then Break;
      c := WFCBuf[Pos - (SizeInt(1) shl (k - 1))];
      // Update_Weight
      W := CharWeight[c] - WFC_Val[k];
      CharWeight[c] := W;
      if c <> Ch then
      begin
        j := Char2Index[c];
        List := @WFC_List[j + 1];
        while CharWeight[List^] > W do
        begin
          List[-1] := List^;
          Char2Index[List^] := j;
          Inc(j);
          Inc(List);
        end;
        WFC_List[j] := c;
        Char2Index[c] := j;
      end;
    end;
  end;
  Result := LongWord(Ch);
end;

{ GRZip_MTF_Ari_Decode (MTF_Ari.c) y GRZip_WFC_Ari_Decode (WFC_Ari.c): el mismo modelo, solo
  cambia cómo el rango se traduce a un byte. Src tiene ARI_PAD ceros después de SrcLen.
  Salida: exactamente OutLen bytes (validación). Sin marcos de excepción (ver MtfWfcAriDecode). }
procedure MtfWfcCore(M: PModels; Src: PByte; SrcLen: SizeInt; Output: PByte; OutLen: SizeInt; WFC: Boolean);
var
  Code, Range, AFr, ABit: LongWord;
  AP, ALimit: PByte;
  VCtx, UCtx: PLongWord;
  OutPos, WFCBufPos: SizeInt;
  i, CtxRLE, CtxL0, CtxL1, CtxL2, GrNum, GrPos: LongInt;
  Log2RunSize, RunSize, Rank, Ch, Cum, Frq, Tot, F: LongWord;
begin
  AP := Src;
  ALimit := Src + SrcLen + ARI_SLACK;
  Code := 0;
  Range := $FFFFFFFF;
  for i := 1 to 5 do   // el primer byte se pierde, como en el C
  begin
    Code := (Code shl 8) or AP^;
    Inc(AP);
  end;
  WFCBufPos := 0;
  CtxRLE := 0; CtxL0 := 0; CtxL1 := 0;
  Ch := 0;
  OutPos := 0;
  with M^ do
  while True do
  begin
    if AP > ALimit then Corrupt('grzip: el codificador aritmético se sale de los datos');   // validación
    VCtx := @Model_L0_1[Ch, 0];
    UCtx := @Model_L0_2[4*CtxL0 + (CtxRLE and 3), 0];
    Tot := Model_L0_0[4] + UCtx[4] + VCtx[4];
    // ARI_GetFreq(Tot)
    Range := Range div Tot;
    Frq := Code div Range;
    if Frq >= Tot then Corrupt('grzip: código aritmético fuera de rango');   // validación
    Cum := 0;
    Rank := 0;
    repeat
      F := Model_L0_0[Rank] + UCtx[Rank] + VCtx[Rank];
      if Frq < Cum + F then Break;
      Inc(Cum, F);
      Inc(Rank);
    until False;
    // ARI_Decode(F, Cum)
    Dec(Code, Cum * Range);
    Range := Range * F;
    ARI_NORM;

    Inc(Model_L0_0[Rank], 2); Inc(UCtx[Rank], 2); Inc(VCtx[Rank], 2);
    Inc(Model_L0_0[4], 2); Inc(UCtx[4], 2); Inc(VCtx[4], 2);
    // Update_Model_L0
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

    if Rank = 3 then
    begin
      // Rango >= 3: grupo (unario, hasta 6) y posición dentro del grupo (GrNum+1 bits)
      VCtx := @Model_L1_0[0];
      UCtx := @Model_L1_1[CtxL1, 0];
      GrNum := 0;
      while GrNum <> 6 do
      begin
        AFr := (VCtx[0] + UCtx[0]) shr 1;
        ARI_BIT;
        if ABit = 0 then
        begin
          Inc(VCtx[0], (Model_MaxFreq - VCtx[0]) shr 4);
          Inc(UCtx[0], (Model_MaxFreq - UCtx[0]) shr 6);
          Break;
        end;
        Dec(VCtx[0], VCtx[0] shr 4);
        Dec(UCtx[0], UCtx[0] shr 6);
        Inc(VCtx); Inc(UCtx);
        Inc(GrNum);
      end;
      CtxL1 := GrNum;
      VCtx := @Model_L2_0[GrNum, 0];
      CtxL2 := 1;
      for i := 0 to GrNum do
      begin
        AFr := VCtx[CtxL2];
        ARI_BIT;
        if ABit = 0 then Inc(VCtx[CtxL2], (Model_MaxFreq - AFr) shr 7)
        else Dec(VCtx[CtxL2], AFr shr 7);
        CtxL2 := (CtxL2 shl 1) or LongInt(ABit);
      end;
      GrPos := CtxL2 - (1 shl (GrNum + 1));   // los bits leídos, sin el 1 inicial
      if (GrNum = 6) and (GrPos = 127) then Break;   // fin del bloque
      Rank := GrNum2GrBegin[GrNum] + LongWord(GrPos);
    end;

    Rank := (Rank + 1) and $FF;
    if not WFC then
    begin
      Ch := MTF_List[Rank];
      if Rank <> 0 then
      begin
        Move(MTF_List[0], MTF_List[1], Rank * SizeOf(LongWord));
        MTF_List[0] := Ch;
      end;
    end
    else
    begin
      Ch := WfcSymbol(M, Rank, WFCBufPos);
      Inc(WFCBufPos);
    end;
    Rank := (Rank - 1) and $FF;
    if Rank > 3 then Rank := 3;
    CtxL0 := ((CtxL0 shl 2) or LongInt(Rank)) and $FF;

    // Largo de la corrida: log2 en unario y después los bits bajos
    VCtx := @Model_Log2RLE_0[CtxRLE + 16*LongInt(Rank), 0];
    UCtx := @Model_Log2RLE_1[Ch, 0];
    Log2RunSize := 0;
    while True do
    begin
      AFr := (VCtx[0] + UCtx[0]) shr 1;
      ARI_BIT;
      if ABit = 0 then
      begin
        Inc(VCtx[0], (Model_MaxFreq - VCtx[0]) shr 6);
        Inc(UCtx[0], (Model_MaxFreq - UCtx[0]) shr 3);
        Break;
      end;
      Dec(VCtx[0], VCtx[0] shr 6);
      Dec(UCtx[0], UCtx[0] shr 3);
      Inc(VCtx); Inc(UCtx);
      Inc(Log2RunSize);
      if Log2RunSize > GRZ_Log2MaxBlockSize then Corrupt('grzip: corrida demasiado larga');   // validación
    end;
    if Log2RunSize < 2 then CtxRLE := (CtxRLE shl 1) and $F
    else CtxRLE := ((CtxRLE shl 1) or 1) and $F;

    VCtx := @Model_Log2RLE_2[Log2RunSize, 0];
    RunSize := 0;
    for i := 1 to LongInt(Log2RunSize) do
    begin
      AFr := VCtx[0];
      ARI_BIT;
      if ABit = 0 then Inc(VCtx[0], (Model_MaxFreq - AFr) shr 6)
      else Dec(VCtx[0], AFr shr 6);
      RunSize := (RunSize shl 1) or ABit;
      Inc(VCtx);
    end;
    Inc(RunSize, Log2RLESize[Log2RunSize]);

    if RunSize > LongWord(OutLen - OutPos) then Corrupt('grzip: la salida del MTF/WFC excede el bloque');   // validación
    if RunSize = 1 then Output[OutPos] := Byte(Ch)
    else FillChar(Output[OutPos], RunSize, Byte(Ch));
    Inc(OutPos, RunSize);
  end;
  if OutPos <> OutLen then Corrupt('grzip: tamaño de salida del MTF/WFC incorrecto');   // validación
end;

{ Reservas y liberación fuera del núcleo: en una función con try/finally FPC no deja variables
  en registros (setjmp), y el núcleo es el bucle caliente. }
procedure MtfWfcAriDecode(Src: PByte; SrcLen: SizeInt; Output: PByte; OutLen: SizeInt; WFC: Boolean);
var
  M: PModels;
  Pad: PByte;
begin
  M := nil;
  Pad := nil;
  try
    New(M);
    M^.WFCBuf := nil;
    InitModels(M);
    // El C reserva H[8] bytes; puede haber hasta OutLen símbolos (relleno incluido)
    if WFC then GetMem(M^.WFCBuf, OutLen + 1);
    GetMem(Pad, SrcLen + ARI_PAD);
    if SrcLen > 0 then Move(Src^, Pad^, SrcLen);
    FillChar(Pad[SrcLen], ARI_PAD, 0);
    MtfWfcCore(M, Pad, SrcLen, Output, OutLen, WFC);
  finally
    if Pad <> nil then FreeMem(Pad);
    if M <> nil then
    begin
      if M^.WFCBuf <> nil then FreeMem(M^.WFCBuf);
      Dispose(M);
    end;
  end;
end;

{ ---------- BWT / ST4 inversos ---------- }

{ GRZip_FastBWT_Decode (BWT.c), en el lugar. }
procedure FastBwtCore(Input: PByte; Size: SizeInt; FBP: LongInt; T: PLongWord);
var
  Count: array[0..255] of LongWord;
  i: SizeInt;
  Sum, u: LongWord;
  c: Byte;
begin
    FillChar(Count, SizeOf(Count), 0);
    for i := 0 to Size - 1 do
    begin
      c := Input[i];
      T[i] := (Count[c] shl 8) or c;
      Inc(Count[c]);
    end;
    Sum := 0;
    for i := 0 to 255 do
    begin
      Inc(Sum, Count[i]);
      Count[i] := Sum - Count[i];
    end;
    // T es una permutación: FBP queda siempre en [0, Size)
    for i := Size - 1 downto 0 do
    begin
      u := T[FBP];
      c := u and $FF;
      FBP := (u shr 8) + Count[c];
      Input[i] := c;
    end;
end;

procedure FastBwtDecode(Input: PByte; Size: SizeInt; FBP: LongInt);
var
  T: PLongWord;
begin
  if (FBP < 0) or (FBP >= Size) then Corrupt('grzip: índice primario del BWT inválido');   // validación
  GetMem(T, Size * SizeOf(LongWord));
  try
    FastBwtCore(Input, Size, FBP, T);
  finally
    FreeMem(T);
  end;
end;

{ GRZip_StrongBWT_Decode (BWT.c), en el lugar. T tiene Size+1 lugares; T[FBP] el C lo deja sin
  inicializar (con datos válidos no se lee): acá es 0. }
procedure StrongBwtCore(Input: PByte; Size: SizeInt; FBP: LongInt; T: PLongWord);
var
  Count: array[0..255] of LongWord;
  i: SizeInt;
  Sum, u, p: LongWord;
  c: Byte;
begin
    FillChar(Count, SizeOf(Count), 0);
    for i := 0 to FBP - 1 do
    begin
      c := Input[i];
      T[i] := (Count[c] shl 8) or c;
      Inc(Count[c]);
    end;
    T[FBP] := 0;
    for i := FBP to Size - 1 do
    begin
      c := Input[i];
      T[i + 1] := (Count[c] shl 8) or c;
      Inc(Count[c]);
    end;
    Sum := 1;
    for i := 0 to 255 do
    begin
      Inc(Sum, Count[i]);
      Count[i] := Sum - Count[i];
    end;
    // Índices en [0, Size]: Count[c] >= 1 y (u shr 8) < Count original de c
    p := 0;
    for i := Size - 1 downto 0 do
    begin
      u := T[p];
      c := u and $FF;
      p := (u shr 8) + Count[c];
      Input[i] := c;
    end;
end;

procedure StrongBwtDecode(Input: PByte; Size: SizeInt; FBP: LongInt);
var
  T: PLongWord;
begin
  if (FBP < 0) or (FBP > Size) then Corrupt('grzip: índice primario del BWT inválido');   // validación
  GetMem(T, (Size + 1) * SizeOf(LongWord));
  try
    StrongBwtCore(Input, Size, FBP, T);
  finally
    FreeMem(T);
  end;
end;

{ GRZip_BWT_Decode (BWT.c): el bit 30 del índice elige la variante. }
procedure BwtDecode(Input: PByte; Size: SizeInt; FBP: LongInt);
begin
  if (FBP and StrongBWT_Flag) = 0 then FastBwtDecode(Input, Size, FBP)
  else StrongBwtDecode(Input, Size, FBP and not StrongBWT_Flag);
end;

{ GRZip_ST4_Decode (ST4.c): transformada de Schindler de orden 4 inversa, en el lugar. }
const
  ST_INDIRECT = $800000;

procedure St4Core(Input: PByte; Size: SizeInt; FBP: LongInt; Context2: PLongInt; Flag: PByte; Table: PLongWord);
const
  IDX_MASK = ST_INDIRECT - 1;
var
  LastSeen, T, S: array[0..255] of LongInt;
  CStart, Sum, i, j: LongInt;
  Sm, k: LongWord;
  c: Byte;
begin
    FillChar(T, SizeOf(T), 0);
    FillChar(LastSeen, SizeOf(LastSeen), $FF);
    for i := 0 to Size - 1 do Inc(T[Input[i]]);
    j := 0; Sum := 0;
    for i := 0 to 255 do
    begin
      Inc(Sum, T[i]);
      T[i] := Sum - T[i];
      while j < Sum do
      begin
        Inc(Context2[(LongInt(Input[j]) shl 8) or i]);
        Inc(j);
      end;
    end;
    S := T;
    j := 0; Sum := 0;
    for i := 0 to 65535 do
    begin
      CStart := Sum;
      Inc(Sum, Context2[i]);
      while j < Sum do
      begin
        c := Input[j];
        if LastSeen[c] <> CStart then
        begin
          LastSeen[c] := CStart;
          Flag[T[c] shr 3] := Flag[T[c] shr 3] or (1 shl (T[c] and 7));   // ST_SetBit
        end;
        Inc(T[c]);
        Inc(j);
      end;
    end;
    FillChar(LastSeen, SizeOf(LastSeen), 0);
    CStart := 0;
    for i := 0 to Size - 1 do
    begin
      c := Input[i];
      if (Flag[i shr 3] and (1 shl (i and 7))) <> 0 then CStart := i;   // ST_GetBit
      if LastSeen[c] <= CStart then
      begin
        Table[i] := LongWord(S[c]);
        LastSeen[c] := i + 1;
      end
      else
        Table[i] := LongWord(LastSeen[c] - 1) or ST_INDIRECT;
      Inc(S[c]);
      Table[i] := Table[i] or (LongWord(c) shl 24);
    end;
    Table[Size] := ST_INDIRECT;

    k := LongWord(FBP);
    Sm := Table[k];
    for i := 0 to Size - 1 do
    begin
      if (Sm and ST_INDIRECT) <> 0 then
      begin
        j := Sm and IDX_MASK;
        if j > Size then Corrupt('grzip: ST4 inválido');   // validación
        k := Table[j] and IDX_MASK;
        Inc(Table[j]);
      end
      else
      begin
        Inc(Table[k]);
        k := Sm and IDX_MASK;
      end;
      if k > LongWord(Size) then Corrupt('grzip: ST4 inválido');   // validación
      Sm := Table[k];
      Input[i] := Byte(Sm shr 24);
    end;
end;

procedure St4Decode(Input: PByte; Size: SizeInt; FBP: LongInt);
var
  Context2: PLongInt;
  Flag: PByte;
  Table: PLongWord;
begin
  // validación: los índices de Table son de 23 bits y FBP está en [0, Size]
  if (Size <= 0) or (Size >= ST_INDIRECT) then Corrupt('grzip: tamaño de bloque ST4 inválido');
  if (FBP < 0) or (FBP > Size) then Corrupt('grzip: índice primario del ST4 inválido');
  Context2 := nil; Flag := nil; Table := nil;
  try
    Context2 := AllocMem(65536 * SizeOf(LongInt));
    Flag := AllocMem((Size + 8) shr 3);
    GetMem(Table, (Size + 1) * SizeOf(LongWord));
    St4Core(Input, Size, FBP, Context2, Flag, Table);
  finally
    if Table <> nil then FreeMem(Table);
    if Flag <> nil then FreeMem(Flag);
    if Context2 <> nil then FreeMem(Context2);
  end;
end;

{ ---------- LZP y filtro de registros ---------- }

{ GRZip_LZP_Decode (LZP.c). El C guarda punteros en una tabla dimensionada con sizeof(uint32)
  (en 64 bits se desborda); acá son offsets en la salida (0 = vacío: siempre son >= 4), la
  misma semántica que el binario de 32 bits. Devuelve el tamaño decodificado (<= OutCap). }
function LzpCore(Input: PByte; Size: SizeInt; Output: PByte; OutCap: SizeInt; MinLen, HTMask: LongWord; Contexts: PLongInt): SizeInt;
const
  LZP_MatchFlag = $F2;
  LZP_RunFlag = $F3;
  LZP_XorFlag = $FF xor LZP_RunFlag;
var
  ip, op, ptr, n: SizeInt;
  Ctx, h, Len: LongWord;
  b: Byte;
begin
    PLongWord(Output)^ := PLongWord(Input)^;
    Ctx := LongWord(Input[3]) or (LongWord(Input[2]) shl 8) or (LongWord(Input[1]) shl 16) or (LongWord(Input[0]) shl 24);
    ip := 4; op := 4;
    while ip < Size do
    begin
      h := ((Ctx shr 15) xor Ctx xor (Ctx shr 3)) and HTMask;
      ptr := Contexts[h];
      Contexts[h] := op;
      b := Input[ip]; Inc(ip);
      if (ptr <> 0) and (b = LZP_MatchFlag) then
      begin
        Len := 0;
        repeat
          if ip >= Size then Corrupt('grzip: LZP truncado');   // validación
          b := Input[ip]; Inc(ip);
          Inc(Len, b xor LZP_XorFlag);
        until b <> LZP_RunFlag;
        if Len <> 0 then
        begin
          Len := Len + MinLen - 1;
          if (Len > LongWord(OutCap - op)) then Corrupt('grzip: el LZP excede el bloque');   // validación
          n := Len;
          if op - ptr >= n then
          begin
            Move(Output[ptr], Output[op], n);
            Inc(op, n);
          end
          else
            while n > 0 do   // solapado: byte a byte, como el C
            begin
              Output[op] := Output[ptr];
              Inc(op); Inc(ptr); Dec(n);
            end;
          Ctx := LongWord(Output[op-1]) or (LongWord(Output[op-2]) shl 8) or (LongWord(Output[op-3]) shl 16) or (LongWord(Output[op-4]) shl 24);
          Continue;
        end;
        b := LZP_MatchFlag;
      end;
      if op >= OutCap then Corrupt('grzip: el LZP excede el bloque');   // validación
      Output[op] := b; Inc(op);
      Ctx := (Ctx shl 8) or b;
    end;
  Result := op;
end;

function LzpDecode(Input: PByte; Size: SizeInt; Output: PByte; OutCap: SizeInt; MinLen, HTMask: LongWord): SizeInt;
var
  Contexts: PLongInt;
begin
  if (Size < 4) or (OutCap < 4) then Corrupt('grzip: bloque LZP demasiado chico');   // validación
  Contexts := AllocMem((SizeInt(HTMask) + 1) * SizeOf(LongInt));
  try
    Result := LzpCore(Input, Size, Output, OutCap, MinLen, HTMask, Contexts);
  finally
    FreeMem(Contexts);
  end;
end;

{ LZP con los parámetros del Mode (Get_LZP_MinMatchLen / Get_LZP_HT_Size de libGRZip.h,
  aritmética con signo de 32 bits; el desplazamiento de 1<<n es módulo 32 como en x86). }
function LzpDecodeMode(Input: PByte; Size: SizeInt; Output: PByte; OutCap: SizeInt; Mode: LongInt): SizeInt;
var
  s: LongInt;
begin
  s := ((Mode div 256) mod 256) and 31;
  if s > MaxHashLog then Corrupt('grzip: tabla hash de LZP inválida');   // validación
  Result := LzpDecode(Input, Size, Output, OutCap, LongWord((Mode div 65536) mod 32767), (LongWord(1) shl s) - 1);
end;

{ GRZip_Rec_Decode (Rec_Flt.c). Palabras little-endian, como en x86. }
procedure RecDecode(Input: PByte; Size: SizeInt; Output: PByte; Mode: LongInt);
var
  NumRecords, P1, P2, P3, i, r: SizeInt;
  D16, Code16, Pred16: Word;
  D32, Code32, Pred32: LongWord;
begin
  case Mode of
    3:
      begin
        NumRecords := Size shr 1;
        Pred16 := 0;
        for r := 0 to NumRecords - 1 do
        begin
          D16 := Word((Word(Input[r]) shl 8) or Input[r + NumRecords]);
          if (D16 and 1) <> 0 then D16 := Word(not (D16 shr 1)) else D16 := D16 shr 1;
          Code16 := Word(D16 + Pred16); Pred16 := Code16;
          Output[2*r] := Byte(Code16); Output[2*r + 1] := Byte(Code16 shr 8);
        end;
        for i := 2*NumRecords to Size - 1 do Output[i] := Input[i];
      end;
    4:
      begin
        NumRecords := Size shr 2;
        P1 := NumRecords; P2 := 2*NumRecords; P3 := 3*NumRecords;
        Pred32 := 0;
        for r := 0 to NumRecords - 1 do
        begin
          D32 := (LongWord(Input[r]) shl 24) or (LongWord(Input[r + P3]) shl 16) or
                 (LongWord(Input[r + P2]) shl 8) or Input[r + P1];
          if (D32 and 1) <> 0 then D32 := not (D32 shr 1) else D32 := D32 shr 1;
          Code32 := D32 + Pred32; Pred32 := Code32;
          Output[4*r] := Byte(Code32); Output[4*r + 1] := Byte(Code32 shr 8);
          Output[4*r + 2] := Byte(Code32 shr 16); Output[4*r + 3] := Byte(Code32 shr 24);
        end;
        for i := 4*NumRecords to Size - 1 do Output[i] := Input[i];
      end;
    1:
      begin
        r := 0;
        i := 0; while i < Size do begin Output[i] := Input[r]; Inc(r); Inc(i, 2); end;
        i := 1; while i < Size do begin Output[i] := Input[r]; Inc(r); Inc(i, 2); end;
      end;
    2:
      begin
        r := 0;
        for P1 := 0 to 3 do
        begin
          i := P1;
          while i < Size do begin Output[i] := Input[r]; Inc(r); Inc(i, 4); end;
        end;
      end;
  else
    Corrupt('grzip: filtro de registros desconocido');   // validación (el C no escribe nada)
  end;
end;

{ ---------- un bloque ---------- }

{ GRZip_DecompressBlock (C_GRZip.cpp). Depth: los sub-bloques de -2 no pueden ser -2 (el
  compresor apaga el filtro para ellos). }
function DecodeBlock(Input: PByte; Size: SizeInt; Output: PByte; OutCap: SizeInt; Depth: Integer): SizeInt;
var
  Mode, OrigSize, DataSize, TSize, FBP, RecMode: LongInt;
  Padded, Part, Pos, OutPos, Got: SizeInt;
  Buf: PByte;
  Tmp: PByte;
  Remain: SizeInt;
  nParts, k: Integer;
begin
  if Size < HDR then Corrupt('grzip: bloque truncado');
  if GetI32(Input + 24) <> 0 then Corrupt('grzip: firma de bloque inválida');
  DataSize := GetI32(Input + 16);
  if (DataSize < 0) or (DataSize > Size - HDR) then Corrupt('grzip: bloque truncado');
  if GetI32(Input + 20) <> 0 then Corrupt('grzip: firma de bloque inválida');
  OrigSize := GetI32(Input);
  if (OrigSize < 0) or (OrigSize > OutCap) then Corrupt('grzip: tamaño de bloque inválido');   // validación
  Mode := GetI32(Input + 4);

  if Mode = -1 then
  begin
    // Guardado (GRZip_StoreBlock), quizás con LZP
    Mode := GetI32(Input + 8);
    if Mode = 0 then
    begin
      if DataSize <> OrigSize then Corrupt('grzip: tamaño de bloque guardado incorrecto');   // validación
      if DataSize > 0 then Move(Input[HDR], Output^, DataSize);
      Exit(DataSize);
    end;
    Result := LzpDecodeMode(Input + HDR, DataSize, Output, OrigSize, Mode);
    if Result <> OrigSize then Corrupt('grzip: tamaño de bloque LZP incorrecto');   // validación
    Exit;
  end;

  if Mode = -2 then
  begin
    // Filtro de registros: 2 ó 4 sub-bloques con sus propios encabezados
    if Depth > 0 then Corrupt('grzip: filtro de registros anidado');   // validación
    RecMode := GetI32(Input + 8);
    if (RecMode < 1) or (RecMode > 4) then Corrupt('grzip: filtro de registros desconocido');
    if (RecMode and 1) = 1 then nParts := 2 else nParts := 4;
    GetMem(Buf, OrigSize + 1);
    try
      Tmp := Input + HDR;
      Remain := DataSize;
      OutPos := 0;
      for k := 1 to nParts do
      begin
        Part := OrigSize div nParts;
        if k = nParts then Part := OrigSize - OutPos;
        if Remain < HDR then Corrupt('grzip: sub-bloque truncado');
        Pos := GetI32(Tmp + 16);
        if (Pos < 0) or (Pos > Remain - HDR) then Corrupt('grzip: sub-bloque truncado');
        Got := DecodeBlock(Tmp, Pos + HDR, Buf + OutPos, Part, Depth + 1);
        if Got <> Part then Corrupt('grzip: sub-bloque de tamaño incorrecto');   // validación
        Inc(OutPos, Got);
        Inc(Tmp, Pos + HDR);
        Dec(Remain, Pos + HDR);
      end;
      RecDecode(Buf, OrigSize, Output, RecMode);
    finally
      FreeMem(Buf);
    end;
    Exit(OrigSize);
  end;

  // Normal: MTF/WFC + aritmético -> BWT/ST4 inverso -> LZP inverso
  TSize := GetI32(Input + 8);
  if (TSize <= 0) or (TSize > OrigSize) then Corrupt('grzip: tamaño LZP inválido');   // validación
  Padded := (SizeInt(TSize) + 7) and not SizeInt(7);
  FBP := GetI32(Input + 12);
  GetMem(Buf, Padded + 8);
  try
    MtfWfcAriDecode(Input + HDR, DataSize, Buf, Padded, (Mode and 4) = 0);
    if (Mode and 2) <> 0 then St4Decode(Buf, Padded, FBP)
    else BwtDecode(Buf, Padded, FBP);
    if (Mode div 256) <> 0 then
    begin
      Got := LzpDecodeMode(Buf, TSize, Output, OrigSize, Mode);
      if Got <> OrigSize then Corrupt('grzip: tamaño de bloque LZP incorrecto');   // validación
    end
    else
    begin
      if TSize <> OrigSize then Corrupt('grzip: tamaño de bloque incorrecto');   // validación
      Move(Buf^, Output^, TSize);
    end;
  finally
    FreeMem(Buf);
  end;
  Result := OrigSize;
end;


{ ---------- parámetros ---------- }

{ parseInt / parseMem de Compression/Common.cpp (parseMem sin sufijo = potencia de 2). }
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

{ parse_GRZIP (C_GRZip.cpp): solo se conserva BlockSize; el resto se valida y se descarta.
  Devuelve el tamaño de los buffers del decodificador C: min(BlockSize, GRZ_MaxBlockSize) +
  LZP_MaxMatchLen. }
function ParseGrzipLimit(const Params: TStringArray): SizeInt;
var
  k: Integer;
  p: string;
  v, BlockSize: QWord;
  ok: Boolean;
begin
  if (Length(Params) = 0) or (Params[0] <> 'grzip') then Corrupt('grzip: método inválido');
  BlockSize := 8 shl 20;
  for k := 1 to High(Params) do
  begin
    p := Params[k];
    if Length(p) = 1 then
    begin
      if p[1] in ['s', 'a', 'l', 'd', 'p'] then Continue;
    end
    else if p <> '' then
      case p[1] of
        'm', 'l', 'h', 't', 'i':
          begin
            if not CParseInt(Copy(p, 2, MaxInt), v) then Corrupt('grzip: parámetro inválido "' + p + '"');
            Continue;
          end;
        'b':
          begin
            if not CParseMem(Copy(p, 2, MaxInt), BlockSize) then Corrupt('grzip: parámetro inválido "' + p + '"');
            Continue;
          end;
      end;
    // Sin nombre: entero = MinMatchLen, si no, BlockSize
    if CParseInt(p, v) then Continue;
    ok := CParseMem(p, v);
    if not ok then Corrupt('grzip: parámetro inválido "' + p + '"');
    BlockSize := v;
  end;
  if BlockSize > GRZ_MaxBlockSize then BlockSize := GRZ_MaxBlockSize;
  Result := SizeInt(BlockSize) + LZP_MaxMatchLen;
end;

{ ---------- en memoria ---------- }

function GrzipDecodeMem(Src: PByte; SrcLen: SizeInt; Dst: PByte; DstLen: SizeInt; const Params: TStringArray): Boolean;
var
  Limit, Pos, OutPos, DataSize, OrigSize: SizeInt;
  Tmp: TBytes;
begin
  Limit := ParseGrzipLimit(Params);
  Pos := 0;
  OutPos := 0;
  while Pos < SrcLen do
  begin
    // GRZipMTDecompressor::ReaderThread
    if SrcLen - Pos < HDR then Corrupt('grzip: bloque truncado');
    if GetI32(Src + Pos + 24) <> 0 then Corrupt('grzip: firma de bloque inválida');
    DataSize := GetI32(Src + Pos + 16);
    if (DataSize < 0) or (DataSize > Limit - HDR) then Corrupt('grzip: tamaño de bloque inválido');   // validación
    if DataSize > SrcLen - Pos - HDR then Corrupt('grzip: bloque truncado');
    OrigSize := GetI32(Src + Pos);
    if (OrigSize < 0) or (OrigSize > Limit) then Corrupt('grzip: tamaño de bloque inválido');   // validación
    if OrigSize > DstLen - OutPos then Exit(False);
    if OrigSize > 0 then
      DecodeBlock(Src + Pos, HDR + DataSize, Dst + OutPos, OrigSize, 0)
    else
    begin
      SetLength(Tmp, 1);
      DecodeBlock(Src + Pos, HDR + DataSize, @Tmp[0], 0, 0);
    end;
    Inc(OutPos, OrigSize);
    Inc(Pos, HDR + DataSize);
  end;
  Result := OutPos = DstLen;
end;

{ ---------- stream (GRZipMTDecompressor: bloques en paralelo) ---------- }

// GRZipMTDecompressor::Process
procedure TGrzipJob.Process;
begin
  SetLength(OutBuf, OutSize + 1);
  DecodeBlock(PByte(InBuf), Length(InBuf), PByte(OutBuf), OutSize, 0);
  InBuf := nil;
end;

constructor TGrzipStage.Create(ASource: TInStage; const Params: TStringArray);
var
  Limit: SizeInt;
begin
  Limit := ParseGrzipLimit(Params);   // antes de adoptar ASource: si falla, el llamador la libera
  // Cada bloque en decodificación usa ~7 veces su tamaño (8mb -> ~60MB): tope de 8 hilos;
  // + 2 bloques por adelantado (NumExtraBuffers por defecto de GRZIP_METHOD)
  inherited Create(ASource, 8, 2);
  FLimit := Limit;
end;

{ GRZipMTDecompressor::ReaderThread: encabezado de 28 bytes (EOF limpio solo antes de él) y
  H[16] bytes de datos. }
function TGrzipStage.ReadJob: TParallelJob;
var
  H: array[0..HDR-1] of Byte;
  DataSize, OrigSize: LongInt;
  Job: TGrzipJob;
begin
  Result := nil;
  if not Source.ReadExactOrEof(@H[0], HDR) then Exit;
  if GetI32(@H[24]) <> 0 then Corrupt('grzip: firma de bloque inválida');
  DataSize := GetI32(@H[16]);
  OrigSize := GetI32(@H[0]);
  // validación: el C lee en un buffer de BlockSize+LZP_MaxMatchLen (y escribe en otro igual)
  if (DataSize < 0) or (DataSize > FLimit - HDR) then Corrupt('grzip: tamaño de bloque inválido');
  if (OrigSize < 0) or (OrigSize > FLimit) then Corrupt('grzip: tamaño de bloque inválido');
  Job := TGrzipJob.Create;
  try
    Job.OutSize := OrigSize;
    SetLength(Job.InBuf, HDR + DataSize);
    Move(H[0], Job.InBuf[0], HDR);
    if DataSize > 0 then Source.ReadExact(@Job.InBuf[HDR], DataSize);
  except
    Job.Free;
    raise;
  end;
  Result := Job;
end;

end.
