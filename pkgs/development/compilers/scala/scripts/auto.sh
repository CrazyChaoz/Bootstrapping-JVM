#!/usr/bin/env bash
# auto.sh NAME COMMIT PREV : build COMMIT as stage NAME by stage PREV in the first mode that
# works, then run its smoke test.  Prints "NAME: MODE ok" (or FAILED and the end of the log).
#
# The modes (AUTO_MODES, default "normal cf fresh"): those of chain/scala2.txt, and two
# that call for a generation of their own when they are the ones that work:
#   cflib   compiler first, with the library sources CFLIB (default scala/reflect) in the
#           compiler's run: CF_LIBRARY_SOURCES (2012)
#   unnest  locker from sources with single package clauses: LOCKER_SOURCE_PATCH unnest.sh
#           (2009)
set -uo pipefail
. "$(dirname "$0")/env.sh"
n=$1 commit=$2 prev=$3
use_generation "$GENERATION" || exit 1
ok() { grep -q 'stage done' "$WORK/log-$n.txt"; }
for mode in ${AUTO_MODES:-normal cf fresh}; do
  unpack "$n" "$commit" || exit 1
  case $mode in
    normal) build "$n" "$prev" ;;
    cf) COMPILER_FIRST=1 build "$n" "$prev" ;;
    cflib) COMPILER_FIRST=1 CF_LIBRARY_SOURCES=${CFLIB:-scala/reflect} build "$n" "$prev" ;;
    fresh) NO_FALLBACK=1 ARRAY_FROM_SOURCE=1 build "$n" "$prev" ;;
    unnest) LOCKER_SOURCE_PATCH=$ROOT/patches/locker/unnest.sh build "$n" "$prev" ;;
    *) echo "unknown mode $mode" >&2; exit 2 ;;
  esac
  if ok; then
    echo "$n: $mode ok"
    stage_test "$n" || { echo "$n: smoke test FAILED"; exit 1; }
    exit 0
  fi
done
echo "$n: FAILED"
shortlog < "$WORK/log-$n.txt" | tail -n "${TAILN:-20}"
exit 1
