#!/usr/bin/env python3
"""libcompare.py JAR DIR SRC: like compare.py, but leaves out the entries ScalaLibraryPlugin replaces
by their scala2-library versions (project/ScalaLibraryFilesToCopy.scala of SRC)."""
import re, sys, zipfile, os
jar, d, src = sys.argv[1:4]
copy = re.findall(r'"([^"]+)"', open(os.path.join(src, "project/ScalaLibraryFilesToCopy.scala")).read())
def replaced(n):
    p = n[:-6] if n.endswith(".class") else None
    return p is not None and any(p == s or p.startswith(s + "$") for s in copy)
z = zipfile.ZipFile(jar)
for i in z.infolist():
    n = i.filename
    if n.endswith("/") or n == "META-INF/MANIFEST.MF" or replaced(n): continue
    f = os.path.join(d, n)
    if not os.path.exists(f): print("jar-only", n)
    elif open(f, "rb").read() != z.read(n): print("different", n)
