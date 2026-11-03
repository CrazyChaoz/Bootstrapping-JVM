#!/usr/bin/env python3
"""Translate Pizza into Java, for the boot compilers of Pizza (0.40) and PiCo (JaCo).

usage: pizza2java.py SRCROOT OUTROOT FILE...

FILE paths (.pizza or .java) are relative to SRCROOT; the translations are
written to the same relative paths below OUTROOT, as .java files, together
with the interfaces of the function types (pizza0/FunN.java, FunNX.java) and
the cell of a captured variable (pizza0/Ref.java).

It works on tokens and knows no types, so it covers what these two compilers'
sources use, and the result only has to behave like Pizza (or PiCo) would
have compiled it: the compiler built from it must then compile itself to the
same class files as it compiles to itself (see README.md).

  * algebraic cases declared as class members
        [mods] case Name;                     constant case
        [mods] case Name(T1 f1, ...) [body]   class case, body = constructor
    become a static nested subclass (fields + constructor, the type
    parameters of the class) plus a static factory method of the same name,
    resp. a singleton field.  A case named like its class ('class Pair<A, B>
    { case Pair(A fst, B snd); }') is the class itself.
  * pattern switches
        switch (e) { case Name(T x, _, Sub(..), CONST, lit): ... }
        case <A1> Cell(A1 x):                 type variables (erased)
    become an if-chain computing a case index followed by an ordinary
    switch on that index; bindings are declared at the start of each case
    group (which is wrapped in a block).
  * function types '(T1, ..., Tn) [throws E] -> R' become pizza0.FunN<...>
    (resp. FunNX), primitive types boxed and void as Void; closures
    'fun(T1 x1, ...) -> R { ... }' lambdas cast to their FunN; calls of
    function-typed variables 'f(x)' are 'f.apply(x)'; a method named as a
    value is a method reference; locals that a closure captures and that
    are assigned are cells (pizza0.Ref), shared as in Pizza.
  * generic type arguments that are primitive types are boxed (Cell<boolean>).
  * PiCo: the cases a subclass adds to an algebraic type (extensible types),
    switches over such a subclass, and 'assert' as a name.
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
        self.typarams = {}         # index of class-body '{' -> '<A, B extends C>'
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
                        if k + 2 < len(stmt) and stmt[k + 2].text == "<":
                            # type parameters: the text up to the matching '>'
                            d, m = 0, k + 2
                            while True:
                                d += {"<": 1, ">": -1, ">>": -2, ">>>": -3}.get(stmt[m].text, 0)
                                if d <= 0:
                                    break
                                m += 1
                            self.typarams[i] = type_text(stmt[k + 2:m + 1])
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

    def fqn_of(self, brace):
        q = self.class_chain(brace)
        return (self.package + "." + q) if self.package else q

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
        tparams = []
        if head and head[0].text == "<":
            d, m = 0, 0
            while True:
                d += {"<": 1, ">": -1, ">>": -2, ">>>": -3}.get(head[m].text, 0)
                if d == 1 and head[m].kind == "id" and head[m - 1].text in ("<", ","):
                    tparams.append(head[m].text)
                if d <= 0:
                    break
                m += 1
            head = head[m + 1:]
        throws = []
        if j + 1 < len(stmt) and stmt[j + 1].text == "throws":
            throws = [y.text for y in stmt[j + 2:] if y.kind == "id"]
        return dict(tok=stmt[i - 1], name=stmt[i - 1].text,
                    params=tuple(re.sub(r"\s", "", ty) for ty, _ in
                                 parse_params(stmt[i + 1:j], self, 0)),
                    ret="".join(y.text for y in head),
                    tparams=tparams, throws=throws,
                    static=any(y.text == "static" for y in stmt[:i - 1]))

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
        if self.name == self.adt.simple:
            return self.adt.fqn       # the class is its only case
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
        self.typarams = ""
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
                raise PizzaError(f"{finfo.where(ci)}: case in anonymous class")
            fqn = (finfo.package + "." + q) if finfo.package else q
            adt = self.adts.get(fqn) or Adt(fqn, finfo)
            self.adts[fqn] = adt
            if brace in finfo.superclass:
                adt.superclass = (finfo.superclass[brace], brace)
            adt.typarams = finfo.typarams.get(brace, "")
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
        while "<" in name:
            name = re.sub(r"<[^<>]*>", "", name)
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


def type_param_names(tp):
    """'<A, B extends C<A>>' -> '<A, B>'"""
    if not tp:
        return ""
    names, depth = [], 0
    for m in re.finditer(r"[<>,]|[\w$.]+", tp):
        x = m.group()
        if x == "<":
            depth += 1
            if depth == 1:
                expect = True
                continue
        elif x == ">":
            depth -= 1
        elif x == "," and depth == 1:
            expect = True
            continue
        elif depth == 1 and expect:
            names.append(x)
        expect = False
    return "<" + ", ".join(names) + ">"


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
        if peek() is not None and peek().text == "<":
            # type arguments (Pizza generics)
            depth = 0
            while True:
                x = peek()
                if x is None:
                    raise PizzaError("unclosed type arguments in pattern")
                depth += {"<": 1, ">": -1, ">>": -2, ">>>": -3}.get(x.text, 0)
                typ += x.text + (" " if x.text == "," else "")
                pos += 1
                if depth <= 0:
                    break
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

    tvars = []
    if peek() is not None and peek().text == "<":
        # 'case <A1, B1> Pair(A1 x, B1 y)': type variables of the pattern
        pos += 1
        while peek().text != ">":
            if peek().kind == "id":
                tvars.append(peek().text)
            pos += 1
        pos += 1
    p = pat()
    if pos != len(toks):
        raise PizzaError(f"trailing tokens in pattern: {toks[pos:]}")
    if tvars:
        tv = re.compile(r"\b(" + "|".join(tvars) + r")\b")

        def erase(q):
            if isinstance(q, PBind):
                q.typ = tv.sub("Object", q.typ)
            elif isinstance(q, PCase):
                for a in q.args:
                    erase(a)
        erase(p)
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
        for k in range(1, len(t)):
            if t[k].text == "private" and self.in_adt_body(k):
                # (pizzadoc reads private fields of pizza.v40.Type)
                self.e.replace(t[k].start, t[k].end, "public /*private*/")
            elif t[k].text == "private" and self.in_nested_class_body(k):
                self.e.replace(t[k].start, t[k].end, "/*private*/")
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

    def in_adt_body(self, k):
        """Is token k a member modifier of a class with cases?  (Its cases
        are subclasses, which see its private members in Pizza.)"""
        b = self.enclosing_brace(k)
        return b is not None and self.f.kinds[b] == "class" and \
            any(cb == b for cb, _ in self.f.cases)

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
        tp = adt.typarams                    # '<A, B extends C>'
        tpn = type_param_names(tp)           # '<A, B>'
        args = ", ".join(nm for _, nm in case.params)
        if name == base:
            # 'class Pair<A, B> { case Pair(A fst, B snd); }': the class is
            # the case
            if case.const:
                raise PizzaError(f"{self.f.where(ci)}: constant case named like its class")
            head = f"{fields} public {name}({formals}) {{ super();{assigns}"
            tail = (f" }} {vis}static {tp} {name}{tpn} {name}({formals})"
                    f" {{ return new {name}{tpn}({args}); }}").replace("static  ", "static ")
        elif case.const:
            head = (f"{vis}static class {cls} extends {base} {{{fields}"
                    f" public {cls}({formals}) {{ super();{assigns}")
            tail = (f" }} public String toString() {{ return \"{name}\"; }} }}"
                    f" {vis}static final {base} {name} = new {cls}();")
        else:
            head = (f"{vis}static class {cls}{tp} extends {base}{tpn} {{{fields}"
                    f" public {cls}({formals}) {{ super();{assigns}")
            tail = (f" }} }} {vis}static {tp} {name}{tpn} {name}({formals})"
                    f" {{ return new {name}{tpn}({args}); }}").replace("static  ", "static ")
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
            subs = [d for d in self.w.adts.values()
                    if d is not adt and self.inherits(d, adt) and name in d.cases]
            if len(subs) == 1:
                return subs[0].cases[name]
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
        result?  (Pizza's flow analysis took it as exhaustive then.)"""
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
            elif isinstance(p, PConst) and p.isname:
                covered.add(p.text.rpartition(".")[2])
        return set(adt.all_cases()) <= covered

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


