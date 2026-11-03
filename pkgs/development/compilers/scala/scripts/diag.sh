#!/usr/bin/env bash
# diag.sh [TARGET] : build the commit after the last stage of chain.txt on the way to TARGET
# (default: the branch checked out in full/), normally and compiler first, and show the first
# errors (N lines, default 15)
set -uo pipefail
. "$(dirname "$0")/env.sh"
read -r s c _ < <(grep '^s' "$WORK/chain.txt" | tail -1)
n=$(git -C "$SCALA_GIT" rev-list --first-parent --reverse "$c..${1:-HEAD}" | head -1)
echo "after $s: $(git -C "$SCALA_GIT" log -1 --format='%h %ad %s' --date=short "$n")"
git -C "$SCALA_GIT" show --stat --format= "$n" | tail -8
use_generation "$GENERATION" || exit 1
for cf in "" 1; do
  unpack diag "$n" || exit 1
  COMPILER_FIRST=$cf build diag "$s"
  echo "--- COMPILER_FIRST=$cf"
  shortlog < "$WORK/log-diag.txt" | grep -v 'I assume\|Therefore I wrap\|If that.s not what\|^  [a-z]' | head -n "${N:-15}"
  grep -q 'stage done' "$WORK/log-diag.txt" && { stage_test diag; break; }
done
