#!/usr/bin/env bash
# climb.sh PREVSTAGE PREVCOMMIT TARGET : step forward until TARGET is built
# (pbisect.sh, K builds in parallel; BISECT=bisect.sh for the sequential one)
# CLIMB_ENV="VAR=VALUE ...": builder environment for every probe, recorded with each stage
set -u
prev=$1; pc=$2; target=$(cd /tmp/sc/full && git rev-parse "$3^{commit}")
n=$(grep -c '^s' /tmp/sc/work/chain.txt)
while true; do
  next=$(/tmp/sc/work/${BISECT:-pbisect.sh} $prev $pc $target 2>>/tmp/sc/climb.log)
  if [ -z "$next" ] || [ "$next" = none ]; then
    # isolated broken commits: probe some following ones (in parallel), take the farthest good one
    next=; j=0; cs=()
    for c in $(cd /tmp/sc/full && git rev-list --first-parent --reverse $pc..$target | awk 'NR==2||NR==3||NR==5||NR==9||NR==17||NR==33||NR==65||NR==129'); do
      j=$((j+1)); cs+=($c)
      ( /tmp/sc/work/auto.sh lin$j $c $prev > /tmp/sc/linear-$j.txt 2>&1; echo "rc=$?" >> /tmp/sc/linear-$j.txt ) &
    done
    wait
    for j in $(seq ${#cs[@]} -1 1); do grep -q '^rc=0$' /tmp/sc/linear-$j.txt && { next=${cs[j-1]}; break; }; done
    [ -n "$next" ] || { echo "STUCK after $prev ($pc)"; exit 1; }
  fi
  n=$((n+1)); name=s$n
  if [ "$(cat /tmp/sc/pbgood.commit 2>/dev/null)" = "$next" ]; then
    # the probe build of pbisect.sh
    rm -rf /tmp/sc/st-$name; mv /tmp/sc/st-pbgood /tmp/sc/st-$name; cp /tmp/sc/pbgood.txt /tmp/sc/climb-$name.txt; rm /tmp/sc/pbgood.commit
  else
    /tmp/sc/work/auto.sh $name $next $prev > /tmp/sc/climb-$name.txt 2>&1 || { echo "rebuild of $name ($next) failed"; exit 1; }
  fi
  mode=normal; grep -q compiler-first /tmp/sc/climb-$name.txt && mode=cf; grep -q 'fresh ok' /tmp/sc/climb-$name.txt && mode=fresh; grep -q 'unnest ok' /tmp/sc/climb-$name.txt && mode=unnest
  extra=; grep -q 'cflib ok' /tmp/sc/climb-$name.txt && { mode=cf; extra=" CF_LIBSRC=${CFLIB:-scala/reflect/api,scala/reflect/makro}"; }
  echo "$name $next $prev $mode${CLIMB_ENV:+ $CLIMB_ENV}$extra" >> /tmp/sc/work/chain.txt
  echo "STEP $name $(cd /tmp/sc/full && git log -1 --format='%h %ad' --date=short $next) $mode"
  prev=$name; pc=$next
  [ "$next" = "$target" ] && { echo "REACHED $3"; exit 0; }
done
