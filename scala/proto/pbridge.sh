#!/usr/bin/env bash
# pbridge.sh NAME BASECOMMIT PREVSTAGE PATCH... : stage of BASECOMMIT with patches from
# scala/stages/patches (backports standing in for unpublished intermediate compilers)
set -uo pipefail
n=$1 base=$2 prev=$3; shift 3
P=/home/kemp/ins/development/bootstrapping-gradle/scala/stages/patches
cd /tmp/sc; rm -rf src-$n && mkdir src-$n && (cd full && git archive $base) | tar -x -C src-$n
for p in "$@"; do patch -s -d src-$n -p1 < $P/$p.patch || exit 1; done
./work/${BUILDER:-stage2.sh} /tmp/sc/src-$n /tmp/sc/st-$n "/tmp/sc/st-$prev/out2:/tmp/sc/st-$prev/classes" > /tmp/sc/log-$n.txt 2>&1; rc=$?
grep -v '^Note\|not applicable\|warning' /tmp/sc/log-$n.txt | grep -v '^ *^\|^      ' | tail -${TAILN:-15}; echo "rc=$rc"
[ $rc = 0 ] && /tmp/sc/work/hello2.sh /tmp/sc/st-$n | head -1
