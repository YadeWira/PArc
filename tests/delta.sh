#!/bin/bash
# tests/delta.sh — the delta filter (src/parc_delta.pas): round trips on synthetic tables of every
# layout (1/2/4-byte fields, little and big endian, strides 1..64), audio-like data, text, random
# data, empty and tiny inputs and tables cut by block boundaries; the same output for any write
# sizes and with assembler or Pascal (-dPARC_NOASM); and damaged streams (hundreds per file):
# always data or a clean error, never a crash. With build/linux64/parc, also through PArc.
# Uso: tests/delta.sh   (DELTA_FUZZ=<n> damaged streams per file; default 300)
set -u
ROOT=$(cd "$(dirname "$0")/.." && pwd)
B=$ROOT/build/tests
T=$B/test_filters
TN=$B/test_filters_noasm
W=${DELTA_WORK:-${TMPDIR:-/tmp}/parc_delta}
FUZZ=${DELTA_FUZZ:-300}
mkdir -p "$B/filtunits" "$B/filtunits_noasm"
fpc -O3 -Fu"$ROOT/src" -FU"$B/filtunits" -FE"$B" "$ROOT/tests/test_filters.lpr" >/dev/null || { echo "no compila test_filters"; exit 2; }
fpc -O3 -dPARC_NOASM -Fu"$ROOT/src" -FU"$B/filtunits_noasm" -FE"$B" -otest_filters_noasm "$ROOT/tests/test_filters.lpr" >/dev/null || { echo "no compila test_filters (noasm)"; exit 2; }
rm -rf -- "${W:?}"; mkdir -p "$W" && cd "$W" || exit 2
fail=0; pass=0
ck() { if eval "$2"; then pass=$((pass+1)); else fail=$((fail+1)); echo "  FAIL $1"; fi; }

"$T" synth syn || exit 2
: > empty
printf 'a' > one
head -c 300 /dev/urandom > small
cat "$ROOT"/src/*.pas > text
head -c 2000000 /dev/urandom > rnd
head -c 3000000 /dev/zero > zeros
cat syn/tables text syn/audio8 > mix
FILES="empty one small text rnd zeros mix syn/tables syn/wide64 syn/audio16le syn/audio16be syn/audio8 syn/bigtable"

rt() {   # rt <method> <file>
  local m=$1 f=$2
  "$T" enc "$m" "$f" a.d 65536 || return 1
  "$T" enc "$m" "$f" b.d 0 || return 1
  cmp -s a.d b.d || { echo "    write sizes change the output"; return 1; }
  "$TN" enc "$m" "$f" n.d 1000000 || return 1
  cmp -s a.d n.d || { echo "    assembler and Pascal differ"; return 1; }
  "$T" dec "$m" a.d a.out && cmp -s "$f" a.out || { echo "    dec"; return 1; }
  "$TN" dec "$m" a.d n.out && cmp -s "$f" n.out || { echo "    dec noasm"; return 1; }
  return 0
}
for f in $FILES; do
  for m in delta delta:x delta:b1mb delta:300000b; do
    ck "rt $m $f" "rt $m $f"
  done
done

# the synthetic tables must be found (and pay): the filtered stream compresses better
n=$("$T" segs delta syn/tables | wc -l)
ck "tables found ($n segments)" "[ $n -ge 30 ]"
for f in syn/audio16le syn/audio16be syn/audio8 syn/bigtable; do
  n=$("$T" segs delta $f | wc -l)
  ck "$f found ($n segments)" "[ $n -ge 1 ]"
done
n=$("$T" segs delta text | wc -l)
ck "text left alone ($n segments)" "[ $n -le 3 ]"
n=$("$T" segs delta rnd | wc -l)
ck "random left alone ($n segments)" "[ $n -eq 0 ]"
if command -v xz >/dev/null; then
  "$T" enc delta syn/tables t.d 0
  a=$(xz -6 -c syn/tables | wc -c); b=$(xz -6 -c t.d | wc -c)
  ck "tables: xz $a -> $b after delta" "[ $b -lt $((a * 9 / 10)) ]"
fi

# damaged streams
for f in syn/tables syn/audio16le mix text one; do
  "$T" enc delta "$f" z.d 0
  ck "fuzz $f" "\"$T\" fuzz delta z.d $FUZZ 1 >/dev/null"
done
# a stream that claims a 1 GB block and ends: clean error, no huge allocation hang
printf '\001\200\200\200\004\000' > big.d
ck "truncated 1 GB block" "! \"$T\" dec delta big.d x.out >/dev/null 2>&1"
printf '\002\001\000' > ver.d
ck "unknown version rejected" "! \"$T\" dec delta ver.d x.out >/dev/null 2>&1"

# through PArc
P=$ROOT/build/linux64/parc
if [ -x "$P" ]; then
  mkdir -p in; cp syn/tables syn/audio16le text in/
  rm -f a.parc
  "$P" a -mdelta+lzma:fast -mt1 a.parc in --no-progress >/dev/null 2>&1 && "$P" t a.parc --no-progress >/dev/null 2>&1
  ck "parc -mdelta+lzma" "[ \$? -eq 0 ]"
  rm -rf out; mkdir out; "$P" x a.parc -dpout --no-progress >/dev/null 2>&1
  ck "parc extract" "cmp -s in/tables out/in/tables && cmp -s in/text out/in/text"
fi

echo "delta: $pass ok, $fail failed"
[ $fail -eq 0 ]
