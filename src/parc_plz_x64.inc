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

{ PlzScanDual: como PlzScanFast1 pero también con la tabla corta (hash de 4 bytes); la misma
  salida que la versión en Pascal de parc_plzenc.pas. S.H queda con el hash de la última
  posición mirada; Dist/Dist2 = candidatos de la tabla principal y la corta (0 = no hay). }
function PlzScanDual(var S: TPlzScan): LongInt; assembler; nostackframe;
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
  mov    dword ptr [rdi + TPlzScan.H], r9d
  mov    eax, dword ptr [r8]                 // V4
  mov    rcx, r8
  sub    rcx, r11
  lea    esi, [rcx + rbp]                    // posición relativa
  mov    rbx, rax
  shl    rbx, 32
  or     rbx, rsi                            // entrada nueva
  mov    rdx, qword ptr [r12 + r9 * 8]       // E
  mov    qword ptr [r12 + r9 * 8], rbx
  mov    r9d, eax
  imul   r9d, r9d, $9E3779B1
  mov    ecx, dword ptr [rdi + TPlzScan.SSh]
  shr    r9d, cl                             // HS
  mov    rcx, qword ptr [rdi + TPlzScan.TS]
  lea    rcx, [rcx + r9 * 8]
  mov    r9, qword ptr [rcx]                 // ES
  mov    qword ptr [rcx], rbx
  // rep0
  mov    rcx, r8
  sub    rcx, r11
  cmp    r13d, ecx
  ja     @norep
  mov    rbx, r8
  sub    rbx, r13
  cmp    eax, dword ptr [rbx]
  je     @hitrep
@norep:
  mov    ebx, esi
  sub    ebx, edx                            // D
  mov    rcx, rdx
  shr    rcx, 32
  cmp    ecx, eax
  jne    @d0
  test   edx, edx
  jz     @d0
  cmp    ebx, r14d
  jbe    @d1
@d0:
  xor    ebx, ebx
@d1:
  mov    ecx, esi
  sub    ecx, r9d                            // D2
  mov    rdx, r9
  shr    rdx, 32
  cmp    edx, eax
  jne    @e0
  test   r9d, r9d
  jz     @e0
  cmp    ecx, r14d
  jbe    @e1
@e0:
  xor    ecx, ecx
@e1:
  mov    edx, ebx
  or     edx, ecx
  jz     @miss
  mov    dword ptr [rdi + TPlzScan.Dist], ebx
  mov    dword ptr [rdi + TPlzScan.Dist2], ecx
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

{ PlzGreedy: el voraz de una vía entero (niveles 1-2) hasta ILimit: búsqueda (con o sin la tabla
  corta, TS = nil), largo de los matches, extensión hacia atrás, literales a Lit, secuencia en
  forma cruda (como TPlzEngine.AddSeq), reps e inserciones (como FastMatch). Hace lo mismo,
  paso por paso, que el camino en Pascal (ParseFast1/ParseFastDual con PlzScanFast1/PlzScanDual,
  MatchLen, FastMatch y AddSeq), que es el que se usa con -dPARC_NOASM. }
function PlzGreedy(var S: TPlzGreedy): LongInt; assembler; nostackframe;
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
  mov    r8, qword ptr [rdi + TPlzGreedy.Ip]
  mov    r11, qword ptr [rdi + TPlzGreedy.Base]
  mov    r12, qword ptr [rdi + TPlzGreedy.T64]
  mov    r13d, dword ptr [rdi + TPlzGreedy.Rep0]
  mov    r14d, dword ptr [rdi + TPlzGreedy.Win]
  mov    r15, qword ptr [rdi + TPlzGreedy.ILimit]
  mov    ebp, dword ptr [rdi + TPlzGreedy.Cur0]
  cmp    r8, r15
  jae    @exit
@top:
  xor    r10d, r10d                          // fallos
  mov    rax, qword ptr [r8]
  mov    ecx, dword ptr [rdi + TPlzGreedy.HSh]
  shl    rax, cl
  mov    rbx, $9E3779B185EBCA87
  imul   rax, rbx
  shr    rax, 32
  mov    ecx, dword ptr [rdi + TPlzGreedy.Sh]
  shr    eax, cl
  mov    r9d, eax
@scan:
  mov    eax, dword ptr [r8]                 // V4
  mov    rcx, r8
  sub    rcx, r11
  lea    esi, [rcx + rbp]                    // posición relativa
  mov    rbx, rax
  shl    rbx, 32
  or     rbx, rsi                            // entrada nueva
  mov    rdx, qword ptr [r12 + r9 * 8]       // E
  mov    qword ptr [r12 + r9 * 8], rbx
  xor    r9d, r9d                            // ES (0 = sin tabla corta)
  cmp    qword ptr [rdi + TPlzGreedy.TS], 0
  je     @nots
  mov    r9d, eax
  imul   r9d, r9d, $9E3779B1
  mov    ecx, dword ptr [rdi + TPlzGreedy.SSh]
  shr    r9d, cl
  mov    rcx, qword ptr [rdi + TPlzGreedy.TS]
  lea    rcx, [rcx + r9 * 8]
  mov    r9, qword ptr [rcx]
  mov    qword ptr [rcx], rbx
