#!/usr/bin/env python3
"""Translate the Pizza subset used by the early Scala compiler into Java.

usage: pizza2java.py SRCROOT OUTROOT [--classpath-src DIR ...] FILE...

FILE paths are relative to SRCROOT; the translated files are written to the
same relative paths below OUTROOT.  Every --classpath-src DIR is scanned for
algebraic types too (for switches over types declared elsewhere) but its
files are not written.

Supported Pizza features:

  * algebraic cases declared as class members
        [mods] case Name;                     constant case
        [mods] case Name(T1 f1, ...) [body]   class case, body = constructor
    become a static nested subclass (fields + constructor) plus a static
    factory method of the same name, resp. a singleton field.
  * pattern switches
        switch (e) { case Name(T x, _, Sub(..), CONST, lit): ... }
    become an if-chain computing a case index followed by an ordinary
    switch on that index; bindings are declared at the start of each case
    group (which is wrapped in a block).
"""
import os
import re
import sys

# --------------------------------------------------------------------------
# lexer

TOKEN_RE = re.compile(r"""
    (?P<ws>\s+)
  | (?P<lc>//[^\n]*)
  | (?P<bc>/\*.*?\*/)
  | (?P<str>"(?:[^"\\\n]|\\.)*")
  | (?P<chr>'(?:[^'\\\n]|\\.)+')
  | (?P<num>(?:0[xX][0-9a-fA-F]+|\d+\.?\d*(?:[eE][+-]?\d+)?|\.\d+(?:[eE][+-]?\d+)?)[lLfFdD]?)
  | (?P<id>[A-Za-z_$][\w$]*)
  | (?P<op>>>>=|<<=|>>=|>>>|\+\+|--|&&|\|\||==|!=|<=|>=|\+=|-=|\*=|/=|%=|&=|\|=|\^=|<<|>>|->|::|[{}()\[\];,.<>=!~?:+\-*/&|^%@])
""", re.S | re.X)


class Tok:
    __slots__ = ("kind", "text", "start", "end")

    def __init__(self, kind, text, start, end):
        self.kind, self.text, self.start, self.end = kind, text, start, end

    def __repr__(self):
        return f"{self.text!r}@{self.start}"


def lex(src, docs=None):
    toks = []
    pos = 0
    while pos < len(src):
        m = TOKEN_RE.match(src, pos)
        if not m:
            raise SyntaxError(f"bad char {src[pos]!r} at {pos}")
        k = m.lastgroup
        if k not in ("ws", "lc", "bc"):
            toks.append(Tok(k, m.group(), m.start(), m.end()))
        elif k == "bc" and docs is not None and m.group().startswith("/**"):
            docs.append((len(toks), m.group()))
        pos = m.end()
    return toks


class PizzaError(Exception):
    pass


# --------------------------------------------------------------------------
# structure


