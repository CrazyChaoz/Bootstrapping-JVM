#!/usr/bin/env bash
# compiler.sh LIBCLASSES: tasty-core-bootstrapped and scala3-compiler-bootstrapped (classes in
# WORK/tasty-b, WORK/comp-b), by the nonbootstrapped compiler (Nix d74) in a copy of the source tree
# (WORK/tree: TASTy records paths relative to it, the Scala.js IR sources under upstream's src_managed)
set -euo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
. "$HERE/env.sh"
LIB=$(realpath "$1")
OVL=${OVERLAY:-$W/overlay-gc}; [ -d "$OVL" ] || NO_STRONG=1 PARALLEL_PICKLING=1 bash "$HERE/overlay.sh" "$OVL" >/dev/null
CCP_PRE=${EXTRA_CCP:-}$OVL:
# (upstream's .jvmopts for sbt; the typer's results depend on GC timing, see NOTES.md)
JOPTS="${JVMOPTS:--Xms1024m -Xmx8192m -XX:MaxInlineLevel=35} -Ddotty.repro.exportOrder=$HERE/export-order-compiler.txt -Ddotty.repro.inlineInfo.default=fresh -Ddotty.repro.inlineInfo=$(grep -v '^#' "$HERE/inlineinfo-replay-compiler.txt" | paste -sd, || true)"
. "$HERE/sc.sh"
T=$W/tree; [ ! -d "$T" ] || chmod -R u+w "$T"; rm -rf "$T"; mkdir -p "$T/compiler" "$T/tasty"
for d in compiler/src compiler/src-bootstrapped tasty/src tasty/src-bootstrapped; do
  [ ! -d "$SRC/$d" ] || cp -r "$SRC/$d" "$T/$d"
done
M=compiler/target/scala3-compiler-bootstrapped/scala-3.10.0-bin-nonbootstrapped/src_managed/main/scalajs-ir-src
python3 "$HERE/sjsir-shade.py" "$T/$M" "$SJS/ir/shared/src/main/scala" "$SJS/ir/shared/src/main/scala-3" "$SJS/ir/jvm/src/main/scala"
chmod -R u+w "$T"
dotc() { (cd "$T" && "${JAVA:-$JDK17/bin/java}" ${XSS:--Xss2m} $JOPTS -cp "$CCP" dotty.tools.dotc.Main "$@"); }

rm -rf "$W/tasty-b"; mkdir -p "$W/tasty-b"
(cd "$T" && find tasty/src $(ls -d tasty/src-bootstrapped 2>/dev/null) -name '*.scala' -o -name '*.java' | LC_ALL=C sort) > "$W/tasty-b.srcs"
dotc "${OPTS[@]}" -classpath "$W/tasty-b:$LIB" -d "$W/tasty-b" @"$W/tasty-b.srcs"

rm -rf "$W/comp-b"; mkdir -p "$W/comp-b"
(cd "$T" && find compiler/src $(ls -d compiler/src-bootstrapped 2>/dev/null) "$M" -name '*.scala' -o -name '*.java' | LC_ALL=C sort) > "$W/comp-b.srcs"
CP="$W/comp-b:$W/if:$W/tasty-b:$LIB:$NIX/deps"
dotc "${OPTS[@]}" -opt '-opt-inline:dotty.**' \
  "-Wconf:src=scalajs-ir-src/.*&msg=Implicit parameters should be provided with a \`using\` clause:s" \
  "-Wconf:src=scalajs-ir-src/.*&msg=uninitialized\` instead:s" \
  "-Wconf:src=scalajs-ir-src/.*&msg=object AnyRefMap in package scala\\.collection\\.mutable is deprecated:s" \
  -classpath "$CP" -d "$W/comp-b" @"$W/comp-b.srcs"
grep '\.java$' "$W/comp-b.srcs" > "$W/comp-b.java" || true
if [ -s "$W/comp-b.java" ]; then
  (cd "$T" && "$JDK17/bin/javac" -Xlint:unchecked -Xlint:deprecation --release 17 -nowarn -classpath "$CP" -d "$W/comp-b" @"$W/comp-b.java")
fi
