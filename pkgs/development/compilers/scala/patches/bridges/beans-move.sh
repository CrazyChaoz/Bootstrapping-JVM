#!/usr/bin/env bash
# beans-move.sh TREE FROMTREE : the bridge over 55109d0d25 (2011-10-01), which moved
# scala.reflect.*Bean* to scala.beans and scala.annotation.target to scala.beans.meta
# (leaving deprecated aliases in the old packages' package objects).
#
# The previous compiler's backend insists on the old classes (scala.reflect.BeanInfo),
# and the old names are aliases in TREE's library.  TREE gets FROMTREE's library (the
# parent's, without the aliases) plus the new packages, so that both compilers find
# their classes.
set -euo pipefail
T=$1 F=$2
new=$(mktemp -d)
cp -r $T/src/library/scala/beans $new/
rm -rf $T/src/library && cp -r --no-preserve=mode $F/src/library $T/src/library
cp -r $new/beans $T/src/library/scala/
rm -r $new
