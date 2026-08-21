/* Tests for the rsMath vector, quaternion and fast-trig primitives.
 *
 * The helios file, ported unchanged. rsVec.h and rsTrigonometry.h are identical
 * between the two submodules, and rsVec.cpp, rsQuat.cpp, rsMatrix.cpp and
 * rsMath.h differ only in include style -- angle brackets with a directory
 * prefix here, quotes without one there. None of the arithmetic differs, so the
 * same expectations and the same measured rsAtan2f bound hold.
 *
 * These are the widest pure-maths surface in the submodule and have no GL or
 * platform coupling, so every expectation below is derived from the definition
 * of the operation rather than read off a run.
 *
 * Column-order matrices, as the comment in rsMatrix.h notes, matching OpenGL.
 */

#include "harness.h"

#include "rsMath/rsMath.h"
#include "rsMath/rsVec.h"
#include "rsMath/rsQuat.h"
#include "rsMath/rsMatrix.h"
#include "rsMath/rsTrigonometry.h"

#include <math.h>

namespace {

const float kTol = 1e-5f;

/* rsAtan2f is a deliberate approximation, not a wrapper -- two linear arms over
 * the half-planes, no series, no table. Its worst-case error was *measured*
 * rather than guessed: sweeping 200,000 angles over the full circle puts it at
 * 0.0711 rad (4.08 degrees), near -2.84 rad, deep in the x < 0 arm.
 *
 * 0.075 is that bound with a little headroom. It is a wide tolerance and it is
 * meant to be: the contract of this function is "cheap and roughly right", and
 * pinning it tighter would be pinning float noise rather than behaviour. It
 * still discriminates -- an arm with a wrong constant, or the two arms swapped,
 * is off by radians, not hundredths. */
const float kAtanTol = 0.075f;

}  // namespace

/* --- rsVec ---------------------------------------------------------------- */

TEST(vec_length_is_euclidean)
{
    /* 3-4-5, so the expectation does not depend on a square root landing the
     * same way twice. */
    rsVec v(3.0f, 4.0f, 0.0f);
    CHECK_NEAR(v.length(), 5.0f, kTol);

    /* All three components non-zero, and another exact triple: (1,2,2) has
     * length 3. Without this the z term could be dropped entirely and every
     * assertion above would still hold. */
    rsVec spatial(1.0f, 2.0f, 2.0f);
    CHECK_NEAR(spatial.length(), 3.0f, kTol);

    rsVec zero(0.0f, 0.0f, 0.0f);
    CHECK_NEAR(zero.length(), 0.0f, kTol);
}

TEST(vec_normalize_returns_the_prior_length_and_leaves_a_unit_vector)
{
    /* The return value is the length *before* scaling -- easy to get backwards,
     * and callers rely on it to avoid a second sqrt. */
    rsVec v(3.0f, 4.0f, 0.0f);
    CHECK_NEAR(v.normalize(), 5.0f, kTol);
    CHECK_NEAR(v.length(), 1.0f, kTol);
    CHECK_NEAR(v[0], 0.6f, kTol);
    CHECK_NEAR(v[1], 0.8f, kTol);
}

TEST(vec_normalize_of_a_zero_vector_yields_positive_y)
{
    /* A zero vector has no direction, so normalize picks one rather than
     * dividing by zero, and reports a length of 0 so the caller can tell. */
    rsVec v(0.0f, 0.0f, 0.0f);
    CHECK_NEAR(v.normalize(), 0.0f, kTol);
    CHECK_NEAR(v[0], 0.0f, kTol);
    CHECK_NEAR(v[1], 1.0f, kTol);
    CHECK_NEAR(v[2], 0.0f, kTol);
    CHECK_NEAR(v.length(), 1.0f, kTol);
}

TEST(vec_dot_is_zero_for_perpendicular_and_length_squared_for_self)
{
    rsVec x(1.0f, 0.0f, 0.0f);
    rsVec y(0.0f, 1.0f, 0.0f);
    CHECK_NEAR(x.dot(y), 0.0f, kTol);

    rsVec v(3.0f, 4.0f, 0.0f);
    CHECK_NEAR(v.dot(v), 25.0f, 1e-4f);

    /* Antiparallel is the negative of the product of the lengths. */
    rsVec back(-3.0f, -4.0f, 0.0f);
    CHECK_NEAR(v.dot(back), -25.0f, 1e-4f);

    /* Every component distinct and non-zero: 1*4 + 2*5 + 3*6 = 32. The cases
     * above all have z = 0, so the z term could carry the wrong sign and none
     * of them would notice. */
    rsVec a(1.0f, 2.0f, 3.0f);
    rsVec b(4.0f, 5.0f, 6.0f);
    CHECK_NEAR(a.dot(b), 32.0f, 1e-4f);
}

