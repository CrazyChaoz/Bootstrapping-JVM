#!/usr/bin/env bash
# unnest.sh SRC : locker's sources for 6a9d9f379a (2009-07), the first tree with chained
# package clauses (`package a; package b`), which the previous compiler does not know:
# rewritten to single clauses plus imports by tools/scala-unnest.py
set -euo pipefail
python3 -I "$TOOLS/scala-unnest.py" "$1"
