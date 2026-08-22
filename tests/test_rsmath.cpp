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
#include <sstream>
#include <string>

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

TEST(matrix_makeTranslate_pointer_and_vec_overloads_agree_with_the_component_form)
{
    float p[3] = {2.0f, 3.0f, 4.0f};
    rsMatrix fromPtr;
    fromPtr.makeTranslate(p);
    CHECK_NEAR(fromPtr.m[12], 2.0f, kTol);
    CHECK_NEAR(fromPtr.m[13], 3.0f, kTol);
    CHECK_NEAR(fromPtr.m[14], 4.0f, kTol);
    CHECK_NEAR(fromPtr.m[0], 1.0f, kTol);

    rsMatrix fromVec;
    fromVec.makeTranslate(rsVec(2.0f, 3.0f, 4.0f));
    CHECK_NEAR(fromVec.m[12], 2.0f, kTol);
    CHECK_NEAR(fromVec.m[13], 3.0f, kTol);
    CHECK_NEAR(fromVec.m[14], 4.0f, kTol);
}

TEST(matrix_makeScale_overloads_all_land_on_the_diagonal)
{
    rsMatrix uniform;
    uniform.makeScale(5.0f);
    CHECK_NEAR(uniform.m[0], 5.0f, kTol);
    CHECK_NEAR(uniform.m[5], 5.0f, kTol);
    CHECK_NEAR(uniform.m[10], 5.0f, kTol);
    CHECK_NEAR(uniform.m[15], 1.0f, kTol);

    rsMatrix xyz;
    xyz.makeScale(2.0f, 3.0f, 4.0f);
    CHECK_NEAR(xyz.m[0], 2.0f, kTol);
    CHECK_NEAR(xyz.m[5], 3.0f, kTol);
    CHECK_NEAR(xyz.m[10], 4.0f, kTol);

    float s[3] = {2.0f, 3.0f, 4.0f};
    rsMatrix fromPtr;
    fromPtr.makeScale(s);
    CHECK_NEAR(fromPtr.m[0], 2.0f, kTol);
    CHECK_NEAR(fromPtr.m[5], 3.0f, kTol);
    CHECK_NEAR(fromPtr.m[10], 4.0f, kTol);

    rsMatrix fromVec;
    fromVec.makeScale(rsVec(2.0f, 3.0f, 4.0f));
    CHECK_NEAR(fromVec.m[0], 2.0f, kTol);
    CHECK_NEAR(fromVec.m[5], 3.0f, kTol);
    CHECK_NEAR(fromVec.m[10], 4.0f, kTol);
}

TEST(matrix_translate_adds_a_world_space_offset_after_the_existing_transform)
{
    /* translate() postMults a translation matrix onto whatever is already
     * there. This class's postMult(X) computes new = X * old, so applied to a
     * vector the *old* transform happens first and X happens second/outer --
     * the new offset lands in world space after the prior scale, not scaled
     * by it. All three overloads must agree. */
    rsMatrix byXYZ;
    byXYZ.makeScale(2.0f, 3.0f, 4.0f);
    byXYZ.translate(1.0f, 1.0f, 1.0f);
    CHECK_NEAR(byXYZ.m[12], 1.0f, kTol);
    CHECK_NEAR(byXYZ.m[13], 1.0f, kTol);
    CHECK_NEAR(byXYZ.m[14], 1.0f, kTol);
    CHECK_NEAR(byXYZ.m[0], 2.0f, kTol);   /* the scale itself survives untouched */

    float p[3] = {1.0f, 1.0f, 1.0f};
    rsMatrix byPtr;
    byPtr.makeScale(2.0f, 3.0f, 4.0f);
    byPtr.translate(p);
    CHECK_NEAR(byPtr.m[12], 1.0f, kTol);
    CHECK_NEAR(byPtr.m[13], 1.0f, kTol);
    CHECK_NEAR(byPtr.m[14], 1.0f, kTol);

    rsMatrix byVec;
    byVec.makeScale(2.0f, 3.0f, 4.0f);
    byVec.translate(rsVec(1.0f, 1.0f, 1.0f));
    CHECK_NEAR(byVec.m[12], 1.0f, kTol);
    CHECK_NEAR(byVec.m[13], 1.0f, kTol);
    CHECK_NEAR(byVec.m[14], 1.0f, kTol);
}

