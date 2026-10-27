#!/usr/bin/env python3
# Print the transitive C/C++ sources of an ICU Bazel target, one per line as
# "DEFINES<TAB>PATH" (DEFINES comma-separated), so that ICU's Unicode data
# generators (gennorm2, genprops, genuca) can be built without Bazel, the same
# way ICU's own data bootstrap (icu4c/source/data/unidata/generate.sh) does.
#
# The BUILD files are Starlark, close enough to Python to exec with stubs.
#
# Usage: bazel-srcs.py ICU_ROOT //package/path:target
import fnmatch
import os
import sys

root = sys.argv[1]
targets = {}  # label -> rule kwargs (+ "_pkg")


def load_package(pkg):
    if any(l.startswith("//" + pkg + ":") for l in targets):
        return
    d = os.path.join(root, pkg)

    def rule(**kw):
        kw["_pkg"] = pkg
        targets["//%s:%s" % (pkg, kw["name"])] = kw

    def glob(patterns, exclude=[]):
        files = sorted(os.listdir(d))
        return [
            f
            for f in files
            if any(fnmatch.fnmatch(f, p) for p in patterns)
            and not any(fnmatch.fnmatch(f, e) for e in exclude)
        ]

    env = {
        "load": lambda *a: None,
        "package": lambda **kw: None,
        "exports_files": lambda *a, **kw: None,
        "cc_library": rule,
        "cc_binary": rule,
        "glob": glob,
    }
    with open(os.path.join(d, "BUILD")) as f:
        exec(f.read(), env)


def resolve(label, pkg):
    if label.startswith(":"):
        label = "//%s%s" % (pkg, label)
    if ":" not in label[2:]:
        label = "%s:%s" % (label, label.rsplit("/", 1)[1])
    return label


seen = set()
out = {}  # path -> defines


def visit(label):
    if label in seen:
        return
    seen.add(label)
    load_package(label[2:].split(":")[0])
    t = targets[label]
    pkg = t["_pkg"]
    for s in t.get("srcs", []):
        if s.endswith((".c", ".cpp")):
            out.setdefault(os.path.join(pkg, s), ",".join(t.get("local_defines", [])))
    for dep in t.get("deps", []):
        visit(resolve(dep, pkg))


visit(resolve(sys.argv[2], ""))
for path in sorted(out):
    print("%s\t%s" % (out[path], path))
