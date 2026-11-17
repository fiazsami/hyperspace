#!/bin/bash
# Builds parity at <ref> in a scratch worktree at <dir>, for the scripts that
# compare the working tree with an earlier commit (seamcheck.sh, refcheck.sh).
# The worktree is rebuilt only when <ref> moves. Its parity draws with its own
# tree's renderer and metal/, so the two sides are the two commits.
#
#   parity/at-ref.sh <ref> <dir>     -> <dir>/.parity-build/parity
#
# Exit 0 = built, 2 = no such commit or the build failed.
set -uo pipefail
cd "$(dirname "$0")/.."
[ $# -eq 2 ] || { echo "usage: parity/at-ref.sh <ref> <dir>" >&2; exit 2; }
ref=$1; WT=$2
sha=$(git rev-parse --verify "$ref^{commit}") || exit 2
if [ "$(git -C "$WT" rev-parse HEAD 2>/dev/null)" != "$sha" ]; then
    git worktree remove --force "$WT" 2>/dev/null; rm -rf "$WT"
    mkdir -p "$(dirname "$WT")"
    git worktree add --detach "$WT" "$sha" >/dev/null || exit 2
fi
(cd "$WT" && parity/build.sh >/dev/null) || { echo "build at $ref failed" >&2; exit 2; }
