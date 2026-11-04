#!/usr/bin/env bash
# check.sh UPSTREAM DIR: each 3.10.0 jar of UPSTREAM (`nix build .#scala.repro.upstream`) against DIR's
set -u
rc=0
for u in "$1"/*-3.10.0.jar; do
  b=$(basename "$u"); [ -f "$2/$b" ] || { echo "missing   $b"; rc=1; continue; }
  if cmp -s "$u" "$2/$b"; then echo "IDENTICAL $(sha256sum < "$u" | cut -c1-16) $b"; else echo "DIFFERS   $b"; rc=1; fi
done
exit $rc
