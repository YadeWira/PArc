#!/bin/bash
# tests/policy.sh — the policy layer: presets (parc_presets), file groups, canonical methods and
# limits (parc_canon), data-type detection (parc_filetype) and memory sizes (ParseMemSize).
#  - every -m text of tests/policy_methods.txt with 1, 2, 3, 4 and 8 threads, and every preset
#    chain of tests/policy_chains.txt canonical for 11 block sizes, give exactly the output of
#    the FreeArc-derived code they replaced (checksums recorded when that code was retired),
#    and a readable subset is checked line by line;
#  - file groups: membership and sort order of names;
#  - CanonStageMem shrinks to the budget and stays parseable;
#  - detection: random data is $compressed, text is $text, zeros and tables are default,
#    empty and tiny inputs work, the answer is the same for the same bytes;
#  - memory sizes: units, powers of two, bad strings;
#  - through parc: -m levels, groups and an archive round trip with mixed data.
# Uso: tests/policy.sh [parc]   (needs build/linux64 built: links its C objects)
set -u
ROOT=$(cd "$(dirname "$0")/.." && pwd)
PARC=${1:-$ROOT/build/linux64/parc}
B=$ROOT/build/tests
T=$B/test_policy
W=${POLICY_WORK:-${TMPDIR:-/tmp}/parc_policy}
mkdir -p "$B/policyunits"
fpc -O2 -Fu"$ROOT/src" -Fu"$ROOT/src/orep" -Fu"$ROOT/src/osrep" -Fu"$ROOT/src/bwt" -Fu"$ROOT/src/cm" -Fu"$ROOT/src/tta" \
    -Fl"$ROOT/build/linux64/units" -Fo"$ROOT/build/linux64/units" -FU"$B/policyunits" -FE"$B" \
    "$ROOT/tests/test_policy.lpr" >/dev/null || { echo "test_policy does not compile (build.sh linux64 first)"; exit 2; }
rm -rf -- "${W:?}"; mkdir -p "$W" && cd "$W" || exit 2
fail=0; pass=0
ck() { if eval "$2"; then pass=$((pass+1)); else fail=$((fail+1)); echo "  FAIL $1"; fi; }

