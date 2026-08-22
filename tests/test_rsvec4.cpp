/* Tests for rsVec4, the plain 4-component vector -- no GL or platform
 * coupling, so every expectation below is derived from the definition of the
 * operation rather than read off a run.
 *
 * Cases favour asymmetric operands (every component distinct, no repeated
 * value across the vectors involved) so that a dropped term, a swapped
 * operand, or an operator that just returns one of its arguments unchanged
 * shows up as a wrong number rather than passing by coincidence.
 */

#include "harness.h"

#include "rsMath/rsVec4.h"
#include "rsMath/rsMatrix.h"

#include <math.h>

namespace {

const float kTol = 1e-5f;

}  // namespace

TEST(vec4_length_is_euclidean)
{
    /* 1-2-2-4 has integer length 5 (1+4+4+16=25), so the expectation does not
     * depend on a square root landing the same way twice. */
    rsVec4 v(1.0f, 2.0f, 2.0f, 4.0f);
    CHECK_NEAR(v.length(), 5.0f, kTol);

    rsVec4 zero(0.0f, 0.0f, 0.0f, 0.0f);
    CHECK_NEAR(zero.length(), 0.0f, kTol);
}

TEST(vec4_normalize_returns_the_prior_length_and_leaves_a_unit_vector)
{
    /* The return value is the length *before* scaling. Every component
     * distinct so a swapped or dropped division shows up. */
    rsVec4 v(1.0f, 2.0f, 2.0f, 4.0f);
    CHECK_NEAR(v.normalize(), 5.0f, kTol);
    CHECK_NEAR(v.length(), 1.0f, kTol);
    CHECK_NEAR(v[0], 0.2f, kTol);
    CHECK_NEAR(v[1], 0.4f, kTol);
    CHECK_NEAR(v[2], 0.4f, kTol);
    CHECK_NEAR(v[3], 0.8f, kTol);
}

TEST(vec4_normalize_of_a_zero_vector_sets_only_the_second_component)
{
    /* Characterization: unlike rsVec::normalize (which assigns all three
     * components explicitly), rsVec4::normalize only writes v[1] = 1.0 in the
     * zero-length branch and leaves v[0], v[2] and v[3] untouched. That is
     * only safe because a *true* zero vector already has every component at
     * 0 (each squared term must be individually zero for the sum to be
     * zero), so the result still comes out (0,1,0,0) -- but it is a real
     * difference in how the two functions are written, worth pinning so a
     * refactor that "fixes" it to match rsVec doesn't silently change
     * behaviour for degenerate near-zero inputs where a component could
     * underflow to 0 while the whole-vector length still reads 0. */
    rsVec4 v(0.0f, 0.0f, 0.0f, 0.0f);
    CHECK_NEAR(v.normalize(), 0.0f, kTol);
    CHECK_NEAR(v[0], 0.0f, kTol);
    CHECK_NEAR(v[1], 1.0f, kTol);
    CHECK_NEAR(v[2], 0.0f, kTol);
    CHECK_NEAR(v[3], 0.0f, kTol);
}

TEST(vec4_dot_is_sum_of_componentwise_products)
{
    /* Every component of both operands distinct and nonzero: 1*5+2*6+3*7+4*8
     * = 5+12+21+32 = 70. Dropping or misindexing any one term changes the
     * total, unlike an all-perpendicular test where a dropped term is
     * invisible. */
    rsVec4 a(1.0f, 2.0f, 3.0f, 4.0f);
    rsVec4 b(5.0f, 6.0f, 7.0f, 8.0f);
    CHECK_NEAR(a.dot(b), 70.0f, 1e-3f);
}

