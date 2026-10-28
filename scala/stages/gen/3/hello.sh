#!/usr/bin/env bash
. "$(dirname "$(readlink -f "$0")")/env.sh"
# hello.sh STAGEDIR : compile+run a test program with the stage's self-hosted compiler
D=$1; CP=$D/out2:$D/classes; O=$(mktemp -d)
$J8/bin/java -Xss64m -cp $CP ${MAIN:-scala.tools.scalac.Main} -d $O -classpath $CP:$D/src $HERE/Hello.scala && $J8/bin/java -cp $O:$CP Hello
