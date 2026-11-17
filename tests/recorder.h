/* A recording HSRenderer for tests: it keeps what the code under test asked to
 * draw or create, in order, instead of drawing it. Header-only, so each test
 * file that needs one includes it; the class is identical in every unit. */

#ifndef HYPERSPACE_TESTS_RECORDER_H
#define HYPERSPACE_TESTS_RECORDER_H

#include "Hyperspace/renderer.h"

#include <string.h>
#include <vector>

struct Strip {
    unsigned int texture;
    float color[4];
    std::vector<HSVertex> v;
    bool overlay;
};

struct GooDraw {
    impSurface *surface;
    float offset[3];
};

struct GooSphere {
    float center[3];
    float radius;
};

struct GooBegin {
    float color[4];
    unsigned int nebula, normals0, normals1;
    bool shaded;
};

struct Offscreen {
    int size;
    std::vector<std::vector<HSColorVertex> > strips;
};

class Recorder : public HSRenderer {
public:
    std::vector<Strip> strips;
    std::vector<int> textureSizes;
    std::vector<HSMipChain> mipmapped;
    std::vector<std::vector<HSMipChain> > cubes;
    std::vector<Offscreen> offscreens;
    int overlays = 0;
    bool inOverlay = false;
    bool inOffscreen = false;
    float aspect = 0.0f;
    unsigned int nextName = 100;
    std::vector<GooDraw> goo;
    bool gooOnGPU = false;              // what buildsGoo answers
    std::vector<HSGooField> gooFields;  // drawGooField's, when it does
    std::vector<GooSphere> spheres;
    std::vector<GooBegin> gooBegins;
    int gooEnds = 0;
    std::vector<std::vector<HSTunnelVertex> > tunnel;
    bool starsOnGPU = false;                 // what drawsStars answers
    std::vector<HSStarField> starFields;     // drawStarField's, when it does
    bool tunnelOnGPU = false;                // what buildsTunnel answers
    int detail = 1;                          // what tunnelDetail answers
    std::vector<HSTunnelField> tunnelFields; // drawTunnelField's, when it does

    void beginFrame(const HSFrame &) override {}
    void endFrame() override {}
    void setFog(bool) override {}
    unsigned int createTexture(int width, int height, const unsigned char *) override
    {
        textureSizes.push_back(width * 1000 + height);
        return ++nextName;
    }
    unsigned int createMipmappedTexture(const HSMipChain &chain) override
    {
        mipmapped.push_back(chain);
        return ++nextName;
    }
    unsigned int createCubeTexture(const HSMipChain faces[6]) override
    {
        cubes.push_back(std::vector<HSMipChain>(faces, faces + 6));
        return ++nextName;
    }
    void beginOffscreen(int size) override
    {
        Offscreen o;
        o.size = size;
        offscreens.push_back(o);
        inOffscreen = true;
    }
    void drawColorStrip(const HSColorVertex *v, int count) override
    {
        offscreens.back().strips.push_back(std::vector<HSColorVertex>(v, v + count));
    }
    /* Reads back a pattern that names the target: byte i of target n is
     * (i + n) % 251, so a test can tell which readback became which texture. */
    void endOffscreen(unsigned char *rgb) override
    {
        int n = int(offscreens.size()) - 1, size = offscreens.back().size;
        for (int i = 0; i < size * size * 3; i++) rgb[i] = (unsigned char)((i + n) % 251);
        inOffscreen = false;
    }
    /* Records the corners drawQuad's contract says it draws. */
    void drawQuad(unsigned int texture, const float color[4], const float model[16], float half) override
    {
        HSVertex v[4];
        hsQuad(model, half, v);
        Strip s;
        s.texture = texture;
        memcpy(s.color, color, sizeof s.color);
        s.v.assign(v, v + 4);
        s.overlay = inOverlay;
        strips.push_back(s);
    }
    bool drawsStars() const override { return starsOnGPU; }
    void drawStarField(const HSStarField &field) override { starFields.push_back(field); }
    void beginOverlay(float a) override { inOverlay = true; aspect = a; overlays++; }
    void endOverlay() override { inOverlay = false; }
    void beginGoo(const float color[4], unsigned int nebula, unsigned int normals0,
                  unsigned int normals1, bool shaded) override
    {
        GooBegin b;
        memcpy(b.color, color, sizeof b.color);
        b.nebula = nebula; b.normals0 = normals0; b.normals1 = normals1; b.shaded = shaded;
        gooBegins.push_back(b);
    }
    void drawGooSurface(impSurface *surface, const float offset[3]) override
    {
        GooDraw d;
        d.surface = surface;
        memcpy(d.offset, offset, sizeof d.offset);
        goo.push_back(d);
    }
    bool buildsGoo() const override { return gooOnGPU; }
    void drawGooField(const HSGooField &field) override { gooFields.push_back(field); }
    void drawGooSphere(const float center[3], float radius) override
    {
        GooSphere d;
        memcpy(d.center, center, sizeof d.center);
        d.radius = radius;
        spheres.push_back(d);
    }
    void endGoo() override { gooEnds++; }
    /* The tunnel leaves its begin and end calls to Hyperspace's draw(), so
     * only what it draws in between is recorded. */
    void beginTunnel(unsigned int, unsigned int, float, bool) override {}
    void drawTunnelStrip(const HSTunnelVertex *v, int count) override
    {
        tunnel.push_back(std::vector<HSTunnelVertex>(v, v + count));
    }
    bool buildsTunnel() const override { return tunnelOnGPU; }
    int tunnelDetail() const override { return detail; }
    void drawTunnelField(const HSTunnelField &field) override { tunnelFields.push_back(field); }
    void endTunnel() override {}
};

#endif
