/* Tests for the goo, the tunnel and the spline path they follow, now that they
 * draw through HSRenderer.
 *
 * The path and the tunnel's rings are asserted on their geometry; the draws on
 * what reaches a recording renderer: which goo surfaces, offset where, and the
 * tunnel's strips in the vertex order GL drew them in before the seam.
 */

#include "harness.h"
#include "recorder.h"

#include "Hyperspace/renderer.h"
#include "Hyperspace/splinePath.h"
#include "Hyperspace/tunnel.h"
#include "Hyperspace/goo.h"
#include "Hyperspace/Hyperspace.h"

#include <math.h>
#include <stdlib.h>
#include <string.h>

namespace {
const double kTol = 1e-5;
const double kTrig = 1e-3;   // rsCosf is a table lookup, good to about 1e-4

/* The path, the goo's phases and speeds draw on rand(). Each case seeds it so
 * that its path does not depend on which cases ran before it. */
struct Seeded { Seeded() { srand(7); } };

/* Fills xyz[] and dir[], which the constructor leaves unset, from a phase of
 * zero: each point sits at its base point plus its whole movement vector. */
void settle(splinePath &p)
{
    for (int i = 0; i < p.numPoints; i++) p.phase[i] = 0.0f;
    p.update(0.0f);
}

double headingOf(const float *from, const float *to)
{
    return atan2(to[0] - from[0], to[2] - from[2]);
}

/* The newest point of a path whose last two points are q - heading and q,
 * with q far enough out to turn the path back toward the centre. */
void extendFrom(splinePath &p, const float q[3], const float heading[3])
{
    int n = p.numPoints;
    for (int k = 0; k < 3; k++) {
        p.basexyz[n - 1][k] = q[k];
        p.basexyz[n - 2][k] = q[k] - heading[k];
    }
    p.step = 0.0f;
    p.moveAlongPath(1.0f);
}
}

TEST(spline_path_has_at_least_six_points)
{
    Seeded seed;
    splinePath p(2);
    CHECK(p.numPoints == 6);
    splinePath q(9);
    CHECK(q.numPoints == 9);
}

TEST(spline_path_passes_through_its_points_and_clamps_the_section)
{
    Seeded seed;
    splinePath p(8);
    settle(p);
    float a[3];
    p.getPoint(3, 0.0f, a);
    for (int k = 0; k < 3; k++) CHECK_NEAR(a[k], p.xyz[3][k], kTol);
    p.getPoint(3, 1.0f, a);
    for (int k = 0; k < 3; k++) CHECK_NEAR(a[k], p.xyz[4][k], kTol);

    /* Sections run 1 .. numPoints - 3: anything outside reads the end one. */
    float lo[3], hi[3];
    p.getPoint(-4, 0.0f, lo);
    p.getPoint(50, 1.0f, hi);
    for (int k = 0; k < 3; k++) {
        CHECK_NEAR(lo[k], p.xyz[1][k], kTol);
        CHECK_NEAR(hi[k], p.xyz[6][k], kTol);
    }

    /* Halfway, the Catmull-Rom weights are -1/16, 9/16, 9/16, -1/16. */
    p.getPoint(2, 0.5f, a);
    for (int k = 0; k < 3; k++) {
        double want = (-p.xyz[1][k] + 9 * p.xyz[2][k] + 9 * p.xyz[3][k] - p.xyz[4][k]) / 16.0;
        CHECK_NEAR(a[k], want, 1e-4);
    }
}

