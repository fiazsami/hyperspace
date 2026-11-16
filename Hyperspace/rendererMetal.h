/*
 * HSRenderer on Metal, drawing with the shaders in metal/.
 *
 * Not every draw is here yet: frames, fog, textures, quads, the overlay, the
 * shaded goo and sphere, and the offscreen target are; the tunnel is not, nor
 * the shaders-off goo (ss-5dl), and calling them stops the process with a
 * message saying so. parity/backendcheck.sh judges
 * this backend against HSRendererGL on the passes it can draw.
 */

#ifndef HYPERSPACE_RENDERER_METAL_H
#define HYPERSPACE_RENDERER_METAL_H

#include <Hyperspace/renderer.h>

struct HSRendererMetalState;

class HSRendererMetal : public HSRenderer{
public:
	// metalDir holds Interface.metal and the pass files, compiled at creation;
	// device is an id<MTLDevice>. A missing file or a compile error stops the
	// process with the compiler's message.
	HSRendererMetal(void *device, const char *metalDir);
	~HSRendererMetal();

	// Frames draw into target, an id<MTLTexture> of a renderable format, until
	// the next call, which must come between frames. endFrame waits for the
	// GPU to finish the frame, and stops the process if the GPU failed it.
	void setTarget(void *target);
	// Draws issued since the last beginFrame.
	int drawCount() const;
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
