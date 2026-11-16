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
INC=(-I. -IHyperspace -IrsMath -IImplicit -IrsText -Iutil -include Hyperspace_Prefix.pch -DGL_SILENCE_DEPRECATION)

# A header, the prefix or this script changing invalidates every object: the GLSL
# under comparison lives in Hyperspace/shaders.h, and a stale object would compare
# against a renderer that no longer exists.
newest=parity/build.sh
for f in Hyperspace_Prefix.pch *.h *.hh Hyperspace/*.h rsMath/*.h Implicit/*.h rsText/*.h Rgbhsl/*.h util/*.h; do
    if [ -e "$f" ] && [ "$f" -nt "$newest" ]; then newest=$f; fi
done
objs=()
for src in Hyperspace/*.cpp rsMath/*.cpp Implicit/*.cpp rsText/*.cpp Rgbhsl/*.cpp; do
    obj="$OUT/obj/$(echo "$src" | tr / _).o"
    # Hyperspace's own sources are compiled as they are, warnings and all.
    if [ ! -e "$obj" ] || [ "$src" -nt "$obj" ] || [ "$newest" -nt "$obj" ]; then
        xcrun clang++ -std=c++17 -O2 -w "${INC[@]}" -c "$src" -o "$obj"
    fi
    objs+=("$obj")
done
# The Metal backend, which renderer=metal draws through.
MMFLAGS=(-std=c++17 -O2 -ObjC++ -fobjc-arc -Wall "${INC[@]}")
mmobjs=()
for src in Hyperspace/*.mm; do
    obj="$OUT/obj/$(echo "$src" | tr / _).o"
    if [ ! -e "$obj" ] || [ "$src" -nt "$obj" ] || [ "$newest" -nt "$obj" ]; then
        xcrun clang++ "${MMFLAGS[@]}" -c "$src" -o "$obj"
    fi
    mmobjs+=("$obj")
done

# Rebuilt only when stale: backendcheck.sh calls this once per fixture.
if [ ! -e "$OUT/obj/parity.o" ] || [ parity/parity.mm -nt "$OUT/obj/parity.o" ] || [ "$newest" -nt "$OUT/obj/parity.o" ]; then
    xcrun clang++ -std=c++17 -O2 -ObjC++ -fobjc-arc -Wall -Wno-deprecated-declarations -Wno-missing-declarations "${INC[@]}" \
        -c parity/parity.mm -o "$OUT/obj/parity.o"
fi
FRAMEWORKS=(-framework Cocoa -framework OpenGL -framework Metal -framework ImageIO)
if [ -n "$variant" ]; then
    xcrun clang++ "${MMFLAGS[@]}" -c "$variant" -o "$variantOut.o"
    xcrun clang++ -o "$variantOut" "$OUT/obj/parity.o" "${objs[@]}" "$variantOut.o" "${FRAMEWORKS[@]}"
    echo "built $variantOut"
    exit 0
fi
xcrun clang++ -o "$OUT/parity" "$OUT/obj/parity.o" "${objs[@]}" "${mmobjs[@]}" "${FRAMEWORKS[@]}"
echo "built $OUT/parity"
