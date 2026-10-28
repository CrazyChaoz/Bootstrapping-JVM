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
# from 2009-09 Predef extends LowPriorityImplicits and starts with imports, so the compilers
# no longer see Predef.scala as the Predef unit and import Predef into it: an illegal cyclic
# reference.  The same imports inside the object do not count as leading ones.
if [ -f src/library/scala/LowPriorityImplicits.scala ]; then
  python3 - src/library/scala/Predef.scala <<'PY'
import re, sys
p = sys.argv[1]; s = open(p, encoding="latin-1").read()
m = re.search(r"^object Predef extends LowPriorityImplicits \{", s, re.M)
if m:
    head, rest = s[:m.start()], s[m.end():]
    imps = re.findall(r"^import [^\n]*$", head, re.M)
    if imps:
        head = re.sub(r"^import [^\n]*$", "", head, flags=re.M)
        open(p, "w", encoding="latin-1").write(head + m.group(0) + " " + "; ".join(imps) + rest)
        print("Predef: leading imports moved into the object", file=sys.stderr)
PY
fi
mkdir -p classes; cp -r $FJBG_CLS/. classes/   # FJBG + MSIL reader
# jline 1.0 for the REPL (from 2007-07); only then: its class files crash earlier compilers (s34's pickler)
# (from 2009-06 a generified jline jar, the one imported as source 2009-10: $JLINE5_CLS)
if grep -rqs 'jline\.' src/compiler && [ ! -d src/jline/src/main/java ]; then
  if grep -qs '^22f7477ecc57' $TREE/lib/jline.jar.desired.sha1 || [ ! -f $TREE/lib/jline.jar.desired.sha1 ]; then
    cp -r $JLINE_CLS/. classes/
  else cp -r $JLINE5_CLS/. classes/; fi
fi
# in-tree Java dependencies: Scala's jline fork (2009-10; jansi from 2010-12), forkjoin (out of
# src/library 2009-12; uses sun.misc.Unsafe, hence JDK 8's javac and not --release 8)
# and, newer than $FJBG_CLS, FJBG + the MSIL reader (2009-05..2012) and ASM (scala.tools.asm, 2012-)
for d in src/jline/src/main/java src/forkjoin src/fjbg src/msil src/asm; do
  [ -d $d ] || continue
  find $d -name '*.java' | grep -v '/msil/tests/\|/msil/util/VJSAssembly\.java$' > javadeps.files
  [ -s javadeps.files ] || continue
  # (712ebe2943, 2010-05, put Scala's ## into msil's Type.java, which scalac compiled)
  { grep -l '\.##' $(cat javadeps.files) || true; } | xargs -r sed -i 's/\.##\([^#]\)/.hashCode()\1/g'
  # (msil's sources have Latin-1 comments, 2010-08)
  enc=utf8; [ $d = src/msil ] && enc=latin1
  $J8/bin/javac -nowarn -encoding $enc -cp classes${JANSI_CLS:+:$JANSI_CLS} -d classes @javadeps.files > javadeps.log 2>&1 || { cat javadeps.log; exit 1; }
