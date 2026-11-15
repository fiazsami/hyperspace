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
// without a context and drawn by another backend later. HSRendererGL is the
// only implementation; it draws exactly what the code it replaced drew.
//
// This covers the stars, the lens flare and every texture, including the
// caustics, which are rendered offscreen and read back. The goo, the tunnel
// and the starburst sphere still draw through GL directly.

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
	// across the target. endOffscreen writes size * size * 3 bytes, bottom row
	// first, and restores the viewport and the camera. Other pipeline state
	// is the backend's to leave: callers set what they draw with next.
	virtual void beginOffscreen(int size) = 0;
	virtual void drawColorStrip(const HSColorVertex *v, int count) = 0;
	virtual void endOffscreen(unsigned char *rgb) = 0;

	// The square hsQuad(model, half) describes, textured, its texture
	// modulated by color, blended (SRC_ALPHA, ONE) over what is already drawn.
	// model places it in world space, seen through the camera and fogged
	// linearly with eye distance -- or, between beginOverlay and endOverlay,
	// in the overlay plane.
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

#endif
