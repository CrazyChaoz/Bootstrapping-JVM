#!/usr/bin/env bash
# Scala 2.x (SABBUS, src/library + src/compiler): locker with the previous
# compiler (STARR), then quick with locker.
# usage: stage2.sh SRCTREE WORKDIR PREVCP [PREVMAIN]
set -euo pipefail
. "$(dirname "$(readlink -f "$0")")/env.sh"
TREE=$1; W=$2; PREVCP=$3; PREVMAIN=${4:-scala.tools.nsc.Main}
# from 2007-12 (dual-mode compiler, Predef.Class[T]) Scala is built against the generic Java 5 API
GENERICS=; grep -q 'type Class\[T\]' $TREE/src/library/scala/Predef.scala 2>/dev/null && GENERICS=1
if [ -n "$GENERICS" ]; then BOOTJAR=${BOOTJAR:-$RT15}; else BOOTJAR=${BOOTJAR:-$RT14}; fi
rm -rf $W; mkdir -p $W; cd $W
if [ -d $TREE/src/library ]; then cp -r $TREE/src src; else
  # 2005-12/2006-01 layout: sources/ (+ newsources/)
  mkdir -p src/library src/compiler; cp -r $TREE/sources/. src/library/
  mv src/library/scala/tools src/compiler/scala_tools; mkdir -p src/compiler/scala; mv src/compiler/scala_tools src/compiler/scala/tools
fi
chmod -R u+w src
mkdir -p classes; cp -r $FJBG_CLS/. classes/   # FJBG + MSIL reader
# jline 1.0 for the REPL (from 2007-07); only then: its class files crash earlier compilers (s34's pickler)
grep -rqs 'jline\.' src/compiler && cp -r $JLINE_CLS/. classes/
. $HERE/nsc-patches.sh
LOCKER_SKIP=${LOCKER_SKIP:-'^src/library/scala/All\$\.scala$\|^src/library/scala/AllRef\$\.scala$'}
EXCL=${NSC_EXCLUDES:-'/ant/\|/dbc/\|scala/tools/nsc/doc/'}
# the doc generator is needed once Main uses it (2007)
if [ -z "${NSC_EXCLUDES:-}" ] && grep -rlq 'DocGenerator' --include=*.scala src/compiler/scala/tools/nsc --exclude-dir=doc; then EXCL='/ant/\|/dbc/'; fi
# MSIL backend: msil.jar (with the Scala-written emit API) was a binary until 2009;
# replace GenMSIL by a phase that refuses to run (JVM-only compiler)
G=src/compiler/scala/tools/nsc/backend/msil/GenMSIL.scala
if [ -f $G ] && grep -q 'msil.emit' $G && [ ! -d src/msil ]; then
  python3 - $G <<'P'
