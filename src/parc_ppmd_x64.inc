{ parc_ppmd_x64.inc — el camino caliente de PPMd en ensamblador x86-64 (SysV y Win64).
  Se incluye desde parc_ppmd.pas con PPMD_ASM definido (x86-64 sin PARC_NOASM). Todo es bit a
  bit igual a la versión Pascal (DecodeStepPas / EncodeStepPas + UpdateModel), que sigue siendo
  la de i386 y la de -dPARC_NOASM, y la que se usa cerca del final de la entrada.
  Desplazamientos de los registros del heap: CONTEXT = NumStats 0, Flags 1, SummFreq 2, Stats 4,
  Suffix 8 (12 bytes); STATE = Symbol 0, Freq 1, Successor 2 (6 bytes). }

{ UpdateModel en ensamblador x86-64 para el caso común, bit a bit igual: UpdateModelSuffix,
  CreateSuccessors (con las dos llamadas posibles) y el bucle de UpdateModelAdd con el camino
  rápido del asignador (lista libre o LoUnit, ExpandUnits con copia incluido).
  Convención propia (sólo la llaman PpmdDecodeRunAsm y PpmdEncodeRunAsm): entra con rdi = Self,
  r15 = heap, r14d = MinContext; conserva rdi y r15 y usa todos los demás. Devuelve en eax:
    0  hecho (FMaxContext actualizado);
    1  no se tocó nada: hace falta UpdateModel en Pascal (ReduceOrder, poca memoria libre
       para CreateSuccessors, o el texto llegó a UnitsStart);
    2  el bucle de UpdateModelAdd se detuvo en FUmPc porque hace falta AllocUnitsRare: lo
       sigue UpdateModelResume.
  r13d = FSuccessor; CreateSuccessors es una subrutina interna (@cs). }
{$asmmode intel}
procedure PpmdUmCore; assembler; nostackframe;
asm
  // FoundState: Freq, Symbol, Successor
  mov eax, [rdi + TPpmdEngine.FFoundState]
  lea rbx, [r15 + rax]
  movzx ecx, byte ptr [rbx + 1]
  mov [rdi + TPpmdEngine.FUmFreq], ecx
  movzx edx, byte ptr [rbx]
  mov [rdi + TPpmdEngine.FUmSym], edx
  mov r13d, [rbx + 2]
  // ---- condiciones del camino rápido (si no, nada tocado: UpdateModel en Pascal) ----
  test r13d, r13d
  jz @bail
  mov eax, [rdi + TPpmdEngine.FHiUnit]
  sub eax, [rdi + TPpmdEngine.FLoUnit]
  cmp eax, 1560                          // UNIT_SIZE * (MAX_O + 2)
  jb @bail
  cmp dword ptr [rdi + TPpmdEngine.FOrderFall], 0
  je @pre_ok
  mov eax, [rdi + TPpmdEngine.FpText]
  inc eax
  cmp eax, [rdi + TPpmdEngine.FUnitsStart]
  jae @bail
@pre_ok:
  // ---- UpdateModelSuffix -> r12d = p (0 si no se tocó) ----
  xor r12d, r12d
  cmp ecx, 31                            // MAX_FREQ div 4
  jae @sufdone
  mov eax, [r15 + r14 + 8]
  test eax, eax
  jz @sufdone
  lea rsi, [r15 + rax]
  cmp byte ptr [rsi], 0
  je @sufbin
  mov eax, [rsi + 4]
  lea rbp, [r15 + rax]
  cmp [rbp], dl
  je @sufinc
@suff:
  add rbp, 6
  cmp [rbp], dl
  jne @suff
  mov al, [rbp + 1]
  cmp al, [rbp - 5]
  jb @sufinc
  // SwapState(s, s - 1); Dec(s)
  movzx eax, word ptr [rbp]
  mov ecx, [rbp + 2]
  movzx ebx, word ptr [rbp - 6]
  mov r8d, [rbp - 4]
  mov [rbp], bx
  mov [rbp + 2], r8d
  mov [rbp - 6], ax
  mov [rbp - 4], ecx
  sub rbp, 6
@sufinc:
  cmp byte ptr [rbp + 1], 115            // MAX_FREQ - 9
  jae @sufp
  add byte ptr [rbp + 1], 2
  add word ptr [rsi + 2], 2
@sufp:
  mov r12, rbp
  sub r12, r15
  jmp @sufdone
@sufbin:
  lea rbp, [rsi + 2]
  cmp byte ptr [rbp + 1], 32
  jae @sufp
  inc byte ptr [rbp + 1]
  jmp @sufp
@sufdone:
  // precarga: Stats de FSuccessor, que suele ser el próximo MinContext
  cmp r13d, [rdi + TPpmdEngine.FUnitsStart]
  jb @nopf3
  mov eax, [r15 + r13 + 4]
  prefetcht0 [r15 + rax]
@nopf3:
  cmp dword ptr [rdi + TPpmdEngine.FOrderFall], 0
  jne @notskip
  // ---- OrderFall = 0: FoundState.Succ := CreateSuccessors(True, p, MinContext) ----
  mov ecx, 1
  call @cs
  mov ecx, [rdi + TPpmdEngine.FFoundState]
  mov [r15 + rcx + 2], eax
  mov [rdi + TPpmdEngine.FMaxContext], eax
  xor eax, eax
  ret
@notskip:
  // pText^ := FSymbol; Inc(pText); Successor := pText
  mov eax, [rdi + TPpmdEngine.FpText]
  mov edx, [rdi + TPpmdEngine.FUmSym]
  mov [r15 + rax], dl
  inc eax
  mov [rdi + TPpmdEngine.FpText], eax
  cmp r13d, [rdi + TPpmdEngine.FUnitsStart]
  jae @fs_ok
  xor ecx, ecx
  call @cs
  mov r13d, eax
@fs_ok:
  mov r11d, [rdi + TPpmdEngine.FpText]       // Successor
  dec dword ptr [rdi + TPpmdEngine.FOrderFall]
  jnz @of_nz
  mov r11d, r13d
  cmp [rdi + TPpmdEngine.FMaxContext], r14d
  je @umastart
  dec dword ptr [rdi + TPpmdEngine.FpText]
  jmp @umastart
@of_nz:
  cmp dword ptr [rdi + TPpmdEngine.FMRMethod], 1   // MRM_FREEZE
  jle @umastart
  mov r11d, r13d
  mov dword ptr [rdi + TPpmdEngine.FpText], 0
  mov dword ptr [rdi + TPpmdEngine.FOrderFall], 0
  // ---- UpdateModelAdd: r8d ns, r9d s0, r11d Successor, rsi contexto, r12 MinContext ----
@umastart:
  lea r12, [r15 + r14]
  movzx r8d, byte ptr [r12]
  movzx r9d, word ptr [r12 + 2]
  sub r9d, r8d
  sub r9d, [rdi + TPpmdEngine.FUmFreq]
  xor eax, eax
  cmp dword ptr [rdi + TPpmdEngine.FUmSym], $40
  jb @flg
  mov eax, 8
@flg:
  mov [rdi + TPpmdEngine.FUmFlag], al
  mov eax, [rdi + TPpmdEngine.FMaxContext]
  lea rsi, [r15 + rax]
