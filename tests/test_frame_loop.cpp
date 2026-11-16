/* Tests for Hyperspace.cpp, the frame loop: setDefaults, reshape, initSaver,
 * draw and cleanUp, driven through a recording renderer.
 *
 * initSaver seeds rand() with time(NULL); this file defines time(), as
 * parity/parity.mm does, so the seed -- the path, the stars, the bursts -- is
 * the same on every run, and so are coverage and the kill-check.
 *
 * draw() keeps the camera's heading and roll, the animation clock and the
 * starburst timer in function statics that outlive each case. So nothing here
 * asserts on where the camera happens to be: frames run with frameTime 0
 * where a value must hold still, ranges are checked where initSaver draws at
 * random, and the animation clock is measured as progress between two frames
 * rather than from a known start.
 */

#include "harness.h"
#include "recorder.h"

#include "Hyperspace/renderer.h"
#include "Hyperspace/transform.h"
#include "Hyperspace/splinePath.h"
#include "Hyperspace/stretchedParticle.h"
#include "Hyperspace/starBurst.h"
#include "Hyperspace/causticTextures.h"
#include "Hyperspace/wavyNormalCubeMaps.h"
#include "Hyperspace/Hyperspace.h"

#include <algorithm>
#include <math.h>
#include <string>
#include <stdlib.h>
#include <string.h>
#include <time.h>

// Binds initSaver's srand(time(NULL)) here: nothing else in the suite reads the clock.
extern "C" time_t time(time_t *t) { if (t) *t = 20261116; return 20261116; }

void setDefaults(HyperspaceSaverSettings *inSettings);
void initSaver(HyperspaceSaverSettings *inSettings, HSRenderer *renderer);
void cleanUp(HyperspaceSaverSettings *inSettings);

// Defined in nebulamap.h, which only Hyperspace.cpp may include: it is a definition.
extern unsigned char nebulamap[256][256][3];

