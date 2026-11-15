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

#ifndef HYPERSPACE_RENDERER_GL_H
#define HYPERSPACE_RENDERER_GL_H

#include <Hyperspace/renderer.h>

// HSRenderer on the current OpenGL context. For world quads the GL state the
// contract describes -- blending (SRC_ALPHA, ONE), GL_TEXTURE_2D enabled,
// MODULATE, and linear fog from 0.7 * depth to depth -- is not set here: it is
// the state draw() and initSaver() leave, set once per frame rather than per
// star, as it was before the seam. beginOverlay sets its own, and so do
// beginGoo and beginTunnel. The goo and tunnel programs are the ones
// initShaders() links; shaded must be false if it was never called.
class HSRendererGL : public HSRenderer{
public:
	unsigned int createTexture(int width, int height, const unsigned char *rgba);
	unsigned int createMipmappedTexture(const HSMipChain &chain);
	unsigned int createCubeTexture(const HSMipChain faces[6]);
	void beginOffscreen(int size);
	void drawColorStrip(const HSColorVertex *v, int count);
	void endOffscreen(unsigned char *rgb);
	void drawQuad(unsigned int texture, const float color[4], const float model[16], float half);
	void beginOverlay(float aspect);
	void endOverlay();
	void beginGoo(const float color[4], unsigned int nebula,
		unsigned int normals0, unsigned int normals1, bool shaded);
	void drawGooSurface(impSurface *surface, const float offset[3]);
	void endGoo();
	void beginTunnel(unsigned int caustic0, unsigned int caustic1, float lerp, bool shaded);
	void drawTunnelStrip(const HSTunnelVertex *v, int count);
	void endTunnel();

	HSRendererGL() : offscreenSize(0), shaded(false), tunnelAlpha(1.0f) {}

private:
	int savedViewport[4];
	int offscreenSize;   // 0 outside beginOffscreen / endOffscreen
	bool shaded;         // the begin call's, for its end call to undo
	float tunnelAlpha;   // lerp when shaded, where the tunnel program reads it
};

#endif
