#!/usr/bin/env bash
# hello.sh STAGEDIR : compile+run a test program with the stage's self-hosted compiler
J8=/nix/store/58fd0v0fp708ha13s5i7ib72a2kdh4lx-openjdk-8u504-b01
D=$1; CP=$D/out2:$D/classes; O=$(mktemp -d)
$J8/bin/java -Xss64m -cp $CP ${MAIN:-scala.tools.scalac.Main} -d $O -classpath $CP /tmp/sc/st0/t/Hello.scala && $J8/bin/java -cp $O:$CP Hello