@nots:
  // rep0
  mov    rcx, r8
  sub    rcx, r11
  cmp    r13d, ecx
  ja     @norep
  mov    rbx, r8
  sub    rbx, r13
  cmp    eax, dword ptr [rbx]
  je     @hitrep
@norep:
  mov    ebx, esi
  sub    ebx, edx                            // D
  mov    rcx, rdx
  shr    rcx, 32
  cmp    ecx, eax
  jne    @d0
  test   edx, edx
  jz     @d0
  cmp    ebx, r14d
  jbe    @d1
@d0:
  xor    ebx, ebx
@d1:
  mov    ecx, esi
  sub    ecx, r9d                            // D2
  mov    rdx, r9
  shr    rdx, 32
  cmp    edx, eax
  jne    @e0
  test   r9d, r9d
  jz     @e0
  cmp    ecx, r14d
  jbe    @e1
@e0:
  xor    ecx, ecx
@e1:
  mov    edx, ebx
  or     edx, ecx
  jnz    @hitcand
  // fallo: avanzar con aceleración
  inc    r10d
  mov    ecx, dword ptr [rdi + TPlzGreedy.Skip]
  mov    ebx, r10d
  shr    ebx, cl
  lea    r8, [r8 + rbx + 1]
  cmp    r8, r15
  jae    @exit
  mov    rax, qword ptr [r8]
  mov    ecx, dword ptr [rdi + TPlzGreedy.HSh]
  shl    rax, cl
  mov    rbx, $9E3779B185EBCA87
  imul   rax, rbx
  shr    rax, 32
  mov    ecx, dword ptr [rdi + TPlzGreedy.Sh]
  shr    eax, cl
  mov    r9d, eax
  prefetcht0 byte ptr [r12 + r9 * 8]
  // y la de 8 bytes más adelante (sólo tiempo)
  lea    rax, [r8 + 16]
  cmp    rax, r15
  jae    @scan
  mov    rax, qword ptr [r8 + 8]
  mov    ecx, dword ptr [rdi + TPlzGreedy.HSh]
  shl    rax, cl
  imul   rax, rbx
  shr    rax, 32
  mov    ecx, dword ptr [rdi + TPlzGreedy.Sh]
  shr    eax, cl
  prefetcht0 byte ptr [r12 + rax * 8]
  jmp    @scan

@hitrep:
  mov    dword ptr [rdi + TPlzGreedy.CurDist], r13d
  lea    rsi, [r8 + 4]
  mov    rdx, rsi
  sub    rdx, r13
  call   @ml
  add    rax, 4
  mov    qword ptr [rdi + TPlzGreedy.CurLen], rax
  jmp    @emit

@hitcand:
  // ebx = D (principal), ecx = D2 (corta)
  mov    dword ptr [rdi + TPlzGreedy.CurDist], ebx
  mov    dword ptr [rdi + TPlzGreedy.Dist2], ecx
  mov    qword ptr [rdi + TPlzGreedy.CurLen], 0
  test   ebx, ebx
  jz     @c2
  lea    rsi, [r8 + 4]
  mov    rdx, rsi
  sub    rdx, rbx
  call   @ml
  add    rax, 4
  mov    qword ptr [rdi + TPlzGreedy.CurLen], rax
@c2:
  mov    ecx, dword ptr [rdi + TPlzGreedy.Dist2]
  test   ecx, ecx
  jz     @emit
  cmp    ecx, dword ptr [rdi + TPlzGreedy.CurDist]
  je     @emit
  lea    rsi, [r8 + 4]
  mov    rdx, rsi
  sub    rdx, rcx
  call   @ml
  add    rax, 4
  mov    ecx, dword ptr [rdi + TPlzGreedy.Dist2]
  cmp    rax, qword ptr [rdi + TPlzGreedy.CurLen]
  ja     @take2
  jb     @emit
  cmp    ecx, dword ptr [rdi + TPlzGreedy.CurDist]
  jae    @emit
@take2:
  mov    qword ptr [rdi + TPlzGreedy.CurLen], rax
  mov    dword ptr [rdi + TPlzGreedy.CurDist], ecx

@emit:
  // extensión hacia atrás: rsi = inicio del match, rax = largo
  mov    rsi, r8
  mov    edx, dword ptr [rdi + TPlzGreedy.CurDist]
  mov    r9, rdx                             // distancia (64 bits)
  mov    rdx, r8
  sub    rdx, r9                             // Cp
  mov    rcx, qword ptr [rdi + TPlzGreedy.Anchor]
  mov    rax, qword ptr [rdi + TPlzGreedy.CurLen]
