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
// star, as it was before the seam. beginOverlay sets its own.
class HSRendererGL : public HSRenderer{
public:
	unsigned int createTexture(int width, int height, const unsigned char *rgba);
	void drawQuad(unsigned int texture, const float color[4], const float model[16], float half);
	void beginOverlay(float aspect);
	void endOverlay();
};

#endif