class FileInfo:
    def __init__(self, rel, src):
        self.rel = rel
        self.src = src
        self.docs = []             # (index of next token, comment)
        self.toks = lex(src, self.docs)
        self.package = ""
        self.imports = []          # (name, ondemand)
        self.kinds = {}            # index of '{' -> kind
        self.match = {}            # index of open bracket -> index of close
        self.parent = {}           # index of '{' -> enclosing '{' index
        self.classname = {}        # index of class-body '{' -> simple name
        self.superclass = {}       # index of class-body '{' -> extends name
        self.cases = []            # (classbrace, caseindex)
        self.labels = []           # (switchbrace, caseindex)
        self.analyse()

    def line(self, i):
        return self.src.count("\n", 0, self.toks[i].start) + 1

    def where(self, i):
        return f"{self.rel}:{self.line(i)}"

    def analyse(self):
        t = self.toks
        stack = []
        for i, tok in enumerate(t):
            if tok.text in "([{" and tok.kind == "op":
                stack.append(i)
            elif tok.text in ")]}" and tok.kind == "op":
                j = stack.pop()
                self.match[j] = i
        # package / imports
        i = 0
        while i < len(t):
            if t[i].text == "package":
                j = i + 1
                while t[j].text != ";":
                    j += 1
                self.package = "".join(x.text for x in t[i + 1:j])
                i = j
            elif t[i].text == "import":
                j = i + 1
                while t[j].text != ";":
                    j += 1
                name = "".join(x.text for x in t[i + 1:j])
                if name.endswith(".*"):
                    self.imports.append((name[:-2], True))
                else:
                    self.imports.append((name, False))
                i = j
            elif t[i].text in ("class", "interface", "public", "final",
                               "abstract"):
                break
            i += 1
        # braces
        braces = []
        boundary = -1
        for i, tok in enumerate(t):
            if tok.kind != "op":
                continue
            if tok.text == "{":
                kind = "block"
                name = None
                enclosing = braces[-1] if braces else None
                stmt = t[boundary + 1:i]
                for k, x in enumerate(stmt):
                    if x.text in ("class", "interface") and \
                            (k == 0 or stmt[k - 1].text != "."):
                        kind = "class"
                        name = stmt[k + 1].text
                        for m, y in enumerate(stmt):
                            if y.text == "extends":
                                e = m + 1
                                while e + 1 < len(stmt) and stmt[e + 1].text == ".":
                                    e += 2
                                self.superclass[i] = "".join(
                                    z.text for z in stmt[m + 1:e + 1])
                                break
                        break
                if kind == "block" and i > 0 and t[i - 1].text == ")":
                    j = self.open_of(i - 1)
                    if j > 0 and t[j - 1].text == "switch":
                        kind = "switch"
                if kind == "block" and i > 0 and t[i - 1].text == ")":
                    # anonymous class?  new Q.N(...) {
                    j = self.open_of(i - 1)
                    k = j - 1
                    while k > 0 and t[k].kind == "id" and t[k - 1].text == ".":
                        k -= 2
                    if k > 0 and t[k].kind == "id" and t[k - 1].text == "new":
                        kind = "class"
                        name = None
                if kind == "block" and enclosing is not None and \
                        self.kinds[enclosing] == "class" and stmt and \
                        any(x.text == "case" for x in stmt):
                    kind = "casebody"
                if kind == "block" and enclosing is not None and \
                        self.kinds[enclosing] == "class" and stmt and \
                        stmt[-1].text == "=":
                    kind = "init"
                self.kinds[i] = kind
                self.parent[i] = enclosing
                if name:
                    self.classname[i] = name
                braces.append(i)
                boundary = i
            elif tok.text == "}":
                braces.pop()
                boundary = i
            elif tok.text == ";":
                boundary = i
            elif tok.text == ":" and braces and self.kinds[braces[-1]] == "switch":
                # a label ends a "statement"
                stmt = t[boundary + 1:i]
                if stmt and stmt[0].text in ("case", "default"):
                    boundary = i
        # case tokens
        braces = []
        for i, tok in enumerate(t):
            if tok.kind == "op" and tok.text == "{":
                braces.append(i)
            elif tok.kind == "op" and tok.text == "}":
                braces.pop()
            elif tok.kind == "id" and tok.text == "case" and braces:
                b = braces[-1]
                if self.kinds[b] == "class":
                    self.cases.append((b, i))
                elif self.kinds[b] == "switch":
                    self.labels.append((b, i))

    def open_of(self, close):
        if not hasattr(self, "_rmatch"):
            self._rmatch = {c: o for o, c in self.match.items()}
        return self._rmatch[close]

    def class_chain(self, brace):
        """Qualified (dotted) name of the class whose body starts at brace."""
        names = []
        b = brace
        while b is not None:
            if self.kinds[b] == "class":
                if b not in self.classname:
                    return None  # anonymous
                names.append(self.classname[b])
            b = self.parent[b]
        return ".".join(reversed(names))

    def enclosing_classes(self, i):
        """Qualified names of all named classes enclosing token i."""
        out = []
        for b in self.classname:
            if b < i < self.match[b]:
                q = self.class_chain(b)
                if q:
                    out.append(q)
        return out


class Case:
    def __init__(self, adt, name, params, const, mods):
        self.adt, self.name, self.params, self.const = adt, name, params, const
        self.mods = mods

    @property
    def cls(self):
        return self.adt.fqn + "." + (("$" + self.name) if self.const else self.name)

    @property
    def ref(self):
        return self.adt.fqn + "." + self.name


class Adt:
    def __init__(self, fqn, finfo):
        self.fqn = fqn
        self.simple = fqn.rsplit(".", 1)[-1]
        self.file = finfo
        self.cases = {}
        self.superclass = None     # (name, brace) as written
        self.parent = None         # resolved Adt or None

    def all_cases(self):
        a, seen = self, {}
        while a is not None:
            for k, v in a.cases.items():
                seen.setdefault(k, v)
            a = a.parent
        return seen

    def root(self):
        a = self
        while a.parent is not None:
            a = a.parent
        return a


