#!/bin/bash
# Validación de parc_ppmd contra los oráculos reales (arc.exe 0.67.1 / unarc.i386).
#
#  1) Matriz de orden y memoria sobre entradas controladas.
#  2) El bloque PPMd de gen/ppmd.arc (el corpus de 14 archivos), reconstruyendo
#     lo esperado como la concatenación de los archivos en el orden de `lt`/`l`.
#  3) Fuzzing: mutaciones de un byte sobre el payload; se exige NO crash
#     (exit 0 = ok, 1 = bytes distintos, 3 = corrupto declarado). Un signal o un
#     runtime error 217 cuentan como falla.
set -u
P=/mnt/IA_LAB/agentes/PA-Lab/ppmd-port
W=/mnt/IA_LAB/agentes/PA-Lab/ref-clean
SAMPLES=/mnt/IA_LAB/compartido/parc/samples
export WINEPREFIX=/mnt/IA_LAB/agentes/PA-Lab/wine WINEDEBUG=-all
TEST=$P/testppmd
T=$P/val; rm -rf $T; mkdir -p $T; cd $T

ok=0; mal=0
blk() {  # imprime "off size" del bloque de datos MÁS GRANDE (el del método que probamos):
         # en gen/ppmd.arc el primer bloque es "storing" (0 bytes) y el PPMd es el segundo.
         # Ojo: solo filas de bloque (arrancan con espacios y la 4ª columna es el nº de
         # archivos); si no, la línea de totales ("21 files, ...") se cuela como bloque.
  wine $W/Arc.exe lt "$1" 2>/dev/null | sed -n '/Pos/,$p' | \
    awk '/^ +[0-9]/ && $4 ~ /^[0-9]+$/ {p=$1; c=$3; gsub(/,/,"",p); gsub(/,/,"",c);
               if (c+0 > max) {max=c+0; po=p; sz=c}}
         END {print po, sz}'
}
caso() { # $1=archivo entrada  $2=orden  $3=memMB
  local in=$1 ord=$2 mem=$3 a=case.arc
  rm -f $a
  if ! wine $W/Arc.exe a -cfg- -mppmd:$ord:${mem}mb "$a" "$in" >/dev/null 2>&1; then
    printf '  %-28s orden=%-3s mem=%-4s ARC_EXE_FALLO\n' "$(basename $in)" $ord $mem; return
  fi
  read off size <<< "$(blk $a)"
  out=$($TEST $a "$off" "$size" "$in" "$ord" "$mem" 2>&1 | tail -1)
  if [ "$out" = "OK: byte a byte identico al original" ]; then
    ok=$((ok+1)); printf '  %-28s orden=%-3s mem=%-4s OK\n' "$(basename $in)" $ord $mem
  else
    mal=$((mal+1)); printf '  %-28s orden=%-3s mem=%-4s FALLA: %s\n' "$(basename $in)" $ord $mem "$out"
  fi
}

# --- entradas controladas
head -c 300000 "$SAMPLES/src/texto/notas.txt" > a300k.txt
head -c 2097152 "$SAMPLES/src/varios/aleatorio.bin" > rand2m.bin
head -c 1000 "$SAMPLES/src/texto/datos.json" > chico.txt

echo "== barrido de ORDEN (mem 48MB, texto 300KB) =="
for o in 2 4 6 8 10 12 16 24 32; do caso a300k.txt $o 48; done
echo "== barrido de MEMORIA (orden 10, texto 300KB) =="
for m in 1 8 48 256; do caso a300k.txt 10 $m; done
echo "== casos límite: alta entropía y archivo chico =="
caso rand2m.bin 10 48
caso rand2m.bin 16 256
caso rand2m.bin 2 1
caso chico.txt 2 1
caso chico.txt 16 48

