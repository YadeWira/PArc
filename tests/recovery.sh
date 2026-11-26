#!/bin/bash
# tests/recovery.sh — PArc's recovery record (parc-rr1, FORMATO-PARC.md §5): -rr syntax, and
# repair of damage within what the record protects (scattered sectors chosen at most m per
# stripe, contiguous bursts up to S*m sectors, damage in the index, locator, head, the record's
# own parity, checks, tables and descriptors, an SFX stub, volumes) restoring the archive
# byte-identical; damage beyond that fails cleanly (exit 2) and says what it could not repair.
set -u
export LC_ALL=C
ROOT=$(cd "$(dirname "$0")/.." && pwd)
PARC=${PARC_BIN:-$ROOT/build/linux64/parc}
W=${RS_WORK:-${TMPDIR:-/tmp}/parc_recovery}
rm -rf -- "${W:?}"; mkdir -p "$W/d" && cd "$W" || exit 2
fail=0
ck() { if eval "$2"; then printf '  ok    %s\n' "$1"; else printf '  FAIL  %s\n' "$1"; fail=$((fail+1)); fi; }
P() { "$PARC" "$@" --no-progress </dev/null; }
q() { "$PARC" "$@" --no-progress </dev/null >/dev/null 2>&1; }
code() { "$PARC" "$@" --no-progress </dev/null >/dev/null 2>&1; echo $?; }
okt() { P t "$@" 2>/dev/null | tail -1 | grep -q 'All OK'; }
for i in $(seq 1 8); do head -c 400000 /dev/urandom > "d/r$i.bin"; done; seq 1 300000 > d/t.txt

