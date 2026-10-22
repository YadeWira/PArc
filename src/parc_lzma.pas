{ Decodificador LZMA1 "raw" (el formato base de FreeArc §7.1), reanudable y con diccionario circular.
  - Bloques de control: memoria-a-memoria, tamaño de salida conocido, sin marca de fin obligatoria.
  - Bloques de datos: streaming (TLzmaStage); el stream termina con marca de fin, como en
    lzma_decompress2 de FreeArc (C_LZMA.cpp), y el diccionario circular mide dictSize.
  Algoritmo según la especificación de referencia de Igor Pavlov (LzmaSpec, dominio público).
  Camino rápido (DecodeFast, como LZMA_DECODE_REAL de LzmaDec.c): mientras queden al menos
  LZMA_REQUIRED_INPUT_MAX bytes de entrada decodifica símbolos enteros sin chequear la entrada;
  la cola del stream (y todo lo que sea entrada corta o truncada) sigue por el camino lento,
  así que los errores y streams cortados dan exactamente lo mismo que antes (tests/test_lzma_diff
  lo compara con la copia congelada de 0.0.2). En x86-64 el núcleo es ensamblador
  (DecLitRunAsm/DecMatchAsm); en i386, o compilando con -dPARC_NOASM, es Pascal. }
unit parc_lzma;

{$mode objfpc}{$H+}
{$R-}{$Q-}
{$pointermath on}
{$macro on}
{$IFDEF CPUX86_64}{$IFNDEF PARC_NOASM}{$DEFINE LZMA_DEC_ASM}{$ENDIF}{$ENDIF}

interface

uses
  SysUtils, parc_stream;

type
  TLzmaResult = (lzOk, lzBadProps, lzDataError, lzInputEof);

  TLzmaStatus = (lsLimit, lsEndMark, lsError, lsInputEof);

const
  kNumPosBitsMax = 4;
  kNumStates = 12;
  kNumLenToPosStates = 4;
  kNumAlignBits = 4;
  kEndPosModelIndex = 14;
  kNumFullDistances = 1 shl (kEndPosModelIndex shr 1);
  IN_BUF_SIZE = 1 shl 16;

type
  TProb = Word;
  PProb = ^TProb;

  TLenDecoder = record
    Choice, Choice2: TProb;
    LowT: array[0..(1 shl kNumPosBitsMax) - 1, 0..7] of TProb;
    MidT: array[0..(1 shl kNumPosBitsMax) - 1, 0..7] of TProb;
    HighT: array[0..255] of TProb;
  end;

  TLzmaDecoder = class
  private
    // Range decoder con entrada "pull" desde FIn
    FIn: TInStage;
    FInBuf: array[0..IN_BUF_SIZE - 1] of Byte;
    FInPos, FInLen: SizeInt;
    FOverrun: Boolean;
    FSrcEof: Boolean;
    Range, Code: LongWord;
    // Modelo
    lc, lp, pb: Integer;
    Literals: array of TProb;
    IsMatch: array[0..(kNumStates shl kNumPosBitsMax) - 1] of TProb;
    IsRep, IsRepG0, IsRepG1, IsRepG2: array[0..kNumStates - 1] of TProb;
    IsRep0Long: array[0..(kNumStates shl kNumPosBitsMax) - 1] of TProb;
    PosSlot: array[0..kNumLenToPosStates - 1, 0..63] of TProb;
    PosDecoders: array[0..1 + kNumFullDistances - kEndPosModelIndex - 1] of TProb;
    Align: array[0..(1 shl kNumAlignBits) - 1] of TProb;
    LenDec, RepLenDec: TLenDecoder;
    State, Rep0, Rep1, Rep2, Rep3: LongWord;
    RemainLen: LongWord;       // bytes pendientes de un match cortado por el límite
    FInitialized, FFinished: Boolean;
    procedure FillInput;
    function DecodeFast(Limit: SizeInt): Integer;
    function RefillByte: Byte;
    function NextByte: Byte; inline;
    procedure Normalize; inline;
    function Bit(var Prob: TProb): LongWord; inline;
    function DirectBits(NumBits: Integer): LongWord;
    function BitTree(Probs: PProb; NumBits: Integer): LongWord;
    function BitTreeReverse(Probs: PProb; NumBits: Integer): LongWord;
    function LenDecode(var d: TLenDecoder; PosState: LongWord): LongWord;
    function DecodeDistance(Len: LongWord): LongWord;
    procedure CopyMatch(Limit: SizeInt);
  public
    Dict: PByte;
    DictSize: SizeInt;
    DicPos: SizeInt;           // posición de escritura en Dict
    TotalPos: QWord;           // bytes producidos desde el inicio
    constructor Create(Alc, Alp, Apb: Integer; ADict: PByte; ADictSize: SizeInt; AIn: TInStage);
    { Decodifica hasta que DicPos = Limit (Limit <= DictSize), marca de fin, error o fin de entrada. }
    function DecodeTo(Limit: SizeInt): TLzmaStatus;
    property Finished: Boolean read FFinished;
    property InputOverrun: Boolean read FOverrun;
  end;

  { Etapa de streaming para bloques de datos. Es dueña de su fuente. }
  TLzmaStage = class(TInStage)
  private
    FDec: TLzmaDecoder;
    FDictBuf: array of Byte;
    FReadPos: SizeInt;
    FEnded: Boolean;
  public
    constructor Create(ASource: TInStage; Alc, Alp, Apb: Integer; ADictSize: QWord);
    destructor Destroy; override;
    function Read(Buf: PByte; Count: SizeInt): SizeInt; override;
  end;

function ValidLzmaProps(lc, lp, pb: Integer): Boolean;

{ Memoria-a-memoria (bloques de control). No exige marca de fin. }
function LzmaDecodeRaw(Src: PByte; SrcLen: SizeInt; Dst: PByte; DstLen: SizeInt;
  lc, lp, pb: Integer; out DstWritten: SizeInt): TLzmaResult;

implementation

uses
  parc_bytes;

const
  LZMA_REQUIRED_INPUT_MAX = 20;   // bytes máximos que consume un símbolo (LzmaDec.c)
  kNumBitModelTotalBits = 11;
  kBitModelTotal = 1 shl kNumBitModelTotalBits;
  kNumMoveBits = 5;
  kTopValue = LongWord(1) shl 24;
  kMatchMinLen = 2;

function ValidLzmaProps(lc, lp, pb: Integer): Boolean;
begin
  Result := (lc >= 0) and (lc <= 8) and (lp >= 0) and (lp <= 4) and (pb >= 0) and (pb <= kNumPosBitsMax);
end;

procedure InitProbs(p: PProb; Count: SizeInt);
begin
  while Count > 0 do
  begin
    p^ := kBitModelTotal shr 1;
    Inc(p);
    Dec(Count);
  end;
end;

{ TLzmaDecoder }

constructor TLzmaDecoder.Create(Alc, Alp, Apb: Integer; ADict: PByte; ADictSize: SizeInt; AIn: TInStage);
begin
  inherited Create;
  lc := Alc; lp := Alp; pb := Apb;
  Dict := ADict;
  DictSize := ADictSize;
  FIn := AIn;
  SetLength(Literals, SizeInt($300) shl (lc + lp));
  InitProbs(@Literals[0], Length(Literals));
  InitProbs(@IsMatch, Length(IsMatch));
  InitProbs(@IsRep, kNumStates);
  InitProbs(@IsRepG0, kNumStates);
  InitProbs(@IsRepG1, kNumStates);
  InitProbs(@IsRepG2, kNumStates);
  InitProbs(@IsRep0Long, Length(IsRep0Long));
  InitProbs(@PosSlot, SizeOf(PosSlot) div SizeOf(TProb));
  InitProbs(@PosDecoders, Length(PosDecoders));
  InitProbs(@Align, Length(Align));
  InitProbs(@LenDec, SizeOf(LenDec) div SizeOf(TProb));
  InitProbs(@RepLenDec, SizeOf(RepLenDec) div SizeOf(TProb));
end;

{ Camino lento de NextByte: recargar el buffer de entrada desde la fuente. Separado para que
  NextByte (el camino rápido) sí se pueda expandir en línea. }
