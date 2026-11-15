#!/bin/bash
# Proves the parity rules can fail, then that the committed shaders pass them.
#
# Every parity/defects/<pass>_*.metal is the committed shader for <pass> with one
# deliberate translation defect; each must FAIL. The committed metal/ shaders must
# then PASS. A rule that a known defect gets through is not a rule, so a defect
# that passes fails this script.
#
# The recorder's own checks are proved the same way, with parity's inject= cases
# (one short stars run each): a *_ok case must PASS, every other case must FAIL.
#
#   parity/killcheck.sh [stars|goo|tunnel ...]     default: all three, plus inject
#   parity/killcheck.sh inject                     the recorder cases alone
#
# About 5 minutes for everything on an M-series Mac; images go to .parity-build/out.
set -uo pipefail
cd "$(dirname "$0")/.."
parity/build.sh >/dev/null || exit 2

passes=("$@"); [ ${#passes[@]} -gt 0 ] || passes=(stars goo tunnel inject)
OUT=.parity-build/out
mkdir -p "$OUT"
bad=0
for pass in "${passes[@]}"; do
    if [ "$pass" = inject ]; then
        cases=$(.parity-build/parity --inject-cases) || exit 2
        for case in $cases; do
            name=inject_$case
            rm -rf "$OUT/$name"
            .parity-build/parity stars metal "$OUT/$name" inject="$case" frames=301 every=300 > "$OUT/$name.log" 2>&1; code=$?
            result=$(tail -1 "$OUT/$name.log")
            # A refused case counts only if the recorder is what failed it; its
            # draws are invisible, so the image rule failing it means something else broke.
            reason=$(grep -m1 -oE '\((unrecorded|GL drew)[^)]*\)' "$OUT/$name.log")
            if [[ $case == *_ok ]]; then
                if [ "$code" -eq 0 ]; then printf 'pass       %-26s %s\n' "$name" "${result#PASS }"
                else printf 'WRONG      %-26s exit %s, wanted a pass: %s\n' "$name" "$code" "$result"; bad=1; fi
            elif [ "$code" -eq 1 ] && [ -n "$reason" ] && ! grep -q '(outside limits)' "$OUT/$name.log"; then
                printf 'killed     %-26s %s\n' "$name" "$reason"
            else printf 'WRONG      %-26s exit %s, wanted a recorder refusal: %s\n' "$name" "$code" "$result"; bad=1; fi
        done
        continue
    fi
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
