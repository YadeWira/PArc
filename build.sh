#!/bin/sh
# Compila PArc. Uso: ./build.sh [linux64|linux32|linuxarm64|macos|win64|win32|all] (default: linux64)
# win32 (y win64 con todos los packages) usan el cross de PA-Lab en $FPC_CROSS.
# El codificador Tornado es el C++ de FreeArc (reference/freearc-0.67/Compression/Tornado),
# compilado acá con g++ / mingw-g++ y llamado desde Pascal por src/parc_torglue.cpp.
set -e
cd "$(dirname "$0")"

FPCFLAGS="-O3 -Xs -vewn -Fusrc"
FPC_CROSS="${FPC_CROSS:-/mnt/IA_LAB/compartido/parc/fpc-cross}"
# Las opciones de FreeArc (Compression/Tornado/makefile) salvo -ffast-math; sin excepciones ni RTTI
CXXFLAGS="-O3 -fno-exceptions -fno-rtti -fomit-frame-pointer -fstrict-aliasing -funroll-loops
  --param inline-unit-growth=999 -fno-asynchronous-unwind-tables -w -DFREEARC_INTEL_BYTE_ORDER"

# ctor <dir> <g++> [opciones]: Tornado.cpp (copia parcheada con src/parc_torglue.patch) +
# el puente -> <dir>/units/parc_torglue.o
ctor() {
  out=$1; cxx=$2; shift 2
  src=$out/ctor
  rm -rf "$src"; mkdir -p "$src/Tornado" "$out/units"
  F=reference/freearc-0.67/Compression
  cp "$F/Common.h" "$F/Compression.h" "$src/"
  cp "$F"/Tornado/*.cpp "$src/Tornado/"
  patch -s -p1 -d "$src" < src/parc_torglue.patch
  $cxx $CXXFLAGS "$@" -I"$src" -c src/parc_torglue.cpp -o "$out/units/parc_torglue.o"
}

build() {
  target=$1; compiler=$2; shift 2
  out="build/$target"
  mkdir -p "$out/units"
  echo "== $target"
  $compiler $FPCFLAGS "$@" -Fo"$out/units" -FU"$out/units" -FE"$out" src/parc.lpr
}

WINCXX="-DFREEARC_WIN -DUNICODE -D_UNICODE"
# Para el .exe: libgcc (___chkstk_ms, divisiones de 64 bits en i386), libmingwex (log2, round) y
# la biblioteca de importación de msvcrt.dll (que viene con Windows), todas estáticas.
winlibs() { echo "-Fl$(dirname "$($1 -print-libgcc-file-name)") -Fl$(dirname "$($1 -print-file-name=libmsvcrt.a)")"; }
case "${1:-linux64}" in
  linux64) ctor build/linux64 g++ -DFREEARC_UNIX -fno-pie
           build linux64 fpc -Tlinux -Px86_64 ;;
  win64)   ctor build/win64 x86_64-w64-mingw32-g++ $WINCXX
           if [ -x "$FPC_CROSS/bin/fpc-win64" ]; then build win64 "$FPC_CROSS/bin/fpc-win64" $(winlibs x86_64-w64-mingw32-gcc)
           else build win64 fpc -Twin64 -Px86_64 $(winlibs x86_64-w64-mingw32-gcc); fi ;;
  # Linux i386: el g++ del sistema con -m32 (lib32stdc++/multilib) y el cross de FPC
  linux32) ctor build/linux32 g++ -m32 -DFREEARC_UNIX -fno-pie -msse2 -mfpmath=sse -mstackrealign
           build linux32 "$FPC_CROSS/bin/fpc-linux32" -Fl/usr/lib32 -Fl"$(dirname "$(g++ -m32 -print-libgcc-file-name)")" ;;
  # Linux aarch64: el cross de FPC y aarch64-linux-gnu-g++ (Common.h detecta 64 bits por el parche)
  linuxarm64)
           if [ "$(uname -m)" = aarch64 ]; then
             # nativo (p. ej. el runner ARM de CI): el g++ y el fpc del sistema
             ctor build/linuxarm64 g++ -DFREEARC_UNIX -fno-pie
             build linuxarm64 fpc -Tlinux -Paarch64
           else
             ctor build/linuxarm64 aarch64-linux-gnu-g++ -DFREEARC_UNIX -fno-pie
             build linuxarm64 "$FPC_CROSS/bin/fpc-linuxarm64" -Fl"$(dirname "$(aarch64-linux-gnu-gcc -print-libgcc-file-name)")"
           fi ;;
  # macOS arm64 (solo en un Mac: clang++ de Xcode y el fpc de Homebrew), contra el SDK de xcrun
  macos)   ctor build/macos clang++ -DFREEARC_UNIX
           build macos fpc -Tdarwin -Paarch64 -XR"$(xcrun --show-sdk-path)" ;;
  # i686: SSE2 para los precios (log2) igual que en x86_64, y la pila realineada (FPC la deja a 4)
  win32)   ctor build/win32 i686-w64-mingw32-g++ $WINCXX -msse2 -mfpmath=sse -mstackrealign
           build win32 "$FPC_CROSS/bin/fpc-win32" $(winlibs i686-w64-mingw32-gcc) ;;
  all)     for t in linux64 linux32 linuxarm64 win64 win32; do "$0" $t; done ;;
  *)       echo "target desconocido: $1" >&2; exit 1 ;;
esac
