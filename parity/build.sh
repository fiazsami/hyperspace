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

# An object is rebuilt when its source, any header, the prefix or this script
# changes -- by content, not by time. Modification times compare at one-second
# resolution here, so a file restored in the same second as a build looked
# unchanged and a stale object survived (ss-a4a.4.9). Each object keeps the hash
# it was built from beside it, in <obj>.key, written only after it compiles.
headers=$(for f in parity/build.sh Hyperspace_Prefix.pch *.h *.hh Hyperspace/*.h rsMath/*.h Implicit/*.h Rgbhsl/*.h util/*.h; do
    [ -e "$f" ] && printf '%s\n' "$f" && cat "$f"
done | shasum | cut -d' ' -f1)
key() { { echo "$headers"; cat "$1"; } | shasum | cut -d' ' -f1; }
stale() { [ ! -e "$1" ] || [ "$(cat "$1.key" 2>/dev/null)" != "$2" ]; }
objs=()
for src in Hyperspace/*.cpp rsMath/*.cpp Implicit/*.cpp Rgbhsl/*.cpp; do
    obj="$OUT/obj/$(echo "$src" | tr / _).o"; k=$(key "$src")
    # Hyperspace's own sources are compiled as they are, warnings and all.
    if stale "$obj" "$k"; then
        xcrun clang++ -std=c++17 -O2 -w "${INC[@]}" -c "$src" -o "$obj"
        echo "$k" > "$obj.key"
    fi
    objs+=("$obj")
done
# The Metal backend, which renderer=metal draws through.
MMFLAGS=(-std=c++17 -O2 -ObjC++ -fobjc-arc -Wall "${INC[@]}")
mmobjs=()
for src in Hyperspace/*.mm; do
    obj="$OUT/obj/$(echo "$src" | tr / _).o"; k=$(key "$src")
    if stale "$obj" "$k"; then
        xcrun clang++ "${MMFLAGS[@]}" -c "$src" -o "$obj"
        echo "$k" > "$obj.key"
    fi
    mmobjs+=("$obj")
done

# Rebuilt only when stale: backendcheck.sh calls this once per fixture.
k=$(key parity/parity.mm)
if stale "$OUT/obj/parity.o" "$k"; then
    xcrun clang++ -std=c++17 -O2 -ObjC++ -fobjc-arc -Wall -Wno-deprecated-declarations -Wno-missing-declarations "${INC[@]}" \
        -c parity/parity.mm -o "$OUT/obj/parity.o"
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
