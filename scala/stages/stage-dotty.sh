#!/usr/bin/env bash
# stage-dotty.sh SRC OUT PREV : a dotty (Scala 3) tree built by the previous stage's compiler.
# PREV is a Scala 2 stage (out2: library + compiler; from it the dotty of 2019-04 that the
# Scala 3 chain starts with) or a dotty stage (OUT/{lib,comp,...}, the reference compiler
# a dotty tree names in project/Build.scala: referenceVersion).
# OUT gets: deps (the external Java/Scala inputs), interfaces, comp (dotty-compiler), lib0 (its
# dotty-library, compiled by PREV: the compiler runs on it), lib (dotty-library compiled by the new
# compiler, as released: what programs compile against), scala2lib (the scala-library).
# SCALA2LIB: the Scala 2 stage whose library the stage builds on (default: PREV's). Inputs (env.sh): ASM_SRCS, ZINC_SRC,
# JLINE3_SRC, SCALAJS_SRC.
set -euo pipefail
. "$(dirname "$(readlink -f "$0")")/env.sh"
SRC=$1 OUT=$2 PREV=$3
mkdir -p $OUT; cd $OUT
cp -r $SRC/. tree; TREE=$OUT/tree; chmod -R u+w tree
JAVA="$J8/bin/java -Xss16m -Xmx4g"

# what compiles: a Scala 2 compiler, or a dotty one
if [ -d $PREV/out2/scala/tools/nsc ]; then
  KIND=scala2; S2=${SCALA2LIB:-$PREV}/out2
  compile() { $JAVA -cp $PREV/out2:$PREV/classes scala.tools.nsc.Main -nowarn -encoding UTF8 -language:existentials,higherKinds,implicitConversions "$@"; }
else
  KIND=dotty; if [ -n "${SCALA2LIB:-}" ]; then S2=$SCALA2LIB/out2; else S2=$(readlink -f $PREV/scala2lib); fi
  pcp=$PREV/comp:$PREV/lib0:$PREV/interfaces:$PREV/deps:$PREV/scala2lib
  compile() { $JAVA -cp $pcp dotty.tools.dotc.Main -nowarn -encoding UTF8 -language:existentials,higherKinds,implicitConversions "$@"; }
fi
ln -s $S2 scala2lib
# SCALA2LIB_BOOT: the Scala 2 stage whose library the released dotty-library builds on, where the
# build names another one for it (stdlibVersion Bootstrapped: 2.13.0 in 2019-08, against 2.12.8)
S2B=${SCALA2LIB_BOOT:+$SCALA2LIB_BOOT/out2}; S2B=${S2B:-$S2}
[ "$S2B" = "$S2" ] || ln -s $S2B scala2lib-boot

# (Java compiled by JDK 8's javac: javac 21's MethodParameters without names break Scala 2's classfile reader)
# external inputs: scala-asm (the version the build names), zinc's compiler-interface (Java,
# with its contraband-generated sources, and sbt's util-interface), jline 3 reader + terminal (no JNA/jansi terminals)
bld=$TREE/project/Build.scala
av=$(sed -n 's/.*"scala-asm" % "\([^"]*\)".*/\1/p' $bld | head -1)
[ -d $ASM_SRCS/$av ] || { echo "no scala-asm $av" >&2; exit 1; }
mkdir -p deps
{ find $ASM_SRCS/$av/ -name '*.java'
  find $SBTUTIL_SRC/internal/util-interface/src/main/java/ -name '*.java'
  find $ZINC_SRC/internal/compiler-interface/src/main/java/ $ZINC_SRC/internal/compiler-interface/src/main/contraband-java/ -name '*.java'
  find $JLINE3_SRC/reader/src/main/java/ $JLINE3_SRC/terminal/src/main/java/ -name '*.java'
} > deps.files
$J8/bin/javac -nowarn -encoding utf8 -d deps @deps.files > deps.log 2>&1 || { cat deps.log; exit 1; }
for r in $JLINE3_SRC/reader/src/main/resources $JLINE3_SRC/terminal/src/main/resources; do [ -d $r ] && cp -r $r/. deps/; done

