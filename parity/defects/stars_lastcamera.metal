// Kill-check fixture: stars shader with one deliberate defect (lastcamera). parity/backendcheck.sh requires it to FAIL. base=cb2c01ad9656e3db77ba286e7229fc47addfa56b
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

// A quad's corner, drawQuad's or a star's: its clip position, its eye-space z,
// which fog reads, and its texcoord and color.
static FFOut quadCorner(float4 position, float eyeZ, float2 texcoord, float4 color)
{
    FFOut o;
    o.position = position;
    o.texcoord = texcoord;
    o.color = saturate(color);   // GL_CLAMP_VERTEX_COLOR defaults to TRUE
    o.depth = abs(eyeZ);
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
    return quadCorner(q[iid].mvp * p, dot(q[iid].modelviewZ, p), float2(u, v), q[iid].color);
}

// Where hsProject puts a point rel from the eye, in a viewport of size
// viewport; false where it does not (w = 0) or the point is past the near
// plane's far side (window z <= 0), as stretchedParticle::draw tests.
static bool project(float4x4 projView, float3 rel, float2 viewport, thread float2 &win)
{
    const float4 clip = projView * float4(rel, 1.0);
    if (clip.w == 0.0 || clip.z / clip.w * 0.5 + 0.5 <= 0.0)
        return false;
    win = (clip.xy / clip.w * 0.5 + 0.5) * viewport;
    return true;
}

// draw()'s wrap of a star rel from the eye: into [-depth, depth] in x and z.
static float3 wrapStar(float3 rel, float depth)
{
    const float span = 2.0 * depth;
    rel.x -= span * floor((rel.x + depth) / span);
    rel.z -= span * floor((rel.z + depth) / span);
    return rel;
}

// The stars (HSRendererMetal::drawStarField): instance 2s is star s's aura and
// 2s + 1 its white core, the order stretchedParticle::draw draws them in;
// vertex v is the corner (v & 1, v >> 1), as ff_quad_vertex's. Each star is
// wrapped round the eye, then billboarded, stretched and rolled as
// stretchedParticle::draw does. Its motion on screen is its position this
// frame less last frame's, each wrapped round its own frame's eye: so a star
// that wrapped since is stretched along its jump for a frame, as on the CPU,
// where its last screen position is from before the jump. A star that did
// not project in either frame is not stretched.
vertex FFOut star_vertex(uint vid [[vertex_id]], uint iid [[instance_id]],
                         const device float *stars [[buffer(0)]],
                         constant StarUniforms &u [[buffer(1)]])
{
    const device float *star = stars + 7 * (iid / 2);   // HS_STAR_FLOATS, asserted in rendererMetal.mm
    const float radius = star[3];
    const float3 fromEye = float3(star[0], star[1], star[2]) - u.eye.xyz;
    const float3 rel = wrapStar(fromEye, u.eye.w);

    float2 win, lastWin, motion = float2(0.0);
    if (u.lastEye.w > 0.0 && project(u.projView, rel, u.viewport, win)
        && project(u.projView, wrapStar(fromEye + u.lastEye.xyz, u.eye.w), u.lastViewport, lastWin))
        motion = win - lastWin;

    // The billboard: z toward the eye, x = (0,1,0) x z, y = z x x.
    const float n = length(rel);
    const float3 zAxis = -rel / n;
    const float3 xAxis = float3(zAxis.z, 0.0, -zAxis.x);
    const float3 yAxis = float3(zAxis.y * xAxis.z - zAxis.z * xAxis.y,
                                zAxis.z * xAxis.x - zAxis.x * xAxis.z,
                                zAxis.x * xAxis.y - zAxis.y * xAxis.x);
    const float stretch = min(max(0.0015 * length(motion) * n / radius, 1.0), 0.5 / radius);
    const float angle = (motion.x == 0.0 && motion.y == 0.0 ? 0.0 : atan2(motion.y, motion.x))
                        + u.unroll * 0.0174532925199;
    const float darkener = max(stretch * 0.3, 1.0);
    const bool core = iid & 1;
    const float halfSize = core ? radius * 0.3 : radius;
    const float4 color = core ? float4(float3(1.0 / darkener), 1.0)
                              : float4(float3(star[4], star[5], star[6]) / darkener, 1.0);

    const float tu = float(vid & 1), tv = float(vid >> 1);
    const float2 corner = float2((2.0 * tu - 1.0) * halfSize * stretch, (2.0 * tv - 1.0) * halfSize);
    const float c = cos(angle), s = sin(angle);
    const float3 at = rel + (c * corner.x - s * corner.y) * xAxis + (s * corner.x + c * corner.y) * yAxis;
    const float4 eyeSpace = u.view * float4(at, 1.0);
    return quadCorner(u.clipProjection * eyeSpace, eyeSpace.z, float2(tu, tv), color);
}

fragment float4 ff_fragment(FFOut in [[stage_in]], constant FFUniforms &u [[buffer(1)]],
                            texture2d<float> tex [[texture(0)]], sampler s [[sampler(0)]])
{
    float4 c = in.color;
    if (u.texOn)
        c *= tex.sample(s, in.texcoord);
    if (u.fogOn) {
        float f = clamp((u.fogEnd - in.depth) / (u.fogEnd - u.fogStart), 0.0, 1.0);
        c.rgb = mix(u.fogColor.rgb, c.rgb, f);
    }
    return c;
}
