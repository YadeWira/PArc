#!/bin/bash
# tests/determinism.sh — mismo binario, misma entrada, mismo PARC_THREADS => mismo archivo.
#
# Comprime el mismo árbol varias veces con cada nivel (-m0..-m9, -mx, -mxx) y varios
# PARC_THREADS, y exige archivos idénticos byte a byte entre corridas con el mismo N. El
# árbol mezcla lo que toca los caminos con hilos: un grupo $binary de ~20 MB (REP con tareas
# de hashing, exe+delta, varios bloques de 4x4 en paralelo, trozos aleatorios que 4x4 guarda
# tal cual), texto (dict/lzp/grzip/ppmd), datos repetidos para REP y muchos archivos chicos;
# con varios grupos los bloques sólidos se escriben en paralelo (parc_writer).
#
# Entre N distintos la salida PUEDE cambiar, y es legítimo:
#  - los presets eligen alternativas "a|b||c" según los hilos (DecodeMethod(.., BudgetThreads),
#    como -mtN de FreeArc): -m1..-m5 usan otros métodos con N=1, N=2 y N>=3;
#  - lzma ht4 :normal/:max usa con 1 hilo la lista de matches de FreeArc -mt1 y con 2 o más la
#    del multihilo (más chica), como FreeArc.
# Fuera de eso ningún codificador depende de los hilos (bt4 multihilo, 4x4, REP, grzip y los
# bloques en paralelo dan la misma salida que en línea). Como las alternativas llegan hasta
# 3, también se exige que N=4 y N=8 den el mismo archivo en cada nivel: si difieren, algo
# depende de la cantidad de hilos en tiempo de ejecución. Las demás diferencias entre N solo
# se informan.
# Antes de 0909464 (TParallelJob.ResetForReuse no volvía FFinished a 0) REP leía hashes
# viejos según el orden de los hilos y -m3 cambiaba entre corridas: esta prueba lo detecta.
#
# Uso: tests/determinism.sh [parc]
#   DET_LEVELS="0 1 .. xx"  DET_THREADS="1 2 4 8"  DET_RUNS=3  (corridas por nivel y N)
#   DETERMINISM_WORK=<dir>  (default $TMPDIR/parc_determinism)
set -u
ROOT=$(cd "$(dirname "$0")/.." && pwd)
PARC=${1:-$ROOT/build/linux64/parc}
case "$PARC" in /*) ;; *) PARC=$PWD/$PARC ;; esac
LEVELS=${DET_LEVELS:-"0 1 2 3 4 5 6 7 8 9 x xx"}
THREADS=${DET_THREADS:-"1 2 4 8"}
RUNS=${DET_RUNS:-3}
OUT=${DETERMINISM_WORK:-${TMPDIR:-/tmp}/parc_determinism}
rm -rf -- "${OUT:?}"; mkdir -p "$OUT/d/bin" "$OUT/d/txt" "$OUT/d/misc" && cd "$OUT" || exit 2
fail=0; pass=0
ok()  { pass=$((pass+1)); echo "  ok   $*"; }
bad() { fail=$((fail+1)); echo "  FAIL $*"; }

# --- árbol de prueba (~34 MB). Lo aleatorio se genera una vez: todas las corridas ven lo mismo
head -c $((6 << 20)) /dev/urandom > rnd
# $binary: el ejecutable de parc con variantes (REP encuentra las copias, exe/delta el código)
for i in 1 2 3 4; do
  { head -c $((i * 4096)) rnd; cat "$PARC"; tail -c $((i * 65536)) rnd; } > d/bin/p$i.exe
done
# un .dll grande: código, 6 MB aleatorios (bloques de 4x4 guardados) y otra vez código
{ cat "$PARC" "$PARC"; cat rnd; cat "$PARC" "$PARC"; } > d/bin/big.dll
# texto: las fuentes de PArc, en tres variantes
cat "$ROOT"/src/*.pas > d/txt/a.txt
tr 'a-z' 'b-za' < d/txt/a.txt > d/txt/b.txt
rev < d/txt/a.txt > d/txt/c.txt
# REP: 2 MB aleatorios repetidos 3 veces, más 300 archivos chicos
{ head -c $((2 << 20)) rnd; head -c $((2 << 20)) rnd; head -c $((2 << 20)) rnd; } > d/misc/rep.bin
for i in $(seq 1 300); do
  { echo "archivo $i"; tail -c +$((i * 997)) "$ROOT/src/parc_writer.pas" | head -c $((i * 37 % 3000 + 50)); } > d/misc/s$i.dat
done
rm -f rnd
echo "árbol: $(du -sh d | cut -f1), niveles: $LEVELS, hilos: $THREADS, corridas: $RUNS"

declare -A H   # H[nivel,N] = md5 del archivo (de la primera corrida)
for L in $LEVELS; do
  for T in $THREADS; do
    first=""; same=1; sizes=""
    for r in $(seq 1 "$RUNS"); do
      rm -f x.parc
      PARC_THREADS=$T "$PARC" a -m$L x.parc d --no-progress >log 2>&1; rc=$?
      if [ $rc -ne 0 ]; then bad "-m$L N=$T corrida $r: rc=$rc: $(tail -1 log)"; same=2; break; fi
      h=$(md5sum < x.parc | cut -c1-32); sizes="$sizes $(stat -c %s x.parc)"
      if [ -z "$first" ]; then
        first=$h
        # el primero también tiene que decodificar
        PARC_THREADS=$T "$PARC" t x.parc >/dev/null 2>&1 || bad "-m$L N=$T: t falla"
      elif [ "$h" != "$first" ]; then same=0; fi
    done
    H[$L,$T]=$first
    if [ $same -eq 1 ]; then ok "-m$L N=$T: $RUNS corridas idénticas ($sizes )"
    elif [ $same -eq 0 ]; then bad "-m$L N=$T: corridas distintas (tamaños:$sizes )"; fi
  done
  # Entre N: N=4 y N=8 (presets saturados) tienen que coincidir; lo demás se informa
  if [ -n "${H[$L,4]:-}" ] && [ -n "${H[$L,8]:-}" ]; then
    if [ "${H[$L,4]}" = "${H[$L,8]}" ]; then ok "-m$L: N=4 y N=8 dan el mismo archivo"
    else bad "-m$L: N=4 y N=8 dan archivos distintos (algo depende de los hilos en ejecución)"; fi
  fi
  info=""
  for T in $THREADS; do
    for U in $THREADS; do
      [ "$U" -le "$T" ] && continue
      [ -n "${H[$L,$T]:-}" ] && [ "${H[$L,$T]}" = "${H[$L,$U]:-x}" ] && info="$info $T=$U"
    done
  done
  echo "  info -m$L: iguales entre N:${info:- ninguno}"
done

# Métodos explícitos (sin presets): la salida no depende de N, salvo lzma ht4 :normal/:max
# (1 hilo contra 2 o más). Bloques chicos para que 4x4 reparta muchos trabajos entre hilos y
# reuse motores de tor (TTorEncCache) en el orden que salga.
for m in "4x4:tor:3:256kb" "4x4:tor:7:256kb" "4x4:tor:12:256kb" "rep:16mb+4x4:lzma:1mb:normal" \
         "rep:8mb+exe+delta+lzma:8mb:max" "lzma:16mb:max:bt4" "4x4:b512kb:grzip:m1" \
         "dict+lzp+ppmd:6" "lzma:16mb:normal:ht4"; do
  ref=""; hs=""; diff=0
  for T in $THREADS; do
    rm -f x.parc
    PARC_THREADS=$T "$PARC" a -m"$m" x.parc d --no-progress >log 2>&1; rc=$?
    if [ $rc -ne 0 ]; then bad "-m$m N=$T: rc=$rc: $(tail -1 log)"; diff=2; break; fi
    h=$(md5sum < x.parc | cut -c1-32)
    case "$m:$T" in *ht4:1) hs="$hs $T:aparte"; continue ;; esac   # lista de -mt1
    [ -z "$ref" ] && ref=$h
    [ "$h" != "$ref" ] && diff=1
    hs="$hs $T:${h:0:8}"
  done
  if [ $diff -eq 0 ]; then ok "-m$m: misma salida con todo N ($hs )"
  elif [ $diff -eq 1 ]; then bad "-m$m: la salida depende de N ($hs )"; fi
done

echo "determinism: $pass ok, $fail fallos"
cd / && rm -rf -- "${OUT:?}"
[ "$fail" -eq 0 ]
