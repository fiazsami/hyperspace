# Kill-check fixture: Metal backend defect (cullfront): front faces culled instead of back.
s/\[st->encoder setCullMode:MTLCullModeBack\];/[st->encoder setCullMode:MTLCullModeFront];/
