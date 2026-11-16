# Kill-check fixture: Metal backend defect (fogscale): the tunnel's fog scale taken as 1 / end instead of 1 / (end - start).
/^void HSRendererMetal::beginTunnel/,/^}/ s|u.fogScale = 1.0f / (st->fogEnd - st->fogStart);|u.fogScale = 1.0f / st->fogEnd;|
