#!/usr/bin/env bash
# annotation-move.sh TREE FROMTREE : the bridge over 8922c4ed09 (2010-12-06), which moved
# Annotation, ClassfileAnnotation, StaticAnnotation and TypeConstraint from scala into
# scala.annotation (leaving deprecated aliases in the scala package object).
#
# The previous compiler only knows the classes in scala; the new one (TREE's compiler)
# only those in scala.annotation.  TREE gets FROMTREE's library (the parent's) with the
# new classes added and the old ones made subclasses of them, so that the library's
# annotations are annotations for both compilers.
set -euo pipefail
T=$1 F=$2
new=$(mktemp -d)
for c in Annotation ClassfileAnnotation StaticAnnotation TypeConstraint; do
  cp $T/src/library/scala/annotation/$c.scala $new/
done
rm -rf $T/src/library && cp -r --no-preserve=mode $F/src/library $T/src/library
# (unqualified, these names would mean the new classes inside package scala.annotation)
grep -rlE '\b(extends|with) (StaticAnnotation|ClassfileAnnotation|TypeConstraint|Annotation)\b' $T/src/library \
  | xargs sed -i -E 's/\b(extends|with) (StaticAnnotation|ClassfileAnnotation|TypeConstraint|Annotation)\b/\1 scala.\2/g'
cp $new/*.scala $T/src/library/scala/annotation/
rm -r $new
cd $T/src/library/scala
echo 'package scala; abstract class Annotation extends scala.annotation.Annotation' > Annotation.scala
echo 'package scala; trait StaticAnnotation extends scala.Annotation with scala.annotation.StaticAnnotation' > StaticAnnotation.scala
echo 'package scala; trait ClassfileAnnotation extends scala.StaticAnnotation with scala.annotation.ClassfileAnnotation' > ClassfileAnnotation.scala
echo 'package scala; trait TypeConstraint extends scala.Annotation with scala.annotation.TypeConstraint' > TypeConstraint.scala
