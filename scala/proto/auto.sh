#!/usr/bin/env bash
# auto.sh NAME COMMIT PREVSTAGE : try normal, then compiler-first, then fresh (no fallback to the
# previous library, scala.Array from source: the 2.8 collections, 2009-05), then unnest (locker
# from sources with single package clauses, 2009-07); then hello test
# (BUILDER=stage2.sh: nsc-era stages, no compiler-first mode, hello2 test that must pass)
P=/tmp/sc/st-$3; PREV=$P/out2:$P/classes
[ "$3" = 1 ] && PREV=/tmp/sc/st1/sc2:/tmp/sc/st1/lib2:/tmp/sc/st1/classes
ok() { grep -q 'stage done' /tmp/sc/log-$1.txt; }
if TAILN=0 /tmp/sc/work/try.sh $1 $2 $PREV >/dev/null 2>&1 && ok $1; then echo "$1: normal ok"
elif COMPILER_FIRST=1 TAILN=0 /tmp/sc/work/try.sh $1 $2 $PREV >/dev/null 2>&1 && ok $1; then echo "$1: compiler-first ok"; echo "$1 CF" >> /tmp/sc/cf.txt
elif FALLBACK=none ARRAY_SRC=1 TAILN=0 /tmp/sc/work/try.sh $1 $2 $PREV >/dev/null 2>&1 && ok $1; then echo "$1: fresh ok"
elif UNNEST=1 TAILN=0 /tmp/sc/work/try.sh $1 $2 $PREV >/dev/null 2>&1 && ok $1; then echo "$1: unnest ok"
else echo "$1: FAILED"; grep -v '^Note\|not applicable' /tmp/sc/log-$1.txt | tail -${TAILN:-20}; exit 1; fi
if [ "${BUILDER:-}" = stage2.sh ]; then
  # (to a file first: a warning may come before the greeting, and `tee | head -1` cut it off)
  /tmp/sc/work/hello2.sh /tmp/sc/st-$1 > /tmp/sc/hello-$1.txt 2>&1; grep -m1 '^Hello from' /tmp/sc/hello-$1.txt
  grep -q '^Hello from' /tmp/sc/hello-$1.txt || { echo "$1: hello2 FAILED"; exit 1; }
else /tmp/sc/work/hello.sh /tmp/sc/st-$1 | head -1; fi