namespace {
const double kTol = 1e-5;

/* Also keeps what the plain Recorder drops: each frame's setup, the fog
 * switches and the tunnel's textures. Counts its own deletion, because
 * cleanUp owns the renderer it was given. */
struct FrameRecorder : Recorder {
    struct TunnelBegin { unsigned int caustic0, caustic1; float lerp; bool shaded; };
    std::vector<HSFrame> frames;
    std::vector<bool> fog;
    std::vector<TunnelBegin> tunnelBegins;
    /* Every frame, fog, bracket and draw call in order, one letter each:
     *   B/E frame begin/end    f/F fog off/on        o offscreen begin
     *   v/w overlay begin/end  g/h goo begin/end     t/u tunnel begin/end
     *   S quad (star, sun)     O overlay quad (flare)
     *   G goo surface          P burst sphere        T tunnel strip
     * Never cleared, unlike the vectors above. */
    std::string events;
    int *deletions = nullptr;
    ~FrameRecorder() override { if (deletions) ++*deletions; }
    void beginFrame(const HSFrame &f) override { frames.push_back(f); events += 'B'; }
    void endFrame() override { events += 'E'; }
    void setFog(bool on) override { fog.push_back(on); events += on ? 'F' : 'f'; }
    void beginOffscreen(int size) override { Recorder::beginOffscreen(size); events += 'o'; }
    void beginOverlay(float a) override { Recorder::beginOverlay(a); events += 'v'; }
    void endOverlay() override { Recorder::endOverlay(); events += 'w'; }
    void beginGoo(const float color[4], unsigned int nebula, unsigned int n0, unsigned int n1, bool shaded) override
    {
        Recorder::beginGoo(color, nebula, n0, n1, shaded);
        events += 'g';
    }
    void endGoo() override { Recorder::endGoo(); events += 'h'; }
    void endTunnel() override { events += 'u'; }
    void drawQuad(unsigned int t, const float c[4], const float m[16], float half) override
    {
        Recorder::drawQuad(t, c, m, half);
        events += inOverlay ? 'O' : 'S';
    }
    void drawGooSurface(impSurface *surface, const float offset[3]) override
    {
        Recorder::drawGooSurface(surface, offset);
        events += 'G';
    }
    void drawGooSphere(const float center[3], float radius) override
    {
        Recorder::drawGooSphere(center, radius);
        events += 'P';
    }
    void drawTunnelStrip(const HSTunnelVertex *v, int count) override
    {
        Recorder::drawTunnelStrip(v, count);
        events += 'T';
    }
    void beginTunnel(unsigned int c0, unsigned int c1, float lerp, bool shaded) override
    {
        TunnelBegin b = {c0, c1, lerp, shaded};
        tunnelBegins.push_back(b);
        events += 't';
    }
};

/* The shipped defaults, shrunk where they only cost time: a handful of stars
 * and the smallest goo and path. Cases ask for tunnels only when they need
 * them: the first frame with tunnels renders 20 frames of caustics, about
 * 150 ms each time, which is most of this file's run time. */
HyperspaceSaverSettings *started(FrameRecorder *r, bool goo, bool tunnels, bool shaders)
{
    HyperspaceSaverSettings *s = new HyperspaceSaverSettings;
    memset(s, 0, sizeof *s);
    setDefaults(s);
    s->dStars = 8;
    s->dDepth = 1;
    s->dResolution = 4;
    s->dUseGoo = goo;
    s->dUseTunnels = tunnels;
    s->dShaders = shaders;
    s->first = 1;
    reshape(400, 200, s);
    // Unshaded, initSaver darkens the global nebula in place, again on every
    // start (ss-568); put it back so every case starts from the shipped image.
    static unsigned char shipped[256][256][3];
    memcpy(shipped, nebulamap, sizeof shipped);
    initSaver(s, r);
    memcpy(nebulamap, shipped, sizeof shipped);
    srand(11);
    // cleanUp never frees the stars, the sun or the starburst (ss-t6q), so each
    // case leaks them; freeing them here would double-free once that is fixed.
    return s;
}

void frame(HyperspaceSaverSettings *s, float seconds)
{
    s->frameTime = seconds;
    draw(s);
}
}

TEST(setDefaults_picks_the_shipped_settings)
{
    HyperspaceSaverSettings s;
    memset(&s, 0, sizeof s);
    setDefaults(&s);
    CHECK(s.dSpeed == 10);
    CHECK(s.dStars == 2000);
    CHECK(s.dStarSize == 10);
    CHECK(s.dResolution == 10);
    CHECK(s.dDepth == 5);
    CHECK(s.dFov == 50);
    CHECK(s.dUseTunnels);
    CHECK(s.dUseGoo);
    CHECK(s.dShaders);   // the Metal saver is shaded only (ss-5dl)
}

TEST(reshape_fits_viewport_aspect_and_projection_to_the_window)
{
    HyperspaceSaverSettings s;
    memset(&s, 0, sizeof s);
    s.dFov = 50;
    reshape(400, 200, &s);
    CHECK(s.xsize == 400 && s.ysize == 200);
    CHECK_NEAR(s.aspectRatio, 2.0, kTol);
    CHECK(s.viewport[0] == 0 && s.viewport[1] == 0);
    CHECK(s.viewport[2] == 400 && s.viewport[3] == 200);
    float p[16];
    hsPerspective(p, 50.0f, 2.0f, 0.001f, 200.0f);
    for (int i = 0; i < 16; i++) CHECK_NEAR(s.projMat[i], p[i], kTol);
}

