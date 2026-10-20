#!/bin/bash
# tests/bcj.sh — filtro BCJ x86 (método exe) contra el C original de FreeArc (Bra86.c), con
# cortes de buffer al azar. No usa el oráculo arc.exe.
set -u
ROOT=$(cd "$(dirname "$0")/.." && pwd)
WORK=${BCJ_WORK:-/tmp/opencode/bcj_test}
rm -rf -- "${WORK:?}"; mkdir -p "$WORK" && cd "$WORK" || exit 2
fail=0; pass=0
ok()  { pass=$((pass+1)); echo "  ok   $*"; }
bad() { fail=$((fail+1)); echo "  FAIL $*"; }

mkdir -p "$ROOT/build/tests"
cc -O2 -w -o bcj_ref "$ROOT/tests/bcj_ref.c" || { echo "no compila bcj_ref"; exit 2; }
fpc -O2 -Fu"$ROOT/src" -FU"$ROOT/build/tests" -FE"$ROOT/build/tests" "$ROOT/tests/test_bcj.lpr" >/dev/null \
  || { echo "no compila test_bcj"; exit 2; }
TEST=$ROOT/build/tests/test_bcj

CAND="$ROOT/build/linux64/parc $ROOT/build/linux64/parcsfx"
for f in /mnt/IA_LAB/compartido/parc/samples/src/binarios/*; do [ -f "$f" ] && CAND="$CAND $f"; done
for f in $CAND; do
  [ -f "$f" ] || continue
  ./bcj_ref 1 1 < "$f" > bcj.enc || { bad "bcj_ref $f"; continue; }
  ./bcj_ref 1 0 < bcj.enc > bcj.dec || { bad "bcj_ref -d $f"; continue; }
  cmp -s "$f" bcj.dec || { bad "bcj_ref no reversible: $f"; continue; }
  for mc in 1 7 4096 1048576; do
    if "$TEST" bcj.enc "$f" 42 $mc >/dev/null; then ok "$(basename "$f") maxchunk=$mc"
    else bad "$(basename "$f") maxchunk=$mc: $("$TEST" bcj.enc "$f" 42 $mc)"; fi
  done
done

echo "== bcj: $pass ok, $fail fallas"
[ $fail -eq 0 ]
