#!/usr/bin/env bash
# nsc0.sh TREE OUT PREV : the first Scala 2 compiler, nsc ("new Scala compiler", written in
# Scala), at the state of 2005-12 (ac84922849~1), built the way SABBUS did: nsc by the old
# Scala 1.4 compiler of stage PREV (osc), then the new library and nsc again by that nsc.
#
# OUT gets the layout of the Scala 2 stages: out2/ (library + compiler), classes/ (their Java
# dependencies: FJBG and the MSIL reader as the previous stage built them).
#
# Inputs (besides those of common.sh): RT14 (the Java 1.4 API, tools/jdk-api-view.py).
set -euo pipefail
. "$(dirname "$(readlink -f "$0")")/common.sh"
require RT14
TREE=$1 W=$2 OSC=$3
OSCCP=$OSC/out2:$OSC/classes
rm -rf "$W"; mkdir -p "$W"; cd "$W"
oldsrc "$OSC/src" oscsrc
cp -r "$TREE/sources" src
cp -r "$TREE/newsources" newsrc
mkdir -p fjbg-cls pnslib osc-nstools nslib nstools
. "$HERE/nsc-patches.sh"
cp -r "$OSC/classes/." fjbg-cls/

# (all source lists sorted: the old compilers are sensitive to the order of their sources, and
# find's order is the file system's)

# 1. pico-nslib: the Java parts of the new library
( cd src; find scala/runtime -name '*.java'; find scala/tools/util -maxdepth 1 -name '*.java'; ls scala/*.java ) | sort > pnslib.files
pico -classpath fjbg-cls -d pnslib $(sed 's|^|src/|' pnslib.files)
# (without what newsources/ replaces by Scala sources)
for b in $(cd newsrc/scala && ls *.scala | sed 's/\.scala$//'); do rm -f "pnslib/scala/$b.class" "pnslib/scala/$b\$"*.class; done

# 2. osc-nstools: nsc compiled by the old compiler
( cd src
  find scala/tools/nsc $(ls -d scala/tools/scalap 2>/dev/null) scala/reflect -name '*.scala' | grep -v '/ant/'
  ls scala/runtime/*.scala; find scala/runtime -mindepth 2 -name '*.scala'
) | LC_ALL=C sort | sed 's|^|src/|' > osc.files
echo "== osc-nstools ($(wc -l < osc.files) files)"
"$JDK8/bin/java" -Xss64m -Xmx2g -cp "$OSCCP" scala.tools.scalac.Main -bootclasspath "$RT14" \
  -d osc-nstools -classpath "osc-nstools:$OSCCP:$PWD/oscsrc" $(cat osc.files)
nsc() { "$JDK8/bin/java" -Xss64m -Xmx2g -cp "osc-nstools:$OSCCP" scala.tools.nsc.Main -bootclasspath "$RT14" "$@"; }

# 3. nslib, the new library, by that nsc: Predef and ScalaRunTime first, without predefs
echo "== nslib (Predef, ScalaRunTime)"
nsc -nopredefs -d nslib -classpath pnslib:nslib:src:newsrc:fjbg-cls src/scala/Predef.scala src/scala/runtime/ScalaRunTime.scala
( cd src; find scala -name '*.scala' | grep -v '^scala/tools/\|^scala/dbc/' | grep -v '^scala/Predef.scala$\|^scala/runtime/ScalaRunTime.scala$' | LC_ALL=C sort ) | sed 's|^|src/|' > nslib.files
echo "== nslib ($(wc -l < nslib.files) files)"
nsc -d nslib -classpath pnslib:nslib:src:newsrc:fjbg-cls $(cat nslib.files)

# 4. nstools, nsc again, by that nsc
( cd src; find scala/tools/nsc -name '*.scala' | grep -v '/ant/' | LC_ALL=C sort ) | sed 's|^|src/|' > nstools.files
echo "== nstools ($(wc -l < nstools.files) files)"
nsc -d nstools -classpath pnslib:nslib:nstools:fjbg-cls $(cat nstools.files)

mkdir -p out2 classes
cp -r pnslib/. out2/; cp -r nslib/. out2/; cp -r nstools/. out2/; cp -r fjbg-cls/. classes/
echo "stage done"