@uloop:
  cmp rsi, r12
  je @udone
  movzx ecx, byte ptr [rsi]
  test ecx, ecx
  jz @ubin
  test ecx, 1
  jz @unoexp
  // ExpandUnits(C^.Stats, nu)
  lea edx, [ecx + 1]
  shr edx, 1
  movzx eax, byte ptr [rdi + rdx + TPpmdEngine.FUnits2Indx]
  cmp al, byte ptr [rdi + rdx + TPpmdEngine.FUnits2Indx - 1]
  je @unoexp
  mov ebx, [rdi + rax * 8 + TPpmdEngine.FBList + 4]
  test ebx, ebx
  jz @ulo
  mov r10d, [r15 + rbx + 4]
  mov [rdi + rax * 8 + TPpmdEngine.FBList + 4], r10d
  dec dword ptr [rdi + rax * 8 + TPpmdEngine.FBList]
  jmp @ucopy
@ulo:
  mov ebx, [rdi + TPpmdEngine.FLoUnit]
  mov r10d, [rdi + rax * 4 + TPpmdEngine.FIndx2Bytes]
  mov eax, [rdi + TPpmdEngine.FHiUnit]
  sub eax, ebx
  cmp r10d, eax
  ja @ustop
  add r10d, ebx
  mov [rdi + TPpmdEngine.FLoUnit], r10d
@ucopy:
  mov eax, [rsi + 4]
  lea r14, [r15 + rax]
  lea rcx, [r15 + rbx]
  mov eax, edx
@ucp:
  mov r10, [r14]
  mov [rcx], r10
  mov r10d, [r14 + 8]
  mov [rcx + 8], r10d
  add r14, 12
  add rcx, 12
  dec eax
  jnz @ucp
  // BListInsert(Units2Indx[nu - 1], vieja, nu)
  movzx eax, byte ptr [rdi + rdx + TPpmdEngine.FUnits2Indx - 1]
  mov ecx, [rsi + 4]
  mov r10d, [rdi + rax * 8 + TPpmdEngine.FBList + 4]
  mov [r15 + rcx + 4], r10d
  mov [rdi + rax * 8 + TPpmdEngine.FBList + 4], ecx
  mov dword ptr [r15 + rcx], $FFFFFFFF
  mov [r15 + rcx + 8], edx
  inc dword ptr [rdi + rax * 8 + TPpmdEngine.FBList]
  mov [rsi + 4], ebx
@unoexp:
  movzx ecx, byte ptr [rsi]
  lea eax, [rcx + rcx * 2 + 1]
  cmp eax, r8d
  jae @ucommon
  inc word ptr [rsi + 2]
  jmp @ucommon
@ubin:
  // AllocUnits(1)
  mov ebx, [rdi + TPpmdEngine.FBList + 4]
  test ebx, ebx
  jz @ublo
  mov eax, [r15 + rbx + 4]
  mov [rdi + TPpmdEngine.FBList + 4], eax
  dec dword ptr [rdi + TPpmdEngine.FBList]
  jmp @ubok
@ublo:
  mov ebx, [rdi + TPpmdEngine.FLoUnit]
  mov eax, [rdi + TPpmdEngine.FHiUnit]
  sub eax, ebx
  cmp eax, 12
  jb @ustop
  lea eax, [rbx + 12]
  mov [rdi + TPpmdEngine.FLoUnit], eax
@ubok:
  movzx eax, word ptr [rsi + 2]
  mov [r15 + rbx], ax
  mov eax, [rsi + 4]
  mov [r15 + rbx + 2], eax
  mov [rsi + 4], ebx
  movzx eax, byte ptr [r15 + rbx + 1]
  cmp eax, 30                            // MAX_FREQ div 4 - 1
  jae @ub120
  add eax, eax
  jmp @ubf
@ub120:
  mov eax, 120                           // MAX_FREQ - 4
@ubf:
  mov [r15 + rbx + 1], al
  movzx ecx, byte ptr [rdi + TPpmdEngine.FInitEsc]
  add eax, ecx
  cmp r8d, 2
  jbe @ubs
  inc eax
@ubs:
  mov [rsi + 2], ax
@ucommon:
  movzx ecx, word ptr [rsi + 2]          // sfc
  mov eax, [rdi + TPpmdEngine.FUmFreq]
  add eax, eax
  lea edx, [rcx + 6]
  imul eax, edx                          // cf
  lea edx, [r9 + rcx]                    // sf
  lea ebx, [rdx + rdx * 2]
  add ebx, ebx                           // 6 sf
  cmp eax, ebx
  jae @uhigh
  lea ebx, [rdx * 4]
  cmp eax, ebx
  jb @ul2
  mov ebx, 3
  jmp @ulset
@ul2:
  cmp eax, edx
  jbe @ul1
  mov ebx, 2
  jmp @ulset
@ul1:
  mov ebx, 1
@ulset:
  add ecx, 4
  mov [rsi + 2], cx
  jmp @uappend
@uhigh:
  lea ebp, [rdx + rdx * 4]
  lea ebp, [rbp + rbp * 2]               // 15 sf
  cmp eax, ebp
  jbe @uh6
  mov ebx, 7
  jmp @uhset
@uh6:
  lea ebp, [rdx + rdx * 2]
  shl ebp, 2                             // 12 sf
  cmp eax, ebp
  jbe @uh5
  mov ebx, 6
  jmp @uhset
@uh5:
  lea ebp, [rdx + rdx * 8]               // 9 sf
  cmp eax, ebp
  jbe @uh4
  mov ebx, 5
  jmp @uhset
@uh4:
  mov ebx, 4
@uhset:
  add ecx, ebx
  mov [rsi + 2], cx
@uappend:
  movzx ecx, byte ptr [rsi]
  inc ecx
  and ecx, 255
  mov [rsi], cl
  mov eax, [rsi + 4]
  lea rcx, [rcx + rcx * 2]
  add rcx, rcx
  add rcx, rax
  add rcx, r15
  mov [rcx + 2], r11d
  mov eax, [rdi + TPpmdEngine.FUmSym]
  mov [rcx], al
  mov [rcx + 1], bl
  movzx eax, byte ptr [rdi + TPpmdEngine.FUmFlag]
  or [rsi + 1], al
  mov eax, [rsi + 8]
  lea rsi, [r15 + rax]
  jmp @uloop
@udone:
  mov [rdi + TPpmdEngine.FMaxContext], r13d
  xor eax, eax
  ret
@ustop:
  // lo sigue UpdateModelResume desde este contexto
  sub rsi, r15
  mov [rdi + TPpmdEngine.FUmPc], esi
  mov [rdi + TPpmdEngine.FUmNs], r8d
  mov [rdi + TPpmdEngine.FUmS0], r9d
  mov [rdi + TPpmdEngine.FUmSucc], r11d
  mov [rdi + TPpmdEngine.FUmFSucc], r13d
  mov eax, 2
  ret
@bail:
  mov eax, 1
  ret

  // ---- CreateSuccessors(Skip = ecx, p = r12d, pc = r14d) -> eax ----
  // Usa rax rbx rcx rdx rsi rbp r8 r9 r10 r11 y r12 (p no se usa después).
@cs:
  mov eax, [rdi + TPpmdEngine.FFoundState]
  lea rbx, [r15 + rax]
  mov r9d, [rbx + 2]                     // UpBranch
  movzx r10d, byte ptr [rbx]             // sym
  lea r8, [rdi + TPpmdEngine.FAsmPs]
  xor r11d, r11d
  lea rsi, [r15 + r14]
  test ecx, ecx
  jnz @cs_skip
  mov [r8], rbx
  mov r11d, 1
  cmp dword ptr [rsi + 8], 0
  je @cs_noloop
