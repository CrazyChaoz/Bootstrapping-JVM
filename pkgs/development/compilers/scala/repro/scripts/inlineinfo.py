#!/usr/bin/env python3
"""inlineinfo.py CLASS...: the method entries of each class file's Scala3InlineInfo attribute."""
import struct, sys

def parse(b):
    p = 10; cp = [None]; n = struct.unpack('>H', b[8:10])[0]; i = 1
    while i < n:
        t = b[p]; p += 1
        if t == 1:
            l = struct.unpack('>H', b[p:p+2])[0]; cp.append(b[p+2:p+2+l].decode('utf8', 'replace')); p += 2 + l
        elif t in (3, 4, 9, 10, 11, 12, 17, 18): cp.append(None); p += 4
        elif t in (5, 6): cp += [None, None]; p += 8; i += 1
        elif t in (7, 8, 16, 19, 20): cp.append(None); p += 2
        elif t == 15: cp.append(None); p += 3
        else: raise ValueError(t)
        i += 1
    p += 6; ni = struct.unpack('>H', b[p:p+2])[0]; p += 2 + 2 * ni
    def members(p):
        c = struct.unpack('>H', b[p:p+2])[0]; p += 2
        for _ in range(c):
            ac = struct.unpack('>H', b[p+6:p+8])[0]; p += 8
            for _ in range(ac):
                l = struct.unpack('>I', b[p+2:p+6])[0]; p += 6 + l
        return p
    p = members(members(p))
    ac = struct.unpack('>H', b[p:p+2])[0]; p += 2
    for _ in range(ac):
        nm = cp[struct.unpack('>H', b[p:p+2])[0]]; l = struct.unpack('>I', b[p+2:p+6])[0]
        if nm == 'Scala3InlineInfo':
            a = b[p+6:p+6+l]; flags = a[1]; q = 2
            if flags & 2: q += 4  # sam
            cnt = struct.unpack('>H', a[q:q+2])[0]; q += 2; out = []
            for _ in range(cnt):
                nn, dd = struct.unpack('>HH', a[q:q+4]); out.append(f"{cp[nn]}{cp[dd]} {a[q+4]}"); q += 5
            return flags, out
        p += 6 + l

for f in sys.argv[1:]:
    r = parse(open(f, 'rb').read())
    print(f, r[0] if r else None)
    for m in (r[1] if r else []): print('  ', m)
