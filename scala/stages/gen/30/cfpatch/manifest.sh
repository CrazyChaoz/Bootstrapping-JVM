#!/usr/bin/env bash
# manifest.sh DIR : the new scala.reflect (2012-04, "Next generation of macros") for the
# previous compiler (with ClassTag synthesis, bridges/classtag-synth.sh), which synthesizes
# the old Manifests but not ConcreteTypeTags: Manifest, OptManifest and NoManifest stay the
# previous library's classes instead of aliases of the new type tags
set -euo pipefail
python3 -I - $1/scala/reflect/package.scala <<'PY'
import re, sys
f = sys.argv[1]; out = []
drop = re.compile(r'\s*(type (OptManifest|Manifest)\[T\]\s*=|(val|lazy val) Manifest\s*=|object NoManifest )')
for l in open(f).read().split("\n"):
    if drop.match(l):
        if out and out[-1].strip().startswith("@deprecated"): out.pop()
        continue
    out.append(l)
open(f, "w").write("\n".join(out))
PY
# (a deprecated method typed with the Manifest alias; and ClassTag, ConcreteTypeTag, which the
# new Predef aliases, imported explicitly where the macro API uses them)
sed -i -E 's/override def typeArguments: List\[Manifest\[_\]\].*/def typeArgumentsNoManifest = ()/' $1/scala/reflect/api/TypeTags.scala
grep -rlE '\b(ClassTag|ConcreteTypeTag)\b' $1/scala/reflect/makro | while read -r f; do
  sed -i '0,/^package .*/s//&\nimport scala.reflect.{ClassTag, ConcreteTypeTag}/' "$f"
done
