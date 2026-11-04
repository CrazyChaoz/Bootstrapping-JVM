# shellcheck shell=bash disable=SC2034  # (sets HERE and T for the builders)
# Helpers shared by the stage builders (sourced).
#
# The builders take their inputs from the environment (default.nix sets them):
#   JDK8      runs the compilers (the old class file readers and run-time libraries want
#             a Java 8 class library) and compiles Java that needs sun.misc.Unsafe
#   JDK21     compiles the other Java sources (javac --release 8 or later)
#   PICO      PiCo, which compiles the Java (PiCo) sources until 2006-06 (pkgs/development/compilers/pico)
#   TOOLS     tools/: jdk-api-view.py, scala-unnest.py, ...
# and whatever else a builder lists in its `require` line.

HERE=$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")

require() { # require VAR... : fail unless the environment sets each VAR
  local v
  for v in "$@"; do
    [ -n "${!v:-}" ] || { echo "$0: $v is not set" >&2; exit 1; }
  done
}
require JDK8 JDK21 TOOLS
T=$TOOLS

# The inputs are read-only (the Nix store): copies of them have to be writable.
cp() { command cp --no-preserve=mode "$@"; }

# Old scalac prefers a source over a class file that is not older, and the Nix store dates
# everything at 1: a previous stage's sources go on a class path as a copy dated before it.
oldsrc() { # oldsrc DIR COPY
  cp -r "$1" "$2"
  find "$2" -exec touch -h -d @0 {} +
}

# pyreplace FILE <<'PY' R=[(OLD, NEW), ...] PY : replace each OLD in FILE by NEW; an OLD
# that does not occur is reported, not an error (the patches serve many source trees).
pyreplace() {
  python3 -c '
import sys
p = sys.argv[1]; s = open(p, encoding="latin-1").read(); exec(sys.stdin.read())
for a, b in R:
    if a in s: s = s.replace(a, b)
    else: print("patch not applicable in", p, ":", a.splitlines()[0][:60], file=sys.stderr)
open(p, "w", encoding="latin-1").write(s)' "$1"
}

# javac of JDK 21 for Java 8 class files
javac8() { "$JDK21/bin/javac" -nowarn --release 8 "$@"; }

# pico ARGS... : PiCo, as the trees' builds ran it (Makefile: -source 1.4, and the library with
# -scala-hack, which lets scala.Int.coerce() be overloaded by its result type; Ant: scalahack
# everywhere); it exits with status 0 after errors
pico() {
  require PICO # (set for the Scala 2 stages only; the dotty ones never call pico)
  "$PICO/bin/pico" -source 1.4 -scala-hack "$@" > pico.log 2>&1 || { cat pico.log; exit 1; }
  if grep -qE '^[0-9]+ errors?$|^Exception in thread' pico.log; then cat pico.log; exit 1; fi
}
