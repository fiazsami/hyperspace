// Kill-check fixture: soften shader with one deliberate defect (shift2): every tap one low-resolution texel to the right, so the goo lands two pixels left of where it belongs. parity/backendcheck.sh requires it to FAIL. base=49b802d0d950e840acea404883c9deda1bfbc524
// The goo's softening, for HSRendererMetal::setSoftGoo: the goo is drawn into a
// target half the frame's width and height, and this adds it back over the
// frame, blurred and upsampled in one step. Compiled with Interface.metal
// prepended.

struct SoftenVaryings {
    float4 position [[position]];
    float2 uv;
};

// One triangle that covers the viewport: vertices 0..2 at (-1,-1), (3,-1),
// (-1,3) in clip space, uv 0..1 across the visible part, top row first.
vertex SoftenVaryings soften_vertex(uint vid [[vertex_id]])
{
    const float2 p = float2(vid == 1 ? 3.0f : -1.0f, vid == 2 ? 3.0f : -1.0f);
    SoftenVaryings out;
    out.position = float4(p, 0.0f, 1.0f);
    out.uv = float2(0.5f * p.x + 0.5f, 0.5f - 0.5f * p.y);
    return out;
}

// A 3x3 tent of bilinear taps one low-resolution texel apart, weights
// (1 2 1) x (1 2 1) / 16: they sum to 1, so the goo keeps its brightness and
// only spreads. Blended (ONE, ONE): the goo target holds what the goo's own
// (SRC_ALPHA, ONE) blending added to black. Alpha 0: the pass adds colour only.
fragment float4 soften_fragment(SoftenVaryings in [[stage_in]],
                                texture2d<float> goo [[texture(0)]])
{
    constexpr sampler s(filter::linear, address::clamp_to_edge);
    const float2 texel = 1.0f / float2(goo.get_width(), goo.get_height());
    float3 sum = 0.0f;
    for (int y = -1; y <= 1; y++)
        for (int x = -1; x <= 1; x++)
            sum += goo.sample(s, in.uv + float2(x + 1, y) * texel).rgb * float((2 - abs(x)) * (2 - abs(y)));
    return float4(sum / 16.0f, 0.0f);
}