TEST(initSaver_without_a_renderer_starts_nothing_and_cleanUp_frees_nothing)
{
    HyperspaceSaverSettings s;
    memset(&s, 0, sizeof s);
    setDefaults(&s);
    s.readyToDraw = 1;
    s.first = 1;
    initSaver(&s, NULL);
    CHECK(!s.readyToDraw);
    CHECK(s.renderer == NULL);
    CHECK(s.thePath == NULL && s.stars == NULL && s.theGoo == NULL);
    cleanUp(&s);   // nothing was built, so nothing may be deleted
    CHECK(s.renderer == NULL);
}

TEST(initSaver_builds_the_scene_the_settings_ask_for)
{
    FrameRecorder *r = new FrameRecorder;
    HyperspaceSaverSettings *s = started(r, true, true, true);
    CHECK(s->readyToDraw);
    CHECK(s->renderer == r);
    // fog ends one goo cubelet short of the goo grid, so the goo never pops in
    CHECK_NEAR(s->depth, 1 * 2.0 - 2.0 / 4, kTol);
    CHECK(s->thePath != NULL && s->thePath->numPoints == 1 * 2 + 6);
    CHECK(s->theTunnel != NULL);
    CHECK(s->theGoo != NULL);
    CHECK(s->stars != NULL);
    for (int i = 0; i < s->dStars; i++) {
        stretchedParticle *p = s->stars[i];
        CHECK(p->radius >= 10 * 0.0005f && p->radius <= 10 * 0.001f);
        CHECK(fabsf(p->pos[0]) <= s->depth && fabsf(p->pos[2]) <= s->depth);
        CHECK(fabsf(p->pos[1]) <= 2.0f);
        CHECK(p->color[0] == 1.0f || p->color[1] == 1.0f || p->color[2] == 1.0f);
        CHECK_NEAR(p->fov, 50.0, kTol);
    }
    CHECK_NEAR(s->sunStar->pos[0], 0.0, kTol);
    CHECK_NEAR(s->sunStar->pos[1], 2.0, kTol);
    CHECK_NEAR(s->sunStar->pos[2], 0.0, kTol);
    CHECK_NEAR(s->sunStar->radius, 10 * 0.004, kTol);
    for (int i = 0; i < SB_NUM_STARS; i++) {
        float radius = s->theStarBurst->stars[i]->radius;
        CHECK(radius >= 10 * 0.001f && radius <= 10 * 0.002f);
    }
    // shaded: the nebula is a cube map, the same image on every face
    CHECK(s->numAnimTexFrames == 20);
    CHECK(r->cubes.size() == 1 && r->mipmapped.empty());
    for (int f = 1; f < 6; f++) CHECK(r->cubes[0][f].levels == r->cubes[0][0].levels);
    CHECK(r->cubes[0][0].size == 256 && r->cubes[0][0].channels == 3);
    CHECK(r->cubes[0][0].levels[0] == std::vector<unsigned char>(&nebulamap[0][0][0], &nebulamap[0][0][0] + 256 * 256 * 3));
    CHECK(s->nebulatex == r->nextName);   // the last texture made
    cleanUp(s);
    delete s;
}

TEST(initSaver_leaves_out_the_goo_and_tunnel_when_they_are_off)
{
    FrameRecorder *r = new FrameRecorder;
    HyperspaceSaverSettings *s = started(r, false, false, true);
    CHECK(s->readyToDraw);
    CHECK(s->theGoo == NULL);
    CHECK(s->theTunnel == NULL);
    cleanUp(s);
    delete s;
}

