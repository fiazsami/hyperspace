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


// Hyperspace screensaver
// Terry Welsh
// Originally wrote this saver in 2001, but computers weren't fast
// enough to run it at a decent frame rate.  Finally released it in 2005.

#ifdef WIN32
#include <windows.h>
#include <rsWin32Saver/rsWin32Saver.h>
#include <regstr.h>
#include <commctrl.h>
#include <resource.h>
#endif
#ifdef RS_XSCREENSAVER
#include <rsXScreenSaver/rsXScreenSaver.h>
#endif

#include <stdio.h>
#include <math.h>
#include <time.h>
#include <string>
#include <rsMath/rsMath.h>
#include <Hyperspace/flare.h>
#include <Hyperspace/causticTextures.h>
#include <Hyperspace/wavyNormalCubeMaps.h>
#include <Hyperspace/splinePath.h>
#include <Hyperspace/tunnel.h>
#include <Hyperspace/goo.h>
#include <Hyperspace/stretchedParticle.h>
#include <Hyperspace/starBurst.h>
#include <Hyperspace/nebulamap.h>
#include <Hyperspace/transform.h>
#include "Hyperspace.h"

//#include <fstream>
//std::ofstream outfile;


/*#ifdef WIN32
LPCTSTR registryPath = ("Software\\Really Slick\\Hyperspace");
HGLRC hglrc;
HDC hdc;
#endif
int readyToDraw = 0;
int xsize, ysize;
float aspectRatio;
float frameTime = 0.0f;
// Parameters edited in the dialog box
int dSpeed;
int dStars;
int dStarSize;
int dResolution;
int dDepth;
int dFov;
int dUseTunnels;
int dUseGoo;
int dShaders;


float camPos[3] = {0.0f, 0.0f, 0.0f};
float depth;
int numAnimTexFrames = 20;
causticTextures* theCausticTextures;
wavyNormalCubeMaps* theWNCM; 
int whichTexture = 0;
splinePath* thePath;
tunnel* theTunnel;
goo* theGoo;
unsigned int speckletex, spheretex, nebulatex;
unsigned int goo_vp, goo_fp, tunnel_vp, tunnel_fp;

stretchedParticle** stars;
stretchedParticle* sunStar;
starBurst* theStarBurst;
*/


