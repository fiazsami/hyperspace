# Kill-check fixture: Metal backend defect (nooffset): every goo surface drawn at the origin, its offset ignored.
s/model.columns\[3\] = simd_make_float4(offset\[0\], offset\[1\], offset\[2\], 1.0f);/model.columns[3] = simd_make_float4(0.0f, 0.0f, 0.0f, 1.0f);/
