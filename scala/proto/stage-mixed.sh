#!/usr/bin/env bash
# Scala 1.x tree whose compiler is part Java (Pizza), part Scala.
# usage: stage-mixed.sh SRCTREE WORKDIR PREVCP [PREVMAIN]
# PREVCP: classpath of the previous compiler (incl. its runtime library)
set -euo pipefail
T=/home/kemp/ins/development/bootstrapping-gradle/tools
J=${J:-/nix/store/nkd7mzlsa4d113n0xwh98m4l6dx9bnax-openjdk-headless-21.0.12.1+1}
J8=${J8:-/nix/store/58fd0v0fp708ha13s5i7ib72a2kdh4lx-openjdk-8u504-b01}
S=/tmp/sc
TREE=$1; W=$2; PREVCP=$3; PREVMAIN=${4:-scala.tools.scalac.Main}
rm -rf $W; mkdir -p $W; cd $W
cp -r $TREE/sources src; chmod -R u+w src
cp -r $S/fjbg/src/fjbg fjbg
L=$TREE/config/list
. $S/work/common-patches.sh
mkdir -p meta-cls
python3 -I $T/pizza2java.py src meta-java $(cd src && find meta -name '*.java')
$J/bin/javac -nowarn -encoding latin1 --release 8 -d meta-cls $(find meta-java -name '*.java') 2>&1 | grep -v '^Note' || true
$J/bin/java -cp meta-cls meta.GenerateAll src generated.lst > /dev/null
lst() { grep -v '^#' $1 | sed 's/\s*$//' | grep .; }
{ lst $L/compiler.lst | sed 's|^|scalac/|'
  lst $L/lamplib.lst | sed 's|^|ch/epfl/lamp/|'
  lst $L/library.lst | grep '\.java$' | sed 's|^|scala/|'; } | grep -v -i 'msil\|CLR' > jfiles.txt
python3 -I $T/pizza2java.py src java --classpath-src fjbg --meta-out meta.json $(cat jfiles.txt)
mkdir -p classes
. $S/work/stubs.sh
$J/bin/javac -nowarn -encoding latin1 --release 8 -d classes $(find fjbg java stubs -name '*.java') 2>&1 | grep -v '^Note' | tee javac.log
grep -q error javac.log && exit 1
python3 -I $T/pico-classfiles.py classes meta.json
lst $L/library.lst | grep '\.scala$' | sed 's|^|src/scala/|' > sfiles.txt
lst $L/scalac.lst | sed 's|^|src/scala/tools/scalac/|' > scfiles.txt
sc() { $J8/bin/java -Xss32m -cp "$1" "$2" "${@:3}"; }
mkdir -p lib scalac
echo "== library with previous compiler"
sc "$PREVCP" $PREVMAIN -d lib -classpath lib:classes:src $(cat sfiles.txt)
echo "== compiler with previous compiler"
sc "$PREVCP" $PREVMAIN -d scalac -classpath scalac:lib:classes:src $(cat scfiles.txt)
echo "== self-host"
mkdir -p lib2 scalac2
sc scalac:lib:classes scala.tools.scalac.Main -d lib2 -classpath lib2:classes:src $(cat sfiles.txt)
sc scalac:lib:classes scala.tools.scalac.Main -d scalac2 -classpath scalac2:lib2:classes:src $(cat scfiles.txt)
echo stage done