class World:
    def __init__(self):
        self.adts = {}       # fqn -> Adt
        self.files = []
        self.packages = set()
        self.roots = set()
        self.classes = set()

    def add_file(self, finfo):
        self.files.append(finfo)
        self.index(finfo)
        t = finfo.toks
        for brace, ci in finfo.cases:
            q = finfo.class_chain(brace)
            if q is None:
                raise PizzaError(f"{finfo.where(ci)}: case in anonymous class")
            fqn = (finfo.package + "." + q) if finfo.package else q
            adt = self.adts.get(fqn) or Adt(fqn, finfo)
            self.adts[fqn] = adt
            if brace in finfo.superclass:
                adt.superclass = (finfo.superclass[brace], brace)
            # modifiers before 'case'
            mods = []
            k = ci - 1
            while k >= 0 and t[k].text in ("public", "private", "protected",
                                           "static", "final", "abstract"):
                mods.insert(0, t[k].text)
                k -= 1
            name = t[ci + 1].text
            params = None
            if t[ci + 2].text == "(":
                close = finfo.match[ci + 2]
                params = parse_params(t[ci + 3:close], finfo, ci)
            adt.cases[name] = Case(adt, name, params or [], params is None,
                                   mods)

    def index(self, finfo):
        self.packages.add(finfo.package)
        self.roots.add(finfo.package.split(".")[0])
        for b, name in finfo.classname.items():
            q = finfo.class_chain(b)
            if q:
                self.classes.add((finfo.package + "." + q) if finfo.package else q)

    def resolve_class(self, name, finfo):
        """Fully qualified name of a class referenced as name in finfo."""
        if name in self.classes:
            return name
        if finfo is None:
            return None
        cands = []
        if finfo.package:
            cands.append(finfo.package + "." + name)
        for imp, ondemand in finfo.imports:
            if ondemand:
                cands.append(imp + "." + name)
            elif imp.rsplit(".", 1)[-1] == name.split(".")[0]:
                cands.append(imp.rsplit(".", 1)[0] + "." + name)
        for c in cands:
            if c in self.classes:
                return c
        return None

    def link(self):
        for a in self.adts.values():
            if a.superclass:
                a.parent = self.resolve_type(a.superclass[0], a.file,
                                             a.superclass[1] + 1)

    # -- name resolution -----------------------------------------------
    def resolve_type(self, name, finfo, at):
        """Resolve a (possibly qualified) class name to an Adt, or None."""
        name = re.sub(r"\s|\[\]", "", name)
        if name in self.adts:
            return self.adts[name]
        cands = []
        first, _, rest = name.partition(".")
        # nested in an enclosing class
        for q in reversed(finfo.enclosing_classes(at)):
            pre = (finfo.package + "." + q) if finfo.package else q
            while pre:
                cands.append(pre + "." + name)
                pre = pre.rpartition(".")[0]
        if finfo.package:
            cands.append(finfo.package + "." + name)
        for imp, ondemand in finfo.imports:
            if ondemand:
                cands.append(imp + "." + name)
            elif imp.rsplit(".", 1)[-1] == first:
                cands.append(imp + ("." + rest if rest else ""))
        cands.append(name)
        for c in cands:
            if c in self.adts:
                return self.adts[c]
        return None

    def adts_with_case(self, name):
        return [a for a in self.adts.values() if name in a.all_cases()]


def parse_params(toks, finfo, at):
    """Split 'T1 f1, T2[] f2' into [(type, name)]."""
    params = []
    cur = []
    depth = 0
    for x in toks + [None]:
        if x is None or (x.text == "," and depth == 0):
            if cur:
                if cur[0].text == "final":
                    cur = cur[1:]
                params.append((type_text(cur[:-1]), cur[-1].text))
            cur = []
            continue
        if x.text in "([<":
            depth += 1
        elif x.text in ")]>":
            depth -= 1
        cur.append(x)
    return params


def type_text(toks):
    out = ""
    for k, x in enumerate(toks):
        if k and x.kind == "id" and toks[k - 1].kind == "id":
            out += " "
        out += x.text
    return out


# --------------------------------------------------------------------------
# patterns


class Pat:
    pass


class PWild(Pat):
    pass


class PBind(Pat):
    def __init__(self, typ, name):
        self.typ, self.name = typ, name


class PConst(Pat):
    """A qualified name or literal."""

    def __init__(self, text, isname):
        self.text, self.isname = text, isname


class PCase(Pat):
    def __init__(self, name, args):
        self.name, self.args = name, args   # args None for constant-like