# dotty-interfaces (Java)
mkdir -p interfaces
$J8/bin/javac -nowarn -d interfaces $(find $TREE/interfaces/src -name '*.java')

# dotty-library: src, the sources for the compiler kind (src-2.x / src-3.x, 2019-04 on) and
# src-non-bootstrapped (what the reference compiler compiles: scalac up to 2019-04, then dotty)
mkdir -p lib0
x=$TREE/library/src-$([ $KIND = scala2 ] && echo 2 || echo 3).x
extra=$TREE/library/src-non-bootstrapped; [ ! -d $x ] || extra="$x $extra"
find $TREE/library/src $extra -name '*.scala' -o -name '*.java' | sort > lib.files
echo "== library ($KIND)"
# (by a dotty: with its released library on the class path, as sbt's scalaInstance has it)
if [ $KIND = dotty ]; then lcp=$PREV/lib:$S2; else lcp=$S2; fi
compile -d lib0 -classpath $lcp $( [ $KIND = dotty ] && echo -sourcepath $TREE/library/src ) @lib.files
jl=$(grep '\.java$' lib.files || true)
[ -z "$jl" ] || $J/bin/javac -nowarn --release 8 -encoding utf8 -cp lib0:$lcp -d lib0 $jl
# (and what of it the new sources lack, for the compiler built on lib0: e.g. src-bootstrapped only parts)
[ $KIND = scala2 ] || cp -rn $PREV/lib/. lib0/

# dotty-compiler (with the scalajs-ir sources the build unpacks; src-non-bootstrapped: what the
# reference compiler compiles, from 2019-08)
mkdir -p comp
{ find $TREE/compiler/src $([ -d $TREE/compiler/src-non-bootstrapped ] && echo $TREE/compiler/src-non-bootstrapped) -name '*.scala' -o -name '*.java'
  [ -d $TREE/compiler/src/dotty/tools/backend/sjs ] && find $SCALAJS_SRC/ir/src/main/scala -name '*.scala'
} | sort > comp.files
v=$(sed -n 's/.*val baseVersion = "\([^"]*\)".*/\1/p' $bld | head -1)
printf 'version.number=%s-bootstrap\nmaven.version.number=%s-bootstrap\ngit.hash=unknown\ncopyright.string=Copyright 2002-2019, LAMP/EPFL\n' $v $v > comp/compiler.properties
echo "== compiler ($KIND)"
[ ! -d $TREE/compiler/resources ] || cp -r $TREE/compiler/resources/. comp/
compile -d comp -classpath lib0:interfaces:deps:$S2 @comp.files
cj=$(grep '\.java$' comp.files || true)
[ -z "$cj" ] || $J/bin/javac -nowarn --release 8 -encoding utf8 -cp comp:lib0:interfaces:deps:$S2 -d comp $cj

# the library again, by the new compiler (src-bootstrapped: what only it compiles); TASTy
# versions change between stages, so programs (and the next stage) need this one
mkdir -p lib
x=$TREE/library/src-3.x; extra=$TREE/library/src-bootstrapped; [ ! -d $x ] || extra="$x $extra"
find $TREE/library/src $extra -name '*.scala' -o -name '*.java' | sort > lib2.files
echo "== library (new compiler)"
$JAVA -cp comp:lib0:interfaces:deps:$S2 dotty.tools.dotc.Main -nowarn -encoding UTF8 -language:existentials,higherKinds,implicitConversions \
  -d lib -classpath $S2B -sourcepath $TREE/library/src @lib2.files
jl=$(grep '\.java$' lib2.files || true)
[ -z "$jl" ] || $J/bin/javac -nowarn --release 8 -encoding utf8 -cp lib:$S2B -d lib $jl
echo "stage done"
