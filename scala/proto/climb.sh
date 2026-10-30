#!/usr/bin/env bash
# climb.sh PREV PREVCOMMIT TARGET : step forward from stage PREV (of commit PREVCOMMIT) to the
# commit TARGET, each step the farthest commit the last stage builds (bisect.sh), and record
# the new stages in chain.txt:
#
#   NAME COMMIT PREV MODE  # GENERATION [what the stage needs beyond it]
#
# A merge that does not build is climbed around: up its merged branch from the stage at the
# branch's base, then the merge from the branch's end (upstream updated the reference compiler
# on such branches, fe1110f2fe 2012-04).  Isolated broken commits are stepped over: some of
# the following commits are probed and the farthest good one taken.
set -uo pipefail
. "$(dirname "$0")/env.sh"
CHAIN=$WORK/chain.txt
touch "$CHAIN"
prev=$1 pc=$2 target=$(git -C "$SCALA_GIT" rev-parse "$3^{commit}")

g() { git -C "$SCALA_GIT" "$@"; }
last_stage() { awk '$1 ~ /^s/ { s = $1 } END { print s }' "$CHAIN"; }
next_name() { echo "s$(($(grep -c '^s' "$CHAIN") + 1))"; }
stage_at() { awk -v c="$1" '$2 == c && $1 ~ /^s/ { s = $1 } END { print s }' "$CHAIN"; }
# record NAME COMMIT PREV AUTOLOG : the stage line, its mode as auto.sh found it
record() {
  local mode extra=
  mode=$(sed -n "s/^$1: \([a-z]*\) ok$/\1/p" "$4")
  case $mode in
    cflib) mode=cf extra=" CF_LIBRARY_SOURCES=${CFLIB:-scala/reflect}" ;;
    unnest) mode=normal extra=" LOCKER_SOURCE_PATCH=locker/unnest.sh" ;;
  esac
  echo "$1 $2 $3 $mode  # $GENERATION$extra" >> "$CHAIN"
  echo "STEP $1 $(g log -1 --format='%h %ad' --date=short "$2") $mode$extra"
}

while true; do
  next=$("$ROOT/scala/proto/bisect.sh" "$prev" "$pc" "$target" 2>> "$WORK/climb.log")
  if { [ -z "$next" ] || [ "$next" = none ]; } && [ -z "${SIDE:-}" ]; then
    m=$(g rev-list --first-parent --reverse "$pc..$target" | head -1)
    for side in $(g rev-list --parents -n1 "$m" | cut -d' ' -f3-); do
      b=$(g merge-base "$pc" "$side")
      bs=$(stage_at "$b")
      if [ -z "$bs" ]; then
        # the branch's base not a stage yet: climbed to first, from the last stage before it
        read -r as ac < <(awk '$1 ~ /^s/ { print $1, $2 }' "$CHAIN" | tac | while read -r x y; do
          g merge-base --is-ancestor "$y" "$b" && { echo "$x $y"; break; }
        done)
        [ -n "${as:-}" ] || continue
        echo "BASE $(g log -1 --format=%h "$b") from $as"
        out=$(SIDE=1 "$0" "$as" "$ac" "$b")
        rc=$?
        echo "$out" | grep -v '^REACHED'
        [ $rc = 0 ] || continue
        bs=$(stage_at "$b")
        [ -n "$bs" ] || continue
      fi
      echo "SIDE $(g log -1 --format=%h "$side") from $bs"
      out=$(SIDE=1 "$0" "$bs" "$b" "$side")
      rc=$?
      echo "$out" | grep -v '^REACHED'
      [ $rc = 0 ] || continue
      sp=$(last_stage) name=$(next_name)
      if "$ROOT/scala/proto/auto.sh" "$name" "$m" "$sp" > "$WORK/climb-$name.txt" 2>&1; then
        record "$name" "$m" "$sp" "$WORK/climb-$name.txt"
        prev=$name pc=$m
        [ "$m" = "$target" ] && { echo "REACHED $3"; exit 0; }
        continue 2
      fi
    done
  fi
  if [ -z "$next" ] || [ "$next" = none ]; then
    next='' j=0 cs=()
    for c in $(g rev-list --first-parent --reverse "$pc..$target" | awk 'NR==2||NR==3||NR==5||NR==9||NR==17||NR==33||NR==65||NR==129'); do
      j=$((j + 1)) cs+=("$c")
      (
        "$ROOT/scala/proto/auto.sh" "lin$j" "$c" "$prev" > "$WORK/linear-$j.txt" 2>&1
        echo "rc=$?" >> "$WORK/linear-$j.txt"
      ) &
    done
    wait
    for j in $(seq ${#cs[@]} -1 1); do
      grep -q '^rc=0$' "$WORK/linear-$j.txt" && { next=${cs[j - 1]}; break; }
    done
    [ -n "$next" ] || { echo "STUCK after $prev ($pc)"; exit 1; }
  fi
  name=$(next_name)
  if [ "$(cat "$WORK/pbgood.commit" 2> /dev/null)" = "$next" ]; then
    # bisect.sh's probe build of it
    rm -rf "$WORK/st-$name"
    mv "$WORK/st-pbgood" "$WORK/st-$name"
    sed "s/^bis[0-9]*:/$name:/" "$WORK/pbgood.txt" > "$WORK/climb-$name.txt"
    rm "$WORK/pbgood.commit"
  else
    "$ROOT/scala/proto/auto.sh" "$name" "$next" "$prev" > "$WORK/climb-$name.txt" 2>&1 || { echo "rebuild of $name ($next) failed"; exit 1; }
  fi
  record "$name" "$next" "$prev" "$WORK/climb-$name.txt"
  prev=$name pc=$next
  [ "$next" = "$target" ] && { echo "REACHED $3"; exit 0; }
done
