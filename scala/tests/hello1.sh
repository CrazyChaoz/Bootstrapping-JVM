#!/usr/bin/env bash
# hello1.sh STAGE : a Scala 1.x stage's compiler compiles and runs Hello1.scala
set -euo pipefail
. "$(dirname "$(readlink -f "$0")")/../builders/common.sh"
D=$1 CP=$1/out2:$1/classes O=$(mktemp -d)
"$JDK8/bin/java" -Xss64m -cp "$CP" scala.tools.scalac.Main -d "$O" -classpath "$CP:$D/src" "$(dirname "$0")/Hello1.scala"
"$JDK8/bin/java" -cp "$O:$CP" Hello
rm -rf "$O"