@bx:
  cmp    rsi, rcx
  jbe    @bxe
  cmp    rdx, r11
  jbe    @bxe
  mov    bl, byte ptr [rsi - 1]
  cmp    bl, byte ptr [rdx - 1]
  jne    @bxe
  dec    rsi
  dec    rdx
  inc    rax
  jmp    @bx
@bxe:
  mov    qword ptr [rdi + TPlzGreedy.CurLen], rax
  mov    qword ptr [rdi + TPlzGreedy.MStart], rsi
  // literales [Anchor, rsi) a Lit
  mov    rdx, qword ptr [rdi + TPlzGreedy.Lit]
  mov    rbx, rsi
  sub    rbx, rcx                            // LL
  mov    r10, rbx
@lc8:
  cmp    rbx, 8
  jb     @lc1
  mov    rax, qword ptr [rcx]
  mov    qword ptr [rdx], rax
  add    rcx, 8
  add    rdx, 8
  sub    rbx, 8
  jmp    @lc8
@lc1:
  test   rbx, rbx
  jz     @lcd
  mov    al, byte ptr [rcx]
  mov    byte ptr [rdx], al
  inc    rcx
  inc    rdx
  dec    rbx
  jmp    @lc1
@lcd:
  mov    qword ptr [rdi + TPlzGreedy.Lit], rdx
  // secuencia cruda
  mov    rdx, qword ptr [rdi + TPlzGreedy.Seq]
  mov    dword ptr [rdx + TPlzSeq.LL], r10d
  mov    rax, qword ptr [rdi + TPlzGreedy.CurLen]
  mov    dword ptr [rdx + TPlzSeq.ML], eax
  // reps (r9d = distancia, r13d = rep0)
  cmp    r9d, r13d
  jne    @rp1
  mov    dword ptr [rdx + TPlzSeq.OC], 0
  jmp    @rpd
@rp1:
  mov    ecx, dword ptr [rdi + TPlzGreedy.Rep1]
  mov    dword ptr [rdi + TPlzGreedy.Rep1], r13d
  mov    r13d, r9d
  cmp    r9d, ecx
  jne    @rp2
  mov    dword ptr [rdx + TPlzSeq.OC], 1
  jmp    @rpd
@rp2:
  mov    ebx, dword ptr [rdi + TPlzGreedy.Rep2]
  mov    dword ptr [rdi + TPlzGreedy.Rep2], ecx
  cmp    r9d, ebx
  jne    @rp3
  mov    dword ptr [rdx + TPlzSeq.OC], 2
  jmp    @rpd
@rp3:
  cmp    r9d, dword ptr [rdi + TPlzGreedy.Rep3]
  jne    @rp4
  mov    dword ptr [rdx + TPlzSeq.OC], 3
  jmp    @rp5
@rp4:
  mov    dword ptr [rdx + TPlzSeq.OC], 4
  mov    dword ptr [rdx + TPlzSeq.OX], r9d
@rp5:
  mov    dword ptr [rdi + TPlzGreedy.Rep3], ebx
@rpd:
  add    rdx, PLZ_SEQSIZE
  mov    qword ptr [rdi + TPlzGreedy.Seq], rdx
  // inserciones: Ip+2 y q-1 en la principal, q-2 en la corta
  mov    rsi, qword ptr [rdi + TPlzGreedy.MStart]
  mov    rax, qword ptr [rdi + TPlzGreedy.CurLen]
  lea    r8, [rsi + rax]                     // q
  mov    qword ptr [rdi + TPlzGreedy.Anchor], r8
  lea    rdx, [rsi + 2]
  cmp    rdx, r15
  jae    @in2
  call   @insmain
@in2:
  lea    rdx, [r8 - 1]
  lea    rax, [rsi + 2]
  cmp    rdx, rax
  jbe    @in3
  cmp    rdx, r15
  jae    @in3
  call   @insmain
@in3:
  cmp    qword ptr [rdi + TPlzGreedy.TS], 0
  je     @next
  lea    rdx, [r8 - 2]
  cmp    rdx, rsi
  jbe    @next
  cmp    rdx, r15
  jae    @next
  // tabla corta: hash de 4 bytes
  mov    eax, dword ptr [rdx]
  mov    ebx, eax
  imul   ebx, ebx, $9E3779B1
  mov    ecx, dword ptr [rdi + TPlzGreedy.SSh]
  shr    ebx, cl
  shl    rax, 32
  mov    rcx, rdx
  sub    rcx, r11
  add    ecx, ebp
  or     rax, rcx
  mov    rcx, qword ptr [rdi + TPlzGreedy.TS]
  mov    qword ptr [rcx + rbx * 8], rax
@next:
  cmp    r8, r15
  jb     @top
  jmp    @exit

