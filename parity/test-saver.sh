#!/bin/bash
# The installed saver, at any commit, measured where users run it.
#
# install <ref>   builds <ref>'s saver renamed "Hyperspace Metal"
#                 (com.reallyslick.HyperspaceMetal, class HyperspaceMetalView),
#                 so it installs beside the user's own Hyperspace and never in
#                 its place; backs up the copy it replaces, installs, and
#                 restarts legacyScreenSaver so the next run loads it.
# restore         undoes the last install: puts back the copy it replaced, or
#                 removes the test copy if there was none.
# profile [secs]  waits (up to two hours) for the user to run Hyperspace Metal,
#                 lets it settle, then records secs (default 5) each of a Time
#                 Profiler and a Metal System Trace and reports: the saver's
#                 and WindowServer's CPU (top), where the saver's CPU goes, and
#                 the GPU busy time of each process (parity/saverprofile.py).
#                 Traces stay in .parity-build/test-saver/profile-<time>/.
#
# Needs Xcode (xcodebuild, xctrace). The saver is started by a person: this
# never selects or launches a screen saver itself.
set -uo pipefail
cd "$(dirname "$0")/.."
export DEVELOPER_DIR=${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}
OUT=$PWD/.parity-build/test-saver
SAVERS="$HOME/Library/Screen Savers"
NAME="Hyperspace Metal"

case ${1:-} in
install)
    [ $# -eq 2 ] || { echo "usage: parity/test-saver.sh install <ref>" >&2; exit 2; }
    sha=$(git rev-parse --verify "$2^{commit}") || exit 2
    src=$OUT/src-${sha:0:12}; rm -rf "$src"; mkdir -p "$src"
    git archive "$sha" | tar -x -C "$src" || exit 2
    # The class is renamed in the view and its principal-class entry; the
    # header keeps its file name, so its import stays as it was.
    sed -i '' 's/HyperspaceView/HyperspaceMetalView/g' "$src/HyperspaceView.h" "$src/HyperspaceView.mm" "$src/Info.plist"
    sed -i '' 's/"HyperspaceMetalView.h"/"HyperspaceView.h"/' "$src/HyperspaceView.mm"
    # Any other code naming the class would build a bundle with both names,
    # the clash the rename exists to avoid. (The nib's File's Owner names it
    # too; that class is never made from the nib.)
    # The saver's own sources only (parity and the tests are not built into
    # it), and code rather than comments.
    left=$(grep -rnw HyperspaceView --include='*.m' --include='*.mm' --include='*.h' --include='*.c' --include='*.cpp' \
            --exclude-dir=parity --exclude-dir=tests "$src" |
        grep -v '#import "HyperspaceView.h"' | grep -vE '^[^:]+:[0-9]+:[[:space:]]*(//|/?\*)')
    [ -z "$left" ] || { echo "code still names HyperspaceView after the rename:" >&2; echo "$left" >&2; exit 2; }
    (cd "$src" && xcodebuild -project Hyperspace.xcodeproj -target Hyperspace -configuration Release \
        SYMROOT="$src/sym" OBJROOT="$src/obj" "PRODUCT_NAME=$NAME" PRODUCT_BUNDLE_IDENTIFIER=com.reallyslick.HyperspaceMetal \
        build > "$src/build.log" 2>&1) || { echo "build failed: $src/build.log" >&2; exit 2; }
    built="$src/sym/Release/$NAME.saver"
    [ "$(plutil -extract NSPrincipalClass raw "$built/Contents/Info.plist")" = HyperspaceMetalView ] ||
        { echo "the built bundle's class is not HyperspaceMetalView" >&2; exit 2; }
    # The last install's backup, or "none" when there was no copy to back up,
    # is what restore puts back: an older backup belongs to an older install.
    backup=none
    if [ -d "$SAVERS/$NAME.saver" ]; then
        backup=$OUT/backup-$(date +%Y%m%d-%H%M%S).saver
        cp -R "$SAVERS/$NAME.saver" "$backup" || exit 2
        echo "backed up the installed copy to $backup"
    fi
    echo "$backup" > "$OUT/last-backup"
    rm -rf "$SAVERS/$NAME.saver" && cp -R "$built" "$SAVERS/" || exit 2
    pkill -x legacyScreenSaver
    echo "installed $NAME at ${sha:0:12}"
    ;;
restore)
    [ -f "$OUT/last-backup" ] || { echo "nothing installed by this script to undo" >&2; exit 2; }
    backup=$(cat "$OUT/last-backup")
    if [ "$backup" = none ]; then
        rm -rf "$SAVERS/$NAME.saver" && pkill -x legacyScreenSaver
        echo "removed $NAME: there was none before the last install"
    else
        [ -d "$backup" ] || { echo "the last install's backup $backup is gone" >&2; exit 2; }
        rm -rf "$SAVERS/$NAME.saver" && cp -R "$backup" "$SAVERS/$NAME.saver" && pkill -x legacyScreenSaver
        echo "restored $backup"
    fi
    rm -f "$OUT/last-backup"
    ;;