void draw(HyperspaceSaverSettings *inSettings){
	if(inSettings->first){
		if(inSettings->dUseTunnels){  // only tunnels use caustic textures
			// Caustic textures can only be created after rendering context has been created
			// because they have to be drawn and then read back from the framebuffer.
#ifdef WIN32
			if(doingPreview) // super fast for Windows previewer
				inSettings->theCausticTextures = new causticTextures(inSettings->renderer, 8, inSettings->numAnimTexFrames, 32, 32, 1.0f, 0.01f, 10.0f);
			else  // normal
#endif
				inSettings->theCausticTextures = new causticTextures(inSettings->renderer, 8, inSettings->numAnimTexFrames, 100, 256, 1.0f, 0.01f, 20.0f);
		}
		if(inSettings->dShaders){
#ifdef WIN32
			if(doingPreview) // super fast for Windows previewer
				inSettings->theWNCM = new wavyNormalCubeMaps(inSettings->renderer, inSettings->numAnimTexFrames, 32);
			else  // normal
#endif
				inSettings->theWNCM = new wavyNormalCubeMaps(inSettings->renderer, inSettings->numAnimTexFrames, 128);
		}
		inSettings->first = 0;
	}

	// Camera movements
	static float camHeading[3] = {0.0f, 0.0f, 0.0f};  // current, target, and last
	static int changeCamHeading = 1;
	static float camHeadingChangeTime[2] = {20.0f, 0.0f};  // total, elapsed
	static float camRoll[3] = {0.0f, 0.0f, 0.0f};  // current, target, and last
	static int changeCamRoll = 1;
	static float camRollChangeTime[2] = {1.0f, 0.0f};  // total, elapsed
	camHeadingChangeTime[1] += inSettings->frameTime;
	if(camHeadingChangeTime[1] >= camHeadingChangeTime[0]){  // Choose new direction
		camHeadingChangeTime[0] = rsRandf(15.0f) + 5.0f;
		camHeadingChangeTime[1] = 0.0f;
		camHeading[2] = camHeading[1];  // last = target
		if(changeCamHeading){
			// face forward most of the time
			if(rsRandi(6))
				camHeading[1] = 0.0f;
			// face backward the rest of the time
			else if(rsRandi(2))
				camHeading[1] = RS_PI;
			else
				camHeading[1] = -RS_PI;
			changeCamHeading = 0;
		}
		else
			changeCamHeading = 1;
	}
	float t = camHeadingChangeTime[1] / camHeadingChangeTime[0];
	t = 0.5f * (1.0f - cosf(RS_PI * t));
	camHeading[0] = camHeading[1] * t + camHeading[2] * (1.0f - t);
	camRollChangeTime[1] += inSettings->frameTime;
	if(camRollChangeTime[1] >= camRollChangeTime[0]){  // Choose new roll angle
		camRollChangeTime[0] = rsRandf(5.0f) + 10.0f;
		camRollChangeTime[1] = 0.0f;
		camRoll[2] = camRoll[1];  // last = target
		if(changeCamRoll){
			camRoll[1] = rsRandf(RS_PIx2*2) - RS_PIx2;
			changeCamRoll = 0;
		}
		else
			changeCamRoll = 1;
	}
	t = camRollChangeTime[1] / camRollChangeTime[0];
	t = 0.5f * (1.0f - cosf(RS_PI * t));
	camRoll[0] = camRoll[1] * t + camRoll[2] * (1.0f - t);

	static float pathDir[3] = {0.0f, 0.0f, -1.0f};
	inSettings->thePath->moveAlongPath(float(inSettings->dSpeed) * inSettings->frameTime * 0.04f);
	inSettings->thePath->update(inSettings->frameTime);
	inSettings->thePath->getPoint(inSettings->dDepth + 2, inSettings->thePath->step, inSettings->camPos);
	inSettings->thePath->getBaseDirection(inSettings->dDepth + 2, inSettings->thePath->step, pathDir);
	float pathAngle = atan2f(-pathDir[0], -pathDir[2]);

	float view[16];
	hsIdentity(view);
	hsRotate(view, -camRoll[0] * RS_RAD2DEG, 0, 0, 1);
	hsRotate(view, (-pathAngle - camHeading[0]) * RS_RAD2DEG, 0, 1, 0);
	hsRotationInverse(inSettings->billboardMat, view);   // faces the camera: undoes the view's rotation
	float rotation[16];   // the view with the eye at the origin, for HSStarField
	for(int i=0; i<16; i++)
		rotation[i] = view[i];
	hsTranslate(view, inSettings->camPos[0]*-1, inSettings->camPos[1]*-1, inSettings->camPos[2]*-1);
	for(int i=0; i<16; i++)
		inSettings->modelMat[i] = view[i];
	inSettings->unroll = camRoll[0] * RS_RAD2DEG;

	if(inSettings->dUseGoo){
		// calculate diagonal fov
		float diagFov = 0.5f * float(inSettings->dFov) / RS_RAD2DEG;
		diagFov = tanf(diagFov);
		diagFov = sqrtf(diagFov * diagFov + (diagFov * inSettings->aspectRatio * diagFov * inSettings->aspectRatio));
		diagFov = 2.0f * atanf(diagFov);
		inSettings->theGoo->update(inSettings->camPos[0], inSettings->camPos[2], pathAngle + camHeading[0], diagFov, inSettings);
	}

	HSFrame frame;
	for(int i=0; i<4; i++)
		frame.viewport[i] = inSettings->viewport[i];
	for(int i=0; i<16; i++){
		frame.projection[i] = float(inSettings->projMat[i]);
		frame.view[i] = view[i];
	}
	frame.fogStart = inSettings->depth * 0.7f;
	frame.fogEnd = inSettings->depth;
	inSettings->renderer->beginFrame(frame);

	// draw stars
	if(inSettings->renderer->drawsStars()){
		if(inSettings->dStars > 0){
			HSStarField field;
			field.stars = inSettings->starData;
			field.count = inSettings->dStars;
			field.generation = inSettings->starGeneration;
			field.texture = inSettings->flaretex[0];
			for(int i=0; i<3; i++)
				field.eye[i] = inSettings->camPos[i];
			for(int i=0; i<16; i++)
				field.view[i] = rotation[i];
			field.unroll = inSettings->unroll;
			field.depth = inSettings->depth;
			inSettings->renderer->drawStarField(field);
		}
	}
	else{
		for(int i=0; i<inSettings->dStars; i++){
			static float temppos[2];
			temppos[0] = inSettings->stars[i]->pos[0] - inSettings->camPos[0];
			temppos[1] = inSettings->stars[i]->pos[2] - inSettings->camPos[2];
			if(temppos[0] > inSettings->depth){
				inSettings->stars[i]->pos[0] -= inSettings->depth * 2.0f;
				inSettings->stars[i]->lastPos[0] -= inSettings->depth * 2.0f;
			}
			if(temppos[0] < inSettings->depth*-1){
				inSettings->stars[i]->pos[0] += inSettings->depth * 2.0f;
				inSettings->stars[i]->lastPos[0] += inSettings->depth * 2.0f;
			}
			if(temppos[1] > inSettings->depth){
				inSettings->stars[i]->pos[2] -= inSettings->depth * 2.0f;
				inSettings->stars[i]->lastPos[2] -= inSettings->depth * 2.0f;
			}
			if(temppos[1] < inSettings->depth*-1){
				inSettings->stars[i]->pos[2] += inSettings->depth * 2.0f;
				inSettings->stars[i]->lastPos[2] += inSettings->depth * 2.0f;
			}
			inSettings->stars[i]->draw(inSettings->renderer, inSettings->flaretex[0], inSettings->camPos, inSettings->unroll, inSettings->modelMat, inSettings->projMat, inSettings->viewport);
		}
	}

	// pick animated texture frame
	static float textureTime = 0.0f;
	textureTime += inSettings->frameTime;
	// loop frames every 2 seconds
	const float texFrameTime(2.0f / float(inSettings->numAnimTexFrames));
	while(textureTime > texFrameTime){
		textureTime -= texFrameTime;
		inSettings->whichTexture ++;
	}
	while(inSettings->whichTexture >= inSettings->numAnimTexFrames)
		inSettings->whichTexture -= inSettings->numAnimTexFrames;

	// alpha component gets normalmap lerp value
	const float lerp = textureTime / texFrameTime;

	// draw goo
	if(inSettings->dUseGoo){
		// calculate color
		static float goo_rgb_phase[3] = {-0.1f, -0.1f, -0.1f};
		static float goo_rgb_speed[3] = {rsRandf(0.02f) + 0.02f, rsRandf(0.02f) + 0.02f, rsRandf(0.02f) + 0.02f};
		float goo_rgb[4];
		for(int i=0; i<3; i++){
			goo_rgb_phase[i] += goo_rgb_speed[i] * inSettings->frameTime;
			if(goo_rgb_phase[i] >= RS_PIx2)
				goo_rgb_phase[i] -= RS_PIx2;
			goo_rgb[i] = sinf(goo_rgb_phase[i]);
			if(goo_rgb[i] < 0.0f)
				goo_rgb[i] = 0.0f;
		}
		// alpha mixes the two normal maps; without shaders there are none
		unsigned int normals0 = 0, normals1 = 0;
		if(inSettings->dShaders){
			goo_rgb[3] = lerp;
			normals0 = inSettings->theWNCM->texture[inSettings->whichTexture];
			normals1 = inSettings->theWNCM->texture[(inSettings->whichTexture + 1) % inSettings->numAnimTexFrames];
		}
		else
			goo_rgb[3] = 1.0f;
		inSettings->renderer->beginGoo(goo_rgb, inSettings->nebulatex, normals0, normals1, inSettings->dShaders);
		inSettings->theGoo->draw(inSettings->renderer);
		inSettings->renderer->endGoo();
	}

	// update starburst
	static float starBurstTime = 300.0f;  // burst after 5 minutes
	starBurstTime -= inSettings->frameTime;
	if(starBurstTime <= 0.0f){
		float pos[] = {inSettings->camPos[0] + (pathDir[0] * inSettings->depth * (0.5f + rsRandf(0.5f))),
			rsRandf(2.0f) - 1.0f,
			inSettings->camPos[2] + (pathDir[2] * inSettings->depth * (0.5f + rsRandf(0.5f)))};
		inSettings->theStarBurst->restart(pos);  // it won't actually restart unless it's ready to
		starBurstTime = rsRandf(240.0f) + 60.0f;  // burst again within 1-5 minutes
	}
	inSettings->theStarBurst->draw(lerp, inSettings);

	// draw tunnel
	if(inSettings->dUseTunnels){
		inSettings->theTunnel->make(inSettings->frameTime, inSettings->dShaders,
			!inSettings->renderer->buildsTunnel());
		inSettings->renderer->beginTunnel(
			inSettings->theCausticTextures->caustictex[inSettings->whichTexture],
			inSettings->theCausticTextures->caustictex[(inSettings->whichTexture + 1) % inSettings->numAnimTexFrames],
			lerp, inSettings->dShaders);
		inSettings->theTunnel->draw(inSettings->renderer);
		inSettings->renderer->endTunnel();
	}

	// draw sun with lens flare
	inSettings->renderer->setFog(false);
	float flarepos[3] = {0.0f, 2.0f, 0.0f};
	inSettings->sunStar->draw(inSettings->renderer, inSettings->flaretex[0], inSettings->camPos, inSettings->unroll, inSettings->modelMat, inSettings->projMat, inSettings->viewport);
	float diff[3] = {flarepos[0] - inSettings->camPos[0], flarepos[1] - inSettings->camPos[1], flarepos[2] - inSettings->camPos[2]};
	float alpha = 0.5f - 0.005f * sqrtf(diff[0] * diff[0] + diff[1] * diff[1] + diff[2] * diff[2]);
	if(alpha > 0.0f)
		flare(flarepos, 1.0f, 1.0f, 1.0f, alpha, inSettings);
	inSettings->renderer->setFog(true);
	inSettings->renderer->endFrame();

#ifdef WIN32
	wglSwapLayerBuffers(hdc, WGL_SWAP_MAIN_PLANE);
#endif
#ifdef RS_XSCREENSAVER
	glXSwapBuffers(xdisplay, xwindow);
#endif
}


