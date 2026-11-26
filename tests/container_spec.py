#!/usr/bin/env python3
"""Independent reader of PArc's container (docs/formato/FORMATO-PARC.md §1-§3, format 2),
written from the specification only, to check that the document describes what PArc writes.

  container_spec.py <archive.parc>
  container_spec.py --from-lt < "parc lt" output     the same lines, from PArc's own listing

Prints one line per entry: "<name> <kind> <size> <crc> <mtime ns> <mode or ->" (kind: f, d, l),
then "comment=<hex>", "locked=<0|1>", "recovery=<spec>". Index encrypted with -hp: not
supported (exits 3). Exit 1 on any inconsistency."""
import lzma
import struct
import sys
import zlib


def fail(msg):
    print('ERROR: ' + msg)
    sys.exit(1)


class R:
    def __init__(self, b):
        self.b, self.p = b, 0

    def u8(self):
        if self.p >= len(self.b): fail('read past end')
        self.p += 1
        return self.b[self.p - 1]

    def u32(self):
        v = struct.unpack_from('<I', self.b, self.p)[0]; self.p += 4; return v

    def uv(self):
        v = s = 0
        while True:
            c = self.u8()
            v |= (c & 0x7F) << s; s += 7
            if c < 0x80:
                if c == 0 and s > 7: fail('non-canonical Uv')
                if v >= 1 << 64: fail('Uv too large')
                return v

    def sv(self):
        v = self.uv()
        return (v >> 1) if not v & 1 else -(v >> 1) - 1

    def ube(self, w):
        v = int.from_bytes(self.b[self.p:self.p + w], 'big'); self.p += w; return v

    def raw(self, n):
        if self.p + n > len(self.b): fail('read past end')
        self.p += n
        return self.b[self.p - n:self.p]

    def str(self):
        return self.raw(self.uv())

    def zstr(self):
        e = self.b.index(0, self.p)
        s = self.b[self.p:e]; self.p = e + 1
        return s


if sys.argv[1] == '--from-lt':
    import re
    for line in sys.stdin.buffer.read().decode('utf-8', 'surrogateescape').splitlines():
        m = re.match(r'  (\d+)\s+(\S+)\s+(\d+)\s+(\d+)\s+([0-9A-F]{8})\s+(-?\d+)\s+(\S+)\s+(.*)$', line)
        if not m: continue
        blk, size, crc, ns, mode, name = m.group(2), m.group(4), m.group(5), m.group(6), m.group(7), m.group(8)
        k = {'dir': 'd', 'link': 'l'}.get(blk, 'f')
        if k == 'l': name = name.split(' -> ')[0]
        mo = ('%o' % (int(mode, 8) & 0o7777)) if mode.startswith('0') else '-'
        print('%s %s %s %s %s %s' % (name, k, size, crc, ns, mo))
    sys.exit(0)

d = open(sys.argv[1], 'rb').read()
end = len(d)
# §2.5: recovery descriptor at the end?
t = d[-48:]
if len(d) >= 48 and t[44:48] == b'PArr' and struct.unpack_from('<I', t, 40)[0] == zlib.crc32(t[:40] + t[44:48]):
    end -= struct.unpack_from('<Q', t, 8)[0]
loc = d[end - 24:end]
if loc[20:24] != b'PAel' or struct.unpack_from('<I', loc, 16)[0] != zlib.crc32(loc[:16] + loc[20:24]):
    fail('no end locator')
ipos, alen = struct.unpack_from('<QQ', loc, 0)
base = end - alen
h = d[base:base + 16]
if h[:8] != b'PArc\r\n\x1a\n' or struct.unpack_from('<I', h, 12)[0] != zlib.crc32(h[:12]) or struct.unpack_from('<HH', h, 8) != (2, 0):
    fail('bad head')
r = R(d)
r.p = base + ipos
if r.raw(4) != b'PAix': fail('no index magic')
if r.uv() != ipos: fail('index position')
slen, plen = r.uv(), r.uv()
method = r.str().decode()
scrc, pcrc = r.u32(), r.u32()
hend = r.p
if r.u32() != zlib.crc32(d[base + ipos:hend]): fail('index header crc')
stored = r.raw(slen)
if zlib.crc32(stored) != scrc: fail('stored payload crc')
if r.p != end - 24: fail('index does not end at the locator')
if method == 'storing':
    pay = stored