function TLzmaDecoder.RefillByte: Byte;
begin
  FInLen := FIn.Read(@FInBuf[0], IN_BUF_SIZE);
  FInPos := 0;
  if FInLen <= 0 then
  begin
    // Más allá del final: marcamos el error y devolvemos 0 para no cortar el flujo
    FInLen := 0;
    FOverrun := True;
    Exit(0);
  end;
  Result := FInBuf[0];
  FInPos := 1;
end;

function TLzmaDecoder.NextByte: Byte;
begin
  if FInPos < FInLen then
  begin
    Result := FInBuf[FInPos];
    Inc(FInPos);
  end
  else
    Result := RefillByte;
end;

procedure TLzmaDecoder.Normalize;
begin
  if Range < kTopValue then
  begin
    Range := Range shl 8;
    // NextByte escrito a mano: FPC no lo expande en línea y este es el camino más caliente
    if FInPos < FInLen then
    begin
      Code := (Code shl 8) or FInBuf[FInPos];
      Inc(FInPos);
    end
    else
      Code := (Code shl 8) or RefillByte;
  end;
end;

function TLzmaDecoder.Bit(var Prob: TProb): LongWord;
var
  Bound: LongWord;
begin
  Bound := (Range shr kNumBitModelTotalBits) * Prob;
  if Code < Bound then
  begin
    Prob := Prob + ((kBitModelTotal - Prob) shr kNumMoveBits);
    Range := Bound;
    Result := 0;
  end
  else
  begin
    Prob := Prob - (Prob shr kNumMoveBits);
    Code := Code - Bound;
    Range := Range - Bound;
    Result := 1;
  end;
  Normalize;
end;

function TLzmaDecoder.DirectBits(NumBits: Integer): LongWord;
var
  t: LongWord;
begin
  Result := 0;
  while NumBits > 0 do
  begin
    Range := Range shr 1;
    Code := Code - Range;
    t := LongWord(0) - (Code shr 31);
    Code := Code + (Range and t);
    Result := (Result shl 1) + (t + 1);
    Normalize;
    Dec(NumBits);
  end;
end;

function TLzmaDecoder.BitTree(Probs: PProb; NumBits: Integer): LongWord;
var
  m: LongWord;
  i: Integer;
begin
  m := 1;
  for i := 1 to NumBits do m := (m shl 1) + Bit(Probs[m]);
  Result := m - (LongWord(1) shl NumBits);
end;

function TLzmaDecoder.BitTreeReverse(Probs: PProb; NumBits: Integer): LongWord;
var
  m, b: LongWord;
  i: Integer;
begin
  m := 1;
  Result := 0;
  for i := 0 to NumBits - 1 do
  begin
    b := Bit(Probs[m]);
    m := (m shl 1) + b;
    Result := Result or (b shl i);
  end;
end;

function TLzmaDecoder.LenDecode(var d: TLenDecoder; PosState: LongWord): LongWord;
begin
  if Bit(d.Choice) = 0 then
    Exit(BitTree(@d.LowT[PosState][0], 3));
  if Bit(d.Choice2) = 0 then
    Exit(8 + BitTree(@d.MidT[PosState][0], 3));
  Result := 16 + BitTree(@d.HighT[0], 8);
end;

function TLzmaDecoder.DecodeDistance(Len: LongWord): LongWord;
var
  LenState, Slot, NumDirectBits: LongWord;
begin
  LenState := Len;
  if LenState > kNumLenToPosStates - 1 then LenState := kNumLenToPosStates - 1;
  Slot := BitTree(@PosSlot[LenState][0], 6);
  if Slot < 4 then Exit(Slot);
  NumDirectBits := (Slot shr 1) - 1;
  Result := (2 or (Slot and 1)) shl NumDirectBits;
  if Slot < kEndPosModelIndex then
    Result := Result + BitTreeReverse(@PosDecoders[Result - Slot], NumDirectBits)
  else
  begin
    Result := Result + (DirectBits(NumDirectBits - kNumAlignBits) shl kNumAlignBits);
    Result := Result + BitTreeReverse(@Align[0], kNumAlignBits);
  end;
end;

{ Copia RemainLen bytes desde la distancia Rep0 (circular), sin pasar de Limit.
  Los solapamientos (dist < len) son legales: se copia byte a byte. }
procedure TLzmaDecoder.CopyMatch(Limit: SizeInt);
var
  Src, n, k, Dist: SizeInt;
  D, S: PByte;
begin
  Src := DicPos - SizeInt(Rep0) - 1;
  if Src < 0 then Inc(Src, DictSize);
  Dist := SizeInt(Rep0) + 1;
  // Por tramos: hasta Limit, hasta el fin del diccionario (la fuente da la vuelta) y lo que
  // falte del match; los contadores se actualizan una vez por tramo
  while (RemainLen > 0) and (DicPos < Limit) do
  begin
    n := Limit - DicPos;
    if n > SizeInt(RemainLen) then n := RemainLen;
    if n > DictSize - Src then n := DictSize - Src;
    D := Dict + DicPos;
    S := Dict + Src;
    if Dist >= n then
      Move(S^, D^, n)                  // sin solapamiento
    else
      for k := 0 to n - 1 do D[k] := S[k];   // solapado (dist < len): byte a byte, hacia adelante
    Inc(DicPos, n);
    Inc(Src, n);
    if Src = DictSize then Src := 0;
    Dec(RemainLen, n);
    Inc(TotalPos, n);
  end;
end;

{ Compacta lo que queda del buffer de entrada al principio y lo completa desde la fuente, para
  que el camino rápido tenga LZMA_REQUIRED_INPUT_MAX bytes por delante. }
procedure TLzmaDecoder.FillInput;
var
  n, r: SizeInt;
begin
  n := FInLen - FInPos;
  if n > 0 then Move(FInBuf[FInPos], FInBuf[0], n);
  FInPos := 0;
  FInLen := n;
  while (FInLen < IN_BUF_SIZE) and not FSrcEof do
  begin
    r := FIn.Read(@FInBuf[FInLen], IN_BUF_SIZE - FInLen);
    if r <= 0 then FSrcEof := True else Inc(FInLen, r);
    if FInLen >= LZMA_REQUIRED_INPUT_MAX then Break;
  end;
end;

{ Camino rápido (LZMA_DECODE_REAL de LzmaDec.c): range coder, estado y punteros en variables
  locales, con al menos LZMA_REQUIRED_INPUT_MAX bytes de entrada por símbolo. Mismo resultado
  que el camino lento. DecodeFast devuelve 0 = sigue, 1 = marca de fin, 2 = error.
  Versión Pascal: DecLitRun + el resto de DecodeFast con las macros de abajo. Versión x86-64:
  DecLitRunAsm + DecMatchAsm, y la copia de los matches en Pascal. }
{$define NORM:=if rng < kTopValue then begin rng := rng shl 8; cod := (cod shl 8) or inp^; Inc(inp); end}
{$define GETBIT:=begin ttt := prob^; bound := (rng shr kNumBitModelTotalBits) * ttt; if cod < bound then begin rng := bound; prob^ := ttt + ((kBitModelTotal - ttt) shr kNumMoveBits); bt := 0; end else begin rng := rng - bound; cod := cod - bound; prob^ := ttt - (ttt shr kNumMoveBits); bt := 1; end; NORM; end}
{$define TREESTEP:=begin prob := probs + sym; ttt := prob^; bound := (rng shr kNumBitModelTotalBits) * ttt; if cod < bound then begin rng := bound; prob^ := ttt + ((kBitModelTotal - ttt) shr kNumMoveBits); sym := sym + sym; end else begin rng := rng - bound; cod := cod - bound; prob^ := ttt - (ttt shr kNumMoveBits); sym := sym + sym + 1; end; NORM; end}
type
  { Estado del camino rápido que comparten DecLitRun (Pascal) y DecLitRunAsm/DecMatchAsm. }
  TLzRun = record
    rng, cod: LongWord;
    inp, inLim, dic: PByte;
    dpos, limit, dicSz: SizeInt;
    total: QWord;
    st, rep0, rep1, rep2, rep3, len: LongWord;
    lits, isMatch: PProb;
    pbMask, lpMask, lc: LongWord;
    isRep, isRepG0, isRepG1, isRepG2, isRep0Long, posSlot, posDec, alignP: PProb;
    lenDec, repLenDec: Pointer;   // TLenDecoder
    sv: array[0..7] of QWord;     // las rutinas asm guardan acá los registros preservados (no usan la pila)
  end;
  PLzRun = ^TLzRun;

