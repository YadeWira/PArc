#!/bin/bash
# Compara el tamaño y el tiempo de PArc contra FreeArc 0.67.1 en -m1..-m9/-mx.
#
# FreeArc se usa SOLO como oráculo de rendimiento: esto no prueba compatibilidad .arc
# (PArc no lee ni escribe .arc). Se invoca con -cfg- para que use sus presets internos y
# no los de un arc.ini local.
#
# Uso:
#   ARC_EXE=/ruta/al/Arc.exe bash tests/bench_vs_freearc.sh <corpus> [más corpus...]
#
# Variables:
#   ARC_EXE    Arc.exe de FreeArc 0.67.1 (obligatoria)
#   WINEPREFIX prefijo de Wine (por defecto $HOME/.wine)
#   PARC       binario de PArc (por defecto build/linux64/parc)
#   LEVELS     niveles a probar (por defecto "1 2 3 4 5 6 7 8 9 x")
set -u

ROOT=$(cd "$(dirname "$0")/.." && pwd)
PARC=${PARC:-$ROOT/build/linux64/parc}
: "${ARC_EXE:?definí ARC_EXE con el Arc.exe de FreeArc 0.67.1}"
export WINEPREFIX=${WINEPREFIX:-$HOME/.wine}
LEVELS=${LEVELS:-1 2 3 4 5 6 7 8 9 x}

[ $# -ge 1 ] || { echo "uso: ARC_EXE=... $0 <corpus> [más corpus...]" >&2; exit 2; }
[ -x "$PARC" ] || { echo "no existe $PARC (compilá con ./build.sh linux64)" >&2; exit 2; }

TMP=$(mktemp -d) || exit 1
trap 'rm -rf "$TMP"' EXIT

now_ns() { date +%s%N; }

printf "%-24s %3s %12s %12s %9s %9s %9s\n" "corpus" "m" "parc" "arc" "delta" "t_parc" "t_arc"
for corpus in "$@"; do
  [ -e "$corpus" ] || { echo "no existe: $corpus" >&2; continue; }
  name=$(basename "$corpus")
  for m in $LEVELS; do
    rm -f "$TMP/p.parc" "$TMP/a.arc"
    t0=$(now_ns)
    "$PARC" a "$TMP/p.parc" "$corpus" -m"$m" --no-progress >/dev/null 2>&1
    t1=$(now_ns)
    wine "$ARC_EXE" a -cfg- "$TMP/a.arc" "$corpus" -m"$m" >/dev/null 2>&1
    t2=$(now_ns)
    ps=$(stat -c%s "$TMP/p.parc" 2>/dev/null || echo 0)
    as=$(stat -c%s "$TMP/a.arc" 2>/dev/null || echo 0)
    if [ "$ps" -gt 0 ] && [ "$as" -gt 0 ]; then
      delta=$(awk "BEGIN{printf \"%+.2f%%\", 100*($ps-$as)/$as}")
    else
      delta="FALLA"
    fi
    tp=$(awk "BEGIN{printf \"%.2f\", ($t1-$t0)/1e9}")
    ta=$(awk "BEGIN{printf \"%.2f\", ($t2-$t1)/1e9}")
    printf "%-24s %3s %12d %12d %9s %9s %9s\n" "$name" "$m" "$ps" "$as" "$delta" "$tp" "$ta"
  done
done