echo '-- presets'
"$T" decode "$ROOT/tests/policy_methods.txt" 1 2 3 4 8 > dec.txt
ck "decode checksum (same as the replaced code)" '[ "$(md5sum < dec.txt | cut -c1-32)" = 4e036adaa888641fd8bd9d6f8ecfee87 ]'
printf '%s\n' 0 1 2 3 4 5 9 x xx 5x ex5 5d 5t 3/\$obj=2b 'lzma/$text=ppmd' 'xlzma:64m' 'eplz:3' '(|x)lzma' 'lzma||ppmd' '5/$text=' > sub.txt
"$T" decode sub.txt 1 4 > sub.out
cat > sub.exp <<'EOF'
[0] c1 => {=storing}
[0] c4 => {=storing}
[1] c1 => {=orep:96m:l256:c2:r512+plz:2}
[1] c4 => {=orep:96m:l256:c2:r512+4x4:plz:1}
[2] c1 => {=orep:96m:l256:r512+exe+delta+plz:4} {$obj=orep:96m:l256:r512+delta+plz:4} {$text=bwt:m4:8m:32:h18:a:e1} {$wav=tta:m1} {$bmp=mm:d1+plz:2} {$compressed=orep:96m:l256:r512+plz:2}
[2] c4 => {=orep:96m:l256:r512+exe+4x4:plz:3} {$obj=orep:96m:l256:r512+4x4:plz:3} {$text=bwt:m4:h20:a:e1} {$wav=tta:m1} {$bmp=mm+bwt:m4:l:a} {$compressed=orep:96m:l256:r512+4x4:plz:1}
[3] c1 => {=orep:96m:l512+exe+delta+lzma:96m:fast:32:mc6:lc4} {$obj=orep:96m:l512+delta+lzma:96m:fast:32:mc6:lc4} {$text=dict:p:64m:85%+bwt:m1:8m:32:h20:a} {$bmp=mm+bwt:m4:l:a} {$compressed=orep:96m:l512+plz:2} {$wav=tta}
[3] c4 => {=orep:96m:l512+exe+delta+4x4:lzma:16mb:normal:16:mc4:lc4} {$obj=orep:96m:l512+delta+4x4:lzma:16mb:normal:16:mc4:lc4} {$text=bwt:m2:h20:a} {$bmp=mm+bwt:m1:l2048:a} {$compressed=orep:96m:l512+4x4:plz:1} {$wav=tta}
[4] c1 => {=orep:96m:l512+exe+delta+lzma:96m:normal:16:mc8:lc4} {$obj=orep:96m:l512+delta+lzma:96m:normal:16:mc8:lc4} {$text=dict:p:64m:80%+lzp:64m:65:d1m:s16:h20:90%+ppmd:8:192m} {$compressed=orep:96m:l512+plz:3} {$wav=tta} {$bmp=mm+bwt:m1:l2048:a}
[4] c4 => {=orep:96m:l512+exe+delta+4x4:lzma:24mb:normal:20:mc6:lc5:pb1} {$obj=orep:96m:l512+delta+4x4:lzma:24mb:normal:20:mc6:lc5:pb1} {$text=bwt:m1:h20:a} {$compressed=orep:96m:l512+4x4:plz:3} {$wav=tta} {$bmp=mm+bwt:m1:l2048:a}
[5] c1 => {=orep:96m:l512+exe+delta+lzma:96m:normal:32:bt4:mc8:lc4:pb1} {$obj=orep:96m:l512+delta+lzma:96m:normal:32:bt4:mc8:lc4:pb1} {$text=dict:p:64m:80%+lzp:80m:105:d1m:s32:h22:92%+ppmd:13:192m} {$wav=tta} {$bmp=mm+bwt:m1:l2048:a}
[5] c4 => {=orep:96m:l512+exe+delta+4x4:lzma:24mb:normal:32:bt4:mc8:lc4} {$obj=orep:96m:l512+delta+4x4:lzma:24mb:normal:32:bt4:mc8:lc4} {$text=dict:p:64m:80%+lzp:64m:65:d1m:s32:h22:90%+4x4:b7mb:ppmd:12:192m} {$wav=tta} {$bmp=mm+bwt:m1:l2048:a}
[9] c1 => {=orep:2040m:l512+exe+delta+lzma:254m:max} {$obj=orep:2040m:l512+delta+lzma:254m:max} {$text=dict:p:128m:75%:l8192:m800:s250+lzp:160m:145:d1m:s32:h23:90%+ppmd:18:512m} {$wav=tta} {$bmp=mm+bwt:m1:l2048:a}
[9] c4 => {=orep:2040m:l512+exe+delta+lzma:254m:max} {$obj=orep:2040m:l512+delta+lzma:254m:max} {$text=dict:p:128m:75%:l8192:m800:s250+lzp:160m:145:d1m:s32:h23:90%+ppmd:18:512m} {$wav=tta} {$bmp=mm+bwt:m1:l2048:a}
[x] c1 => {=orep:2040m:l512+exe+delta+lzma:254m:max} {$obj=orep:2040m:l512+delta+lzma:254m:max} {$text=dict:p:128m:75%:l8192:m800:s250+lzp:160m:145:d1m:s32:h23:90%+ppmd:18:512m} {$wav=tta} {$bmp=mm+bwt:m1:l2048:a}
[x] c4 => {=orep:2040m:l512+exe+delta+lzma:254m:max} {$obj=orep:2040m:l512+delta+lzma:254m:max} {$text=dict:p:128m:75%:l8192:m800:s250+lzp:160m:145:d1m:s32:h23:90%+ppmd:18:512m} {$wav=tta} {$bmp=mm+bwt:m1:l2048:a}
[xx] c1 => {=orep:2040m:l512+exe+delta+lzma:254m:max} {$wav=tta} {$bmp=mm+bwt:m1:l2048:a} {$text=dict:p:128m:75%:l8192:m800:s250+lzp:160m:145:d1m:s32:h23:90%+cm} {$binary=orep:64m:l512:a1+exe+delta+cm} {$obj=orep:64m:l512:a1+exe+delta+cm}
[xx] c4 => {=orep:2040m:l512+exe+delta+lzma:254m:max} {$wav=tta} {$bmp=mm+bwt:m1:l2048:a} {$text=dict:p:128m:75%:l8192:m800:s250+lzp:160m:145:d1m:s32:h23:90%+cm} {$binary=orep:64m:l512:a1+exe+delta+cm} {$obj=orep:64m:l512:a1+exe+delta+cm}
[5x] c1 => {=exe+delta+lzma:96m:normal:32:bt4:mc8:lc4:pb1} {$obj=delta+lzma:96m:normal:32:bt4:mc8:lc4:pb1} {$text=dict:128m:75%+lzma:96m:normal:32:bt4:mc8:lc4:pb1} {$wav=tta:m1} {$bmp=mm+lzma:96m:normal:32:bt4:mc8:lc4:pb1}
[5x] c4 => {=exe+delta+4x4:lzma:24mb:normal:32:bt4:mc8:lc4} {$obj=delta+4x4:lzma:24mb:normal:32:bt4:mc8:lc4} {$text=dict:128m:75%+4x4:lzma:24mb:normal:32:bt4:mc8:lc4} {$wav=tta:m1} {$bmp=mm+4x4:lzma:24mb:normal:32:bt4:mc8:lc4}
[ex5] c1 => {=orep:96m:l512+exe+delta+4x4:lzma:24mb:normal:32:bt4:mc8:lc4} {$obj=orep:96m:l512+delta+4x4:lzma:24mb:normal:32:bt4:mc8:lc4} {$text=dict:p:64m:80%+lzp:64m:65:d1m:s32:h22:90%+4x4:b7mb:ppmd:12:192m} {$wav=tta} {$bmp=mm+bwt:m1:l2048:a}
[ex5] c4 => {=orep:96m:l512+exe+delta+4x4:lzma:24mb:normal:32:bt4:mc8:lc4} {$obj=orep:96m:l512+delta+4x4:lzma:24mb:normal:32:bt4:mc8:lc4} {$text=dict:p:64m:80%+lzp:64m:65:d1m:s32:h22:90%+4x4:b7mb:ppmd:12:192m} {$wav=tta} {$bmp=mm+bwt:m1:l2048:a}
[5d] c1 => {=orep:96m:l512+exe+delta+lzma:96m:normal:32:bt4:mc8:lc4:pb1} {$obj=orep:96m:l512+delta+lzma:96m:normal:32:bt4:mc8:lc4:pb1} {$text=dict+orep:96m:l512+delta+lzma:96m:normal:32:bt4:mc8:lc4:pb1} {$wav=tta:m1} {$bmp=mm+lzma:96m:normal:32:bt4:mc8:lc4:pb1}
[5d] c4 => {=orep:96m:l512+exe+delta+4x4:lzma:24mb:normal:32:bt4:mc8:lc4} {$obj=orep:96m:l512+delta+4x4:lzma:24mb:normal:32:bt4:mc8:lc4} {$text=dict+orep:96m:l512+delta+4x4:lzma:24mb:normal:32:bt4:mc8:lc4} {$wav=tta:m1} {$bmp=mm+4x4:lzma:24mb:normal:32:bt4:mc8:lc4}
[5t] c1 => {=dict:p:64m:80%+lzp:80m:105:d1m:s32:h22:92%+ppmd:13:192m}
[5t] c4 => {=dict:p:64m:80%+lzp:64m:65:d1m:s32:h22:90%+4x4:b7mb:ppmd:12:192m}
[3/$obj=2b] c1 => {=orep:96m:l512+exe+delta+lzma:96m:fast:32:mc6:lc4} {$text=dict:p:64m:85%+bwt:m1:8m:32:h20:a} {$bmp=mm+bwt:m4:l:a} {$compressed=orep:96m:l512+plz:2} {$wav=tta} {$obj=orep:96m:l256:r512+delta+plz:4}
[3/$obj=2b] c4 => {=orep:96m:l512+exe+delta+4x4:lzma:16mb:normal:16:mc4:lc4} {$text=bwt:m2:h20:a} {$bmp=mm+bwt:m1:l2048:a} {$compressed=orep:96m:l512+4x4:plz:1} {$wav=tta} {$obj=orep:96m:l256:r512+4x4:plz:3}
[lzma/$text=ppmd] c1 => {=lzma} {$text=ppmd}
[lzma/$text=ppmd] c4 => {=lzma} {$text=ppmd}
[xlzma:64m] c1 => {=4x4:lzma:64m}
[xlzma:64m] c4 => {=4x4:lzma:64m}
[eplz:3] c1 => {=plz:3}
[eplz:3] c4 => {=4x4:plz:3}
[(|x)lzma] c1 => {=lzma}
[(|x)lzma] c4 => {=4x4:lzma}
[lzma||ppmd] c1 => {=lzma}
[lzma||ppmd] c4 => {=ppmd}
[5/$text=] c1 => {=orep:96m:l512+exe+delta+lzma:96m:normal:32:bt4:mc8:lc4:pb1} {$obj=orep:96m:l512+delta+lzma:96m:normal:32:bt4:mc8:lc4:pb1} {$wav=tta} {$bmp=mm+bwt:m1:l2048:a}
[5/$text=] c4 => {=orep:96m:l512+exe+delta+4x4:lzma:24mb:normal:32:bt4:mc8:lc4} {$obj=orep:96m:l512+delta+4x4:lzma:24mb:normal:32:bt4:mc8:lc4} {$wav=tta} {$bmp=mm+bwt:m1:l2048:a}
EOF
ck "decode subset" 'diff sub.exp sub.out >/dev/null || { diff sub.exp sub.out | head -5; false; }'
# a long chain of names resolves without looping; unknown names stay as written
printf '%s\n' 'foo:1+bar' 'x+x+x+x+x+x+x+x+x+x+x+x' '' '9p' > odd.txt
"$T" decode odd.txt 1 > odd.out
ck "unknown names kept" 'grep -q "^\[foo:1+bar\] c1 => {=foo:1+bar}$" odd.out && grep -q "^\[9p\] c1 => {=9p}$" odd.out'
ck "empty text: no chains" 'grep -q "^\[\] c1 =>$" odd.out'

