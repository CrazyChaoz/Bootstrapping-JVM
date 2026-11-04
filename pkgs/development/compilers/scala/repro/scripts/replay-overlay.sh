#!/usr/bin/env bash
# replay-overlay.sh OUT: BTypeLoader of the d74 compiler sources with a replay hook for the
# nondeterministic InlineInfo of classes compiled in the run (see NOTES.md, "InlineInfo").
# -Ddotty.repro.inlineInfo=cls=stale,cls=fresh,... builds a listed class's InlineInfo from its
# decls at flattenPhase.next (stale: what the generic-signature callback sees) or at genBCode
# (fresh); unlisted classes are untouched, or fresh with -Ddotty.repro.inlineInfo.default=fresh.
set -euo pipefail
. "$(dirname "$0")/env.sh"
OUT=$(realpath -m "$1"); rm -rf "$OUT" "$OUT-src"; mkdir -p "$OUT" "$OUT-src"
python3 - "$SRC/compiler/src/dotty/tools/backend/jvm/BTypeLoader.scala" "$OUT-src/BTypeLoader.scala" <<'PY'
import sys
s = open(sys.argv[1]).read()
def rep(old, new):
    global s
    assert s.count(old) == 1, old
    s = s.replace(old, new)
rep("""  private def buildInlineInfoFromClassSymbol(classSym: ClassSymbol)(using Context): InlineInfo = {""",
"""  private lazy val replayInlineInfo: Map[String, Boolean] =
    val p = System.getProperty("dotty.repro.inlineInfo")
    if p == null then Map.empty
    else p.split(',').nn.toList.map(_.nn).filter(_.contains('=')).map(_.split('=').nn).map(a => a(0).nn -> (a(1).nn == "stale")).toMap

  private def buildInlineInfoFromClassSymbol(classSym: ClassSymbol)(using Context): InlineInfo =
    replayInlineInfo.get(classSym.fullName.toString) match
      case Some(true) => atPhase(flattenPhase.next)(buildInlineInfoFromClassSymbol0(classSym))
      case Some(false) => atPhase(ctx.base.allPhases.find(_.phaseName == "genBCode").get)(buildInlineInfoFromClassSymbol0(classSym))
      case None =>
        if System.getProperty("dotty.repro.inlineInfo.default") == "fresh"
        then atPhase(ctx.base.allPhases.find(_.phaseName == "genBCode").get)(buildInlineInfoFromClassSymbol0(classSym))
        else buildInlineInfoFromClassSymbol0(classSym)

  private def buildInlineInfoFromClassSymbol0(classSym: ClassSymbol)(using Context): InlineInfo = {""")
open(sys.argv[2], "w").write(s)
PY
CP="$NIX/comp:$NIX/lib0:$NIX/tasty:$NIX/interfaces:$NIX/deps"
"$JDK17/bin/java" -Xss16m -cp "$CP" dotty.tools.dotc.Main -language:implicitConversions -Yexplicit-nulls \
  -classpath "$CP" -d "$OUT" "$OUT-src/BTypeLoader.scala"
