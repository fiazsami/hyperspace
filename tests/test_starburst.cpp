/* Tests for the starburst, now that it draws through HSRenderer: the sphere it
 * draws in the goo's look, the stars it throws out, and when it may restart.
 */

#include "harness.h"
#include "recorder.h"

#include "Hyperspace/renderer.h"
#include "Hyperspace/transform.h"
#include "Hyperspace/starBurst.h"
#include "Hyperspace/stretchedParticle.h"
#include "Hyperspace/wavyNormalCubeMaps.h"
#include "Hyperspace/Hyperspace.h"

#include <math.h>
#include <stdlib.h>
#include <string.h>

namespace {
const double kTol = 1e-5;

/* rand() decides the burst's colour and its stars' speeds. */
struct Seeded { Seeded() { srand(11); } };

/* A camera at the origin looking down -z through a 200x100 viewport, a burst
 * 5 ahead of it, nothing in the way. */
HyperspaceSaverSettings *settingsFor(Recorder *r)
{
    HyperspaceSaverSettings *s = new HyperspaceSaverSettings;
    memset(s, 0, sizeof *s);
    s->renderer = r;
    s->xsize = 200; s->ysize = 100; s->aspectRatio = 2.0f;
    float p[16];
    hsPerspective(p, 90.0, 2.0, 0.1, 100.0);
    for (int i = 0; i < 16; i++) {
        s->modelMat[i] = (i % 5 == 0) ? 1.0 : 0.0;
        s->projMat[i] = p[i];
    }
    s->viewport[2] = 200; s->viewport[3] = 100;
    hsIdentity(s->billboardMat);
    s->depth = 10.0f;
    s->frameTime = 0.1f;
    s->nebulatex = 7;
    s->flaretex[0] = 3;
    return s;
}

/* starBurst declares a destructor and never defines it (nothing upstream
 * deletes one), so each case makes its burst on the heap and leaves it. */
starBurst &newBurst() { return *new starBurst; }

double length3(const float *v) { return sqrt(v[0] * v[0] + v[1] * v[1] + v[2] * v[2]); }
}

TEST(sphere_bands_lie_on_the_unit_sphere_ring_by_ring)
{
    const double t = 2 * M_PI / 32;
    for (int b = 0; b < HS_SPHERE_BANDS; b++) {
        float band[HS_SPHERE_BAND_POINTS][3];
        hsSphereBand(b, band);
        for (int i = 0; i <= 32; i++) {
            /* even points ring b, odd points ring b + 1, at longitude i */
            for (int side = 0; side < 2; side++) {
                const float *p = band[2 * i + side];
                double lat = (b + side) * t, lon = i * t;
                CHECK_NEAR(p[0], sin(lat) * cos(lon), kTol);
                CHECK_NEAR(p[1], cos(lat), kTol);
                CHECK_NEAR(p[2], sin(lat) * sin(lon), kTol);
                CHECK_NEAR(length3(p), 1.0, kTol);
            }
        }
    }
}

TEST(sphere_bands_join_and_cover_the_sphere_twice)
{
    float a[HS_SPHERE_BAND_POINTS][3], b[HS_SPHERE_BAND_POINTS][3];
    /* Neighbouring bands share a ring. Each band computes it from its own
     * sinf/cosf calls, which a compiler may pair into sincosf differently, so
     * equal to rounding rather than bit for bit. */
    for (int n = 0; n + 1 < HS_SPHERE_BANDS; n++) {
        hsSphereBand(n, a);
        hsSphereBand(n + 1, b);
        for (int i = 0; i <= 32; i++)
            for (int k = 0; k < 3; k++) CHECK_NEAR(a[2 * i + 1][k], b[2 * i][k], 1e-6);
    }
    /* Band 0 starts at the +y pole and band 15 ends at the -y pole... */
    hsSphereBand(0, a);
    CHECK_NEAR(a[0][1], 1.0, kTol);
    hsSphereBand(15, a);
    CHECK_NEAR(a[1][1], -1.0, kTol);
    /* ...and on the way back up, ring 32 - n retraces ring n on the far side:
     * the same latitude, longitudes half a turn round. Ring 32 - n is the
     * first ring of band 32 - n. */
    for (int n = 1; n < 16; n++) {
        hsSphereBand(n, a);
        hsSphereBand(32 - n, b);
        for (int i = 0; i <= 32; i++) {
            CHECK_NEAR(b[2 * i][0], -a[2 * i][0], kTol);
            CHECK_NEAR(b[2 * i][1], a[2 * i][1], kTol);
            CHECK_NEAR(b[2 * i][2], -a[2 * i][2], kTol);
        }
    }
}

TEST(starburst_starts_idle_with_stars_of_bounded_speed)
{
    Seeded seed;
    starBurst &sb = newBurst();
    CHECK(sb.size >= 3.0f);                        /* ready to restart */
    for (int i = 0; i < SB_NUM_STARS; i++) {
        CHECK(!sb.stars_active[i]);
        double v = length3(sb.stars_velocity[i]);
        CHECK(v >= 0.25 - 1e-5 && v <= 1.0 + 1e-5);
    }
}

