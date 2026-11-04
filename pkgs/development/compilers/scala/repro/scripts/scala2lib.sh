#!/usr/bin/env bash
# scala2lib.sh OUT: upstream's scala2-library project: the 2.13.18 library sources (v2.13.18's
# src/library; the sources jar's library-aux files are all excluded) by the chain's scalac 2.13.18
# (s230), Java by javac 17
set -euo pipefail
. "$(dirname "$0")/env.sh"
OUT=$(realpath -m "$1"); rm -rf "$OUT"; mkdir -p "$OUT"
cd "$SRC2/src/library"
find "$PWD/scala" \( -name "*.scala" -o -name "*.java" \) | LC_ALL=C sort > "$OUT.srcs"
"$JDK17/bin/java" -Xss16m -Xmx4g -cp "$S230/out2:$S230/classes" scala.tools.nsc.Main \
  -feature -deprecation -unchecked -Werror \
  "-Wconf:msg=package scala contains object and package with same name:i" \
  "-Wconf:src=scaladoc-testcases/.*:s" "-Wconf:src=presentation-compiler-testcases/.*:s" \
  "-Wconf:msg=The RHS of reassignment must be transitively initialized:i" \
  "-Wconf:msg=Could not verify that the method argument is transitively initialized:i" \
  "-Wconf:msg=may cause initialization errors:i" \
  "-Wconf:cat=deprecation&origin=scala\\.collection\\.Iterable\\.stringPrefix:s" \
  -encoding UTF8 -language:implicitConversions \
  -release:17 "-sourcepath:$SRC2/src/library" -opt:local \
  -classpath "$OUT:$S230/quick/lib" -d "$OUT" @"$OUT.srcs"
grep '\.java$' "$OUT.srcs" > "$OUT.java"
"$JDK17/bin/javac" -Xlint:unchecked -Xlint:deprecation --release 17 -nowarn -classpath "$OUT" -d "$OUT" @"$OUT.java" 2>&1 | tail -5
