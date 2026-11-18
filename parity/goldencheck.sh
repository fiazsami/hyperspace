#!/bin/bash
# Judges the Metal saver against approved images of itself (ss-ss8.1), and
# proves the judgement can fail.
#
# backendcheck.sh proved the backend drew what GL draws. Where the Metal saver
# is meant to look better than GL (ss-ss8, and every frame pass since the
# tone map, ss-z8x), GL stops being the reference, and
# these goldens take its place: each pass drawn through the backend at 480x270,
# six shots, kept in parity/golden/<pass>/, and compared with a new run under
# parity --compare's rule. See parity/README.md, Golden check.
#
# Then each fixture in KILL below is drawn the same way, from a copy of metal/
# with it in place, and must come out DIFFERENT from its pass's goldens. A
# fixture made from a shader other than today's is STALE, as in backendcheck.sh.
#
# --update rewrites the named passes' goldens, for a change meant to alter the
# picture once its look is approved; it runs no fixtures.
#
#   parity/goldencheck.sh [--update] [stars|goo|tunnel|burst|sun|goosoft ...]    default: all six
#
# Exit 0 = every pass SAME and every fixture killed (or updated), 1 = otherwise,
# 2 = a run failed or the arguments were wrong. Nothing is updated unless every
# argument is good.
set -uo pipefail
shopt -s nullglob
cd "$(dirname "$0")/.."

ALL=(stars goo tunnel burst sun goosoft)
SHOTS=6
# fixture:shader file:pass. The narrowest of the three is tunnel_fog110, a 10%
# fog change: 0.114% of lit pixels against --compare's 0.1%, through the tone
# map (hyperspace#59; it was 0.157% before).
KILL=(tunnel_fog110:Tunnel.metal:tunnel stars_fog110:FixedFunction.metal:stars stars_jumpstreak:FixedFunction.metal:stars)

update=0; passes=()
for arg in "$@"; do
    if [ "$arg" = --update ]; then update=1; continue; fi
    [[ " ${ALL[*]} " == *" $arg "* ]] || { echo "unknown pass $arg (one of: ${ALL[*]})" >&2; exit 2; }
    passes+=("$arg")
done
[ ${#passes[@]} -gt 0 ] || passes=("${ALL[@]}")

OUT=.parity-build/golden
rm -rf "$OUT"; mkdir -p "$OUT"
parity/build.sh >/dev/null || exit 2

run(){  # pass metal-dir outdir
    .parity-build/parity "$1" "$2" "$3" renderer=metal shots=$SHOTS w=480 h=270 samples=4 tunneldetail=2 > "$3.log" ||
        { echo "$1 run failed: $(tail -1 "$3.log")" >&2; exit 2; }
}
compare(){  # pass dir -> sets code
    .parity-build/parity --compare-golden "parity/golden/$1" "$2" > "$2.compare"; code=$?
    [ $code -le 1 ] || { echo "compare $1 failed: $(tail -1 "$2.compare")" >&2; exit 2; }
}

# Every run first, so a failed one leaves the goldens as they were.
for pass in "${passes[@]}"; do
    run "$pass" metal "$OUT/$pass"
    shots=("$OUT/$pass"/*_backend.png)
    [ ${#shots[@]} -eq $SHOTS ] || { echo "$pass shot ${#shots[@]} images, not $SHOTS" >&2; exit 2; }
done

if [ $update -eq 1 ]; then
    for pass in "${passes[@]}"; do
        rm -rf "parity/golden/$pass"; mkdir -p "parity/golden/$pass"
        cp "$OUT/$pass"/*_backend.png "parity/golden/$pass/" || exit 2
        printf '%-10s %-10s %s\n' updated "$pass" "$SHOTS shots"
    done
    exit 0
fi

bad=0
for pass in "${passes[@]}"; do
    [ -d "parity/golden/$pass" ] || { echo "no goldens for $pass: run with --update once the look is approved" >&2; exit 2; }
    compare "$pass" "$OUT/$pass"
    [ $code -eq 0 ] || bad=1
    printf '%-10s %-25s %s\n' "$([ $code -eq 0 ] && echo same || echo DIFFERENT)" "golden ($pass)" "$(tail -1 "$OUT/$pass.compare")"
done

for k in "${KILL[@]}"; do
    IFS=: read -r name file pass <<< "$k"
    [[ " ${passes[*]} " == *" $pass "* ]] || continue
    fixture=parity/defects/$name.metal
    [ -f "$fixture" ] || { echo "no fixture $fixture" >&2; exit 2; }
    base=$(head -1 "$fixture" | sed -n 's/.* base=\([0-9a-f]\{40\}\)$/\1/p')
    if [ "$base" != "$(git hash-object "metal/$file")" ]; then
        printf '%-10s %-25s made from another metal/%s\n' STALE "$name" "$file"; bad=1; continue
    fi
    metal=$OUT/variants/$name-metal; mkdir -p "$metal"; cp metal/*.metal "$metal/"
    tail -n +2 "$fixture" > "$metal/$file"
    run "$pass" "$metal" "$OUT/variants/$name"
    compare "$pass" "$OUT/variants/$name"
    verdict=killed; [ $code -eq 1 ] || { verdict=SURVIVED; bad=1; }
    printf '%-10s %-25s %s\n' "$verdict" "$name" "$(tail -1 "$OUT/variants/$name.compare")"
done
exit $bad
