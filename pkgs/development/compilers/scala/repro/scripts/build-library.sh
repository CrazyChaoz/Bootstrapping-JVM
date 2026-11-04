#!/usr/bin/env bash
# build-library.sh OUT.jar: org.scala-lang:scala-library:3.10.0 from source, as upstream's
# scala-library-bootstrapped: lib.sh (Scala 3 sources by the nonbootstrapped compiler = Nix d74),
# scala2lib.sh (2.13.18 sources by s230), PatchScala2 (ScalaLibraryPlugin), resources, MkJar.
set -euo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
. "$HERE/env.sh"
OUT=$(realpath -m "$1"); mkdir -p "$(dirname "$OUT")"
mkdir -p "$W/tools"
"$JDK17/bin/javac" --release 17 -cp "$NIX/deps" -d "$W/tools" "$HERE/../tools/PatchScala2.java" "$HERE/../tools/MkJar.java"
bash "$HERE/lib.sh" "$W/bl-lib"
bash "$HERE/scala2lib.sh" "$W/bl-s2"
grep -o '"[^"]*"' "$SRC/project/ScalaLibraryFilesToCopy.scala" | tr -d '"' > "$W/bl-filesToCopy.txt"
"$JDK17/bin/java" -cp "$W/tools:$NIX/deps" PatchScala2 "$W/bl-lib" "$W/bl-s2" "$W/bl-filesToCopy.txt"
cp "$SRC"/library/resources/* "$W/bl-lib/"
python3 "$HERE/props.py" library-properties 3.10.0 2026 > "$W/bl-lib/library.properties"
python3 "$HERE/props.py" manifest scala-library-bootstrapped 3.10.0 Automatic-Module-Name=scala.library > "$W/bl-manifest.mf"
"$JDK17/bin/java" -Duser.timezone=UTC -cp "$W/tools" MkJar "$OUT" "$W/bl-lib" "$W/bl-manifest.mf"
