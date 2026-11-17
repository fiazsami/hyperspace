/*
 * This file is part of Hyperspace.
 *
 * Hyperspace is free software; you can redistribute it and/or modify
 * it under the terms of the GNU General Public License version 2 as
 * published by the Free Software Foundation.
 *
 * Hyperspace is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
 * GNU General Public License for more details.
 */

// Where Hyperspace's drawing meets a graphics API. Code that draws through this
// interface computes its own geometry and never calls GL, so it can be tested
// without a context. HSRendererMetal (rendererMetal.h) is the saver's backend;
// HSRendererGL draws exactly what the GL code it replaced drew, and is the
// reference parity/ judges the Metal backend against.
//
// Every draw Hyperspace makes goes through here -- the stars, the lens flare,
// the goo, the starburst, the tunnel -- and every texture is created here,
// including the caustics, which are rendered offscreen and read back. Each
// frame starts with beginFrame, which sets the camera and fog that every
// world-space draw in it is seen through.

#ifndef HYPERSPACE_RENDERER_H
#define HYPERSPACE_RENDERER_H

#include <vector>

struct HSVertex{
	float pos[3];
	float uv[2];
};

struct HSColorVertex{
	float pos[3];
	float color[3];
};

struct HSTunnelVertex{
	float pos[3];
	float uv[2];
	float color[3];
};

class impSurface;

// The goo as its field, for a backend that builds the surface itself
// (HSRenderer::buildsGoo). The surface is where goo::function equals surface,
// built in blocks of resolution^3 cells unitSize wide, each block spanning
// volumeSize in x, y and z and centred on (offset x, 0, offset z) -- the
// blocks goo::update chose, in its order. Vertices are placed relative to
// origin and drawn moved back by it, as drawGooSurface's offset does, so that
// positions stay small however far the camera has travelled.
struct HSGooField{
	float c[4];             // goo::c: the four waves' amplitudes this frame
	float camx, camz;       // the eye, which goo::function's bubble surrounds
	float origin[2];        // x and z the vertices are placed relative to
	float unitSize;         // a cell's edge
	float volumeSize;       // a block's edge
	float surface;          // the value of goo::function on the surface
	int resolution;         // cells along a block's edge
	std::vector<float> offsets;   // each block's centre, x then z
};

// What a frame is seen through: the viewport, the camera's projection and view
// (column-major, as GL takes them), and black linear fog from fogStart to
// fogEnd units from the eye.
struct HSFrame{
	int viewport[4];
	float projection[16];
	float view[16];
	float fogStart, fogEnd;
};

// A square, power-of-two image and every mip level down to 1x1, tightly
// packed bytes, channels per pixel. levels[0] is the image itself.
struct HSMipChain{
	int size;
	int channels;
	std::vector<std::vector<unsigned char> > levels;
	HSMipChain() : size(0), channels(0) {}   // empty: a backend uploads nothing
};

class HSRenderer{
public:
	virtual ~HSRenderer(){}

	// Clear to black and start drawing a frame through frame. Fog is on.
	// endFrame finishes it: a backend that queues its draws submits them there.
	virtual void beginFrame(const HSFrame &frame) = 0;
	virtual void endFrame() = 0;

	// Fog for world-space draws until the next setFog or beginFrame. The sun
	// and its lens flare draw with it off.
	virtual void setFog(bool on) = 0;

	// An RGBA8 texture, linear min and mag filtering, no mipmaps.
	virtual unsigned int createTexture(int width, int height, const unsigned char *rgba) = 0;

	// A texture from a full mip chain: trilinear filtering, repeating.
	virtual unsigned int createMipmappedTexture(const HSMipChain &chain) = 0;

	// A cube map from six full mip chains, ordered -x +x -y +y -z +z:
	// trilinear filtering, clamped to the edge.
	virtual unsigned int createCubeTexture(const HSMipChain faces[6]) = 0;

	// Render into a size x size RGB target and read it back. beginOffscreen
	// clears to black; strips drawn until endOffscreen are untextured,
	// per-vertex colored, blended (SRC_ALPHA, ONE), with x and y running 0..1
	// across the target, unfogged. endOffscreen writes size * size * 3 bytes,
	// bottom row first, and restores the viewport, the camera and the fog
	// setting. Other pipeline state is the backend's to leave: callers set
	// what they draw with next.
	virtual void beginOffscreen(int size) = 0;
	virtual void drawColorStrip(const HSColorVertex *v, int count) = 0;
	virtual void endOffscreen(unsigned char *rgb) = 0;

