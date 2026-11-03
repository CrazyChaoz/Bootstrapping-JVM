# shellcheck shell=bash
# Shared by the PiCo builders (sourced).  JDK is the JDK 8 that compiles and runs everything.

# javac for the old sources: JCup is Java 1.1 code (`enum` is a name in it)
javac_old() { "$JDK/bin/javac" -source 1.4 -target 1.4 -nowarn -encoding latin1 "$@"; }

# pico_files SRC : the sources of the compiler, as upstream's build.xml (compile.jaco) lists
# them, relative to SRC (JaCo's sources/ directory), without the Ant task
pico_files() {
  (cd "$1" && for d in jaco/framework jaco/framework/parser jaco/java/struct jaco/java/component \
      jaco/java/context jaco/java/grammar jaco/pizza/struct jaco/pizza/component \
      jaco/pizza/context jaco/pizza/grammar jaco/pizza; do
    ls "$d"/*.java
  done | grep -v '/Ant')
}

# pico_resources SRC OUT : what upstream's build.xml copies next to the classes: the messages
# and settings, and the parse tables
pico_resources() {
  local d
  for d in jaco/java/resources jaco/pizza/resources; do
    mkdir -p "$2/$d"
    cp -r "$1/$d/." "$2/$d/"
  done
  cp "$1/jaco/java/grammar/Parser.tables" "$2/jaco/java/grammar/"
  cp "$1/jaco/pizza/grammar/PizzaParser.tables" "$2/jaco/pizza/grammar/"
}

# pico_compile COMPILER_CLASSPATH SRC DEST : compile the sources with a compiler
pico_compile() {
  mkdir -p "$3"
  (cd "$2" && "$JDK/bin/java" -Xss16m -cp "$1" jaco.pizza.Main -d "$3" $(pico_files .)) 2>&1 | tee "$3.log"
  # (the compiler exits with status 0 after errors)
  if grep -Eq '^[0-9]+ errors?$|^Exception in thread' "$3.log"; then
    echo "pico: compilation failed" >&2
    exit 1
  fi
}
