/* Tests for impKnot: its constructor's defaults, the coil/twist setters, and
 * the value()/center()/addCrawlPoint() functions built on top of them.
 *
 * Like the other impShape subclasses (see test_imp_primitives.cpp), invtrmat
 * is left uninitialised by impShape's constructor and is only filled in by
 * setMatrix(), so every value() call below is preceded by an explicit
 * setMatrix().
 *
 * value() reads invtrmat and calls the *approximate* rsSqrtf/rsCosf/rsSinf/
 * rsAtan2f from rsMath, not the standard library ones -- addCrawlPoint(), by
 * contrast, uses plain cosf/sinf directly. The expected constants below were
 * derived analytically with the standard library's math functions and
 * cross-checked against the on-axis fixture already proven correct in
 * helios' twin of this file; the approximation's own error at these points
 * is small enough that the tolerances below have generous headroom without
 * being wide enough to hide a dropped term or a wrong sign.
 *
 * ss-e5n item 3: helios' twin of this file used only on-axis value() fixtures
 * (y = z = 0), so rsAtan2f(ty, tx) was always 0 and `lat` -- and therefore
 * twistsOverCoils, and therefore setNumTwists -- was never exercised.
 * Replacing the production `lat` computation with `const float lat(0.0f)`,
 * or changing `twistsf/coilsf` to `twistsf*coilsf`, left that suite green.
 * knot_value_off_axis_depends_on_twists below uses an off-axis point (ty and
 * tx both nonzero) at two different setNumTwists settings and asserts the
 * results differ, which neither mutation survives.
 *
 * ss-e5n item 9: every primitive's value() fixture used to rely on identity
 * or pure-translation matrices, so invtrmat's nine linear-part entries were
 * never pinned. test_imp_primitives.cpp fixed this for the other shapes with
 * a shared "coupled" matrix whose linear part is fully populated and has no
 * 0 or 1 entries; knot_value_pins_matrix_rotation_and_shear below reuses
 * that exact matrix and position so a wrong invtrmat index moves the result
 * far outside the tolerance here.
 */

#include "harness.h"

#include <math.h>

#include <Implicit/impKnot.h>

namespace {

const float kTol = 1e-4f;

void makeIdentity(float *m)
{
    for (int i = 0; i < 16; i++) m[i] = 0.0f;
    m[0] = m[5] = m[10] = m[15] = 1.0f;
}

/* Same matrix as test_imp_primitives.cpp's makeCoupledMatrix: every one of
 * the nine linear-part entries of the resulting invtrmat is distinct and
 * neither 0 nor 1, so a formula that reads the wrong index produces a
 * visibly different result rather than coincidentally matching. */
void makeCoupledMatrix(float *m)
{
    makeIdentity(m);
    m[0] = 2.0f;  m[1] = 1.0f;  m[2] = 1.0f;
    m[4] = 1.0f;  m[5] = 3.0f;  m[6] = 1.0f;
    m[8] = 1.0f;  m[9] = 1.0f;  m[10] = 4.0f;
    m[12] = 1.0f; m[13] = 2.0f; m[14] = 3.0f;
}

}  // namespace

/* --- impKnot() --------------------------------------------------------------
 *
 * The constructor's initializer-list arithmetic (coilsf, twistsOverCoils,
 * lat_offset) has no direct getter, but its inputs -- radius1, radius2,
 * coils, twists -- are all readable and are what value()/center() actually
 * depend on. */

TEST(knot_constructor_sets_the_documented_defaults)
{
    impKnot k;
    CHECK_NEAR(k.getRadius1(), 1.0f, kTol);
    CHECK_NEAR(k.getRadius2(), 0.5f, kTol);
    CHECK(k.getNumCoils() == 3);
    CHECK(k.getNumTwists() == 2);
}

/* --- impKnot::setNumCoils ----------------------------------------------------
 *
 * "coils must be greater than 1" is what the comment claims, but the clamp
 * (c<1 ? 1 : c) actually only enforces coils >= 1 -- setNumCoils(1) is
 * accepted, not rejected. Characterizing the code as it stands, not the
 * comment's stronger claim. */

TEST(knot_setNumCoils_clamps_zero_and_negative_up_to_one)
{
    impKnot k;

    k.setNumCoils(0);
    CHECK(k.getNumCoils() == 1);

    k.setNumCoils(-5);
    CHECK(k.getNumCoils() == 1);
}

TEST(knot_setNumCoils_accepts_values_of_one_and_above)
{
    impKnot k;

    k.setNumCoils(1);
    CHECK(k.getNumCoils() == 1);

    k.setNumCoils(7);
    CHECK(k.getNumCoils() == 7);
}

