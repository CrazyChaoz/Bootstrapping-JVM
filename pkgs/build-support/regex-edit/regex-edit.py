"""regex-edit [OPTIONS] PATTERN REPLACEMENT FILE... : edit FILEs in place, replacing the
matches of the regular expression PATTERN (Python's re) by REPLACEMENT.

By default the first match of each file is replaced, in the whole file (flags go into the
pattern: (?s) for "." matching newlines, (?m) for ^/$ at each line, (?x) verbose).
REPLACEMENT is Python's re.sub template: \\1 or \\g<1> for groups, \\g<0> for the match,
\\n for a newline.

  --all            replace every match, not just the first
  --lines          match each line on its own (with its newline), as `sed` and `perl -p` do
  --optional       do not fail when nothing matches, and skip FILEs that do not exist
  --subst-var VAR  replace @VAR@ in REPLACEMENT by the value of the environment variable
                   VAR, verbatim (for text that is not a template, like code)
  --subst-file VAR FILE  replace @VAR@ in REPLACEMENT by the contents of FILE, verbatim

Fails when no file has a match (unless --optional): an edit that no longer applies to the
sources it is meant for should not go unnoticed.  Files are read and written as bytes
(Latin-1), and \\s, \\w, \\d match ASCII only.
"""

import os
import re
import sys


def main(argv):
    every = lines = optional = False
    substs = {}  # VAR -> its text
    while argv and argv[0].startswith("--"):
        opt = argv.pop(0)
        if opt == "--all":
            every = True
        elif opt == "--lines":
            lines = True
        elif opt == "--optional":
            optional = True
        elif opt == "--subst-var":
            var = argv.pop(0)
            substs[var] = os.fsencode(os.environ[var]).decode("latin-1")
        elif opt == "--subst-file":
            var, path = argv.pop(0), argv.pop(0)
            with open(path, encoding="latin-1", newline="") as h:
                substs[var] = h.read()
        elif opt == "--":
            break
        else:
            sys.exit(f"regex-edit: unknown option {opt}")
    if len(argv) < 2:
        sys.exit(__doc__)
    # the arguments as the bytes they were given (Latin-1: one character per byte)
    pattern, template, *files = (os.fsencode(a).decode("latin-1") for a in argv)
    regex = re.compile(pattern, re.ASCII)
    # a function rather than the template string, so that substituted values stay verbatim
    for var in substs:
        template = template.replace(f"@{var}@", "\0" + var + "\0")
    parts = template.split("\0")

    def replace(m):
        out = []
        for i, part in enumerate(parts):
            if i % 2:
                out.append(substs[part])
            else:
                out.append(m.expand(part))
        return "".join(out)

    count = 0 if every else 1
    found = 0
    for f in files:
        if optional and not os.path.exists(f):
            continue
        with open(f, encoding="latin-1", newline="") as h:
            text = h.read()
        old = text
        if lines:
            new = []
            for line in re.findall(r"[^\n]*\n|[^\n]+\Z", text):
                line, n = regex.subn(replace, line, count=count)
                new.append(line)
                found += n
            text = "".join(new)
        else:
            text, n = regex.subn(replace, text, count=count)
            found += n
        if text != old:
            with open(f, "w", encoding="latin-1", newline="") as h:
                h.write(text)
    if not found and not optional:
        sys.exit(f"regex-edit: no match for {pattern!r} in {' '.join(files)}")


if __name__ == "__main__":
    main(sys.argv[1:])