elif method.startswith('lzma:') and '+' not in method:
    pay = lzma.LZMADecompressor(lzma.FORMAT_RAW, filters=[{'id': lzma.FILTER_LZMA1, 'dict_size': 1 << 20,
                                                            'lc': 3, 'lp': 0, 'pb': 2}]).decompress(stored, plen)
else:
    print('unsupported index method ' + method)
    sys.exit(3)
if len(pay) != plen or zlib.crc32(pay) != pcrc: fail('decoded payload')

p = R(pay)
N = Z = B = 0
names = sizes = crcs = times = modes = kinds = links = None
comment, locked, recovery = b'', 0, b''
first = True
while True:
    sid = p.u8()
    if sid == 0: break
    ln = p.uv()
    s = R(p.raw(ln))
    if first and sid != 1: fail('ARCHIVE is not first')
    first = False
    if sid == 1:
        fl = s.uv(); locked = fl & 1; N, Z, B = s.uv(), s.uv(), s.uv()
    elif sid == 2:
        runs = [(s.uv(), s.uv()) for _ in range(s.uv())]
        meth = [s.str() for _ in range(s.uv())]
        midx = [s.uv() for _ in range(B)]
        cnt = [s.uv() for _ in range(B)]
        ssz = [s.uv() for _ in range(B)]
        if sum(c for _, c in runs) != B or sum(cnt) != N - Z: fail('block counts')
    elif sid == 3:
        dirs, prev = [], b''
        for _ in range(s.uv()):
            k = s.uv(); prev = prev[:k] + s.zstr(); dirs.append(prev)
        bases = [s.zstr() for _ in range(N)]
        mode = s.u8(); idx = []; cur = 0
        for _ in range(N):
            cur = s.uv() if mode == 0 else cur + s.sv(); idx.append(cur)
        names = [(dirs[i] + b'/' + b_) if dirs[i] else b_ for i, b_ in zip(idx, bases)]
    elif sid == 4:
        kinds = list(s.raw(Z))
    elif sid == 5:
        w = s.u8()
        sizes = [s.uv() if w == 0xFF else s.ube(w) for _ in range(N - Z)]
    elif sid == 6:
        crcs = [s.u32() if sz else 0 for sz in sizes]
    elif sid == 7:
        if s.u8() == 1:
            times, cur = [], 0
            for _ in range(N): cur += s.sv(); times.append(cur)
        else:
            b0 = s.sv(); w = s.u8(); secs = [b0 + s.ube(w) for _ in range(N)]
            k = s.u8(); ws = s.u8(); times = [sc * 10**9 + s.ube(ws) * 10**k for sc in secs]
    elif sid == 8:
        modes = [s.uv() for _ in range(N)]
    elif sid == 9:
        s.p = len(s.b)
    elif sid == 10:
        links = [s.str() if k >= 2 else None for k in kinds]
    elif sid == 0x81:
        comment = s.raw(len(s.b))
    elif sid == 0x82:
        recovery = s.raw(len(s.b))
    elif sid & 0x80:
        s.p = len(s.b)
    else:
        fail('unknown mandatory section %d' % sid)
    if s.p != len(s.b): fail('section %d length' % sid)
if p.p != len(pay): fail('bytes after the end')
for i in range(N):
    if i < Z:
        k = 'd' if kinds[i] == 1 else ('l' if kinds[i] >= 2 else 'f'); sz, c = 0, 0
    else:
        k = 'f'; sz, c = sizes[i - Z], crcs[i - Z]
    m = ('%o' % (modes[i] & 0o7777)) if modes else '-'
    print('%s %s %d %08X %d %s' % (names[i].decode('utf-8', 'surrogateescape'), k, sz, c, times[i], m))
print('comment=' + comment.hex())
print('locked=%d' % locked)
print('recovery=' + recovery.decode())