def parse_pattern(toks, finfo):
    pos = 0

    def peek(k=0):
        return toks[pos + k] if pos + k < len(toks) else None

    def pat():
        nonlocal pos
        x = peek()
        if x is None:
            raise PizzaError("empty pattern")
        if x.text == "_":
            pos += 1
            return PWild()
        if x.kind in ("num", "str", "chr") or x.text in ("true", "false", "null") \
                or x.text == "-":
            text = x.text
            pos += 1
            if x.text == "-":
                text += peek().text
                pos += 1
            return PConst(text, False)
        if x.kind != "id":
            raise PizzaError(f"unexpected {x.text!r} in pattern")
        # qualified name
        parts = [x.text]
        pos += 1
        while peek() is not None and peek().text == "." and peek(1) is not None \
                and peek(1).kind == "id":
            parts.append(peek(1).text)
            pos += 2
        if peek() is not None and peek().text == "(":
            pos += 1
            args = []
            if peek().text != ")":
                while True:
                    args.append(pat())
                    if peek().text == ",":
                        pos += 1
                        continue
                    break
            if peek().text != ")":
                raise PizzaError(f"expected ) in pattern, got {peek().text!r}")
            pos += 1
            return PCase(".".join(parts), args)
        # binding: Type [ [] ...] name
        typ = ".".join(parts)
        while peek() is not None and peek().text == "[":
            typ += "[]"
            pos += 2
        if peek() is not None and peek().kind == "id":
            name = peek().text
            pos += 1
            while peek() is not None and peek().text == "[":
                typ += "[]"
                pos += 2
            return PBind(typ, name)
        return PConst(typ, True)

    p = pat()
    if pos != len(toks):
        raise PizzaError(f"trailing tokens in pattern: {toks[pos:]}")
    return p


# --------------------------------------------------------------------------
# translation


class Edits:
    def __init__(self):
        self.list = []   # (start, end, text, order)

    def replace(self, start, end, text, order=0):
        self.list.append((start, end, text, order))

    def insert(self, pos, text, order=0):
        self.list.append((pos, pos, text, order))

    def apply(self, src):
        out = []
        last = 0
        for start, end, text, _ in sorted(self.list, key=lambda e: (e[0], e[3], e[1])):
            if start < last:
                raise PizzaError(f"overlapping edits at {start}")
            out.append(src[last:start])
            out.append(text)
            last = end
        out.append(src[last:])
        return "".join(out)