TEST(spline_path_directions_are_unit_and_follow_the_points)
{
    Seeded seed;
    splinePath p(8);
    settle(p);
    for (int s = 0; s < 8; s++) {
        float d[3];
        p.getDirection(s, 0.3f, d);
        CHECK_NEAR(d[0] * d[0] + d[1] * d[1] + d[2] * d[2], 1.0, 1e-5);
    }
    /* makeNewPoint fills basedir[1 .. numPoints - 3] only, so a base
     * direction is defined for sections 2 .. numPoints - 5; outside them it
     * reads unset memory. The saver asks for section dDepth + 2 of a
     * 2 * dDepth + 6 point path, which is always inside. */
    for (int s = 2; s <= p.numPoints - 5; s++) {
        float b[3];
        p.getBaseDirection(s, 0.3f, b);
        CHECK_NEAR(b[0] * b[0] + b[1] * b[1] + b[2] * b[2], 1.0, 1e-5);
    }
    /* update() makes dir[i] the chord from point i-1 to point i+1, and at a
     * section's start the direction is that chord, normalised. Clamping
     * applies to directions as it does to points. */
    float d[3], lo[3], hi[3];
    p.getDirection(2, 0.0f, d);
    double c[3], len = 0;
    for (int k = 0; k < 3; k++) { c[k] = p.xyz[3][k] - p.xyz[1][k]; len += c[k] * c[k]; }
    for (int k = 0; k < 3; k++) CHECK_NEAR(d[k], c[k] / sqrt(len), 1e-4);
    p.getDirection(0, 0.0f, lo);
    p.getDirection(1, 0.0f, d);
    for (int k = 0; k < 3; k++) CHECK_NEAR(lo[k], d[k], kTol);
    p.getDirection(99, 1.0f, hi);
    p.getDirection(5, 1.0f, d);
    for (int k = 0; k < 3; k++) CHECK_NEAR(hi[k], d[k], kTol);
}

TEST(spline_path_points_sway_along_their_movement_vectors)
{
    Seeded seed;
    splinePath p(8);
    for (int i = 0; i < p.numPoints; i++) { p.phase[i] = 0.5f; p.rate[i] = 2.0f; }
    p.update(0.25f);                                     /* phase 0.5 + 2 * 0.25 = 1 */
    for (int i = 0; i < p.numPoints; i++) {
        CHECK_NEAR(p.phase[i], 1.0, kTol);
        for (int k = 0; k < 3; k++)
            CHECK_NEAR(p.xyz[i][k], p.basexyz[i][k] + p.movevec[i][k] * cos(1.0), 1e-5);
    }
}

TEST(spline_path_moves_one_point_per_unit_step)
{
    Seeded seed;
    splinePath p(8);
    float second[3];
    memcpy(second, p.basexyz[1], sizeof second);
    p.moveAlongPath(0.75f);
    CHECK_NEAR(p.step, 0.75, kTol);
    CHECK(p.basexyz[0][0] != second[0] || p.basexyz[0][2] != second[2]);   /* nothing shifted yet */
    p.moveAlongPath(0.5f);                                  /* 1.25: one new point */
    CHECK_NEAR(p.step, 0.25, kTol);
    for (int k = 0; k < 3; k++) CHECK(p.basexyz[0][k] == second[k]);

    /* Each new point lies 2 to 8 out from the last, level, and the path's
     * base directions are refreshed from the new points. */
    int n = p.numPoints;
    double dx = p.basexyz[n - 1][0] - p.basexyz[n - 2][0], dz = p.basexyz[n - 1][2] - p.basexyz[n - 2][2];
    double len = sqrt(dx * dx + dz * dz);
    CHECK(len >= 2.0 - 1e-4 && len <= 8.0 + 1e-4);
    CHECK(p.basexyz[n - 1][1] == 0.0f);
    CHECK_NEAR(p.basedir[n - 3][0], p.basexyz[n - 2][0] - p.basexyz[n - 4][0], kTol);
    CHECK_NEAR(p.basedir[n - 3][2], p.basexyz[n - 2][2] - p.basexyz[n - 4][2], kTol);
}

