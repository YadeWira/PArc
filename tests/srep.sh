#!/bin/bash
# tests/srep.sh — decodificador SREP contra el srep de referencia (Compression/SREP/srep.cpp).
#
# El srep del repo no compila tal cual contra el Common.h actual (es de 2013): se arma una
# copia en un temporal con dos ajustes mínimos (el typedef `index`, que choca con el de
# <strings.h>, y BigAlloc/file_seek_cur del modo Windows). Después se generan streams con
# `-m3f` (formato v3, el que usa arc.ini) y se comparan con `tests/test_srep`.
#
# No usa wine. Uso: tests/srep.sh
set -u
ROOT=$(cd "$(dirname "$0")/.." && pwd)
OUT=${SREP_WORK:-/tmp/opencode/srep_test}
PARC_SRC=$ROOT/src
rm -rf -- "${OUT:?}"; mkdir -p "$OUT" && cd "$OUT" || exit 2
fail=0; pass=0
ok()  { pass=$((pass+1)); echo "  ok   $*"; }
bad() { fail=$((fail+1)); echo "  FAIL $*"; }

echo "== compilar srep de referencia"
mkdir -p ref && cp -a "$ROOT/reference/freearc-0.67/Compression" ref/ 2>/dev/null
S=ref/Compression/SREP
sed -i 's/\bindex\b/srep_index/g' "$S/compress_inmem.cpp" "$S/compress_cdc.cpp" "$S/compress.cpp" "$S/srep.cpp"
cat > "$S/ref_wrap.cpp" <<'EOF'
#include "../Common.h"
#ifndef FREEARC_WIN
enum LPType {DEFAULT, FORCE, DISABLE, TRY};
static void* BigAllocLP(int64 size, LPType mode=DEFAULT) { (void)mode; return MyAlloc((size_t)size); }
#undef BigAlloc
#define BigAlloc(...) BigAllocLP(__VA_ARGS__)
#define file_seek_cur(stream,pos) (fseeko64(stream, (pos), SEEK_CUR))
#endif
#include "srep.cpp"
EOF
if ! ( cd "$S" && g++ -DFREEARC_UNIX -DFREEARC_INTEL_BYTE_ORDER -D_FILE_OFFSET_BITS=64 -O2 -DMY_MEMCPY \
        -I. -I../_Encryption -I../_Encryption/headers -I../_Encryption/hashes \
        ../Common.cpp ref_wrap.cpp -o "$OUT/srep_ref" -lrt -lpthread -lstdc++ \
        -Wno-write-strings -Wno-unused-result ) 2>"$OUT/build.log"; then
  echo "  skip: no se pudo compilar el srep de referencia (ver $OUT/build.log)"
  echo "== srep: 0 ok, 0 failures (omitido)"
  exit 0
fi
ok "srep_ref"

echo "== compilar tests/test_srep"
mkdir -p "$OUT/units"
if ! fpc -O2 -Fu"$PARC_SRC" -FU"$OUT/units" -FE"$OUT" "$ROOT/tests/test_srep.lpr" >"$OUT/test.log" 2>&1; then
  echo "  FAIL no compila tests/test_srep (ver $OUT/test.log)"; exit 1
fi
ok "test_srep"

echo "== ida y vuelta"
gen() {
  case $1 in
    text) seq 1 "$2" > f ;;
    rep)  head -c 50000 /dev/urandom > x; for i in $(seq 1 "$2"); do cat x; done > f ;;
    rand) head -c "$2" /dev/urandom > f ;;
    mix)  seq 1 100000 > f; head -c 200000 /dev/urandom >> f; seq 1 100000 >> f ;;
  esac
}
for spec in "text 200000" "rep 200" "rand 100000" "mix 1" "text 3000000"; do
  set -- $spec; gen "$1" "$2"; sz=$(stat -c%s f)
  if ! "$OUT/srep_ref" -m3f f f.srep >/dev/null 2>&1; then bad "srep_ref falla ($spec)"; continue; fi
  if ! "$OUT/test_srep" f.srep f.out >/dev/null 2>&1; then bad "decode falla ($1 $2, $sz bytes)"; continue; fi
  cmp -s f f.out && ok "$1 $2 ($sz bytes)" || bad "difiere $1 $2 ($sz bytes)"
done

echo "== bloque (byte de guardado)"
head -c 300000 /dev/urandom > f; "$OUT/srep_ref" -m3f f f.srep >/dev/null 2>&1
python3 - <<'EOF'
d = open('f.srep', 'rb').read()
open('f.flag1', 'wb').write(b'\x01' + d)          # comprimido por srep
open('f.raw', 'wb').write(b'\x00' + open('f', 'rb').read())   # guardado tal cual
EOF
"$OUT/test_srep" f.flag1 f.o1 >/dev/null 2>&1 && cmp -s f f.o1 && ok "flag 1" || bad "flag 1"
"$OUT/test_srep" f.raw f.o2 >/dev/null 2>&1 && cmp -s f f.o2 && ok "flag 0 (guardado)" || bad "flag 0"

echo "== v2 format (I/O LZ)"
for opt in -m0o -m1o; do
  gen text 200000
  "$OUT/srep_ref" $opt f f2.srep >/dev/null 2>&1 || { bad "srep $opt falla"; continue; }
  "$OUT/test_srep" f2.srep f2.out >/dev/null 2>&1 && cmp -s f f2.out && ok "$opt" || bad "$opt"
done

