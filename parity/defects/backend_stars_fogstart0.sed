# Kill-check fixture: Metal backend defect (fogstart0): the stars' fog starting at the eye instead of fogStart.
s/f.fogStart = st->fogStart;/f.fogStart = 0.0f;/
