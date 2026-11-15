/* Tests for the code that draws through HSRenderer: the stars, the lens flare,
 * and the geometry helpers they share.
 *
 * A recording renderer stands in for GL, so each case asserts on the strips the
 * code would hand to a backend: how many, with which texture and color, and
 * where their corners are. The expected geometry is what the GL matrix stack
 * produced from the calls this code used to make.
 */

#include "harness.h"

#include "Hyperspace/renderer.h"
#include "Hyperspace/transform.h"
#include "Hyperspace/stretchedParticle.h"
#include "Hyperspace/flare.h"

#include <math.h>
#include <stdlib.h>
#include <string.h>
#include <vector>

namespace {
const double kTol = 1e-5;

struct Strip {
    unsigned int texture;
    float color[4];
    std::vector<HSVertex> v;
    bool overlay;
};

class Recorder : public HSRenderer {
public:
    std::vector<Strip> strips;
    std::vector<int> textureSizes;
    int overlays = 0;
    bool inOverlay = false;
    float aspect = 0.0f;

    unsigned int createTexture(int width, int height, const unsigned char *) override
    {
        textureSizes.push_back(width * 1000 + height);
        return 100 + (unsigned int)textureSizes.size();
    }
    void drawStrip(unsigned int texture, const float color[4], const HSVertex *v, int count) override
    {
        Strip s;
        s.texture = texture;
        memcpy(s.color, color, sizeof s.color);
        s.v.assign(v, v + count);
        s.overlay = inOverlay;
        strips.push_back(s);
    }
    void beginOverlay(float a) override { inOverlay = true; aspect = a; overlays++; }
    void endOverlay() override { inOverlay = false; }
};

/* A camera at the origin looking down -z: identity view, a 90-degree
 * perspective, a 200x100 viewport. */
void camera(double model[16], double proj[16], int viewport[4])
{
    float p[16];
    hsPerspective(p, 90.0, 2.0, 0.1, 100.0);
    for (int i = 0; i < 16; i++) {
        model[i] = (i % 5 == 0) ? 1.0 : 0.0;
        proj[i] = p[i];
    }
    viewport[0] = 0; viewport[1] = 0; viewport[2] = 200; viewport[3] = 100;
}

HyperspaceSaverSettings *settingsFor(Recorder *r)
{
    HyperspaceSaverSettings *s = new HyperspaceSaverSettings;
    memset(s, 0, sizeof *s);
    s->renderer = r;
    s->xsize = 200; s->ysize = 100; s->aspectRatio = 2.0f;
    camera(s->modelMat, s->projMat, s->viewport);
    hsIdentity(s->billboardMat);
    s->frameTime = 0.0f;   // keeps the flicker where it is
    return s;
}
}

TEST(renderer_apply_places_a_point_like_the_gl_stack)
{
    float m[16], p[3];
    hsIdentity(m);
    hsTranslate(m, 1, 2, 3);
    hsRotate(m, 90, 0, 0, 1);
    hsScale(m, 2, 1, 1);
    hsApply(m, 1, 0, 0, p);                 /* scaled to x=2, turned to +y, moved */
    CHECK_NEAR(p[0], 1.0, kTol); CHECK_NEAR(p[1], 4.0, kTol); CHECK_NEAR(p[2], 3.0, kTol);
}

TEST(renderer_quad_is_the_unit_square_in_strip_order)
{
    float m[16];
    HSVertex q[4];
    hsIdentity(m);
    hsTranslate(m, 10, 20, 30);
    hsQuad(m, 0.5f, q);
    const float x[4] = {-0.5f, 0.5f, -0.5f, 0.5f}, y[4] = {-0.5f, -0.5f, 0.5f, 0.5f};
    const float u[4] = {0, 1, 0, 1}, v[4] = {0, 0, 1, 1};
    for (int i = 0; i < 4; i++) {
        CHECK_NEAR(q[i].pos[0], 10 + x[i], kTol);
        CHECK_NEAR(q[i].pos[1], 20 + y[i], kTol);
        CHECK_NEAR(q[i].pos[2], 30.0, kTol);
        CHECK(q[i].uv[0] == u[i]);
        CHECK(q[i].uv[1] == v[i]);
    }
}

