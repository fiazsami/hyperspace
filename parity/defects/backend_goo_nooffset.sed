# Kill-check fixture: Metal backend defect (nooffset): the goo built on the GPU drawn at the origin, the field's origin ignored.
s/model.columns\[3\] = simd_make_float4(field.origin\[0\], 0.0f, field.origin\[1\], 1.0f);/model.columns[3] = simd_make_float4(0.0f, 0.0f, 0.0f, 1.0f);/
