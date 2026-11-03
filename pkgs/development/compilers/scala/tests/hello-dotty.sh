#!/usr/bin/env bash
# hello-dotty.sh STAGE : a dotty stage's compiler compiles and runs Hello2.scala
set -euo pipefail
. "$(dirname "$(readlink -f "$0")")/../builders/common.sh"
st=$1 d=$(mktemp -d)
jvm=$(cat "$st/jvm")
b=$st/scala2lib; [ ! -e "$st/scala2lib-boot" ] || b=$st/scala2lib-boot   # what programs build on
cp=$st/comp:$st/lib0:$st/tasty:$st/interfaces:$st/deps:$st/scala2lib
"$jvm" -Xss16m -cp "$cp" dotty.tools.dotc.Main -d "$d" -classpath "$st/lib:$b" "$(dirname "$0")/Hello2.scala"
"$jvm" -cp "$d:$st/lib:$b" Hello
rm -rf "$d"
