// Types shared between the Metal passes and whatever feeds them.
//
// The feeder is HSRendererMetal (Hyperspace/rendererMetal.mm), whose C++ mirrors
// of these structs are held to this layout by static_asserts. A pass file is
// compiled with this file prepended, so it must not repeat these declarations.

#include <metal_stdlib>
using namespace metal;

// Immediate-mode vertex as issued by glColor*/glTexCoord*/glVertex*. Stars,
// sun, flare, the caustics' strips and the tunnel use it.
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

// GooBuild.metal: the goo's field, as HSGooField carries it.
struct GooBuildUniforms {
    float4 c;            // the four waves' amplitudes
    float2 cam;          // the eye's x and z, which the bubble surrounds
    float2 origin;       // x and z the vertices are placed relative to
    float  unitSize;     // a cell's edge
    float  halfVolume;   // half a block's edge: a block's cells start here
    float  surface;      // the field's value on the surface
    uint   resolution;   // cells along a block's edge
    uint   maxVertices;  // the vertex buffer's length; a cell past it is dropped
    uint   pad[3];
};

// Entry points each pass provides (buffer 0 = vertices, buffer 1 = uniforms):
//   FixedFunction.metal  ff_vertex / ff_fragment           texture(0), sampler(0)
//   Goo.metal            goo_vertex / goo_fragment         normaltex0..1, tex: texture(0..2)
//   Tunnel.metal         tunnel_vertex / tunnel_fragment   tex0, tex1: texture(0..1)
//   GooBuild.metal       goo_build, goo_build_count        compute: GooBuildUniforms, block offsets,
//                                                          triangle table, counter, GooVertex out
// Blending (SRC_ALPHA, ONE) and culling are pipeline state, set by the caller.
