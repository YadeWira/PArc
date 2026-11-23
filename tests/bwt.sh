#!/bin/bash
# tests/bwt.sh — the bwt codec (src/parc_bwt.pas + src/bwt/): round trips with the presets' and
# edge parameters (every level and coder, LZP on/off, tiny and odd block sizes) on empty/tiny
# inputs, text, repeats, zeros, random data, two-symbol and every-byte-value data; the same
# output for any write sizes; a stream with other parameters is rejected; damaged streams
# (hundreds per file): always data or a clean error, never a crash or a hang. Through PArc:
# the grzip alias is stored as bwt, archives are the same with 1 and 4 threads, the text and
# bitmap presets round-trip, damaged archives fail cleanly.
# Uso: tests/bwt.sh   (BWT_FUZZ=<n> damaged streams per file; default 300;
#      PARC_OLD=<parc 0.0.5> also checks that its grzip archives are refused cleanly)
set -u
ROOT=$(cd "$(dirname "$0")/.." && pwd)
B=$ROOT/build/tests
T=$B/test_filters
W=${BWT_WORK:-${TMPDIR:-/tmp}/parc_bwt}
FUZZ=${BWT_FUZZ:-300}
P=$ROOT/build/linux64/parc
mkdir -p "$B/filtunits"
gcc -O3 -fno-builtin -ffreestanding -fno-stack-protector -fno-tree-loop-distribute-patterns -fno-pie -w \
  -c "$ROOT/src/bwt/bwt_core.c" -o "$B/filtunits/bwt_core.o" || { echo "no compila bwt_core.c"; exit 2; }
fpc -O3 -Fu"$ROOT/src" -Fo"$B/filtunits" -FU"$B/filtunits" -FE"$B" "$ROOT/tests/test_filters.lpr" >/dev/null ||
  { echo "no compila test_filters"; exit 2; }
rm -rf -- "${W:?}"; mkdir -p "$W" && cd "$W" || exit 2
fail=0; pass=0
ck() { if eval "$2"; then pass=$((pass+1)); else fail=$((fail+1)); echo "  FAIL $1"; fi; }