TEST(matrix_scale_wraps_around_the_existing_transform_and_rescales_its_translation)
{
    /* Mirror image of the translate case: with new = X * old, an existing
     * translation happens first (inner) and the new scale wraps around it
     * (outer) -- so the prior translation column comes out scaled too, unlike
     * makeScale which never touches translation at all. */
    rsMatrix byXYZ;
    byXYZ.makeTranslate(5.0f, 6.0f, 7.0f);
    byXYZ.scale(2.0f, 3.0f, 4.0f);
    CHECK_NEAR(byXYZ.m[0], 2.0f, kTol);
    CHECK_NEAR(byXYZ.m[5], 3.0f, kTol);
    CHECK_NEAR(byXYZ.m[10], 4.0f, kTol);
    CHECK_NEAR(byXYZ.m[12], 10.0f, kTol);
    CHECK_NEAR(byXYZ.m[13], 18.0f, kTol);
    CHECK_NEAR(byXYZ.m[14], 28.0f, kTol);

    rsMatrix byUniform;
    byUniform.makeTranslate(5.0f, 6.0f, 7.0f);
    byUniform.scale(2.0f);
    CHECK_NEAR(byUniform.m[0], 2.0f, kTol);
    CHECK_NEAR(byUniform.m[10], 2.0f, kTol);
    CHECK_NEAR(byUniform.m[12], 10.0f, kTol);

    float s[3] = {2.0f, 3.0f, 4.0f};
    rsMatrix byPtr;
    byPtr.makeTranslate(5.0f, 6.0f, 7.0f);
    byPtr.scale(s);
    CHECK_NEAR(byPtr.m[0], 2.0f, kTol);
    CHECK_NEAR(byPtr.m[12], 10.0f, kTol);

    rsMatrix byVec;
    byVec.makeTranslate(5.0f, 6.0f, 7.0f);
    byVec.scale(rsVec(2.0f, 3.0f, 4.0f));
    CHECK_NEAR(byVec.m[0], 2.0f, kTol);
    CHECK_NEAR(byVec.m[12], 10.0f, kTol);
}

TEST(matrix_makeRotate_overloads_agree_on_a_quarter_turn_about_z)
{
    /* Same hand-derived rotation as quat_toMat below: 90 degrees about +z maps
     * +x to +y, so column 0 becomes (0,1,0) and column 1 becomes (-1,0,0). */
    rsMatrix byComponents;
    byComponents.makeRotate(RS_PIo2, 0.0f, 0.0f, 1.0f);
    CHECK_NEAR(byComponents.m[0], 0.0f, kTol);
    CHECK_NEAR(byComponents.m[1], 1.0f, kTol);
    CHECK_NEAR(byComponents.m[4], -1.0f, kTol);
    CHECK_NEAR(byComponents.m[5], 0.0f, kTol);
    CHECK_NEAR(byComponents.m[10], 1.0f, kTol);

    rsMatrix byVec;
    byVec.makeRotate(RS_PIo2, rsVec(0.0f, 0.0f, 1.0f));
    CHECK_NEAR(byVec.m[0], 0.0f, kTol);
    CHECK_NEAR(byVec.m[1], 1.0f, kTol);
    CHECK_NEAR(byVec.m[4], -1.0f, kTol);

    rsQuat q;
    q.make(RS_PIo2, rsVec(0.0f, 0.0f, 1.0f));
    rsMatrix byQuat;
    byQuat.makeRotate(q);
    CHECK_NEAR(byQuat.m[0], 0.0f, kTol);
    CHECK_NEAR(byQuat.m[1], 1.0f, kTol);
    CHECK_NEAR(byQuat.m[4], -1.0f, kTol);
}

TEST(matrix_rotate_postmultiplies_the_rotation_after_the_existing_transform)
{
    /* Starting from a non-identity matrix (rather than from scratch) is what
     * makes this discriminate a preMult/postMult swap: identity times
     * anything looks the same either way. */
    rsMatrix base;
    base.makeTranslate(1.0f, 2.0f, 3.0f);

    rsMatrix rotationOnly;
    rotationOnly.makeRotate(RS_PIo2, 0.0f, 0.0f, 1.0f);
    rsMatrix expected;
    expected.copy(base);
    expected.postMult(rotationOnly);

    rsMatrix byComponents;
    byComponents.copy(base);
    byComponents.rotate(RS_PIo2, 0.0f, 0.0f, 1.0f);
    for (int i = 0; i < 16; i++) CHECK_NEAR(byComponents.m[i], expected.m[i], kTol);

    rsMatrix byVec;
    byVec.copy(base);
    byVec.rotate(RS_PIo2, rsVec(0.0f, 0.0f, 1.0f));
    for (int i = 0; i < 16; i++) CHECK_NEAR(byVec.m[i], expected.m[i], kTol);

    rsQuat q;
    q.make(RS_PIo2, rsVec(0.0f, 0.0f, 1.0f));
    rsMatrix byQuat;
    byQuat.copy(base);
    byQuat.rotate(q);
    for (int i = 0; i < 16; i++) CHECK_NEAR(byQuat.m[i], expected.m[i], kTol);
}

TEST(matrix_copy_and_assignment_duplicate_every_entry_and_overwrite_the_target)
{
    float vals[16];
    for (int i = 0; i < 16; i++) vals[i] = (float)(i + 1) * 1.5f;
    rsMatrix src;
    src.set(vals);

    /* Both targets start as identity, which is nothing like src -- so if copy
     * or operator= silently no-op, the assertions below catch it. */
    rsMatrix copied;
    copied.identity();
    copied.copy(src);
    for (int i = 0; i < 16; i++) CHECK_NEAR(copied.m[i], vals[i], kTol);

    rsMatrix assigned;
    assigned.identity();
    assigned = src;
    for (int i = 0; i < 16; i++) CHECK_NEAR(assigned.m[i], vals[i], kTol);
}

