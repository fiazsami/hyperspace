# Kill-check fixture: Metal backend defect (fogstart0): fog starts at the eye instead of the frame's fogStart.
s/u.fogStart = st->fogStart;/u.fogStart = 0.0f;/