{ Decodifica literales seguidos (IsMatch = 0) con pocas variables vivas. True: se leyó un
  IsMatch = 1 (el llamador sigue con el match); False: se llegó al límite de salida o de
  entrada. }
function DecLitRun(var r: TLzRun): Boolean;
var
  rng, cod, bound, ttt, sym, offs, bt, matchByte: LongWord;
  inp: PByte;
  probs, prob: PProb;
  dpos: SizeInt;
  total: QWord;
  st: LongWord;
  src: SizeInt;
begin
  Result := False;
  rng := r.rng; cod := r.cod; inp := r.inp;
  dpos := r.dpos; total := r.total; st := r.st;
  while (dpos < r.limit) and (inp <= r.inLim) do
  begin
    prob := r.isMatch + ((st shl kNumPosBitsMax) + (LongWord(total) and r.pbMask));
    ttt := prob^; bound := (rng shr kNumBitModelTotalBits) * ttt;
    if cod >= bound then
    begin
      rng := rng - bound; cod := cod - bound; prob^ := ttt - (ttt shr kNumMoveBits);
      NORM;
      Result := True;
      Break;
    end;
    rng := bound; prob^ := ttt + ((kBitModelTotal - ttt) shr kNumMoveBits);
    NORM;
    if dpos > 0 then sym := r.dic[dpos - 1]
    else if total = 0 then sym := 0
    else sym := r.dic[r.dicSz - 1];
    probs := r.lits + $300 * (((LongWord(total) and r.lpMask) shl r.lc) + (sym shr (8 - r.lc)));
    sym := 1;
    if st >= 7 then
    begin
      src := dpos - SizeInt(r.rep0) - 1;
      if src < 0 then Inc(src, r.dicSz);
      matchByte := r.dic[src];
      offs := $100;
      repeat
        matchByte := matchByte shl 1;
        bt := matchByte and offs;
        prob := probs + offs + bt + sym;
        ttt := prob^; bound := (rng shr kNumBitModelTotalBits) * ttt;
        if cod < bound then
        begin
          rng := bound; prob^ := ttt + ((kBitModelTotal - ttt) shr kNumMoveBits);
          sym := sym + sym; offs := offs and not bt;
        end
        else
        begin
          rng := rng - bound; cod := cod - bound; prob^ := ttt - (ttt shr kNumMoveBits);
          sym := sym + sym + 1; offs := offs and bt;
        end;
        NORM;
      until sym >= $100;
    end
    else
      repeat TREESTEP; until sym >= $100;
    r.dic[dpos] := Byte(sym);
    Inc(dpos);
    Inc(total);
    if st < 4 then st := 0 else if st < 10 then st := st - 3 else st := st - 6;
  end;
  r.rng := rng; r.cod := cod; r.inp := inp;
  r.dpos := dpos; r.total := total; r.st := st;
end;

{$IFDEF LZMA_DEC_ASM}
{ DecLitRun en ensamblador x86-64 (mismo resultado, bit a bit): FPC no deja rng/cod/inp en
  registros en el bucle de literales, que es ~75% del tiempo de decodificación. Rutina hoja que
  no toca la pila: los registros preservados (SysV y Win64) se guardan en r.sv, así no hace
  falta información de unwind en Win64. Registros: r8d rng, r9d cod, r10 inp, r11 dic, r12 dpos,
  r13 total, r14d st (offs en el literal con match), r15 probs del literal, ebx sym,
  ebp matchByte / resultado. }
{$asmmode intel}
function DecLitRunAsm(r: PLzRun): Boolean; assembler; nostackframe;
asm
{$IFDEF WIN64}
  mov rax, rcx
{$ELSE}
  mov rax, rdi
{$ENDIF}
  mov [rax + TLzRun.sv + 0], rbx
  mov [rax + TLzRun.sv + 8], rbp
  mov [rax + TLzRun.sv + 16], r12
  mov [rax + TLzRun.sv + 24], r13
  mov [rax + TLzRun.sv + 32], r14
  mov [rax + TLzRun.sv + 40], r15
  mov [rax + TLzRun.sv + 48], rdi
  mov [rax + TLzRun.sv + 56], rsi
  mov rdi, rax
  mov r8d, [rdi + TLzRun.rng]
  mov r9d, [rdi + TLzRun.cod]
  mov r10, [rdi + TLzRun.inp]
  mov r11, [rdi + TLzRun.dic]
  mov r12, [rdi + TLzRun.dpos]
  mov r13, [rdi + TLzRun.total]
  mov r14d, [rdi + TLzRun.st]
@loop:
  cmp r12, [rdi + TLzRun.limit]
  jge @done
  cmp r10, [rdi + TLzRun.inLim]
  ja @done
  // IsMatch[st][total and pbMask]
  mov eax, r14d
  shl eax, 4
  mov ecx, r13d
  and ecx, [rdi + TLzRun.pbMask]
  add eax, ecx
  mov rsi, [rdi + TLzRun.isMatch]
  lea rsi, [rsi + rax * 2]
  movzx eax, word ptr [rsi]
  mov edx, r8d
  shr edx, 11
  imul edx, eax
  cmp r9d, edx
  jae @ismatch
  mov r8d, edx
  mov ecx, 2048
  sub ecx, eax
  shr ecx, 5
  add eax, ecx
  mov [rsi], ax
  cmp r8d, $1000000
  jae @n0
  shl r8d, 8
  shl r9d, 8
  movzx ecx, byte ptr [r10]
  or r9d, ecx
  inc r10
@n0:
  // byte anterior: dic[dpos-1], 0 al principio del stream o dic[dicSz-1] si dio la vuelta
  test r12, r12
  jle @prevspecial
  movzx eax, byte ptr [r11 + r12 - 1]
@prevok:
  mov ecx, 8
  sub ecx, [rdi + TLzRun.lc]
  shr eax, cl
  mov edx, r13d
  and edx, [rdi + TLzRun.lpMask]
  mov ecx, [rdi + TLzRun.lc]
  shl edx, cl
  add eax, edx
  imul eax, eax, $600
  mov r15, [rdi + TLzRun.lits]
  add r15, rax
  mov ebx, 1
  cmp r14d, 7
  jae @matched
@plain:
  // un bit del árbol del literal, sin saltos: el bit es impredecible
  movzx eax, word ptr [r15 + rbx * 2]
  mov edx, r8d
  shr edx, 11
  imul edx, eax
  mov esi, eax
  shr esi, 5
  mov ecx, eax
  sub ecx, esi
  mov esi, 2048
  sub esi, eax
  shr esi, 5
  add esi, eax
  sub r8d, edx
  mov eax, r9d
  sub eax, edx
  cmovb r8d, edx
  cmovae r9d, eax
  cmovae esi, ecx
  mov [r15 + rbx * 2], si
  cmc
  adc ebx, ebx
  cmp r8d, $1000000
  jae @n1
  shl r8d, 8
  shl r9d, 8
  movzx ecx, byte ptr [r10]
  or r9d, ecx
  inc r10
@n1:
  cmp ebx, $100
  jb @plain
@store:
  mov [r11 + r12], bl
  inc r12
  inc r13
  cmp r14d, 4
  jb @st0
  cmp r14d, 10
  jb @st3
  sub r14d, 6
  jmp @loop
@st3:
  sub r14d, 3
  jmp @loop
@st0:
  xor r14d, r14d
  jmp @loop
@prevspecial:
  xor eax, eax
  test r13, r13
  jz @prevok
  mov rcx, [rdi + TLzRun.dicSz]
  movzx eax, byte ptr [r11 + rcx - 1]
  jmp @prevok
