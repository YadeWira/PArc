{ parc_aes — AES-256 (FIPS 197, sólo cifrado) y AES-256-GCM (NIST SP 800-38D) con nonce de
  96 bits y etiqueta de 128 bits.

  Código propio escrito a partir de las especificaciones.

  - x86-64 con AES-NI y PCLMULQDQ (CPUID, al arrancar): expansión de la clave con
    AESKEYGENASSIST, CTR de a 8 bloques y GHASH de a 4 bloques con las potencias H..H^4 y
    una sola reducción (multiplicación sin acarreo de los bloques con los bytes invertidos,
    corrimiento de 1 bit y reducción módulo x^128 + x^7 + x^2 + x + 1). PCLMULQDQ va
    codificada a mano: el ensamblador de FPC 3.2.2 no la conoce.
  - Camino portable (i386, aarch64, CPUs sin AES-NI, PARC_NOASM o PARC_CRYPT=pas):
    AES con tablas T (cuatro de 256 palabras generadas al arrancar a partir de la S-box, que
    se calcula con la inversa en GF(2^8) y la transformación afín). OJO: NO es de tiempo
    constante, los índices de las tablas dependen de la clave y de los datos (canal lateral de
    caché si un atacante corre código en la misma máquina mientras se cifra). GHASH sí es de
    tiempo constante: multiplicación sin acarreo de 64x64 bits con enteros y "huecos" (cada
    cuarto bit), sin tablas.
  Los dos caminos dan exactamente lo mismo. }
unit parc_aes;

{$mode objfpc}{$H+}
{$R-}{$Q-}
{$IFDEF CPUX86_64}{$ASMMODE INTEL}{$ENDIF}
{$IF defined(CPUX86_64) and not defined(PARC_NOASM)}{$DEFINE AES_ASM}{$ENDIF}

interface

type
  { Clave de AES-256-GCM ya preparada (sub-claves de ronda y potencias de H). Los offsets de
    los campos son los que usa el ensamblador. }
  TAesGcmKey = record
    RkB: array[0..239] of Byte;          // 0: sub-claves en el orden de bytes de FIPS 197
    Pad0: array[0..15] of Byte;          // 240
    HPow: array[0..3, 0..15] of Byte;    // 256: H^1..H^4 con los bytes invertidos (asm)
    BSwap: array[0..15] of Byte;         // 320: máscara de pshufb que invierte los 16 bytes
    One: array[0..15] of Byte;           // 336: 1 en la palabra baja (contador)
    Save: array[0..19] of QWord;         // 352: xmm6..xmm15 (Win64)
    Rk: array[0..59] of LongWord;        // camino portable: palabras big-endian
    H0, H1: QWord;                       // camino portable: H en orden natural (bit i = x^i)
    Asm_: Boolean;
  end;
  PAesGcmKey = ^TAesGcmKey;

procedure AesGcmInit(out K: TAesGcmKey; Key32: PByte);
procedure AesGcmClear(var K: TAesGcmKey);
{ Seal: Dst := cifrado de Src, Tag := etiqueta de 16 bytes. Open comprueba la etiqueta antes
  de descifrar y, si no coincide, devuelve False sin tocar Dst. Src y Dst pueden coincidir. }
procedure AesGcmSeal(const K: TAesGcmKey; Nonce12, AD: PByte; ADLen: SizeInt; Src, Dst: PByte;
                     Len: SizeInt; Tag: PByte);
function  AesGcmOpen(const K: TAesGcmKey; Nonce12, AD: PByte; ADLen: SizeInt; Src, Dst: PByte;
                     Len: SizeInt; Tag: PByte): Boolean;

{ Un bloque de AES-256 (para los vectores de FIPS 197). }
procedure Aes256EncryptBlock(Key32, Src16, Dst16: PByte);

{ ¿Se usan AES-NI y PCLMULQDQ? }
function AesUsesNI: Boolean;

implementation

uses
  SysUtils;

var
  SBox: array[0..255] of Byte;
  Te0, Te1, Te2, Te3: array[0..255] of LongWord;
  UseNI: Boolean = False;

function Ror32(x: LongWord; n: Integer): LongWord; inline;
begin
  Result := (x shr n) or (x shl (32 - n));
end;

function LoadBE32(p: PByte): LongWord; inline;
begin
  Result := (LongWord(p[0]) shl 24) or (LongWord(p[1]) shl 16) or (LongWord(p[2]) shl 8) or LongWord(p[3]);
end;

procedure StoreBE32(p: PByte; v: LongWord); inline;
begin
  p[0] := Byte(v shr 24); p[1] := Byte(v shr 16); p[2] := Byte(v shr 8); p[3] := Byte(v);
end;

function LoadLE64(p: PByte): QWord; inline;
var
  i: Integer;
begin
  Result := 0;
  for i := 7 downto 0 do Result := (Result shl 8) or p[i];
end;

procedure StoreLE64(p: PByte; v: QWord); inline;
var
  i: Integer;
begin
  for i := 0 to 7 do begin p[i] := Byte(v); v := v shr 8; end;
end;

procedure StoreBE64(p: PByte; v: QWord); inline;
var
  i: Integer;
begin
  for i := 7 downto 0 do begin p[i] := Byte(v); v := v shr 8; end;
end;

{ S-box (FIPS 197 §5.1.1) y tablas T, calculadas: inversa multiplicativa en GF(2^8) con las
  tablas de potencias de 3 y transformación afín. }
procedure InitTables;
var
  Pow, Lg: array[0..255] of Byte;
  i: Integer;
  x, b, s: Byte;
  s2, s3: LongWord;
