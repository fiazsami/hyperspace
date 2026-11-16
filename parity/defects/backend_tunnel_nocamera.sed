# Kill-check fixture: Metal backend defect (nocamera): the tunnel projected without the camera, as if it were in eye space.
/^void HSRendererMetal::beginTunnel/,/^}/ s|u.mvp = simd_mul(st->clipProjection, st->view);|u.mvp = st->clipProjection;|