TEST(renderer_star_draws_an_aura_and_a_white_core_facing_the_eye)
{
    Recorder r;
    double model[16], proj[16];
    int viewport[4];
    camera(model, proj, viewport);
    float eye[3] = {0, 0, 0};

    stretchedParticle star;
    star.radius = 0.1f;
    star.color[0] = 0.2f; star.color[1] = 0.4f; star.color[2] = 0.6f;
    star.pos[0] = star.lastPos[0] = 0;
    star.pos[1] = star.lastPos[1] = 0;
    star.pos[2] = star.lastPos[2] = -5;
    star.draw(&r, 7, eye, 0.0f, model, proj, viewport);   /* projects: sets screenPos */
    r.strips.clear();
    star.draw(&r, 7, eye, 0.0f, model, proj, viewport);   /* still: no stretch */

    CHECK(r.strips.size() == 2);
    for (size_t i = 0; i < r.strips.size(); i++) {
        CHECK(r.strips[i].texture == 7);
        CHECK(r.strips[i].v.size() == 4);
        CHECK(r.strips[i].color[3] == 1.0f);
    }
    CHECK_NEAR(r.strips[0].color[0], 0.2, kTol);
    CHECK_NEAR(r.strips[0].color[1], 0.4, kTol);
    CHECK_NEAR(r.strips[0].color[2], 0.6, kTol);
    for (int c = 0; c < 3; c++) CHECK_NEAR(r.strips[1].color[c], 1.0, kTol);

    /* Straight ahead the billboard basis is the identity, so the quad lies in
     * z = -5, u along +x, half-size radius for the aura and 0.3 radius for
     * the core. */
    const HSVertex *aura = r.strips[0].v.data(), *core = r.strips[1].v.data();
    for (int i = 0; i < 4; i++) {
        CHECK_NEAR(aura[i].pos[2], -5.0, kTol);
        CHECK_NEAR(core[i].pos[2], -5.0, kTol);
    }
    CHECK_NEAR(aura[0].pos[0], -0.1, kTol); CHECK_NEAR(aura[0].pos[1], -0.1, kTol);
    CHECK_NEAR(aura[3].pos[0],  0.1, kTol); CHECK_NEAR(aura[3].pos[1],  0.1, kTol);
    CHECK_NEAR(core[3].pos[0],  0.03, kTol); CHECK_NEAR(core[3].pos[1], 0.03, kTol);
}

TEST(renderer_star_stretches_and_darkens_along_its_screen_motion)
{
    Recorder r;
    double model[16], proj[16];
    int viewport[4];
    camera(model, proj, viewport);
    float eye[3] = {0, 0, 0};

    stretchedParticle star;
    star.radius = 0.01f;
    star.pos[0] = star.lastPos[0] = 0; star.pos[1] = star.lastPos[1] = 0; star.pos[2] = star.lastPos[2] = -1;
    star.draw(&r, 1, eye, 0.0f, model, proj, viewport);
    star.pos[0] = 5.0f;                         /* moves 250 pixels right */
    r.strips.clear();
    star.draw(&r, 1, eye, 0.0f, model, proj, viewport);

    CHECK(r.strips.size() == 2);
    const HSVertex *aura = r.strips[0].v.data();
    float w = 0, h = 0;
    for (int c = 0; c < 3; c++) {
        w += (aura[1].pos[c] - aura[0].pos[c]) * (aura[1].pos[c] - aura[0].pos[c]);
        h += (aura[2].pos[c] - aura[0].pos[c]) * (aura[2].pos[c] - aura[0].pos[c]);
    }
    /* Clamped at 0.5 / radius = 50: longer along the motion by exactly that. */
    CHECK_NEAR(sqrtf(w / h), 50.0, 1e-3);
    /* darkener = 0.3 * stretch = 15 */
    CHECK_NEAR(r.strips[0].color[0], 1.0 / 15.0, kTol);
    CHECK_NEAR(r.strips[1].color[0], 1.0 / 15.0, kTol);
}

TEST(renderer_star_keeps_its_last_screen_position_when_projection_fails)
{
    Recorder r;
    double model[16], proj[16];
    int viewport[4];
    camera(model, proj, viewport);
    float eye[3] = {0, 0, 0};

    stretchedParticle star;
    star.pos[0] = star.lastPos[0] = 0; star.pos[1] = star.lastPos[1] = 0; star.pos[2] = star.lastPos[2] = -1;
    star.draw(&r, 1, eye, 0.0f, model, proj, viewport);
    double sx = star.screenPos[0], sy = star.screenPos[1];
    CHECK_NEAR(sx, 100.0, kTol); CHECK_NEAR(sy, 50.0, kTol);

    star.pos[0] = 0.3f; star.pos[2] = 0.0f;     /* in the eye plane: w = 0 */
    star.draw(&r, 1, eye, 0.0f, model, proj, viewport);
    CHECK(star.screenPos[0] == sx);
    CHECK(star.screenPos[1] == sy);

    star.pos[2] = -0.05f;                       /* nearer than the near plane: win z < 0 */
    star.draw(&r, 1, eye, 0.0f, model, proj, viewport);
    CHECK(star.screenPos[0] == sx);
    CHECK(star.screenPos[1] == sy);
}

TEST(renderer_flare_textures_are_four_64_square_images)
{
    Recorder r;
    HyperspaceSaverSettings *s = settingsFor(&r);
    initFlares(s);
    CHECK(r.textureSizes.size() == 4);
    for (size_t i = 0; i < r.textureSizes.size(); i++) CHECK(r.textureSizes[i] == 64064);
    for (int i = 0; i < 4; i++) CHECK(s->flaretex[i] == 101u + i);
    /* The first is a sphere: opaque at the centre, clear at the corner. */
    CHECK(s->flare1[32][32][3] == 255);
    CHECK(s->flare1[0][0][3] == 0);
    delete s;
}

