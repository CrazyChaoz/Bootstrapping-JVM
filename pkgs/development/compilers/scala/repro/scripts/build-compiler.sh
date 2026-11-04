#!/usr/bin/env bash
# build-compiler.sh OUTDIR: scala3-interfaces, tasty-core_3 and scala3-compiler_3 3.10.0 jars from
# source, against the library classes of build-library.sh (LIBCLASSES, default WORK/bl-lib);
# see compiler.sh
set -euo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
. "$HERE/env.sh"
OUT=$(realpath -m "$1"); mkdir -p "$OUT"
mkdir -p "$W/tools"
"$JDK17/bin/javac" --release 17 -cp "$NIX/deps" -d "$W/tools" "$HERE/../tools/MkJar.java"
rm -rf "$W/if"; mkdir -p "$W/if"
(cd "$SRC/interfaces/src" && "$JDK17/bin/javac" -Xlint:unchecked -Xlint:deprecation --release 17 -nowarn -d "$W/if" $(find . -name '*.java' | LC_ALL=C sort))
bash "$HERE/compiler.sh" "${LIBCLASSES:-$W/bl-lib}"
python3 "$HERE/props.py" compiler-properties 3.10.0 25c18aa 2026 > "$W/comp-b/compiler.properties"
mf() { python3 "$HERE/props.py" manifest "$@"; }
mf scala3-interfaces 3.10.0 Automatic-Module-Name=org.scala.lang.scala3.interfaces > "$W/mf-if"
mf tasty-core-bootstrapped 3.10.0 > "$W/mf-tasty"
mf scala3-compiler-bootstrapped 3.10.0 Main-Class=dotty.tools.dotc.Main Git-Hash=25c18aa > "$W/mf-comp"
j() { "$JDK17/bin/java" -Duser.timezone=UTC -cp "$W/tools" MkJar "$OUT/$1" "$2" "$3"; }
j scala3-interfaces-3.10.0.jar "$W/if" "$W/mf-if"
j tasty-core_3-3.10.0.jar "$W/tasty-b" "$W/mf-tasty"
j scala3-compiler_3-3.10.0.jar "$W/comp-b" "$W/mf-comp"
# org.scala-lang:scala3-library_3 is an empty placeholder (only the manifest)
mkdir -p "$W/empty"
mf scala3-library-bootstrapped 3.10.0 Automatic-Module-Name=org.scala.lang.scala3.library > "$W/mf-l3"
j scala3-library_3-3.10.0.jar "$W/empty" "$W/mf-l3"