TEST(initSaver_unshaded_darkens_the_nebula_toward_its_centre)
{
    static unsigned char saved[256][256][3];
    memcpy(saved, nebulamap, sizeof saved);
    FrameRecorder *r = new FrameRecorder;
    HyperspaceSaverSettings *s = started(r, false, false, false);
    CHECK(s->numAnimTexFrames == 60);
    CHECK(r->cubes.empty() && r->mipmapped.size() == 1);
    // A sphere map: each texel scaled by its squared distance from the
    // centre, squared twice, and left alone outside the unit circle.
    const std::vector<unsigned char> &level0 = r->mipmapped[0].levels[0];
    CHECK(level0.size() == 256 * 256 * 3);
    int wrong = 0;
    for (int i = 0; i < 256; i++)
        for (int j = 0; j < 256; j++) {
            float x = (i - 128) / 128.0f, y = (j - 128) / 128.0f;
            float t = x * x + y * y;
            if (t > 1.0f) t = 1.0f;
            t = t * t;
            t = t * t;
            // +-1: the truncation may round differently in another translation unit
            for (int c = 0; c < 3; c++)
                if (abs(int(level0[(i * 256 + j) * 3 + c]) - int((unsigned char)(float(saved[i][j][c]) * t))) > 1) wrong++;
        }
    CHECK(wrong == 0);
    CHECK(level0[(128 * 256 + 128) * 3] == 0);           // the centre goes black
    CHECK(level0[0] == saved[0][0][0]);                  // a corner keeps its colour
    cleanUp(s);
    delete s;
}

TEST(draw_makes_the_animated_textures_on_the_first_frame_only)
{
    FrameRecorder *r = new FrameRecorder;
    HyperspaceSaverSettings *s = started(r, true, true, true);
    CHECK(s->theCausticTextures == NULL && s->theWNCM == NULL);
    frame(s, 0.0f);
    CHECK(!s->first);
    CHECK(s->theCausticTextures != NULL);
    CHECK(s->theWNCM != NULL);
    causticTextures *caustics = s->theCausticTextures;
    wavyNormalCubeMaps *normals = s->theWNCM;
    size_t offscreens = r->offscreens.size(), cubes = r->cubes.size();
    CHECK(offscreens > 0);
    frame(s, 0.0f);
    CHECK(s->theCausticTextures == caustics && s->theWNCM == normals);
    CHECK(r->offscreens.size() == offscreens && r->cubes.size() == cubes);
    cleanUp(s);
    delete s;
}

TEST(draw_without_tunnels_or_shaders_makes_neither_texture_set)
{
    FrameRecorder *r = new FrameRecorder;
    HyperspaceSaverSettings *s = started(r, true, false, false);
    frame(s, 0.0f);
    CHECK(s->theCausticTextures == NULL);
    CHECK(s->theWNCM == NULL);
    CHECK(r->offscreens.empty());
    // unshaded goo: no normal maps, and alpha carries no blend
    CHECK(r->gooBegins.size() == 1);
    CHECK(!r->gooBegins[0].shaded);
    CHECK(r->gooBegins[0].normals0 == 0 && r->gooBegins[0].normals1 == 0);
    CHECK_NEAR(r->gooBegins[0].color[3], 1.0, kTol);
    CHECK(r->tunnelBegins.empty() && r->tunnel.empty());
    cleanUp(s);
    delete s;
}

TEST(draw_skips_the_goo_and_tunnel_when_they_are_off)
{
    FrameRecorder *r = new FrameRecorder;
    HyperspaceSaverSettings *s = started(r, false, false, false);
    frame(s, 0.0f);
    CHECK(r->frames.size() == 1);
    CHECK(r->gooBegins.empty() && r->gooEnds == 0 && r->goo.empty());
    CHECK(r->tunnelBegins.empty() && r->tunnel.empty());
    cleanUp(s);
    delete s;
}

