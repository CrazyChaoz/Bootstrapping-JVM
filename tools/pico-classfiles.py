#!/usr/bin/env python3
"""Post-process javac output the way PiCo (the Pizza compiler) would.

usage: pico-classfiles.py CLASSDIR META.json

  * adds a "JacoMeta" attribute (u2 index of a UTF8 constant holding the
    text of the @meta doc comment) to every class, method and field listed
    in META.json (as written by pizza2java.py --meta-out);
  * renames methods called NAME$$pizzaXYZ to NAME.  This expresses overrides
    with a different primitive return type (scala.Int.$plus()I overriding
    scala.Long.$plus()J), which the JVM allows but Java source does not.
"""
import json
import os
import struct
import sys

SUFFIX = "$$pizza"
PRIMS = {"B": "byte", "C": "char", "D": "double", "F": "float", "I": "int",
         "J": "long", "S": "short", "Z": "boolean", "V": "void"}


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


def desc_params(desc):
    """Simple names of the parameter types of a method descriptor."""
    out = []
    i = 1
    while desc[i] != ")":
        dims = 0
        while desc[i] == "[":
            dims += 1
            i += 1
        if desc[i] == "L":
            j = desc.index(";", i)
            name = desc[i + 1:j].rsplit("/", 1)[-1].rsplit("$", 1)[-1]
            i = j + 1
        else:
            name = PRIMS[desc[i]]
            i += 1
        out.append(name + "[]" * dims)
    return out


def desc_ret(desc):
    r = desc[desc.index(")") + 1:]
    dims = r.count("[")
    r = r.lstrip("[")
    name = r[1:-1].rsplit("/", 1)[-1].rsplit("$", 1)[-1] if r[0] == "L" else PRIMS[r]
    return name + "[]" * dims


def simple(ty):
    ty = ty.replace(" ", "")
    dims = ty.count("[]")
    return ty.replace("[]", "").rsplit(".", 1)[-1] + "[]" * dims


def main(classdir, metafile):
    metas = {}
    with open(metafile) as fh:
        for cls, kind, name, params, meta, ret in json.load(fh):
            metas.setdefault(cls, []).append((kind, name, params, meta, ret))
    done = set()
    for dp, _, fs in os.walk(classdir):
        for fn in fs:
            if not fn.endswith(".class"):
                continue
            path = os.path.join(dp, fn)
            cls = os.path.relpath(path, classdir)[:-6].replace(os.sep, ".")
            with open(path, "rb") as fh:
                data = fh.read()
            want = metas.get(cls, [])
            if not want and SUFFIX.encode() not in data:
                continue
            cf = parse(data)
            # NAME$$pizzaXYZ -> NAME, in declarations and references
            for i, e in enumerate(cf["pool"]):
                if e and e[0] == 1 and SUFFIX.encode() in e[1]:
                    n = e[1].decode("utf-8")
                    cf["pool"][i] = (1, n[:n.index(SUFFIX)].encode("utf-8"))
            attr = None
            for kind, name, params, meta, ret in want:
                if kind in ("case", "algebraic"):
                    # PiCo marks algebraic classes and their cases with a
                    # JacoInterface attribute (u2 mods, u2 mods >> 16) and
                    # makes the case fields public synthetic
                    mods = 0x00200000 if kind == "case" else 0x00100000
                    cf["attrs"].append((utf8(cf, "JacoInterface"),
                                        struct.pack(">HH", mods & 0xffff, mods >> 16)))
                    if kind == "case":
                        synth = utf8(cf, "Synthetic")
                        for f in cf["fields"]:
                            if text(cf, f[1]) in params:
                                f[0] |= 0x1000
                                f[3].append((synth, b""))
                        for m in cf["methods"]:
                            if text(cf, m[1]) == "<init>":
                                m[0] |= 0x1000
                    done.add((cls, kind, name, str(params)))
                    continue
                if attr is None:
                    attr = utf8(cf, "JacoMeta")
                value = struct.pack(">H", utf8(cf, meta))
                if kind == "class":
                    cf["attrs"].append((attr, value))
                    done.add((cls, kind, name, str(params)))
                    continue
                ms = cf["fields"] if kind == "field" else cf["methods"]
                jname = name
                if kind == "method" and name == cls.rsplit(".", 1)[-1].rsplit("$", 1)[-1]:
                    jname = "<init>"
                if SUFFIX in name:
                    jname = name[:name.index(SUFFIX)]
                hits = [m for m in ms if text(cf, m[1]) == jname]
                if kind == "method":
                    hits = [m for m in hits if
                            [simple(p) for p in params] == desc_params(text(cf, m[2]))]
                    if len(hits) > 1:
                        hits = [m for m in hits if desc_ret(text(cf, m[2])) == simple(ret)]
                if len(hits) != 1:
                    print(f"error: {cls}.{name}{params}: {len(hits)} matches",
                          file=sys.stderr)
                    sys.exit(1)
                hits[0][3].append((attr, value))
                done.add((cls, kind, name, str(params)))
            with open(path, "wb") as fh:
                fh.write(write(cf))
    missing = [(c, k, n, p) for c, ws in metas.items() for k, n, p, _, _ in ws
               if (c, k, n, str(p)) not in done]
    for c, k, n, p in missing:  # noqa
        print(f"error: no class file for meta of {c} {k} {n}", file=sys.stderr)
    if missing:
        sys.exit(1)


if __name__ == "__main__":
    main(sys.argv[1], sys.argv[2])
