# shellcheck shell=bash disable=SC2034  # (settings for the scripts that source it)
# Settings and helpers of the prototype scripts (sourced).
#
# The prototype finds new stages by building candidate commits outside Nix, with the
# builders, tools and patches of this checkout and the other inputs of the Nix builds
# (`nix build .#scala.builderEnv`).  It works in SCALA_WORK (default /tmp/sc):
#
#   full/            a clone of https://github.com/scala/scala
#   dotty/           a clone of https://github.com/scala/scala3 (for the dotty chain)
#   chain.txt        the stages built so far, as the stage lines of scala/chain/scala2.txt
#   st-NAME/         the output of stage NAME, as in the Nix build (st1: the pizza stage)
#   src-NAME/, log-NAME.txt   the tree and build log of the last try of NAME
#
# A stage is built with the builder and settings of a generation of nix/scala/generations.nix
# (GENERATION, default: the last one of scala/chain/scala2.txt); settings in the environment
# take precedence over the generation's.

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
WORK=${SCALA_WORK:-/tmp/sc}
SCALA_GIT=$WORK/full
DOTTY_GIT=$WORK/dotty
mkdir -p "$WORK"

# the inputs of the Nix builds (a GC root in the work directory); TOOLS of this checkout
[ -e "$WORK/builder-env.sh" ] || nix build -o "$WORK/builder-env.sh" "$ROOT#scala.builderEnv"
. "$WORK/builder-env.sh"
export TOOLS=$ROOT/scala/tools
# the FJBG classes the Scala 2 builder links, from the nsc0 stage
export FJBG_CLS=$WORK/st-n0/classes

GENERATION=${GENERATION:-$(awk '$1 == "generation" { g = $2 } END { print g }' "$ROOT/scala/chain/scala2.txt")}

# use_generation NAME : the builder of generation NAME (in BUILDER), and its settings,
# but for those already set
use_generation() {
  local exports
  exports=$(nix eval --raw --impure --expr "
    let g = (import $ROOT/nix/scala/generations.nix { patches = \"$ROOT/patches/scala\"; }).\"$1\";
    in builtins.concatStringsSep \"\" (
      [ \"BUILDER=\${g.builder}\n\" ]
      ++ map (n: \"export \${n}=\${\"$\"}{\${n}-\${g.env.\${n}}}\n\") (builtins.attrNames (g.env or { })))") || return
  eval "$exports"
}

# stage_test NAME : the smoke test of stage NAME's builder (a compiled and run Hello)
stage_test() {
  local log=$WORK/hello-$1.txt
  case $BUILDER in
    scala1.sh) bash "$ROOT/scala/tests/hello1.sh" "$WORK/st-$1" > "$log" 2>&1 ;;
    nsc0.sh | scala2.sh) bash "$ROOT/scala/tests/hello2.sh" "$WORK/st-$1" > "$log" 2>&1 ;;
    *) return 0 ;;
  esac
  grep -m1 '^Hello from' "$log"
}

# shortlog : a build log without the noise of old compilers (notes, warnings, positions)
shortlog() {
  grep -v '^Note\|not applicable\|warning\|^ *\^\|signature = ' | grep -v '^      '
}

# unpack NAME COMMIT : the tree of COMMIT in src-NAME, without the binaries it ships (as
# fetchScala in nix/scala/default.nix)
unpack() {
  local d=$WORK/src-$1
  rm -rf "$d" && mkdir "$d" && git -C "$SCALA_GIT" archive "$2" | tar -x -C "$d" || return
  find "$d" -type f \( -name '*.jar' -o -name '*.class' -o -name '*.so' -o -name '*.dll' \
    -o -name '*.dylib' -o -name '*.exe' -o -name '*.zip' -o -name '*.a' -o -name '*.jnilib' \) -delete
}

# build NAME PREV : stage NAME from src-NAME by stage PREV ("-": none, for the pizza builder),
# with BUILDER; killed after TRY_TIMEOUT seconds (default 3600: some failing builds hang
# printing their type errors).  The log goes to log-NAME.txt.
build() {
  local prev=
  [ "$2" = - ] || prev=$WORK/st-$2
  rm -rf "$WORK/st-$1"
  timeout "${TRY_TIMEOUT:-3600}" bash "$ROOT/scala/builders/$BUILDER" "$WORK/src-$1" "$WORK/st-$1" $prev > "$WORK/log-$1.txt" 2>&1
}
