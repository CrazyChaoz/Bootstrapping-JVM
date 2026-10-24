#!/usr/bin/env bash
# try.sh NAME COMMIT PREVCP  -> builds /tmp/sc/st-NAME
set -uo pipefail
cd /tmp/sc; rm -rf src-$1 && mkdir src-$1 && (cd full && git archive $2) | tar -x -C src-$1
./work/stage.sh /tmp/sc/src-$1 /tmp/sc/st-$1 "$3" > /tmp/sc/log-$1.txt 2>&1; rc=$?
grep -v '^Note\|not applicable' /tmp/sc/log-$1.txt | tail -${TAILN:-25}; echo "rc=$rc"
