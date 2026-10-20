#!/usr/bin/env python3
"""
tests/fuzz_update.py — fuzz de actualización contra FreeArc 0.67.1 (arc.exe).

Reproduce el pendiente de docs/BUGS-FREEARC.md §6: secuencias aleatorias de `a/u/f/d`,
con cambios de modo sólido y de método (incluye `rep` solo y `rep+tor:16`, #257/#392),
y compara el resultado de PArc contra el de arc.exe:

  - arc.exe t tiene que aceptar el archivo que escribió PArc (autoridad del formato);
  - la estructura de bloques (qué archivos, en qué orden, con qué método) tiene que ser igual;
  - el árbol extraído tiene que ser idéntico.

Uso: tests/fuzz_update.py [--iters N] [--seed S] [--work DIR] [--keep]
Sale con 0 si no encontró diferencias.
"""
import argparse, os, random, re, shutil, subprocess, sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
PARC = os.environ.get('PARC_BIN', os.path.join(ROOT, 'build/linux64/parc'))
ARC = os.environ.get('ARC_EXE', '/mnt/IA_LAB/agentes/PArc/ref/Arc.exe')
WORK = os.environ.get('FUZZ_WORK', '/mnt/IA_LAB/agentes/PArc/fuzz_update')
ENV = dict(os.environ,
           WINEPREFIX=os.environ.get('WINEPREFIX', '/mnt/IA_LAB/agentes/PArc/wine'),
           WINEDEBUG='-all')

# Los métodos donde el codificador de PArc puede dar otros bytes que el de arc.exe
# (documentado en docs/USO.md): se comparan estructura y método, no el tamaño comprimido.
METHODS = ['-m0', '-m1', '-m3', '-m4', '-m5', '-m9',
           '-mlzma', '-mppmd', '-mrep', '-mtor:16', '-mtor:3', '-m4x4', '-mdict',
           '-mexe+lzma', '-mrep:96m+lzma', '-mdelta+lzma',
           '-msrep', '-msrep+lzma', '-mdispack', '-mdispack+lzma']
# (rep+tor:16 queda afuera: hace caer al codificador de arc.exe, #392, y a veces termina con
#  código 0 y un archivo mal formado; PArc lo comprime bien y arc.exe lo lee. Ver BUGS §1.)

FILES = ['a.txt', 'b.txt', 'c.bin', 'd.bin', 'sub/e.txt', 'sub/f.bin', 'sub/deep/g.txt']


def run(cmd, cwd, check=False, timeout=600):
    try:
        p = subprocess.run(cmd, cwd=cwd, env=ENV, stdin=subprocess.DEVNULL,
                           capture_output=True, text=True, errors='replace', timeout=timeout)
    except subprocess.TimeoutExpired as e:
        out = (e.stdout or b'') if isinstance(e.stdout, bytes) else (e.stdout or '')
        err = (e.stderr or b'') if isinstance(e.stderr, bytes) else (e.stderr or '')
        if isinstance(out, bytes):
            out = out.decode('utf-8', 'replace')
        if isinstance(err, bytes):
            err = err.decode('utf-8', 'replace')
        p = subprocess.CompletedProcess(cmd, 124, out, err + f'\n(timeout {timeout}s)')
    if check and p.returncode != 0:
        raise RuntimeError(f'{cmd} -> {p.returncode}\n{p.stdout}\n{p.stderr}')
    return p