begin
  x := 1;
  for i := 0 to 254 do
  begin
    Pow[i] := x;
    Lg[x] := i;
    // x·3 = x·2 xor x
    if x and $80 <> 0 then x := Byte((x shl 1) xor $1B xor x) else x := Byte((x shl 1) xor x);
  end;
  for i := 0 to 255 do
  begin
    if i = 0 then b := 0 else b := Pow[(255 - Lg[i]) mod 255];
    s := b xor Byte((b shl 1) or (b shr 7)) xor Byte((b shl 2) or (b shr 6)) xor
         Byte((b shl 3) or (b shr 5)) xor Byte((b shl 4) or (b shr 4)) xor $63;
    SBox[i] := s;
  end;
  for i := 0 to 255 do
  begin
    s := SBox[i];
    if s and $80 <> 0 then s2 := Byte((s shl 1) xor $1B) else s2 := Byte(s shl 1);
    s3 := s2 xor s;
    Te0[i] := (s2 shl 24) or (LongWord(s) shl 16) or (LongWord(s) shl 8) or s3;
    Te1[i] := Ror32(Te0[i], 8);
    Te2[i] := Ror32(Te0[i], 16);
    Te3[i] := Ror32(Te0[i], 24);
  end;
end;

function SubWord(w: LongWord): LongWord; inline;
begin
  Result := (LongWord(SBox[w shr 24]) shl 24) or (LongWord(SBox[(w shr 16) and 255]) shl 16) or
            (LongWord(SBox[(w shr 8) and 255]) shl 8) or SBox[w and 255];
end;

{ Expansión de la clave de AES-256 (FIPS 197 §5.2): Nk = 8, Nr = 14, 60 palabras. }
procedure ExpandKey(Key: PByte; out Rk: array of LongWord);
var
  i: Integer;
  t, rcon: LongWord;
begin
  for i := 0 to 7 do Rk[i] := LoadBE32(Key + 4 * i);
  rcon := $01000000;
  for i := 8 to 59 do
  begin
    t := Rk[i - 1];
    if i mod 8 = 0 then
    begin
      t := SubWord((t shl 8) or (t shr 24)) xor rcon;
      if rcon and $80000000 <> 0 then rcon := (rcon shl 1) xor $1B000000 else rcon := rcon shl 1;
    end
    else if i mod 8 = 4 then
      t := SubWord(t);
    Rk[i] := Rk[i - 8] xor t;
  end;
end;

procedure EncBlockPas(const Rk: array of LongWord; Src, Dst: PByte);
var
  s0, s1, s2, s3, t0, t1, t2, t3: LongWord;
  r: Integer;
begin
  s0 := LoadBE32(Src) xor Rk[0];
  s1 := LoadBE32(Src + 4) xor Rk[1];
  s2 := LoadBE32(Src + 8) xor Rk[2];
  s3 := LoadBE32(Src + 12) xor Rk[3];
  for r := 1 to 13 do
  begin
    t0 := Te0[s0 shr 24] xor Te1[(s1 shr 16) and 255] xor Te2[(s2 shr 8) and 255] xor Te3[s3 and 255] xor Rk[4 * r];
    t1 := Te0[s1 shr 24] xor Te1[(s2 shr 16) and 255] xor Te2[(s3 shr 8) and 255] xor Te3[s0 and 255] xor Rk[4 * r + 1];
    t2 := Te0[s2 shr 24] xor Te1[(s3 shr 16) and 255] xor Te2[(s0 shr 8) and 255] xor Te3[s1 and 255] xor Rk[4 * r + 2];
    t3 := Te0[s3 shr 24] xor Te1[(s0 shr 16) and 255] xor Te2[(s1 shr 8) and 255] xor Te3[s2 and 255] xor Rk[4 * r + 3];
    s0 := t0; s1 := t1; s2 := t2; s3 := t3;
  end;
  // última ronda: SubBytes + ShiftRows (sin MixColumns)
  t0 := (LongWord(SBox[s0 shr 24]) shl 24) or (LongWord(SBox[(s1 shr 16) and 255]) shl 16) or
        (LongWord(SBox[(s2 shr 8) and 255]) shl 8) or SBox[s3 and 255];
  t1 := (LongWord(SBox[s1 shr 24]) shl 24) or (LongWord(SBox[(s2 shr 16) and 255]) shl 16) or
        (LongWord(SBox[(s3 shr 8) and 255]) shl 8) or SBox[s0 and 255];
  t2 := (LongWord(SBox[s2 shr 24]) shl 24) or (LongWord(SBox[(s3 shr 16) and 255]) shl 16) or
        (LongWord(SBox[(s0 shr 8) and 255]) shl 8) or SBox[s1 and 255];
  t3 := (LongWord(SBox[s3 shr 24]) shl 24) or (LongWord(SBox[(s0 shr 16) and 255]) shl 16) or
        (LongWord(SBox[(s1 shr 8) and 255]) shl 8) or SBox[s2 and 255];
  StoreBE32(Dst, t0 xor Rk[56]);
  StoreBE32(Dst + 4, t1 xor Rk[57]);
  StoreBE32(Dst + 8, t2 xor Rk[58]);
  StoreBE32(Dst + 12, t3 xor Rk[59]);
end;

{ ------------------------------------------------------- GHASH portable (tiempo constante) }

{ 64 bits bajos del producto sin acarreo: cada operando partido en 4 clases de bits (i mod 4)
  con 3 bits vacíos entre cada uno; en cada producto entero las sumas de una posición no pasan
  de 15, así que no se pisan con la siguiente posición de la misma clase. }
