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
# Paths below are relative: from anywhere but a tree's root it would find
# nothing and blame the project for a shader it never looked for.
[ -d metal ] || { echo "parity/bundlecheck.sh: run it from a hyperspace tree's root (no metal/ in $PWD)" >&2; exit 2; }
# What belongs: the files git tracks under metal/, or, in an archive with no
# git (test-saver's), the files there, which are only tracked ones. Paths are
# relative to metal/. -z, because git quotes a name holding a quote or a
# backslash otherwise, whatever core.quotePath says.
if tracked=$(git ls-files -z -- metal 2>/dev/null | tr '\0' '\n' | sed 's|^metal/||') && [ -n "$tracked" ]; then :; else
    tracked=$(cd metal && find . \( -type f -o -type l \) | sed 's|^\./||')
fi
# A symlink is listed too: the folder reference copies one like any file.
bundled=$(cd -- "$1/Contents/Resources/metal" && find . \( -type f -o -type l \) | sed 's|^\./||') ||
    { echo "$1 has no Contents/Resources/metal" >&2; exit 1; }
while IFS= read -r f; do
    [ -n "$f" ] || continue
    b="$1/Contents/Resources/metal/$f"
    [ -f "metal/$f" ] || { echo "metal/$f is tracked but not in the working tree: git rm it, or restore it" >&2; exit 1; }
    [ -f "$b" ] || { echo "$1 lacks metal/$f: check the project's metal folder reference and its Copy Metal Sources phase" >&2; exit 1; }
    cmp -s "metal/$f" "$b" || { echo "$1 holds a different metal/$f from the tree's" >&2; exit 1; }
done <<< "$tracked"
# find sees dotfiles (an editor's swap file) as well as subdirectories.
while IFS= read -r f; do
    [ -n "$f" ] || continue
    grep -qxF -- "$f" <<< "$tracked" ||
        { echo "$1 holds metal/$f, which git does not track: a stray file in metal/ was bundled" >&2; exit 1; }
done <<< "$bundled"
