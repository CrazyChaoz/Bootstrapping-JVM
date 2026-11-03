#!/usr/bin/env bash
# classmanifest-alias.sh DIR : the new scala.reflect of cba0cbb892 (2012-06, ClassManifest an alias
# of ClassTag) for the compiler first: the previous compiler loops on that alias (its subtyping
# fix comes with the commit), so the alias and the ClassManifest value are left out, ClassManifest
# stays the previous library's trait and object; the factories and the Manifest value are kept
set -euo pipefail
python3 -I - $1/scala/reflect/package.scala <<'PY'
import sys
f = sys.argv[1]; s = open(f).read()
old = """  @deprecated("Use scala.reflect.ClassTag instead", "2.10.0")
  @annotation.implicitNotFound(msg = "No ClassManifest available for ${T}.")
  type ClassManifest[T]  = scala.reflect.ClassTag[T]
"""
assert s.count(old) == 1
s = s.replace(old, "  // (type ClassManifest left out, see patches/compiler-first/classmanifest-alias.sh)\n")
old = """  @deprecated("Use scala.reflect.ClassTag instead", "2.10.0")
  val ClassManifest = ClassManifestFactory
"""
assert s.count(old) == 1
s = s.replace(old, "  // (val ClassManifest left out: the previous library has the object)\n")
open(f, "w").write(s)
PY
# and the manifest factories, written for ClassManifest as that alias, with ClassTag for it
# (Manifest then mixes in ClassManifestDeprecatedApis itself, as ClassTag does in the new library)
for f in $1/scala/reflect/ClassManifest.scala $1/scala/reflect/Manifest.scala; do
  sed -i -E -e 's/\bClassManifest\./ClassManifestFactory./g' -e 's/\bClassManifest\[/ClassTag[/g' -e 's/: ClassManifest\]/: ClassTag]/g' $f
done
sed -i -E 's/^trait Manifest\[T\] extends ClassTag\[T\] with Equals/trait Manifest[T] extends ClassTag[T] with ClassManifestDeprecatedApis[T] with Equals/' $1/scala/reflect/Manifest.scala
grep -q 'with ClassManifestDeprecatedApis\[T\] with Equals' $1/scala/reflect/Manifest.scala
