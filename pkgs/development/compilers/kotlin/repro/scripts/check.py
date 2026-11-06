"""check.py UPSTREAM-DIR OURS-DIR: compares each jar of OURS-DIR with the one of the same name in
UPSTREAM-DIR; prints one line per jar (and the differing entries); exit status 1 unless all are
identical."""
import os
import sys
import zipfile

up, ours = sys.argv[1:]
bad = 0
for name in sorted(os.listdir(ours)):
    a, b = os.path.join(up, name), os.path.join(ours, name)
    if open(a, "rb").read() == open(b, "rb").read():
        print("%-36s identical" % name)
        continue
    bad += 1
    za, zb = zipfile.ZipFile(a), zipfile.ZipFile(b)
    na, nb = za.namelist(), zb.namelist()
    diff = [n for n in na if n in nb and za.read(n) != zb.read(n)]
    print("%-36s DIFFERENT: entries %d/%d, %d differ, order %s" % (name, len(nb), len(na), len(diff),
          "same" if na == nb else "different"))
    for n in sorted(set(na) ^ set(nb)):
        print("    only %s: %s" % ("upstream" if n in na else "ours", n))
    for n in diff[:20]:
        print("    differs: %s" % n)
sys.exit(1 if bad else 0)
