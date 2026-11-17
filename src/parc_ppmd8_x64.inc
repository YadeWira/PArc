{ parc_ppmd8_x64.inc — PPMd (variante I) en ensamblador x86-64 (credits: LZMA SDK (Igor Pavlov,
  public domain), based on PPMd var.H/var.I (Dmitry Shkarin, public domain)): el paso de un símbolo
  (P8EncodeSymbol / P8DecodeSymbol) y la parte caliente del modelo (P8CreateSuccessors y
  P8UpdateModel). Es lo que FPC compila peor (guarda casi todo en la pila): con esto el codec
  va a la par del C del SDK compilado con gcc.

  Mismo algoritmo, operación por operación, que las versiones en Pascal de parc_ppmd.pas
  (P8EncodeFirst/Bin/Masked, P8DecodeFirst/Bin/Masked, P8CreateSuccessors,
  P8UpdateSuffixFreq + P8UpdateModel), que a su vez son Ppmd8.c/Ppmd8Enc.c/Ppmd8Dec.c del
  LZMA SDK (Igor Pavlov, dominio público): el stream sale bit a bit igual que con
  -dPARC_NOASM (tests/ppmd_asm.sh). Lo raro (Update1/Update1_0/Update2, Rescale, ReduceOrder,
  RestoreModel, AllocUnitsRare, el bucle de normalización) queda en Pascal y se llama desde acá.

  Registros: rbx = p, r12 = p^.Base, r13 = contexto, r14 = estado, r15 = máscara o prob.
  Siempre con tamaño explícito (byte/word/dword ptr): FPC toma el tamaño del campo si no.
  ABI: SysV (Linux) y Win64; las llamadas a Pascal pasan p en rdi/rcx con la pila alineada a
  16 (y en Win64 con los 32 bytes de "shadow space"). }

{$ASMMODE INTEL}

{ Normalización del decodificador: el caso común en línea, el bucle en Pascal }
procedure P8AsmNormDec; assembler; nostackframe;
asm
  // entrada: rbx = p; llamada con "call" desde un punto con la pila alineada a 16
  mov    eax, dword ptr [rbx + TPpmd8.RcLow]
  mov    ecx, dword ptr [rbx + TPpmd8.RcRange]
  lea    edx, [rax + rcx]
  xor    edx, eax
  cmp    edx, 1 shl 24
  jb     @slow
  cmp    ecx, 1 shl 15
  jb     @slow
  ret
@slow:
{$IFDEF WIN64}
  sub    rsp, 40
  mov    rcx, rbx
  call   P8RcNormDecSlow
  add    rsp, 40
{$ELSE}
  sub    rsp, 8
  mov    rdi, rbx
  call   P8RcNormDecSlow
  add    rsp, 8
{$ENDIF}
end;

function P8DecodeSymbol(p: PPpmd8): Integer; assembler; nostackframe;
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
  sub    rsp, 40
  mov    rbx, rcx
{$ELSE}
  sub    rsp, 8
  mov    rbx, rdi
{$ENDIF}
  mov    r12, qword ptr [rbx + TPpmd8.Base]
  mov    r13, qword ptr [rbx + TPpmd8.MinContext]
  movzx  eax, byte ptr [r13]                      // NumStats
  test   eax, eax
  jz     @bin

  // ---------------- primer contexto (P8DecodeFirst) ----------------
  mov    r14d, dword ptr [r13 + 4]                // s := Stats
  add    r14, r12
  movzx  ecx, word ptr [r13 + 2]                  // summFreq
  mov    esi, dword ptr [rbx + TPpmd8.RcRange]
  cmp    ecx, esi
  cmova  ecx, esi                                 // summFreq := min(summFreq, Range)
  mov    eax, esi
  xor    edx, edx
  div    ecx
  mov    dword ptr [rbx + TPpmd8.RcRange], eax      // Range := Range div summFreq
  mov    r8d, eax
  mov    eax, dword ptr [rbx + TPpmd8.RcCode]
  xor    edx, edx
  div    r8d                                      // count := Code div Range
  mov    ebp, eax                                 // hiCnt := count
  movzx  edx, byte ptr [r14 + 1]
  sub    eax, edx
  js     @first0
  mov    dword ptr [rbx + TPpmd8.PrevSuccess], 0
  movzx  r9d, byte ptr [r13]                      // i := NumStats
@loop1:
  add    r14, 6
  movzx  edx, byte ptr [r14 + 1]
  sub    eax, edx
  js     @firstN
  dec    r9d
  jnz    @loop1
  // escape del primer contexto
  cmp    ebp, ecx
  jae    @error                                   // hiCnt >= summFreq
  sub    ebp, eax                                 // hiCnt := hiCnt - count
  mov    eax, dword ptr [rbx + TPpmd8.RcRange]
  mov    edx, ecx
  sub    edx, ebp                                 // size := summFreq - hiCnt
  imul   ebp, eax                                 // start := hiCnt * Range
  add    dword ptr [rbx + TPpmd8.RcLow], ebp
  sub    dword ptr [rbx + TPpmd8.RcCode], ebp
  imul   eax, edx
  mov    dword ptr [rbx + TPpmd8.RcRange], eax
  // máscara: todo $FF y los símbolos de Stats en 0 (MaskStats)
  lea    r15, [rbx + TPpmd8.CharMask]
  pcmpeqb xmm0, xmm0
  movdqu [r15], xmm0
  movdqu [r15 + 16], xmm0
  movdqu [r15 + 32], xmm0
  movdqu [r15 + 48], xmm0
  movdqu [r15 + 64], xmm0
  movdqu [r15 + 80], xmm0
  movdqu [r15 + 96], xmm0
  movdqu [r15 + 112], xmm0
  movdqu [r15 + 128], xmm0
  movdqu [r15 + 144], xmm0
  movdqu [r15 + 160], xmm0
  movdqu [r15 + 176], xmm0
  movdqu [r15 + 192], xmm0
  movdqu [r15 + 208], xmm0
  movdqu [r15 + 224], xmm0
  movdqu [r15 + 240], xmm0
  movzx  eax, byte ptr [r14]
  mov    byte ptr [r15 + rax], 0                  // mask[s^.Symbol] := 0
  mov    r8d, dword ptr [r13 + 4]
  add    r8, r12                                  // s2 := Stats
@zm1:
  movzx  eax, byte ptr [r8]
  movzx  edx, byte ptr [r8 + 6]
  add    r8, 12
  mov    byte ptr [r15 + rax], 0
  mov    byte ptr [r15 + rdx], 0
  cmp    r8, r14
  jb     @zm1
  jmp    @masked

@first0:                                          // el primer símbolo
  mov    eax, dword ptr [rbx + TPpmd8.RcRange]
  imul   eax, edx
  mov    dword ptr [rbx + TPpmd8.RcRange], eax      // RcDecode(0, Freq)
  call   P8AsmNormDec
  mov    qword ptr [rbx + TPpmd8.FoundState], r14
  movzx  ebp, byte ptr [r14]
{$IFDEF WIN64}
  mov    rcx, rbx
{$ELSE}
  mov    rdi, rbx
{$ENDIF}
  call   P8Update1_0
  mov    eax, ebp
  jmp    @ret

