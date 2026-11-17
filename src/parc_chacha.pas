{ parc_chacha — ChaCha20, HChaCha20, Poly1305 y los AEAD ChaCha20-Poly1305 (RFC 8439) y
  XChaCha20-Poly1305 (draft-irtf-cfrg-xchacha-03).

  Código propio escrito a partir de esas especificaciones.

  - ChaCha20: contador de 32 bits y nonce de 96 bits (RFC 8439 §2.3). En x86-64 con AVX2
    (CPUID, al arrancar) cuatro bloques por vuelta: cada ymm lleva una fila de dos bloques
    (una en cada mitad de 128 bits) y las diagonales se arman con vpshufd dentro de cada
    mitad. Sin AVX2, o en i386/aarch64, el bloque en Pascal. Las dos dan lo mismo.
  - Poly1305: en x86-64 la acumulación va en base 2^64 (tres palabras) con MUL de 64x64 bits
    en ensamblador; en las demás, cinco limbs de 26 bits en Pascal. El resultado es el mismo.
  - Nada depende de los datos secretos para elegir camino ni direcciones (las dos son de
    tiempo constante, salvo la última resta condicional de Poly1305, hecha con máscaras).

  PARC_CRYPT=pas en el entorno apaga AVX2 (para medir y para probar el camino portable). }
unit parc_chacha;

{$mode objfpc}{$H+}
{$R-}{$Q-}
{$IFDEF CPUX86_64}{$ASMMODE INTEL}{$ENDIF}
{$IF defined(CPUX86_64) and not defined(PARC_NOASM)}{$DEFINE CHACHA_ASM}{$ENDIF}

interface

type
  TPoly1305 = record
    {$IFDEF CHACHA_ASM}
    H0, H1, H2: QWord;          // acumulador en base 2^64
    R0, R1, S1: QWord;          // r ya recortado; S1 = R1 + R1 shr 2
    Save: array[0..7] of QWord; // registros preservados (el ensamblador no usa la pila)
    {$ELSE}
    H: array[0..4] of LongWord; // acumulador en base 2^26
    R: array[0..4] of LongWord;
    {$ENDIF}
    Pad: array[0..3] of LongWord;
    Buf: array[0..15] of Byte;
    BufLen: Integer;
  end;

procedure Poly1305Init(out P: TPoly1305; Key: PByte);
procedure Poly1305Update(var P: TPoly1305; Data: PByte; Len: SizeInt);
procedure Poly1305Final(var P: TPoly1305; Tag: PByte);
procedure Poly1305Mac(Key, Data: PByte; Len: SizeInt; Tag: PByte);

{ ChaCha20 de RFC 8439: Dst := Src xor keystream(Key, Nonce12, Counter...). Src y Dst pueden
  ser el mismo buffer. }
procedure ChaCha20Xor(Key, Nonce12: PByte; Counter: LongWord; Src, Dst: PByte; Len: SizeInt);
{ El bloque de ChaCha20 (64 bytes) para los vectores del RFC. }
procedure ChaCha20Block(Key, Nonce12: PByte; Counter: LongWord; Out64: PByte);
{ HChaCha20 (draft-irtf-cfrg-xchacha §2.2): subclave de 32 bytes a partir de 16 de nonce. }
procedure HChaCha20(Key, Nonce16, Out32: PByte);

{ AEAD de RFC 8439 §2.8 (nonce de 12 bytes) y XChaCha20-Poly1305 (nonce de 24). Seal deja el
  cifrado en Dst y la etiqueta de 16 bytes en Tag; Open comprueba la etiqueta ANTES de
  descifrar lo que no se haya descifrado ya; si no coincide devuelve False y en Dst no queda
  nada del claro (ceros, o sin tocar). }
procedure ChaChaPolySeal(Key, Nonce12, AD: PByte; ADLen: SizeInt; Src, Dst: PByte; Len: SizeInt; Tag: PByte);
function  ChaChaPolyOpen(Key, Nonce12, AD: PByte; ADLen: SizeInt; Src, Dst: PByte; Len: SizeInt; Tag: PByte): Boolean;
procedure XChaChaPolySeal(Key, Nonce24, AD: PByte; ADLen: SizeInt; Src, Dst: PByte; Len: SizeInt; Tag: PByte);
function  XChaChaPolyOpen(Key, Nonce24, AD: PByte; ADLen: SizeInt; Src, Dst: PByte; Len: SizeInt; Tag: PByte): Boolean;

{ Comparación de tiempo constante. }
function ConstEq(a, b: PByte; Len: SizeInt): Boolean;

{ ¿Se usa el camino AVX2 de ChaCha20? }
function ChaChaUsesAvx2: Boolean;

implementation

uses
  SysUtils;

function Rol32(x: LongWord; n: Integer): LongWord; inline;
begin
  Result := (x shl n) or (x shr (32 - n));
end;

function LoadLE32(p: PByte): LongWord; inline;
begin
  Result := LongWord(p[0]) or (LongWord(p[1]) shl 8) or (LongWord(p[2]) shl 16) or (LongWord(p[3]) shl 24);
end;

procedure StoreLE32(p: PByte; v: LongWord); inline;
begin
  p[0] := Byte(v); p[1] := Byte(v shr 8); p[2] := Byte(v shr 16); p[3] := Byte(v shr 24);
end;

procedure StoreLE64(p: PByte; v: QWord); inline;
begin
  StoreLE32(p, LongWord(v));
  StoreLE32(p + 4, LongWord(v shr 32));
end;

function ConstEq(a, b: PByte; Len: SizeInt): Boolean;
var
  d: Byte;
  i: SizeInt;
begin
  d := 0;
  for i := 0 to Len - 1 do d := d or (a[i] xor b[i]);
  Result := d = 0;
end;

{ ------------------------------------------------------------------------------ ChaCha20 }

type
  TChaState = array[0..15] of LongWord;

  { Lo que recibe el ensamblador (offsets fijos). }
  TChaAsmCtx = record
    State: TChaState;                       // 0
    Rot16, Rot8: array[0..31] of Byte;      // 64, 96
    Inc01, Inc2, Inc4: array[0..7] of LongWord;   // 128, 160, 192
    Save: array[0..19] of QWord;            // 224: xmm6..xmm15 (Win64)
    PolyState: Pointer;                     // 384: TPoly1305 (ChaChaPolyAvx2)
    PolyData: Pointer;                      // 392: lo que autentica (avanza 256 por vuelta)
    GSave: array[0..7] of QWord;            // 400: rbx, rbp, rsi, rdi, r12-r15
  end;

const
  SIGMA: array[0..3] of LongWord = ($61707865, $3320646e, $79622d32, $6b206574);

var
  UseAvx2: Boolean = False;

procedure ChaInit(out S: TChaState; Key, Nonce12: PByte; Counter: LongWord);
var
  i: Integer;
begin
  for i := 0 to 3 do S[i] := SIGMA[i];
  for i := 0 to 7 do S[4 + i] := LoadLE32(Key + 4 * i);
  S[12] := Counter;
  for i := 0 to 2 do S[13 + i] := LoadLE32(Nonce12 + 4 * i);
end;

procedure ChaRounds(var x: TChaState);
var
  x0, x1, x2, x3, x4, x5, x6, x7, x8, x9, x10, x11, x12, x13, x14, x15: LongWord;
  i: Integer;
begin
  // (en variables locales: con QR sobre elementos del arreglo FPC no los deja en registros)
  x0 := x[0]; x1 := x[1]; x2 := x[2]; x3 := x[3]; x4 := x[4]; x5 := x[5]; x6 := x[6]; x7 := x[7];
  x8 := x[8]; x9 := x[9]; x10 := x[10]; x11 := x[11]; x12 := x[12]; x13 := x[13]; x14 := x[14]; x15 := x[15];
  for i := 1 to 10 do
  begin
    x0 := x0 + x4; x12 := RolDWord(x12 xor x0, 16);
    x8 := x8 + x12; x4 := RolDWord(x4 xor x8, 12);
    x0 := x0 + x4; x12 := RolDWord(x12 xor x0, 8);
    x8 := x8 + x12; x4 := RolDWord(x4 xor x8, 7);
    x1 := x1 + x5; x13 := RolDWord(x13 xor x1, 16);
    x9 := x9 + x13; x5 := RolDWord(x5 xor x9, 12);
    x1 := x1 + x5; x13 := RolDWord(x13 xor x1, 8);
    x9 := x9 + x13; x5 := RolDWord(x5 xor x9, 7);
    x2 := x2 + x6; x14 := RolDWord(x14 xor x2, 16);
    x10 := x10 + x14; x6 := RolDWord(x6 xor x10, 12);
    x2 := x2 + x6; x14 := RolDWord(x14 xor x2, 8);
    x10 := x10 + x14; x6 := RolDWord(x6 xor x10, 7);
    x3 := x3 + x7; x15 := RolDWord(x15 xor x3, 16);
    x11 := x11 + x15; x7 := RolDWord(x7 xor x11, 12);
    x3 := x3 + x7; x15 := RolDWord(x15 xor x3, 8);
    x11 := x11 + x15; x7 := RolDWord(x7 xor x11, 7);
    x0 := x0 + x5; x15 := RolDWord(x15 xor x0, 16);
    x10 := x10 + x15; x5 := RolDWord(x5 xor x10, 12);
    x0 := x0 + x5; x15 := RolDWord(x15 xor x0, 8);
    x10 := x10 + x15; x5 := RolDWord(x5 xor x10, 7);
    x1 := x1 + x6; x12 := RolDWord(x12 xor x1, 16);
    x11 := x11 + x12; x6 := RolDWord(x6 xor x11, 12);
    x1 := x1 + x6; x12 := RolDWord(x12 xor x1, 8);
    x11 := x11 + x12; x6 := RolDWord(x6 xor x11, 7);
    x2 := x2 + x7; x13 := RolDWord(x13 xor x2, 16);
    x8 := x8 + x13; x7 := RolDWord(x7 xor x8, 12);
    x2 := x2 + x7; x13 := RolDWord(x13 xor x2, 8);
    x8 := x8 + x13; x7 := RolDWord(x7 xor x8, 7);
    x3 := x3 + x4; x14 := RolDWord(x14 xor x3, 16);
    x9 := x9 + x14; x4 := RolDWord(x4 xor x9, 12);
    x3 := x3 + x4; x14 := RolDWord(x14 xor x3, 8);
    x9 := x9 + x14; x4 := RolDWord(x4 xor x9, 7);
  end;
  x[0] := x0; x[1] := x1; x[2] := x2; x[3] := x3; x[4] := x4; x[5] := x5; x[6] := x6; x[7] := x7;
  x[8] := x8; x[9] := x9; x[10] := x10; x[11] := x11; x[12] := x12; x[13] := x13; x[14] := x14; x[15] := x15;
end;

{ Un bloque de keystream con el estado S (no incrementa el contador). }
procedure ChaBlock(const S: TChaState; Out64: PByte);
var
  x: TChaState;
  i: Integer;
begin
  x := S;
  ChaRounds(x);
  for i := 0 to 15 do StoreLE32(Out64 + 4 * i, x[i] + S[i]);
end;

{$IFDEF CHACHA_ASM}
function CpuHasAvx2: Boolean;
var
  c1, b7, xcr: LongWord;
begin
  asm
    mov eax, 1
    xor ecx, ecx
    cpuid
    mov c1, ecx
    mov eax, 7
    xor ecx, ecx
    cpuid
    mov b7, ebx
  end ['rax', 'rbx', 'rcx', 'rdx'];
  Result := False;
  // AVX (bit 28) y OSXSAVE (bit 27): el sistema guarda los ymm
  if (c1 and (1 shl 27) = 0) or (c1 and (1 shl 28) = 0) then Exit;
  asm
    xor ecx, ecx
    db $0F, $01, $D0          // xgetbv
    mov xcr, eax
  end ['rax', 'rcx', 'rdx'];
  if xcr and 6 <> 6 then Exit;
  Result := (b7 and (1 shl 5)) <> 0;   // AVX2
end;

{ Groups vueltas de 4 bloques (256 bytes) con Ctx.State (contador en la palabra 12, que NO se
  actualiza: lo hace el llamador). Dst := Src xor keystream. }
procedure ChaChaAvx2(Ctx: Pointer; Src, Dst: PByte; Groups: SizeUInt); assembler; nostackframe;
asm
  {$IFDEF WIN64}
  movdqu [rcx + 224], xmm6
  movdqu [rcx + 240], xmm7
  movdqu [rcx + 256], xmm8
  movdqu [rcx + 272], xmm9
  movdqu [rcx + 288], xmm10
  movdqu [rcx + 304], xmm11
  movdqu [rcx + 320], xmm12
  movdqu [rcx + 336], xmm13
  movdqu [rcx + 352], xmm14
  movdqu [rcx + 368], xmm15
  mov r10, rcx
  mov r11, rdx
  {$ELSE}
  mov r10, rdi
  mov r11, rsi
  mov r8, rdx
  mov r9, rcx
  {$ENDIF}
  // r10 = ctx, r11 = src, r8 = dst, r9 = vueltas
  vbroadcasti128 ymm12, [r10]
  vbroadcasti128 ymm13, [r10 + 16]
  vbroadcasti128 ymm14, [r10 + 32]
  vbroadcasti128 ymm15, [r10 + 48]
  vpaddd ymm15, ymm15, [r10 + 128]       // bloques n y n+1
  vmovdqu ymm10, [r10 + 64]              // rotar 16
  vmovdqu ymm11, [r10 + 96]              // rotar 8
