/* Tests for the bare-float[3] vector helpers and the random helpers.
 *
 * Both groups were bucket B in triage -- not testable until something changed.
 * The vector helpers were b:hidden: defined with external linkage in rsVec.cpp
 * but declared nowhere, so no test could name them. Declaring them in rsVec.h
 * was the whole fix.
 *
 * The random helpers were b:nondeterministic, which turned out to be a misfiled
 * verdict rather than a real blocker. They are thin wrappers over rand(), and
 * their contract is a range, not a value -- so the tests below assert the range
 * and the seeded reproducibility, neither of which can flake. Nothing about
 * them needed to change.
 *
 * These duplicate rsVec's member functions almost exactly. That duplication is
 * in the code under test, not introduced here, and it is worth pinning
 * separately: the two implementations are not identical, and rsNormalize's
 * zero-length case differs from rsVec::normalize's.
 */

#include "harness.h"

#include "rsMath/rsMath.h"
#include "rsMath/rsVec.h"

#include <math.h>
#include <stdlib.h>

namespace {
const float kTol = 1e-5f;
}

/* --- the exposed free functions ------------------------------------------ */

TEST(free_length_is_euclidean)
{
    float v[3] = {1.0f, 2.0f, 2.0f};       /* length 3, all components non-zero */
    CHECK_NEAR(rsLength(v), 3.0f, kTol);

    float zero[3] = {0.0f, 0.0f, 0.0f};
    CHECK_NEAR(rsLength(zero), 0.0f, kTol);
}

TEST(free_normalize_returns_prior_length_and_scales_in_place)
{
    float v[3] = {0.0f, 3.0f, 4.0f};
    CHECK_NEAR(rsNormalize(v), 5.0f, kTol);
    CHECK_NEAR(rsLength(v), 1.0f, kTol);
    CHECK_NEAR(v[1], 0.6f, kTol);
    CHECK_NEAR(v[2], 0.8f, kTol);
}

TEST(free_normalize_leaves_a_zero_vector_alone)
{
    /* This is where the free function and the member function part company, and
     * the reason it is worth having both pinned. rsVec::normalize picks a
     * direction for a zero vector -- it sets v[1] to 1. rsNormalize returns 0
     * and leaves the input untouched. A caller that assumed they agreed would
     * be wrong. */
    float v[3] = {0.0f, 0.0f, 0.0f};
    CHECK_NEAR(rsNormalize(v), 0.0f, kTol);
    CHECK_NEAR(v[0], 0.0f, kTol);
    CHECK_NEAR(v[1], 0.0f, kTol);
    CHECK_NEAR(v[2], 0.0f, kTol);
}

TEST(free_dot_matches_the_definition)
{
    float a[3] = {1.0f, 2.0f, 3.0f};
    float b[3] = {4.0f, 5.0f, 6.0f};
    CHECK_NEAR(rsDot(a, b), 32.0f, 1e-4f);

    float x[3] = {1.0f, 0.0f, 0.0f};
    float y[3] = {0.0f, 1.0f, 0.0f};
    CHECK_NEAR(rsDot(x, y), 0.0f, kTol);
}

TEST(free_cross_is_right_handed)
{
    float a[3] = {1.0f, 2.0f, 3.0f};
    float b[3] = {4.0f, 5.0f, 6.0f};
    float out[3] = {0.0f, 0.0f, 0.0f};

    rsCross(a, b, out);
    CHECK_NEAR(out[0], -3.0f, 1e-4f);
    CHECK_NEAR(out[1], 6.0f, 1e-4f);
    CHECK_NEAR(out[2], -3.0f, 1e-4f);

    /* Perpendicular to both inputs, which is the property rather than the
     * arithmetic. */
    CHECK_NEAR(rsDot(out, a), 0.0f, 1e-3f);
    CHECK_NEAR(rsDot(out, b), 0.0f, 1e-3f);
}

TEST(free_scale_multiplies_every_component)
{
    float v[3] = {1.0f, -2.0f, 3.0f};
    rsScaleVec(v, 2.5f);
    CHECK_NEAR(v[0], 2.5f, kTol);
    CHECK_NEAR(v[1], -5.0f, kTol);
    CHECK_NEAR(v[2], 7.5f, kTol);

    rsScaleVec(v, 0.0f);
    CHECK_NEAR(rsLength(v), 0.0f, kTol);
}

/* --- the random helpers -------------------------------------------------- */

TEST(rand_int_stays_inside_the_half_open_range)
{
    /* The contract is a range, so that is what is asserted -- no seed needed and
     * nothing to flake. rsRandi(x) is rand() % x, so 0 <= result < x. */
    srand(1);
    for (int i = 0; i < 500; i++) {
        const int r = rsRandi(10);
        CHECK(r >= 0);
        CHECK(r < 10);
    }

    /* A bound of 1 leaves exactly one legal answer. */
    for (int i = 0; i < 10; i++)
        CHECK(rsRandi(1) == 0);
}

TEST(rand_float_stays_inside_the_closed_range)
{
    /* rsRandf(x) is x * rand()/RAND_MAX, so 0 <= result <= x, inclusive at the
     * top because rand() can return RAND_MAX. */
    srand(2);
    for (int i = 0; i < 500; i++) {
        const float r = rsRandf(4.0f);
        CHECK(r >= 0.0f);
        CHECK(r <= 4.0f);
    }

    /* A range of zero collapses to a point regardless of the draw. */
    for (int i = 0; i < 10; i++)
        CHECK_NEAR(rsRandf(0.0f), 0.0f, kTol);
}

TEST(rand_helpers_are_reproducible_from_a_seed)
{
    /* Both wrap rand(), so seeding fixes the sequence. This is what makes them
     * usable in a deterministic test at all, and it is the property a future
     * change to a different generator would have to preserve. */
    srand(12345);
    int firstInts[8];
    float firstFloats[8];
    for (int i = 0; i < 8; i++) firstInts[i] = rsRandi(1000);
    for (int i = 0; i < 8; i++) firstFloats[i] = rsRandf(1.0f);

    srand(12345);
    for (int i = 0; i < 8; i++) CHECK(rsRandi(1000) == firstInts[i]);
    for (int i = 0; i < 8; i++) CHECK_NEAR(rsRandf(1.0f), firstFloats[i], 0.0f);
}