@firstN:                                          // otro símbolo del primer contexto
  mov    ecx, ebp
  sub    ecx, eax
  sub    ecx, edx                                 // start := (hiCnt - count) - Freq
  mov    eax, dword ptr [rbx + TPpmd8.RcRange]
  imul   ecx, eax
  add    dword ptr [rbx + TPpmd8.RcLow], ecx
  sub    dword ptr [rbx + TPpmd8.RcCode], ecx
  imul   eax, edx
  mov    dword ptr [rbx + TPpmd8.RcRange], eax
  call   P8AsmNormDec
  mov    qword ptr [rbx + TPpmd8.FoundState], r14
  movzx  ebp, byte ptr [r14]
{$IFDEF WIN64}
  mov    rcx, rbx
{$ELSE}
  mov    rdi, rbx
{$ENDIF}
  call   P8Update1
  mov    eax, ebp
  jmp    @ret

  // ---------------- contexto binario (P8DecodeBin) ----------------
@bin:
  movzx  eax, byte ptr [r13 + 3]                  // OneState^.Freq
  movzx  eax, byte ptr [rbx + TPpmd8.NS2Indx + rax - 1]
  shl    eax, 6
  add    eax, dword ptr [rbx + TPpmd8.PrevSuccess]
  mov    ecx, dword ptr [rbx + TPpmd8.RunLength]
  shr    ecx, 26
  and    ecx, 20h
  add    eax, ecx
  mov    ecx, dword ptr [r13 + 8]                 // Suffix
  movzx  ecx, byte ptr [r12 + rcx]                // NumStats del sufijo
  movzx  ecx, byte ptr [rbx + TPpmd8.NS2BSIndx + rcx]
  add    eax, ecx
  movzx  ecx, byte ptr [r13 + 1]                  // Flags
  add    eax, ecx
  lea    r15, [rbx + TPpmd8.BinSumm + rax * 2]    // prob
  movzx  ecx, word ptr [r15]                      // pr
  mov    esi, dword ptr [rbx + TPpmd8.RcRange]
  mov    edx, esi
  shr    edx, 14
  imul   edx, ecx                                 // size0 := (Range shr 14) * pr
  lea    eax, [rcx + 32]
  shr    eax, 7
  sub    ecx, eax                                 // pr := pr - GET_MEAN(pr)
  cmp    dword ptr [rbx + TPpmd8.RcCode], edx
  jae    @binEsc
  add    ecx, 128
  mov    word ptr [r15], cx
  mov    dword ptr [rbx + TPpmd8.RcRange], edx
  call   P8AsmNormDec
  lea    r14, [r13 + 2]                           // s := OneState
  movzx  ebp, byte ptr [r14]                      // símbolo
  mov    qword ptr [rbx + TPpmd8.FoundState], r14
  mov    dword ptr [rbx + TPpmd8.PrevSuccess], 1
  add    dword ptr [rbx + TPpmd8.RunLength], 1
  movzx  eax, byte ptr [r14 + 1]
  cmp    eax, 196
  adc    eax, 0
  mov    byte ptr [r14 + 1], al                   // Freq := Freq + Ord(Freq < 196)
  mov    ecx, dword ptr [r14 + 2]                 // Successor
  add    rcx, r12
  cmp    dword ptr [rbx + TPpmd8.OrderFall], 0
  jne    @binUM
  cmp    rcx, qword ptr [rbx + TPpmd8.UnitsStart]
  jb     @binUM
  mov    qword ptr [rbx + TPpmd8.MinContext], rcx
  mov    qword ptr [rbx + TPpmd8.MaxContext], rcx
  mov    eax, ebp
  jmp    @ret
@binUM:
{$IFDEF WIN64}
  mov    rcx, rbx
{$ELSE}
  mov    rdi, rbx
{$ENDIF}
  call   P8UpdateModel
  mov    eax, ebp
  jmp    @ret

@binEsc:
  mov    word ptr [r15], cx
  shr    ecx, 10
  movzx  ecx, byte ptr [rbx + TPpmd8.ExpEscape + rcx]
  mov    dword ptr [rbx + TPpmd8.InitEsc], ecx
  add    dword ptr [rbx + TPpmd8.RcLow], edx
  sub    dword ptr [rbx + TPpmd8.RcCode], edx
  and    esi, 0FFFFC000h
  sub    esi, edx
  mov    dword ptr [rbx + TPpmd8.RcRange], esi
  lea    r15, [rbx + TPpmd8.CharMask]
  pcmpeqb xmm0, xmm0
  movdqu [r15], xmm0
  movdqu [r15 + 16], xmm0
  movdqu [r15 + 32], xmm0
  movdqu [r15 + 48], xmm0
  movdqu [r15 + 64], xmm0
  movdqu [r15 + 80], xmm0
  movdqu [r15 + 96], xmm0
  movdqu [r15 + 112], xmm0
  movdqu [r15 + 128], xmm0
  movdqu [r15 + 144], xmm0
  movdqu [r15 + 160], xmm0
  movdqu [r15 + 176], xmm0
  movdqu [r15 + 192], xmm0
  movdqu [r15 + 208], xmm0
  movdqu [r15 + 224], xmm0
  movdqu [r15 + 240], xmm0
  movzx  eax, byte ptr [r13 + 2]
  mov    byte ptr [r15 + rax], 0
  mov    dword ptr [rbx + TPpmd8.PrevSuccess], 0

  // ---------------- sufijos con máscara (P8DecodeMasked) ----------------
@masked:
  call   P8AsmNormDec
  mov    r13, qword ptr [rbx + TPpmd8.MinContext]
  movzx  r8d, byte ptr [r13]                      // numMasked
@suf:
  add    dword ptr [rbx + TPpmd8.OrderFall], 1
  mov    eax, dword ptr [r13 + 8]
  test   eax, eax
  jz     @end
  lea    r13, [r12 + rax]
  movzx  ecx, byte ptr [r13]
  cmp    ecx, r8d
  je     @suf
  mov    r14d, dword ptr [r13 + 4]
  add    r14, r12                                 // s := Stats
  lea    r9d, [rcx + 1]
  mov    eax, r9d
  shr    r9d, 1                                   // num2
  and    eax, 1                                   // num
  movzx  edx, byte ptr [r14]
  movzx  ebp, byte ptr [r15 + rdx]
  movzx  edx, byte ptr [r14 + 1]
  and    ebp, edx
  mov    edx, eax
  neg    edx
  and    ebp, edx                                 // hiCnt
  lea    rax, [rax + rax * 2]
  lea    r14, [r14 + rax * 2]                     // s := s + num
  mov    qword ptr [rbx + TPpmd8.MinContext], r13
