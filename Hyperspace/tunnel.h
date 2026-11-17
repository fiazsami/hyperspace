/*
 * Copyright (C) 2005-2010  Terence M. Welsh
 *
 * This file is part of Hyperspace.
 *
 * Hyperspace is free software; you can redistribute it and/or modify
 * it under the terms of the GNU General Public License as published
 * by the Free Software Foundation; either version 2 of the License,
 * or (at your option) any later version.
 *
 * Hyperspace is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
 * GNU General Public License for more details.
 *
 * You should have received a copy of the GNU General Public License
 * along with this program; if not, write to the Free Software
 * Foundation, Inc., 59 Temple Place, Suite 330, Boston, MA  02111-1307  USA
 */


#ifndef TUNNEL_H
#define TUNNEL_H



#include "splinePath.h"
#include <Hyperspace/renderer.h>
#include <vector>



class tunnel{
public:
	splinePath* path;
	int resolution;
	int numSections;
	int section;
	float**** v;  // vertex data
	float**** t;  // texture coordinate data
	float**** c;  // color data
	std::vector<HSTunnelVertex> strip;  // draw()'s, sized once here

	float radius;
	// offset for tunnel width
	float widthOffset;

	// spin texture map around tunnel
	float texSpin;

	// offsets for low and high frequency 3D color waves
	float huelo, huehi;
	float satlo, sathi;
	float lumlo, lumhi;

	// make's dShaders, which draw's field carries
	bool shaded;

	tunnel(splinePath* sp, int res);
	~tunnel();
	// Advances the tunnel's phases and, when vertices is true, builds v, t and
	// c from them -- the CPU's part of a backend that does not build the
	// tunnel itself (HSRenderer::buildsTunnel).
	void make(float frameTime, bool dShaders, bool vertices = true);
	// Between the caller's beginTunnel and endTunnel: one strip per ring of
	// each section, or the field once to a backend that builds the tunnel.
	void draw(HSRenderer *renderer);
};



#endif