TEST(spline_path_far_from_centre_turns_back_at_most_0_7_radians)
{
    Seeded seed;
    /* Heading -x from (-1, 0, 200): the centre is behind and to the left.
     * The raw turn is past pi and wraps to about -1.58, clamped to -0.7. */
    splinePath p(8);
    const float q[3] = {-1.0f, 0.0f, 200.0f}, h[3] = {-1.0f, 0.0f, -0.01f};
    extendFrom(p, q, h);
    int n = p.numPoints;
    CHECK_NEAR(headingOf(p.basexyz[n - 2], p.basexyz[n - 1]), atan2(-1.0, -0.01) - 0.7, 1e-4);

    /* The mirror image wraps the other way and clamps to +0.7. */
    splinePath r(8);
    const float q2[3] = {1.0f, 0.0f, 200.0f}, h2[3] = {1.0f, 0.0f, -0.01f};
    extendFrom(r, q2, h2);
    CHECK_NEAR(headingOf(r.basexyz[n - 2], r.basexyz[n - 1]), atan2(1.0, -0.01) + 0.7, 1e-4);

    /* Within reach of the turn, it aims straight at the centre. */
    splinePath s(8);
    const float q3[3] = {5.0f, 0.0f, 200.0f}, h3[3] = {0.3f, 0.0f, -1.0f};
    extendFrom(s, q3, h3);
    double dx = s.basexyz[n - 1][0] - q3[0], dz = s.basexyz[n - 1][2] - q3[2], len = sqrt(dx * dx + dz * dz);
    CHECK_NEAR(dx / len, -5.0 / sqrt(5.0 * 5.0 + 200.0 * 200.0), 1e-4);
    CHECK_NEAR(dz / len, -200.0 / sqrt(5.0 * 5.0 + 200.0 * 200.0), 1e-4);
}

TEST(tunnel_rings_circle_the_path_and_carry_its_texture_coordinates)
{
    Seeded seed;
    splinePath p(8);
    settle(p);
    tunnel t(&p, 4);
    CHECK(t.numSections == 3);
    t.make(0.0f, true);
    for (int k = 0; k < t.numSections; k++) {
        for (int i = 0; i <= 4; i++) {
            float pos[3], dir[3];
            p.getPoint(k + 2, i / 4.0f, pos);
            p.getDirection(k + 2, i / 4.0f, dir);
            for (int j = 0; j <= 4; j++) {
                double o[3], dot = 0, len = 0;
                for (int c = 0; c < 3; c++) {
                    o[c] = t.v[k][i][j][c] - pos[c];
                    dot += o[c] * dir[c];
                    len += o[c] * o[c];
                }
                CHECK_NEAR(dot, 0.0, 1e-5);                  /* in the plane across the path */
                CHECK(sqrt(len) > 0.0 && sqrt(len) <= 1.5 * t.radius + 1e-5);
                CHECK_NEAR(t.t[k][i][j][0], i / 4.0, kTol);  /* along the path */
                CHECK_NEAR(t.t[k][i][j][1], j / 4.0 + 1.0, kTrig);   /* around it, spun by cos(0) */
            }
            /* A quarter turn round is the top of the ring: the path is level,
             * so the ring's up axis is world up. */
            CHECK(t.v[k][i][1][1] - pos[1] > 0.4 * t.radius);
        }
    }
    /* j = 0 starts at angle 0, so a ring closes on itself at j = resolution. */
    for (int c = 0; c < 3; c++) CHECK_NEAR(t.v[1][2][0][c], t.v[1][2][4][c], 1e-4);

    /* Without shaders the texture repeats twice as often. */
    t.make(0.0f, false);
    CHECK_NEAR(t.t[0][4][0][0], 2.0, kTol);
    CHECK_NEAR(t.t[0][0][4][1], 2.0 + 1.0, kTrig);
}

