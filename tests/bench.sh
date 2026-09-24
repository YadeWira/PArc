#!/bin/sh
# Benchmark de descompresión: parc t vs unarc t (mejor de N corridas, tiempo real).
# Uso: tests/bench.sh [N] archivo.arc...   (default N=3)
cd "$(dirname "$0")/.."
PARC=./build/linux64/parc
UNARC=${UNARC:-/mnt/IA_LAB/agentes/PA-Lab/bin/unarc.x64}
N=3
case "${1:-}" in [0-9]*) N=$1; shift ;; esac
best() {  # best <cmd...>: mejor tiempo de N corridas, en segundos
  b=999999
  i=0
  while [ $i -lt $N ]; do
    s=$(date +%s.%N); "$@" >/dev/null 2>&1; e=$(date +%s.%N)
    t=$(echo "$e - $s" | bc); b=$(echo "if ($t < $b) $t else $b" | bc); i=$((i+1))
  done
  echo "$b"
}
printf '%-14s %8s %8s %6s\n' archivo parc unarc ratio
for a in "$@"; do
  p=$(best "$PARC" t "$a"); u=$(cd /tmp && best "$UNARC" t "$a")
  printf '%-14s %7.2fs %7.2fs %6.2f\n' "$(basename "$a" .arc)" "$p" "$u" "$(echo "$u / $p" | bc -l)"
done
