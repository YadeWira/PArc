#!/bin/bash
# tests/solid.sh — solid-block planning (parc_solid): order, kind by name and content, -s
# limits, per-file tta/mm, the cap of block-local stages, updates and determinism.
set -u
ROOT=$(cd "$(dirname "$0")/.." && pwd)
PARC=${PARC_BIN:-$ROOT/build/linux64/parc}
W=${SOLID_WORK:-${TMPDIR:-/tmp}/parc_solid}
rm -rf -- "${W:?}"; mkdir -p "$W" && cd "$W" || exit 2
fail=0
ck() { if eval "$2"; then printf '  ok    %s\n' "$1"; else printf '  FAIL %s\n' "$1"; fail=$((fail+1)); fi; }
P() { "$PARC" "$@" --no-progress; }

python3 - <<'PY'
import os, random, struct, math
r = random.Random(7)
def w(p, b):
    os.makedirs(os.path.dirname(p), exist_ok=True)
    open(p, 'wb').write(b)
words = [''.join(r.choice('abcdefghijklmnopqrstuvwxyz') for _ in range(r.randint(2, 9))) for _ in range(400)]
def text(n):
    out = []
    while sum(map(len, out)) < n:
        out.append(' '.join(r.choice(words) for _ in range(12)) + '\n')
    return ''.join(out).encode()[:n]
