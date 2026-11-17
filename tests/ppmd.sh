#!/bin/bash
# tests/ppmd.sh — PPMd (parc_ppmd, variante I del LZMA SDK).
#
#  1. tests/test_ppmd.lpr con ensamblador y con -dPARC_NOASM: ida y vuelta de entradas chicas
#     (vacía, 1 byte, repetidas, al azar) y de texto/binario con órdenes 2..64, memorias de
#     2 KB a 32 MB (con restart y cut-off: la memoria se llena), parámetros inválidos y cabeceras
#     que no coinciden; streams dañados (solo EArcCorrupt o una salida, nunca otro error).
#  2. Si está el LZMA SDK ($PPMD_SDK, con Ppmd8.c): el stream sin la cabecera tiene que ser
#     bit a bit el del C original (tests/ppmd_ref.c), también con órdenes > 16 (el SDK los
#     limita a 16 por el formato zip; acá se compila con PPMD8_MAX_ORDER = 64).
#
# Uso: tests/ppmd.sh   (PPMD_CORRUPT=<iteraciones>, default 300)
set -u
ROOT=$(cd "$(dirname "$0")/.." && pwd)
W=${PPMD_WORK:-${TMPDIR:-/tmp}/parc_ppmd_test}
SDK=${PPMD_SDK:-/mnt/IA_LAB/agentes/PArc/upstream/lzma-sdk/C}
ITERS=${PPMD_CORRUPT:-300}
rm -rf -- "${W:?}"; mkdir -p "$W/asm" "$W/pas" "$W/in" || exit 2
fail=0
bad() { fail=$((fail+1)); echo "  FAIL $*"; }

for v in asm pas; do
  d=""; [ $v = pas ] && d=-dPARC_NOASM
  fpc -O3 $d -Fu"$ROOT/src" -FU"$W/$v" -FE"$W/$v" "$ROOT/tests/test_ppmd.lpr" > "$W/$v.log" 2>&1 \
    || { echo "no compila test_ppmd ($v)"; tail -5 "$W/$v.log"; exit 2; }
done

# Entradas: texto (fuentes), binario x86 y una mezcla con bytes al azar
cat "$ROOT"/src/*.pas | head -c 1500000 > "$W/in/text"
PARC=$ROOT/build/linux64/parc
[ -f "$PARC" ] || PARC=$W/asm/test_ppmd
head -c 1200000 "$PARC" > "$W/in/bin"
{ head -c 200000 "$W/in/text"; head -c 100000 /dev/urandom; head -c 200000 "$W/in/bin"; } > "$W/in/mix"

for v in asm pas; do
  echo "== $v: ida y vuelta"
  "$W/$v/test_ppmd" suite "$W/in/text" "$W/in/bin" "$W/in/mix" || bad "$v suite"
  echo "== $v: streams dañados ($ITERS)"
  "$W/$v/test_ppmd" corrupt "$W/in/mix" "$ITERS" 7 || bad "$v corrupt"
done

if [ -f "$SDK/Ppmd8.c" ] && command -v gcc > /dev/null; then
  echo "== contra el LZMA SDK en C ($SDK)"
  mkdir -p "$W/sdk" "$W/ref"
  cp "$SDK"/*.h "$SDK"/Ppmd8.c "$SDK"/Ppmd8Enc.c "$W/sdk/"
  sed -i 's/#define PPMD8_MAX_ORDER 16/#define PPMD8_MAX_ORDER 64/' "$W/sdk/Ppmd8.h"
  [ -f "$W/sdk/CpuArch.h" ] || cat > "$W/sdk/CpuArch.h" <<'EOF'
#ifndef PARC_CPUARCH_STUB
#define PARC_CPUARCH_STUB
#include "7zTypes.h"
#define MY_CPU_LE
#define MY_CPU_pragma_pack_push_1 _Pragma("pack(push, 1)")
#define MY_CPU_pragma_pop _Pragma("pack(pop)")
#ifndef Z7_FORCE_INLINE
#define Z7_FORCE_INLINE __attribute__((always_inline)) inline
#endif
#ifndef Z7_NO_INLINE
#define Z7_NO_INLINE __attribute__((noinline))
#endif
#endif
EOF
  if gcc -O2 -w -I"$W/sdk" -o "$W/ref/ppmd_ref" "$ROOT/tests/ppmd_ref.c" "$W/sdk/Ppmd8.c" "$W/sdk/Ppmd8Enc.c" > "$W/ref.log" 2>&1; then
    n=0
    for f in text bin mix; do
      for cfg in "2 2048 0" "4 65536 1" "6 1048576 0" "6 1048576 1" "8 4194304 1" "16 2097152 1" \
                 "16 16777216 0" "24 8388608 1" "64 3145728 1" "12 67108864 0"; do
        set -- $cfg
        for v in asm pas; do
          "$W/$v/test_ppmd" enc "$W/in/$f" $1 $2 $3 "$W/p.out" > /dev/null || { bad "$v enc $f $cfg"; continue; }
          "$W/ref/ppmd_ref" "$W/in/$f" $1 $2 $3 "$W/r.out" || { bad "ppmd_ref $f $cfg"; continue; }
          if tail -c +9 "$W/p.out" | cmp -s - "$W/r.out"; then n=$((n+1))
          else bad "$v $f ppmd:$1:$2:r$3: distinto del SDK"; fi
        done
      done
    done
    echo "  $n streams iguales al SDK"
  else
    echo "  (no compila el SDK: $(tail -1 "$W/ref.log"); se saltea la comparación)"
  fi
else
  echo "== (sin LZMA SDK en $SDK: se saltea la comparación con el C original)"
fi

cd / && rm -rf -- "${W:?}"
if [ "$fail" -eq 0 ]; then echo "All OK"; else echo "Errors: $fail"; exit 1; fi
