#!/usr/bin/env bash
# stage.sh SRC PREV OUT : PiCo compiled by the compiler PREV (a class path), then by itself,
# and again: the last two results must be the same class files, and they go to OUT.
#
# Inputs: JDK.
set -euo pipefail
. "$(dirname "$(readlink -f "$0")")/common.sh"
SRC=$1 PREV=$2 OUT=$3
W=$(mktemp -d)
trap 'rm -rf "$W"' EXIT

for n in 1 2 3; do
  pico_compile "$PREV" "$SRC" "$W/c$n"
  pico_resources "$SRC" "$W/c$n"     # (a compiler needs them to run)
  PREV=$W/c$n
done
diff -r "$W/c2" "$W/c3"
if diff -rq "$W/c1" "$W/c2" > /dev/null; then
  echo "(the boot compiler compiled it to the same class files)"
fi
mkdir -p "$OUT"
cp -r "$W/c2/." "$OUT/"