@matched:
  // literal después de un match: matchByte = dic[dpos - rep0 - 1] (circular)
  mov rcx, r12
  mov eax, [rdi + TLzRun.rep0]
  sub rcx, rax
  sub rcx, 1
  jge @mbok
  add rcx, [rdi + TLzRun.dicSz]
@mbok:
  movzx ebp, byte ptr [r11 + rcx]
  // r12/r13 (dpos/total) quedan libres como temporales mientras dura el literal
  mov [rdi + TLzRun.st], r14d
  mov [rdi + TLzRun.dpos], r12
  mov [rdi + TLzRun.total], r13
  mov r14d, $100
@mloop:
  // bit sin saltos: bt = matchByte and offs; offs := offs and (bt xor m), m = -1 si el bit es 0
  add ebp, ebp
  mov ecx, ebp
  and ecx, r14d
  lea rsi, [r14 + rcx]
  add rsi, rbx
  lea rsi, [r15 + rsi * 2]
  movzx eax, word ptr [rsi]
  mov edx, r8d
  shr edx, 11
  imul edx, eax
  mov r12d, eax
  shr r12d, 5
  mov r13d, eax
  sub r13d, r12d
  mov r12d, 2048
  sub r12d, eax
  shr r12d, 5
  add r12d, eax
  sub r8d, edx
  mov eax, r9d
  sub eax, edx
  cmovb r8d, edx
  cmovae r9d, eax
  cmovae r12d, r13d
  sbb edx, edx
  mov [rsi], r12w
  cmc
  adc ebx, ebx
  xor ecx, edx
  and r14d, ecx
  cmp r8d, $1000000
  jae @n2
  shl r8d, 8
  shl r9d, 8
  movzx ecx, byte ptr [r10]
  or r9d, ecx
  inc r10
@n2:
  cmp ebx, $100
  jb @mloop
  mov r14d, [rdi + TLzRun.st]
  mov r12, [rdi + TLzRun.dpos]
  mov r13, [rdi + TLzRun.total]
  jmp @store
@ismatch:
  // IsMatch = 1: se consume el bit y vuelve al llamador con True
  sub r8d, edx
  sub r9d, edx
  mov ecx, eax
  shr ecx, 5
  sub eax, ecx
  mov [rsi], ax
  cmp r8d, $1000000
  jae @n3
  shl r8d, 8
  shl r9d, 8
  movzx ecx, byte ptr [r10]
  or r9d, ecx
  inc r10
@n3:
  mov ebp, 1
  jmp @exit
@done:
  xor ebp, ebp
@exit:
  mov [rdi + TLzRun.rng], r8d
  mov [rdi + TLzRun.cod], r9d
  mov [rdi + TLzRun.inp], r10
  mov [rdi + TLzRun.dpos], r12
  mov [rdi + TLzRun.total], r13
  mov [rdi + TLzRun.st], r14d
  mov eax, ebp
  mov rbx, [rdi + TLzRun.sv + 0]
  mov rbp, [rdi + TLzRun.sv + 8]
  mov r12, [rdi + TLzRun.sv + 16]
  mov r13, [rdi + TLzRun.sv + 24]
  mov r14, [rdi + TLzRun.sv + 32]
  mov r15, [rdi + TLzRun.sv + 40]
  mov rsi, [rdi + TLzRun.sv + 56]
  mov rdi, [rdi + TLzRun.sv + 48]
end;

{ Símbolo de match o rep después de un IsMatch = 1 (que ya consumió DecLitRunAsm), en
  ensamblador como DecLitRunAsm. Bits de árbol (longitudes, slot, distancias) sin saltos;
  IsRep/IsRepG*/IsRep0Long con saltos. Deja en r.len la longitud - 2, en r.rep0..3 las
  distancias y en r.st el estado. 0 = match o rep, 1 = marca de fin, 2 = error (rep sin datos
  previos o distancia fuera de lo decodificado / del diccionario), 3 = "short rep" (1 byte).
  El cuerpo lo genera tests/lzma_ref/gen_lzma_match_asm.py (bits y árboles repetidos); si se
  cambia, regenerarlo y correr tests/test_lzma_diff. }
function DecMatchAsm(r: PLzRun): LongWord; assembler; nostackframe;
asm
  {$IFDEF WIN64}
  mov rax, rcx
  {$ELSE}
  mov rax, rdi
  {$ENDIF}
  mov [rax + TLzRun.sv + 0], rbx
  mov [rax + TLzRun.sv + 8], rbp
  mov [rax + TLzRun.sv + 16], r12
  mov [rax + TLzRun.sv + 24], r13
  mov [rax + TLzRun.sv + 32], r14
  mov [rax + TLzRun.sv + 40], r15
  mov [rax + TLzRun.sv + 48], rdi
  mov [rax + TLzRun.sv + 56], rsi
  mov rdi, rax
  mov r8d, [rdi + TLzRun.rng]
  mov r9d, [rdi + TLzRun.cod]
  mov r10, [rdi + TLzRun.inp]
  mov r11d, [rdi + TLzRun.st]
  mov r12d, [rdi + TLzRun.total]
  and r12d, [rdi + TLzRun.pbMask]
  xor r14d, r14d
  mov rsi, [rdi + TLzRun.isRep]
  lea rsi, [rsi + r11 * 2]
  movzx eax, word ptr [rsi]
  mov edx, r8d
  shr edx, 11
  imul edx, eax
  cmp r9d, edx
  jae @b11
  mov r8d, edx
  mov ecx, 2048
  sub ecx, eax
  shr ecx, 5
  add eax, ecx
  mov [rsi], ax
  cmp r8d, $1000000
  jae @nm3
  shl r8d, 8
  shl r9d, 8
  movzx ecx, byte ptr [r10]
  or r9d, ecx
  inc r10
@nm3:
  jmp @b02
@b11:
  sub r8d, edx
  sub r9d, edx
  mov ecx, eax
  shr ecx, 5
  sub eax, ecx
  mov [rsi], ax
  cmp r8d, $1000000
  jae @nm4
  shl r8d, 8
  shl r9d, 8
  movzx ecx, byte ptr [r10]
  or r9d, ecx
  inc r10
@nm4:
  jmp @rep
@b02:
  mov eax, [rdi + TLzRun.rep2]
  mov [rdi + TLzRun.rep3], eax
  mov eax, [rdi + TLzRun.rep1]
  mov [rdi + TLzRun.rep2], eax
  mov eax, [rdi + TLzRun.rep0]
  mov [rdi + TLzRun.rep1], eax
  mov r13, [rdi + TLzRun.lenDec]
  xor ebp, ebp
@len:
  xor r14d, r14d
  lea rsi, [r13 + TLenDecoder.Choice]
  movzx eax, word ptr [rsi]
  mov edx, r8d
  shr edx, 11
  imul edx, eax
  cmp r9d, edx
  jae @b15
  mov r8d, edx
  mov ecx, 2048
  sub ecx, eax
  shr ecx, 5
  add eax, ecx
  mov [rsi], ax
  cmp r8d, $1000000
  jae @nm7
  shl r8d, 8
  shl r9d, 8
  movzx ecx, byte ptr [r10]
  or r9d, ecx
  inc r10
@nm7:
  jmp @b06
@b15:
  sub r8d, edx
  sub r9d, edx
  mov ecx, eax
  shr ecx, 5
  sub eax, ecx
  mov [rsi], ax
  cmp r8d, $1000000
  jae @nm8
  shl r8d, 8
  shl r9d, 8
  movzx ecx, byte ptr [r10]
  or r9d, ecx
  inc r10
@nm8:
  jmp @lnc1
@b06:
  mov eax, r12d
  shl eax, 4
  lea r13, [r13 + rax + TLenDecoder.LowT]
  jmp @lnt3
@lnc1:
  lea rsi, [r13 + TLenDecoder.Choice2]
  movzx eax, word ptr [rsi]
  mov edx, r8d
  shr edx, 11
  imul edx, eax
  cmp r9d, edx
  jae @b19
  mov r8d, edx
  mov ecx, 2048
  sub ecx, eax
  shr ecx, 5
  add eax, ecx
  mov [rsi], ax
  cmp r8d, $1000000
  jae @nm11
  shl r8d, 8
  shl r9d, 8
  movzx ecx, byte ptr [r10]
  or r9d, ecx
  inc r10
