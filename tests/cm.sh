#!/bin/bash
# tests/cm.sh — context-mixing codec (cm: src/parc_cm.pas + src/cm/pcm_core.c), -mxx (CM max)
# and -mx (fast-decode max).
#  - test_cm (the stage alone): round trips of empty/1-byte/tiny/text/random/zero/mixed inputs and
#    sizes around the 64 KB block, the 1 MB small-table limit and the 16 MB known-size limit, at
#    levels 1, 6 and 9; the same bytes for any write sizes; SSE2 == portable C
#    (-DPCM_NO_SIMD); damaged streams (CM_FUZZ per file, default 300): data or a clean
#    EArcCorrupt, never a crash or another exception.
#  - through PArc: -mcm, -mxx/-mx round trips and ratios, PARC_THREADS=1 == 4, damaged archive
#    (exit code 2), encrypted archive.
# Uso: tests/cm.sh   (needs build/linux64 from ./build.sh)
set -u
ROOT=$(cd "$(dirname "$0")/.." && pwd)
PARC=${PARC_BIN:-$ROOT/build/linux64/parc}
W=${CM_WORK:-${TMPDIR:-/tmp}/parc_cm_test}
FUZZ=${CM_FUZZ:-300}
B=$ROOT/build/tests
rm -rf -- "${W:?}"; mkdir -p "$W/corpus" && cd "$W" || exit 2
fail=0
check() { if eval "$2"; then printf '  ok    %s\n' "$1"; else printf '  FAIL %s\n' "$1"; fail=$((fail+1)); fi; }

# ---- the stage alone (test_cm), native SSE2 core and portable C core ----
PCMFLAGS="-O3 -funroll-loops -fno-builtin -ffreestanding -fno-stack-protector -fno-tree-loop-distribute-patterns -fno-pie -w"
mkdir -p "$B/cmunits" "$B/cmunits_c"
gcc $PCMFLAGS -c "$ROOT/src/cm/pcm_core.c" -o "$B/cmunits/pcm_core.o" &&
gcc $PCMFLAGS -DPCM_NO_SIMD -c "$ROOT/src/cm/pcm_core.c" -o "$B/cmunits_c/pcm_core.o" &&
fpc -O3 -Fu"$ROOT/src" -Fo"$B/cmunits" -FU"$B/cmunits" -FE"$B" "$ROOT/tests/test_cm.lpr" >/dev/null &&
fpc -O3 -Fu"$ROOT/src" -Fo"$B/cmunits_c" -FU"$B/cmunits_c" -FE"$B" -otest_cm_c "$ROOT/tests/test_cm.lpr" >/dev/null ||
  { echo "no compila test_cm"; exit 2; }
