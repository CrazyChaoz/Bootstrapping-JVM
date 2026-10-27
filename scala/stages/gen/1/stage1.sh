#!/usr/bin/env bash
# Stage 1: the Java (Pizza) boot compiler of 2004-02-19 (3b4e70e1bd, the last
# commit with a complete Java "scalacboot"), built by javac; it compiles the
# library and the Scala-written compiler parts (lib, scalac), which then
# compile themselves again (lib2, sc2).
# usage: stage1.sh SRCTREE WORKDIR
set -euo pipefail
. "$(dirname "$(readlink -f "$0")")/env.sh"
TREE=$1; W=$2
bash "$HERE/stage-java.sh" "$TREE" "$W"
cd $W; rm -rf lib2 sc2; mkdir lib2 sc2
$J8/bin/java -Xss32m -cp scalac:lib:classes scala.tools.scalac.Main -d lib2 -classpath lib2:classes:src $(cat sfiles.txt)
$J8/bin/java -Xss32m -cp scalac:lib:classes scala.tools.scalac.Main -d sc2 -classpath sc2:lib2:classes:src $(cat scfiles.txt)
echo stage done
