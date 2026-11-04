# sourced: dotc ARGS... runs Nix's non-bootstrapped 3.10.0 compiler (comp/ of d74) from the tree root
. "$(dirname "${BASH_SOURCE[0]}")/env.sh"
# the nonbootstrapped compiler's version, as sbt's build gives it
mkdir -p "$W/props"
python3 "$(dirname "${BASH_SOURCE[0]}")/props.py" compiler-properties 3.10.0-bin-nonbootstrapped 25c18aa 2026 > "$W/props/compiler.properties"
OPTS=(-feature -deprecation -unchecked -Werror
  "-Wconf:msg=package scala contains object and package with same name:i"
  "-Wconf:src=scaladoc-testcases/.*:s" "-Wconf:src=presentation-compiler-testcases/.*:s"
  "-Wconf:msg=The RHS of reassignment must be transitively initialized:i"
  "-Wconf:msg=Could not verify that the method argument is transitively initialized:i"
  "-Wconf:msg=may cause initialization errors:i"
  "-Wconf:cat=deprecation&origin=scala\\.collection\\.Iterable\\.stringPrefix:s"
  -encoding UTF8 -language:implicitConversions --java-output-version:17 -Yexplicit-nulls -Wsafe-init)
CCP=${CCP_PRE:-}$W/props:$NIX/comp:$NIX/lib0:$NIX/tasty:$NIX/interfaces:$NIX/deps
dotc() { (cd "$SRC" && "${JAVA:-$JDK17/bin/java}" -Xss16m ${JOPTS:--Xmx6g} -cp "$CCP" dotty.tools.dotc.Main "$@"); }
