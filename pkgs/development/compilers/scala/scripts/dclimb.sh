#!/usr/bin/env bash
# dclimb.sh FROM [TO] : build the stages FROM..TO of the dotty chain, chain/dotty.txt,
# each by its PREV stage (d0: by the Scala 2 stage of its LIBRARY) with the Scala 2 library
# stages it names (the stages of chain/scala2.txt at those release tags, built in the
# work directory beforehand), and run their smoke tests.  Progress goes to dclimb.out.
set -uo pipefail
. "$(dirname "$0")/env.sh"
from=$1 to=${2:-}
# scala2_stage VERSION : the stage of scala2.txt at tag vVERSION (the last of that commit)
scala2_stage() {
  local c
  c=$(git -C "$SCALA_GIT" rev-parse -q --verify "v$1^{commit}") || return
  awk -v c="$c" '$1 != "generation" && $2 == c { s = $1 } END { print s }' "$ROOT/chain/scala2.txt"
}
on=
while read -r d c p v lib boot; do
  [ "$d" = "$from" ] && on=1
  [ -n "$on" ] || continue
  s=$(scala2_stage "$lib") sb=$(scala2_stage "${boot:-$lib}")
  for x in "$s" "$sb"; do
    [ -d "$WORK/st-$x/out2" ] || { echo "$d: Scala 2 stage ${x:-of $lib} not built" >> "$WORK/dclimb.out"; exit 1; }
  done
  if [ "$p" = - ]; then prev=st-$s; else prev=st-$p; fi
  echo "BUILD $d $v ($c) by $prev, library $lib = $s, boot library ${boot:-$lib} = $sb" >> "$WORK/dclimb.out"
  rm -rf "$WORK/dtree-$d" "$WORK/st-$d"
  mkdir "$WORK/dtree-$d"
  git -C "$DOTTY_GIT" archive "$c" | tar -x -C "$WORK/dtree-$d"
  if SCALA2LIB=$WORK/st-$s SCALA2LIB_BOOT=$WORK/st-$sb DOTTY_VERSION=$v timeout 7200 \
    bash "$ROOT/builders/dotty.sh" "$WORK/dtree-$d" "$WORK/st-$d" "$WORK/$prev" > "$WORK/log-$d.txt" 2>&1 &&
    bash "$ROOT/tests/hello-dotty.sh" "$WORK/st-$d" > "$WORK/hello-$d.txt" 2>&1 &&
    grep -q '^Hello from' "$WORK/hello-$d.txt"; then
    echo "OK $d $v" >> "$WORK/dclimb.out"
    rm -rf "$WORK/dtree-$d"
  else
    echo "FAILED $d $v" >> "$WORK/dclimb.out"
    exit 1
  fi
  [ "$d" = "$to" ] && break
done < <(grep -v '^#\|^$' "$ROOT/chain/dotty.txt")
echo "DONE" >> "$WORK/dclimb.out"