@cs_skip:
  mov eax, [rsi + 8]
  lea rsi, [r15 + rax]
  mov eax, [rsi + 8]                     // precarga del sufijo siguiente
  prefetcht0 [r15 + rax]
  test r12d, r12d
  jz @cs_find
  lea rbp, [r15 + r12]
  jmp @cs_entry
@cs_find:
  cmp byte ptr [rsi], 0
  je @cs_fbin
  mov eax, [rsi + 4]
  lea rbp, [r15 + rax]
  cmp [rbp], r10b
  je @cs_ff
@cs_fl:
  add rbp, 6
  cmp [rbp], r10b
  jne @cs_fl
@cs_ff:
  cmp byte ptr [rbp + 1], 115            // MAX_FREQ - 9
  jae @cs_entry
  inc byte ptr [rbp + 1]
  inc word ptr [rsi + 2]
  jmp @cs_entry
@cs_fbin:
  lea rbp, [rsi + 2]
  cmp byte ptr [rbp + 1], 24
  jae @cs_entry
  mov eax, [rsi + 8]
  cmp byte ptr [r15 + rax], 0
  jne @cs_entry
  inc byte ptr [rbp + 1]
@cs_entry:
  mov eax, [rbp + 2]
  cmp eax, r9d
  je @cs_add
  lea rsi, [r15 + rax]
  jmp @cs_noloop
@cs_add:
  mov [r8 + r11 * 8], rbp
  inc r11d
  mov eax, [rsi + 8]
  test eax, eax
  jz @cs_noloop
  lea rsi, [r15 + rax]
  mov eax, [rsi + 8]                     // precarga del sufijo siguiente
  prefetcht0 [r15 + rax]
  jmp @cs_find
@cs_noloop:
  test r11d, r11d
  jnz @cs_make
  mov rax, rsi
  sub rax, r15
  ret
@cs_make:
  xor edx, edx
  cmp r10d, $40
  jb @cf1
  mov edx, $10
@cf1:
  movzx r10d, byte ptr [r15 + r9]        // símbolo nuevo = H[UpBranch]
  cmp r10d, $40
  jb @cf2
  or edx, 8
@cf2:
  cmp byte ptr [rsi], 0
  je @cs_hibin
  mov eax, [rsi + 4]
  lea rbp, [r15 + rax]
  cmp [rbp], r10b
  je @cs_hf
@cs_hl:
  add rbp, 6
  cmp [rbp], r10b
  jne @cs_hl
@cs_hf:
  movzx ecx, byte ptr [rbp + 1]
  dec ecx                                // cf
  movzx eax, word ptr [rsi + 2]
  movzx ebx, byte ptr [rsi]
  sub eax, ebx
  sub eax, ecx                           // s0
  lea ebx, [rcx + rcx]
  cmp ebx, eax
  ja @cs_div
  lea ebx, [rcx + rcx * 4]
  cmp ebx, eax
  jbe @cs_h1
  mov ebx, 2
  jmp @cs_hdr
@cs_h1:
  mov ebx, 1
  jmp @cs_hdr
@cs_div:
  mov ebx, eax
  add eax, eax
  add eax, ecx
  sub eax, 3                             // cf + 2 s0 - 3
  mov r12d, edx
  xor edx, edx
  div ebx
  mov edx, r12d
  lea ebx, [rax + 1]
  jmp @cs_hdr
@cs_hibin:
  movzx ebx, byte ptr [rsi + 3]
@cs_hdr:
  movzx ebx, bl
  shl ebx, 24
  shl r10d, 16
  or ebx, r10d
  shl edx, 8
  or ebx, edx
  lea eax, [r9 + 1]
  shl rax, 32
  or rbx, rax
  mov rax, rsi
  sub rax, r15
  mov ecx, [rdi + TPpmdEngine.FHiUnit]
@cs_alloc:
  sub ecx, 12
  mov [r15 + rcx], rbx
  mov [r15 + rcx + 8], eax
  dec r11d
  mov rdx, [r8 + r11 * 8]
  mov [rdx + 2], ecx
  mov eax, ecx
  test r11d, r11d
  jnz @cs_alloc
  mov [rdi + TPpmdEngine.FHiUnit], ecx
  ret

end;
{$asmmode default}

{ El bucle de DecodeMore en ensamblador x86-64, bit a bit igual: por símbolo, DecodeStepPas
  (DecodeSymbol1, DecodeBinSymbol, MakeEscFreq2 y DecodeSymbol2 en línea), la salida del byte y
  UpdateModel (PpmdUmCore). FPC no deja el estado del range coder ni los punteros en registros
  a lo largo de esas funciones, y las llamadas cuestan casi tanto como el trabajo. No llama a
  Pascal ni toca la pila (salvo la llamada interna a PpmdUmCore): los registros preservados
  (SysV y Win64) se guardan en FAsmSv, así no hace falta información de unwind en Win64.
  Sigue mientras FOutLen < ALimit y haya PPMD_IN_MARGIN bytes de entrada. Devuelve:
    0  llegó a ALimit;  5  falta entrada (InRefill o DecodeStepPas);
    1..4  un símbolo a medias, como lo deja DecodeStepPas (RESCALE, errores, STOP);
    6, 7  símbolo emitido: falta UpdateModel / UpdateModelResume (PpmdUmCore devolvió 1 / 2).
  Registros: rdi Self, r15 heap, r8d Low, r9d Range, r10d Code, r11 cursor de entrada,
  r12 contexto, r14 SEE, el resto temporales. }
{$asmmode intel}
function PpmdDecodeRunAsm(e: TPpmdEngine; ALimit: SizeInt): LongInt; assembler; nostackframe;
asm
{$IFDEF WIN64}
  mov rax, rcx
  mov [rax + TPpmdEngine.FAsmLimit], rdx
{$ELSE}
  mov rax, rdi
  mov [rax + TPpmdEngine.FAsmLimit], rsi
{$ENDIF}
  mov [rax + TPpmdEngine.FAsmSv + 0], rbx
  mov [rax + TPpmdEngine.FAsmSv + 8], rbp
  mov [rax + TPpmdEngine.FAsmSv + 16], r12
  mov [rax + TPpmdEngine.FAsmSv + 24], r13
  mov [rax + TPpmdEngine.FAsmSv + 32], r14
  mov [rax + TPpmdEngine.FAsmSv + 40], r15
  mov [rax + TPpmdEngine.FAsmSv + 48], rdi
  mov [rax + TPpmdEngine.FAsmSv + 56], rsi
  mov rdi, rax
  mov r15, [rdi + TPpmdEngine.FHeap]
  mov r8d, [rdi + TPpmdEngine.FLow]
  mov r9d, [rdi + TPpmdEngine.FRange]
  mov r10d, [rdi + TPpmdEngine.FCode]
  mov r11, [rdi + TPpmdEngine.FInPos]
  lea r11, [rdi + r11 + TPpmdEngine.FInBuf]
  // ---- un símbolo por vuelta ----
@sym:
  mov rax, [rdi + TPpmdEngine.FOutLen]
  cmp rax, [rdi + TPpmdEngine.FAsmLimit]
  jge @r_limit
  lea rax, [rdi + TPpmdEngine.FInBuf]
  add rax, [rdi + TPpmdEngine.FInLen]
  sub rax, r11
  cmp rax, PPMD_IN_MARGIN
  jl @r_refill
  mov dword ptr [rdi + TPpmdEngine.FAsmPhase], 0
  // ---- AriDecNormalize ----
