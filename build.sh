#!/bin/sh
# Compila PArc. Uso: ./build.sh [linux64|linux32|linuxarm64|macos|win64|win32|all] (default: linux64)
# Todo es Pascal (con ensamblador en línea) salvo el núcleo de OREP (src/orep/orep_core.c, MIT,
# C sin libc), que se compila acá con el gcc/clang de cada target y se enlaza estático (no hace
# falta libstdc++ ni libgcc). Con -dOREP_NO_NATIVE se usa la referencia en Pascal (mismos bytes).
# win32, linux32 y linuxarm64 (y win64 si está) usan el cross de PA-Lab en $FPC_CROSS.
set -e
cd "$(dirname "$0")"

FPCFLAGS="-O3 -Xs -vewn -Fusrc -Fusrc/orep"
FPC_CROSS="${FPC_CROSS:-/mnt/IA_LAB/compartido/parc/fpc-cross}"

# corep <dir> <cc> [opciones]: el núcleo en C de OREP -> <dir>/units/orep_core.o, que
# src/orep/orep.pas enlaza con {$L}. Opciones del README de OREP.
COREPFLAGS="-O2 -fno-builtin -ffreestanding -fno-stack-protector -fno-tree-loop-distribute-patterns -w"
corep() {
  out=$1; cc=$2; shift 2
  mkdir -p "$out/units"
  $cc $COREPFLAGS "$@" -c src/orep/orep_core.c -o "$out/units/orep_core.o"
}

build() {
  target=$1; compiler=$2; shift 2
  out="build/$target"
  mkdir -p "$out/units"
  echo "== $target"
  $compiler $FPCFLAGS "$@" -Fo"$out/units" -FU"$out/units" -FE"$out" src/parc.lpr
}

case "${1:-linux64}" in
  linux64) corep build/linux64 gcc -fno-pie
           build linux64 fpc -Tlinux -Px86_64 ;;
  win64)   corep build/win64 x86_64-w64-mingw32-gcc
           if [ -x "$FPC_CROSS/bin/fpc-win64" ]; then build win64 "$FPC_CROSS/bin/fpc-win64"
           else build win64 fpc -Twin64 -Px86_64; fi ;;
  linux32) corep build/linux32 gcc -m32 -fno-pie -mstackrealign
           build linux32 "$FPC_CROSS/bin/fpc-linux32" ;;
  # Linux aarch64: nativo (p. ej. el runner ARM de CI) con el fpc del sistema, si no el cross
  linuxarm64)
           if [ "$(uname -m)" = aarch64 ]; then
             corep build/linuxarm64 gcc -fno-pie
             build linuxarm64 fpc -Tlinux -Paarch64
           else
             corep build/linuxarm64 aarch64-linux-gnu-gcc -fno-pie
             build linuxarm64 "$FPC_CROSS/bin/fpc-linuxarm64"
           fi ;;
  # macOS arm64 (solo en un Mac: el fpc de Homebrew y clang de Xcode), contra el SDK de xcrun
  macos)   corep build/macos clang
           build macos fpc -Tdarwin -Paarch64 -XR"$(xcrun --show-sdk-path)" ;;
  # i686: la pila realineada (FPC la deja a 4)
  win32)   corep build/win32 i686-w64-mingw32-gcc -mstackrealign
           build win32 "$FPC_CROSS/bin/fpc-win32" ;;
  all)     for t in linux64 linux32 linuxarm64 win64 win32; do "$0" $t; done ;;
  *)       echo "target desconocido: $1" >&2; exit 1 ;;
esac
