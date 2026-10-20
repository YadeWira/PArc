#!/bin/bash
# tests/containers.sh — .zip (lectura y escritura), .7z y .rar (sólo lectura) vía 7-Zip ZS.
#
# PArc delega esos formatos en el binario 7zz (no los implementa). El test se saltea si no
# encuentra 7zz: PARC_7ZZ, build/<target>/7zz o el PATH. Para compilarlo: tools/build-7zz.sh.
set -u
ROOT=$(cd "$(dirname "$0")/.." && pwd)
PARC=${PARC_BIN:-$ROOT/build/linux64/parc}
Z=${PARC_7ZZ:-}
if [ -z "$Z" ]; then
  for c in "$ROOT/build/linux64/7zz" "$(command -v 7zz 2>/dev/null)" "$(command -v 7z 2>/dev/null)"; do
    [ -n "$c" ] && [ -x "$c" ] && { Z=$c; break; }
  done
fi
if [ -z "$Z" ] || [ ! -x "$Z" ]; then
  echo "  skip: no hay 7zz (definí PARC_7ZZ o compilá con tools/build-7zz.sh)"
  exit 0
fi
export PARC_7ZZ=$Z
OUT=${CONTAINERS_WORK:-/tmp/opencode/containers_test}
rm -rf -- "${OUT:?}"; mkdir -p "$OUT/c" && cd "$OUT" || exit 2

C=$OUT/c
seq 1 20000 > "$C/a.txt"
head -c 60000 /dev/urandom > "$C/b.bin"
mkdir -p "$C/sub"; seq 1 5000 > "$C/sub/d.txt"
touch -d '2025-01-01' "$C"/* "$C/sub"/*
fail=0; pass=0
ok()  { pass=$((pass+1)); echo "  ok   $*"; }
bad() { fail=$((fail+1)); echo "  FAIL $*"; }

echo "== zip: crear, listar, verificar, extraer"
if "$PARC" a t.zip c >/dev/null 2>&1; then ok "parc a"; else bad "parc a"; fi
"$Z" t t.zip >/dev/null 2>&1 && ok "7zz t" || bad "7zz t"
"$PARC" t t.zip >/dev/null 2>&1 && ok "parc t" || bad "parc t"
rm -rf x7 xp; mkdir x7 xp
"$Z" x t.zip -ox7 -y >/dev/null 2>&1 && "$PARC" x t.zip -dpxp -o+ >/dev/null 2>&1 && diff -r x7/c xp/c >/dev/null \
  && ok "extracción de PArc = 7zz" || bad "extracción de PArc != 7zz"

echo "== zip con ZSTD"
"$PARC" a z.zip c -mzstd:5 >/dev/null 2>&1 || bad "parc a -mzstd:5"
if "$Z" l -slt z.zip 2>/dev/null | grep -q "Method = zstd"; then ok "método zstd"; else bad "método zstd"; fi
"$PARC" t z.zip >/dev/null 2>&1 && ok "parc t (zstd)" || bad "parc t (zstd)"

echo "== zip: u, f y d"
seq 1 60000 > "$C/a.txt"; touch -d '2027-01-01' "$C/a.txt"
seq 1 700 > "$C/nuevo.txt"; touch -d '2027-01-01' "$C/nuevo.txt"
"$PARC" u t.zip c >/dev/null 2>&1 || bad "parc u"
rm -rf u; mkdir u; "$PARC" x t.zip -dpu -o+ >/dev/null 2>&1
cmp -s "$C/a.txt" u/c/a.txt && [ -f u/c/nuevo.txt ] && ok "u agrega y reemplaza" || bad "u agrega y reemplaza"
seq 1 90000 > "$C/a.txt"; touch -d '2027-06-01' "$C/a.txt"
seq 1 800 > "$C/otro.txt"; touch -d '2027-06-01' "$C/otro.txt"
"$PARC" f t.zip c >/dev/null 2>&1 || bad "parc f"
rm -rf f; mkdir f; "$PARC" x t.zip -dpf -o+ >/dev/null 2>&1
cmp -s "$C/a.txt" f/c/a.txt && [ ! -f f/c/otro.txt ] && ok "f reemplaza sin agregar" || bad "f reemplaza sin agregar"
"$PARC" d t.zip c/sub/d.txt >/dev/null 2>&1 || bad "parc d"
"$Z" l t.zip 2>/dev/null | grep -q "sub/d.txt" && bad "d no borró" || ok "d borra"

echo "== zip: e (plano), -x y -m0"
rm -rf e; mkdir e
"$PARC" e t.zip -dpe >/dev/null 2>&1 && [ -f e/a.txt ] && [ -f e/nuevo.txt ] && ok "e plano" || bad "e plano"
"$PARC" a xs.zip c -x'*.bin' >/dev/null 2>&1
"$Z" l xs.zip 2>/dev/null | grep -q "\.bin" && bad "-x no excluye" || ok "-x excluye"
"$PARC" a s0.zip c -m0 >/dev/null 2>&1
"$Z" l -slt s0.zip 2>/dev/null | grep -q "Method = Store" && ok "-m0 guarda" || bad "-m0 guarda"

echo "== 7z: sólo lectura"
rm -f t.7z
"$Z" a -t7z t.7z c >/dev/null 2>&1
"$PARC" t t.7z >/dev/null 2>&1 && ok "parc t 7z" || bad "parc t 7z"
rm -rf x7z; mkdir x7z
"$PARC" x t.7z -dpx7z -o+ >/dev/null 2>&1 && diff -r c x7z/c >/dev/null && ok "parc x 7z" || bad "parc x 7z"
"$PARC" a t.7z c >/dev/null 2>&1; [ $? -eq 1 ] && ok "7z escritura rechazada (código 1)" || bad "7z escritura rechazada"

echo "== rar: sólo lectura"
RAR=${RAR_SAMPLE:-}
if [ -z "$RAR" ] && [ -d /mnt/OSR_D3/fileFormatSamples/fileFormatSamples/archive/rar ]; then
  RAR=$(find /mnt/OSR_D3/fileFormatSamples/fileFormatSamples/archive/rar -iname '*.rar' -size -300k 2>/dev/null | head -1)
fi
if [ -n "$RAR" ] && [ -f "$RAR" ]; then
  cp "$RAR" sample.rar
  "$PARC" t sample.rar >/dev/null 2>&1 && ok "parc t rar" || bad "parc t rar"
  rm -rf xr; mkdir xr
  if "$PARC" x sample.rar -dpxr -o+ >/dev/null 2>&1 && [ -n "$(find xr -type f | head -1)" ]; then
    ok "parc x rar"
  else bad "parc x rar"; fi
  "$PARC" a sample.rar c >/dev/null 2>&1; [ $? -eq 1 ] && ok "rar escritura rechazada" || bad "rar escritura rechazada"
else
  echo "  skip: no hay muestra .rar (definí RAR_SAMPLE)"
fi

echo "== binario ausente"
PARC_7ZZ=/no/existe "$PARC" l t.zip >/dev/null 2>&1; [ $? -eq 4 ] && ok "sin 7zz: código 4" || bad "sin 7zz: código 4"

echo "== contenedores: $pass ok, $fail fallas"
[ $fail -eq 0 ]
