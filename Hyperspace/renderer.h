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
// This covers the stars and the lens flare. The goo, the tunnel and the
// starburst sphere still call GL directly.

#ifndef HYPERSPACE_RENDERER_H
#define HYPERSPACE_RENDERER_H

struct HSVertex{
	float pos[3];
	float uv[2];
};

class HSRenderer{
public:
	virtual ~HSRenderer(){}

	// An RGBA8 texture, linear min and mag filtering, no mipmaps.
	virtual unsigned int createTexture(int width, int height, const unsigned char *rgba) = 0;

	// A triangle strip, textured, its texture modulated by color, blended
	// (SRC_ALPHA, ONE) over what is already drawn. Positions are world space,
	// through the camera, except between beginOverlay and endOverlay.
	virtual void drawStrip(unsigned int texture, const float color[4], const HSVertex *v, int count) = 0;

	// The lens-flare plane: x runs 0..aspect left to right, y 0..1 bottom to
	// top, with no camera and no fog.
	virtual void beginOverlay(float aspect) = 0;
	virtual void endOverlay() = 0;
};

// The unit-textured square of side 2 * half centred on the origin, through m,
// in strip order: (-,-) (+,-) (-,+) (+,+), texcoords (0,0) (1,0) (0,1) (1,1).
// The stars and every flare element are one of these.
void hsQuad(const float m[16], float half, HSVertex out[4]);

#endif