/*void IdleProc(){
	// update time
	static rsTimer timer;
	frameTime = timer.tick();

	if(readyToDraw && !isSuspended && !checkingPassword)
		draw();
}*/


double hsFrameInterval(double refreshInterval, double minPerSecond){
	// 0.5% of tolerance, relative: 119.88 / 60 is 1.998 and must count as 2,
	// while 119.4 / 60, 1.99, must not -- it would draw 59.7 a second.
	const double perFrame = floor(1.005 / (refreshInterval * minPerSecond));
	return refreshInterval * (perFrame > 1.0 ? perFrame : 1.0);
}


bool hsFrameDue(double now, double *nextDue, double interval, double slack){
	if(*nextDue > 0.0 && now < *nextDue - slack)
		return false;
	*nextDue = (*nextDue > 0.0 && now - *nextDue < interval) ? *nextDue + interval : now + interval;
	return true;
}


void hsFramePresented(HSVisibility *v, bool shown, double now){
	if(shown)
		v->unseenSince = 0.0;
	else if(v->unseenSince == 0.0)
		v->unseenSince = now;
}


bool hsShouldDraw(HSVisibility *v, double now, double unseenLimit, double probeInterval){
	if(v->unseenSince == 0.0 || now - v->unseenSince < unseenLimit)
		return true;
	if(now < v->probeAt)
		return false;
	v->probeAt = now + probeInterval;
	return true;
}