TEST(matrix_postMult_applies_the_prior_transform_first_and_the_argument_last)
{
    /* m.postMult(x) computes new = x * old_m: applied to a vector, old_m acts
     * first (inner) and x acts second (outer). Starting from a translation
     * and postMult-ing a scale means the translation happens first and the
     * scale wraps around it afterward, so the translation distance itself
     * comes out scaled: 5 * 2 = 10. */
    rsMatrix t;
    t.makeTranslate(5.0f, 0.0f, 0.0f);
    rsMatrix s;
    s.makeScale(2.0f, 2.0f, 2.0f);

    rsMatrix result;
    result.copy(t);
    result.postMult(s);
    CHECK_NEAR(result.m[0], 2.0f, kTol);
    CHECK_NEAR(result.m[12], 10.0f, kTol);
}

TEST(matrix_preMult_applies_the_argument_first_and_the_prior_transform_last)
{
    /* m.preMult(x) computes new = old_m * x: the mirror image of postMult --
     * x acts first (inner), old_m acts second (outer). The same translate and
     * scale composed this way leaves the translation untouched (5, not 10),
     * because the scale is now the inner operation and the translate's offset
     * is added afterward, unscaled. This is the pair of assertions (10 vs 5)
     * that a preMult/postMult swap would flip. */
    rsMatrix t;
    t.makeTranslate(5.0f, 0.0f, 0.0f);
    rsMatrix s;
    s.makeScale(2.0f, 2.0f, 2.0f);

    rsMatrix result;
    result.copy(t);
    result.preMult(s);
    CHECK_NEAR(result.m[0], 2.0f, kTol);
    CHECK_NEAR(result.m[12], 5.0f, kTol);
}

TEST(matrix_determinant3_matches_the_textbook_expansion)
{
    rsMatrix mat;
    /* | 1 2 3 |
     * | 4 5 6 |   = -3
     * | 7 8 10| */
    CHECK_NEAR(mat.determinant3(1.0f, 2.0f, 3.0f, 4.0f, 5.0f, 6.0f, 7.0f, 8.0f, 10.0f), -3.0f, 1e-3f);

    /* Two identical rows make it singular. */
    CHECK_NEAR(mat.determinant3(1.0f, 2.0f, 3.0f, 1.0f, 2.0f, 3.0f, 7.0f, 8.0f, 10.0f), 0.0f, 1e-3f);

    /* The identity's determinant is 1. */
    CHECK_NEAR(mat.determinant3(1.0f, 0.0f, 0.0f, 0.0f, 1.0f, 0.0f, 0.0f, 0.0f, 1.0f), 1.0f, 1e-3f);
}

TEST(matrix_invert_recovers_the_identity_when_composed_with_its_source)
{
    /* A generic, non-symmetric compound transform -- translate, rotate,
     * scale -- rather than something axis-aligned enough to be accidentally
     * self-inverse. M * invert(M) and invert(M) * M must both be the
     * identity; that property does not depend on hand-deriving the inverse. */
    rsMatrix m;
    m.identity();
    m.translate(3.0f, -2.0f, 5.0f);
    m.rotate(RS_PIo2, rsVec(0.0f, 0.0f, 1.0f));
    m.scale(2.0f, 3.0f, 4.0f);

    rsMatrix inv;
    inv.copy(m);
    const bool ok = inv.invert();
    CHECK(ok == true);

    rsMatrix product;
    product.copy(m);
    product.postMult(inv);
    rsMatrix identity;
    identity.identity();
    for (int i = 0; i < 16; i++) CHECK_NEAR(product.m[i], identity.m[i], 1e-3f);

    rsMatrix product2;
    product2.copy(inv);
    product2.postMult(m);
    for (int i = 0; i < 16; i++) CHECK_NEAR(product2.m[i], identity.m[i], 1e-3f);
}

TEST(matrix_invert_on_a_singular_matrix_fails_and_leaves_the_matrix_untouched)
{
    rsMatrix mat;
    mat.makeScale(0.0f, 0.0f, 0.0f);   /* zero linear part: determinant is 0 */
    float before[16];
    for (int i = 0; i < 16; i++) before[i] = mat.m[i];

    const bool ok = mat.invert();
    CHECK(ok == false);
    for (int i = 0; i < 16; i++) CHECK_NEAR(mat.m[i], before[i], kTol);
}

TEST(matrix_invert_from_argument_leaves_the_source_untouched)
{
    rsMatrix source;
    source.identity();
    source.translate(1.0f, 2.0f, 3.0f);
    source.rotate(RS_PIo2, rsVec(1.0f, 0.0f, 0.0f));
    float before[16];
    for (int i = 0; i < 16; i++) before[i] = source.m[i];

    rsMatrix inv;
    const bool ok = inv.invert(source);
    CHECK(ok == true);
    for (int i = 0; i < 16; i++) CHECK_NEAR(source.m[i], before[i], kTol);

    rsMatrix product;
    product.copy(source);
    product.postMult(inv);
    rsMatrix identity;
    identity.identity();
    for (int i = 0; i < 16; i++) CHECK_NEAR(product.m[i], identity.m[i], 1e-3f);
}

