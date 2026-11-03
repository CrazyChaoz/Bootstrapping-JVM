#!/usr/bin/env bash
# scala2.sh TREE OUT PREV : a Scala 2 tree (scala/scala from 2005-12 to 2.13), built as its own
# build (SABBUS, later sbt) does: "locker", library and compiler, by the previous stage's
# compiler ("STARR"), then "quick", library and compiler again, by locker.
#
# PREV is the previous stage: out2/ (its library and compiler), classes/ (their Java
# dependencies) and, for a Scala 2 stage, quick/lib/ (its library alone).  OUT gets the same.
#
# Inputs (besides those of common.sh):
#   RT14 RT15 RT16   the Java 1.4, 1.5 and 1.6 API (tools/jdk-api-view.py); the compilers
#                    of 2015 on get JDK 8's whole class library
#   FJBG_CLS         FJBG and the MSIL reader, as the first nsc stage built them
#   JLINE_CLS        jline 1.0, for the REPL (2007-07 on)
#   JLINE5_CLS       Scala's generified jline of 2009-06 (lib/jline.jar)
#   JANSI_CLS        jansi, for Scala's jline fork (2010-12 on)
#   ASM_SRCS         scala/scala-asm releases by version (2015-05 on: ASM left the tree)
#   DIFFUTILS_SRCS   java-diff-utils releases by version (2022-05 on)
#
# The way a stage is built (generations.nix sets these):
#   COMPILER_FIRST=1     for a flag day, when the new library needs the new compiler: locker's
#                        compiler first, by STARR against the previous library, then locker's
#                        library by it (otherwise the library first, then the compiler)
#   NO_FALLBACK=1        locker's library without the previous library behind it, for a new
#                        library that replaces the old one wholesale (2.8 collections, 2009)
#   JAVA_API=1.6|1.8     the Java API the compilers see, instead of 1.4 (1.5 from 2007-12)
#   ARRAY_FROM_SOURCE=1  scala.Array on the source path (see lib)
#   LIBRARY_KEEP_FIRST_RUN=1, PACKAGE_OBJECTS_FIRST=1, LIBRARY_NO_SOURCEPATH=1,
#   LIBRARY_ONE_RUN=1    how the library's Scala sources are compiled (see lib)
#   JAVA_AFTER_SCALA=1   the Java sources compiled after the Scala ones, which read them (the
#                        sbt order), instead of before (see lib, comp)
#   REFLECT_SEPARATELY=1 src/reflect compiled before src/compiler, in a run of its own (see comp)
#   FALLBACK_DROP=PATH,...  classes of the previous library that locker's library must not see
#   VERSION_PROPERTIES=1 library.properties and compiler.properties with the version, as the
#                        build writes them (the compilers of 2015-03 on parse it at start-up;
#                        with it on the class path, the compiler of 2007-03 crashes building
#                        the next: HashSet.findEntry, s32)
#   SCALAC_FLAGS=FLAG... flags for each compiler that knows them
#   STARR_FLAGS=FLAG...  flags for the previous compiler
#   CF_LIBRARY_SOURCES=DIR,...  (with COMPILER_FIRST) library sources locker's compiler is
#                        compiled with (see comp)
# and hooks that adapt the sources (patches/; a .patch is applied to src/, a script run
# with the directory):
#   SOURCE_PATCH         for src/, before anything else
#   LOCKER_SOURCE_PATCH  for a copy of src/ that locker is built from (quick gets the original)
#   FALLBACK_PATCH       for the previous library classes locker's library builds against
#   CF_LIBRARY_PATCH     for the CF_LIBRARY_SOURCES
#   LOCKER_ON_PREVIOUS_LIBRARY=1  locker runs on the previous library as well as its own
#   LOCKER_ONLY=1        the stage is its locker (for a commit that does not build itself)
set -euo pipefail
. "$(dirname "$(readlink -f "$0")")/common.sh"
require RT14 RT15 RT16 FJBG_CLS JLINE_CLS JLINE5_CLS JANSI_CLS ASM_SRCS DIFFUTILS_SRCS
TREE=$1 W=$2 PREV=$3
PREVCP=$PREV/out2:$PREV/classes
# the previous library alone, without its compiler
PREVLIB=$PREVCP; [ ! -d "$PREV/quick/lib" ] || PREVLIB=$PREV/quick/lib:$PREV/classes

