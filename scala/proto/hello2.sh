#!/usr/bin/env bash
J8=/nix/store/z2mxh5237w3dd8klbikm94x2wwipgc2y-openjdk-headless-8u504-b01
D=$1; CP=$D/out2:$D/classes; O=$(mktemp -d)
$J8/bin/java -Xss64m -cp $CP scala.tools.nsc.Main -bootclasspath ${BOOTJAR:-/tmp/sc/rt14b.jar} -d $O -classpath $CP /tmp/sc/Hello2.scala && $J8/bin/java -cp $O:$CP Hello
