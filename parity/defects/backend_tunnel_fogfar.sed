# Kill-check fixture: Metal backend defect (fogfar): the tunnel's fog ending twice as far.
/^void HSRendererMetal::beginTunnel/,/^}/ s/u.fogEnd = st->fogEnd;$/u.fogEnd = 2.0f * st->fogEnd;/
