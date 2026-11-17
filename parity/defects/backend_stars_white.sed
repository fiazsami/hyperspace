# Kill-check fixture: Metal backend defect (white): the quad's color ignored, drawn white.
s/q.color = simd_make_float4(color\[0\], color\[1\], color\[2\], color\[3\]);/q.color = simd_make_float4(1.0f, 1.0f, 1.0f, 1.0f);/
