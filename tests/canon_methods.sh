#!/bin/bash
# tests/canon_methods.sh — el método que PArc guarda es el mismo texto canónico que arc.exe.
#
# Por cada método explícito (-m4x4, -mtor:16, ...) se arma el mismo árbol con arc.exe y con
# PArc y se compara el método del primer bloque de datos (`parc lb`). Además, arc.exe tiene
# que poder verificar y extraer lo que escribió PArc.
#
# Necesita wine + Arc.exe (como order_matrix/update_matrix).
set -u
ROOT=$(cd "$(dirname "$0")/.." && pwd)
PARC=${PARC_BIN:-$ROOT/build/linux64/parc}
ARC_EXE=${ARC_EXE:-/mnt/IA_LAB/agentes/PArc/ref/Arc.exe}
export WINEPREFIX=${WINEPREFIX:-/mnt/IA_LAB/agentes/PArc/wine} WINEDEBUG=-all
OUT=${CANON_WORK:-/mnt/IA_LAB/agentes/PArc/canon_methods}
rm -rf -- "${OUT:?}"; mkdir -p "$OUT/c" && cd "$OUT" || exit 2

C=$OUT/c
seq 1 12000 > "$C/a.txt"; seq 3 15000 > "$C/b.txt"
head -c 90000 /dev/urandom > "$C/c.bin"
touch -d '2020-01-01' "$C"/*
fail=0; pass=0
ok()  { pass=$((pass+1)); echo "  ok   $*"; }
bad() { fail=$((fail+1)); echo "  FAIL $*"; }

# métodos explícitos: 4x4 (con y sin interno/parámetros), tornado por número, y los demás
METHODS="4x4 4x4:lzma 4x4:t2 4x4:b16mb tor tor:16 tor:10 rep rep:96m lzma dict ppmd grzip lzp delta mm tta exe"
for m in $METHODS; do
  rm -f a.arc p.arc
  if ! wine "$ARC_EXE" a -m$m a.arc c </dev/null >/dev/null 2>&1; then
    echo "  skip $m (arc.exe no comprime)"; continue
  fi
  if ! "$PARC" a -m$m p.arc c --no-progress >/dev/null 2>&1; then bad "$m: parc no comprime"; continue; fi
  am=$("$PARC" lb a.arc | grep ' data ' | sed -n '2p' | awk '{print $NF}')
  pm=$("$PARC" lb p.arc | grep ' data ' | sed -n '2p' | awk '{print $NF}')
  if [ "$am" = "$pm" ]; then ok "$m ($pm)"; else bad "$m: arc=[$am] parc=[$pm]"; fi
  wine "$ARC_EXE" t p.arc </dev/null >/dev/null 2>&1 && ok "$m: arc.exe t" || bad "$m: arc.exe t rechaza el de parc"
  rm -rf x; mkdir x
  if wine "$ARC_EXE" x p.arc -o+ -dpx </dev/null >/dev/null 2>&1 && diff -r c x/c >/dev/null; then
    ok "$m: arc.exe x idéntico"
  else bad "$m: arc.exe x difiere"; fi
done

# Método todavía no soportado: `parc` sale con 3 ("no soportado"), no con 2 ("datos dañados").
# (Hoy SREP no está portado; cuando lo esté, cambiar este caso por un método inventado.)
rm -f s.arc
if wine "$ARC_EXE" a -msrep s.arc c </dev/null >/dev/null 2>&1; then
  out=$("$PARC" t s.arc 2>&1); code=$?
  [ $code = 3 ] && ok "método no soportado: código 3" || bad "método no soportado: código $code (esperado 3)"
  echo "$out" | grep -q "no soportado" && ok "método no soportado: lo informa" || bad "método no soportado: no lo informa"
else
  echo "  skip método no soportado (arc.exe no crea srep)"
fi

echo "== métodos canónicos: $pass ok, $fail fallas"
[ $fail -eq 0 ]
