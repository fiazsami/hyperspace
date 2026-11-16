// Types shared between the Metal passes and whatever feeds them.
//
// Today the feeder is parity/parity.mm, which records each draw Hyperspace makes
// in OpenGL and replays it here; its C++ mirrors of these structs (FFU, GooU,
// TunnelU, Vtx) must keep the same layout. A pass file is compiled with this
// file prepended, so it must not repeat these declarations.

#include <metal_stdlib>
using namespace metal;

// Immediate-mode vertex as issued by glColor*/glTexCoord*/glVertex*. Stars,
// sun, flare and tunnel use it. The replay expands strips into a triangle list;
// HSRendererMetal draws them as strips. The layout is the same either way.
struct ImmediateVertex {
    packed_float3 position;
    float         pad0;
    float2        texcoord;
    float2        pad1;
    float4        color;
};
typedef ImmediateVertex FFVertex;
typedef ImmediateVertex TunnelVertex;

// GL fixed function as Hyperspace uses it: GL_MODULATE, optional texture,
// optional linear fog on eye-plane depth.
struct FFUniforms {
    float4x4 mvp;        // projection * modelview, remapped to Metal clip space
    float4x4 modelview;
    float4   fogColor;
    float    fogStart;
    float    fogEnd;
    int      fogOn;
    int      texOn;
};

// Goo: VBO interleaved normal-first, exactly as Implicit/impSurface.cpp builds it.
struct GooVertex { packed_float3 normal; packed_float3 position; };

struct GooUniforms {
    float4x4 mvp;        // projection * modelview, remapped to Metal clip space
    float4x4 modelview;  // gl_ModelViewMatrix
    float4   color;      // gl_Color (rgb = goo color, a = normal-map lerp)
    float4   fogColor;   // gl_Fog.color
    float    fogEnd;     // gl_Fog.end
    float    fogScale;   // gl_Fog.scale = 1 / (end - start)
    float4x4 projection; // gl_ProjectionMatrix, remapped to Metal clip space
};

struct TunnelUniforms {
    float4x4 mvp;        // projection * modelview, remapped to Metal clip space
    float4x4 modelview;  // gl_ModelViewMatrix
    float4x4 projection; // gl_ProjectionMatrix, remapped to Metal clip space
    float4   fogColor;   // gl_Fog.color
    float    fogEnd;     // gl_Fog.end
    float    fogScale;   // gl_Fog.scale = 1 / (end - start)
};

// Entry points each pass provides (buffer 0 = vertices, buffer 1 = uniforms):
//   FixedFunction.metal  ff_vertex / ff_fragment           texture(0), sampler(0)
//   Goo.metal            goo_vertex / goo_fragment         normaltex0..1, tex: texture(0..2)
//   Tunnel.metal         tunnel_vertex / tunnel_fragment   tex0, tex1: texture(0..1)
// Blending (SRC_ALPHA, ONE) and culling are pipeline state, set by the caller.