@hl:
  movzx  eax, byte ptr [r14]
  movzx  edx, byte ptr [r14 + 6]
  add    r14, 12
  movzx  eax, byte ptr [r15 + rax]
  movzx  r10d, byte ptr [r14 - 11]
  and    eax, r10d
  add    ebp, eax
  movzx  edx, byte ptr [r15 + rdx]
  movzx  r10d, byte ptr [r14 - 5]
  and    edx, r10d
  add    ebp, edx
  dec    r9d
  jnz    @hl

  // see := MakeEscFreq(p, numMasked, escFreq)   (ecx = NumStats, r8d = numMasked)
  cmp    ecx, 0FFh
  je     @dummySee
  movzx  eax, byte ptr [rbx + TPpmd8.NS2Indx + rcx + 2]
  sub    eax, 3
  shl    eax, 5
  movzx  edx, word ptr [r13 + 2]                  // SummFreq
  lea    esi, [rcx + 1]
  imul   esi, esi, 11
  cmp    edx, esi
  seta   dl
  movzx  edx, dl
  add    eax, edx                                 // + (SummFreq > 11 * (NumStats + 1))
  mov    esi, dword ptr [r13 + 8]
  movzx  esi, byte ptr [r12 + rsi]
  add    esi, r8d
  lea    edi, [rcx + rcx]
  xor    edx, edx
  cmp    edi, esi
  setb   dl
  lea    eax, [rax + rdx * 2]                     // + 2 * (2 * NumStats < Suffix^.NumStats + numMasked)
  movzx  edx, byte ptr [r13 + 1]
  add    eax, edx                                 // + Flags
  lea    r10, [rbx + TPpmd8.See + rax * 4]        // see
  movzx  eax, word ptr [r10]                      // summ
  movzx  ecx, byte ptr [r10 + 2]                  // shift
  mov    edx, eax
  shr    edx, cl                                  // r := summ shr Shift
  sub    eax, edx
  mov    word ptr [r10], ax
  cmp    edx, 1
  adc    edx, 0                                   // escFreq := r + Ord(r = 0)
  jmp    @haveSee
@dummySee:
  lea    r10, [rbx + TPpmd8.DummySee]
  mov    edx, 1
@haveSee:
  add    edx, ebp                                 // freqSum := escFreq + hiCnt
  mov    r11d, edx                                // freqSum (para see)
  mov    ecx, dword ptr [rbx + TPpmd8.RcRange]
  cmp    edx, ecx
  cmova  edx, ecx                                 // freqSum2 := min(freqSum, Range)
  mov    esi, edx
  mov    eax, ecx
  xor    edx, edx
  div    esi
  mov    dword ptr [rbx + TPpmd8.RcRange], eax
  mov    ecx, eax
  mov    eax, dword ptr [rbx + TPpmd8.RcCode]
  xor    edx, edx
  div    ecx                                      // count := Code div Range
  cmp    eax, ebp
  jae    @mEsc
  // símbolo en este contexto
  mov    r14d, dword ptr [r13 + 4]
  add    r14, r12
  mov    ebp, eax                                 // hiCnt := count
@find:
  movzx  edx, byte ptr [r14]
  movzx  edx, byte ptr [r15 + rdx]
  movzx  ecx, byte ptr [r14 + 1]
  and    edx, ecx
  add    r14, 6
  sub    eax, edx
  jns    @find
  sub    r14, 6
  movzx  edx, byte ptr [r14 + 1]                  // Freq
  mov    ecx, ebp
  sub    ecx, eax
  sub    ecx, edx                                 // start := (hiCnt - count) - Freq
  mov    eax, dword ptr [rbx + TPpmd8.RcRange]
  imul   ecx, eax
  add    dword ptr [rbx + TPpmd8.RcLow], ecx
  sub    dword ptr [rbx + TPpmd8.RcCode], ecx
  imul   eax, edx
  mov    dword ptr [rbx + TPpmd8.RcRange], eax
  // SeeUpdate(see)
  movzx  ecx, byte ptr [r10 + 2]
  cmp    ecx, 7
  jae    @seeDone
  sub    byte ptr [r10 + 3], 1
  jnz    @seeDone
  shl    word ptr [r10], 1
  mov    eax, 3
  shl    eax, cl
  mov    byte ptr [r10 + 3], al
  add    byte ptr [r10 + 2], 1
@seeDone:
  call   P8AsmNormDec
  mov    qword ptr [rbx + TPpmd8.FoundState], r14
  movzx  ebp, byte ptr [r14]
{$IFDEF WIN64}
  mov    rcx, rbx
{$ELSE}
  mov    rdi, rbx
{$ENDIF}
  call   P8Update2
  mov    eax, ebp
  jmp    @ret

@mEsc:
  cmp    eax, esi
  jae    @error                                   // count >= freqSum2
  sub    esi, ebp                                 // size := freqSum2 - hiCnt
  mov    eax, dword ptr [rbx + TPpmd8.RcRange]
  imul   ebp, eax                                 // start := hiCnt * Range
  add    dword ptr [rbx + TPpmd8.RcLow], ebp
  sub    dword ptr [rbx + TPpmd8.RcCode], ebp
  imul   eax, esi
  mov    dword ptr [rbx + TPpmd8.RcRange], eax
  add    word ptr [r10], r11w                     // see^.Summ += freqSum
  mov    r14d, dword ptr [r13 + 4]
  add    r14, r12
  movzx  ecx, byte ptr [r13]
  lea    rcx, [rcx + rcx * 2]
  lea    r8, [r14 + rcx * 2 + 6]                  // s2 := s + NumStats + 1
@mz:
  movzx  eax, byte ptr [r14]
  mov    byte ptr [r15 + rax], 0
  add    r14, 6
  cmp    r14, r8
  jne    @mz
  jmp    @masked

@end:
  mov    eax, -1                                  // PPMD_SYM_END
  jmp    @ret
@error:
  mov    eax, -2                                  // PPMD_SYM_ERROR
@ret:
{$IFDEF WIN64}
  add    rsp, 40
  pop    rsi
  pop    rdi
{$ELSE}
  add    rsp, 8
{$ENDIF}
  pop    r15
  pop    r14
  pop    r13
  pop    r12
  pop    rbp
  pop    rbx
end;

{ Normalización del codificador: el caso común en línea, el bucle en Pascal }
procedure P8AsmNormEnc; assembler; nostackframe;
asm
  mov    eax, dword ptr [rbx + TPpmd8.RcLow]
  mov    ecx, dword ptr [rbx + TPpmd8.RcRange]
  lea    edx, [rax + rcx]
  xor    edx, eax
  cmp    edx, 1 shl 24
  jb     @slow
  cmp    ecx, 1 shl 15
  jb     @slow
  ret
@slow:
{$IFDEF WIN64}
  sub    rsp, 40
  mov    rcx, rbx
  call   P8RcNormEncSlow
  add    rsp, 40
{$ELSE}
  sub    rsp, 8
  mov    rdi, rbx
  call   P8RcNormEncSlow
  add    rsp, 8
{$ENDIF}
end;

{ symbol = -1: marca de fin }
procedure P8EncodeSymbol(p: PPpmd8; symbol: Integer); assembler; nostackframe;
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
  sub    rsp, 40
  mov    rbx, rcx
  mov    ebp, edx
{$ELSE}
  sub    rsp, 8
  mov    rbx, rdi
  mov    ebp, esi
{$ENDIF}
  mov    r12, qword ptr [rbx + TPpmd8.Base]
  mov    r13, qword ptr [rbx + TPpmd8.MinContext]
  movzx  eax, byte ptr [r13]                      // NumStats
  test   eax, eax
  jz     @bin

  // ---------------- primer contexto (P8EncodeFirst) ----------------
  mov    r14d, dword ptr [r13 + 4]
  add    r14, r12                                 // s := Stats
  movzx  edi, word ptr [r13 + 2]                  // summFreq
  mov    esi, dword ptr [rbx + TPpmd8.RcRange]
  cmp    edi, esi
  cmova  edi, esi
  movzx  eax, byte ptr [r14]
  cmp    eax, ebp
  jne    @f1
  // el primer símbolo: RcEncode(0, Freq, summFreq)
  mov    eax, esi
  xor    edx, edx
  div    edi
  movzx  edx, byte ptr [r14 + 1]
  imul   eax, edx
  mov    dword ptr [rbx + TPpmd8.RcRange], eax
  call   P8AsmNormEnc
  mov    qword ptr [rbx + TPpmd8.FoundState], r14
{$IFDEF WIN64}
  mov    rcx, rbx
{$ELSE}
  mov    rdi, rbx
{$ENDIF}
  call   P8Update1_0
  jmp    @ret