done
grep -rqs 'org\.fusesource' src/jline && cp -r $JANSI_CLS/. classes/
[ -d src/jline/src/main/resources ] && cp -r src/jline/src/main/resources/. classes/
. $HERE/nsc-patches.sh
LOCKER_SKIP=${LOCKER_SKIP:-'^src/library/scala/All\$\.scala$\|^src/library/scala/AllRef\$\.scala$'}
EXCL=${NSC_EXCLUDES:-'/ant/\|/dbc/\|scala/tools/nsc/doc/\|scala/tools/nsc/ScalaDoc\.scala$'}
# the doc generator is needed once Main uses it (2007)
if [ -z "${NSC_EXCLUDES:-}" ] && grep -rlq 'DocGenerator' --include=*.scala src/compiler/scala/tools/nsc --exclude-dir=doc; then EXCL='/ant/\|/dbc/'; fi
# MSIL backend: msil.jar (with the Scala-written emit API) was a binary until 2009;
# replace GenMSIL by a phase that refuses to run (JVM-only compiler)
G=src/compiler/scala/tools/nsc/backend/msil/GenMSIL.scala
# (src/msil from 2009-05 has it in Scala, still left out)
if [ -f $G ] && grep -q 'msil.emit' $G; then
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
has_opt() { # has_opt CP OPTION : does the compiler on CP know OPTION (settings classes, nsc/settings from 2009-03)
  local d; for d in ${1//:/ }; do
    grep -lqs -- "$2" $d/scala/tools/nsc/*Settings*.class $d/scala/tools/nsc/settings/*.class && return 0
  done; return 1; }
sc() { local cp=$1 main=$2 g=; shift 2
  [ -n "$GENERICS" ] && has_opt "$cp" '"-Ygenerics"\|-Ygenerics' && g=-Ygenerics
  # STARR_OPTS: for the previous compiler only (e.g. -Ynewarrays, the array scheme of 2009-09)
  [ "$cp" = "$PREVCP" ] && g="$g ${STARR_OPTS:-}"
  # (from 2010-02, e9a60f236b, -bootclasspath no longer replaces the running JVM's classes)
  has_opt "$cp" '-javabootclasspath' && g="$g -javabootclasspath $BOOTJAR"
  # (from 2010-03, PathResolver, the compiler's own class path comes first: for the previous
  # compiler that is the previous library; quick's, locker's library, is wanted there)
  [ "$cp" = "$PREVCP" ] && has_opt "$cp" '-javaignorecp' && g="$g -javaignorecp"
  $J8/bin/java -Xss64m -Xmx3g -cp "$cp" $main -bootclasspath $BOOTJAR $g ${SCALAC_OPTS:-} "$@"; }
nopredefs() { # option spelling understood by the compiler on classpath $1 (renamed 2007-07, 2012)
  if has_opt "$1" '-Yno-predefs'; then echo -Yno-predefs
  elif has_opt "$1" '-Yno-predef'; then echo -Yno-predef
  else echo -nopredefs; fi; }
lib() { # lib NAME COMPILERCP MAIN [FALLBACKCP] : library into NAME/lib
  local n=$1 ccp=$2 main=$3 fb=${4:+:$4}; local L=$n/lib
  mkdir -p $L
  if [ -n "$fb" ] && [ -n "$(for d in ${4//:/ }; do find $d/scala -maxdepth 1 -name '*$mc*$sp.class' 2>/dev/null; done | head -1)" ]; then
    # the fallback without its specialized subclasses (Tuple1$mcD$sp, 2010-05): compiled
    # from source as well, they would be "defined twice"
    local F=$n/fallback; rm -rf $F; mkdir -p $F
    for d in ${4//:/ }; do cp -rsn $(realpath $d)/. $F/; done
    find $F -name '*$mc*$sp*.class' -delete
    # FALLBACK_DROP: classes left out as well, comma-separated paths (scala/serializable, which an alias
    # of the scala package object stands for from 2010-11: "contains wrong class"; and */package,
    # the package objects that refer to it)
    for c in $(echo ${FALLBACK_DROP:-} | tr , " "); do find $F \( -path "$F/$c.class" -o -path "$F/$c\$*.class" \) -delete; done
    # FALLBACK_RENAME=OLD:NEW: a type name renamed in the fallback's pickles (the inherited
    # @scala.serializable, see tools/scala-pickle-rename.py)
    for r in ${FALLBACK_RENAME:-}; do
      find $F -name '*.class' -print0 | xargs -0 python3 -I $T/scala-pickle-rename.py ${r%%:*} ${r#*:}
    done
    fb=:$F
  fi
  ( cd src/library; find . -name '*.java' | sed 's|^\./||' ) > $n.libjava
  if [ -s $n.libjava ]; then
    python3 -I $T/pizza2java.py src/library $n/java-lib --classpath-src src/library --meta-out $n.lib.meta.json $(cat $n.libjava)
    # (forkjoin, in the library from 2009-09, needs sun.misc.Unsafe: JDK 8's javac)
    local jc="$J/bin/javac --release 8"; grep -rqs 'sun\.misc\.Unsafe' $n/java-lib && jc=$J8/bin/javac
    # forkjoin alone first: stale forkjoin classes of the previous library would shadow
    # java.util.concurrent (its own RunnableFuture, dropped 2009-09)
    if [ -d $n/java-lib/scala/concurrent/forkjoin ]; then
      $jc -nowarn -encoding latin1 -cp $L:classes -d $L $(find $n/java-lib/scala/concurrent/forkjoin -name '*.java') > $n.libjava.log 2>&1 || { cat $n.libjava.log; exit 1; }
    fi
    # the previous library behind, without its scala.runtime.Boolean, Int, ... (the primitive
    # companions, moved to scala in 2010-04), which would shadow java.lang's
    local pj=$PREVCP
    if [ -f $(echo $PREVCP | cut -d: -f1)/scala/runtime/Boolean.class ] && [ ! -f src/library/scala/runtime/Boolean.scala ]; then
      pj=$n/prev-java; rm -rf $pj; mkdir -p $pj
      for d in ${PREVCP//:/ }; do cp -rsn $(realpath $d)/. $pj/; done
      for t in Boolean Byte Short Char Int Long Float Double Unit; do rm -f $pj/scala/runtime/$t.class $pj/scala/runtime/$t\$.class; done
    fi
    $jc -nowarn -encoding latin1 -cp $L:classes:$pj -d $L $(find $n/java-lib -name '*.java' ! -path '*/scala/concurrent/forkjoin/*') >> $n.libjava.log 2>&1 || { cat $n.libjava.log; exit 1; }
    python3 -I $T/pico-classfiles.py $L $n.lib.meta.json
  fi
  echo "== $n: library"
  local sp=src/library
  if [ -n "$GENERICS" ] && [ -z "${ARRAY_SRC:-}" ]; then
    # loading java.lang.Class at compiler start-up forces scala.Array, which must then
    # come from a class file (the previous library), not the source path
    sp=$n/libsp; rm -rf $sp; mkdir -p $n; cp -rs $PWD/src/library $sp; rm $sp/scala/Array.scala
  fi
  ( cd $L; find . -name '*.class' | sort ) > $n.before-predef
  # (with Predef's superclass LowPriorityImplicits from 2009-09)
  local first="src/library/scala/Predef.scala src/library/scala/runtime/ScalaRunTime.scala"
  [ -f src/library/scala/LowPriorityImplicits.scala ] && first="src/library/scala/LowPriorityImplicits.scala $first"
  # (from 2009-11 ScalaObject has no `import Predef._`, so read from the source path it would
  # import Predef: the new compiler compiles it first (pkgObjectsFirst), as we do here)
  grep -q 'import Predef' src/library/scala/ScalaObject.scala || first="src/library/scala/ScalaObject.scala $first"
  # and then the package objects (scala's aliases into scala.math, scala.math's min/max, from
  # 2009-11), whose members the compilers of 9a9fece5c4 on only see from their class files;
  # quick with locker's library behind: scala.BigInt needs ScalaNumericConversions, which the
  # source path does not find (it is in BigDecimal.scala)
  local fcp=$L:classes$fb
  if [ -n "${PREDEF_KEEP:-}" ]; then
    first="$first $(find src/library -name package.scala | sort | tr '\n' ' ')"
    [ $n = quick ] && fcp=$fcp:locker/lib
  fi
  # (LIB_ONESTEP: all in one run, as SABBUS from a4895b8592, the compilers ordering ScalaObject,
  # Predef and the package objects first themselves; from 2010-06 the step above would need much
  # of the library from the source path, under names it cannot find there: the parallel collections)
  [ -n "${LIB_ONESTEP:-}" ] || sc "$ccp" $main $(nopredefs "$ccp") -d $L -classpath $fcp -sourcepath $sp $first
  if [ -n "$GENERICS" ] && [ -z "${PREDEF_KEEP:-}" ]; then
    # (PREDEF_KEEP: keep them, as SABBUS did, where the new compiler needs e.g. :: from a class
    # file: its case accessor lookup of 2009-07/08 crashes on source symbols, pilib.scala)
    # keep only Predef/ScalaRunTime from this step: other classes it compiled on the way are
    # compiled again below, and stale copies confuse the class path (Stream$cons$$anon$2, 2008-06)
    ( cd $L; find . -name '*.class' | sort | comm -13 $W/$n.before-predef - | grep -v '^\./scala/Predef\|^\./scala/runtime/ScalaRunTime\|^\./scala/LowPriorityImplicits' | xargs -r rm )
  fi
  ( cd src/library; find . -name '*.scala' | sed 's|^\./||' | grep -v "$EXCL" | grep -v '^scala/Predef.scala$\|^scala/runtime/ScalaRunTime.scala$\|^scala/LowPriorityImplicits.scala$' ) | sed 's|^|src/library/|' > $n.libscala
  [ -n "${LIB_ONESTEP:-}" ] && ( cd src/library; find . -name '*.scala' | sed 's|^\./||' | grep -v "$EXCL" ) | sed 's|^|src/library/|' > $n.libscala
  # (and ScalaObject and the package objects of the step: from 2010-03 compiling ScalaObject
  # again gives the cyclic reference involving Predef)
  if [ -n "${PREDEF_KEEP:-}" ] && [ -z "${LIB_ONESTEP:-}" ]; then
    printf '%s\n' $first | grep -vxF -f - $n.libscala > $n.libscala2 || true; mv $n.libscala2 $n.libscala
  fi
  if [ -n "$fb" ]; then
    # library classes an old STARR cannot compile from Scala source (scala.All$/AllRef$,
    # Java until 2006-04): take them from the previous library; quick compiles them properly
    grep -v "$LOCKER_SKIP" $n.libscala > $n.libscala2 || true; mv $n.libscala2 $n.libscala
    for f in $(find src/library -name '*.scala' | grep "$LOCKER_SKIP"); do
      c=${f#src/library/}; c=${c%.scala}; for d in ${PREVCP//:/ }; do [ -f $d/$c.class ] && { mkdir -p $L/$(dirname $c); cp $d/$c.class $L/$c.class; break; }; done
    done
  fi
  # (LIB_NOSP: without the source path, as SABBUS from a4895b8592: from 2010-03 the compilers
  # take Predef from the source path rather than from the class file of the step above)
  local msp="-sourcepath $sp" mcp=$L:classes$fb; [ -n "${LIB_NOSP:-}" ] && msp=
  # (quick: locker's library behind, which the compilers took from their own class path until
  # ae8c065594, 2010-03)
  [ -n "${LIB_NOSP:-}" ] && [ $n = quick ] && mcp=$mcp:locker/lib
  sc "$ccp" $main -d $L -classpath $mcp $msp $(cat $n.libscala)
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
if [ -n "${UNNEST:-}${LOCKER_PATCH:-}" ]; then
  # locker from rewritten sources, quick from the real ones: UNNEST (the STARR predates
  # chained package clauses, package a; package b, 2009-07), LOCKER_PATCH (patches/NAME.patch)
  mv src src.orig; cp -r src.orig src
  [ -n "${UNNEST:-}" ] && python3 -I $T/scala-unnest.py src
  for p in ${LOCKER_PATCH:-}; do patch -s -p1 < $HERE/patches/$p.patch; done
fi
# the previous library alone (without its compiler)
P=$(dirname ${PREVCP%%:*}); PREVLIB=$PREVCP; [ -d $P/quick/lib ] && PREVLIB=$P/quick/lib:$P/classes
if [ -n "${COMPILER_FIRST:-}" ]; then
  # flag day (the new library needs the new compiler, e.g. Int.box 2007-05):
  # locker compiler by STARR against the previous library, then the library by it
  echo "== compiler-first"
  comp locker "$PREVCP" $PREVMAIN $PREVLIB
  lib locker locker/comp:$PREVLIB:classes scala.tools.nsc.Main ${GENERICS:+$PREVLIB}
else
  # locker: classes the STARR insists on but the new library lacks come from the old one
  # (the library only: the STARR misreads its own compiler's nested classes, 2009-02)
  # (FALLBACK=none: no fallback, when the new library replaces the old one wholesale)
  FB=${FALLBACK:-$PREVLIB}; [ "$FB" = none ] && FB=
  lib locker "$PREVCP" $PREVMAIN "$FB"
  comp locker "$PREVCP" $PREVMAIN locker/lib "$FB"
fi
if [ -n "${UNNEST:-}${LOCKER_PATCH:-}" ]; then rm -rf src; mv src.orig src; fi
if [ -n "$GENERICS" ]; then   # only scala.Array (see lib) from locker, nothing else may leak into quick
  # (with its named nested classes, e.g. Array$Array0 from 2008-07; anonymous ones would pull in more)
  mkdir -p quick/arrayfb/scala
  # (and its superclass FallbackArrayBuilding, 2009-09)
  ( cd locker/lib/scala; ls Array.class 'Array$'*.class FallbackArrayBuilding*.class 2>/dev/null | grep -v 'anon' || true ) | while read f; do cp "locker/lib/scala/$f" quick/arrayfb/scala/; done
fi
# the locker compiler runs on the library it was compiled against
LCP=locker/lib:locker/comp:classes; [ -n "${COMPILER_FIRST:-}" ] && LCP=locker/comp:$PREVLIB:classes
lib quick $LCP scala.tools.nsc.Main ${GENERICS:+quick/arrayfb}
comp quick $LCP scala.tools.nsc.Main quick/lib
mkdir -p out2; cp -r quick/lib/. out2/; cp -r quick/comp/. out2/
echo stage done
