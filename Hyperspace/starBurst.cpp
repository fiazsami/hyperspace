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
#include <Hyperspace/extensions.h>
#endif

#include <Hyperspace/starBurst.h>
#include <Hyperspace/flare.h>
#include <Hyperspace/renderer.h>
#include <Hyperspace/wavyNormalCubeMaps.h>
#include <rsMath/rsMath.h>


starBurst::starBurst(){
	int i;
	float vel[3];
	float normalizer;

	// initialize stars
	stars = new stretchedParticle*[SB_NUM_STARS];
	stars_active = new bool[SB_NUM_STARS];
	stars_velocity = new float*[SB_NUM_STARS];
	for(i=0; i<SB_NUM_STARS; i++){
		stars[i] = new stretchedParticle;
		stars_active[i] = 0;
		stars_velocity[i] = new float[3];
		vel[0] = rsRandf(1.0f) - 0.5f;
		vel[1] = rsRandf(1.0f) - 0.5f;
		vel[2] = rsRandf(1.0f) - 0.5f;
		normalizer = (rsRandf(0.75f) + 0.25f)
			/ sqrtf(vel[0] * vel[0] + vel[1] * vel[1] + vel[2] * vel[2]);
		stars_velocity[i][0] = vel[0] * normalizer;
		stars_velocity[i][1] = vel[1] * normalizer;
		stars_velocity[i][2] = vel[2] * normalizer;
	}

	size = 4.0f;
}


void starBurst::restart(float* position){
	int i;

	for(i=0; i<SB_NUM_STARS; i++){  // don't restart if any star is still active
		if(stars_active[i])
			return;
	}
	if(size < 3.0f)  // or if flare hasn't faded out completely
		return;

	float color[3];
	color[0] = rsRandf(1.0f);
	color[1] = rsRandf(1.0f);
	color[2] = rsRandf(1.0f);
	color[rsRandi(3)] = 1.0f;
	for(i=0; i<SB_NUM_STARS; i++){
		stars_active[i] = 1;
		stars[i]->pos[0] = position[0];
		stars[i]->pos[1] = position[1];
		stars[i]->pos[2] = position[2];
		stars[i]->color[0] = color[0];
		stars[i]->color[1] = color[1];
		stars[i]->color[2] = color[2];
	}

	size = 0.0f;
	pos[0] = position[0];
	pos[1] = position[1];
	pos[2] = position[2];
}


void starBurst::drawStars(HyperspaceSaverSettings *inSettings){
	int i;
	float distance;

	// draw stars
	for(i=0; i<SB_NUM_STARS; i++){
		stars[i]->pos[0] += stars_velocity[i][0] * inSettings->frameTime;
		stars[i]->pos[1] += stars_velocity[i][1] * inSettings->frameTime;
		stars[i]->pos[2] += stars_velocity[i][2] * inSettings->frameTime;
		distance = sqrtf((stars[i]->pos[0] - inSettings->camPos[0]) * (stars[i]->pos[0] - inSettings->camPos[0])
			+ (stars[i]->pos[1] - inSettings->camPos[1]) * (stars[i]->pos[1] - inSettings->camPos[1])
			+ (stars[i]->pos[2] - inSettings->camPos[2]) * (stars[i]->pos[2] - inSettings->camPos[2]));
		if(distance > inSettings->depth)
			stars_active[i] = 0;
		if(stars_active[i])
			stars[i]->draw(inSettings->renderer, inSettings->flaretex[0], inSettings->camPos, inSettings->unroll, inSettings->modelMat, inSettings->projMat, inSettings->viewport);
	}
}


void starBurst::draw(float lerp, HyperspaceSaverSettings *inSettings){
	drawStars(inSettings);
	
	size += inSettings->frameTime * 0.5f;
	if(size >= 3.0f)
		return;

	// draw flare
	float brightness = 1.0f - (size * 0.333333f);
	if(brightness > 0.0f){
		float p[3];
		p[0] = pos[0];
		p[1] = pos[1];
		p[2] = pos[2];
		flare(p, 1.0f, 1.0f, 1.0f, brightness, inSettings);
	}

	// draw sphere; without shaders there are no normal maps to mix
	float color[4] = {brightness, brightness, brightness, 1.0f};
	unsigned int normals0 = 0, normals1 = 0;
	if(inSettings->dShaders){
		color[3] = lerp;
		normals0 = inSettings->theWNCM->texture[inSettings->whichTexture];
		normals1 = inSettings->theWNCM->texture[(inSettings->whichTexture + 1) % inSettings->numAnimTexFrames];
	}
	inSettings->renderer->beginGoo(color, inSettings->nebulatex, normals0, normals1, inSettings->dShaders);
	inSettings->renderer->drawGooSphere(pos, size);
	inSettings->renderer->endGoo();
}
