#!/usr/bin/env bash
# hello.sh STAGEDIR : compile+run a test program with the stage's self-hosted compiler
J8=/nix/store/z2mxh5237w3dd8klbikm94x2wwipgc2y-openjdk-headless-8u504-b01
D=$1; CP=$D/out2:$D/classes; O=$(mktemp -d)
$J8/bin/java -Xss64m -cp $CP ${MAIN:-scala.tools.scalac.Main} -d $O -classpath $CP:$D/src /tmp/sc/st0/t/Hello.scala && $J8/bin/java -cp $O:$CP Hello
