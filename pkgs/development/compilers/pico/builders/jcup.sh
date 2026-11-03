#!/usr/bin/env bash
# jcup.sh SRC OUT : JCup, the parser generator of JaCo, without its shipped parse tables.
# SRC is JaCo's sources/ directory.  JCup reads grammars with a parser that is generated from
# its own grammar (jcup/parser.cup), and that parser needs tables from JCup.  The tables
# come from a stand-in for the parser (BOOT/parser.java) that reads parser.cup and nothing
# else; then JCup makes its own tables again, and they must be the same.
#
# Inputs: JDK, BOOT (pico/jcup-bootstrap).
set -euo pipefail
. "$(dirname "$(readlink -f "$0")")/common.sh"
SRC=$1 OUT=$2
W=$(mktemp -d)
trap 'rm -rf "$W"' EXIT
generate() { # generate CLASSES DIR : JCup's parser for parser.cup
  mkdir -p "$2"
  "$JDK/bin/java" -cp "$1" jcup.Main -package jcup -parser parser -symbols sym -o "$2/" -f "$SRC/jcup/parser.cup"
}

mkdir "$W/boot"
javac_old -d "$W/boot" $(ls "$SRC"/jcup/*.java | grep -v '/parser.java$') "$SRC"/jcup/runtime/*.java "$BOOT/parser.java"
generate "$W/boot" "$W/tables1"

mkdir -p "$OUT"
javac_old -d "$OUT" "$SRC"/jcup/*.java "$SRC"/jcup/runtime/*.java
cp "$W/tables1/parser.tables" "$OUT/jcup/"
generate "$OUT" "$W/tables2"
cmp "$W/tables1/parser.tables" "$W/tables2/parser.tables"
