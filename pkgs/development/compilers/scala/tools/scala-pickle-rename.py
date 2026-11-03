#!/usr/bin/env python3
"""Rename a type name in the Scala signatures (pickles) of class files, in place.

usage: scala-pickle-rename.py OLD NEW FILE...   (OLD and NEW of the same length)

A class compiled from source while an older class file of it is on the class path
keeps that file's annotations, so @scala.serializable, which the 2.8 compilers put
on the library's objects, is handed down from library to library.  Once
scala.serializable is a type alias of the scala package object (2010-11) those
references cannot be read any more ("refers to nonexisting symbol").  Renaming the
name in the previous library's pickles (serializable -> Serializable, the new
trait) lets the new compiler read them.  Only TYPEname entries equal to OLD are
changed; the encoded ScalaSignature keeps its length.
"""
import os
import struct
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import classfile  # noqa: E402


def decode(b):
    """ScalaSignature string bytes -> pickle (scala.reflect.generic.ByteCodecs)."""
    src, i = bytearray(), 0
    while i < len(b):
        if b[i] == 0xC0 and i + 1 < len(b) and b[i + 1] == 0x80:
            src.append(0x7F); i += 2
        else:
            src.append((b[i] - 1) & 0x7F); i += 1
    out, acc, bits = bytearray(), 0, 0
    for x in src:
        acc |= x << bits; bits += 7
        if bits >= 8:
            out.append(acc & 0xFF); acc >>= 8; bits -= 8
    return bytes(out), len(src)


def encode(d, n7):
    """pickle -> ScalaSignature string bytes, n7 7-bit groups."""
    src, acc, bits, i = bytearray(), 0, 0, 0
    while len(src) < n7:
        while bits < 7 and i < len(d):
            acc |= d[i] << bits; bits += 8; i += 1
        src.append(acc & 0x7F); acc >>= 7; bits = max(bits - 7, 0)
    out = bytearray()
    for x in src:
        if x == 0x7F:
            out += b"\xC0\x80"
        else:
            out.append(x + 1)
    return bytes(out)


def nat(b, p):
    x = 0
    while True:
        c = b[p]; p += 1; x = (x << 7) | (c & 0x7F)
        if c < 0x80:
            return x, p


def rename(d, old, new):
    p = 0
    _, p = nat(d, p); _, p = nat(d, p); n, p = nat(d, p)
    d = bytearray(d); hits = 0
    for _ in range(n):
        tag = d[p]; p += 1; ln, p = nat(d, p)
        if tag == 2 and bytes(d[p:p + ln]) == old:   # TYPEname
            d[p:p + ln] = new; hits += 1
        p += ln
    return bytes(d), hits


def sig_strings(cf, data):
    """Constant pool indices of the ScalaSignature `bytes` strings in a
    RuntimeVisibleAnnotations attribute."""
    found = []

    def value(p, sig):
        tag = data[p:p + 1]; p += 1
        if tag in b"BCDFIJSZsc":
            if sig and tag == b"s":
                found.append(struct.unpack(">H", data[p:p + 2])[0])
            return p + 2
        if tag == b"e":
            return p + 4
        if tag == b"@":
            return annotation(p)
        if tag == b"[":
            n = struct.unpack(">H", data[p:p + 2])[0]; p += 2
            for _ in range(n):
                p = value(p, False)
            return p
        raise ValueError(tag)

    def annotation(p):
        t, n = struct.unpack(">HH", data[p:p + 4]); p += 4
        sig = classfile.text(cf, t) == "Lscala/reflect/ScalaSignature;"
        for _ in range(n):
            p = value(p + 2, sig)
        return p

    n = struct.unpack(">H", data[:2])[0]; p = 2
    for _ in range(n):
        p = annotation(p)
    return found


def main(old, new, files):
    old, new = old.encode(), new.encode()
    assert len(old) == len(new)
    total = 0
    for f in files:
        cf = classfile.parse(open(f, "rb").read())
        for aname, data in cf["attrs"]:
            if classfile.text(cf, aname) != "RuntimeVisibleAnnotations":
                continue
            for v in sig_strings(cf, data):
                raw = cf["pool"][v][1]
                d, n7 = decode(raw)
                d2, hits = rename(d, old, new)
                if hits:
                    enc = encode(d2, n7)
                    assert len(enc) == len(raw) and decode(enc)[0][:len(d2)] == d2[:len(d)]
                    cf["pool"][v] = (cf["pool"][v][0], enc)
                    total += hits
                    tmp = f + ".new"; open(tmp, "wb").write(classfile.write(cf)); os.replace(tmp, f)
    print(f"scala-pickle-rename: {old.decode()} -> {new.decode()} in {total} entries", file=sys.stderr)


if __name__ == "__main__":
    main(sys.argv[1], sys.argv[2], sys.argv[3:])
