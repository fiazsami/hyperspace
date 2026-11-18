#!/bin/bash
# The saver's bundle holds metal/ as the tree does: every shader, byte for
# byte, and nothing else.
#
# The renderer compiles metal/ at run time from the bundle, so a shader the
# bundle lacks builds clean and passes every parity gate (parity compiles from
# the tree), then fails only in the saver: "Could not start Metal backend", as
# ToneMap.metal once did. The project copies metal/ whole (a folder
# reference), so a missing shader means that reference or its copy phase is
# broken; and whatever else sits in the working tree's metal/ is copied too,
# which is why extra files are refused. Run by test-saver.sh install and the
# tests workflow.
#
#   parity/bundlecheck.sh <bundle.saver>     from the repository's root
#
# Exit 0 = the bundle's metal/ is the tree's, 1 = not.
set -uo pipefail
[ $# -eq 1 ] || { echo "usage: parity/bundlecheck.sh <bundle.saver>" >&2; exit 2; }
# The glob below is relative: from anywhere but a tree's root it matches
# nothing and would blame the project for a shader it never looked for.
[ -d metal ] || { echo "parity/bundlecheck.sh: run it from a hyperspace tree's root (no metal/ in $PWD)" >&2; exit 2; }
for m in metal/*.metal; do
    b="$1/Contents/Resources/metal/$(basename "$m")"
    [ -f "$b" ] || { echo "$1 lacks metal/$(basename "$m"): check the project's metal folder reference and its Copy Metal Sources phase" >&2; exit 1; }
    cmp -s "$m" "$b" || { echo "$1 holds a different metal/$(basename "$m") from the tree's" >&2; exit 1; }
done
# What belongs: the files git tracks in metal/, or, in an archive with no git
# (test-saver's), the directory as it is, which holds only tracked files.
if tracked=$(git ls-files -- metal 2>/dev/null) && [ -n "$tracked" ]; then :; else
    tracked=$(ls -1 metal | sed 's|^|metal/|')
fi
for b in "$1"/Contents/Resources/metal/*; do
    grep -qxF "metal/$(basename "$b")" <<< "$tracked" ||
        { echo "$1 holds metal/$(basename "$b"), which git does not track: a stray file in metal/ was bundled" >&2; exit 1; }
done
