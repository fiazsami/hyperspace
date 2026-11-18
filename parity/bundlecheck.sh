#!/bin/bash
# The saver's bundle holds every shader in metal/, byte for byte.
#
# The renderer compiles metal/ at run time from the bundle, so a shader the
# project's Copy Metal Sources misses builds clean and passes every parity
# gate (parity compiles from the tree), then fails only in the saver: "Could
# not start Metal backend", as ToneMap.metal once did. Run by test-saver.sh
# install and the tests workflow.
#
#   parity/bundlecheck.sh <bundle.saver>     from the repository's root
#
# Exit 0 = every metal/*.metal is in the bundle and the same file, 1 = not.
set -uo pipefail
[ $# -eq 1 ] || { echo "usage: parity/bundlecheck.sh <bundle.saver>" >&2; exit 2; }
# The glob below is relative: from anywhere but a tree's root it matches
# nothing and would blame the project for a shader it never looked for.
[ -d metal ] || { echo "parity/bundlecheck.sh: run it from a hyperspace tree's root (no metal/ in $PWD)" >&2; exit 2; }
for m in metal/*.metal; do
    b="$1/Contents/Resources/metal/$(basename "$m")"
    [ -f "$b" ] || { echo "$1 lacks metal/$(basename "$m"): add it to the project's Copy Metal Sources" >&2; exit 1; }
    cmp -s "$m" "$b" || { echo "$1 holds a different metal/$(basename "$m") from the tree's" >&2; exit 1; }
done