echo '-- canonical methods'
"$T" canon "$ROOT/tests/policy_chains.txt" 0 1 1000 65536 100000 1048576 5000000 33554432 100000000 1000000000 5000000000 > canon.txt
ck "canon checksum (same as the replaced code)" '[ "$(md5sum < canon.txt | cut -c1-32)" = ffdd4418fe9437840c95bebd39c56b48 ]'
printf '%s\n' 'lzma:96m:normal:32:bt4:mc8:lc4:pb1' 'orep:96m:l256:c2:r512' 'dict:p:64m:80%' 'lzp:80m:105:d1m:s32:h22:92%' 'bwt:m1:l2048:a' 'plz:2' 'ppmd:13:192m' '4x4:lzma:24mb:normal:20:mc6:lc5:pb1' 'mm:d1' 'tta:m1' 'lz4:hc' 'lzma:max' 'lzma:fastest' 'orep:d0' 'ppmd:4097m' 'lzma:bad' > c.txt
"$T" canon c.txt 1048576 > c.out
cat > c.exp <<'EOF'
[lzma:96m:normal:32:bt4:mc8:lc4:pb1] 1048576 => lzma:1035kb:normal:bt4:32:mc8:pb1:lc4
[orep:96m:l256:c2:r512] 1048576 => orep:1035kb:l256:c2:r512
[dict:p:64m:80%] 1048576 => dict:1035kb:80%:l8192:m400:s100
[lzp:80m:105:d1m:s32:h22:92%] 1048576 => lzp:1035kb:92%:105:h21:d1mb
[bwt:m1:l2048:a] 1048576 => bwt:1035kb:m1:l2048:h18:a
[plz:2] 1048576 => plz:2:1088kb
[ppmd:13:192m] 1048576 => ppmd:13:192mb
[4x4:lzma:24mb:normal:20:mc6:lc5:pb1] 1048576 => 4x4:lzma:1035kb:normal:20:mc6:pb1:lc5
[mm:d1] 1048576 => mm
[tta:m1] 1048576 => tta:m1
[lz4:hc] 1048576 => lz4:c2
[lzma:max] 1048576 => lzma:1035kb:normal:bt4:128
[lzma:fastest] 1048576 => lzma:1035kb:fast:5:mc1
[orep:d0] 1048576 => orep:1035kb:d1b
[ppmd:4097m] 1048576 => ppmd:10:4195328kb
[lzma:bad] 1048576 => lzma:bad
EOF
ck "canon subset" 'diff c.exp c.out >/dev/null || { diff c.exp c.out | head -5; false; }'
# memory limit: the stage shrinks and stays canonical (canonizing it again changes nothing)
printf '%s\n' 'lzma:254mb:normal:bt4:128' 'orep:2040mb:l512' 'ppmd:18:512mb' 'dict:128mb:75%' 'lzp:160mb:90%:145:h23:d1mb' 'bwt:8mb:m1:l32:h18:a' 'plz:4:64mb' '4x4:lzma:24mb:normal:32' > m.txt
"$T" stagemem m.txt 50000000 > m.out
sed 's/.* => //' m.out > m2.txt
ck "stagemem shrinks" '! grep -q -e "254mb" -e "2040mb" -e "512mb" -e "128mb" -e "160mb" -e "plz:4:64mb" m2.txt'
"$T" canon m2.txt 5000000000 | sed 's/.* => //' > m3.txt
ck "stagemem output is canonical" 'cmp -s m2.txt m3.txt'