def wav(n):
    s = b''.join(struct.pack('<h', int(8000 * math.sin(i / 9.0))) for i in range(n // 2))
    hdr = b'RIFF' + struct.pack('<I', 36 + len(s)) + b'WAVEfmt ' + struct.pack('<IHHIIHH', 16, 1, 1, 22050, 44100, 2, 16) + b'data' + struct.pack('<I', len(s))
    return hdr + s
w('src/docs/readme.txt', text(30000))
w('src/docs/notes.TXT', text(9000))
w('src/docs/plain.zzz', text(200000))            # text by content, unknown extension
w('src/bin/noise.zzz', os.urandom(300000))       # compressed by content
w('src/bin/fake.txt', os.urandom(200000))        # a .txt that is not text
w('src/bin/fake.wav', os.urandom(70000))         # a .wav that is not audio
w('src/snd/tone.wav', wav(200000))
w('src/snd/tone2.wav', wav(90000))
w('src/a/same.dat', bytes(range(256)) * 40)      # twins in different directories
w('src/m/other.dat', b'x' * 9000)
w('src/z/same.dat', bytes(range(256)) * 41)
w('src/empty.bin', b'')
w('src/one.bin', b'!')
w('src/sp ace/na me.txt', text(5000))
for i in range(40):
    w('src/many/f%02d.c' % i, text(r.randint(10, 3000)))
PY

EXT() { awk '$3 ~ /^[0-9]+$/ && $4 != "<DIR>" {print $NF}'; }
# data blocks: "<files> <method>" per block (the first one, of directories, left out)
blocks() { P lb "$1" | awk '/^Data blocks/ {d = 1} d && $1 == "data" {m = $NF; o = $3} d && /file\(s\)/ {if (!(o == "orig=0" && m == "storing")) print $1, m}'; }
xcmp() { rm -rf "x_$1" && mkdir "x_$1" && P x "$1" -dp"x_$1" >/dev/null 2>&1 && diff -r src "x_$1/src" >/dev/null; }

# round trips
for o in "-m0" "-m1" "-m3" "-m5" "-mx" "-m3 -s-" "-m3 -se" "-m3 -s3f" "-m3 -s20k" "-m2 -s1f" "-m4 -se5f64k"; do
  n=rt$(echo "$o" | tr -dc 'a-z0-9'); rm -f $n.parc
  ck "a $o + x" 'P a $n.parc src $o >/dev/null 2>&1 && xcmp $n.parc'
done

# -s limits
ck "-s-: one file per block"   'blocks rts.parc 2>/dev/null; [ -z "$(blocks rtm3s.parc | awk "\$1 != 1")" ]'
ck "-s3f: at most 3 per block" '[ -z "$(blocks rtm3s3f.parc | awk "\$1 > 3")" ] && [ -n "$(blocks rtm3s3f.parc | awk "\$1 == 3")" ]'
ck "-se: one extension per block" '
  ok=1; for b in $(P lb rtm3se.parc | awk "/file\\(s\\) from/ {sub(\"#\",\"\",\$4); print \$1\":\"\$4}"); do :; done
  P v rtm3se.parc | awk "NF >= 9 && \$1 ~ /^20/ && \$3 != \"<DIR>\" && \$4 != \"<DIR>\" {getline n; b = \$8; sub(/^ +/, \"\", n); e = n; if (e ~ /\\./) sub(/.*\\./, \"\", e); else e = \"\"; e = tolower(e); if (b in E && E[b] != e) bad = 1; E[b] = e} END {exit bad}"'
ck "-s20k: blocks close once they reach 20 KB" '
  P v rtm3s20k.parc | awk "NF >= 9 && \$1 ~ /^20/ && \$3 != \"<DIR>\" && \$4 != \"<DIR>\" {S[\$8] += \$4; L[\$8] = \$4; N[\$8]++} END {for (b in S) if (N[b] > 1 && S[b] - L[b] >= 20480) bad = 1; exit bad}"'

# kinds (-m3: \$text = bwt, \$compressed = orep+plz, \$wav = tta)
meth() { P v "$1" | awk -v f="$2" 'NF >= 9 && $1 ~ /^20/ {m = $NF; getline n; sub(/^ +/, "", n); if (n == f) print m}'; }
ck "text by name -> bwt"        'meth rtm3.parc src/docs/readme.txt | grep -q "^bwt"'
ck "text by content -> bwt"     'meth rtm3.parc src/docs/plain.zzz | grep -q "^bwt"'
ck "random data -> \$compressed"  'meth rtm3.parc src/bin/noise.zzz | grep -q "plz:1"'
ck "random .txt -> not bwt"     '! meth rtm3.parc src/bin/fake.txt | grep -q "bwt"'
ck "wav -> tta, one per block"  'meth rtm3.parc src/snd/tone.wav | grep -q "^tta" && [ -z "$(blocks rtm3.parc | awk "\$2 ~ /^tta/ && \$1 != 1")" ]'
ck "random .wav -> not tta"     '! meth rtm3.parc src/bin/fake.wav | grep -q "tta"'

# order: twins next to each other, grouped by extension
ck "twins together"             'P l rtm0.parc | grep -A1 "src/a/same.dat" | tail -1 | grep -q "src/z/same.dat"'
ck "extension runs"             '[ "$(P l rtm0.parc | grep -n "\.c$" | cut -d: -f1 | awk "NR > 1 && \$1 != p + 1 {bad = 1} {p = \$1} END {print bad + 0}")" = 0 ]'

# cap of block-local stages: 4 bwt blocks of 64 KB = 256 KB per solid block
python3 -c '
import os, random
r = random.Random(3)
os.makedirs("cap", exist_ok=True)
for i in range(12):
    open("cap/t%02d.txt" % i, "w").write("".join(r.choice("abcd efgh\n") for _ in range(100000)))'
ck "bwt cap: <= 4 blocks per solid block" 'P a cap.parc cap -mbwt:64kb >/dev/null 2>&1 &&
  [ "$(P lb cap.parc | grep -c "^  data.*bwt")" -ge 4 ] &&
  [ -z "$(P lb cap.parc | awk "/^  data/ {sub(\"orig=\", \"\", \$3); if (\$3 + 0 > 262144) print}")" ]'

# determinism: the plan does not depend on the threads (a method without alternatives)
M='-mlzma:1m/$text=ppmd:6/$compressed=storing/$wav=tta'
ck "T1 == T8 (plan and bytes)"  'PARC_THREADS=1 P a d1.parc src "$M" >/dev/null 2>&1 && PARC_THREADS=8 P a d8.parc src "$M" >/dev/null 2>&1 && cmp -s d1.parc d8.parc'
ck "same T twice"               'PARC_THREADS=4 P a d4a.parc src -m4 >/dev/null 2>&1 && PARC_THREADS=4 P a d4b.parc src -m4 >/dev/null 2>&1 && cmp -s d4a.parc d4b.parc'

# updates: whole old blocks are copied, changed ones rewritten
cp rtm3.parc up.parc
before=$(blocks up.parc | sort)
printf 'changed\n' >> src/docs/notes.TXT
ck "a with one changed file"    'P a up.parc src -m3 >/dev/null 2>&1 && xcmp up.parc'
ck "untouched blocks copied"    '[ "$(comm -12 <(echo "$before") <(blocks up.parc | sort) | wc -l)" -ge 3 ]'
printf 'brand new file\n' > src/docs/new.txt
ck "u adds a file"              'P u up.parc src -m3 >/dev/null 2>&1 && xcmp up.parc'
ck "d removes a file"           'P d up.parc src/bin/noise.zzz >/dev/null 2>&1 && rm src/bin/noise.zzz && xcmp up.parc'
ck "d -m recompresses"          'P d up.parc src/one.bin -m2 >/dev/null 2>&1 && rm src/one.bin && xcmp up.parc'
ck "ch -m1 rewrites"            'P ch up.parc -m1 >/dev/null 2>&1 && xcmp up.parc'

# edges
mkdir -p e1 e0; printf 'x' > e1/one; : > e0/zero
ck "1-byte file"                'P a e1.parc e1 -m4 >/dev/null 2>&1 && P t e1.parc | grep -q "All OK"'
ck "0-byte file"                'P a e0.parc e0 -m4 >/dev/null 2>&1 && P t e0.parc | grep -q "All OK"'
ck "bad -s rejected"            '! P a bad.parc src -sq >/dev/null 2>&1 || ! [ -s bad.parc ]'

[ "$fail" -eq 0 ] && { echo "solid: all ok"; cd /; rm -rf -- "${W:?}"; exit 0; }
echo "solid: $fail failures (work dir $W)"; exit 1
