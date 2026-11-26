#!/bin/bash
# tests/4x4.sh — the 4x4 stage (src/parc_4x4.pas, stream in FORMATO-PARC.md §6.12): round trips
# with plz/lz4/lzma/ppmd inside and several block sizes on empty/tiny inputs, text, zeros, random
# data, every byte value and a mix with repeated random data (mixed records); the same stream for
# any write sizes and for 1, 4 and 8 threads; random data is stored; damaged streams always give
# data (a damaged record is zeros plus a warning) or a clean error, never a crash or a hang.
# Through PArc: the presets that use 4x4 at 4 threads round-trip, an explicit 4x4 archive is the
# same with 1, 4 and 8 threads, damaged archives fail cleanly.
# Uso: tests/4x4.sh   (FX_FUZZ=<n> damaged streams per file; default 200). Needs ./build.sh first.
set -u
ROOT=$(cd "$(dirname "$0")/.." && pwd)
B=$ROOT/build/tests
T=$B/test_4x4
W=${FX_WORK:-${TMPDIR:-/tmp}/parc_4x4}
FUZZ=${FX_FUZZ:-200}
P=$ROOT/build/linux64/parc
[ -f "$ROOT/build/linux64/units/orep_core.o" ] || { echo "run ./build.sh first"; exit 2; }
mkdir -p "$B/fxunits"
fpc -O2 -Fu"$ROOT/src" -Fu"$ROOT/src/orep" -Fu"$ROOT/src/osrep" -Fu"$ROOT/src/bwt" -Fo"$ROOT/build/linux64/units" \
  -FU"$B/fxunits" -FE"$B" "$ROOT/tests/test_4x4.lpr" >/dev/null || { echo "no compila test_4x4"; exit 2; }
rm -rf -- "${W:?}"; mkdir -p "$W" && cd "$W" || exit 2
fail=0; pass=0
ck() { if eval "$2"; then pass=$((pass+1)); else fail=$((fail+1)); echo "  FAIL $1"; fi; }

