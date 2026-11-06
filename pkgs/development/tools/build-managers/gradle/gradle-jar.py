#!/usr/bin/env python3
"""gradle-jar.py OUT [options]: writes a jar the way Gradle's reproducible Jar task does
(commons-compress, as in Gradle's own build: reproducibleFileOrder, no file timestamps).

  --attr 'Key: Value'   a main attribute of the manifest, after Manifest-Version (in order)
  --no-manifest         no META-INF/MANIFEST.MF
  --root DIR            a directory to add (in order; a directory entry is written once)
  --append NAME=FILE    a file to add after the roots, as NAME
  --from JAR            the entries of JAR after the roots, in its order (its manifest dropped)

The format: entries deflated (level 6, directories as empty deflate streams), Unix
attributes (0644 files, 0755 directories), all dated 1980-02-01 00:00, no data descriptors,
UTF-8 names.  A directory is walked files first, then subdirectories, each sorted by name.
"""
import os
import struct
import sys
import zipfile
import zlib

DOS_TIME, DOS_DATE = 0, (0 << 9) | (2 << 5) | 1  # 1980-02-01 00:00:00
FILE_ATTR, DIR_ATTR = 0o100644 << 16, (0o40755 << 16) | 0x10


def manifest(attrs):
    out = []
    for line in ["Manifest-Version: 1.0"] + attrs:
        b = line.encode("utf-8")
        out.append(b[:72])
        b = b[72:]
        while b:
            out.append(b" " + b[:71])
            b = b[71:]
    return b"".join(l + b"\r\n" for l in out) + b"\r\n"


class Jar:
    def __init__(self, path):
        self.f = open(path, "wb")
        self.central = []
        self.names = set()

    def add(self, name, data):
        """data None: a directory"""
        if name in self.names:
            if data is None:
                return
            sys.exit(f"gradle-jar: duplicate entry {name}")
        parent = name.rstrip("/").rpartition("/")[0]
        if parent and parent + "/" not in self.names:
            self.add(parent + "/", None)
        self.names.add(name)
        raw = b"" if data is None else data
        c = zlib.compressobj(6, zlib.DEFLATED, -15)
        comp = c.compress(raw) + c.flush()
        crc = zlib.crc32(raw)
        n = name.encode("utf-8")
        off = self.f.tell()
        self.f.write(struct.pack("<IHHHHHIIIHH", 0x04034B50, 20, 0x800, 8, DOS_TIME, DOS_DATE,
                                 crc, len(comp), len(raw), len(n), 0) + n + comp)
        attr = DIR_ATTR if data is None else FILE_ATTR
        self.central.append(struct.pack("<IHHHHHHIIIHHHHHII", 0x02014B50, (3 << 8) | 20, 20, 0x800, 8,
                                        DOS_TIME, DOS_DATE, crc, len(comp), len(raw), len(n), 0, 0, 0, 0,
                                        attr, off) + n)

    def walk(self, root, rel=""):
        d = os.path.join(root, rel)
        entries = sorted(os.listdir(d))
        files = [e for e in entries if not os.path.isdir(os.path.join(d, e))]
        dirs = [e for e in entries if os.path.isdir(os.path.join(d, e))]
        for e in files:
            with open(os.path.join(d, e), "rb") as fh:
                self.add(rel + e, fh.read())
        for e in dirs:
            self.add(rel + e + "/", None)
            self.walk(root, rel + e + "/")

    def close(self):
        start = self.f.tell()
        for c in self.central:
            self.f.write(c)
        size = self.f.tell() - start
        n = len(self.central)
        self.f.write(struct.pack("<IHHHHIIH", 0x06054B50, 0, 0, n, n, size, start, 0))
        self.f.close()


def main(argv):
    out, args = argv[0], argv[1:]
    attrs, steps, with_manifest = [], [], True
    i = 0
    while i < len(args):
        a = args[i]
        if a == "--no-manifest":
            with_manifest = False
            i += 1
            continue
        v = args[i + 1]
        i += 2
        if a == "--attr":
            attrs.append(v)
        elif a in ("--root", "--append", "--from"):
            steps.append((a, v))
        else:
            sys.exit(f"gradle-jar: unknown option {a}")
    jar = Jar(out)
    if with_manifest:
        jar.add("META-INF/", None)
        jar.add("META-INF/MANIFEST.MF", manifest(attrs))
    for kind, v in steps:
        if kind == "--root":
            jar.walk(v)
        elif kind == "--append":
            name, _, path = v.partition("=")
            with open(path, "rb") as fh:
                jar.add(name, fh.read())
        else:
            z = zipfile.ZipFile(v)
            for info in z.infolist():
                if info.filename == "META-INF/MANIFEST.MF" or (info.filename == "META-INF/" and with_manifest):
                    continue
                jar.add(info.filename, None if info.is_dir() else z.read(info))
    jar.close()


if __name__ == "__main__":
    main(sys.argv[1:])
