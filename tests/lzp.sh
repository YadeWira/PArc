#!/bin/bash
# tests/lzp.sh — the lzp filter (src/parc_lzp.pas): round trips with the presets' parameters and
# edge ones (tiny blocks, small tables, minimum lengths, barrier), on empty/tiny inputs, text,
# repetitive text, zeros, random data and data where every byte value is frequent (escapes
# everywhere); the same output for any write sizes; a stream with other parameters is rejected;
# damaged streams (hundreds per file): always data or a clean error, never a crash.
# Uso: tests/lzp.sh   (LZP_FUZZ=<n> damaged streams per file; default 300)
set -u
ROOT=$(cd "$(dirname "$0")/.." && pwd)
B=$ROOT/build/tests
T=$B/test_filters
W=${LZP_WORK:-${TMPDIR:-/tmp}/parc_lzp}
FUZZ=${LZP_FUZZ:-300}
mkdir -p "$B/filtunits"
fpc -O3 -Fu"$ROOT/src" -FU"$B/filtunits" -FE"$B" "$ROOT/tests/test_filters.lpr" >/dev/null || { echo "no compila test_filters"; exit 2; }
rm -rf -- "${W:?}"; mkdir -p "$W" && cd "$W" || exit 2
fail=0; pass=0
ck() { if eval "$2"; then pass=$((pass+1)); else fail=$((fail+1)); echo "  FAIL $1"; fi; }

: > empty
printf 'a' > one
printf 'abcdefghijklmnopq' > s17
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
sys.stdout.buffer.write(bytes(out))" > allbytes
{ head -c 300000 rnd; cat text; head -c 100000 rnd; head -c 900000 text; } > mix
FILES="empty one s17 text rep3 rnd zeros allbytes mix"
METHODS="lzp lzp:64m:32:h20:92% lzp:64m:65:d1m:s16:h20:90% lzp:80m:105:d1m:s32:h22:92% lzp:160m:145:d1m:s32:h23:90% lzp:b64kb:8:h10 lzp:b1mb:32:d64kb:s12:h16 lzp:300000b:40:h12:50%"

rt() {   # rt <method> <file>
  local m=$1 f=$2
  "$T" enc "$m" "$f" a.l 65536 || return 1
  "$T" enc "$m" "$f" b.l 0 || return 1
  cmp -s a.l b.l || { echo "    write sizes change the output"; return 1; }
  "$T" dec "$m" a.l a.out && cmp -s "$f" a.out || { echo "    dec"; return 1; }
  return 0
}
for f in $FILES; do
  for m in $METHODS; do
    ck "rt $m $f" "rt '$m' $f"
  done
done

# repeats are removed
"$T" enc lzp:64m:32:h20 rep3 r.l 0
a=$(stat -c %s rep3); b=$(stat -c %s r.l)
ck "rep3: $a -> $b" "[ $b -lt $((a * 45 / 100)) ]"
# a stream decoded with other parameters is rejected
"$T" enc lzp:64m:32:h20 text t.l 0
ck "other parameters rejected" "! \"$T\" dec lzp:64m:33:h20 t.l x.out >/dev/null 2>&1"
ck "other hash rejected" "! \"$T\" dec lzp:64m:32:h21 t.l x.out >/dev/null 2>&1"

# damaged streams
for f in text rep3 allbytes mix; do
  for m in lzp:64m:32:h20 lzp:b64kb:8:h10; do
    "$T" enc "$m" "$f" z.l 0
    ck "fuzz $m $f" "\"$T\" fuzz '$m' z.l $FUZZ 1 >/dev/null"
  done
done

# through PArc
P=$ROOT/build/linux64/parc
if [ -x "$P" ]; then
  mkdir -p in; cp text rep3 allbytes in/
  rm -f a.parc
  "$P" a -mlzp:64m:32:h20+ppmd:8:64m -mt1 a.parc in --no-progress >/dev/null 2>&1 && "$P" t a.parc --no-progress >/dev/null 2>&1
  ck "parc -mlzp+ppmd" "[ \$? -eq 0 ]"
  rm -rf out; mkdir out; "$P" x a.parc -dpout --no-progress >/dev/null 2>&1
  ck "parc extract" "cmp -s in/rep3 out/in/rep3 && cmp -s in/allbytes out/in/allbytes"
fi

echo "lzp: $pass ok, $fail failed"
[ $fail -eq 0 ]
