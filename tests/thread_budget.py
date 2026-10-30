#!/usr/bin/env python3
"""tests/thread_budget.py — presupuesto global de hilos (PARC_THREADS=N).

PARC_THREADS=N es el tope de hilos TRABAJANDO a la vez en todo el proceso, sumando bloques en
paralelo, 4x4, hashing de REP, el match finder multihilo de LZMA y la verificación/extracción
en paralelo (parc_parallel). Se muestrea /proc/<pid>/task/*/stat (hilos en estado R) mientras
corre cada comando y se exige:
  - núcleos promedio (CPU/wall) <= N + 0.3 (holgura: el hilo principal que solo junta
    progreso o copia lo comprimido al archivo no tiene ficha; ver parc_parallel);
  - percentil 99 de hilos en R <= N (un hilo que acaba de pasar su ficha sigue en R unos
    microsegundos, por eso no se mira el máximo);
  - que lo extraído sea idéntico.
Escenarios: REP con varios bloques en paralelo (-s-, el caso de tests/rep_threads.sh de antes),
un bloque grande con rep+4x4, LZMA con match finder multihilo, y t/x de esos archivos.
Solo Linux. Uso: tests/thread_budget.py [parc]
"""
import os, random, shutil, subprocess, sys, tempfile, time

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
PARC = os.path.abspath(sys.argv[1]) if len(sys.argv) > 1 else os.path.join(ROOT, 'build/linux64/parc')
fails = passes = 0


def ok(msg):
    global passes
    passes += 1
    print('  ok   ' + msg)


def bad(msg):
    global fails
    fails += 1
    print('  FAIL ' + msg)


def run(args, n, cwd):
    """Corre parc con PARC_THREADS=n; devuelve (rc, núcleos promedio, p99 de hilos en R)."""
    env = dict(os.environ, PARC_THREADS=str(n))
    t0 = time.time()
    p = subprocess.Popen([PARC] + args + ['--no-progress'], cwd=cwd, env=env,
                         stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    tdir = '/proc/%d/task' % p.pid
    hist = []
    while True:
        if os.waitid(os.P_PID, p.pid, os.WEXITED | os.WNOHANG | os.WNOWAIT) is not None:
            break
        cnt = 0
        try:
            for t in os.listdir(tdir):
                try:
                    with open(tdir + '/' + t + '/stat', 'rb') as f:
                        s = f.read()
                    if s[s.rindex(b')') + 2:s.rindex(b')') + 3] == b'R':
                        cnt += 1
                except OSError:
                    pass
        except OSError:
            pass
        hist.append(cnt)
        time.sleep(0.003)
    _, status, ru = os.wait4(p.pid, 0)
    wall = max(time.time() - t0, 1e-3)
    hist.sort()
    p99 = hist[int(0.99 * (len(hist) - 1))] if hist else 0
    return os.waitstatus_to_exitcode(status), (ru.ru_utime + ru.ru_stime) / wall, p99


def check(label, args, n, cwd):
    rc, cores, p99 = run(args, n, cwd)
    if rc != 0:
        bad('%s N=%d: rc=%d' % (label, n, rc))
        return False
    if cores <= n + 0.3 and p99 <= n:
        ok('%s N=%d: %.2f núcleos, p99 %d hilos en R' % (label, n, cores, p99))
    else:
        bad('%s N=%d: %.2f núcleos, p99 %d hilos en R (tope %d)' % (label, n, cores, p99, n))
    return True


def same_tree(a, b):
    r = subprocess.run(['diff', '-r', a, b], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    return r.returncode == 0


def text(rng, size):
    words = [''.join(rng.choice('abcdefghijklmnopqrstuvwxyz') for _ in range(rng.randint(2, 9)))
             for _ in range(3000)]
    out = []
    n = 0
    while n < size:
        line = ' '.join(rng.choice(words) for _ in range(12)) + '\n'
        out.append(line)
        n += len(line)
    return ''.join(out).encode()[:size]


def main():
    base = os.environ.get('BUDGET_WORK') or tempfile.mkdtemp(prefix='parc_budget_')
    shutil.rmtree(base, ignore_errors=True)
    os.makedirs(base)
    rng = random.Random(1)
    # g: 4 archivos de 24 MB (8 MB aleatorios repetidos 3 veces: REP encuentra coincidencias)
    g = os.path.join(base, 'g')
    os.makedirs(g)
    for i in range(4):
        seed = rng.randbytes(8 << 20)
        with open(os.path.join(g, 'f%d' % i), 'wb') as f:
            f.write(rng.randbytes(4096) + seed + seed + seed)
    # b: un archivo de 48 MB comprimible (texto) con repeticiones lejanas
    b = os.path.join(base, 'b')
    os.makedirs(b)
    t = text(rng, 16 << 20)
    with open(os.path.join(b, 'big'), 'wb') as f:
        f.write(t + rng.randbytes(1 << 20) + t + t[:15 << 20])
    cases = [
        ('rep -s- (bloques en paralelo)', 'g', ['-s-', '-mrep:32mb:256']),
        ('rep+4x4 (un bloque)', 'b', ['-mrep:64mb+4x4:b2mb:lzma:2mb:fast']),
        ('lzma mt (un bloque)', 'b', ['-mlzma:16mb:normal:bt4']),
        ('-m3 -s- (bloques con 4x4)', 'g', ['-s-', '-m3']),
    ]
    for n in (1, 2, 3):
        for k, (label, src, opts) in enumerate(cases):
            arc = os.path.join(base, 'a%d_%d.parc' % (n, k))
            if not check(label + ': a', ['a', arc, src] + opts, n, base):
                continue
            check(label + ': t', ['t', arc], n, base)
            out = os.path.join(base, 'x%d_%d' % (n, k))
            os.makedirs(out)
            if check(label + ': x', ['x', arc], n, out):
                if same_tree(os.path.join(base, src), os.path.join(out, src)):
                    ok('%s N=%d: extracción idéntica' % (label, n))
                else:
                    bad('%s N=%d: extracción distinta' % (label, n))
            shutil.rmtree(out, ignore_errors=True)
            os.remove(arc)
    shutil.rmtree(base, ignore_errors=True)
    print('thread_budget: %d ok, %d fallos' % (passes, fails))
    sys.exit(1 if fails else 0)


main()
