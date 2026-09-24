#!/usr/bin/env python3
"""Fuzzing de robustez: corrompe bytes al azar y verifica que `parc t` termine con un código de
error controlado (0 ok, 2 dañado, 3 método no soportado, 5 contraseña), sin crash (runtime
error 216/217) ni cuelgue.
Uso: tests/fuzz.py <parc> <n_iter> archivo.arc...   (PARC_ARGS="-p1234" agrega argumentos)"""
import os, random, shlex, subprocess, sys, tempfile
parc, n = sys.argv[1], int(sys.argv[2])
arcs = sys.argv[3:]
extra = shlex.split(os.environ.get('PARC_ARGS', ''))
random.seed(7)
crashes = hangs = 0
codes = {}
with tempfile.TemporaryDirectory() as d:
    for it in range(n):
        src = random.choice(arcs)
        data = bytearray(open(src, 'rb').read())
        for _ in range(random.choice([1, 1, 2, 8, 64])):
            p = random.randrange(len(data))
            data[p] = random.randrange(256) if random.random() < .5 else data[p] ^ (1 << random.randrange(8))
        if random.random() < .1:
            data = data[:random.randrange(len(data))]  # truncado
        f = os.path.join(d, 'f.arc'); open(f, 'wb').write(data)
        try:
            r = subprocess.run([parc, 't', f] + extra, capture_output=True, timeout=120, stdin=subprocess.DEVNULL)
            codes[r.returncode] = codes.get(r.returncode, 0) + 1
            if r.returncode not in (0, 2, 3, 5):
                crashes += 1
                keep = f'/mnt/IA_LAB/agentes/PArc/fuzz_crash_{it}.arc'; open(keep, 'wb').write(data)
                print(f'CRASH it={it} rc={r.returncode} src={os.path.basename(src)} -> {keep}\n  {r.stderr.decode(errors="replace")[-300:]}')
        except subprocess.TimeoutExpired:
            hangs += 1
            keep = f'/mnt/IA_LAB/agentes/PArc/fuzz_hang_{it}.arc'; open(keep, 'wb').write(data)
            print(f'HANG it={it} src={os.path.basename(src)} -> {keep}')
print(f'{n} iteraciones: códigos {codes}, crashes {crashes}, cuelgues {hangs}')
sys.exit(1 if crashes or hangs else 0)