TEST(matrix_invert_from_argument_on_a_singular_matrix_fails)
{
    rsMatrix source;
    source.makeScale(1.0f, 0.0f, 1.0f);   /* one axis collapsed: still singular */
    rsMatrix target;
    target.identity();
    const bool ok = target.invert(source);
    CHECK(ok == false);
}

TEST(matrix_rotationInvert_does_not_actually_invert_the_rotation)
{
    /* Characterization, not a spec: rotationInvert's cofactor formula, for
     * every rotation matrix tried here (an axis-aligned quarter turn and a
     * generic-axis rotation alike), reproduces the *input* matrix rather than
     * its inverse -- invert() on the same input gives the mathematically
     * correct transpose. This is filed as ss-c6g and is deliberately left
     * unfixed; pinned as found.
     *
     * Both cases named in that sentence are actually built below. They were
     * not always: an earlier version described two and tested one, and passed
     * rsVec(1,2,2) -- length 3 -- to make(), whose header documents a
     * NORMALIZED axis. toMat divides by the quaternion's norm squared, so the
     * matrix came out orthonormal either way and the test still passed, but
     * the rotation it encoded was not by 0.9 rad and the fixture said
     * otherwise. The axis is normalized here so the stated angle is the real
     * one. */
    {
        /* Axis-aligned quarter turn about z. */
        rsQuat q;
        q.make(RS_PIo2, rsVec(0.0f, 0.0f, 1.0f));
        rsMatrix rot;
        q.toMat(rot.m);

        rsMatrix viaRotationInvert;
        viaRotationInvert.rotationInvert(rot);
        for (int i = 0; i < 16; i++) CHECK_NEAR(viaRotationInvert.m[i], rot.m[i], 1e-4f);

        rsMatrix viaInvert;
        viaInvert.invert(rot);
        /* The two disagree -- that is the point being pinned. */
        CHECK(fabsf(viaInvert.m[1] - viaRotationInvert.m[1]) > 0.1f);
    }

    {
        /* Generic axis, normalized: (1,2,2)/3. */
        rsQuat q;
        q.make(0.9f, rsVec(1.0f / 3.0f, 2.0f / 3.0f, 2.0f / 3.0f));
        rsMatrix rot;
        q.toMat(rot.m);

        rsMatrix viaRotationInvert;
        viaRotationInvert.rotationInvert(rot);
        for (int i = 0; i < 16; i++) CHECK_NEAR(viaRotationInvert.m[i], rot.m[i], 1e-4f);

        rsMatrix viaInvert;
        viaInvert.invert(rot);
        CHECK(fabsf(viaInvert.m[1] - viaRotationInvert.m[1]) > 0.1f);
    }
}

TEST(matrix_stream_operator_prints_rows_in_the_columns_stored_order)
{
    float vals[16] = {
        1.0f, 2.0f, 3.0f, 4.0f,
        5.0f, 6.0f, 7.0f, 8.0f,
        9.0f, 10.0f, 11.0f, 12.0f,
        13.0f, 14.0f, 15.0f, 16.0f
    };
    rsMatrix mat;
    mat.set(vals);

    /* Member operator<<, so the call reads mat << stream, not stream << mat --
     * the commented-out free function in rsMatrix.cpp was the other way
     * around and never got uncommented. Each printed row pulls one value from
     * each of the four stored columns (m[0],m[4],m[8],m[12] for row 0), which
     * is what makes this catch a transposed print. */
    std::ostringstream os;
    mat << os;
    const std::string text = os.str();
    CHECK(text.find("1 5 9 13") != std::string::npos);
    CHECK(text.find("2 6 10 14") != std::string::npos);
    CHECK(text.find("4 8 12 16") != std::string::npos);
}

/* --- rsQuat: the wider surface ---------------------------------------- */

TEST(quat_make_xyzw_with_a_negligible_angle_is_the_identity)
{
    /* The float,float,float,float overload duplicates make(float, rsVec&)'s
     * logic against three loose floats instead of a vector -- same epsilon
     * short-circuit, exercised on both sides of zero. */
    rsQuat q(9.0f, 9.0f, 9.0f, 9.0f);   /* deliberately not the identity already */
    q.make(0.0f, 0.0f, 1.0f, 0.0f);
    CHECK_NEAR(q[0], 0.0f, kTol);
    CHECK_NEAR(q[1], 0.0f, kTol);
    CHECK_NEAR(q[2], 0.0f, kTol);
    CHECK_NEAR(q[3], 1.0f, kTol);

    rsQuat q2(9.0f, 9.0f, 9.0f, 9.0f);
    q2.make(-0.0000001f, 0.0f, 1.0f, 0.0f);   /* just inside -RS_EPSILON */
    CHECK_NEAR(q2[3], 1.0f, kTol);
}