@loop:
  vmovdqa ymm0, ymm12
  vmovdqa ymm1, ymm13
  vmovdqa ymm2, ymm14
  vmovdqa ymm3, ymm15
  vmovdqa ymm4, ymm12
  vmovdqa ymm5, ymm13
  vmovdqa ymm6, ymm14
  vpaddd ymm7, ymm15, [r10 + 160]        // bloques n+2 y n+3
  mov eax, 10
@round:
  // columnas
  vpaddd ymm0, ymm0, ymm1
  vpaddd ymm4, ymm4, ymm5
  vpxor ymm3, ymm3, ymm0
  vpxor ymm7, ymm7, ymm4
  vpshufb ymm3, ymm3, ymm10
  vpshufb ymm7, ymm7, ymm10
  vpaddd ymm2, ymm2, ymm3
  vpaddd ymm6, ymm6, ymm7
  vpxor ymm1, ymm1, ymm2
  vpxor ymm5, ymm5, ymm6
  vpslld ymm8, ymm1, 12
  vpsrld ymm1, ymm1, 20
  vpslld ymm9, ymm5, 12
  vpsrld ymm5, ymm5, 20
  vpor ymm1, ymm1, ymm8
  vpor ymm5, ymm5, ymm9
  vpaddd ymm0, ymm0, ymm1
  vpaddd ymm4, ymm4, ymm5
  vpxor ymm3, ymm3, ymm0
  vpxor ymm7, ymm7, ymm4
  vpshufb ymm3, ymm3, ymm11
  vpshufb ymm7, ymm7, ymm11
  vpaddd ymm2, ymm2, ymm3
  vpaddd ymm6, ymm6, ymm7
  vpxor ymm1, ymm1, ymm2
  vpxor ymm5, ymm5, ymm6
  vpslld ymm8, ymm1, 7
  vpsrld ymm1, ymm1, 25
  vpslld ymm9, ymm5, 7
  vpsrld ymm5, ymm5, 25
  vpor ymm1, ymm1, ymm8
  vpor ymm5, ymm5, ymm9
  // a diagonales
  vpshufd ymm1, ymm1, $39
  vpshufd ymm5, ymm5, $39
  vpshufd ymm2, ymm2, $4e
  vpshufd ymm6, ymm6, $4e
  vpshufd ymm3, ymm3, $93
  vpshufd ymm7, ymm7, $93
  // diagonales
  vpaddd ymm0, ymm0, ymm1
  vpaddd ymm4, ymm4, ymm5
  vpxor ymm3, ymm3, ymm0
  vpxor ymm7, ymm7, ymm4
  vpshufb ymm3, ymm3, ymm10
  vpshufb ymm7, ymm7, ymm10
  vpaddd ymm2, ymm2, ymm3
  vpaddd ymm6, ymm6, ymm7
  vpxor ymm1, ymm1, ymm2
  vpxor ymm5, ymm5, ymm6
  vpslld ymm8, ymm1, 12
  vpsrld ymm1, ymm1, 20
  vpslld ymm9, ymm5, 12
  vpsrld ymm5, ymm5, 20
  vpor ymm1, ymm1, ymm8
  vpor ymm5, ymm5, ymm9
  vpaddd ymm0, ymm0, ymm1
  vpaddd ymm4, ymm4, ymm5
  vpxor ymm3, ymm3, ymm0
  vpxor ymm7, ymm7, ymm4
  vpshufb ymm3, ymm3, ymm11
  vpshufb ymm7, ymm7, ymm11
  vpaddd ymm2, ymm2, ymm3
  vpaddd ymm6, ymm6, ymm7
  vpxor ymm1, ymm1, ymm2
  vpxor ymm5, ymm5, ymm6
  vpslld ymm8, ymm1, 7
  vpsrld ymm1, ymm1, 25
  vpslld ymm9, ymm5, 7
  vpsrld ymm5, ymm5, 25
  vpor ymm1, ymm1, ymm8
  vpor ymm5, ymm5, ymm9
  // de vuelta a columnas
  vpshufd ymm1, ymm1, $93
  vpshufd ymm5, ymm5, $93
  vpshufd ymm2, ymm2, $4e
  vpshufd ymm6, ymm6, $4e
  vpshufd ymm3, ymm3, $39
  vpshufd ymm7, ymm7, $39
  dec eax
  jnz @round
  // + estado inicial
  vpaddd ymm0, ymm0, ymm12
  vpaddd ymm1, ymm1, ymm13
  vpaddd ymm2, ymm2, ymm14
  vpaddd ymm3, ymm3, ymm15
  vpaddd ymm4, ymm4, ymm12
  vpaddd ymm5, ymm5, ymm13
  vpaddd ymm6, ymm6, ymm14
  vpaddd ymm7, ymm7, ymm15
  vpaddd ymm7, ymm7, [r10 + 160]
  // bloque n: mitades bajas; n+1: altas
  vperm2i128 ymm8, ymm0, ymm1, $20
  vperm2i128 ymm9, ymm2, ymm3, $20
  vpxor ymm8, ymm8, [r11]
  vpxor ymm9, ymm9, [r11 + 32]
  vmovdqu [r8], ymm8
  vmovdqu [r8 + 32], ymm9
  vperm2i128 ymm8, ymm0, ymm1, $31
  vperm2i128 ymm9, ymm2, ymm3, $31
  vpxor ymm8, ymm8, [r11 + 64]
  vpxor ymm9, ymm9, [r11 + 96]
  vmovdqu [r8 + 64], ymm8
  vmovdqu [r8 + 96], ymm9
  vperm2i128 ymm8, ymm4, ymm5, $20
  vperm2i128 ymm9, ymm6, ymm7, $20
  vpxor ymm8, ymm8, [r11 + 128]
  vpxor ymm9, ymm9, [r11 + 160]
  vmovdqu [r8 + 128], ymm8
  vmovdqu [r8 + 160], ymm9
  vperm2i128 ymm8, ymm4, ymm5, $31
  vperm2i128 ymm9, ymm6, ymm7, $31
  vpxor ymm8, ymm8, [r11 + 192]
  vpxor ymm9, ymm9, [r11 + 224]
  vmovdqu [r8 + 192], ymm8
  vmovdqu [r8 + 224], ymm9
  vpaddd ymm15, ymm15, [r10 + 192]       // contador + 4
  add r11, 256
  add r8, 256
  dec r9
  jnz @loop
  vzeroupper
  {$IFDEF WIN64}
  movdqu xmm6, [r10 + 224]
  movdqu xmm7, [r10 + 240]
  movdqu xmm8, [r10 + 256]
  movdqu xmm9, [r10 + 272]
  movdqu xmm10, [r10 + 288]
  movdqu xmm11, [r10 + 304]
  movdqu xmm12, [r10 + 320]
  movdqu xmm13, [r10 + 336]
  movdqu xmm14, [r10 + 352]
  movdqu xmm15, [r10 + 368]
  {$ENDIF}
end;


{ ChaChaAvx2 + Poly1305 "cosidos": en cada vuelta de 4 bloques, mientras corren las 10 rondas
  dobles (desenrolladas; puertos vectoriales), Poly1305 autentica 256 bytes de Ctx.PolyData
  (16 bloques; multiplicador entero), con el estado de Ctx.PolyState (TPoly1305, base 2^64, sin
  bytes pendientes). Las instrucciones escalares van intercaladas entre las vectoriales (ninguna
  vectorial toca los flags que encadenan add/adc). Ctx.PolyData avanza 256 por vuelta. Al
  descifrar en el mismo buffer, los 256 bytes se leen antes de escribir la salida de la vuelta. }
procedure ChaChaPolyAvx2(Ctx: Pointer; Src, Dst: PByte; Groups: SizeUInt); assembler; nostackframe;
asm
  {$IFDEF WIN64}
  movdqu [rcx + 224], xmm6
  movdqu [rcx + 240], xmm7
  movdqu [rcx + 256], xmm8
  movdqu [rcx + 272], xmm9
  movdqu [rcx + 288], xmm10
  movdqu [rcx + 304], xmm11
  movdqu [rcx + 320], xmm12
  movdqu [rcx + 336], xmm13
  movdqu [rcx + 352], xmm14
  movdqu [rcx + 368], xmm15
  mov [rcx + 400], rbx
  mov [rcx + 408], rbp
  mov [rcx + 416], rsi
  mov [rcx + 424], rdi
  mov [rcx + 432], r12
  mov [rcx + 440], r13
  mov [rcx + 448], r14
  mov [rcx + 456], r15
  mov r10, rcx
  mov r11, rdx
  {$ELSE}
  mov [rdi + 400], rbx
  mov [rdi + 408], rbp
  mov [rdi + 432], r12
  mov [rdi + 440], r13
  mov [rdi + 448], r14
  mov [rdi + 456], r15
  mov r10, rdi
  mov r11, rsi
  mov r8, rdx
  mov r9, rcx
  {$ENDIF}
  // r10 = ctx, r11 = src, r8 = dst, r9 = vueltas; rbp = Poly1305, rsi = datos a autenticar
  mov rbp, [r10 + 384]
  mov rsi, [r10 + 392]
  mov r13, [rbp]
  mov r14, [rbp + 8]
  mov r15, [rbp + 16]
  vbroadcasti128 ymm12, [r10]
  vbroadcasti128 ymm13, [r10 + 16]
  vbroadcasti128 ymm14, [r10 + 32]
  vbroadcasti128 ymm15, [r10 + 48]
  vpaddd ymm15, ymm15, [r10 + 128]
  vmovdqu ymm10, [r10 + 64]
  vmovdqu ymm11, [r10 + 96]
