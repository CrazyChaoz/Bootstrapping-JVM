#!/usr/bin/env python3
"""Translate PiCo into Java, for PiCo's boot compiler (see README.md).

usage: pico2java.py SRCROOT OUTROOT FILE...

FILE paths (.pizza or .java) are relative to SRCROOT; the translations are
written to the same relative paths below OUTROOT, as .java files.

It works on tokens and knows no types, so it covers what JaCo's sources use,
and the result only has to behave like PiCo would have compiled it: the
compiler built from it must then compile itself to the same class files as
it compiles to itself.

  * algebraic cases declared as class members
        [mods] case Name;                     constant case
        [mods] case Name(T1 f1, ...) [body]   class case, body = constructor
    become a static nested subclass (fields + constructor) plus a static
    factory method of the same name, resp. a singleton field; a subclass can
    add cases to an algebraic type (extensible algebraic types)
  * pattern switches
        switch (e) { case Name(T x, _, Sub(..), CONST): ... }
    become an if-chain computing a case index followed by an ordinary
    switch on that index; bindings are declared at the start of each case
    group (which is wrapped in a block)
  * 'enum' and 'assert' as names
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


def lex(src):
    toks = []
    pos = 0
    while pos < len(src):
        m = TOKEN_RE.match(src, pos)
        if not m:
            raise SyntaxError(f"bad char {src[pos]!r} at {pos}")
        k = m.lastgroup
        if k not in ("ws", "lc", "bc"):
            toks.append(Tok(k, m.group(), m.start(), m.end()))
        pos = m.end()
    return toks


class PicoError(Exception):
    pass


# --------------------------------------------------------------------------
# structure


class FileInfo:
    def __init__(self, rel, src):
        self.rel = rel
        self.src = src
        self.toks = lex(src)
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

    def methods(self, b):
        """Method declarations directly in the class body starting at b."""
        t = self.toks
        out = []
        start = b + 1
        k = b + 1
        end = self.match[b]
        while k < end:
            x = t[k]
            if x.kind == "op" and x.text == "{":
                m = self.method_decl(t[start:k])
                if m:
                    m["body"] = k
                    out.append(m)
                k = self.match[k] + 1
                start = k
                continue
            if x.text == ";":
                m = self.method_decl(t[start:k])
                if m:
                    out.append(m)
                start = k + 1
            k += 1
        return out

    def method_decl(self, stmt):
        for i, x in enumerate(stmt):
            if x.text == "(":
                break
        else:
            return None
        if i < 2 or stmt[i - 1].kind != "id" or \
                stmt[i - 2].kind != "id" and stmt[i - 2].text not in ("]", ">", ">>", ">>>"):
            return None
        if any(y.text in ("=", "new", "class", "interface", "case", "->") for y in stmt[:i]):
            return None
        depth = 0
        j = i
        while True:
            if stmt[j].text == "(":
                depth += 1
            elif stmt[j].text == ")":
                depth -= 1
                if depth == 0:
                    break
            j += 1
        mods = ("public", "private", "protected", "static", "final",
                "abstract", "native", "synchronized")
        head = [y for y in stmt[:i - 1] if y.text not in mods]
        return dict(ret="".join(y.text for y in head))

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
        self.classes = set()

    def add_file(self, finfo):
        self.files.append(finfo)
        self.index(finfo)
        t = finfo.toks
        for brace, ci in finfo.cases:
            q = finfo.class_chain(brace)
            if q is None:
                raise PicoError(f"{finfo.where(ci)}: case in anonymous class")
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
                params = parse_params(t[ci + 3:close])
            adt.cases[name] = Case(adt, name, params or [], params is None,
                                   mods)

    def index(self, finfo):
        for b, name in finfo.classname.items():
            q = finfo.class_chain(b)
            if q:
                self.classes.add((finfo.package + "." + q) if finfo.package else q)

    def resolve_class(self, name, finfo):
        """Fully qualified name of a class referenced as name in finfo."""
        cands = []
        if finfo.package:
            cands.append(finfo.package + "." + name)
        for imp, ondemand in finfo.imports:
            if ondemand:
                cands.append(imp + "." + name)
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
        cands = []
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
        cands.append(name)
        for c in cands:
            if c in self.adts:
                return self.adts[c]
        return None



def parse_params(toks):
    """Split 'T1 f1, T2[] f2' into [(type, name)]."""
    params = []
    cur = []
    depth = 0
    for x in toks + [None]:
        if x is None or (x.text == "," and depth == 0):
            if cur:
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
    return "".join(x.text for x in toks)


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
    """A constant case."""

    def __init__(self, text):
        self.text = text


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
            raise PicoError("empty pattern")
        if x.text == "_":
            pos += 1
            return PWild()
        if x.kind != "id":
            raise PicoError(f"unexpected {x.text!r} in pattern")
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
                raise PicoError(f"expected ) in pattern, got {peek().text!r}")
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
            return PBind(typ, name)
        return PConst(typ)

    p = pat()
    if pos != len(toks):
        raise PicoError(f"trailing tokens in pattern: {toks[pos:]}")
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
                raise PicoError(f"overlapping edits at {start}")
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
        for k in range(1, len(t)):
            if t[k].text in ("enum", "assert") and t[k].kind == "id":
                self.e.replace(t[k].start, t[k].end, t[k].text + "$")
        for brace, ci in self.f.cases:
            self.case_decl(brace, ci)
        by_switch = {}
        for b, ci in self.f.labels:
            by_switch.setdefault(b, []).append(ci)
        for b, cis in by_switch.items():
            self.switch(b, cis)
        return self.e.apply(self.f.src)

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
                    raise PicoError(f"{self.f.where(i)}: cannot resolve import {name}")
                name = q + name[len(first):]
                self.e.replace(t[i + 1].start, t[j].start, name)
            if name.endswith(".*") and name[:-2] in self.w.adts:
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
        args = ", ".join(nm for _, nm in case.params)
        if case.const:
            head = (f"{vis}static class {cls} extends {base} {{{fields}"
                    f" public {cls}({formals}) {{ super();{assigns}")
            tail = (f" }} public String toString() {{ return \"{name}\"; }} }}"
                    f" {vis}static final {base} {name} = new {cls}();")
        else:
            head = (f"{vis}static class {cls} extends {base} {{{fields}"
                    f" public {cls}({formals}) {{ super();{assigns}")
            tail = (f" }} }} {vis}static {name} {name}({formals})"
                    f" {{ return new {name}({args}); }}")
        if t[j].text == ";":
            self.e.replace(start, t[j].end, head + tail)
        else:
            raise PicoError(f"{self.f.where(ci)}: unexpected {t[j].text!r} after case")

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
                raise PicoError(f"{self.f.where(ci)}: '?' in case label")
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
            elif isinstance(p, PConst):
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
            raise PicoError(f"{self.f.where(at)}: no algebraic type has cases {simple}")
        raise PicoError(f"{self.f.where(at)}: ambiguous switch over "
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
                raise PicoError(f"{self.f.where(at)}: unknown algebraic type {q}")
            adt, name = a2, simple
        cases = adt.all_cases()
        if name not in cases:
            subs = [d for d in self.w.adts.values()
                    if d is not adt and self.inherits(d, adt) and name in d.cases]
            if len(subs) == 1:
                return subs[0].cases[name]
            raise PicoError(f"{self.f.where(at)}: {adt.fqn} has no case {name}")
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
            cases = adt.all_cases() if adt is not None else {}
            if p.text in cases and cases[p.text].const:
                conds.append(f"{expr} == {cases[p.text].ref}")
            else:
                conds.append(f"{expr} == {p.text}")
            return
        if isinstance(p, PCase):
            if adt is None:
                raise PicoError(f"{self.f.where(at)}: cannot type sub-pattern {p.name}")
            case = self.case_of(adt, p.name, at)
            if case.const:
                raise PicoError(f"{self.f.where(at)}: constant case {p.name} with args")
            if len(p.args) != len(case.params):
                raise PicoError(f"{self.f.where(at)}: {p.name} expects "
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
        try:
            pats = [parse_pattern(toks, self.f) for _, _, toks in labels]
        except PicoError as ex:
            raise PicoError(f"{self.f.where(brace)}: {ex}")
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
        m = re.fullmatch(r"\s*\(\s*([\w.]+)\s*\)\s*([\w.\[\]]+)\s*", expr)
        if m:
            cast = self.w.resolve_type(m.group(1), self.f, brace)
            if cast is not None and cast.root() is root and cast is not root:
                expr = " " + m.group(2) + " "
        head = (f"{{ final {root.fqn} {sel} = ({root.fqn}) ({expr}); int {idx}; "
                f"{chain} else {idx} = -1; switch ({idx}) ")
        self.e.replace(t[po - 1].start, t[sw].end, head)
        self.e.insert(t[self.f.match[brace]].end, " }")
        if (self.exhaustive(adt, pats) or self.tail_of_value_method(brace)) and \
                not self.has_default(brace):
            # javac's flow analysis does not know the switch is exhaustive
            # (first: the last group may fall through to the end)
            self.e.insert(t[brace].end,
                          ' default: throw new Error("exhaustive switch"); ', order=-1)
        label_no = {ci: num for num, (ci, _, _) in enumerate(labels)}
        self.wrap_groups(brace, cis, label_no, binds_all)

    def tail_of_value_method(self, brace):
        """Is the switch at brace the last statement of a method with a
        result?  (PiCo's flow analysis took it as exhaustive then.)"""
        t = self.f.toks
        k = self.f.match[brace] + 1
        while k < len(t) and t[k].text == "}":
            for b in self.f.classname:
                if b < brace < self.f.match[b]:
                    for m in self.f.methods(b):
                        if m.get("body") is not None and self.f.match[m["body"]] == k:
                            return m["ret"] != "void"
            k += 1
        return False

    def has_default(self, brace):
        t = self.f.toks
        depth = 0
        for k in range(brace + 1, self.f.match[brace]):
            x = t[k].text
            if x in "{([":
                depth += 1
            elif x in "})]":
                depth -= 1
            elif depth == 0 and x == "default" and t[k + 1].text == ":":
                return True
        return False

    def exhaustive(self, adt, pats):
        covered = set()
        for p in pats:
            if isinstance(p, (PWild, PBind)):
                return True
            if isinstance(p, PCase) and all(isinstance(a, (PWild, PBind)) for a in p.args):
                covered.add(p.name.rpartition(".")[2])
            elif isinstance(p, PConst):
                covered.add(p.text.rpartition(".")[2])
        return set(adt.all_cases()) <= covered

    def wrap_groups(self, brace, cis, label_no, binds_all):
        """Give every group of statements its own block (PiCo scoping);
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
                            raise PicoError(f"{self.f.where(k)}: bindings in "
                                             "fall-through labels")
                        binds = binds_all[num]
            last_end = group[-1][2]
            body_end = (t[groups[g + 1][0][1]].start if g + 1 < len(groups)
                        else t[self.f.match[brace]].start)
            self.e.insert(t[last_end].end, " { " + " ".join(binds), order=1)
            self.e.insert(body_end, "} ", order=-1)


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
    # old scalac references members through their declaring class, so
    # package-private top-level classes must become public (and get their
    # own file)
    pub = []
    for start, open_, close, name, public in tops:
        if not public and name:
            pub.append(toks[start].start)
    if pub:
        for pos in reversed(pub):
            text = text[:pos] + "public " + text[pos:]
        return split_public(rel, text)
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
    world = World()
    infos = []
    for rel in argv[3:]:
        with open(os.path.join(srcroot, rel), encoding="latin-1") as fh:
            fi = FileInfo(rel, fh.read())
        world.add_file(fi)
        infos.append(fi)
    world.link()
    errors = 0
    for fi in infos:
        try:
            out = Translator(world, fi).run()
        except PicoError as ex:
            print(f"error: {ex}", file=sys.stderr)
            errors += 1
            continue
        for rel, text in split_public(re.sub(r"\.pizza$", ".java", fi.rel), out):
            dest = os.path.join(outroot, rel)
            os.makedirs(os.path.dirname(dest), exist_ok=True)
            with open(dest, "w", encoding="latin-1") as fh:
                fh.write(text)
    return 1 if errors else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