# --------------------------------------------------------------------------
# first pass: Pizza's higher-order functions -> Java
#
#   (T1, ..., Tn) -> R          pizza0.FunN<T1', ..., Tn', R'>  (primitive types
#                               boxed, void as Void)
#   fun(T1 x1, ...) -> R {..}   a lambda, cast to its FunN type; primitive
#                               parameters are unboxed in a prologue, a void
#                               closure returns null
#   f(args), f of function type f.apply(args) (cast back to R if primitive)
#   C<int>                      C<Integer> (primitive type arguments)

PRIMS = {"boolean": "Boolean", "byte": "Byte", "char": "Character",
         "short": "Short", "int": "Integer", "long": "Long",
         "float": "Float", "double": "Double", "void": "Void"}
ANGLE = {"<": 1, ">": -1, ">>": -2, ">>>": -3}


class FunType:
    def __init__(self, params, res, throws=()):
        self.params, self.res = params, res      # Java texts (unboxed)
        self.throws = list(throws)

    def java(self):
        args = [PRIMS.get(p, p) for p in self.params] + [PRIMS.get(self.res, self.res)]
        n = len(self.params)
        if self.throws:
            exc = self.throws[0] if len(self.throws) == 1 else "Exception"
            return f"pizza0.Fun{n}X<{', '.join(args + [exc])}>"
        return f"pizza0.Fun{n}<{', '.join(args)}>"