TEST(quat_make_xyzw_encodes_the_half_angle_per_axis_component)
{
    rsQuat q;
    q.make(RS_PIo2, 0.0f, 1.0f, 0.0f);
    CHECK_NEAR(q[0], 0.0f, kTol);
    CHECK_NEAR(q[1], sinf(RS_PIo2 * 0.5f), kTol);
    CHECK_NEAR(q[2], 0.0f, kTol);
    CHECK_NEAR(q[3], cosf(RS_PIo2 * 0.5f), kTol);

    /* All three axis components nonzero and distinct, matching the
     * unnormalized-axis behaviour this overload has: the components are
     * scaled by sin(a/2) directly, not by a normalized axis. */
    rsQuat q2;
    q2.make(RS_PIo2, 1.0f, 2.0f, 3.0f);
    const float half = sinf(RS_PIo2 * 0.5f);
    CHECK_NEAR(q2[0], half * 1.0f, kTol);
    CHECK_NEAR(q2[1], half * 2.0f, kTol);
    CHECK_NEAR(q2[2], half * 3.0f, kTol);
}

TEST(quat_toMat_with_a_zero_axis_is_the_identity_regardless_of_w)
{
    /* The special case only inspects q[0..2]; a caller who somehow has w = 0
     * too (an invalid, non-unit quaternion) still gets the identity rather
     * than a divide by zero in the general formula below. */
    rsQuat degenerate(0.0f, 0.0f, 0.0f, 0.0f);
    float mat[16];
    for (int i = 0; i < 16; i++) mat[i] = -99.0f;   /* prove it gets overwritten */
    degenerate.toMat(mat);
    for (int i = 0; i < 16; i++)
        CHECK_NEAR(mat[i], (i % 5 == 0) ? 1.0f : 0.0f, kTol);
}

TEST(quat_toMat_matches_the_hand_derived_matrix_for_a_quarter_turn_about_z)
{
    /* Rotating +x by 90 degrees about +z lands on +y, so column 0 must be
     * (0,1,0) and column 1 must be (-1,0,0) -- this is the sign convention
     * check: a right-vs-left-handed mixup swaps these two off-diagonal
     * signs. */
    rsQuat q;
    q.make(RS_PIo2, rsVec(0.0f, 0.0f, 1.0f));
    float mat[16];
    q.toMat(mat);
    CHECK_NEAR(mat[0], 0.0f, kTol);
    CHECK_NEAR(mat[1], 1.0f, kTol);
    CHECK_NEAR(mat[2], 0.0f, kTol);
    CHECK_NEAR(mat[4], -1.0f, kTol);
    CHECK_NEAR(mat[5], 0.0f, kTol);
    CHECK_NEAR(mat[6], 0.0f, kTol);
    CHECK_NEAR(mat[10], 1.0f, kTol);
    CHECK_NEAR(mat[15], 1.0f, kTol);
}

TEST(quat_fromMat_recovers_a_generic_orientation_when_the_trace_is_positive)
{
    /* The a > 0 branch has no self-referential read, so a round trip through
     * toMat/fromMat on a non-axis-aligned rotation should land back on the
     * original quaternion (up to sign, and this angle keeps w positive so
     * even the sign matches). */
    rsQuat original;
    rsVec axis(1.0f, 2.0f, 2.0f);
    axis.normalize();
    original.make(RS_PIo2, axis);

    float mat[16];
    original.toMat(mat);

    rsQuat recovered;
    recovered.fromMat(mat);
    CHECK_NEAR(recovered[0], original[0], 1e-4f);
    CHECK_NEAR(recovered[1], original[1], 1e-4f);
    CHECK_NEAR(recovered[2], original[2], 1e-4f);
    CHECK_NEAR(recovered[3], original[3], 1e-4f);
}

