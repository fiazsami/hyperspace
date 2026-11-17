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
// Whether a view's frames are reaching the screen, from what became of them:
// after unseenLimit seconds in which no frame was shown, the view draws only
// one probe frame each probeInterval seconds, until one is shown. A view any
// of whose frames are shown keeps drawing. Zero-initialised is a view drawing
// normally.
struct HSVisibility { double unseenSince; double probeAt; };
// A frame's fate, as its drawable's presented handler reports it, at time now
// (> 0: a zero unseenSince is the drawing state).
__private_extern__ void hsFramePresented(HSVisibility *v, bool shown, double now);
// Whether to draw a frame at time now.
__private_extern__ bool hsShouldDraw(HSVisibility *v, double now, double unseenLimit, double probeInterval);

#endif