@f1:
  mov    dword ptr [rbx + TPpmd8.PrevSuccess], 0
  movzx  ecx, byte ptr [r14 + 1]                  // sum
  movzx  r9d, byte ptr [r13]                      // i := NumStats
@loop1:
  add    r14, 6
  movzx  eax, byte ptr [r14]
  cmp    eax, ebp
  je     @firstN
  movzx  eax, byte ptr [r14 + 1]
  add    ecx, eax
  dec    r9d
  jnz    @loop1
  // escape: RcEncode(sum, summFreq - sum, summFreq)
  mov    eax, esi
  xor    edx, edx
  div    edi                                      // r := Range div summFreq
  sub    edi, ecx                                 // size
  mov    edx, ecx
  imul   edx, eax
  add    dword ptr [rbx + TPpmd8.RcLow], edx
  imul   eax, edi
  mov    dword ptr [rbx + TPpmd8.RcRange], eax
  lea    r15, [rbx + TPpmd8.CharMask]
  pcmpeqb xmm0, xmm0
  movdqu [r15], xmm0
  movdqu [r15 + 16], xmm0
  movdqu [r15 + 32], xmm0
  movdqu [r15 + 48], xmm0
  movdqu [r15 + 64], xmm0
  movdqu [r15 + 80], xmm0
  movdqu [r15 + 96], xmm0
  movdqu [r15 + 112], xmm0
  movdqu [r15 + 128], xmm0
  movdqu [r15 + 144], xmm0
  movdqu [r15 + 160], xmm0
  movdqu [r15 + 176], xmm0
  movdqu [r15 + 192], xmm0
  movdqu [r15 + 208], xmm0
  movdqu [r15 + 224], xmm0
  movdqu [r15 + 240], xmm0
  movzx  eax, byte ptr [r14]
  mov    byte ptr [r15 + rax], 0
  mov    r8d, dword ptr [r13 + 4]
  add    r8, r12
@zm1:
  movzx  eax, byte ptr [r8]
  movzx  edx, byte ptr [r8 + 6]
  add    r8, 12
  mov    byte ptr [r15 + rax], 0
  mov    byte ptr [r15 + rdx], 0
  cmp    r8, r14
  jb     @zm1
  jmp    @masked

@firstN:                                          // RcEncode(sum, Freq, summFreq)
  mov    eax, esi
  xor    edx, edx
  div    edi
  mov    edx, ecx
  imul   edx, eax
  add    dword ptr [rbx + TPpmd8.RcLow], edx
  movzx  edx, byte ptr [r14 + 1]
  imul   eax, edx
  mov    dword ptr [rbx + TPpmd8.RcRange], eax
  call   P8AsmNormEnc
  mov    qword ptr [rbx + TPpmd8.FoundState], r14
{$IFDEF WIN64}
  mov    rcx, rbx
{$ELSE}
  mov    rdi, rbx
{$ENDIF}
  call   P8Update1
  jmp    @ret

  // ---------------- contexto binario (P8EncodeBin) ----------------
@bin:
  movzx  eax, byte ptr [r13 + 3]
  movzx  eax, byte ptr [rbx + TPpmd8.NS2Indx + rax - 1]
  shl    eax, 6
  add    eax, dword ptr [rbx + TPpmd8.PrevSuccess]
  mov    ecx, dword ptr [rbx + TPpmd8.RunLength]
  shr    ecx, 26
  and    ecx, 20h
  add    eax, ecx
  mov    ecx, dword ptr [r13 + 8]
  movzx  ecx, byte ptr [r12 + rcx]
  movzx  ecx, byte ptr [rbx + TPpmd8.NS2BSIndx + rcx]
  add    eax, ecx
  movzx  ecx, byte ptr [r13 + 1]
  add    eax, ecx
  lea    r15, [rbx + TPpmd8.BinSumm + rax * 2]    // prob
  movzx  ecx, word ptr [r15]                      // pr
  mov    esi, dword ptr [rbx + TPpmd8.RcRange]
  mov    edx, esi
  shr    edx, 14
  imul   edx, ecx                                 // bound
  lea    eax, [rcx + 32]
  shr    eax, 7
  sub    ecx, eax
  lea    r14, [r13 + 2]                           // s := OneState
  movzx  eax, byte ptr [r14]
  cmp    eax, ebp
  jne    @binEsc
  add    ecx, 128
  mov    word ptr [r15], cx
  mov    dword ptr [rbx + TPpmd8.RcRange], edx
  call   P8AsmNormEnc
  mov    qword ptr [rbx + TPpmd8.FoundState], r14
  mov    dword ptr [rbx + TPpmd8.PrevSuccess], 1
  add    dword ptr [rbx + TPpmd8.RunLength], 1
  movzx  eax, byte ptr [r14 + 1]
  cmp    eax, 196
  adc    eax, 0
  mov    byte ptr [r14 + 1], al
  mov    ecx, dword ptr [r14 + 2]
  add    rcx, r12
  cmp    dword ptr [rbx + TPpmd8.OrderFall], 0
  jne    @binUM
  cmp    rcx, qword ptr [rbx + TPpmd8.UnitsStart]
  jb     @binUM
  mov    qword ptr [rbx + TPpmd8.MinContext], rcx
  mov    qword ptr [rbx + TPpmd8.MaxContext], rcx
  jmp    @ret
@binUM:
{$IFDEF WIN64}
  mov    rcx, rbx
{$ELSE}
  mov    rdi, rbx
{$ENDIF}
  call   P8UpdateModel
  jmp    @ret

@binEsc:
  mov    word ptr [r15], cx
  shr    ecx, 10
  movzx  ecx, byte ptr [rbx + TPpmd8.ExpEscape + rcx]
  mov    dword ptr [rbx + TPpmd8.InitEsc], ecx
  add    dword ptr [rbx + TPpmd8.RcLow], edx
  and    esi, 0FFFFC000h
  sub    esi, edx
  mov    dword ptr [rbx + TPpmd8.RcRange], esi
  lea    r15, [rbx + TPpmd8.CharMask]
  pcmpeqb xmm0, xmm0
  movdqu [r15], xmm0
  movdqu [r15 + 16], xmm0
  movdqu [r15 + 32], xmm0
  movdqu [r15 + 48], xmm0
  movdqu [r15 + 64], xmm0
  movdqu [r15 + 80], xmm0
  movdqu [r15 + 96], xmm0
  movdqu [r15 + 112], xmm0
  movdqu [r15 + 128], xmm0
  movdqu [r15 + 144], xmm0
  movdqu [r15 + 160], xmm0
  movdqu [r15 + 176], xmm0
  movdqu [r15 + 192], xmm0
  movdqu [r15 + 208], xmm0
  movdqu [r15 + 224], xmm0
  movdqu [r15 + 240], xmm0
  movzx  eax, byte ptr [r14]
  mov    byte ptr [r15 + rax], 0
  mov    dword ptr [rbx + TPpmd8.PrevSuccess], 0

  // ---------------- sufijos con máscara (P8EncodeMasked) ----------------