function Bmul64(x, y: QWord): QWord;
const
  M0 = QWord($1111111111111111); M1 = QWord($2222222222222222);
  M2 = QWord($4444444444444444); M3 = QWord($8888888888888888);
var
  x0, x1, x2, x3, y0, y1, y2, y3, z0, z1, z2, z3: QWord;
begin
  x0 := x and M0; x1 := x and M1; x2 := x and M2; x3 := x and M3;
  y0 := y and M0; y1 := y and M1; y2 := y and M2; y3 := y and M3;
  z0 := (x0 * y0) xor (x1 * y3) xor (x2 * y2) xor (x3 * y1);
  z1 := (x0 * y1) xor (x1 * y0) xor (x2 * y3) xor (x3 * y2);
  z2 := (x0 * y2) xor (x1 * y1) xor (x2 * y0) xor (x3 * y3);
  z3 := (x0 * y3) xor (x1 * y2) xor (x2 * y1) xor (x3 * y0);
  Result := (z0 and M0) or (z1 and M1) or (z2 and M2) or (z3 and M3);
end;

{ Invierte el orden de los bits de cada byte. }
function RevBitsInBytes(x: QWord): QWord; inline;
begin
  x := ((x shr 1) and QWord($5555555555555555)) or ((x and QWord($5555555555555555)) shl 1);
  x := ((x shr 2) and QWord($3333333333333333)) or ((x and QWord($3333333333333333)) shl 2);
  x := ((x shr 4) and QWord($0F0F0F0F0F0F0F0F)) or ((x and QWord($0F0F0F0F0F0F0F0F)) shl 4);
  Result := x;
end;

function Rev64(x: QWord): QWord; inline;
begin
  Result := SwapEndian(RevBitsInBytes(x));
end;

{ Producto sin acarreo de 64x64 -> 128 bits: los bits altos salen de multiplicar los operandos
  invertidos (rev(x)·rev(y) = rev127(x·y)). }
procedure Clmul64(x, y: QWord; out Hi, Lo: QWord); inline;
begin
  Lo := Bmul64(x, y);
  Hi := Rev64(Bmul64(Rev64(x), Rev64(y))) shr 1;
end;

{ (A1:A0) := (A1:A0)·(B1:B0) en GF(2^128) en orden natural (bit i de A0 = coeficiente de x^i,
  bit i de A1 = x^(64+i)), módulo x^128 + x^7 + x^2 + x + 1. Karatsuba: tres productos. }
procedure GfMul(var A0, A1: QWord; B0, B1: QWord);
var
  z0h, z0l, z1h, z1l, z2h, z2l, p0, p1, p2, p3, u, r0, r1: QWord;
begin
  Clmul64(A0, B0, z0h, z0l);
  Clmul64(A1, B1, z2h, z2l);
  Clmul64(A0 xor A1, B0 xor B1, z1h, z1l);
  z1l := z1l xor z0l xor z2l;
  z1h := z1h xor z0h xor z2h;
  p0 := z0l;
  p1 := z0h xor z1l;
  p2 := z2l xor z1h;
  p3 := z2h;
  // T = p3:p2 vale T·x^128 = T·(x^7 + x^2 + x + 1); lo que T·x^k desborda vuelve otra vez
  r0 := p0 xor p2 xor (p2 shl 1) xor (p2 shl 2) xor (p2 shl 7);
  r1 := p1 xor p3 xor (p3 shl 1) xor (p2 shr 63) xor (p3 shl 2) xor (p2 shr 62) xor (p3 shl 7) xor (p2 shr 57);
  u := (p3 shr 63) xor (p3 shr 62) xor (p3 shr 57);
  r0 := r0 xor u xor (u shl 1) xor (u shl 2) xor (u shl 7);
  A0 := r0;
  A1 := r1;
end;

procedure GhashPas(const K: TAesGcmKey; var Y0, Y1: QWord; Data: PByte; Blocks: SizeUInt);
begin
  while Blocks > 0 do
  begin
    Y0 := Y0 xor RevBitsInBytes(LoadLE64(Data));
    Y1 := Y1 xor RevBitsInBytes(LoadLE64(Data + 8));
    GfMul(Y0, Y1, K.H0, K.H1);
    Inc(Data, 16);
    Dec(Blocks);
  end;
end;

{ ------------------------------------------------------------------- AES-NI y PCLMULQDQ }

{$IFDEF AES_ASM}
function CpuHasAesNI: Boolean;
var
  r: LongWord;
begin
  asm
    mov eax, 1
    xor ecx, ecx
    cpuid
    mov r, ecx
  end ['rax', 'rbx', 'rcx', 'rdx'];
  // AES-NI (bit 25), PCLMULQDQ (bit 1), SSSE3 (bit 9, pshufb)
  Result := (r and (1 shl 25) <> 0) and (r and 2 <> 0) and (r and (1 shl 9) <> 0);
end;

