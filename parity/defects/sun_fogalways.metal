// Kill-check fixture: sun shader (the stars pass's) with one deliberate defect (fogalways): fog on every draw, the sun's included. Only the sun pass can see it. parity/backendcheck.sh requires it to FAIL. base=6536483048df0cf1081a43e2cbbdb0f83f954ece
// The GL fixed-function path Hyperspace uses for stars, sun and lens flare:
// vertex color MODULATE texture, then linear fog on eye-plane depth (Apple's GL
// fogs on |z_eye|, not radial distance -- measured, see parity/README.md).

struct FFOut { float4 position [[position]]; float2 texcoord; float4 color; float depth; };

vertex FFOut ff_vertex(uint vid [[vertex_id]], const device FFVertex *v [[buffer(0)]], constant FFUniforms &u [[buffer(1)]])
{
    float4 p = float4(float3(v[vid].position), 1.0);
    FFOut o;
    o.position = u.mvp * p;
    o.texcoord = v[vid].texcoord;
    o.color = saturate(v[vid].color);   // GL_CLAMP_VERTEX_COLOR defaults to TRUE
    o.depth = abs((u.modelview * p).z);
    return o;
}

// drawQuad's quads, instanced: instance i is the i-th queued quad, and vertex
// v its corner (v & 1, v >> 1) -- hsQuad's order (Hyperspace/renderer.cpp,
// which GL and the tests draw), drawn as a strip of 4.
vertex FFOut ff_quad_vertex(uint vid [[vertex_id]], uint iid [[instance_id]],
                            const device QuadInstance *q [[buffer(0)]])
{
    const float u = float(vid & 1), v = float(vid >> 1);
    const float4 p = float4((2.0 * u - 1.0) * q[iid].halfSize, (2.0 * v - 1.0) * q[iid].halfSize, 0.0, 1.0);
    FFOut o;
    o.position = q[iid].mvp * p;
    o.texcoord = float2(u, v);
    o.color = saturate(q[iid].color);   // GL_CLAMP_VERTEX_COLOR defaults to TRUE
    o.depth = abs(dot(q[iid].modelviewZ, p));
    return o;
}

fragment float4 ff_fragment(FFOut in [[stage_in]], constant FFUniforms &u [[buffer(1)]],
                            texture2d<float> tex [[texture(0)]], sampler s [[sampler(0)]])
{
    float4 c = in.color;
    if (u.texOn)
        c *= tex.sample(s, in.texcoord);
    if (true) {
        float f = clamp((u.fogEnd - in.depth) / (u.fogEnd - u.fogStart), 0.0, 1.0);
        c.rgb = mix(u.fogColor.rgb, c.rgb, f);
    }
    return c;
}