@masked:
  call   P8AsmNormEnc
  mov    r13, qword ptr [rbx + TPpmd8.MinContext]
  movzx  r8d, byte ptr [r13]                      // numMasked
@suf:
  add    dword ptr [rbx + TPpmd8.OrderFall], 1
  mov    eax, dword ptr [r13 + 8]
  test   eax, eax
  jz     @ret                                     // marca de fin (symbol = -1)
  lea    r13, [r12 + rax]
  movzx  ecx, byte ptr [r13]
  cmp    ecx, r8d
  je     @suf
  mov    qword ptr [rbx + TPpmd8.MinContext], r13

  // see := MakeEscFreq(p, numMasked, escFreq)   (ecx = NumStats, r8d = numMasked)
  cmp    ecx, 0FFh
  je     @dummySee
  movzx  eax, byte ptr [rbx + TPpmd8.NS2Indx + rcx + 2]
  sub    eax, 3
  shl    eax, 5
  movzx  edx, word ptr [r13 + 2]
  lea    esi, [rcx + 1]
  imul   esi, esi, 11
  cmp    edx, esi
  seta   dl
  movzx  edx, dl
  add    eax, edx
  mov    esi, dword ptr [r13 + 8]
  movzx  esi, byte ptr [r12 + rsi]
  add    esi, r8d
  lea    edi, [rcx + rcx]
  xor    edx, edx
  cmp    edi, esi
  setb   dl
  lea    eax, [rax + rdx * 2]
  movzx  edx, byte ptr [r13 + 1]
  add    eax, edx
  lea    r10, [rbx + TPpmd8.See + rax * 4]        // see
  movzx  eax, word ptr [r10]
  movzx  ecx, byte ptr [r10 + 2]
  mov    r11d, eax
  shr    r11d, cl
  sub    eax, r11d
  mov    word ptr [r10], ax
  cmp    r11d, 1
  adc    r11d, 0                                  // escFreq
  jmp    @haveSee
@dummySee:
  lea    r10, [rbx + TPpmd8.DummySee]
  mov    r11d, 1
@haveSee:
  mov    r14d, dword ptr [r13 + 4]
  add    r14, r12                                 // s := Stats
  xor    ecx, ecx                                 // sum := 0
  movzx  esi, byte ptr [r13]
  inc    esi                                      // i := NumStats + 1
@search:
  movzx  eax, byte ptr [r14]
  cmp    eax, ebp
  je     @mFound
  movzx  eax, byte ptr [r15 + rax]
  movzx  edx, byte ptr [r14 + 1]
  and    eax, edx
  add    ecx, eax
  add    r14, 6
  dec    esi
  jnz    @search

  // escape: total := sum + escFreq
  lea    eax, [rcx + r11]
  add    word ptr [r10], ax                       // see^.Summ += total
  mov    edx, dword ptr [rbx + TPpmd8.RcRange]
  cmp    eax, edx
  cmova  eax, edx                                 // total := min(total, Range)
  mov    edi, eax
  mov    eax, edx
  xor    edx, edx
  div    edi                                      // r := Range div total
  sub    edi, ecx                                 // size := total - sum
  mov    edx, ecx
  imul   edx, eax
  add    dword ptr [rbx + TPpmd8.RcLow], edx
  imul   eax, edi
  mov    dword ptr [rbx + TPpmd8.RcRange], eax
  sub    r14, 6                                   // último símbolo
  movzx  eax, byte ptr [r14]
  mov    byte ptr [r15 + rax], 0
  mov    r8d, dword ptr [r13 + 4]
  add    r8, r12
@zm2:
  movzx  eax, byte ptr [r8]
  movzx  edx, byte ptr [r8 + 6]
  add    r8, 12
  mov    byte ptr [r15 + rax], 0
  mov    byte ptr [r15 + rdx], 0
  cmp    r8, r14
  jb     @zm2
  jmp    @masked

@mFound:
  mov    r9d, ecx                                 // low := sum
  movzx  edi, byte ptr [r14 + 1]                  // freq
  // SeeUpdate(see)
  movzx  ecx, byte ptr [r10 + 2]
  cmp    ecx, 7
  jae    @seeDone
  sub    byte ptr [r10 + 3], 1
  jnz    @seeDone
  shl    word ptr [r10], 1
  mov    eax, 3
  shl    eax, cl
  mov    byte ptr [r10 + 3], al
  add    byte ptr [r10 + 2], 1
@seeDone:
  mov    qword ptr [rbx + TPpmd8.FoundState], r14
  lea    ecx, [r9 + r11]                          // sum := low + escFreq
  mov    eax, esi
  shr    esi, 1                                   // num2
  and    eax, 1                                   // i and 1
  mov    edx, eax
  neg    edx
  and    edx, edi
  add    ecx, edx                                 // sum += freq and (0 - i)
  test   esi, esi
  jz     @sumDone
  lea    rax, [rax + rax * 2]
  lea    r14, [r14 + rax * 2]
@sl:
  movzx  eax, byte ptr [r14]
  movzx  edx, byte ptr [r14 + 6]
  add    r14, 12
  movzx  eax, byte ptr [r15 + rax]
  movzx  r8d, byte ptr [r14 - 11]
  and    eax, r8d
  add    ecx, eax
  movzx  edx, byte ptr [r15 + rdx]
  movzx  r8d, byte ptr [r14 - 5]
  and    edx, r8d
  add    ecx, edx
  dec    esi
  jnz    @sl
@sumDone:
  mov    edx, dword ptr [rbx + TPpmd8.RcRange]
  cmp    ecx, edx
  cmova  ecx, edx                                 // sum := min(sum, Range)
  mov    eax, edx
  xor    edx, edx
  div    ecx                                      // r := Range div sum
  mov    edx, r9d
  imul   edx, eax
  add    dword ptr [rbx + TPpmd8.RcLow], edx      // Low += low * r
  imul   eax, edi
  mov    dword ptr [rbx + TPpmd8.RcRange], eax    // Range := r * freq
  call   P8AsmNormEnc
{$IFDEF WIN64}
  mov    rcx, rbx
{$ELSE}
  mov    rdi, rbx
{$ENDIF}
  call   P8Update2

@ret:
{$IFDEF WIN64}
  add    rsp, 40
  pop    rsi
  pop    rdi
{$ELSE}
  add    rsp, 8
{$ENDIF}
  pop    r15
  pop    r14
  pop    r13
  pop    r12
  pop    rbp
  pop    rbx
end;

{ ------------------------------------------------------------------------------------------
  Modelo: CreateSuccessors y UpdateModel (los dos tercios del tiempo que no son el range
  coder). Mismo orden de operaciones que P8CreateSuccessors / P8UpdateSuffixFreq /
  P8UpdateModel en Pascal; lo raro (AllocUnitsRare, ReduceOrder, RestoreModel) se llama en
  Pascal. }