class Translator:
    def __init__(self, world, finfo):
        self.w = world
        self.f = finfo
        self.e = Edits()
        self.counter = 0

    def run(self):
        self.import_statics()
        t = self.f.toks
        mods = ("public", "private", "protected", "static", "final", "abstract")
        for k in range(1, len(t)):
            if t[k].text in mods and t[k].text == t[k - 1].text:
                self.e.replace(t[k].start, t[k].end, "")
            if t[k].text == "private" and self.in_nested_class_body(k):
                self.e.replace(t[k].start, t[k].end, "/*private*/")
            if t[k].text == "enum" and t[k].kind == "id":
                self.e.replace(t[k].start, t[k].end, "enum$")
        for brace, ci in self.f.cases:
            self.case_decl(brace, ci)
        by_switch = {}
        for b, ci in self.f.labels:
            by_switch.setdefault(b, []).append(ci)
        for b, cis in by_switch.items():
            self.switch(b, cis)
        return self.e.apply(self.f.src)

    def in_nested_class_body(self, k):
        """Is token k a member modifier inside a class nested in a class?"""
        b = self.enclosing_brace(k)
        if b is None or self.f.kinds[b] != "class":
            return False
        p = self.f.parent[b]
        while p is not None:
            if self.f.kinds[p] == "class":
                return True
            p = self.f.parent[p]
        return False

    def enclosing_brace(self, k):
        if not hasattr(self, "_encl"):
            self._encl = []
            stack = []
            for i, x in enumerate(self.f.toks):
                self._encl.append(stack[-1] if stack else None)
                if x.kind == "op" and x.text == "{":
                    stack.append(i)
                elif x.kind == "op" and x.text == "}":
                    stack.pop()
        return self._encl[k]

    # -- imports: 'import a.b.Adt.*' also needs the static factories ------
    def import_statics(self):
        t = self.f.toks
        for i, x in enumerate(t):
            if x.text != "import":
                continue
            j = i + 1
            while t[j].text != ";":
                j += 1
            name = "".join(y.text for y in t[i + 1:j])
            first = name.split(".")[0]
            if first[:1].isupper():
                # 'import Tree.*' relative to the other imports (Java 1.1)
                q = self.w.resolve_class(first, self.f)
                if q is None:
                    raise PizzaError(f"{self.f.where(i)}: cannot resolve import {name}")
                name = q + name[len(first):]
                self.e.replace(t[i + 1].start, t[j].start, name)
            pkg = name[:-2] if name.endswith(".*") else None
            if pkg and pkg.split(".")[0] in self.w.roots and \
                    pkg not in self.w.packages and \
                    self.w.resolve_class(pkg, None) is None:
                self.e.replace(t[i].start, t[j].end, f"/* import {name}; */")
                continue
            if name.endswith(".*") and name[:-2] in self.w.adts:
                self.e.insert(t[j].end, f" import static {name};")
            elif not name.endswith(".*") and name.rpartition(".")[0] in self.w.adts:
                self.e.insert(t[j].end, f" import static {name};")

    # -- case declarations -------------------------------------------------
    def case_decl(self, brace, ci):
        t = self.f.toks
        q = self.f.class_chain(brace)
        fqn = (self.f.package + "." + q) if self.f.package else q
        adt = self.w.adts[fqn]
        name = t[ci + 1].text
        case = adt.cases[name]
        base = adt.simple
        # remove modifiers + 'case' header
        k = ci
        while k - 1 >= 0 and t[k - 1].text in ("public", "private", "protected",
                                               "static", "final", "abstract"):
            k -= 1
        start = t[k].start
        vis = " ".join(m for m in case.mods if m in ("public", "private", "protected"))
        vis = (vis + " ") if vis else ""
        j = ci + 2
        if not case.const:
            j = self.f.match[ci + 2] + 1
        # j: ';' or '{'
        cls = ("$" + name) if case.const else name
        fields = "".join(f" public {ty} {nm};" for ty, nm in case.params)
        formals = ", ".join(f"{ty} {nm}" for ty, nm in case.params)
        assigns = "".join(f" this.{nm} = {nm};" for _, nm in case.params)
        head = (f"{vis}static class {cls} extends {base} {{{fields}"
                f" public {cls}({formals}) {{ super();{assigns}")
        if case.const:
            tail = (f" }} public String toString() {{ return \"{name}\"; }} }}"
                    f" {vis}static final {base} {name} = new {cls}();")
        else:
            args = ", ".join(nm for _, nm in case.params)
            tail = (f" }} }} {vis}static {name} {name}({formals})"
                    f" {{ return new {name}({args}); }}")
        if t[j].text == ";":
            self.e.replace(start, t[j].end, head + tail)
        elif t[j].text == "{":
            self.e.replace(start, t[j].start, head + " ")
            self.e.insert(t[self.f.match[j]].end, tail)
        else:
            raise PizzaError(f"{self.f.where(ci)}: unexpected {t[j].text!r} after case")

    # -- switches ------------------------------------------------------------
    def label_end(self, ci):
        """Index of the ':' that ends the label starting at ci."""
        t = self.f.toks
        depth = 0
        k = ci + 1
        while True:
            x = t[k]
            if x.text in "([{":
                depth += 1
            elif x.text in ")]}":
                depth -= 1
            elif x.text == ":" and depth == 0:
                return k
            elif x.text == "?" and depth == 0:
                raise PizzaError(f"{self.f.where(ci)}: '?' in case label")
            k += 1

    def is_pattern_switch(self, pats):
        """pats: list of token lists"""
        for toks in pats:
            if any(x.text == "(" for x in toks) or any(x.text == "_" for x in toks):
                return True
        names = []
        for toks in pats:
            if len(toks) == 1 and toks[0].kind == "id":
                names.append(toks[0].text)
            elif all(x.kind == "id" or x.text == "." for x in toks):
                names.append(toks[-1].text)
            else:
                return False   # literal: an ordinary switch
        if not names:
            return False
        cands = [a for a in self.w.adts.values() if all(n in a.all_cases() for n in names)]
        return bool(cands)

    def choose_adt(self, pats, at):
        tops = []
        for p in pats:
            if isinstance(p, PCase):
                tops.append(p.name)
            elif isinstance(p, PConst) and p.isname:
                tops.append(p.text)
        qualified = [n for n in tops if "." in n]
        for n in qualified:
            adt = self.w.resolve_type(n.rpartition(".")[0], self.f, at)
            if adt is not None:
                return adt
        simple = [n.rpartition(".")[2] for n in tops]
        cands = [a for a in self.w.adts.values()
                 if all(n in a.all_cases() for n in simple)]
        # drop candidates whose subclass is also a candidate
        cands = [a for a in cands
                 if not any(b is not a and self.inherits(b, a) for b in cands)] \
            if len(cands) > 1 and all(c.root() is cands[0].root() for c in cands) \
            else cands
        if len(cands) == 1:
            return cands[0]
        if not cands:
            raise PizzaError(f"{self.f.where(at)}: no algebraic type has cases {simple}")
        # keep the ones whose case parameter types agree with the bindings
        def fits(a, p):
            if not isinstance(p, PCase):
                return True
            c = a.all_cases().get(p.name.rpartition(".")[2])
            if c is None or c.const or len(c.params) != len(p.args):
                return False
            for (ty, _), sub in zip(c.params, p.args):
                if isinstance(sub, PBind) and \
                        sub.typ.rpartition(".")[2] != ty.replace(" ", "").rpartition(".")[2]:
                    return False
            return True
        fitting = [a for a in cands if all(fits(a, p) for p in pats)]
        if len(fitting) == 1:
            return fitting[0]
        if fitting:
            cands = fitting
        # the declared type of a simple selector variable
        t = self.f.toks
        close = at - 1
        po = self.f.open_of(close)
        if close == po + 2 and t[po + 1].kind == "id":
            var = t[po + 1].text
            for k in range(po - 1, 0, -1):
                if t[k].text == var and t[k - 1].kind == "id" and \
                        t[k + 1].text in ("=", ",", ")", ";"):
                    for a in cands:
                        if a.simple == t[k - 1].text:
                            return a
                    break
        # prefer the ones visible by simple name from here
        vis = [a for a in cands if self.w.resolve_type(a.simple, self.f, at) is a]
        if len(vis) == 1:
            return vis[0]
        encl = self.f.enclosing_classes(at)
        for a in cands:
            for q in encl:
                if a.fqn.endswith("." + q) or a.fqn == q:
                    return a
        raise PizzaError(f"{self.f.where(at)}: ambiguous switch over "
                         f"{[a.fqn for a in cands]}")

    @staticmethod
    def inherits(a, b):
        while a is not None:
            if a is b:
                return True
            a = a.parent
        return False

    def case_of(self, adt, name, at):
        if "." in name:
            q, _, simple = name.rpartition(".")
            a2 = self.w.resolve_type(q, self.f, at)
            if a2 is None:
                raise PizzaError(f"{self.f.where(at)}: unknown algebraic type {q}")
            adt, name = a2, simple
        cases = adt.all_cases()
        if name not in cases:
            raise PizzaError(f"{self.f.where(at)}: {adt.fqn} has no case {name}")
        return cases[name]

    def compile_pat(self, p, expr, adt, at, conds, binds, static_type=None):
        """Append matching conditions / bindings for pattern p on expr.

        adt is the algebraic type expected at this position (or None)."""
        if isinstance(p, PWild):
            return
        if isinstance(p, PBind):
            binds.append(f"{p.typ} {p.name} = ({p.typ}) {expr};")
            return
        if isinstance(p, PConst):
            if p.isname and adt is not None:
                simple = p.text.rpartition(".")[2]
                cases = adt.all_cases()
                if "." in p.text:
                    a2 = self.w.resolve_type(p.text.rpartition(".")[0], self.f, at)
                    cases = a2.all_cases() if a2 is not None else {}
                if simple in cases and cases[simple].const:
                    conds.append(f"{expr} == {cases[simple].ref}")
                    return
            if p.isname and adt is None:
                # maybe a constant case of some other adt, qualified
                if "." in p.text:
                    a2 = self.w.resolve_type(p.text.rpartition(".")[0], self.f, at)
                    if a2 is not None and p.text.rpartition(".")[2] in a2.all_cases():
                        conds.append(f"{expr} == {a2.all_cases()[p.text.rpartition('.')[2]].ref}")
                        return
            if p.text.startswith('"'):
                conds.append(f"{p.text}.equals({expr})")
            else:
                conds.append(f"{expr} == {p.text}")
            return
        if isinstance(p, PCase):
            if adt is None:
                if "." in p.name:
                    adt = self.w.resolve_type(p.name.rpartition(".")[0], self.f, at)
                if adt is None:
                    cands = self.w.adts_with_case(p.name)
                    if len(cands) != 1:
                        raise PizzaError(f"{self.f.where(at)}: cannot type sub-pattern {p.name}")
                    adt = cands[0]
            case = self.case_of(adt, p.name, at)
            if case.const:
                if p.args:
                    raise PizzaError(f"{self.f.where(at)}: constant case {p.name} with args")
                conds.append(f"{expr} == {case.ref}")
                return
            if len(p.args) != len(case.params):
                raise PizzaError(f"{self.f.where(at)}: {p.name} expects "
                                 f"{len(case.params)} args, got {len(p.args)}")
            conds.append(f"{expr} instanceof {case.cls}")
            for (ty, fname), sub in zip(case.params, p.args):
                sub_adt = None
                if not ty.endswith("]"):
                    sub_adt = self.w.resolve_type(ty, case.adt.file,
                                                  self.case_token(case))
                self.compile_pat(sub, f"(({case.cls}) {expr}).{fname}",
                                 sub_adt, at, conds, binds)
            return
        raise AssertionError(p)

    def case_token(self, case):
        f = case.adt.file
        for b, ci in f.cases:
            if f.toks[ci + 1].text == case.name:
                return ci
        return 0

    def selector_type(self, brace):
        """Declared type of a simple selector variable, if found."""
        t = self.f.toks
        close = brace - 1
        po = self.f.open_of(close)
        if close == po + 2 and t[po + 1].kind == "id":
            var = t[po + 1].text
            for k in range(po - 1, 0, -1):
                if t[k].text == var and t[k - 1].kind == "id" and \
                        t[k - 1].text not in ("return", "case", "new") and \
                        t[k + 1].text in ("=", ",", ")", ";"):
                    return t[k - 1].text
        return None

    def switch(self, brace, cis):
        t = self.f.toks
        # header: 'switch' '(' expr ')' '{'
        sw = brace - 1
        assert t[sw].text == ")"
        po = self.f.open_of(sw)
        assert t[po - 1].text == "switch", self.f.where(brace)
        labels = []
        for ci in cis:
            le = self.label_end(ci)
            labels.append((ci, le, t[ci + 1:le]))
        if not self.is_pattern_switch([toks for _, _, toks in labels]):
            return self.wrap_groups(brace, cis, None, None)
        if not any(x.text in ("(", "_") for _, _, toks in labels for x in toks):
            # only bare names: maybe an ordinary switch over int constants
            sty = self.selector_type(brace)
            if sty in ("int", "char", "short", "byte", "long"):
                return self.wrap_groups(brace, cis, None, None)
            for _, _, toks in labels:
                if len(toks) > 1:
                    q = "".join(x.text for x in toks[:-2])
                    if self.w.resolve_type(q, self.f, brace) is None:
                        return self.wrap_groups(brace, cis, None, None)
        try:
            pats = [parse_pattern(toks, self.f) for _, _, toks in labels]
        except PizzaError as ex:
            raise PizzaError(f"{self.f.where(brace)}: {ex}")
        adt = self.choose_adt(pats, brace)
        n = self.counter = self.counter + 1
        sel, idx = f"$sel{n}", f"$idx{n}"
        root = adt.root()
        conds_all, binds_all = [], []
        for (ci, le, toks), p in zip(labels, pats):
            conds, binds = [], []
            self.compile_pat(p, sel, adt, ci, conds, binds)
            conds_all.append(" && ".join(conds) or "true")
            binds_all.append(binds)
        chain = " else ".join(f"if ({c}) {idx} = {k};" for k, c in enumerate(conds_all))
        expr = self.f.src[t[po].end:t[sw].start]
        head = (f"{{ final {root.fqn} {sel} = ({root.fqn}) ({expr}); int {idx}; "
                f"{chain} else {idx} = -1; switch ({idx}) ")
        self.e.replace(t[po - 1].start, t[sw].end, head)
        self.e.insert(t[self.f.match[brace]].end, " }")
        label_no = {ci: num for num, (ci, _, _) in enumerate(labels)}
        self.wrap_groups(brace, cis, label_no, binds_all)

    def wrap_groups(self, brace, cis, label_no, binds_all):
        """Give every group of statements its own block (Pizza scoping);
        for pattern switches also renumber the labels and add bindings."""
        t = self.f.toks
        # labels and groups
        # collect all label positions (case + default) at this switch level
        level = []
        for ci in cis:
            level.append(("case", ci))
        depth = 0
        for k in range(brace + 1, self.f.match[brace]):
            x = t[k]
            if x.text in "{([":
                depth += 1
            elif x.text in "})]":
                depth -= 1
            elif depth == 0 and x.text == "default" and t[k + 1].text == ":":
                level.append(("default", k))
        level.sort(key=lambda e: e[1])
        groups = []   # list of lists of label entries
        prev_end = None
        for kind, k in level:
            end = self.label_end(k) if kind == "case" else k + 1
            if groups and k == prev_end + 1:
                groups[-1].append((kind, k, end))
            else:
                groups.append([(kind, k, end)])
            prev_end = end
        for g, group in enumerate(groups):
            binds = []
            for kind, k, end in group:
                if kind == "case" and label_no is not None:
                    num = label_no[k]
                    self.e.replace(t[k].start, t[end].end, f"case {num}:")
                    if binds_all[num]:
                        if binds:
                            raise PizzaError(f"{self.f.where(k)}: bindings in "
                                             "fall-through labels")
                        binds = binds_all[num]
            last_end = group[-1][2]
            body_end = (t[groups[g + 1][0][1]].start if g + 1 < len(groups)
                        else t[self.f.match[brace]].start)
            self.e.insert(t[last_end].end, " { " + " ".join(binds), order=1)
            self.e.insert(body_end, "} ", order=-1)


