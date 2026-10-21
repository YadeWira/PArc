#!/bin/bash
# tests/bcj2.sh — BCJ2-style filter: round-trip on x86-like data.
set -u
ROOT=$(cd "$(dirname "$0")/.." && pwd)
PARC=${PARC_BIN:-$ROOT/build/linux64/parc}
W=${BCJ2_WORK:-/tmp/opencode/bcj2_test}
rm -rf -- "${W:?}"; mkdir -p "$W" && cd "$W" || exit 2
fail=0
check() { if eval "$2"; then printf '  ok    %s\n' "$1"; else printf '  FAIL %s\n' "$1"; fail=$((fail+1)); fi; }

# Marcadores E8/E9/0F8x, operandos y datos normales.
python3 - <<'PY'
import struct, random
random.seed(1234)
b = bytearray()
for i in range(20000):
    r = random.randrange(5)
    if r == 0:
        b += b'\xE8' + struct.pack('<i', random.randrange(-100000, 100000))
    elif r == 1:
        b += b'\xE9' + struct.pack('<i', random.randrange(-100000, 100000))
    elif r == 2:
        b += bytes([0x0F, 0x80 + random.randrange(16)]) + struct.pack('<i', random.randrange(-100000, 100000))
    else:
        b += bytes([random.randrange(256)])
open('x86.bin', 'wb').write(b)
open('random.bin', 'wb').write(random.randbytes(200000))
PY
: > empty.bin

for f in x86.bin random.bin empty.bin; do
  rm -f a.parc; rm -rf out
  "$PARC" a a.parc "$f" -mbcj2 --no-progress >/dev/null 2>&1
  check "$f comprime"      '[ -s a.parc ]'
  check "$f verifica"      '"$PARC" t a.parc --no-progress | tail -1 | grep -q "Errors: 0"'
  "$PARC" x a.parc -dpout -o+ --no-progress >/dev/null 2>&1
  check "$f extrae"        'cmp "$f" "out/$f"'
done

echo "== bcj2: $fail failures"
[ $fail -eq 0 ]
