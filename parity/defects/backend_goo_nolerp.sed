# Kill-check fixture: Metal backend defect (nolerp): the goo color's alpha, which mixes the two normal maps, dropped to 0.
s/st->gooColor = simd_make_float4(color\[0\], color\[1\], color\[2\], color\[3\]);/st->gooColor = simd_make_float4(color[0], color[1], color[2], 0.0f);/
