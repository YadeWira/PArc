#!/bin/bash
# tests/container_cross.sh — the container (index, locator, recovery record) is the same on every
# platform: build/<target>/parc for linux32, linuxarm64 (qemu-aarch64) and win64/win32 (Wine)
# rewrite a reference archive made on linux64 (`ch`: copied blocks, own index, -rr record,
# comment, lock; with -mlzma also recompressed) byte-identically to the linux64 binary, list it
# the same (lt), and repair a damaged copy to the same bytes.
# Uso: ./build.sh all; tests/container_cross.sh   (targets that are not built are skipped)
set -u
export LC_ALL=C
ROOT=$(cd "$(dirname "$0")/.." && pwd)
W=${CONTAINER_CROSS_WORK:-${TMPDIR:-/tmp}/parc_container_cross}
rm -rf -- "${W:?}"; mkdir -p "$W/src/sub/x" "$W/src/empty" && cd "$W" || exit 2
fail=0; pass=0
ck() { if eval "$2"; then pass=$((pass+1)); else fail=$((fail+1)); echo "  FAIL $1"; fi; }
export WINEDEBUG=-all
run() {   # run <target> args...
  local t=$1; shift
  case $t in
    linuxarm64) QEMU_LD_PREFIX=/usr/aarch64-linux-gnu qemu-aarch64 "$ROOT/build/$t/parc" "$@" --no-progress </dev/null ;;
    win64|win32) wine "$ROOT/build/$t/parc.exe" "$@" --no-progress </dev/null ;;
    *) "$ROOT/build/$t/parc" "$@" --no-progress </dev/null ;;
  esac
}
[ -x "$ROOT/build/linux64/parc" ] || { echo "build/linux64/parc missing"; exit 2; }
TARGETS=""
[ -x "$ROOT/build/linux32/parc" ] && TARGETS="$TARGETS linux32"
[ -x "$ROOT/build/linuxarm64/parc" ] && command -v qemu-aarch64 >/dev/null && TARGETS="$TARGETS linuxarm64"
if command -v wine >/dev/null; then
  for t in win64 win32; do [ -x "$ROOT/build/$t/parc.exe" ] && TARGETS="$TARGETS $t"; done
fi
echo "platforms: linux64 (reference)$TARGETS"

printf 'alpha\n' > src/a.txt; : > src/zero; printf 'x' > src/sub/one
seq 1 40000 > src/sub/n.txt; head -c 200000 /dev/urandom > src/sub/x/r.bin
printf 'u\n' > 'src/sub/ñandú.txt'; ln -s a.txt src/link
for i in $(seq 1 300); do printf 'f%d\n' $i > src/sub/x/f$i.txt; done
run linux64 a ref.parc src -m1 >/dev/null 2>&1 || exit 2
# options of each rewrite: (name|options)
CASES="copy|-rr5%
cmt|-rr2% --archive-comment=hello
lock|-k
lzma|-mlzma:1mb -rr1%
nons|-mlzma:1mb -s-"
while IFS='|' read -r name opts; do
  cp ref.parc r_$name.parc
  run linux64 ch r_$name.parc $opts >/dev/null 2>&1
  run linux64 lt r_$name.parc 2>&1 | tr -d '\r' | sed 's/^Archive: [^ ]*/Archive:/' > r_$name.lt
  for t in $TARGETS; do
    cp ref.parc o.parc
    run $t ch o.parc $opts >/dev/null 2>&1
    ck "$t ch $opts: same bytes" "cmp -s o.parc r_$name.parc"
    run $t lt r_$name.parc 2>&1 | tr -d '\r' | sed 's/^Archive: [^ ]*/Archive:/' > o.lt
    ck "$t lt $name: same listing" "cmp -s o.lt r_$name.lt"
    ck "$t t $name" "run $t t r_$name.parc 2>&1 | tr -d '\r' | tail -1 | grep -q 'All OK'"
  done
done <<< "$CASES"
# repair of a damaged copy
python3 -c "
import random; random.seed(5); d=bytearray(open('r_copy.parc','rb').read())
for o in random.sample(range(0, len(d) - 200000), 3): d[o] ^= 0x5A
d[-10] ^= 0x33
open('dmg.parc','wb').write(d)"
for t in $TARGETS; do
  rm -f fixed.dmg.parc
  run $t r dmg.parc >/dev/null 2>&1
  ck "$t r: byte-identical repair" "cmp -s fixed.dmg.parc r_copy.parc"
done
echo "container_cross: $pass ok, $fail failures"
[ $fail -eq 0 ]
