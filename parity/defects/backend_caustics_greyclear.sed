# Kill-check fixture: Metal backend defect (greyclear): the offscreen target cleared to dark grey, not black.
/rp.colorAttachments\[0\].texture = st->offscreenTarget;/,/clearColor/ s/MTLClearColorMake(0, 0, 0, 1)/MTLClearColorMake(0.05, 0.05, 0.05, 1)/
