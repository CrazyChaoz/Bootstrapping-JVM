#!/usr/bin/env bash
# dotty.sh TREE OUT PREV : a dotty (Scala 3) tree, scala/scala3, built by the previous stage's
# compiler.  PREV is a Scala 2 stage (out2/: library and compiler) for the first tree, of
# 2019-04, whose build still used Scala 2.12; then a dotty stage, the reference compiler the
# tree names (referenceVersion in project/Build.scala, later project/Versions.scala).
#
# OUT gets:
#   deps/        the external Java inputs: scala-asm or ASM, zinc's compiler-interface (with
#                sbt's util-interface), jline 3 (reader, terminal)
#   interfaces/  dotty-interfaces
#   lib0/        dotty-library, compiled by PREV: the library the new compiler runs on
#   tasty/       tasty-core (2019-12 on)
#   comp/        dotty-compiler
#   lib/         dotty-library again, by the new compiler, as released: what programs (and the
#                next stage) compile against, since TASTy versions change between stages
#   scala2lib    (a link) the Scala 2 library the stage runs on; scala2lib-boot, if any, the
#                one lib/ was compiled against
#   jvm          the java to run the compiler with
#
# Inputs (besides those of common.sh):
#   SCALA2LIB        the Scala 2 stage whose library the stage builds on
#   SCALA2LIB_BOOT   (optional) the Scala 2 stage whose library lib/ builds on, where the
#                    build names another one for it (stdlibVersion Bootstrapped: 2.13.0 in
#                    2019-08, against 2.12.8 for the rest)
#   DOTTY_VERSION    the version the compiler reports
#   ASM_SRCS OW2ASM_SRCS ZINC_SRCS SBTUTIL_SRCS JLINE3_SRCS SCALAJS_SRCS
#                    source trees by version (scala-asm, ASM, zinc, sbt's util, jline 3,
#                    Scala.js), of which the stage takes those its build names (tools/dotty-deps)
set -euo pipefail
. "$(dirname "$(readlink -f "$0")")/common.sh"
require SCALA2LIB DOTTY_VERSION ASM_SRCS OW2ASM_SRCS ZINC_SRCS SBTUTIL_SRCS JLINE3_SRCS SCALAJS_SRCS
TREE=$1 OUT=$2 PREV=$3
mkdir -p "$OUT"; cd "$OUT"
cp -r "$TREE/." tree; TREE=$OUT/tree
bld=$TREE/project/Build.scala
scalacOpts="-nowarn -encoding UTF8 -language:existentials,higherKinds,implicitConversions"

# The JVM the library's Java sources want (3.8 on: 17, java.lang.invoke.VarHandle): then the
# compilers run on JDK 21 and javac compiles for it; the Scala output stays at the default
# target (8), and the older compilers run on JDK 8
rel=$(sed -n 's/.*val minimumJVMVersion = "\([0-9]*\)".*/\1/p' "$TREE/project/Versions.scala" 2>/dev/null || true); rel=${rel:-8}
jvm=$JDK8/bin/java; [ "$rel" -le 8 ] || jvm=$JDK21/bin/java
echo "$jvm" > jvm
JAVA="$jvm -Xss16m -Xmx4g"
javac() { "$JDK21/bin/javac" -nowarn --release "$rel" -encoding utf8 "$@"; }

# What compiles the tree: the Scala 2 compiler or the previous dotty
S2=$SCALA2LIB/out2
if [ -d "$PREV/out2/scala/tools/nsc" ]; then
  KIND=scala2
  compile() { $JAVA -cp "$PREV/out2:$PREV/classes" scala.tools.nsc.Main $scalacOpts "$@"; }
else
  KIND=dotty
  pcp=$PREV/comp:$PREV/lib0:$PREV/tasty:$PREV/interfaces:$PREV/deps:$PREV/scala2lib
  compile() { $JAVA -cp "$pcp" dotty.tools.dotc.Main $scalacOpts "$@"; }
fi
# From 3.7 the Scala 2 library's sources are part of library/src (RedBlackTree is one): the
# stage's own library is the whole standard library, and no Scala 2 library may be on the class
# paths (its specialized Tuple2 subclasses would extend the final scala.Tuple2 of the new library)
if [ -f "$TREE/library/src/scala/collection/immutable/RedBlackTree.scala" ]; then
  mkdir scala2lib-none; S2=$PWD/scala2lib-none
