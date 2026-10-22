#!/usr/bin/env python3
"""Genera el cuerpo asm de DecMatchAsm (x86-64, sintaxis intel de FPC) de src/parc_lzma.pas.
Uso: python3 tests/lzma_ref/gen_lzma_match_asm.py            (imprime el cuerpo)
     python3 tests/lzma_ref/gen_lzma_match_asm.py --check src/parc_lzma.pas   (0 si coincide)
     python3 tests/lzma_ref/gen_lzma_match_asm.py --write src/parc_lzma.pas   (lo reemplaza)
Registros: r8d rng, r9d cod, r10 inp, rdi registro TLzRun, r11d st, r12d posState (contador
después), r13 base de probabilidades, r14d len, r15d dist, ebx sym, ebp máscara/acumulador y
código de salida. Temporales: eax, ecx, edx, esi.
BITMODE=cmov genera los bits de decisión (IsRep, Choice...) sin saltos; medido más lento que
con saltos (jmp, el default), que es lo que usa el fuente."""
import os
import sys

out = []
n = [0]


def lab(p):
    n[0] += 1
    return '@%s%d' % (p, n[0])


def e(s):
    out.append('  ' + s if not s.startswith('@') else s)


def norm():
    l = lab('nm')
    e('cmp r8d, $1000000')
    e('jae %s' % l)
    e('shl r8d, 8')
    e('shl r9d, 8')
    e('movzx ecx, byte ptr [r10]')
    e('or r9d, ecx')
    e('inc r10')
    e(l + ':')


MODE = os.environ.get('BITMODE', 'jmp')


def branchy(one):
    if MODE == 'cmov':
        return branchy_cmov(one)
    return branchy_jmp(one)


def branchy_cmov(one):
    """bit de decisión: actualización sin saltos (como tree) y un solo salto según el bit.
    Probabilidad en [rsi]; usa ebx y ecx. Si el bit es 1 salta a `one`; si es 0 sigue."""
    e('movzx eax, word ptr [rsi]')
    e('mov edx, r8d')
    e('shr edx, 11')
    e('imul edx, eax')
    e('mov ebx, eax')
    e('shr ebx, 5')
    e('mov ecx, eax')
    e('sub ecx, ebx')
    e('mov ebx, 2048')
    e('sub ebx, eax')
    e('shr ebx, 5')
    e('add ebx, eax')
    e('sub r8d, edx')
    e('mov eax, r9d')
    e('sub eax, edx')
    e('cmovb r8d, edx')
    e('cmovae r9d, eax')
    e('cmovae ebx, ecx')
    e('mov [rsi], bx')
    e('sbb ebx, ebx')
    norm()
    e('test ebx, ebx')
    e('jz %s' % one)


def branchy_jmp(one):
    """bit con saltos; probabilidad en [rsi]. Si el bit es 1 salta a `one`; si es 0 sigue."""
    l1 = lab('b1')
    l0 = lab('b0')
    e('movzx eax, word ptr [rsi]')
    e('mov edx, r8d')
    e('shr edx, 11')
    e('imul edx, eax')
    e('cmp r9d, edx')
    e('jae %s' % l1)
    e('mov r8d, edx')
    e('mov ecx, 2048')
    e('sub ecx, eax')
    e('shr ecx, 5')
    e('add eax, ecx')
    e('mov [rsi], ax')
    norm()
    e('jmp %s' % l0)
    e(l1 + ':')
    e('sub r8d, edx')
    e('sub r9d, edx')
    e('mov ecx, eax')
    e('shr ecx, 5')
    e('sub eax, ecx')
    e('mov [rsi], ax')
    norm()
    e('jmp %s' % one)
    e(l0 + ':')


def tree():
    """paso de árbol sin saltos: prob [r13 + rbx*2], ebx := 2*ebx + bit"""
    e('movzx eax, word ptr [r13 + rbx * 2]')
    e('mov edx, r8d')
    e('shr edx, 11')
    e('imul edx, eax')
    e('mov esi, eax')
    e('shr esi, 5')
    e('mov ecx, eax')
    e('sub ecx, esi')
    e('mov esi, 2048')
    e('sub esi, eax')
    e('shr esi, 5')
    e('add esi, eax')
    e('sub r8d, edx')
    e('mov eax, r9d')
    e('sub eax, edx')
    e('cmovb r8d, edx')
    e('cmovae r9d, eax')
    e('cmovae esi, ecx')
    e('mov [r13 + rbx * 2], si')
    e('cmc')
    e('adc ebx, ebx')
    norm()


def rev_step():
    """paso de árbol inverso: como tree() y además dist |= bit * ebp; ebp *= 2"""
    tree()
    e('mov eax, ebx')
    e('and eax, 1')
    e('neg eax')
    e('and eax, ebp')
    e('or r15d, eax')
    e('add ebp, ebp')


