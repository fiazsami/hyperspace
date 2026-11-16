# Kill-check fixture: Metal backend defect (nocull): back faces drawn, where GL culls them.
s/\[st->encoder setCullMode:MTLCullModeBack\];/[st->encoder setCullMode:MTLCullModeNone];/
