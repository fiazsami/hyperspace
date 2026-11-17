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
# and must FAIL its pass against the same GL images. So must every
# parity/defects/<pass>_*.metal: a copy of the pass's shader file with one
# translation defect, drawn through the backend from a copy of metal/ with it in
# place. The goo pass also takes parity/defects/goobuild_*.metal, defects in
# GooBuild.metal, the kernel the backend builds the goo's surface with. A
# fixture that changes nothing is an error, not a survivor.
#
# textures and caustics are not passes but the same shape. `parity
# --backend-textures` uploads mip chains and six different cube faces through
# both backends and compares every level and face byte for byte, since no pass
# reads the textures back. `parity --backend-caustics` makes the tunnel's
# caustic textures through both backends' offscreen targets and compares every
# level. Their fixtures are backend_textures_*.sed and backend_caustics_*.sed.
#
# About 8 minutes for everything (8m03s measured on an M5 Max, 2026-11-16:
# eight passes, 63 fixtures, the goo at resolution 20; since then two more
# goosoft fixtures, and two backend stars fixtures for one shader stars fixture).
#
#   parity/backendcheck.sh [stars|goo|tunnel|burst|sun|goosoft|textures|caustics ...]    default: all eight
#
# Exit 0 = the backend passes and every fixture is killed, 1 = otherwise,
# 2 = a run or build failed.
set -uo pipefail
shopt -s nullglob
cd "$(dirname "$0")/.."
passes=("$@"); [ ${#passes[@]} -gt 0 ] || passes=(stars goo tunnel burst sun goosoft textures caustics)

OUT=.parity-build/backend
rm -rf "$OUT"; mkdir -p "$OUT/variants"
parity/build.sh >/dev/null || exit 2

bad=0
for pass in "${passes[@]}"; do
    if [ "$pass" = textures ] || [ "$pass" = caustics ]; then
        .parity-build/parity --backend-$pass metal > "$OUT/$pass.compare"; code=$?
        [ $code -le 1 ] || { echo "$pass failed: $(tail -1 "$OUT/$pass.compare")" >&2; exit 2; }
    else
        .parity-build/parity "$pass" metal "$OUT/$pass/gl" > "$OUT/$pass-gl.log" ||
            { echo "GL $pass run failed: $(tail -1 "$OUT/$pass-gl.log")" >&2; exit 2; }
        .parity-build/parity "$pass" metal "$OUT/$pass/backend" renderer=metal > "$OUT/$pass-backend.log" ||
            { echo "backend $pass run failed: $(tail -1 "$OUT/$pass-backend.log")" >&2; exit 2; }
        .parity-build/parity --compare-backend "$pass" "$OUT/$pass/gl" "$OUT/$pass/backend" > "$OUT/$pass.compare"; code=$?
        [ $code -le 1 ] || { echo "compare $pass failed: $(tail -1 "$OUT/$pass.compare")" >&2; exit 2; }
    fi
    verdict=pass; [ $code -eq 0 ] || { verdict=FAIL; bad=1; }
    printf '%-10s %-25s %s\n' "$verdict" "backend ($pass)" "$(tail -1 "$OUT/$pass.compare")"

    fixtures=(parity/defects/backend_"$pass"_*.sed parity/defects/"$pass"_*.metal)
    [ "$pass" = goo ] && fixtures+=(parity/defects/goobuild_*.metal)
    if [ ${#fixtures[@]} -eq 0 ]; then
        printf 'NO FIXTURES %-25s parity/defects/backend_%s_*.sed and %s_*.metal match nothing\n' "$pass" "$pass" "$pass"; bad=1
    fi
    for fixture in ${fixtures[@]+"${fixtures[@]}"}; do
        if [[ $fixture == *.metal ]]; then
            # A shader defect: the committed backend, drawing from a metal/ with
            # the defect in place of the pass's shader file.
            name=$(basename "$fixture" .metal); bin=.parity-build/parity; metal=$OUT/variants/$name-metal
            case $name in goobuild_*) file=GooBuild.metal;; *)
                case $pass in goo|burst) file=Goo.metal;; goosoft) file=Soften.metal;; tunnel) file=Tunnel.metal;; *) file=FixedFunction.metal;; esac;;
            esac
            # Line 1 names the blob of metal/$file the fixture was made from. A
            # shader changed since then would make the fixture differ by the
            # change as well as by its defect, and it would be killed for that.
            base=$(head -1 "$fixture" | sed -n 's/.* base=\([0-9a-f]\{40\}\)$/\1/p')
            if [ "$base" != "$(git hash-object "metal/$file")" ]; then
                printf 'STALE      %-25s made from %s, not metal/%s as it is; regenerate it\n' "$name" "${base:-no base}" "$file"; bad=1; continue
            fi
            if tail -n +2 "$fixture" | cmp -s - "metal/$file"; then
                printf 'NO CHANGE  %-25s the fixture is metal/%s as committed\n' "$name" "$file"; bad=1; continue
            fi
            rm -rf "$metal"; mkdir -p "$metal"; cp metal/*.metal "$metal/"; cp "$fixture" "$metal/$file"
        else
            name=$(basename "$fixture" .sed); bin=$OUT/variants/$name; metal=metal
            src=$OUT/variants/$name.mm
            sed -f "$fixture" Hyperspace/rendererMetal.mm > "$src"
            if cmp -s "$src" Hyperspace/rendererMetal.mm; then
                printf 'NO CHANGE  %-25s the fixture no longer matches rendererMetal.mm\n' "$name"; bad=1; continue
            fi
            parity/build.sh --backend "$src" "$bin" > "$OUT/variants/$name.build" 2>&1 ||
                { echo "build of $name failed: $(tail -1 "$OUT/variants/$name.build")" >&2; exit 2; }
        fi
        if [ "$pass" = textures ] || [ "$pass" = caustics ]; then
            "$bin" --backend-$pass "$metal" > "$OUT/variants/$name.log"; code=$?
            line=$(tail -1 "$OUT/variants/$name.log")
        else
            "$bin" "$pass" "$metal" "$OUT/$pass/$name" renderer=metal > "$OUT/variants/$name.log"; code=$?
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