@norm:
  mov eax, r8d
  add eax, r9d
  xor eax, r8d
  cmp eax, $1000000
  jb @shift
  cmp r9d, $8000
  jae @normdone
  mov r9d, r8d
  neg r9d
  and r9d, $7FFF
@shift:
  movzx eax, byte ptr [r11]
  inc r11
  shl r10d, 8
  or r10d, eax
  shl r9d, 8
  shl r8d, 8
  jmp @norm
@normdone:
  cmp dword ptr [rdi + TPpmdEngine.FAsmPhase], 0
  jne @escwalk
  mov dword ptr [rdi + TPpmdEngine.FAsmPhase], 1
  mov eax, [rdi + TPpmdEngine.FMinContext]
  lea r12, [r15 + rax]
  mov eax, [r12 + 8]
  prefetcht0 [r15 + rax]
  cmp byte ptr [r12], 0
  je @bin
  // ---- DecodeSymbol1 ----
  mov eax, [r12 + 4]
  lea rsi, [r15 + rax]
  movzx ebx, word ptr [r12 + 2]
  test ebx, ebx
  jz @errscale
  mov eax, r9d
  xor edx, edx
  div ebx
  test eax, eax
  jz @errrange
  mov r9d, eax
  mov ecx, eax
  mov eax, r10d
  sub eax, r8d
  xor edx, edx
  div ecx
  // precarga: Stats y Suffix del sufijo (el sufijo se pidió al empezar y ya llegó mientras se
  // esperaba Stats de este contexto); los usan el escape y UpdateModel
  mov r14d, [r12 + 8]
  mov ecx, [r15 + r14 + 4]
  prefetcht0 [r15 + rcx]
  mov ecx, [r15 + r14 + 8]
  prefetcht0 [r15 + rcx]
  movzx r13d, byte ptr [rsi + 1]
  cmp eax, r13d
  jae @s1scan
  // el más probable
  lea ecx, [r13d + r13d]
  xor edx, edx
  cmp ecx, ebx
  setae dl
  mov [rdi + TPpmdEngine.FPrevSuccess], dl
  add [rdi + TPpmdEngine.FRunLength], edx
  mov eax, [r12 + 4]
  mov [rdi + TPpmdEngine.FFoundState], eax
  add byte ptr [rsi + 1], 4
  add word ptr [r12 + 2], 4
  imul r9d, r13d
  xor eax, eax
  cmp r13d, 120
  seta al
  jmp @found
@s1scan:
  movzx ecx, byte ptr [r12]
  mov byte ptr [rdi + TPpmdEngine.FPrevSuccess], 0
@s1loop:
  add rsi, 6
  movzx edx, byte ptr [rsi + 1]
  add r13d, edx
  cmp r13d, eax
  ja @s1found
  dec ecx
  jnz @s1loop
  // escape: SubLow = HiCnt, SubHigh = scale
  movzx edx, byte ptr [rdi + TPpmdEngine.FEscCount]
  movzx eax, byte ptr [rsi]
  mov [rdi + rax + TPpmdEngine.FCharMask], dl
  movzx ecx, byte ptr [r12]
  mov [rdi + TPpmdEngine.FNumMasked], cl
  mov dword ptr [rdi + TPpmdEngine.FFoundState], 0
@s1mask:
  sub rsi, 6
  movzx eax, byte ptr [rsi]
  mov [rdi + rax + TPpmdEngine.FCharMask], dl
  dec ecx
  jnz @s1mask
  mov eax, r9d
  imul eax, r13d
  add r8d, eax
  sub ebx, r13d
  imul r9d, ebx
  jmp @norm
@s1found:
  // SubHigh = HiCnt, SubLow = HiCnt - Freq
  mov eax, r13d
  sub eax, edx
  imul eax, r9d
  add r8d, eax
  imul r9d, edx
  mov rax, rsi
  sub rax, r15
  mov [rdi + TPpmdEngine.FFoundState], eax
  add byte ptr [rsi + 1], 4
  add word ptr [r12 + 2], 4
  movzx edx, byte ptr [rsi + 1]
  xor eax, eax
  cmp dl, byte ptr [rsi - 5]
  jbe @found
  // SwapState(p, p - 1)
  movzx ecx, word ptr [rsi]
  mov r13d, [rsi + 2]
  movzx ebx, word ptr [rsi - 6]
  mov r14d, [rsi - 4]
  mov [rsi], bx
  mov [rsi + 2], r14d
  mov [rsi - 6], cx
  mov [rsi - 4], r13d
  lea rax, [rsi - 6]
  sub rax, r15
  mov [rdi + TPpmdEngine.FFoundState], eax
  xor eax, eax
  cmp dl, 124
  seta al
  jmp @found
  // ---- DecodeBinSymbol ----
@bin:
  movzx eax, byte ptr [r12 + 3]
  movzx eax, byte ptr [rdi + rax + TPpmdEngine.FQTable - 1]
  shl eax, 7
  mov ecx, [r12 + 8]
  movzx ecx, byte ptr [r15 + rcx]
  movzx ecx, byte ptr [rdi + rcx + TPpmdEngine.FNS2BSIndx]
  movzx edx, byte ptr [rdi + TPpmdEngine.FPrevSuccess]
  add ecx, edx
  movzx edx, byte ptr [r12 + 1]
  add ecx, edx
  mov edx, [rdi + TPpmdEngine.FRunLength]
  shr edx, 26
  and edx, $20
  add ecx, edx
  lea rbx, [rdi + rax + TPpmdEngine.FBinSumm]
  lea rbx, [rbx + rcx * 2]
  mov eax, r9d
  shr eax, 14
  jz @errrange
  mov r9d, eax
  mov ecx, eax
  mov eax, r10d
  sub eax, r8d
  xor edx, edx
  div ecx
  // precarga: Stats y Suffix del sufijo (el sufijo se pidió al empezar y ya llegó mientras se
  // esperaba Stats de este contexto); los usan el escape y UpdateModel
  mov r14d, [r12 + 8]
  mov ecx, [r15 + r14 + 4]
  prefetcht0 [r15 + rcx]
  mov ecx, [r15 + r14 + 8]
  prefetcht0 [r15 + rcx]
  movzx ecx, word ptr [rbx]
  cmp eax, ecx
  jae @binesc
  mov eax, [rdi + TPpmdEngine.FMinContext]
  add eax, 2
  mov [rdi + TPpmdEngine.FFoundState], eax
  cmp byte ptr [r12 + 3], 196
  jae @bf1
  inc byte ptr [r12 + 3]
@bf1:
  imul r9d, ecx
  lea edx, [ecx + 32]
  shr edx, 7
  lea eax, [ecx + 128]
  sub eax, edx
  mov [rbx], ax
  mov byte ptr [rdi + TPpmdEngine.FPrevSuccess], 1
  inc dword ptr [rdi + TPpmdEngine.FRunLength]
  xor eax, eax
  jmp @found
