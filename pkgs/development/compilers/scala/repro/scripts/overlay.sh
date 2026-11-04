#!/usr/bin/env bash
# overlay.sh OUT: classes put in front of the d74 compiler for deterministic runs (see NOTES.md):
#   BTypeLoader  replay hook for the InlineInfo of classes compiled in the run
#                (-Ddotty.repro.inlineInfo=cls=stale,...; -Ddotty.repro.inlineInfo.default=fresh)
#   WeakHashSet  entries also held strongly: hash-consed types are never collected (the
#                typer's results otherwise depend on GC timing)
#   Pickler      ParallelPickling = false (unless PARALLEL_PICKLING=1)
#   Namer        replay hook for the order of wildcard export forwarders (-Ddotty.repro.exportOrder=FILE)
# NO_STRONG=1 leaves WeakHashSet alone.
set -euo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
. "$HERE/env.sh"
OUT=$(realpath -m "$1"); rm -rf "$OUT" "$OUT-src"; mkdir -p "$OUT" "$OUT-src"
bash "$HERE/replay-overlay.sh" "$OUT-replay" >/dev/null
cp -r "$OUT-replay/." "$OUT/"; rm -rf "$OUT-replay" "$OUT-replay-src"
python3 - "$SRC/compiler/src/dotty/tools/dotc" "$OUT-src" <<'PY'
import sys, os
src, out = sys.argv[1:]
def edit(rel, old, new):
    s = open(os.path.join(src, rel)).read()
    assert s.count(old) == 1, (rel, old)
    open(os.path.join(out, os.path.basename(rel)), "w").write(s.replace(old, new))
edit("util/WeakHashSet.scala",
     "  protected def addEntryAt(bucket: Int, elem: A, elemHash: Int, oldHead: Entry[A] | Null): A = {",
     "  private val strongRefs = new java.util.ArrayList[AnyRef]()\n"
     "  protected def addEntryAt(bucket: Int, elem: A, elemHash: Int, oldHead: Entry[A] | Null): A = {\n"
     "    strongRefs.add(elem)")
if os.environ.get("NO_STRONG") != "1":
    pass
else:
    os.remove(os.path.join(out, "WeakHashSet.scala"))
if os.environ.get("PARALLEL_PICKLING") != "1":
    edit("transform/Pickler.scala", "inline val ParallelPickling = true", "inline val ParallelPickling = false")
s = open(os.path.join(src, "typer/Namer.scala")).read()
old = "        for mbr <- pathType.membersBasedOnFlags(required = EmptyFlags, excluded = PrivateOrSynthetic) do"
new = """        val mbrs0 = pathType.membersBasedOnFlags(required = EmptyFlags, excluded = PrivateOrSynthetic)
        val mbrs = ReproExportOrder.map.get(cls.fullName.toString.stripSuffix("$")) match
          case Some(order) => mbrs0.sortBy(m => order.indexOf(m.name.toTermName.toString) match { case -1 => Int.MaxValue case i => i })
          case None => mbrs0
        for mbr <- mbrs do"""
assert s.count(old) == 1
s = s.replace(old, new) + """
/** scala-repro: -Ddotty.repro.exportOrder=FILE (lines `CLASS: NAME...`) orders the members a
 *  wildcard export of CLASS forwards (memberNames is a Set[Name], Name.hashCode an identity hash). */
object ReproExportOrder:
  lazy val map: Map[String, List[String]] =
    val f = System.getProperty("dotty.repro.exportOrder")
    if f == null then Map.empty
    else
      import scala.jdk.CollectionConverters.*
      java.nio.file.Files.readAllLines(java.nio.file.Paths.get(f)).nn.asScala.toList.map(_.nn)
        .filter(l => l.contains(':') && !l.startsWith("#"))
        .map: l =>
          val i = l.indexOf(':')
          l.substring(0, i).nn.trim.nn -> l.substring(i + 1).nn.trim.nn.split(' ').nn.toList.map(_.nn).filter(_.nonEmpty)
        .toMap
"""
open(os.path.join(out, "Namer.scala"), "w").write(s)
PY
CP="$NIX/comp:$NIX/lib0:$NIX/tasty:$NIX/interfaces:$NIX/deps"
"$JDK17/bin/java" -Xss16m -cp "$CP" dotty.tools.dotc.Main -language:implicitConversions -Yexplicit-nulls \
  -classpath "$CP" -d "$OUT" "$OUT-src"/*.scala