{ Expansión de la clave de AES-256 con AESKEYGENASSIST (Rk: 240 bytes). Sólo xmm0-xmm4. }
procedure AesniExpand256(Key, Rk: PByte); assembler; nostackframe;
asm
  {$IFDEF WIN64}
  mov r10, rcx
  mov r11, rdx
  {$ELSE}
  mov r10, rdi
  mov r11, rsi
  {$ENDIF}
  movdqu xmm1, [r10]
  movdqu xmm3, [r10 + 16]
  movdqu [r11], xmm1
  movdqu [r11 + 16], xmm3
  aeskeygenassist xmm2, xmm3, $01
  call @a1
  movdqu [r11 + 32], xmm1
  aeskeygenassist xmm2, xmm1, $00
  call @a2
  movdqu [r11 + 48], xmm3
  aeskeygenassist xmm2, xmm3, $02
  call @a1
  movdqu [r11 + 64], xmm1
  aeskeygenassist xmm2, xmm1, $00
  call @a2
  movdqu [r11 + 80], xmm3
  aeskeygenassist xmm2, xmm3, $04
  call @a1
  movdqu [r11 + 96], xmm1
  aeskeygenassist xmm2, xmm1, $00
  call @a2
  movdqu [r11 + 112], xmm3
  aeskeygenassist xmm2, xmm3, $08
  call @a1
  movdqu [r11 + 128], xmm1
  aeskeygenassist xmm2, xmm1, $00
  call @a2
  movdqu [r11 + 144], xmm3
  aeskeygenassist xmm2, xmm3, $10
  call @a1
  movdqu [r11 + 160], xmm1
  aeskeygenassist xmm2, xmm1, $00
  call @a2
  movdqu [r11 + 176], xmm3
  aeskeygenassist xmm2, xmm3, $20
  call @a1
  movdqu [r11 + 192], xmm1
  aeskeygenassist xmm2, xmm1, $00
  call @a2
  movdqu [r11 + 208], xmm3
  aeskeygenassist xmm2, xmm3, $40
  call @a1
  movdqu [r11 + 224], xmm1
  pxor xmm1, xmm1
  pxor xmm2, xmm2
  pxor xmm3, xmm3
  pxor xmm4, xmm4
  ret
  // w[i..i+3] pares: RotWord+SubWord+Rcon de la última palabra de xmm3
@a1:
  pshufd xmm2, xmm2, $ff
  movdqa xmm4, xmm1
  pslldq xmm4, 4
  pxor xmm1, xmm4
  pslldq xmm4, 4
  pxor xmm1, xmm4
  pslldq xmm4, 4
  pxor xmm1, xmm4
  pxor xmm1, xmm2
  ret
  // impares: SubWord (sin rotar ni Rcon) de la última palabra de xmm1
@a2:
  pshufd xmm2, xmm2, $aa
  movdqa xmm4, xmm3
  pslldq xmm4, 4
  pxor xmm3, xmm4
  pslldq xmm4, 4
  pxor xmm3, xmm4
  pslldq xmm4, 4
  pxor xmm3, xmm4
  pxor xmm3, xmm2
end;

{ Un bloque. Sólo xmm0, xmm1. }
procedure AesniEncBlock(Rk, Src, Dst: PByte); assembler; nostackframe;
asm
  {$IFDEF WIN64}
  mov r10, rcx
  mov r11, rdx
  {$ELSE}
  mov r10, rdi
  mov r11, rsi
  mov r8, rdx
  {$ENDIF}
  movdqu xmm0, [r11]
  movdqu xmm1, [r10]
  pxor xmm0, xmm1
  movdqu xmm1, [r10 + 16]
  aesenc xmm0, xmm1
  movdqu xmm1, [r10 + 32]
  aesenc xmm0, xmm1
  movdqu xmm1, [r10 + 48]
  aesenc xmm0, xmm1
  movdqu xmm1, [r10 + 64]
  aesenc xmm0, xmm1
  movdqu xmm1, [r10 + 80]
  aesenc xmm0, xmm1
  movdqu xmm1, [r10 + 96]
  aesenc xmm0, xmm1
  movdqu xmm1, [r10 + 112]
  aesenc xmm0, xmm1
  movdqu xmm1, [r10 + 128]
  aesenc xmm0, xmm1
  movdqu xmm1, [r10 + 144]
  aesenc xmm0, xmm1
  movdqu xmm1, [r10 + 160]
  aesenc xmm0, xmm1
  movdqu xmm1, [r10 + 176]
  aesenc xmm0, xmm1
  movdqu xmm1, [r10 + 192]
  aesenc xmm0, xmm1
  movdqu xmm1, [r10 + 208]
  aesenc xmm0, xmm1
  movdqu xmm1, [r10 + 224]
  aesenclast xmm0, xmm1
  movdqu [r8], xmm0
end;

{ CTR: Blocks bloques enteros; Ctr = bloque contador (16 bytes; inc32 en los 4 últimos, big
  endian), se actualiza. Ctx = TAesGcmKey. }
procedure AesniCtr(Ctx, Ctr, Src, Dst: PByte; Blocks: SizeUInt); assembler; nostackframe;
asm
  {$IFDEF WIN64}
  movdqu [rcx + 352], xmm6
  movdqu [rcx + 368], xmm7
  movdqu [rcx + 384], xmm8
  movdqu [rcx + 400], xmm9
  movdqu [rcx + 416], xmm10
  movdqu [rcx + 432], xmm11
  movdqu [rcx + 448], xmm12
  movdqu [rcx + 464], xmm13
  movdqu [rcx + 480], xmm14
  movdqu [rcx + 496], xmm15
  mov r10, rcx
  mov rax, rdx
  mov r11, r8
  mov r8, r9
  mov r9, [rsp + 40]
  {$ELSE}
  mov r10, rdi
  mov rax, rsi
  mov r11, rdx
  mov r9, r8
  mov r8, rcx
  {$ENDIF}
  // r10 = ctx, rax = contador, r11 = src, r8 = dst, r9 = bloques
  movdqu xmm15, [r10 + 320]
  movdqu xmm13, [r10 + 336]
  movdqu xmm14, [rax]
  pshufb xmm14, xmm15              // contador como entero en la palabra baja
  cmp r9, 8
  jb @one
