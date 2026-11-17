#!/bin/bash
# Compares the working tree's Metal saver with <ref>'s, as each draws as the
# saver does: what it costs and what it looks like. The method for evolving
# the saver in any direction (parity/README.md, Evolving the saver): the
# reference is a commit, not a mode kept in the code.
#
# Cost: `parity <pass> ... look=saver time` at 3440x1440 over the pass's own
# frames (the footage its look shots come from: the tunnel pass is two minutes
# because one rarely reaches the inside of a tunnel), the two sides alternated (ref new ref new) so drift lands on both. Reported per pass:
# GPU ms a frame (median) and the process's CPU ms a frame (mean), each side's
# two runs averaged, the change, and the noise -- the reference's own
# run-to-run difference. Only the reference's: the side being judged must not
# set its own bar, or a change that made timings erratic would raise it. A change counts only past the larger of twice
# that noise and 2% of the reference: with nothing changed the two sides'
# GPU differs by under 0.3% and CPU by up to a few percent on the cheapest
# passes (measured, refcheck against itself), more than either side moves on
# its own. Nor below 0.003 ms a frame (0.2 ms a second at 60 fps): the
# cheapest passes' CPU drifted up to 0.0026 ms against themselves. Timings are printed to 0.00001 ms, so rounding never
# reaches that 2% (the cheapest passes are about 0.04 ms a frame).
#
# Look: six shots of each pass through `parity --compare-look` (mid-tones kept,
# no shot darker, clipped pixels reported), and a page flipping between the
# two sides at full size: .parity-build/ref/index.html.
#
# <ref> must have parity's look=saver and time (this harness, ss-z8x.1, on);
# an older one is refused, not approximated.
#
#   parity/refcheck.sh <ref> [stars|goo|tunnel|burst|sun ...]    default: all five
#   REFCHECK_COST=goo,tunnel parity/refcheck.sh <ref>             cost for these passes only
#
# Exit 0 = look KEPT and cost not above the noise, 1 = either changed (read
# the report: a change may be the point), 2 = a run or build failed.
set -uo pipefail
cd "$(dirname "$0")/.."
[ $# -ge 1 ] || { echo "usage: parity/refcheck.sh <ref> [pass ...]" >&2; exit 2; }
ref=$1; shift
passes=("$@"); [ ${#passes[@]} -gt 0 ] || passes=(stars goo tunnel burst sun)
for pass in "${passes[@]}"; do
    case $pass in stars|goo|tunnel|burst|sun) ;; *) echo "unknown pass $pass (goosoft is goo as the saver draws it)" >&2; exit 2;; esac
done
costList=${REFCHECK_COST:-}
cost=(${costList//,/ }); [ ${#cost[@]} -gt 0 ] || cost=("${passes[@]}")
for pass in "${cost[@]}"; do
    case $pass in stars|goo|tunnel|burst|sun) ;; *) echo "unknown pass $pass in REFCHECK_COST" >&2; exit 2;; esac
done
sha=$(git rev-parse --verify "$ref^{commit}") || exit 2

OUT=.parity-build/ref
WT=.parity-build/ref-tree
rm -rf "$OUT"; mkdir -p "$OUT"
parity/at-ref.sh "$sha" "$WT" || exit 2
parity/build.sh >/dev/null || exit 2
REF=$WT/.parity-build/parity; NEW=.parity-build/parity
usage=$("$REF" 2>&1)   # parity prints its usage and exits 2, so not a pipeline under pipefail
[[ $usage == *look=saver* ]] ||
    { echo "$ref's parity has no look=saver: refcheck compares with commits from ss-z8x.1 on" >&2; exit 2; }

bin_for(){ [ "$1" = ref ] && echo "$REF" || echo "$NEW"; }
metal_for(){ [ "$1" = ref ] && echo "$WT/metal" || echo metal; }

bad=0
echo "look ($ref against the working tree, as the saver draws)"
for pass in "${passes[@]}"; do
    for side in ref new; do
        "$(bin_for $side)" "$pass" "$(metal_for $side)" "$OUT/$side/$pass" renderer=metal look=saver shots=6 > "$OUT/$side-$pass.log" ||
            { echo "$side $pass run failed: $(tail -1 "$OUT/$side-$pass.log")" >&2; exit 2; }
    done
    .parity-build/parity --compare-look "$OUT/ref/$pass" "$OUT/new/$pass" > "$OUT/$pass.look"; code=$?
    [ $code -le 1 ] || { echo "compare $pass failed: $(tail -1 "$OUT/$pass.look")" >&2; exit 2; }
    [ $code -eq 0 ] || bad=1
    printf '  %-7s %s\n' "$pass" "$(tail -1 "$OUT/$pass.look")"
done

echo "cost (3440x1440, each pass's own frames, ref new ref new)"
printf '  %-7s %26s %30s\n' "" "GPU ms/frame ref -> new" "process CPU ms/frame ref -> new"
for pass in "${cost[@]}"; do
    for run in 1 2; do
        for side in ref new; do
            "$(bin_for $side)" "$pass" "$(metal_for $side)" "$OUT/time/$side$run-$pass" renderer=metal look=saver time \
                shots=1 w=3440 h=1440 > "$OUT/time-$side$run-$pass.log" ||
                { echo "$side $pass timing failed: $(tail -1 "$OUT/time-$side$run-$pass.log")" >&2; exit 2; }
        done
    done
    line=$(for f in ref1 new1 ref2 new2; do grep '^TIME' "$OUT/time-$f-$pass.log"; done | awk '
        { for (i = 1; i <= NF; i++) { if ($i == "gpu_ms") g[NR] = substr($(i+1), 8); if ($i == "process_cpu_ms") c[NR] = substr($(i+1), 6) } }
        function abs(x) { return x < 0 ? -x : x }
        END {
            # +0: substr() gives strings, and "0.00000" <= 0 compares as text.
            for (i = 1; i <= 4; i++) if (NR != 4 || g[i] + 0 <= 0 || c[i] + 0 <= 0) { print "ERROR"; exit }
            gr = (g[1] + g[3]) / 2; gn = (g[2] + g[4]) / 2; gnoise = abs(g[1] - g[3])
            cr = (c[1] + c[3]) / 2; cn = (c[2] + c[4]) / 2; cnoise = abs(c[1] - c[3])
            gl = 2 * gnoise > 0.02 * gr ? 2 * gnoise : 0.02 * gr; cl = 2 * cnoise > 0.02 * cr ? 2 * cnoise : 0.02 * cr
            if (gl < 0.003) gl = 0.003; if (cl < 0.003) cl = 0.003
            higher = (gn - gr > gl) || (cn - cr > cl)
            printf "%6.3f -> %6.3f (%+6.1f%%, noise %.3f)  %6.3f -> %6.3f (%+6.1f%%, noise %.3f)  %s",
                gr, gn, 100 * (gn - gr) / gr, gnoise, cr, cn, 100 * (cn - cr) / cr, cnoise, higher ? "HIGHER" : "not higher"
        }')
    [[ $line == ERROR* || -z $line ]] && { echo "$pass: no usable timings in $OUT/time-*-$pass.log" >&2; exit 2; }
    [[ $line == *HIGHER* ]] && bad=1
    printf '  %-7s %s\n' "$pass" "$line"
done

# The page: every shot of every pass, most changed first, each image flipping
# between the two sides on click.
{
    echo '<!doctype html><meta charset="utf-8"><title>refcheck</title>'
    echo '<style>body{background:#111;color:#ddd;font:14px -apple-system,sans-serif;margin:16px}img{max-width:100%;cursor:pointer;display:block}figure{margin:0 0 20px}</style>'
    echo "<h1>$ref (ref) against the working tree (new)</h1><p>Click an image to flip it between the two. Shots outside a rule first, then by mid-tone change.</p>"
    for pass in "${passes[@]}"; do
        echo "<h2>$pass</h2><pre>$(tail -1 "$OUT/$pass.look")</pre>"
        grep '_backend.png' "$OUT/$pass.look" | awk '{print ($NF == "CHANGED" ? 1 : 0), $4, $0}' | sort -k1,1nr -k2,2gr |
            cut -d' ' -f3- | awk '{print $1, $0}' | while read -r shot rest; do
            printf '<figure><img src="ref/%s/%s" data-a="ref/%s/%s" data-b="new/%s/%s"><figcaption>%s -- showing ref</figcaption></figure>\n' \
                "$pass" "$shot" "$pass" "$shot" "$pass" "$shot" "$rest"
        done
    done
    echo '<script>document.querySelectorAll("img").forEach(i=>i.onclick=()=>{const b=i.getAttribute("src")===i.dataset.a;i.src=b?i.dataset.b:i.dataset.a;const c=i.nextElementSibling;c.textContent=c.textContent.replace(/showing (ref|new)/,"showing "+(b?"new":"ref"))})</script>'
} > "$OUT/index.html"
echo "page: $OUT/index.html"
exit $bad