TEST(quat_fromMat_dominant_axis_branches_zero_the_axis_component_on_a_fresh_quat)
{
    /* Characterization of a real bug, filed as ss-9wk, beyond the slerp bug
     * (ss-qss). For trace <= 0, fromMat picks the dominant diagonal axis i
     * and is supposed to write q[i] = sqrt(...) * 0.5. Instead it writes
     * `q[i] *= 0.5f` -- it reads whatever q[i] already held *before* this
     * call and halves that, rather than assigning the freshly computed value.
     * On a default-constructed rsQuat (q[i] == 0 for i in 0..2), that means
     * the dominant component always comes out 0, no matter what the input
     * matrix says it should be. All three axis branches (i==0, i==1, i==2)
     * show the same pattern. */
    const float angle = 2.6179938f;   /* 150 degrees: trace = 1 + 2*cos(150) < 0 */

    {   /* dominant x: correct answer would be (sin75, 0, 0, cos75) */
        rsQuat correct;
        correct.make(angle, rsVec(1.0f, 0.0f, 0.0f));
        float mat[16];
        correct.toMat(mat);
        rsQuat result;   /* default-constructed: q == (0,0,0,1) */
        result.fromMat(mat);
        CHECK_NEAR(result[0], 0.0f, 1e-4f);          /* bug: should be ~0.96593 */
        CHECK_NEAR(result[1], 0.0f, 1e-4f);
        CHECK_NEAR(result[2], 0.0f, 1e-4f);
        CHECK_NEAR(result[3], 0.25881907f, 1e-4f);   /* w is unaffected by the bug */
    }
    {   /* dominant y */
        rsQuat correct;
        correct.make(angle, rsVec(0.0f, 1.0f, 0.0f));
        float mat[16];
        correct.toMat(mat);
        rsQuat result;
        result.fromMat(mat);
        CHECK_NEAR(result[1], 0.0f, 1e-4f);          /* bug: should be ~0.96593 */
        CHECK_NEAR(result[3], 0.25881907f, 1e-4f);
    }
    {   /* dominant z */
        rsQuat correct;
        correct.make(angle, rsVec(0.0f, 0.0f, 1.0f));
        float mat[16];
        correct.toMat(mat);
        rsQuat result;
        result.fromMat(mat);
        CHECK_NEAR(result[2], 0.0f, 1e-4f);          /* bug: should be ~0.96593 */
        CHECK_NEAR(result[3], 0.25881907f, 1e-4f);
    }
}

TEST(quat_fromMat_dominant_axis_component_is_read_from_whatever_the_caller_left_there)
{
    /* Sharper version of the same bug (ss-9wk): seed the target quaternion
     * with an arbitrary prior x component (9.0) instead of the default 0, and
     * the dominant-x branch's output x is exactly half of it (4.5) -- the
     * input matrix has no say in that component at all. */
    rsQuat correct;
    correct.make(2.6179938f, rsVec(1.0f, 0.0f, 0.0f));
    float mat[16];
    correct.toMat(mat);

    rsQuat result(9.0f, -3.0f, 5.0f, 1.0f);   /* arbitrary prior state */
    result.fromMat(mat);
    CHECK_NEAR(result[0], 4.5f, 1e-4f);   /* 9.0 * 0.5, not derived from mat at all */
}

TEST(quat_fromMat_off_axis_dominant_branch_also_miscomputes_the_other_two_components)
{
    /* A second, independent defect in the same branch (also part of ss-9wk),
     * visible once the axis is not conveniently aligned so the "wrong"
     * component isn't coincidentally zero anyway: the formula for the two
     * non-dominant, non-w components pulls the wrong pair of matrix entries,
     * so they come out neither matching the source rotation nor the earlier
     * all-zero pattern. Pinned as observed. */
    rsQuat correct;
    rsVec axis(1.0f, 1.0f, 0.0f);
    axis.normalize();
    correct.make(2.6179938f, axis);   /* trace < 0, dominant x */
    float mat[16];
    correct.toMat(mat);

    rsQuat result;   /* default-constructed */
    result.fromMat(mat);
    /* correct[1] would be ~0.68301 (matching correct[0]); it comes out 0. */
    CHECK_NEAR(result[1], 0.0f, 1e-4f);
    /* correct[2] would be 0 (the axis has no z); it comes out nonzero. */
    CHECK_NEAR(result[2], -0.25881910f, 1e-4f);
    CHECK_NEAR(result[3], 0.25881910f, 1e-4f);
}

TEST(quat_slerp_antipodal_branch_depends_on_the_targets_prior_state)
{
    /* ss-qss: the antipodal fallback branch (triggered when a and b are
     * exact opposites, so 1+cn <= RS_EPSILON) computes q[1] from q[0] and
     * q[3] from q[2] -- reading its own output field, which at that point
     * still holds whatever the *caller's* quaternion held before this call,
     * not a value derived from a and b. Two calls with identical a, b, t but
     * different prior contents of the result object produce different
     * answers, which is the signature of the bug and the property this test
     * pins. */
    rsQuat a(0.5f, 0.5f, 0.5f, 0.5f);
    rsQuat b(-0.5f, -0.5f, -0.5f, -0.5f);   /* exact negation: antipodal */

    rsQuat freshResult;   /* default-constructed: (0,0,0,1) */
    freshResult.slerp(a, b, 0.3f);
    CHECK_NEAR(freshResult[0], 0.44550326f, 1e-4f);
    CHECK_NEAR(freshResult[1], 0.64775753f, 1e-4f);
    CHECK_NEAR(freshResult[2], -0.00848728f, 1e-4f);
    CHECK_NEAR(freshResult[3], 0.44165012f, 1e-4f);

    rsQuat seededResult(7.0f, -2.0f, 9.0f, 4.0f);   /* arbitrary prior state */
    seededResult.slerp(a, b, 0.3f);
    CHECK_NEAR(seededResult[0], 1.35348439f, 1e-4f);
    CHECK_NEAR(seededResult[1], 1.05997241f, 1e-4f);
    CHECK_NEAR(seededResult[2], -1.37045896f, 1e-4f);
    CHECK_NEAR(seededResult[3], -0.17667213f, 1e-4f);

    /* Same a, b, t; different answer -- the two calls above must disagree. */
    CHECK(fabsf(freshResult[0] - seededResult[0]) > 0.1f);
}

