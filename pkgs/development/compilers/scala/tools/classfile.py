"""Class files as Python data (for jdk-api-view.py and scala-pickle-rename.py): parse(bytes) gives a dict of the constant
pool (a list of (tag, bytes), None for the second slot of long and double), the access, this
and super indices (head), the interfaces, the fields and methods ([access, name, descriptor,
attributes]) and the attributes ((name index, bytes)); write(dict) gives the bytes again.
utf8(cf, s) is the index of the UTF8 constant s (added if missing), text(cf, i) its text.
"""
import struct


class Reader:
    def __init__(self, data):
        self.d, self.p = data, 0

    def u1(self):
        self.p += 1
        return self.d[self.p - 1]

    def u2(self):
        self.p += 2
        return struct.unpack_from(">H", self.d, self.p - 2)[0]

    def u4(self):
        self.p += 4
        return struct.unpack_from(">I", self.d, self.p - 4)[0]

    def bytes(self, n):
        self.p += n
        return self.d[self.p - n:self.p]


def parse(data):
    r = Reader(data)
    assert r.u4() == 0xCAFEBABE
    minor, major = r.u2(), r.u2()
    count = r.u2()
    pool = [None]
    i = 1
    while i < count:
        tag = r.u1()
        if tag == 1:
            n = r.u2()
            pool.append((tag, r.bytes(n)))
        elif tag in (3, 4, 9, 10, 11, 12, 17, 18):
            pool.append((tag, r.bytes(4)))
        elif tag in (5, 6):
            pool.append((tag, r.bytes(8)))
            pool.append(None)
            i += 1
        elif tag in (7, 8, 16, 19, 20):
            pool.append((tag, r.bytes(2)))
        elif tag == 15:
            pool.append((tag, r.bytes(3)))
        else:
            raise ValueError(f"bad constant tag {tag}")
        i += 1
    head = r.bytes(6)  # access, this, super
    nif = r.u2()
    ifaces = r.bytes(2 * nif)

    def members():
        out = []
        for _ in range(r.u2()):
            acc, name, desc = r.u2(), r.u2(), r.u2()
            out.append([acc, name, desc, attrs()])
        return out

    def attrs():
        out = []
        for _ in range(r.u2()):
            name = r.u2()
            out.append((name, r.bytes(r.u4())))
        return out

    fields = members()
    methods = members()
    cattrs = attrs()
    return dict(minor=minor, major=major, pool=pool, head=head, nif=nif,
                ifaces=ifaces, fields=fields, methods=methods, attrs=cattrs)


def write(cf):
    out = bytearray(struct.pack(">IHHH", 0xCAFEBABE, cf["minor"], cf["major"],
                                len(cf["pool"])))
    for e in cf["pool"][1:]:
        if e is None:
            continue
        tag, b = e
        out.append(tag)
        if tag == 1:
            out += struct.pack(">H", len(b))
        out += b
    out += cf["head"] + struct.pack(">H", cf["nif"]) + cf["ifaces"]

    def attrs(a):
        o = bytearray(struct.pack(">H", len(a)))
        for name, b in a:
            o += struct.pack(">HI", name, len(b)) + b
        return o
    for ms in (cf["fields"], cf["methods"]):
        out += struct.pack(">H", len(ms))
        for acc, name, desc, a in ms:
            out += struct.pack(">HHH", acc, name, desc) + attrs(a)
    out += attrs(cf["attrs"])
    return bytes(out)


def utf8(cf, s):
    b = s.encode("utf-8")
    for i, e in enumerate(cf["pool"]):
        if e and e[0] == 1 and e[1] == b:
            return i
    cf["pool"].append((1, b))
    return len(cf["pool"]) - 1


def text(cf, i):
    return cf["pool"][i][1].decode("utf-8")
