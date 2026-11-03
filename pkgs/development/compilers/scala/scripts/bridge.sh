#!/usr/bin/env bash
# bridge.sh NAME COMMIT PREV FROM FILE... : build a bridge stage NAME by stage PREV, the tree
# of COMMIT with FILEs as of commit FROM -- or, for a single FILE ending in .sh, changed by
# that script of patches/bridges (SCRIPT TREE FROMTREE); see the bridge modes in
# chain/scala2.txt
set -uo pipefail
. "$(dirname "$0")/env.sh"
n=$1 commit=$2 prev=$3 from=$4
shift 4
use_generation "$GENERATION" || exit 1
unpack "$n" "$commit" || exit 1
if [ $# = 1 ] && [[ $1 == *.sh ]]; then
  unpack "$n-from" "$from" || exit 1
  bash "$ROOT/patches/bridges/$1" "$WORK/src-$n" "$WORK/src-$n-from" || exit 1
  rm -rf "$WORK/src-$n-from"
else
  for f in "$@"; do git -C "$SCALA_GIT" show "$from:$f" > "$WORK/src-$n/$f" || exit 1; done
fi
build "$n" "$prev"; rc=$?
shortlog < "$WORK/log-$n.txt" | tail -n "${TAILN:-15}"
echo "rc=$rc"
[ $rc = 0 ] && stage_test "$n"
exit $rc
