#!/usr/bin/env bash
# boot.sh SRC OUT : the boot compiler.  SRC is JaCo's sources/ directory, which is written in
# PiCo; TRANSLATOR (the Pizza chain's tools/pizza2java.py) translates it to Java and
# javac compiles that.  This compiler only has to compile PiCo once (stage.sh).
#
# Inputs: JDK, TRANSLATOR, and python3 on the PATH.
set -euo pipefail
. "$(dirname "$(readlink -f "$0")")/common.sh"
SRC=$1 OUT=$2
W=$(mktemp -d)
trap 'rm -rf "$W"' EXIT

python3 -I "$TRANSLATOR" "$SRC" "$W/java" $(pico_files "$SRC")
mkdir -p "$OUT"
"$JDK/bin/javac" -nowarn -encoding latin1 -d "$OUT" $(find "$W/java" -name '*.java' | LC_ALL=C sort)
pico_resources "$SRC" "$OUT"