@nm11:
  jmp @b010
@b19:
  sub r8d, edx
  sub r9d, edx
  mov ecx, eax
  shr ecx, 5
  sub eax, ecx
  mov [rsi], ax
  cmp r8d, $1000000
  jae @nm12
  shl r8d, 8
  shl r9d, 8
  movzx ecx, byte ptr [r10]
  or r9d, ecx
  inc r10
@nm12:
  jmp @lnc2
@b010:
  mov eax, r12d
  shl eax, 4
  lea r13, [r13 + rax + TLenDecoder.MidT]
  mov r14d, 8
@lnt3:
  mov ebx, 1
@tl13:
  movzx eax, word ptr [r13 + rbx * 2]
  mov edx, r8d
  shr edx, 11
  imul edx, eax
  mov esi, eax
  shr esi, 5
  mov ecx, eax
  sub ecx, esi
  mov esi, 2048
  sub esi, eax
  shr esi, 5
  add esi, eax
  sub r8d, edx
  mov eax, r9d
  sub eax, edx
  cmovb r8d, edx
  cmovae r9d, eax
  cmovae esi, ecx
  mov [r13 + rbx * 2], si
  cmc
  adc ebx, ebx
  cmp r8d, $1000000
  jae @nm14
  shl r8d, 8
  shl r9d, 8
  movzx ecx, byte ptr [r10]
  or r9d, ecx
  inc r10
@nm14:
  cmp ebx, 8
  jb @tl13
  lea r14d, [r14 + rbx - 8]
  jmp @lndone
@lnc2:
  lea r13, [r13 + TLenDecoder.HighT]
  mov ebx, 1
@tl15:
  movzx eax, word ptr [r13 + rbx * 2]
  mov edx, r8d
  shr edx, 11
  imul edx, eax
  mov esi, eax
  shr esi, 5
  mov ecx, eax
  sub ecx, esi
  mov esi, 2048
  sub esi, eax
  shr esi, 5
  add esi, eax
  sub r8d, edx
  mov eax, r9d
  sub eax, edx
  cmovb r8d, edx
  cmovae r9d, eax
  cmovae esi, ecx
  mov [r13 + rbx * 2], si
  cmc
  adc ebx, ebx
  cmp r8d, $1000000
  jae @nm16
  shl r8d, 8
  shl r9d, 8
  movzx ecx, byte ptr [r10]
  or r9d, ecx
  inc r10
@nm16:
  cmp ebx, 256
  jb @tl15
  lea r14d, [rbx - 240]
@lndone:
  test ebp, ebp
  jnz @repstate
  mov eax, 10
  cmp r11d, 7
  mov r11d, 7
  cmovae r11d, eax
  mov eax, r14d
  mov ecx, 3
  cmp eax, ecx
  cmova eax, ecx
  shl eax, 7
  mov r13, [rdi + TLzRun.posSlot]
  add r13, rax
  mov ebx, 1
@tl17:
  movzx eax, word ptr [r13 + rbx * 2]
  mov edx, r8d
  shr edx, 11
  imul edx, eax
  mov esi, eax
  shr esi, 5
  mov ecx, eax
  sub ecx, esi
  mov esi, 2048
  sub esi, eax
  shr esi, 5
  add esi, eax
  sub r8d, edx
  mov eax, r9d
  sub eax, edx
  cmovb r8d, edx
  cmovae r9d, eax
  cmovae esi, ecx
  mov [r13 + rbx * 2], si
  cmc
  adc ebx, ebx
  cmp r8d, $1000000
  jae @nm18
  shl r8d, 8
  shl r9d, 8
  movzx ecx, byte ptr [r10]
  or r9d, ecx
  inc r10
@nm18:
  cmp ebx, 64
  jb @tl17
  sub ebx, 64
  cmp ebx, 4
  jae @slot4
  mov r15d, ebx
  jmp @distdone
@slot4:
  mov ecx, ebx
  shr ecx, 1
  dec ecx
  mov r15d, ebx
  and r15d, 1
  or r15d, 2
  shl r15d, cl
  mov r12d, ecx
  cmp ebx, 14
  jae @direct
  mov eax, r15d
  sub eax, ebx
  mov r13, [rdi + TLzRun.posDec]
  lea r13, [r13 + rax * 2]
  mov ebx, 1
  mov ebp, 1
@revloop:
  movzx eax, word ptr [r13 + rbx * 2]
  mov edx, r8d
  shr edx, 11
  imul edx, eax
  mov esi, eax
  shr esi, 5
  mov ecx, eax
  sub ecx, esi
  mov esi, 2048
  sub esi, eax
  shr esi, 5
  add esi, eax
  sub r8d, edx
  mov eax, r9d
  sub eax, edx
  cmovb r8d, edx
  cmovae r9d, eax
  cmovae esi, ecx
  mov [r13 + rbx * 2], si
  cmc
  adc ebx, ebx
  cmp r8d, $1000000
  jae @nm19
  shl r8d, 8
  shl r9d, 8
  movzx ecx, byte ptr [r10]
  or r9d, ecx
  inc r10
@nm19:
  mov eax, ebx
  and eax, 1
  neg eax
  and eax, ebp
  or r15d, eax
  add ebp, ebp
  dec r12d
  jnz @revloop
  jmp @distdone
@direct:
  sub r12d, 4
  xor ebp, ebp
@dirloop:
  shr r8d, 1
  sub r9d, r8d
  mov ecx, r9d
  sar ecx, 31
  mov eax, ecx
  and eax, r8d
  add r9d, eax
  add ebp, ebp
  inc ebp
  add ebp, ecx
  cmp r8d, $1000000
  jae @nm20
  shl r8d, 8
  shl r9d, 8
  movzx ecx, byte ptr [r10]
  or r9d, ecx
  inc r10
@nm20:
  dec r12d
  jnz @dirloop
  shl ebp, 4
  add r15d, ebp
  mov r13, [rdi + TLzRun.alignP]
  mov ebx, 1
  mov ebp, 1
  mov r12d, 4
@alignloop:
  movzx eax, word ptr [r13 + rbx * 2]
  mov edx, r8d
  shr edx, 11
  imul edx, eax
  mov esi, eax
  shr esi, 5
  mov ecx, eax
  sub ecx, esi
  mov esi, 2048
  sub esi, eax
  shr esi, 5
  add esi, eax
  sub r8d, edx
  mov eax, r9d
  sub eax, edx
  cmovb r8d, edx
  cmovae r9d, eax
  cmovae esi, ecx
  mov [r13 + rbx * 2], si
  cmc
  adc ebx, ebx
  cmp r8d, $1000000
  jae @nm21
  shl r8d, 8
  shl r9d, 8
  movzx ecx, byte ptr [r10]
  or r9d, ecx
  inc r10
@nm21:
  mov eax, ebx
  and eax, 1
  neg eax
  and eax, ebp
  or r15d, eax
  add ebp, ebp
  dec r12d
  jnz @alignloop
@distdone:
  mov [rdi + TLzRun.rep0], r15d
  cmp r15d, $FFFFFFFF
  je @endmark
  mov eax, r15d
  cmp rax, [rdi + TLzRun.total]
  jae @error
  cmp rax, [rdi + TLzRun.dicSz]
  jae @error
  xor ebp, ebp
  jmp @exit
@rep:
  cmp qword ptr [rdi + TLzRun.total], 0
  je @error
  mov rsi, [rdi + TLzRun.isRepG0]
  lea rsi, [rsi + r11 * 2]
  movzx eax, word ptr [rsi]
  mov edx, r8d
  shr edx, 11
  imul edx, eax
  cmp r9d, edx
  jae @b122
  mov r8d, edx
  mov ecx, 2048
  sub ecx, eax
  shr ecx, 5
  add eax, ecx
  mov [rsi], ax
  cmp r8d, $1000000
  jae @nm24
  shl r8d, 8
  shl r9d, 8
  movzx ecx, byte ptr [r10]
  or r9d, ecx
  inc r10
@nm24:
  jmp @b023
