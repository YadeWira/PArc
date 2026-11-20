#!/bin/sh
# Compila PArc. Uso: ./build.sh [linux64|linux32|linuxarm64|macos|win64|win32|all] (default: linux64)
# Todo es Pascal (con ensamblador en línea): no hace falta compilador de C/C++ ni libstdc++.
# win32, linux32 y linuxarm64 (y win64 si está) usan el cross de PA-Lab en $FPC_CROSS.
set -e
cd "$(dirname "$0")"

FPCFLAGS="-O3 -Xs -vewn -Fusrc"
FPC_CROSS="${FPC_CROSS:-/mnt/IA_LAB/compartido/parc/fpc-cross}"

build() {
  target=$1; compiler=$2; shift 2
  out="build/$target"
  mkdir -p "$out/units"
  echo "== $target"
  $compiler $FPCFLAGS "$@" -Fo"$out/units" -FU"$out/units" -FE"$out" src/parc.lpr
}

case "${1:-linux64}" in
  linux64) build linux64 fpc -Tlinux -Px86_64 ;;
  win64)   if [ -x "$FPC_CROSS/bin/fpc-win64" ]; then build win64 "$FPC_CROSS/bin/fpc-win64"
           else build win64 fpc -Twin64 -Px86_64; fi ;;
  linux32) build linux32 "$FPC_CROSS/bin/fpc-linux32" ;;
  # Linux aarch64: nativo (p. ej. el runner ARM de CI) con el fpc del sistema, si no el cross
  linuxarm64)
           if [ "$(uname -m)" = aarch64 ]; then build linuxarm64 fpc -Tlinux -Paarch64
           else build linuxarm64 "$FPC_CROSS/bin/fpc-linuxarm64"; fi ;;
  # macOS arm64 (solo en un Mac: el fpc de Homebrew), contra el SDK de xcrun
  macos)   build macos fpc -Tdarwin -Paarch64 -XR"$(xcrun --show-sdk-path)" ;;
  win32)   build win32 "$FPC_CROSS/bin/fpc-win32" ;;
  all)     for t in linux64 linux32 linuxarm64 win64 win32; do "$0" $t; done ;;
  *)       echo "target desconocido: $1" >&2; exit 1 ;;
esac
