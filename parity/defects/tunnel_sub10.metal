// Kill-check fixture: tunnel shader with one deliberate defect (sub10). parity/backendcheck.sh requires it to FAIL.
// Metal translation of the tunnel GLSL program in Hyperspace/shaders.h. Compiled with Interface.metal prepended.

struct TunnelVaryings {
    float4 position [[position]];
    float4 vsPosition;   // eye-space position (varying vsPosition)
    float4 color;        // gl_FrontColor / gl_BackColor, clamped like the fixed-function path
    float4 texcoord0;    // gl_TexCoord[0]
};

vertex TunnelVaryings tunnel_vertex(uint vid [[vertex_id]],
                                    const device TunnelVertex *v [[buffer(0)]],
                                    constant TunnelUniforms &u [[buffer(1)]])
{
    TunnelVertex vert = v[vid];
    // gl_Vertex from glVertex3fv has w = 1; gl_MultiTexCoord0 from glTexCoord2fv has r = 0, q = 1.
    float4 glVertex = float4(float3(vert.position), 1.0);
    TunnelVaryings out;
    out.vsPosition = u.modelview * glVertex;
    // GL_CLAMP_VERTEX_COLOR defaults to TRUE: front/back colors are clamped to [0,1].
    out.color = saturate(vert.color);
    out.texcoord0 = float4(vert.texcoord, 0.0, 1.0);
    // ftransform() == gl_ModelViewProjectionMatrix * gl_Vertex.
    out.position = u.mvp * glVertex;
    return out;
}

fragment float4 tunnel_fragment(TunnelVaryings in [[stage_in]],
                                constant TunnelUniforms &u [[buffer(1)]],
                                texture2d<float> tex0 [[texture(0)]],
                                texture2d<float> tex1 [[texture(1)]],
                                sampler s0 [[sampler(0)]],
                                sampler s1 [[sampler(1)]])
{
    float2 tc = in.texcoord0.xy;
    float4 texcol0 = tex0.sample(s0, tc);
    texcol0 += 0.5 * tex0.sample(s0, tc * float2(3.0, 2.0));
    float4 texcol1 = tex1.sample(s1, tc);
    texcol1 += 0.5 * tex1.sample(s1, tc * float2(3.0, 2.0));
    float4 color = mix(texcol0, texcol1, in.color.a);
    color.rgb = 2.0 * mix(in.color.rgb * color.rgb,
                          max(float3(0.0), in.color.rgb + color.rgb - float3(1.0)),
                          0.5);
    // Depth cue: linear fog in eye space (eye z is negative in front of the camera).
    color = mix(u.fogColor, color, clamp((u.fogEnd + in.vsPosition.z) * u.fogScale, 0.0, 1.0));
    // GL clamps gl_FragColor to [0,1] for a fixed-point framebuffer before blending.
    return saturate(color);
}