@b122:
  sub r8d, edx
  sub r9d, edx
  mov ecx, eax
  shr ecx, 5
  sub eax, ecx
  mov [rsi], ax
  cmp r8d, $1000000
  jae @nm25
  shl r8d, 8
  shl r9d, 8
  movzx ecx, byte ptr [r10]
  or r9d, ecx
  inc r10
@nm25:
  jmp @g1
@b023:
  mov eax, r11d
  shl eax, 4
  add eax, r12d
  mov rsi, [rdi + TLzRun.isRep0Long]
  lea rsi, [rsi + rax * 2]
  movzx eax, word ptr [rsi]
  mov edx, r8d
  shr edx, 11
  imul edx, eax
  cmp r9d, edx
  jae @b126
  mov r8d, edx
  mov ecx, 2048
  sub ecx, eax
  shr ecx, 5
  add eax, ecx
  mov [rsi], ax
  cmp r8d, $1000000
  jae @nm28
  shl r8d, 8
  shl r9d, 8
  movzx ecx, byte ptr [r10]
  or r9d, ecx
  inc r10
@nm28:
  jmp @b027
@b126:
  sub r8d, edx
  sub r9d, edx
  mov ecx, eax
  shr ecx, 5
  sub eax, ecx
  mov [rsi], ax
  cmp r8d, $1000000
  jae @nm29
  shl r8d, 8
  shl r9d, 8
  movzx ecx, byte ptr [r10]
  or r9d, ecx
  inc r10
@nm29:
  jmp @replen
@b027:
  mov eax, 11
  cmp r11d, 7
  mov r11d, 9
  cmovae r11d, eax
  mov ebp, 3
  jmp @exit
@g1:
  mov rsi, [rdi + TLzRun.isRepG1]
  lea rsi, [rsi + r11 * 2]
  movzx eax, word ptr [rsi]
  mov edx, r8d
  shr edx, 11
  imul edx, eax
  cmp r9d, edx
  jae @b130
  mov r8d, edx
  mov ecx, 2048
  sub ecx, eax
  shr ecx, 5
  add eax, ecx
  mov [rsi], ax
  cmp r8d, $1000000
  jae @nm32
  shl r8d, 8
  shl r9d, 8
  movzx ecx, byte ptr [r10]
  or r9d, ecx
  inc r10
@nm32:
  jmp @b031
@b130:
  sub r8d, edx
  sub r9d, edx
  mov ecx, eax
  shr ecx, 5
  sub eax, ecx
  mov [rsi], ax
  cmp r8d, $1000000
  jae @nm33
  shl r8d, 8
  shl r9d, 8
  movzx ecx, byte ptr [r10]
  or r9d, ecx
  inc r10
@nm33:
  jmp @g2
@b031:
  mov r15d, [rdi + TLzRun.rep1]
  jmp @g1done
@g2:
  mov rsi, [rdi + TLzRun.isRepG2]
  lea rsi, [rsi + r11 * 2]
  movzx eax, word ptr [rsi]
  mov edx, r8d
  shr edx, 11
  imul edx, eax
  cmp r9d, edx
  jae @b134
  mov r8d, edx
  mov ecx, 2048
  sub ecx, eax
  shr ecx, 5
  add eax, ecx
  mov [rsi], ax
  cmp r8d, $1000000
  jae @nm36
  shl r8d, 8
  shl r9d, 8
  movzx ecx, byte ptr [r10]
  or r9d, ecx
  inc r10
@nm36:
  jmp @b035
@b134:
  sub r8d, edx
  sub r9d, edx
  mov ecx, eax
  shr ecx, 5
  sub eax, ecx
  mov [rsi], ax
  cmp r8d, $1000000
  jae @nm37
  shl r8d, 8
  shl r9d, 8
  movzx ecx, byte ptr [r10]
  or r9d, ecx
  inc r10
@nm37:
  jmp @g3
@b035:
  mov r15d, [rdi + TLzRun.rep2]
  jmp @g2done
@g3:
  mov r15d, [rdi + TLzRun.rep3]
  mov eax, [rdi + TLzRun.rep2]
  mov [rdi + TLzRun.rep3], eax
@g2done:
  mov eax, [rdi + TLzRun.rep1]
  mov [rdi + TLzRun.rep2], eax
@g1done:
  mov eax, [rdi + TLzRun.rep0]
  mov [rdi + TLzRun.rep1], eax
  mov [rdi + TLzRun.rep0], r15d
@replen:
  mov r13, [rdi + TLzRun.repLenDec]
  mov ebp, 1
  jmp @len
@repstate:
  mov eax, 11
  cmp r11d, 7
  mov r11d, 8
  cmovae r11d, eax
  xor ebp, ebp
  jmp @exit
@endmark:
  mov ebp, 1
  jmp @exit
@error:
  mov ebp, 2
@exit:
  mov [rdi + TLzRun.rng], r8d
  mov [rdi + TLzRun.cod], r9d
  mov [rdi + TLzRun.inp], r10
  mov [rdi + TLzRun.st], r11d
  mov [rdi + TLzRun.len], r14d
  mov eax, ebp
  mov rbx, [rdi + TLzRun.sv + 0]
  mov rbp, [rdi + TLzRun.sv + 8]
  mov r12, [rdi + TLzRun.sv + 16]
  mov r13, [rdi + TLzRun.sv + 24]
  mov r14, [rdi + TLzRun.sv + 32]
  mov r15, [rdi + TLzRun.sv + 40]
  mov rsi, [rdi + TLzRun.sv + 56]
  mov rdi, [rdi + TLzRun.sv + 48]
end;
{$ENDIF}

{$IFDEF LZMA_DEC_ASM}
{ Versión x86-64: literales y símbolos de match en ensamblador, copia de los matches acá. }
function TLzmaDecoder.DecodeFast(Limit: SizeInt): Integer;
var
  r: TLzRun;
  mres, len: LongWord;
  dic, d, sp: PByte;
  dpos, dicSz, src, curLen, k: SizeInt;
begin
  Result := 0;
  dic := Dict;
  dicSz := DictSize;
  r.rng := Range; r.cod := Code;
  r.inp := @FInBuf[FInPos];
  r.inLim := @FInBuf[FInLen - LZMA_REQUIRED_INPUT_MAX];
  r.dic := dic; r.dpos := DicPos; r.limit := Limit; r.dicSz := dicSz; r.total := TotalPos;
  r.st := State; r.rep0 := Rep0; r.rep1 := Rep1; r.rep2 := Rep2; r.rep3 := Rep3; r.len := 0;
  r.lits := @Literals[0]; r.isMatch := @IsMatch[0];
  r.pbMask := (LongWord(1) shl pb) - 1;
  r.lpMask := (LongWord(1) shl lp) - 1;
  r.lc := lc;
  r.isRep := @IsRep[0]; r.isRepG0 := @IsRepG0[0]; r.isRepG1 := @IsRepG1[0]; r.isRepG2 := @IsRepG2[0];
  r.isRep0Long := @IsRep0Long[0]; r.posSlot := @PosSlot[0][0]; r.posDec := @PosDecoders[0];
  r.alignP := @Align[0]; r.lenDec := @LenDec; r.repLenDec := @RepLenDec;
  while DecLitRunAsm(@r) do
  begin
    mres := DecMatchAsm(@r);
    if mres = 1 then begin Result := 1; Break; end;
    if mres = 2 then begin Result := 2; Break; end;
    dpos := r.dpos;
    src := dpos - SizeInt(r.rep0) - 1;
    if src < 0 then Inc(src, dicSz);
    if mres = 3 then
    begin
      // short rep: un byte desde rep0 (DecLitRunAsm ya verificó dpos < Limit)
      dic[dpos] := dic[src];
      r.dpos := dpos + 1;
      Inc(r.total);
      Continue;
    end;
    // copiar el match (len + 2 bytes desde rep0)
    len := r.len + kMatchMinLen;
    curLen := Limit - dpos;
    if curLen > SizeInt(len) then curLen := len;
    d := dic + dpos;
    if src + curLen <= dicSz then
    begin
      sp := dic + src;
      if r.rep0 >= 7 then
      begin
        k := 0;
        while k + 8 <= curLen do
        begin
          PQWord(d + k)^ := PQWord(sp + k)^;
          Inc(k, 8);
        end;
        while k < curLen do begin d[k] := sp[k]; Inc(k); end;
      end
      else
        for k := 0 to curLen - 1 do d[k] := sp[k];
    end
    else
      for k := 0 to curLen - 1 do
      begin
        d[k] := dic[src];
        Inc(src);
        if src = dicSz then src := 0;
      end;
    r.dpos := dpos + curLen;
    Inc(r.total, curLen);
    RemainLen := len - LongWord(curLen);
    if RemainLen <> 0 then Break;
  end;
  Range := r.rng; Code := r.cod;
  FInPos := r.inp - PByte(@FInBuf[0]);
  DicPos := r.dpos; TotalPos := r.total;
  State := r.st; Rep0 := r.rep0; Rep1 := r.rep1; Rep2 := r.rep2; Rep3 := r.rep3;