TEST(tunnel_colours_are_paler_with_shaders)
{
    Seeded seed;
    /* Chroma = (1 - |2L - 1|) * S, so the saturation limit -- 0.1 with
     * shaders, 0.4 without -- bounds how far a colour's channels can spread. */
    splinePath p(8);
    settle(p);
    tunnel t(&p, 8);
    double worst[2] = {0, 0};
    for (int shaded = 0; shaded < 2; shaded++) {
        t.huelo = t.huehi = t.satlo = t.sathi = 0.0f;
        t.lumlo = 1.5f; t.lumhi = 0.0f;           /* lit, unlike a new tunnel's 3.14 */
        t.make(0.0f, shaded == 1);
        for (int k = 0; k < t.numSections; k++)
            for (int i = 0; i <= 8; i++)
                for (int j = 0; j <= 8; j++) {
                    const float *c = t.c[k][i][j];
                    double hi = fmax(c[0], fmax(c[1], c[2])), lo = fmin(c[0], fmin(c[1], c[2]));
                    CHECK(lo >= 0.0 && hi <= 1.0);
                    worst[shaded] = fmax(worst[shaded], hi - lo);
                }
    }
    CHECK(worst[1] <= 0.1 + 1e-4);
    CHECK(worst[0] > 0.1 && worst[0] <= 0.4 + 1e-4);
}

TEST(tunnel_starts_dark_and_its_phases_wrap)
{
    Seeded seed;
    splinePath p(8);
    settle(p);
    tunnel t(&p, 4);
    t.make(0.0f, true);
    for (int c = 0; c < 3; c++) CHECK(t.c[0][2][2][c] == 0.0f);   /* lumlo 3.14: invisible at first */

    /* 6.27 is close enough to 2 pi that even the slowest rate, 0.04, wraps. */
    t.widthOffset = t.texSpin = 6.27f;
    t.huelo = t.huehi = t.satlo = t.sathi = t.lumlo = t.lumhi = 6.27f;
    t.make(1.0f, true);
    const float *phases[] = {&t.widthOffset, &t.texSpin, &t.huelo, &t.huehi, &t.satlo, &t.sathi, &t.lumlo, &t.lumhi};
    const double rates[] = {1.5, 0.1, 0.04, 0.15, 0.04, 1.0, 0.04, 0.5};
    for (int i = 0; i < 8; i++) {
        double want = 6.27 + rates[i] - 2 * M_PI;
        CHECK_NEAR(*phases[i], want, 1e-4);
    }
}

TEST(tunnel_draws_one_strip_per_ring_pair_next_ring_first)
{
    Seeded seed;
    splinePath p(8);
    settle(p);
    tunnel t(&p, 4);
    t.lumlo = 1.5f;
    t.make(0.0f, true);
    Recorder r;
    t.draw(&r);
    CHECK(r.tunnel.size() == size_t(3 * 4));
    for (int k = 0; k < 3; k++)
        for (int i = 0; i < 4; i++) {
            const std::vector<HSTunnelVertex> &s = r.tunnel[k * 4 + i];
            CHECK(s.size() == size_t(2 * 5));
            if (s.size() != 10) continue;
            for (int j = 0; j <= 4; j++)
                for (int side = 0; side < 2; side++) {
                    const HSTunnelVertex &v = s[2 * j + side];
                    int ring = side == 0 ? i + 1 : i;
                    CHECK(memcmp(v.pos, t.v[k][ring][j], sizeof v.pos) == 0);
                    CHECK(memcmp(v.uv, t.t[k][ring][j], sizeof v.uv) == 0);
                    CHECK(memcmp(v.color, t.c[k][ring][j], sizeof v.color) == 0);
                }
        }
}

TEST(goo_value_is_the_wavy_layer_less_a_bubble_round_the_eye)
{
    Seeded seed;
    goo g(10, 5.0f);
    g.shiftx = 1.0f; g.shiftz = 2.0f;
    g.camx = 0.5f; g.camz = 0.25f;
    for (int i = 0; i < 4; i++) g.c[i] = 0.1f * (i + 1);
    float at[3] = {0.25f, 0.3f, -0.5f};
    double px = 1.25, y = 0.3, pz = 1.5, x = px - 0.5, z = pz - 0.25;
    double want = 1.25 * y * y + 0.1 * cos(px - 2.71 * y) + 0.2 * cos(4.21 * y + pz)
        + 0.3 * cos(1.91 * px - 1.67 * pz) + 0.4 * cos(1.53 * px + 1.11 * y + 2.11 * pz)
        - 0.1 / (x * x + y * y + z * z);
    CHECK_NEAR(goo::function(at, &g), want, kTrig);
}