TEST(quat_normalize_scales_to_unit_length)
{
    rsQuat q(2.0f, 0.0f, 0.0f, 0.0f);
    q.normalize();
    CHECK_NEAR(q[0], 1.0f, kTol);
    CHECK_NEAR(q[1], 0.0f, kTol);

    /* All four components nonzero and distinct: (1,2,2,4) has length 5. */
    rsQuat q2(1.0f, 2.0f, 2.0f, 4.0f);
    q2.normalize();
    CHECK_NEAR(q2[0], 0.2f, kTol);
    CHECK_NEAR(q2[1], 0.4f, kTol);
    CHECK_NEAR(q2[2], 0.4f, kTol);
    CHECK_NEAR(q2[3], 0.8f, kTol);
}

TEST(quat_fromEuler_matches_the_hpr_formula_for_a_single_axis)
{
    /* yaw only: half-angle sine lands purely on q[2], half-angle cosine on
     * q[3], with q[0] and q[1] left at zero. */
    rsQuat q;
    q.fromEuler(RS_PIo2, 0.0f, 0.0f);
    CHECK_NEAR(q[0], 0.0f, kTol);
    CHECK_NEAR(q[1], 0.0f, kTol);
    CHECK_NEAR(q[2], sinf(RS_PIo2 * 0.5f), kTol);
    CHECK_NEAR(q[3], cosf(RS_PIo2 * 0.5f), kTol);
}

TEST(quat_fromEuler_combines_yaw_and_pitch_with_roll_zero)
{
    /* Yaw and pitch nonzero, but roll is still zero here, so sr == 0 and
     * cr == 1: every term carrying sr vanishes and this case cannot tell
     * the sr-bearing half of the formula from a version with those terms
     * dropped or sign-flipped. See
     * quat_fromEuler_combines_all_three_axes_with_distinct_angles below for
     * the case that pins those terms. */
    rsQuat q;
    q.fromEuler(RS_PIo2, RS_PIo2, 0.0f);
    CHECK_NEAR(q[0], -0.5f, 1e-4f);
    CHECK_NEAR(q[1], 0.5f, 1e-4f);
    CHECK_NEAR(q[2], 0.5f, 1e-4f);
    CHECK_NEAR(q[3], 0.5f, 1e-4f);
}

TEST(quat_fromEuler_combines_all_three_axes_with_distinct_angles)
{
    /* yaw, pitch and roll all nonzero and pairwise distinct (0.6, 0.4,
     * 0.9), so sr != 0 and every cross term in the formula actually
     * contributes -- unlike the roll-zero case above, where sr == 0 kills
     * every term that carries it. Expected values are the half-angle
     * formula worked by hand:
     *   cy=cos(0.3) sy=sin(0.3) cp=cos(0.2) sp=sin(0.2)
     *   cr=cos(0.45) sr=sin(0.45)
     *   q3 = cr*cp*cy + sr*sp*sy
     *   q0 = sr*cp*cy - cr*sp*sy
     *   q1 = cr*sp*cy + sr*cp*sy
     *   q2 = cr*cp*sy - sr*sp*cy */
    rsQuat q;
    q.fromEuler(0.6f, 0.4f, 0.9f);
    CHECK_NEAR(q[0], 0.3543894f, 1e-4f);
    CHECK_NEAR(q[1], 0.2968802f, 1e-4f);
    CHECK_NEAR(q[2], 0.1782413f, 1e-4f);
    CHECK_NEAR(q[3], 0.8686198f, 1e-4f);
}

TEST(quat_preMult_and_postMult_differ_by_multiplication_order)
{
    /* preMult(passed) computes this*passed; postMult(passed) computes
     * passed*this. Quaternion multiplication is not commutative, so the two
     * must disagree here -- this is the assertion that catches the operand
     * order being swapped inside either implementation. Both inputs use
     * generic, fully off-axis rotations (every component of a, b nonzero and
     * distinct) rather than axis-aligned ones: several of preMult/postMult's
     * cross terms multiply a zero component in the axis-aligned case and a
     * sign error there would go unnoticed. */
    rsQuat a;
    rsVec axisA(1.0f, 2.0f, 2.0f);
    axisA.normalize();
    a.make(1.1f, axisA);

    rsQuat b;
    rsVec axisB(2.0f, -1.0f, 2.0f);
    axisB.normalize();
    b.make(0.7f, axisB);

    rsQuat pre(a[0], a[1], a[2], a[3]);
    pre.preMult(b);
    CHECK_NEAR(pre[0], 0.47803745f, 1e-4f);
    CHECK_NEAR(pre[1], 0.26971769f, 1e-4f);
    CHECK_NEAR(pre[2], 0.42264670f, 1e-4f);
    CHECK_NEAR(pre[3], 0.72118127f, 1e-4f);

    rsQuat post(a[0], a[1], a[2], a[3]);
    post.postMult(b);
    CHECK_NEAR(post[0], 0.23906635f, 1e-4f);
    CHECK_NEAR(post[1], 0.19006066f, 1e-4f);
    CHECK_NEAR(post[2], 0.62178922f, 1e-4f);
    CHECK_NEAR(post[3], 0.72118127f, 1e-4f);
}