TEST(draw_hands_the_renderer_one_frame_in_the_settings_view)
{
    FrameRecorder *r = new FrameRecorder;
    HyperspaceSaverSettings *s = started(r, true, false, false);
    frame(s, 0.0f);
    CHECK(r->frames.size() == 1);
    const HSFrame &f = r->frames[0];
    for (int i = 0; i < 4; i++) CHECK(f.viewport[i] == s->viewport[i]);
    for (int i = 0; i < 16; i++) {
        CHECK_NEAR(f.projection[i], s->projMat[i], kTol);
        CHECK_NEAR(f.view[i], s->modelMat[i], kTol);
    }
    CHECK_NEAR(f.fogStart, s->depth * 0.7, kTol);
    CHECK_NEAR(f.fogEnd, s->depth, kTol);
    // the view's eye sits at the camera: it carries -camPos through the rotation
    float origin[3];
    for (int i = 0; i < 3; i++)
        origin[i] = float(s->modelMat[0 * 4 + i] * s->camPos[0] + s->modelMat[1 * 4 + i] * s->camPos[1] +
                          s->modelMat[2 * 4 + i] * s->camPos[2] + s->modelMat[3 * 4 + i]);
    for (int i = 0; i < 3; i++) CHECK_NEAR(origin[i], 0.0, 1e-4);
    // billboards face the camera: their matrix undoes the view's rotation
    for (int row = 0; row < 3; row++)
        for (int col = 0; col < 3; col++) {
            double sum = 0;
            for (int k = 0; k < 3; k++) sum += s->billboardMat[k * 4 + row] * s->modelMat[col * 4 + k];
            CHECK_NEAR(sum, row == col ? 1.0 : 0.0, 1e-4);
        }
    // the sun and its flare are drawn unfogged, and fog is back on after
    CHECK(r->fog.size() == 2 && !r->fog[0] && r->fog[1]);
    cleanUp(s);
    delete s;
}

namespace {
/* Each draw letter sits inside its own bracket pair, and the pairs neither
 * nest nor go unclosed. */
bool bracketsBalanced(const std::string &e)
{
    char open = 0;
    for (char c : e) {
        if (c == 'v' || c == 'g' || c == 't') {
            if (open) return false;
            open = c;
        } else if (c == 'w' || c == 'h' || c == 'u') {
            if (open != (c == 'w' ? 'v' : c == 'h' ? 'g' : 't')) return false;
            open = 0;
        } else if (c == 'O' && open != 'v') return false;
        else if ((c == 'G' || c == 'P') && open != 'g') return false;
        else if (c == 'T' && open != 't') return false;
        else if (c == 'S' && open) return false;
    }
    return open == 0;
}

/* Counts a broken rule once per frame and keeps the first frame that broke
 * it, so a regression reports one line per rule, with the evidence. */
struct Rules {
    struct Rule { const char *name; int broken; std::string first; };
    std::vector<Rule> rules;
    void check(const char *name, bool ok, const std::string &frame)
    {
        for (Rule &r : rules)
            if (r.name == name) { if (!ok && !r.broken++) r.first = frame; return; }
        rules.push_back(Rule{name, ok ? 0 : 1, ok ? std::string() : frame});
    }
    bool clean() const
    {
        bool all = true;
        for (const Rule &r : rules)
            if (r.broken) {
                printf("  rule '%s' broken in %d frame(s), first: %s\n", r.name, r.broken, r.first.c_str());
                all = false;
            }
        return all;
    }
};
}

