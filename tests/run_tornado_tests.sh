#!/bin/bash
# Pruebas del decodificador Tornado (src/parc_tornado.pas) contra el compresor C de FreeArc.
# El oráculo es Compression/Tornado/main.cpp compilado aparte (no escribe encabezado propio: el
# .tor es exactamente el stream de tor_compress), con compress_all_at_once=1 si TOR_AAO está
# definida (así comprime/descomprime FreeArc dentro de 4x4).
# (FULL_COMPILE: sin él faltan combinaciones de parser/codificador, p. ej. -5 -c1.)
# Uso: tests/run_tornado_tests.sh [-j N]      Variables: TOR, CORPUS, WORK
set -u
cd "$(dirname "$0")/.."
REPO=$PWD
LAB=/mnt/IA_LAB/agentes/PArc/tornado
TOR=${TOR:-$LAB/tor64}
CORPUS=${CORPUS:-$LAB/corpus}
WORK=${WORK:-$LAB/work}
JOBS=16
[ "${1:-}" = "-j" ] && JOBS=$2
T=$REPO/build/tests/test_tornado

# --- oráculo ---
if [ ! -x "$TOR" ]; then
  echo "== compilando el oráculo en $LAB"
  mkdir -p "$LAB/src/Tornado"
  F=$REPO/reference/freearc-0.67/Compression
  cp "$F/Common.h" "$F/Common.cpp" "$F/Compression.h" "$LAB/src/"
  cp "$F"/Tornado/*.cpp "$F"/Tornado/*.h "$LAB/src/Tornado/"
  sed -i 's/^int compress_all_at_once = 0;/int compress_all_at_once = getenv("TOR_AAO")!=NULL;/' "$LAB/src/Tornado/main.cpp"
  (cd "$LAB/src/Tornado" && g++ -DFULL_COMPILE -DFREEARC_UNIX -DFREEARC_INTEL_BYTE_ORDER -D_FILE_OFFSET_BITS=64 -O2 \
     -fno-exceptions -fno-rtti -w -fpermissive main.cpp -o "$TOR" -lrt) || exit 1
fi

# --- corpus (copias; nunca se toca el original) ---
if [ ! -d "$CORPUS" ]; then
  echo "== armando el corpus en $CORPUS"
  C=/mnt/OSR_D3/fileFormatSamples/fileFormatSamples
  S=/mnt/IA_LAB/compartido/parc/samples/src
  mkdir -p "$CORPUS"
  cp "$C/executable/exe/EMPEARTH.EXE" "$CORPUS/empearth.exe"
  cp "$C/executable/dll/msimsg.dll" "$C/executable/dll/AMIEQN.DLL" "$C/audio/wav/drumloop.wav" \
     "$C/audio/wav/SETUP.WAV" "$C/text/emblSequenceData/output.embl" "$CORPUS/"
  cp "$C/image/bmp/CADUCEUS.BMP" "$CORPUS/caduceus.bmp"
  (cd "$S" && find . -type f) | while read -r f; do
    cp "$S/$f" "$CORPUS/src_$(basename "$f" | tr -c 'A-Za-z0-9._\n-' '_')"
  done
  printf 'x' > "$CORPUS/uno.bin"; printf 'abcab' > "$CORPUS/cinco.bin"
  head -c 100 /dev/urandom > "$CORPUS/rnd100.bin"
  # >10000 tablas en el primer tramo de 8MB: fuerza el camino tables.filled()
  python3 - "$CORPUS/tablas_sint.bin" <<'EOF'
import random, struct, sys
random.seed(7); out = bytearray()
while len(out) < 6_000_000:
    out += bytes(random.getrandbits(8) for _ in range(random.randint(8, 40)))
    n = random.randint(30, 80); v = random.getrandbits(32); w = random.choice([2, 4]); step = random.randint(1, 3000)
    for i in range(n):
        v = (v + step + random.randint(0, 3)) & (0xffffffff if w == 4 else 0xffff)
        out += struct.pack('<I' if w == 4 else '<H', v)
open(sys.argv[1], 'wb').write(out)
EOF
fi

# --- programa de prueba ---
mkdir -p build/tests/units
fpc -O2 -vewn -Fusrc -FUbuild/tests/units -FEbuild/tests tests/test_tornado.lpr >/dev/null || { echo "no compila test_tornado"; exit 1; }

rm -rf "$WORK"; mkdir -p "$WORK"
export TOR T WORK

# Un caso: <categoría> <aao 0|1> <archivo> <opciones del compresor...>
# Normal: modo s siempre; si el archivo entra en el bufsize del encabezado, también S y m.
# Si no entra, AllAtOnce no es válido (tampoco en el C): se compara W contra el C con TOR_AAO=1.
run_case() {
  cat=$1; aao=$2; f=$3; shift 3
  tag="$cat $(basename "$f") $*"
  id=$(echo "$tag" | md5sum | cut -c1-12)
  out=$WORK/$id.tor
  if [ "$aao" = 1 ]; then TOR_AAO=1 "$TOR" -q "$@" "$f" -o"$out" 2>/dev/null; else "$TOR" -q "$@" "$f" -o"$out" 2>/dev/null; fi
  [ -s "$out" ] || { echo "FAIL|$cat|$tag|el compresor no generó salida"; return; }
  size=$(stat -c %s "$f")
  bufsize=$(od -An -tu4 -j2 -N4 "$out" | tr -d ' ')
  modes=s; [ "$size" -le "$bufsize" ] && modes=sSm
  if ! msg=$("$T" "$out" "$f" "$modes" 2>&1); then echo "FAIL|$cat|$tag|$msg"; rm -f "$out"; return; fi
  if [ "$modes" = s ]; then
    TOR_AAO=1 "$TOR" -d -q "$out" -o"$out.c" 2>/dev/null
    "$T" "$out" "$out.p" W
    if ! cmp -s "$out.c" "$out.p"; then echo "FAIL|$cat|$tag|W distinto del C con TOR_AAO"; rm -f "$out"*; return; fi
    modes="s+W"
  fi
  echo "OK|$cat|$tag|$modes"
  rm -f "$out"*
}
export -f run_case

FILES=$(ls "$CORPUS"/* | sort)
BIG="$CORPUS/empearth.exe $CORPUS/SETUP.WAV $CORPUS/tablas_sint.bin $CORPUS/output.embl $CORPUS/src_arc067.exe $CORPUS/src_aleatorio.bin"
{
  for f in $FILES; do
    for p in $(seq 1 16); do echo "preset-$p 0 $f -$p"; done
    for c in 1 2 3 4; do for t in 0 1; do
      echo "c$c-t$t 0 $f -5 -c$c -t$t"
      echo "c$c-t$t 0 $f -3 -c$c -t$t"
    done; done
    # AllAtOnce: el compresor lee todo de una vez (buffer >= archivo), como 4x4
    for p in 1 2 3 4 5 6 9 11 12 16; do echo "aao-$p 1 $f -$p -b1gb"; done
    for c in 1 2 3 4; do echo "aao-c$c 1 $f -5 -c$c -b1gb"; done
  done
  # Vuelta del buffer circular: archivos mucho más grandes que el bufsize
  for f in $BIG; do
    for c in 1 2 3 4; do
      echo "wrap-c$c 0 $f -5 -c$c -b64kb"
      echo "wrap-c$c 0 $f -3 -c$c -b300kb"
      echo "wrap-c$c 0 $f -4 -c$c -b1mb"
      echo "wrap-c$c 0 $f -12 -c$c -b256kb"
    done
    # buffer > LARGE_BUFFER_SIZE: outbuf = bufsize exacto y tramos que no son múltiplo de 8MB
    echo "wrap-big 0 $f -5 -b3mb"
    echo "wrap-big 0 $f -11 -b5mb"
  done
} > "$WORK/cases.txt"

echo "== $(wc -l < "$WORK/cases.txt") casos, $JOBS en paralelo"
xargs -P "$JOBS" -L 1 bash -c 'run_case "$@"' _ < "$WORK/cases.txt" > "$WORK/results.txt"

grep '^FAIL' "$WORK/results.txt" | cut -d'|' -f3- | sed 's/^/  FAIL /'
echo
printf '%-12s %6s %6s\n' categoría ok fail
cut -d'|' -f1,2 "$WORK/results.txt" | sort -t'|' -k2,2V | awk -F'|' '
  { c[$2]++; if ($1=="OK") ok[$2]++; else bad[$2]++; if (!($2 in seen)) { seen[$2]=1; order[n++]=$2 } }
  END { for (i=0;i<n;i++) { k=order[i]; printf "%-12s %6d %6d\n", k, ok[k]+0, bad[k]+0 } }'
tot=$(wc -l < "$WORK/results.txt"); nf=$(grep -c '^FAIL' "$WORK/results.txt")
echo "total: $tot casos, $((tot-nf)) ok, $nf fallas"

# Datos corruptos: decodifican o lanzan EArcCorrupt, nunca otra excepción ni cuelgue
echo; echo "== fuzz"
for c in 1 2 3 4; do
  for f in "$CORPUS/SETUP.WAV" "$CORPUS/tablas_sint.bin"; do
    "$TOR" -q -$c -b1mb "$f" -o"$WORK/fz.tor"
    if r=$(timeout 600 "$T" "$WORK/fz.tor" "$f" f $c 2>&1); then echo "  ok   c$c $(basename "$f"): $r"
    else echo "  FAIL c$c $(basename "$f"): $r"; nf=$((nf+1)); fi
  done
done

# Archivos .arc reales de FreeArc 0.67.1 (CRC de cada archivo, sin el CLI)
ARCS=${ARCS:-/mnt/IA_LAB/compartido/parc/samples/gen/tor.arc $(ls "$LAB"/arcs/*.arc 2>/dev/null)}
echo; echo "== .arc de FreeArc"
fpc -O2 -vewn -Fusrc -FUbuild/tests/units -FEbuild/tests tests/test_tornado_arc.lpr >/dev/null || { echo "no compila test_tornado_arc"; exit 1; }
for a in $ARCS; do
  if r=$(build/tests/test_tornado_arc "$a" 2>&1); then echo "  ok   $(basename "$a"): $(echo "$r" | grep -v salteado | head -1 | sed 's/^[^"]*//')"
  else echo "  FAIL $(basename "$a")"; echo "$r" | sed 's/^/       /'; nf=$((nf+1)); fi
done
[ "$nf" -eq 0 ]