class Prepass:
    def __init__(self, fi, funfields, methods, allmethods=None, method_values=True):
        self.allmethods = allmethods or {}   # (class simple name, name) -> method
        self.method_values = method_values   # (only where there are function types: PiCo has none)
        self.f = fi
        self.t = fi.toks
        self.funfields = funfields   # name -> FunType, fields of all files
        self.methods = methods       # names of all methods of all files
        self.e = Edits()
        self.decls = []              # (name, FunType, scope lo, scope hi)
        self.arities = set()

    # -- types -------------------------------------------------------------
    def is_funtype(self, k):
        t = self.t
        if t[k].text != "(" or (k > 0 and t[k - 1].text == "fun"):
            return False
        j = self.f.match.get(k)
        return j is not None and self.arrow(j) is not None

    def arrow(self, j):
        """j: ')' of a parameter list; the index of '->' after it and the
        exceptions of a 'throws' clause between them, or None."""
        t = self.t
        if j + 1 < len(t) and t[j + 1].text == "->":
            return j + 1, []
        if j + 1 < len(t) and t[j + 1].text == "throws":
            k, exc = j + 2, []
            while k < len(t) and t[k].kind == "id":
                name = t[k].text
                k += 1
                while t[k].text == "." and t[k + 1].kind == "id":
                    name += "." + t[k + 1].text
                    k += 2
                exc.append(name)
                if t[k].text == ",":
                    k += 1
                    continue
                break
            if t[k].text == "->":
                return k, exc
        return None

    def split_commas(self, lo, hi):
        """Top-level comma separated ranges of tokens lo..hi-1."""
        out, start, depth = [], lo, 0
        for k in range(lo, hi):
            x = self.t[k].text
            if x in ("(", "["):
                depth += 1
            elif x in (")", "]"):
                depth -= 1
            elif x in ANGLE:
                depth += ANGLE[x]
            elif x == "," and depth == 0:
                out.append((start, k))
                start = k + 1
        if start < hi:
            out.append((start, hi))
        return out

    def type_at(self, k):
        """Parse a type at token k: (Java text, unboxed form, end index)."""
        t = self.t
        if self.is_funtype(k):
            j = self.f.match[k]
            params = [self.type_at(a)[0] for a, _ in self.split_commas(k + 1, j)]
            ar, exc = self.arrow(j)
            res, _, end = self.type_at(ar + 1)
            ft = FunType(params, res, exc)
            self.arities.add(len(params))
            text = ft.java()
            while end < len(t) and t[end].text == "[" and t[end + 1].text == "]":
                text += "[]"
                end += 2
            return text, ft, end
        if t[k].kind != "id":
            raise PizzaError(f"{self.f.where(k)}: expected a type, got {t[k].text!r}")
        text = t[k].text
        end = k + 1
        while end + 1 < len(t) and t[end].text == "." and t[end + 1].kind == "id":
            text += "." + t[end + 1].text
            end += 2
        if end < len(t) and t[end].text == "<" and text not in PRIMS:
            args, end = self.type_args(end)
            text += args
        while end + 1 < len(t) and t[end].text == "[" and t[end + 1].text == "]":
            text += "[]"
            end += 2
        return text, None, end

    def type_args(self, k):
        """'<' at k: (Java text, index after the closing '>')."""
        t = self.t
        out = "<"
        k += 1
        pending = 0   # '>' of '>>' still to close
        while True:
            text, _, k = self.type_at(k)
            if text in PRIMS:
                text = PRIMS[text]
            out += text
            x = t[k].text
            if x == ",":
                out += ", "
                k += 1
                continue
            if x in (">", ">>", ">>>"):
                return out + ">", (k + 1 if x == ">" else self.split_close(k))
            raise PizzaError(f"{self.f.where(k)}: bad type arguments")

    def split_close(self, k):
        """A '>>' closes this level and the next: replace the token by '>'."""
        tok = self.t[k]
        rest = tok.text[1:]
        new = Tok("op", rest, tok.start + 1, tok.end)
        self.t[k] = new
        return k

    # -- the pass ----------------------------------------------------------
    def run(self):
        t = self.t
        f = self.f
        # brace -> innermost enclosing brace / bracket, for scopes
        self.stack_at = []
        stack = []
        for k, x in enumerate(t):
            self.stack_at.append(list(stack))
            if x.kind == "op" and x.text in "({[":
                stack.append(k)
            elif x.kind == "op" and x.text in ")}]":
                stack.pop()
        self.closures = {}   # body '{' -> FunType
        self.closure_spans = {}   # body '{' -> ('fun' index, closing '}')
        k = 0
        while k < len(t):
            x = t[k]
            if x.text == "fun" and x.kind == "id" and k + 1 < len(t) and t[k + 1].text == "(":
                k = self.closure(k)
                continue
            if self.is_funtype(k):
                text, ft, end = self.type_at(k)
                self.e.replace(t[k].start, t[end - 1].end, text)
                self.declared(end, ft)
                k = end
                continue
            if x.text == "<" and k > 0 and t[k - 1].kind == "id" and self.looks_generic(k):
                text, end = self.type_args(k)
                self.e.replace(t[k].start, t[end - 1].end, text)
                k = end
                continue
            k += 1
        self.applications()
        if self.method_values:
            self.method_refs()
        self.box_captured()
        return self.e.apply(f.src)

    # -- locals that closures assign, or that are assigned after a closure
    # -- captured them: Java wants them effectively final, so they become cells
    ASSIGN = ("=", "+=", "-=", "*=", "/=", "%=", "&=", "|=", "^=", "<<=", ">>=", ">>>=")

    def box_captured(self):
        t = self.t
        f = self.f
        done = set()
        for body, (fun, close) in sorted(self.closure_spans.items()):
            inner = set()
            for k in range(fun, close):
                if t[k].kind == "id" and t[k + 1].text in ("=", ";", ",", ")") and \
                        (t[k - 1].kind == "id" or t[k - 1].text in (">", "]", ">>")):
                    inner.add(t[k].text)
            names = {t[k].text for k in range(body, close)
                     if t[k].kind == "id" and t[k - 1].text != "." and t[k].text not in inner}
            for name in sorted(names):
                d = self.find_decl(name, fun)
                if d is None or d in done:
                    continue
                j, lo, hi, param = d
                if self.assigned(name, j, lo, hi):
                    done.add(d)
                    self.box(name, j, lo, hi, param)

    def find_decl(self, name, before):
        t = self.t
        for j in range(before - 1, 0, -1):
            if t[j].text != name or t[j].kind != "id":
                continue
            if t[j + 1].text not in ("=", ";", ",", ")"):
                continue
            if not (t[j - 1].kind == "id" and t[j - 1].text not in ("return", "throw", "case", "new", "else")
                    or t[j - 1].text in (">", "]", ">>", ">>>")):
                continue
            st = self.stack_at[j]
            if not st:
                return None
            b = st[-1]
            if t[b].text == "(":
                close = self.f.match[b]
                k = close + 1
                while k < len(t) and t[k].text not in ("{", ";"):
                    k += 1
                if t[k].text != "{" or not (k < before < self.f.match[k]):
                    continue
                return (j, k, self.f.match[k], True)
            if t[b].text == "{":
                if self.f.kinds.get(b) == "class":
                    return None      # a field
                if j < before < self.f.match[b]:
                    return (j, j, self.f.match[b], False)
        return None

    def assigned(self, name, j, lo, hi):
        t = self.t
        for k in range(lo, hi):
            if k == j or t[k].text != name or t[k - 1].text == ".":
                continue
            if t[k + 1].text in self.ASSIGN or t[k + 1].text in ("++", "--") or \
                    t[k - 1].text in ("++", "--"):
                return True
        return False

    def type_start(self, k):
        """k: last token of a type; its first token."""
        t = self.t
        depth = 0
        while True:
            x = t[k].text
            if x in ("]",):
                k -= 2
                continue
            if x in (">", ">>", ">>>"):
                depth += len(x)
            elif x == "<":
                depth -= 1
            if depth == 0 and t[k].kind == "id":
                while k >= 2 and t[k - 1].text == "." and t[k - 2].kind == "id":
                    k -= 2
                return k
            k -= 1

    def box(self, name, j, lo, hi, param):
        t = self.t
        ts = self.type_start(j - 1)
        text, _, end = self.type_at(ts)
        boxed = PRIMS.get(text, text)
        ref = f"pizza0.Ref<{boxed}>"
        self.uses_ref = True
        if param:
            self.e.replace(t[j].start, t[j].end, name + "$v")
            self.e.insert(t[lo].end, f" final {ref} {name} = new {ref}({name}$v);")
        else:
            fin = ts - 1 if ts > 0 and t[ts - 1].text == "final" else ts
            self.e.replace(t[fin].start, t[j].end, f"final {ref} {name}")
            if t[j + 1].text == "=":
                k, depth = j + 2, 0
                while depth > 0 or t[k].text not in (";", ","):
                    if t[k].text in "([{":
                        depth += 1
                    elif t[k].text in ")]}":
                        depth -= 1
                    k += 1
                self.e.insert(t[j + 2].start, f"new {ref}(", order=1)
                self.e.insert(t[k].start, ")", order=-1)
            else:
                dflt = {"boolean": "false", "char": "(char) 0", "long": "0L",
                        "float": "0f", "double": "0d"}.get(text, "0" if text in PRIMS else "null")
                self.e.insert(t[j].end, f" = new {ref}({dflt})")
        funvar = any(n == name for n, _, _, _ in self.decls)
        for k in range(lo, hi):
            if k == j or t[k].text != name or t[k].kind != "id" or t[k - 1].text == ".":
                continue
            if t[k + 1].text == "(" and not funvar:
                continue
            self.e.replace(t[k].start, t[k].end, name + ".v")

    def method_refs(self):
        """A method name used as a value: a method reference, cast to its
        function type (type parameters of the method erased)."""
        t = self.t
        f = self.f
        variables = set()
        for k in range(1, len(t) - 1):
            if t[k].kind == "id" and t[k + 1].text in ("=", ";", ",", ")", "[") and \
                    (t[k - 1].kind == "id" and t[k - 1].text not in ("return", "throw", "case", "new")
                     or t[k - 1].text in (">", "]", ">>", ">>>")):
                variables.add(t[k].text)
        for k in range(1, len(t) - 1):
            x = t[k]
            if x.kind != "id" or t[k + 1].text not in (")", ",", ";", ":"):
                continue
            prev = t[k - 1].text
            qual = None
            if prev == "." and t[k - 2].kind == "id" and t[k - 3].text in ("(", ",", "=", "return", "?", ":"):
                qual = t[k - 2].text
                start = k - 2
            elif prev in ("(", ",", "=", "return", "?", ":"):
                start = k
            else:
                continue
            if qual is None and x.text in variables:
                continue
            if t[start - 1].text == "(" and t[k + 1].text == ")" and k + 2 < len(t) and \
                    (t[k + 2].kind in ("id", "num", "str", "chr") or t[k + 2].text in ("(", "!", "~")):
                continue   # a cast
            m, owner = self.find_method(x.text, qual, k)
            if m is None:
                continue
            if qual is not None:
                ref = f"{qual}::{x.text}"
            elif m["static"]:
                ref = f"{owner}::{x.text}"
            else:
                inner = f.enclosing_classes(k)
                ref = f"this::{x.text}" if inner and inner[-1] == owner else f"{owner}.this::{x.text}"
            ft = self.method_funtype(m)
            if ft is None:
                continue
            if ft.res == "void":
                # void is Void in a function type: a lambda returning null
                ps = ", ".join(f"a{i}" for i in range(len(ft.params)))
                call = ref.replace("::", ".")
                ref = f"({ps}) -> {{ {call}({ps}); return null; }}"
            self.e.replace(t[start].start, x.end, f"(({ft.java()}) {ref})")

    def find_method(self, name, qual, k):
        f = self.f
        cands = []
        if qual is None:
            encl = sorted((b for b in f.classname if b < k < f.match[b]), reverse=True)
            for b in encl:
                ms = [m for m in f.methods(b) if m["name"] == name]
                if ms:
                    return (ms[0] if len(ms) == 1 else None), f.class_chain(b)
            return None, None
        for b in f.classname:
            if f.classname[b] == qual:
                ms = [m for m in f.methods(b) if m["name"] == name]
                if len(ms) == 1:
                    return ms[0], qual
        m = self.allmethods.get((qual, name))
        return m, qual

    def method_funtype(self, m):
        params = list(m["params"])
        ret = m["ret"]
        if any("->" in p for p in params) or "->" in ret:
            return None
        if m["tparams"]:
            tv = re.compile(r"\b(" + "|".join(m["tparams"]) + r")\b")
            params = [tv.sub("Object", p) for p in params]
            ret = tv.sub("Object", ret)
        self.arities.add(len(params))
        return FunType(params, ret, m["throws"])

    def looks_generic(self, k):
        """Is '<' at k the start of type arguments with a primitive or a
        function type in them?  (Others stay as they are.)"""
        t = self.t
        depth = 0
        for j in range(k, min(len(t), k + 200)):
            x = t[j].text
            if x in ANGLE:
                depth += ANGLE[x]
                if depth <= 0:
                    seg = t[k:j + 1]
                    return any(y.text in PRIMS for y in seg) or \
                        any(self.is_funtype(k + i) for i in range(len(seg)))
            elif x in (";", "{", "}", "=", "&&", "||", "?", ":"):
                return False
            elif x == "(" and not self.is_funtype(j):
                return False
        return False

    def declared(self, end, ft):
        """A function type ended before token end: a declaration?"""
        t = self.t
        while end < len(t) and t[end].kind == "id":
            name = t[end].text
            if t[end + 1].text not in ("=", ";", ",", ")"):
                return
            self.declare(end, name, ft)
            if t[end + 1].text != ",":
                return
            # 'T a, b': only for fields / locals
            if not self.stack_at[end] or t[self.stack_at[end][-1]].text == "(":
                return
            end += 2

    def declare(self, k, name, ft):
        t = self.t
        st = self.stack_at[k]
        if not st:
            return
        b = st[-1]
        if t[b].text == "(":
            # a parameter: of a closure, a method, or a case
            close = self.f.match[b]
            j = close + 1
            if self.arrow(close) is not None:
                # closure params: scope = closure body
                j = self.arrow(close)[0] + 1
                while t[j].text != "{":
                    j += 1
            else:
                while j < len(t) and t[j].text not in ("{", ";"):
                    j += 1
            if t[j].text == "{":
                self.decls.append((name, ft, j, self.f.match[j]))
            if b > 1 and t[b - 2].text == "case":
                self.funfields[name] = ft
            return
        if t[b].text == "{":
            if self.f.kinds.get(b) == "class":
                self.funfields[name] = ft
                self.decls.append((name, ft, b, self.f.match[b]))
            else:
                self.decls.append((name, ft, k, self.f.match[b]))

    def closure(self, k):
        t = self.t
        po = k + 1
        pc = self.f.match[po]
        if self.arrow(pc) is None:
            raise PizzaError(f"{self.f.where(k)}: closure without result type")
        ar, exc = self.arrow(pc)
        params = []
        for a, b in self.split_commas(po + 1, pc):
            j = a
            if t[j].text == "final":
                j += 1
            text, ft, end = self.type_at(j)
            if end != b - 1 or t[end].kind != "id":
                raise PizzaError(f"{self.f.where(a)}: bad closure parameter")
            params.append((text, t[end].text))
            if ft is not None:
                self.declare(end, t[end].text, ft)
        res, rft, end = self.type_at(ar + 1)
        throws = []
        if t[end].text == "throws":
            j = end + 1
            while t[j].text != "{":
                if t[j].kind == "id" and t[j - 1].text != ".":
                    q = j
                    name = t[j].text
                    while t[q + 1].text == ".":
                        name += "." + t[q + 2].text
                        q += 2
                    throws.append(name)
                    j = q
                j += 1
            end = j
        exc = exc or throws
        while t[end].text != "{":
            end += 1
        body = end
        ft = FunType([p for p, _ in params], res, exc)
        self.arities.add(len(params))
        formals, prologue = [], []
        for ty, nm in params:
            if ty in PRIMS:
                formals.append(f"{PRIMS[ty]} {nm}$p")
                prologue.append(f"{ty} {nm} = {nm}$p;")
            else:
                formals.append(f"{ty} {nm}")
        head = f"(({ft.java()}) ({', '.join(formals)}) -> {{ {' '.join(prologue)}"
        void = res == "void"
        if void:
            head += " if (true) {"
        self.e.replace(t[k].start, t[body].end, head)
        close = self.f.match[body]
        self.e.replace(t[close].start, t[close].end,
                       "} return null; })" if void else "})")
        if void:
            self.void_returns(body, close)
        self.closures[body] = ft
        self.closure_spans[body] = (k, close)
        return body + 1

    def void_returns(self, body, close):
        t = self.t
        k = body + 1
        while k < close:
            x = t[k]
            if x.text == "{" and self.f.kinds.get(k) == "class":
                k = self.f.match[k] + 1
                continue
            if x.text == "fun" and t[k + 1].text == "(":
                j = self.f.match[k + 1]
                while t[j].text != "{":
                    j += 1
                k = self.f.match[j] + 1
                continue
            if x.text == "return" and t[k + 1].text == ";":
                self.e.replace(x.start, x.end, "return null")
            k += 1

    def applications(self):
        t = self.t
        for k in range(len(t) - 1):
            x = t[k]
            if x.kind != "id" or t[k + 1].text != "(":
                continue
            prev = t[k - 1] if k else None
            if prev is not None and (prev.kind == "id" and prev.text not in
                                     ("return", "throw", "else", "case")
                                     or prev.text in (">", "]", "new", ">>")):
                continue   # a declaration or 'new'
            ft = None
            if prev is not None and prev.text == ".":
                if x.text in self.funfields and x.text not in self.methods:
                    ft = self.funfields[x.text]
            else:
                for name, dft, lo, hi in self.decls:
                    if name == x.text and lo < k < hi:
                        ft = dft
            if ft is None:
                continue
            self.e.insert(x.end, ".apply")
            if ft.res in PRIMS and ft.res != "void" and prev is not None and prev.text != ".":
                self.e.insert(x.start, f"(({ft.res}) ", order=-1)
                self.e.insert(t[self.f.match[k + 1]].end, ")", order=1)


