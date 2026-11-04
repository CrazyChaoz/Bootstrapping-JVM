#!/usr/bin/env python3
"""props.py library-properties VERSION YEAR | compiler-properties VERSION GITHASH YEAR
         | manifest NAME VERSION [ATTRIBUTE=VALUE...]

library.properties as project/LibraryProperties.scala's content(version, year), and the
MANIFEST.MF sbt writes for an org.scala-lang project (packageOptions of Build.scala: the
Specification-/Implementation- attributes of sbt's defaults, homepage, Automatic-Module-Name)."""
import sys

def library_properties(version, year):
    banner = ("%n      ________ ___   / /  ___"
              "%n    / __/ __// _ | / /  / _ |"
              "%n  __\\\\ \\\\/ /__/ __ |/ /__/ __ |"
              "%n /____/\\\\___/_/ |_/____/_/ | |"
              "%n                          |/  %s")
    return (f"version.number={version}\nmaven.version.number={version}\n"
            f"copyright.string=Copyright 2002-{year}, LAMP/EPFL\nshell.banner={banner}\n")

def compiler_properties(version, githash, year):
    return (f"version.number={version}\nmaven.version.number={version}\ngit.hash={githash}\n"
            f"copyright.string=Copyright 2002-{year}, LAMP/EPFL\n")

def manifest(name, version, *extra):
    attrs = [("Manifest-Version", "1.0"), ("Specification-Title", name), ("Specification-Version", version),
             ("Specification-Vendor", "LAMP/EPFL"), ("Implementation-Title", name),
             ("Implementation-Version", version), ("Implementation-Vendor", "LAMP/EPFL"),
             ("Implementation-Vendor-Id", "org.scala-lang"), ("Implementation-URL", "https://scala-lang.org/")]
    attrs += [tuple(e.split("=", 1)) for e in extra]
    return "".join(f"{k}: {v}\r\n" for k, v in attrs) + "\r\n"

if sys.argv[1] == "library-properties": sys.stdout.write(library_properties(*sys.argv[2:4]))
elif sys.argv[1] == "compiler-properties": sys.stdout.write(compiler_properties(*sys.argv[2:5]))
else: sys.stdout.write(manifest(*sys.argv[2:]))
