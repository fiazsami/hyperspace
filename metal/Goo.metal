// Metal translation of the goo GLSL program in Hyperspace/shaders.h. Compiled with Interface.metal prepended.

struct GooVaryings {
    float4 position [[position]];
    float4 vsPosition;   // eye-space position (gl_ModelViewMatrix * gl_Vertex)
    float4 texCoord0;    // gl_TexCoord[0] = vec4(gl_Normal, 1.0)
    float4 color;        // gl_FrontColor
};

vertex GooVaryings goo_vertex(uint vid [[vertex_id]],
                              const device GooVertex *v [[buffer(0)]],
                              constant GooUniforms &u [[buffer(1)]])
{
    float4 glVertex = float4(float3(v[vid].position), 1.0);
    GooVaryings out;
    out.vsPosition = u.modelview * glVertex;
    // Fixed-function vertex colour clamping (GL_CLAMP_VERTEX_COLOR defaults to TRUE).
    out.color = saturate(u.color);
    out.texCoord0 = float4(float3(v[vid].normal), 1.0);
    out.position = u.mvp * glVertex; // ftransform()
    return out;
}

fragment float4 goo_fragment(GooVaryings in [[stage_in]],
                             constant GooUniforms &u [[buffer(1)]],
                             texturecube<float> normaltex0 [[texture(0)]],
                             texturecube<float> normaltex1 [[texture(1)]],
                             texturecube<float> tex [[texture(2)]],
                             sampler s0 [[sampler(0)]],
                             sampler s1 [[sampler(1)]],
                             sampler s2 [[sampler(2)]])
{
    float4 normal0 = normaltex0.sample(s0, in.texCoord0.xyz) * 2.0 - 1.0;
    float4 normal1 = normaltex1.sample(s1, in.texCoord0.xyz) * 2.0 - 1.0;
    float4 texnormal = mix(normal0, normal1, in.color.a);
    // Reflection vector
    float3 eyevec = normalize(in.vsPosition.xyz);
    float eyedotnorm = dot(eyevec, texnormal.xyz);
    float3 reflectvec = (texnormal.xyz * (eyedotnorm * 2.0)) - eyevec;
    // Reflected color
    float4 color = tex.sample(s2, reflectvec);
    // Fresnel reflection
    float fresnelalpha = 1.0 - abs(eyedotnorm);
    color *= fresnelalpha * fresnelalpha * fresnelalpha;
    // Overbrighten and modulate with vertex color using a mix of regular multiplicative and subtractive alpha
    color.rgb = 2.0 * mix(color.rgb * in.color.rgb, max(float3(0.0), color.rgb + in.color.rgb - float3(1.0)), 0.6);
    // Depth cue
    color = mix(u.fogColor, color, clamp((u.fogEnd + in.vsPosition.z) * u.fogScale, 0.0, 1.0));
    return color;
}