echo '-- file groups'
printf '%s\n' a.txt dir/B.TXT readme README.exe x/makefile Makefile.am noext dot. foo.~bak x.r01 x.a0b x.ear1 x.ab_ 'x.ab$' x.doc x.exe x.wav x.bmp x.jpg x.mp3 x.7z x.pak x.zip x.bin x.o unknown.qqq 'u.ÑB_' > n.txt
"$T" groups n.txt > g.out
grp() { awk -F'\t' -v n="$1" '$2 == n { print $3 }' g.out; }
rank() { awk -F'\t' -v n="$1" '$2 == n { print $1 }' g.out; }
ck "a.txt text"            '[ "$(grp a.txt)" = "\$text" ]'
ck "B.TXT text (case)"     '[ "$(grp dir/B.TXT)" = "\$text" ]'
ck "readme text"           '[ "$(grp readme)" = "\$text" ]'
ck "README.exe text+exe"   '[ "$(grp README.exe)" = "\$text \$exe" ]'
ck "makefile text"         '[ "$(grp x/makefile)" = "\$text" ] && [ "$(grp Makefile.am)" = "\$text" ]'
ck "no extension text"     '[ "$(grp noext)" = "\$text" ] && [ "$(grp dot.)" = "\$text" ]'
ck "*.~* text"             '[ "$(grp foo.~bak)" = "\$text" ]'
ck "*.r0? *.a0? compressed" '[ "$(grp x.r01)" = "\$compressed" ] && [ "$(grp x.a0b)" = "\$compressed" ]'
ck "*.ear? precomp"        '[ "$(grp x.ear1)" = "\$precomp" ]'
ck "*.??_ *.??\$"          '[ "$(grp x.ab_)" = "\$compressed" ] && [ "$(grp "x.ab\$")" = "\$compressed" ]'
ck "? is one UTF-8 char"   '[ "$(grp "u.ÑB_")" = "\$compressed" ]'
ck "jpg jpgsolid, pak precomp" '[ "$(grp x.jpg)" = "\$jpgsolid" ] && [ "$(grp x.pak)" = "\$precomp" ]'
ck "groups of wav bmp exe o bin" '[ "$(grp x.wav)" = "\$wav" ] && [ "$(grp x.bmp)" = "\$bmp" ] && [ "$(grp x.exe)" = "\$exe" ] && [ "$(grp x.o)" = "\$obj" ] && [ "$(grp x.bin)" = "\$iso" ]'
ck "unknown: no group"     '[ -z "$(grp unknown.qqq)" ]'
ck "order: txt < doc < unknown < exe < mp3" '[ $(rank a.txt) -lt $(rank x.doc) ] && [ $(rank x.doc) -lt $(rank unknown.qqq) ] && [ $(rank unknown.qqq) -lt $(rank x.exe) ] && [ $(rank x.exe) -lt $(rank x.mp3) ]'
ck "order: same mask, same rank" '[ $(rank a.txt) = $(rank dir/B.TXT) ]'