# The Java sources: by PiCo while the tree's build compiles them with it (until 2006-06), else by javac
PICO_ERA=; grep -qs '<pico' "$TREE/build.xml" && PICO_ERA=1

# From 2007-12 (the dual-mode compiler, Predef.Class[T]) Scala is built against the generic Java 5 API.
GENERICS=; grep -qs 'type Class\[T\]' "$TREE/src/library/scala/Predef.scala" && GENERICS=1
case ${JAVA_API:-} in
  1.6) BOOTJAR=$RT16 ;;
  1.8) BOOTJAR=$JDK8/lib/openjdk/jre/lib/rt.jar ;;
  "") if [ -n "$GENERICS" ]; then BOOTJAR=$RT15; else BOOTJAR=$RT14; fi ;;
  *) echo "unknown JAVA_API $JAVA_API" >&2; exit 1 ;;
esac

patch_src() { # patch_src PATCH : a .patch (relative to src/) or a script (run on src/)
  case $1 in
    *.patch) patch -s -p1 -d src < "$1" ;;
    *) bash "$1" src ;;
  esac
}

rm -rf "$W"; mkdir -p "$W"; cd "$W"
if [ -d "$TREE/src/library" ]; then
  cp -r "$TREE/src" src
else
  # (the layout of 2005-12/2006-01: sources/ and newsources/)
  mkdir -p src/library src/compiler/scala
  cp -r "$TREE/sources/." src/library/
  mv src/library/scala/tools src/compiler/scala/tools
fi
[ -z "${SOURCE_PATCH:-}" ] || patch_src "$SOURCE_PATCH"

# --- the Java dependencies, into classes/
mkdir -p classes; cp -r "$FJBG_CLS/." classes/
# jline 1.0 for the REPL (2007-07); only then: its class files crash earlier compilers (s34's
# pickler).  From 2009-06 the generified jline jar that came as source in 2009-10.
if grep -rqs 'jline\.' src/compiler && [ ! -d src/jline/src/main/java ]; then
  if [ ! -f "$TREE/lib/jline.jar.desired.sha1" ] || grep -qs '^22f7477ecc57' "$TREE/lib/jline.jar.desired.sha1"; then
    cp -r "$JLINE_CLS/." classes/
  else
    cp -r "$JLINE5_CLS/." classes/
  fi
fi
# In-tree Java: Scala's jline fork (2009-10; with jansi from 2010-12), forkjoin (out of
# src/library 2009-12; it uses sun.misc.Unsafe, hence JDK 8's javac), and, newer than
# FJBG_CLS, FJBG + the MSIL reader (2009-05..2012) and ASM (scala.tools.asm, 2012-2015)
for d in src/jline/src/main/java src/forkjoin src/fjbg src/msil src/asm; do
  [ -d $d ] || continue
  find $d -name '*.java' | grep -v '/msil/tests/\|/msil/util/VJSAssembly\.java$' | sort > javadeps.files || true
  [ -s javadeps.files ] || continue
  # (forkjoin takes sun.misc.Unsafe from the library's scala.concurrent.util.Unsafe, 2012-06,
  # until that moved into src/forkjoin itself)
  u=src/library/scala/concurrent/util/Unsafe.java
  if [ $d = src/forkjoin ] && [ -f $u ] && grep -rqs 'scala\.concurrent\.util\.Unsafe' $d; then echo $u >> javadeps.files; fi
  # (712ebe2943, 2010-05, put Scala's ## into msil's Type.java, which scalac compiled)
  { grep -l '\.##' $(cat javadeps.files) || true; } | xargs -r sed -i 's/\.##\([^#]\)/.hashCode()\1/g'
  # (msil's sources have Latin-1 comments, 2010-08)
  enc=utf8; [ $d != src/msil ] || enc=latin1
  "$JDK8/bin/javac" -nowarn -encoding $enc -cp "classes:$JANSI_CLS" -d classes @javadeps.files > javadeps.log 2>&1 || { cat javadeps.log; exit 1; }
