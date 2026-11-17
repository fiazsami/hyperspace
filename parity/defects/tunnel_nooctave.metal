// Kill-check fixture: tunnel shader with one deliberate defect (nooctave). parity/backendcheck.sh requires it to FAIL. base=b6948b1ccceb7fa5c990ea3cebe197fb5aaa5ee3
// Metal translation of the tunnel GLSL program in Hyperspace/shaders.h. Compiled with Interface.metal prepended.

struct TunnelVaryings {
    float4 position [[position]];
    float4 vsPosition;   // eye-space position (varying vsPosition)
    float4 color;        // gl_FrontColor / gl_BackColor, clamped like the fixed-function path
    float4 texcoord0;    // gl_TexCoord[0]
};

// What tunnel_build_vertex outputs for a vertex at pos (world space).
static TunnelVaryings tunnelVaryings(float3 pos, float2 texcoord, float4 color, constant TunnelUniforms &u)
{
    // gl_Vertex from glVertex3fv has w = 1; gl_MultiTexCoord0 from glTexCoord2fv has r = 0, q = 1.
    float4 glVertex = float4(pos, 1.0);
    TunnelVaryings out;
    out.vsPosition = u.modelview * glVertex;
    // GL_CLAMP_VERTEX_COLOR defaults to TRUE: front/back colors are clamped to [0,1].
    out.color = saturate(color);
    out.texcoord0 = float4(texcoord, 0.0, 1.0);
    // ftransform() == gl_ModelViewProjectionMatrix * gl_Vertex.
    out.position = u.mvp * glVertex;
    return out;
}

// splinePath::interpolate.
static float3 spline(constant float4 *p, uint first, float where)
{
    const float3 a = p[first].xyz, b = p[first + 1].xyz, c = p[first + 2].xyz, d = p[first + 3].xyz;
    const float3 q = ((3.0 * b + d - a - 3.0 * c) * (where * where * where)) * 0.5;
    const float3 r = ((2.0 * a - 5.0 * b + 4.0 * c - d) * (where * where)) * 0.5;
    const float3 s = ((c - a) * where) * 0.5;
    return q + r + s + b;
}

// Rgbhsl's hsl2rgb, h already in [0, 1).
static float3 hsl2rgb(float h, float s, float l)
{
    float3 rgb;
    if(h < 0.166667)
        rgb = float3(1.0, h * 6.0, 0.0);
    else if(h < 0.5)
        rgb = h < 0.333333 ? float3(1.0 - (h - 0.166667) * 6.0, 1.0, 0.0)
                           : float3(0.0, 1.0, (h - 0.333333) * 6.0);
    else if(h < 0.833333)
        rgb = h < 0.666667 ? float3(0.0, 1.0 - (h - 0.5) * 6.0, 1.0)
                           : float3((h - 0.666667) * 6.0, 0.0, 1.0);
    else
        rgb = float3(1.0, 0.0, 1.0 - (h - 0.833333) * 6.0);
    return (1.0 - s * (1.0 - rgb)) * l;
}

// The tunnel built from the path, as tunnel::make builds it on the CPU and
// tunnel::draw strips it: instance k * resolution + i is section k's strip
// between rings i and i + 1, the next ring first; vertex 2j + side is the
// j-th point round ring i + 1 - side. Its trig is true cos and sin (ss-ss8.2),
// where the CPU's is rsCosf and rsSinf, 256-entry tables indexed by the bits
// of value * 65536/2pi + 1.5 * 2^23: past a few hundred the float holding that
// sum loses the fraction, then the index, and the colour waves -- 4(x+y+z)
// gets there within some 100 units of travel -- turn to steps. So this tunnel
// departs from GL's on purpose, most deep in a run; parity/gl-retired.
vertex TunnelVaryings tunnel_build_vertex(uint vid [[vertex_id]],
                                          uint iid [[instance_id]],
                                          constant TunnelShape &shape [[buffer(0)]],
                                          constant TunnelUniforms &u [[buffer(1)]],
                                          constant float4 *path [[buffer(2)]])
{
    const uint res = shape.resolution;
    const uint k = iid / res, ring = iid % res + 1 - vid % 2, j = vid / 2;
    const float where = float(ring) / float(res);
    // getPoint(k + 2, where) and getDirection(k + 2, where): points k + 1 to k + 4.
    const float3 pos = spline(path, k + 1, where);
    float3 dir = spline(path + shape.numPoints, k + 1, where);
    dir *= 1.0 / sqrt(dot(dir, dir));
    // The ring's frame: z along the path, x = (0,1,0) x z, y = z x x.
    const float3 zAxis = -dir;
    const float3 xAxis = float3(zAxis.z, 0.0, -zAxis.x);
    const float3 yAxis = float3(zAxis.y * xAxis.z - zAxis.z * xAxis.y,
                                zAxis.z * xAxis.x - zAxis.x * xAxis.z,
                                zAxis.x * xAxis.y - zAxis.y * xAxis.x);
    const float angle = float(j) * 6.28318530718 / float(res);
    const float x = (shape.radius + shape.radius * 0.5 * cos(2.0 * pos.x + shape.widthOffset)) * cos(angle);
    const float y = (shape.radius + shape.radius * 0.5 * cos(pos.z + shape.widthOffset)) * sin(angle);
    const float3 v = pos + x * xAxis + y * yAxis;
    const float2 texcoord = float2(shape.texcoordMult * float(ring) / float(res),
                                   shape.texcoordMult * float(j) / float(res) + shape.texShift);
    const float h = fract(2.0 * cos(0.1 * v.x + shape.huelo) - 1.0);
    const float s = clamp(0.25 * (cos(0.013 * v.y - shape.satlo) + cos(v.z + shape.sathi) + 2.0),
                          0.0, shape.maxSaturation);
    const float l = saturate(2.0 * cos(0.01 * v.z + shape.lumlo) + cos(0.4 * v.x - shape.lumhi)
                             + 0.3 * cos(4.0 * (v.x + v.y + v.z)));
    return tunnelVaryings(v, texcoord, float4(hsl2rgb(h, s, l), shape.alpha), u);
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
    float4 texcol1 = tex1.sample(s1, tc);
    texcol1 += 0.5 * tex1.sample(s1, tc * float2(3.0, 2.0));
    float4 color = mix(texcol0, texcol1, in.color.a);
    color.rgb = 2.0 * mix(in.color.rgb * color.rgb,
                          max(float3(0.0), in.color.rgb * float3(1.5) + color.rgb - float3(1.5)),
                          0.5);
    // Depth cue: linear fog in eye space (eye z is negative in front of the camera).
    color = mix(u.fogColor, color, clamp((u.fogEnd + in.vsPosition.z) * u.fogScale, 0.0, 1.0));
    // GL clamps gl_FragColor to [0,1] for a fixed-point framebuffer before blending.
    return saturate(color);
}