META_RE = re.compile(r"@meta\s+(.*?)(?:\*/|\n\s*\*\s*@|$)", re.S)


def extract_meta(fi):
    """The @meta annotations of fi: [(class, kind, name, params, meta)].

    class is the binary class name; kind is 'class', 'method' or 'field';
    params the list of parameter types (methods only)."""
    out = []
    t = fi.toks
    for i, doc in fi.docs:
        m = META_RE.search(doc)
        if not m or i >= len(t):
            continue
        meta = re.sub(r"\s*\n\s*\*\s*", " ", m.group(1)).strip()
        k = i
        while t[k].text in ("public", "private", "protected", "static", "final",
                            "abstract", "native", "synchronized", "transient",
                            "volatile"):
            k += 1
        # enclosing class
        encl = None
        for b in fi.classname:
            if b < i < fi.match[b] and (encl is None or b > encl):
                encl = b
        def binary(brace):
            q = fi.class_chain(brace).replace(".", "$")
            return (fi.package + "." + q) if fi.package else q
        if t[k].text in ("class", "interface"):
            # the class body starts at the next '{'
            b = k
            while t[b].text != "{":
                b += 1
            out.append((binary(b), "class", None, None, meta))
            continue
        if encl is None:
            continue
        # method or field: find '(' or '=' / ';'
        j = k
        while t[j].text not in ("(", "=", ";", ","):
            j += 1
        name = t[j - 1].text
        if t[j].text == "(":
            close = fi.match[j]
            params = []
            if close > j + 1:
                for ty, _ in parse_params(t[j + 1:close], fi, j):
                    params.append(ty)
            out.append((binary(encl), "method", name, params, meta))
        else:
            out.append((binary(encl), "field", name, None, meta))
    return out