TEST(draw_brackets_every_on_screen_draw_inside_its_frame)
{
    FrameRecorder *r = new FrameRecorder;
    HyperspaceSaverSettings *s = started(r, true, true, false);
    Rules rules;
    bool flareSeen = false, burstSeen = false;
    // Frames until the flare has shown -- it draws only while the sun is in
    // view, which the first frame's is not -- then one with a burst forced.
    // Stopping early spends little of draw()'s shared clocks.
    for (int n = 0; n < 120 && !(flareSeen && burstSeen); n++) {
        if (flareSeen) {
            float ahead[3] = {s->camPos[0], 0.0f, s->camPos[2] - 0.5f * s->depth};
            s->theStarBurst->restart(ahead);
        }
        size_t start = r->events.size();
        frame(s, n == 0 ? 0.0f : 1.0f);
        std::string e = r->events.substr(start);
        // offscreen work (the first frame's caustics) comes before the frame
        size_t b = e.find('B');
        rules.check("offscreen work only before the frame", e.find('o', b) == std::string::npos, e);
        e = e.substr(b == std::string::npos ? 0 : b);
        size_t off = e.find('f'), on = e.find('F');
        bool shaped = std::count(e.begin(), e.end(), 'B') == 1 && e.back() == 'E' &&
                      std::count(e.begin(), e.end(), 'E') == 1 && std::count(e.begin(), e.end(), 'f') == 1 &&
                      std::count(e.begin(), e.end(), 'F') == 1 && off < on;
        rules.check("one frame; fog off once, then on once", shaped, e);
        rules.check("each draw inside its own bracket", bracketsBalanced(e), e);
        if (!shaped) continue;
        std::string fogged = e.substr(1, off - 1), unfogged = e.substr(off + 1, on - off - 1);
        // the stars, the goo, the tunnel and a burst -- sphere and flare -- draw fogged
        rules.check("stars fogged", fogged.find('S') != std::string::npos, e);
        rules.check("goo fogged", fogged.find('G') != std::string::npos, e);
        rules.check("tunnel fogged", fogged.find('T') != std::string::npos, e);
        // the sun and its flare draw unfogged, and nothing of the scene does
        rules.check("sun unfogged", unfogged.find('S') != std::string::npos, e);
        rules.check("no goo, burst or tunnel unfogged", unfogged.find_first_of("gGPtT") == std::string::npos, e);
        rules.check("nothing after fog is back on", e.substr(on + 1) == "E", e);
        if (unfogged.find('O') != std::string::npos) flareSeen = true;
        if (e.find('P') != std::string::npos) {
            burstSeen = true;
            rules.check("burst sphere fogged", fogged.find('P') != std::string::npos, e);
        }
    }
    CHECK(rules.clean());
    CHECK(flareSeen);
    CHECK(burstSeen);
    cleanUp(s);
    delete s;
}

TEST(draw_blends_this_animation_frame_with_the_next)
{
    FrameRecorder *r = new FrameRecorder;
    HyperspaceSaverSettings *s = started(r, true, true, true);
    frame(s, 0.0f);
    int n = s->numAnimTexFrames, w = s->whichTexture;
    CHECK(w >= 0 && w < n);
    CHECK(r->gooBegins.size() == 1 && r->gooEnds == 1 && !r->goo.empty());
    const GooBegin &g = r->gooBegins[0];
    CHECK(g.shaded);
    CHECK(g.nebula == s->nebulatex);
    CHECK(g.normals0 == s->theWNCM->texture[w]);
    CHECK(g.normals1 == s->theWNCM->texture[(w + 1) % n]);
    CHECK(g.color[3] >= 0.0f && g.color[3] <= 1.0f);
    for (int i = 0; i < 3; i++) CHECK(g.color[i] >= 0.0f && g.color[i] <= 1.0f);
    CHECK(r->tunnelBegins.size() == 1 && !r->tunnel.empty());
    const FrameRecorder::TunnelBegin &t = r->tunnelBegins[0];
    CHECK(t.shaded);
    CHECK(t.caustic0 == s->theCausticTextures->caustictex[w]);
    CHECK(t.caustic1 == s->theCausticTextures->caustictex[(w + 1) % n]);
    CHECK_NEAR(t.lerp, g.color[3], kTol);   // the goo's alpha is the same blend
    cleanUp(s);
    delete s;
}

