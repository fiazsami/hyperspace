# Kill-check fixture: Metal backend defect (modelfirst): the quad's model matrix before the camera instead of after.
s/const simd_float4x4 modelview = simd_mul(st->view, fromGL(model));/const simd_float4x4 modelview = simd_mul(fromGL(model), st->view);/
