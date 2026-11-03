#!/usr/bin/env bash
# macros-2012-04.sh SRC : locker's sources for e4976678fa (2012-04, "Next generation of macros")
# built by ../bridges/classtag-synth.sh's compiler: macro definitions (`def f = macro impl`,
# which it cannot parse) become ???, and Manifest stays the old class (../compiler-first/manifest.sh)
set -euo pipefail
grep -rlE '=\s*macro\s' $1/library | xargs -r sed -i -E 's/=\s*macro\s.*$/= ???/'
bash "$(dirname "$0")/../compiler-first/manifest.sh" "$1/library"