def split_public(rel, text):
    """Move extra public top-level classes into files of their own.

    Returns [(rel, text)]."""
    toks = lex(text)
    base = os.path.basename(rel).split(".")[0]
    header_end = 0
    depth = 0
    tops = []   # (start_tok, open_brace_tok, close_tok, name, public)
    i = 0
    while i < len(toks):
        x = toks[i]
        if depth == 0 and x.text in ("package", "import"):
            while toks[i].text != ";":
                i += 1
            header_end = toks[i].end
            i += 1
            continue
        if depth == 0 and x.kind == "id":
            # a top-level declaration: modifiers class|interface Name ... {
            start = i
            while toks[i].text != "{":
                i += 1
            names = [toks[k + 1].text for k in range(start, i)
                     if toks[k].text in ("class", "interface")]
            public = any(toks[k].text == "public" for k in range(start, i))
            open_ = i
            d = 0
            while True:
                if toks[i].text == "{":
                    d += 1
                elif toks[i].text == "}":
                    d -= 1
                    if d == 0:
                        break
                i += 1
            tops.append((start, open_, i, names[0] if names else None, public))
            i += 1
            continue
        i += 1
    extra = [tp for tp in tops if tp[4] and tp[3] != base]
    if not extra:
        return [(rel, text)]
    header = text[:header_end]
    out = []
    main = []
    last = 0
    for start, _, close, name, _ in extra:
        s0, s1 = toks[start].start, toks[close].end
        main.append(text[last:s0])
        last = s1
        out.append((os.path.join(os.path.dirname(rel), name + ".java"),
                    header + "\n\n" + text[s0:s1] + "\n"))
    main.append(text[last:])
    return [(rel, "".join(main))] + out


