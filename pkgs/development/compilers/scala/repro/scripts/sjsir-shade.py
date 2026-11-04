#!/usr/bin/env python3
"""sjsir-shade.py OUT DIR...: the scalajs-ir sources of DIR... as scala3's build unpacks them into
src_managed/main/scalajs-ir-src (Build.scala, scala3-compiler-bootstrapped): read with sbt's
IO.readLines, the first `package` line rewritten by Shading.replacePackage (org.scalajs.ir ->
dotty.tools.sjs.ir), written with IO.writeLines (each line + "\\n")."""
import os, re, sys

out, *dirs = sys.argv[1:]
for d in dirs:
    for root, _, fs in os.walk(d):
        for f in fs:
            if not f.endswith(".scala"):
                continue
            s = open(os.path.join(root, f), encoding="utf-8", newline="").read()
            lines = re.split(r"\r\n|\r|\n", s)
            if lines and lines[-1] == "" and s:  # BufferedReader.readLine: no empty last line
                lines.pop()
            for i, l in enumerate(lines):
                if l.startswith("package "):
                    name = l[len("package "):].strip()
                    lines[i] = "package " + ("dotty.tools.sjs.ir" if name == "org.scalajs.ir" else name)
                    break
            dst = os.path.join(out, os.path.relpath(os.path.join(root, f), d))
            os.makedirs(os.path.dirname(dst), exist_ok=True)
            with open(dst, "w", encoding="utf-8", newline="") as o:
                o.write("".join(l + "\n" for l in lines))