TEST(vec4_cross_uses_a_shifted_pairwise_formula_not_the_3d_cross)
{
    /* Characterization, not a spec: rsVec4::cross does not compute the
     * standard 3D cross product embedded in 4D (which would ignore w and
     * leave v[3] as some fourth quantity like 0 or the wedge of the w's). It
     * instead applies the same "product of the next two components minus
     * the swapped product" pattern cyclically to all four indices, e.g.
     * v[0] = vec1[1]*vec2[2] - vec2[1]*vec1[2], v[1] uses indices (2,3), v[2]
     * wraps around to (3,0), v[3] to (0,1). For unit basis vectors x and y
     * this produces (0,0,0,1) rather than the (0,0,1,0)-shaped result a
     * "cross in the first three, zero in w" implementation would give. This
     * is pinned as read from hyperspace's own rsVec4.cpp (identical to
     * helios' here), not asserted as the mathematically standard 4D cross. */
    rsVec4 x(1.0f, 0.0f, 0.0f, 0.0f);
    rsVec4 y(0.0f, 1.0f, 0.0f, 0.0f);
    rsVec4 result;
    result.cross(x, y);
    CHECK_NEAR(result[0], 0.0f, kTol);
    CHECK_NEAR(result[1], 0.0f, kTol);
    CHECK_NEAR(result[2], 0.0f, kTol);
    CHECK_NEAR(result[3], 1.0f, kTol);

    /* Every component of both operands distinct so a swapped index inside
     * any one of the four rows shows up as a wrong number. */
    rsVec4 a(1.0f, 2.0f, 3.0f, 4.0f);
    rsVec4 b(5.0f, 6.0f, 7.0f, 8.0f);
    result.cross(a, b);
    CHECK_NEAR(result[0], -4.0f, 1e-3f);
    CHECK_NEAR(result[1], -4.0f, 1e-3f);
    CHECK_NEAR(result[2], 12.0f, 1e-3f);
    CHECK_NEAR(result[3], -4.0f, 1e-3f);

    /* Swapping the operands negates every component -- the property that
     * catches an operand pair silently swapped inside one of the four rows
     * but not the others. */
    result.cross(b, a);
    CHECK_NEAR(result[0], 4.0f, 1e-3f);
    CHECK_NEAR(result[1], 4.0f, 1e-3f);
    CHECK_NEAR(result[2], -12.0f, 1e-3f);
    CHECK_NEAR(result[3], 4.0f, 1e-3f);
}

TEST(vec4_scale_multiplies_every_component_in_place)
{
    rsVec4 v(1.0f, -2.0f, 3.0f, -4.0f);
    v.scale(2.0f);
    CHECK_NEAR(v[0], 2.0f, kTol);
    CHECK_NEAR(v[1], -4.0f, kTol);
    CHECK_NEAR(v[2], 6.0f, kTol);
    CHECK_NEAR(v[3], -8.0f, kTol);

    v.scale(0.0f);
    CHECK_NEAR(v.length(), 0.0f, kTol);
}

TEST(vec4_almost_equal_measures_euclidean_distance_not_per_component_difference)
{
    /* Four distinct per-component offsets (0.06, 0.08, 0.09, 0.1) rather than
     * a repeated value: dropping any single term from the sum-of-squares
     * still leaves the other three below (0.16)^2, so a single tolerance of
     * 0.16 catches a dropped term in *any* one of the four positions, not
     * just the one a repeated offset would happen to hide. Full distance is
     * sqrt(0.06^2+0.08^2+0.09^2+0.1^2) = sqrt(0.0281) ~= 0.1677. */
    rsVec4 origin(0.0f, 0.0f, 0.0f, 0.0f);
    rsVec4 corner(0.06f, 0.08f, 0.09f, 0.1f);
    CHECK(origin.almostEqual(corner, 0.16f) == 0);
    CHECK(origin.almostEqual(corner, 0.18f) == 1);

    rsVec4 near(0.05f, 0.0f, 0.0f, 0.0f);
    CHECK(origin.almostEqual(near, 0.1f) == 1);
    CHECK(origin.almostEqual(origin, 0.0f) == 1);   /* boundary is inclusive */
}

