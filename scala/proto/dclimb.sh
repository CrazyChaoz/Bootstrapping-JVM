#!/usr/bin/env bash
# dclimb.sh FROM [TO] : builds the dotty chain stages FROM..TO of /tmp/sc/dwork/dchain.txt
# (NAME COMMIT PREV VERSION ...), each by its PREV stage (d0: by the Scala 2 stage of its
# scalacVersion) on the Scala 2 library stage dlib.txt names; waits for Scala 2 stages
# the 2.13 climb has not made yet.  Output: /tmp/sc/dclimb.out, logs /tmp/sc/log-dN.txt.
cd /tmp/sc
from=$1 to=${2:-}
s2stage() { # Scala 2 stage at tag v$1 (chain.txt), empty if none yet
  local c; c=$(git -C full rev-parse -q --verify "v$1^{commit}") || return
  awk -v c=$c '$2==c{print $1}' work/chain.txt | tail -1; }
on=
while read -r d c p v rest; do
  [ "$d" = "$from" ] && on=1; [ -n "$on" ] || continue
  lv=$(awk -v d=$d '$1==d{print $2}' dwork/dlib.txt)
  until s=$(s2stage $lv); [ -n "$s" ] && [ -d st-$s/out2 ]; do sleep 60; done
  if [ "$p" = - ]; then prev=st-$s; else prev=st-$p; fi
  echo "BUILD $d $v ($c) by $prev, scala-library $lv = $s" >> dclimb.out
  rm -rf dtree-$d st-$d; mkdir dtree-$d; git -C dotty archive $c | tar x -C dtree-$d
  if SCALA2LIB=/tmp/sc/st-$s timeout 7200 work/stage-dotty.sh /tmp/sc/dtree-$d /tmp/sc/st-$d /tmp/sc/$prev > log-$d.txt 2>&1 \
     && work/hello-dotty.sh /tmp/sc/st-$d > hello-$d.txt 2>&1 && grep -q '^Hello from' hello-$d.txt; then
    echo "OK $d $v" >> dclimb.out; rm -rf dtree-$d
  else
    echo "FAILED $d $v" >> dclimb.out; exit 1
  fi
  [ "$d" = "$to" ] && break
done < dwork/dchain.txt
echo "DONE" >> dclimb.out