@eight:
  movdqa xmm0, xmm14
  paddd xmm14, xmm13
  movdqa xmm1, xmm14
  paddd xmm14, xmm13
  movdqa xmm2, xmm14
  paddd xmm14, xmm13
  movdqa xmm3, xmm14
  paddd xmm14, xmm13
  movdqa xmm4, xmm14
  paddd xmm14, xmm13
  movdqa xmm5, xmm14
  paddd xmm14, xmm13
  movdqa xmm6, xmm14
  paddd xmm14, xmm13
  movdqa xmm7, xmm14
  paddd xmm14, xmm13
  movdqu xmm8, [r10]
  pshufb xmm0, xmm15
  pshufb xmm1, xmm15
  pshufb xmm2, xmm15
  pshufb xmm3, xmm15
  pshufb xmm4, xmm15
  pshufb xmm5, xmm15
  pshufb xmm6, xmm15
  pshufb xmm7, xmm15
  pxor xmm0, xmm8
  pxor xmm1, xmm8
  pxor xmm2, xmm8
  pxor xmm3, xmm8
  pxor xmm4, xmm8
  pxor xmm5, xmm8
  pxor xmm6, xmm8
  pxor xmm7, xmm8
  mov rcx, 16
@rounds8:
  movdqu xmm8, [r10 + rcx]
  aesenc xmm0, xmm8
  aesenc xmm1, xmm8
  aesenc xmm2, xmm8
  aesenc xmm3, xmm8
  aesenc xmm4, xmm8
  aesenc xmm5, xmm8
  aesenc xmm6, xmm8
  aesenc xmm7, xmm8
  add rcx, 16
  cmp rcx, 224
  jb @rounds8
  movdqu xmm8, [r10 + 224]
  aesenclast xmm0, xmm8
  aesenclast xmm1, xmm8
  aesenclast xmm2, xmm8
  aesenclast xmm3, xmm8
  aesenclast xmm4, xmm8
  aesenclast xmm5, xmm8
  aesenclast xmm6, xmm8
  aesenclast xmm7, xmm8
  movdqu xmm8, [r11]
  pxor xmm0, xmm8
  movdqu [r8], xmm0
  movdqu xmm8, [r11 + 16]
  pxor xmm1, xmm8
  movdqu [r8 + 16], xmm1
  movdqu xmm8, [r11 + 32]
  pxor xmm2, xmm8
  movdqu [r8 + 32], xmm2
  movdqu xmm8, [r11 + 48]
  pxor xmm3, xmm8
  movdqu [r8 + 48], xmm3
  movdqu xmm8, [r11 + 64]
  pxor xmm4, xmm8
  movdqu [r8 + 64], xmm4
  movdqu xmm8, [r11 + 80]
  pxor xmm5, xmm8
  movdqu [r8 + 80], xmm5
  movdqu xmm8, [r11 + 96]
  pxor xmm6, xmm8
  movdqu [r8 + 96], xmm6
  movdqu xmm8, [r11 + 112]
  pxor xmm7, xmm8
  movdqu [r8 + 112], xmm7
  add r11, 128
  add r8, 128
  sub r9, 8
  cmp r9, 8
  jae @eight
@one:
  test r9, r9
  jz @done
  movdqa xmm0, xmm14
  paddd xmm14, xmm13
  pshufb xmm0, xmm15
  movdqu xmm8, [r10]
  pxor xmm0, xmm8
  mov rcx, 16
@rounds1:
  movdqu xmm8, [r10 + rcx]
  aesenc xmm0, xmm8
  add rcx, 16
  cmp rcx, 224
  jb @rounds1
  movdqu xmm8, [r10 + 224]
  aesenclast xmm0, xmm8
  movdqu xmm8, [r11]
  pxor xmm0, xmm8
  movdqu [r8], xmm0
  add r11, 16
  add r8, 16
  dec r9
  jmp @one
@done:
  pshufb xmm14, xmm15
  movdqu [rax], xmm14
  {$IFDEF WIN64}
  movdqu xmm6, [r10 + 352]
  movdqu xmm7, [r10 + 368]
  movdqu xmm8, [r10 + 384]
  movdqu xmm9, [r10 + 400]
  movdqu xmm10, [r10 + 416]
  movdqu xmm11, [r10 + 432]
  movdqu xmm12, [r10 + 448]
  movdqu xmm13, [r10 + 464]
  movdqu xmm14, [r10 + 480]
  movdqu xmm15, [r10 + 496]
  {$ENDIF}
end;

{ GHASH de Blocks bloques sobre Y (16 bytes en el orden de GCM, se actualiza), con H..H^4 de
  Ctx.HPow. De a 4 bloques: Y·H^4 + X2·H^3 + X3·H^2 + X4·H con una sola reducción. }
procedure ClmulGhash(Ctx, Y, Data: PByte; Blocks: SizeUInt); assembler; nostackframe;
asm
  {$IFDEF WIN64}
  movdqu [rcx + 352], xmm6
  movdqu [rcx + 368], xmm7
  movdqu [rcx + 384], xmm8
  movdqu [rcx + 400], xmm9
  movdqu [rcx + 416], xmm10
  movdqu [rcx + 432], xmm11
  movdqu [rcx + 448], xmm12
  movdqu [rcx + 464], xmm13
  movdqu [rcx + 480], xmm14
  movdqu [rcx + 496], xmm15
  mov r10, rcx
  mov rax, rdx
  mov r11, r8
  {$ELSE}
  mov r10, rdi
  mov rax, rsi
  mov r11, rdx
  mov r9, rcx
  {$ENDIF}
  // r10 = ctx, rax = Y, r11 = datos, r9 = bloques
  movdqu xmm15, [r10 + 320]
  movdqu xmm14, [rax]
  pshufb xmm14, xmm15
  cmp r9, 4
  jb @one