namespace {

/* A matrix with every one of its 16 entries distinct and nonzero, rather
 * than the diagonal-plus-translation shape used elsewhere in this
 * submodule's tests -- with a diagonal linear part, the off-diagonal
 * cross-terms (e.g. y * m[4]) are multiplied by zero, so dropping one from
 * the implementation would not change the result. Combined with an
 * all-ones input vector below, each output component becomes a plain sum of
 * a distinct subset of these values, so dropping or misindexing any single
 * term is a wrong, checkable number. */
void makeGenericMatrix(rsMatrix &mat)
{
    mat.m[0] = 2.0f;  mat.m[1] = 3.0f;  mat.m[2] = 5.0f;  mat.m[3] = 7.0f;
    mat.m[4] = 11.0f; mat.m[5] = 13.0f; mat.m[6] = 17.0f; mat.m[7] = 19.0f;
    mat.m[8] = 23.0f; mat.m[9] = 29.0f; mat.m[10] = 31.0f; mat.m[11] = 37.0f;
    mat.m[12] = 41.0f; mat.m[13] = 43.0f; mat.m[14] = 47.0f; mat.m[15] = 53.0f;
}

}  // namespace

TEST(vec4_transPoint_applies_the_full_4x4_transform_including_translation_and_w_row)
{
    /* Point components (1,2,3,4) are all distinct, unlike an all-ones point:
     * with x==y==z==w, swapping which matrix column pairs with which point
     * component (e.g. y*m[4]+z*m[8] computed as y*m[8]+z*m[4]) is invisible,
     * because the two terms being swapped have equal coefficients. Distinct
     * components make that swap a wrong, checkable number. */
    rsMatrix mat;
    makeGenericMatrix(mat);

    rsVec4 point(1.0f, 2.0f, 3.0f, 4.0f);
    point.transPoint(mat);
    CHECK_NEAR(point[0], 257.0f, kTol);   /* 1*m0+2*m4+3*m8+4*m12 */
    CHECK_NEAR(point[1], 288.0f, kTol);   /* 1*m1+2*m5+3*m9+4*m13 */
    CHECK_NEAR(point[2], 320.0f, kTol);   /* 1*m2+2*m6+3*m10+4*m14 */
    CHECK_NEAR(point[3], 368.0f, kTol);   /* 1*m3+2*m7+3*m11+4*m15 */
}

TEST(vec4_transVec_drops_the_translation_and_w_row_and_leaves_w_untouched)
{
    /* Same matrix as the transPoint case, and the same distinct-component
     * reasoning: transVec must apply the linear (upper-left 3x3) part but
     * ignore both the translation column and the w row entirely, and it
     * must not write v[3] at all -- the prior w survives whatever the
     * matrix's w row says. */
    rsMatrix mat;
    makeGenericMatrix(mat);

    rsVec4 direction(1.0f, 2.0f, 3.0f, 99.0f);
    direction.transVec(mat);
    CHECK_NEAR(direction[0], 93.0f, kTol);    /* 1*m0+2*m4+3*m8, translation excluded */
    CHECK_NEAR(direction[1], 116.0f, kTol);   /* 1*m1+2*m5+3*m9 */
    CHECK_NEAR(direction[2], 132.0f, kTol);   /* 1*m2+2*m6+3*m10 */
    CHECK_NEAR(direction[3], 99.0f, kTol);    /* untouched, not 0 and not transformed */
}

