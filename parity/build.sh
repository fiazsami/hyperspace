#!/bin/bash
# Builds parity/parity.mm against Hyperspace's unmodified sources into
# .parity-build/parity. Drives xcrun clang directly, like the tests workflow; the
# Xcode project is not involved.
set -euo pipefail
cd "$(dirname "$0")/.."

OUT=.parity-build
mkdir -p "$OUT/obj"
INC=(-I. -IHyperspace -IrsMath -IImplicit -IrsText -Iutil -include Hyperspace_Prefix.pch -DGL_SILENCE_DEPRECATION)

# A header, the prefix or this script changing invalidates every object: the GLSL
# under comparison lives in Hyperspace/shaders.h, and a stale object would compare
# against a renderer that no longer exists.
newest=parity/build.sh
for f in Hyperspace_Prefix.pch Hyperspace/*.h rsMath/*.h Implicit/*.h rsText/*.h Rgbhsl/*.h util/*.h; do
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

xcrun clang++ -std=c++17 -O2 -ObjC++ -fobjc-arc -Wall -Wno-deprecated-declarations -Wno-missing-declarations "${INC[@]}" \
    -c parity/parity.mm -o "$OUT/obj/parity.o"
xcrun clang++ -o "$OUT/parity" "$OUT/obj/parity.o" "${objs[@]}" \
    -framework Cocoa -framework OpenGL -framework Metal -framework ImageIO
echo "built $OUT/parity"
