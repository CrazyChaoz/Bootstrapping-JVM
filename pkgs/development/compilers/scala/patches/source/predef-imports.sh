#!/usr/bin/env bash
# predef-imports.sh SRC : from 2009-09 Predef extends LowPriorityImplicits and starts with
# imports, so the compilers no longer see Predef.scala as the Predef unit and import Predef
# into it: an illegal cyclic reference.  The same imports inside the object do not count as
# leading ones.  (Until 2013-04: from then on the move makes the previous compiler fail.)
set -euo pipefail
[ -f "$1/library/scala/LowPriorityImplicits.scala" ] || exit 0
python3 - "$1/library/scala/Predef.scala" <<'PY'
import re, sys
p = sys.argv[1]; s = open(p, encoding="latin-1").read()
m = re.search(r"^object Predef extends LowPriorityImplicits \{", s, re.M)
if m:
    head, rest = s[:m.start()], s[m.end():]
    imps = re.findall(r"^import [^\n]*$", head, re.M)
    if imps:
        head = re.sub(r"^import [^\n]*$", "", head, flags=re.M)
        open(p, "w", encoding="latin-1").write(head + m.group(0) + " " + "; ".join(imps) + rest)
        print("Predef: leading imports moved into the object", file=sys.stderr)
PY
