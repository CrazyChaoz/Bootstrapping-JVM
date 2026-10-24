#!/usr/bin/env bash
# Scala 2.x (SABBUS, src/library + src/compiler): locker with the previous
# compiler (STARR), then quick with locker.
# usage: stage2.sh SRCTREE WORKDIR PREVCP [PREVMAIN]
set -euo pipefail
T=/home/kemp/ins/development/bootstrapping-gradle/tools
J=/nix/store/nkd7mzlsa4d113n0xwh98m4l6dx9bnax-openjdk-headless-21.0.12.1+1
J8=/nix/store/z2mxh5237w3dd8klbikm94x2wwipgc2y-openjdk-headless-8u504-b01
S=/tmp/sc; BOOTJAR=${BOOTJAR:-/tmp/sc/rt14b.jar}
TREE=$1; W=$2; PREVCP=$3; PREVMAIN=${4:-scala.tools.nsc.Main}
rm -rf $W; mkdir -p $W; cd $W
if [ -d $TREE/src/library ]; then cp -r $TREE/src src; else
  # 2005-12/2006-01 layout: sources/ (+ newsources/)
  mkdir -p src/library src/compiler; cp -r $TREE/sources/. src/library/
  mv src/library/scala/tools src/compiler/scala_tools; mkdir -p src/compiler/scala; mv src/compiler/scala_tools src/compiler/scala/tools
fi
chmod -R u+w src
mkdir -p classes; cp -r $S/st-n0/fjbg-cls/. classes/   # FJBG + MSIL reader
. $S/work/nsc-patches.sh
LOCKER_SKIP=${LOCKER_SKIP:-'^src/library/scala/All\$\.scala$\|^src/library/scala/AllRef\$\.scala$'}
EXCL=${NSC_EXCLUDES:-'/ant/\|/dbc/\|scala/tools/nsc/doc/'}
sc() { local cp=$1 main=$2; shift 2; $J8/bin/java -Xss64m -Xmx3g -cp "$cp" $main -bootclasspath $BOOTJAR "$@"; }
build() { # build NAME COMPILERCP MAIN [FALLBACKCP]
  local n=$1 ccp=$2 main=$3 fb=${4:+:$4}; local L=$n/lib C=$n/comp
  mkdir -p $L $C
  ( cd src/library; find . -name '*.java' | sed 's|^\./||' ) > $n.libjava
  if [ -s $n.libjava ]; then
    python3 -I $T/pizza2java.py src/library $n/java-lib --classpath-src src/library --meta-out $n.lib.meta.json $(cat $n.libjava)
    $J/bin/javac -nowarn -encoding latin1 --release 8 -cp $L:classes:$PREVCP -d $L $(find $n/java-lib -name '*.java') > $n.libjava.log 2>&1 || { cat $n.libjava.log; exit 1; }
    python3 -I $T/pico-classfiles.py $L $n.lib.meta.json
  fi
  echo "== $n: library"
  sc "$ccp" $main -nopredefs -d $L -classpath $L:classes$fb -sourcepath src/library src/library/scala/Predef.scala src/library/scala/runtime/ScalaRunTime.scala
  ( cd src/library; find . -name '*.scala' | sed 's|^\./||' | grep -v "$EXCL" | grep -v '^scala/Predef.scala$\|^scala/runtime/ScalaRunTime.scala$' ) | sed 's|^|src/library/|' > $n.libscala
  if [ -n "$fb" ]; then
    # library classes an old STARR cannot compile from Scala source (scala.All$/AllRef$,
    # Java until 2006-04): take them from the previous library; quick compiles them properly
    grep -v "$LOCKER_SKIP" $n.libscala > $n.libscala2 || true; mv $n.libscala2 $n.libscala
    for f in $(find src/library -name '*.scala' | grep "$LOCKER_SKIP"); do
      c=${f#src/library/}; c=${c%.scala}; for d in ${PREVCP//:/ }; do [ -f $d/$c.class ] && { mkdir -p $L/$(dirname $c); cp $d/$c.class $L/$c.class; break; }; done
    done
  fi
  sc "$ccp" $main -d $L -classpath $L:classes$fb -sourcepath src/library $(cat $n.libscala)
  ( cd src/compiler; find . -name '*.java' | sed 's|^\./||' ) > $n.compjava
  if [ -s $n.compjava ]; then
    python3 -I $T/pizza2java.py src/compiler $n/java-comp --classpath-src src/compiler --meta-out $n.comp.meta.json $(cat $n.compjava)
    $J/bin/javac -nowarn -encoding latin1 --release 8 -cp $L:$C:classes -d $C $(find $n/java-comp -name '*.java') > $n.compjava.log 2>&1 || { cat $n.compjava.log; exit 1; }
    python3 -I $T/pico-classfiles.py $C $n.comp.meta.json
  fi
  echo "== $n: compiler"
  ( cd src/compiler; find . -name '*.scala' | sed 's|^\./||' | grep -v "$EXCL" ) | sed 's|^|src/compiler/|' > $n.compscala
  sc "$ccp" $main -d $C -classpath $L:$C:classes$fb -sourcepath src/compiler $(cat $n.compscala)
}
# locker: classes the STARR insists on but the new library lacks come from the old one
build locker "$PREVCP" $PREVMAIN "$PREVCP"
build quick locker/lib:locker/comp:classes scala.tools.nsc.Main
mkdir -p out2; cp -r quick/lib/. out2/; cp -r quick/comp/. out2/
echo stage done
