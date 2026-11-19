#!/bin/bash
# tests/plz.sh — el códec plz (src/parc_plz.pas, src/parc_plzenc.pas): idas y vueltas en todos
# los niveles y ventanas (entradas vacías, de un byte, chicas, aleatorias, repeticiones enormes,
# más grandes que la ventana), la misma salida en streaming (en trozos fijos o al azar) y en
# memoria, ensamblador = Pascal (-dPARC_NOASM), y streams dañados (cientos): siempre un error
# limpio o datos, nunca un crash ni un cuelgue. Con build/linux64/parc, además por PArc.
# Uso: tests/plz.sh   (PLZ_FUZZ=<n> cambia la cantidad de streams dañados por caso; default 400)
set -u
ROOT=$(cd "$(dirname "$0")/.." && pwd)
B=$ROOT/build/tests
T=$B/test_plz
TN=$B/test_plz_noasm
W=${PLZ_WORK:-${TMPDIR:-/tmp}/parc_plz}
FUZZ=${PLZ_FUZZ:-400}
mkdir -p "$B/plzunits" "$B/plzunits_noasm"
fpc -O3 -Fu"$ROOT/src" -FU"$B/plzunits" -FE"$B" "$ROOT/tests/test_plz.lpr" >/dev/null || { echo "no compila test_plz"; exit 2; }
fpc -O3 -dPARC_NOASM -Fu"$ROOT/src" -FU"$B/plzunits_noasm" -FE"$B" -otest_plz_noasm "$ROOT/tests/test_plz.lpr" >/dev/null || { echo "no compila test_plz (noasm)"; exit 2; }
rm -rf -- "${W:?}"; mkdir -p "$W" && cd "$W" || exit 2
fail=0; pass=0
ck() { if eval "$2"; then pass=$((pass+1)); else fail=$((fail+1)); echo "  FAIL $1"; fi; }