: > empty
printf 'a' > one
head -c 100 "$ROOT/docs/USO.md" > s100
cat "$ROOT"/src/*.pas | head -c 3000000 > text
head -c 3000000 /dev/urandom > rnd
head -c 2000000 /dev/zero > zeros
python3 -c "
import sys
sys.stdout.buffer.write(bytes(range(256)) * 3000)" > allbytes
{ head -c 700000 rnd; head -c 600000 text; head -c 700000 rnd; tail -c 400000 text; } > mix
FILES="empty one s100 text rnd zeros allbytes mix"
METHODS="4x4 4x4:plz:1 4x4:b64kb:plz:3 4x4:lz4 4x4:b100kb:lz4:hc 4x4:b1mb:lzma:1mb:normal:16:mc4:lc4
 4x4:b700kb:lzma:fast 4x4:b512kb:i0:lzma:1mb:max 4x4:b300kb:ppmd:4:16mb 4x4:r90:b1mb:lzma:1mb:normal"

rt() {   # rt <method> <file>
  local m=$1 f=$2
  PARC_THREADS=4 "$T" enc "$m" "$f" a.b 65536 >/dev/null || return 1
  PARC_THREADS=4 "$T" enc "$m" "$f" b.b 0 >/dev/null || return 1
  cmp -s a.b b.b || { echo "    write sizes change the output"; return 1; }
  PARC_THREADS=1 "$T" enc "$m" "$f" c.b 65536 >/dev/null || return 1
  PARC_THREADS=8 "$T" enc "$m" "$f" d.b 0 >/dev/null || return 1
  cmp -s a.b c.b && cmp -s a.b d.b || { echo "    threads change the output"; return 1; }
  PARC_THREADS=4 "$T" dec "$m" a.b a.out >/dev/null && cmp -s "$f" a.out || { echo "    dec T4"; return 1; }
  PARC_THREADS=1 "$T" dec "$m" a.b a.out >/dev/null && cmp -s "$f" a.out || { echo "    dec T1"; return 1; }
  return 0
}
for f in $FILES; do
  for m in $METHODS; do
    ck "rt $m $f" "rt '$m' $f"
  done
done

# random data is stored, text is packed, the mix keeps its random parts apart (a mixed record)
m=4x4:b1mb:lzma:1mb:normal:16:mc4:lc4
"$T" enc $m rnd r.b 0 >/dev/null; "$T" enc $m text t.b 0 >/dev/null; "$T" enc $m mix x.b 0 >/dev/null
ck "rnd: stored ($("$T" recs r.b))" "\"$T\" recs r.b | grep -q '^stored 3 packed 0 mixed 0'"
ck "rnd: 3000000 -> $(stat -c %s r.b)" "[ $(stat -c %s r.b) -le 3000020 ]"
ck "text: packed ($("$T" recs t.b))" "\"$T\" recs t.b | grep -q '^stored 0 packed [1-9] mixed 0'"
ck "mix: mixed records ($("$T" recs x.b))" "\"$T\" recs x.b | grep -q 'mixed [1-9]'"
# the repeated random part of the mix is packed with the other copy (both in one block)
{ head -c 400000 rnd; head -c 100000 text; head -c 400000 rnd; } > dup
"$T" enc 4x4:b2mb:lzma:2mb:normal dup u.b 0 >/dev/null
ck "dup: random copy packed ($(stat -c %s u.b))" "[ $(stat -c %s u.b) -lt 450000 ]"
# plz and lz4 inside: no analysis, a random block is stored because it does not shrink
"$T" enc 4x4:plz:1 rnd p.b 0 >/dev/null
ck "rnd plz: stored ($("$T" recs p.b))" "\"$T\" recs p.b | grep -q '^stored [1-9][0-9]* packed 0 mixed 0'"

# damaged streams: data (zeros for a damaged record) or a clean error
for f in text mix allbytes; do
  for m in 4x4:b256kb:plz:1 4x4:b256kb:lzma:1mb:normal 4x4:b128kb:lz4 4x4:b200kb:ppmd:4:8mb; do
    "$T" enc "$m" "$f" z.b 0 >/dev/null
    ck "fuzz $m $f" "timeout 600 \"$T\" fuzz '$m' z.b $FUZZ 1 >/dev/null 2>&1"
  done
done
# a header that is not 4x4's, a truncated stream, a missing end record
"$T" enc 4x4:plz:1 text h.b 0 >/dev/null
printf 'XX\x01' | dd of=hh.b bs=1 count=3 2>/dev/null; tail -c +4 h.b >> hh.b
ck "other header rejected" "\"$T\" dec 4x4:plz:1 hh.b x.out 2>&1 | grep -q 'not a 4x4 stream'"
head -c $(( $(stat -c %s h.b) - 1 )) h.b > ht.b
ck "missing end record rejected" "\"$T\" dec 4x4:plz:1 ht.b x.out 2>&1 | grep -q 'truncated'"

# through PArc
if [ -x "$P" ]; then
  mkdir -p in; cp text rnd mix allbytes one zeros in/; cat "$P" "$P" > in/exe.bin
  for lv in 1 2 3 4 5; do
    rm -f p.parc; PARC_THREADS=4 "$P" a -m$lv p.parc in --no-progress >/dev/null 2>&1 && PARC_THREADS=4 "$P" t p.parc --no-progress >/dev/null 2>&1
    ck "parc -m$lv T4" "[ \$? -eq 0 ]"
  done
  for m in 4x4:b512kb:lzma:1mb:normal 4x4:b256kb:plz:1; do
    rm -f a1.parc a4.parc a8.parc
    for t in 1 4 8; do PARC_THREADS=$t "$P" a -m$m a$t.parc in --no-progress >/dev/null 2>&1; done
    ck "parc -m$m: same archive with 1, 4 and 8 threads" "cmp -s a1.parc a4.parc && cmp -s a1.parc a8.parc"
    rm -rf out; mkdir out; PARC_THREADS=4 "$P" x a4.parc -dpout --no-progress >/dev/null 2>&1
    ck "parc -m$m extract" "cmp -s in/mix out/in/mix && cmp -s in/exe.bin out/in/exe.bin && cmp -s in/rnd out/in/rnd"
  done
  # damaged archives: a clean exit code (1 or 2), never a crash or a hang
  rm -f d.parc; "$P" a -m4x4:b256kb:lzma:1mb:normal d.parc in --no-progress >/dev/null 2>&1
  sz=$(stat -c %s d.parc); bad=0
  for i in $(seq 1 40); do
    cp d.parc dd.parc
    off=$(( (RANDOM * 32768 + RANDOM) % (sz - 200) + 40 ))
    printf "\\x$(printf %02x $((RANDOM % 256)))" | dd of=dd.parc bs=1 seek=$off conv=notrunc 2>/dev/null
    timeout 120 "$P" t dd.parc --no-progress >/dev/null 2>&1; rc=$?
    [ $rc -le 2 ] || { bad=$((bad+1)); echo "    offset $off: exit $rc"; }
  done
  ck "damaged archives fail cleanly" "[ $bad -eq 0 ]"
fi

echo "4x4: $pass ok, $fail failed"
[ $fail -eq 0 ] && rm -rf -- "${W:?}"
[ $fail -eq 0 ]
