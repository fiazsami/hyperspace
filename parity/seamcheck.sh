#!/bin/bash
# Proves a change to how Hyperspace is drawn left the picture alone.
#
# Builds parity at <ref> in a scratch worktree, runs the requested passes there and
# on the working tree, and compares the GL images shot by shot with
# `parity --compare`. Both sides are the GL renderer, so the two should agree to
# within float rounding; the Metal images are not compared. Each run still builds
# its own tree's Metal pipelines, so <ref> must be a commit whose parity runs --
# any master commit is -- and knows every pass asked for: name the passes when
# <ref> predates the burst pass.
#
#   parity/seamcheck.sh <ref> [stars|goo|tunnel|burst ...]    default: all four
#
# Exit 0 = the same picture, 1 = different, 2 = a run or build failed.
set -uo pipefail
cd "$(dirname "$0")/.."
[ $# -ge 1 ] || { echo "usage: parity/seamcheck.sh <ref> [pass ...]" >&2; exit 2; }
ref=$1; shift
passes=("$@"); [ ${#passes[@]} -gt 0 ] || passes=(stars goo tunnel burst)
sha=$(git rev-parse --verify "$ref^{commit}") || exit 2

OUT=.parity-build/seam
WT=$OUT/ref-tree
mkdir -p "$OUT"
# The reference tree is rebuilt only when <ref> moves.
if [ "$(git -C "$WT" rev-parse HEAD 2>/dev/null)" != "$sha" ]; then
    git worktree remove --force "$WT" 2>/dev/null; rm -rf "$WT"
    git worktree add --detach "$WT" "$sha" >/dev/null || exit 2
fi
(cd "$WT" && parity/build.sh >/dev/null) || { echo "reference build failed" >&2; exit 2; }
parity/build.sh >/dev/null || exit 2

bad=0
for pass in "${passes[@]}"; do
    for side in ref new; do
        bin=.parity-build/parity; metal=metal
        [ $side = ref ] && { bin=$WT/.parity-build/parity; metal=$WT/metal; }   # each side with its own shaders
        rm -rf "$OUT/$side/$pass"
        # Exit 1 is a parity FAIL (GL vs Metal), irrelevant here; only 2 is fatal.
        "$bin" "$pass" "$metal" "$OUT/$side/$pass" > "$OUT/$side-$pass.log"; code=$?
        [ $code -le 1 ] || { echo "$side $pass run failed (exit $code): $(tail -1 "$OUT/$side-$pass.log")" >&2; exit 2; }
    done
    .parity-build/parity --compare "$OUT/ref/$pass" "$OUT/new/$pass" > "$OUT/$pass.compare"; code=$?
    printf '%-7s %s\n' "$pass" "$(tail -1 "$OUT/$pass.compare")"
    [ $code -eq 0 ] || bad=$code
done
exit $bad