TEST(starburst_restarts_only_once_the_last_has_finished)
{
    Seeded seed;
    starBurst &sb = newBurst();
    float at[3] = {1.0f, 2.0f, -5.0f};
    sb.restart(at);
    CHECK(sb.size == 0.0f);
    for (int k = 0; k < 3; k++) CHECK(sb.pos[k] == at[k]);
    bool full = false;
    for (int i = 0; i < SB_NUM_STARS; i++) {
        CHECK(sb.stars_active[i]);
        for (int k = 0; k < 3; k++) {
            CHECK(sb.stars[i]->pos[k] == at[k]);
            CHECK(sb.stars[i]->color[k] == sb.stars[0]->color[k]);   /* one colour */
        }
    }
    for (int k = 0; k < 3; k++) full |= sb.stars[0]->color[k] == 1.0f;
    CHECK(full);                                   /* one channel at full */

    /* Not while a star is still out... */
    float elsewhere[3] = {9.0f, 9.0f, 9.0f};
    for (int i = 1; i < SB_NUM_STARS; i++) sb.stars_active[i] = false;
    sb.size = 4.0f;
    sb.restart(elsewhere);
    CHECK(sb.pos[0] == at[0]);
    /* ...nor while the sphere is still fading. */
    sb.stars_active[0] = false;
    sb.size = 2.9f;
    sb.restart(elsewhere);
    CHECK(sb.pos[0] == at[0]);
    sb.size = 3.0f;
    sb.restart(elsewhere);
    CHECK(sb.pos[0] == elsewhere[0]);
}

TEST(starburst_stars_fly_out_and_stop_drawing_past_the_depth)
{
    Seeded seed;
    Recorder r;
    HyperspaceSaverSettings *s = settingsFor(&r);
    starBurst &sb = newBurst();
    float at[3] = {0.0f, 0.0f, -5.0f};
    sb.restart(at);
    for (int i = 1; i < SB_NUM_STARS; i++) {     /* all but two finished */
        sb.stars_active[i] = false;
    }
    sb.stars_active[1] = true;
    sb.stars[1]->pos[2] = -9.95f;                  /* about to leave the depth */
    sb.stars_velocity[1][0] = sb.stars_velocity[1][1] = 0.0f;
    sb.stars_velocity[1][2] = -1.0f;
    sb.drawStars(s);
    for (int k = 0; k < 3; k++)
        CHECK_NEAR(sb.stars[0]->pos[k], at[k] + sb.stars_velocity[0][k] * 0.1, kTol);
    CHECK_NEAR(sb.stars[1]->pos[2], -10.05, kTol);
    CHECK(sb.stars_active[0]);
    CHECK(!sb.stars_active[1]);
    /* Only the star still within the depth drew: a stretched particle draws
     * its aura and its core. */
    CHECK(r.strips.size() == 2);
    for (size_t n = 0; n < r.strips.size(); n++) CHECK(r.strips[n].texture == 3);
    delete s;
}

TEST(starburst_sphere_grows_and_fades_in_the_goos_look)
{
    Seeded seed;
    Recorder r;
    HyperspaceSaverSettings *s = settingsFor(&r);
    s->dShaders = true;
    s->numAnimTexFrames = 4;
    s->whichTexture = 3;
    wavyNormalCubeMaps wncm(&r, 4, 8);
    s->theWNCM = &wncm;
    starBurst &sb = newBurst();
    float at[3] = {0.0f, 0.0f, -5.0f};
    sb.restart(at);
    sb.draw(0.25f, s);

    /* size grows half a unit a second; brightness falls a third per unit. */
    CHECK_NEAR(sb.size, 0.05, kTol);
    CHECK(r.overlays == 1);                        /* its lens flare */
    CHECK(r.gooBegins.size() == 1 && r.gooEnds == 1);
    CHECK(r.goo.size() == 1);
    if (r.gooBegins.size() == 1 && r.goo.size() == 1) {
        const GooBegin &b = r.gooBegins[0];
        double bright = 1.0 - 0.05 * 0.333333;
        for (int k = 0; k < 3; k++) CHECK_NEAR(b.color[k], bright, kTol);
        CHECK(b.color[3] == 0.25f);                /* lerp mixes the normal maps */
        CHECK(b.shaded);
        CHECK(b.nebula == 7);
        CHECK(b.normals0 == wncm.texture[3]);
        CHECK(b.normals1 == wncm.texture[0]);      /* the next frame, wrapping */
        CHECK(r.goo[0].surface == NULL);
        for (int k = 0; k < 3; k++) CHECK(r.goo[0].offset[k] == at[k]);
        CHECK_NEAR(r.goo[0].radius, 0.05, kTol);
    }

    /* Without shaders: opaque colour, no normal maps. */
    Recorder plain;
    s->renderer = &plain;
    s->dShaders = false;
    sb.draw(0.25f, s);
    CHECK(plain.gooBegins.size() == 1);
    if (plain.gooBegins.size() == 1) {
        CHECK(plain.gooBegins[0].color[3] == 1.0f);
        CHECK(!plain.gooBegins[0].shaded);
        CHECK(plain.gooBegins[0].normals0 == 0 && plain.gooBegins[0].normals1 == 0);
        CHECK_NEAR(plain.goo[0].radius, 0.1, kTol);
    }

    /* Once the sphere reaches 3 it has faded: only the stars draw. */
    Recorder done;
    s->renderer = &done;
    sb.size = 2.96f;
    sb.draw(0.25f, s);
    CHECK(sb.size >= 3.0f);
    CHECK(done.gooBegins.empty() && done.goo.empty());
    CHECK(done.overlays == 0);
    CHECK(!done.strips.empty());                   /* its stars are still out */
    delete s;
}
