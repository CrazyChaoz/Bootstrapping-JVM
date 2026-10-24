#!/usr/bin/env bash
# hello2.sh STAGEDIR : compile and run Hello2.scala with a 2.x stage
J8=/nix/store/z2mxh5237w3dd8klbikm94x2wwipgc2y-openjdk-headless-8u504-b01
D=$1; CP=$D/out2:$D/classes; O=$(mktemp -d)
B=/tmp/sc/rt14b.jar; G=
if grep -q 'type Class\[T\]' $D/src/library/scala/Predef.scala 2>/dev/null; then
  B=/tmp/sc/rt15.jar; grep -lq -- -Ygenerics $D/out2/scala/tools/nsc/Settings*.class && G=-Ygenerics
fi
$J8/bin/java -Xss64m -cp $CP scala.tools.nsc.Main -bootclasspath ${BOOTJAR:-$B} $G -d $O -classpath $CP /tmp/sc/Hello2.scala && $J8/bin/java -cp $O:$CP Hello
