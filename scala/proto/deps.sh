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