: > empty
printf 'a' > one
head -c 63 "$ROOT/docs/USO.md" > s63
head -c 64 "$ROOT/docs/USO.md" > s64
head -c 65 "$ROOT/docs/USO.md" > s65
cat "$ROOT"/src/*.pas > text
cat text text text > rep3
head -c 2000000 /dev/urandom > rnd
head -c 3000000 /dev/zero > zeros
python3 -c "
import sys, random
random.seed(5)
b = bytes(range(256)) * 4
out = bytearray()
for i in range(3000):
    out += b[random.randrange(0, 512):][:random.randrange(40, 600)]
sys.stdout.buffer.write(bytes(out))
open('twosym', 'wb').write(bytes(random.choice(b'ab') for _ in range(300000)))
open('runs', 'wb').write(b''.join(bytes([random.randrange(4)]) * random.randrange(1, 5000) for _ in range(3000)))" > allbytes
{ head -c 300000 rnd; cat text; head -c 100000 rnd; head -c 900000 text; } > mix
FILES="empty one s63 s64 s65 text rep3 rnd zeros allbytes twosym runs mix"
METHODS="bwt bwt:m2 bwt:m3 bwt:m4 bwt:l bwt:m4:8m:32:h18 bwt:m1:h20 bwt:m3:8m:l bwt:m1:l2048 bwt:m4:l
 bwt:b64kb:m1 bwt:b1mb:m2:l64:h12 bwt:m1:e1 bwt:m2:e2 bwt:300000b:m1:l bwt:100b:m2"

rt() {   # rt <method> <file>
  local m=$1 f=$2
  "$T" enc "$m" "$f" a.b 65536 || return 1
  "$T" enc "$m" "$f" b.b 0 || return 1
  cmp -s a.b b.b || { echo "    write sizes change the output"; return 1; }
  "$T" dec "$m" a.b a.out && cmp -s "$f" a.out || { echo "    dec"; return 1; }
  return 0
}
for f in $FILES; do
  for m in $METHODS; do
    ck "rt $m $f" "rt '$m' $f"
  done
done

# text compresses, the adaptive coder is smaller than the static one, random data stays its size
"$T" enc bwt:m1 text t1.b 0; "$T" enc bwt:m2 text t2.b 0; "$T" enc bwt rnd r.b 0
a=$(stat -c %s text); b1=$(stat -c %s t1.b); b2=$(stat -c %s t2.b); r=$(stat -c %s r.b)
ck "text: $a -> m1 $b1, m2 $b2" "[ $b1 -lt $((a / 4)) ] && [ $b1 -lt $b2 ]"
ck "rnd: 2000000 -> $r" "[ $r -le 2000100 ]"
# a stream decoded with other parameters is rejected
ck "other LZP minimum rejected" "! \"$T\" dec bwt:m1:l33 t1.b x.out >/dev/null 2>&1"
ck "other hash rejected" "! \"$T\" dec bwt:m1:h19 t1.b x.out >/dev/null 2>&1"
ck "no LZP rejected" "! \"$T\" dec bwt:m1:l t1.b x.out >/dev/null 2>&1"
ck "smaller block rejected" "! \"$T\" dec bwt:1mb t1.b x.out >/dev/null 2>&1"

# damaged streams
for f in text allbytes mix runs; do
  for m in bwt:m1 bwt:m2:l bwt:b64kb:m4:l64:h12; do
    "$T" enc "$m" "$f" z.b 0
    ck "fuzz $m $f" "timeout 600 \"$T\" fuzz '$m' z.b $FUZZ 1 >/dev/null"
  done
done

# through PArc
if [ -x "$P" ]; then
  mkdir -p in; cp text rep3 allbytes mix runs one in/; head -c 9000000 rep3 > in/big.txt
  for m in bwt:m1 grzip:m4:8m:32:h18:a bwt:b1mb:m2; do
    rm -f a.parc
    PARC_THREADS=4 "$P" a -m"$m" a.parc in --no-progress >/dev/null 2>&1 && PARC_THREADS=4 "$P" t a.parc --no-progress >/dev/null 2>&1
    ck "parc -m$m" "[ \$? -eq 0 ]"
    rm -f a1.parc
    PARC_THREADS=1 "$P" a -m"$m" a1.parc in --no-progress >/dev/null 2>&1
    ck "parc -m$m: same archive with 1 and 4 threads" "cmp -s a.parc a1.parc"
  done
  ck "grzip is stored as bwt" "\"$P\" lb a.parc 2>/dev/null | grep -q 'bwt:1mb:m2' && ! \"$P\" lb a.parc 2>/dev/null | grep -q grzip"
  rm -f g.parc; "$P" a -mgrzip:m4:8m:32:h18:a g.parc in --no-progress >/dev/null 2>&1
  ck "grzip alias stored as bwt:8mb:m4:l32:h18" "\"$P\" lb g.parc 2>/dev/null | grep -q 'bwt:8mb:m4:l32:h18'"
  rm -rf out; mkdir out; "$P" x a.parc -dpout --no-progress >/dev/null 2>&1
  ck "parc extract" "cmp -s in/rep3 out/in/rep3 && cmp -s in/allbytes out/in/allbytes && cmp -s in/big.txt out/in/big.txt"
  for lv in 2 3 4; do
    for t in 1 4; do
      rm -f p.parc; PARC_THREADS=$t "$P" a -m$lv p.parc in --no-progress >/dev/null 2>&1 && PARC_THREADS=$t "$P" t p.parc --no-progress >/dev/null 2>&1
      ck "parc -m$lv (text preset) T$t" "[ \$? -eq 0 ]"
    done
  done
  rm -f p.parc; "$P" a -mmm+bwt:m1:l2048:a p.parc in --no-progress >/dev/null 2>&1 && "$P" t p.parc --no-progress >/dev/null 2>&1
  ck "parc -mmm+bwt (bmp preset)" "[ \$? -eq 0 ]"
  # damaged archives: a clean error (exit code 1 or 2), never a crash or a hang
  rm -f d.parc; "$P" a -mbwt:b256kb:m1 d.parc in --no-progress >/dev/null 2>&1
  sz=$(stat -c %s d.parc); bad=0
  for i in $(seq 1 40); do
    cp d.parc dd.parc
    off=$(( (RANDOM * 32768 + RANDOM) % (sz - 200) + 40 ))
    printf "\\x$(printf %02x $((RANDOM % 256)))" | dd of=dd.parc bs=1 seek=$off conv=notrunc 2>/dev/null
    timeout 120 "$P" t dd.parc --no-progress >/dev/null 2>&1; rc=$?
    [ $rc -le 2 ] || { bad=$((bad+1)); echo "    offset $off: exit $rc"; }
  done
  ck "damaged archives fail cleanly" "[ $bad -eq 0 ]"
  if [ -n "${PARC_OLD:-}" ] && [ -x "$PARC_OLD" ]; then
    rm -f o.parc; "$PARC_OLD" a -mgrzip:m1 o.parc in/text --no-progress >/dev/null 2>&1
    "$P" t o.parc --no-progress > o.txt 2>&1; rc=$?
    ck "old grzip archive refused (exit $rc)" "[ $rc -eq 3 ] && grep -q 'no longer supported' o.txt"
  fi
fi

echo "bwt: $pass ok, $fail failed"
[ $fail -eq 0 ]