fi
ln -s "$S2" scala2lib
S2B=$S2
if [ "$S2" = "$SCALA2LIB/out2" ] && [ -n "${SCALA2LIB_BOOT:-}" ] && [ "$SCALA2LIB_BOOT" != "$SCALA2LIB" ]; then
  S2B=$SCALA2LIB_BOOT/out2; ln -s "$S2B" scala2lib-boot
fi

# --- the external inputs, the versions the build names
python3 -I "$T/dotty-deps" "$TREE" > deps.versions
dv() { # dv KEY DIR : DIR/VERSION, the version of KEY in deps.versions
  local v; v=$(sed -n "s/^$1 //p" deps.versions)
  [ -n "$v" ] && [ -d "$2/$v" ] || { echo "no $1 ${v:-version} in $2" >&2; exit 1; }
  echo "$2/$v"
}
ZINC_SRC=$(dv zinc "$ZINC_SRCS"); JLINE3_SRC=$(dv jline "$JLINE3_SRCS"); SCALAJS_SRC=$(dv scalajs "$SCALAJS_SRCS")
# (util-interface: the sbt util version zinc's build names)
uv=$(sed -n 's/.*utilVersion = \(nightlyVersion.getOrElse(\)\?"\([^"]*\)".*/\2/p' "$ZINC_SRC/project/Dependencies.scala" | head -1)
SBTUTIL_SRC=$SBTUTIL_SRCS/$uv; [ -d "$SBTUTIL_SRC" ] || { echo "no sbt util-interface $uv" >&2; exit 1; }
# (the backend uses scala-asm, from 2026 ASM itself: org.objectweb.asm)
if grep -q '^ow2asm ' deps.versions; then
  a=$(dv ow2asm "$OW2ASM_SRCS"); asmdirs=$(for m in asm asm-tree asm-analysis asm-util asm-commons; do echo "$a/$m/src/main/java/"; done)
else
  asmdirs=$(dv asm "$ASM_SRCS")/
fi
# (jline: no JNA/jansi terminals; its native/ module from 3.24)
jlinedirs="$JLINE3_SRC/reader/src/main/java/ $JLINE3_SRC/terminal/src/main/java/"
[ ! -d "$JLINE3_SRC/native/src/main/java" ] || jlinedirs="$jlinedirs $JLINE3_SRC/native/src/main/java/"
mkdir -p deps
{ find $asmdirs -name '*.java' ! -name module-info.java
  find "$SBTUTIL_SRC/internal/util-interface/src/main/java/" -name '*.java'
  find "$ZINC_SRC/internal/compiler-interface/src/main/java/" "$ZINC_SRC/internal/compiler-interface/src/main/contraband-java/" -name '*.java'
  find $jlinedirs -name '*.java' ! -name module-info.java
} | sort > deps.files
# (by JDK 8's javac where the compilers run on JDK 8: javac 21's MethodParameters without names
# break Scala 2's class file reader)
if [ "$rel" -le 8 ]; then javacDeps="$JDK8/bin/javac -nowarn -encoding utf8"; else javacDeps="javac"; fi
$javacDeps -d deps @deps.files > deps.log 2>&1 || { cat deps.log; exit 1; }
for r in "$JLINE3_SRC/reader/src/main/resources" "$JLINE3_SRC/terminal/src/main/resources"; do
  [ ! -d "$r" ] || cp -r "$r/." deps/
done

# --- dotty-interfaces (Java)
mkdir -p interfaces
"$JDK8/bin/javac" -nowarn -d interfaces $(find "$TREE/interfaces/src" -name '*.java' | sort)

# --- dotty-library, by PREV: src, the sources for the compiler kind (src-2.x / src-3.x, 2019-04
# on) and src-non-bootstrapped (what the reference compiler compiles)
mkdir -p lib0
x=$TREE/library/src-$([ $KIND = scala2 ] && echo 2 || echo 3).x
extra=$TREE/library/src-non-bootstrapped; [ ! -d "$x" ] || extra="$x $extra"
find "$TREE/library/src" $extra -name '*.scala' -o -name '*.java' | sort > lib.files
lopts=$(sed -n 's/^libopts //p' deps.versions)
# (-sourcepath as the build has it: library/src (scalaSource), from 2020-01 all source directories)
if grep -qE '"-sourcepath", \((Compile / )?sourceDirectories' "$bld"; then
  srcpath() { echo "$TREE/library/src" $extra | tr ' ' :; }
else
  srcpath() { echo "$TREE/library/src"; }
