#!/usr/bin/env bash
# hello2.sh STAGE : a Scala 2 stage's compiler compiles and runs Hello2.scala
set -euo pipefail
. "$(dirname "$(readlink -f "$0")")/../builders/common.sh"
require RT14 RT15
D=$1 CP=$1/out2:$1/classes O=$(mktemp -d)
# (the Java 5 API, and -Ygenerics where the compiler has it, for the stages from 2007-12 on)
B=$RT14 G=
if grep -qs 'type Class\[T\]' "$D/src/library/scala/Predef.scala"; then
  B=$RT15
  ! grep -lqs -- -Ygenerics "$D"/out2/scala/tools/nsc/Settings*.class || G=-Ygenerics
fi
"$JDK8/bin/java" -Xss64m -cp "$CP" scala.tools.nsc.Main -bootclasspath "$B" $G -d "$O" -classpath "$CP" "$(dirname "$0")/Hello2.scala"
"$JDK8/bin/java" -cp "$O:$CP" Hello
rm -rf "$O"
