#!/usr/bin/env python3
"""Fuzz del espacio de opciones de tor: combinaciones aleatorias de tor:N:... (y 4x4:tor)
sobre entradas chicas. Cada caso comprime con `parc a`, verifica con `parc t`, extrae y
compara. Falla si hay un crash (señal), un cuelgue o un archivo creado que no verifica o no
extrae igual. Un rechazo limpio de una combinación inválida (rc=3 sin archivo) es válido.

Uso: python3 tests/tor_optfuzz.py build/linux64/parc [iteraciones] [semilla]
"""
import os, random, shutil, subprocess, sys, tempfile

def rnd_mem(r):
    return r.choice(['32kb', '64kb', '100kb', '256kb', '1mb', '3mb', '7kb', '1000b',
                     '4mb', '16mb', '17', '20', '12345', str(r.randint(1, 1 << 22))])

def rnd_opt(r):
    k = r.choice('bhlcpxsutAaLf#')
    if k == 'b': return 'b' + rnd_mem(r)
    if k == 'h': return 'h' + rnd_mem(r)
    if k == 'l': return 'l' + str(r.choice([0, 1, 2, 3, 4, 5, 8, 16, 33, 64, 128, 256, 300]))
    if k == 'c': return 'c' + str(r.randint(0, 5))
    if k == 'p': return 'p' + str(r.choice([0, 1, 2, 3, 4]))
    if k == 'x': return 'x' + str(r.choice([0, 5, 7, 14, 15, 16, 25, 3]))
    if k == 's': return 's' + str(r.randint(0, 3))
    if k == 'u': return 'u' + str(r.choice([0, 1, 2, 4, 999]))
    if k == 't': return 't' + str(r.randint(0, 1))
    if k == 'A': return 'ah' + rnd_mem(r)
    if k == 'a': return 'al' + str(r.choice([0, 1, 2, 4, 8, 128]))
    if k == 'L': return rnd_mem(r)
    if k == 'f': return 'fb' + str(r.choice([2, 16, 64, 128, 512, 1000]))
    return str(r.randint(1, 16))

def make_inputs(d, r):
    files = []
    sizes = [0, 1, 37, 4096, 70000, 300000, 1200000]
    for i, n in enumerate(sizes):
        p = os.path.join(d, 'in%d.bin' % i)
        kind = i % 3
        if kind == 0:
            data = os.urandom(n)
        elif kind == 1:
            words = [b'alpha ', b'beta ', b'gamma\n', b'delta ', b'0123456789']
            data = b''.join(r.choice(words) for _ in range(n // 5 + 1))[:n]
        else:
            base = os.urandom(997)
            data = bytearray()
            while len(data) < n:
                data += base[r.randrange(500):][:r.randint(1, 400)]
                if r.random() < 0.1: data += os.urandom(r.randint(1, 50))
            data = bytes(data[:n])
        open(p, 'wb').write(data)
        files.append(p)
    return files

def run(cmd, env, timeout=120):
    try:
        p = subprocess.run(cmd, env=env, stdout=subprocess.DEVNULL, stderr=subprocess.PIPE,
                           timeout=timeout)
        return p.returncode, p.stderr.decode('utf-8', 'replace')
    except subprocess.TimeoutExpired:
        return 'timeout', ''

def main():
    parc = os.path.abspath(sys.argv[1])
    iters = int(sys.argv[2]) if len(sys.argv) > 2 else 200
    seed = int(sys.argv[3]) if len(sys.argv) > 3 else 12345
    r = random.Random(seed)
    tmp = tempfile.mkdtemp(prefix='tor_optfuzz_')
    bad = 0
    ok = rej = 0
    try:
        files = make_inputs(tmp, r)
        for it in range(iters):
            opts = [rnd_opt(r) for _ in range(r.randint(0, 5))]
            if r.random() < 0.6: opts.insert(0, str(r.randint(1, 16)))
            m = ':'.join(['tor'] + opts)
            if r.random() < 0.2: m = '4x4:' + r.choice(['', 'b64kb:', 'b300kb:']) + m
            env = dict(os.environ, PARC_THREADS=str(r.choice([1, 2, 4])))
            arc = os.path.join(tmp, 'a.parc')
            out = os.path.join(tmp, 'out')
            if os.path.exists(arc): os.remove(arc)
            shutil.rmtree(out, ignore_errors=True)
            sel = r.sample(files, r.randint(1, len(files)))
            rc, err = run([parc, 'a', '-m' + m, '--no-progress', arc] + sel, env)
            if rc == 'timeout' or (isinstance(rc, int) and rc < 0):
                print('FALLA %s: a rc=%s' % (m, rc)); bad += 1; continue
            if rc != 0:
                rej += 1
                if os.environ.get('TOR_OPTFUZZ_VERBOSE'):
                    print('rechazo %s rc=%s: %s' % (m, rc, err.strip().splitlines()[-1:] if err else ''))
                if os.path.exists(arc) and rc not in (3,):
                    print('FALLA %s: a rc=%d y quedó archivo' % (m, rc)); bad += 1
                continue
            rc, err = run([parc, 't', arc, '--no-progress'], env)
            if rc != 0:
                print('FALLA %s: t rc=%s %s' % (m, rc, err.strip()[:200])); bad += 1; continue
            os.makedirs(out)
            rc, err = run([parc, 'e', arc, '-dp' + out, '--no-progress'], env)
            if rc != 0:
                print('FALLA %s: x rc=%s' % (m, rc)); bad += 1; continue
            for f in sel:
                g = os.path.join(out, os.path.basename(f))
                if open(f, 'rb').read() != open(g, 'rb').read():
                    print('FALLA %s: %s distinto' % (m, os.path.basename(f))); bad += 1
                    break
            else:
                ok += 1
    finally:
        shutil.rmtree(tmp, ignore_errors=True)
    print('tor_optfuzz: %d ok, %d rechazados, %d fallas' % (ok, rej, bad))
    sys.exit(1 if bad else 0)

if __name__ == '__main__':
    main()