@loop:
  vmovdqa ymm0, ymm12
  vmovdqa ymm1, ymm13
  vmovdqa ymm2, ymm14
  vmovdqa ymm3, ymm15
  vmovdqa ymm4, ymm12
  vmovdqa ymm5, ymm13
  vmovdqa ymm6, ymm14
  vpaddd ymm7, ymm15, [r10 + 160]
  vpaddd ymm0, ymm0, ymm1
  add r13, [rsi + 0]
  vpaddd ymm4, ymm4, ymm5
  adc r14, [rsi + 8]
  vpxor ymm3, ymm3, ymm0
  adc r15, 1
  vpxor ymm7, ymm7, ymm4
  vpshufb ymm3, ymm3, ymm10
  mov rax, r13
  vpshufb ymm7, ymm7, ymm10
  mul qword ptr [rbp + 24]
  vpaddd ymm2, ymm2, ymm3
  vpaddd ymm6, ymm6, ymm7
  mov rbx, rax
  vpxor ymm1, ymm1, ymm2
  mov rcx, rdx
  vpxor ymm5, ymm5, ymm6
  vpslld ymm8, ymm1, 12
  mov rax, r14
  vpsrld ymm1, ymm1, 20
  mul qword ptr [rbp + 40]
  vpslld ymm9, ymm5, 12
  add rbx, rax
  vpsrld ymm5, ymm5, 20
  vpor ymm1, ymm1, ymm8
  adc rcx, rdx
  vpor ymm5, ymm5, ymm9
  mov rax, r13
  vpaddd ymm0, ymm0, ymm1
  vpaddd ymm4, ymm4, ymm5
  mul qword ptr [rbp + 32]
  vpxor ymm3, ymm3, ymm0
  mov r13, rbx
  vpxor ymm7, ymm7, ymm4
  vpshufb ymm3, ymm3, ymm11
  mov rbx, rax
  vpshufb ymm7, ymm7, ymm11
  mov rdi, rdx
  vpaddd ymm2, ymm2, ymm3
  mov rax, r14
  vpaddd ymm6, ymm6, ymm7
  vpxor ymm1, ymm1, ymm2
  mul qword ptr [rbp + 24]
  vpxor ymm5, ymm5, ymm6
  add rbx, rax
  vpslld ymm8, ymm1, 7
  vpsrld ymm1, ymm1, 25
  adc rdi, rdx
  vpslld ymm9, ymm5, 7
  mov rax, r15
  vpsrld ymm5, ymm5, 25
  vpor ymm1, ymm1, ymm8
  imul rax, [rbp + 40]
  vpor ymm5, ymm5, ymm9
  add rbx, rax
  vpshufd ymm1, ymm1, $39
  adc rdi, 0
  vpshufd ymm5, ymm5, $39
  vpshufd ymm2, ymm2, $4e
  imul r15, [rbp + 24]
  vpshufd ymm6, ymm6, $4e
  add rbx, rcx
  vpshufd ymm3, ymm3, $93
  vpshufd ymm7, ymm7, $93
  adc rdi, r15
  vpaddd ymm0, ymm0, ymm1
  mov r14, rbx
  vpaddd ymm4, ymm4, ymm5
  vpxor ymm3, ymm3, ymm0
  mov r15, rdi
  vpxor ymm7, ymm7, ymm4
  mov rax, r15
  vpshufb ymm3, ymm3, ymm10
  vpshufb ymm7, ymm7, ymm10
  and r15, 3
  vpaddd ymm2, ymm2, ymm3
  shr rax, 2
  vpaddd ymm6, ymm6, ymm7
  lea rax, [rax + rax * 4]
  vpxor ymm1, ymm1, ymm2
  vpxor ymm5, ymm5, ymm6
  add r13, rax
  vpslld ymm8, ymm1, 12
  adc r14, 0
  vpsrld ymm1, ymm1, 20
  vpslld ymm9, ymm5, 12
  adc r15, 0
  vpsrld ymm5, ymm5, 20
  add r13, [rsi + 16]
  vpor ymm1, ymm1, ymm8
  vpor ymm5, ymm5, ymm9
  adc r14, [rsi + 24]
  vpaddd ymm0, ymm0, ymm1
  adc r15, 1
  vpaddd ymm4, ymm4, ymm5
  mov rax, r13
  vpxor ymm3, ymm3, ymm0
  vpxor ymm7, ymm7, ymm4
  mul qword ptr [rbp + 24]
  vpshufb ymm3, ymm3, ymm11
  mov rbx, rax
  vpshufb ymm7, ymm7, ymm11
  vpaddd ymm2, ymm2, ymm3
  mov rcx, rdx
  vpaddd ymm6, ymm6, ymm7
  mov rax, r14
  vpxor ymm1, ymm1, ymm2
  vpxor ymm5, ymm5, ymm6
  mul qword ptr [rbp + 40]
  vpslld ymm8, ymm1, 7
  add rbx, rax
  vpsrld ymm1, ymm1, 25
  adc rcx, rdx
  vpslld ymm9, ymm5, 7
  vpsrld ymm5, ymm5, 25
  mov rax, r13
  vpor ymm1, ymm1, ymm8
  mul qword ptr [rbp + 32]
  vpor ymm5, ymm5, ymm9
  vpshufd ymm1, ymm1, $93
  mov r13, rbx
  vpshufd ymm5, ymm5, $93
  mov rbx, rax
  vpshufd ymm2, ymm2, $4e
  vpshufd ymm6, ymm6, $4e
  mov rdi, rdx
  vpshufd ymm3, ymm3, $39
  mov rax, r14
  vpshufd ymm7, ymm7, $39
  vpaddd ymm0, ymm0, ymm1
  mul qword ptr [rbp + 24]
  vpaddd ymm4, ymm4, ymm5
  add rbx, rax
  vpxor ymm3, ymm3, ymm0
  adc rdi, rdx
  vpxor ymm7, ymm7, ymm4
  vpshufb ymm3, ymm3, ymm10
  mov rax, r15
  vpshufb ymm7, ymm7, ymm10
  imul rax, [rbp + 40]
  vpaddd ymm2, ymm2, ymm3
  vpaddd ymm6, ymm6, ymm7
  add rbx, rax
  vpxor ymm1, ymm1, ymm2
  adc rdi, 0
  vpxor ymm5, ymm5, ymm6
  vpslld ymm8, ymm1, 12
  imul r15, [rbp + 24]
  vpsrld ymm1, ymm1, 20
  add rbx, rcx
  vpslld ymm9, ymm5, 12
  adc rdi, r15
  vpsrld ymm5, ymm5, 20
  vpor ymm1, ymm1, ymm8
  mov r14, rbx
  vpor ymm5, ymm5, ymm9
  mov r15, rdi
  vpaddd ymm0, ymm0, ymm1
  vpaddd ymm4, ymm4, ymm5
  mov rax, r15
  vpxor ymm3, ymm3, ymm0
  and r15, 3
  vpxor ymm7, ymm7, ymm4
  vpshufb ymm3, ymm3, ymm11
  shr rax, 2
  vpshufb ymm7, ymm7, ymm11
  lea rax, [rax + rax * 4]
  vpaddd ymm2, ymm2, ymm3
  add r13, rax
  vpaddd ymm6, ymm6, ymm7
  vpxor ymm1, ymm1, ymm2
  adc r14, 0
  vpxor ymm5, ymm5, ymm6
  adc r15, 0
  vpslld ymm8, ymm1, 7
  vpsrld ymm1, ymm1, 25
  add r13, [rsi + 32]
  vpslld ymm9, ymm5, 7
  adc r14, [rsi + 40]
  vpsrld ymm5, ymm5, 25
  vpor ymm1, ymm1, ymm8
  adc r15, 1
  vpor ymm5, ymm5, ymm9
  mov rax, r13
  vpshufd ymm1, ymm1, $39
  mul qword ptr [rbp + 24]
  vpshufd ymm5, ymm5, $39
  vpshufd ymm2, ymm2, $4e
  mov rbx, rax
  vpshufd ymm6, ymm6, $4e
  mov rcx, rdx
  vpshufd ymm3, ymm3, $93
  vpshufd ymm7, ymm7, $93
  mov rax, r14
  vpaddd ymm0, ymm0, ymm1
  mul qword ptr [rbp + 40]
  vpaddd ymm4, ymm4, ymm5
  vpxor ymm3, ymm3, ymm0
  add rbx, rax
  vpxor ymm7, ymm7, ymm4
  adc rcx, rdx
  vpshufb ymm3, ymm3, ymm10
  vpshufb ymm7, ymm7, ymm10
  mov rax, r13
  vpaddd ymm2, ymm2, ymm3
  mul qword ptr [rbp + 32]
  vpaddd ymm6, ymm6, ymm7
  mov r13, rbx
  vpxor ymm1, ymm1, ymm2
  vpxor ymm5, ymm5, ymm6
  mov rbx, rax
  vpslld ymm8, ymm1, 12
  mov rdi, rdx
  vpsrld ymm1, ymm1, 20
  vpslld ymm9, ymm5, 12
  mov rax, r14
  vpsrld ymm5, ymm5, 20
  mul qword ptr [rbp + 24]
  vpor ymm1, ymm1, ymm8
  vpor ymm5, ymm5, ymm9
  add rbx, rax
  vpaddd ymm0, ymm0, ymm1
  adc rdi, rdx
  vpaddd ymm4, ymm4, ymm5
  mov rax, r15
  vpxor ymm3, ymm3, ymm0
  vpxor ymm7, ymm7, ymm4
  imul rax, [rbp + 40]
  vpshufb ymm3, ymm3, ymm11
  add rbx, rax
  vpshufb ymm7, ymm7, ymm11
  vpaddd ymm2, ymm2, ymm3
  adc rdi, 0
  vpaddd ymm6, ymm6, ymm7
  imul r15, [rbp + 24]
  vpxor ymm1, ymm1, ymm2
  vpxor ymm5, ymm5, ymm6
  add rbx, rcx
  vpslld ymm8, ymm1, 7
  adc rdi, r15
  vpsrld ymm1, ymm1, 25
  mov r14, rbx
  vpslld ymm9, ymm5, 7
  vpsrld ymm5, ymm5, 25
  mov r15, rdi
  vpor ymm1, ymm1, ymm8
  mov rax, r15
  vpor ymm5, ymm5, ymm9
  vpshufd ymm1, ymm1, $93
  and r15, 3
  vpshufd ymm5, ymm5, $93
  shr rax, 2
  vpshufd ymm2, ymm2, $4e
  vpshufd ymm6, ymm6, $4e
  lea rax, [rax + rax * 4]
  vpshufd ymm3, ymm3, $39
  add r13, rax
  vpshufd ymm7, ymm7, $39
  vpaddd ymm0, ymm0, ymm1
  adc r14, 0
  vpaddd ymm4, ymm4, ymm5
  adc r15, 0
  vpxor ymm3, ymm3, ymm0
  add r13, [rsi + 48]
  vpxor ymm7, ymm7, ymm4
  vpshufb ymm3, ymm3, ymm10
  adc r14, [rsi + 56]
  vpshufb ymm7, ymm7, ymm10
  adc r15, 1
  vpaddd ymm2, ymm2, ymm3
  vpaddd ymm6, ymm6, ymm7
  mov rax, r13
  vpxor ymm1, ymm1, ymm2
  mul qword ptr [rbp + 24]
  vpxor ymm5, ymm5, ymm6
  vpslld ymm8, ymm1, 12
  mov rbx, rax
  vpsrld ymm1, ymm1, 20
  mov rcx, rdx
  vpslld ymm9, ymm5, 12
  mov rax, r14
  vpsrld ymm5, ymm5, 20
  vpor ymm1, ymm1, ymm8
  mul qword ptr [rbp + 40]
  vpor ymm5, ymm5, ymm9
  add rbx, rax
  vpaddd ymm0, ymm0, ymm1
  vpaddd ymm4, ymm4, ymm5
  adc rcx, rdx
  vpxor ymm3, ymm3, ymm0
  mov rax, r13
  vpxor ymm7, ymm7, ymm4
  vpshufb ymm3, ymm3, ymm11
  mul qword ptr [rbp + 32]
  vpshufb ymm7, ymm7, ymm11
  mov r13, rbx
  vpaddd ymm2, ymm2, ymm3
  mov rbx, rax
  vpaddd ymm6, ymm6, ymm7
  vpxor ymm1, ymm1, ymm2
  mov rdi, rdx
  vpxor ymm5, ymm5, ymm6
  mov rax, r14
  vpslld ymm8, ymm1, 7
  vpsrld ymm1, ymm1, 25
  mul qword ptr [rbp + 24]
  vpslld ymm9, ymm5, 7
  add rbx, rax
  vpsrld ymm5, ymm5, 25
  vpor ymm1, ymm1, ymm8
  adc rdi, rdx
  vpor ymm5, ymm5, ymm9
  mov rax, r15
  vpshufd ymm1, ymm1, $39
  vpshufd ymm5, ymm5, $39
  imul rax, [rbp + 40]
  vpshufd ymm2, ymm2, $4e
  add rbx, rax
  vpshufd ymm6, ymm6, $4e
  adc rdi, 0
  vpshufd ymm3, ymm3, $93
  vpshufd ymm7, ymm7, $93
  imul r15, [rbp + 24]
  vpaddd ymm0, ymm0, ymm1
  add rbx, rcx
  vpaddd ymm4, ymm4, ymm5
  vpxor ymm3, ymm3, ymm0
  adc rdi, r15
  vpxor ymm7, ymm7, ymm4
  mov r14, rbx
  vpshufb ymm3, ymm3, ymm10
  vpshufb ymm7, ymm7, ymm10
  mov r15, rdi
  vpaddd ymm2, ymm2, ymm3
  mov rax, r15
  vpaddd ymm6, ymm6, ymm7
  and r15, 3
  vpxor ymm1, ymm1, ymm2
  vpxor ymm5, ymm5, ymm6
  shr rax, 2
  vpslld ymm8, ymm1, 12
  lea rax, [rax + rax * 4]
  vpsrld ymm1, ymm1, 20
  vpslld ymm9, ymm5, 12
  add r13, rax
  vpsrld ymm5, ymm5, 20
  adc r14, 0
  vpor ymm1, ymm1, ymm8
  vpor ymm5, ymm5, ymm9
  adc r15, 0
  vpaddd ymm0, ymm0, ymm1
  add r13, [rsi + 64]
  vpaddd ymm4, ymm4, ymm5
  adc r14, [rsi + 72]
  vpxor ymm3, ymm3, ymm0
  vpxor ymm7, ymm7, ymm4
  adc r15, 1
  vpshufb ymm3, ymm3, ymm11
  mov rax, r13
  vpshufb ymm7, ymm7, ymm11
  vpaddd ymm2, ymm2, ymm3
  mul qword ptr [rbp + 24]
  vpaddd ymm6, ymm6, ymm7
  mov rbx, rax
  vpxor ymm1, ymm1, ymm2
  vpxor ymm5, ymm5, ymm6
  mov rcx, rdx
  vpslld ymm8, ymm1, 7
  mov rax, r14
  vpsrld ymm1, ymm1, 25
  mul qword ptr [rbp + 40]
  vpslld ymm9, ymm5, 7
  vpsrld ymm5, ymm5, 25
  add rbx, rax
  vpor ymm1, ymm1, ymm8
  adc rcx, rdx
  vpor ymm5, ymm5, ymm9
  vpshufd ymm1, ymm1, $93
  mov rax, r13
  vpshufd ymm5, ymm5, $93
  mul qword ptr [rbp + 32]
  vpshufd ymm2, ymm2, $4e
  vpshufd ymm6, ymm6, $4e
  mov r13, rbx
  vpshufd ymm3, ymm3, $39
  mov rbx, rax
  vpshufd ymm7, ymm7, $39
  vpaddd ymm0, ymm0, ymm1
  mov rdi, rdx
  vpaddd ymm4, ymm4, ymm5
  mov rax, r14
  vpxor ymm3, ymm3, ymm0
  mul qword ptr [rbp + 24]
  vpxor ymm7, ymm7, ymm4
  vpshufb ymm3, ymm3, ymm10
  add rbx, rax
  vpshufb ymm7, ymm7, ymm10
  adc rdi, rdx
  vpaddd ymm2, ymm2, ymm3
  vpaddd ymm6, ymm6, ymm7
  mov rax, r15
  vpxor ymm1, ymm1, ymm2
  imul rax, [rbp + 40]
  vpxor ymm5, ymm5, ymm6
  vpslld ymm8, ymm1, 12
  add rbx, rax
  vpsrld ymm1, ymm1, 20
  adc rdi, 0
  vpslld ymm9, ymm5, 12
  imul r15, [rbp + 24]
  vpsrld ymm5, ymm5, 20
  vpor ymm1, ymm1, ymm8
  add rbx, rcx
  vpor ymm5, ymm5, ymm9
  adc rdi, r15
  vpaddd ymm0, ymm0, ymm1
  vpaddd ymm4, ymm4, ymm5
  mov r14, rbx
  vpxor ymm3, ymm3, ymm0
  mov r15, rdi
  vpxor ymm7, ymm7, ymm4
  vpshufb ymm3, ymm3, ymm11
  mov rax, r15
  vpshufb ymm7, ymm7, ymm11
  and r15, 3
  vpaddd ymm2, ymm2, ymm3
  shr rax, 2
  vpaddd ymm6, ymm6, ymm7
  vpxor ymm1, ymm1, ymm2
  lea rax, [rax + rax * 4]
  vpxor ymm5, ymm5, ymm6
  add r13, rax
  vpslld ymm8, ymm1, 7
  vpsrld ymm1, ymm1, 25
  adc r14, 0
  vpslld ymm9, ymm5, 7
  adc r15, 0
  vpsrld ymm5, ymm5, 25
  vpor ymm1, ymm1, ymm8
  add r13, [rsi + 80]
  vpor ymm5, ymm5, ymm9
  adc r14, [rsi + 88]
  vpshufd ymm1, ymm1, $39
  vpshufd ymm5, ymm5, $39
  adc r15, 1
  vpshufd ymm2, ymm2, $4e
  mov rax, r13
  vpshufd ymm6, ymm6, $4e
  mul qword ptr [rbp + 24]
  vpshufd ymm3, ymm3, $93
  vpshufd ymm7, ymm7, $93
  mov rbx, rax
  vpaddd ymm0, ymm0, ymm1
  mov rcx, rdx
  vpaddd ymm4, ymm4, ymm5
  vpxor ymm3, ymm3, ymm0
  mov rax, r14
  vpxor ymm7, ymm7, ymm4
  mul qword ptr [rbp + 40]
  vpshufb ymm3, ymm3, ymm10
  vpshufb ymm7, ymm7, ymm10
  add rbx, rax
  vpaddd ymm2, ymm2, ymm3
  adc rcx, rdx
  vpaddd ymm6, ymm6, ymm7
  mov rax, r13
  vpxor ymm1, ymm1, ymm2
  vpxor ymm5, ymm5, ymm6
  mul qword ptr [rbp + 32]
  vpslld ymm8, ymm1, 12
  mov r13, rbx
  vpsrld ymm1, ymm1, 20
  vpslld ymm9, ymm5, 12
  mov rbx, rax
  vpsrld ymm5, ymm5, 20
  mov rdi, rdx
  vpor ymm1, ymm1, ymm8
  vpor ymm5, ymm5, ymm9
  mov rax, r14
  vpaddd ymm0, ymm0, ymm1
  mul qword ptr [rbp + 24]
  vpaddd ymm4, ymm4, ymm5
  add rbx, rax
  vpxor ymm3, ymm3, ymm0
  vpxor ymm7, ymm7, ymm4
  adc rdi, rdx
  vpshufb ymm3, ymm3, ymm11
  mov rax, r15
  vpshufb ymm7, ymm7, ymm11
  vpaddd ymm2, ymm2, ymm3
  imul rax, [rbp + 40]
  vpaddd ymm6, ymm6, ymm7
  add rbx, rax
  vpxor ymm1, ymm1, ymm2
  vpxor ymm5, ymm5, ymm6
  adc rdi, 0
  vpslld ymm8, ymm1, 7
  imul r15, [rbp + 24]
  vpsrld ymm1, ymm1, 25
  vpslld ymm9, ymm5, 7
  add rbx, rcx
  vpsrld ymm5, ymm5, 25
  adc rdi, r15
  vpor ymm1, ymm1, ymm8
  mov r14, rbx
  vpor ymm5, ymm5, ymm9
  vpshufd ymm1, ymm1, $93
  mov r15, rdi
  vpshufd ymm5, ymm5, $93
  mov rax, r15
  vpshufd ymm2, ymm2, $4e
  vpshufd ymm6, ymm6, $4e
  and r15, 3
  vpshufd ymm3, ymm3, $39
  shr rax, 2
  vpshufd ymm7, ymm7, $39
  vpaddd ymm0, ymm0, ymm1
  lea rax, [rax + rax * 4]
  vpaddd ymm4, ymm4, ymm5
  add r13, rax
  vpxor ymm3, ymm3, ymm0
  adc r14, 0
  vpxor ymm7, ymm7, ymm4
  vpshufb ymm3, ymm3, ymm10
  adc r15, 0
  vpshufb ymm7, ymm7, ymm10
  add r13, [rsi + 96]
  vpaddd ymm2, ymm2, ymm3
  vpaddd ymm6, ymm6, ymm7
  adc r14, [rsi + 104]
  vpxor ymm1, ymm1, ymm2
  adc r15, 1
  vpxor ymm5, ymm5, ymm6
  vpslld ymm8, ymm1, 12
  mov rax, r13
  vpsrld ymm1, ymm1, 20
  mul qword ptr [rbp + 24]
  vpslld ymm9, ymm5, 12
  mov rbx, rax
  vpsrld ymm5, ymm5, 20
  vpor ymm1, ymm1, ymm8
  mov rcx, rdx
  vpor ymm5, ymm5, ymm9
  mov rax, r14
  vpaddd ymm0, ymm0, ymm1
  vpaddd ymm4, ymm4, ymm5
  mul qword ptr [rbp + 40]
  vpxor ymm3, ymm3, ymm0
  add rbx, rax
  vpxor ymm7, ymm7, ymm4
  vpshufb ymm3, ymm3, ymm11
  adc rcx, rdx
  vpshufb ymm7, ymm7, ymm11
  mov rax, r13
  vpaddd ymm2, ymm2, ymm3
  mul qword ptr [rbp + 32]
  vpaddd ymm6, ymm6, ymm7
  vpxor ymm1, ymm1, ymm2
  mov r13, rbx
  vpxor ymm5, ymm5, ymm6
  mov rbx, rax
  vpslld ymm8, ymm1, 7
  vpsrld ymm1, ymm1, 25
  mov rdi, rdx
  vpslld ymm9, ymm5, 7
  mov rax, r14
  vpsrld ymm5, ymm5, 25
  vpor ymm1, ymm1, ymm8
  mul qword ptr [rbp + 24]
  vpor ymm5, ymm5, ymm9
  add rbx, rax
  vpshufd ymm1, ymm1, $39
  vpshufd ymm5, ymm5, $39
  adc rdi, rdx
  vpshufd ymm2, ymm2, $4e
  mov rax, r15
  vpshufd ymm6, ymm6, $4e
  imul rax, [rbp + 40]
  vpshufd ymm3, ymm3, $93
  vpshufd ymm7, ymm7, $93
  add rbx, rax
  vpaddd ymm0, ymm0, ymm1
  adc rdi, 0
  vpaddd ymm4, ymm4, ymm5
  vpxor ymm3, ymm3, ymm0
  imul r15, [rbp + 24]
  vpxor ymm7, ymm7, ymm4
  add rbx, rcx
  vpshufb ymm3, ymm3, ymm10
  vpshufb ymm7, ymm7, ymm10
  adc rdi, r15
  vpaddd ymm2, ymm2, ymm3
  mov r14, rbx
  vpaddd ymm6, ymm6, ymm7
  mov r15, rdi
  vpxor ymm1, ymm1, ymm2
  vpxor ymm5, ymm5, ymm6
  mov rax, r15
  vpslld ymm8, ymm1, 12
  and r15, 3
  vpsrld ymm1, ymm1, 20
  vpslld ymm9, ymm5, 12
  shr rax, 2
  vpsrld ymm5, ymm5, 20
  lea rax, [rax + rax * 4]
  vpor ymm1, ymm1, ymm8
  vpor ymm5, ymm5, ymm9
  add r13, rax
  vpaddd ymm0, ymm0, ymm1
  adc r14, 0
  vpaddd ymm4, ymm4, ymm5
  adc r15, 0
  vpxor ymm3, ymm3, ymm0
  vpxor ymm7, ymm7, ymm4
  add r13, [rsi + 112]
  vpshufb ymm3, ymm3, ymm11
  adc r14, [rsi + 120]
  vpshufb ymm7, ymm7, ymm11
  vpaddd ymm2, ymm2, ymm3
  adc r15, 1
  vpaddd ymm6, ymm6, ymm7
  mov rax, r13
  vpxor ymm1, ymm1, ymm2
  vpxor ymm5, ymm5, ymm6
  mul qword ptr [rbp + 24]
  vpslld ymm8, ymm1, 7
  mov rbx, rax
  vpsrld ymm1, ymm1, 25
  vpslld ymm9, ymm5, 7
  mov rcx, rdx
  vpsrld ymm5, ymm5, 25
  mov rax, r14
  vpor ymm1, ymm1, ymm8
  mul qword ptr [rbp + 40]
  vpor ymm5, ymm5, ymm9
  vpshufd ymm1, ymm1, $93
  add rbx, rax
  vpshufd ymm5, ymm5, $93
  adc rcx, rdx
  vpshufd ymm2, ymm2, $4e
  vpshufd ymm6, ymm6, $4e
  mov rax, r13
  vpshufd ymm3, ymm3, $39
  mul qword ptr [rbp + 32]
  vpshufd ymm7, ymm7, $39
  vpaddd ymm0, ymm0, ymm1
  mov r13, rbx
  vpaddd ymm4, ymm4, ymm5
  mov rbx, rax
  vpxor ymm3, ymm3, ymm0
  mov rdi, rdx
  vpxor ymm7, ymm7, ymm4
  vpshufb ymm3, ymm3, ymm10
  mov rax, r14
  vpshufb ymm7, ymm7, ymm10
  mul qword ptr [rbp + 24]
  vpaddd ymm2, ymm2, ymm3
  vpaddd ymm6, ymm6, ymm7
  add rbx, rax
  vpxor ymm1, ymm1, ymm2
  adc rdi, rdx
  vpxor ymm5, ymm5, ymm6
  vpslld ymm8, ymm1, 12
  mov rax, r15
  vpsrld ymm1, ymm1, 20
  imul rax, [rbp + 40]
  vpslld ymm9, ymm5, 12
  add rbx, rax
  vpsrld ymm5, ymm5, 20
  vpor ymm1, ymm1, ymm8
  adc rdi, 0
  vpor ymm5, ymm5, ymm9
  imul r15, [rbp + 24]
  vpaddd ymm0, ymm0, ymm1
  vpaddd ymm4, ymm4, ymm5
  add rbx, rcx
  vpxor ymm3, ymm3, ymm0
  adc rdi, r15
  vpxor ymm7, ymm7, ymm4
  vpshufb ymm3, ymm3, ymm11
  mov r14, rbx
  vpshufb ymm7, ymm7, ymm11
  mov r15, rdi
  vpaddd ymm2, ymm2, ymm3
  vpaddd ymm6, ymm6, ymm7
  mov rax, r15
  vpxor ymm1, ymm1, ymm2
  and r15, 3
  vpxor ymm5, ymm5, ymm6
  shr rax, 2
  vpslld ymm8, ymm1, 7
  vpsrld ymm1, ymm1, 25
  lea rax, [rax + rax * 4]
  vpslld ymm9, ymm5, 7
  add r13, rax
  vpsrld ymm5, ymm5, 25
  vpor ymm1, ymm1, ymm8
  adc r14, 0
  vpor ymm5, ymm5, ymm9
  adc r15, 0
  vpshufd ymm1, ymm1, $39
  vpshufd ymm5, ymm5, $39
  add r13, [rsi + 128]
  vpshufd ymm2, ymm2, $4e
  adc r14, [rsi + 136]
  vpshufd ymm6, ymm6, $4e
  adc r15, 1
  vpshufd ymm3, ymm3, $93
  vpshufd ymm7, ymm7, $93
  mov rax, r13
  vpaddd ymm0, ymm0, ymm1
  mul qword ptr [rbp + 24]
  vpaddd ymm4, ymm4, ymm5
  vpxor ymm3, ymm3, ymm0
  mov rbx, rax
  vpxor ymm7, ymm7, ymm4
  mov rcx, rdx
  vpshufb ymm3, ymm3, ymm10
  vpshufb ymm7, ymm7, ymm10
  mov rax, r14
  vpaddd ymm2, ymm2, ymm3
  mul qword ptr [rbp + 40]
  vpaddd ymm6, ymm6, ymm7
  add rbx, rax
  vpxor ymm1, ymm1, ymm2
  vpxor ymm5, ymm5, ymm6
  adc rcx, rdx
  vpslld ymm8, ymm1, 12
  mov rax, r13
  vpsrld ymm1, ymm1, 20
  vpslld ymm9, ymm5, 12
  mul qword ptr [rbp + 32]
  vpsrld ymm5, ymm5, 20
  mov r13, rbx
  vpor ymm1, ymm1, ymm8
  vpor ymm5, ymm5, ymm9
  mov rbx, rax
  vpaddd ymm0, ymm0, ymm1
  mov rdi, rdx
  vpaddd ymm4, ymm4, ymm5
  mov rax, r14
  vpxor ymm3, ymm3, ymm0
  vpxor ymm7, ymm7, ymm4
  mul qword ptr [rbp + 24]
  vpshufb ymm3, ymm3, ymm11
  add rbx, rax
  vpshufb ymm7, ymm7, ymm11
  vpaddd ymm2, ymm2, ymm3
  adc rdi, rdx
  vpaddd ymm6, ymm6, ymm7
  mov rax, r15
  vpxor ymm1, ymm1, ymm2
  vpxor ymm5, ymm5, ymm6
  imul rax, [rbp + 40]
  vpslld ymm8, ymm1, 7
  add rbx, rax
  vpsrld ymm1, ymm1, 25
  vpslld ymm9, ymm5, 7
  adc rdi, 0
  vpsrld ymm5, ymm5, 25
  imul r15, [rbp + 24]
  vpor ymm1, ymm1, ymm8
  add rbx, rcx
  vpor ymm5, ymm5, ymm9
  vpshufd ymm1, ymm1, $93
  adc rdi, r15
  vpshufd ymm5, ymm5, $93
  mov r14, rbx
  vpshufd ymm2, ymm2, $4e
  vpshufd ymm6, ymm6, $4e
  mov r15, rdi
  vpshufd ymm3, ymm3, $39
  mov rax, r15
  vpshufd ymm7, ymm7, $39
  vpaddd ymm0, ymm0, ymm1
  and r15, 3
  vpaddd ymm4, ymm4, ymm5
  shr rax, 2
  vpxor ymm3, ymm3, ymm0
  lea rax, [rax + rax * 4]
  vpxor ymm7, ymm7, ymm4
  vpshufb ymm3, ymm3, ymm10
  add r13, rax
  vpshufb ymm7, ymm7, ymm10
  adc r14, 0
  vpaddd ymm2, ymm2, ymm3
  vpaddd ymm6, ymm6, ymm7
  adc r15, 0
  vpxor ymm1, ymm1, ymm2
  add r13, [rsi + 144]
  vpxor ymm5, ymm5, ymm6
  vpslld ymm8, ymm1, 12
  adc r14, [rsi + 152]
  vpsrld ymm1, ymm1, 20
  adc r15, 1
  vpslld ymm9, ymm5, 12
  mov rax, r13
  vpsrld ymm5, ymm5, 20
  vpor ymm1, ymm1, ymm8
  mul qword ptr [rbp + 24]
  vpor ymm5, ymm5, ymm9
  mov rbx, rax
  vpaddd ymm0, ymm0, ymm1
  vpaddd ymm4, ymm4, ymm5
  mov rcx, rdx
  vpxor ymm3, ymm3, ymm0
  mov rax, r14
  vpxor ymm7, ymm7, ymm4
  vpshufb ymm3, ymm3, ymm11
  mul qword ptr [rbp + 40]
  vpshufb ymm7, ymm7, ymm11
  add rbx, rax
  vpaddd ymm2, ymm2, ymm3
  vpaddd ymm6, ymm6, ymm7
  adc rcx, rdx
  vpxor ymm1, ymm1, ymm2
  mov rax, r13
  vpxor ymm5, ymm5, ymm6
  mul qword ptr [rbp + 32]
  vpslld ymm8, ymm1, 7
  vpsrld ymm1, ymm1, 25
  mov r13, rbx
  vpslld ymm9, ymm5, 7
  mov rbx, rax
  vpsrld ymm5, ymm5, 25
  vpor ymm1, ymm1, ymm8
  mov rdi, rdx
  vpor ymm5, ymm5, ymm9
  mov rax, r14
  vpshufd ymm1, ymm1, $39
  vpshufd ymm5, ymm5, $39
  mul qword ptr [rbp + 24]
  vpshufd ymm2, ymm2, $4e
  add rbx, rax
  vpshufd ymm6, ymm6, $4e
  adc rdi, rdx
  vpshufd ymm3, ymm3, $93
  vpshufd ymm7, ymm7, $93
  mov rax, r15
  vpaddd ymm0, ymm0, ymm1
  imul rax, [rbp + 40]
  vpaddd ymm4, ymm4, ymm5
  vpxor ymm3, ymm3, ymm0
  add rbx, rax
  vpxor ymm7, ymm7, ymm4
  adc rdi, 0
  vpshufb ymm3, ymm3, ymm10
  vpshufb ymm7, ymm7, ymm10
  imul r15, [rbp + 24]
  vpaddd ymm2, ymm2, ymm3
  add rbx, rcx
  vpaddd ymm6, ymm6, ymm7
  adc rdi, r15
  vpxor ymm1, ymm1, ymm2
  vpxor ymm5, ymm5, ymm6
  mov r14, rbx
  vpslld ymm8, ymm1, 12
  mov r15, rdi
  vpsrld ymm1, ymm1, 20
  vpslld ymm9, ymm5, 12
  mov rax, r15
  vpsrld ymm5, ymm5, 20
  and r15, 3
  vpor ymm1, ymm1, ymm8
  vpor ymm5, ymm5, ymm9
  shr rax, 2
  vpaddd ymm0, ymm0, ymm1
  lea rax, [rax + rax * 4]
  vpaddd ymm4, ymm4, ymm5
  vpxor ymm3, ymm3, ymm0
  add r13, rax
  vpxor ymm7, ymm7, ymm4
  adc r14, 0
  vpshufb ymm3, ymm3, ymm11
  adc r15, 0
  vpshufb ymm7, ymm7, ymm11
  vpaddd ymm2, ymm2, ymm3
  add r13, [rsi + 160]
  vpaddd ymm6, ymm6, ymm7
  adc r14, [rsi + 168]
  vpxor ymm1, ymm1, ymm2
  vpxor ymm5, ymm5, ymm6
  adc r15, 1
  vpslld ymm8, ymm1, 7
  mov rax, r13
  vpsrld ymm1, ymm1, 25
  vpslld ymm9, ymm5, 7
  mul qword ptr [rbp + 24]
  vpsrld ymm5, ymm5, 25
  mov rbx, rax
  vpor ymm1, ymm1, ymm8
  mov rcx, rdx
  vpor ymm5, ymm5, ymm9
  vpshufd ymm1, ymm1, $93
  mov rax, r14
  vpshufd ymm5, ymm5, $93
  mul qword ptr [rbp + 40]
  vpshufd ymm2, ymm2, $4e
  vpshufd ymm6, ymm6, $4e
  add rbx, rax
  vpshufd ymm3, ymm3, $39
  adc rcx, rdx
  vpshufd ymm7, ymm7, $39
  vpaddd ymm0, ymm0, ymm1
  mov rax, r13
  vpaddd ymm4, ymm4, ymm5
  mul qword ptr [rbp + 32]
  vpxor ymm3, ymm3, ymm0
  mov r13, rbx
  vpxor ymm7, ymm7, ymm4
  vpshufb ymm3, ymm3, ymm10
  mov rbx, rax
  vpshufb ymm7, ymm7, ymm10
  mov rdi, rdx
  vpaddd ymm2, ymm2, ymm3
  vpaddd ymm6, ymm6, ymm7
  mov rax, r14
  vpxor ymm1, ymm1, ymm2
  mul qword ptr [rbp + 24]
  vpxor ymm5, ymm5, ymm6
  vpslld ymm8, ymm1, 12
  add rbx, rax
  vpsrld ymm1, ymm1, 20
  adc rdi, rdx
  vpslld ymm9, ymm5, 12
  mov rax, r15
  vpsrld ymm5, ymm5, 20
  vpor ymm1, ymm1, ymm8
  imul rax, [rbp + 40]
  vpor ymm5, ymm5, ymm9
  add rbx, rax
  vpaddd ymm0, ymm0, ymm1
  vpaddd ymm4, ymm4, ymm5
  adc rdi, 0
  vpxor ymm3, ymm3, ymm0
  imul r15, [rbp + 24]
  vpxor ymm7, ymm7, ymm4
  vpshufb ymm3, ymm3, ymm11
  add rbx, rcx
  vpshufb ymm7, ymm7, ymm11
  adc rdi, r15
  vpaddd ymm2, ymm2, ymm3
  vpaddd ymm6, ymm6, ymm7
  mov r14, rbx
  vpxor ymm1, ymm1, ymm2
  mov r15, rdi
  vpxor ymm5, ymm5, ymm6
  mov rax, r15
  vpslld ymm8, ymm1, 7
  vpsrld ymm1, ymm1, 25
  and r15, 3
  vpslld ymm9, ymm5, 7
  shr rax, 2
  vpsrld ymm5, ymm5, 25
  vpor ymm1, ymm1, ymm8
  lea rax, [rax + rax * 4]
  vpor ymm5, ymm5, ymm9
  add r13, rax
  vpshufd ymm1, ymm1, $39
  vpshufd ymm5, ymm5, $39
  adc r14, 0
  vpshufd ymm2, ymm2, $4e
  adc r15, 0
  vpshufd ymm6, ymm6, $4e
  add r13, [rsi + 176]
  vpshufd ymm3, ymm3, $93
  vpshufd ymm7, ymm7, $93
  adc r14, [rsi + 184]
  vpaddd ymm0, ymm0, ymm1
  adc r15, 1
  vpaddd ymm4, ymm4, ymm5
  vpxor ymm3, ymm3, ymm0
  mov rax, r13
  vpxor ymm7, ymm7, ymm4
  mul qword ptr [rbp + 24]
  vpshufb ymm3, ymm3, ymm10
  vpshufb ymm7, ymm7, ymm10
  mov rbx, rax
  vpaddd ymm2, ymm2, ymm3
  mov rcx, rdx
  vpaddd ymm6, ymm6, ymm7
  mov rax, r14
  vpxor ymm1, ymm1, ymm2
  vpxor ymm5, ymm5, ymm6
  mul qword ptr [rbp + 40]
  vpslld ymm8, ymm1, 12
  add rbx, rax
  vpsrld ymm1, ymm1, 20
  vpslld ymm9, ymm5, 12
  adc rcx, rdx
  vpsrld ymm5, ymm5, 20
  mov rax, r13
  vpor ymm1, ymm1, ymm8
  vpor ymm5, ymm5, ymm9
  mul qword ptr [rbp + 32]
  vpaddd ymm0, ymm0, ymm1
  mov r13, rbx
  vpaddd ymm4, ymm4, ymm5
  vpxor ymm3, ymm3, ymm0
  mov rbx, rax
  vpxor ymm7, ymm7, ymm4
  mov rdi, rdx
  vpshufb ymm3, ymm3, ymm11
  mov rax, r14
  vpshufb ymm7, ymm7, ymm11
  vpaddd ymm2, ymm2, ymm3
  mul qword ptr [rbp + 24]
  vpaddd ymm6, ymm6, ymm7
  add rbx, rax
  vpxor ymm1, ymm1, ymm2
  vpxor ymm5, ymm5, ymm6
  adc rdi, rdx
  vpslld ymm8, ymm1, 7
  mov rax, r15
  vpsrld ymm1, ymm1, 25
  vpslld ymm9, ymm5, 7
  imul rax, [rbp + 40]
  vpsrld ymm5, ymm5, 25
  add rbx, rax
  vpor ymm1, ymm1, ymm8
  adc rdi, 0
  vpor ymm5, ymm5, ymm9
  vpshufd ymm1, ymm1, $93
  imul r15, [rbp + 24]
  vpshufd ymm5, ymm5, $93
  add rbx, rcx
  vpshufd ymm2, ymm2, $4e
  vpshufd ymm6, ymm6, $4e
  adc rdi, r15
  vpshufd ymm3, ymm3, $39
  mov r14, rbx
  vpshufd ymm7, ymm7, $39
  vpaddd ymm0, ymm0, ymm1
  mov r15, rdi
  vpaddd ymm4, ymm4, ymm5
  mov rax, r15
  vpxor ymm3, ymm3, ymm0
  and r15, 3
  vpxor ymm7, ymm7, ymm4
  vpshufb ymm3, ymm3, ymm10
  shr rax, 2
  vpshufb ymm7, ymm7, ymm10
  lea rax, [rax + rax * 4]
  vpaddd ymm2, ymm2, ymm3
  vpaddd ymm6, ymm6, ymm7
  add r13, rax
  vpxor ymm1, ymm1, ymm2
  adc r14, 0
  vpxor ymm5, ymm5, ymm6
  vpslld ymm8, ymm1, 12
  adc r15, 0
  vpsrld ymm1, ymm1, 20
  add r13, [rsi + 192]
  vpslld ymm9, ymm5, 12
  adc r14, [rsi + 200]
  vpsrld ymm5, ymm5, 20
  vpor ymm1, ymm1, ymm8
  adc r15, 1
  vpor ymm5, ymm5, ymm9
  mov rax, r13
  vpaddd ymm0, ymm0, ymm1
  vpaddd ymm4, ymm4, ymm5
  mul qword ptr [rbp + 24]
  vpxor ymm3, ymm3, ymm0
  mov rbx, rax
  vpxor ymm7, ymm7, ymm4
  vpshufb ymm3, ymm3, ymm11
  mov rcx, rdx
  vpshufb ymm7, ymm7, ymm11
  mov rax, r14
  vpaddd ymm2, ymm2, ymm3
  vpaddd ymm6, ymm6, ymm7
  mul qword ptr [rbp + 40]
  vpxor ymm1, ymm1, ymm2
  add rbx, rax
  vpxor ymm5, ymm5, ymm6
  adc rcx, rdx
  vpslld ymm8, ymm1, 7
  vpsrld ymm1, ymm1, 25
  mov rax, r13
  vpslld ymm9, ymm5, 7
  mul qword ptr [rbp + 32]
  vpsrld ymm5, ymm5, 25
  vpor ymm1, ymm1, ymm8
  mov r13, rbx
  vpor ymm5, ymm5, ymm9
  mov rbx, rax
  vpshufd ymm1, ymm1, $39
  vpshufd ymm5, ymm5, $39
  mov rdi, rdx
  vpshufd ymm2, ymm2, $4e
  mov rax, r14
  vpshufd ymm6, ymm6, $4e
  mul qword ptr [rbp + 24]
  vpshufd ymm3, ymm3, $93
  vpshufd ymm7, ymm7, $93
  add rbx, rax
  vpaddd ymm0, ymm0, ymm1
  adc rdi, rdx
  vpaddd ymm4, ymm4, ymm5
  vpxor ymm3, ymm3, ymm0
  mov rax, r15
  vpxor ymm7, ymm7, ymm4
  imul rax, [rbp + 40]
  vpshufb ymm3, ymm3, ymm10
  vpshufb ymm7, ymm7, ymm10
  add rbx, rax
  vpaddd ymm2, ymm2, ymm3
  adc rdi, 0
  vpaddd ymm6, ymm6, ymm7
  imul r15, [rbp + 24]
  vpxor ymm1, ymm1, ymm2
  vpxor ymm5, ymm5, ymm6
  add rbx, rcx
  vpslld ymm8, ymm1, 12
  adc rdi, r15
  vpsrld ymm1, ymm1, 20
  vpslld ymm9, ymm5, 12
  mov r14, rbx
  vpsrld ymm5, ymm5, 20
  mov r15, rdi
  vpor ymm1, ymm1, ymm8
  vpor ymm5, ymm5, ymm9
  mov rax, r15
  vpaddd ymm0, ymm0, ymm1
  and r15, 3
  vpaddd ymm4, ymm4, ymm5
  vpxor ymm3, ymm3, ymm0
  shr rax, 2
  vpxor ymm7, ymm7, ymm4
  lea rax, [rax + rax * 4]
  vpshufb ymm3, ymm3, ymm11
  add r13, rax
  vpshufb ymm7, ymm7, ymm11
  vpaddd ymm2, ymm2, ymm3
  adc r14, 0
  vpaddd ymm6, ymm6, ymm7
  adc r15, 0
  vpxor ymm1, ymm1, ymm2
  vpxor ymm5, ymm5, ymm6
  add r13, [rsi + 208]
  vpslld ymm8, ymm1, 7
  adc r14, [rsi + 216]
  vpsrld ymm1, ymm1, 25
  vpslld ymm9, ymm5, 7
  adc r15, 1
  vpsrld ymm5, ymm5, 25
  mov rax, r13
  vpor ymm1, ymm1, ymm8
  mul qword ptr [rbp + 24]
  vpor ymm5, ymm5, ymm9
  vpshufd ymm1, ymm1, $93
  mov rbx, rax
  vpshufd ymm5, ymm5, $93
  mov rcx, rdx
  vpshufd ymm2, ymm2, $4e
  vpshufd ymm6, ymm6, $4e
  mov rax, r14
  vpshufd ymm3, ymm3, $39
  mul qword ptr [rbp + 40]
  vpshufd ymm7, ymm7, $39
  vpaddd ymm0, ymm0, ymm1
  add rbx, rax
  vpaddd ymm4, ymm4, ymm5
  adc rcx, rdx
  vpxor ymm3, ymm3, ymm0
  mov rax, r13
  vpxor ymm7, ymm7, ymm4
  vpshufb ymm3, ymm3, ymm10
  mul qword ptr [rbp + 32]
  vpshufb ymm7, ymm7, ymm10
  mov r13, rbx
  vpaddd ymm2, ymm2, ymm3
  vpaddd ymm6, ymm6, ymm7
  mov rbx, rax
  vpxor ymm1, ymm1, ymm2
  mov rdi, rdx
  vpxor ymm5, ymm5, ymm6
  vpslld ymm8, ymm1, 12
  mov rax, r14
  vpsrld ymm1, ymm1, 20
  mul qword ptr [rbp + 24]
  vpslld ymm9, ymm5, 12
  vpsrld ymm5, ymm5, 20
  add rbx, rax
  vpor ymm1, ymm1, ymm8
  adc rdi, rdx
  vpor ymm5, ymm5, ymm9
  mov rax, r15
  vpaddd ymm0, ymm0, ymm1
  vpaddd ymm4, ymm4, ymm5
  imul rax, [rbp + 40]
  vpxor ymm3, ymm3, ymm0
  add rbx, rax
  vpxor ymm7, ymm7, ymm4
  vpshufb ymm3, ymm3, ymm11
  adc rdi, 0
  vpshufb ymm7, ymm7, ymm11
  imul r15, [rbp + 24]
  vpaddd ymm2, ymm2, ymm3
  vpaddd ymm6, ymm6, ymm7
  add rbx, rcx
  vpxor ymm1, ymm1, ymm2
  adc rdi, r15
  vpxor ymm5, ymm5, ymm6
  mov r14, rbx
  vpslld ymm8, ymm1, 7
  vpsrld ymm1, ymm1, 25
  mov r15, rdi
  vpslld ymm9, ymm5, 7
  mov rax, r15
  vpsrld ymm5, ymm5, 25
  vpor ymm1, ymm1, ymm8
  and r15, 3
  vpor ymm5, ymm5, ymm9
  shr rax, 2
  vpshufd ymm1, ymm1, $39
  vpshufd ymm5, ymm5, $39
  lea rax, [rax + rax * 4]
  vpshufd ymm2, ymm2, $4e
  add r13, rax
  vpshufd ymm6, ymm6, $4e
  adc r14, 0
  vpshufd ymm3, ymm3, $93
  vpshufd ymm7, ymm7, $93
  adc r15, 0
  vpaddd ymm0, ymm0, ymm1
  add r13, [rsi + 224]
  vpaddd ymm4, ymm4, ymm5
  vpxor ymm3, ymm3, ymm0
  adc r14, [rsi + 232]
  vpxor ymm7, ymm7, ymm4
  adc r15, 1
  vpshufb ymm3, ymm3, ymm10
  vpshufb ymm7, ymm7, ymm10
  mov rax, r13
  vpaddd ymm2, ymm2, ymm3
  mul qword ptr [rbp + 24]
  vpaddd ymm6, ymm6, ymm7
  mov rbx, rax
  vpxor ymm1, ymm1, ymm2
  vpxor ymm5, ymm5, ymm6
  mov rcx, rdx
  vpslld ymm8, ymm1, 12
  mov rax, r14
  vpsrld ymm1, ymm1, 20
  vpslld ymm9, ymm5, 12
  mul qword ptr [rbp + 40]
  vpsrld ymm5, ymm5, 20
  add rbx, rax
  vpor ymm1, ymm1, ymm8
  vpor ymm5, ymm5, ymm9
  adc rcx, rdx
  vpaddd ymm0, ymm0, ymm1
  mov rax, r13
  vpaddd ymm4, ymm4, ymm5
  vpxor ymm3, ymm3, ymm0
  mul qword ptr [rbp + 32]
  vpxor ymm7, ymm7, ymm4
  mov r13, rbx
  vpshufb ymm3, ymm3, ymm11
  mov rbx, rax
  vpshufb ymm7, ymm7, ymm11
  vpaddd ymm2, ymm2, ymm3
  mov rdi, rdx
  vpaddd ymm6, ymm6, ymm7
  mov rax, r14
  vpxor ymm1, ymm1, ymm2
  vpxor ymm5, ymm5, ymm6
  mul qword ptr [rbp + 24]
  vpslld ymm8, ymm1, 7
  add rbx, rax
  vpsrld ymm1, ymm1, 25
  vpslld ymm9, ymm5, 7
  adc rdi, rdx
  vpsrld ymm5, ymm5, 25
  mov rax, r15
  vpor ymm1, ymm1, ymm8
  imul rax, [rbp + 40]
  vpor ymm5, ymm5, ymm9
  vpshufd ymm1, ymm1, $93
  add rbx, rax
  vpshufd ymm5, ymm5, $93
  adc rdi, 0
  vpshufd ymm2, ymm2, $4e
  vpshufd ymm6, ymm6, $4e
  imul r15, [rbp + 24]
  vpshufd ymm3, ymm3, $39
  add rbx, rcx
  vpshufd ymm7, ymm7, $39
  adc rdi, r15
  mov r14, rbx
  mov r15, rdi
  mov rax, r15
  and r15, 3
  shr rax, 2
  lea rax, [rax + rax * 4]
  add r13, rax
  adc r14, 0
  adc r15, 0
  add r13, [rsi + 240]
  adc r14, [rsi + 248]
  adc r15, 1
  mov rax, r13
  mul qword ptr [rbp + 24]
  mov rbx, rax
  mov rcx, rdx
  mov rax, r14
  mul qword ptr [rbp + 40]
  add rbx, rax
  adc rcx, rdx
  mov rax, r13
  mul qword ptr [rbp + 32]
  mov r13, rbx
  mov rbx, rax
  mov rdi, rdx
  mov rax, r14
  mul qword ptr [rbp + 24]
  add rbx, rax
  adc rdi, rdx
  mov rax, r15
  imul rax, [rbp + 40]
  add rbx, rax
  adc rdi, 0
  imul r15, [rbp + 24]
  add rbx, rcx
  adc rdi, r15
  mov r14, rbx
  mov r15, rdi
  mov rax, r15
  and r15, 3
  shr rax, 2
  lea rax, [rax + rax * 4]
  add r13, rax
  adc r14, 0
  adc r15, 0
  // + estado inicial
  vpaddd ymm0, ymm0, ymm12
  vpaddd ymm1, ymm1, ymm13
  vpaddd ymm2, ymm2, ymm14
  vpaddd ymm3, ymm3, ymm15
  vpaddd ymm4, ymm4, ymm12
  vpaddd ymm5, ymm5, ymm13
  vpaddd ymm6, ymm6, ymm14
  vpaddd ymm7, ymm7, ymm15
  vpaddd ymm7, ymm7, [r10 + 160]
  // bloque n: mitades bajas; n+1: altas
  vperm2i128 ymm8, ymm0, ymm1, $20
  vperm2i128 ymm9, ymm2, ymm3, $20
  vpxor ymm8, ymm8, [r11]
  vpxor ymm9, ymm9, [r11 + 32]
  vmovdqu [r8], ymm8
  vmovdqu [r8 + 32], ymm9
  vperm2i128 ymm8, ymm0, ymm1, $31
  vperm2i128 ymm9, ymm2, ymm3, $31
  vpxor ymm8, ymm8, [r11 + 64]
  vpxor ymm9, ymm9, [r11 + 96]
  vmovdqu [r8 + 64], ymm8
  vmovdqu [r8 + 96], ymm9
  vperm2i128 ymm8, ymm4, ymm5, $20
  vperm2i128 ymm9, ymm6, ymm7, $20
  vpxor ymm8, ymm8, [r11 + 128]
  vpxor ymm9, ymm9, [r11 + 160]
  vmovdqu [r8 + 128], ymm8
  vmovdqu [r8 + 160], ymm9
  vperm2i128 ymm8, ymm4, ymm5, $31
  vperm2i128 ymm9, ymm6, ymm7, $31
  vpxor ymm8, ymm8, [r11 + 192]
  vpxor ymm9, ymm9, [r11 + 224]
  vmovdqu [r8 + 192], ymm8
  vmovdqu [r8 + 224], ymm9
  vpaddd ymm15, ymm15, [r10 + 192]
  add rsi, 256
  add r11, 256
  add r8, 256
  dec r9
  jnz @loop
  vzeroupper
  mov [rbp], r13
  mov [rbp + 8], r14
  mov [rbp + 16], r15
  mov [r10 + 392], rsi
  mov rbx, [r10 + 400]
  mov rbp, [r10 + 408]
  mov r12, [r10 + 432]
  mov r13, [r10 + 440]
  mov r14, [r10 + 448]
  mov r15, [r10 + 456]
  {$IFDEF WIN64}
  mov rsi, [r10 + 416]
  mov rdi, [r10 + 424]
  movdqu xmm6, [r10 + 224]
  movdqu xmm7, [r10 + 240]
  movdqu xmm8, [r10 + 256]
  movdqu xmm9, [r10 + 272]
  movdqu xmm10, [r10 + 288]
  movdqu xmm11, [r10 + 304]
  movdqu xmm12, [r10 + 320]
  movdqu xmm13, [r10 + 336]
  movdqu xmm14, [r10 + 352]
  movdqu xmm15, [r10 + 368]
  {$ENDIF}
