#!/usr/bin/env bash
# Build a Scala 1.x tree module by module (Makefile order) using a previous
# compiler for the Scala sources, then rebuild the Scala parts with itself.
# usage: stage.sh SRCTREE WORKDIR PREVCP [PREVMAIN]
set -euo pipefail
. "$(dirname "$(readlink -f "$0")")/env.sh"
BOOTJAR=${BOOTJAR:-$RT14}
TREE=$1; W=$2; PREVCP=$3; PREVMAIN=${4:-scala.tools.scalac.Main}
rm -rf $W; mkdir -p $W; cd $W
cp -r $TREE/sources src; chmod -R u+w src
cp -r $FJBG_SRC fjbg
cp -r $MSIL_SRC/. fjbg/
# not needed by the compiler, and not compilable here (VJSAssembly: J# types)
rm -rf fjbg/ch/epfl/lamp/compiler/msil/tests fjbg/ch/epfl/lamp/compiler/msil/util/VJSAssembly.java
L=$TREE/config/list
. $HERE/common-patches.sh
[ -n "${EXTRA_PATCHES:-}" ] && . $EXTRA_PATCHES
# meta programs generate Tree.java, Function*.java, ...
mkdir -p meta-cls
python3 -I $T/pizza2java.py src meta-java $(cd src && find meta -name '*.java')
$J/bin/javac -nowarn -encoding latin1 --release 8 -d meta-cls $(find meta-java -name '*.java') 2>&1 | grep -v '^Note' || true
$J/bin/java -cp meta-cls meta.GenerateAll src generated.lst > /dev/null
lst() { [ -f $L/$1.lst ] && grep -v '^#' $L/$1.lst | sed 's/\s*$//' | grep . | sed "s|^|$2/|" | python3 -c '
import os,sys
for l in sys.stdin:
    p = os.path.normpath(l.strip())
    if os.path.exists(os.path.join("src", p)) or p.endswith(".java") and os.path.exists(os.path.join("src", p + ".tmpl")): print(p)
    else: print("warning: listed file missing:", p, file=sys.stderr)' || true; }
mkdir -p classes out stubs
. $HERE/stubs.sh
$J/bin/javac -nowarn -encoding latin1 --release 8 -d classes $(find fjbg stubs -name '*.java')
sc() { $J8/bin/java -Xss64m -Xmx2g -cp "$1" "$2" ${BOOTJAR:+-bootclasspath $BOOTJAR} "${@:3}"; }
CP=out:classes
if [ -n "${COMPILER_FIRST:-}" ]; then
  # 1. all Java, 2. compiler Scala parts with the previous compiler (against
  # the previous library), 3. the library with the new compiler
  for m in lamplib:ch/epfl/lamp library:scala util:scala/tools/util compiler:scalac scalac:scala/tools/scalac; do
    name=${m%%:*}; root=${m#*:}
    lst $name $root | grep -v -i "${EXCLUDE:-backend/msil}" > $name.files || true
    grep '\.java$' $name.files > $name.jfiles || true
    grep '\.scala$' $name.files > $name.sfiles || true
    sed 's|^|src/|' $name.sfiles > $name.sargs
    echo "== $name: $(wc -l < $name.jfiles) java, $(wc -l < $name.sfiles) scala"
  done
  cat lamplib.jfiles library.jfiles util.jfiles compiler.jfiles scalac.jfiles 2>/dev/null > all.jfiles
  python3 -I $T/pizza2java.py src java-all --classpath-src fjbg --classpath-src src --stub "${STUB:-/CLR[A-Za-z]*\.java$}" \
      --meta-out all.meta.json $(cat all.jfiles)
  mkdir -p jout cout lout
  $J/bin/javac -nowarn -encoding latin1 --release 8 -cp classes:$PREVCP -d jout $(find java-all -name '*.java') > all.javac.log 2>&1 || { cat all.javac.log; exit 1; }
  python3 -I $T/pico-classfiles.py jout all.meta.json
  # the compiler's Java classes without the new library's (package scala,
  # except scala.tools): the previous compiler uses the previous library
  mkdir -p jcomp; cp -r jout/. jcomp/
  find jcomp/scala -mindepth 1 -maxdepth 1 ! -name tools -exec rm -rf {} +
  echo "== compiler (Scala) with the previous compiler"
  PREVSRC=${PREVSRC:-$(dirname ${PREVCP%%:*})/src}
  sc "$PREVCP" $PREVMAIN -d cout -classpath cout:jcomp:classes:$PREVCP:$PREVSRC $(cat util.sargs scalac.sargs)
  echo "== library with the new compiler"
  sc cout:jcomp:classes:$PREVCP scala.tools.scalac.Main -d lout -classpath lout:jout:classes:src $(cat library.sargs)
  cp -r jout/. out/; cp -r lout/. out/; cp -r cout/. out/
else
for m in lamplib:ch/epfl/lamp library:scala util:scala/tools/util compiler:scalac scalac:scala/tools/scalac; do
  name=${m%%:*}; root=${m#*:}
  lst $name $root | grep -v -i "${EXCLUDE:-backend/msil}" > $name.files || true
  [ -s $name.files ] || continue
  grep '\.java$' $name.files > $name.jfiles || true
  grep '\.scala$' $name.files > $name.sfiles || true
  echo "== $name: $(wc -l < $name.jfiles) java, $(wc -l < $name.sfiles) scala"
  if [ -s $name.jfiles ]; then
    python3 -I $T/pizza2java.py src java-$name --classpath-src fjbg --classpath-src src --stub "${STUB:-/CLR[A-Za-z]*\.java$}" \
      --meta-out $name.meta.json $(cat $name.jfiles)
    mkdir -p jout
    $J/bin/javac -nowarn -encoding latin1 --release 8 -cp $CP -d jout $(find java-$name -name '*.java') > $name.javac.log 2>&1 || { cat $name.javac.log; exit 1; }
    python3 -I $T/pico-classfiles.py jout $name.meta.json
    cp -r jout/. out/
  fi
  if [ -s $name.sfiles ]; then
    sed 's|^|src/|' $name.sfiles > $name.sargs
    sc "$PREVCP" $PREVMAIN -d out -classpath $CP:src $(cat $name.sargs)
  fi
done
fi
echo "== self-host"
mkdir -p out2
cp -r jout/. out2/
for name in lamplib library util compiler scalac; do
  [ -s $name.sargs ] 2>/dev/null || continue
  sc out:classes scala.tools.scalac.Main -d out2 -classpath out2:classes:src $(cat $name.sargs)
done
echo stage done
