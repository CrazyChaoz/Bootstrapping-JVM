#!/usr/bin/env bash
# hello-dotty.sh STAGE : the dotty stage's compiler compiles and runs Hello2.scala
set -euo pipefail
. "$(dirname "$(readlink -f "$0")")/env.sh"
st=$1 d=$(mktemp -d)
cp=$st/comp:$st/lib:$st/interfaces:$st/deps:$st/scala2lib
$J8/bin/java -Xss16m -cp $cp dotty.tools.dotc.Main -d $d -classpath $st/lib:$st/scala2lib "$(dirname "$(readlink -f "$0")")/Hello2.scala"
$J8/bin/java -cp $d:$st/lib:$st/scala2lib Hello
rm -rf $d
