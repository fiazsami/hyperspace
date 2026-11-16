# Kill-check fixture: Metal backend defect (alphaone): the caustics' mix ignored, every vertex at alpha 1.
s/o.color\[3\] = st->tunnelAlpha;/o.color[3] = 1.0f;/