def content(rng, kind, size=None):
    if kind == 'text':
        n = size or rng.randint(200, 40000)
        return ''.join(f'{rng.randint(0, 99999)}\n' for _ in range(n // 5))
    if kind == 'seq':
        a = rng.randint(0, 10000)
        return ''.join(f'{i}\n' for i in range(a, a + (size or rng.randint(100, 8000))))
    n = size or rng.randint(100, 60000)
    return bytes(rng.getrandbits(8) for _ in range(n))


KINDS = ['text', 'seq', 'bin']


def write_file(root, rel, data):
    p = os.path.join(root, rel)
    os.makedirs(os.path.dirname(p) or '.', exist_ok=True)
    mode = 'wb' if isinstance(data, bytes) else 'w'
    with open(p, mode) as f:
        f.write(data)


def make_tree(rng, root):
    shutil.rmtree(root, ignore_errors=True)
    os.makedirs(root)
    for rel in FILES:
        kind = KINDS[rng.randrange(len(KINDS))]
        write_file(root, rel, content(rng, kind))
    stamp = 1600000000
    for dirpath, _, names in os.walk(root):
        for n in names:
            os.utime(os.path.join(dirpath, n), (stamp, stamp))
    os.utime(root, (stamp, stamp))


def blocks(archive):
    """(orig, comp, método, [archivos]) por bloque, leído con `parc lb`."""
    names = []
    lst = run([PARC, 'l', archive], '.', check=True).stdout.splitlines()
    for line in lst[2:]:
        if line.startswith('-----'):
            break
        names.append(line[47:])
    out, cur = [], None
    for line in run([PARC, 'lb', archive], '.', check=True).stdout.splitlines():
        m = re.match(r'\s+data\s+pos=\S+\s+orig=(\d+)\s+comp=(\d+)\s+(.*)', line)
        if m:
            cur = (int(m.group(1)), int(m.group(2)), m.group(3).strip())
            continue
        m = re.match(r'\s+(\d+) archivo\(s\) desde #(\d+)', line)
        if m and cur:
            n, f = int(m.group(1)), int(m.group(2))
            out.append(cur + (tuple(names[f:f + n]),))
            cur = None
    return out


def same_structure(a, b):
    ba, bb = blocks(a), blocks(b)
    if [x[3] for x in ba] != [x[3] for x in bb]:
        return False, 'bloques/orden de archivos distintos'
    for x, y in zip(ba, bb):
        if x[2] != y[2]:
            return False, f'método distinto: {x[2]} vs {y[2]}'
    return True, ''


def extract_ok(archive, dest, who):
    shutil.rmtree(dest, ignore_errors=True)
    os.makedirs(dest)
    if who == 'arc':
        p = run([ 'wine', ARC, 'x', os.path.abspath(archive), '-o+'], dest)
    else:
        p = run([PARC, 'x', os.path.abspath(archive), '-o+'], dest)
    return p.returncode == 0, p.stdout + p.stderr


def tree_hash(root):
    import hashlib
    h = {}
    for dirpath, _, names in os.walk(root):
        for n in names:
            p = os.path.join(dirpath, n)
            rel = os.path.relpath(p, root)
            with open(p, 'rb') as f:
                h[rel] = hashlib.sha256(f.read()).hexdigest()
    return h


def gen_op(rng, present):
    """Elige la próxima operación mirando los archivos que existen ahora.

    Devuelve (acción, archivo, cmd, args, descripción). La acción ('write'/'unlink'/None)
    se aplica a los DOS árboles antes de correr el comando, así ambos ven el mismo disco.
    """
    kind = rng.choices(['new', 'mod', 'del', 'a', 'u', 'f', 'd'],
                       weights=[2, 2, 2, 3, 2, 2, 2])[0]
    if kind == 'new':
        rel = f'n{rng.randint(0, 9999)}.dat'
        return 'write', rel, 'a', [rel], f'a nuevo {rel}'
    if kind == 'mod':
        rel = rng.choice(sorted(present))
        return 'write', rel, rng.choice(['a', 'u', 'f']), [rel], f'{rel} modificado'
    if kind == 'del':
        rel = rng.choice(sorted(present))
        return 'unlink', rel, 'd', [rel], f'd {rel} (y borrado del disco)'
    if kind == 'd':
        rel = rng.choice(sorted(present))
        return None, None, 'd', [rel], f'd {rel}'
    target = ['.'] if rng.random() < 0.2 else [rng.choice(sorted(present))]
    return None, None, kind, target, f'{kind} {" ".join(target)}'


def one_iteration(rng, it):
    base = os.path.join(WORK, f'it{it}')
    shutil.rmtree(base, ignore_errors=True)
    os.makedirs(base)
    c = os.path.join(base, 'c')
    make_tree(rng, c)

    m0 = rng.choice(METHODS)
    solid = rng.choice(['', '-s', '-s-'])
    base_args = [m0] + ([solid] if solid else [])
    results = []
    for who in ('arc', 'par'):
        w = os.path.join(base, 'w_' + who)
        shutil.copytree(c, w, symlinks=True)
        if who == 'arc':
            p = run(['wine', ARC, 'a', 'base.arc', '.', '-xbase.arc'] + base_args, w)
        else:
            p = run([PARC, 'a', 'base.arc', '.', '-xbase.arc', '--no-progress'] + base_args, w)
        if p.returncode != 0:
            if who == 'arc':
                return f'ORACLE: arc.exe no pudo crear la base ({m0} {solid}): {p.stdout[-200:]}'
            return f'base parc falló ({m0} {solid}): {p.stdout}\n{p.stderr}'
        results.append((who, w, os.path.join(w, 'base.arc')))

    present = {f for f in FILES}
    history = []
    for _ in range(rng.randint(1, 5)):
        action, rel, cmd, files, desc = gen_op(rng, present)
        m = rng.choice(METHODS) if rng.random() < 0.5 else m0
        s = rng.choice(['', '-s', '-s-']) if rng.random() < 0.5 else solid
        extra = [m] + ([s] if s else [])
        if rng.random() < 0.08:
            extra.append('-rr' + rng.choice(['', '2%', '10%']))
        if rng.random() < 0.06:
            extra.append('--recompress')
        history.append(f'{cmd} {" ".join(files)} {" ".join(extra)}  ({desc})')
        # el mismo cambio de disco en los dos árboles (mismo contenido y misma fecha)
        if action is not None:
            data = content(rng, KINDS[rng.randrange(3)]) if action == 'write' else None
            stamp = 1700000000 + rng.randint(0, 99999)
            for who, w, _ in results:
                path = os.path.join(w, rel)
                if action == 'write':
                    write_file(w, rel, data)
                    os.utime(path, (stamp, stamp))
                elif os.path.exists(path):
                    os.unlink(path)
            if action == 'write':
                present.add(rel)
            else:
                present.discard(rel)
        for who, w, _ in results:
            if who == 'arc':
                p = run(['wine', ARC, cmd, 'base.arc'] + files + ['-xbase.arc'] + extra, w)
            else:
                p = run([PARC, cmd, 'base.arc'] + files + ['-xbase.arc', '--no-progress'] + extra, w)
            if p.returncode != 0:
                if who == 'arc':
                    return f'ORACLE: arc.exe falló en {desc} {extra}: {p.stdout[-200:]}'
                return (f'{who}: {desc} {extra} falló ({p.returncode}): {p.stdout}\n{p.stderr}'
                        f'\n  ' + '\n  '.join(history))

    (_, wa, aa), (_, wp, ap) = results
    # 1. arc.exe tiene que aceptar lo que escribió parc
    t = run(['wine', ARC, 't', ap], wa)
    if 'All OK' not in t.stdout.replace('\r', '\n'):
        # Sin un srep.exe al lado de Arc.exe, arc.exe no puede descomprimir srep (el
        # compresor es externo en arc.ini). No es un defecto del archivo de PArc.
        metodos = [b[2] for b in blocks(ap)]
        if 'invalid compression method' in (t.stdout + t.stderr) and any('srep' in m for m in metodos):
            return 'ORACLE: arc.exe sin srep.exe no puede probar srep (entorno)'
        return 'arc.exe t rechaza el archivo de parc\n' + t.stdout + t.stderr
    # 2. estructura igual
    ok, why = same_structure(ap, aa)
    if not ok:
        return f'estructura: {why}\n  base={m0} {solid}\n  ' + '\n  '.join(history)
    # 3. extracción igual
    da, dp = os.path.join(base, 'x_arc'), os.path.join(base, 'x_par')
    oka, outa = extract_ok(aa, da, 'arc')
    okp, outp = extract_ok(ap, dp, 'par')
    if not (oka and okp):
        return (f'extracción falló: arc={oka} par={okp}\n{outa}\n{outp}'
                f'\n  base={m0} {solid}\n  ' + '\n  '.join(history))
    ha, hp = tree_hash(da), tree_hash(dp)
    if ha != hp:
        diff = sorted(set(ha) ^ set(hp)) or [k for k in ha if ha[k] != hp[k]]
        return (f'árboles distintos tras extraer: {diff[:5]}'
                f'\n  base={m0} {solid}\n  ' + '\n  '.join(history))
    return None


def main():
    global WORK
    ap = argparse.ArgumentParser()
    ap.add_argument('--iters', type=int, default=50)
    ap.add_argument('--seed', type=int, default=1)
    ap.add_argument('--work', default=WORK)
    ap.add_argument('--keep', action='store_true')
    ap.add_argument('-v', '--verbose', action='store_true')
    a = ap.parse_args()
    WORK = a.work
    os.makedirs(WORK, exist_ok=True)
    fails = 0
    oracle = 0
    for it in range(a.iters):
        if a.verbose:
            print(f'it={it}', flush=True)
        rng = random.Random(a.seed * 100000 + it)
        try:
            err = one_iteration(rng, it)
        except Exception as e:  # noqa: BLE001
            err = f'excepción: {e}'
        if err and err.startswith('ORACLE:'):
            oracle += 1
            print(f'skip it={it} seed={a.seed}  {err[7:]}', flush=True)
            shutil.rmtree(os.path.join(WORK, f'it{it}'), ignore_errors=True)
        elif err:
            fails += 1
            print(f'FAIL it={it} seed={a.seed}\n  {err}', flush=True)
            if not a.keep:
                break
        else:
            shutil.rmtree(os.path.join(WORK, f'it{it}'), ignore_errors=True)
    print(f'== fuzz_update: {a.iters - fails - oracle if not a.keep else "?"} ok, '
          f'{fails} fallas, {oracle} omitidas por arc.exe (seed {a.seed})')
    return 1 if fails else 0


if __name__ == '__main__':
    sys.exit(main())