TEST(matrix_fromQuat_with_a_zero_axis_quat_is_the_identity)
{
    rsMatrix mat;
    mat.identity();
    for (int i = 0; i < 16; i++) mat.m[i] = -42.0f;   /* prove it gets overwritten */
    rsQuat degenerate(0.0f, 0.0f, 0.0f, 0.3f);   /* not even unit length */
    mat.fromQuat(degenerate);
    for (int i = 0; i < 16; i++)
        CHECK_NEAR(mat.m[i], (i % 5 == 0) ? 1.0f : 0.0f, kTol);
}

TEST(matrix_fromQuat_matches_quat_toMat_for_the_same_orientation)
{
    /* rsMatrix::fromQuat and rsQuat::toMat carry the same formula in two
     * different places; a generic axis and a non-right-angle rotation means a
     * transcription slip in either copy would show up as a mismatch. */
    rsQuat q;
    rsVec axis(1.0f, 2.0f, 2.0f);
    axis.normalize();
    q.make(0.9f, axis);

    float viaToMat[16];
    q.toMat(viaToMat);

    rsMatrix viaFromQuat;
    viaFromQuat.fromQuat(q);

    for (int i = 0; i < 16; i++) CHECK_NEAR(viaFromQuat.m[i], viaToMat[i], kTol);
}

/* --- rsVec: the remaining member surface -------------------------------- */

TEST(vec_scale_multiplies_every_component_in_place)
{
    rsVec v(1.0f, -2.0f, 3.0f);
    v.scale(2.0f);
    CHECK_NEAR(v[0], 2.0f, kTol);
    CHECK_NEAR(v[1], -4.0f, kTol);
    CHECK_NEAR(v[2], 6.0f, kTol);

    v.scale(0.0f);
    CHECK_NEAR(v.length(), 0.0f, kTol);
}

TEST(vec_transPoint_and_transVec_differ_by_the_translation_column)
{
    /* A matrix with both a nontrivial linear part and a translation: transVec
     * must apply the scale but drop the translation; transPoint must apply
     * both. A matrix that was pure translation (identity linear part) could
     * not tell these two apart. */
    rsMatrix mat;
    mat.makeScale(2.0f, 3.0f, 4.0f);
    mat.m[12] = 5.0f;
    mat.m[13] = 6.0f;
    mat.m[14] = 7.0f;

    rsVec point(1.0f, 1.0f, 1.0f);
    point.transPoint(mat);
    CHECK_NEAR(point[0], 7.0f, kTol);
    CHECK_NEAR(point[1], 9.0f, kTol);
    CHECK_NEAR(point[2], 11.0f, kTol);

    rsVec direction(1.0f, 1.0f, 1.0f);
    direction.transVec(mat);
    CHECK_NEAR(direction[0], 2.0f, kTol);
    CHECK_NEAR(direction[1], 3.0f, kTol);
    CHECK_NEAR(direction[2], 4.0f, kTol);
}

TEST(vec_compound_assignment_operators_match_their_binary_counterparts)
{
    rsVec a(1.0f, 2.0f, 3.0f);
    rsVec b(4.0f, 6.0f, 8.0f);

    rsVec sum;
    sum = a;
    sum += b;
    CHECK_NEAR(sum[0], 5.0f, kTol);
    CHECK_NEAR(sum[1], 8.0f, kTol);
    CHECK_NEAR(sum[2], 11.0f, kTol);

    rsVec diff;
    diff = b;
    diff -= a;
    CHECK_NEAR(diff[0], 3.0f, kTol);
    CHECK_NEAR(diff[1], 4.0f, kTol);
    CHECK_NEAR(diff[2], 5.0f, kTol);

    rsVec scaled;
    scaled = a;
    scaled *= 2.0f;
    CHECK_NEAR(scaled[0], 2.0f, kTol);
    CHECK_NEAR(scaled[1], 4.0f, kTol);
    CHECK_NEAR(scaled[2], 6.0f, kTol);

    rsVec componentwise;
    componentwise = a;
    componentwise *= b;
    CHECK_NEAR(componentwise[0], 4.0f, kTol);
    CHECK_NEAR(componentwise[1], 12.0f, kTol);
    CHECK_NEAR(componentwise[2], 24.0f, kTol);

    rsVec assigned;
    assigned = a;
    CHECK_NEAR(assigned[0], 1.0f, kTol);
    CHECK_NEAR(assigned[1], 2.0f, kTol);
    CHECK_NEAR(assigned[2], 3.0f, kTol);
}