const
{$IFDEF WIN64}
  CS_PS = 32;     // ps[] después del "shadow space"
  UM_L  = 32;     // variables locales de UpdateModel
{$ELSE}
  CS_PS = 0;
  UM_L  = 0;
{$ENDIF}

function P8CreateSuccessors(p: PPpmd8; skip: Boolean; s1: PState; c: PCtx8): PCtx8; assembler; nostackframe;
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
  sub    rsp, 2088
  mov    rbx, rcx
  movzx  eax, dl
  mov    r14, r8
  mov    r13, r9
{$ELSE}
  sub    rsp, 2056
  mov    rbx, rdi
  movzx  eax, sil
  mov    r14, rdx
  mov    r13, rcx
{$ENDIF}
  mov    r12, qword ptr [rbx + TPpmd8.Base]
  mov    rdx, qword ptr [rbx + TPpmd8.FoundState]
  mov    r15d, dword ptr [rdx + 2]                // upBranch := Successor(FoundState)
  xor    ebp, ebp                                 // numPs := 0
  test   eax, eax
  jnz    @walk
  mov    qword ptr [rsp + CS_PS], rdx             // ps[0] := FoundState
  mov    ebp, 1
@walk:
  mov    eax, dword ptr [r13 + 8]                 // c^.Suffix
  test   eax, eax
  jz     @create
  lea    r13, [r12 + rax]
  test   r14, r14
  jz     @noS1
  mov    r8, r14                                  // s := s1; s1 := nil
  xor    r14d, r14d
  jmp    @haveS
@noS1:
  movzx  eax, byte ptr [r13]
  test   eax, eax
  jz     @one
  mov    rdx, qword ptr [rbx + TPpmd8.FoundState]
  movzx  eax, byte ptr [rdx]                      // sym
  mov    r8d, dword ptr [r13 + 4]
  add    r8, r12                                  // s := Stats
  cmp    byte ptr [r8], al
  je     @fnd
@lp:
  add    r8, 6
  cmp    byte ptr [r8], al
  jne    @lp
@fnd:
  movzx  eax, byte ptr [r8 + 1]
  cmp    eax, MAX_FREQ - 9
  jae    @haveS
  add    byte ptr [r8 + 1], 1
  add    word ptr [r13 + 2], 1
  jmp    @haveS
@one:
  lea    r8, [r13 + 2]                            // s := OneState
  mov    eax, dword ptr [r13 + 8]
  movzx  eax, byte ptr [r12 + rax]                // NumStats del sufijo
  test   eax, eax
  jnz    @haveS
  movzx  eax, byte ptr [r8 + 1]
  cmp    eax, 24
  adc    byte ptr [r8 + 1], 0                     // Freq += Ord(Freq < 24)
@haveS:
  mov    eax, dword ptr [r8 + 2]                  // successor
  cmp    eax, r15d
  je     @push
  lea    r13, [r12 + rax]                         // c := CTX(successor)
  test   ebp, ebp
  jnz    @create
  mov    rax, r13
  jmp    @ret
@push:
  mov    qword ptr [rsp + CS_PS + rbp * 8], r8
  inc    ebp
  jmp    @walk

@create:
  mov    eax, r15d
  movzx  r14d, byte ptr [r12 + rax]               // newSym := texto[upBranch]
  inc    r15d                                     // upBranch + 1
  mov    rdx, qword ptr [rbx + TPpmd8.FoundState]
  movzx  r10d, byte ptr [rdx]
  add    r10d, 0C0h
  shr    r10d, 4
  and    r10d, 16                                 // HiBits4(FoundState^.Symbol)
  lea    eax, [r14 + 0C0h]
  shr    eax, 5
  and    eax, 8
  add    r10d, eax                                // flags
  movzx  eax, byte ptr [r13]
  test   eax, eax
  jnz    @multi
  movzx  edx, byte ptr [r13 + 3]                  // newFreq := OneState^.Freq
  jmp    @nf
@multi:
  mov    r8d, dword ptr [r13 + 4]
  add    r8, r12
  cmp    byte ptr [r8], r14b
  je     @f2
@lp2:
  add    r8, 6
  cmp    byte ptr [r8], r14b
  jne    @lp2
@f2:
  movzx  ecx, byte ptr [r8 + 1]
  dec    ecx                                      // cf := Freq - 1
  movzx  r9d, word ptr [r13 + 2]
  sub    r9d, eax
  sub    r9d, ecx                                 // s0 := SummFreq - NumStats - cf
  lea    edx, [rcx + rcx]
  cmp    edx, r9d
  ja     @divide
  lea    edx, [rcx + rcx * 4]
  xor    eax, eax
  cmp    edx, r9d
  seta   al
  lea    edx, [rax + 1]                           // 1 + Ord(5 * cf > s0)
  jmp    @nf
@divide:
  lea    eax, [rcx + r9 * 2 - 3]
  xor    edx, edx
  div    r9d
  lea    edx, [rax + 1]                           // 1 + (cf + 2 * s0 - 3) div s0
@nf:
  // cabecera del contexto nuevo: NumStats 0, Flags, Symbol, Freq
  and    edx, 0FFh
  shl    edx, 24
  shl    r14d, 16
  or     r14d, edx
  shl    r10d, 8
  or     r14d, r10d
@alloc:
  mov    rax, qword ptr [rbx + TPpmd8.HiUnit]
  cmp    rax, qword ptr [rbx + TPpmd8.LoUnit]
  je     @freeList
  sub    rax, UNIT_SIZE
  mov    qword ptr [rbx + TPpmd8.HiUnit], rax
  jmp    @got
@freeList:
  mov    eax, dword ptr [rbx + TPpmd8.FreeList]
  test   eax, eax
  jz     @rare
  add    rax, r12                                 // RemoveNode(p, 0)
  mov    edx, dword ptr [rax + 4]
  mov    dword ptr [rbx + TPpmd8.FreeList], edx
  sub    dword ptr [rbx + TPpmd8.Stamps], 1
  jmp    @got
@rare:
{$IFDEF WIN64}
  mov    rcx, rbx
  xor    edx, edx
{$ELSE}
  mov    rdi, rbx
  xor    esi, esi
{$ENDIF}
  call   P8AllocUnitsRare
  test   rax, rax
  jz     @ret                                     // nil
@got:
  mov    dword ptr [rax], r14d
  mov    dword ptr [rax + 4], r15d                // Successor(OneState) := upBranch
  mov    edx, r13d
  sub    edx, r12d
  mov    dword ptr [rax + 8], edx                 // Suffix := REF(c)
  dec    ebp
  mov    rdx, qword ptr [rsp + CS_PS + rbp * 8]
  mov    ecx, eax
  sub    ecx, r12d
  mov    dword ptr [rdx + 2], ecx                 // Successor(ps[numPs]) := REF(c1)
  mov    r13, rax
  test   ebp, ebp
  jnz    @alloc
  mov    rax, r13
@ret:
{$IFDEF WIN64}
  add    rsp, 2088
  pop    rsi
  pop    rdi
{$ELSE}
  add    rsp, 2056
{$ENDIF}
  pop    r15
  pop    r14
  pop    r13
  pop    r12
  pop    rbp
  pop    rbx
