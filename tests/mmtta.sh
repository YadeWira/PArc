#!/bin/bash
# tests/mmtta.sh — PArc's own multimedia methods: tta (lossless audio) and mm (decorrelation
# filter), src/parc_tta.pas, parc_mm.pas, parc_mmdet.pas and the C core src/tta/mmtta_core.c.
#  - detection of every container (WAV 8/16/24/32/float, 6 channels, AIFF, BMP 8/24/32, TGA,
#    PGM/PPM 8/16-bit, TIFF) and of headerless PCM;
#  - round trips at every tta level and mm detection level, with explicit c/w/o parameters, on
#    synthetic files, empty / 1-byte / random / text inputs and (if present) corpus copies;
#  - the same stream for any write sizes, and with the C core built without SIMD;
#  - damaged streams (hundreds per file): data or a clean error, never a crash;
#  - through PArc (build/linux64/parc): the wav/bmp presets and extraction.
# Uso: tests/mmtta.sh   (MMTTA_FUZZ=<n> damaged streams per file, default 300)
set -u
ROOT=$(cd "$(dirname "$0")/.." && pwd)
B=$ROOT/build/tests/mmtta
W=${MMTTA_WORK:-${TMPDIR:-/tmp}/parc_mmtta}
FUZZ=${MMTTA_FUZZ:-300}
CF="-O3 -fwrapv -fno-builtin -ffreestanding -fno-stack-protector -fno-tree-loop-distribute-patterns -w -fno-pie"
mkdir -p "$B/u" "$B/u_nosimd"
gcc $CF -c "$ROOT/src/tta/mmtta_core.c" -o "$B/u/mmtta_core.o" || exit 2
gcc $CF -DTTAC_NO_SIMD -c "$ROOT/src/tta/mmtta_core.c" -o "$B/u_nosimd/mmtta_core.o" || exit 2
fpc -O3 -Fu"$ROOT/src" -Fo"$B/u" -FU"$B/u" -FE"$B" "$ROOT/tests/test_mmtta.lpr" >"$B/build.log" 2>&1 ||
  { echo "no compila test_mmtta ($B/build.log)"; exit 2; }
fpc -O3 -Fu"$ROOT/src" -Fo"$B/u_nosimd" -FU"$B/u_nosimd" -FE"$B" -otest_mmtta_nosimd "$ROOT/tests/test_mmtta.lpr" >"$B/build2.log" 2>&1 ||
  { echo "no compila test_mmtta sin SIMD ($B/build2.log)"; exit 2; }
T=$B/test_mmtta
TN=$B/test_mmtta_nosimd
rm -rf -- "${W:?}"; mkdir -p "$W" && cd "$W" || exit 2
fail=0; pass=0
ck() { if eval "$2"; then pass=$((pass+1)); else fail=$((fail+1)); echo "  FAIL $1"; fi; }