end;

var
  AsmConst: TChaAsmCtx;   // las constantes (Rot16, Rot8, Inc*); el estado va en una copia local

procedure InitAsmConst;
var
  i, j: Integer;
begin
  FillChar(AsmConst, SizeOf(AsmConst), 0);
  for i := 0 to 7 do
    for j := 0 to 3 do
    begin
      AsmConst.Rot16[4 * i + j] := 4 * (i mod 4) + (j + 2) mod 4;
      AsmConst.Rot8[4 * i + j] := 4 * (i mod 4) + (j + 3) mod 4;
    end;
  AsmConst.Inc01[4] := 1;
  AsmConst.Inc2[0] := 2; AsmConst.Inc2[4] := 2;
  AsmConst.Inc4[0] := 4; AsmConst.Inc4[4] := 4;
end;
{$ENDIF}

{ Dst := Src xor keystream desde el estado S; S[12] avanza un bloque por cada 64 bytes. }
procedure ChaXor(var S: TChaState; Src, Dst: PByte; Len: SizeInt);
var
  Ks: array[0..63] of Byte;
  x: TChaState;
  i, n: SizeInt;
  {$IFDEF CHACHA_ASM}
  Ctx: TChaAsmCtx;
  g: SizeUInt;
  {$ENDIF}