@four:
  movdqu xmm0, [r11 + 0]
  pshufb xmm0, xmm15
  movdqu xmm1, [r11 + 16]
  pshufb xmm1, xmm15
  movdqu xmm2, [r11 + 32]
  pshufb xmm2, xmm15
  movdqu xmm3, [r11 + 48]
  pshufb xmm3, xmm15
  pxor xmm0, xmm14
  movdqu xmm8, [r10 + 304]
  movdqa xmm4, xmm0
  db $66, $41, $0F, $3A, $44, $E0, $00   // pclmulqdq xmm4, xmm8, $00
  movdqa xmm5, xmm0
  db $66, $41, $0F, $3A, $44, $E8, $11   // pclmulqdq xmm5, xmm8, $11
  movdqa xmm6, xmm0
  db $66, $41, $0F, $3A, $44, $F0, $10   // pclmulqdq xmm6, xmm8, $10
  db $66, $41, $0F, $3A, $44, $C0, $01   // pclmulqdq xmm0, xmm8, $01
  pxor xmm6, xmm0
  movdqu xmm8, [r10 + 288]
  movdqa xmm7, xmm1
  db $66, $41, $0F, $3A, $44, $F8, $00   // pclmulqdq xmm7, xmm8, $00
  pxor xmm4, xmm7
  movdqa xmm7, xmm1
  db $66, $41, $0F, $3A, $44, $F8, $11   // pclmulqdq xmm7, xmm8, $11
  pxor xmm5, xmm7
  movdqa xmm7, xmm1
  db $66, $41, $0F, $3A, $44, $F8, $10   // pclmulqdq xmm7, xmm8, $10
  pxor xmm6, xmm7
  db $66, $41, $0F, $3A, $44, $C8, $01   // pclmulqdq xmm1, xmm8, $01
  pxor xmm6, xmm1
  movdqu xmm8, [r10 + 272]
  movdqa xmm7, xmm2
  db $66, $41, $0F, $3A, $44, $F8, $00   // pclmulqdq xmm7, xmm8, $00
  pxor xmm4, xmm7
  movdqa xmm7, xmm2
  db $66, $41, $0F, $3A, $44, $F8, $11   // pclmulqdq xmm7, xmm8, $11
  pxor xmm5, xmm7
  movdqa xmm7, xmm2
  db $66, $41, $0F, $3A, $44, $F8, $10   // pclmulqdq xmm7, xmm8, $10
  pxor xmm6, xmm7
  db $66, $41, $0F, $3A, $44, $D0, $01   // pclmulqdq xmm2, xmm8, $01
  pxor xmm6, xmm2
  movdqu xmm8, [r10 + 256]
  movdqa xmm7, xmm3
  db $66, $41, $0F, $3A, $44, $F8, $00   // pclmulqdq xmm7, xmm8, $00
  pxor xmm4, xmm7
  movdqa xmm7, xmm3
  db $66, $41, $0F, $3A, $44, $F8, $11   // pclmulqdq xmm7, xmm8, $11
  pxor xmm5, xmm7
  movdqa xmm7, xmm3
  db $66, $41, $0F, $3A, $44, $F8, $10   // pclmulqdq xmm7, xmm8, $10
  pxor xmm6, xmm7
  db $66, $41, $0F, $3A, $44, $D8, $01   // pclmulqdq xmm3, xmm8, $01
  pxor xmm6, xmm3
  // [xmm5:xmm4] = producto de 256 bits (orden reflejado); xmm6 = términos del medio
  movdqa xmm7, xmm6
  pslldq xmm7, 8
  psrldq xmm6, 8
  pxor xmm4, xmm7
  pxor xmm5, xmm6
  // corrimiento de 1 bit a la izquierda de los 256 bits (el producto reflejado tiene 255)
  movdqa xmm7, xmm4
  psrld xmm7, 31
  movdqa xmm8, xmm5
  psrld xmm8, 31
  pslld xmm4, 1
  pslld xmm5, 1
  movdqa xmm9, xmm7
  psrldq xmm9, 12
  pslldq xmm8, 4
  pslldq xmm7, 4
  por xmm4, xmm7
  por xmm5, xmm8
  por xmm5, xmm9
  // reducción módulo x^128 + x^7 + x^2 + x + 1
  movdqa xmm7, xmm4
  pslld xmm7, 31
  movdqa xmm8, xmm4
  pslld xmm8, 30
  movdqa xmm9, xmm4
  pslld xmm9, 25
  pxor xmm7, xmm8
  pxor xmm7, xmm9
  movdqa xmm8, xmm7
  psrldq xmm8, 4
  pslldq xmm7, 12
  pxor xmm4, xmm7
  movdqa xmm10, xmm4
  psrld xmm10, 1
  movdqa xmm11, xmm4
  psrld xmm11, 2
  movdqa xmm9, xmm4
  psrld xmm9, 7
  pxor xmm10, xmm11
  pxor xmm10, xmm9
  pxor xmm10, xmm8
  pxor xmm4, xmm10
  pxor xmm5, xmm4
  movdqa xmm14, xmm5
  add r11, 64
  sub r9, 4
  cmp r9, 4
  jae @four
