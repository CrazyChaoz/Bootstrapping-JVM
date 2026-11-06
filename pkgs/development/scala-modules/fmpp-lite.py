#!/usr/bin/env python3
"""fmpp-lite TEMPLATE > OUT: expands the FreeMarker subset of sbinary's fmpp templates.

Directives: <#list A..B as x>...</#list> (A, B integers or names), <#assign n>...</#assign>,
<#if x != y>...</#if>, and ${name} interpolations.  Anything else is an error, so that a
template using more of FreeMarker fails loudly instead of expanding wrongly.
"""
import re
import sys

TOKEN = re.compile(r"<#(list|assign|if)\s+([^>]*)>|</#(list|assign|if)>|\$\{([^}]*)\}")


def parse(text):
    """-> list of nodes: str | ('var', name) | (kind, arg, children)"""
    root = []
    stack = [("root", None, root)]
    pos = 0
    for m in TOKEN.finditer(text):
        stack[-1][2].append(text[pos:m.start()])
        pos = m.end()
        if m.group(1):
            node = (m.group(1), m.group(2).strip(), [])
            stack[-1][2].append(node)
            stack.append(node)
        elif m.group(3):
            if stack[-1][0] != m.group(3):
                sys.exit(f"fmpp-lite: </#{m.group(3)}> closes <#{stack[-1][0]}>")
            stack.pop()
        else:
            stack[-1][2].append(("var", m.group(4).strip()))
    if len(stack) != 1:
        sys.exit(f"fmpp-lite: unclosed <#{stack[-1][0]}>")
    if "<#" in text[pos:]:
        sys.exit("fmpp-lite: unsupported directive")
    root.append(text[pos:])
    return root


def value(expr, env):
    expr = expr.strip()
    if re.fullmatch(r"\d+", expr):
        return int(expr)
    if expr not in env:
        sys.exit(f"fmpp-lite: unknown name {expr!r}")
    return env[expr]


def render(nodes, env):
    out = []
    for n in nodes:
        if isinstance(n, str):
            out.append(n)
        elif n[0] == "var":
            out.append(str(value(n[1], env)))
        elif n[0] == "list":
            m = re.fullmatch(r"(\w+)\.\.(\w+)\s+as\s+(\w+)", n[1])
            if not m:
                sys.exit(f"fmpp-lite: unsupported list {n[1]!r}")
            for i in range(value(m.group(1), env), value(m.group(2), env) + 1):
                out.append(render(n[2], {**env, m.group(3): i}))
        elif n[0] == "assign":
            if not re.fullmatch(r"\w+", n[1]):
                sys.exit(f"fmpp-lite: unsupported assign {n[1]!r}")
            env[n[1]] = render(n[2], env)
        elif n[0] == "if":
            m = re.fullmatch(r"(\w+)\s*!=\s*(\w+)", n[1])
            if not m:
                sys.exit(f"fmpp-lite: unsupported condition {n[1]!r}")
            if value(m.group(1), env) != value(m.group(2), env):
                out.append(render(n[2], env))
    return "".join(out)


if __name__ == "__main__":
    sys.stdout.write(render(parse(open(sys.argv[1], encoding="utf-8").read()), {}))