@binesc:
  // SubLow = b, SubHigh = BIN_SCALE
  mov eax, r9d
  imul eax, ecx
  add r8d, eax
  mov eax, $4000
  sub eax, ecx
  imul r9d, eax
  lea edx, [ecx + 32]
  shr edx, 7
  sub ecx, edx
  mov [rbx], cx
  movzx ecx, cx
  shr ecx, 10
  movzx ecx, byte ptr [rdi + rcx + TPpmdEngine.FExpEscape]
  mov [rdi + TPpmdEngine.FInitEsc], cl
  movzx eax, byte ptr [r12 + 2]
  movzx edx, byte ptr [rdi + TPpmdEngine.FEscCount]
  mov [rdi + rax + TPpmdEngine.FCharMask], dl
  mov byte ptr [rdi + TPpmdEngine.FNumMasked], 0
  mov byte ptr [rdi + TPpmdEngine.FPrevSuccess], 0
  mov dword ptr [rdi + TPpmdEngine.FFoundState], 0
  jmp @norm
  // ---- escape: bajar por los sufijos ----
@escwalk:
  mov eax, [rdi + TPpmdEngine.FMinContext]
  movzx ecx, byte ptr [rdi + TPpmdEngine.FNumMasked]
@walk:
  inc dword ptr [rdi + TPpmdEngine.FOrderFall]
  mov eax, [r15 + rax + 8]
  test eax, eax
  jz @stop
  cmp byte ptr [r15 + rax], cl
  je @walk
  mov [rdi + TPpmdEngine.FMinContext], eax
  lea r12, [r15 + rax]
  // ---- MakeEscFreq2 ----
  movzx eax, byte ptr [r12]
  cmp eax, 255
  je @dummysee
  mov ecx, [r12 + 8]
  movzx ecx, byte ptr [r15 + rcx]
  movzx edx, byte ptr [rdi + TPpmdEngine.FNumMasked]
  add ecx, edx
  movzx edx, byte ptr [r12 + 1]
  lea esi, [eax + eax]
  cmp esi, ecx
  jae @c1
  add edx, 2
@c1:
  lea esi, [eax + 1]
  imul esi, 11
  movzx ecx, word ptr [r12 + 2]
  cmp ecx, esi
  jbe @c2
  inc edx
@c2:
  movzx eax, byte ptr [rdi + rax + TPpmdEngine.FQTable + 2]
  sub eax, 3
  shl eax, 7
  lea r14, [rdi + rax + TPpmdEngine.FSEE2Cont]
  lea r14, [r14 + rdx * 4]
  movzx eax, word ptr [r14]
  movzx ecx, byte ptr [r14 + 2]
  mov edx, eax
  shr edx, cl
  sub eax, edx
  mov [r14], ax
  cmp edx, 1
  adc edx, 0
  mov ebx, edx
  jmp @sym2
@dummysee:
  lea r14, [rdi + TPpmdEngine.FDummySEE2]
  mov ebx, 1
  // ---- DecodeSymbol2 ----
@sym2:
  movzx ecx, byte ptr [r12]
  movzx eax, byte ptr [rdi + TPpmdEngine.FNumMasked]
  sub ecx, eax
  mov eax, [r12 + 4]
  lea rsi, [r15 + rax - 6]
  movzx edx, byte ptr [rdi + TPpmdEngine.FEscCount]
  lea rbp, [rdi + TPpmdEngine.FAsmPs]
  xor eax, eax
@g1:
  add rsi, 6
  movzx r13d, byte ptr [rsi]
  cmp [rdi + r13 + TPpmdEngine.FCharMask], dl
  je @g1
  movzx r13d, byte ptr [rsi + 1]
  add eax, r13d
  mov [rbp], rsi
  add rbp, 8
  dec ecx
  jnz @g1
  add ebx, eax
  jz @errscale
  mov r13d, eax
  mov eax, r9d
  xor edx, edx
  div ebx
  test eax, eax
  jz @errrange
  mov r9d, eax
  mov ecx, eax
  mov eax, r10d
  sub eax, r8d
  xor edx, edx
  div ecx
  cmp eax, r13d
  jae @s2esc
  lea rcx, [rdi + TPpmdEngine.FAsmPs]
  mov rsi, [rcx]
  movzx r13d, byte ptr [rsi + 1]
  cmp r13d, eax
  ja @s2f
@s2l:
  add rcx, 8
  mov rsi, [rcx]
  movzx edx, byte ptr [rsi + 1]
  add r13d, edx
  cmp r13d, eax
  jbe @s2l
@s2f:
  movzx edx, byte ptr [rsi + 1]
  mov eax, r13d
  sub eax, edx
  imul eax, r9d
  add r8d, eax
  imul r9d, edx
  // See2Update
  movzx ecx, byte ptr [r14 + 2]
  cmp ecx, 7
  jae @su
  dec byte ptr [r14 + 3]
  jnz @su
  shl word ptr [r14], 1
  mov eax, 3
  shl eax, cl
  mov [r14 + 3], al
  inc byte ptr [r14 + 2]
@su:
  mov rax, rsi
  sub rax, r15
  mov [rdi + TPpmdEngine.FFoundState], eax
  add byte ptr [rsi + 1], 4
  add word ptr [r12 + 2], 4
  inc byte ptr [rdi + TPpmdEngine.FEscCount]
  mov eax, [rdi + TPpmdEngine.FInitRL]
  mov [rdi + TPpmdEngine.FRunLength], eax
  xor eax, eax
  cmp byte ptr [rsi + 1], 124
  seta al
  jmp @found
@s2esc:
  // SubLow = HiCnt, SubHigh = scale
  mov eax, r9d
  imul eax, r13d
  add r8d, eax
  mov eax, ebx
  sub eax, r13d
  imul r9d, eax
  movzx eax, byte ptr [r12]
  mov [rdi + TPpmdEngine.FNumMasked], al
  movzx edx, byte ptr [rdi + TPpmdEngine.FEscCount]
  lea rcx, [rdi + TPpmdEngine.FAsmPs]
@m2:
  mov rsi, [rcx]
  movzx eax, byte ptr [rsi]
  mov [rdi + rax + TPpmdEngine.FCharMask], dl
  add rcx, 8
  cmp rcx, rbp
  jne @m2
  add word ptr [r14], bx
  jmp @norm
@stop:
  mov dword ptr [rdi + TPpmdEngine.FMinContext], 0
  mov eax, 4
  jmp @done
@errscale:
  mov eax, 2
  jmp @done
@errrange:
  mov eax, 3
  jmp @done
  // ---- símbolo encontrado: lo que en Pascal hace DecodeMore después del paso ----
@found:
  test eax, eax
  jnz @done                              // RESCALE: lo sigue DecodeMore
  mov eax, [rdi + TPpmdEngine.FFoundState]
  lea rbx, [r15 + rax]
  mov ecx, [rbx + 2]                     // Successor
  prefetcht0 [r15 + rcx]
  movzx edx, byte ptr [rbx]
  mov rax, [rdi + TPpmdEngine.FOutBuf]
  mov rsi, [rdi + TPpmdEngine.FOutLen]
  mov [rax + rsi], dl
  inc rsi
  mov [rdi + TPpmdEngine.FOutLen], rsi
  cmp dword ptr [rdi + TPpmdEngine.FOrderFall], 0
  jne @um
  cmp ecx, [rdi + TPpmdEngine.FUnitsStart]
  jb @um
  mov [rdi + TPpmdEngine.FMaxContext], ecx
  jmp @next
