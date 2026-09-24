#!/bin/sh
# Regresión de extracción: compara PArc contra el oráculo unarc (FreeArc 0.67 compilado por PA-Lab)
# sobre los .arc generados con arc.exe, verifica que `parc t` detecte corrupción, y prueba BCJ
# contra el C original de FreeArc con cortes de buffer aleatorios.
# Uso: tests/regress.sh [archivos .arc...]   (default: samples/gen con métodos ya soportados)
set -u
cd "$(dirname "$0")/.."
PARC=./build/linux64/parc
UNARC=${UNARC:-/mnt/IA_LAB/agentes/PA-Lab/bin/unarc.x64}
# Plan B cuando unarc falla (p. ej. el LZ4 de 2012 que trae Unarc no lee los lz4 de arc.exe 0.67.1):
# el arc.exe original bajo wine
ARCEXE=${ARCEXE:-/mnt/IA_LAB/agentes/PArc/ref/Arc.exe}
export WINEPREFIX=${WINEPREFIX:-/mnt/IA_LAB/agentes/PArc/wine} WINEDEBUG=-all
GEN=${GEN:-/mnt/IA_LAB/compartido/parc/samples/gen}
WORK=${WORK:-/mnt/IA_LAB/agentes/PArc/regress}
fail=0; pass=0
ok()  { pass=$((pass+1)); echo "  ok   $*"; }
bad() { fail=$((fail+1)); echo "  FAIL $*"; }

[ $# -gt 0 ] || set -- "$GEN"/m0.arc "$GEN"/lzma.arc "$GEN"/exe.arc "$GEN"/exe_lzma.arc "$GEN"/delta.arc "$GEN"/delta_lzma.arc
mkdir -p "$WORK"

echo "== extracción vs unarc"
for a in "$@"; do
  n=$(basename "$a" .arc)
  rm -rf "${WORK:?}/$n.u" "${WORK:?}/$n.p"; mkdir -p "$WORK/$n.u" "$WORK/$n.p"
  oracle=unarc
  if ! (cd "$WORK/$n.u" && "$UNARC" x -o+ "$a" >/dev/null 2>&1); then
    rm -rf "${WORK:?}/$n.u"; mkdir -p "$WORK/$n.u"; oracle=arc.exe
    (cd "$WORK/$n.u" && wine "$ARCEXE" x -o+ "$a" >/dev/null 2>&1) || { bad "$n: fallaron unarc y arc.exe"; continue; }
  fi
  if ! "$PARC" t "$a" >/dev/null; then bad "$n: parc t con errores"; continue; fi
  "$PARC" x "$a" -dp"$WORK/$n.p" -o+ >/dev/null || { bad "$n: parc x con errores"; continue; }
  if diff -r "$WORK/$n.u" "$WORK/$n.p" >/dev/null; then ok "$n (vs $oracle)"; else bad "$n: el árbol difiere de $oracle"; fi
done

echo "== corrupción detectada"
c="$WORK/corrupto.arc"; cp "$GEN/m0.arc" "$c"
# Un byte en medio de los datos (storing): el CRC del archivo tiene que fallar
python3 -c "import sys;f=open(sys.argv[1],'r+b');f.seek(5000);b=f.read(1);f.seek(5000);f.write(bytes([b[0]^0x55]))" "$c"
if "$PARC" t "$c" >/dev/null 2>&1; then bad "parc t no detectó un byte corrupto"; else ok "parc t detecta un byte corrupto"; fi

echo "== BCJ vs C original (cortes aleatorios)"
mkdir -p build/tests
cc -O2 -w -o build/tests/bcj_ref tests/bcj_ref.c || { bad "no compila bcj_ref"; }
fpc -O2 -Fusrc -FUbuild/tests -FEbuild/tests tests/test_bcj.lpr >/dev/null || bad "no compila test_bcj"
for f in "$GEN"/../src/binarios/* ; do
  [ -f "$f" ] || continue
  build/tests/bcj_ref 1 1 < "$f" > "$WORK/bcj.enc"
  build/tests/bcj_ref 1 0 < "$WORK/bcj.enc" > "$WORK/bcj.dec"
  cmp -s "$f" "$WORK/bcj.dec" || { bad "bcj_ref no es reversible en $(basename "$f")"; continue; }
  for mc in 1 7 4096 1048576; do
    if build/tests/test_bcj "$WORK/bcj.enc" "$f" 42 $mc >/dev/null; then ok "bcj $(basename "$f") maxchunk=$mc"
    else bad "bcj $(basename "$f") maxchunk=$mc: $(build/tests/test_bcj "$WORK/bcj.enc" "$f" 42 $mc)"; fi
  done
done

echo "== resultado: $pass ok, $fail fallas"
[ $fail -eq 0 ]
