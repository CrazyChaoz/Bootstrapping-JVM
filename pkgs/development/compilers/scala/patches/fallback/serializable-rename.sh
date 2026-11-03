#!/usr/bin/env bash
# serializable-rename.sh DIR : the previous library's classes for 4be5e11ccc (2010-11), where
# scala.serializable became an alias of the trait scala.Serializable: their Scala signatures
# carry the inherited annotation @scala.serializable, which the new compiler cannot read any
# more, so the name is renamed there (tools/scala-pickle-rename.py)
set -euo pipefail
find "$1" -name '*.class' -print0 | xargs -0 python3 -I "$TOOLS/scala-pickle-rename.py" serializable Serializable