TEST(draw_loops_the_animation_every_two_seconds)
{
    FrameRecorder *r = new FrameRecorder;
    HyperspaceSaverSettings *s = started(r, true, false, true);
    frame(s, 0.0f);
    int n = s->numAnimTexFrames;
    int w0 = s->whichTexture;
    float lerp0 = r->gooBegins.back().color[3];
    // Progress is measured in frames, whole plus blend, so it does not matter
    // where the clock stood: 0.25 s is two and a half frames.
    frame(s, 0.25f);
    int w1 = s->whichTexture;
    float lerp1 = r->gooBegins.back().color[3];
    CHECK(w1 >= 0 && w1 < n);
    CHECK_NEAR(((w1 - w0 + n) % n) + lerp1 - lerp0, 2.5, 1e-3);
    // and 2.25 s is a full loop more: the same two and a half
    frame(s, 2.25f);
    int w2 = s->whichTexture;
    float lerp2 = r->gooBegins.back().color[3];
    CHECK(w2 >= 0 && w2 < n);
    CHECK_NEAR(((w2 - w1 + n) % n) + lerp2 - lerp1, 2.5, 1e-3);
    CHECK(r->gooBegins.back().normals0 == s->theWNCM->texture[w2]);
    cleanUp(s);
    delete s;
}

TEST(draw_wraps_a_star_that_leaves_the_fogged_box_to_the_far_side)
{
    FrameRecorder *r = new FrameRecorder;
    HyperspaceSaverSettings *s = started(r, false, false, false);
    frame(s, 0.0f);   // with no time passing the camera holds still
    float cam[3] = {s->camPos[0], s->camPos[1], s->camPos[2]};
    float d = s->depth;
    stretchedParticle *p = s->stars[0];
    float behind[3] = {cam[0] + 1.5f * d, 0.5f, cam[2] - 1.5f * d};
    memcpy(p->pos, behind, sizeof behind);
    memcpy(p->lastPos, behind, sizeof behind);
    stretchedParticle *o = s->stars[1];
    float before[3] = {cam[0] - 1.5f * d, 0.25f, cam[2] + 1.5f * d};
    memcpy(o->pos, before, sizeof before);
    memcpy(o->lastPos, before, sizeof before);
    stretchedParticle *q = s->stars[2];
    float inside[3] = {cam[0] + 0.5f * d, -0.5f, cam[2] - 0.5f * d};
    memcpy(q->pos, inside, sizeof inside);
    frame(s, 0.0f);
    for (int i = 0; i < 3; i++) CHECK_NEAR(s->camPos[i], cam[i], kTol);
    CHECK_NEAR(p->pos[0], cam[0] - 0.5f * d, 1e-4);
    CHECK_NEAR(p->pos[2], cam[2] + 0.5f * d, 1e-4);
    CHECK_NEAR(p->pos[1], 0.5, kTol);   // height is never wrapped
    CHECK_NEAR(o->pos[0], cam[0] + 0.5f * d, 1e-4);
    CHECK_NEAR(o->pos[2], cam[2] - 0.5f * d, 1e-4);
    // lastPos moves with it, so the streak does not cross the box; not checked
    // here, because drawing the star then overwrites lastPos with pos.
    for (int i = 0; i < 3; i++) CHECK_NEAR(q->pos[i], inside[i], kTol);
    cleanUp(s);
    delete s;
}

