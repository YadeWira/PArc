{ parc_plz_x64.inc — el lazo de búsqueda del voraz de una vía de plz (PlzScanFast1) en
  ensamblador x86-64. Código propio de PArc.

  Hace exactamente lo mismo que la versión en Pascal de parc_plzenc.pas (PlzScanFast1 con
  -dPARC_NOASM): recorre posiciones actualizando la tabla directa hasta que el rep0 o la entrada
  de la tabla coinciden en 4 bytes, o hasta ILimit; el resto del voraz queda en Pascal. FPC
  guarda casi todas las variables de ese lazo en la pila; acá viven en registros.
  Registros: rdi = S, r8 = Ip, r9 = H, r10 = fallos, r11 = Base, r12 = tabla, r13 = rep0,
  r14 = ventana, r15 = ILimit, rbp = posición relativa de Base. ABI SysV y Win64. }

{$ASMMODE INTEL}

function PlzScanFast1(var S: TPlzScan): LongInt; assembler; nostackframe;
asm
  push   rbx
  push   rbp
  push   r12
  push   r13
  push   r14
  push   r15
{$IFDEF WIN64}
  push   rdi
  push   rsi
  mov    rdi, rcx
{$ENDIF}
  mov    r8, qword ptr [rdi + TPlzScan.Ip]
  mov    r9d, dword ptr [rdi + TPlzScan.H]
  mov    r10d, dword ptr [rdi + TPlzScan.Miss]
  mov    r11, qword ptr [rdi + TPlzScan.Base]
  mov    r12, qword ptr [rdi + TPlzScan.T64]
  mov    r13d, dword ptr [rdi + TPlzScan.R0]
  mov    r14d, dword ptr [rdi + TPlzScan.Win]
  mov    r15, qword ptr [rdi + TPlzScan.ILimit]
  mov    ebp, dword ptr [rdi + TPlzScan.Cur0]
@loop:
  mov    eax, dword ptr [r8]                 // V4
  mov    rdx, qword ptr [r12 + r9 * 8]       // E
  mov    rcx, r8
  sub    rcx, r11                            // Ip - Base
  lea    esi, [rcx + rbp]                    // posición relativa (32 bits)
  mov    rbx, rax
  shl    rbx, 32
  or     rbx, rsi
  mov    qword ptr [r12 + r9 * 8], rbx       // entrada nueva: V4 arriba, posición abajo
  // rep0: R0 <= Ip - Base y los 4 bytes iguales
  cmp    r13d, ecx
  ja     @norep
  mov    rbx, r8
  sub    rbx, r13
  cmp    eax, dword ptr [rbx]
  je     @hitrep
@norep:
  mov    ebx, esi
  sub    ebx, edx                            // D = posición - LongWord(E)
  mov    rcx, rdx
  shr    rcx, 32
  cmp    ecx, eax
  jne    @miss
  test   edx, edx
  jz     @miss
  cmp    ebx, r14d
  ja     @miss
  mov    dword ptr [rdi + TPlzScan.Dist], ebx
  mov    eax, 2
  jmp    @done
@miss:
  inc    r10d
  mov    ecx, dword ptr [rdi + TPlzScan.Skip]
  mov    ebx, r10d
  shr    ebx, cl
  lea    r8, [r8 + rbx + 1]
  cmp    r8, r15
  jae    @eob
  mov    rax, qword ptr [r8]
  mov    ecx, dword ptr [rdi + TPlzScan.HSh]
  shl    rax, cl
  mov    rbx, $9E3779B185EBCA87
  imul   rax, rbx
  shr    rax, 32
  mov    ecx, dword ptr [rdi + TPlzScan.Sh]
  shr    eax, cl
  mov    r9d, eax
  prefetcht0 byte ptr [r12 + r9 * 8]
  jmp    @loop
@hitrep:
  mov    eax, 1
  jmp    @done
@eob:
  xor    eax, eax
@done:
  mov    qword ptr [rdi + TPlzScan.Ip], r8
  mov    dword ptr [rdi + TPlzScan.H], r9d
  mov    dword ptr [rdi + TPlzScan.Miss], r10d
{$IFDEF WIN64}
  pop    rsi
  pop    rdi
{$ENDIF}
  pop    r15
  pop    r14
  pop    r13
  pop    r12
  pop    rbp
  pop    rbx
end;