void setDefaults(HyperspaceSaverSettings *inSettings){
	inSettings->dSpeed = 23;
	inSettings->dStars = 2000;
	inSettings->dStarSize = 10;
	inSettings->dResolution = 20;
	inSettings->dDepth = 5;
	inSettings->dFov = 50;
	inSettings->dUseTunnels = 1;
	inSettings->dUseGoo = 1;
	inSettings->dShaders = 1;
}


#ifdef RS_XSCREENSAVER
void handleCommandLine(int argc, char* argv[]){
	setDefaults();
	getArgumentsValue(argc, argv, std::string("-speed"), dSpeed, 1, 100);
	getArgumentsValue(argc, argv, std::string("-stars"), dStars, 0, 10000);
	getArgumentsValue(argc, argv, std::string("-starsize"), dStarSize, 1, 100);
	getArgumentsValue(argc, argv, std::string("-resolution"), dResolution, 4, 20);
	getArgumentsValue(argc, argv, std::string("-depth"), dDepth, 1, 10);
	getArgumentsValue(argc, argv, std::string("-fov"), dFov, 10, 150);
	getArgumentsValue(argc, argv, std::string("-usetunnels"), dUseTunnels, 0, 1);
	getArgumentsValue(argc, argv, std::string("-usegoo"), dUseGoo, 0, 1);
	getArgumentsValue(argc, argv, std::string("-shaders"), dShaders, 0, 1);
}
#endif


void reshape(int width, int height, HyperspaceSaverSettings *inSettings){
	inSettings->aspectRatio = float(width) / float(height);

	inSettings->xsize = width;
	inSettings->ysize = height;

	inSettings->viewport[0] = 0;
	inSettings->viewport[1] = 0;
	inSettings->viewport[2] = width;
	inSettings->viewport[3] = height;

	// setup projection matrix
	float proj[16];
	hsPerspective(proj, float(inSettings->dFov), inSettings->aspectRatio, 0.001f, 200.0f);
	for(int i=0; i<16; i++)
		inSettings->projMat[i] = proj[i];
}


