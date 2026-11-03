#!/usr/bin/env python3
"""Runs GenerateKotlinDependencyExtensions of Gradle's build-logic: expands the file templates of the task.

usage: gen-kotlin-dependency-extensions.py <gradle-src> <out-dir> <embedded-kotlin-version> <kotlin-dsl-plugins-version>
"""
import os
import re
import sys

src, out, kotlin, plugins = sys.argv[1:5]
gen = open(os.path.join(src, "build-logic/kotlin-dsl/src/main/kotlin/gradlebuild/kotlindsl/generator/tasks/GenerateKotlinDependencyExtensions.kt")).read()
hdr = open(os.path.join(src, "build-logic/kotlin-dsl-shared-runtime/src/main/kotlin/org/gradle/kotlin/dsl/internal/sharedruntime/codegen/SourceFileHeader.kt")).read()
m = re.search(r'LICENSE_HEADER[^=]*=\s*"""(.*?)"""', hdr, re.S)
license_header = m.group(1) if m else ""
license_header = license_header.replace("${'$'}", "$")

for m in re.finditer(r'writeFile\(\s*"([^"]+)",\s*"""(.*?)"""\s*\)', gen, re.S):
    path, text = m.groups()
    text = text.replace("$LICENSE_HEADER", license_header)
    text = text.replace("${embeddedKotlinVersion}", kotlin).replace("$embeddedKotlinVersion", kotlin)
    text = text.replace("$kotlinDslPluginsVersion", plugins)
    text = text.replace("${'$'}", "$")
    dest = os.path.join(out, path)
    os.makedirs(os.path.dirname(dest), exist_ok=True)
    with open(dest, "w") as f:
        f.write(text)
