#!/bin/bash
# tests/crc.sh — CRC-32 de parc_crc (plegado PCLMULQDQ si la CPU lo tiene) contra las tablas y
# contra un CRC de a un bit. Con PARC_CRC=table se prueba también el camino sin PCLMULQDQ.
set -u
ROOT=$(cd "$(dirname "$0")/.." && pwd)
mkdir -p "$ROOT/build/tests/units"
fpc -O3 -vewn -Fu"$ROOT/src" -FU"$ROOT/build/tests/units" -FE"$ROOT/build/tests" "$ROOT/tests/test_crc.lpr" >/dev/null \
  || { echo "no compila test_crc"; exit 1; }
"$ROOT/build/tests/test_crc" "$@" || exit 1
PARC_CRC=table "$ROOT/build/tests/test_crc" || exit 1
echo "crc: OK"