TEST(vec_cross_is_right_handed)
{
    rsVec x(1.0f, 0.0f, 0.0f);
    rsVec y(0.0f, 1.0f, 0.0f);

    rsVec result;
    result.cross(x, y);
    CHECK_NEAR(result[0], 0.0f, kTol);
    CHECK_NEAR(result[1], 0.0f, kTol);
    CHECK_NEAR(result[2], 1.0f, kTol);

    /* Reversing the operands negates it -- the property that catches an
     * operand swap inside the implementation. */
    result.cross(y, x);
    CHECK_NEAR(result[2], -1.0f, kTol);

    /* Axis-aligned inputs leave two of the three output components zero, so a
     * swapped operand pair in one row is invisible above. (1,2,3) x (4,5,6)
     * exercises all three rows with distinct values. */
    rsVec p(1.0f, 2.0f, 3.0f);
    rsVec q(4.0f, 5.0f, 6.0f);
    result.cross(p, q);
    CHECK_NEAR(result[0], -3.0f, 1e-4f);
    CHECK_NEAR(result[1], 6.0f, 1e-4f);
    CHECK_NEAR(result[2], -3.0f, 1e-4f);
}

TEST(vec_cross_of_parallel_vectors_is_zero)
{
    rsVec a(2.0f, -1.0f, 3.0f);
    rsVec b(4.0f, -2.0f, 6.0f);   /* exactly 2a */
    rsVec result;
    result.cross(a, b);
    CHECK_NEAR(result.length(), 0.0f, 1e-4f);
}

TEST(vec_almost_equal_measures_distance_not_per_component_difference)
{
    /* The distinction matters: a vector off by exactly the tolerance in each of
     * the three components is sqrt(3) times the tolerance away, and must not
     * compare equal. A per-component implementation would say it does. */
    rsVec origin(0.0f, 0.0f, 0.0f);
    rsVec corner(0.1f, 0.1f, 0.1f);          /* distance ~0.1732 */
    CHECK(origin.almostEqual(corner, 0.1f) == 0);
    CHECK(origin.almostEqual(corner, 0.2f) == 1);

    rsVec near(0.05f, 0.0f, 0.0f);
    CHECK(origin.almostEqual(near, 0.1f) == 1);
    CHECK(origin.almostEqual(origin, 0.0f) == 1);   /* boundary is inclusive */
}

TEST(vec_arithmetic_operators_are_componentwise)
{
    rsVec a(1.0f, 2.0f, 3.0f);
    rsVec b(4.0f, 6.0f, 8.0f);

    rsVec sum = a + b;
    CHECK_NEAR(sum[0], 5.0f, kTol);
    CHECK_NEAR(sum[2], 11.0f, kTol);

    rsVec difference = b - a;
    CHECK_NEAR(difference[0], 3.0f, kTol);
    CHECK_NEAR(difference[1], 4.0f, kTol);

    rsVec scaled = a * 2.0f;
    CHECK_NEAR(scaled[1], 4.0f, kTol);

    rsVec divided = b / 2.0f;
    CHECK_NEAR(divided[2], 4.0f, kTol);
}

/* --- rsAtan2f ------------------------------------------------------------- */

TEST(rs_atan2f_approximates_atan2_across_the_whole_circle)
{
    /* Swept rather than spot-checked: the approximation is piecewise, and a
     * mistake in one arm is invisible if you only sample the other. 36 steps
     * crosses every quadrant boundary. */
    for (int i = 0; i < 36; i++) {
        const float angle = -RS_PI + (float)i * (RS_PIx2 / 36.0f);
        const float y = sinf(angle);
        const float x = cosf(angle);
        CHECK_NEAR(rsAtan2f(y, x), atan2f(y, x), kAtanTol);
    }
}

TEST(rs_atan2f_puts_the_axes_where_atan2_does)
{
    CHECK_NEAR(rsAtan2f(0.0f, 1.0f), 0.0f, kAtanTol);           /* +x */
    CHECK_NEAR(rsAtan2f(1.0f, 0.0f), RS_PIo2, kAtanTol);        /* +y */
    CHECK_NEAR(rsAtan2f(-1.0f, 0.0f), -RS_PIo2, kAtanTol);      /* -y */
    CHECK_NEAR(rsAtan2f(0.0f, -1.0f), RS_PI, kAtanTol);         /* -x */
}

TEST(rs_atan2f_sign_follows_y)
{
    /* The implementation computes a positive angle and negates on y < 0, so a
     * dropped sign is a whole-half-plane error. */
    for (int i = 1; i < 8; i++) {
        const float angle = (float)i * (RS_PI / 8.0f);
        const float y = sinf(angle), x = cosf(angle);
        CHECK(rsAtan2f(y, x) > 0.0f);
        CHECK(rsAtan2f(-y, x) < 0.0f);
    }
}

/* --- rsQuat --------------------------------------------------------------- */

