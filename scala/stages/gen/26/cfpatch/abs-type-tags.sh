#!/usr/bin/env bash
# abs-type-tags.sh DIR : the new scala.reflect.base of 5acac4d806 (2012-06, TypeTag => AbsTypeTag,
# ConcreteTypeTag => TypeTag) for the compiler first: the previous compiler requires a member
# ConcreteTypeTag of base.TypeTags (it only looks it up), so a stand-in is added there
set -euo pipefail
python3 -I - $1/scala/reflect/base/TypeTags.scala <<'PY'
import sys
f = sys.argv[1]; s = open(f).read()
anchor = "trait TypeTags { self: Universe =>\n"
assert s.count(anchor) == 1
s = s.replace(anchor, anchor + """  // (cfpatch/abs-type-tags.sh: the previous compiler's name for TypeTag, looked up only)
  trait ConcreteTypeTag[T]
  object ConcreteTypeTag
""")
open(f, "w").write(s)
PY
# and the stand-ins of compat.scala (for the previous compiler, as upstream) without its top-level
# ConcreteTypeTag, which the previous library's package object has as an alias
python3 -I - $1/scala/reflect/compat.scala <<'PY'
import sys
f = sys.argv[1]; s = open(f).read()
old = "package scala.reflect {\n  trait ArrayTag[T]\n  trait ErasureTag[T]\n  trait ConcreteTypeTag[T]\n}"
assert s.count(old) == 1
s = s.replace(old, "package scala.reflect {\n  trait ArrayTag[T]\n  trait ErasureTag[T]\n}")
open(f, "w").write(s)
PY
# and the new anchor materializeAbsTypeTag, unknown to the previous compiler's fast track (which
# then wants a macro implementation), as a plain method
sed -i -E 's/(def materializeAbsTypeTag\[T\].*)= macro \?\?\?/\1= ???/' $1/scala/reflect/makro/internal/package.scala
grep -q 'materializeAbsTypeTag.*= ???$' $1/scala/reflect/makro/internal/package.scala