#ifdef WIN32
void initSaver(HWND hwnd){
	RECT rect;

	// Window initialization
	hdc = GetDC(hwnd);
	setBestPixelFormat(hdc);
	hglrc = wglCreateContext(hdc);
	GetClientRect(hwnd, &rect);
	wglMakeCurrent(hdc, hglrc);
	
	// setup viewport
	//viewport[0] = rect.left;
	//viewport[1] = rect.top;
	//viewport[2] = rect.right - rect.left;
	//viewport[3] = rect.bottom - rect.top;

	// initialize extensions
	if(!initExtensions())
		dShaders = 0;

	reshape(rect.right, rect.bottom);
#endif
//#ifdef RS_XSCREENSAVER
void initSaver(HyperspaceSaverSettings *inSettings, HSRenderer *renderer){
//#endif
	// Seed random number generator
	srand((unsigned)time(NULL));

	// Limit memory consumption because the Windows previewer is just too darn slow
	/*if(doingPreview){
		dResolution = 6;
		if(dDepth > 3)
			dDepth = 3;
	};*/
	
	// Set up some other inSettings defaults...
	inSettings->camPos[0] = 0.0f;
	inSettings->camPos[1] = 0.0f;
	inSettings->camPos[2] = 0.0f;
	inSettings->numAnimTexFrames = 20;
	inSettings->whichTexture = 0;

	// NULL once drew through OpenGL; the saver has no OpenGL now. Refuse it
	// here rather than crash in initFlares; with readyToDraw 0, nothing draws.
	if(renderer == NULL){
		fprintf(stderr, "initSaver: no renderer\n");
		inSettings->readyToDraw = 0;
		inSettings->renderer = NULL;   // so cleanUp frees nothing of a run that did not start
		return;
	}
	inSettings->renderer = renderer;
	initFlares(inSettings);

	inSettings->thePath = new splinePath((inSettings->dDepth * 2) + 6);

	if(inSettings->dUseTunnels)
		inSettings->theTunnel = new tunnel(inSettings->thePath, 20);

	// To avoid popping, depth, which will be used for fogging, is set to
	// dDepth * goo grid size - size of one goo cubelet
	inSettings->depth = float(inSettings->dDepth) * 2.0f - 2.0f / float(inSettings->dResolution);

	if(inSettings->dUseGoo)
		inSettings->theGoo = new goo(inSettings->dResolution, inSettings->depth);

	inSettings->stars = new stretchedParticle*[inSettings->dStars];
	for(int i=0; i<inSettings->dStars; i++){
		inSettings->stars[i] = new stretchedParticle;
		inSettings->stars[i]->radius = rsRandf(float(inSettings->dStarSize) * 0.0005f) + float(inSettings->dStarSize) * 0.0005f;
		if(i % 10){  // usually bland stars
			inSettings->stars[i]->color[0] = 0.8f + rsRandf(0.2f);
			inSettings->stars[i]->color[1] = 0.8f + rsRandf(0.2f);
			inSettings->stars[i]->color[2] = 0.8f + rsRandf(0.2f);
		}
		else{  // occasionally a colorful one
			inSettings->stars[i]->color[0] = 0.3f + rsRandf(0.7f);
			inSettings->stars[i]->color[1] = 0.3f + rsRandf(0.7f);
			inSettings->stars[i]->color[2] = 0.3f + rsRandf(0.7f);
			inSettings->stars[i]->color[rsRandi(3)] = 1.0f;
		}
		inSettings->stars[i]->color[rsRandi(3)] = 1.0f;
		inSettings->stars[i]->pos[0] = rsRandf(2.0f * inSettings->depth) - inSettings->depth;
		inSettings->stars[i]->pos[1] = rsRandf(4.0f) - 2.0f;
		inSettings->stars[i]->pos[2] = rsRandf(2.0f * inSettings->depth) - inSettings->depth;
		inSettings->stars[i]->fov = float(inSettings->dFov);
	}
	// A new generation each time, so a backend never keeps another run's stars.
	static unsigned int starGenerations = 0;
	inSettings->starGeneration = ++starGenerations;
	inSettings->starData = new float[HS_STAR_FLOATS * (inSettings->dStars > 0 ? inSettings->dStars : 1)];
	for(int i=0; i<inSettings->dStars; i++){
		float *d = inSettings->starData + HS_STAR_FLOATS * i;
		const stretchedParticle *star = inSettings->stars[i];
		d[0] = star->pos[0]; d[1] = star->pos[1]; d[2] = star->pos[2];
		d[3] = star->radius;
		d[4] = star->color[0]; d[5] = star->color[1]; d[6] = star->color[2];
	}

	inSettings->sunStar = new stretchedParticle;
	inSettings->sunStar->radius = float(inSettings->dStarSize) * 0.004f;
	inSettings->sunStar->pos[0] = 0.0f;
	inSettings->sunStar->pos[1] = 2.0f;
	inSettings->sunStar->pos[2] = 0.0f;
	inSettings->sunStar->fov = float(inSettings->dFov);

	inSettings->theStarBurst = new starBurst;
	for(int i=0; i<SB_NUM_STARS; i++)
		inSettings->theStarBurst->stars[i]->radius = rsRandf(float(inSettings->dStarSize) * 0.001f) + float(inSettings->dStarSize) * 0.001f;

	if(inSettings->dShaders){
		inSettings->numAnimTexFrames = 20;
		HSMipChain faces[6];  // the same nebula on every face
		hsBuildMipmaps(&nebulamap[0][0][0], NEBULAMAPSIZE, 3, faces[0]);
		for(int f=1; f<6; f++)
			faces[f] = faces[0];
		inSettings->nebulatex = inSettings->renderer->createCubeTexture(faces);
	}
	else{
		//unsigned char spheremap[NEBULAMAPSIZE][NEBULAMAPSIZE][3] = nebulamap;
		inSettings->numAnimTexFrames = 60;
		float x, y, temp;
		const int halfsize(NEBULAMAPSIZE / 2);
		for(int i=0; i<NEBULAMAPSIZE; ++i){
			for(int j=0; j<NEBULAMAPSIZE; ++j){
				x = float(i - halfsize) / float(halfsize);
				y = float(j - halfsize) / float(halfsize);
				temp = (x * x) + (y * y);
				if(temp > 1.0f)
					temp = 1.0f;
				if(temp < 0.0f)
					temp = 0.0f;
				temp = temp * temp;
				temp = temp * temp;
				nebulamap[i][j][0] = (unsigned char)(float(nebulamap[i][j][0]) * temp);
				nebulamap[i][j][1] = (unsigned char)(float(nebulamap[i][j][1]) * temp);
				nebulamap[i][j][2] = (unsigned char)(float(nebulamap[i][j][2]) * temp);
			}
		}
		HSMipChain chain;
		hsBuildMipmaps(&nebulamap[0][0][0], NEBULAMAPSIZE, 3, chain);
		inSettings->nebulatex = inSettings->renderer->createMipmappedTexture(chain);
	}

	//outfile.open("outfile");

	inSettings->readyToDraw = 1;
}


//#ifdef RS_XSCREENSAVER
void cleanUp(HyperspaceSaverSettings *inSettings){
	// initSaver sets the renderer before it builds anything, and this nulls it
	// after freeing everything: no renderer means nothing of this run to free
	// (initSaver refused, or this already ran), and the other pointers may be
	// a previous run's, already deleted.
	if(inSettings->renderer == NULL)
		return;
	// Free memory
	if(inSettings->dUseGoo)
		delete inSettings->theGoo;
	if(inSettings->dUseTunnels){
		delete inSettings->theTunnel;
		delete inSettings->theCausticTextures;
	}
	delete inSettings->thePath;
	delete inSettings->theWNCM;
	delete[] inSettings->starData;
	delete inSettings->renderer;
	// The caustics and cube maps are made by the first draw(), so a start and
	// stop with no frame between them would delete these again.
	inSettings->theCausticTextures = NULL;
	inSettings->theWNCM = NULL;
	inSettings->starData = NULL;
	inSettings->renderer = NULL;
	inSettings->first = 1;
}
//#endif


/*#ifdef WIN32
void cleanUp(HWND hwnd){
	// Free memory
	if(dUseGoo)
		delete theGoo;
	if(dUseTunnels){
		delete theTunnel;
		delete theCausticTextures;
	}
	delete thePath;
	delete theWNCM;

	// Kill device context
	ReleaseDC(hwnd, hdc);
	wglMakeCurrent(NULL, NULL);
	wglDeleteContext(hglrc);
}


// Initialize all user-defined stuff
void readRegistry(){
	LONG result;
	HKEY skey;
	DWORD valtype, valsize, val;

	setDefaults();

	result = RegOpenKeyEx(HKEY_CURRENT_USER, registryPath, 0, KEY_READ, &skey);
	if(result != ERROR_SUCCESS)
		return;

	valsize=sizeof(val);

	result = RegQueryValueEx(skey, "Speed", 0, &valtype, (LPBYTE)&val, &valsize);
	if(result == ERROR_SUCCESS)
		dSpeed = val;
	result = RegQueryValueEx(skey, "Stars", 0, &valtype, (LPBYTE)&val, &valsize);
	if(result == ERROR_SUCCESS)
		dStars = val;
	result = RegQueryValueEx(skey, "StarSize", 0, &valtype, (LPBYTE)&val, &valsize);
	if(result == ERROR_SUCCESS)
		dStarSize = val;
	result = RegQueryValueEx(skey, "Resolution", 0, &valtype, (LPBYTE)&val, &valsize);
	if(result == ERROR_SUCCESS)
		dResolution = val;
	result = RegQueryValueEx(skey, "Depth", 0, &valtype, (LPBYTE)&val, &valsize);
	if(result == ERROR_SUCCESS)
		dDepth = val;
	result = RegQueryValueEx(skey, "Fov", 0, &valtype, (LPBYTE)&val, &valsize);
	if(result == ERROR_SUCCESS)
		dFov = val;
	result = RegQueryValueEx(skey, "UseTunnels", 0, &valtype, (LPBYTE)&val, &valsize);
	if(result == ERROR_SUCCESS)
		dUseTunnels = val;
	result = RegQueryValueEx(skey, "UseGoo", 0, &valtype, (LPBYTE)&val, &valsize);
	if(result == ERROR_SUCCESS)
		dUseGoo = val;
	result = RegQueryValueEx(skey, "Shaders", 0, &valtype, (LPBYTE)&val, &valsize);
	if(result == ERROR_SUCCESS)
		dShaders = val;
	result = RegQueryValueEx(skey, "FrameRateLimit", 0, &valtype, (LPBYTE)&val, &valsize);
	if(result == ERROR_SUCCESS)
		dFrameRateLimit = val;

	RegCloseKey(skey);
}


// Save all user-defined stuff
void writeRegistry(){
    LONG result;
	HKEY skey;
	DWORD val, disp;

	result = RegCreateKeyEx(HKEY_CURRENT_USER, registryPath, 0, NULL, REG_OPTION_NON_VOLATILE, KEY_WRITE, NULL, &skey, &disp);
	if(result != ERROR_SUCCESS)
		return;

	val = dSpeed;
	RegSetValueEx(skey, "Speed", 0, REG_DWORD, (CONST BYTE*)&val, sizeof(val));
	val = dStars;
	RegSetValueEx(skey, "Stars", 0, REG_DWORD, (CONST BYTE*)&val, sizeof(val));
	val = dStarSize;
	RegSetValueEx(skey, "StarSize", 0, REG_DWORD, (CONST BYTE*)&val, sizeof(val));
	val = dResolution;
	RegSetValueEx(skey, "Resolution", 0, REG_DWORD, (CONST BYTE*)&val, sizeof(val));
	val = dDepth;
	RegSetValueEx(skey, "Depth", 0, REG_DWORD, (CONST BYTE*)&val, sizeof(val));
	val = dFov;
	RegSetValueEx(skey, "Fov", 0, REG_DWORD, (CONST BYTE*)&val, sizeof(val));
	val = dUseTunnels;
	RegSetValueEx(skey, "UseTunnels", 0, REG_DWORD, (CONST BYTE*)&val, sizeof(val));
	val = dUseGoo;
	RegSetValueEx(skey, "UseGoo", 0, REG_DWORD, (CONST BYTE*)&val, sizeof(val));
	val = dShaders;
	RegSetValueEx(skey, "Shaders", 0, REG_DWORD, (CONST BYTE*)&val, sizeof(val));
	val = dFrameRateLimit;
	RegSetValueEx(skey, "FrameRateLimit", 0, REG_DWORD, (CONST BYTE*)&val, sizeof(val));

	RegCloseKey(skey);
}


BOOL aboutProc(HWND hdlg, UINT msg, WPARAM wpm, LPARAM lpm){
	switch(msg){
	case WM_CTLCOLORSTATIC:
		if(HWND(lpm) == GetDlgItem(hdlg, WEBPAGE)){
			SetTextColor(HDC(wpm), RGB(0,0,255));
			SetBkColor(HDC(wpm), COLORREF(GetSysColor(COLOR_3DFACE)));
			return(int(GetSysColorBrush(COLOR_3DFACE)));
		}
		break;
    case WM_COMMAND:
		switch(LOWORD(wpm)){
		case IDOK:
		case IDCANCEL:
			EndDialog(hdlg, LOWORD(wpm));
			break;
		case WEBPAGE:
			ShellExecute(NULL, "open", "http://www.reallyslick.com/", NULL, NULL, SW_SHOWNORMAL);
		}
	}
	return FALSE;
}


void initControls(HWND hdlg){
	char cval[16];

	CheckDlgButton(hdlg, USETUNNELS, dUseTunnels);
	CheckDlgButton(hdlg, USEGOO, dUseGoo);
	CheckDlgButton(hdlg, USESHADERS, dShaders);

	SendDlgItemMessage(hdlg, SPEED, TBM_SETRANGE, 0, LPARAM(MAKELONG(DWORD(1), DWORD(100))));
	SendDlgItemMessage(hdlg, SPEED, TBM_SETPOS, 1, LPARAM(dSpeed));
	SendDlgItemMessage(hdlg, SPEED, TBM_SETLINESIZE, 0, LPARAM(1));
	SendDlgItemMessage(hdlg, SPEED, TBM_SETPAGESIZE, 0, LPARAM(5));
	sprintf(cval, "%d", dSpeed);
	SendDlgItemMessage(hdlg, SPEEDTEXT, WM_SETTEXT, 0, LPARAM(cval));

	SendDlgItemMessage(hdlg, STARS, TBM_SETRANGE, 0, LPARAM(MAKELONG(DWORD(0), DWORD(10000))));
	SendDlgItemMessage(hdlg, STARS, TBM_SETPOS, 1, LPARAM(dStars));
	SendDlgItemMessage(hdlg, STARS, TBM_SETLINESIZE, 0, LPARAM(1));
	SendDlgItemMessage(hdlg, STARS, TBM_SETPAGESIZE, 0, LPARAM(50));
	sprintf(cval, "%d", dStars);
	SendDlgItemMessage(hdlg, STARSTEXT, WM_SETTEXT, 0, LPARAM(cval));
	
	SendDlgItemMessage(hdlg, STARSIZE, TBM_SETRANGE, 0, LPARAM(MAKELONG(DWORD(1), DWORD(100))));
	SendDlgItemMessage(hdlg, STARSIZE, TBM_SETPOS, 1, LPARAM(dStarSize));
	SendDlgItemMessage(hdlg, STARSIZE, TBM_SETLINESIZE, 0, LPARAM(1));
	SendDlgItemMessage(hdlg, STARSIZE, TBM_SETPAGESIZE, 0, LPARAM(5));
	sprintf(cval, "%d", dStarSize);
	SendDlgItemMessage(hdlg, STARSIZETEXT, WM_SETTEXT, 0, LPARAM(cval));
	
	SendDlgItemMessage(hdlg, RESOLUTION, TBM_SETRANGE, 0, LPARAM(MAKELONG(DWORD(4), DWORD(20))));
	SendDlgItemMessage(hdlg, RESOLUTION, TBM_SETPOS, 1, LPARAM(dResolution));
	SendDlgItemMessage(hdlg, RESOLUTION, TBM_SETLINESIZE, 0, LPARAM(1));
	SendDlgItemMessage(hdlg, RESOLUTION, TBM_SETPAGESIZE, 0, LPARAM(2));
	if(dUseGoo)
		EnableWindow(GetDlgItem(hdlg, RESOLUTION), TRUE);
	else
		EnableWindow(GetDlgItem(hdlg, RESOLUTION), FALSE);
	sprintf(cval, "%d", dResolution);
	SendDlgItemMessage(hdlg, RESOLUTIONTEXT, WM_SETTEXT, 0, LPARAM(cval));

	SendDlgItemMessage(hdlg, DEPTH, TBM_SETRANGE, 0, LPARAM(MAKELONG(DWORD(1), DWORD(10))));
	SendDlgItemMessage(hdlg, DEPTH, TBM_SETPOS, 1, LPARAM(dDepth));
	SendDlgItemMessage(hdlg, DEPTH, TBM_SETLINESIZE, 0, LPARAM(1));
	SendDlgItemMessage(hdlg, DEPTH, TBM_SETPAGESIZE, 0, LPARAM(2));
	sprintf(cval, "%d", dDepth);
	SendDlgItemMessage(hdlg, DEPTHTEXT, WM_SETTEXT, 0, LPARAM(cval));

	SendDlgItemMessage(hdlg, FOV, TBM_SETRANGE, 0, LPARAM(MAKELONG(DWORD(10), DWORD(150))));
	SendDlgItemMessage(hdlg, FOV, TBM_SETPOS, 1, LPARAM(dFov));
	SendDlgItemMessage(hdlg, FOV, TBM_SETLINESIZE, 0, LPARAM(1));
	SendDlgItemMessage(hdlg, FOV, TBM_SETPAGESIZE, 0, LPARAM(5));
	sprintf(cval, "%d", dFov);
	SendDlgItemMessage(hdlg, FOVTEXT, WM_SETTEXT, 0, LPARAM(cval));

	initFrameRateLimitSlider(hdlg, FRAMERATELIMIT, FRAMERATELIMITTEXT);
}


BOOL screenSaverConfigureDialog(HWND hdlg, UINT msg, WPARAM wpm, LPARAM lpm){
	int ival;
	char cval[16];

    switch(msg){
    case WM_INITDIALOG:
        InitCommonControls();
        readRegistry();
        initControls(hdlg);
        return TRUE;
    case WM_COMMAND:
        switch(LOWORD(wpm)){
        case IDOK:
			dSpeed = SendDlgItemMessage(hdlg, SPEED, TBM_GETPOS, 0, 0);
			dStars = SendDlgItemMessage(hdlg, STARS, TBM_GETPOS, 0, 0);
			dStarSize = SendDlgItemMessage(hdlg, STARSIZE, TBM_GETPOS, 0, 0);
			dResolution = SendDlgItemMessage(hdlg, RESOLUTION, TBM_GETPOS, 0, 0);
			dDepth = SendDlgItemMessage(hdlg, DEPTH, TBM_GETPOS, 0, 0);
			dFov = SendDlgItemMessage(hdlg, FOV, TBM_GETPOS, 0, 0);
			dUseTunnels = (IsDlgButtonChecked(hdlg, USETUNNELS) == BST_CHECKED);
			dUseGoo = (IsDlgButtonChecked(hdlg, USEGOO) == BST_CHECKED);
			dShaders = (IsDlgButtonChecked(hdlg, USESHADERS) == BST_CHECKED);
			dFrameRateLimit = SendDlgItemMessage(hdlg, FRAMERATELIMIT, TBM_GETPOS, 0, 0);
			writeRegistry();
            // Fall through
        case IDCANCEL:
            EndDialog(hdlg, LOWORD(wpm));
            break;
		case DEFAULTS:
			setDefaults();
			initControls(hdlg);
			break;
		case ABOUT:
			DialogBox(mainInstance, MAKEINTRESOURCE(DLG_ABOUT), hdlg, DLGPROC(aboutProc));
			break;
		case USEGOO:
			if(IsDlgButtonChecked(hdlg, USEGOO) == BST_CHECKED)
				EnableWindow(GetDlgItem(hdlg, RESOLUTION), TRUE);
			else
				EnableWindow(GetDlgItem(hdlg, RESOLUTION), FALSE);
			break;
		}
        return TRUE;
	case WM_HSCROLL:
		if(HWND(lpm) == GetDlgItem(hdlg, SPEED)){
			ival = SendDlgItemMessage(hdlg, SPEED, TBM_GETPOS, 0, 0);
			sprintf(cval, "%d", ival);
			SendDlgItemMessage(hdlg, SPEEDTEXT, WM_SETTEXT, 0, LPARAM(cval));
		}
		if(HWND(lpm) == GetDlgItem(hdlg, STARS)){
			ival = SendDlgItemMessage(hdlg, STARS, TBM_GETPOS, 0, 0);
			sprintf(cval, "%d", ival);
			SendDlgItemMessage(hdlg, STARSTEXT, WM_SETTEXT, 0, LPARAM(cval));
		}
		if(HWND(lpm) == GetDlgItem(hdlg, STARSIZE)){
			ival = SendDlgItemMessage(hdlg, STARSIZE, TBM_GETPOS, 0, 0);
			sprintf(cval, "%d", ival);
			SendDlgItemMessage(hdlg, STARSIZETEXT, WM_SETTEXT, 0, LPARAM(cval));
		}
		if(HWND(lpm) == GetDlgItem(hdlg, RESOLUTION)){
			ival = SendDlgItemMessage(hdlg, RESOLUTION, TBM_GETPOS, 0, 0);
			sprintf(cval, "%d", ival);
			SendDlgItemMessage(hdlg, RESOLUTIONTEXT, WM_SETTEXT, 0, LPARAM(cval));
		}
		if(HWND(lpm) == GetDlgItem(hdlg, DEPTH)){
			ival = SendDlgItemMessage(hdlg, DEPTH, TBM_GETPOS, 0, 0);
			sprintf(cval, "%d", ival);
			SendDlgItemMessage(hdlg, DEPTHTEXT, WM_SETTEXT, 0, LPARAM(cval));
		}
		if(HWND(lpm) == GetDlgItem(hdlg, FOV)){
			ival = SendDlgItemMessage(hdlg, FOV, TBM_GETPOS, 0, 0);
			sprintf(cval, "%d", ival);
			SendDlgItemMessage(hdlg, FOVTEXT, WM_SETTEXT, 0, LPARAM(cval));
		}
		if(HWND(lpm) == GetDlgItem(hdlg, FRAMERATELIMIT))
			updateFrameRateLimitSlider(hdlg, FRAMERATELIMIT, FRAMERATELIMITTEXT);
		return TRUE;
    }
    return FALSE;
}


LONG screenSaverProc(HWND hwnd, UINT msg, WPARAM wpm, LPARAM lpm){
	switch(msg){
	case WM_CREATE:
		readRegistry();
		initSaver(hwnd);
		break;
	case WM_DESTROY:
		readyToDraw = 0;
		cleanUp(hwnd);
		break;
	}
	return defScreenSaverProc(hwnd, msg, wpm, lpm);
}
#endif
 */