echo '-- detection'
: > empty
printf 'a' > one
head -c 300000 /dev/urandom > rnd
head -c 300000 /dev/zero > zeros
# prose only: the benchmark tables of ESTADO.md read as numeric data, not text
cat "$ROOT"/docs/USO.md "$ROOT"/README.md "$ROOT"/docs/formato/FORMATO-PARC.md | head -c 400000 > text
python3 -c "
import struct, sys
sys.stdout.buffer.write(b''.join(struct.pack('<IIhh', i * 7, 100000 + i * 3, i % 50, -i % 9) for i in range(40000)))" > table
for f in empty one rnd zeros text table; do "$T" detect $f > $f.det; done
ck "empty and 1 byte: default" 'grep -q " default" empty.det && grep -q " default" one.det'
ck "random: \$compressed"      '! grep -v -q " \$compressed " rnd.det'
ck "zeros: default"            '! grep -v -q " default " zeros.det'
ck "text: \$text"              '! grep -v -q " \$text " text.det'
ck "table: not \$text"         '! grep -q " \$text " table.det'
"$T" detect text 4096 > t1; "$T" detect text 4096 > t2
ck "same bytes, same answer"   'cmp -s t1 t2'
"$T" detect rnd 7 > /dev/null
ck "tiny chunks"               '[ $? = 0 ]'

