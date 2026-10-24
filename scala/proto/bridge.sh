#!/usr/bin/env bash
# bridge.sh NAME BASECOMMIT FROMCOMMIT PREVCP FILE... : stage of BASECOMMIT with FILEs taken
# from FROMCOMMIT -- stands in for the unpublished intermediate compilers behind STARR updates
set -uo pipefail
n=$1 base=$2 from=$3 prev=$4; shift 4
cd /tmp/sc; rm -rf src-$n && mkdir src-$n && (cd full && git archive $base) | tar -x -C src-$n
for f in "$@"; do (cd full && git show $from:$f) > src-$n/$f; done
./work/${BUILDER:-stage2.sh} /tmp/sc/src-$n /tmp/sc/st-$n "$prev" > /tmp/sc/log-$n.txt 2>&1; rc=$?
grep -v '^Note\|not applicable\|warning' /tmp/sc/log-$n.txt | grep -v '^ *^\|^      ' | tail -${TAILN:-15}; echo "rc=$rc"