// inserta en la tabla principal la posición rdx (usa rax, rbx, rcx)
@insmain:
  mov    rax, qword ptr [rdx]
  mov    ecx, dword ptr [rdi + TPlzGreedy.HSh]
  shl    rax, cl
  mov    rbx, $9E3779B185EBCA87
  imul   rax, rbx
  shr    rax, 32
  mov    ecx, dword ptr [rdi + TPlzGreedy.Sh]
  shr    eax, cl
  mov    ebx, eax
  mov    eax, dword ptr [rdx]
  shl    rax, 32
  mov    rcx, rdx
  sub    rcx, r11
  add    ecx, ebp
  or     rax, rcx
  mov    qword ptr [r12 + rbx * 8], rax
  ret

// largo común de rsi y rdx hasta IEnd -> rax (usa rbx, rcx)
@ml:
  mov    rcx, qword ptr [rdi + TPlzGreedy.IEnd]
  mov    rax, rsi
@ml8:
  lea    rbx, [rsi + 8]
  cmp    rbx, rcx
  ja     @mlb
  mov    rbx, qword ptr [rsi]
  xor    rbx, qword ptr [rdx]
  jnz    @mlf
  add    rsi, 8
  add    rdx, 8
  jmp    @ml8
@mlf:
  bsf    rbx, rbx
  shr    rbx, 3
  add    rsi, rbx
  jmp    @mle
@mlb:
  cmp    rsi, rcx
  jae    @mle
  mov    bl, byte ptr [rsi]
  cmp    bl, byte ptr [rdx]
  jne    @mle
  inc    rsi
  inc    rdx
  jmp    @mlb
@mle:
  sub    rsi, rax
  mov    rax, rsi
  ret

@exit:
  mov    qword ptr [rdi + TPlzGreedy.Ip], r8
  mov    dword ptr [rdi + TPlzGreedy.Rep0], r13d
  xor    eax, eax
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

{ PlzEval1: TPlzEngine.EvalAt + FindAndInsert para las tablas de una vía (cubo de 1 o 2
  entradas y la tabla corta), la misma salida que el Pascal. Devuelve 1 si hay match (Ln, Dt, G
  en S), 0 si no. }
function PlzEval1(var S: TPlzEval): LongInt; assembler; nostackframe;
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
  mov    r8, qword ptr [rdi + TPlzEval.X]
  mov    r11, qword ptr [rdi + TPlzEval.Base]
  mov    r15, qword ptr [rdi + TPlzEval.IEnd]
  // reps: r12 = mejor ganancia (GR), r13 = RB, r14d = RD
  mov    r12, -1000
  xor    r13, r13
  xor    r14d, r14d
  mov    rbp, r8
  sub    rbp, r11                            // Avail
  mov    eax, dword ptr [r8]
  and    eax, $FFFFFF                        // V3
  xor    r10d, r10d                          // i
@rloop:
  mov    r9d, dword ptr [rdi + TPlzEval.Rep0 + r10 * 4]
  cmp    r9, rbp
  ja     @rnext
  mov    rbx, r8
  sub    rbx, r9
  mov    ecx, dword ptr [rbx]
  and    ecx, $FFFFFF
  cmp    ecx, eax
  jne    @rnext
  push   rax
  lea    rsi, [r8 + 3]
  lea    rdx, [rbx + 3]
  call   @ml
  add    rax, 3                              // RL
  lea    rcx, [rax * 4]
  sub    rcx, r10                            // RL*4 - i
  cmp    rcx, r12
  jle    @rskip
  mov    r12, rcx
  mov    r13, rax
  mov    r14d, r9d
@rskip:
  pop    rax
@rnext:
  inc    r10d
  cmp    r10d, 4
  jb     @rloop
  // tabla: sólo si C >= InsNext
  mov    qword ptr [rdi + TPlzEval.HL], 0
  mov    dword ptr [rdi + TPlzEval.HD], 0
  mov    ebx, ebp
  add    ebx, dword ptr [rdi + TPlzEval.Cur0]  // C
  mov    dword ptr [rdi + TPlzEval.C], ebx
  cmp    ebx, dword ptr [rdi + TPlzEval.InsNext]
  jb     @decide
  inc    ebx
  mov    dword ptr [rdi + TPlzEval.InsNext], ebx
  mov    qword ptr [rdi + TPlzEval.HL], 3      // Best
  mov    eax, dword ptr [r8]                 // V4
  mov    r9, rax
  shl    r9, 32
  mov    ecx, dword ptr [rdi + TPlzEval.C]
  or     r9, rcx                             // entrada nueva
  // hash principal
  mov    rax, qword ptr [r8]
  mov    ecx, dword ptr [rdi + TPlzEval.HShl]
  shl    rax, cl
  mov    rbx, $9E3779B185EBCA87
  imul   rax, rbx
  shr    rax, 32
  mov    ecx, dword ptr [rdi + TPlzEval.Sh]
  shr    eax, cl                             // fila
  mov    rbx, qword ptr [rdi + TPlzEval.T64]
  cmp    dword ptr [rdi + TPlzEval.Bucket], 2
  je     @b2
  lea    rbx, [rbx + rax * 8]
  mov    rdx, qword ptr [rbx]
  mov    qword ptr [rbx], r9
  call   @cand
  jmp    @short