T=$B/test_cm; TC=$B/test_cm_c
mkdir -p st && cd st || exit 2
: > empty
printf 'a' > one
head -c 300 /dev/urandom > small
cat "$ROOT"/src/*.pas | head -c 1000000 > text
head -c 400000 /dev/urandom > rnd
head -c 1000000 /dev/zero > zeros
{ head -c 100000 rnd; head -c 500000 text; head -c 200000 zeros; head -c 150000 "$PARC"; head -c 70000 rnd; } > mix
for n in 65535 65536 65537 1048575 1048576 1048577; do head -c $n mix > s$n; done
{ head -c 16700000 /dev/urandom; head -c 77216 text; } > big16   # raw blocks: fast
head -c 16777215 big16 > b16m1; { cat big16; printf 'xy'; } > b16p2
rt() {   # rt <level> <file>
  local l=$1 f=$2
  "$T" enc $l "$f" a.c 65536 || return 1
  "$T" enc $l "$f" b.c 0 || return 1
  cmp -s a.c b.c || { echo "    write sizes change the output"; return 1; }
  "$T" dec a.c a.out && cmp -s "$f" a.out || { echo "    dec"; return 1; }
  return 0
}
for f in empty one small text rnd zeros mix s65535 s65536 s65537 s1048575 s1048576 s1048577; do
  check "stage cm:6 $f" "rt 6 $f"
done
for f in one text mix; do
  check "stage cm:1 $f" "rt 1 $f"
done
check "stage cm:9 mix" "rt 9 mix"
for f in b16m1 big16 b16p2; do
  check "stage cm:2 $f (16 MB limit)" "rt 2 $f"
done
check "random stays within 0.1%" '"$T" enc 6 rnd r.c 0 && [ $(stat -c%s r.c) -le $((400000 + 400)) ]'
check "SSE2 == portable C (mix)" '"$T" enc 6 mix a.c 0 && "$TC" enc 6 mix c.c 0 && cmp -s a.c c.c'
check "SSE2 == portable C (text)" '"$T" enc 3 text a.c 0 && "$TC" enc 3 text c.c 0 && cmp -s a.c c.c'
check "portable C reads SSE2" '"$TC" dec a.c c.out && cmp -s text c.out'
head -c 60000 text > ftext; head -c 150000 mix > fmix
for f in small ftext fmix; do
  "$T" enc 6 $f z.c 0
  check "fuzz $f" '"$T" fuzz z.c $FUZZ 7 >/dev/null'
done
cd "$W" || exit 2

# ---- through PArc ----

seq 1 200000 > corpus/texto.txt
printf 'linea repetida\n' >> corpus/texto.txt
for i in $(seq 1 20); do cat "$ROOT/docs/USO.md"; done > corpus/prosa.txt
head -c 300000 /dev/urandom > corpus/azar.bin
: > corpus/vacio.bin
printf 'A' > corpus/uno.bin

"$PARC" a cm.parc corpus -mcm --no-progress >/dev/null 2>&1
check "a -mcm"                    '[ -s cm.parc ]'
check "t -mcm"                    '"$PARC" t cm.parc --no-progress | tail -1 | grep -q "All OK"'
rm -rf out; "$PARC" x cm.parc -dpout --no-progress >/dev/null 2>&1
check "x -mcm idéntico"           'diff -r corpus out/corpus >/dev/null'

rm -f m9.parc m6.parc mx.parc xx.parc
"$PARC" a m9.parc corpus/prosa.txt -m9 --no-progress >/dev/null 2>&1
"$PARC" a m6.parc corpus -m6 --no-progress >/dev/null 2>&1
"$PARC" a xx.parc corpus/prosa.txt -mxx --no-progress >/dev/null 2>&1
"$PARC" a mx.parc corpus/prosa.txt -mx --no-progress >/dev/null 2>&1
check "-mxx más chico que -m9"    '[ "$(stat -c%s xx.parc)" -lt "$(stat -c%s m9.parc)" ]'
check "-mxx verifica"             '"$PARC" t xx.parc --no-progress | tail -1 | grep -q "All OK"'
rm -rf outxx; "$PARC" x xx.parc -dpoutxx --no-progress >/dev/null 2>&1
check "-mxx extrae idéntico"      'cmp corpus/prosa.txt outxx/corpus/prosa.txt'
check "-mx verifica"              '"$PARC" t mx.parc --no-progress | tail -1 | grep -q "All OK"'
rm -rf outmx; "$PARC" x mx.parc -dpoutmx --no-progress >/dev/null 2>&1
check "-mx extrae idéntico"       'cmp corpus/prosa.txt outmx/corpus/prosa.txt'
check "-mx más chico que -m6"     '[ "$(stat -c%s mx.parc)" -lt "$(stat -c%s m6.parc)" ]'
rm -f mx1.parc; PARC_THREADS=1 "$PARC" a mx1.parc corpus/prosa.txt -mx --no-progress >/dev/null 2>&1
check "-mx paralelo == serial"    '[ "$(stat -c%s mx.parc)" = "$(stat -c%s mx1.parc)" ]'
rm -f xx1.parc xx4.parc
PARC_THREADS=1 "$PARC" a xx1.parc corpus -mxx --no-progress >/dev/null 2>&1
PARC_THREADS=4 "$PARC" a xx4.parc corpus -mxx --no-progress >/dev/null 2>&1
check "-mxx PARC_THREADS=1 == 4"  'cmp -s xx1.parc xx4.parc'

cp xx.parc bad.parc
python3 - <<'PY'
f=open('bad.parc','r+b'); f.seek(120); b=f.read(1); f.seek(120); f.write(bytes([b[0]^0x55]))
PY
check "cm dañado: código 2"       '{ "$PARC" t bad.parc --no-progress >/dev/null 2>&1; [ $? = 2 ]; }'

"$PARC" a e.parc corpus/prosa.txt -mxx -pclave --no-progress >/dev/null 2>&1
check "cm cifrado"                '"$PARC" t e.parc -pclave --no-progress | tail -1 | grep -q "All OK"'

echo "== cm: $fail failures"
[ $fail -eq 0 ]
