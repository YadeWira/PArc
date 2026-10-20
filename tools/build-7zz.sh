#!/bin/sh
# tools/build-7zz.sh — compila 7-Zip ZS (7zz) para Linux y lo deja al lado de parc.
#
# PArc no enlaza 7-Zip: para .zip/.7z/.rar ejecuta este binario como proceso externo.
# 7-Zip ZS es LGPL 2.1+ (con la restricción de unRAR para el código de RAR); no se
# redistribuye en este repo, sólo se compila localmente.
#
# Uso: tools/build-7zz.sh [destino]        (default: build/linux64)
#     ZS_TAG=<tag> tools/build-7zz.sh     (default: v26.02-v1.5.7-R2)
set -e
ROOT=$(cd "$(dirname "$0")/.." && pwd)
DEST=${1:-$ROOT/build/linux64}
TAG=${ZS_TAG:-v26.02-v1.5.7-R2}
SRC=${ZS_SRC:-$ROOT/build/7zip-zstd}
JOBS=${JOBS:-$(getconf _NPROCESSORS_ONLN 2>/dev/null || echo 4)}

if [ ! -d "$SRC/.git" ]; then
  echo "== clonando 7-Zip ZS $TAG en $SRC"
  mkdir -p "$(dirname "$SRC")"
  git clone --depth 1 --branch "$TAG" https://github.com/mcmilk/7-Zip-zstd "$SRC"
fi

echo "== compilando 7zz ($JOBS hilos)"
( cd "$SRC/CPP/7zip/Bundles/Alone2" && make -j"$JOBS" -f makefile.gcc )

mkdir -p "$DEST"
cp "$SRC/CPP/7zip/Bundles/Alone2/_o/7zz" "$DEST/7zz"
chmod +x "$DEST/7zz"
echo "OK: $DEST/7zz"
"$DEST/7zz" | head -1
