# Kill-check fixture: Metal backend defect (modelfirst): the quad's model matrix before the camera instead of after.
s/u.modelview = simd_mul(st->view, fromGL(model));/u.modelview = simd_mul(fromGL(model), st->view);/
