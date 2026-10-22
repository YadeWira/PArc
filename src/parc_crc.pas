{ CRC-32 IEEE (poli 0xEDB88320), igual al UpdateCRC de FreeArc y a zlib.crc32.
  "Slicing-by-16": 16 tablas procesan 16 bytes por iteración en vez de 1 (el mismo resultado,
  varias veces más rápido), con lecturas de 32 bits: las plataformas de PArc (x86, x64) son
  little-endian y leen sin alinear sin costo. En big-endian se usa el camino de a un byte.
  En x86-64 con PCLMULQDQ (se mira con CPUID al arrancar) los tramos largos se pliegan con
  multiplicación sin acarreo, 64 bytes por vuelta (Intel, "Fast CRC Computation for Generic
  Polynomials Using PCLMULQDQ"; mismas constantes que crc32-pclmul de Linux): el mismo CRC,
  varias veces más rápido. Sin la instrucción, o en 32 bits, quedan las tablas. }
unit parc_crc;

{$mode objfpc}{$H+}
{$R-}{$Q-}
{$IFDEF CPUX86_64}{$ASMMODE INTEL}{$ENDIF}

interface

const
  CRC_INIT = $FFFFFFFF;

function UpdateCRC(Crc: LongWord; Data: PByte; Len: SizeUInt): LongWord;
function CalcCRC(Data: PByte; Len: SizeUInt): LongWord;

{ Solo las tablas (para pruebas y comparaciones). }
function UpdateCRCTable(Crc: LongWord; Data: PByte; Len: SizeUInt): LongWord;
{ ¿Se usa el plegado con PCLMULQDQ? (PARC_CRC=table lo apaga, para medir) }
function CRCUsesPclmul: Boolean;

implementation

uses
  SysUtils;

var
  T: array[0..15, Byte] of LongWord;

procedure InitTables;
var
  i, k: Integer;
  r: LongWord;
begin
  for i := 0 to 255 do
  begin
    r := i;
    for k := 1 to 8 do
      if (r and 1) <> 0 then r := (r shr 1) xor $EDB88320
      else r := r shr 1;
    T[0][i] := r;
  end;
  // T[k][i] = CRC de i seguido de k bytes en cero
  for i := 0 to 255 do
    for k := 1 to 15 do
      T[k][i] := (T[k - 1][i] shr 8) xor T[0][T[k - 1][i] and $FF];
end;

function UpdateCRCTable(Crc: LongWord; Data: PByte; Len: SizeUInt): LongWord;
{$IFDEF ENDIAN_LITTLE}
var
  a, b, c, d: LongWord;
begin
  while Len >= 16 do
  begin
    a := Crc xor PLongWord(Data)^;
    b := PLongWord(Data + 4)^;
    c := PLongWord(Data + 8)^;
    d := PLongWord(Data + 12)^;
    Crc := T[15][a and $FF] xor T[14][(a shr 8) and $FF] xor
           T[13][(a shr 16) and $FF] xor T[12][a shr 24] xor
           T[11][b and $FF] xor T[10][(b shr 8) and $FF] xor
           T[9][(b shr 16) and $FF] xor T[8][b shr 24] xor
           T[7][c and $FF] xor T[6][(c shr 8) and $FF] xor
           T[5][(c shr 16) and $FF] xor T[4][c shr 24] xor
           T[3][d and $FF] xor T[2][(d shr 8) and $FF] xor
           T[1][(d shr 16) and $FF] xor T[0][d shr 24];
    Inc(Data, 16);
    Dec(Len, 16);
  end;
{$ELSE}
begin
{$ENDIF}
  while Len > 0 do
  begin
    Crc := T[0][Byte(Crc) xor Data^] xor (Crc shr 8);
    Inc(Data);
    Dec(Len);
  end;
  Result := Crc;
end;

{$IFDEF CPUX86_64}
const
  PCLMUL_MIN = 128;   // por debajo, las tablas (el plegado tiene un costo fijo)

var
  UsePclmul: Boolean = False;
  // Constantes del plegado (cada una, 128 bits: mitad baja, mitad alta)
  CrcK: array[0..9] of QWord = (
    $0000000154442BD4, $00000001C6E41596,   // R1, R2: plegar 512 bits
    $00000001751997D0, $00000000CCAA009E,   // R3, R4: plegar 128 bits
    $0000000163CD6124, $0000000000000000,   // R5: de 64 a 32 bits
    $00000000FFFFFFFF, $0000000000000000,   // máscara de 32 bits
    $00000001DB710641, $00000001F7011641);  // P' y µ (Barrett)

function CpuHasPclmul: Boolean;
var
  r: LongWord;
begin
  asm
    mov eax, 1
    cpuid
    mov r, ecx
  end ['rax', 'rbx', 'rcx', 'rdx'];
  Result := (r and 2) <> 0;   // CPUID.1:ECX.PCLMULQDQ[bit 1] (SSE2 siempre está en x86-64)
end;

{ Crc (sin invertir, como UpdateCRC) de Len bytes, Len >= 64 y múltiplo de 16. PCLMULQDQ va
  codificada a mano (66 0F 3A 44 /r ib): el ensamblador de FPC 3.2.2 no la conoce. Solo usa
  registros volátiles en las dos convenciones (System V y Win64: xmm0-xmm5, rax, rcx, rdx,
  r8-r11), así que no hay nada que guardar. }
function CrcFold(Crc: LongWord; Data: PByte; Len: SizeUInt; K: Pointer): LongWord; assembler; nostackframe;
asm
  {$IFDEF WIN64}
  mov r10d, ecx
  mov r11, rdx
  {$ELSE}
  mov r10d, edi
  mov r11, rsi
  mov r8, rdx
  mov r9, rcx
  {$ENDIF}
  // r10d = crc, r11 = datos, r8 = largo, r9 = constantes
  movdqu xmm1, [r11]
  movdqu xmm2, [r11 + 16]
  movdqu xmm3, [r11 + 32]
  movdqu xmm4, [r11 + 48]
  movd xmm0, r10d
  pxor xmm1, xmm0
  add r11, 64
  sub r8, 64
  cmp r8, 64
  jb @less64
  movdqu xmm0, [r9]               // R2:R1
@loop64:
  movdqa xmm5, xmm1
  db $66, $0F, $3A, $44, $C8, $00   // pclmulqdq xmm1, xmm0, $00
  db $66, $0F, $3A, $44, $E8, $11   // pclmulqdq xmm5, xmm0, $11
  pxor xmm1, xmm5
  movdqu xmm5, [r11]
  pxor xmm1, xmm5
  movdqa xmm5, xmm2
  db $66, $0F, $3A, $44, $D0, $00   // pclmulqdq xmm2, xmm0, $00
  db $66, $0F, $3A, $44, $E8, $11   // pclmulqdq xmm5, xmm0, $11
  pxor xmm2, xmm5
  movdqu xmm5, [r11 + 16]
  pxor xmm2, xmm5
  movdqa xmm5, xmm3
  db $66, $0F, $3A, $44, $D8, $00   // pclmulqdq xmm3, xmm0, $00
  db $66, $0F, $3A, $44, $E8, $11   // pclmulqdq xmm5, xmm0, $11
  pxor xmm3, xmm5
  movdqu xmm5, [r11 + 32]
  pxor xmm3, xmm5
  movdqa xmm5, xmm4
  db $66, $0F, $3A, $44, $E0, $00   // pclmulqdq xmm4, xmm0, $00
  db $66, $0F, $3A, $44, $E8, $11   // pclmulqdq xmm5, xmm0, $11
  pxor xmm4, xmm5
  movdqu xmm5, [r11 + 48]
  pxor xmm4, xmm5
  add r11, 64
  sub r8, 64
  cmp r8, 64
  jae @loop64
@less64:
  // los cuatro acumuladores en uno
  movdqu xmm0, [r9 + 16]          // R4:R3
  movdqa xmm5, xmm1
  db $66, $0F, $3A, $44, $C8, $00   // pclmulqdq xmm1, xmm0, $00
  db $66, $0F, $3A, $44, $E8, $11   // pclmulqdq xmm5, xmm0, $11
  pxor xmm1, xmm5
  pxor xmm1, xmm2
  movdqa xmm5, xmm1
  db $66, $0F, $3A, $44, $C8, $00   // pclmulqdq xmm1, xmm0, $00
  db $66, $0F, $3A, $44, $E8, $11   // pclmulqdq xmm5, xmm0, $11
  pxor xmm1, xmm5
  pxor xmm1, xmm3
  movdqa xmm5, xmm1
  db $66, $0F, $3A, $44, $C8, $00   // pclmulqdq xmm1, xmm0, $00
  db $66, $0F, $3A, $44, $E8, $11   // pclmulqdq xmm5, xmm0, $11
  pxor xmm1, xmm5
  pxor xmm1, xmm4
  cmp r8, 16
  jb @fold64
@loop16:
  movdqa xmm5, xmm1
  db $66, $0F, $3A, $44, $C8, $00   // pclmulqdq xmm1, xmm0, $00
  db $66, $0F, $3A, $44, $E8, $11   // pclmulqdq xmm5, xmm0, $11
  pxor xmm1, xmm5
  movdqu xmm5, [r11]
  pxor xmm1, xmm5
  add r11, 16
  sub r8, 16
  cmp r8, 16
  jae @loop16
@fold64:
  // de 128 a 64 bits (agrega 32 ceros al final)
  db $66, $0F, $3A, $44, $C1, $01   // pclmulqdq xmm0, xmm1, $01 (R4 * xmm1.bajo)
  psrldq xmm1, 8
  pxor xmm1, xmm0
  // de 64 a 32 bits
  movdqa xmm2, xmm1
  movdqu xmm0, [r9 + 32]          // R5
  movdqu xmm3, [r9 + 48]          // máscara
  psrldq xmm2, 4
  pand xmm1, xmm3
  db $66, $0F, $3A, $44, $C8, $00   // pclmulqdq xmm1, xmm0, $00
  pxor xmm1, xmm2
  // reducción de Barrett (bits invertidos), 64 -> 32
  movdqu xmm0, [r9 + 64]          // µ:P'
  movdqa xmm2, xmm1
  pand xmm1, xmm3
  db $66, $0F, $3A, $44, $C8, $10   // pclmulqdq xmm1, xmm0, $10
  pand xmm1, xmm3
  db $66, $0F, $3A, $44, $C8, $00   // pclmulqdq xmm1, xmm0, $00
  pxor xmm1, xmm2
  psrldq xmm1, 4
  movd eax, xmm1
end;
{$ENDIF}

function UpdateCRC(Crc: LongWord; Data: PByte; Len: SizeUInt): LongWord;
{$IFDEF CPUX86_64}
var
  n: SizeUInt;
{$ENDIF}
begin
  {$IFDEF CPUX86_64}
  if UsePclmul and (Len >= PCLMUL_MIN) then
  begin
    n := Len and not SizeUInt(15);
    Crc := CrcFold(Crc, Data, n, @CrcK[0]);
    Inc(Data, n);
    Dec(Len, n);
  end;
  {$ENDIF}
  Result := UpdateCRCTable(Crc, Data, Len);
end;

function CalcCRC(Data: PByte; Len: SizeUInt): LongWord;
begin
  Result := UpdateCRC(CRC_INIT, Data, Len) xor CRC_INIT;
end;

function CRCUsesPclmul: Boolean;
begin
  {$IFDEF CPUX86_64}Result := UsePclmul;{$ELSE}Result := False;{$ENDIF}
end;

initialization
  InitTables;
  {$IFDEF CPUX86_64}
  UsePclmul := CpuHasPclmul and (GetEnvironmentVariable('PARC_CRC') <> 'table');
  {$ENDIF}
end.