@b2:
  shl    rax, 4
  add    rbx, rax
  mov    rdx, qword ptr [rbx]                // E
  mov    rcx, qword ptr [rbx + 8]            // E2
  mov    qword ptr [rbx + 8], rdx
  mov    qword ptr [rbx], r9
  push   rcx
  call   @cand
  pop    rdx
  cmp    dword ptr [rdi + TPlzEval.Check2], 0
  je     @short
  call   @cand
@short:
  cmp    qword ptr [rdi + TPlzEval.TS], 0
  je     @decide
  mov    eax, dword ptr [r8]
  imul   eax, eax, $9E3779B1
  mov    ecx, dword ptr [rdi + TPlzEval.SSh]
  shr    eax, cl
  mov    rbx, qword ptr [rdi + TPlzEval.TS]
  lea    rbx, [rbx + rax * 8]
  mov    rdx, qword ptr [rbx]                // ES
  mov    qword ptr [rbx], r9
  // D = C - lo(ES); válido, D <> HD, hi = V4
  test   edx, edx
  jz     @decide
  mov    ecx, dword ptr [rdi + TPlzEval.C]
  sub    ecx, edx
  cmp    ecx, dword ptr [rdi + TPlzEval.Win]
  ja     @decide
  cmp    ecx, dword ptr [rdi + TPlzEval.HD]
  je     @decide
  mov    rax, rdx
  shr    rax, 32
  cmp    eax, dword ptr [r8]
  jne    @decide
  mov    dword ptr [rdi + TPlzEval.D2], ecx
  lea    rsi, [r8 + 4]
  mov    rdx, rsi
  sub    rdx, rcx
  call   @ml
  add    rax, 4
  mov    ecx, dword ptr [rdi + TPlzEval.D2]
  cmp    rax, qword ptr [rdi + TPlzEval.HL]
  ja     @stake
  jb     @decide
  cmp    dword ptr [rdi + TPlzEval.HD], 0
  je     @decide
  cmp    ecx, dword ptr [rdi + TPlzEval.HD]
  jae    @decide
@stake:
  mov    qword ptr [rdi + TPlzEval.HL], rax
  mov    dword ptr [rdi + TPlzEval.HD], ecx

@decide:
  // GH = HL >= 4 ? HL*4 - bsr(HD+3) : -1000
  mov    rax, qword ptr [rdi + TPlzEval.HL]
  mov    rcx, -1000
  cmp    rax, 4
  jb     @gh
  lea    rcx, [rax * 4]
  mov    edx, dword ptr [rdi + TPlzEval.HD]
  add    edx, 3
  bsr    edx, edx
  sub    rcx, rdx
@gh:
  // sin rep ni hash: no hay match
  test   r13, r13
  jnz    @have
  cmp    rax, 4
  jb     @none
@have:
  cmp    r12, rcx
  jl     @useh
  mov    qword ptr [rdi + TPlzEval.Ln], r13
  mov    dword ptr [rdi + TPlzEval.Dt], r14d
  mov    qword ptr [rdi + TPlzEval.G], r12
  mov    eax, 1
  jmp    @done
@useh:
  mov    qword ptr [rdi + TPlzEval.Ln], rax
  mov    edx, dword ptr [rdi + TPlzEval.HD]
  mov    dword ptr [rdi + TPlzEval.Dt], edx
  mov    qword ptr [rdi + TPlzEval.G], rcx
  mov    eax, 1
  jmp    @done
@none:
  xor    eax, eax
  jmp    @done

// candidato de la tabla principal en rdx (entrada): si es válido y coincide en 4 bytes y es
// más largo que HL, pasa a HL/HD (usa rax, rbx, rcx, rsi)
@cand:
  test   edx, edx
  jz     @cret
  mov    ecx, dword ptr [rdi + TPlzEval.C]
  sub    ecx, edx                            // D
  cmp    ecx, dword ptr [rdi + TPlzEval.Win]
  ja     @cret
  mov    rax, rdx
  shr    rax, 32
  cmp    eax, dword ptr [r8]
  jne    @cret
  push   rcx
  lea    rsi, [r8 + 4]
  mov    rdx, rsi
  sub    rdx, rcx
  call   @ml
  add    rax, 4
  pop    rcx
  cmp    rax, qword ptr [rdi + TPlzEval.HL]
  jbe    @cret
  mov    qword ptr [rdi + TPlzEval.HL], rax
  mov    dword ptr [rdi + TPlzEval.HD], ecx
@cret:
  ret

// largo común de rsi y rdx hasta IEnd (r15) -> rax (usa rbx, rcx)
@ml:
  mov    rax, rsi
@ml8:
  lea    rbx, [rsi + 8]
  cmp    rbx, r15
  ja     @mlb
  mov    rbx, qword ptr [rsi]
  xor    rbx, qword ptr [rdx]
  jnz    @mlf
  add    rsi, 8
  add    rdx, 8
  jmp    @ml8