profile)
    secs=${2:-5}
    dir=$OUT/profile-$(date +%Y%m%d-%H%M%S); mkdir -p "$dir"
    echo "waiting for $NAME to run full-screen..."
    pid=; hits=0
    for _ in $(seq 1 7200); do
        cand=$(ps -Ao pid=,pcpu=,comm= | awk '/legacyScreenSaver/ && $2 > 5 {print $1}' | while read -r p; do
            lsof -p "$p" 2>/dev/null | grep -q "$NAME.saver/" && echo "$p"; done | head -1)
        if [ -n "$cand" ]; then pid=$cand; hits=$((hits + 1)); else hits=0; fi
        [ $hits -ge 3 ] && break
        sleep 1
    done
    [ $hits -ge 3 ] || { echo "$NAME never ran" >&2; exit 1; }
    sleep 5
    ws=$(pgrep -x WindowServer | head -1)
    # Each xctrace step logs to the profile directory and stops the run when it fails.
    xt(){ local log=$1; shift; xcrun xctrace "$@" > "$dir/$log.log" 2>&1 || { echo "xctrace $1 failed: $dir/$log.log" >&2; tail -3 "$dir/$log.log" >&2; exit 2; }; }
    xt cpu-record record --template "Time Profiler" --attach "$pid" --time-limit "${secs}s" --output "$dir/cpu.trace"
    # top's first sample has nothing to measure against and reads 0%: skipped.
    top -l 4 -s 2 -stats pid,cpu 2>/dev/null | awk -v p="$pid" -v w="$ws" '/^Processes:/ {k++} k < 2 {next}
        $1 == p {s += $2; n++} $1 == w {ws += $2; m++}
        END {if (!n || !m) {print "  top did not see the saver and WindowServer"; exit 1}
             printf "  saver CPU %.1f%%   WindowServer CPU %.1f%%   (top, 3 samples)\n", s / n, ws / m}'
    xt gpu-record record --template "Metal System Trace" --all-processes --time-limit "${secs}s" --output "$dir/gpu.trace"
    xcrun xctrace export --input "$dir/cpu.trace" --xpath '/trace-toc/run[@number="1"]/data/table[@schema="time-profile"]' > "$dir/cpu.xml" 2> "$dir/cpu-export.log"
    xcrun xctrace export --input "$dir/gpu.trace" --xpath '/trace-toc/run[@number="1"]/data/table[@schema="metal-gpu-intervals"]' > "$dir/gpu.xml" 2> "$dir/gpu-export.log"
    for t in cpu gpu; do
        grep -q '<row' "$dir/$t.xml" || { echo "the $t trace exported no rows: $dir/$t-export.log" >&2; exit 2; }
    done
    echo "where the saver's CPU goes:"; python3 -I parity/saverprofile.py cpu "$dir/cpu.xml"
    echo "GPU, busiest first (the saver is legacyScreenSaver ($pid)):"
    python3 -I parity/saverprofile.py gpu "$dir/gpu.xml" "$secs" | awk -v p="($pid)" 'NR <= 8 || index($0, p) || /WindowServer/'
    echo "traces: $dir"
    ;;
*)
    echo "usage: parity/test-saver.sh install <ref> | restore | profile [secs]" >&2; exit 2;;
esac
