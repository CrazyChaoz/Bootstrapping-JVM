#!/usr/bin/env bash
# deps.sh : third-party Java libraries the Scala build needs, from source
set -euo pipefail
J=/nix/store/nkd7mzlsa4d113n0xwh98m4l6dx9bnax-openjdk-headless-21.0.12.1+1
D=/tmp/sc/deps; mkdir -p $D; cd $D
# jline 1.0 (same API as the 0.9.x jars Scala shipped 2007-2010); the Windows DLLs are left out
[ -d jline1 ] || git clone -q https://github.com/jline/jline1.git
rm -rf jline-src jline-cls; mkdir jline-src jline-cls
(cd jline1 && git archive jline-1.0 src/main) | tar -x -C jline-src
$J/bin/javac -nowarn --release 8 -encoding utf8 -d jline-cls $(find jline-src/src/main/java -name '*.java')
(cd jline-src/src/main/resources && find . -name '*.properties' | cpio -pdm --quiet $D/jline-cls)
# jansi 1.4 with jansi-native 1.0 and hawtjni-runtime 1.0 (Java parts only: the native
# Windows console support is never loaded on Unix), for Scala's jline fork from 2010-12
J8=/nix/store/z2mxh5237w3dd8klbikm94x2wwipgc2y-openjdk-headless-8u504-b01
rm -rf jansi-src jansi-cls; mkdir jansi-src jansi-cls
for u in jansi/archive/jansi-1.4 jansi-native/archive/jansi-native-1.0 hawtjni/archive/hawtjni-1.0; do
  curl -sL https://github.com/fusesource/$u.tar.gz | tar -xz -C jansi-src
done
$J8/bin/javac -nowarn -encoding utf8 -d jansi-cls $(find jansi-src/jansi-jansi-1.4/src/main/java jansi-src/jansi-native-jansi-native-1.0/src/main/java jansi-src/hawtjni-hawtjni-1.0/hawtjni-runtime/src/main/java -name '*.java')
# Scala's generified jline (lib/jline.jar from 2009-06), as imported as source in c107643d20 (2009-10)
rm -rf jline5-src jline5-cls; mkdir jline5-src jline5-cls
(cd /tmp/sc/full && git archive c107643d20 src/jline/src/main) | tar -x -C jline5-src
$J8/bin/javac -nowarn -encoding utf8 -d jline5-cls $(find jline5-src/src/jline/src/main/java -name '*.java')
cp -r jline5-src/src/jline/src/main/resources/. jline5-cls/
