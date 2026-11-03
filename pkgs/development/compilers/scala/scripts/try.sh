#!/usr/bin/env bash
# try.sh NAME COMMIT PREV : build COMMIT as stage NAME by stage PREV (see env.sh); prints the
# end of the log (TAILN lines, default 25) and the builder's exit status
set -uo pipefail
. "$(dirname "$0")/env.sh"
use_generation "$GENERATION" || exit 1
unpack "$1" "$2" || exit 1
build "$1" "$3"; rc=$?
shortlog < "$WORK/log-$1.txt" | tail -n "${TAILN:-25}"
echo "rc=$rc"
exit $rc
