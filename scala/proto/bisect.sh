#!/usr/bin/env bash
# bisect.sh PREVSTAGE PREVCOMMIT TARGETCOMMIT : find the farthest commit in
# (PREVCOMMIT, TARGETCOMMIT] that builds with PREVSTAGE (auto mode); prints it
cd /tmp/sc/full
mapfile -t C < <(git rev-list --first-parent --reverse $2..$3)
lo=-1; hi=${#C[@]}   # C[lo] known good (prev), C[hi] unknown/bad
# try the target first
if /tmp/sc/work/auto.sh bis ${C[hi-1]} $1 > /tmp/sc/bisect-last.txt 2>&1; then echo ${C[hi-1]}; exit 0; fi
hi=$((hi-1))
while [ $((hi-lo)) -gt 1 ]; do
  mid=$(((lo+hi)/2))
  if /tmp/sc/work/auto.sh bis ${C[mid]} $1 > /tmp/sc/bisect-last.txt 2>&1; then lo=$mid; else hi=$mid; fi
  echo "bisect: lo=$lo hi=$hi (${#C[@]})" >&2
done
[ $lo -ge 0 ] && echo ${C[lo]} || { echo none; exit 1; }
