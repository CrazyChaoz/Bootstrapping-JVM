#!/usr/bin/env bash
# pbisect.sh PREVSTAGE PREVCOMMIT TARGETCOMMIT : like bisect.sh (the farthest commit in
# (PREVCOMMIT, TARGETCOMMIT] that builds with PREVSTAGE), probing K=${K:-6} commits at once
cd /tmp/sc/full
mapfile -t C < <(git rev-list --first-parent --reverse $2..$3)
K=${K:-6}
lo=-1; hi=${#C[@]}; rm -f /tmp/sc/pbgood.commit   # C[lo] known good (prev), C[hi] bad or past the end
first=1
while [ $((hi-lo)) -gt 1 ]; do
  # probe points (at most K)
  pts=(); n=$((hi-lo-1)); k=$K; [ $n -lt $k ] && k=$n
  if [ $first = 1 ]; then
    # first round: the target and steps growing exponentially (16, 32, 64, ...)
    d=16; for i in $(seq 2 $k); do [ $d -lt $n ] && pts+=($((lo + d))); d=$((d*2)); done
    pts+=($((hi-1)))
  else
    for i in $(seq 1 $k); do pts+=($((lo + (n*i + k - 1)/k))); done
  fi
  first=0
  pts=($(printf '%s\n' "${pts[@]}" | sort -nu))
  j=0
  for p in "${pts[@]}"; do
    j=$((j+1)); ( /tmp/sc/work/auto.sh bis$j ${C[p]} $1 > /tmp/sc/bisect-$j.txt 2>&1; echo "rc=$?" >> /tmp/sc/bisect-$j.txt ) &
  done
  wait
  # results (the failed probes' logs kept as /tmp/sc/fail-COMMIT.txt)
  j=0; for p in "${pts[@]}"; do j=$((j+1)); grep -q '^rc=0$' /tmp/sc/bisect-$j.txt || cp /tmp/sc/log-bis$j.txt /tmp/sc/fail-${C[p]:0:10}.txt 2>/dev/null; done
  j=0; good=$lo; bad=$hi
  for p in "${pts[@]}"; do
    j=$((j+1))
    grep -q '^rc=0$' /tmp/sc/bisect-$j.txt && [ $p -gt $good ] && { good=$p; gj=$j; }
  done
  for p in "${pts[@]}"; do [ $p -gt $good ] && [ $p -lt $bad ] && bad=$p; done
  # keep the farthest good build: climb.sh takes it as the new stage
  if [ $good -gt $lo ]; then
    rm -rf /tmp/sc/st-pbgood; mv /tmp/sc/st-bis$gj /tmp/sc/st-pbgood
    cp /tmp/sc/bisect-$gj.txt /tmp/sc/pbgood.txt; echo ${C[good]} > /tmp/sc/pbgood.commit
  fi
  lo=$good; hi=$bad
  echo "pbisect: lo=$lo hi=$hi (${#C[@]}) probes=${pts[*]}" >&2
done
[ $lo -ge 0 ] && echo ${C[lo]} || { echo none; exit 1; }
