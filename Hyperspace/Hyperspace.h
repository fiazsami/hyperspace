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
// A saver window: its frame, and the window number the window server gave it.
struct HSWindowSlot { double x, y, width, height; long number; };
// Whether one of others has exactly me's frame and a higher window number: a
// window opened later in the same place, which covers me. The macOS 26 host
// was measured leaving such a window behind, drawing frames never shown.
__private_extern__ bool hsCoveredByNewer(const HSWindowSlot &me, const HSWindowSlot *others, int count);

#endif
