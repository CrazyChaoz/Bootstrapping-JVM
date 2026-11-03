#!/usr/bin/env bash
# stage.sh SRC PREV OUT : a Pizza release, compiled by the previous compiler and then by
# itself.  SRC is the (patched) source root of the release (the directory with its
# packages), PREV the class path of the previous compiler (main class PREV_MAIN).  The
# release's compiler (main class MAIN) compiled by PREV compiles the sources again, and
# that compiler once more: these two results must be the same class files, and they go
# to OUT/classes.
#
# Inputs: JDK (runs the compilers: Pizza reads the class library from its rt.jar),
# EXCLUDE (an extended regular expression of source paths not to compile, optional).
set -euo pipefail
SRC=$1 PREV=$2 OUT=$3
W=$(mktemp -d)
trap 'rm -rf "$W"' EXIT

(cd "$SRC" && find . \( -name '*.pizza' -o -name '*.java' \) | sed 's|^\./||' |
  { if [ -n "${EXCLUDE:-}" ]; then grep -Ev "$EXCLUDE"; else cat; fi; } | LC_ALL=C sort) > "$W/files"

# pizzac COMPILER MAIN DEST: compile the sources with the compiler in COMPILER
pizzac() {
  mkdir -p "$3"
  (cd "$SRC" && "$JDK/bin/java" -Xss16m -cp "$1" "$2" -classpath "$3" -d "$3" $(cat "$W/files")) 2>&1 |
    tee "$W/log"
  # (0.40 exits with status 0 after errors)
  if grep -Eq '^[0-9]+ errors?$|An exception has occurred' "$W/log"; then
    echo "stage.sh: compilation failed" >&2
    exit 1
  fi
}
echo "## compiled by the previous stage"
pizzac "$PREV" "$PREV_MAIN" "$W/c1"
echo "## compiled by itself"
pizzac "$W/c1" "$MAIN" "$W/c2"
echo "## and again"
pizzac "$W/c2" "$MAIN" "$W/c3"
if ! diff -r "$W/c2" "$W/c3"; then
  echo "stage.sh: the compiler does not compile itself to itself" >&2
  exit 1
fi
if diff -rq "$W/c1" "$W/c2" > /dev/null; then
  echo "## (the previous stage compiled it to the same class files)"
fi
mkdir -p "$OUT"
cp -r "$W/c2" "$OUT/classes"