TEST(renderer_flare_draws_thirteen_elements_in_the_overlay)
{
    Recorder r;
    HyperspaceSaverSettings *s = settingsFor(&r);
    for (int i = 0; i < 4; i++) s->flaretex[i] = 10 + i;
    float pos[3] = {0, 0, -5};                  /* dead ahead: screen centre */
    flare(pos, 1, 1, 1, 1, s);

    CHECK(r.overlays == 1);
    CHECK(!r.inOverlay);
    CHECK_NEAR(r.aspect, 2.0, kTol);
    CHECK(r.strips.size() == 13);
    const unsigned int tex[13] = {10, 10, 12, 11, 11, 11, 13, 11, 11, 11, 13, 11, 13};
    for (size_t i = 0; i < r.strips.size() && i < 13; i++) {
        CHECK(r.strips[i].overlay);
        CHECK(r.strips[i].texture == tex[i]);
    }
    /* The first element is centred on the source, at (aspect / 2, 1 / 2). */
    const HSVertex *q = r.strips[0].v.data();
    CHECK_NEAR((q[0].pos[0] + q[3].pos[0]) / 2, 1.0, kTol);
    CHECK_NEAR((q[0].pos[1] + q[3].pos[1]) / 2, 0.5, kTol);
    /* torus: scaled 0.5 by 0.2, colour (r, g/2, b/2) */
    const HSVertex *t = r.strips[2].v.data();
    CHECK_NEAR(t[3].pos[0] - t[0].pos[0], 0.5, kTol);
    CHECK_NEAR(t[3].pos[1] - t[0].pos[1], 0.2, kTol);
    CHECK_NEAR(r.strips[2].color[1], 0.5, kTol);
    delete s;
}

TEST(renderer_flare_draws_nothing_it_cannot_place)
{
    Recorder r;
    HyperspaceSaverSettings *s = settingsFor(&r);

    float inPlane[3] = {1, 0, 0};               /* w = 0: no screen position */
    flare(inPlane, 1, 1, 1, 1, s);
    float behind[3] = {0, 0, 5};                /* billboard z says behind the camera */
    s->billboardMat[10] = 1.0f;
    flare(behind, 1, 1, 1, 1, s);
    float farLeft[3] = {-50, 0, -1};            /* far past the fade margin */
    flare(farLeft, 1, 1, 1, 1, s);

    CHECK(r.strips.empty());
    CHECK(r.overlays == 0);
    delete s;
}

namespace {
/* The wide flare's alpha (strip 1) for a source at pos, or -1 if nothing drew.
 * frameTime is 0, so the flicker is whatever the last call left it at, and
 * is the same for every call a test compares. */
float wideAlpha(HyperspaceSaverSettings *s, Recorder *r, float x, float y)
{
    r->strips.clear();
    float pos[3] = {x, y, -1};
    flare(pos, 1, 1, 1, 1, s);
    return r->strips.size() == 13 ? r->strips[1].color[3] : -1.0f;
}
}

TEST(renderer_flare_fades_a_source_past_each_screen_edge)
{
    /* fadewidth is xsize / 10 = 20, compared against the flare plane's units
     * (x 0..2, y 0..1), so the fade starts at the edge and runs 20 units out.
     * At z = -1 a source at eye (x, y) lands at plane (x / 2 + 1, y / 2 + 0.5). */
    Recorder r;
    HyperspaceSaverSettings *s = settingsFor(&r);
    float full = wideAlpha(s, &r, 0, 0);
    CHECK(full > 0);
    CHECK_NEAR(wideAlpha(s, &r, 0, -11) / full, 0.75, 1e-4);     /* y = -5   */
    CHECK_NEAR(wideAlpha(s, &r, 0, 219) / full, 0.5, 1e-4);      /* y = 110  */
    CHECK_NEAR(wideAlpha(s, &r, -12, 0) / full, 0.75, 1e-4);     /* x = -5   */
    CHECK_NEAR(wideAlpha(s, &r, 418, 0) / full, 0.5, 1e-4);      /* x = 210  */
    CHECK(wideAlpha(s, &r, 0, -51) < 0);                         /* y = -25  */
    CHECK(wideAlpha(s, &r, 0, 259) < 0);                         /* y = 130  */
    CHECK(wideAlpha(s, &r, 458, 0) < 0);                         /* x = 230  */
    delete s;
}

TEST(renderer_flare_flicker_stays_between_0_9_and_1_1)
{
    Recorder r;
    HyperspaceSaverSettings *s = settingsFor(&r);
    s->frameTime = 100.0f;                      /* every step overshoots a bound */
    srand(1);
    bool low = false, high = false;
    for (int i = 0; i < 20; i++) {
        r.strips.clear();
        float pos[3] = {0, 0, -5};
        flare(pos, 1, 1, 1, 1, s);
        CHECK(r.strips.size() == 13);
        float w = r.strips[0].v[1].pos[0] - r.strips[0].v[0].pos[0];   /* 0.1 * flicker */
        CHECK(w > 0.0899f && w < 0.1101f);
        low = low || fabsf(w - 0.09f) < 1e-5f;
        high = high || fabsf(w - 0.11f) < 1e-5f;
    }
    CHECK(low && high);
    s->frameTime = 0.0f;
    delete s;
}
