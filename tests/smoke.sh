#!/bin/bash
# tests/smoke.sh — ida y vuelta en todos los niveles, con 1 y 4 hilos, usando solo herramientas
# POSIX (corre igual en Linux, macOS y Git Bash): a, t, x y diff -r contra el original.
# Uso: tests/smoke.sh [parc]     (SMOKE_WORK=<dir>, default $TMPDIR/parc_smoke)
set -u
ROOT=$(cd "$(dirname "$0")/.." && pwd)
PARC=${1:-$ROOT/build/linux64/parc}
case "$PARC" in /*) ;; *) PARC=$PWD/$PARC ;; esac
W=${SMOKE_WORK:-${TMPDIR:-/tmp}/parc_smoke}
rm -rf -- "${W:?}"; mkdir -p "$W/in/sub" && cd "$W" || exit 2
fail=0; pass=0
ck() { if eval "$2"; then pass=$((pass+1)); else fail=$((fail+1)); echo "  FAIL $1"; fi; }

# árbol de prueba: fuentes (texto), el propio ejecutable (binario), datos repetidos y vacíos
cp "$ROOT"/src/*.pas in/
cp "$PARC" in/sub/bin.exe
cat in/sub/bin.exe in/sub/bin.exe > in/sub/twice.bin
: > in/sub/empty
printf 'x' > in/one
echo "parc: $("$PARC" --version | head -1)"

for T in 1 4; do
  for m in 0 1 2 3 4 5 6 7 8 9 x; do
    rm -rf o.parc out
    ck "-m$m T=$T a" "PARC_THREADS=$T '$PARC' a -m$m o.parc in --no-progress >log 2>&1"
    ck "-m$m T=$T t" "PARC_THREADS=$T '$PARC' t o.parc --no-progress 2>&1 | grep -q 'All OK'"
    ck "-m$m T=$T x" "mkdir out && PARC_THREADS=$T '$PARC' x o.parc -dpout --no-progress >/dev/null 2>&1 && diff -r in out/in >/dev/null"
  done
done
# cifrado, actualización y borrado
rm -rf o.parc out
ck "-p: a"        "'$PARC' a -m2 -psecreto o.parc in --no-progress >/dev/null 2>&1"
ck "-p: t"        "'$PARC' t -psecreto o.parc --no-progress 2>&1 | grep -q 'All OK'"
ck "-p: mala"     "! '$PARC' t -potra o.parc --no-progress >/dev/null 2>&1"
printf 'nuevo\n' > in/nuevo.txt
ck "u"            "'$PARC' u -psecreto o.parc in --no-progress >/dev/null 2>&1"
ck "d"            "'$PARC' d -psecreto o.parc in/one --no-progress >/dev/null 2>&1"
ck "x tras u/d"   "mkdir out && '$PARC' x -psecreto o.parc -dpout --no-progress >/dev/null 2>&1 && [ -f out/in/nuevo.txt ] && [ ! -f out/in/one ]"

echo "== smoke: $pass ok, $fail fallos"
cd / && rm -rf -- "${W:?}"
[ "$fail" -eq 0 ]
