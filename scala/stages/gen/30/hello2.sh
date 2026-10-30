#!/usr/bin/env bash
. "$(dirname "$(readlink -f "$0")")/env.sh"
# hello2.sh STAGEDIR : compile and run Hello2.scala with a 2.x stage
D=$1; CP=$D/out2:$D/classes; O=$(mktemp -d)
B=$RT14; G=
if grep -q 'type Class\[T\]' $D/src/library/scala/Predef.scala 2>/dev/null; then
  B=$RT15; grep -lq -- -Ygenerics $D/out2/scala/tools/nsc/Settings*.class && G=-Ygenerics
fi
$J8/bin/java -Xss64m -cp $CP scala.tools.nsc.Main -bootclasspath ${BOOTJAR:-$B} $G -d $O -classpath $CP $HERE/Hello2.scala && $J8/bin/java -cp $O:$CP Hello