@mlf:
  bsf    rbx, rbx
  shr    rbx, 3
  add    rsi, rbx
  jmp    @mle
@mlb:
  cmp    rsi, r15
  jae    @mle
  mov    bl, byte ptr [rsi]
  cmp    bl, byte ptr [rdx]
  jne    @mle
  inc    rsi
  inc    rdx
  jmp    @mlb
@mle:
  sub    rsi, rax
  mov    rax, rsi
  ret

@done:
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

{ PlzEvalRows: TPlzEngine.EvalAt + FindAndInsert para filas de hasta 8 entradas (un grupo de
  etiquetas), con la tabla corta; la misma salida que el Pascal. }
function PlzEvalRows(var S: TPlzEval): LongInt; assembler; nostackframe;
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
  mov    r8, qword ptr [rdi + TPlzEval.X]
  mov    r11, qword ptr [rdi + TPlzEval.Base]
  mov    r15, qword ptr [rdi + TPlzEval.IEnd]
  // reps: r12 = mejor ganancia (GR), r13 = RB, r14d = RD
  mov    r12, -1000
  xor    r13, r13
  xor    r14d, r14d
  mov    rbp, r8
  sub    rbp, r11                            // Avail
  mov    eax, dword ptr [r8]
  and    eax, $FFFFFF                        // V3
  xor    r10d, r10d                          // i
@rloop:
  mov    r9d, dword ptr [rdi + TPlzEval.Rep0 + r10 * 4]
  cmp    r9, rbp
  ja     @rnext
  mov    rbx, r8
  sub    rbx, r9
  mov    ecx, dword ptr [rbx]
  and    ecx, $FFFFFF
  cmp    ecx, eax
  jne    @rnext
  push   rax
  lea    rsi, [r8 + 3]
  lea    rdx, [rbx + 3]
  call   @ml
  add    rax, 3                              // RL
  lea    rcx, [rax * 4]
  sub    rcx, r10                            // RL*4 - i
  cmp    rcx, r12
  jle    @rskip
  mov    r12, rcx
  mov    r13, rax
  mov    r14d, r9d
@rskip:
  pop    rax
@rnext:
  inc    r10d
  cmp    r10d, 4
  jb     @rloop
  // tabla: sólo si C >= InsNext
  mov    qword ptr [rdi + TPlzEval.HL], 0
  mov    dword ptr [rdi + TPlzEval.HD], 0
  mov    ebx, ebp
  add    ebx, dword ptr [rdi + TPlzEval.Cur0]  // C
  mov    dword ptr [rdi + TPlzEval.C], ebx
  cmp    ebx, dword ptr [rdi + TPlzEval.InsNext]
  jb     @decide
  inc    ebx
  mov    dword ptr [rdi + TPlzEval.InsNext], ebx
  mov    qword ptr [rdi + TPlzEval.HL], 3      // Best
  mov    eax, dword ptr [r8]                 // V4
  mov    r9, rax
  shl    r9, 32
  mov    ecx, dword ptr [rdi + TPlzEval.C]
  or     r9, rcx                             // entrada nueva (tabla corta)
  push   r9
  // hash: fila y etiqueta
  mov    rax, qword ptr [r8]
  mov    ecx, dword ptr [rdi + TPlzEval.HShl]
  shl    rax, cl
  mov    rbx, $9E3779B185EBCA87
  imul   rax, rbx
  shr    rax, 32
  mov    edx, eax
  mov    ecx, dword ptr [rdi + TPlzEval.TagSh]
  shr    edx, cl
  mov    byte ptr [rdi + TPlzEval.Tag], dl
  mov    ecx, dword ptr [rdi + TPlzEval.Sh]
  shr    eax, cl                             // fila
  imul   rax, qword ptr [rdi + TPlzEval.RowBytes]
  mov    r9, qword ptr [rdi + TPlzEval.Rows]
  add    r9, rax                             // R
  mov    ecx, dword ptr [rdi + TPlzEval.HeadOff]
  movzx  ebp, byte ptr [r9 + rcx]            // Hd
  // máscara de etiquetas iguales (un grupo de 8)
  movzx  ebx, byte ptr [rdi + TPlzEval.Tag]
  mov    rcx, $0101010101010101
  imul   rbx, rcx
  mov    rax, qword ptr [r9]
  xor    rax, rbx                            // V
  mov    rbx, rax
  sub    rbx, rcx
  not    rax
  and    rbx, rax
  mov    rax, $8080808080808080
  and    rbx, rax
  shr    rbx, 7
  mov    rax, $0102040810204080
  imul   rbx, rax
  shr    rbx, 56
  and    rbx, qword ptr [rdi + TPlzEval.WayFull]
  mov    r10, rbx
  test   ebp, ebp
  jz     @norot
  mov    ecx, ebp
  mov    rax, r10
  shr    rax, cl
  mov    ecx, dword ptr [rdi + TPlzEval.Ways]
  sub    ecx, ebp
  shl    r10, cl
  or     r10, rax
  and    r10, qword ptr [rdi + TPlzEval.WayFull]
