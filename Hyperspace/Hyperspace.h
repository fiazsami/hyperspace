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
// refreshInterval seconds: every n-th refresh, the largest n that draws at
// least minPerSecond frames a second less 0.5%, so every frame stays on screen
// the same number of refreshes. 144 Hz at 60 gives 1/72; 120 Hz 1/60; a
// display at or under minPerSecond, every refresh. The 0.5% is for rates
// reported a hair under a whole one: 119.88 Hz draws 59.94, not 119.88.
// refreshInterval and minPerSecond must be > 0.
__private_extern__ double hsFrameInterval(double refreshInterval, double minPerSecond);
// Whether a call at time now draws a frame, on a schedule of one frame each
// interval: true when now is no more than slack before *nextDue, or *nextDue
// is 0 (nothing drawn yet). On true, *nextDue becomes the next frame's time:
// an interval after this one was due, so the average rate holds whatever the
// caller's cadence -- or, after a stall of more than an interval, an interval
// from now. Frames are evenly spaced only if the calls come on the refreshes;
// from calls at another cadence (105 a second on 144 Hz) they are spaced 1
// and 2 calls apart by turns, which nothing that only filters calls can fix.
__private_extern__ bool hsFrameDue(double now, double *nextDue, double interval, double slack);
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
