#!/bin/sh
# Compila PArc y su módulo autoextraíble (parcsfx). Uso: ./build.sh [linux64|win64|win32|all] (default: linux64)
# win32 (y win64 con todos los packages) usan el cross de PA-Lab en $FPC_CROSS.
set -e
cd "$(dirname "$0")"

FPCFLAGS="-O2 -Xs -vewn -Fusrc"
FPC_CROSS="${FPC_CROSS:-/mnt/IA_LAB/compartido/parc/fpc-cross}"

build() {
  target=$1; compiler=$2; shift 2
  out="build/$target"
  mkdir -p "$out/units"
  echo "== $target"
  $compiler $FPCFLAGS "$@" -FU"$out/units" -FE"$out" src/parc.lpr
  # el módulo autoextraíble (parc a -sfx lo busca al lado de parc)
  $compiler $FPCFLAGS "$@" -FU"$out/units" -FE"$out" src/parcsfx.lpr
}

case "${1:-linux64}" in
  linux64) build linux64 fpc -Tlinux -Px86_64 ;;
  win64)   if [ -x "$FPC_CROSS/bin/fpc-win64" ]; then build win64 "$FPC_CROSS/bin/fpc-win64"
           else build win64 fpc -Twin64 -Px86_64; fi ;;
  win32)   build win32 "$FPC_CROSS/bin/fpc-win32" ;;
  all)     "$0" linux64; "$0" win64; "$0" win32 ;;
  *)       echo "target desconocido: $1" >&2; exit 1 ;;
esac
