#!/usr/bin/env bash
# bisect.sh PREV PREVCOMMIT TARGET : the farthest commit of (PREVCOMMIT, TARGET] (on the
# first-parent line) that stage PREV builds (auto.sh), probing K (default 6) commits at once;
# prints it, or "none".  The farthest good build is kept as st-pbgood (its commit in
# pbgood.commit, its auto.sh output in pbgood.txt), for climb.sh to take as the next stage;
# the logs of failed probes as fail-COMMIT.txt.
set -uo pipefail
. "$(dirname "$0")/env.sh"
mapfile -t C < <(git -C "$SCALA_GIT" rev-list --first-parent --reverse "$2..$3")
K=${K:-6}
lo=-1 hi=${#C[@]} # C[lo] known good (PREVCOMMIT), C[hi] bad or past the end
rm -f "$WORK/pbgood.commit"
first=1
while [ $((hi - lo)) -gt 1 ]; do
  # the probes: at most K, spread evenly; in the first round the target and steps of 16,
  # 32, 64, ... commits (most climbs end at the target or close to the previous stage)
  pts=() n=$((hi - lo - 1)) k=$K
  [ $n -lt $k ] && k=$n
  if [ $first = 1 ]; then
    d=16
    for _ in $(seq 2 $k); do
      [ $d -lt $n ] && pts+=($((lo + d)))
      d=$((d * 2))
    done
    pts+=($((hi - 1)))
  else
    for i in $(seq 1 $k); do pts+=($((lo + (n * i + k - 1) / k))); done
  fi
  first=0
  mapfile -t pts < <(printf '%s\n' "${pts[@]}" | sort -nu)
  j=0
  for p in "${pts[@]}"; do
    j=$((j + 1))
    (
      "$ROOT/scripts/auto.sh" "bis$j" "${C[p]}" "$1" > "$WORK/bisect-$j.txt" 2>&1
      echo "rc=$?" >> "$WORK/bisect-$j.txt"
    ) &
  done
  wait
  j=0 good=$lo bad=$hi gj=
  for p in "${pts[@]}"; do
    j=$((j + 1))
    if grep -q '^rc=0$' "$WORK/bisect-$j.txt"; then
      [ "$p" -gt $good ] && good=$p gj=$j
    else
      cp "$WORK/log-bis$j.txt" "$WORK/fail-${C[p]:0:10}.txt" 2> /dev/null
    fi
  done
  for p in "${pts[@]}"; do [ "$p" -gt $good ] && [ "$p" -lt $bad ] && bad=$p; done
  if [ $good -gt $lo ]; then
    rm -rf "$WORK/st-pbgood"
    mv "$WORK/st-bis$gj" "$WORK/st-pbgood"
    cp "$WORK/bisect-$gj.txt" "$WORK/pbgood.txt"
    echo "${C[good]}" > "$WORK/pbgood.commit"
  fi
  lo=$good hi=$bad
  echo "bisect: lo=$lo hi=$hi (${#C[@]}) probes=${pts[*]}" >&2
done
if [ $lo -ge 0 ]; then echo "${C[lo]}"; else
  echo none
  exit 1
fi
