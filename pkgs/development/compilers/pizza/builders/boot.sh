#!/usr/bin/env bash
# boot.sh SRC OUT : the boot compiler.  SRC is the (patched) source tree of Pizza 0.40,
# which is written in Pizza; tools/pizza2java.py translates it to Java, and javac
# compiles that to OUT/classes.  This compiler only has to compile Pizza 0.40 once
# (stage.sh), and that compiler then has to compile itself to the same class files.
#
# Inputs: JDK (javac), TOOLS (tools/), and python3 and regex-edit on the PATH.
set -euo pipefail
SRC=$1 OUT=$2
mkdir -p "$OUT/classes"
W=$(mktemp -d)
trap 'rm -rf "$W"' EXIT

(cd "$SRC" && find pizza \( -name '*.pizza' -o -name '*.java' \) | LC_ALL=C sort) > "$W/files"
python3 -I "$TOOLS/pizza2java.py" "$SRC" "$W/java" $(cat "$W/files")

# Gen.typecode's message `"typecode " + type.tag` names the method tag() of a Type as a
# value (a closure, in Pizza); the translator cannot tell that from a field, so it is
# made a method reference here.
regex-edit '"typecode " \+ type\.tag\)' '"typecode " + (pizza0.Fun0<Integer>) type::tag)' \
  "$W/java/pizza/v40/Gen.java"

"$JDK/bin/javac" -nowarn -encoding latin1 -d "$OUT/classes" $(find "$W/java" -name '*.java' | LC_ALL=C sort)