done
# From 2015-05 ASM is the scala-asm artifact: the release the tree names in versions.properties
# (2017 on), else 5.1.0-scala-2 (the 5.0.x-scala-N of 2015-16 were never tagged; this is their superset)
if [ ! -d src/asm ] && grep -rqs 'scala\.tools\.asm' src/compiler; then
  av=$(sed -n 's/^scala-asm\.version=\([^ ]*\).*/\1/p' "$TREE/versions.properties" 2>/dev/null || true)
  [ -n "$av" ] && [ -d "$ASM_SRCS/$av" ] || av=5.1.0-scala-2
  find "$ASM_SRCS/$av/" -name '*.java' | sort > javadeps.files
  "$JDK8/bin/javac" -nowarn -encoding utf8 -d classes @javadeps.files > javadeps.log 2>&1 || { cat javadeps.log; exit 1; }
fi
# From 2022-05 the compiler uses java-diff-utils (-Yprint-trees:diff): the release build.sbt names
if grep -rqs 'com\.github\.difflib' src/compiler; then
  dv=$(sed -n 's/.*"java-diff-utils" *% *"\([^"]*\)".*/\1/p' "$TREE/build.sbt" | head -1)
  [ -d "$DIFFUTILS_SRCS/$dv" ] || { echo "no java-diff-utils $dv" >&2; exit 1; }
  find "$DIFFUTILS_SRCS/$dv/java-diff-utils/src/main/java/" -name '*.java' | sort > diffutils.files
  "$JDK8/bin/javac" -nowarn -encoding utf8 -d classes @diffutils.files > diffutils.log 2>&1 || { cat diffutils.log; exit 1; }
fi
! grep -rqs 'org\.fusesource' src/jline || cp -r "$JANSI_CLS/." classes/
[ ! -d src/jline/src/main/resources ] || cp -r src/jline/src/main/resources/. classes/

# --- source patches
. "$HERE/nsc-patches.sh"
# MSIL backend: msil.jar (with the Scala-written emit API) was a binary until 2009 (src/msil
# from 2009-05 has it in Scala, still left out): GenMSIL becomes a phase that refuses to run
G=src/compiler/scala/tools/nsc/backend/msil/GenMSIL.scala
if [ -f $G ] && grep -q 'msil.emit' $G; then
  python3 - $G <<'PY'
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
PY
fi

# What is not compiled: the Ant tasks, scala.dbc, and the doc generator until Main uses it (2007)
EXCL='/ant/\|/dbc/\|scala/tools/nsc/doc/\|scala/tools/nsc/ScalaDoc\.scala$'
! grep -rlq 'DocGenerator' --include=*.scala src/compiler/scala/tools/nsc --exclude-dir=doc || EXCL='/ant/\|/dbc/'

