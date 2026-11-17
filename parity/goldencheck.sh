#!/bin/bash
# Judges the Metal saver against approved images of itself (ss-ss8.1).
#
# backendcheck.sh proves the backend draws what GL draws. Where the Metal saver
# is meant to look better than GL (ss-ss8), GL stops being the reference, and
# these goldens take its place: each pass drawn through the backend at 480x270,
# six shots, kept in parity/golden/<pass>/, and compared with a new run under
# parity --compare's rule. The backend draws the same bytes run to run on one
# machine (measured, M5 Max, macOS 26), so a shot outside that rule is a change
# in the picture, wanted or not.
#
# A change meant to alter the picture updates the goldens in the same pull
# request, with --update, once the new look is approved from its images. A
# different GPU or macOS may move a few pixels; see parity/README.md.
#
#   parity/goldencheck.sh [--update] [stars|goo|tunnel|burst|sun|goosoft ...]    default: all six
#
# Exit 0 = every pass SAME (or updated), 1 = a pass DIFFERENT, 2 = a run failed.
set -uo pipefail
cd "$(dirname "$0")/.."

update=0
if [ "${1:-}" = --update ]; then update=1; shift; fi
passes=("$@"); [ ${#passes[@]} -gt 0 ] || passes=(stars goo tunnel burst sun goosoft)

# Six shots a pass: every = the pass's frames / 6 (the last frame is always shot).
every_for(){ case $1 in stars|goo|goosoft) echo 600;; tunnel) echo 1200;; burst) echo 80;; sun) echo 200;;
             *) echo "unknown pass $1" >&2; return 1;; esac; }

OUT=.parity-build/golden
rm -rf "$OUT"; mkdir -p "$OUT"
parity/build.sh >/dev/null || exit 2

bad=0
for pass in "${passes[@]}"; do
    every=$(every_for "$pass") || exit 2
    .parity-build/parity "$pass" metal "$OUT/$pass" renderer=metal every="$every" w=480 h=270 > "$OUT/$pass.log" ||
        { echo "$pass run failed: $(tail -1 "$OUT/$pass.log")" >&2; exit 2; }
    golden=parity/golden/$pass
    if [ $update -eq 1 ]; then
        rm -rf "$golden"; mkdir -p "$golden"
        cp "$OUT/$pass"/*_backend.png "$golden"/
        printf '%-10s %-10s %s\n' updated "$pass" "$(ls "$golden" | wc -l | tr -d ' ') shots"
        continue
    fi
    [ -d "$golden" ] || { echo "no goldens for $pass: run with --update once the look is approved" >&2; exit 2; }
    .parity-build/parity --compare-golden "$golden" "$OUT/$pass" > "$OUT/$pass.compare"; code=$?
    [ $code -le 1 ] || { echo "compare $pass failed: $(tail -1 "$OUT/$pass.compare")" >&2; exit 2; }
    [ $code -eq 0 ] || bad=1
    printf '%-10s %-10s %s\n' "$([ $code -eq 0 ] && echo same || echo DIFFERENT)" "$pass" "$(tail -1 "$OUT/$pass.compare")"
done
exit $bad
