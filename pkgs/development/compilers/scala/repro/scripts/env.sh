# sourced: the inputs, from REPRO_ENV (`nix build .#scala.repro.env`) or the environment,
# and WORK, the work directory (default: ../work)
[ -z "${REPRO_ENV:-}" ] || . "$REPRO_ENV"
for v in SRC NIX S230 SRC2 SJS JDK17; do
  [ -n "${!v:-}" ] || { echo "${BASH_SOURCE[1]##*/}: $v is not set (REPRO_ENV=\$(nix build --print-out-paths .#scala.repro.env))" >&2; exit 1; }
done
W=${WORK:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/work}
mkdir -p "$W"