@norot:
@cl:
  test   r10, r10
  jz     @rdone
  bsf    rax, r10
  lea    rcx, [r10 - 1]
  and    r10, rcx
  add    eax, ebp
  and    eax, dword ptr [rdi + TPlzEval.WayMask]
  mov    ecx, dword ptr [rdi + TPlzEval.PosOff]
  lea    rbx, [r9 + rcx]
  mov    edx, dword ptr [rbx + rax * 4]      // C del candidato
  test   edx, edx
  jz     @rdone
  mov    ecx, dword ptr [rdi + TPlzEval.C]
  sub    ecx, edx                            // D
  cmp    ecx, dword ptr [rdi + TPlzEval.Win]
  ja     @rdone
  mov    rax, r15
  sub    rax, r8                             // MaxL
  mov    rdx, qword ptr [rdi + TPlzEval.HL]  // Best
  cmp    rdx, rax
  jae    @rdone
  mov    rbx, r8
  sub    rbx, rcx                            // Cp
  mov    al, byte ptr [rbx + rdx]
  cmp    al, byte ptr [r8 + rdx]
  jne    @cl
  push   rcx
  mov    rsi, r8
  mov    rdx, rbx
  call   @ml
  pop    rcx
  cmp    rax, qword ptr [rdi + TPlzEval.HL]
  jbe    @cl
  mov    qword ptr [rdi + TPlzEval.HL], rax
  mov    dword ptr [rdi + TPlzEval.HD], ecx
  cmp    rax, qword ptr [rdi + TPlzEval.Nice]
  jae    @rdone
  jmp    @cl
@rdone:
  // insertar X en la fila
  lea    eax, [rbp - 1]
  and    eax, dword ptr [rdi + TPlzEval.WayMask]
  mov    ecx, dword ptr [rdi + TPlzEval.HeadOff]
  mov    byte ptr [r9 + rcx], al
  mov    dl, byte ptr [rdi + TPlzEval.Tag]
  mov    byte ptr [r9 + rax], dl
  mov    ecx, dword ptr [rdi + TPlzEval.PosOff]
  lea    rbx, [r9 + rcx]
  mov    edx, dword ptr [rdi + TPlzEval.C]
  mov    dword ptr [rbx + rax * 4], edx
  pop    r9                                  // entrada nueva para la tabla corta
@short:
  cmp    qword ptr [rdi + TPlzEval.TS], 0
  je     @decide
  mov    eax, dword ptr [r8]
  imul   eax, eax, $9E3779B1
  mov    ecx, dword ptr [rdi + TPlzEval.SSh]
  shr    eax, cl
  mov    rbx, qword ptr [rdi + TPlzEval.TS]
  lea    rbx, [rbx + rax * 8]
  mov    rdx, qword ptr [rbx]                // ES
  mov    qword ptr [rbx], r9
  // D = C - lo(ES); válido, D <> HD, hi = V4
  test   edx, edx
  jz     @decide
  mov    ecx, dword ptr [rdi + TPlzEval.C]
  sub    ecx, edx
  cmp    ecx, dword ptr [rdi + TPlzEval.Win]
  ja     @decide
  cmp    ecx, dword ptr [rdi + TPlzEval.HD]
  je     @decide
  mov    rax, rdx
  shr    rax, 32
  cmp    eax, dword ptr [r8]
  jne    @decide
  mov    dword ptr [rdi + TPlzEval.D2], ecx
  lea    rsi, [r8 + 4]
  mov    rdx, rsi
  sub    rdx, rcx
  call   @ml
  add    rax, 4
  mov    ecx, dword ptr [rdi + TPlzEval.D2]
  cmp    rax, qword ptr [rdi + TPlzEval.HL]
  ja     @stake
  jb     @decide
  cmp    dword ptr [rdi + TPlzEval.HD], 0
  je     @decide
  cmp    ecx, dword ptr [rdi + TPlzEval.HD]
  jae    @decide
@stake:
  mov    qword ptr [rdi + TPlzEval.HL], rax
  mov    dword ptr [rdi + TPlzEval.HD], ecx

@decide:
  // GH = HL >= 4 ? HL*4 - bsr(HD+3) : -1000
  mov    rax, qword ptr [rdi + TPlzEval.HL]
  mov    rcx, -1000
  cmp    rax, 4
  jb     @gh
  lea    rcx, [rax * 4]
  mov    edx, dword ptr [rdi + TPlzEval.HD]
  add    edx, 3
  bsr    edx, edx
  sub    rcx, rdx
@gh:
  // sin rep ni hash: no hay match
  test   r13, r13
  jnz    @have
  cmp    rax, 4
  jb     @none
@have:
  cmp    r12, rcx
  jl     @useh
  mov    qword ptr [rdi + TPlzEval.Ln], r13
  mov    dword ptr [rdi + TPlzEval.Dt], r14d
  mov    qword ptr [rdi + TPlzEval.G], r12
  mov    eax, 1
  jmp    @done