@one:
  test r9, r9
  jz @done
  movdqu xmm0, [r11]
  pshufb xmm0, xmm15
  pxor xmm0, xmm14
  movdqu xmm8, [r10 + 256]
  movdqa xmm4, xmm0
  db $66, $41, $0F, $3A, $44, $E0, $00   // pclmulqdq xmm4, xmm8, $00
  movdqa xmm5, xmm0
  db $66, $41, $0F, $3A, $44, $E8, $11   // pclmulqdq xmm5, xmm8, $11
  movdqa xmm6, xmm0
  db $66, $41, $0F, $3A, $44, $F0, $10   // pclmulqdq xmm6, xmm8, $10
  db $66, $41, $0F, $3A, $44, $C0, $01   // pclmulqdq xmm0, xmm8, $01
  pxor xmm6, xmm0
  // [xmm5:xmm4] = producto de 256 bits (orden reflejado); xmm6 = términos del medio
  movdqa xmm7, xmm6
  pslldq xmm7, 8
  psrldq xmm6, 8
  pxor xmm4, xmm7
  pxor xmm5, xmm6
  // corrimiento de 1 bit a la izquierda de los 256 bits (el producto reflejado tiene 255)
  movdqa xmm7, xmm4
  psrld xmm7, 31
  movdqa xmm8, xmm5
  psrld xmm8, 31
  pslld xmm4, 1
  pslld xmm5, 1
  movdqa xmm9, xmm7
  psrldq xmm9, 12
  pslldq xmm8, 4
  pslldq xmm7, 4
  por xmm4, xmm7
  por xmm5, xmm8
  por xmm5, xmm9
  // reducción módulo x^128 + x^7 + x^2 + x + 1
  movdqa xmm7, xmm4
  pslld xmm7, 31
  movdqa xmm8, xmm4
  pslld xmm8, 30
  movdqa xmm9, xmm4
  pslld xmm9, 25
  pxor xmm7, xmm8
  pxor xmm7, xmm9
  movdqa xmm8, xmm7
  psrldq xmm8, 4
  pslldq xmm7, 12
  pxor xmm4, xmm7
  movdqa xmm10, xmm4
  psrld xmm10, 1
  movdqa xmm11, xmm4
  psrld xmm11, 2
  movdqa xmm9, xmm4
  psrld xmm9, 7
  pxor xmm10, xmm11
  pxor xmm10, xmm9
  pxor xmm10, xmm8
  pxor xmm4, xmm10
  pxor xmm5, xmm4
  movdqa xmm14, xmm5
  add r11, 16
  dec r9
  jmp @one
@done:
  pshufb xmm14, xmm15
  movdqu [rax], xmm14
  {$IFDEF WIN64}
  movdqu xmm6, [r10 + 352]
  movdqu xmm7, [r10 + 368]
  movdqu xmm8, [r10 + 384]
  movdqu xmm9, [r10 + 400]
  movdqu xmm10, [r10 + 416]
  movdqu xmm11, [r10 + 432]
  movdqu xmm12, [r10 + 448]
  movdqu xmm13, [r10 + 464]
  movdqu xmm14, [r10 + 480]
  movdqu xmm15, [r10 + 496]
  {$ENDIF}
end;
{$ENDIF}

function AesUsesNI: Boolean;
begin
  Result := UseNI;
end;

{ ---------------------------------------------------------------------------------- GCM }

procedure EncBlock(const K: TAesGcmKey; Src, Dst: PByte); inline;
begin
  {$IFDEF AES_ASM}
  if K.Asm_ then begin AesniEncBlock(@K.RkB[0], Src, Dst); Exit; end;
  {$ENDIF}
  EncBlockPas(K.Rk, Src, Dst);
end;

procedure AesGcmInit(out K: TAesGcmKey; Key32: PByte);
var
  Z, Hb: array[0..15] of Byte;
  P0, P1: QWord;
  i, j: Integer;
begin
  FillChar(K, SizeOf(K), 0);
  K.Asm_ := UseNI;
  ExpandKey(Key32, K.Rk);
  {$IFDEF AES_ASM}
  if K.Asm_ then AesniExpand256(Key32, @K.RkB[0]);
  {$ENDIF}
  for i := 0 to 15 do K.BSwap[i] := 15 - i;
  K.One[0] := 1;
  // H = E(K, 0^128)
  FillChar(Z, SizeOf(Z), 0);
  EncBlock(K, @Z[0], @Hb[0]);
  K.H0 := RevBitsInBytes(LoadLE64(@Hb[0]));
  K.H1 := RevBitsInBytes(LoadLE64(@Hb[8]));
  // H^1..H^4 para el ensamblador: en bytes de GCM, invertidos
  P0 := K.H0; P1 := K.H1;
  for i := 0 to 3 do
  begin
    if i > 0 then GfMul(P0, P1, K.H0, K.H1);
    StoreLE64(@Z[0], RevBitsInBytes(P0));
    StoreLE64(@Z[8], RevBitsInBytes(P1));
    for j := 0 to 15 do K.HPow[i, j] := Z[15 - j];
  end;
  FillChar(Hb, SizeOf(Hb), 0);
  FillChar(Z, SizeOf(Z), 0);
  P0 := 0; P1 := 0;
end;

procedure AesGcmClear(var K: TAesGcmKey);
begin
  FillChar(K, SizeOf(K), 0);
end;