begin
  {$IFDEF CHACHA_ASM}
  if UseAvx2 and (Len >= 256) then
  begin
    Ctx := AsmConst;
    Ctx.State := S;
    g := Len div 256;
    ChaChaAvx2(@Ctx, Src, Dst, g);
    Inc(S[12], LongWord(4 * g));
    Inc(Src, 256 * g);
    Inc(Dst, 256 * g);
    Dec(Len, 256 * g);
    FillChar(Ctx.State, SizeOf(Ctx.State), 0);
  end;
  {$ENDIF}
  {$IFDEF ENDIAN_LITTLE}
  // bloques enteros: de a palabras, sin pasar por Ks
  while Len >= 64 do
  begin
    x := S;
    ChaRounds(x);
    for i := 0 to 15 do PLongWord(Dst)[i] := PLongWord(Src)[i] xor (x[i] + S[i]);
    Inc(S[12]);
    Inc(Src, 64);
    Inc(Dst, 64);
    Dec(Len, 64);
  end;
  FillChar(x, SizeOf(x), 0);
  {$ENDIF}
  while Len > 0 do
  begin
    ChaBlock(S, @Ks[0]);
    Inc(S[12]);
    if Len < 64 then n := Len else n := 64;
    for i := 0 to n - 1 do Dst[i] := Src[i] xor Ks[i];
    Inc(Src, n);
    Inc(Dst, n);
    Dec(Len, n);
  end;
  FillChar(Ks, SizeOf(Ks), 0);
