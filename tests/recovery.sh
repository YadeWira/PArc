#!/bin/bash
# Regresión de parc r: daña sectores de un .arc con -rr4% (creado por arc.exe) y compara la
# reparación de parc con la de arc.exe r y con el original.
set -u
ROOT=$(cd "$(dirname "$0")/.." && pwd)
P=${PARC_BIN:-$ROOT/build/linux64/parc}
ARC_EXE=${ARC_EXE:-/mnt/IA_LAB/agentes/PArc/ref/Arc.exe}
export WINEPREFIX=${WINEPREFIX:-/mnt/IA_LAB/agentes/PArc/wine} WINEDEBUG=-all
O=${RR_ARC:-/mnt/IA_LAB/compartido/parc/samples/rr/r4.arc}
W=$(mktemp -d); trap 'rm -rf -- "$W"' EXIT; cd "$W"
fail=0
prueba() {   # prueba <esperado: repara|no> <sectores...>
  local want=$1; shift
  cp "$O" dam.arc
  python3 -c "
import sys
d=bytearray(open('dam.arc','rb').read())
for s in sys.argv[1:]: d[1000+int(s)*512+7] ^= 0x5A
open('dam.arc','wb').write(d)" "$@"
  rm -f fixed.dam.arc p_fixed.arc
  "$P" r dam.arc >/dev/null 2>&1; [ -f fixed.dam.arc ] && mv fixed.dam.arc p_fixed.arc
  wine "$ARC_EXE" r dam.arc >/dev/null 2>&1
  if [ "$want" = repara ]; then
    if [ -f p_fixed.arc ] && cmp -s p_fixed.arc fixed.dam.arc && cmp -s p_fixed.arc "$O"; then r=ok; else r=FALLA; fi
  else
    if [ ! -f p_fixed.arc ] && [ ! -f fixed.dam.arc ]; then r=ok; else r=FALLA; fi
  fi
  [ $r = ok ] || fail=$((fail+1))
  echo "  $r  daño en sectores $* (esperado: $want)"
  rm -f fixed.dam.arc p_fixed.arc dam.arc
}
prueba repara 3
prueba repara 0 1 2 3 4 5 6
prueba repara 10 20 30
prueba no 0 7
echo "== recovery: $fail fallas"
[ $fail -eq 0 ]