	// The square hsQuad(model, half) describes, textured, its texture
	// modulated by color, blended (SRC_ALPHA, ONE) over what is already drawn,
	// from either side: quads are not culled.
	// model places it in world space, seen through the camera and fogged
	// linearly with eye distance unless setFog(false) -- or, between
	// beginOverlay and endOverlay, in the overlay plane, never fogged.
	//
	// The quad takes its model matrix rather than finished corners so that a
	// backend can apply it after the camera's translation, as GL's matrix
	// stack did. Corners rounded in world space lose precision far from the
	// origin, where a star's core is only a few float steps wide.
	virtual void drawQuad(unsigned int texture, const float color[4], const float model[16], float half) = 0;

	// The lens-flare plane: x runs 0..aspect left to right, y 0..1 bottom to
	// top, with no camera and no fog.
	virtual void beginOverlay(float aspect) = 0;
	virtual void endOverlay() = 0;

	// Both the goo and the tunnel have two looks, chosen by shaded: the GLSL
	// programs (metal/Goo.metal and metal/Tunnel.metal are their translations)
	// or GL's fixed function, which is what a user who turns shaders off gets.
	// Both are seen through the camera, fogged, and blended (SRC_ALPHA, ONE).
	//
	// The goo, and the starburst's sphere, which is drawn in the goo's look:
	// each surface or sphere drawn between beginGoo and endGoo, colored by
	// color. A surface's vertices are moved by offset; the sphere is the one
	// hsSphereBand describes, scaled by radius and centred on center. Shaded, it reflects the nebula cube
	// map through normals perturbed by the two wavy normal cube maps, mixed by
	// color[3]. Not shaded, nebula is a 2D texture sphere-mapped onto it.
	// The surface is not const because a backend may cache it for the GPU.
	virtual void beginGoo(const float color[4], unsigned int nebula,
		unsigned int normals0, unsigned int normals1, bool shaded) = 0;
	virtual void drawGooSurface(impSurface *surface, const float offset[3]) = 0;
	// A backend that builds the goo's surface from its field answers true.
	// goo::draw then passes it the field, once a frame between beginGoo and
	// endGoo, and builds no surfaces on the CPU -- most of a frame's CPU time.
	// For a backend that does not, goo::draw builds each surface and draws it
	// with drawGooSurface.
	// The defaults are a backend that does not: drawGooField is never called.
	virtual bool buildsGoo() const { return false; }
	virtual void drawGooField(const HSGooField &field) { (void)field; }
	virtual void drawGooSphere(const float center[3], float radius) = 0;
	virtual void endGoo() = 0;

	// The tunnel: triangle strips with back faces culled, each vertex's color
	// modulating the caustic texture. Shaded, textures caustic0 and caustic1
	// are mixed by lerp; not shaded, caustic0 alone, and lerp is unused.
	virtual void beginTunnel(unsigned int caustic0, unsigned int caustic1, float lerp, bool shaded) = 0;
	virtual void drawTunnelStrip(const HSTunnelVertex *v, int count) = 0;
	virtual void endTunnel() = 0;
};

// The unit-textured square of side 2 * half centred on the origin, through m,
// in strip order: (-,-) (+,-) (-,+) (+,+), texcoords (0,0) (1,0) (0,1) (1,1).
// It is what drawQuad draws.
void hsQuad(const float m[16], float half, HSVertex out[4]);

// gluBuild2DMipmaps' chain, built on the CPU: each level halves the last,
// every texel the rounded mean of the 2x2 block above it, (a+b+c+d+2)/4.
// That matches Apple's GLU byte for byte on power-of-two images. False, and
// out untouched, when size is not a power of two (GLU would rescale those;
// nothing here does, so texture sizes must be powers of two) or channels is
// not 1 to 4.
bool hsBuildMipmaps(const unsigned char *pixels, int size, int channels, HSMipChain &out);

// Each of impCubeVolume's 256 corner configurations as triangles, for a
// backend that builds the goo (HSRenderer::buildsGoo): row mask holds the
// triangle count, then three edge indices per triangle (impCubeTables'
// numbering), in the order and winding impCubeVolume::polygonize emits them.
// Five triangles at most, so 16 entries a row.
const int HS_GOO_TABLE_ROW = 16;
void hsGooTriangleTable(short out[256][HS_GOO_TABLE_ROW]);

// The unit sphere drawGooSphere draws, as HS_SPHERE_BANDS triangle strips:
// band b's 66 points in strip order, alternating the rings at latitude angle
// b and b + 1 (in 32nds of a turn) round 33 longitudes. On a unit sphere each
// point is its own normal. The angle runs a full turn, not half: bands 0..15
// go from the +y pole to the -y pole, and bands 16..31 come back up the far
// side, so every point is drawn twice, and with additive blending that is
// twice as bright. A backend draws all of them, and as strips: the same
// triangles as a list rasterize a few pixels differently, which the seam
// check sees.
const int HS_SPHERE_BANDS = 32;
const int HS_SPHERE_BAND_POINTS = 2 * (HS_SPHERE_BANDS + 1);   // longitudes 0..32, two rings
void hsSphereBand(int band, float out[HS_SPHERE_BAND_POINTS][3]);

#endif
