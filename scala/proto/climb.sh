#!/usr/bin/env bash
# climb.sh PREVSTAGE PREVCOMMIT TARGET : step forward until TARGET is built
set -u
prev=$1; pc=$2; target=$(cd /tmp/sc/full && git rev-parse "$3^{commit}")
n=$(grep -c '^s' /tmp/sc/work/chain.txt)
while true; do
  next=$(/tmp/sc/work/bisect.sh $prev $pc $target 2>>/tmp/sc/climb.log)
  if [ -z "$next" ] || [ "$next" = none ]; then
    # isolated broken commits: probe the following ones linearly
    next=
    for c in $(cd /tmp/sc/full && git rev-list --first-parent --reverse $pc..$target | awk 'NR==2||NR==3||NR==5||NR==9||NR==17||NR==33||NR==65||NR==129'); do
      if /tmp/sc/work/auto.sh bis $c $prev > /tmp/sc/bisect-last.txt 2>&1; then next=$c; break; fi
    done
    [ -n "$next" ] || { echo "STUCK after $prev ($pc)"; exit 1; }
  fi
  n=$((n+1)); name=s$n
  /tmp/sc/work/auto.sh $name $next $prev > /tmp/sc/climb-$name.txt 2>&1 || { echo "rebuild of $name ($next) failed"; exit 1; }
  mode=normal; grep -q compiler-first /tmp/sc/climb-$name.txt && mode=cf
  echo "$name $next $prev $mode" >> /tmp/sc/work/chain.txt
  echo "STEP $name $(cd /tmp/sc/full && git log -1 --format='%h %ad' --date=short $next) $mode"
  prev=$name; pc=$next
  [ "$next" = "$target" ] && { echo "REACHED $3"; exit 0; }
done
