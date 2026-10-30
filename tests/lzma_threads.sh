#!/bin/bash
# tests/lzma_threads.sh — hilos del match finder multihilo de lzma bajo PARC_THREADS.
#
# Con PARC_THREADS >= 2 las etapas lzma :normal/:max usan el match finder multihilo (bt4 :max
# hasta 3 hilos: el que comprime, el BT y el hash; ht4 :normal 2), con la parte del bloque del
# presupuesto global (LzmaEncThreadsFor); con PARC_THREADS=1, uno solo. Se mide el pico de
# /proc/<pid>/task (hilos que existen) para ver que el multihilo arranca. El tope de hilos
# TRABAJANDO a la vez lo verifica tests/thread_budget.py: con el presupuesto por fichas pueden
# existir hilos ociosos (hashing de REP, pools) sin pasar de PARC_THREADS.
# Solo Linux. Uso: tests/lzma_threads.sh [parc]
set -u
ROOT=$(cd "$(dirname "$0")/.." && pwd)
PARC=${1:-$ROOT/build/linux64/parc}
case "$PARC" in /*) ;; *) PARC=$PWD/$PARC ;; esac
OUT=${LZMA_THREADS_WORK:-${TMPDIR:-/tmp}/parc_lzma_threads}
rm -rf -- "${OUT:?}"; mkdir -p "$OUT/g" && cd "$OUT" || exit 2
fail=0; pass=0
ok()  { pass=$((pass+1)); echo "  ok   $*"; }
bad() { fail=$((fail+1)); echo "  FAIL $*"; }

# un archivo de 8 MB y 4 de 4 MB (base64 de datos aleatorios: lzma :max va rápido sobre esto)
head -c $((6 << 20)) /dev/urandom | base64 > one
mkdir -p g4
for i in 1 2 3 4; do head -c $((3 << 20)) /dev/urandom | base64 > g4/f$i; done

# pico de hilos de un `parc a` con PARC_THREADS=$1 sobre $2, opciones $3...
peak() {
  local T=$1 src=$2; shift 2
  rm -f x.parc
  PARC_THREADS=$T "$PARC" a x.parc "$src" "$@" >/dev/null 2>&1 &
  local pid=$! max=0 t n
  while [ -d /proc/$pid/task ]; do
    t=(/proc/$pid/task/*); n=${#t[@]}
    [ "$n" -gt "$max" ] && max=$n
  done
  wait $pid; RC=$?
  PEAK=$max
}

roundtrip() {
  rm -rf xo; mkdir xo
  if (cd xo && "$PARC" x ../x.parc >/dev/null 2>&1) && diff -r "$1" "xo/$1" >/dev/null
  then ok "$2: extracción idéntica"
  else bad "$2: extracción distinta"; fi
}

# bloque solo: T=1 -> 1 hilo; T=2 -> 2 (BT sin hilo hash); T>=3 -> 3
for T in 1 2 4; do
  peak $T one -mlzma:16mb:max
  want=$T; [ "$want" -gt 3 ] && want=3
  if [ "$RC" -ne 0 ]; then bad "bloque solo, PARC_THREADS=$T: rc=$RC"; continue; fi
  if [ "$PEAK" -eq "$want" ] || { [ "$T" -gt 1 ] && [ "$PEAK" -ge "$want" ]; }; then ok "bloque solo, PARC_THREADS=$T: $PEAK hilos"
  else bad "bloque solo, PARC_THREADS=$T: $PEAK hilos (se esperaban $want)"; fi
  roundtrip one "bloque solo, PARC_THREADS=$T"
done

# ht4 :normal: LZ + el hilo de las filas (2 como mucho)
for T in 1 4; do
  peak $T one -mlzma:16mb:normal
  want=$T; [ "$want" -gt 2 ] && want=2
  if [ "$RC" -ne 0 ]; then bad "ht4 normal, PARC_THREADS=$T: rc=$RC"; continue; fi
  if [ "$PEAK" -eq "$want" ] || { [ "$T" -gt 1 ] && [ "$PEAK" -ge "$want" ]; }; then ok "ht4 normal, PARC_THREADS=$T: $PEAK hilos"
  else bad "ht4 normal, PARC_THREADS=$T: $PEAK hilos (se esperaban $want)"; fi
  roundtrip one "ht4 normal, PARC_THREADS=$T"
done

# rep+lzma en un bloque: lzma usa el match finder multihilo aunque haya rep (antes, con T=2
# rep se quedaba los 2 hilos y lzma corría en uno: -m7 un 50% más lento). Los hilos de hashing
# de rep existen pero casi siempre esperan: al menos lzma (2) + rep.
for T in 2 3 4; do
  peak $T one -mrep:16mb+lzma:16mb:max
  if [ "$RC" -ne 0 ]; then bad "rep+lzma, PARC_THREADS=$T: rc=$RC"; continue; fi
  if [ "$PEAK" -ge 3 ]; then ok "rep+lzma, PARC_THREADS=$T: $PEAK hilos"
  else bad "rep+lzma, PARC_THREADS=$T: $PEAK hilos (se esperaban 3 o más)"; fi
  roundtrip one "rep+lzma, PARC_THREADS=$T"
done

# 4 bloques en paralelo: los 4 se comprimen a la vez (el tope de los que trabajan lo mira
# tests/thread_budget.py).
for T in 4 8; do
  peak $T g4 -s- -mlzma:8mb:max
  if [ "$RC" -ne 0 ]; then bad "4 bloques, PARC_THREADS=$T: rc=$RC"; continue; fi
  if [ "$PEAK" -ge 4 ]; then ok "4 bloques, PARC_THREADS=$T: pico $PEAK hilos"
  else bad "4 bloques, PARC_THREADS=$T: pico $PEAK hilos (se esperaban 4 o más)"; fi
  roundtrip g4 "4 bloques, PARC_THREADS=$T"
done

echo "lzma_threads: $pass ok, $fail fallos"
cd / && rm -rf -- "${OUT:?}"
[ "$fail" -eq 0 ]
