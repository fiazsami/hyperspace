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


#include <Hyperspace/flare.h>
#include <Hyperspace/transform.h>
#include <Hyperspace/renderer.h>



#define FLARESIZE 64


/*unsigned char flare1[FLARESIZE][FLARESIZE][4];
unsigned char flare2[FLARESIZE][FLARESIZE][4];
unsigned char flare3[FLARESIZE][FLARESIZE][4];
unsigned char flare4[FLARESIZE][FLARESIZE][4];
unsigned int flarelist[4];
GLuint flaretex[4];*/

/*extern int xsize, ysize;
extern float aspectRatio;
extern float billboardMat[16];
extern double modelMat[16];
extern double projMat[16];
extern GLint viewport[4];
// Calculated in main draw routine each frame
extern float frameTime;
extern float camPos[3];*/



void initFlares(HyperspaceSaverSettings *inSettings){
	int i, j;
	float x, y;
	float temp;
	
	// First flare:  basic sphere
	for(i=0; i<FLARESIZE; i++){
		for(j=0; j<FLARESIZE; j++){
			inSettings->flare1[i][j][0] = 255;
			inSettings->flare1[i][j][1] = 255;
			inSettings->flare1[i][j][2] = 255;
			x = float(i - FLARESIZE / 2) / float(FLARESIZE / 2);
			y = float(j - FLARESIZE / 2) / float(FLARESIZE / 2);
			temp = 1.0f - ((x * x) + (y * y));
			if(temp > 1.0f)
				temp = 1.0f;
			if(temp < 0.0f)
				temp = 0.0f;
			temp = temp * temp;
			inSettings->flare1[i][j][3] = (unsigned char)(255.0f * temp);
		}
	}
	inSettings->flaretex[0] = inSettings->renderer->createTexture(FLARESIZE, FLARESIZE, &inSettings->flare1[0][0][0]);
	
	// Second flare:  flattened sphere
	for(i=0; i<FLARESIZE; i++){
		for(j=0; j<FLARESIZE; j++){
			inSettings->flare2[i][j][0] = 255;
			inSettings->flare2[i][j][1] = 255;
			inSettings->flare2[i][j][2] = 255;
			x = float(i - FLARESIZE / 2) / float(FLARESIZE / 2);
			y = float(j - FLARESIZE / 2) / float(FLARESIZE / 2);
			temp = 2.5f * (1.0f - ((x * x) + (y * y)));
			if(temp > 1.0f)
				temp = 1.0f;
			if(temp < 0.0f)
				temp = 0.0f;
			//temp = temp * temp * temp * temp;
			inSettings->flare2[i][j][3] = (unsigned char)(255.0f * temp);
		}
	}
	inSettings->flaretex[1] = inSettings->renderer->createTexture(FLARESIZE, FLARESIZE, &inSettings->flare2[0][0][0]);
	
	// Third flare:  torus
	for(i=0; i<FLARESIZE; i++){
		for(j=0; j<FLARESIZE; j++){
			inSettings->flare3[i][j][0] = 255;
			inSettings->flare3[i][j][1] = 255;
			inSettings->flare3[i][j][2] = 255;
			x = float(i - FLARESIZE / 2) / float(FLARESIZE / 2);
			y = float(j - FLARESIZE / 2) / float(FLARESIZE / 2);
			temp = 4.0f * ((x * x) + (y * y)) * (1.0f - ((x * x) + (y * y)));
			if(temp > 1.0f)
				temp = 1.0f;
			if(temp < 0.0f)
				temp = 0.0f;
			temp = temp * temp * temp * temp;
			inSettings->flare3[i][j][3] = (unsigned char)(255.0f * temp);
		}
	}
	inSettings->flaretex[2] = inSettings->renderer->createTexture(FLARESIZE, FLARESIZE, &inSettings->flare3[0][0][0]);
	
	// Fourth flare:  weird flare
	for(i=0; i<FLARESIZE; i++){
		for(j=0; j<FLARESIZE; j++){
			x = float(i - FLARESIZE / 2) / float(FLARESIZE / 2);
			if(x < 0.0f)
				x = -x;
			y = float(j - FLARESIZE / 2) / float(FLARESIZE / 2);
			if(y < 0.0f)
				y = -y;
			inSettings->flare4[i][j][0] = 255;
			inSettings->flare4[i][j][1] = 255;
			temp = 0.14f * (1.0f - max(x, y)) / max((x * y), 0.05f);
			if(temp > 1.0f)
				temp = 1.0f;
			if(temp < 0.0f)
				temp = 0.0f;
			inSettings->flare4[i][j][2] = (unsigned char)(255.0f * temp);
			temp = 0.1f * (1.0f - max(x, y)) / max((x * y), 0.1f);
			if(temp > 1.0f)
				temp = 1.0f;
			if(temp < 0.0f)
				temp = 0.0f;
			inSettings->flare4[i][j][3] = (unsigned char)(255.0f * temp);
		}
	}
	inSettings->flaretex[3] = inSettings->renderer->createTexture(FLARESIZE, FLARESIZE, &inSettings->flare4[0][0][0]);
}


