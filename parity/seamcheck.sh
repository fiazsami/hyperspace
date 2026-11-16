#!/bin/bash
# Proves a change to how Hyperspace is drawn left the picture alone.
#
# Builds parity at <ref> in a scratch worktree, runs the requested passes there and
# on the working tree, and compares the GL images shot by shot with
# `parity --compare`. Both sides are the GL renderer, so the two should agree to
# within float rounding. Each side runs with its own tree's metal/, so <ref> must
# be a commit whose parity runs -- any master commit is. A pass <ref>'s parity
# does not know (burst or sun, before they were added) is skipped with a note,
# not compared.
#
#   parity/seamcheck.sh <ref> [stars|goo|tunnel|burst|sun ...]    default: all five
#
# Exit 0 = the same picture, 1 = different, 2 = a run or build failed.
set -uo pipefail
cd "$(dirname "$0")/.."
[ $# -ge 1 ] || { echo "usage: parity/seamcheck.sh <ref> [pass ...]" >&2; exit 2; }
ref=$1; shift
passes=("$@"); [ ${#passes[@]} -gt 0 ] || passes=(stars goo tunnel burst sun)
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

# The passes <ref> knows, from its usage line: "parity <stars|goo|tunnel> ...".
known=$("$WT/.parity-build/parity" 2>&1 | sed -n 's/^usage: parity <\([^>]*\)>.*/|\1|/p')
bad=0
for pass in "${passes[@]}"; do
    if [[ $known != *"|$pass|"* ]]; then
        printf '%-7s skipped: %s predates it\n' "$pass" "$ref"
        continue
    fi
    for side in ref new; do
        bin=.parity-build/parity; metal=metal
        [ $side = ref ] && { bin=$WT/.parity-build/parity; metal=$WT/metal; }   # each side with its own shaders
        rm -rf "$OUT/$side/$pass"
        "$bin" "$pass" "$metal" "$OUT/$side/$pass" > "$OUT/$side-$pass.log"; code=$?
        # A <ref> from before ss-a4a.4.5 replays through Metal too and exits 1 on
        # that verdict, which is irrelevant here -- unless GL itself raised an
        # error, which would make its images no reference.
        if [ $side = ref ] && [ $code -eq 1 ] && ! grep -q "GL error" "$OUT/$side-$pass.log"; then code=0; fi
        [ $code -eq 0 ] || { echo "$side $pass run failed (exit $code): $(tail -1 "$OUT/$side-$pass.log")" >&2; exit 2; }
    done
    .parity-build/parity --compare "$OUT/ref/$pass" "$OUT/new/$pass" > "$OUT/$pass.compare"; code=$?
    printf '%-7s %s\n' "$pass" "$(tail -1 "$OUT/$pass.compare")"
    [ $code -eq 0 ] || bad=$code
done
exit $bad
