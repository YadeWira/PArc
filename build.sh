#!/bin/sh
# Compila PArc. Uso: ./build.sh [linux64|win64|win32|all] (default: linux64)
# win32 necesita el compilador cruzado i386 (ver FPC_CROSS386 abajo).
set -e
cd "$(dirname "$0")"

FPCFLAGS="-O2 -Xs -vewn -Fusrc"
FPC_CROSS386="${FPC_CROSS386:-/mnt/IA_LAB/compartido/parc/fpc-cross}"

build() {
  target=$1; shift
  out="build/$target"
  mkdir -p "$out/units"
  echo "== $target"
  fpc $FPCFLAGS "$@" -FU"$out/units" -FE"$out" src/parc.lpr
}

case "${1:-linux64}" in
  linux64) build linux64 -Tlinux -Px86_64 ;;
  win64)   build win64 -Twin64 -Px86_64 ;;
  win32)   build win32 -Twin32 -Pi386 ;;
  all)     "$0" linux64; "$0" win64; "$0" win32 ;;
  *)       echo "target desconocido: $1" >&2; exit 1 ;;
esac
