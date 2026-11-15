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


#ifdef WIN32
	#include <windows.h>
#endif
#include <Hyperspace/stretchedParticle.h>
#include <Hyperspace/transform.h>
#include <Hyperspace/renderer.h>
#include <stdio.h>
#include <math.h>



//extern float billboardMat[16];
/*extern float unroll;
extern double modelMat[16];
extern double projMat[16];
extern GLint viewport[4];*/



stretchedParticle::stretchedParticle(){
	pos[0] = pos[1] = pos[2] = 0.0f;
	lastPos[0] = lastPos[1] = lastPos[2] = 0.0f;
	drawPos[0] = drawPos[1] = drawPos[2] = 0.0f;
	// A star whose first projection fails has no last frame to keep.
	screenPos[0] = screenPos[1] = 0.0;
	lastScreenPos[0] = lastScreenPos[1] = 0.0;
	
	radius = 0.03f;
	color[0] = color[1] = color[2] = 1.0f;
}


void stretchedParticle::draw(HSRenderer *renderer, unsigned int texture, float* eyepoint, float unroll, double *modelMat, double *projMat, int *viewport){
	double win[3];
	// Where the projection fails (w = 0) the star keeps last frame's position.
	if(hsProject(pos[0], pos[1], pos[2], modelMat, projMat, viewport, win) && win[2] > 0.0f){
		screenPos[0] = win[0];
		screenPos[1] = win[1];
	}

	drawPos[0] = (pos[0] + lastPos[0]) * 0.5f;
	drawPos[1] = (pos[1] + lastPos[1]) * 0.5f;
	drawPos[2] = (pos[2] + lastPos[2]) * 0.5f;
	lastPos[0] = pos[0];
	lastPos[1] = pos[1];
	lastPos[2] = pos[2];

	float sd[2], pd[3];  // screen difference, position difference
	sd[0] = float(screenPos[0] - lastScreenPos[0]);
	sd[1] = float(screenPos[1] - lastScreenPos[1]);
	pd[0] = eyepoint[0] - drawPos[0];
	pd[1] = eyepoint[1] - drawPos[1];
	pd[2] = eyepoint[2] - drawPos[2];

	float bbMat[16];
	bbMat[0] = bbMat[5] = bbMat[10] = bbMat[15] = 1.0f;
	bbMat[1] = bbMat[2] = bbMat[3] = bbMat[4] =
	bbMat[6] = bbMat[7] = bbMat[8] = bbMat[9] =
	bbMat[11] = bbMat[12] = bbMat[13] = bbMat[14] = 0.0f;
	float n =  sqrtf(pd[0] * pd[0] + pd[1] * pd[1] + pd[2] * pd[2]);
	bbMat[8] = pd[0] / n;
	bbMat[9] = pd[1] / n;
	bbMat[10] = pd[2] / n;
	bbMat[0] = bbMat[10];
	bbMat[2] = -bbMat[8];
	bbMat[4] = bbMat[9] * bbMat[2] - bbMat[1] * bbMat[10];
	bbMat[5] = bbMat[10] * bbMat[0] - bbMat[2] * bbMat[8];
	bbMat[6] = bbMat[8] * bbMat[1] - bbMat[0] * bbMat[9];

	float stretch = 0.0015f * sqrtf(sd[0] * sd[0] + sd[1] * sd[1]) * n / radius;
	if(stretch < 1.0f)
		stretch = 1.0f;
	if(stretch > 0.5f / radius)
		stretch = 0.5f / radius;
	float m[16];
	hsIdentity(m);
	hsTranslate(m, drawPos[0], drawPos[1], drawPos[2]);
	hsMultiply(m, bbMat);
	hsRotate(m, 57.2957795131f * atan2f(sd[1], sd[0]) + unroll, 0, 0, 1);
	hsScale(m, stretch, 1.0f, 1.0f);
	float darkener = stretch * 0.3f;
	if(darkener < 1.0f)
		darkener = 1.0f;
	HSVertex quad[4];
	// draw colored aura
	const float aura[4] = {color[0] / darkener, color[1] / darkener, color[2] / darkener, 1.0f};
	hsQuad(m, radius, quad);
	renderer->drawStrip(texture, aura, quad, 4);
	// draw white center
	const float center[4] = {1.0f / darkener, 1.0f / darkener, 1.0f / darkener, 1.0f};
	hsQuad(m, radius * 0.3f, quad);
	renderer->drawStrip(texture, center, quad, 4);
	
	lastScreenPos[0] = screenPos[0];
	lastScreenPos[1] = screenPos[1];
}
