#!/usr/bin/env python3
"""Build a period-accurate view of the Java class library (like ct.sym).

usage: jdk-api-view.py SRC.ZIP RT.JAR MAXVERSION OUT.JAR

Old Scala compilers resolve `import java.io._` against whatever is on the
boot class path, so e.g. java.io.Console (1.6) shadows scala.Console.  This
copies RT.JAR to OUT.JAR without the java.*/javax.* types whose class-level
javadoc says @since > MAXVERSION (e.g. 1.4).  Hidden types still needed as
supertypes of kept classes stay; fields and methods of kept classes whose
descriptors mention hidden types are removed, as are InnerClasses entries
of hidden classes.  Nested classes follow their top-level class.  For
MAXVERSION < 5 the Java 5+ attributes (annotations, generic signatures,
...) are removed as well: a 1.4 class file had none, and a compiler from
that time that reads annotations would look for e.g. java.lang.Deprecated.
For MAXVERSION >= 5, annotations of hidden types (@FunctionalInterface, ...)
are dropped, members whose generic Signature mentions hidden types are
removed like those with such descriptors, and class Signatures are rewritten
to match the flattened supertypes (hidden ones become their nearest visible
supertypes, raw), keeping the type parameters.
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


JAVA5_ATTRS = {"RuntimeVisibleAnnotations", "RuntimeInvisibleAnnotations",
               "RuntimeVisibleParameterAnnotations", "RuntimeInvisibleParameterAnnotations",
               "RuntimeVisibleTypeAnnotations", "RuntimeInvisibleTypeAnnotations",
               "AnnotationDefault", "Signature", "EnclosingMethod", "MethodParameters"}


JAVA8_ATTRS = {"RuntimeVisibleTypeAnnotations", "RuntimeInvisibleTypeAnnotations",
               "MethodParameters"}
ANNOTS = {"RuntimeVisibleAnnotations", "RuntimeInvisibleAnnotations"}
PARAM_ANNOTS = {"RuntimeVisibleParameterAnnotations", "RuntimeInvisibleParameterAnnotations"}


def skip_value(d, p):
    tag = chr(d[p]); p += 1
    if tag in "BCDFIJSZsc":
        return p + 2
    if tag == "e":
        return p + 4
    if tag == "@":
        return skip_annotation(d, p)
    if tag == "[":
        n = struct.unpack_from(">H", d, p)[0]; p += 2
        for _ in range(n):
            p = skip_value(d, p)
        return p
    raise ValueError("bad element_value tag " + tag)


def skip_annotation(d, p):
    n = struct.unpack_from(">H", d, p + 2)[0]; p += 4
    for _ in range(n):
        p = skip_value(d, p + 2)
    return p


def filter_annotations(d, p, keep):
    """annotations table at d[p:]: (new bytes, end), dropping those keep() rejects"""
    n = struct.unpack_from(">H", d, p)[0]; p += 2
    out = []
    for _ in range(n):
        e = skip_annotation(d, p)
        if keep(struct.unpack_from(">H", d, p)[0]):
            out.append(d[p:e])
        p = e
    return struct.pack(">H", len(out)) + b"".join(out), p


def split_sig(sig):
    """class Signature -> (formal type parameters, [supertype signatures])"""
    def end(i):          # i at 'L' (or '<'): index after the matching ';' / '>'
        depth = 0
        while True:
            c = sig[i]
            if c == "<":
                depth += 1
            elif c == ">":
                depth -= 1
                if depth == 0 and sig[0] == "<" and formal is None:
                    return i + 1
            elif c == ";" and depth == 0:
                return i + 1
            i += 1
    formal = None
    i = 0
    if sig.startswith("<"):
        i = end(0)
    formal = sig[:i]
    out = []
    while i < len(sig):
        j = end(i)
        out.append(sig[i:j])
        i = j
    return formal, out


def split_args(t):
    """'Lp/C<A;B;>;' -> ('p/C', ['A;', 'B;']); raw 'Lp/C;' -> ('p/C', [])"""
    i = t.find("<")
    if i < 0:
        return t[1:-1], []
    name, body, args, depth, start = t[1:i], t[i + 1:-2], [], 0, 0
    for k, c in enumerate(body):
        if c == "<":
            depth += 1
        elif c == ">":
            depth -= 1
        elif depth == 0 and (c == ";" or (c in "*" and k == start)):
            args.append(body[start:k + 1]); start = k + 1
    return name, args


def formal_names(formal):
    """'<K:Ljava/lang/Object;V::Lx/Y;>' -> ['K', 'V']"""
    out, depth, i = [], 0, 1
    while i < len(formal) - 1:
        if depth == 0:
            j = formal.index(":", i)
            out.append(formal[i:j]); i = j
            while i < len(formal) - 1 and formal[i] == ":":        # class/interface bounds
                i += 1
                if formal[i] == ":":
                    continue
                k, d = i, 0
                while True:
                    c = formal[k]
                    if c == "<": d += 1
                    elif c == ">": d -= 1
                    elif c == ";" and d == 0: break
                    k += 1
                i = k + 1
        else:
            i += 1
    return out


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
    def invisible(n):
        """Hidden, or a non-public java/javax class (old compilers cannot
        see those either)."""
        if top(n) in hidden:
            return True
        if n in classes and n.startswith(("java/", "javax/")):
            acc = struct.unpack(">H", get(n)["head"][0:2])[0]
            return not acc & 0x0001
        return False

    def visible_super(n):
        """Nearest superclass of n that is not hidden."""
        cf = get(n)
        sup = struct.unpack(">H", cf["head"][4:6])[0]
        if not sup:
            return None
        s = cls_name(cf, sup)
        while invisible(s):
            s = visible_super(s)
        return s

    def visible_ifaces(n, seen=None):
        """Interfaces of n, hidden ones replaced by their visible supers."""
        out = []
        cf = get(n)
        for k in range(cf["nif"]):
            i = cls_name(cf, struct.unpack(">H", cf["ifaces"][2 * k:2 * k + 2])[0])
            if invisible(i):
                out += [j for j in visible_ifaces(i) if j not in out]
            elif i not in out:
                out.append(i)
        # interfaces of hidden superclasses
        sup = struct.unpack(">H", cf["head"][4:6])[0]
        if sup:
            s = cls_name(cf, sup)
            if invisible(s) and s in classes:
                out += [j for j in visible_ifaces(s) if j not in out]
        return out

    def class_entry(cf, name):
        u = pico.utf8(cf, name)
        for i, e in enumerate(cf["pool"]):
            if e and e[0] == 7 and struct.unpack(">H", e[1])[0] == u:
                return i
        cf["pool"].append((7, struct.pack(">H", u)))
        return len(cf["pool"]) - 1
    ref = re.compile(r"L([\w/$]+)[;<]")

    def mentions_hidden(desc):
        return any(top(m) in hidden for m in ref.findall(desc))

    name_of = lambda t: re.match(r"L([\w/$]+)", t).group(1)

    def expand(t):
        """supertype signature t of a hidden class -> (its visible superclass signature,
        [its visible interface signatures]), type arguments substituted"""
        n, args = split_args(t)
        if n not in classes:
            return "Ljava/lang/Object;", []
        hsig = attr(get(n), get(n)["attrs"], "Signature")
        if hsig is None or not args or any(a == "*" or a[0] in "+-" for a in args):
            vs = visible_super(n)
            return ("L%s;" % vs if vs else "Ljava/lang/Object;"), ["L%s;" % i for i in visible_ifaces(n)]
        formal, parts = split_sig(hsig)
        sub = dict(zip(formal_names(formal), args))
        subst = lambda x: re.sub(r"T(\w+);", lambda m: sub.get(m.group(1), m.group(0)), x)
        parts = [subst(x) for x in parts]
        sup, ifs = parts[0], []
        if invisible(name_of(sup)):
            sup, ifs = expand(sup)
        for x in parts[1:]:
            ifs += [x] if not invisible(name_of(x)) else expand(x)[1]
        return sup, ifs

    def attr(cf, attrs, nm):
        for a in attrs:
            if pico.text(cf, a[0]) == nm:
                return pico.text(cf, struct.unpack(">H", a[1][:2])[0])
        return None

    def filter_attrs(cf, attrs):
        """drop annotations of hidden types; Java 8 attributes for older views"""
        ok = lambda t: not mentions_hidden(pico.text(cf, t))
        out = []
        for a, d in attrs:
            nm = pico.text(cf, a)
            if maxv < 8 and nm in JAVA8_ATTRS:
                continue
            if nm in ANNOTS:
                d = filter_annotations(d, 0, ok)[0]
            elif nm in PARAM_ANNOTS:
                np, p, parts = d[0], 1, [d[:1]]
                for _ in range(np):
                    b, p = filter_annotations(d, p, ok)
                    parts.append(b)
                d = b"".join(parts)
            out.append((a, d))
        return out
    def strip_java5(cf):
        keep = lambda attrs: [a for a in attrs if pico.text(cf, a[0]) not in JAVA5_ATTRS]
        for key in ("fields", "methods"):
            for m in cf[key]:
                m[3] = keep(m[3])
        cf["attrs"] = keep(cf["attrs"])
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
            cf = get(name)
            if maxv < 5:
                strip_java5(cf)
            else:
                cf["attrs"] = filter_attrs(cf, cf["attrs"])
                for key in ("fields", "methods"):
                    for m in cf[key]:
                        m[3] = filter_attrs(cf, m[3])
            if not name.startswith(("java/", "javax/")):
                zo.writestr(info, pico.write(cf))
                continue
            sig = attr(cf, cf["attrs"], "Signature")
            if sig and any(invisible(x) for x in supers(name)):
                # supertypes get flattened below: rewrite the generic signature to match
                formal, parts = split_sig(sig)
                sup, ifs = parts[0], []
                if invisible(name_of(sup)):
                    sup, ifs = expand(sup)
                for t in parts[1:]:
                    ifs += [t] if not invisible(name_of(t)) else expand(t)[1]
                seen, uniq = set(), []
                for t in ifs:
                    if name_of(t) not in seen:
                        seen.add(name_of(t)); uniq.append(t)
                have = seen
                uniq += ["L%s;" % i for i in visible_ifaces(name) if i not in have]
                new = formal + sup + "".join(uniq)
                cf["attrs"] = [(a, struct.pack(">H", pico.utf8(cf, new)) if pico.text(cf, a) == "Signature" else d)
                               for a, d in cf["attrs"]]
                sig = new
            if sig and mentions_hidden(sig):
                cf["attrs"] = [a for a in cf["attrs"] if pico.text(cf, a[0]) != "Signature"]
            # hidden supertypes: use the nearest visible ones
            if any(invisible(x) for x in supers(name)):
                vs = visible_super(name)
                vi = visible_ifaces(name)
                head = cf["head"][:4] + struct.pack(">H", class_entry(cf, vs) if vs else 0)
                ifs = b"".join(struct.pack(">H", class_entry(cf, i)) for i in vi)
                cf["head"], cf["nif"], cf["ifaces"] = head, len(vi), ifs
            for key in ("fields", "methods"):
                keep = [m for m in cf[key] if not mentions_hidden(pico.text(cf, m[2]))
                        and not mentions_hidden(attr(cf, m[3], "Signature") or "")]
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
