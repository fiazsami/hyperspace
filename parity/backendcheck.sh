#!/bin/bash
# Judges the Metal backend (HSRendererMetal) against the GL renderer, and proves
# the judgement can fail.
#
# For each pass: one run through GL (its _gl.png), one through the backend
# (renderer=metal, its _backend.png), then `parity --compare-backend` under the
# pass's own rules. Both runs share the seed, so they draw the same frames.
#
# Then every parity/defects/backend_<pass>_*.sed is applied to a copy of
# Hyperspace/rendererMetal.mm, built into its own parity (build.sh --backend),
# and must FAIL its pass against the same GL images. A fixture that changes
# nothing is an error, not a survivor. The backend has no tunnel yet, so stars,
# goo, burst and sun run; tunnel does not.
#
# textures is not a pass but the same shape: `parity --backend-textures` uploads
# mip chains and six different cube faces through both backends and compares
# every level and face byte for byte, since no pass reads the textures back.
# Its fixtures are backend_textures_*.sed. About 4 minutes.
#
#   parity/backendcheck.sh [stars|goo|burst|sun|textures ...]    default: all five
#
# Exit 0 = the backend passes and every fixture is killed, 1 = otherwise,
# 2 = a run or build failed.
set -uo pipefail
shopt -s nullglob
cd "$(dirname "$0")/.."
passes=("$@"); [ ${#passes[@]} -gt 0 ] || passes=(stars goo burst sun textures)

OUT=.parity-build/backend
rm -rf "$OUT"; mkdir -p "$OUT/variants"
parity/build.sh >/dev/null || exit 2

bad=0
for pass in "${passes[@]}"; do
    if [ "$pass" = textures ]; then
        .parity-build/parity --backend-textures metal > "$OUT/$pass.compare"; code=$?
        [ $code -le 1 ] || { echo "textures failed: $(tail -1 "$OUT/$pass.compare")" >&2; exit 2; }
    else
        .parity-build/parity "$pass" metal "$OUT/$pass/gl" > "$OUT/$pass-gl.log"; code=$?
        # Exit 1 is the replay's verdict, which is not what this judges.
        [ $code -le 1 ] || { echo "GL $pass run failed (exit $code): $(tail -1 "$OUT/$pass-gl.log")" >&2; exit 2; }
        .parity-build/parity "$pass" metal "$OUT/$pass/backend" renderer=metal > "$OUT/$pass-backend.log" ||
            { echo "backend $pass run failed: $(tail -1 "$OUT/$pass-backend.log")" >&2; exit 2; }
        .parity-build/parity --compare-backend "$pass" "$OUT/$pass/gl" "$OUT/$pass/backend" > "$OUT/$pass.compare"; code=$?
        [ $code -le 1 ] || { echo "compare $pass failed: $(tail -1 "$OUT/$pass.compare")" >&2; exit 2; }
    fi
    verdict=pass; [ $code -eq 0 ] || { verdict=FAIL; bad=1; }
    printf '%-10s %-25s %s\n' "$verdict" "backend ($pass)" "$(tail -1 "$OUT/$pass.compare")"

    fixtures=(parity/defects/backend_"$pass"_*.sed)
    if [ ${#fixtures[@]} -eq 0 ]; then
        printf 'NO FIXTURES %-25s parity/defects/backend_%s_*.sed matches nothing\n' "$pass" "$pass"; bad=1
    fi
    for fixture in ${fixtures[@]+"${fixtures[@]}"}; do
        name=$(basename "$fixture" .sed)
        src=$OUT/variants/$name.mm; bin=$OUT/variants/$name
        sed -f "$fixture" Hyperspace/rendererMetal.mm > "$src"
        if cmp -s "$src" Hyperspace/rendererMetal.mm; then
            printf 'NO CHANGE  %-25s the fixture no longer matches rendererMetal.mm\n' "$name"; bad=1; continue
        fi
        parity/build.sh --backend "$src" "$bin" > "$OUT/variants/$name.build" 2>&1 ||
            { echo "build of $name failed: $(tail -1 "$OUT/variants/$name.build")" >&2; exit 2; }
        if [ "$pass" = textures ]; then
            "$bin" --backend-textures metal > "$OUT/variants/$name.log"; code=$?
            line=$(tail -1 "$OUT/variants/$name.log")
        else
            "$bin" "$pass" metal "$OUT/$pass/$name" renderer=metal > "$OUT/variants/$name.log"; code=$?
            line=$(tail -1 "$OUT/variants/$name.log")
            if [ $code -eq 0 ]; then
                .parity-build/parity --compare-backend "$pass" "$OUT/$pass/gl" "$OUT/$pass/$name" > "$OUT/variants/$name.compare"; code=$?
                line=$(tail -1 "$OUT/variants/$name.compare")
            fi
        fi
        [ $code -le 1 ] || line="run exited $code: $line"
        # Only a FAIL verdict counts as killed; a crashed run proves nothing.
        if [ $code -eq 1 ]; then printf '%-10s %-25s %s\n' killed "$name" "$line"
        else printf '%-10s %-25s %s\n' SURVIVED "$name" "$line"; bad=1; fi
    done
done
exit $bad
