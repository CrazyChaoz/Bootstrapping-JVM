#!/usr/bin/env bash
# lib.sh OUT: scala-library-bootstrapped's classes (Scala by Nix's d74 compiler, Java by javac 17)
set -euo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
. "$HERE/env.sh"
OVL=${OVERLAY:-$W/overlay-gc}
[ -d "$OVL" ] || NO_STRONG=1 PARALLEL_PICKLING=1 bash "$HERE/overlay.sh" "$OVL" >/dev/null
CCP_PRE=${CCP_PRE:-}$OVL:
JOPTS="${JOPTS:--Xmx6g} -Ddotty.repro.inlineInfo.default=fresh -Ddotty.repro.inlineInfo=$(grep -v '^#' "$HERE/inlineinfo-replay.txt" | paste -sd,)"
. "$HERE/sc.sh"
OUT=$(realpath -m "$1"); rm -rf "$OUT"; mkdir -p "$OUT"
cd "$SRC"
find library/src library/src-bootstrapped \( -name '*.scala' -o -name '*.java' \) | LC_ALL=C sort > "$OUT.srcs"
dotc "${OPTS[@]}" ${EXTRA:-} -opt '-opt-inline:**,!java.**' -sourcepath "$SRC/library/src:$SRC/library/src-bootstrapped" \
  -classpath "$OUT" -d "$OUT" @"$OUT.srcs"
grep '\.java$' "$OUT.srcs" > "$OUT.java"
"$JDK17/bin/javac" -Xlint:unchecked -Xlint:deprecation --release 17 -nowarn -classpath "$OUT" -d "$OUT" @"$OUT.java" 2>&1 | tail -5