TEST(quat_make_with_a_negligible_angle_is_the_identity)
{
    /* Below RS_EPSILON the half-angle sine underflows to nothing useful, so the
     * constructor short-circuits to the identity rather than producing a
     * near-zero axis. */
    rsQuat q;
    q.make(0.0f, rsVec(0.0f, 1.0f, 0.0f));
    CHECK_NEAR(q[0], 0.0f, kTol);
    CHECK_NEAR(q[1], 0.0f, kTol);
    CHECK_NEAR(q[2], 0.0f, kTol);
    CHECK_NEAR(q[3], 1.0f, kTol);
}

TEST(quat_make_encodes_the_half_angle)
{
    /* A quaternion for angle a about unit axis n is (n*sin(a/2), cos(a/2)).
     * Half is the part that is easy to get wrong and invisible at a = 0. */
    rsQuat q;
    q.make(RS_PIo2, rsVec(0.0f, 1.0f, 0.0f));
    CHECK_NEAR(q[0], 0.0f, kTol);
    CHECK_NEAR(q[1], sinf(RS_PIo2 * 0.5f), kTol);
    CHECK_NEAR(q[2], 0.0f, kTol);
    CHECK_NEAR(q[3], cosf(RS_PIo2 * 0.5f), kTol);

    /* Unit axis in, unit quaternion out. */
    const float norm = sqrtf(q[0]*q[0] + q[1]*q[1] + q[2]*q[2] + q[3]*q[3]);
    CHECK_NEAR(norm, 1.0f, kTol);
}

TEST(quat_slerp_returns_its_endpoints)
{
    rsQuat a, b, result;
    a.make(0.0f, rsVec(0.0f, 1.0f, 0.0f));
    b.make(RS_PIo2, rsVec(0.0f, 1.0f, 0.0f));

    result.slerp(a, b, 0.0f);
    for (int i = 0; i < 4; i++) CHECK_NEAR(result[i], a[i], 1e-4f);

    result.slerp(a, b, 1.0f);
    for (int i = 0; i < 4; i++) CHECK_NEAR(result[i], b[i], 1e-4f);
}

TEST(quat_slerp_midpoint_is_the_half_rotation_and_stays_unit)
{
    /* Interpolating halfway between identity and a quarter turn about the same
     * axis must give the eighth turn -- that is what distinguishes spherical
     * interpolation from a componentwise lerp, which would come out short. */
    rsQuat a, b, result, expected;
    a.make(0.0f, rsVec(0.0f, 1.0f, 0.0f));
    b.make(RS_PIo2, rsVec(0.0f, 1.0f, 0.0f));
    expected.make(RS_PIo2 * 0.5f, rsVec(0.0f, 1.0f, 0.0f));

    result.slerp(a, b, 0.5f);
    for (int i = 0; i < 4; i++) CHECK_NEAR(result[i], expected[i], 1e-4f);

    const float norm = sqrtf(result[0]*result[0] + result[1]*result[1]
                             + result[2]*result[2] + result[3]*result[3]);
    CHECK_NEAR(norm, 1.0f, 1e-4f);
}

TEST(quat_slerp_between_identical_rotations_is_that_rotation)
{
    /* Exercises the near-parallel shortcut, where acos would divide by a sine
     * of zero. */
    rsQuat a, result;
    a.make(RS_PIo2, rsVec(0.0f, 0.0f, 1.0f));
    result.slerp(a, a, 0.5f);
    for (int i = 0; i < 4; i++) CHECK_NEAR(result[i], a[i], 1e-4f);
}

/* --- rsMatrix ------------------------------------------------------------- */

TEST(matrix_identity_is_ones_on_the_diagonal)
{
    rsMatrix mat;
    mat.identity();
    for (int i = 0; i < 16; i++)
        CHECK_NEAR(mat.m[i], (i % 5 == 0) ? 1.0f : 0.0f, kTol);
}

TEST(matrix_set_and_get_round_trip)
{
    float in[16], out[16];
    for (int i = 0; i < 16; i++) in[i] = (float)i * 0.5f;

    rsMatrix mat;
    mat.set(in);
    mat.get(out);
    for (int i = 0; i < 16; i++) CHECK_NEAR(out[i], in[i], kTol);
}

TEST(matrix_translation_lands_in_the_fourth_column)
{
    /* Column order, as rsMatrix.h documents: the translation occupies 12, 13
     * and 14. A row-order implementation would put it at 3, 7, 11 -- this is
     * the assertion that catches a transposed matrix. */
    rsMatrix mat;
    mat.makeTranslate(2.0f, 3.0f, 4.0f);
    CHECK_NEAR(mat.m[12], 2.0f, kTol);
    CHECK_NEAR(mat.m[13], 3.0f, kTol);
    CHECK_NEAR(mat.m[14], 4.0f, kTol);
    CHECK_NEAR(mat.m[15], 1.0f, kTol);
    CHECK_NEAR(mat.m[3], 0.0f, kTol);
    CHECK_NEAR(mat.m[7], 0.0f, kTol);
}
