#!/bin/bash
# tests/container.sh — PArc's container (format 2, FORMATO-PARC.md §1-§4): round trips of every kind
# of entry with ns mtimes and modes, update/delete/lock/comment, SFX stub, encryption (-p, -hp),
# volumes, determinism, and damaged archives (end locator, index, head, garbage, old format,
# random flips: never a crash or a hang).
set -u
export LC_ALL=C
ROOT=$(cd "$(dirname "$0")/.." && pwd)
PARC=${PARC_BIN:-$ROOT/build/linux64/parc}
W=${CONTAINER_WORK:-${TMPDIR:-/tmp}/parc_container}
rm -rf -- "${W:?}"; mkdir -p "$W" && cd "$W" || exit 2
fail=0
ck() { if eval "$2"; then printf '  ok    %s\n' "$1"; else printf '  FAIL  %s\n' "$1"; fail=$((fail+1)); fi; }
P() { "$PARC" "$@" --no-progress </dev/null; }
q() { "$PARC" "$@" --no-progress </dev/null >/dev/null 2>&1; }
code() { "$PARC" "$@" --no-progress </dev/null >/dev/null 2>&1; echo $?; }
okt() { P t "$@" 2>/dev/null | tail -1 | grep -q 'All OK'; }
# same tree: contents, symlinks, modes and mtimes with nanoseconds (not of the links themselves:
# extraction does not set them)
meta() { (cd "$1" && { find . ! -type l -printf '%P %y %m %T@\n'; find . -type l -printf '%P %y %l\n'; } | sort); }
same() { diff -r --no-dereference "$1" "$2" >/dev/null && [ "$(meta "$1")" = "$(meta "$2")" ]; }
flip() { python3 -c "
import sys; f=open(sys.argv[1],'r+b'); o=int(sys.argv[2]); n=len(f.read()); o=o if o>=0 else n+o
f.seek(o); b=f.read(1); f.seek(o); f.write(bytes([b[0]^0x55]))" "$1" "$2"; }
KDF=-ae=chacha:t1:m8m:p1

mkdir -p src/sub/deep/er src/empty src/ñandú
printf 'alpha\n' > src/a.txt; printf 'x' > src/one; : > src/zero; : > src/sub/zero2
seq 1 60000 > src/n.txt; head -c 300000 /dev/urandom > src/r.bin
printf 'unicode\n' > 'src/ñandú/café ☕.txt'; printf 'deep\n' > src/sub/deep/er/d.txt
for i in $(seq 1 400); do printf 'file %d\n' $i > src/sub/f$i.txt; done
ln -s a.txt src/link; ln -s sub src/dlink
chmod 750 src/sub/deep; chmod 600 src/one; chmod 755 src/a.txt
touch -d '1999-12-31 23:59:59.123456789' src/n.txt
touch -d '2099-01-01 00:00:00.5' src/r.bin
touch -h -d '2001-02-03 04:05:06.7' src/link

echo '-- round trips'
for m in -m0 -m1 -m5 "-m3 -s-"; do
  rm -rf o; q a "rt.parc" src ${m}; q x rt.parc -dpo -o+ -y
  ck "round trip $m (data, links, modes, ns mtimes)" 'same src o/src'
  rm -f rt.parc
done
q a e1.parc src/zero; ck "archive of one empty file"   'okt e1.parc && P l e1.parc | grep -q zero'
q a e2.parc src/empty; ck "archive of one empty dir"   'okt e2.parc && P l e2.parc | grep -q empty'
q a ab.parc src -m5
ck "lb: head, index, locator"                 'P lb ab.parc | grep -q "^  head" && P lb ab.parc | grep -q "^  index" && P lb ab.parc | grep -q "^  locator"'
ck "starts with the head magic"               '[ "$(head -c 8 ab.parc | od -An -tx1 | tr -d " \n")" = "504172630d0a1a0a" ]'
ck "ends with the end locator magic"          '[ "$(tail -c 4 ab.parc)" = "PAel" ]'

echo '-- determinism'
q a d1.parc src -m5; q a d2.parc src -m5
ck "same input, same archive (-m5)"           'cmp -s d1.parc d2.parc'
PARC_THREADS=1 q a d3.parc src -m0 -s-; PARC_THREADS=4 q a d4.parc src -m0 -s-
ck "same archive with 1 and 4 threads (-m0 -s-)" 'cmp -s d3.parc d4.parc'
q a d5.parc src -m2 -rr5%; q a d6.parc src -m2 -rr5%
ck "same archive with a recovery record"      'cmp -s d5.parc d6.parc'

echo '-- update / delete / lock / comment'
q a u.parc src -m2
blocks() { P lb "$1" | awk '/^Data blocks/{d=1} d && $1=="data" && $4!="comp=0" {print $4, $NF}' | sort; }
b0=$(blocks u.parc)
printf 'new\n' > new.txt; q a u.parc new.txt
ck "a: old blocks copied unchanged"           '[ "$(blocks u.parc | grep -F -x -c -f <(echo "$b0"))" = "$(echo "$b0" | wc -l)" ] && okt u.parc'
ck "a: the new file is there"                 'P l u.parc | grep -q new.txt'
q d u.parc src/sub/f7.txt
ck "d: deleted"                               '! P l u.parc | grep -q "sub/f7.txt$" && okt u.parc'
q a u.parc src -rr4%
ck "a -rr4%: recovery kept in the index"      'P lb u.parc | grep -q "recovery=\"4%\"" && P lb u.parc | grep -q "^  recovery"'
printf 'more\n' > more.txt; q a u.parc more.txt
ck "update keeps the record"                  'P lb u.parc | grep -q "^  recovery" && P r u.parc | grep -q "No damaged"'
q c u.parc --archive-comment='hello comment'
ck "comment"                                  '[ "$(P cw u.parc -)" = "hello comment" ] && okt u.parc'
q k u.parc
ck "k: locked"                                'P lb u.parc | grep -q "locked=yes"'
ck "locked: a refused"                        '[ $(code a u.parc new.txt) = 1 ]'
ck "locked: d refused"                        '[ $(code d u.parc new.txt) = 1 ]'

echo '-- SFX stub'
head -c 5000 /dev/urandom > stub; q a s0.parc src -m1 -rr3%; cat stub s0.parc > s.parc
ck "stub: listed and tested"                  'P lb s.parc | grep -q "SFX=5000" && okt s.parc'
rm -rf o; q x s.parc -dpo -o+ -y; ck "stub: extracted"  'same src o/src'
q a s.parc new.txt
ck "stub kept on update"                      'cmp -s <(head -c 5000 s.parc) stub && okt s.parc && P l s.parc | grep -q new.txt'
cp s.parc sd.parc; flip sd.parc 9000; rm -f fixed.sd.parc; q r sd.parc
ck "stub: repair restores it byte-identical"  'cmp -s fixed.sd.parc s.parc'

echo '-- encryption'
q a p.parc src -m2 -pSecret $KDF
ck "-p: names listed without a password"      'P l p.parc | grep -q a.txt'
ck "-p: test without password = 5"            '[ $(code t p.parc) = 5 ]'
ck "-p: round trip"                           'rm -rf o; q x p.parc -dpo -o+ -y -pSecret && same src o/src'
q a h.parc src -m2 -hpSecret $KDF
ck "-hp: list without password = 5"           '[ $(code l h.parc) = 5 ]'
ck "-hp: wrong password = 5"                  '[ $(code l h.parc -pWrong) = 5 ]'
ck "-hp: index encrypted (method in header)"  'P lb h.parc -pSecret | grep "^  index" | grep -q "xchacha20:.*:h"'
ck "-hp: round trip"                          'rm -rf o; q x h.parc -dpo -o+ -y -pSecret && same src o/src'
ck "-hp: no names in the clear"               '! grep -q "ñandú" h.parc && ! grep -qa "deep/er" h.parc'
q a h.parc new.txt -pSecret
ck "-hp: stays encrypted after an update"     '[ $(code l h.parc) = 5 ] && P l h.parc -pSecret | grep -q new.txt'

echo '-- volumes'
q a v.parc src -m1 -v100k
ck "volumes: tested"                          'okt v.parc.001'
q a nv.parc src -m1
ck "volumes = the same archive cut"           'cat v.parc.0* | cmp -s - nv.parc'
mv v.parc.003 v.parc.003.x
ck "missing volume: clean error"              '[ $(code l v.parc) = 2 ] || [ $(code l v.parc) = 4 ]'
mv v.parc.003.x v.parc.003

echo '-- damaged archives'
q a g.parc src -m2
cp g.parc t1.parc; flip t1.parc -3
ck "locator damaged: listed (index found by scanning)" 'P l t1.parc 2>&1 | grep -q a.txt && P l t1.parc 2>&1 | grep -q "Warning:.*scanning" && okt t1.parc'
head -c $(( $(stat -c %s g.parc) - 10 )) g.parc > t2.parc
ck "cut end: listed and tested"               'okt t2.parc'
cp g.parc t3.parc; flip t3.parc 3
ck "head damaged: warning, still readable"    'P l t3.parc 2>&1 | grep -q "Warning:.*head" && okt t3.parc'
ipos=$(P lb g.parc | awk '$1=="index"{sub("pos=","",$2); print $2}')
cp g.parc t4.parc; flip t4.parc $((ipos + 5))
ck "index damaged: error 2"                   '[ $(code l t4.parc) = 2 ] && P l t4.parc 2>&1 | grep -qi "index"'
cp g.parc t5.parc; flip t5.parc $((ipos - 3))
ck "index header damaged: error 2"            '[ $(code l t5.parc) = 2 ]'
head -c 3000 /dev/urandom > t6.parc
ck "garbage: not a .parc (2)"                 '[ $(code l t6.parc) = 2 ] && P l t6.parc 2>&1 | grep -q "not a .parc"'
: > t7.parc
ck "empty file: error"                        '[ $(code l t7.parc) != 0 ]'
printf 'PAr\001\001\000\000\000' > t8.parc; head -c 2000 /dev/urandom >> t8.parc
ck "old format: clear error"                  'P l t8.parc 2>&1 | grep -q "old PArc format"'
dpos=$(P lb g.parc | awk '$1=="data" && $4!="comp=0" {sub("pos=","",$2); print $2; exit}')
cp g.parc t9.parc; flip t9.parc $((dpos + 40))
ck "data damaged: test fails (2)"             '[ $(code t t9.parc) = 2 ]'
# random flips anywhere in the index, header and locator: never a crash or a hang
size=$(stat -c %s g.parc); bad=0
for i in $(seq 1 60); do
  cp g.parc f.parc
  python3 -c "
import random,sys; random.seed($i); f=open('f.parc','r+b'); n=$size; lo=$ipos-60
for _ in range(random.randint(1,4)):
    o=random.randrange(lo,n); f.seek(o); b=f.read(1); f.seek(o); f.write(bytes([b[0]^random.randrange(1,256)]))"
  timeout 20 "$PARC" t f.parc --no-progress </dev/null >/dev/null 2>&1; c=$?
  case $c in 0|1|2|3|5) ;; *) bad=$((bad+1)); echo "    flip seed $i: exit $c";; esac
done
ck "60 random index/locator flips: no crash, no hang" '[ $bad = 0 ]'

echo "== container: $fail failures"
[ $fail -eq 0 ]
