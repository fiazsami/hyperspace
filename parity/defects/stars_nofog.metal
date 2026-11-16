// Kill-check fixture: stars shader with one deliberate defect (nofog). parity/backendcheck.sh requires it to FAIL.
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

fragment float4 ff_fragment(FFOut in [[stage_in]], constant FFUniforms &u [[buffer(1)]],
                            texture2d<float> tex [[texture(0)]], sampler s [[sampler(0)]])
{
    float4 c = in.color;
    if (u.texOn)
        c *= tex.sample(s, in.texcoord);
    if (false) {
        float f = clamp((u.fogEnd - in.depth) / (u.fogEnd - u.fogStart), 0.0, 1.0);
        c.rgb = mix(u.fogColor.rgb, c.rgb, f);
    }
    return c;
}
