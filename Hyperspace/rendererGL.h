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

// HSRenderer on the current OpenGL context. Blend, texture enable and fog are
// the caller's for world strips, as they were before the seam: draw() sets
// them once per frame, not per star.
class HSRendererGL : public HSRenderer{
public:
	unsigned int createTexture(int width, int height, const unsigned char *rgba);
	void drawStrip(unsigned int texture, const float color[4], const HSVertex *v, int count);
	void beginOverlay(float aspect);
	void endOverlay();
};

#endif
