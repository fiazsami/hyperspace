#!/bin/bash
# Builds parity/parity.mm against Hyperspace's unmodified sources into
# .parity-build/parity. Drives xcrun clang directly, like the tests workflow; the
# Xcode project is not involved.
#
#   parity/build.sh [--backend <rendererMetal.mm> <out-binary>]
#
# --backend links <out-binary> with that file in place of the Metal backend's own
# source; parity/backendcheck.sh builds its kill-check variants this way.
set -euo pipefail
cd "$(dirname "$0")/.."
variant=; variantOut=
if [ $# -gt 0 ]; then
    [ $# -eq 3 ] && [ "$1" = --backend ] || { echo "usage: parity/build.sh [--backend <src.mm> <out-binary>]" >&2; exit 2; }
    variant=$2; variantOut=$3
fi

OUT=.parity-build
mkdir -p "$OUT/obj"
INC=(-I. -IHyperspace -IrsMath -IImplicit -Iutil -include Hyperspace_Prefix.pch -DGL_SILENCE_DEPRECATION)
CXXFLAGS=(-std=c++17 -O2 -w "${INC[@]}")   # Hyperspace's own sources, as they are, warnings and all
MMFLAGS=(-std=c++17 -O2 -ObjC++ -fobjc-arc -Wall "${INC[@]}")
PARITYFLAGS=(-std=c++17 -O2 -ObjC++ -fobjc-arc -Wall -Wno-deprecated-declarations -Wno-missing-declarations "${INC[@]}")
SOURCES=(Hyperspace/*.cpp rsMath/*.cpp Implicit/*.cpp Rgbhsl/*.cpp)

# An object is rebuilt when what it was built from changes -- by content, not by
# time. Modification times compare at one-second resolution here, so a file
# restored in the same second as a build looked unchanged and a stale object
# survived (ss-a4a.4.9). What it was built from: its source, every header in the
# tree (not a list of directories, which a new one would slip past), the flags,
# and the compiler and SDK. Each object keeps that key beside it, in <obj>.key,
# written only after it compiles.
toolchain=$(xcrun clang++ --version | head -1; xcrun --show-sdk-path)
headers=$( { echo "$toolchain"; echo "${CXXFLAGS[*]}|${MMFLAGS[*]}|${PARITYFLAGS[*]}"
    find . \( -path ./.parity-build -o -path ./build -o -path ./.git \) -prune -o \
        -type f \( -name '*.h' -o -name '*.hh' -o -name '*.hpp' -o -name '*.inl' -o -name '*.pch' \) -print |
        LC_ALL=C sort | tr '\n' '\0' | xargs -0 shasum; } | shasum | cut -d' ' -f1)
# One shasum for every source; keyof looks a source up without starting a process.
digests=$(shasum "${SOURCES[@]}" Hyperspace/*.mm parity/parity.mm)
keyof() {
    local digest file
    while read -r digest file; do [ "$file" = "$1" ] && { echo "$headers$digest"; return; }; done <<<"$digests"
    echo "no digest for $1" >&2; exit 2
}
stale() { [ ! -e "$1" ] || [ "$(cat "$1.key" 2>/dev/null)" != "$2" ]; }
objs=()
for src in "${SOURCES[@]}"; do
    obj="$OUT/obj/${src//\//_}.o"; k=$(keyof "$src")
    if stale "$obj" "$k"; then
        xcrun clang++ "${CXXFLAGS[@]}" -c "$src" -o "$obj"
        echo "$k" > "$obj.key"
    fi
    objs+=("$obj")
done
# The Metal backend, which renderer=metal draws through.
mmobjs=()
for src in Hyperspace/*.mm; do
    obj="$OUT/obj/${src//\//_}.o"; k=$(keyof "$src")
    if stale "$obj" "$k"; then
        xcrun clang++ "${MMFLAGS[@]}" -c "$src" -o "$obj"
        echo "$k" > "$obj.key"
    fi
    mmobjs+=("$obj")
done

# Rebuilt only when stale: backendcheck.sh calls this once per fixture.
k=$(keyof parity/parity.mm)
if stale "$OUT/obj/parity.o" "$k"; then
    xcrun clang++ "${PARITYFLAGS[@]}" -c parity/parity.mm -o "$OUT/obj/parity.o"
    echo "$k" > "$OUT/obj/parity.o.key"
fi
FRAMEWORKS=(-framework Cocoa -framework OpenGL -framework Metal -framework QuartzCore -framework ImageIO)
if [ -n "$variant" ]; then
    xcrun clang++ "${MMFLAGS[@]}" -c "$variant" -o "$variantOut.o"
    xcrun clang++ -o "$variantOut" "$OUT/obj/parity.o" "${objs[@]}" "$variantOut.o" "${FRAMEWORKS[@]}"
    echo "built $variantOut"
    exit 0
fi
xcrun clang++ -o "$OUT/parity" "$OUT/obj/parity.o" "${objs[@]}" "${mmobjs[@]}" "${FRAMEWORKS[@]}"
echo "built $OUT/parity"
