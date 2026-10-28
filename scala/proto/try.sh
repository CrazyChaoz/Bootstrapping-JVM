#!/usr/bin/env bash
# try.sh NAME COMMIT PREVCP  -> builds /tmp/sc/st-NAME (killed after TRY_TIMEOUT seconds, default 3600:
# some failing builds hang printing their type errors)
set -uo pipefail
cd /tmp/sc; rm -rf src-$1 && mkdir src-$1 && (cd full && git archive $2) | tar -x -C src-$1
timeout ${TRY_TIMEOUT:-3600} ./work/${BUILDER:-stage.sh} /tmp/sc/src-$1 /tmp/sc/st-$1 "$3" > /tmp/sc/log-$1.txt 2>&1; rc=$?
grep -v '^Note\|not applicable' /tmp/sc/log-$1.txt | tail -${TAILN:-25}; echo "rc=$rc"