echo "== codificador de PArc, leído por el srep de referencia"
for spec in "text 200000" "rep 200" "rand 100000" "mix 1"; do
  set -- $spec; gen "$1" "$2"; sz=$(stat -c%s f)
  if ! "$OUT/test_srep" e f f.mine >/dev/null 2>&1; then bad "encode falla ($1 $2)"; continue; fi
  if ! "$OUT/srep_ref" -d f.mine f.dec >/dev/null 2>&1; then bad "srep -d rechaza lo de PArc ($1 $2)"; continue; fi
  cmp -s f f.dec && ok "encode $1 $2 ($sz -> $(stat -c%s f.mine))" || bad "encode difiere $1 $2"
  "$OUT/test_srep" f.mine f.own >/dev/null 2>&1 && cmp -s f f.own && ok "PArc lee lo suyo ($1 $2)" || bad "PArc no lee lo suyo ($1 $2)"
done

echo "== encoder header (v3 with BASE_LEN=0, like 3.93a)"
gen mix 1
"$OUT/test_srep" e f f.b0 >/dev/null 2>&1
if python3 - <<'PY'
import struct
w = struct.unpack('<4I', open('f.b0', 'rb').read(16))
raise SystemExit(0 if (w[2] & 255) == 3 and w[3] == 0 else 1)
PY
then ok "versión 3 y BASE_LEN=0"; else bad "header inesperado (¿versión o BASE_LEN?)"; fi
"$OUT/srep_ref" -d f.b0 f.b0.out >/dev/null 2>&1 && cmp -s f f.b0.out && ok "3.93 lo decodifica" || bad "3.93 no lo decodifica"

echo "== v4 format (Index-LZ)"
for opt in -m0 -m2 -m3; do
  gen mix 1
  "$OUT/srep_ref" $opt f f4.srep >/dev/null 2>&1 || { bad "srep $opt falla"; continue; }
  "$OUT/test_srep" f4.srep f4.out >/dev/null 2>&1 && cmp -s f f4.out && ok "$opt (v4)" || bad "$opt (v4)"
done

echo "== SREP 3.93a format (BASE_LEN=0 and short lengths with 32-bit wrap)"
python3 - <<'PY'
import struct
SIG, SREP = 0x26351817, 0x50455253

def write(path, base, block_out, stats, lits):
    hdr = struct.pack('<4I', SIG, SREP, 3 | (1 << 8), base)   # v3, hash_num=1, seed 0
    st = b''.join(struct.pack('<4I', *s) for s in stats)
    blk = struct.pack('<3I', len(lits), len(block_out), len(st)) + b'\0' * 16
    open(path, 'wb').write(hdr + blk + st + lits)
    open(path + '.expected', 'wb').write(block_out)

# 1) BASE_LEN=0 (3.93a): match de 2 bytes en dest=10 desde src=0
out = b'abcdefghij' + b'ab' + b'Z' * 9
write('s0.srep', 0, out, [(0, 10, 0, 2)], out[:10] + out[12:])

# 2) BASE_LEN=512 con un match de 477 (<BASE_LEN): len_code = 477-512 en 32 bits
out = b'A' * 577 + b'B' * 23
write('s477.srep', 512, out, [(0, 100, 0, (477 - 512) & 0xFFFFFFFF)], out[:100] + out[577:])
PY
"$OUT/test_srep" s0.srep s0.out >/dev/null 2>&1 && cmp -s s0.srep.expected s0.out && ok "v3 BASE_LEN=0 (3.93a)" || bad "v3 BASE_LEN=0 (3.93a)"
"$OUT/test_srep" s477.srep s477.out >/dev/null 2>&1 && cmp -s s477.srep.expected s477.out && ok "match corto con vuelta de 32 bits" || bad "match corto con vuelta de 32 bits"

if [ -n "${SREP_393A:-}" ] && [ -x "${SREP_393A}" ]; then
  echo "== interoperabilidad con SREP 3.93a ($SREP_393A)"
  gen mix 1
  for opt in -m3f -m3 -m0o; do
    "$SREP_393A" $opt f f393a.srep >/dev/null 2>&1 || { bad "3.93a $opt falla"; continue; }
    "$OUT/test_srep" f393a.srep f393a.out >/dev/null 2>&1 && cmp -s f f393a.out && ok "3.93a $opt -> PArc" || bad "3.93a $opt -> PArc"
  done
  "$OUT/test_srep" e f p393a.srep >/dev/null 2>&1
  "$SREP_393A" -d p393a.srep p393a.out >/dev/null 2>&1 && cmp -s f p393a.out && ok "PArc -> 3.93a" || bad "PArc -> 3.93a"
else
  echo "  (SREP_393A no definido: se omite la interoperabilidad con 3.93a)"
fi

echo "== robustness: damaged streams (no crash or hang)"
gen mix 1
"$OUT/srep_ref" -m3f f f.srep >/dev/null 2>&1
rotos=0
for i in $(seq 1 25); do
  python3 - "$i" <<'PY'
import random, sys
random.seed(int(sys.argv[1]))
d = bytearray(open('f.srep', 'rb').read())
modo = random.randrange(3)
if modo == 0:                       # bytes cambiados
    for _ in range(random.choice([1, 2, 8, 64])):
        p = random.randrange(len(d)); d[p] ^= 1 << random.randrange(8)
elif modo == 1:                     # truncado
    d = d[:random.randrange(1, len(d))]
else:                               # cabecera rota
    for p in random.sample(range(min(64, len(d))), 4):
        d[p] = random.randrange(256)
open('f.bad', 'wb').write(d)
PY
  timeout 20 "$OUT/test_srep" f.bad f.badout >/dev/null 2>&1; rc=$?
  if [ $rc -eq 124 ] || [ $rc -ge 128 ] || [ $rc -eq 217 ]; then
    bad "corrupción $i terminó con rc=$rc"; rotos=$((rotos+1))
  fi
done
[ $rotos -eq 0 ] && ok "25 corrupciones sin crash ni cuelgue"

echo "== srep: $pass ok, $fail failures"
[ $fail -eq 0 ]