import re, sys
f = sys.argv[1]; s = open(f).read()
pkg = re.search(r"^package .*$", s, re.M).group(0)
open(f, "w").write(pkg + """

abstract class GenMSIL extends SubComponent {
  import global._
  override def newPhase(p: Phase) = new MsilPhase(p)
  val phaseName = "msil"
  class MsilPhase(prev: Phase) extends GlobalPhase(prev) {
    def name = phaseName
    override def erasedTypes = true
    override def run: Unit = throw new Error("MSIL backend not bootstrapped")
    def apply(unit: CompilationUnit): Unit = throw new Error("MSIL backend not bootstrapped")
  }
}
""")
P
fi
has_opt() { # has_opt CP OPTION : does the compiler on CP know OPTION
  local d; for d in ${1//:/ }; do
    ls $d/scala/tools/nsc/Settings*.class >/dev/null 2>&1 || continue
    grep -lq -- "$2" $d/scala/tools/nsc/Settings*.class && return 0
  done; return 1; }
sc() { local cp=$1 main=$2 g=; shift 2
  [ -n "$GENERICS" ] && has_opt "$cp" '"-Ygenerics"\|-Ygenerics' && g=-Ygenerics
  $J8/bin/java -Xss64m -Xmx3g -cp "$cp" $main -bootclasspath $BOOTJAR $g ${SCALAC_OPTS:-} "$@"; }
nopredefs() { # option spelling understood by the compiler on classpath $1 (renamed 2007-07)
  local d; for d in ${1//:/ }; do
    ls $d/scala/tools/nsc/Settings*.class >/dev/null 2>&1 || continue
    grep -lq -- '-Yno-predefs' $d/scala/tools/nsc/Settings*.class && { echo -Yno-predefs; return; }
  done; echo -nopredefs; }
lib() { # lib NAME COMPILERCP MAIN [FALLBACKCP] : library into NAME/lib
  local n=$1 ccp=$2 main=$3 fb=${4:+:$4}; local L=$n/lib
  mkdir -p $L
  ( cd src/library; find . -name '*.java' | sed 's|^\./||' ) > $n.libjava
  if [ -s $n.libjava ]; then
    python3 -I $T/pizza2java.py src/library $n/java-lib --classpath-src src/library --meta-out $n.lib.meta.json $(cat $n.libjava)
    $J/bin/javac -nowarn -encoding latin1 --release 8 -cp $L:classes:$PREVCP -d $L $(find $n/java-lib -name '*.java') > $n.libjava.log 2>&1 || { cat $n.libjava.log; exit 1; }
    python3 -I $T/pico-classfiles.py $L $n.lib.meta.json
  fi
  echo "== $n: library"
  local sp=src/library
  if [ -n "$GENERICS" ]; then
    # loading java.lang.Class at compiler start-up forces scala.Array, which must then
    # come from a class file (the previous library), not the source path
    sp=$n/libsp; rm -rf $sp; mkdir -p $n; cp -rs $PWD/src/library $sp; rm $sp/scala/Array.scala
  fi
  ( cd $L; find . -name '*.class' | sort ) > $n.before-predef
  sc "$ccp" $main $(nopredefs "$ccp") -d $L -classpath $L:classes$fb -sourcepath $sp src/library/scala/Predef.scala src/library/scala/runtime/ScalaRunTime.scala
  if [ -n "$GENERICS" ]; then
    # keep only Predef/ScalaRunTime from this step: other classes it compiled on the way are
    # compiled again below, and stale copies confuse the class path (Stream$cons$$anon$2, 2008-06)
    ( cd $L; find . -name '*.class' | sort | comm -13 $W/$n.before-predef - | grep -v '^\./scala/Predef\|^\./scala/runtime/ScalaRunTime' | xargs -r rm )
  fi
  ( cd src/library; find . -name '*.scala' | sed 's|^\./||' | grep -v "$EXCL" | grep -v '^scala/Predef.scala$\|^scala/runtime/ScalaRunTime.scala$' ) | sed 's|^|src/library/|' > $n.libscala
  if [ -n "$fb" ]; then
    # library classes an old STARR cannot compile from Scala source (scala.All$/AllRef$,
    # Java until 2006-04): take them from the previous library; quick compiles them properly
    grep -v "$LOCKER_SKIP" $n.libscala > $n.libscala2 || true; mv $n.libscala2 $n.libscala
    for f in $(find src/library -name '*.scala' | grep "$LOCKER_SKIP"); do
      c=${f#src/library/}; c=${c%.scala}; for d in ${PREVCP//:/ }; do [ -f $d/$c.class ] && { mkdir -p $L/$(dirname $c); cp $d/$c.class $L/$c.class; break; }; done
    done
  fi
  sc "$ccp" $main -d $L -classpath $L:classes$fb -sourcepath $sp $(cat $n.libscala)
}
comp() { # comp NAME COMPILERCP MAIN LIBCP [FALLBACKCP] : compiler into NAME/comp, against LIBCP
  local n=$1 ccp=$2 main=$3 lcp=$4 fb=${5:+:$5}; local C=$n/comp
  mkdir -p $C
  ( cd src/compiler; find . -name '*.java' | sed 's|^\./||' ) > $n.compjava
  if [ -s $n.compjava ]; then
    python3 -I $T/pizza2java.py src/compiler $n/java-comp --classpath-src src/compiler --meta-out $n.comp.meta.json $(cat $n.compjava)
    $J/bin/javac -nowarn -encoding latin1 --release 8 -cp $lcp:$C:classes -d $C $(find $n/java-comp -name '*.java') > $n.compjava.log 2>&1 || { cat $n.compjava.log; exit 1; }
    python3 -I $T/pico-classfiles.py $C $n.comp.meta.json
  fi
  echo "== $n: compiler"
  ( cd src/compiler; find . -name '*.scala' | sed 's|^\./||' | grep -v "$EXCL" ) | sed 's|^|src/compiler/|' > $n.compscala
  sc "$ccp" $main -d $C -classpath $lcp:$C:classes$fb -sourcepath src/compiler $(cat $n.compscala)
}
if [ -n "${COMPILER_FIRST:-}" ]; then
  # flag day (the new library needs the new compiler, e.g. Int.box 2007-05):
  # locker compiler by STARR against the previous library, then the library by it
  echo "== compiler-first"
  P=$(dirname ${PREVCP%%:*}); PREVLIB=$PREVCP; [ -d $P/quick/lib ] && PREVLIB=$P/quick/lib:$P/classes
  comp locker "$PREVCP" $PREVMAIN $PREVLIB
  lib locker locker/comp:$PREVLIB:classes scala.tools.nsc.Main ${GENERICS:+$PREVLIB}
else
  # locker: classes the STARR insists on but the new library lacks come from the old one
  lib locker "$PREVCP" $PREVMAIN "$PREVCP"
  comp locker "$PREVCP" $PREVMAIN locker/lib "$PREVCP"
fi
if [ -n "$GENERICS" ]; then   # only scala.Array (see lib) from locker, nothing else may leak into quick
  mkdir -p quick/arrayfb/scala; cp locker/lib/scala/Array.class quick/arrayfb/scala/; cp locker/lib/scala/'Array$.class' quick/arrayfb/scala/ 2>/dev/null || true
fi
lib quick locker/lib:locker/comp:classes scala.tools.nsc.Main ${GENERICS:+quick/arrayfb}
comp quick locker/lib:locker/comp:classes scala.tools.nsc.Main quick/lib
mkdir -p out2; cp -r quick/lib/. out2/; cp -r quick/comp/. out2/
echo stage done