TEST(goo_builds_the_surfaces_in_view_and_draws_each_once)
{
    Seeded seed;
    /* Resolution below 5 is raised to 5. Radius 5 gives a 6 x 6 grid of
     * 2-unit volumes, centred on the camera's cell: shifts -5 .. 5. */
    goo g(4, 5.0f);
    CHECK(g.resolution == 5);
    CHECK(g.arraySize == 6);
    CHECK_NEAR(g.unitSize, 0.4, kTol);
    goo big(6, 5.0f);
    CHECK(big.resolution == 6);

    HyperspaceSaverSettings s;
    memset(&s, 0, sizeof s);
    s.frameTime = 0.5f;
    for (int i = 0; i < 4; i++) { g.cp[i] = 0.0f; g.cs[i] = 0.2f * (i + 1); }
    g.update(0.7f, -0.3f, 0.4f, 1.0f, &s);
    for (int i = 0; i < 4; i++) CHECK_NEAR(g.c[i], 0.25 * cos(0.1 * (i + 1)), 1e-5);

    /* The camera snaps to a goo cell by int(0.5 + x / unitSize): 0.7 / 0.4
     * rounds to cell 2, but int() truncates toward zero, so -0.3 / 0.4 lands
     * in cell 0, not -1. */
    CHECK_NEAR(g.centerx, 0.8, kTol);
    CHECK_NEAR(g.centerz, 0.0, kTol);

    /* Heading 0.4 with a 1-radian view keeps the wedge between the two side
     * planes, here (x across, z up the page; shift = 2 * (0.5 + i - 3)):
     *
     *   z  5  . . . . . .
     *      3  . . . # . .
     *      1  . # # # . .
     *     -1  # # # # . .
     *     -3  # # # # # .
     *     -5  # # # # # .
     *        -5    -1 1    5  x                                          */
    CHECK(g.useSurface[0][0]);
    CHECK(g.useSurface[4][0]);
    CHECK(!g.useSurface[5][0]);
    CHECK(g.useSurface[0][2]);
    CHECK(!g.useSurface[0][3]);
    CHECK(g.useSurface[1][3]);
    CHECK(g.useSurface[3][4]);
    CHECK(!g.useSurface[2][4]);
    for (int i = 0; i < 6; i++) CHECK(!g.useSurface[i][5]);

    int used = 0;
    for (int i = 0; i < 6; i++) for (int j = 0; j < 6; j++) used += g.useSurface[i][j];
    Recorder r;
    g.draw(&r);
    CHECK(g.surface[0][0]->getIndexCount() > 0);   // built by draw, for a CPU renderer
    CHECK(r.goo.size() == size_t(used));
    bool sawCorner = false;
    for (size_t n = 0; n < r.goo.size(); n++) {
        CHECK(r.goo[n].offset[1] == 0.0f);
        if (r.goo[n].surface == g.surface[0][0]) {
            sawCorner = true;
            CHECK_NEAR(r.goo[n].offset[0], 0.8 - 5.0, kTol);
            CHECK_NEAR(r.goo[n].offset[2], -5.0, kTol);
        }
    }
    CHECK(sawCorner);

    /* A surface is drawn once per update. */
    Recorder again;
    g.draw(&again);
    CHECK(again.goo.empty());
}

TEST(goo_constant_phases_wrap)
{
    Seeded seed;
    goo g(10, 1.0f);
    HyperspaceSaverSettings s;
    memset(&s, 0, sizeof s);
    s.frameTime = 1.0f;
    for (int i = 0; i < 4; i++) { g.cp[i] = 6.2f; g.cs[i] = 0.5f; }
    g.update(0.0f, 0.0f, 0.0f, 1.0f, &s);
    for (int i = 0; i < 4; i++) CHECK_NEAR(g.cp[i], 6.7 - 2 * M_PI, 1e-5);
}
