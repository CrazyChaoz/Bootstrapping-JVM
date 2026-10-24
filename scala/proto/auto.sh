#!/usr/bin/env bash
# auto.sh NAME COMMIT PREVSTAGE : try normal, then compiler-first; then hello test
P=/tmp/sc/st-$3; PREV=$P/out2:$P/classes
[ "$3" = 1 ] && PREV=/tmp/sc/st1/sc2:/tmp/sc/st1/lib2:/tmp/sc/st1/classes
if TAILN=0 /tmp/sc/work/try.sh $1 $2 $PREV >/dev/null 2>&1 && grep -q 'stage done' /tmp/sc/log-$1.txt; then echo "$1: normal ok"
elif COMPILER_FIRST=1 TAILN=0 /tmp/sc/work/try.sh $1 $2 $PREV >/dev/null 2>&1 && grep -q 'stage done' /tmp/sc/log-$1.txt; then echo "$1: compiler-first ok"; echo "$1 CF" >> /tmp/sc/cf.txt
else echo "$1: FAILED"; grep -v '^Note\|not applicable' /tmp/sc/log-$1.txt | tail -${TAILN:-20}; exit 1; fi
/tmp/sc/work/hello.sh /tmp/sc/st-$1 | head -1
