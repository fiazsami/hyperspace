#!/bin/bash
# The cost of the Metal saver on another Mac, at a commit, as one file to send
# back. For a Mac the work is not done on: refcheck.sh's numbers come from one
# machine, and a saver must stay quiet on the slowest one it runs on.
#
#   parity/basemac.sh baseline [ref]    default origin/master
#   parity/basemac.sh final <ref>
#
# Builds parity at <ref> (parity/at-ref.sh), then times every pass as the saver
# draws it (look=saver time) at 3440x1440 over the pass's own frames, twice, and writes
# .parity-build/basemac/<mode>-<sha>.txt: the machine, the commit, and each
# run's TIME line. Dividing its numbers by the same commit's on the reference
# Mac gives that Mac's scale factor per pass. About a minute; keep other work
# off the machine while it runs. Needs the Xcode command line tools.
set -uo pipefail
cd "$(dirname "$0")/.."
mode=${1:-}
case $mode in
baseline) ref=${2:-origin/master};;
final) [ $# -eq 2 ] || { echo "usage: parity/basemac.sh final <ref>" >&2; exit 2; }; ref=$2;;
*) echo "usage: parity/basemac.sh baseline [ref] | final <ref>" >&2; exit 2;;
esac
# Fetched only when needed: origin/master to be current, any other ref only if
# this clone lacks it, so an offline Mac can still time a commit it has.
if [ "$ref" = origin/master ] || ! git rev-parse -q --verify "$ref^{commit}" >/dev/null; then
    git fetch -q origin || { echo "git fetch failed" >&2; exit 2; }
fi
sha=$(git rev-parse --verify "$ref^{commit}") || exit 2
WT=.parity-build/basemac/tree
parity/at-ref.sh "$sha" "$WT" || exit 2
usage=$("$WT/.parity-build/parity" 2>&1)
[[ $usage == *look=saver* ]] || { echo "$ref's parity has no look=saver and time (ss-z8x.1)" >&2; exit 2; }
out=.parity-build/basemac/$mode-${sha:0:12}.txt
rm -f "$out"   # written only when every run succeeds, so a file is a whole result
{
    echo "basemac $mode ref=$ref sha=$sha date=$(date -u +%FT%TZ)"
    echo "machine $(sysctl -n hw.model) $(sysctl -n machdep.cpu.brand_string) macOS $(sw_vers -productVersion)"
    for run in 1 2; do
        for pass in stars goo tunnel burst sun; do
            "$WT/.parity-build/parity" "$pass" "$WT/metal" ".parity-build/basemac/run" renderer=metal look=saver time \
                shots=1 w=3440 h=1440 | grep '^TIME' || { echo "ERROR $pass run failed"; exit 2; }
        done
    done
} | tee "$out.partial"
[ "${PIPESTATUS[0]}" -eq 0 ] || { echo "a run failed: no result file written ($out.partial kept)" >&2; exit 2; }
mv "$out.partial" "$out"
echo "wrote $out -- send this file back"
