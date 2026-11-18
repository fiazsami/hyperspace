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
unset CDPATH   # a cd under it prints the directory, which the listings below would read as a file
unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE   # git is asked about the tree in $PWD, not one a caller pointed at
[ $# -eq 1 ] || { echo "usage: parity/bundlecheck.sh <bundle.saver>" >&2; exit 2; }
# Paths below are relative: from anywhere but a tree's root it would find
# nothing and blame the project for a shader it never looked for.
[ -d metal ] || { echo "parity/bundlecheck.sh: run it from a hyperspace tree's root (no metal/ in $PWD)" >&2; exit 2; }
# What belongs. In a checkout (./.git, a directory or a submodule's file)
# git's list is the answer, empty or not, and any git failure is an error:
# listing metal/ instead would count an untracked file as belonging. With no
# ./.git, as in test-saver's archive, metal/ is listed as it is, and holds only
# what was tracked. -z, because git quotes a name holding a quote or a
# backslash otherwise, whatever core.quotePath says.
if [ -e .git ]; then
    tracked=$(git ls-files -z -- metal | tr '\0' '\n' | sed 's|^metal/||') ||
        { echo "git ls-files failed in $PWD" >&2; exit 2; }
else
    tracked=$(cd metal && find . ! -type d | sed 's|^\./||')
fi
[ -d "$1/Contents/Resources/metal" ] || { echo "$1 has no Contents/Resources/metal" >&2; exit 1; }
# Everything but directories, symlinks included: the folder reference copies a
# link like any file.
bundled=$(cd -- "$1/Contents/Resources/metal" && find . ! -type d | sed 's|^\./||') ||
    { echo "could not list $1/Contents/Resources/metal" >&2; exit 1; }
while IFS= read -r f; do
    [ -n "$f" ] || continue
    b="$1/Contents/Resources/metal/$f"
    # metal/ holds plain files. A link would be checked through its target
    # here and could break once installed, so none is allowed, either side.
    [ ! -L "metal/$f" ] && [ ! -L "$b" ] || { echo "metal/$f is a symlink: metal/ holds plain files only" >&2; exit 1; }
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
