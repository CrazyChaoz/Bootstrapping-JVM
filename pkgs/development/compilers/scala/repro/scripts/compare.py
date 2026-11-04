#!/usr/bin/env python3
"""compare.py JAR DIR [--list N] [--show-diff]: the entries of JAR against the files of DIR.

Prints counts of entries only in the jar, only in the directory, identical and different
(META-INF/MANIFEST.MF and directory entries are left out), then up to N names of each kind.
"""
import hashlib
import os
import sys
import zipfile


def main():
    jar, d = sys.argv[1], sys.argv[2]
    n = int(sys.argv[sys.argv.index("--list") + 1]) if "--list" in sys.argv else 10
    z = zipfile.ZipFile(jar)
    jent = {i.filename: i for i in z.infolist() if not i.filename.endswith("/")}
    files = {}
    for dp, _, fs in os.walk(d):
        for f in fs:
            p = os.path.join(dp, f)
            files[os.path.relpath(p, d)] = p
    skip = {"META-INF/MANIFEST.MF"}
    only_j = sorted(k for k in jent if k not in files and k not in skip)
    only_d = sorted(k for k in files if k not in jent and k not in skip)
    same, diff = [], []
    for k in sorted(jent):
        if k in files and k not in skip:
            a = z.read(k)
            b = open(files[k], "rb").read()
            (same if a == b else diff).append(k)
    print(f"{os.path.basename(jar)} vs {d}: jar-only {len(only_j)}, dir-only {len(only_d)}, "
          f"identical {len(same)}, different {len(diff)}")
    for label, xs in (("jar-only", only_j), ("dir-only", only_d), ("different", diff)):
        for x in xs[:n]:
            print(f"  {label}: {x}")


if __name__ == "__main__":
    main()
