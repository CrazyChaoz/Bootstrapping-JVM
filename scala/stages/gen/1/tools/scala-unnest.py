#!/usr/bin/env python3
"""Rewrite chained package clauses (Scala 2.8, 2009-07) for a compiler that only knows one:

    package scala.tools.nsc          package scala.tools.nsc.typechecker
    package typechecker        ==>   import scala.tools.nsc._

Each clause but the last makes the members of its package visible, hence the
imports.  usage: scala-unnest.py DIR  (rewrites the .scala files under DIR in place)
"""
import os
import re
import sys

CLAUSE = re.compile(r"^package\s+([\w.]+)\s*;?\s*$")


def unnest(text):
    lines = text.split("\n")
    pkgs, idx, i, in_comment = [], [], 0, False
    while i < len(lines):
        s = lines[i].strip()
        if in_comment:
            in_comment = "*/" not in s
        elif s.startswith("/*"):
            in_comment = "*/" not in s
        elif s == "" or s.startswith("//"):
            pass
        else:
            m = CLAUSE.match(s)
            if not m:
                break
            pkgs.append(m.group(1)); idx.append(i)
        i += 1
    if len(pkgs) < 2:
        return None
    full, imports = [], []
    for p in pkgs:
        full.append(p)
        imports.append("import %s._" % ".".join(full))
    lines[idx[0]] = "package %s; %s" % (".".join(full), "; ".join(imports[:-1]))
    for k in idx[1:]:
        lines[k] = ""
    return "\n".join(lines)


def main(root):
    n = 0
    for dp, _, fs in os.walk(root):
        for f in fs:
            if f.endswith(".scala"):
                p = os.path.join(dp, f)
                t = unnest(open(p, encoding="latin-1").read())
                if t is not None:
                    open(p, "w", encoding="latin-1").write(t)
                    n += 1
    print("unnested package clauses in %d files" % n, file=sys.stderr)


if __name__ == "__main__":
    main(sys.argv[1])