@um:
  mov [rdi + TPpmdEngine.FLow], r8d
  mov [rdi + TPpmdEngine.FRange], r9d
  mov [rdi + TPpmdEngine.FCode], r10d
  lea rcx, [rdi + TPpmdEngine.FInBuf]
  sub r11, rcx
  mov [rdi + TPpmdEngine.FInPos], r11
  mov r14d, [rdi + TPpmdEngine.FMinContext]
  call PpmdUmCore
  test eax, eax
  jnz @r_um
  mov r8d, [rdi + TPpmdEngine.FLow]
  mov r9d, [rdi + TPpmdEngine.FRange]
  mov r10d, [rdi + TPpmdEngine.FCode]
  mov r11, [rdi + TPpmdEngine.FInPos]
  lea r11, [rdi + r11 + TPpmdEngine.FInBuf]
  // ClearMask si EscCount dio la vuelta
  cmp byte ptr [rdi + TPpmdEngine.FEscCount], 0
  jne @next
  mov byte ptr [rdi + TPpmdEngine.FEscCount], 1
  inc byte ptr [rdi + TPpmdEngine.FPrintCount]
  lea rax, [rdi + TPpmdEngine.FCharMask]
  xor ecx, ecx
  mov edx, 32
@cm:
  mov [rax], rcx
  add rax, 8
  dec edx
  jnz @cm
@next:
  mov eax, [rdi + TPpmdEngine.FMaxContext]
  mov [rdi + TPpmdEngine.FMinContext], eax
  jmp @sym
@r_um:
  add eax, 5                             // 6: UpdateModel, 7: UpdateModelResume
  jmp @restore
@r_limit:
  xor eax, eax
  jmp @done
@r_refill:
  mov eax, 5
@done:
  mov [rdi + TPpmdEngine.FLow], r8d
  mov [rdi + TPpmdEngine.FRange], r9d
  mov [rdi + TPpmdEngine.FCode], r10d
  lea rcx, [rdi + TPpmdEngine.FInBuf]
  sub r11, rcx
  mov [rdi + TPpmdEngine.FInPos], r11
@restore:
  mov rcx, rdi
  mov rbx, [rcx + TPpmdEngine.FAsmSv + 0]
  mov rbp, [rcx + TPpmdEngine.FAsmSv + 8]
  mov r12, [rcx + TPpmdEngine.FAsmSv + 16]
  mov r13, [rcx + TPpmdEngine.FAsmSv + 24]
  mov r14, [rcx + TPpmdEngine.FAsmSv + 32]
  mov r15, [rcx + TPpmdEngine.FAsmSv + 40]
  mov rdi, [rcx + TPpmdEngine.FAsmSv + 48]
  mov rsi, [rcx + TPpmdEngine.FAsmSv + 56]
end;
{$asmmode default}

{ El bucle de EncodeBytes en ensamblador x86-64, bit a bit igual: por byte, EncodeStepPas
  (EncodeSymbol1, EncodeBinSymbol, MakeEscFreq2, EncodeSymbol2 y el range encoder en línea) y
  UpdateModel (PpmdUmCore). Mismo esquema que PpmdDecodeRunAsm. Sigue mientras queden bytes y
  haya PPMD_IN_MARGIN libres en FEncBuf; FAsmPos = bytes consumidos. Devuelve: 0 terminó;
  5 hay que vaciar FEncBuf; 1 (RESCALE) o 4 (STOP) el último byte quedó como lo deja
  EncodeStepPas; 6, 7 falta UpdateModel / UpdateModelResume del último byte. Registros: rdi Self, r15 heap, r8d Low, r9d Range, r10 cursor de salida,
  r11d c, r12 contexto, r14 SEE, el resto temporales. }
{$asmmode intel}
function PpmdEncodeRunAsm(e: TPpmdEngine; Buf: PByte; Count: SizeInt): LongInt; assembler; nostackframe;
asm
{$IFDEF WIN64}
  mov rax, rcx
  mov [rax + TPpmdEngine.FAsmBuf], rdx
  mov [rax + TPpmdEngine.FAsmCount], r8
{$ELSE}
  mov rax, rdi
  mov [rax + TPpmdEngine.FAsmBuf], rsi
  mov [rax + TPpmdEngine.FAsmCount], rdx
{$ENDIF}
  mov qword ptr [rax + TPpmdEngine.FAsmPos], 0
  mov [rax + TPpmdEngine.FAsmSv + 0], rbx
  mov [rax + TPpmdEngine.FAsmSv + 8], rbp
  mov [rax + TPpmdEngine.FAsmSv + 16], r12
  mov [rax + TPpmdEngine.FAsmSv + 24], r13
  mov [rax + TPpmdEngine.FAsmSv + 32], r14
  mov [rax + TPpmdEngine.FAsmSv + 40], r15
  mov [rax + TPpmdEngine.FAsmSv + 48], rdi
  mov [rax + TPpmdEngine.FAsmSv + 56], rsi
  mov rdi, rax
  mov r15, [rdi + TPpmdEngine.FHeap]
  mov r8d, [rdi + TPpmdEngine.FLow]
  mov r9d, [rdi + TPpmdEngine.FRange]
  movsxd r10, dword ptr [rdi + TPpmdEngine.FEncBufLen]
  lea r10, [rdi + r10 + TPpmdEngine.FEncBuf]
  // ---- un símbolo por vuelta ----
@sym:
  mov rax, [rdi + TPpmdEngine.FAsmPos]
  cmp rax, [rdi + TPpmdEngine.FAsmCount]
  jge @r_limit
  lea rcx, [rdi + TPpmdEngine.FEncBuf + PPMD_ENC_BUF - PPMD_IN_MARGIN]
  cmp r10, rcx
  ja @r_flush
  mov rcx, [rdi + TPpmdEngine.FAsmBuf]
  movzx r11d, byte ptr [rcx + rax]
  inc rax
  mov [rdi + TPpmdEngine.FAsmPos], rax
  mov dword ptr [rdi + TPpmdEngine.FAsmPhase], 0
  // ---- AriEncNormalize ----
@norm:
  mov eax, r8d
  add eax, r9d
  xor eax, r8d
  cmp eax, $1000000
  jb @emit
  cmp r9d, $8000
  jae @normdone
  mov r9d, r8d
  neg r9d
  and r9d, $7FFF
@emit:
  mov eax, r8d
  shr eax, 24
  mov [r10], al
  inc r10
  shl r9d, 8
  shl r8d, 8
  jmp @norm
@normdone:
  cmp dword ptr [rdi + TPpmdEngine.FAsmPhase], 0
  jne @escwalk
  mov dword ptr [rdi + TPpmdEngine.FAsmPhase], 1
  mov eax, [rdi + TPpmdEngine.FMinContext]
  lea r12, [r15 + rax]
  mov eax, [r12 + 8]
  prefetcht0 [r15 + rax]
  cmp byte ptr [r12], 0
  je @bin
  // ---- EncodeSymbol1 + AriEncodeSymbol ----
  mov eax, [r12 + 4]
  lea rsi, [r15 + rax]
  movzx ebx, word ptr [r12 + 2]
  movzx r13d, byte ptr [rsi + 1]
  // precarga: Stats y Suffix del sufijo (el sufijo se pidió al empezar y ya llegó mientras se
  // esperaba Stats de este contexto); los usan el escape y UpdateModel
  mov r14d, [r12 + 8]
  mov ecx, [r15 + r14 + 4]
  prefetcht0 [r15 + rcx]
  mov ecx, [r15 + r14 + 8]
  prefetcht0 [r15 + rcx]
  cmp byte ptr [rsi], r11b
  jne @e1scan
  // el más probable: SubLow = 0, SubHigh = Freq
  lea ecx, [r13d + r13d]
  xor eax, eax
  cmp ecx, ebx
  setae al
  mov [rdi + TPpmdEngine.FPrevSuccess], al
  add [rdi + TPpmdEngine.FRunLength], eax
  mov eax, [r12 + 4]
  mov [rdi + TPpmdEngine.FFoundState], eax
  add byte ptr [rsi + 1], 4
  add word ptr [r12 + 2], 4
  mov eax, r9d
  xor edx, edx
  div ebx
  imul eax, r13d
  mov r9d, eax
  xor eax, eax
  cmp r13d, 120
  seta al
  jmp @found
