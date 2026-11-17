/*
 * HSRenderer on Metal, drawing with the shaders in metal/.
 *
 * It draws the shaded look only: the shaders-off goo and tunnel are ss-5dl,
 * and asking for them throws HSRendererMetalError saying so.
 * parity/backendcheck.sh judges this backend against HSRendererGL.
 */

#ifndef HYPERSPACE_RENDERER_METAL_H
#define HYPERSPACE_RENDERER_METAL_H

#include <Hyperspace/renderer.h>
#include <stdexcept>
#include <string>

struct HSRendererMetalState;

// What every failure in this backend throws: a missing or uncompilable shader
// source, a GPU failure on a frame that is read back, or a call out of order.
// A saver catches it and stops drawing; parity leaves it uncaught, so the
// process ends with the message, which is also printed to stderr.
class HSRendererMetalError : public std::runtime_error{
public:
	explicit HSRendererMetalError(const std::string &what) : std::runtime_error(what) {}
};

class HSRendererMetal : public HSRenderer{
public:
	// metalDir holds Interface.metal and the pass files, compiled at creation;
	// device is an id<MTLDevice>. A missing file or a compile error throws
	// HSRendererMetalError with the compiler's message.
	HSRendererMetal(void *device, const char *metalDir);
	~HSRendererMetal();

	// Frames draw into target, an id<MTLTexture> of a renderable format, until
	// the next call, which must come between frames. endFrame waits for the
	// GPU to finish the frame, so the texture can be read back, and throws if
	// the GPU failed it.
	void setTarget(void *target);
	// The next frame draws into drawable, an id<CAMetalDrawable>, and endFrame
	// presents it without waiting for the GPU; a frame the GPU fails is logged
	// and skipped. Call it before every beginFrame: a drawable is one frame's.
	void setDrawable(void *drawable);
	// Draws issued since the last beginFrame: all of them, and the goo
	// surfaces and tunnel strips among them.
	int drawCount() const;
	int gooDrawCount() const;
	int tunnelDrawCount() const;
	// Whether the goo's field is drawn soft: into a target half the frame's
	// width and height, then added over the frame blurred by a 3x3 tent
	// (metal/Soften.metal). On from creation, which is the saver's look; parity
	// turns it off to judge the goo against GL, which draws it sharp. The
	// starburst's sphere, drawn in the goo's look, is never softened. Between
	// frames only, like setTarget. A frame whose soft target cannot be
	// allocated draws the goo sharp.
	void setSoftGoo(bool soft);
	// The id<MTLTexture> a create* call returned name for, or NULL.
	void *texture(unsigned int name) const;

	void beginFrame(const HSFrame &frame);
	void endFrame();
	void setFog(bool on);
	unsigned int createTexture(int width, int height, const unsigned char *rgba);
	unsigned int createMipmappedTexture(const HSMipChain &chain);
	unsigned int createCubeTexture(const HSMipChain faces[6]);
	void beginOffscreen(int size);
	void drawColorStrip(const HSColorVertex *v, int count);
	void endOffscreen(unsigned char *rgb);
	void drawQuad(unsigned int texture, const float color[4], const float model[16], float half);
	void beginOverlay(float aspect);
	void endOverlay();
	void beginGoo(const float color[4], unsigned int nebula,
		unsigned int normals0, unsigned int normals1, bool shaded);
	void drawGooSurface(impSurface *surface, const float offset[3]);
	// The goo is built here, on the GPU (metal/GooBuild.metal).
	bool buildsGoo() const;
	void drawGooField(const HSGooField &field);
	void drawGooSphere(const float center[3], float radius);
	void endGoo();
	void beginTunnel(unsigned int caustic0, unsigned int caustic1, float lerp, bool shaded);
	void drawTunnelStrip(const HSTunnelVertex *v, int count);
	void endTunnel();

private:
	HSRendererMetalState *st;
	HSRendererMetal(const HSRendererMetal &);
	HSRendererMetal &operator=(const HSRendererMetal &);
};

#endif