def tree_loop(limit):
    """árbol completo: ebx = 1 al entrar, sale con ebx en [limit, 2*limit)"""
    l = lab('tl')
    e('mov ebx, 1')
    e(l + ':')
    tree()
    e('cmp ebx, %d' % limit)
    e('jb ' + l)


def length(pfx):
    """decodifica la longitud (0..271) en r14d; r13 = TLenDecoder; usa r12d = posState.
    Low y Mid comparten el árbol de 3 bits (r14d = 0 u 8 de base)."""
    c1 = '@%sc1' % pfx
    t3 = '@%st3' % pfx
    c2 = '@%sc2' % pfx
    done = '@%sdone' % pfx
    e('xor r14d, r14d')
    e('lea rsi, [r13 + TLenDecoder.Choice]')
    branchy(c1)
    e('mov eax, r12d')
    e('shl eax, 4')
    e('lea r13, [r13 + rax + TLenDecoder.LowT]')
    e('jmp ' + t3)
    e(c1 + ':')
    e('lea rsi, [r13 + TLenDecoder.Choice2]')
    branchy(c2)
    e('mov eax, r12d')
    e('shl eax, 4')
    e('lea r13, [r13 + rax + TLenDecoder.MidT]')
    e('mov r14d, 8')
    e(t3 + ':')
    tree_loop(8)
    e('lea r14d, [r14 + rbx - 8]')
    e('jmp ' + done)
    e(c2 + ':')
    e('lea r13, [r13 + TLenDecoder.HighT]')
    tree_loop(256)
    e('lea r14d, [rbx - 240]')
    e(done + ':')


R = 'TLzRun'
# entrada
e('{$IFDEF WIN64}')
e('mov rax, rcx')
e('{$ELSE}')
e('mov rax, rdi')
e('{$ENDIF}')
for i, r in enumerate(['rbx', 'rbp', 'r12', 'r13', 'r14', 'r15', 'rdi', 'rsi']):
    e('mov [rax + %s.sv + %d], %s' % (R, i * 8, r))