/* --- impKnot::setNumTwists ---------------------------------------------------
 *
 * Unlike setNumCoils, there is no clamp at all here: twists is stored
 * exactly as given, including zero and negative values. */

TEST(knot_setNumTwists_stores_the_value_unclamped)
{
    impKnot k;

    k.setNumTwists(5);
    CHECK(k.getNumTwists() == 5);

    k.setNumTwists(0);
    CHECK(k.getNumTwists() == 0);

    k.setNumTwists(-3);
    CHECK(k.getNumTwists() == -3);
}

/* --- impKnot::value ----------------------------------------------------------
 *
 * value() sums one inverse-square falloff term per coil, each centered on a
 * ring displaced around the knot's tube. With the default matrix (identity)
 * and a point on the x axis at x = radius1 + radius2, y = z = 0: atan2(0, x)
 * is ~0, so lat ~0 and the i=0 term's lon is ~0 too, putting hor = temp -
 * cos(0)*radius2 at exactly zero and ver at zero -- that term is dominated
 * by IMP_MIN_DIVISOR and swamps the other two coils' off-ring contributions. */

TEST(knot_value_peaks_on_the_first_coil_ring)
{
    impKnot k;
    float m[16];
    makeIdentity(m);
    k.setMatrix(m);

    /* radius1=1, radius2=0.5 (defaults): x = 1.5 sits exactly on the i=0
     * coil ring. Two other coils (default coils=3) each contribute a small
     * off-ring term; the total was cross-checked offline at 100.026663. */
    float onRing[3] = {1.5f, 0.0f, 0.0f};
    CHECK_NEAR(k.value(onRing), 100.026663f, 0.01f);
}

TEST(knot_value_falls_off_away_from_the_tube)
{
    impKnot k;
    float m[16];
    makeIdentity(m);
    k.setMatrix(m);

    /* Far past the ring (x=5 vs. the ring at x=1.5): every coil's hor term
     * is large, so no single term dominates and the total is small.
     * Cross-checked offline at 0.001912. */
    float farOff[3] = {5.0f, 0.0f, 0.0f};
    CHECK_NEAR(k.value(farOff), 0.001912f, 1e-4f);
}

TEST(knot_value_sums_exactly_one_term_per_coil)
{
    impKnot k;
    float m[16];
    makeIdentity(m);
    k.setMatrix(m);

    /* Same on-ring point as above, but with setNumCoils(1) there is only
     * one term in the sum -- no off-ring coils to add their small
     * contribution, so the total is exactly the IMP_MIN_DIVISOR-dominated
     * term itself, not ~100.0267 as with three coils. This is what actually
     * pins the loop to `coils` rather than a hardcoded count. */
    k.setNumCoils(1);
    float onRing[3] = {1.5f, 0.0f, 0.0f};
    CHECK_NEAR(k.value(onRing), 100.0f, 0.01f);
}

/* ss-e5n item 3: an off-axis point (both tx and ty nonzero), so
 * rsAtan2f(ty, tx) is not 0 and `lat` actually depends on twistsOverCoils.
 * setNumTwists to two different values at the same position and require the
 * results to differ -- a stub `lat` of 0.0f, or a twistsOverCoils computed
 * as twistsf*coilsf instead of twistsf/coilsf, both leave this failing. */

TEST(knot_value_off_axis_depends_on_twists)
{
    impKnot k;
    float m[16];
    makeIdentity(m);
    k.setMatrix(m);

    /* 30 degrees around from the x axis, at the default ring radius
     * (radius1+radius2=1.5), z=0: tx=1.299038, ty=0.75. rsAtan2f is a table
     * approximation (rsTrigonometry.h), not std::atan2, so these constants
     * were obtained by calling the real value() offline rather than derived
     * analytically. Default twists=2: value = 0.303606. */
    float offAxis[3] = {1.299038f, 0.75f, 0.0f};
    CHECK_NEAR(k.value(offAxis), 0.303606f, 1e-3f);

    /* Same position, twists=1: value = 1.107761. */
    k.setNumTwists(1);
    const float withOneTwist = k.value(offAxis);
    CHECK_NEAR(withOneTwist, 1.107761f, 1e-3f);

    /* Same position, twists=5: value = 0.091591. */
    k.setNumTwists(5);
    const float withFiveTwists = k.value(offAxis);
    CHECK_NEAR(withFiveTwists, 0.091591f, 1e-3f);

    /* The two twists settings must not coincide -- this is what a stubbed
     * `lat` or a twistsf*coilsf typo would collapse. */
    CHECK(fabsf(withOneTwist - withFiveTwists) > 0.1f);
}

