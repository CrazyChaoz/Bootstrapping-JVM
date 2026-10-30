#!/usr/bin/env bash
# scala1.sh TREE OUT PREV : a Scala 1.x tree (2004-2005), built module by module in the order
# of its Makefile (config/list/*.lst): the Java (Pizza) parts by tools/pizza2java.py + javac,
# the Scala parts by the previous stage's compiler; then the Scala parts again by the new
# compiler itself (out2/: what the next stage runs).
#
# COMPILER_FIRST=1: for a flag day, when the new library needs the new compiler (Int.box,
# 2004-2005): all Java first, then the compiler's Scala parts by the previous compiler
# against the previous library, then the library by the new compiler.
#
# Inputs (besides those of common.sh): FJBG_SRC and MSIL_SRC, the class file libraries of
# the JVM and .NET backends (src/fjbg and src/msil of 2009; MSIL for the class file reader
# only), RT14 (the Java 1.4 API, tools/jdk-api-view.py).
set -euo pipefail
. "$(dirname "$(readlink -f "$0")")/common.sh"
require FJBG_SRC MSIL_SRC RT14
TREE=$1 W=$2 PREV=$3
# (the first stage's layout: sc2/ and lib2/)
if [ -d "$PREV/sc2" ]; then PREVCP=$PREV/sc2:$PREV/lib2:$PREV/classes; else PREVCP=$PREV/out2:$PREV/classes; fi
rm -rf "$W"; mkdir -p "$W"; cd "$W"
cp -r "$TREE/sources" src
cp -r "$FJBG_SRC" fjbg
cp -r "$MSIL_SRC/." fjbg/
# (not needed by the compiler, and not compilable here: VJSAssembly uses J# types)
rm -rf fjbg/ch/epfl/lamp/compiler/msil/tests fjbg/ch/epfl/lamp/compiler/msil/util/VJSAssembly.java
L=$TREE/config/list
mkdir -p classes out stubs
. "$HERE/scala1-patches.sh"

# --- the meta programs generate Tree.java, Function*.java, ...
mkdir -p meta-cls
python3 -I "$T/pizza2java.py" src meta-java $(cd src && find meta -name '*.java' | sort)
javac8 -encoding latin1 -d meta-cls $(find meta-java -name '*.java' | sort)
"$JDK21/bin/java" -cp meta-cls meta.GenerateAll src generated.lst > /dev/null

lst() { # lst MODULE ROOT : the files config/list/MODULE.lst names (under src/ROOT) that exist
  [ -f "$L/$1.lst" ] || return 0
  grep -v '^#' "$L/$1.lst" | sed 's/\s*$//' | grep . | sed "s|^|$2/|" | python3 -c '
import os, sys
for l in sys.stdin:
    p = os.path.normpath(l.strip())
    if os.path.exists(os.path.join("src", p)) or p.endswith(".java") and os.path.exists(os.path.join("src", p + ".tmpl")):
        print(p)
    else:
        print("warning: listed file missing:", p, file=sys.stderr)'
}
# java2class SRCLIST META CP OUT : Pizza sources of SRCLIST to Java (META: what the Pizza compiler
# would have written into the class files), compiled into OUT
java2class() {
  rm -rf "java-$1"
  python3 -I "$T/pizza2java.py" src "java-$1" --classpath-src fjbg --classpath-src src --stub '/CLR[A-Za-z]*\.java$' \
    --meta-out "$1.meta.json" $(cat "$2")
  javac8 -encoding latin1 -cp "$3" -d "$4" $(find "java-$1" -name '*.java' | sort) > "$1.javac.log" 2>&1 || { cat "$1.javac.log"; exit 1; }
  python3 -I "$T/pico-classfiles.py" "$4" "$1.meta.json"
}
scalac() { # scalac CP ARGS... : the compiler on CP
  "$JDK8/bin/java" -Xss64m -Xmx2g -cp "$1" scala.tools.scalac.Main -bootclasspath "$RT14" "${@:2}"
}

javac8 -encoding latin1 -d classes $(find fjbg stubs -name '*.java' | sort)
modules="lamplib:ch/epfl/lamp library:scala util:scala/tools/util compiler:scalac scalac:scala/tools/scalac"
for m in $modules; do
  name=${m%%:*} root=${m#*:}
  lst "$name" "$root" | { grep -v -i 'backend/msil' || true; } > "$name.files"
  grep '\.java$' "$name.files" > "$name.jfiles" || true
  grep '\.scala$' "$name.files" | sed 's|^|src/|' > "$name.sargs" || true
  echo "== $name: $(wc -l < "$name.jfiles") java, $(wc -l < "$name.sargs") scala"
done

if [ -n "${COMPILER_FIRST:-}" ]; then
  mkdir -p jout cout lout jcomp
  cat lamplib.jfiles library.jfiles util.jfiles compiler.jfiles scalac.jfiles > all.jfiles
  java2class all all.jfiles "classes:$PREVCP" jout
  # the compiler's Java classes without the new library's (package scala, but scala.tools):
  # the previous compiler compiles against the previous library
  cp -r jout/. jcomp/
  find jcomp/scala -mindepth 1 -maxdepth 1 ! -name tools -exec rm -rf {} +
  echo "== compiler (Scala) by the previous compiler"
  oldsrc "$PREV/src" prevsrc
  scalac "$PREVCP" -d cout -classpath "cout:jcomp:classes:$PREVCP:$PWD/prevsrc" $(cat util.sargs scalac.sargs)
  echo "== library by the new compiler"
  scalac "cout:jcomp:classes:$PREVCP" -d lout -classpath lout:jout:classes:src $(cat library.sargs)
  cp -r jout/. out/; cp -r lout/. out/; cp -r cout/. out/
else
  mkdir -p jout
  for m in $modules; do
    name=${m%%:*}
    [ -s "$name.files" ] || continue
    if [ -s "$name.jfiles" ]; then
      java2class "$name" "$name.jfiles" out:classes jout
      cp -r jout/. out/
    fi
    [ ! -s "$name.sargs" ] || scalac "$PREVCP" -d out -classpath out:classes:src $(cat "$name.sargs")
  done
fi

echo "== self-host"
mkdir -p out2
cp -r jout/. out2/
for m in $modules; do
  name=${m%%:*}
  [ ! -s "$name.sargs" ] || scalac out:classes -d out2 -classpath out2:classes:src $(cat "$name.sargs")
done
echo "stage done"