e('mov rdi, rax')
e('mov r8d, [rdi + %s.rng]' % R)
e('mov r9d, [rdi + %s.cod]' % R)
e('mov r10, [rdi + %s.inp]' % R)
e('mov r11d, [rdi + %s.st]' % R)
e('mov r12d, [rdi + %s.total]' % R)
e('and r12d, [rdi + %s.pbMask]' % R)
e('xor r14d, r14d')
# IsRep[st]
e('mov rsi, [rdi + %s.isRep]' % R)
e('lea rsi, [rsi + r11 * 2]')
branchy('@rep')
# ---- match ----
e('mov eax, [rdi + %s.rep2]' % R)
e('mov [rdi + %s.rep3], eax' % R)
e('mov eax, [rdi + %s.rep1]' % R)
e('mov [rdi + %s.rep2], eax' % R)
e('mov eax, [rdi + %s.rep0]' % R)
e('mov [rdi + %s.rep1], eax' % R)
e('mov r13, [rdi + %s.lenDec]' % R)
e('xor ebp, ebp')
# longitud compartida por match (ebp = 0) y rep (ebp = 1)
e('@len:')
length('ln')
e('test ebp, ebp')
e('jnz @repstate')
e('mov eax, 10')
e('cmp r11d, 7')
e('mov r11d, 7')
e('cmovae r11d, eax')
# pos slot
e('mov eax, r14d')
e('mov ecx, 3')
e('cmp eax, ecx')
e('cmova eax, ecx')
e('shl eax, 7')
e('mov r13, [rdi + %s.posSlot]' % R)
e('add r13, rax')
tree_loop(64)
e('sub ebx, 64')
e('cmp ebx, 4')
e('jae @slot4')
e('mov r15d, ebx')
e('jmp @distdone')
e('@slot4:')
e('mov ecx, ebx')
e('shr ecx, 1')
e('dec ecx')
e('mov r15d, ebx')
e('and r15d, 1')
e('or r15d, 2')
e('shl r15d, cl')
e('mov r12d, ecx')
e('cmp ebx, 14')
e('jae @direct')
# inverso sobre PosDecoders[dist - slot], nd bits
e('mov eax, r15d')
e('sub eax, ebx')
e('mov r13, [rdi + %s.posDec]' % R)
e('lea r13, [r13 + rax * 2]')
e('mov ebx, 1')
e('mov ebp, 1')
e('@revloop:')
rev_step()
e('dec r12d')
e('jnz @revloop')
e('jmp @distdone')
e('@direct:')
e('sub r12d, 4')
e('xor ebp, ebp')
e('@dirloop:')
e('shr r8d, 1')
e('sub r9d, r8d')
e('mov ecx, r9d')
e('sar ecx, 31')
e('mov eax, ecx')
e('and eax, r8d')
e('add r9d, eax')
e('add ebp, ebp')
e('inc ebp')
e('add ebp, ecx')
norm()
e('dec r12d')
e('jnz @dirloop')
e('shl ebp, 4')
e('add r15d, ebp')
e('mov r13, [rdi + %s.alignP]' % R)
e('mov ebx, 1')
e('mov ebp, 1')
e('mov r12d, 4')
e('@alignloop:')
rev_step()
e('dec r12d')
e('jnz @alignloop')
e('@distdone:')
e('mov [rdi + %s.rep0], r15d' % R)
e('cmp r15d, $FFFFFFFF')
e('je @endmark')
e('mov eax, r15d')
e('cmp rax, [rdi + %s.total]' % R)
e('jae @error')
e('cmp rax, [rdi + %s.dicSz]' % R)
e('jae @error')
e('xor ebp, ebp')
e('jmp @exit')
# ---- rep ----
e('@rep:')
e('cmp qword ptr [rdi + %s.total], 0' % R)
e('je @error')
e('mov rsi, [rdi + %s.isRepG0]' % R)
e('lea rsi, [rsi + r11 * 2]')
branchy('@g1')
e('mov eax, r11d')
e('shl eax, 4')
e('add eax, r12d')
e('mov rsi, [rdi + %s.isRep0Long]' % R)
e('lea rsi, [rsi + rax * 2]')
branchy('@replen')
# short rep
e('mov eax, 11')
e('cmp r11d, 7')
e('mov r11d, 9')
e('cmovae r11d, eax')
e('mov ebp, 3')
e('jmp @exit')
e('@g1:')
e('mov rsi, [rdi + %s.isRepG1]' % R)
e('lea rsi, [rsi + r11 * 2]')
branchy('@g2')
e('mov r15d, [rdi + %s.rep1]' % R)
e('jmp @g1done')
e('@g2:')
e('mov rsi, [rdi + %s.isRepG2]' % R)
e('lea rsi, [rsi + r11 * 2]')
branchy('@g3')
e('mov r15d, [rdi + %s.rep2]' % R)
e('jmp @g2done')
e('@g3:')
e('mov r15d, [rdi + %s.rep3]' % R)
e('mov eax, [rdi + %s.rep2]' % R)
e('mov [rdi + %s.rep3], eax' % R)
e('@g2done:')
e('mov eax, [rdi + %s.rep1]' % R)
e('mov [rdi + %s.rep2], eax' % R)
e('@g1done:')
e('mov eax, [rdi + %s.rep0]' % R)
e('mov [rdi + %s.rep1], eax' % R)
e('mov [rdi + %s.rep0], r15d' % R)
e('@replen:')
e('mov r13, [rdi + %s.repLenDec]' % R)
e('mov ebp, 1')
e('jmp @len')
e('@repstate:')
e('mov eax, 11')
e('cmp r11d, 7')
e('mov r11d, 8')
e('cmovae r11d, eax')
e('xor ebp, ebp')
e('jmp @exit')
e('@endmark:')
e('mov ebp, 1')
e('jmp @exit')
e('@error:')
e('mov ebp, 2')
e('@exit:')
e('mov [rdi + %s.rng], r8d' % R)
e('mov [rdi + %s.cod], r9d' % R)
e('mov [rdi + %s.inp], r10' % R)
e('mov [rdi + %s.st], r11d' % R)
e('mov [rdi + %s.len], r14d' % R)
e('mov eax, ebp')
for i, r in enumerate(['rbx', 'rbp', 'r12', 'r13', 'r14', 'r15']):
    e('mov %s, [rdi + %s.sv + %d]' % (r, R, i * 8))
e('mov rsi, [rdi + %s.sv + 56]' % R)
e('mov rdi, [rdi + %s.sv + 48]' % R)

body = '\n'.join(out) + '\n'
HEAD = 'function DecMatchAsm(r: PLzRun): LongWord; assembler; nostackframe;\nasm\n'
TAIL = 'end;\n{$ENDIF}\n'
if len(sys.argv) == 3 and sys.argv[1] in ('--check', '--write'):
    src = open(sys.argv[2], encoding='utf-8').read()
    a = src.index(HEAD) + len(HEAD)
    b = src.index(TAIL, a)
    if sys.argv[1] == '--check':
        ok = src[a:b] == body
        print('DecMatchAsm: ' + ('coincide' if ok else 'NO coincide con el generador'))
        sys.exit(0 if ok else 1)
    open(sys.argv[2], 'w', encoding='utf-8').write(src[:a] + body + src[b:])
else:
    sys.stdout.write(body)
