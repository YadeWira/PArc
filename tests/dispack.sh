#!/bin/bash
# tests/dispack.sh — DisPack (método dispack070) en .parc y contra el C original.
#
#  1. PArc crea un .parc con -mdispack, lo verifica y lo extrae.
#  2. El filtro de PArc (tests/test_dispack) se compara byte a byte con el C
#     (tests/dispack_ref + reference/freearc-0.67/Compression/DisPack).
#  3. Un bloque dañado termina con código 2, sin crash.
set -u
ROOT=$(cd "$(dirname "$0")/.." && pwd)
PARC=${PARC_BIN:-$ROOT/build/linux64/parc}
REF=$ROOT/reference/freearc-0.67/Compression
OUT=${DISPACK_WORK:-/tmp/opencode/dispack_test}
rm -rf -- "${OUT:?}"; mkdir -p "$OUT/c" && cd "$OUT" || exit 2
fail=0; pass=0
ok()  { pass=$((pass+1)); echo "  ok   $*"; }
bad() { fail=$((fail+1)); echo "  FAIL $*"; }

C=$OUT/c
cp "$PARC" "$C/parc.bin"                 # un binario real: es donde DisPack filtra
seq 1 30000 > "$C/a.txt"
head -c 70000 /dev/urandom > "$C/r.bin"
touch -d '2020-01-01' "$C"/*

echo "== .parc con dispack070"
rm -f d.parc
if "$PARC" a d.parc c -mdispack --no-progress >/dev/null 2>&1; then ok "parc a -mdispack"; else bad "parc a -mdispack"; fi
"$PARC" t d.parc >/dev/null 2>&1 && ok "parc t" || bad "parc t"
rm -rf x; mkdir x
"$PARC" x d.parc -o+ -dpx >/dev/null 2>&1 && diff -r c x/c >/dev/null && ok "parc x idéntico" || bad "parc x"

echo "== filtro vs C original"
mkdir -p "$ROOT/build/tests"
if g++ -O2 -w -DFREEARC_UNIX -DFREEARC_INTEL_BYTE_ORDER -I"$REF" -I"$REF/DisPack" \
     -o dispack_ref "$ROOT/tests/dispack_ref.cpp" "$REF/DisPack/DisPack.cpp" 2>/dev/null; then
  ok "compila dispack_ref"
else
  bad "no compila dispack_ref"
fi
fpc -O2 -Fu"$ROOT/src" -FU"$ROOT/build/tests" -FE"$ROOT/build/tests" "$ROOT/tests/test_dispack.lpr" >/dev/null \
  && ok "compila test_dispack" || bad "no compila test_dispack"
for f in "$C/parc.bin" "$C/a.txt" "$C/r.bin"; do
  size=$(stat -c%s "$f")
  ./dispack_ref f 1073741824 < "$f" > ref.f
  "$ROOT/build/tests/test_dispack" f 1073741824 < "$f" > parc.f
  cmp -s ref.f parc.f && ok "filtro idéntico: $(basename "$f")" || bad "filtro distinto: $(basename "$f")"
  ./dispack_ref u 1073741824 "$size" < parc.f > parc.u
  cmp -s "$f" parc.u && ok "vuelta: $(basename "$f")" || bad "vuelta: $(basename "$f")"
done

echo "== bloque dañado"
cp d.parc bad.parc
python3 - <<'EOF'
d = bytearray(open('bad.parc', 'rb').read())
d[200] ^= 0x55
open('bad.parc', 'wb').write(d)
EOF
"$PARC" t bad.parc >/dev/null 2>&1; code=$?
[ $code = 2 ] && ok "código 2" || bad "código $code (esperado 2)"

echo "== dispack: $pass ok, $fail fallas"
[ $fail -eq 0 ]
