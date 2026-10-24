#!/usr/bin/env python3
"""default-imports.txt and api-mapping.txt of gradle-runtime-api-info.jar, from the Java sources of the public API.

usage: gen-api-info.py <out-dir> <source-dir>...
Replicates ExtractDslMetaDataTask + GenerateDefaultImports + GenerateApiMapping of Gradle's own build:
top level types of the public API packages (PublicApi.includes/excludes), sorted by class name.
"""
import os
import re
import sys

out = sys.argv[1]
includes = """org/gradle/* org/gradle/api/** org/gradle/authentication/** org/gradle/build/** org/gradle/buildconfiguration/**
org/gradle/buildinit/** org/gradle/caching/** org/gradle/concurrent/** org/gradle/deployment/** org/gradle/external/javadoc/**
org/gradle/ide/** org/gradle/ivy/** org/gradle/jvm/** org/gradle/language/** org/gradle/maven/** org/gradle/nativeplatform/**
org/gradle/normalization/** org/gradle/platform/** org/gradle/plugin/devel/** org/gradle/plugin/use/* org/gradle/plugin/management/*
org/gradle/plugins/** org/gradle/process/** org/gradle/testfixtures/** org/gradle/testing/jacoco/** org/gradle/tooling/**
org/gradle/swiftpm/** org/gradle/model/** org/gradle/testkit/** org/gradle/testing/** org/gradle/vcs/** org/gradle/work/**
org/gradle/workers/** org/gradle/util/**""".split()
pats = []
for i in includes:
    if i.endswith("/**"):
        pats.append(re.compile(re.escape(i[:-3].replace("/", ".")) + r"(\..+)?"))
    else:
        pats.append(re.compile(re.escape(i[:-2].replace("/", ".")) + r"\.[^.]+"))
internal = re.compile(r".+\.internal(\..+)?")
# GradleUserManualPlugin.getDefaultExcludedPackages()
excluded = {"org.gradle.tooling", "org.gradle.testfixtures", "org.gradle.plugins.ide.eclipse.model",
            "org.gradle.plugins.ide.idea.model", "org.gradle.api.tasks.testing.logging", "org.gradle.plugins.binaries.model"}
excluded_prefixes = ["org.gradle.tooling.", "org.gradle.testfixtures."]
decl = re.compile(r"^(?:(?:public|abstract|final|sealed|non-sealed|static|strictfp)\s+)*(?:@interface|class|interface|enum|record)\s+(\w+)", re.M)

classes = {}
for root in sys.argv[2:]:
    for dp, _, fs in os.walk(root):
        for f in fs:
            if not f.endswith(".java") or f in ("package-info.java", "module-info.java"):
                continue
            pkg = os.path.relpath(dp, root).replace(os.sep, ".")
            if not any(p.fullmatch(pkg) for p in pats) or internal.fullmatch(pkg):
                continue
            if pkg in excluded or any(pkg.startswith(x) for x in excluded_prefixes):
                continue
            text = open(os.path.join(dp, f), encoding="utf-8", errors="replace").read()
            text = re.sub(r"/\*.*?\*/", "", text, flags=re.S)
            for m in decl.finditer(text):
                classes[pkg + "." + m.group(1)] = (pkg, m.group(1))

os.makedirs(out, exist_ok=True)
with open(os.path.join(out, "default-imports.txt"), "w") as w:
    seen = []
    for cn in sorted(classes):
        pkg = classes[cn][0]
        if pkg not in seen:
            seen.append(pkg)
            w.write(f"import {pkg}.*\n")
with open(os.path.join(out, "api-mapping.txt"), "w") as w:
    names = {}
    for cn in sorted(classes):
        names.setdefault(classes[cn][1], []).append(cn)
    for n, cns in names.items():
        w.write(n + ":" + "".join(c + ";" for c in cns) + "\n")