@e1scan:
  movzx ecx, byte ptr [r12]
  mov byte ptr [rdi + TPpmdEngine.FPrevSuccess], 0
@e1loop:
  add rsi, 6
  cmp byte ptr [rsi], r11b
  je @e1found
  movzx eax, byte ptr [rsi + 1]
  add r13d, eax
  cmp ecx, 1
  je @e1esc
  dec ecx
  jmp @e1loop
@e1esc:
  // SubLow = LoCnt, SubHigh = scale
  movzx edx, byte ptr [rdi + TPpmdEngine.FEscCount]
  movzx eax, byte ptr [rsi]
  mov [rdi + rax + TPpmdEngine.FCharMask], dl
  movzx ecx, byte ptr [r12]
  mov [rdi + TPpmdEngine.FNumMasked], cl
  mov dword ptr [rdi + TPpmdEngine.FFoundState], 0
@e1mask:
  sub rsi, 6
  movzx eax, byte ptr [rsi]
  mov [rdi + rax + TPpmdEngine.FCharMask], dl
  dec ecx
  jnz @e1mask
  mov eax, r9d
  xor edx, edx
  div ebx
  mov ecx, eax
  imul eax, r13d
  add r8d, eax
  sub ebx, r13d
  imul ecx, ebx
  mov r9d, ecx
  jmp @norm
@e1found:
  // SubLow = LoCnt, SubHigh = LoCnt + Freq
  movzx r14d, byte ptr [rsi + 1]
  mov eax, r9d
  xor edx, edx
  div ebx
  mov ecx, eax
  imul eax, r13d
  add r8d, eax
  imul ecx, r14d
  mov r9d, ecx
  mov rax, rsi
  sub rax, r15
  mov [rdi + TPpmdEngine.FFoundState], eax
  add byte ptr [rsi + 1], 4
  add word ptr [r12 + 2], 4
  movzx edx, byte ptr [rsi + 1]
  xor eax, eax
  cmp dl, byte ptr [rsi - 5]
  jbe @found
  movzx ecx, word ptr [rsi]
  mov r13d, [rsi + 2]
  movzx ebx, word ptr [rsi - 6]
  mov r14d, [rsi - 4]
  mov [rsi], bx
  mov [rsi + 2], r14d
  mov [rsi - 6], cx
  mov [rsi - 4], r13d
  lea rax, [rsi - 6]
  sub rax, r15
  mov [rdi + TPpmdEngine.FFoundState], eax
  xor eax, eax
  cmp dl, 124
  seta al
  jmp @found
  // ---- EncodeBinSymbol + AriShiftEncodeSymbol(TOT_BITS) ----
@bin:
  movzx eax, byte ptr [r12 + 3]
  movzx eax, byte ptr [rdi + rax + TPpmdEngine.FQTable - 1]
  shl eax, 7
  mov ecx, [r12 + 8]
  movzx ecx, byte ptr [r15 + rcx]
  movzx ecx, byte ptr [rdi + rcx + TPpmdEngine.FNS2BSIndx]
  movzx edx, byte ptr [rdi + TPpmdEngine.FPrevSuccess]
  add ecx, edx
  movzx edx, byte ptr [r12 + 1]
  add ecx, edx
  mov edx, [rdi + TPpmdEngine.FRunLength]
  shr edx, 26
  and edx, $20
  add ecx, edx
  lea rbx, [rdi + rax + TPpmdEngine.FBinSumm]
  lea rbx, [rbx + rcx * 2]
  // precarga: Stats y Suffix del sufijo (el sufijo se pidió al empezar y ya llegó mientras se
  // esperaba Stats de este contexto); los usan el escape y UpdateModel
  mov r14d, [r12 + 8]
  mov ecx, [r15 + r14 + 4]
  prefetcht0 [r15 + rcx]
  mov ecx, [r15 + r14 + 8]
  prefetcht0 [r15 + rcx]
  movzx ecx, word ptr [rbx]
  shr r9d, 14
  cmp byte ptr [r12 + 2], r11b
  jne @ebinesc
  mov eax, [rdi + TPpmdEngine.FMinContext]
  add eax, 2
  mov [rdi + TPpmdEngine.FFoundState], eax
  cmp byte ptr [r12 + 3], 196
  jae @ebf1
  inc byte ptr [r12 + 3]
@ebf1:
  imul r9d, ecx
  lea edx, [ecx + 32]
  shr edx, 7
  lea eax, [ecx + 128]
  sub eax, edx
  mov [rbx], ax
  mov byte ptr [rdi + TPpmdEngine.FPrevSuccess], 1
  inc dword ptr [rdi + TPpmdEngine.FRunLength]
  xor eax, eax
  jmp @found
@ebinesc:
  // SubLow = b, SubHigh = BIN_SCALE
  mov eax, r9d
  imul eax, ecx
  add r8d, eax
  mov eax, $4000
  sub eax, ecx
  imul r9d, eax
  lea edx, [ecx + 32]
  shr edx, 7
  sub ecx, edx
  mov [rbx], cx
  movzx ecx, cx
  shr ecx, 10
  movzx ecx, byte ptr [rdi + rcx + TPpmdEngine.FExpEscape]
  mov [rdi + TPpmdEngine.FInitEsc], cl
  movzx eax, byte ptr [r12 + 2]
  movzx edx, byte ptr [rdi + TPpmdEngine.FEscCount]
  mov [rdi + rax + TPpmdEngine.FCharMask], dl
  mov byte ptr [rdi + TPpmdEngine.FNumMasked], 0
  mov byte ptr [rdi + TPpmdEngine.FPrevSuccess], 0
  mov dword ptr [rdi + TPpmdEngine.FFoundState], 0
  jmp @norm
  // ---- escape: bajar por los sufijos ----
@escwalk:
  mov eax, [rdi + TPpmdEngine.FMinContext]
  movzx ecx, byte ptr [rdi + TPpmdEngine.FNumMasked]
@walk:
  inc dword ptr [rdi + TPpmdEngine.FOrderFall]
  mov eax, [r15 + rax + 8]
  test eax, eax
  jz @stop
  cmp byte ptr [r15 + rax], cl
  je @walk
  mov [rdi + TPpmdEngine.FMinContext], eax
  lea r12, [r15 + rax]
  // ---- MakeEscFreq2 ----
  movzx eax, byte ptr [r12]
  cmp eax, 255
  je @dummysee
  mov ecx, [r12 + 8]
  movzx ecx, byte ptr [r15 + rcx]
  movzx edx, byte ptr [rdi + TPpmdEngine.FNumMasked]
  add ecx, edx
  movzx edx, byte ptr [r12 + 1]
  lea esi, [eax + eax]
  cmp esi, ecx
  jae @c1
  add edx, 2
