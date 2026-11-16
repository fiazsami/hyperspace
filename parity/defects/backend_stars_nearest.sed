# Kill-check fixture: Metal backend defect (nearest): textures sampled nearest instead of linear.
s/sd.minFilter = sd.magFilter = MTLSamplerMinMagFilterLinear;/sd.minFilter = sd.magFilter = MTLSamplerMinMagFilterNearest;/
