#!/bin/bash
# tests/lzma_threads.sh — hilos del match finder multihilo de lzma bajo PARC_THREADS.
#
# parc_writer concede hilos a las etapas lzma (LzmaEncThreadGrant): un bloque solo recibe todo
# el presupuesto (bt4 :max usa hasta 3: el que comprime, el BT y el hash; ht4 :normal 2) y los bloques en
# paralelo se lo reparten. Sin la concesión el match finder multihilo no corría nunca (un
# hilo con cualquier PARC_THREADS); antes de la concesión, cada bloque abría 3 hilos aunque
# hubiera 4 bloques en paralelo con PARC_THREADS=4.
# Se mide el pico de /proc/<pid>/task. El muestreo solo puede subestimar el pico, así que un
# FAIL por "más que el tope" es real; el mínimo se cumple de sobra porque los hilos del
# match finder viven todo el stream.
#
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
  if [ "$PEAK" -eq "$want" ]; then ok "bloque solo, PARC_THREADS=$T: $PEAK hilos"
  else bad "bloque solo, PARC_THREADS=$T: $PEAK hilos (se esperaban $want)"; fi
  roundtrip one "bloque solo, PARC_THREADS=$T"
done

# ht4 :normal: LZ + el hilo de las filas (2 como mucho)
for T in 1 4; do
  peak $T one -mlzma:16mb:normal
  want=$T; [ "$want" -gt 2 ] && want=2
  if [ "$RC" -ne 0 ]; then bad "ht4 normal, PARC_THREADS=$T: rc=$RC"; continue; fi
  if [ "$PEAK" -eq "$want" ]; then ok "ht4 normal, PARC_THREADS=$T: $PEAK hilos"
  else bad "ht4 normal, PARC_THREADS=$T: $PEAK hilos (se esperaban $want)"; fi
  roundtrip one "ht4 normal, PARC_THREADS=$T"
done

# rep+lzma en un bloque: los hilos de hashing de rep salen de la concesión de lzma
# (CreateEncoderChain), así que el total no pasa de PARC_THREADS; y lzma se queda primero con
# los hilos que le sirven (bt4 :max, 3): T=2 -> lzma 2 y rep en línea; T=3 -> lzma 3 y rep en
# línea; T=4 -> 3 + 1 de rep. Antes con T=2 rep se quedaba 2 hilos y lzma corría en uno solo
# (pico 3, por encima del tope, y -m7 un 50% más lento que con el match finder multihilo).
for T in 2 3 4; do
  peak $T one -mrep:16mb+lzma:16mb:max
  if [ "$RC" -ne 0 ]; then bad "rep+lzma, PARC_THREADS=$T: rc=$RC"; continue; fi
  if [ "$PEAK" -eq "$T" ]; then ok "rep+lzma, PARC_THREADS=$T: $PEAK hilos"
  else bad "rep+lzma, PARC_THREADS=$T: $PEAK hilos (se esperaban $T)"; fi
  roundtrip one "rep+lzma, PARC_THREADS=$T"
done

# 4 bloques en paralelo: los hilos de los bloques se reparten T. Además existen (sin
# trabajar) main, que espera, y el hilo del pool que escribió el grupo del directorio g4.
for T in 4 8; do
  peak $T g4 -s- -mlzma:8mb:max
  lim=$((2 + T))
  if [ "$RC" -ne 0 ]; then bad "4 bloques, PARC_THREADS=$T: rc=$RC"; continue; fi
  if [ "$PEAK" -le "$lim" ]; then ok "4 bloques, PARC_THREADS=$T: pico $PEAK hilos (tope $lim)"
  else bad "4 bloques, PARC_THREADS=$T: pico $PEAK hilos > tope $lim"; fi
  roundtrip g4 "4 bloques, PARC_THREADS=$T"
done

echo "lzma_threads: $pass ok, $fail fallos"
cd / && rm -rf -- "${OUT:?}"
[ "$fail" -eq 0 ]