end;

procedure ChaCha20Xor(Key, Nonce12: PByte; Counter: LongWord; Src, Dst: PByte; Len: SizeInt);
var
  S: TChaState;
begin
  ChaInit(S, Key, Nonce12, Counter);
  ChaXor(S, Src, Dst, Len);
  FillChar(S, SizeOf(S), 0);
end;

procedure ChaCha20Block(Key, Nonce12: PByte; Counter: LongWord; Out64: PByte);
var
  S: TChaState;
begin
  ChaInit(S, Key, Nonce12, Counter);
  ChaBlock(S, Out64);
end;

procedure HChaCha20(Key, Nonce16, Out32: PByte);
var
  x: TChaState;
  i: Integer;
begin
  for i := 0 to 3 do x[i] := SIGMA[i];
  for i := 0 to 7 do x[4 + i] := LoadLE32(Key + 4 * i);
  for i := 0 to 3 do x[12 + i] := LoadLE32(Nonce16 + 4 * i);
  ChaRounds(x);
  // sin sumar el estado inicial: las filas 0 y 3
  for i := 0 to 3 do StoreLE32(Out32 + 4 * i, x[i]);
  for i := 0 to 3 do StoreLE32(Out32 + 16 + 4 * i, x[12 + i]);
  FillChar(x, SizeOf(x), 0);
