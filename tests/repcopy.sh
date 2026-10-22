#!/bin/bash
# tests/repcopy.sh — copia de matches del decodificador REP (TRepStage) contra un oráculo byte a
# byte: distancias 1..64 y cercanas a la ventana, largos 1..300, con vuelta de la ventana.
set -u
ROOT=$(cd "$(dirname "$0")/.." && pwd)
mkdir -p "$ROOT/build/tests/units"
fpc -O2 -Fu"$ROOT/src" -FU"$ROOT/build/tests/units" -FE"$ROOT/build/tests" "$ROOT/tests/test_repcopy.lpr" >/dev/null \
  || { echo "no compila test_repcopy"; exit 2; }
"$ROOT/build/tests/test_repcopy"