@c1:
  lea esi, [eax + 1]
  imul esi, 11
  movzx ecx, word ptr [r12 + 2]
  cmp ecx, esi
  jbe @c2
  inc edx
@c2:
  movzx eax, byte ptr [rdi + rax + TPpmdEngine.FQTable + 2]
  sub eax, 3
  shl eax, 7
  lea r14, [rdi + rax + TPpmdEngine.FSEE2Cont]
  lea r14, [r14 + rdx * 4]
  movzx eax, word ptr [r14]
  movzx ecx, byte ptr [r14 + 2]
  mov edx, eax
  shr edx, cl
  sub eax, edx
  mov [r14], ax
  cmp edx, 1
  adc edx, 0
  mov ebx, edx
  jmp @sym2
@dummysee:
  lea r14, [rdi + TPpmdEngine.FDummySEE2]
  mov ebx, 1
  // ---- EncodeSymbol2 + AriEncodeSymbol ----
@sym2:
  movzx ecx, byte ptr [r12]
  movzx eax, byte ptr [rdi + TPpmdEngine.FNumMasked]
  sub ecx, eax
  mov eax, [r12 + 4]
  lea rsi, [r15 + rax - 6]
  movzx edx, byte ptr [rdi + TPpmdEngine.FEscCount]
  xor r13d, r13d
@f1:
  add rsi, 6
  movzx eax, byte ptr [rsi]
  cmp [rdi + rax + TPpmdEngine.FCharMask], dl
  je @f1
  mov [rdi + rax + TPpmdEngine.FCharMask], dl
  cmp eax, r11d
  je @f2found
  movzx eax, byte ptr [rsi + 1]
  add r13d, eax
  cmp ecx, 1
  je @f2esc
  dec ecx
  jmp @f1
@f2esc:
  // SubLow = LoCnt, SubScale = SEE + LoCnt = SubHigh
  add ebx, r13d
  add word ptr [r14], bx
  movzx eax, byte ptr [r12]
  mov [rdi + TPpmdEngine.FNumMasked], al
  mov eax, r9d
  xor edx, edx
  div ebx
  mov ecx, eax
  imul eax, r13d
  add r8d, eax
  sub ebx, r13d
  imul ecx, ebx
  mov r9d, ecx
  jmp @norm
@f2found:
  // SubLow = LoCnt, SubHigh = LoCnt + Freq; después se suman los no enmascarados
  mov rbp, rsi
  movzx eax, byte ptr [rsi + 1]
  add r13d, eax
  add ebx, r13d
  dec ecx
  jz @f2sum
@f2s:
  add rsi, 6
  movzx eax, byte ptr [rsi]
  cmp [rdi + rax + TPpmdEngine.FCharMask], dl
  je @f2s
  movzx eax, byte ptr [rsi + 1]
  add ebx, eax
  dec ecx
  jnz @f2s
@f2sum:
  movzx ecx, byte ptr [rbp + 1]
  mov eax, r9d
  xor edx, edx
  div ebx
  mov edx, r13d
  sub edx, ecx
  imul edx, eax
  add r8d, edx
  imul eax, ecx
  mov r9d, eax
  // See2Update
  movzx ecx, byte ptr [r14 + 2]
  cmp ecx, 7
  jae @su
  dec byte ptr [r14 + 3]
  jnz @su
  shl word ptr [r14], 1
  mov eax, 3
  shl eax, cl
  mov [r14 + 3], al
  inc byte ptr [r14 + 2]
@su:
  mov rax, rbp
  sub rax, r15
  mov [rdi + TPpmdEngine.FFoundState], eax
  add byte ptr [rbp + 1], 4
  add word ptr [r12 + 2], 4
  inc byte ptr [rdi + TPpmdEngine.FEscCount]
  mov eax, [rdi + TPpmdEngine.FInitRL]
  mov [rdi + TPpmdEngine.FRunLength], eax
  xor eax, eax
  cmp byte ptr [rbp + 1], 124
  seta al
  jmp @found
@stop:
  mov dword ptr [rdi + TPpmdEngine.FMinContext], 0
  mov eax, 4
  jmp @done
  // ---- símbolo codificado: lo que en Pascal hace EncodeOne después del paso ----
@found:
  test eax, eax
  jnz @done                              // RESCALE: lo sigue EncodeOne
  mov eax, [rdi + TPpmdEngine.FFoundState]
  mov ecx, [r15 + rax + 2]               // Successor
  prefetcht0 [r15 + rcx]
  cmp dword ptr [rdi + TPpmdEngine.FOrderFall], 0
  jne @um
  cmp ecx, [rdi + TPpmdEngine.FUnitsStart]
  jb @um
  mov [rdi + TPpmdEngine.FMaxContext], ecx
  jmp @next
@um:
  mov [rdi + TPpmdEngine.FLow], r8d
  mov [rdi + TPpmdEngine.FRange], r9d
  lea rcx, [rdi + TPpmdEngine.FEncBuf]
  sub r10, rcx
  mov [rdi + TPpmdEngine.FEncBufLen], r10d
  mov r14d, [rdi + TPpmdEngine.FMinContext]
  call PpmdUmCore
  test eax, eax
  jnz @r_um
  mov r8d, [rdi + TPpmdEngine.FLow]
  mov r9d, [rdi + TPpmdEngine.FRange]
  movsxd r10, dword ptr [rdi + TPpmdEngine.FEncBufLen]
  lea r10, [rdi + r10 + TPpmdEngine.FEncBuf]
  // ClearMask si EscCount dio la vuelta
  cmp byte ptr [rdi + TPpmdEngine.FEscCount], 0
  jne @next
  mov byte ptr [rdi + TPpmdEngine.FEscCount], 1
  inc byte ptr [rdi + TPpmdEngine.FPrintCount]
  lea rax, [rdi + TPpmdEngine.FCharMask]
  xor ecx, ecx
  mov edx, 32
@cm:
  mov [rax], rcx
  add rax, 8
  dec edx
  jnz @cm
@next:
  mov eax, [rdi + TPpmdEngine.FMaxContext]
  mov [rdi + TPpmdEngine.FMinContext], eax
  jmp @sym
@r_um:
  add eax, 5                             // 6: UpdateModel, 7: UpdateModelResume
  jmp @restore
@r_limit:
  xor eax, eax
  jmp @done
@r_flush:
  mov eax, 5
@done:
  mov [rdi + TPpmdEngine.FLow], r8d
  mov [rdi + TPpmdEngine.FRange], r9d
  lea rcx, [rdi + TPpmdEngine.FEncBuf]
  sub r10, rcx
  mov [rdi + TPpmdEngine.FEncBufLen], r10d
@restore:
  mov rcx, rdi
  mov rbx, [rcx + TPpmdEngine.FAsmSv + 0]
  mov rbp, [rcx + TPpmdEngine.FAsmSv + 8]
  mov r12, [rcx + TPpmdEngine.FAsmSv + 16]
  mov r13, [rcx + TPpmdEngine.FAsmSv + 24]
  mov r14, [rcx + TPpmdEngine.FAsmSv + 32]
  mov r15, [rcx + TPpmdEngine.FAsmSv + 40]
  mov rdi, [rcx + TPpmdEngine.FAsmSv + 48]
  mov rsi, [rcx + TPpmdEngine.FAsmSv + 56]
end;
{$asmmode default}