end;

function ChaChaUsesAvx2: Boolean;
begin
  Result := UseAvx2;
end;

{ ------------------------------------------------------------------------------ Poly1305 }

{$IFDEF CHACHA_ASM}
{ Blocks bloques de 16 bytes; HiBit = 1 (bloque entero) o 0 (el último, ya relleno con 1 y
  ceros). Acumulación en base 2^64 con reducción parcial (h < 2^130 + algo): h2 queda chico, así
  que h2·s1 y h2·r0 entran en 64 bits. Preserva rbx, rbp, r12-r15 (y rdi, rsi en Win64) en P.Save. }
procedure PolyBlocksAsm(P: Pointer; Data: PByte; Blocks: SizeUInt; HiBit: QWord); assembler; nostackframe;
asm
  {$IFDEF WIN64}
  mov [rcx + 48], rbx
  mov [rcx + 56], rbp
  mov [rcx + 64], r12
  mov [rcx + 72], r13
  mov [rcx + 80], r14
  mov [rcx + 88], r15
  mov [rcx + 96], rdi
  mov [rcx + 104], rsi
  mov rdi, rcx
  mov rsi, rdx
  mov r15, r8
  mov r14, r9
  {$ELSE}
  mov [rdi + 48], rbx
  mov [rdi + 56], rbp
  mov [rdi + 64], r12
  mov [rdi + 72], r13
  mov [rdi + 80], r14
  mov [rdi + 88], r15
  mov r15, rdx
  mov r14, rcx
  {$ENDIF}
  // rdi = estado, rsi = datos, r15 = bloques, r14 = bit alto
  mov r9, [rdi]           // h0
  mov r10, [rdi + 8]      // h1
  mov r11, [rdi + 16]     // h2
  mov r12, [rdi + 24]     // r0
  mov r13, [rdi + 32]     // r1
  mov rbp, [rdi + 40]     // s1
  test r15, r15
  jz @done
@loop:
  add r9, [rsi]
  adc r10, [rsi + 8]
  adc r11, r14
  // t0 = h0·r0 + h1·s1  (rbx:rcx)
  mov rax, r9
  mul r12
  mov rbx, rax
  mov rcx, rdx
  mov rax, r10
  mul rbp
  add rbx, rax
  adc rcx, rdx
  // t1 = h0·r1 + h1·r0 + h2·s1  (r8:rdx -> r8 alto)
  mov rax, r9
  mul r13
  mov r9, rbx             // h0 = t0 bajo
  mov rbx, rax
  mov r8, rdx
  mov rax, r10
  mul r12
  add rbx, rax
  adc r8, rdx
  mov rax, r11
  imul rax, rbp
  add rbx, rax
  adc r8, 0
  // t2 = h2·r0
  imul r11, r12
  // h1 = t0 alto + t1 bajo; h2 = t1 alto + t2 + acarreo
  add rbx, rcx
  adc r8, r11
  mov r10, rbx
  mov r11, r8
  // reducción parcial: lo que pasa de 2^130 vuelve multiplicado por 5
  mov rax, r11
  and r11, 3
  shr rax, 2
  lea rax, [rax + rax * 4]
  add r9, rax
  adc r10, 0
  adc r11, 0
  add rsi, 16
  dec r15
  jnz @loop
@done:
  mov [rdi], r9
  mov [rdi + 8], r10
  mov [rdi + 16], r11
  mov rbx, [rdi + 48]
  mov rbp, [rdi + 56]
  mov r12, [rdi + 64]
  mov r13, [rdi + 72]
  mov r14, [rdi + 80]
  mov r15, [rdi + 88]
  {$IFDEF WIN64}
  mov rsi, [rdi + 104]
  mov rdi, [rdi + 96]
  {$ENDIF}
end;

procedure PolyBlocks(var P: TPoly1305; Data: PByte; Blocks: SizeUInt; HiBit: LongWord); inline;
begin
  PolyBlocksAsm(@P, Data, Blocks, HiBit);
end;

procedure Poly1305Init(out P: TPoly1305; Key: PByte);
var
  i: Integer;
begin
  FillChar(P, SizeOf(P), 0);
  P.R0 := PQWord(Key)^ and QWord($0ffffffc0fffffff);
  P.R1 := PQWord(Key + 8)^ and QWord($0ffffffc0ffffffc);
  P.S1 := P.R1 + (P.R1 shr 2);
  for i := 0 to 3 do P.Pad[i] := LoadLE32(Key + 16 + 4 * i);
end;

procedure Poly1305Final(var P: TPoly1305; Tag: PByte);
var
  g0, g1, g2, c, m, t: QWord;
begin
  if P.BufLen > 0 then
  begin
    P.Buf[P.BufLen] := 1;
    FillChar(P.Buf[P.BufLen + 1], 15 - P.BufLen, 0);
    PolyBlocks(P, @P.Buf[0], 1, 0);
  end;
  // reducción completa: h < 2p, así que basta restar p una vez (g = h + 5 - 2^130)
  g0 := P.H0 + 5;
  c := Ord(g0 < 5);
  g1 := P.H1 + c;
  c := Ord(g1 < c);
  g2 := P.H2 + c;
  m := QWord(0) - (g2 shr 2);         // todo unos si g >= 2^130 (h >= p)
  m := m and 1;
  m := QWord(0) - m;
  g0 := (g0 and m) or (P.H0 and not m);
  g1 := (g1 and m) or (P.H1 and not m);
  // + s (mod 2^128)
  t := g0 + (QWord(P.Pad[0]) or (QWord(P.Pad[1]) shl 32));
  c := Ord(t < g0);
  g0 := t;
  g1 := g1 + (QWord(P.Pad[2]) or (QWord(P.Pad[3]) shl 32)) + c;
  StoreLE64(Tag, g0);
  StoreLE64(Tag + 8, g1);
  FillChar(P, SizeOf(P), 0);
end;

{$ELSE}

procedure PolyBlocks(var P: TPoly1305; Data: PByte; Blocks: SizeUInt; HiBit: LongWord);
var
  h0, h1, h2, h3, h4, r0, r1, r2, r3, r4, s1, s2, s3, s4, c: LongWord;
  d0, d1, d2, d3, d4: QWord;
  hb: LongWord;