end;
{$ELSE}
function TLzmaDecoder.DecodeFast(Limit: SizeInt): Integer;
var
  rng, cod, bound, ttt, bt, sym, posState, pbMask, lpMask,
    len, dist, slot, nd, i, mi: LongWord;
  inp, inLim, dic, d, sp: PByte;
  probs, prob: PProb;
  dpos, dicSz, src, curLen, k: SizeInt;
  total: QWord;
  lcv: LongWord;
  lr: TLzRun;
begin
  Result := 0;
  rng := Range; cod := Code;
  inp := @FInBuf[FInPos];
  inLim := @FInBuf[FInLen - LZMA_REQUIRED_INPUT_MAX];
  dic := Dict; dpos := DicPos; dicSz := DictSize; total := TotalPos;
  pbMask := (LongWord(1) shl pb) - 1;
  lpMask := (LongWord(1) shl lp) - 1;
  lcv := lc;
  lr.inLim := inLim; lr.dic := dic; lr.limit := Limit; lr.dicSz := dicSz;
  lr.lits := @Literals[0]; lr.isMatch := @IsMatch[0];
  lr.pbMask := pbMask; lr.lpMask := lpMask; lr.lc := lcv;
  while (dpos < Limit) and (inp <= inLim) do
  begin
    lr.rng := rng; lr.cod := cod; lr.inp := inp; lr.dpos := dpos; lr.total := total;
    lr.st := State; lr.rep0 := Rep0;
    if not DecLitRun(lr) then
    begin
      rng := lr.rng; cod := lr.cod; inp := lr.inp; dpos := lr.dpos; total := lr.total;
      State := lr.st;
      Break;
    end;
    rng := lr.rng; cod := lr.cod; inp := lr.inp; dpos := lr.dpos; total := lr.total;
    State := lr.st;
    posState := LongWord(total) and pbMask;
    prob := @IsRep[State];
    GETBIT;
    if bt <> 0 then
    begin
      if total = 0 then
      begin
        Result := 2;   // rep sin datos previos (como el camino lento: estado guardado)
        Break;
      end;
      prob := @IsRepG0[State];
      GETBIT;
      if bt = 0 then
      begin
        prob := @IsRep0Long[(State shl kNumPosBitsMax) + posState];
        GETBIT;
        if bt = 0 then
        begin
          // short rep
          if State < 7 then State := 9 else State := 11;
          src := dpos - SizeInt(Rep0) - 1;
          if src < 0 then Inc(src, dicSz);
          dic[dpos] := dic[src];
          Inc(dpos);
          Inc(total);
          Continue;
        end;
      end
      else
      begin
        prob := @IsRepG1[State];
        GETBIT;
        if bt = 0 then
          dist := Rep1
        else
        begin
          prob := @IsRepG2[State];
          GETBIT;
          if bt = 0 then
            dist := Rep2
          else
          begin
            dist := Rep3;
            Rep3 := Rep2;
          end;
          Rep2 := Rep1;
        end;
        Rep1 := Rep0;
        Rep0 := dist;
      end;
      // longitud (rep)
      prob := @RepLenDec.Choice;
      GETBIT;
      if bt = 0 then
      begin
        probs := @RepLenDec.LowT[posState][0]; sym := 1;
        TREESTEP; TREESTEP; TREESTEP;
        len := sym - 8;
      end
      else
      begin
        prob := @RepLenDec.Choice2;
        GETBIT;
        if bt = 0 then
        begin
          probs := @RepLenDec.MidT[posState][0]; sym := 1;
          TREESTEP; TREESTEP; TREESTEP;
          len := 8 + sym - 8;
        end
        else
        begin
          probs := @RepLenDec.HighT[0]; sym := 1;
          for i := 1 to 8 do TREESTEP;
          len := 16 + sym - 256;
        end;
      end;
      if State < 7 then State := 8 else State := 11;
    end
    else
    begin
      Rep3 := Rep2; Rep2 := Rep1; Rep1 := Rep0;
      prob := @LenDec.Choice;
      GETBIT;
      if bt = 0 then
      begin
        probs := @LenDec.LowT[posState][0]; sym := 1;
        TREESTEP; TREESTEP; TREESTEP;
        len := sym - 8;
      end
      else
      begin
        prob := @LenDec.Choice2;
        GETBIT;
        if bt = 0 then
        begin
          probs := @LenDec.MidT[posState][0]; sym := 1;
          TREESTEP; TREESTEP; TREESTEP;
          len := 8 + sym - 8;
        end
        else
        begin
          probs := @LenDec.HighT[0]; sym := 1;
          for i := 1 to 8 do TREESTEP;
          len := 16 + sym - 256;
        end;
      end;
      if State < 7 then State := 7 else State := 10;
      // distancia
      if len < kNumLenToPosStates - 1 then probs := @PosSlot[len][0]
      else probs := @PosSlot[kNumLenToPosStates - 1][0];
      sym := 1;
      TREESTEP; TREESTEP; TREESTEP; TREESTEP; TREESTEP; TREESTEP;
      slot := sym - 64;
      if slot < 4 then
        dist := slot
      else
      begin
        nd := (slot shr 1) - 1;
        dist := (2 or (slot and 1)) shl nd;
        if slot < kEndPosModelIndex then
        begin
          probs := @PosDecoders[dist - slot];
          mi := 1;
          for i := 0 to nd - 1 do
          begin
            prob := probs + mi;
            GETBIT;
            mi := mi + mi + bt;
            dist := dist or (bt shl i);
          end;
        end
        else
        begin
          nd := nd - kNumAlignBits;
          repeat
            rng := rng shr 1;
            cod := cod - rng;
            ttt := LongWord(0) - (cod shr 31);
            cod := cod + (rng and ttt);
            dist := dist + ((ttt + 1) shl (nd - 1 + kNumAlignBits));
            NORM;
            Dec(nd);
          until nd = 0;
          // los bits directos se sumaron en su posición; ahora los 4 de alineación
          probs := @Align[0];
          mi := 1;
          for i := 0 to kNumAlignBits - 1 do
          begin
            prob := probs + mi;
            GETBIT;
            mi := mi + mi + bt;
            dist := dist or (bt shl i);
          end;
        end;
      end;
      Rep0 := dist;
      if Rep0 = $FFFFFFFF then
      begin
        Result := 1;
        Break;
      end;
      if (QWord(Rep0) >= total) or (SizeInt(Rep0) >= dicSz) then
      begin
        Result := 2;
        Break;
      end;
    end;
    // copiar el match (len + 2 bytes desde Rep0)
    len := len + kMatchMinLen;
    curLen := Limit - dpos;
    if curLen > SizeInt(len) then curLen := len;
    src := dpos - SizeInt(Rep0) - 1;
    if src < 0 then Inc(src, dicSz);
    d := dic + dpos;
    if src + curLen <= dicSz then
    begin
      sp := dic + src;
      if Rep0 >= 7 then
      begin
        k := 0;
        while k + 8 <= curLen do
        begin
          PQWord(d + k)^ := PQWord(sp + k)^;
          Inc(k, 8);
        end;
        while k < curLen do begin d[k] := sp[k]; Inc(k); end;
      end
      else
        for k := 0 to curLen - 1 do d[k] := sp[k];
    end
    else
      for k := 0 to curLen - 1 do
      begin
        d[k] := dic[src];
        Inc(src);
        if src = dicSz then src := 0;
      end;
    Inc(dpos, curLen);
    Inc(total, curLen);
    RemainLen := len - LongWord(curLen);
    if RemainLen <> 0 then Break;
  end;
  Range := rng; Code := cod;
  FInPos := inp - PByte(@FInBuf[0]);
  DicPos := dpos; TotalPos := total;
