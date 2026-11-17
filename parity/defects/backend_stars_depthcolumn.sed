# Kill-check fixture: Metal backend defect (depthcolumn): the quad's fog depth from the modelview's third column instead of its z row.
s/q.modelviewZ = simd_make_float4(modelview.columns\[0\].z, modelview.columns\[1\].z,/q.modelviewZ = modelview.columns[2]; (void)simd_make_float4(modelview.columns[0].z, modelview.columns[1].z,/
