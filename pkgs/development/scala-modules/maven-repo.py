#!/usr/bin/env python3
"""maven-repo INDEX.json OUT: a Maven repository layout of the jars in INDEX, with POMs."""
import json
import os
import shutil
import sys
from xml.sax.saxutils import escape

index, out = sys.argv[1:]
for e in json.load(open(index)):
    g, a, v = e["group"], e["artifact"], e["version"]
    d = os.path.join(out, *g.split("."), a, v)
    os.makedirs(d, exist_ok=True)
    shutil.copy(e["jar"], os.path.join(d, f"{a}-{v}.jar"))
    if e.get("sources"):
        shutil.copy(e["sources"], os.path.join(d, f"{a}-{v}-sources.jar"))
    deps = "".join(
        f"""    <dependency>
      <groupId>{escape(x["group"])}</groupId>
      <artifactId>{escape(x["artifact"])}</artifactId>
      <version>{escape(x["version"])}</version>
    </dependency>
"""
        for x in e["deps"]
    )
    with open(os.path.join(d, f"{a}-{v}.pom"), "w") as f:
        f.write(f"""<?xml version="1.0" encoding="UTF-8"?>
<project xmlns="http://maven.apache.org/POM/4.0.0">
  <modelVersion>4.0.0</modelVersion>
  <groupId>{escape(g)}</groupId>
  <artifactId>{escape(a)}</artifactId>
  <version>{escape(v)}</version>
  <packaging>jar</packaging>
  <dependencies>
{deps}  </dependencies>
</project>
""")
