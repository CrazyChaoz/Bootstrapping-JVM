#!/usr/bin/env python3
"""boilerplate TEMPLATE [N] > OUT: sbt-boilerplate's template expansion (sjson-new's
src/main/boilerplate/*.template), a port of spray.boilerplate.TemplateParser and Generator.

  [#...#]        the inner text for i = 1..n, joined by ", " (n = N, default 22, at the top
                 level, else the index of the enclosing block)
  [#...#SEP]     joined by SEP;  [A..B#...#] for i = A..B (either bound optional)
  0, 1, 2        inside a block: i-1, i, i+1;  ##0 ##1 ##2: the digit;  \\#: #
"""
import re
import sys

RANGE = re.compile(r"(\d{1,2})?\s*\.\.\s*(\d{1,2})?")
CLOSE = re.compile(r"#[^\]]*\]")


class Fail(Exception):
    pass


def expand_start(s, i):
    """-> (start, end, index after the '#') or None"""
    if i >= len(s) or s[i] != "[":
        return None
    j = i + 1
    start = end = None
    m = RANGE.match(s, j)
    if m:
        start = int(m.group(1)) if m.group(1) else None
        end = int(m.group(2)) if m.group(2) else None
        j = m.end()
    if j < len(s) and s[j] == "#":
        return start, end, j + 1
    return None


def parse_expand(s, i):
    st = expand_start(s, i)
    if st is None:
        raise Fail
    start, end, j = st
    inner, j = parse_elements(s, j)
    if j >= len(s) or s[j] != "#":
        raise Fail
    j += 1
    k = j
    while k < len(s) and s[k] != "]":
        k += 1
    if k >= len(s):
        raise Fail
    sep = s[j:k] if k > j else ", "
    return ("expand", inner, sep, start, end), k + 1


def parse_elements(s, i):
    els = []
    while i < len(s):
        c = s[i]
        if c in "012":
            els.append(("offset", int(c)))
            i += 1
            continue
        lit = []
        while i < len(s):
            if s.startswith("\\#", i):
                lit.append("#")
                i += 2
            elif s.startswith("##", i):
                if i + 2 >= len(s) or s[i + 2] not in "012":
                    sys.exit("boilerplate: '##' is used to quote '0', '1', or '2'")
                lit.append(s[i + 2])
                i += 3
            elif expand_start(s, i) is not None or CLOSE.match(s, i) or s[i] in "012":
                break
            else:
                lit.append(s[i])
                i += 1
        if lit:
            els.append(("lit", "".join(lit)))
            continue
        try:
            e, i = parse_expand(s, i)
        except Fail:
            break
        els.append(e)
    if not els:
        raise Fail
    return els, i


def parse_outside(s):
    els, i = [], 0
    while i < len(s):
        try:
            e, i = parse_expand(s, i)
            els.append(e)
            continue
        except Fail:
            pass
        lit = []
        while i < len(s):
            if s.startswith("\\#", i):
                lit.append("#")
                i += 2
            elif expand_start(s, i) is not None and lit:
                break
            else:
                lit.append(s[i])
                i += 1
                if expand_start(s, i) is not None:
                    break
        els.append(("lit", "".join(lit)))
    return els


def generate(els, idx):
    out = []
    for e in els:
        if e[0] == "lit":
            out.append(e[1])
        elif e[0] == "offset":
            out.append(str(idx + e[1] - 1))
        else:
            _, inner, sep, start, end = e
            lo = 1 if start is None else start
            hi = idx if end is None else end
            out.append(sep.join(generate(inner, k) for k in range(lo, hi + 1)))
    return "".join(out)


if __name__ == "__main__":
    n = int(sys.argv[2]) if len(sys.argv) > 2 else 22
    sys.stdout.write(generate(parse_outside(open(sys.argv[1], encoding="utf-8").read()), n))