/* ss-e5n item 9: matrix with a fully populated, non-identity linear part, so
 * a value() that reads the wrong invtrmat index moves the result far
 * outside the tolerance below rather than coincidentally matching. */

TEST(knot_value_pins_matrix_rotation_and_shear)
{
    impKnot k;
    float m[16];
    makeCoupledMatrix(m);
    k.setMatrix(m);

    /* Same (tx,ty,tz) = (0.235294, 0.117647, 0.411765) as
     * test_imp_primitives.cpp's coupled-matrix fixtures at position (2,3,5).
     * With the default radius1=1, radius2=0.5, coils=3, twists=2, calling
     * the real value() offline gives 0.089546. */
    float pos[3] = {2.0f, 3.0f, 5.0f};
    CHECK_NEAR(k.value(pos), 0.089546f, 1e-4f);
}

/* --- impKnot::center ----------------------------------------------------------
 *
 * center() only reads mat, not invtrmat, so no setMatrix() is required --
 * same as impTorus::center in test_imp_primitives.cpp. */

TEST(knot_center_combines_the_radius_sum_along_local_x_with_position)
{
    impKnot k;

    /* Default radius1=1, radius2=0.5, identity matrix: center is one
     * (radius1+radius2) out along local x from the origin. */
    float c[3];
    k.center(c);
    CHECK_NEAR(c[0], 1.5f, kTol);
    CHECK_NEAR(c[1], 0.0f, kTol);
    CHECK_NEAR(c[2], 0.0f, kTol);

    /* Changing both radii and moving the shape both have to show up. */
    k.setRadius1(2.0f);
    k.setRadius2(1.0f);
    k.setPosition(10.0f, 20.0f, 30.0f);
    k.center(c);
    CHECK_NEAR(c[0], 13.0f, kTol);
    CHECK_NEAR(c[1], 20.0f, kTol);
    CHECK_NEAR(c[2], 30.0f, kTol);
}

/* --- impKnot::addCrawlPoint ---------------------------------------------------
 *
 * Places one crawl point per coil, evenly spaced around the tube's local
 * x-z circle of radius `radius2`, offset by `radius1` along x -- using plain
 * cosf/sinf, not the rsMath approximations, so these are exact to float
 * precision. */

TEST(knot_addCrawlPoint_places_one_point_per_coil_around_the_xz_circle)
{
    impKnot k;
    k.setNumCoils(4);

    impCrawlPointVector cpv;
    k.addCrawlPoint(cpv);

    CHECK(cpv.size() == 4);

    /* i=0: angle 0 -> (radius1 + radius2, 0, 0) = (1.5, 0, 0). */
    CHECK_NEAR(cpv[0].position[0], 1.5f, kTol);
    CHECK_NEAR(cpv[0].position[1], 0.0f, kTol);
    CHECK_NEAR(cpv[0].position[2], 0.0f, kTol);

    /* i=1: angle pi/2 -> (radius1, 0, radius2) = (1.0, 0, 0.5). */
    CHECK_NEAR(cpv[1].position[0], 1.0f, kTol);
    CHECK_NEAR(cpv[1].position[1], 0.0f, kTol);
    CHECK_NEAR(cpv[1].position[2], 0.5f, kTol);

    /* i=2: angle pi -> (radius1 - radius2, 0, 0) = (0.5, 0, 0). */
    CHECK_NEAR(cpv[2].position[0], 0.5f, kTol);
    CHECK_NEAR(cpv[2].position[2], 0.0f, kTol);

    /* i=3: angle 3pi/2 -> (radius1, 0, -radius2) = (1.0, 0, -0.5). */
    CHECK_NEAR(cpv[3].position[0], 1.0f, kTol);
    CHECK_NEAR(cpv[3].position[2], -0.5f, kTol);
}

TEST(knot_addCrawlPoint_appends_rather_than_replaces)
{
    impKnot k;
    k.setNumCoils(3);

    impCrawlPointVector cpv;
    k.addCrawlPoint(cpv);
    CHECK(cpv.size() == 3);

    k.addCrawlPoint(cpv);
    CHECK(cpv.size() == 6);

    /* The second batch repeats the same pattern as the first. */
    CHECK_NEAR(cpv[3].position[0], cpv[0].position[0], kTol);
    CHECK_NEAR(cpv[3].position[2], cpv[0].position[2], kTol);
}