fi
echo "== library ($KIND)"
lcp=$S2
if [ $KIND = dotty ]; then
  # A dotty compiles the library with its own released library on the class path, without what
  # would clash with or shadow the new sources (tools/dotty-reflib): refboot; the non-bootstrapped
  # sources use parts only src-bootstrapped defines (scala.IArray, 2019-08).  lib0 gets all of it
  # but what this run compiles (refall): nested classes of what it compiles differently,
  # TreeUtils$TreeMap 2019-08, are what the new compiler is compiled against.
  python3 -I "$T/dotty-reflib" "$PREV/lib" refboot "$TREE/library" "$TREE/library/src" $extra
  python3 -I "$T/dotty-reflib" "$PREV/lib" refall "$TREE/library"
  lcp=refboot:$S2
  compile -d lib0 -classpath "$lcp" -sourcepath "$(srcpath)" $lopts @lib.files
else
  compile -d lib0 -classpath "$lcp" @lib.files
fi
jl=$(grep '\.java$' lib.files || true)
[ -z "$jl" ] || javac -cp "lib0:$lcp" -d lib0 $jl
[ ! -d refall ] || cp -rn refall/. lib0/

# --- tasty-core (the TASTy format, a project of its own from 2019-12), by PREV
mkdir -p tasty
if [ -d "$TREE/tasty/src" ]; then
  echo "== tasty-core ($KIND)"
  compile -d tasty -classpath "lib0:$S2" $(find "$TREE/tasty/src" $([ ! -d "$TREE/tasty/src-non-bootstrapped" ] || echo "$TREE/tasty/src-non-bootstrapped") -name '*.scala' | sort)
fi

# --- dotty-compiler, by PREV (src-non-bootstrapped: what the reference compiler compiles, 2019-08
# on), with the Scala.js IR sources the build unpacks into it
mkdir -p comp
{ find "$TREE/compiler/src" $([ ! -d "$TREE/compiler/src-non-bootstrapped" ] || echo "$TREE/compiler/src-non-bootstrapped") -name '*.scala' -o -name '*.java'
  if [ -d "$TREE/compiler/src/dotty/tools/backend/sjs" ]; then
    irdirs=$(ls -d "$SCALAJS_SRC/ir/src/main/scala" "$SCALAJS_SRC/ir/shared/src/main/scala" "$SCALAJS_SRC/ir/shared/src/main/scala-2" "$SCALAJS_SRC/ir/jvm/src/main/scala" 2>/dev/null || true)
    # (from 2024-07 the build unpacks them as dotty.tools.sjs.ir)
    if grep -q '"org.scalajs.ir" => "dotty.tools.sjs.ir"' "$bld"; then
      python3 -I "$T/dotty-sjsir" sjsir $irdirs
    else
      find $irdirs -name '*.scala'
    fi
  fi
} | sort > comp.files
printf 'version.number=%s-bootstrap\nmaven.version.number=%s-bootstrap\ngit.hash=unknown\ncopyright.string=Copyright 2002-2019, LAMP/EPFL\n' \
  "$DOTTY_VERSION" "$DOTTY_VERSION" > comp/compiler.properties
echo "== compiler ($KIND)"
[ ! -d "$TREE/compiler/resources" ] || cp -r "$TREE/compiler/resources/." comp/
compile -d comp -classpath "lib0:tasty:interfaces:deps:$S2" $(sed -n "s/^compopts //p" deps.versions) @comp.files
cj=$(grep '\.java$' comp.files || true)
[ -z "$cj" ] || javac -cp "comp:lib0:tasty:interfaces:deps:$S2" -d comp $cj

# --- dotty-library again, by the new compiler (src-bootstrapped: what only it compiles)
mkdir -p lib
x=$TREE/library/src-3.x; extra=$TREE/library/src-bootstrapped; [ ! -d "$x" ] || extra="$x $extra"
find "$TREE/library/src" $extra -name '*.scala' -o -name '*.java' | sort > lib2.files
echo "== library (new compiler)"
$JAVA -cp "comp:lib0:tasty:interfaces:deps:$S2" dotty.tools.dotc.Main $scalacOpts \
  -d lib -classpath "$S2B" -sourcepath "$(srcpath)" $lopts $(sed -n 's/^libopts-boot //p' deps.versions) @lib2.files
jl=$(grep '\.java$' lib2.files || true)
[ -z "$jl" ] || javac -cp "lib:$S2B" -d lib $jl
echo "stage done"