// One flare element: the unit square through m, in flare texture which.
static void flareElement(HyperspaceSaverSettings *inSettings, int which, const float m[16],
                         float red, float green, float blue, float alpha){
	const float color[4] = {red, green, blue, alpha};
	inSettings->renderer->drawQuad(inSettings->flaretex[which], color, m, 0.5f);
}


// Draw a flare at a specified (x,y) location on the screen
// Screen corners are at (0,0) and (1,1)
// alpha = 0.0 for lowest intensity; alpha = 1.0 for highest intensity
void flare(float *pos, float red, float green, float blue, float alpha, HyperspaceSaverSettings *inSettings){
	double win[3];  // in screen coordinates
	float x, y, dx, dy;
	float fadewidth, temp;
	static float flicker = 0.95f;

	if(!hsProject(pos[0], pos[1], pos[2], inSettings->modelMat, inSettings->projMat, inSettings->viewport, win))
		return;   // in the eye plane: no screen position to draw at
	x = (float(win[0]) / float(inSettings->xsize)) * inSettings->aspectRatio;
	y = float(win[1]) / float(inSettings->ysize);
	float diff[3] = {pos[0] - inSettings->camPos[0], pos[1] - inSettings->camPos[1], pos[2] - inSettings->camPos[2]};
	if(diff[0] * inSettings->billboardMat[8] + diff[1] * inSettings->billboardMat[9] + diff[2] * inSettings->billboardMat[10] > 0.0f)
		return;

	// Fade alpha if source is off edge of screen
	fadewidth = float(inSettings->xsize) / 10.0f;
	if(y < 0){
		temp = fadewidth + y;
		if(temp < 0.0f)
			return;
		alpha *= temp / fadewidth;
	}
	if(y > inSettings->ysize){
		temp = fadewidth - y + inSettings->ysize;
		if(temp < 0.0f)
			return;
		alpha *= temp / fadewidth;
	}
	if(x < 0){
		temp = fadewidth + x;
		if(temp < 0.0f)
			return;
		alpha *= temp / fadewidth;
	}
	if(x > inSettings->xsize){
		temp = fadewidth - x + inSettings->xsize;
		if(temp < 0.0f)
			return;
		alpha *= temp / fadewidth;
	}

	// Find lens flare vector
	// This vector runs from the light source through the screen's center
	dx = 0.5f * inSettings->aspectRatio - x;
	dy = 0.5f - y;
	
	inSettings->renderer->beginOverlay(inSettings->aspectRatio);

	// Update fractal flickering
	flicker += inSettings->frameTime * (rsRandf(2.0f) - 1.0f);
	if(flicker < 0.9f)
		flicker = 0.9f;
	if(flicker > 1.1f)
		flicker = 1.1f;
	alpha *= flicker;

	// Draw stuff
	float m[16];

	hsIdentity(m);
	hsTranslate(m, x, y, 0.0f);
	hsScale(m, 0.1f * flicker, 0.1f * flicker, 1.0f);
	flareElement(inSettings, 0, m, red, green, blue * 0.8f, alpha);

	// wide flare
	hsIdentity(m);
	hsTranslate(m, x, y, 0.0f);
	hsScale(m, 5.0f * alpha, 0.05f * alpha, 1.0f);
	flareElement(inSettings, 0, m, red * 0.3f, green * 0.3f, blue, alpha);

	// torus
	hsIdentity(m);
	hsTranslate(m, x, y, 0.0f);
	hsScale(m, 0.5f, 0.2f, 1.0f);
	flareElement(inSettings, 2, m, red, green * 0.5f, blue * 0.5f, alpha * 0.4f);

	// 3 blueish dots
	hsIdentity(m);
	hsTranslate(m, x + dx * 0.35f, y + dy * 0.35f, 0.0f);
	hsScale(m, 0.06f, 0.06f, 1.0f);
	flareElement(inSettings, 1, m, red * 0.85f, green * 0.85f, blue, alpha * 0.5f);

	hsIdentity(m);
	hsTranslate(m, x + dx * 0.45f, y + dy * 0.45f, 0.0f);
	hsScale(m, 0.09f, 0.09f, 1.0f);
	flareElement(inSettings, 1, m, red * 0.7f, green * 0.7f, blue, alpha * 0.4f);

	hsIdentity(m);
	hsTranslate(m, x + dx * 0.55f, y + dy * 0.55f, 0.0f);
	hsScale(m, 0.12f, 0.12f, 1.0f);
	flareElement(inSettings, 1, m, red * 0.55f, green * 0.55f, blue, alpha * 0.3f);

	// 4 more dots
	hsIdentity(m);
	hsTranslate(m, x + dx * 0.75f, y + dy * 0.75f, 0.0f);
	hsScale(m, 0.14f, 0.07f, 1.0f);
	flareElement(inSettings, 3, m, red * 0.3f, green * 0.3f, blue * 0.3f, alpha);

	hsIdentity(m);
	hsTranslate(m, x + dx * 0.78f, y + dy * 0.78f, 0.0f);
	hsScale(m, 0.06f, 0.06f, 1.0f);
	flareElement(inSettings, 1, m, red * 0.3f, green * 0.4f, blue * 0.4f, alpha * 0.5f);

	hsIdentity(m);
	hsTranslate(m, x + dx * 1.25f, y + dy * 1.25f, 0.0f);
	hsScale(m, 0.1f, 0.1f, 1.0f);
	flareElement(inSettings, 1, m, red * 0.3f, green * 0.4f, blue * 0.3f, alpha * 0.5f);

	hsIdentity(m);
	hsTranslate(m, x + dx * 1.3f, y + dy * 1.3f, 0.0f);
	hsScale(m, 0.07f, 0.07f, 1.0f);
	flareElement(inSettings, 1, m, red * 0.6f, green * 0.45f, blue * 0.3f, alpha * 0.5f);

	// stretched weird flare
	hsIdentity(m);
	hsTranslate(m, x + dx * 1.45f, y + dy * 1.45f, 0.0f);
	hsScale(m, 0.8f, 0.2f, 1.0f);
	hsRotate(m, x * 70.0f, 0, 0, 1);
	flareElement(inSettings, 3, m, red, green, blue, alpha * 0.4f);

	// circle
	hsIdentity(m);
	hsTranslate(m, x + dx * 2.0f, y + dy * 2.0f, 0.0f);
	hsScale(m, 0.3f, 0.3f, 1.0f);
	flareElement(inSettings, 1, m, red, green, blue, alpha * 0.2f);

	// big weird flare
	hsIdentity(m);
	hsTranslate(m, x + dx * 2.4f, y + dy * 2.4f, 0.0f);
	hsRotate(m, y * 40.0f, 0, 0, 1);
	hsScale(m, 0.7f, 0.7f, 1.0f);
	flareElement(inSettings, 3, m, red, green, blue, alpha * 0.3f);

	inSettings->renderer->endOverlay();
}