procedure Aes256EncryptBlock(Key32, Src16, Dst16: PByte);
var
  K: TAesGcmKey;
begin
  AesGcmInit(K, Key32);
  EncBlock(K, Src16, Dst16);
  AesGcmClear(K);
end;

{ CTR desde el bloque contador Ctr (se actualiza): Dst := Src xor E(K, Ctr++)... }
procedure CtrXor(const K: TAesGcmKey; var Ctr: array of Byte; Src, Dst: PByte; Len: SizeInt);
var
  Ks: array[0..15] of Byte;
  n, i: SizeInt;
  c: LongWord;
begin
  {$IFDEF AES_ASM}
  if K.Asm_ and (Len >= 16) then
  begin
    n := Len div 16;
    AesniCtr(@K, @Ctr[0], Src, Dst, n);
    Inc(Src, 16 * n);
    Inc(Dst, 16 * n);
    Dec(Len, 16 * n);
  end;
  {$ENDIF}
  while Len > 0 do
  begin
    EncBlock(K, @Ctr[0], @Ks[0]);
    c := LoadBE32(@Ctr[12]) + 1;
    StoreBE32(@Ctr[12], c);
    if Len < 16 then n := Len else n := 16;
    for i := 0 to n - 1 do Dst[i] := Src[i] xor Ks[i];
    Inc(Src, n);
    Inc(Dst, n);
    Dec(Len, n);
  end;
  FillChar(Ks, SizeOf(Ks), 0);
end;

{ GHASH(A, C) con relleno a 16 y el bloque de largos; deja S en Y (bytes de GCM). }
procedure Ghash(const K: TAesGcmKey; AD: PByte; ADLen: SizeInt; C: PByte; CLen: SizeInt; out Y: array of Byte);
var
  Last: array[0..15] of Byte;
  Y0, Y1: QWord;

  procedure Feed(Data: PByte; Len: SizeInt);
  var
    n: SizeInt;
  begin
    n := Len div 16;
    if n > 0 then
    begin
      {$IFDEF AES_ASM}
      if K.Asm_ then ClmulGhash(@K, @Y[0], Data, n) else
      {$ENDIF}
      GhashPas(K, Y0, Y1, Data, n);
    end;
    if Len and 15 <> 0 then
    begin
      FillChar(Last, 16, 0);
      Move(Data[16 * n], Last[0], Len and 15);
      {$IFDEF AES_ASM}
      if K.Asm_ then ClmulGhash(@K, @Y[0], @Last[0], 1) else
      {$ENDIF}
      GhashPas(K, Y0, Y1, @Last[0], 1);
    end;
  end;

begin
  FillChar(Y[0], 16, 0);
  Y0 := 0; Y1 := 0;
  Feed(AD, ADLen);
  Feed(C, CLen);
  StoreBE64(@Last[0], QWord(ADLen) * 8);
  StoreBE64(@Last[8], QWord(CLen) * 8);
  {$IFDEF AES_ASM}
  if K.Asm_ then ClmulGhash(@K, @Y[0], @Last[0], 1) else
  {$ENDIF}
  GhashPas(K, Y0, Y1, @Last[0], 1);
  if not K.Asm_ then
  begin
    StoreLE64(@Y[0], RevBitsInBytes(Y0));
    StoreLE64(@Y[8], RevBitsInBytes(Y1));
  end;
end;

procedure GcmTag(const K: TAesGcmKey; Nonce12, AD: PByte; ADLen: SizeInt; C: PByte; CLen: SizeInt; Tag: PByte);
var
  J0, Ek, S: array[0..15] of Byte;
  i: Integer;
begin
  Move(Nonce12^, J0[0], 12);
  J0[12] := 0; J0[13] := 0; J0[14] := 0; J0[15] := 1;
  EncBlock(K, @J0[0], @Ek[0]);
  Ghash(K, AD, ADLen, C, CLen, S);
  for i := 0 to 15 do Tag[i] := Ek[i] xor S[i];
end;

procedure StartCtr(Nonce12: PByte; out Ctr: array of Byte);
begin
  Move(Nonce12^, Ctr[0], 12);
  Ctr[12] := 0; Ctr[13] := 0; Ctr[14] := 0; Ctr[15] := 2;
end;

procedure AesGcmSeal(const K: TAesGcmKey; Nonce12, AD: PByte; ADLen: SizeInt; Src, Dst: PByte;
                     Len: SizeInt; Tag: PByte);
var
  Ctr: array[0..15] of Byte;
begin
  StartCtr(Nonce12, Ctr);
  CtrXor(K, Ctr, Src, Dst, Len);
  GcmTag(K, Nonce12, AD, ADLen, Dst, Len, Tag);
end;

function AesGcmOpen(const K: TAesGcmKey; Nonce12, AD: PByte; ADLen: SizeInt; Src, Dst: PByte;
                    Len: SizeInt; Tag: PByte): Boolean;
var
  Ctr, T: array[0..15] of Byte;
  d: Byte;
  i: Integer;
begin
  GcmTag(K, Nonce12, AD, ADLen, Src, Len, @T[0]);
  d := 0;
  for i := 0 to 15 do d := d or (T[i] xor Tag[i]);
  Result := d = 0;
  if not Result then Exit;
  StartCtr(Nonce12, Ctr);
  CtrXor(K, Ctr, Src, Dst, Len);
end;

initialization
  InitTables;
  {$IFDEF AES_ASM}
  UseNI := CpuHasAesNI and (GetEnvironmentVariable('PARC_CRYPT') <> 'pas');
  {$ENDIF}
end.
