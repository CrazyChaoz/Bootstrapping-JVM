#!/usr/bin/env bash
# hello-dotty.sh STAGE : the dotty stage's compiler compiles and runs Hello2.scala
set -euo pipefail
. "$(dirname "$(readlink -f "$0")")/env.sh"
st=$1 d=$(mktemp -d)
jvm=$(cat $st/jvm 2>/dev/null || echo $J8/bin/java)   # (older stages: JDK 8)
b=$st/scala2lib; [ ! -e $st/scala2lib-boot ] || b=$st/scala2lib-boot   # what programs build on
cp=$st/comp:$st/lib0:$st/tasty:$st/interfaces:$st/deps:$st/scala2lib
$jvm -Xss16m -cp $cp dotty.tools.dotc.Main -d $d -classpath $st/lib:$b "$(dirname "$(readlink -f "$0")")/Hello2.scala"
$jvm -cp $d:$st/lib:$b Hello
rm -rf $d