# --- bloque PPMd del corpus (gen/ppmd.arc)
# Ojo: NO se reconstruye por nombre (arc.exe l imprime rutas con "\" y \r, y los
# nombres UTF-8 salen mal codificados).  En vez de eso se parte el stream
# decodificado según los TAMAÑOS de `l` y se exige que cada trozo coincida con
# algún archivo de src/ (biyección por sha256).  Así la verificación es real.
echo "== gen/ppmd.arc (corpus de 14 archivos) =="
GEN=$SAMPLES/gen/ppmd.arc
read off size <<< "$(blk $GEN)"
# El test vuelca lo decodificado en <esperado>.dec antes de comparar, así que se
# lo invoca con cualquier esperado y se usa ese volcado.
rm -f chico.txt.dec gen_dec.bin
$TEST $GEN "$off" "$size" chico.txt 10 48 >/dev/null 2>&1
[ -f chico.txt.dec ] && mv chico.txt.dec gen_dec.bin
python3 - "$SAMPLES" "$GEN" <<'PY'
import hashlib, os, subprocess, sys
samples, genpath = sys.argv[1], sys.argv[2]
dec = open('gen_dec.bin','rb').read() if os.path.exists('gen_dec.bin') else b''
# El stream decodificado es la concatenación de los archivos del bloque, en el
# orden del archivo.  En vez de parsear nombres (arc.exe los imprime con "\\",
# CR y en otra codificación), se parte por CONTENIDO: se avanza por el stream
# mientras el prefijo coincida EXACTAMENTE con el contenido de un archivo de
# src/.  Si se consumen los 13 archivos no vacíos y el stream entero, el decode
# es byte a byte correcto.
src = []
for dp, _, fs in os.walk(os.path.join(samples, 'src')):
    for f in sorted(fs):
        data = open(os.path.join(dp, f), 'rb').read()
        if data:
            src.append((os.path.relpath(os.path.join(dp, f), samples), data))
pos, usados = 0, []
while pos < len(dec):
    cand = [x for x in src if dec.startswith(x[1], pos)]
    if len(cand) != 1:
        print(f"  FALLA: en el offset {pos} hay {len(cand)} candidatos (ambiguo o desconocido)")
        sys.exit(1)
    usados.append(cand[0][0]); pos += len(cand[0][1])
faltan = [x[0] for x in src if x[0] not in usados]
print(f"  archivos de src/ no vacíos: {len(src)}   usados al partir el stream: {len(usados)}")
print(f"  bytes decodificados: {len(dec)}   consumidos: {pos}")
if faltan: print("  FALTA usar:", faltan)
ok_total = (not faltan) and pos == len(dec) and len(dec) > 0
print("  gen/ppmd.arc " + ("OK: byte a byte" if ok_total else "FALLA"))
sys.exit(0 if ok_total else 1)
PY
if [ $? -eq 0 ]; then ok=$((ok+1)); else mal=$((mal+1)); fi

# --- fuzzing
echo "== fuzzing (200 mutaciones de 1 byte en el payload de a300k) =="
rm -f fz.arc; wine $W/Arc.exe a -cfg- -mppmd:10:48mb fz.arc a300k.txt >/dev/null 2>&1
read off size <<< "$(blk fz.arc)"
crashes=0; distintos=0; corruptos=0; iguales=0
for i in $(seq 1 200); do
  cp fz.arc mut.arc
  # mutar un byte dentro del payload [off, off+size)
  python3 - "$off" "$size" <<'PY'
import random, sys
off=int(sys.argv[1]); size=int(sys.argv[2])
p='mut.arc'; d=bytearray(open(p,'rb').read())
i=off+random.randrange(size)
d[i]^=1<<random.randrange(8)
open(p,'wb').write(d)
PY
  $TEST mut.arc "$off" "$size" a300k.txt 10 48 >/dev/null 2>&1
  rc=$?
  case $rc in
    0) iguales=$((iguales+1)) ;;
    1) distintos=$((distintos+1)) ;;
    3) corruptos=$((corruptos+1)) ;;
    *) crashes=$((crashes+1)); echo "  CRASH en la mutación $i (rc=$rc)" ;;
  esac
done
echo "  iguales=$iguales distintos=$distintos corruptos-declarados=$corruptos CRASHES=$crashes"
[ $crashes -ne 0 ] && mal=$((mal+1))

echo
echo "===== RESULTADO: $ok OK / $mal FALLAS ====="
[ $mal -eq 0 ]
