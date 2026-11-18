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
[ $# -eq 1 ] || { echo "usage: parity/bundlecheck.sh <bundle.saver>" >&2; exit 2; }
# Paths below are relative: from anywhere but a tree's root it would find
# nothing and blame the project for a shader it never looked for.
[ -d metal ] || { echo "parity/bundlecheck.sh: run it from a hyperspace tree's root (no metal/ in $PWD)" >&2; exit 2; }
# What belongs: the files git tracks under metal/, or, in an archive with no
# git (test-saver's), the files there, which are only tracked ones. Paths are
# relative to metal/. -z, because git quotes a name holding a quote or a
# backslash otherwise, whatever core.quotePath says.
# Any other git failure is an error: the directory listing would count an
# untracked file as belonging.
tracked=
if command -v git >/dev/null && gitdir=$(git rev-parse --git-dir 2>&1); then
    tracked=$(git ls-files -z -- metal | tr '\0' '\n' | sed 's|^metal/||') ||
        { echo "git ls-files failed in $PWD" >&2; exit 2; }
elif command -v git >/dev/null && [[ $gitdir != *"not a git repository"* ]]; then
    echo "git failed in $PWD: $gitdir" >&2; exit 2
fi
# Empty: no repository, or an archive inside one that git ignores (test-saver's).
[ -n "$tracked" ] || tracked=$(cd metal && find . ! -type d | sed 's|^\./||')
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