has_opt() { # has_opt CP OPTION : does the compiler on CP know OPTION (its settings classes)
  local d
  for d in ${1//:/ }; do
    grep -lqs -- "$2" $d/scala/tools/nsc/*Settings*.class $d/scala/tools/nsc/settings/*.class && return 0
  done
  return 1
}
sc() { # sc CP ARGS... : the compiler on CP (STARR if CP is PREVCP)
  local cp=$1 g='' o; shift
  [ -z "$GENERICS" ] || ! has_opt "$cp" '"-Ygenerics"\|-Ygenerics' || g=-Ygenerics
  [ "$cp" != "$PREVCP" ] || g="$g ${STARR_FLAGS:-}"
  # (from 2010-02, e9a60f236b, -bootclasspath no longer replaces the running JVM's classes)
  ! has_opt "$cp" '-javabootclasspath' || g="$g -javabootclasspath $BOOTJAR"
  # (from 2010-03, PathResolver, the compiler's own class path comes first: for STARR that is
  # the previous library, and the one to compile against comes from the -classpath)
  [ "$cp" != "$PREVCP" ] || ! has_opt "$cp" '-javaignorecp' || g="$g -javaignorecp"
  for o in ${SCALAC_FLAGS:-}; do ! has_opt "$cp" "$o" || g="$g $o"; done
  "$JDK8/bin/java" -Xss64m -Xmx3g -cp "$cp" scala.tools.nsc.Main -bootclasspath "$BOOTJAR" $g "$@"
}
nopredefs() { # the spelling of -nopredefs the compiler on CP $1 knows (renamed 2007-07, 2012)
  if has_opt "$1" '-Yno-predefs'; then echo -Yno-predefs
  elif has_opt "$1" '-Yno-predef'; then echo -Yno-predef
  else echo -nopredefs; fi
}
props() { # props DIR NAME : NAME.properties with the version.number, as the Ant and sbt builds write it
  # (from 2015-03 the compiler parses the library's at start-up, ScalaVersion.current)
  local v=
  [ -n "${VERSION_PROPERTIES:-}" ] || return 0
  if [ -f "$TREE/build.number" ]; then
    v=$(for k in major minor patch; do sed -n "s/^version\.$k=\([0-9]*\).*/\1/p" "$TREE/build.number"; done | paste -sd.)
  elif [ -f "$TREE/versions.properties" ]; then
    v=$(sed -n 's/^maven\.version\.base=\([0-9.]*\).*/\1/p' "$TREE/versions.properties")
  fi
  # (from 2016-09 only in build.sbt: baseVersion in Global := "2.12.0")
  [ -n "$v" ] || [ ! -f "$TREE/build.sbt" ] || v=$(sed -n 's/.*baseVersion.*:= *"\([0-9.]*\)".*/\1/p' "$TREE/build.sbt" | head -1)
  [ -z "$v" ] || printf 'version.number=%s-bootstrap\n' "$v" > "$1/$2.properties"
}
farm() { # farm DIR CP : DIR, a symlink farm of the class path CP (the first entry wins)
  local d
  rm -rf "$1"; mkdir -p "$1"
  for d in ${2//:/ }; do cp -rsn "$(realpath "$d")/." "$1/"; done
}
drop() { # drop DIR PATH,... : delete the classes PATH (and their nested classes) from DIR
  local c cs
  IFS=, read -ra cs <<< "$2"
  for c in "${cs[@]}"; do find "$1" \( -path "$1/$c.class" -o -path "$1/$c\$*.class" \) -delete; done
}

lib() { # lib NAME COMPILERCP [FALLBACKCP] : the library into NAME/lib by the compiler on COMPILERCP,
  # with FALLBACKCP behind it: what the compiler needs but the new library lacks
  local n=$1 ccp=$2 fb=${3:+:$3} L=$1/lib java_after='' fi_src=''
  mkdir -p $L
  props $L library
  if [ -n "$fb" ] && [ -n "$(for d in ${3//:/ }; do find $d/scala -maxdepth 1 -name '*$mc*$sp.class' 2>/dev/null; done | head -1)" ]; then
    # the fallback without its specialized subclasses (Tuple1$mcD$sp, 2010-05), which, compiled
    # from source as well, would be "defined twice", and without FALLBACK_DROP
    farm $n/fallback "$3"
    find $n/fallback -name '*$mc*$sp*.class' -delete
    drop $n/fallback "${FALLBACK_DROP:-}"
    [ -z "${FALLBACK_PATCH:-}" ] || bash "$FALLBACK_PATCH" $n/fallback
    fb=:$n/fallback
  fi

  # The Java sources
  ( cd src/library; find . -name '*.java' | sed 's|^\./||' | sort ) > $n.libjava
  if [ -s $n.libjava ] && [ -n "$PICO_ERA" ]; then
    pico -classpath $L:classes:$PREVCP -d $L $(sed 's|^|src/library/|' $n.libjava)
  elif [ -s $n.libjava ]; then
    # (a copy, which the workarounds below may change)
    rm -rf $n/java-lib; mkdir -p $n/java-lib
    ( cd src/library && cp --parents $(cat ../../$n.libjava) ../../$n/java-lib/ )
    if [ -n "${JAVA_AFTER_SCALA:-}" ]; then
      # (scalac reads them with the Scala sources, javac compiles them afterwards, against the
      # new library: from 2016-08 they call its Scala code, LambdaDeserializer)
      java_after=$n/java-lib
    else
      # Before the Scala sources, against the previous library, whose trait encoding may be
      # older than the sources: then javac rejects the @FunctionalInterface of JFunctionN, which
      # needs the new one (default methods, 2016-03), so quick compiles them again after its Scala.
      if grep -rlq '@FunctionalInterface' $n/java-lib; then
        fi_src=$n/java-lib-fi; rm -rf $fi_src; cp -r $n/java-lib $fi_src
        grep -rl '@FunctionalInterface' $n/java-lib | xargs sed -i 's/@FunctionalInterface//'
      fi
      # (forkjoin, in the library from 2009-09, needs sun.misc.Unsafe: JDK 8's javac; and so does
      # what uses scala.concurrent.util.Unsafe.instance, AbstractPromise 2012-06)
      local jc=javac8; ! grep -rqs 'sun\.misc\.Unsafe\|Unsafe\.instance' $n/java-lib || jc="$JDK8/bin/javac -nowarn"
      # forkjoin alone first: stale forkjoin classes of the previous library would shadow
      # java.util.concurrent (its own RunnableFuture, dropped 2009-09)
      if [ -d $n/java-lib/scala/concurrent/forkjoin ]; then
        $jc -encoding latin1 -cp $L:classes -d $L $(find $n/java-lib/scala/concurrent/forkjoin -name '*.java' | sort) > $n.libjava.log 2>&1 || { cat $n.libjava.log; exit 1; }
      fi
      # the previous library behind, without its scala.runtime.Boolean, Int, ... (the primitive
      # companions moved to scala in 2010-04), which would shadow java.lang's
      local pj=$PREVCP
      if [ -f $PREV/out2/scala/runtime/Boolean.class ] && [ ! -f src/library/scala/runtime/Boolean.scala ]; then
        pj=$n/prev-java; farm $pj "$PREVCP"
        for t in Boolean Byte Short Char Int Long Float Double Unit; do rm -f $pj/scala/runtime/$t.class $pj/scala/runtime/$t\$.class; done
      fi
      $jc -encoding latin1 -cp $L:classes:$pj -d $L $(find $n/java-lib -name '*.java' ! -path '*/scala/concurrent/forkjoin/*' | sort) >> $n.libjava.log 2>&1 || { cat $n.libjava.log; exit 1; }
    fi
  fi

  # The Scala sources
  echo "== $n: library"
  local sp=src/library
  if [ -n "$GENERICS" ] && [ -z "${ARRAY_FROM_SOURCE:-}" ]; then
    # (loading java.lang.Class at compiler start-up forces scala.Array, which must then come from
    # a class file, the fallback's, not from the source path)
    sp=$n/libsp; rm -rf $sp; mkdir -p $n; cp -rs "$PWD/src/library" $sp; rm $sp/scala/Array.scala
  fi
  ( cd src/library; find . -name '*.scala' | sed 's|^\./||' | grep -v "$EXCL" ) | sed 's|^|src/library/|' > $n.libscala
  if [ -z "${LIBRARY_ONE_RUN:-}" ]; then
    # Two runs, as SABBUS until 2010: Predef and ScalaRunTime (and Predef's superclass
    # LowPriorityImplicits, 2009-09) without the predefs, then the rest.  (From 2009-11
    # ScalaObject has no `import Predef._` and, read from the source path, would import Predef:
    # the new compiler compiles it first itself (pkgObjectsFirst), and so does the first run.)
    local first="src/library/scala/Predef.scala src/library/scala/runtime/ScalaRunTime.scala" fcp=$L:classes$fb
    [ ! -f src/library/scala/LowPriorityImplicits.scala ] || first="src/library/scala/LowPriorityImplicits.scala $first"
    [ ! -f src/library/scala/ScalaObject.scala ] || grep -q 'import Predef' src/library/scala/ScalaObject.scala || first="src/library/scala/ScalaObject.scala $first"
    if [ -n "${PACKAGE_OBJECTS_FIRST:-}" ]; then
      # (and the package objects, scala's aliases into scala.math and scala.math's min/max of
      # 2009-11, whose members the compilers of 9a9fece5c4 on only see from their class files;
      # all of the first run is kept (from 2010-03 compiling ScalaObject again gives a cyclic
      # reference involving Predef); quick's first run sees locker's library: scala.BigInt
      # needs ScalaNumericConversions, which the source path does not find in BigDecimal.scala)
      first="$first $(find src/library -name package.scala | sort | tr '\n' ' ')"
      [ $n != quick ] || fcp=$fcp:locker/lib
    fi
    ( cd $L; find . -name '*.class' | sort ) > $n.before-first
    sc "$ccp" $(nopredefs "$ccp") -d $L -classpath $fcp -sourcepath $sp $first
    if [ -n "${PACKAGE_OBJECTS_FIRST:-}" ]; then
      printf '%s\n' $first | { grep -vxF -f - $n.libscala || true; } > $n.libscala2; mv $n.libscala2 $n.libscala
    else
      # (with GENERICS: only Predef, ScalaRunTime and LowPriorityImplicits are kept, the other
      # classes the first run compiled on the way are compiled again by the second, and stale
      # copies confuse the class path: Stream$cons$$anon$2, 2008-06; but with
      # LIBRARY_KEEP_FIRST_RUN all of them, as SABBUS: from 2009-10 the new compiler needs `::`
      # from a class file, its case accessor lookup crashes on source symbols)
      if [ -n "$GENERICS" ] && [ -z "${LIBRARY_KEEP_FIRST_RUN:-}" ]; then
        ( cd $L; find . -name '*.class' | sort | comm -13 "$W/$n.before-first" - \
            | { grep -v '^\./scala/Predef\|^\./scala/runtime/ScalaRunTime\|^\./scala/LowPriorityImplicits' || true; } | xargs -r rm )
      fi
      grep -v '^src/library/scala/Predef.scala$\|^src/library/scala/runtime/ScalaRunTime.scala$\|^src/library/scala/LowPriorityImplicits.scala$' $n.libscala > $n.libscala2 || true
      mv $n.libscala2 $n.libscala
    fi
  fi
  # (One run, as SABBUS from a4895b8592: the compilers order ScalaObject, Predef and the
  # package objects first themselves; from 2010-06 the first run would need much of the library
  # from the source path, under names it cannot find there: the parallel collections.)
  if [ -n "$fb" ]; then
    # (scala.All$ and AllRef$, Java until 2006-04, which an old STARR cannot compile from Scala:
    # from the previous library; quick compiles them properly)
    local skip='^src/library/scala/All\$\.scala$\|^src/library/scala/AllRef\$\.scala$' f c d
    grep -v "$skip" $n.libscala > $n.libscala2 || true; mv $n.libscala2 $n.libscala
    for f in $(find src/library -name '*.scala' | grep "$skip"); do
      c=${f#src/library/}; c=${c%.scala}
      for d in ${PREVCP//:/ }; do
        if [ -f $d/$c.class ]; then mkdir -p $L/$(dirname $c); cp $d/$c.class $L/$c.class; break; fi
      done
    done
  fi
  # (LIBRARY_NO_SOURCEPATH: without the source path, as SABBUS from a4895b8592: from 2010-03
  # the compilers take Predef from the source path rather than from the class file of the first
  # run; quick then needs locker's library behind it, which the compilers took from their own
  # class path until ae8c065594, 2010-03)
  local msp="-sourcepath $sp" mcp=$L:classes$fb
  if [ -n "${LIBRARY_NO_SOURCEPATH:-}" ]; then
    msp=; [ $n != quick ] || mcp=$mcp:locker/lib
  fi
  sc "$ccp" -d $L -classpath $mcp $msp $(cat $n.libscala) ${java_after:+$(find $java_after -name '*.java' | sort)}
  if [ -n "$java_after" ]; then
    javac8 -encoding latin1 -cp $L:classes -d $L $(find $java_after -name '*.java' | sort) > $n.libjava.log 2>&1 || { cat $n.libjava.log; exit 1; }
  fi
  if [ -n "$fi_src" ] && [ $n = quick ]; then
    javac8 -encoding latin1 -cp $L:classes -d $L $(find $fi_src -name '*.java' -path '*/scala/runtime/java8/*' | sort) > $n.libjava2.log 2>&1 || { cat $n.libjava2.log; exit 1; }
  fi
}

comp() { # comp NAME COMPILERCP LIBCP [FALLBACKCP] : the compiler into NAME/comp by the compiler on
  # COMPILERCP, against the library LIBCP (and FALLBACKCP)
  local n=$1 ccp=$2 lcp=$3 fb=${4:+:$4} C=$1/comp cjava='' csp=src/compiler
  mkdir -p $C
  props $C compiler
  if [ -n "${JAVA_AFTER_SCALA:-}" ]; then
    # (the sbt order here too, with src/reflect's Java sources from 2017-10, StatisticsStatics:
    # to scalac with the Scala sources, then javac)
    cjava=$(find src/compiler $([ ! -d src/reflect ] || echo src/reflect) -name '*.java' | grep -v "$EXCL" | sort || true)
  else
    ( cd src/compiler; find . -name '*.java' | sed 's|^\./||' | sort ) > $n.compjava
    if [ -s $n.compjava ] && [ -n "$PICO_ERA" ]; then
      pico -classpath $lcp:$C:classes -d $C $(sed 's|^|src/compiler/|' $n.compjava)
    elif [ -s $n.compjava ]; then
      javac8 -encoding latin1 -cp $lcp:$C:classes -d $C $(sed 's|^|src/compiler/|' $n.compjava) > $n.compjava.log 2>&1 || { cat $n.compjava.log; exit 1; }
    fi
  fi
  echo "== $n: compiler"
  ( cd src/compiler; find . -name '*.scala' | sed 's|^\./||' | grep -v "$EXCL" ) | sed 's|^|src/compiler/|' > $n.compscala
  # (with src/reflect, the reflection library of 2012-06, scala-reflect.jar: into the compiler's classes)
  if [ -d src/reflect ]; then find src/reflect -name '*.scala' >> $n.compscala; csp=src/compiler:src/reflect; fi
  if [ -n "${COMPILER_FIRST:-}" ] && [ $n = locker ] && [ -n "${CF_LIBRARY_SOURCES:-}" ]; then
    # Library parts the new compiler needs that the previous library lacks, compiled with it
    # (the reflection API in scala/reflect/api, 2012-03).  Copies: macro definitions (`def f =
    # macro impl`, 2012-04) become ??? where the previous compiler cannot parse them, i.e. has no
    # -Xmacro-settings (which came with them and outlived -Xmacros); kept otherwise, so that the tag
    # materializers of scala.reflect.makro.internal stay macros.  "!PATH" entries are left out.
    local stub='s/=\s*macro\s.*$/= ???/' cfl d cfx=
    ! has_opt "$PREVCP" '-Xmacro-settings' || stub=
    IFS=, read -ra cfl <<< "$CF_LIBRARY_SOURCES"
    for d in "${cfl[@]}"; do [[ $d != !* ]] || cfx="$cfx|src/library/${d#!}"; done
    for d in "${cfl[@]}"; do [[ $d == !* ]] || find src/library/$d -name '*.scala'; done | grep -vxE "${cfx#|}${cfx:+|}^$" | while read -r f; do
      mkdir -p "$n/cf-libsrc/$(dirname "$f")"; sed -E "$stub" "$f" > "$n/cf-libsrc/$f"
    done
    [ -z "${CF_LIBRARY_PATCH:-}" ] || bash "$CF_LIBRARY_PATCH" $n/cf-libsrc/src/library
    find $n/cf-libsrc -name '*.scala' >> $n.compscala
  fi
  if [ -n "${REFLECT_SEPARATELY:-}" ] && [ -d src/reflect ]; then
    # (src/reflect in a run of its own, the compiler against its classes, as the sbt projects:
    # joint compilation infers other types once Name became a CharSequence, 2020-11)
    local rjava; rjava=$(echo $cjava | tr ' ' '\n' | grep '^src/reflect/' || true)
    echo "== $n: reflect"
    sc "$ccp" -d $C -classpath $lcp:$C:classes$fb -sourcepath src/reflect $(grep '^src/reflect/' $n.compscala) $rjava
    [ -z "$rjava" ] || javac8 -encoding utf8 -cp $lcp:$C:classes -d $C $rjava > $n.compjava.log 2>&1 || { cat $n.compjava.log; exit 1; }
    grep -v '^src/reflect/' $n.compscala > $n.compscala.c; mv $n.compscala.c $n.compscala
    csp=src/compiler; cjava=$(echo $cjava | tr ' ' '\n' | grep -v '^src/reflect/' | paste -sd' ' || true)
  fi
  sc "$ccp" -d $C -classpath $lcp:$C:classes$fb -sourcepath $csp $(cat $n.compscala) $cjava
  [ -z "$cjava" ] || javac8 -encoding utf8 -cp $lcp:$C:classes -d $C $cjava > $n.compjava.log 2>&1 || { cat $n.compjava.log; exit 1; }
}

# --- locker, by STARR (from patched sources, LOCKER_SOURCE_PATCH)
if [ -n "${LOCKER_SOURCE_PATCH:-}" ]; then
  mv src src.orig; cp -r src.orig src
  patch_src "$LOCKER_SOURCE_PATCH"
fi
if [ -n "${COMPILER_FIRST:-}" ]; then
  echo "== compiler first"
  comp locker "$PREVCP" "$PREVLIB"
  lib locker "locker/comp:$PREVLIB:classes" ${GENERICS:+"$PREVLIB"}
else
  # the classes STARR insists on but the new library lacks come from the old library (the
  # library only: the STARR of 2009-02 misreads its own compiler's nested classes)
  FB=$PREVLIB; [ -z "${NO_FALLBACK:-}" ] || FB=
  lib locker "$PREVCP" "$FB"
  comp locker "$PREVCP" locker/lib "$FB"
fi
if [ -n "${LOCKER_SOURCE_PATCH:-}" ]; then rm -rf src; mv src.orig src; fi
if [ -n "$GENERICS" ]; then
  # quick's library builds on scala.Array from locker (see lib) and on nothing else of it: its
  # named nested classes (Array$Array0, 2008-07) and its superclass FallbackArrayBuilding (2009-09)
  mkdir -p quick/arrayfb/scala
  for f in locker/lib/scala/Array.class locker/lib/scala/'Array$'*.class locker/lib/scala/FallbackArrayBuilding*.class; do
    if [ -e "$f" ] && [[ $f != *anon* ]]; then cp "$f" quick/arrayfb/scala/; fi
  done
fi
# the locker compiler runs on the library it was compiled against
LCP=locker/lib:locker/comp:classes; [ -z "${COMPILER_FIRST:-}" ] || LCP=locker/comp:$PREVLIB:classes
[ -z "${LOCKER_ON_PREVIOUS_LIBRARY:-}" ] || LCP=$LCP:$PREVLIB

mkdir -p out2
if [ -n "${LOCKER_ONLY:-}" ]; then
  cp -r locker/lib/. out2/; cp -r locker/comp/. out2/
else
  # --- quick, by locker
  lib quick $LCP ${GENERICS:+quick/arrayfb}
  comp quick $LCP quick/lib
  cp -r quick/lib/. out2/; cp -r quick/comp/. out2/
fi
echo "stage done"