begin
  hb := HiBit shl 24;
  r0 := P.R[0]; r1 := P.R[1]; r2 := P.R[2]; r3 := P.R[3]; r4 := P.R[4];
  s1 := r1 * 5; s2 := r2 * 5; s3 := r3 * 5; s4 := r4 * 5;
  h0 := P.H[0]; h1 := P.H[1]; h2 := P.H[2]; h3 := P.H[3]; h4 := P.H[4];
  while Blocks > 0 do
  begin
    h0 := h0 + (LoadLE32(Data) and $3ffffff);
    h1 := h1 + ((LoadLE32(Data + 3) shr 2) and $3ffffff);
    h2 := h2 + ((LoadLE32(Data + 6) shr 4) and $3ffffff);
    h3 := h3 + ((LoadLE32(Data + 9) shr 6) and $3ffffff);
    h4 := h4 + ((LoadLE32(Data + 12) shr 8) or hb);
    d0 := QWord(h0) * r0 + QWord(h1) * s4 + QWord(h2) * s3 + QWord(h3) * s2 + QWord(h4) * s1;
    d1 := QWord(h0) * r1 + QWord(h1) * r0 + QWord(h2) * s4 + QWord(h3) * s3 + QWord(h4) * s2;
    d2 := QWord(h0) * r2 + QWord(h1) * r1 + QWord(h2) * r0 + QWord(h3) * s4 + QWord(h4) * s3;
    d3 := QWord(h0) * r3 + QWord(h1) * r2 + QWord(h2) * r1 + QWord(h3) * r0 + QWord(h4) * s4;
    d4 := QWord(h0) * r4 + QWord(h1) * r3 + QWord(h2) * r2 + QWord(h3) * r1 + QWord(h4) * r0;
    c := LongWord(d0 shr 26); h0 := LongWord(d0) and $3ffffff;
    d1 := d1 + c; c := LongWord(d1 shr 26); h1 := LongWord(d1) and $3ffffff;
    d2 := d2 + c; c := LongWord(d2 shr 26); h2 := LongWord(d2) and $3ffffff;
    d3 := d3 + c; c := LongWord(d3 shr 26); h3 := LongWord(d3) and $3ffffff;
    d4 := d4 + c; c := LongWord(d4 shr 26); h4 := LongWord(d4) and $3ffffff;
    h0 := h0 + c * 5; c := h0 shr 26; h0 := h0 and $3ffffff;
    h1 := h1 + c;
    Inc(Data, 16);
    Dec(Blocks);
  end;
  P.H[0] := h0; P.H[1] := h1; P.H[2] := h2; P.H[3] := h3; P.H[4] := h4;
end;

procedure Poly1305Init(out P: TPoly1305; Key: PByte);
var
  i: Integer;
begin
  FillChar(P, SizeOf(P), 0);
  // r recortado (RFC 8439 §2.5), en limbs de 26 bits
  P.R[0] := LoadLE32(Key) and $3ffffff;
  P.R[1] := (LoadLE32(Key + 3) shr 2) and $3ffff03;
  P.R[2] := (LoadLE32(Key + 6) shr 4) and $3ffc0ff;
  P.R[3] := (LoadLE32(Key + 9) shr 6) and $3f03fff;
  P.R[4] := (LoadLE32(Key + 12) shr 8) and $00fffff;
  for i := 0 to 3 do P.Pad[i] := LoadLE32(Key + 16 + 4 * i);
end;

procedure Poly1305Final(var P: TPoly1305; Tag: PByte);
var
  h0, h1, h2, h3, h4, c, g0, g1, g2, g3, g4, m: LongWord;
  f: QWord;
begin
  if P.BufLen > 0 then
  begin
    P.Buf[P.BufLen] := 1;
    FillChar(P.Buf[P.BufLen + 1], 15 - P.BufLen, 0);
    PolyBlocks(P, @P.Buf[0], 1, 0);
  end;
  h0 := P.H[0]; h1 := P.H[1]; h2 := P.H[2]; h3 := P.H[3]; h4 := P.H[4];
  // acarreo completo
  c := h1 shr 26; h1 := h1 and $3ffffff;
  h2 := h2 + c; c := h2 shr 26; h2 := h2 and $3ffffff;
  h3 := h3 + c; c := h3 shr 26; h3 := h3 and $3ffffff;
  h4 := h4 + c; c := h4 shr 26; h4 := h4 and $3ffffff;
  h0 := h0 + c * 5; c := h0 shr 26; h0 := h0 and $3ffffff;
  h1 := h1 + c;
  // g = h + 5 - 2^130; si no hubo préstamo, h >= p y se toma g
  g0 := h0 + 5; c := g0 shr 26; g0 := g0 and $3ffffff;
  g1 := h1 + c; c := g1 shr 26; g1 := g1 and $3ffffff;
  g2 := h2 + c; c := g2 shr 26; g2 := g2 and $3ffffff;
  g3 := h3 + c; c := g3 shr 26; g3 := g3 and $3ffffff;
  g4 := h4 + c - (1 shl 26);
  m := (g4 shr 31) - 1;     // todo unos si g4 >= 0
  g0 := g0 and m; g1 := g1 and m; g2 := g2 and m; g3 := g3 and m; g4 := g4 and m;
  m := not m;
  h0 := (h0 and m) or g0; h1 := (h1 and m) or g1; h2 := (h2 and m) or g2;
  h3 := (h3 and m) or g3; h4 := (h4 and m) or g4;
  // a cuatro palabras de 32 bits, + s
  h0 := h0 or (h1 shl 26);
  h1 := (h1 shr 6) or (h2 shl 20);
  h2 := (h2 shr 12) or (h3 shl 14);
  h3 := (h3 shr 18) or (h4 shl 8);
  f := QWord(h0) + P.Pad[0];             h0 := LongWord(f);
  f := QWord(h1) + P.Pad[1] + (f shr 32); h1 := LongWord(f);
  f := QWord(h2) + P.Pad[2] + (f shr 32); h2 := LongWord(f);
  f := QWord(h3) + P.Pad[3] + (f shr 32); h3 := LongWord(f);
  StoreLE32(Tag, h0); StoreLE32(Tag + 4, h1); StoreLE32(Tag + 8, h2); StoreLE32(Tag + 12, h3);
  FillChar(P, SizeOf(P), 0);
end;
{$ENDIF}

procedure Poly1305Update(var P: TPoly1305; Data: PByte; Len: SizeInt);
var
  n: SizeInt;
begin
  if P.BufLen > 0 then
  begin
    n := 16 - P.BufLen;
    if n > Len then n := Len;
    Move(Data^, P.Buf[P.BufLen], n);
    Inc(P.BufLen, n);
    Inc(Data, n);
    Dec(Len, n);
    if P.BufLen < 16 then Exit;
    PolyBlocks(P, @P.Buf[0], 1, 1);
    P.BufLen := 0;
  end;
  if Len >= 16 then
  begin
    PolyBlocks(P, Data, Len div 16, 1);
    Inc(Data, Len and not SizeInt(15));
    Len := Len and 15;
  end;
  if Len > 0 then
  begin
    Move(Data^, P.Buf[0], Len);
    P.BufLen := Len;
  end;
end;

procedure Poly1305Mac(Key, Data: PByte; Len: SizeInt; Tag: PByte);
var
  P: TPoly1305;
begin
  Poly1305Init(P, Key);
  Poly1305Update(P, Data, Len);
  Poly1305Final(P, Tag);
end;

{ --------------------------------------------------------------------------------- AEAD }

const
  ZERO16: array[0..15] of Byte = (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0);

{ Poly1305 con la clave de un solo uso (bloque 0) y AD con su relleno. }
procedure AeadStart(var S: TChaState; out P: TPoly1305; AD: PByte; ADLen: SizeInt);
var
  Blk: array[0..63] of Byte;
begin
  S[12] := 0;
  ChaBlock(S, @Blk[0]);
  Poly1305Init(P, @Blk[0]);
  FillChar(Blk, SizeOf(Blk), 0);
  Poly1305Update(P, AD, ADLen);
  if ADLen and 15 <> 0 then Poly1305Update(P, @ZERO16[0], 16 - ADLen and 15);
end;

{ Relleno del cifrado, largos y etiqueta (RFC 8439 §2.8). }
procedure AeadFinish(var P: TPoly1305; ADLen, CLen: SizeInt; Tag: PByte);
var
  L: array[0..15] of Byte;
begin
  if CLen and 15 <> 0 then Poly1305Update(P, @ZERO16[0], 16 - CLen and 15);
  StoreLE64(@L[0], QWord(ADLen));
  StoreLE64(@L[8], QWord(CLen));
  Poly1305Update(P, @L[0], 16);
  Poly1305Final(P, Tag);
end;

procedure SealState(var S: TChaState; AD: PByte; ADLen: SizeInt; Src, Dst: PByte; Len: SizeInt; Tag: PByte);
var
  P: TPoly1305;
  Done: SizeInt;
  {$IFDEF CHACHA_ASM}
  Ctx: TChaAsmCtx;
  g: SizeUInt;
  {$ENDIF}
begin
  AeadStart(S, P, AD, ADLen);
  S[12] := 1;
  Done := 0;
  {$IFDEF CHACHA_ASM}
  g := Len div 256;
  if UseAvx2 and (g >= 2) then
  begin
    // la primera vuelta sola; en las demás se autentica la salida de la anterior; la última
    // salida, al final
    Ctx := AsmConst;
    Ctx.State := S;
    ChaChaAvx2(@Ctx, Src, Dst, 1);
    Inc(Ctx.State[12], 4);
    Ctx.PolyState := @P;
    Ctx.PolyData := Dst;
    ChaChaPolyAvx2(@Ctx, Src + 256, Dst + 256, g - 1);
    PolyBlocks(P, Dst + 256 * (g - 1), 16, 1);
    FillChar(Ctx.State, SizeOf(Ctx.State), 0);
    Inc(S[12], LongWord(4 * g));
    Done := 256 * g;
  end;
  {$ENDIF}
  ChaXor(S, Src + Done, Dst + Done, Len - Done);
  Poly1305Update(P, Dst + Done, Len - Done);
  AeadFinish(P, ADLen, Len, Tag);
  FillChar(S, SizeOf(S), 0);
end;

{ Si la etiqueta no coincide devuelve False y deja Dst en ceros (con AVX2 se descifra mientras
  se autentica, así que algo se pudo haber escrito: no se entrega nada). }
function OpenState(var S: TChaState; AD: PByte; ADLen: SizeInt; Src, Dst: PByte; Len: SizeInt; Tag: PByte): Boolean;
var
  P: TPoly1305;
  T: array[0..15] of Byte;
  Done: SizeInt;
  {$IFDEF CHACHA_ASM}
  Ctx: TChaAsmCtx;
  g: SizeUInt;
  {$ENDIF}
begin
  AeadStart(S, P, AD, ADLen);
  S[12] := 1;
  Done := 0;
  {$IFDEF CHACHA_ASM}
  g := Len div 256;
  if UseAvx2 and (g >= 1) then
  begin
    Ctx := AsmConst;
    Ctx.State := S;
    Ctx.PolyState := @P;
    Ctx.PolyData := Src;
    ChaChaPolyAvx2(@Ctx, Src, Dst, g);
    FillChar(Ctx.State, SizeOf(Ctx.State), 0);
    Inc(S[12], LongWord(4 * g));
    Done := 256 * g;
  end;
  {$ENDIF}
  // (el resto: primero autenticar, después descifrar, por si Src = Dst)
  Poly1305Update(P, Src + Done, Len - Done);
  AeadFinish(P, ADLen, Len, @T[0]);
  Result := ConstEq(@T[0], Tag, 16);
  if Result then
  begin
    if Done < Len then ChaXor(S, Src + Done, Dst + Done, Len - Done);
  end
  else if Done > 0 then
    FillChar(Dst^, Done, 0);
  FillChar(S, SizeOf(S), 0);
end;

procedure ChaChaPolySeal(Key, Nonce12, AD: PByte; ADLen: SizeInt; Src, Dst: PByte; Len: SizeInt; Tag: PByte);
var
  S: TChaState;
begin
  ChaInit(S, Key, Nonce12, 0);
  SealState(S, AD, ADLen, Src, Dst, Len, Tag);
end;

function ChaChaPolyOpen(Key, Nonce12, AD: PByte; ADLen: SizeInt; Src, Dst: PByte; Len: SizeInt; Tag: PByte): Boolean;
var
  S: TChaState;
begin
  ChaInit(S, Key, Nonce12, 0);
  Result := OpenState(S, AD, ADLen, Src, Dst, Len, Tag);
end;

{ XChaCha20: subclave = HChaCha20(clave, nonce[0..15]); nonce de ChaCha20 = 0^4 || nonce[16..23]. }
procedure XInit(out S: TChaState; Key, Nonce24: PByte);
var
  Sub: array[0..31] of Byte;
  N: array[0..11] of Byte;
begin
  HChaCha20(Key, Nonce24, @Sub[0]);
  FillChar(N, 4, 0);
  Move(Nonce24[16], N[4], 8);
  ChaInit(S, @Sub[0], @N[0], 0);
  FillChar(Sub, SizeOf(Sub), 0);
end;

procedure XChaChaPolySeal(Key, Nonce24, AD: PByte; ADLen: SizeInt; Src, Dst: PByte; Len: SizeInt; Tag: PByte);
var
  S: TChaState;
begin
  XInit(S, Key, Nonce24);
  SealState(S, AD, ADLen, Src, Dst, Len, Tag);
end;

function XChaChaPolyOpen(Key, Nonce24, AD: PByte; ADLen: SizeInt; Src, Dst: PByte; Len: SizeInt; Tag: PByte): Boolean;
var
  S: TChaState;
begin
  XInit(S, Key, Nonce24);
  Result := OpenState(S, AD, ADLen, Src, Dst, Len, Tag);
end;

initialization
  {$IFDEF CHACHA_ASM}
  InitAsmConst;
  UseAvx2 := CpuHasAvx2 and (GetEnvironmentVariable('PARC_CRYPT') <> 'pas');
  {$ENDIF}
end.