end;

procedure P8UpdateModel(p: PPpmd8); assembler; nostackframe;
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
  sub    rsp, 72
  mov    rbx, rcx
{$ELSE}
  sub    rsp, 40
  mov    rbx, rdi
{$ENDIF}
  // locales: [UM_L] fFreq, [+4] fSymbol, [+8] flag, [+12] ns, [+16] s0, [+20] i, [+24] oldNU
  mov    r12, qword ptr [rbx + TPpmd8.Base]
  mov    rdx, qword ptr [rbx + TPpmd8.FoundState]
  mov    r15d, dword ptr [rdx + 2]                // minSuccessor
  movzx  eax, byte ptr [rdx + 1]
  mov    dword ptr [rsp + UM_L], eax              // fFreq
  movzx  ecx, byte ptr [rdx]
  mov    dword ptr [rsp + UM_L + 4], ecx          // fSymbol

  // --- P8UpdateSuffixFreq: s en r14 (o nil) ---
  xor    r14d, r14d
  cmp    eax, 31                                  // MAX_FREQ div 4
  jae    @sfDone
  mov    r8, qword ptr [rbx + TPpmd8.MinContext]
  mov    eax, dword ptr [r8 + 8]
  test   eax, eax
  jz     @sfDone
  lea    r8, [r12 + rax]                          // c := sufijo
  movzx  eax, byte ptr [r8]
  test   eax, eax
  jnz    @sfMulti
  lea    r14, [r8 + 2]
  movzx  eax, byte ptr [r14 + 1]
  cmp    eax, 32
  jae    @sfDone
  add    byte ptr [r14 + 1], 1
  jmp    @sfDone
@sfMulti:
  mov    r14d, dword ptr [r8 + 4]
  add    r14, r12
  cmp    byte ptr [r14], cl
  je     @sfFreq
@sfl:
  add    r14, 6
  cmp    byte ptr [r14], cl
  jne    @sfl
  movzx  eax, byte ptr [r14 + 1]
  movzx  edx, byte ptr [r14 - 5]
  cmp    eax, edx
  jb     @sfFreq
  mov    eax, dword ptr [r14]                     // SwapStates(s, s - 1)
  movzx  edx, word ptr [r14 + 4]
  mov    r9d, dword ptr [r14 - 6]
  movzx  r10d, word ptr [r14 - 2]
  mov    dword ptr [r14 - 6], eax
  mov    word ptr [r14 - 2], dx
  mov    dword ptr [r14], r9d
  mov    word ptr [r14 + 4], r10w
  sub    r14, 6
@sfFreq:
  movzx  eax, byte ptr [r14 + 1]
  cmp    eax, MAX_FREQ - 9
  jae    @sfDone
  add    byte ptr [r14 + 1], 2
  add    word ptr [r8 + 2], 2
@sfDone:

  mov    r13, qword ptr [rbx + TPpmd8.MaxContext] // c := MaxContext
  cmp    dword ptr [rbx + TPpmd8.OrderFall], 0
  jne    @notMax
  test   r15d, r15d
  jz     @notMax
  // cs := CreateSuccessors(p, True, s, MinContext)
{$IFDEF WIN64}
  mov    rcx, rbx
  mov    edx, 1
  mov    r8, r14
  mov    r9, qword ptr [rbx + TPpmd8.MinContext]
{$ELSE}
  mov    rdi, rbx
  mov    esi, 1
  mov    rdx, r14
  mov    rcx, qword ptr [rbx + TPpmd8.MinContext]
{$ENDIF}
  call   P8CreateSuccessors
  mov    rdx, qword ptr [rbx + TPpmd8.FoundState]
  test   rax, rax
  jz     @csFail
  mov    ecx, eax
  sub    ecx, r12d
  mov    dword ptr [rdx + 2], ecx
  mov    qword ptr [rbx + TPpmd8.MinContext], rax
  mov    qword ptr [rbx + TPpmd8.MaxContext], rax
  jmp    @ret
@csFail:
  mov    dword ptr [rdx + 2], 0
  jmp    @restore

@notMax:
  mov    rax, qword ptr [rbx + TPpmd8.Text]
  mov    rdx, qword ptr [rbx + TPpmd8.FoundState]
  movzx  ecx, byte ptr [rdx]
  mov    byte ptr [rax], cl
  inc    rax
  mov    qword ptr [rbx + TPpmd8.Text], rax
  cmp    rax, qword ptr [rbx + TPpmd8.UnitsStart]
  jae    @restore
  mov    ebp, eax
  sub    ebp, r12d                                // maxSuccessor := REF(Text)
  test   r15d, r15d
  jnz    @hasMin
  // cs := ReduceOrder(p, s, MinContext)
{$IFDEF WIN64}
  mov    rcx, rbx
  mov    rdx, r14
  mov    r8, qword ptr [rbx + TPpmd8.MinContext]
{$ELSE}
  mov    rdi, rbx
  mov    rsi, r14
  mov    rdx, qword ptr [rbx + TPpmd8.MinContext]
{$ENDIF}
  call   P8ReduceOrder
  test   rax, rax
  jz     @restore
  mov    r15d, eax
  sub    r15d, r12d
  jmp    @of
@hasMin:
  lea    rax, [r12 + r15]
  cmp    rax, qword ptr [rbx + TPpmd8.UnitsStart]
  jae    @of
  // sucesor RAW: cs := CreateSuccessors(p, False, s, MinContext)
{$IFDEF WIN64}
  mov    rcx, rbx
  xor    edx, edx
  mov    r8, r14
  mov    r9, qword ptr [rbx + TPpmd8.MinContext]
{$ELSE}
  mov    rdi, rbx
  xor    esi, esi
  mov    rdx, r14
  mov    rcx, qword ptr [rbx + TPpmd8.MinContext]
{$ENDIF}
  call   P8CreateSuccessors
  test   rax, rax
  jz     @restore
  mov    r15d, eax
  sub    r15d, r12d
@of:
  sub    dword ptr [rbx + TPpmd8.OrderFall], 1
  jnz    @flag
  mov    ebp, r15d                                // maxSuccessor := minSuccessor
  mov    rax, qword ptr [rbx + TPpmd8.MaxContext]
  cmp    rax, qword ptr [rbx + TPpmd8.MinContext]
  je     @flag
  sub    qword ptr [rbx + TPpmd8.Text], 1
@flag:
  mov    eax, dword ptr [rsp + UM_L + 4]
  add    eax, 0C0h
  shr    eax, 5
  and    eax, 8
  mov    dword ptr [rsp + UM_L + 8], eax          // flag := HiBits3(fSymbol)
  mov    rdx, qword ptr [rbx + TPpmd8.MinContext]
  movzx  ecx, byte ptr [rdx]
  mov    dword ptr [rsp + UM_L + 12], ecx         // ns
  movzx  eax, word ptr [rdx + 2]
  sub    eax, ecx
  sub    eax, dword ptr [rsp + UM_L]
  mov    dword ptr [rsp + UM_L + 16], eax         // s0 := SummFreq - ns - fFreq