@useh:
  mov    qword ptr [rdi + TPlzEval.Ln], rax
  mov    edx, dword ptr [rdi + TPlzEval.HD]
  mov    dword ptr [rdi + TPlzEval.Dt], edx
  mov    qword ptr [rdi + TPlzEval.G], rcx
  mov    eax, 1
  jmp    @done
@none:
  xor    eax, eax
  jmp    @done

// candidato de la tabla principal en rdx (entrada): si es válido y coincide en 4 bytes y es
// más largo que HL, pasa a HL/HD (usa rax, rbx, rcx, rsi)
@cand:
  test   edx, edx
  jz     @cret
  mov    ecx, dword ptr [rdi + TPlzEval.C]
  sub    ecx, edx                            // D
  cmp    ecx, dword ptr [rdi + TPlzEval.Win]
  ja     @cret
  mov    rax, rdx
  shr    rax, 32
  cmp    eax, dword ptr [r8]
  jne    @cret
  push   rcx
  lea    rsi, [r8 + 4]
  mov    rdx, rsi
  sub    rdx, rcx
  call   @ml
  add    rax, 4
  pop    rcx
  cmp    rax, qword ptr [rdi + TPlzEval.HL]
  jbe    @cret
  mov    qword ptr [rdi + TPlzEval.HL], rax
  mov    dword ptr [rdi + TPlzEval.HD], ecx
@cret:
  ret

// largo común de rsi y rdx hasta IEnd (r15) -> rax (usa rbx, rcx)
@ml:
  mov    rax, rsi
@ml8:
  lea    rbx, [rsi + 8]
  cmp    rbx, r15
  ja     @mlb
  mov    rbx, qword ptr [rsi]
  xor    rbx, qword ptr [rdx]
  jnz    @mlf
  add    rsi, 8
  add    rdx, 8
  jmp    @ml8
@mlf:
  bsf    rbx, rbx
  shr    rbx, 3
  add    rsi, rbx
  jmp    @mle
@mlb:
  cmp    rsi, r15
  jae    @mle
  mov    bl, byte ptr [rsi]
  cmp    bl, byte ptr [rdx]
  jne    @mle
  inc    rsi
  inc    rdx
  jmp    @mlb
@mle:
  sub    rsi, rax
  mov    rax, rsi
  ret

@done:
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

{ PlzInsRows: inserta las posiciones [A, B) en las filas (hasta 8 entradas) y, si TS <> nil, en
  la tabla corta; lo mismo que TPlzEngine.Insert posición por posición. }
procedure PlzInsRows(var S: TPlzEval; A, B: PByte); assembler; nostackframe;
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
  mov    r15, r8
  mov    r8, rdx
{$ELSE}
  mov    r8, rsi
  mov    r15, rdx
{$ENDIF}
  mov    r11, qword ptr [rdi + TPlzEval.Base]
  mov    r12, qword ptr [rdi + TPlzEval.Rows]
  mov    r13, qword ptr [rdi + TPlzEval.RowBytes]
  mov    ebp, dword ptr [rdi + TPlzEval.Cur0]
@loop:
  cmp    r8, r15
  jae    @done
  // posición relativa
  mov    r14, r8
  sub    r14, r11
  add    r14d, ebp                           // C (32 bits)
  mov    rax, qword ptr [r8]
  mov    ecx, dword ptr [rdi + TPlzEval.HShl]
  shl    rax, cl
  mov    rbx, $9E3779B185EBCA87
  imul   rax, rbx
  shr    rax, 32
  mov    edx, eax
  mov    ecx, dword ptr [rdi + TPlzEval.TagSh]
  shr    edx, cl                             // etiqueta en dl
  mov    ecx, dword ptr [rdi + TPlzEval.Sh]
  shr    eax, cl
  imul   rax, r13
  lea    r9, [r12 + rax]                     // fila
  mov    ecx, dword ptr [rdi + TPlzEval.HeadOff]
  movzx  eax, byte ptr [r9 + rcx]
  dec    eax
  and    eax, dword ptr [rdi + TPlzEval.WayMask]
  mov    byte ptr [r9 + rcx], al
  mov    byte ptr [r9 + rax], dl
  mov    ecx, dword ptr [rdi + TPlzEval.PosOff]
  lea    rbx, [r9 + rcx]
  mov    dword ptr [rbx + rax * 4], r14d
  // tabla corta
  mov    rbx, qword ptr [rdi + TPlzEval.TS]
  test   rbx, rbx
  jz     @next
  mov    eax, dword ptr [r8]
  mov    edx, eax
  imul   edx, edx, $9E3779B1
  mov    ecx, dword ptr [rdi + TPlzEval.SSh]
  shr    edx, cl
  shl    rax, 32
  or     rax, r14
  mov    qword ptr [rbx + rdx * 8], rax
@next:
  inc    r8
  jmp    @loop
@done:
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
