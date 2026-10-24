#!/usr/bin/env bash
# First Scala 2 compiler: SABBUS steps of 2005-12 (ac84922849~1) with the
# 1.4 compiler (osc) of stage OSCSTAGE.
# usage: stage-nsc0.sh SRCTREE WORKDIR OSCSTAGE   (a stage directory, or a name under $S/st-)
set -euo pipefail
. "$(dirname "$(readlink -f "$0")")/env.sh"
BOOTJAR=${BOOTJAR:-$RT14}
TREE=$1; W=$2; OSC=$3; [[ $OSC == */* ]] || OSC=$S/st-$3
OSCCP=$OSC/out2:$OSC/classes; OSCSRC=$OSC/src
rm -rf $W; mkdir -p $W; cd $W
cp -r $TREE/sources src; cp -r $TREE/newsources newsrc; chmod -R u+w src newsrc
mkdir -p fjbg-cls pnslib osc-nstools nslib nstools
. $HERE/nsc-patches.sh
cp -r $OSC/classes/. fjbg-cls/      # FJBG (+msil reader) built by the osc stage
# 1. pico-nslib: the Java parts of the new library
( cd src; find scala/runtime -name '*.java'; find scala/tools/util -maxdepth 1 -name '*.java'
  ls scala/*.java ) > pnslib.files
python3 -I $T/pizza2java.py src java-pnslib --classpath-src src --meta-out pnslib.meta.json $(cat pnslib.files)
$J/bin/javac -nowarn -encoding latin1 --release 8 -cp fjbg-cls -d pnslib $(find java-pnslib -name '*.java') > pnslib.log 2>&1 || { cat pnslib.log; exit 1; }
python3 -I $T/pico-classfiles.py pnslib pnslib.meta.json
for b in $(cd newsrc/scala && ls *.scala | sed 's/\.scala$//'); do rm -f pnslib/scala/$b.class pnslib/scala/$b\$*.class; done
# 2. osc-nstools: nsc compiled by the old compiler
( cd src; find scala/tools/nsc $(ls -d scala/tools/scalap 2>/dev/null) scala/reflect -name '*.scala' | grep -v '/ant/'
  ls scala/runtime/*.scala; find scala/runtime -mindepth 2 -name '*.scala' ) | sed 's|^|src/|' > osc.files
echo "== osc-nstools ($(wc -l < osc.files) files)"
$J8/bin/java -Xss64m -Xmx2g -cp $OSCCP scala.tools.scalac.Main -bootclasspath $BOOTJAR \
  -d osc-nstools -classpath osc-nstools:$OSCCP:$OSCSRC $(cat osc.files)
NSC0="$J8/bin/java -Xss64m -Xmx2g -cp osc-nstools:$OSCCP scala.tools.nsc.Main -bootclasspath $BOOTJAR"
# 3. nslib with nsc
echo "== nslib (Predef, ScalaRunTime)"
$NSC0 -nopredefs -d nslib -classpath pnslib:nslib:src:newsrc:fjbg-cls src/scala/Predef.scala src/scala/runtime/ScalaRunTime.scala
( cd src; find scala -name '*.scala' | grep -v '^scala/tools/\|^scala/dbc/' | grep -v '^scala/Predef.scala$\|^scala/runtime/ScalaRunTime.scala$' ) | sed 's|^|src/|' > nslib.files
echo "== nslib ($(wc -l < nslib.files) files)"
$NSC0 -d nslib -classpath pnslib:nslib:src:newsrc:fjbg-cls $(cat nslib.files)
# 4. nstools with nsc
( cd src; find scala/tools/nsc -name '*.scala' | grep -v '/ant/' ) | sed 's|^|src/|' > nstools.files
echo "== nstools ($(wc -l < nstools.files) files)"
$NSC0 -d nstools -classpath pnslib:nslib:nstools:fjbg-cls $(cat nstools.files)
# the stage layout of 2.x builds: out2 (library + compiler), classes (FJBG + MSIL reader)
mkdir -p out2 classes
cp -r pnslib/. out2/; cp -r nslib/. out2/; cp -r nstools/. out2/; cp -r fjbg-cls/. classes/
echo stage done