@loop:
  cmp    r13, qword ptr [rbx + TPpmd8.MinContext]
  je     @done
  movzx  ecx, byte ptr [r13]                      // ns1
  test   ecx, ecx
  jz     @bin2
  test   ecx, 1
  jz     @noExp
  lea    edx, [rcx + 1]
  shr    edx, 1                                   // oldNU
  movzx  eax, byte ptr [rbx + TPpmd8.Units2Indx + rdx - 1]   // i
  movzx  r8d, byte ptr [rbx + TPpmd8.Units2Indx + rdx]
  cmp    eax, r8d
  je     @noExp
  mov    dword ptr [rsp + UM_L + 20], eax
  mov    dword ptr [rsp + UM_L + 24], edx
{$IFDEF WIN64}
  mov    rcx, rbx
  lea    edx, [rax + 1]
{$ELSE}
  mov    rdi, rbx
  lea    esi, [rax + 1]
{$ENDIF}
  call   P8AllocUnitsF
  test   rax, rax
  jz     @restore
  mov    r8d, dword ptr [r13 + 4]
  add    r8, r12                                  // oldPtr
  mov    ecx, dword ptr [rsp + UM_L + 24]
  mov    r9, rax
  mov    r10, r8
@cp:
  mov    edx, dword ptr [r10]
  mov    dword ptr [r9], edx
  mov    edx, dword ptr [r10 + 4]
  mov    dword ptr [r9 + 4], edx
  mov    edx, dword ptr [r10 + 8]
  mov    dword ptr [r9 + 8], edx
  add    r10, 12
  add    r9, 12
  dec    ecx
  jnz    @cp
  // InsertNode(p, oldPtr, i)
  mov    ecx, dword ptr [rsp + UM_L + 20]
  mov    dword ptr [r8], 0FFFFFFFFh
  mov    edx, dword ptr [rbx + TPpmd8.FreeList + rcx * 4]
  mov    dword ptr [r8 + 4], edx
  movzx  edx, byte ptr [rbx + TPpmd8.Indx2Units + rcx]
  mov    dword ptr [r8 + 8], edx
  mov    edx, r8d
  sub    edx, r12d
  mov    dword ptr [rbx + TPpmd8.FreeList + rcx * 4], edx
  add    dword ptr [rbx + TPpmd8.Stamps + rcx * 4], 1
  mov    edx, eax
  sub    edx, r12d
  mov    dword ptr [r13 + 4], edx                 // c^.Stats := REF(ptr)
  movzx  ecx, byte ptr [r13]
@noExp:
  movzx  eax, word ptr [r13 + 2]                  // sum := SummFreq
  lea    edx, [rcx + rcx * 2 + 1]
  xor    r8d, r8d
  cmp    edx, dword ptr [rsp + UM_L + 12]
  setb   r8b
  add    eax, r8d                                 // + Ord(3 * ns1 + 1 < ns)
  jmp    @addSym
@bin2:
{$IFDEF WIN64}
  mov    rcx, rbx
  xor    edx, edx
{$ELSE}
  mov    rdi, rbx
  xor    esi, esi
{$ENDIF}
  call   P8AllocUnitsF
  test   rax, rax
  jz     @restore
  movzx  edx, byte ptr [r13 + 3]                  // freq
  movzx  r8d, byte ptr [r13 + 2]
  mov    byte ptr [rax], r8b
  mov    r8d, dword ptr [r13 + 4]
  mov    dword ptr [rax + 2], r8d                 // Successor
  mov    r8d, eax
  sub    r8d, r12d
  mov    dword ptr [r13 + 4], r8d                 // c^.Stats := REF(s)
  cmp    edx, 30                                  // MAX_FREQ div 4 - 1
  jb     @dbl
  mov    edx, MAX_FREQ - 4
  jmp    @fset
@dbl:
  add    edx, edx
@fset:
  mov    byte ptr [rax + 1], dl
  mov    eax, edx
  add    eax, dword ptr [rbx + TPpmd8.InitEsc]
  xor    r8d, r8d
  cmp    dword ptr [rsp + UM_L + 12], 2
  seta   r8b
  add    eax, r8d                                 // sum := freq + InitEsc + Ord(ns > 2)
  xor    ecx, ecx                                 // ns1 := 0
@addSym:
  // eax = sum, ecx = ns1
  mov    r8d, dword ptr [r13 + 4]
  add    r8, r12
  lea    rdx, [rcx + rcx * 2]
  lea    r8, [r8 + rdx * 2 + 6]                   // s := Stats + ns1 + 1
  lea    r9d, [rax + 6]
  add    r9d, r9d
  imul   r9d, dword ptr [rsp + UM_L]              // cf := 2 * (sum + 6) * fFreq
  mov    r10d, dword ptr [rsp + UM_L + 16]
  add    r10d, eax                                // sf := s0 + sum
  mov    edx, dword ptr [rsp + UM_L + 4]
  mov    byte ptr [r8], dl                        // Symbol := fSymbol
  lea    edx, [rcx + 1]
  mov    byte ptr [r13], dl                       // NumStats := ns1 + 1
  mov    dword ptr [r8 + 2], ebp                  // Successor := maxSuccessor
  mov    edx, dword ptr [rsp + UM_L + 8]
  or     byte ptr [r13 + 1], dl                   // Flags := Flags or flag
  lea    edx, [r10 + r10 * 2]
  add    edx, edx
  cmp    r9d, edx
  jae    @big
  xor    edx, edx
  cmp    r9d, r10d
  seta   dl
  lea    r11d, [rdx + 1]
  lea    edx, [r10 * 4]
  xor    ecx, ecx
  cmp    r9d, edx
  setae  cl
  add    r11d, ecx                                // cf := 1 + Ord(cf > sf) + Ord(cf >= 4 * sf)
  add    eax, 4
  jmp    @st
@big:
  mov    r11d, 4
  lea    edx, [r10 + r10 * 8]
  xor    ecx, ecx
  cmp    r9d, edx
  seta   cl
  add    r11d, ecx
  lea    edx, [r10 + r10 * 2]
  shl    edx, 2
  xor    ecx, ecx
  cmp    r9d, edx
  seta   cl
  add    r11d, ecx
  lea    edx, [r10 + r10 * 4]
  lea    edx, [rdx + rdx * 2]
  xor    ecx, ecx
  cmp    r9d, edx
  seta   cl
  add    r11d, ecx                                // cf := 4 + ...
  add    eax, r11d
@st:
  mov    word ptr [r13 + 2], ax                   // SummFreq := sum
  mov    byte ptr [r8 + 1], r11b                  // Freq := cf
  mov    eax, dword ptr [r13 + 8]
  lea    r13, [r12 + rax]                         // c := sufijo
  jmp    @loop

@done:
  lea    rax, [r12 + r15]
  mov    qword ptr [rbx + TPpmd8.MinContext], rax
  mov    qword ptr [rbx + TPpmd8.MaxContext], rax
  jmp    @ret
@restore:
{$IFDEF WIN64}
  mov    rcx, rbx
  mov    rdx, r13
{$ELSE}
  mov    rdi, rbx
  mov    rsi, r13
{$ENDIF}
  call   P8RestoreModel
@ret:
{$IFDEF WIN64}
  add    rsp, 72
  pop    rsi
  pop    rdi
{$ELSE}
  add    rsp, 40
{$ENDIF}
  pop    r15
  pop    r14
  pop    r13
  pop    r12
  pop    rbp
  pop    rbx
end;