"$T" synth syn >/dev/null || exit 2
: > empty
printf 'a' > one
head -c 300 /dev/urandom > small
cat "$ROOT"/src/*.pas > text
head -c 1500000 /dev/urandom > rnd
head -c 2000000 /dev/zero > zeros
cat syn/w16s.wav syn/b24.bmp text > mix
C=/mnt/OSR_D3/fileFormatSamples/fileFormatSamples
CORPUS=""
if [ -d "$C/audio/wav" ]; then
  mkdir -p corpus
  for f in "$C/audio/wav/drumloop.wav" "$C/audio/wav/END.WAV" "$C/audio/wav/CHCENTER.WAV" "$C/image/bmp/"*.bmp; do
    [ -f "$f" ] || continue
    s=$(stat -c %s "$f"); [ "$s" -lt 3000000 ] || continue
    n=corpus/$(basename "$f" | tr -c 'A-Za-z0-9._\n' '_'); cp "$f" "$n"; CORPUS="$CORPUS $n"
  done
fi

# detection
det() { "$T" detect "$1" | cut -d' ' -f1-4; }
ck "w16s.wav header" "[ \"\$(det syn/w16s.wav)\" = 'header kind=0 chan=2 bits=16' ]"
ck "w24s.wav header" "[ \"\$(det syn/w24s.wav)\" = 'header kind=0 chan=2 bits=24' ]"
ck "w16c6.wav header" "[ \"\$(det syn/w16c6.wav)\" = 'header kind=0 chan=6 bits=16' ]"
ck "a16s.aif header" "[ \"\$(det syn/a16s.aif)\" = 'header kind=0 chan=2 bits=16' ]"
ck "b24.bmp header" "[ \"\$(det syn/b24.bmp)\" = 'header kind=1 chan=3 bits=8' ]"
ck "t32.tga header" "[ \"\$(det syn/t32.tga)\" = 'header kind=1 chan=4 bits=8' ]"
ck "p6w.ppm header" "[ \"\$(det syn/p6w.ppm)\" = 'header kind=1 chan=3 bits=16' ]"
ck "i24.tif header" "[ \"\$(det syn/i24.tif)\" = 'header kind=1 chan=3 bits=8' ]"
ck "raw16s.pcm statistics" "[ \"\$(det syn/raw16s.pcm)\" = 'stats chan=2 bits=16 flags=0' ]"
ck "random: nothing" "[ \"\$(det rnd)\" = 'none' ]"
ck "text: nothing" "[ \"\$(det text)\" = 'none' ]"

rt() {   # rt <method> <file>: same stream for any write sizes and without SIMD; decodes back
  local m=$1 f=$2
  "$T" enc "$m" "$f" a.d 65536 >/dev/null || return 1
  "$T" enc "$m" "$f" b.d 0 >/dev/null || return 1
  cmp -s a.d b.d || { echo "    write sizes change the output"; return 1; }
  "$TN" enc "$m" "$f" n.d 1000000 >/dev/null || return 1
  cmp -s a.d n.d || { echo "    SIMD and plain C differ"; return 1; }
  "$T" dec "$m" a.d a.out >/dev/null && cmp -s "$f" a.out || { echo "    dec"; return 1; }
  "$TN" dec "$m" a.d n.out >/dev/null && cmp -s "$f" n.out || { echo "    dec nosimd"; return 1; }
  return 0
}
FILES="empty one small text rnd zeros mix $(ls syn/* | tr '\n' ' ') $CORPUS"
for f in $FILES; do
  for m in tta tta:m1 tta:m2 tta:m9 mm mm:d1; do
    ck "rt $m $f" "rt $m $f"
  done
done
for c in "tta:2*16:o44:w16s" "tta:c2:w16:s:raw16s" "tta:1*8:w8m" "tta:1*32f:wf32s" "tta:m0:w16s" "tta:r1:w16s" \
         "mm:2*16:raw16s" "mm:s:b24" "mm:c3:w8:o54:b24" "mm:d9:raw16s"; do
  f=${c##*:}; m=${c%:*}
  g=$(ls syn/$f.* 2>/dev/null | head -1)
  ck "rt $m $g" "rt $m $g"
done

# coded, not stored, where it pays: tta beats xz on audio, mm helps on images
if command -v xz >/dev/null; then
  for f in syn/w16s.wav syn/a16s.aif syn/raw16s.pcm; do
    "$T" enc tta "$f" t.d 0 >/dev/null
    a=$(xz -6 -c "$f" | wc -c); b=$(stat -c %s t.d)
    ck "$f: tta $b < xz $a" "[ $b -lt $a ]"
  done
  for f in syn/b24.bmp syn/t24.tga syn/p6.ppm syn/i24.tif; do
    "$T" enc mm "$f" t.d 0 >/dev/null
    a=$(xz -6 -c "$f" | wc -c); b=$(xz -6 -c t.d | wc -c)
    ck "$f: xz $a -> $b after mm" "[ $b -lt $a ]"
  done
fi
"$T" enc tta rnd t.d 0 >/dev/null
ck "random: tta stores (+$(( $(stat -c %s t.d) - 1500000 )))" "[ \$(stat -c %s t.d) -le 1500016 ]"

# damaged streams
for c in tta:syn/w16s.wav tta:m1:syn/w8m.wav tta:syn/w24s.wav tta:syn/w16c6.wav mm:syn/b24.bmp mm:syn/w16s.wav \
         mm:syn/raw16s.pcm tta:one mm:one; do
  f=${c##*:}; m=${c%:*}
  "$T" enc "$m" "$f" z.d 0 >/dev/null
  ck "fuzz $m $f" "\"$T\" fuzz $m z.d $FUZZ 1 >/dev/null"
done
printf '\002\000' > ver.d
ck "tta: unknown version rejected" "! \"$T\" dec tta ver.d x.out >/dev/null 2>&1"
ck "mm: unknown version rejected" "! \"$T\" dec mm ver.d x.out >/dev/null 2>&1"
ck "tta: invalid parameter rejected" "! \"$T\" enc tta:q syn/w16s.wav x.d 0 >/dev/null 2>&1"
ck "mm: reorder rejected" "! \"$T\" enc mm:r1 syn/w16s.wav x.d 0 >/dev/null 2>&1"

# through PArc
P=$ROOT/build/linux64/parc
if [ -x "$P" ]; then
  mkdir -p in; cp syn/w16s.wav syn/w8m.wav syn/a16s.aif syn/b24.bmp syn/t32.tga syn/p6.ppm in/
  for m in 1 2 3 5 9 2x ex1; do
    for t in 1 4; do
      rm -f a.parc; rm -rf out
      PARC_THREADS=$t "$P" a -m$m -mt$t a.parc in --no-progress >/dev/null 2>&1 &&
        PARC_THREADS=$t "$P" t -mt$t a.parc --no-progress >/dev/null 2>&1
      ck "parc -m$m -mt$t" "[ \$? -eq 0 ]"
    done
  done
  "$P" lt a.parc 2>/dev/null | grep -q 'mm+' ; ck "ex1 uses mm" "[ \$? -eq 0 ]"
  rm -f a.parc; "$P" a -m5 a.parc in --no-progress >/dev/null 2>&1
  "$P" lt a.parc 2>/dev/null | grep -q ' tta' ; ck "-m5 uses tta" "[ \$? -eq 0 ]"
  mkdir out; "$P" x a.parc -dpout --no-progress >/dev/null 2>&1
  ck "parc extract" "cmp -s in/w16s.wav out/in/w16s.wav && cmp -s in/b24.bmp out/in/b24.bmp"
fi

echo "mmtta: $pass ok, $fail failed"
[ $fail -eq 0 ]
