#!/usr/bin/env python3
"""Build a period-accurate view of the Java class library (like ct.sym).

usage: jdk-api-view.py SRC.ZIP RT.JAR MAXVERSION OUT.JAR

Old Scala compilers resolve `import java.io._` against whatever is on the
boot class path, so e.g. java.io.Console (1.6) shadows scala.Console.  This
copies RT.JAR to OUT.JAR without the java.*/javax.* types whose class-level
javadoc says @since > MAXVERSION (e.g. 1.4).  Hidden types still needed as
supertypes of kept classes stay; fields and methods of kept classes whose
descriptors mention hidden types are removed, as are InnerClasses entries
of hidden classes.  Nested classes follow their top-level class.
"""
import importlib.util
import os
import re
import struct
import sys
import zipfile

here = os.path.dirname(os.path.abspath(__file__))
spec = importlib.util.spec_from_file_location("pico", os.path.join(here, "pico-classfiles.py"))
pico = importlib.util.module_from_spec(spec)
spec.loader.exec_module(pico)

SINCE = re.compile(r"@since\s+(?:JDK\s*)?([0-9]+(?:\.[0-9]+)?)")


def version(v):
    parts = [int(x) for x in v.split(".")]
    if parts[0] == 1 and len(parts) > 1:
        return parts[1]      # 1.4 -> 4
    return parts[0]          # 5, 6, 8 ...


def class_since(src):
    """@since of the javadoc right before the top-level type declaration."""
    m = re.search(r"/\*\*((?:(?!\*/).)*)\*/\s*(?:@[\w.]+(?:\([^)]*\))?\s*)*"
                  r"(?:public\s+|abstract\s+|final\s+|strictfp\s+)*"
                  r"(?:class|interface|enum|@interface)\s", src, re.S)
    if not m:
        return None
    s = SINCE.search(m.group(1))
    return version(s.group(1)) if s else None


def top(name):
    return name.split("$")[0]


def cls_name(cf, idx):
    return pico.text(cf, struct.unpack(">H", cf["pool"][idx][1])[0])


def main(srczip, rtjar, maxv, outjar):
    maxv = version(maxv)
    hidden = set()
    with zipfile.ZipFile(srczip) as z:
        for n in z.namelist():
            if n.endswith(".java") and n.startswith(("java/", "javax/")):
                since = class_since(z.read(n).decode("latin-1"))
                if since is not None and since > maxv:
                    hidden.add(n[:-5])
    zi = zipfile.ZipFile(rtjar)
    classes = {}
    for info in zi.infolist():
        if info.filename.endswith(".class"):
            classes[info.filename[:-6]] = info
    parsed = {}

    def get(n):
        if n not in parsed:
            parsed[n] = pico.parse(zi.read(classes[n]))
        return parsed[n]

    def supers(n):
        cf = get(n)
        sup = struct.unpack(">H", cf["head"][4:6])[0]
        out = [cls_name(cf, sup)] if sup else []
        for k in range(cf["nif"]):
            out.append(cls_name(cf, struct.unpack(">H", cf["ifaces"][2 * k:2 * k + 2])[0]))
        return out
    # hidden types needed as supertypes of kept classes stay visible
    changed = True
    while changed:
        changed = False
        for n in classes:
            if top(n) in hidden:
                continue
            for s in supers(n):
                if top(s) in hidden:
                    hidden.discard(top(s))
                    changed = True
    ref = re.compile(r"L([\w/$]+);")

    def mentions_hidden(desc):
        return any(top(m) in hidden for m in ref.findall(desc))
    dropped = stripped = 0
    with zipfile.ZipFile(outjar, "w", zipfile.ZIP_DEFLATED) as zo:
        for info in zi.infolist():
            n = info.filename
            if not n.endswith(".class"):
                zo.writestr(info, zi.read(n))
                continue
            name = n[:-6]
            if top(name) in hidden:
                dropped += 1
                continue
            if not name.startswith(("java/", "javax/")):
                zo.writestr(info, zi.read(n))
                continue
            cf = get(name)
            for key in ("fields", "methods"):
                keep = [m for m in cf[key] if not mentions_hidden(pico.text(cf, m[2]))]
                stripped += len(cf[key]) - len(keep)
                cf[key] = keep
            attrs = []
            for aname, data in cf["attrs"]:
                if pico.text(cf, aname) == "InnerClasses":
                    cnt = struct.unpack(">H", data[:2])[0]
                    ents = [data[2 + 8 * k:10 + 8 * k] for k in range(cnt)]
                    ents = [e for e in ents
                            if top(cls_name(cf, struct.unpack(">H", e[:2])[0])) not in hidden]
                    data = struct.pack(">H", len(ents)) + b"".join(ents)
                attrs.append((aname, data))
            cf["attrs"] = attrs
            zo.writestr(info, pico.write(cf))
    print(f"{outjar}: hid {dropped} classes, stripped {stripped} members "
          f"(API as of Java {sys.argv[3]})")


if __name__ == "__main__":
    main(*sys.argv[1:5])
