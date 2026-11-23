#!/bin/bash
# tests/dispack.sh — PArc's x86/x86-64 filter (src/parc_dispack.pas, methods dispack/dispack070/exe2):
# round trips on real executables (ELF64 parc, and when they exist the win64/win32/linux32 builds and
# 32-bit system libraries), code without headers (heuristic path), headers glued to random data (every
# byte parsed as an instruction: prefixes, VEX/EVEX, cut instructions), escape-heavy and prefix-heavy
# inputs, text, random, empty and 1-byte inputs, with block sizes that cut code regions; the same
# output for any write sizes; damaged streams (only clean EArcCorrupt); and .parc archives.
# Uso: tests/dispack.sh   (DISPACK_FUZZ=<n> damaged streams per file, default 300;
#                          DISPACK_SAMPLES=<dir> more executables to round-trip)
set -u
ROOT=$(cd "$(dirname "$0")/.." && pwd)
PARC=${PARC_BIN:-$ROOT/build/linux64/parc}
B=$ROOT/build/tests
T=$B/test_filters
W=${DISPACK_WORK:-${TMPDIR:-/tmp}/parc_dispack}
FUZZ=${DISPACK_FUZZ:-300}
mkdir -p "$B/filtunits"
fpc -O3 -Fu"$ROOT/src" -FU"$B/filtunits" -FE"$B" "$ROOT/tests/test_filters.lpr" >/dev/null || { echo "no compila test_filters"; exit 2; }
rm -rf -- "${W:?}"; mkdir -p "$W/c" && cd "$W" || exit 2
fail=0; pass=0
ck() { if eval "$2"; then pass=$((pass+1)); else fail=$((fail+1)); echo "  FAIL $1"; fi; }

# --- inputs
: > empty
printf 'a' > one
printf '\xd6' > esc1
head -c 300 /dev/urandom > small
head -c 2000000 /dev/urandom > rnd
cat "$ROOT"/src/*.pas > text
cp "$PARC" elf64
head -c 4096 elf64 > hdr64
tail -c +4097 elf64 > nohdr64                        # code without a header: heuristic
{ cat hdr64; head -c 3000000 /dev/urandom; } > fake64  # header over random bytes
python3 - <<'EOF'
import random
random.seed(7)
open('d6', 'wb').write(b'\xd6' * 200000)
open('pfx', 'wb').write(bytes(random.choice(b'\x66\x67\xf2\xf3\x2e\x3e\x26\x64\x65\xf0\x40\x48\x4f') for _ in range(100000)))
open('vex', 'wb').write(bytes(random.choice(b'\xc4\xc5\x62\x0f\x38\x3a\x8f\xc0\xff\xe8\xe9\x00') for _ in range(100000)))
EOF
{ cat hdr64; cat d6 pfx vex; } > fakeedge64
FILES="empty one esc1 small rnd text elf64 nohdr64 fake64 fakeedge64"
for x in win64/parc.exe win32/parc.exe linux32/parc; do
  [ -f "$ROOT/build/$x" ] && { n=x_${x//\//_}; cp "$ROOT/build/$x" $n; FILES="$FILES $n";
    head -c 4096 $n > h_$n; { cat h_$n; head -c 1000000 /dev/urandom; cat d6 pfx vex; } > fake_$n; FILES="$FILES fake_$n"; }
done
for x in /usr/lib/i386-linux-gnu/libc.so.6 /usr/lib32/libc.so.6; do
  [ -f "$x" ] && { cp -L "$x" libc32; FILES="$FILES libc32"; break; }
done
if [ -n "${DISPACK_SAMPLES:-}" ]; then
  i=0; for f in "$DISPACK_SAMPLES"/*; do [ -f "$f" ] && { i=$((i+1)); cp "$f" s$i; FILES="$FILES s$i"; }; done
fi
cat elf64 rnd text > mixed; FILES="$FILES mixed"

rt() {   # rt <method> <file>
  local m=$1 f=$2
  "$T" enc "$m" "$f" a.d 65536 || return 1
  "$T" enc "$m" "$f" b.d 0 || return 1
  cmp -s a.d b.d || { echo "    write sizes change the output"; return 1; }
  "$T" dec "$m" a.d a.out && cmp -s "$f" a.out || { echo "    dec"; return 1; }
  return 0
}
echo "== round trips"
for f in $FILES; do
  for m in dispack dispack:b64kb dispack:4000b dispack070:x; do
    ck "rt $m $f" "rt $m $f"
  done
done

echo "== the filter pays on code (xz of filtered < xz of plain)"
if command -v xz >/dev/null; then
  for f in elf64 nohdr64; do
    "$T" enc dispack $f a.d 0
    p=$(xz -6 -c $f | wc -c); q=$(xz -6 -c a.d | wc -c)
    ck "$f: $q < $p" "[ $q -lt $p ]"
  done
  "$T" enc dispack rnd a.d 0
  ck "random grows by < 0.1%" "[ $(stat -c%s a.d) -lt $(( $(stat -c%s rnd) * 1001 / 1000 )) ]"
fi

echo "== damaged streams"
for f in elf64 fake64 fakeedge64 small; do
  "$T" enc dispack:b64kb $f a.d 0
  out=$("$T" fuzz dispack:b64kb a.d $FUZZ 11 2>&1); code=$?
  ck "fuzz $f: $out" "[ $code = 0 ]"
done

echo "== .parc"
cp elf64 text rnd c/
touch -d '2020-01-01' c/*
for m in dispack exe2 dispack+lzma:8m dispack:b1mb+plz:4; do
  rm -rf x d.parc
  if "$PARC" a d.parc c -m$m --no-progress >/dev/null 2>&1 && "$PARC" t d.parc >/dev/null 2>&1; then
    mkdir x; "$PARC" x d.parc -o+ -dpx >/dev/null 2>&1 && diff -r c x/c >/dev/null
    ck "-m$m: a, t, x" "[ $? = 0 ]"
  else
    ck "-m$m: a, t" false
  fi
done
"$PARC" a d.parc c -mdispack --no-progress -o+ >/dev/null 2>&1
cp d.parc bad.parc
python3 -c "
d = bytearray(open('bad.parc','rb').read()); d[len(d)//2] ^= 0x55; open('bad.parc','wb').write(d)"
"$PARC" t bad.parc >/dev/null 2>&1; code=$?
ck "damaged archive: code $code (2)" "[ $code = 2 ]"

echo "== dispack: $pass ok, $fail failures"
[ $fail -eq 0 ]