TEST(draw_bursts_ahead_of_the_camera_within_five_minutes_and_again_within_one_to_five)
{
    FrameRecorder *r = new FrameRecorder;
    HyperspaceSaverSettings *s = started(r, false, false, false);
    // The first burst is due 300 s into the run -- the timer is a function
    // static, so earlier cases may have spent some of it -- and each later one
    // 60 to 300 s after the last. A burst starts a run of frames that draw its
    // sphere, a few seconds long; its stars, at 0.25 units/s or more, have left
    // the fog box before the next is due -- provided they outrun the camera,
    // which moves at about dSpeed * 0.04 = 0.4 units/s. A star that keeps pace
    // stays active and restart() refuses, which would stretch a gap past 300
    // s for reasons of its own; so every star here moves at 1 unit/s, keeping
    // its random direction, and clears the box within seconds.
    // Forty gaps, because one random gap says little about the range.
    for (int i = 0; i < SB_NUM_STARS; i++) {
        float *v = s->theStarBurst->stars_velocity[i];
        float length = sqrtf(v[0] * v[0] + v[1] * v[1] + v[2] * v[2]);
        for (int c = 0; c < 3; c++) v[c] /= length;
    }
    const int wanted = 41;
    struct Burst { int second; float offset[2], dir[3], height; } bursts[wanted];
    int found = 0;
    bool drawing = false;
    for (int second = 1; second <= 300 * wanted && found < wanted; second++) {
        size_t before = r->spheres.size();
        frame(s, 1.0f);
        bool drew = r->spheres.size() > before;
        if (drew && !drawing) {
            Burst &b = bursts[found++];
            const float *c = r->spheres[before].center;
            b.second = second;
            s->thePath->getBaseDirection(s->dDepth + 2, s->thePath->step, b.dir);
            b.offset[0] = c[0] - s->camPos[0];
            b.offset[1] = c[2] - s->camPos[2];
            b.height = c[1];
        }
        drawing = drew;
        r->spheres.clear();
        r->strips.clear();
    }
    CHECK(found == wanted);
    CHECK(bursts[0].second >= 1 && bursts[0].second <= 300);
    for (int i = 1; i < found; i++) {
        int gap = bursts[i].second - bursts[i - 1].second;
        CHECK(gap >= 60 && gap <= 300);
    }
    // Aimed ahead along the path, 0.5 to 1 fog depths on each axis -- each
    // scaled by its own random factor, so not on the path's line -- at a
    // random height between -1 and 1.
    for (int i = 0; i < found; i++) {
        const Burst &b = bursts[i];
        for (int a = 0; a < 2; a++) {
            float along = b.dir[a * 2] * s->depth;
            CHECK(b.offset[a] * along >= 0.0f);
            CHECK(fabsf(b.offset[a]) >= 0.5f * fabsf(along) - 1e-4f && fabsf(b.offset[a]) <= fabsf(along) + 1e-4f);
        }
        CHECK(fabsf(b.dir[0]) + fabsf(b.dir[2]) > 0.1f);   // or the checks above hold trivially
        CHECK(b.height >= -1.0f && b.height <= 1.0f);
    }
    cleanUp(s);
    delete s;
}

TEST(draw_clamps_the_goo_colour_at_zero_through_its_cycle)
{
    FrameRecorder *r = new FrameRecorder;
    HyperspaceSaverSettings *s = started(r, true, false, false);
    // Each channel is a sine at 0.02 to 0.04 rad/s, clamped at zero, so 400 s
    // takes every channel through its negative half. What this pins is the
    // clamp: channels reach exactly 0 and never go below. The phase wrap at
    // 2 pi runs too, but sine is periodic, so nothing here can see it.
    int clamped[3] = {0, 0, 0};
    for (int second = 1; second <= 400; second++) {
        r->gooBegins.clear();
        frame(s, 1.0f);
        CHECK(!r->gooBegins.empty());   // the goo's, then a burst's sphere when one shows
        for (int c = 0; c < 3; c++) {
            float v = r->gooBegins[0].color[c];
            CHECK(v >= 0.0f && v <= 1.0f);
            if (v == 0.0f) clamped[c]++;
        }
    }
    for (int c = 0; c < 3; c++) CHECK(clamped[c] > 0);
    cleanUp(s);
    delete s;
}

TEST(cleanUp_frees_the_run_once_and_leaves_it_ready_to_restart)
{
    int deletions = 0;
    FrameRecorder *r = new FrameRecorder;
    r->deletions = &deletions;
    HyperspaceSaverSettings *s = started(r, true, true, true);
    frame(s, 0.0f);
    cleanUp(s);
    CHECK(deletions == 1);
    CHECK(s->renderer == NULL);
    CHECK(s->theCausticTextures == NULL && s->theWNCM == NULL);
    CHECK(s->first);   // the next run makes its textures again
    cleanUp(s);
    CHECK(deletions == 1);
    delete s;
}