end;
{$ENDIF}

function TLzmaDecoder.DecodeTo(Limit: SizeInt): TLzmaStatus;
var
  PosState, PbMask, LpMask, Symbol, MatchByte, MatchBit, b, Len, Dist: LongWord;
  PrevByte: Byte;
  LitProbs: PProb;
  i: Integer;
  Src: SizeInt;
begin
  if FFinished then Exit(lsEndMark);
  if not FInitialized then
  begin
    FInitialized := True;
    Range := $FFFFFFFF;
    Code := 0;
    if NextByte <> 0 then Exit(lsError);
    for i := 1 to 4 do Code := (Code shl 8) or NextByte;
    if FOverrun then Exit(lsInputEof);
    if Code = Range then Exit(lsError);
  end;

  if RemainLen > 0 then CopyMatch(Limit);

  PbMask := (LongWord(1) shl pb) - 1;
  LpMask := (LongWord(1) shl lp) - 1;
  while DicPos < Limit do
  begin
    if FOverrun then Exit(lsInputEof);
    if (FInLen - FInPos < LZMA_REQUIRED_INPUT_MAX) and not FSrcEof then FillInput;
    if FInLen - FInPos >= LZMA_REQUIRED_INPUT_MAX then
    begin
      case DecodeFast(Limit) of
        1: begin
             FFinished := True;
             Exit(lsEndMark);
           end;
        2: Exit(lsError);
      end;
      Continue;
    end;
    PosState := LongWord(TotalPos) and PbMask;
    if Bit(IsMatch[(State shl kNumPosBitsMax) + PosState]) = 0 then
    begin
      // Literal
      if TotalPos = 0 then PrevByte := 0
      else if DicPos > 0 then PrevByte := Dict[DicPos - 1]
      else PrevByte := Dict[DictSize - 1];
      LitProbs := @Literals[$300 * (((LongWord(TotalPos) and LpMask) shl lc) + (LongWord(PrevByte) shr (8 - lc)))];
      Symbol := 1;
      if State >= 7 then
      begin
        Src := DicPos - SizeInt(Rep0) - 1;
        if Src < 0 then Inc(Src, DictSize);
        MatchByte := Dict[Src];
        repeat
          MatchBit := (MatchByte shr 7) and 1;
          MatchByte := MatchByte shl 1;
          b := Bit(LitProbs[((1 + MatchBit) shl 8) + Symbol]);
          Symbol := (Symbol shl 1) or b;
          if MatchBit <> b then Break;
        until Symbol >= $100;
      end;
      while Symbol < $100 do
        Symbol := (Symbol shl 1) or Bit(LitProbs[Symbol]);
      Dict[DicPos] := Byte(Symbol - $100);
      Inc(DicPos);
      Inc(TotalPos);
      if State < 4 then State := 0
      else if State < 10 then State := State - 3
      else State := State - 6;
      Continue;
    end;

    if Bit(IsRep[State]) <> 0 then
    begin
      if TotalPos = 0 then Exit(lsError);
      if Bit(IsRepG0[State]) = 0 then
      begin
        if Bit(IsRep0Long[(State shl kNumPosBitsMax) + PosState]) = 0 then
        begin
          // "Short rep": un solo byte desde rep0
          if State < 7 then State := 9 else State := 11;
          RemainLen := 1;
          CopyMatch(Limit);
          Continue;
        end;
      end
      else
      begin
        if Bit(IsRepG1[State]) = 0 then
          Dist := Rep1
        else
        begin
          if Bit(IsRepG2[State]) = 0 then
            Dist := Rep2
          else
          begin
            Dist := Rep3;
            Rep3 := Rep2;
          end;
          Rep2 := Rep1;
        end;
        Rep1 := Rep0;
        Rep0 := Dist;
      end;
      Len := LenDecode(RepLenDec, PosState);
      if State < 7 then State := 8 else State := 11;
    end
    else
    begin
      Rep3 := Rep2; Rep2 := Rep1; Rep1 := Rep0;
      Len := LenDecode(LenDec, PosState);
      if State < 7 then State := 7 else State := 10;
      Rep0 := DecodeDistance(Len);
      if Rep0 = $FFFFFFFF then
      begin
        FFinished := True;
        if FOverrun then Exit(lsInputEof);
        Exit(lsEndMark);
      end;
      if (QWord(Rep0) >= TotalPos) or (SizeInt(Rep0) >= DictSize) then Exit(lsError);
    end;
    RemainLen := Len + kMatchMinLen;
    CopyMatch(Limit);
  end;
  if FOverrun then Exit(lsInputEof);
  Result := lsLimit;
end;

{ TLzmaStage }

constructor TLzmaStage.Create(ASource: TInStage; Alc, Alp, Apb: Integer; ADictSize: QWord);
var
  n: SizeInt;
begin
  // Validar antes de adoptar ASource: si el constructor falla, FPC llama a Destroy, y la
  // cadena que nos creó también liberaría ASource (doble liberación)
  if not ValidLzmaProps(Alc, Alp, Apb) then Corrupt('invalid lzma properties');
  if ADictSize > QWord(High(SizeInt) div 2) then Corrupt('diccionario lzma demasiado grande');
  inherited Create(ASource);
  n := ADictSize;
  if n < 4096 then n := 4096;
  SetLength(FDictBuf, n);
  FDec := TLzmaDecoder.Create(Alc, Alp, Apb, @FDictBuf[0], n, ASource);
end;

destructor TLzmaStage.Destroy;
begin
  FDec.Free;
  inherited Destroy;
end;

function TLzmaStage.Read(Buf: PByte; Count: SizeInt): SizeInt;
const
  CHUNK = 1 shl 20;
var
  Limit: SizeInt;
  st: TLzmaStatus;
begin
  Result := 0;
  if Count <= 0 then Exit;
  while FReadPos >= FDec.DicPos do
  begin
    if FEnded then Exit(0);
    if FDec.DicPos = FDec.DictSize then
    begin
      // Todo lo del diccionario ya se entregó: se puede reciclar desde el principio
      FDec.DicPos := 0;
      FReadPos := 0;
    end;
    Limit := FDec.DicPos + CHUNK;
    if Limit > FDec.DictSize then Limit := FDec.DictSize;
    st := FDec.DecodeTo(Limit);
    case st of
      lsEndMark: FEnded := True;
      lsError: Corrupt('invalid lzma data');
      lsInputEof: Corrupt('stream lzma truncado');
      lsLimit: ;
    end;
  end;
  Result := FDec.DicPos - FReadPos;
  if Result > Count then Result := Count;
  Move(FDictBuf[FReadPos], Buf^, Result);
  Inc(FReadPos, Result);
end;

{ Memoria-a-memoria }

function LzmaDecodeRaw(Src: PByte; SrcLen: SizeInt; Dst: PByte; DstLen: SizeInt;
  lc, lp, pb: Integer; out DstWritten: SizeInt): TLzmaResult;
var
  Input: TMemStage;
  Dec: TLzmaDecoder;
begin
  DstWritten := 0;
  if not ValidLzmaProps(lc, lp, pb) then Exit(lzBadProps);
  if DstLen = 0 then Exit(lzOk);
  Input := TMemStage.Create(Src, SrcLen);
  Dec := TLzmaDecoder.Create(lc, lp, pb, Dst, DstLen, Input);
  try
    case Dec.DecodeTo(DstLen) of
      lsLimit, lsEndMark: Result := lzOk;
      lsInputEof: Result := lzInputEof;
    else
      Result := lzDataError;
    end;
    DstWritten := Dec.DicPos;
  finally
    Dec.Free;
    Input.Free;
  end;
end;

end.