# Entradas
: > empty
printf 'a' > one
printf 'abc' > three
printf 'abcdefgh' > eight
printf 'abcabcabcabcabcab' > rep17
cat "$ROOT"/src/*.pas > text
head -c 3000000 /dev/urandom > rnd
{ head -c 100000 rnd; cat text; head -c 70000 rnd; cat text; } > mix
head -c 20000000 /dev/zero > zeros
python3 -c "
import sys
p=bytes(range(256))*3+b'PArc plz '*7
sys.stdout.buffer.write(p*(40000000//len(p)))" > pattern
head -c 2500000 text > t25
FILES="empty one three eight rep17 text rnd mix zeros pattern"

# 1) todos los niveles con su ventana, y varias ventanas (las chicas obligan a dar la vuelta)
LEVELS=$(seq 1 7)
rt() {   # rt <método> <archivo>: streaming = memoria = streaming al azar = noasm; ida y vuelta
  local m=$1 f=$2 n w
  n=$(stat -c %s "$f")
  "$T" enc "$m" "$f" s.plz 65536 || return 1
  "$T" enc "$m" "$f" r.plz 0 || return 1
  cmp -s s.plz r.plz || { echo "    trozos al azar dan otra salida"; return 1; }
  "$TN" enc "$m" "$f" n.plz 65536 || return 1
  cmp -s s.plz n.plz || { echo "    ensamblador y Pascal difieren"; return 1; }
  "$T" encmem "$m" "$f" m.plz >/dev/null; rc=$?
  if [ $rc -eq 0 ]; then
    # en memoria la ventana se achica al tamaño de la entrada: igual que en streaming con esa ventana
    if ! cmp -s s.plz m.plz; then
      w=$(od -An -tu4 -j1 -N4 m.plz | tr -d ' ')
      "$T" enc "$m:${w}b" "$f" w.plz 65536 || return 1
      cmp -s w.plz m.plz || { echo "    memoria y streaming difieren"; return 1; }
    fi
    "$T" decmem m.plz m.out "$n" && cmp -s "$f" m.out || { echo "    decmem"; return 1; }
  elif [ $rc -ne 3 ]; then return 1; fi
  "$T" dec s.plz s.out && cmp -s "$f" s.out || { echo "    dec"; return 1; }
  "$TN" dec s.plz n.out && cmp -s "$f" n.out || { echo "    dec noasm"; return 1; }
}
for l in $LEVELS; do
  for f in $FILES; do ck "plz:$l $f" "rt plz:$l $f"; done
done
for w in 1kb 4kb 64kb 1mb 8mb; do
  for l in 1 2 4 6; do
    for f in t25 mix pattern; do ck "plz:$l:$w $f" "rt plz:$l:$w $f"; done
  done
done
for m in plz:2:h64kb plz:3:w2:z0 plz:3:w64:z2:n4096 plz:2:x4:k0 plz:5:b16kb plz:5:b1mb plz:1:x7 plz:4:i2 plz:4:i0 plz:1:y0 plz:2:y12:q0 plz:3:w1:g2:y14:u1 plz:3:w1:x6:i0:y16 plz:4:v4:q2 plz:3:y0:w2 plz:3:t0 plz:3:g1:e0 plz:4:t14:e3 plz:3:t16:g1:m16 plz:4:r6 plz:5:t18:g2:e2 plz:3:v4:k8; do
  for f in t25 mix one; do ck "$m $f" "rt $m $f"; done
done

# 2) parámetros inválidos: el codificador los rechaza
for m in plz:0 plz:99 plz:3:w3 plz:3:j1 plz:3:q9 plz:3:g3 plz:3:y30 plz:3:2gb plz:3:b8mb plz:3:x9 plz:3:t27 plz:3:e65 plz:3:r32; do
  ck "rechaza $m" "! '$T' enc $m one bad.plz 2>/dev/null"
done

# 3) streams dañados
"$T" enc plz:3 t25 f1.plz
"$T" enc plz:1:64kb mix f2.plz
"$T" enc plz:6 text f3.plz
head -c 5000 text > t5k; "$T" enc plz:2 t5k f4.plz
"$T" enc plz:1 one f5.plz
for c in "f1.plz t25" "f2.plz mix" "f3.plz text" "f4.plz t5k" "f5.plz one"; do
  set -- $c
  out=$(timeout 600 "$T" fuzz $1 $2 $FUZZ 7); rc=$?
  ck "dañados $1 ($FUZZ): $(echo $out | tr '\n' ' ')" "[ $rc -eq 0 ]"
done
# cortado, con basura detrás, versión o ventana inválidas: error (rc 2)
head -c 100 f1.plz > c.plz;               ck "cortado" "! '$T' dec c.plz c.out >/dev/null"
cat f4.plz one > g.plz;                   ck "basura detrás" "! '$T' dec g.plz g.out >/dev/null"
{ printf '\x02'; tail -c +2 f4.plz; } > v.plz; ck "versión desconocida" "! '$T' dec v.plz v.out >/dev/null"
{ printf '\x01\x00\x00\x00\x80'; tail -c +6 f4.plz; } > w.plz; ck "ventana de 2 GB" "! '$T' dec w.plz w.out >/dev/null"

# 4) por PArc (si está compilado): cadenas con plz, sólido y 4x4, con 1 y 4 hilos
P=$ROOT/build/linux64/parc
if [ -x "$P" ]; then
  mkdir -p d; cp text mix rnd t25 d/; cp one d/; : > d/empty
  for m in plz plz:1 plz:7 4x4:plz:2 4x4:plz:3:1mb rep:96m:256:c256+plz:1 rep+exe+delta+plz:4 rep+exe+delta+4x4:plz:3; do
    for t in 1 4; do
      rm -f a.parc
      ck "parc -m$m (hilos $t)" "PARC_THREADS=$t '$P' a -m$m a.parc d --no-progress >/dev/null && PARC_THREADS=$t '$P' t a.parc --no-progress >/dev/null"
    done
  done
  # La misma salida con 1, 2 y 8 hilos para un plz suelto
  for t in 1 2 8; do rm -f h$t.parc; PARC_THREADS=$t "$P" a -mplz:3 h$t.parc d --no-progress -tk >/dev/null; done
  ck "parc -mplz:3: mismo archivo con 1/2/8 hilos" "cmp -s h1.parc h2.parc && cmp -s h1.parc h8.parc"
fi

echo "plz: $pass ok, $fail fallas"
[ $fail -eq 0 ]
