# Inputs of the stage scripts (sourced).  The defaults are the prototype
# layout in /tmp/sc; the Nix expressions in nix/scala set all of them.
HERE=$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")
S=${S:-/tmp/sc}
T=${TOOLS:-$HERE/../../tools}                                          # pizza2java.py, pico-classfiles.py
J=${J:-/nix/store/nkd7mzlsa4d113n0xwh98m4l6dx9bnax-openjdk-headless-21.0.12.1+1}   # javac --release 8
J8=${J8:-/nix/store/z2mxh5237w3dd8klbikm94x2wwipgc2y-openjdk-headless-8u504-b01}   # runs the compilers
FJBG_SRC=${FJBG_SRC:-$S/fjbg/src/fjbg}     # src/fjbg of scala/scala 0f10ffedc8 (2009)
MSIL_SRC=${MSIL_SRC:-$S/msil/src/msil}     # src/msil of scala/scala 4304b15730 (2009)
ASM_SRC=${ASM_SRC:-$S/scala-asm-5.1/src/main/java}  # scala/scala-asm v5.1.0-scala-2 (ASM 5.1 + Scala's cherry-picks)
ASM_SRCS=${ASM_SRCS:-$S/scala-asm-srcs}     # scala/scala-asm sources by version (the tags' src/main/java)
FJBG_CLS=${FJBG_CLS:-$S/st-n0/fjbg-cls}    # FJBG + MSIL reader classes, as built for the first nsc
JLINE_CLS=${JLINE_CLS:-$S/deps/jline-cls}  # jline 1.0
JLINE5_CLS=${JLINE5_CLS:-$S/deps/jline5-cls}  # Scala's generified jline (src/jline of c107643d20, 2009-10)
JANSI_CLS=${JANSI_CLS:-$S/deps/jansi-cls}  # jansi 1.4 + jansi-native 1.0 + hawtjni-runtime 1.0 (for the jline fork, 2010-12)
RT14=${RT14:-$S/rt14b.jar}                 # JDK API views (tools/jdk-api-view.py) as of Java 1.4 / 1.5
RT15=${RT15:-$S/rt15.jar}
RT16=${RT16:-$S/rt16.jar}                  # (and 1.6, JAVA_API=1.6)
# inputs may be read-only (the Nix store): copies of them have to be writable
cp() { command cp --no-preserve=mode "$@"; }
# Old scalac prefers a source over a class file that is not older, and the Nix store dates
# everything at 1: put a previous stage's sources on a class path as a copy dated before it.
oldsrc() { cp -r "$1" "$2"; find "$2" -exec touch -h -d @0 {} +; }
ZINC_SRC=${ZINC_SRC:-$S/deps/zinc-v1.2.5}           # sbt/zinc (internal/compiler-interface), for dotty
JLINE3_SRC=${JLINE3_SRC:-$S/deps/jline3-3.9.0}      # jline/jline3 (reader, terminal), for dotty's REPL
SCALAJS_SRC=${SCALAJS_SRC:-$S/deps/scala-js-v1.0.0-M7}  # scala-js/scala-js (ir), for dotty's Scala.js backend
SBTUTIL_SRC=${SBTUTIL_SRC:-$S/deps/sbt-util-v1.2.2}    # sbt/util (internal/util-interface: xsbti.Position etc.), for zinc