TEST(vec4_arithmetic_operators_are_componentwise)
{
    rsVec4 a(1.0f, 2.0f, 3.0f, 4.0f);
    rsVec4 b(10.0f, 20.0f, 30.0f, 40.0f);

    rsVec4 sum = a + b;
    CHECK_NEAR(sum[0], 11.0f, kTol);
    CHECK_NEAR(sum[1], 22.0f, kTol);
    CHECK_NEAR(sum[2], 33.0f, kTol);
    CHECK_NEAR(sum[3], 44.0f, kTol);

    rsVec4 difference = b - a;
    CHECK_NEAR(difference[0], 9.0f, kTol);
    CHECK_NEAR(difference[1], 18.0f, kTol);
    CHECK_NEAR(difference[2], 27.0f, kTol);
    CHECK_NEAR(difference[3], 36.0f, kTol);

    rsVec4 scaled = a * 2.0f;
    CHECK_NEAR(scaled[0], 2.0f, kTol);
    CHECK_NEAR(scaled[1], 4.0f, kTol);
    CHECK_NEAR(scaled[2], 6.0f, kTol);
    CHECK_NEAR(scaled[3], 8.0f, kTol);

    rsVec4 divided = b / 2.0f;
    CHECK_NEAR(divided[0], 5.0f, kTol);
    CHECK_NEAR(divided[1], 10.0f, kTol);
    CHECK_NEAR(divided[2], 15.0f, kTol);
    CHECK_NEAR(divided[3], 20.0f, kTol);
}

TEST(vec4_compound_assignment_operators_match_their_binary_counterparts)
{
    rsVec4 a(1.0f, 2.0f, 3.0f, 4.0f);
    rsVec4 b(10.0f, 20.0f, 30.0f, 40.0f);

    rsVec4 sum;
    sum = a;
    sum += b;
    CHECK_NEAR(sum[0], 11.0f, kTol);
    CHECK_NEAR(sum[1], 22.0f, kTol);
    CHECK_NEAR(sum[2], 33.0f, kTol);
    CHECK_NEAR(sum[3], 44.0f, kTol);

    rsVec4 diff;
    diff = b;
    diff -= a;
    CHECK_NEAR(diff[0], 9.0f, kTol);
    CHECK_NEAR(diff[1], 18.0f, kTol);
    CHECK_NEAR(diff[2], 27.0f, kTol);
    CHECK_NEAR(diff[3], 36.0f, kTol);

    rsVec4 scaled;
    scaled = a;
    scaled *= 2.0f;
    CHECK_NEAR(scaled[0], 2.0f, kTol);
    CHECK_NEAR(scaled[1], 4.0f, kTol);
    CHECK_NEAR(scaled[2], 6.0f, kTol);
    CHECK_NEAR(scaled[3], 8.0f, kTol);

    /* operator*=(rsVec4) is componentwise multiplication, distinct from the
     * scalar overload above -- every result component here differs from
     * both operands' corresponding component and from the scalar case. */
    rsVec4 componentwise;
    componentwise = a;
    componentwise *= b;
    CHECK_NEAR(componentwise[0], 10.0f, kTol);
    CHECK_NEAR(componentwise[1], 40.0f, kTol);
    CHECK_NEAR(componentwise[2], 90.0f, kTol);
    CHECK_NEAR(componentwise[3], 160.0f, kTol);
}

TEST(vec4_operator_assign_copies_every_component_and_survives_self_assignment)
{
    rsVec4 a(1.0f, 2.0f, 3.0f, 4.0f);
    rsVec4 assigned(9.0f, 9.0f, 9.0f, 9.0f);   /* deliberately not equal to a first */
    assigned = a;
    CHECK_NEAR(assigned[0], 1.0f, kTol);
    CHECK_NEAR(assigned[1], 2.0f, kTol);
    CHECK_NEAR(assigned[2], 3.0f, kTol);
    CHECK_NEAR(assigned[3], 4.0f, kTol);

    /* Self-assignment: each component is copied from the same index it is
     * written to, so aliasing the source and destination must be a no-op
     * rather than corrupting later components with already-overwritten
     * earlier ones. */
    rsVec4 self(5.0f, 6.0f, 7.0f, 8.0f);
    self = self;
    CHECK_NEAR(self[0], 5.0f, kTol);
    CHECK_NEAR(self[1], 6.0f, kTol);
    CHECK_NEAR(self[2], 7.0f, kTol);
    CHECK_NEAR(self[3], 8.0f, kTol);
}
