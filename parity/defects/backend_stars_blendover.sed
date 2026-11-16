# Kill-check fixture: Metal backend defect (blendover): blended (SRC_ALPHA, ONE_MINUS_SRC_ALPHA) instead of additive.
s/destinationAlphaBlendFactor = MTLBlendFactorOne;/destinationAlphaBlendFactor = MTLBlendFactorOneMinusSourceAlpha;/
