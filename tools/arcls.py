#!/usr/bin/env python3
"""Prototipo de referencia: lista un archivo FreeArc según la spec (para validar antes del port a Pascal)."""
import re, sys, struct, zlib, lzma, datetime

SIG = b'ArC\x01'
BLOCK = {0: 'DESCR', 1: 'HEADER', 2: 'DATA', 3: 'DIR', 4: 'FOOTER', 5: 'RECOVERY'}

class Buf:
    def __init__(s, b): s.b = b + b'\0' * 9; s.n = len(b); s.p = 0
    def eof(s): return s.p >= s.n
    def int(s):
        b = s.b; p = s.p; x = b[p]
        for k in range(8):
            if (x >> k) & 1 == 0:
                v = int.from_bytes(b[p:p + k + 1], 'little') >> (k + 1); s.p += k + 1; return v
        v = int.from_bytes(b[p + 1:p + 9], 'little'); s.p += 9; return v
    def u8(s): v = s.b[s.p]; s.p += 1; return v
    def u32(s): v = struct.unpack_from('<I', s.b, s.p)[0]; s.p += 4; return v
    def str(s):
        e = s.b.index(0, s.p); v = s.b[s.p:e].decode('utf-8', 'replace'); s.p = e + 1; return v

def parse_mem(t):
    m = re.fullmatch(r'(\d+)([bkmg]?)b?', t.lower())
    if not m: return None
    return int(m[1]) << {'': 20, 'b': 0, 'k': 10, 'm': 20, 'g': 30}[m[2]]

def decompress(method, data, origsize):
    stages = method.split('+')
    for m in reversed(stages):
        name, *params = m.split(':')
        if name == 'storing':
            continue
        if name != 'lzma':
            raise NotImplementedError(m)
        d, lc, lp, pb = 64 << 20, 3, 0, 2
        for q in params:
            if q[:2] == 'lc': lc = int(q[2:])
            elif q[:2] == 'lp': lp = int(q[2:])
            elif q[:2] == 'pb': pb = int(q[2:])
            elif q[:1] == 'd' and parse_mem(q[1:]) is not None: d = parse_mem(q[1:])
            elif q.isdigit(): pass  # numFastBytes, no afecta al decoder
            elif parse_mem(q) is not None: d = parse_mem(q)
        f = [{'id': lzma.FILTER_LZMA1, 'dict_size': d, 'lc': lc, 'lp': lp, 'pb': pb}]
        data = lzma.LZMADecompressor(lzma.FORMAT_RAW, filters=f).decompress(data, origsize)
    return data

def crc(b): return zlib.crc32(b) & 0xffffffff

def read_block(f, pos, method, origsize, compsize, want_crc):
    f.seek(pos); raw = f.read(compsize)
    data = decompress(method, raw, origsize)
    assert len(data) == origsize, 'tamaño'
    assert crc(data) == want_crc, 'CRC de bloque'
    return data

def local_descriptor(f, arcsize, dpos):
    f.seek(dpos); raw = f.read(min(arcsize - dpos, 4096))
    b = Buf(raw[:-4]); assert crc(raw[:-4]) == struct.unpack('<I', raw[-4:])[0], 'CRC descriptor'
    assert b.u32() == struct.unpack('<I', SIG)[0]
    t = b.int(); m = b.str(); o = b.int(); c = b.int(); k = b.u32()
    return dict(type=t, method=m, origsize=o, compsize=c, crc=k, pos=dpos - c)

def main(path):
    f = open(path, 'rb'); f.seek(0, 2); arcsize = f.tell()
    n = min(arcsize, 4096); f.seek(arcsize - n); tail = f.read(n)
    dpos = arcsize - n + tail.rindex(SIG)
    ft = local_descriptor(f, arcsize, dpos)
    assert ft['type'] == 4
    print('FOOTER', ft)
    b = Buf(read_block(f, ft['pos'], ft['method'], ft['origsize'], ft['compsize'], ft['crc']))
    blocks = []
    for _ in range(b.int()):
        t = b.int(); m = b.str(); rel = b.int(); o = b.int(); c = b.int(); k = b.u32()
        blocks.append(dict(type=t, method=m, pos=ft['pos'] - rel, origsize=o, compsize=c, crc=k))
    locked = b.u8(); oldc = b.int(); b.p += oldc * 4
    rr = b.str() if not b.eof() else ''
    cmt = ''
    if not b.eof():
        L = b.int(); cmt = b.b[b.p:b.p + L].decode('utf-8', 'replace'); b.p += L
    print(f'locked={locked} rr={rr!r} comment={cmt!r} sfx={blocks[0]["pos"]}')
    for bl in blocks:
        print(f'  {BLOCK.get(bl["type"], bl["type"]):8} pos={bl["pos"]:<10} {bl["origsize"]:>10} {bl["compsize"]:>10} {bl["method"]}')
    for bl in blocks:
        if bl['type'] != 3: continue
        d = Buf(read_block(f, bl['pos'], bl['method'], bl['origsize'], bl['compsize'], bl['crc']))
        nb = d.int(); nf = [d.int() for _ in range(nb)]
        meth = [d.str() for _ in range(nb)]
        offs = [d.int() for _ in range(nb)]; csz = [d.int() for _ in range(nb)]
        dirs = [d.str() for _ in range(d.int())]
        tot = sum(nf)
        names = [d.str() for _ in range(tot)]; dn = [d.int() for _ in range(tot)]
        sizes = [d.int() for _ in range(tot)]; times = [d.u32() for _ in range(tot)]
        isdir = [d.u8() for _ in range(tot)]; crcs = [d.u32() for _ in range(tot)]
        tag = d.int() if not d.eof() else None
        print(f'DIR @ {bl["pos"]}: {nb} solid block(s), {tot} file(s), tag_end={tag}, rest={d.n - d.p}')
        for i in range(nb):
            print(f'  data[{i}] pos={bl["pos"] - offs[i]} comp={csz[i]} files={nf[i]} {meth[i]}')
        for i in range(tot):
            full = (dirs[dn[i]] + '/' if dirs[dn[i]] else '') + names[i]
            ts = datetime.datetime.fromtimestamp(times[i], datetime.timezone.utc).strftime('%Y-%m-%d %H:%M')
            print(f'  {"D" if isdir[i] else "-"} {sizes[i]:>10} {ts} {crcs[i]:08x} {full}')

if __name__ == '__main__':
    main(sys.argv[1])
