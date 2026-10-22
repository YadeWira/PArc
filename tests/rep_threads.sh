#!/bin/bash
# tests/rep_threads.sh — tope de hilos del codificador REP con bloques en paralelo.
#
# Los hilos de hashing de REP (RepHashThreads, máx. 2) son un tope para todo el proceso, no
# por etapa: con -s- cada archivo es un bloque y los bloques se escriben en paralelo
# (ThreadCount(4) hilos en parc_writer), cada uno con su etapa REP. Antes cada etapa creaba
# su propio pool de 2 hilos y el pico era main + escritores + 2*escritores.
# Se mide el pico de /proc/<pid>/task y se exige <= main + escritores + 2. El muestreo solo
# puede subestimar el pico, así que un FAIL es real.
#
# Solo Linux. Uso: tests/rep_threads.sh [parc]
set -u
ROOT=$(cd "$(dirname "$0")/.." && pwd)
PARC=${1:-$ROOT/build/linux64/parc}
case "$PARC" in /*) ;; *) PARC=$PWD/$PARC ;; esac
OUT=${REP_THREADS_WORK:-${TMPDIR:-/tmp}/parc_rep_threads}
rm -rf -- "${OUT:?}"; mkdir -p "$OUT/g" && cd "$OUT" || exit 2
fail=0; pass=0
ok()  { pass=$((pass+1)); echo "  ok   $*"; }
bad() { fail=$((fail+1)); echo "  FAIL $*"; }

# 4 archivos de 48 MB: 16 MB aleatorios repetidos 3 veces (REP encuentra coincidencias)
head -c $((16 << 20)) /dev/urandom > seed
for i in 1 2 3 4; do
  { head -c 4096 /dev/urandom; cat seed seed seed; } > g/f$i
done
rm -f seed

# pico de hilos de un `parc a` con PARC_THREADS=$1
peak() {
  rm -f x.parc
  PARC_THREADS=$1 "$PARC" a x.parc g -s- -mrep:96mb:256 >/dev/null 2>&1 &
  local pid=$! max=0 t n
  while [ -d /proc/$pid/task ]; do
    t=(/proc/$pid/task/*); n=${#t[@]}
    [ "$n" -gt "$max" ] && max=$n
  done
  wait $pid; RC=$?
  PEAK=$max
}

for T in 2 4; do
  peak $T
  lim=$((1 + T + 2))
  if [ "$RC" -ne 0 ]; then bad "PARC_THREADS=$T: rc=$RC"; continue; fi
  if [ "$PEAK" -le "$lim" ]; then ok "PARC_THREADS=$T: pico $PEAK hilos (tope $lim)"
  else bad "PARC_THREADS=$T: pico $PEAK hilos > tope $lim"; fi
  rm -rf xo; mkdir xo
  if (cd xo && "$PARC" x ../x.parc >/dev/null 2>&1) && cmp -s g/f1 xo/g/f1 && cmp -s g/f4 xo/g/f4
  then ok "PARC_THREADS=$T: extracción idéntica"
  else bad "PARC_THREADS=$T: extracción distinta"; fi
done

echo "rep_threads: $pass ok, $fail fallos"
cd / && rm -rf -- "${OUT:?}"
[ "$fail" -eq 0 ]