# layout of the record of an archive: "N S m ss start reclen recpos" (start = after an SFX stub)
layout() { python3 - "$1" <<'EOF'
import struct, sys
d = open(sys.argv[1], 'rb').read()
t = d[-48:]
prot, rlen, S, ss, m = struct.unpack('<QQQIH', t[:30])
recpos = len(d) - rlen
print((prot + ss - 1) // ss, S, m, ss, recpos - prot, rlen, recpos)
EOF
}
# damage <src> <dst> <seed> <what>: flips bytes in chosen sectors of the protected area
#   scatter K   : K random sectors, at most m per stripe (K <= S*m)
#   over        : m+1 sectors of one stripe
#   burst L     : L contiguous bytes from a random offset of the protected area
#   at O L      : L bytes at offset O (negative: from the end of the file)
damage() { python3 - "$@" <<'EOF'
import random, sys, shutil, struct
src, dst, seed, what = sys.argv[1], sys.argv[2], int(sys.argv[3]), sys.argv[4]
args = [int(a) for a in sys.argv[5:]]
random.seed(seed)
d = bytearray(open(src, 'rb').read())
t = d[-48:]
prot, rlen, S, ss, m = struct.unpack('<QQQIH', t[:30])
start = len(d) - rlen - prot
N = (prot + ss - 1) // ss
def hit(sec):
    lo = start + sec * ss; n = min(ss, prot - sec * ss)
    o = lo + random.randrange(n); d[o] ^= random.randrange(1, 256)
if what == 'scatter':
    per = {}; picked = 0
    for sec in random.sample(range(N), N):
        if picked == args[0]: break
        s = sec % S
        if per.get(s, 0) < m:
            per[s] = per.get(s, 0) + 1; hit(sec); picked += 1
elif what == 'over':
    s = random.randrange(S); secs = [p * S + s for p in range((N - s + S - 1) // S)]
    for sec in random.sample(secs, m + 1): hit(sec)
elif what == 'burst':
    L = args[0]; o = start + random.randrange(max(1, prot - L))
    for i in range(o, o + L): d[i] ^= random.randrange(1, 256)
elif what == 'at':
    o, L = args
    if o < 0: o += len(d)
    for i in range(o, o + L): d[i] ^= random.randrange(1, 256)
open(dst, 'wb').write(d)
EOF
}
repaired() {   # repaired <damaged> <original>: r says OK and fixed.<damaged> == original
  rm -f "fixed.$1"; "$PARC" r "$1" </dev/null >"$1.out" 2>&1 && cmp -s "fixed.$1" "$2"; }

echo '-- -rr syntax'
for s in 1% 5% '' 100k 50 50s '20;4k' '30*1k' '2%;1kb' 0.1% 0.01%; do
  rm -f s.parc; q a s.parc d -m1 "-rr$s"
  ck "-rr$s: written, no damage reported"     'P r s.parc | grep -q "No damaged sectors" && okt s.parc'
done
for s in abc '5%%' '1;100' '10*100' '0%' '101%' '5;'; do
  ck "-rr$s rejected"                          '[ $(code a bad.parc d -m1 "-rr$s") != 0 ] && [ ! -f bad.parc ]'
done
q a s.parc d -m1 -rr0.1%
ck "-rr0.1%: checks only, 4 KB sectors"       'P r s.parc | grep -q "checks only (sectors of 4096"'

echo '-- repair within the budget: byte-identical'
q a a.parc d -m1 -rr5%
read N S m ss start rlen rpos < <(layout a.parc)
echo "   (N=$N S=$S m=$m sector=$ss)"
for seed in 1 2 3 4 5; do
  damage a.parc sc$seed.parc $seed scatter $((S * m))
  ck "scatter S*m=$((S*m)) sectors, seed $seed" 'repaired sc$seed.parc a.parc'
done
for seed in 1 2 3; do
  damage a.parc bu$seed.parc $seed burst $(( (S * m - 1) * ss ))
  ck "burst of (S*m-1) sectors, seed $seed"   'repaired bu$seed.parc a.parc'
done
ipos=$(P lb a.parc | awk '$1=="index"{sub("pos=","",$2); print $2}')
damage a.parc ix.parc 1 at $((ipos - 20)) 60
ck "index header + payload"                   '[ $(code l ix.parc) = 2 ] && repaired ix.parc a.parc'
damage a.parc lo.parc 1 at $((rpos - 24)) 24
ck "end locator"                              'repaired lo.parc a.parc'
damage a.parc hd.parc 1 at 0 16
ck "head"                                     'repaired hd.parc a.parc'
damage a.parc pa.parc 1 at $((rpos + rlen / 2)) 3000
ck "the record's parity"                      'repaired pa.parc a.parc'
damage a.parc ch.parc 1 at $((rpos + 48 + 4 * S + 4 + 10)) 40
ck "the record's checks (false erasures)"     'repaired ch.parc a.parc'
damage a.parc td.parc 1 at -48 48
ck "trailing descriptor (found from the first)" 'repaired td.parc a.parc'
damage a.parc tb.parc 1 at $((rpos + 48)) $((4 * S + 4))
ck "first stripe table"                       'repaired tb.parc a.parc'
damage a.parc mx.parc 7 scatter $((S * m / 2))
damage mx.parc mx.parc 8 at -60 60
ck "scatter + end of the record"              'repaired mx.parc a.parc'
ck "repaired archive tests OK"                'okt fixed.mx.parc'

echo '-- beyond the budget: clean failure'
damage a.parc ov.parc 3 over
ck "m+1 sectors in one stripe: exit 2"        '[ $(code r ov.parc) = 2 ] && P r ov.parc 2>&1 | grep -q "unrecoverable"'
damage a.parc hv.parc 4 burst $(( (S * m + S) * ss ))
ck "burst beyond S*m sectors: exit 2"         '[ $(code r hv.parc) = 2 ]'
ck "never reported as repaired"               '! P r hv.parc 2>/dev/null | grep -q "^Repaired"'
q a c.parc d -m1 -rr0.1%
damage c.parc c1.parc 1 burst 100
ck "checks only: damage detected, exit 2"     '[ $(code r c1.parc) = 2 ] && P r c1.parc | grep -q "Damaged sectors"'
ck "no record: exit 1"                        'q a n.parc d -m1; [ $(code r n.parc) = 1 ]'

echo '-- stub, volumes, small archives, updates'
head -c 3000 /dev/urandom > stub; cat stub a.parc > st.parc
damage st.parc st2.parc 5 scatter $((S * m))
ck "SFX stub + scatter"                       'repaired st2.parc st.parc'
q a v.parc d -m1 -rr3% -v300k
cat v.parc.0* > vjoined.parc
damage vjoined.parc vj2.parc 2 burst 20000
cp vj2.parc vbad.parc; rm -f v2.parc.*; split -b 300k -d -a 3 --numeric-suffixes=1 vbad.parc v2.parc.
ck "volumes: repaired into one file"          'rm -f fixed.v2.parc; q r v2.parc; cmp -s fixed.v2.parc vjoined.parc'
printf 'x' > one; q a one.parc one -rr
damage one.parc one2.parc 1 at 10 3
ck "1-byte archive"                           'repaired one2.parc one.parc'
head -c 3000000 /dev/urandom > d/big.bin
q a g.parc d -m1 -rr3%
read N S m ss start rlen rpos < <(layout g.parc)
damage g.parc g2.parc 9 scatter $((S * m))
ck "3%, $S stripes: S*m scattered sectors"    'repaired g2.parc g.parc'
echo nuevo > d/nuevo.txt; q a a.parc d/nuevo.txt
ck "update keeps the record"                  'P r a.parc | grep -q "parc-rr1" && P lb a.parc | grep -q "^  recovery"'

echo "== recovery: $fail failures"
[ $fail -eq 0 ]
