#!/usr/bin/env python3
"""Genera streams LZMA1 raw con Python y verifica que tests/test_lzma los decodifique igual."""
import lzma, os, random, subprocess, sys, tempfile
exe = sys.argv[1]
corpus = sys.argv[2:]  # archivos reales opcionales
random.seed(1)
cases = [b'', b'a', b'abc' * 1000, bytes(range(256)) * 50, os.urandom(70000),
         bytes(random.choice(b'ab') for _ in range(100000))]
for p in corpus:
    cases.append(open(p, 'rb').read()[:3 << 20])
props = [(3, 0, 2), (0, 0, 0), (8, 0, 0), (0, 4, 4), (4, 2, 1), (1, 3, 3)]
fails = total = 0
with tempfile.TemporaryDirectory() as d:
    for i, data in enumerate(cases):
        for lc, lp, pb in props:
            if lc + lp > 4 and lzma.__name__ and (lc, lp) != (8, 0):  # liblzma: lc+lp<=4 para LZMA1
                continue
            for eos in (False, True):
                f = [{'id': lzma.FILTER_LZMA1, 'dict_size': 1 << 20, 'lc': lc, 'lp': lp, 'pb': pb}]
                try:
                    c = lzma.compress(data, lzma.FORMAT_RAW, filters=f) if eos else None
                except lzma.LZMAError:
                    continue
                if not eos:  # FORMAT_ALONE con tamaño conocido no escribe marca de fin
                    try:
                        a = lzma.compress(data, lzma.FORMAT_ALONE, filters=f)
                    except lzma.LZMAError:
                        continue
                    c = a[13:]
                cp, op = os.path.join(d, 'c'), os.path.join(d, 'o')
                open(cp, 'wb').write(c); open(op, 'wb').write(data)
                r = subprocess.run([exe, cp, op, str(lc), str(lp), str(pb)], capture_output=True, text=True)
                total += 1
                if r.returncode:
                    fails += 1
                    print(f'FAIL case={i} len={len(data)} lc={lc} lp={lp} pb={pb} eos={eos}: {r.stdout.strip()}')
print(f'{total - fails}/{total} OK')
sys.exit(1 if fails else 0)
