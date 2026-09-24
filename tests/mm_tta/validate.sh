#!/bin/bash
# Valida parc_mm y parc_tta contra arc.exe (autoridad): decodifica el payload de
# un .arc de método único y lo compara byte a byte con el original.
set -u
D=/mnt/IA_LAB/agentes/PA-Lab/mm-tta-port
R=/mnt/IA_LAB/agentes/PA-Lab/ref-clean
export WINEPREFIX=/mnt/IA_LAB/agentes/PA-Lab/wine WINEDEBUG=-all
TEST=$D/teststage
M=$D/media
W=${W:-/tmp/mtval}; rm -rf $W; mkdir -p $W; cd $W

ok=0; mal=0; casos=""
blk() {  # offset y tamaño comprimido del bloque de datos más grande
  wine $R/Arc.exe lt "$1" 2>/dev/null | sed -n '/Pos/,$p' | \
    awk '/^ +[0-9]/ && $4 ~ /^[0-9]+$/ {p=$1;c=$3;gsub(/,/,"",p);gsub(/,/,"",c);
         if (c+0>max){max=c+0;po=p;sz=c}} END {print po, sz}'
}
probar() { # $1 = media  $2 = spec de método (sin el -m)
  local f=$1 spec=$2 a=case.arc
  rm -f $a
  cp "$M/$f" .
  if ! wine $R/Arc.exe a -cfg- -m"$spec" "$a" "$f" >/dev/null 2>&1; then
    printf '  %-22s %-14s ARC.EXE FALLO\n' "$f" "$spec"; mal=$((mal+1)); return
  fi
  local real; real=$(wine $R/Arc.exe lt "$a" 2>/dev/null | sed -n '/Pos/,$p' | sed -n '3p' | awk '{for(i=5;i<=NF;i++) printf "%s ", $i}')
  set -- $(blk "$a")
  local off=$1 sz=$2
  local out; out=$($TEST "$a" "$off" "$sz" "$f" "$spec" 2>&1 | tail -1)
  if [ "$out" = "OK: byte a byte identico al original" ]; then
    ok=$((ok+1)); printf '  %-22s %-16s OK   (%s)\n' "$f" "$spec" "$real"
  else
    mal=$((mal+1)); printf '  %-22s %-16s FALLA: %s   (metodo real: %s)\n' "$f" "$spec" "$out" "$real"
    casos="$casos $f/$spec"
  fi
}

echo "== MM sobre BMP (8/24/32 bits) =="
for f in b8.bmp b24.bmp b32.bmp; do probar $f "mm"; done
echo "== MM forzando formato =="
probar b24.bmp "mm:1*24"
probar b32.bmp "mm:1*32"
probar b8.bmp  "mm:1*8"
echo "== MM sobre WAV =="
probar w16_2ch_44100.wav "mm"
probar w8_1ch_44100.wav  "mm"
echo "== TTA sobre WAV (todos los formatos) =="
for f in w8_1ch_44100.wav w8_2ch_44100.wav w16_1ch_44100.wav w16_2ch_44100.wav \
         w24_1ch_44100.wav w24_2ch_44100.wav w16_2ch_48000.wav w16_1ch_48000.wav; do
  probar $f "tta"
done
echo "== TTA con niveles =="
probar w16_2ch_44100.wav "tta:m1"
probar w16_2ch_44100.wav "tta:m2"
echo
echo "== fuzzing (100 mutaciones de 1 byte sobre el payload) =="
fuzz() { # $1=media  $2=spec
  local f=$1 spec=$2 a=fz.arc cr=0 rc
  rm -f $a; cp "$M/$f" .
  wine $R/Arc.exe a -cfg- -m"$spec" "$a" "$f" >/dev/null 2>&1
  set -- $(blk "$a")
  local off=$1 sz=$2
  for i in $(seq 1 100); do
    cp "$a" m.arc
    python3 - "$off" "$sz" <<'PY'
import random, sys
off, size = int(sys.argv[1]), int(sys.argv[2])
p = 'm.arc'; d = bytearray(open(p, 'rb').read())
i = off + random.randrange(size)
d[i] ^= 1 << random.randrange(8)
open(p, 'wb').write(d)
PY
    $TEST m.arc "$off" "$sz" "$f" "$spec" >/dev/null 2>&1; rc=$?
    # 0 = ok, 1 = bytes distintos, 3 = corrupto declarado: todos aceptables
    if [ $rc -ne 0 ] && [ $rc -ne 1 ] && [ $rc -ne 3 ]; then
      cr=$((cr+1)); echo "  CRASH (rc=$rc) en $f/$spec mutación $i"
    fi
  done
  printf '  %-22s %-8s %d crashes en 100 mutaciones\n' "$f" "$spec" "$cr"
  [ $cr -ne 0 ] && mal=$((mal+1))
}
fuzz b32.bmp "mm:1*32"
fuzz w16_2ch_44100.wav "tta"

echo
echo "===== MM/TTA: $ok OK / $mal FALLAS ====="
[ -n "$casos" ] && echo "fallas:$casos"
[ $mal -eq 0 ]
