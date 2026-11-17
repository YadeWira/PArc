#!/bin/bash
# tests/lz4frame.sh — el stream de `lz4` es un frame LZ4 estándar: lo que escribe PArc lo lee
# la herramienta `lz4`, y PArc lee lo que escribe `lz4` (bloques enlazados, checksums, tamaño
# de contenido). También frames dañados: tienen que dar error, no un cuelgue ni un crash.
# Uso: tests/lz4frame.sh   (salta lo de la herramienta si no hay `lz4` en el PATH)
set -u
ROOT=$(cd "$(dirname "$0")/.." && pwd)
T=$ROOT/build/tests/test_lz4frame
W=${LZ4FRAME_WORK:-${TMPDIR:-/tmp}/parc_lz4frame}
mkdir -p "$ROOT/build/tests/units"
fpc -O2 -Fu"$ROOT/src" -FU"$ROOT/build/tests/units" -FE"$ROOT/build/tests" "$ROOT/tests/test_lz4frame.lpr" >/dev/null || { echo "no compila test_lz4frame"; exit 2; }
rm -rf -- "${W:?}"; mkdir -p "$W" && cd "$W" || exit 2
fail=0; pass=0
ck() { if eval "$2"; then pass=$((pass+1)); echo "  ok   $1"; else fail=$((fail+1)); echo "  FAIL $1"; fi; }

cat "$ROOT"/src/*.pas > text
head -c 3000000 /dev/urandom > rnd
{ head -c 100000 rnd; cat text; head -c 70000 rnd; } > mix
: > empty
printf 'a' > one
for f in text rnd mix empty one; do
  for m in lz4 lz4:hc lz4:b64kb lz4:b4mb lz4:hc:b256kb; do
    ck "$f $m: ida y vuelta" "'$T' enc $m $f $f.lz4 && '$T' dec $f.lz4 $f.out && cmp -s $f $f.out"
    if command -v lz4 >/dev/null; then
      ck "$f $m: lo lee lz4" "lz4 -dqf $f.lz4 $f.cli && cmp -s $f $f.cli"
    fi
  done
  if command -v lz4 >/dev/null; then
    for o in "-1" "-9" "-1 -BD" "-1 -B4" "-1 --content-size" "-1 -BX" "-9 -BD -BX --content-size"; do
      ck "$f lz4 $o: lo lee PArc" "lz4 -qf $o $f $f.std && '$T' dec $f.std $f.out2 && cmp -s $f $f.out2"
    done
  fi
done
# dañados: cada byte del frame cambiado (en un archivo chico) y frames cortados
"$T" enc lz4 one one.lz4
"$T" enc lz4:b64kb mix mix.lz4
bad=0
for i in $(seq 0 $(( $(stat -c %s one.lz4) - 1 ))); do
  cp one.lz4 d.lz4; printf '\xff' | dd of=d.lz4 bs=1 seek=$i conv=notrunc 2>/dev/null
  timeout 10 "$T" dec d.lz4 d.out >/dev/null 2>&1; rc=$?
  [ $rc -eq 0 ] && cmp -s one d.out && bad=$((bad+1))   # dañado y sin error ni diferencia: raro
  [ $rc -ge 124 ] || [ $rc -eq 1 ] && bad=$((bad+1))
done
ck "frame chico dañado byte a byte: error limpio" "[ $bad -eq 0 ]"
bad=0
for n in 1 5 7 11 100 1000 50000 $(( $(stat -c %s mix.lz4) - 1 )); do
  head -c $n mix.lz4 > c.lz4
  timeout 10 "$T" dec c.lz4 c.out >/dev/null 2>&1; [ $? -eq 2 ] || bad=$((bad+1))
done
ck "frames cortados: error limpio" "[ $bad -eq 0 ]"
bad=0
for i in $(seq 1 200); do
  cp mix.lz4 r.lz4
  printf "\\x$(printf %02x $((RANDOM % 256)))" | dd of=r.lz4 bs=1 seek=$((RANDOM * 32768 % $(stat -c %s mix.lz4) + RANDOM % 1000)) conv=notrunc 2>/dev/null
  timeout 10 "$T" dec r.lz4 r.out >/dev/null 2>&1; rc=$?
  [ $rc -eq 0 ] || [ $rc -eq 2 ] || bad=$((bad+1))
done
ck "200 frames con un byte al azar: sin crash ni cuelgue" "[ $bad -eq 0 ]"

echo "== lz4frame: $pass ok, $fail fallos"
cd / && rm -rf -- "${W:?}"
[ "$fail" -eq 0 ]