def main(argv):
    srcroot, outroot = argv[1], argv[2]
    files, extra = [], []
    meta_out = None
    it = iter(argv[3:])
    for a in it:
        if a == "--classpath-src":
            extra.append(next(it))
        elif a == "--meta-out":
            meta_out = next(it)
        else:
            files.append(a)
    world = World()
    infos = []
    for rel in files:
        with open(os.path.join(srcroot, rel), encoding="latin-1") as fh:
            fi = FileInfo(rel, fh.read())
        world.add_file(fi)
        infos.append(fi)
    for d in extra:
        for dp, _, fs in os.walk(d):
            for fn in fs:
                if fn.endswith(".java"):
                    p = os.path.join(dp, fn)
                    with open(p, encoding="latin-1") as fh:
                        src = fh.read()
                    world.add_file(FileInfo(os.path.relpath(p, d), src))
    world.link()
    if meta_out:
        import json
        with open(meta_out, "w") as fh:
            json.dump([m for fi in infos for m in extract_meta(fi)], fh, indent=1)
    errors = 0
    for fi in infos:
        try:
            out = Translator(world, fi).run()
        except PizzaError as ex:
            print(f"error: {ex}", file=sys.stderr)
            errors += 1
            continue
        for rel, text in split_public(fi.rel, out):
            dest = os.path.join(outroot, rel)
            os.makedirs(os.path.dirname(dest), exist_ok=True)
            with open(dest, "w", encoding="latin-1") as fh:
                fh.write(text)
    return 1 if errors else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
