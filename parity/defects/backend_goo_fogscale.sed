# Kill-check fixture: Metal backend defect (fogscale): the goo's fog scale taken as 1 / end instead of 1 / (end - start).
/^static void bindGoo/,/^}/ s|u.fogScale = 1.0f / (st->fogEnd - st->fogStart);|u.fogScale = 1.0f / st->fogEnd;|
