#!/bin/bash
# tests/lzma_enc.sh — the LZMA encoder (src/parc_lzmaenc.pas), above all the own ht4 row finder
# (every row shape: 32/64-byte rows with 32-bit positions, 16/32-byte rows with 24-bit
# positions, 4/6/8-bit tags), the method-string parser and the :fast parser thresholds.
#  - tests/test_lzmaenc (full): round trips through PArc's decoder, LzmaEncodeMem, invalid
#    parameters, the thread budget and multi-thread == one thread (bt4 and ht4, also with
#    position normalization);
#  - the streams it dumps decode with liblzma (Python lzma, if present);
#  - assembler and Pascal (-dPARC_NOASM) encoders write the same bytes;
#  - through PArc: round trips on empty/1-byte/random/zeros/text/mixed inputs with every ht4
#    shape (fast and normal, mc 1..14, small and large dictionaries, h<size>, 4x4 blocks),
#    the same archive twice, the same archive with 1 and 4 threads (ht4 and bt4 give the same
#    stream with any number of threads), and damaged archives fail cleanly (no crash).
# Uso: tests/lzma_enc.sh [parc]
set -u
ROOT=$(cd "$(dirname "$0")/.." && pwd)
PARC=${1:-$ROOT/build/linux64/parc}
case "$PARC" in /*) ;; *) PARC=$PWD/$PARC ;; esac
B=$ROOT/build/tests
W=${LZMA_ENC_WORK:-${TMPDIR:-/tmp}/parc_lzma_enc}
mkdir -p "$B/lzunits" "$B/lzunits_noasm"
fpc -O2 -Fu"$ROOT/src" -Fu"$ROOT/src/orep" -Fu"$ROOT/src/osrep" -Fu"$ROOT/src/bwt" -FU"$B/lzunits" -FE"$B" "$ROOT/tests/test_lzmaenc.lpr" >/dev/null \
  || { echo "no compila test_lzmaenc"; exit 2; }
fpc -O2 -dPARC_NOASM -Fu"$ROOT/src" -Fu"$ROOT/src/orep" -Fu"$ROOT/src/osrep" -Fu"$ROOT/src/bwt" -FU"$B/lzunits_noasm" -FE"$B" -otest_lzmaenc_noasm \
  "$ROOT/tests/test_lzmaenc.lpr" >/dev/null || { echo "no compila test_lzmaenc (noasm)"; exit 2; }
rm -rf -- "${W:?}"; mkdir -p "$W" && cd "$W" || exit 2
fail=0; pass=0
ck() { if eval "$2"; then pass=$((pass+1)); else fail=$((fail+1)); echo "  FAIL $1"; fi; }

echo "== test_lzmaenc"
"$B/test_lzmaenc" -dump d1 > t1.log 2>&1
ck "test_lzmaenc ($(tail -1 t1.log))" "grep -q ' 0 fallos' t1.log"
grep FAIL t1.log | head
"$B/test_lzmaenc_noasm" -quick -dump d2 > t2.log 2>&1
"$B/test_lzmaenc" -quick -dump d3 > t3.log 2>&1
ndiff=0; for f in d3/*.lz; do cmp -s "$f" "d2/${f#d3/}" || ndiff=$((ndiff+1)); done
ck "noasm == asm (quick set, $(ls d3/*.lz | wc -l) streams)" "[ $ndiff -eq 0 ] && grep -q ' 0 fallos' t2.log"
if python3 -c 'import lzma' 2>/dev/null; then
  cat > lib.py <<'EOF'
import lzma, sys, os
d = sys.argv[1]; ok = bad = 0
for line in open(os.path.join(d, 'manifest.txt')):
    p = line.split()
    if len(p) < 6: continue
    f, orig, dic, lc, lp, pb = p[0], p[1], int(p[2]), int(p[3]), int(p[4]), int(p[5])
    if lc + lp > 4: continue
    try:
        out = lzma.decompress(open(os.path.join(d, f), 'rb').read(), lzma.FORMAT_RAW,
            filters=[{'id': lzma.FILTER_LZMA1, 'dict_size': max(dic, 4096), 'lc': lc, 'lp': lp, 'pb': pb}])
        if os.path.exists(orig) and out != open(orig, 'rb').read(): bad += 1; print('MISMATCH', f)
        else: ok += 1
    except Exception as e:
        bad += 1; print('FAIL', f, e)
print(ok, bad)
sys.exit(1 if bad else 0)
EOF
  ck "liblzma decodes the dumped streams ($(python3 -I lib.py d1 | tail -1))" "python3 -I lib.py d1 >/dev/null"
fi
rm -rf d1 d2 d3

echo "== through PArc"
: > empty
printf 'a' > one
head -c 3000000 /dev/urandom > rnd
head -c 4000000 /dev/zero > zeros
cat "$ROOT"/src/*.pas "$ROOT"/docs/*.md > text
{ head -c 1000000 /dev/urandom; cat "$ROOT"/src/*.pas; head -c 2000000 /dev/zero; cat "$ROOT"/build/linux64/parc; cat "$ROOT"/src/*.pas; } > mix
METHODS="lzma:8mb:fast lzma:8mb:fast:mc1 lzma:8mb:fast:mc9 lzma:8mb:fastest lzma:8mb:normal lzma:8mb:normal:mc2 \
lzma:8mb:normal:mc6 lzma:8mb:normal:mc8:fb273 lzma:8mb:normal:mc14 lzma:64mb:normal:mc4 lzma:64mb:normal:mc6 \
lzma:64mb:normal:mc12 lzma:64mb:fast:32:mc6:lc4 lzma:1mb:normal:mc4 lzma:256kb:normal:mc7 lzma:8mb:normal:h64kb \
lzma:8mb:fast:h1mb lzma:8mb:max lzma:8mb:normal:hc4 4x4:lzma:1mb:normal:16:mc4:lc4 4x4:lzma:2mb:normal:20:mc6:lc5:pb1"
for f in empty one rnd zeros text mix; do
  for m in $METHODS; do
    rm -f a.parc b.parc
    "$PARC" a -m"$m" -mt1 -s- a.parc "$f" --no-progress >/dev/null 2>&1
    "$PARC" a -m"$m" -mt1 -s- b.parc "$f" --no-progress >/dev/null 2>&1
    ck "$m $f: t" "\"$PARC\" t a.parc --no-progress 2>/dev/null | grep -q 'All OK'"
    ck "$m $f: same archive twice" "cmp -s a.parc b.parc"
  done
done
# one stream (no 4x4): ht4 :normal and bt4 give the same bytes with 1 and 4 threads
for m in lzma:8mb:normal lzma:8mb:normal:mc4 lzma:64mb:normal:mc12 lzma:8mb:max; do
  rm -f a.parc b.parc
  "$PARC" a -m"$m" -mt1 -s- a.parc mix --no-progress >/dev/null 2>&1
  "$PARC" a -m"$m" -mt4 -s- b.parc mix --no-progress >/dev/null 2>&1
  ck "$m: 1 thread == 4 threads" "cmp -s a.parc b.parc"
done
# damaged archives: an error or wrong data is reported, never a crash
"$PARC" a -mlzma:8mb:normal -mt1 -s- good.parc mix --no-progress >/dev/null 2>&1
sz=$(stat -c %s good.parc)
crash=0; detected=0
for i in $(seq 1 60); do
  cp good.parc bad.parc
  off=$(( (RANDOM * 32768 + RANDOM) % (sz - 200) + 100 ))
  printf "\\x$(printf %02x $((RANDOM % 256)))" | dd of=bad.parc bs=1 seek=$off conv=notrunc 2>/dev/null
  "$PARC" t bad.parc --no-progress >/dev/null 2>&1; rc=$?
  [ $rc -ge 128 ] && crash=$((crash+1))
  [ $rc -ne 0 ] && detected=$((detected+1))
done
ck "damaged archives: no crash ($detected/60 detected)" "[ $crash -eq 0 ]"

echo "== $pass ok, $fail fallos"
[ $fail -eq 0 ]
