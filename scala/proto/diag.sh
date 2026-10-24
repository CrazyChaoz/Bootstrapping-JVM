#!/usr/bin/env bash
# diag.sh [TARGET] : build the commit after the last chain stage (normal + CF), show first errors
cd /tmp/sc/full; P=$(tail -1 /tmp/sc/work/chain.txt); s=${P%% *}; c=$(echo $P | cut -d' ' -f2)
n=$(git rev-list --first-parent --reverse $c..${1:-v2.7.7} | head -1)
echo "after $s: $(git log -1 --format='%h %ad %s' --date=short $n)"; git show --stat --format= $n | tail -8
cd /tmp/sc/work
for m in "" 1; do
  COMPILER_FIRST=$m BUILDER=stage2.sh TAILN=0 ./try.sh bis $n /tmp/sc/st-$s/out2:/tmp/sc/st-$s/classes >/dev/null 2>&1
  echo "--- CF=$m"; grep -v '^Note\|not applicable\|warning\|^ *\^' /tmp/sc/log-bis.txt | grep -v '^      \|^  [a-z]' | head -${N:-15}
  grep -q 'stage done' /tmp/sc/log-bis.txt && { ./hello2.sh /tmp/sc/st-bis 2>&1 | head -2; break; }
done