def fun_interfaces(arities):
    out = {"pizza0/Ref.java": (
        "package pizza0;\n\n/** a local variable that a closure assigns */\n"
        "public final class Ref<T> {\n    public T v;\n"
        "    public Ref(T v) { this.v = v; }\n}\n")}
    for n in sorted(arities):
        tps = ", ".join([f"A{i}" for i in range(1, n + 1)] + ["R"])
        ps = ", ".join(f"A{i} a{i}" for i in range(1, n + 1))
        out[f"pizza0/Fun{n}.java"] = (
            "package pizza0;\n\n/** a Pizza function type, for the boot compiler */\n"
            f"public interface Fun{n}<{tps}> {{\n    R apply({ps});\n}}\n")
        out[f"pizza0/Fun{n}X.java"] = (
            "package pizza0;\n\n/** a Pizza function type with a throws clause */\n"
            f"public interface Fun{n}X<{tps}, E extends Throwable> {{\n"
            f"    R apply({ps}) throws E;\n}}\n")
    return out


def main(argv):
    srcroot, outroot = argv[1], argv[2]
    files = argv[3:]
    world = World()
    infos = []
    srcs = {}
    for rel in files:
        with open(os.path.join(srcroot, rel), encoding="latin-1") as fh:
            srcs[rel] = fh.read()
    # higher-order functions first; twice, the second time knowing the
    # function-typed fields of all files
    funfields, methods, arities = {}, set(), set()
    allmethods = {}
    functions = False
    for rel in files:
        fi = FileInfo(rel, srcs[rel])
        functions = functions or any(x.text == "->" for x in fi.toks)
        for b in fi.classname:
            ms = fi.methods(b)
            methods.update(m["name"] for m in ms)
            for m in ms:
                key = (fi.classname[b], m["name"])
                allmethods[key] = None if key in allmethods else m
    for rnd in (0, 1):
        out = {}
        for rel in files:
            pp = Prepass(FileInfo(rel, srcs[rel]), funfields, methods, allmethods, functions)
            try:
                out[rel] = pp.run()
            except PizzaError as ex:
                if rnd:
                    print(f"error: {ex}", file=sys.stderr)
                    return 1
            arities |= pp.arities
    srcs = out
    for rel in files:
        fi = FileInfo(rel, srcs[rel])
        world.add_file(fi)
        infos.append(fi)
    world.link()
    errors = 0
    for fi in infos:
        try:
            out = Translator(world, fi).run()
        except PizzaError as ex:
            print(f"error: {ex}", file=sys.stderr)
            errors += 1
            continue
        for rel, text in split_public(re.sub(r"\.pizza$", ".java", fi.rel), out):
            dest = os.path.join(outroot, rel)
            os.makedirs(os.path.dirname(dest), exist_ok=True)
            with open(dest, "w", encoding="latin-1") as fh:
                fh.write(text)
    for rel, text in fun_interfaces(arities).items():
        dest = os.path.join(outroot, rel)
        os.makedirs(os.path.dirname(dest), exist_ok=True)
        with open(dest, "w") as fh:
            fh.write(text)
    return 1 if errors else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
