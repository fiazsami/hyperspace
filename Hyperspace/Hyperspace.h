#ifndef HYPERSPACE_H
#define HYPERSPACE_H

class causticTextures;
class wavyNormalCubeMaps;
class splinePath;
class tunnel;
class goo;
class stretchedParticle;
class starBurst;
class HSRenderer;

#define FLARESIZE 64

typedef struct HyperspaceSaverSettings
{
	// Parameters edited in the dialog box
	int dSpeed;
	int dStars;
	int dStarSize;
	int dResolution;
	int dDepth;
	int dFov;
	bool dUseTunnels;
	bool dUseGoo;
	bool dShaders;
	
	// Additional globals:
	float frameTime;
	bool doingPreview;
	bool readyToDraw;
	int xsize, ysize;
	float aspectRatio;
	bool first;
	
	float unroll;
	float billboardMat[16];
	double modelMat[16];
	double projMat[16];
	int viewport[4];
	
	float camPos[3]/* = {0.0f, 0.0f, 0.0f}*/;
	float depth;
	int numAnimTexFrames/* = 20*/;
	causticTextures* theCausticTextures;
	wavyNormalCubeMaps* theWNCM; 
	int whichTexture/* = 0*/;
	splinePath* thePath;
	tunnel* theTunnel;
	goo* theGoo;
	unsigned int nebulatex;
	
	stretchedParticle** stars;
	stretchedParticle* sunStar;
	starBurst* theStarBurst;
	
	unsigned char flare1[FLARESIZE][FLARESIZE][4];
	unsigned char flare2[FLARESIZE][FLARESIZE][4];
	unsigned char flare3[FLARESIZE][FLARESIZE][4];
	unsigned char flare4[FLARESIZE][FLARESIZE][4];
	unsigned int flaretex[4];

	HSRenderer *renderer;  // every draw goes through this
};

__private_extern__ void draw(HyperspaceSaverSettings *inSettings);
__private_extern__ void reshape(int width, int height, HyperspaceSaverSettings *inSettings);
// renderer is the backend to draw through, and must not be NULL: the settings
// own it from here on, and cleanUp deletes it.
__private_extern__ void initSaver(HyperspaceSaverSettings *inSettings, HSRenderer *renderer);
__private_extern__ void cleanUp(HyperspaceSaverSettings *inSettings);
__private_extern__ void setDefaults(HyperspaceSaverSettings *inSettings);
// The interval to draw frames at on a display that refreshes every
// refreshInterval seconds: every n-th refresh, the largest n that still draws
// at least minPerSecond frames a second, so every frame stays on screen the
// same number of refreshes. 144 Hz at 60 gives 1/72; 120 Hz 1/60; a display
// at or under minPerSecond, every refresh. Rates reported a hair under a
// whole one (119.88 Hz) count as that one. refreshInterval must be > 0.
__private_extern__ double hsFrameInterval(double refreshInterval, double minPerSecond);

#endif
