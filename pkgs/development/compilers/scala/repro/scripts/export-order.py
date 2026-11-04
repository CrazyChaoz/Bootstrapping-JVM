#!/usr/bin/env python3
"""export-order.py TASTYPRINT: the names of the EXPORTED definitions, in tree order, of each
template in a TastyPrinter listing (one line per class: TYPEDEF-name: names...)."""
import re, sys
cur = []; out = {}; owner = None; stack = []
defs = []  # (indent, name, exported)
for l in open(sys.argv[1], errors="replace"):
    m = re.match(r"\s*\d+:(\s*)(\w+)(\(\d+\))?\s*(\d+)?\s*(\[(.*?)\])?", l)
    if not m: continue
    ind, tag, name = len(m.group(1)), m.group(2), m.group(6)
    while stack and stack[-1][0] >= ind: stack.pop()
    if tag == "TYPEDEF": stack.append((ind, "T", name))
    elif tag in ("DEFDEF", "VALDEF"):
        stack.append((ind, "D", name)); defs.append([name, False, [s[2] for s in stack if s[1] == "T"][-1:]])
    elif tag == "EXPORTED":
        d = [s for s in stack if s[1] == "D"]
        if d and defs and defs[-1][0] == d[-1][2]: defs[-1][1] = True
for name, exp, own in defs:
    if exp:
        out.setdefault(own[0] if own else "?", [])
        if name.split("[")[0] not in out[own[0] if own else "?"]: out[own[0] if own else "?"].append(name.split("[")[0])
for k, v in out.items(): print(f"{k}: {' '.join(v)}")
