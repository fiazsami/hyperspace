#!/bin/bash
# Proves the parity rules can fail, then that the committed shaders pass them.
#
# Every parity/defects/<pass>_*.metal is the committed shader for <pass> with one
# deliberate translation defect; each must FAIL. The committed metal/ shaders must
# then PASS. A rule that a known defect gets through is not a rule, so a defect
# that passes fails this script.
#
#   parity/killcheck.sh [stars|goo|tunnel ...]     default: all three
#
# About 5 minutes for all three on an M-series Mac; images go to .parity-build/out.
set -uo pipefail
cd "$(dirname "$0")/.."
parity/build.sh >/dev/null || exit 2

passes=("$@"); [ ${#passes[@]} -gt 0 ] || passes=(stars goo tunnel)
OUT=.parity-build/out
mkdir -p "$OUT"
bad=0
for pass in "${passes[@]}"; do
    for defect in parity/defects/"$pass"_*.metal; do
        name=$(basename "$defect" .metal)
        rm -rf "$OUT/$name"
        .parity-build/parity "$pass" metal "$OUT/$name" shader="$defect" > "$OUT/$name.log"; code=$?
        result=$(tail -1 "$OUT/$name.log")
        if [ "$code" -eq 1 ]; then printf 'killed     %-26s %s\n' "$name" "${result#FAIL }"
        else printf 'SURVIVED   %-26s exit %s: %s\n' "$name" "$code" "$result"; bad=1; fi
    done
    rm -rf "$OUT/$pass"
    .parity-build/parity "$pass" metal "$OUT/$pass" > "$OUT/$pass.log"; code=$?
    result=$(tail -1 "$OUT/$pass.log")
    if [ "$code" -eq 0 ]; then printf 'pass       %-26s %s\n' "metal/ ($pass)" "${result#PASS }"
    else printf 'FAILED     %-26s exit %s: %s\n' "metal/ ($pass)" "$code" "$result"; bad=1; fi
done
exit $bad
