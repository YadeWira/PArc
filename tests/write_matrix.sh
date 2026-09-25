#!/bin/bash
# tests/write_matrix.sh — matriz de compatibilidad al revés: PArc COMPRIME y FreeArc lee.
#
# Por cada método o preset: `parc a` sobre el corpus (a .arc), y después
#   parc t · unarc.i386 t · arc.exe t (autoridad) · arc.exe x comparado por sha256 contra el
#   corpus; y lo mismo a .parc (parc t + parc x idéntico, con fechas en ns).
# Un método sin codificador todavía se reporta como "sin-codificador", aparte, no como falla.
#
# Uso: tests/write_matrix.sh [--solo m5,lzma,...] [--keep]
# El corpus es el que genera tests/compat_matrix.sh (correrlo antes una vez).
set -u
export LC_NUMERIC=C   # printf con punto decimal aunque el locale use coma
SOLO=""; KEEP=0
while [ $# -gt 0 ]; do
  case $1 in
    --solo) shift; SOLO=$1 ;;
    --keep) KEEP=1 ;;
    *) echo "opción desconocida: $1" >&2; exit 2 ;;
  esac; shift
done

ROOT=$(cd "$(dirname "$0")/.." && pwd)
PARC=${PARC_BIN:-$ROOT/build/linux64/parc}
ARC_EXE=${ARC_EXE:-/mnt/IA_LAB/agentes/PArc/ref/Arc.exe}
UNARC=${UNARC:-/mnt/IA_LAB/agentes/PA-Lab/bin/unarc.i386}
export WINEPREFIX=${WINEPREFIX:-/mnt/IA_LAB/agentes/PArc/wine} WINEDEBUG=-all
BASE=${WORK:-/mnt/IA_LAB/agentes/PArc/compat}
CORPUS=$BASE/corpus
OUT=${WRITE_WORK:-/mnt/IA_LAB/agentes/PArc/write_matrix}
[ -d "$CORPUS" ] || { echo "no hay corpus en $CORPUS: correr tests/compat_matrix.sh primero" >&2; exit 2; }
mkdir -p "$OUT"

# clave:método (el método es lo que va en -m; puede ser un preset)
METHODS="
m0:0
storing:storing
lzma:lzma
lzma_max:lzma:64mb:max
exe_lzma:exe+lzma:16mb:normal
x4_lzma:4x4:lzma:4mb:normal
ppmd:ppmd:8:32mb
x4_ppmd:4x4:b1mb:ppmd:6:16mb
lzp_ppmd:lzp:8mb:64:h18+ppmd:8:32mb
rep_lzma:rep:96m+lzma:8mb
delta_lzma:delta+lzma:8mb
bin_chain:rep:96m+exe+delta+lzma:96m:normal:32:mc32
bin_chain_x4:rep:96m+exe+delta+4x4:lzma:96mb:normal:32:mc32
lz4:lz4
lz4hc:lz4:hc
x4_lz4:4x4:lz4
m1:1
m2:2
m3:3
m4:4
m5:5
m9:9
mx:x
"

sha_tree() { (cd "$1" && find . -type f -print0 | sort -z | xargs -0 sha256sum); }
REF=$(sha_tree "$CORPUS/..") ; REF_SUM=$(echo "$REF" | grep ' ./corpus/' | sha256sum | cut -c1-16)

ok=0; fail=0; nocod=0; refc=0
printf '%-13s %-9s %-9s %-9s %-10s %-10s %s\n' método 'parc a' 'unarc t' 'arc.exe t' 'arc.exe x' '.parc x' 'tiempo/tamaño'
printf -- '-%.0s' $(seq 1 90); echo
while IFS=: read -r key m; do
  [ -z "$key" ] && continue
  if [ -n "$SOLO" ] && ! echo ",$SOLO," | grep -q ",$key,"; then continue; fi
  arc="$OUT/$key.arc"; parc="$OUT/$key.parc"
  rm -f -- "$arc" "$parc"
  s=$(date +%s.%N)
  msg=$(cd "$BASE" && "$PARC" a "$arc" corpus -m"$m" 2>&1)
  rc=$?; e=$(date +%s.%N)
  if [ $rc -ne 0 ]; then
    if echo "$msg" | grep -q "todavía no hay codificador\|todavía no se puede comprimir"; then
      nocod=$((nocod+1))
      printf '%-13s %-9s %s\n' "$key" 'sin-cod.' "$(echo "$msg" | tail -n +2 | tr -s ' \n' ' ' | cut -c1-70)"
    else
      fail=$((fail+1)); printf '%-13s %-9s %s\n' "$key" 'FALLA' "$(echo "$msg" | tail -1)"
    fi
    continue
  fi
  t=$(printf '%.1fs %s' "$(echo "$e - $s" | bc)" "$(stat -c %s "$arc")")
  u=$(cd /tmp && "$UNARC" t "$arc" 2>&1 | tail -1); [ "$u" = "All OK" ] && u=OK || u=FALLA
  a=$(wine "$ARC_EXE" t "$arc" 2>&1 | tr '\r' '\n' | grep -a -E 'All OK|rror' | tail -1); [ "$a" = "All OK" ] && a=OK || a=FALLA
  x="$OUT/x_$key"; rm -rf -- "$x"; mkdir -p "$x"
  (cd "$x" && wine "$ARC_EXE" x -o+ "$arc" >/dev/null 2>&1)
  xs=$(sha_tree "$x" | grep ' ./corpus/' | sha256sum | cut -c1-16); [ "$xs" = "$REF_SUM" ] && xr=IDÉNTICO || xr=DIFIERE
  # .parc: PArc escribe y lee
  (cd "$BASE" && "$PARC" a "$parc" corpus -m"$m" >/dev/null 2>&1)
  px="$OUT/px_$key"; rm -rf -- "$px"; mkdir -p "$px"
  "$PARC" x "$parc" -dp"$px" >/dev/null 2>&1
  ps=$(sha_tree "$px" | grep ' ./corpus/' | sha256sum | cut -c1-16); [ "$ps" = "$REF_SUM" ] && pr=IDÉNTICO || pr=DIFIERE
  note=""
  if [ $u = OK ] && [ $a = OK ] && [ $xr = IDÉNTICO ] && [ $pr = IDÉNTICO ]; then ok=$((ok+1))
  elif [ $u = FALLA ] && [ $a = OK ] && [ $xr = IDÉNTICO ] && [ $pr = IDÉNTICO ]; then
    # arc.exe (la autoridad) lo acepta y lo extrae idéntico: se cayó la referencia C (el
    # decodificador GRZip de unarc corrompe el heap; le pasa también con .arc de arc.exe)
    refc=$((refc+1)); u="REF-CAE"; note="  (unarc cae; arc.exe OK)"
  else fail=$((fail+1)); fi
  printf '%-13s %-9s %-9s %-9s %-10s %-10s %s%s\n' "$key" OK "$u" "$a" "$xr" "$pr" "$t" "$note"
  [ $KEEP = 1 ] || rm -rf -- "$x" "$px"
done <<< "$METHODS"
echo
echo "===== RESUMEN escritura: $ok OK · $refc OK-con-unarc-caído · $nocod sin codificador · $fail fallas ====="
[ $fail -eq 0 ]
