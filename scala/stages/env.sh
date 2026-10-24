# Inputs of the stage scripts (sourced).  The defaults are the prototype
# layout in /tmp/sc; the Nix expressions in nix/scala set all of them.
HERE=$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")
S=${S:-/tmp/sc}
T=${TOOLS:-$HERE/../../tools}                                          # pizza2java.py, pico-classfiles.py
J=${J:-/nix/store/nkd7mzlsa4d113n0xwh98m4l6dx9bnax-openjdk-headless-21.0.12.1+1}   # javac --release 8
J8=${J8:-/nix/store/z2mxh5237w3dd8klbikm94x2wwipgc2y-openjdk-headless-8u504-b01}   # runs the compilers
FJBG_SRC=${FJBG_SRC:-$S/fjbg/src/fjbg}     # src/fjbg of scala/scala 0f10ffedc8 (2009)
MSIL_SRC=${MSIL_SRC:-$S/msil/src/msil}     # src/msil of scala/scala 4304b15730 (2009)
FJBG_CLS=${FJBG_CLS:-$S/st-n0/fjbg-cls}    # FJBG + MSIL reader classes, as built for the first nsc
JLINE_CLS=${JLINE_CLS:-$S/deps/jline-cls}  # jline 1.0
RT14=${RT14:-$S/rt14b.jar}                 # JDK API views (tools/jdk-api-view.py) as of Java 1.4 / 1.5
RT15=${RT15:-$S/rt15.jar}
# inputs may be read-only (the Nix store): copies of them have to be writable
cp() { command cp --no-preserve=mode "$@"; }