echo '-- memory sizes'
"$T" mem 24 1b 512b 64k 64kb 1035kb 96m 96mb 2g 1gb =24 16MB 63 64 0 x 1q 24mbx '' 99999999999g 8589934591g > mem.out
cat > mem.exp <<'EOF'
24 16777216
1b 1
512b 512
64k 65536
64kb 65536
1035kb 1059840
96m 100663296
96mb 100663296
2g 2147483648
1gb 1073741824
=24 16777216
16MB 16777216
63 9223372036854775808
64 bad
0 1
x bad
1q bad
24mbx bad
 bad
99999999999g bad
8589934591g 9223372035781033984
EOF
ck "ParseMemSize" 'diff mem.exp mem.out >/dev/null || { diff mem.exp mem.out | head -5; false; }'

echo '-- through parc'
mkdir -p tree/sub
cp text tree/a.txt; cp table tree/t.bin; cp rnd tree/r.dat; cp zeros tree/z.wav; cp text tree/sub/readme
for L in 1 2 3 5 9 x 5x ex3 3d; do
  rm -f a.parc; rm -rf out
  PARC_THREADS=2 "$PARC" a a.parc tree -m$L -y >/dev/null 2>&1 && "$PARC" x a.parc -dpout -y >/dev/null 2>&1
  ck "-m$L round trip" 'diff -r tree out/tree >/dev/null 2>&1'
done
out=$("$PARC" --print-config 2>&1)
ck "--print-config sections" 'echo "$out" | grep -q "^\[Compression methods\]" && echo "$out" | grep -q "^\[Presets\]" && echo "$out" | grep -q "^\[File groups\]"'

echo "policy: $pass ok, $fail failed"
[ $fail = 0 ]
