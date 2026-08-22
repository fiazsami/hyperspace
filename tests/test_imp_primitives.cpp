/* Tests for the implicit primitive shapes' value() functions and the small
 * torus helpers built on top of them.
 *
 * impShape's constructor sets mat and invmat to identity but leaves invtrmat
 * uninitialised -- it is only filled in by setMatrix(). Every primitive below
 * whose value() reads invtrmat (all but impSphere, which reads invmat
 * directly) is given an explicit matrix via setMatrix() before value() is
 * called, so no test reads uninitialised memory.
 *
 * Matrices are column-major (mat[12..14] is the translation column), matching
 * the convention noted in test_rsmath.cpp.
 *
 * ss-e5n: helios' twin of this file used only identity or pure-translation
 * matrices in every value() fixture, so all nine linear-part entries of
 * invtrmat were 0 or 1 and their *indices* were never pinned -- swapping
 * y*invtrmat[1]+z*invtrmat[2] for y*invtrmat[9]+z*invtrmat[6] in every
 * primitive's tx computation left that suite green. impRoundedHexahedron's
 * width/height/length also all defaulted to 1.0 there, so which parameter an
 * axis reads was invisible too. Every primitive below that reads invtrmat
 * gets one fixture built on kCoupledMatrix, a matrix whose nine linear-part
 * entries are all distinct and none is 0 or 1, evaluated at an off-axis
 * point -- and impRoundedHexahedron is given distinct width/height/length so
 * each axis can only pass by reading its own parameter.
 */

#include "harness.h"

#include <Implicit/impCapsule.h>
#include <Implicit/impCrawlPoint.h>
#include <Implicit/impEllipsoid.h>
#include <Implicit/impHexahedron.h>
#include <Implicit/impRoundedHexahedron.h>
#include <Implicit/impSphere.h>
#include <Implicit/impTorus.h>

namespace {

const float kTol = 1e-4f;

/* IMP_MIN_DIVISOR from impShape.h -- every value() formula below adds it to
 * the falloff denominator, so exact-center points still divide by a nonzero
 * number instead of the position term's own zero. */
const float kMinDivisor = 0.0001f;

void makeIdentity(float *m)
{
    for (int i = 0; i < 16; i++) m[i] = 0.0f;
    m[0] = m[5] = m[10] = m[15] = 1.0f;
}

/* A non-symmetric 3x3 shear/scale block plus a full translation. The block
 * is deliberately *not* symmetric (m[4] != m[1], m[8] != m[2], m[9] !=
 * m[6]): an earlier version of this fixture used the symmetric block
 * [[2,1,1],[1,3,1],[1,1,4]], which made invtrmat's linear part symmetric
 * too and left the transpose step in impShape::setMatrix() -- and the
 * index each value()'s tx/ty/tz reads -- unpinned (a verbatim
 * invtrmat[k]=invmat[k] copy, or reading invtrmat[4]/[8] where tx should
 * read [1]/[2], both coincidentally matched the transposed value). Every
 * one of the nine linear-part entries of the resulting invtrmat (computed
 * independently, by hand, from the adjugate of this block divided by its
 * determinant of 41/2 -- see the fractions below) is distinct and neither
 * 0 nor 1:
 * invtrmat[0..2]  = { 22/41, -15/41,  12/41}
 * invtrmat[4..6]  = { -6/41,  19/41,  -7/41}
 * invtrmat[8..10] = { -4/41,  -1/41,   9/41}
 * so a formula that reads the wrong index, or a setMatrix() that copies
 * instead of transposing, produces a visibly different result rather than
 * coincidentally matching. */
void makeCoupledMatrix(float *m)
{
    makeIdentity(m);
    m[0] = 2.0f;  m[1] = 1.0f;  m[2] = 1.0f;
    m[4] = 1.5f;  m[5] = 3.0f;  m[6] = 1.0f;
    m[8] = -1.5f; m[9] = 1.0f;  m[10] = 4.0f;
    m[12] = 1.0f; m[13] = 2.0f; m[14] = 3.0f;
}

}  // namespace

/* --- impHexahedron::value ---------------------------------------------------
 *
 * value() is the minimum of three per-axis inverse-square falloffs, computed
 * with two comparisons (xx<yy, then xx<zz or yy<zz) that together always pick
 * the smallest of the three -- so every combination of comparison outcomes
 * still has to return the true minimum. The four cases below drive both
 * branches of both comparisons. */

TEST(hexahedron_value_picks_x_when_x_is_farthest_on_both_branches)
{
    impHexahedron h;
    float m[16];
    makeIdentity(m);
    h.setMatrix(m);

    /* |x|=3 > |y|=2 > |z|=1, so xx < yy and xx < zz: both comparisons take
     * their true branch and the outer/inner true path returns xx. */
    float pos[3] = {3.0f, 2.0f, 1.0f};
    const float xx = 1.0f / (3.0f * 3.0f + kMinDivisor);
    CHECK_NEAR(h.value(pos), xx, kTol);
}

TEST(hexahedron_value_picks_z_when_xy_branch_is_true_but_z_is_smaller)
{
    impHexahedron h;
    float m[16];
    makeIdentity(m);
    h.setMatrix(m);

    /* |x|=2 > |y|=1 (xx < yy, true) but |z|=3 makes zz the true minimum, so
     * the true/false path (xx < yy but not xx < zz) has to fall through to
     * zz rather than returning xx early. */
    float pos[3] = {2.0f, 1.0f, 3.0f};
    const float zz = 1.0f / (3.0f * 3.0f + kMinDivisor);
    CHECK_NEAR(h.value(pos), zz, kTol);
}

TEST(hexahedron_value_picks_y_when_xy_branch_is_false_and_y_is_smaller)
{
    impHexahedron h;
    float m[16];
    makeIdentity(m);
    h.setMatrix(m);

    /* |y|=3 is largest so xx < yy is false; within the else, yy < zz is true
     * because |y| > |z|. False/true path returns yy. */
    float pos[3] = {1.0f, 3.0f, 2.0f};
    const float yy = 1.0f / (3.0f * 3.0f + kMinDivisor);
    CHECK_NEAR(h.value(pos), yy, kTol);
}

TEST(hexahedron_value_picks_z_when_xy_branch_is_false_and_z_is_smaller)
{
    impHexahedron h;
    float m[16];
    makeIdentity(m);
    h.setMatrix(m);

    /* |z|=3 is the largest of all three: xx < yy is false (|x|<|y|), and
     * within the else, yy < zz is also false. False/false path returns zz. */
    float pos[3] = {1.0f, 2.0f, 3.0f};
    const float zz = 1.0f / (3.0f * 3.0f + kMinDivisor);
    CHECK_NEAR(h.value(pos), zz, kTol);
}

TEST(hexahedron_value_at_center_uses_min_divisor_on_every_axis)
{
    impHexahedron h;
    float m[16];
    makeIdentity(m);
    h.setMatrix(m);

    /* All three transformed coordinates are exactly zero, so all three
     * per-axis terms are equal (1/kMinDivisor) and the tie has to resolve to
     * one of them rather than dividing by zero anywhere. */
    float pos[3] = {0.0f, 0.0f, 0.0f};
    const float expected = 1.0f / kMinDivisor;
    CHECK_NEAR(h.value(pos), expected, 1.0f);
}

TEST(hexahedron_value_pins_matrix_rotation_and_shear)
{
    impHexahedron h;
    float m[16];
    makeCoupledMatrix(m);
    h.setMatrix(m);

    /* Independently derived by replaying setMatrix's own invertMatrix() and
     * value()'s formula: at position (2,3,5), (tx,ty,tz) = (31/41, -1/41,
     * 13/41) = (0.756098, -0.024390, 0.317073), giving (xx,yy,zz) =
     * (1.74891, 1439.09, 9.93686) and value = min = xx. Every term in tx, ty
     * and tz depends on a distinct invtrmat entry, so reading the wrong one
     * moves this result by more than kTol.
     *
     * This point only exercises tx, though: value() returns the *minimum*
     * of xx, yy and zz, and here xx is smallest by nearly three orders of
     * magnitude, so a wrong index inside the ty or tz computation would
     * leave the returned xx untouched. The two points below make yy and zz
     * the minimum in turn, so a wrong index anywhere in invtrmat's y or z
     * rows moves the returned value instead of a term that gets discarded. */
    float pos[3] = {2.0f, 3.0f, 5.0f};
    CHECK_NEAR(h.value(pos), 1.748914f, 1e-3f);

    /* At position (-1,-2,1), (tx,ty,tz) = (-8/41, -50/41, -6/41) =
     * (-0.195122, -1.219512, -0.146341): |ty| is the largest of the three,
     * so yy = 1/(ty^2+kMinDivisor) is the smallest term and value = yy.
     * Every coefficient in the ty row (invtrmat[4..7]) feeds this result;
     * reading invtrmat[6] (the z coefficient) from the wrong row, as from
     * invtrmat[9], moves ty from -50/41 to -44/41 and the result well
     * outside kTol. */
    float tyDominant[3] = {-1.0f, -2.0f, 1.0f};
    CHECK_NEAR(h.value(tyDominant), 0.672355f, 1e-3f);

    /* At position (1,-1,-2), (tx,ty,tz) = (-15/41, -22/41, -42/41) =
     * (-0.365854, -0.536585, -1.024390): |tz| is the largest of the three,
     * so value = zz. Swapping invtrmat[8] and invtrmat[9] -- the x and y
     * coefficients that feed tz -- moves tz from -42/41 to -36/41 and the
     * result well outside kTol. */
    float tzDominant[3] = {1.0f, -1.0f, -2.0f};
    CHECK_NEAR(h.value(tzDominant), 0.952857f, 1e-3f);
}

/* --- impEllipsoid::value ---------------------------------------------------- */

TEST(ellipsoid_value_is_max_at_center_and_falls_off_with_squared_distance)
{
    impEllipsoid e;
    float m[16];
    makeIdentity(m);
    e.setMatrix(m);

    /* Default thickness is 0.1 (impShape's constructor), so thicknessSquared
     * is 0.01. */
    float center[3] = {0.0f, 0.0f, 0.0f};
    CHECK_NEAR(e.value(center), 0.01f / kMinDivisor, 1.0f);

    float off[3] = {3.0f, 4.0f, 0.0f};
    CHECK_NEAR(e.value(off), 0.01f / (25.0f + kMinDivisor), 1e-6f);
}

TEST(ellipsoid_value_pins_matrix_rotation_and_shear)
{
    impEllipsoid e;
    float m[16];
    makeCoupledMatrix(m);
    e.setMatrix(m);

    /* Same (tx,ty,tz) as the hexahedron coupling case above:
     * 0.01 / (0.756098^2 + 0.024390^2 + 0.317073^2 + kMinDivisor). */
    float pos[3] = {2.0f, 3.0f, 5.0f};
    CHECK_NEAR(e.value(pos), 0.0148607f, 1e-5f);
}

/* --- impSphere::value -------------------------------------------------------
 *
 * Unlike the others, impSphere reads invmat directly rather than invtrmat, so
 * it is well-defined straight from impShape's constructor (identity) without
 * a setMatrix() call, and setMatrix's rotation/shear part never reaches it --
 * it has no coupling fixture for that reason. */

TEST(sphere_value_is_max_at_center_and_falls_off_with_squared_distance)
{
    impSphere s;

    float center[3] = {0.0f, 0.0f, 0.0f};
    CHECK_NEAR(s.value(center), 0.01f / kMinDivisor, 1.0f);

    float off[3] = {3.0f, 4.0f, 0.0f};
    CHECK_NEAR(s.value(off), 0.01f / (25.0f + kMinDivisor), 1e-6f);
}

TEST(sphere_value_follows_setPosition)
{
    impSphere s;
    s.setPosition(5.0f, 0.0f, 0.0f);

    float atNewCenter[3] = {5.0f, 0.0f, 0.0f};
    CHECK_NEAR(s.value(atNewCenter), 0.01f / kMinDivisor, 1.0f);
}

/* --- impTorus::value --------------------------------------------------------- */

TEST(torus_value_peaks_on_the_ring_and_falls_off_radially)
{
    impTorus t;
    float m[16];
    makeIdentity(m);
    t.setMatrix(m);

    /* Default radius is 1.0 (impTorus's constructor). A point exactly on the
     * ring, in-plane, drives temp = sqrt(1) - 1 = 0. */
    float onRing[3] = {1.0f, 0.0f, 0.0f};
    CHECK_NEAR(t.value(onRing), 0.01f / kMinDivisor, 1.0f);

    /* Off the ring in-plane: temp = sqrt(9) - 1 = 2. */
    float offRing[3] = {3.0f, 0.0f, 0.0f};
    CHECK_NEAR(t.value(offRing), 0.01f / (4.0f + kMinDivisor), 1e-6f);
}

TEST(torus_value_falls_off_along_the_tube_axis)
{
    impTorus t;
    float m[16];
    makeIdentity(m);
    t.setMatrix(m);

    /* Directly above the ring center (0,0), off the ring plane by 1: temp =
     * sqrt(0) - 1 = -1, so temp*temp still contributes 1, plus tz*tz = 1. */
    float aboveCenter[3] = {0.0f, 0.0f, 1.0f};
    CHECK_NEAR(t.value(aboveCenter), 0.01f / (2.0f + kMinDivisor), 1e-6f);
}

TEST(torus_value_pins_matrix_rotation_and_shear)
{
    impTorus t;
    float m[16];
    makeCoupledMatrix(m);
    t.setMatrix(m);

    /* Same (tx,ty,tz) as above; temp = sqrt(0.756098^2 + 0.024390^2) -
     * 1 = -0.243509 (default radius 1), value = 0.01 / (temp^2 + tz^2 +
     * kMinDivisor). */
    float pos[3] = {2.0f, 3.0f, 5.0f};
    CHECK_NEAR(t.value(pos), 0.0625265f, 1e-5f);
}

/* --- impTorus::center -------------------------------------------------------- */

TEST(torus_center_combines_radius_along_local_x_with_position)
{
    impTorus t;

    /* Default radius 1, default (identity) matrix: mat[0]=1, mat[12..14]=0,
     * so center is the point one radius out along local x. */
    float c[3];
    t.center(c);
    CHECK_NEAR(c[0], 1.0f, kTol);
    CHECK_NEAR(c[1], 0.0f, kTol);
    CHECK_NEAR(c[2], 0.0f, kTol);

    /* Moving the shape and changing the radius both have to show up: radius
     * 2 along local x, plus the new translation. */
    t.setRadius(2.0f);
    t.setPosition(10.0f, 20.0f, 30.0f);
    t.center(c);
    CHECK_NEAR(c[0], 12.0f, kTol);
    CHECK_NEAR(c[1], 20.0f, kTol);
    CHECK_NEAR(c[2], 30.0f, kTol);
}

TEST(torus_center_reads_each_axis_from_its_own_mat_column_entry)
{
    impTorus t;
    float m[16];
    makeCoupledMatrix(m);
    t.setMatrix(m);
    t.setRadius(2.0f);

    /* center() reads mat directly (mat[0..2] and mat[12..14]), not
     * invtrmat, and every test above used an identity or pure-translation
     * matrix, where mat[0]=1 and mat[1]=mat[2]=0 -- so center()'s c[1] and
     * c[2] never distinguished mat[1]/mat[2] from any other zero entry, and
     * reading position[1] from mat[4] instead of mat[1] would have gone
     * unnoticed. With the coupled matrix (mat[0]=2, mat[1]=1, mat[2]=1,
     * mat[12..14]=(1,2,3)) and radius 2: c = mat[0..2]*radius + mat[12..14]
     * = (2*2+1, 1*2+2, 1*2+3) = (5, 4, 5). Reading c[1] from mat[4]=1.5
     * instead of mat[1]=1 would give 5 instead of 4. */
    float c[3];
    t.center(c);
    CHECK_NEAR(c[0], 5.0f, kTol);
    CHECK_NEAR(c[1], 4.0f, kTol);
    CHECK_NEAR(c[2], 5.0f, kTol);
}

/* --- impTorus::addCrawlPoint -------------------------------------------------- */

TEST(torus_addCrawlPoint_appends_the_same_point_as_center)
{
    impTorus t;
    t.setRadius(2.0f);
    t.setPosition(10.0f, 20.0f, 30.0f);

    impCrawlPointVector cpv;
    t.addCrawlPoint(cpv);

    CHECK(cpv.size() == 1);
    CHECK_NEAR(cpv[0].position[0], 12.0f, kTol);
    CHECK_NEAR(cpv[0].position[1], 20.0f, kTol);
    CHECK_NEAR(cpv[0].position[2], 30.0f, kTol);

    /* Appends rather than replaces. */
    t.addCrawlPoint(cpv);
    CHECK(cpv.size() == 2);
}

TEST(torus_addCrawlPoint_reads_each_axis_from_its_own_mat_column_entry)
{
    impTorus t;
    float m[16];
    makeCoupledMatrix(m);
    t.setMatrix(m);
    t.setRadius(2.0f);

    /* Same computation and the same gap as
     * torus_center_reads_each_axis_from_its_own_mat_column_entry above:
     * addCrawlPoint() reads mat directly, and every other fixture in this
     * file used an identity or pure-translation matrix, where mat[1] and
     * mat[4] were both zero. With the coupled matrix and radius 2, the
     * appended point is (5, 4, 5), matching center()'s result exactly. */
    impCrawlPointVector cpv;
    t.addCrawlPoint(cpv);

    CHECK(cpv.size() == 1);
    CHECK_NEAR(cpv[0].position[0], 5.0f, kTol);
    CHECK_NEAR(cpv[0].position[1], 4.0f, kTol);
    CHECK_NEAR(cpv[0].position[2], 5.0f, kTol);
}

/* --- impCapsule::value -------------------------------------------------------
 *
 * The along-axis term is clamped to zero inside the capsule's length and only
 * grows past its ends: sz = zz * (zz > 0.0f) where zz = fabsf(tz) - length. */

TEST(capsule_value_ignores_axial_distance_within_its_length)
{
    impCapsule c;
    float m[16];
    makeIdentity(m);
    c.setMatrix(m);

    /* Default length is 1.0. z=0 is well inside it, so the length term
     * (zz negative) is clamped to zero and only tx, ty contribute. */
    float onAxis[3] = {0.0f, 0.0f, 0.0f};
    CHECK_NEAR(c.value(onAxis), 0.01f / kMinDivisor, 1.0f);

    float offAxisWithinLength[3] = {1.0f, 1.0f, 0.0f};
    CHECK_NEAR(c.value(offAxisWithinLength), 0.01f / (2.0f + kMinDivisor), 1e-6f);
}

TEST(capsule_value_falls_off_past_its_length)
{
    impCapsule c;
    float m[16];
    makeIdentity(m);
    c.setMatrix(m);

    /* z=3 is past the default length of 1, so zz = 3 - 1 = 2 is positive and
     * unclamped: sz*sz = 4. */
    float pastEnd[3] = {0.0f, 0.0f, 3.0f};
    CHECK_NEAR(c.value(pastEnd), 0.01f / (4.0f + kMinDivisor), 1e-6f);
}

TEST(capsule_value_pins_matrix_rotation_and_shear)
{
    impCapsule c;
    float m[16];
    makeCoupledMatrix(m);
    c.setMatrix(m);

    /* Position (2,3,5) (used elsewhere in this file) leaves |tz|=0.317073
     * within the default length of 1, so sz clamps to zero there and the tz
     * computation -- the sz term's own invtrmat row -- is never exercised.
     * Position (1,-1,-3) instead gives (tx,ty,tz) = (-0.658537, -0.365854,
     * -1.243902): tx and ty are unchanged in kind from the (2,3,5) case
     * above, but |tz|-length=0.243902 is now positive and unclamped, so
     * sz = 0.243902 contributes: 0.01 / (0.658537^2 + 0.365854^2 +
     * 0.243902^2 + kMinDivisor). Reading tz from the wrong invtrmat indices
     * moves sz, and therefore this result, well outside the tolerance. */
    float pos[3] = {1.0f, -1.0f, -3.0f};
    CHECK_NEAR(c.value(pos), 0.0159462f, 1e-5f);
}

/* --- impRoundedHexahedron::value and impRoundedHexahedron() -----------------
 *
 * Each axis clamps the same way the capsule's length axis does: sx = xx *
 * (xx > 0.0f) where xx = fabsf(tx) - width, and likewise for height/length.
 * Constructing the shape exercises its constructor (default width = height =
 * length = 1.0), and the first case below relies on those defaults. */

TEST(roundedHexahedron_value_is_zero_falloff_inside_the_box)
{
    impRoundedHexahedron rh;
    float m[16];
    makeIdentity(m);
    rh.setMatrix(m);

    float center[3] = {0.0f, 0.0f, 0.0f};
    CHECK_NEAR(rh.value(center), 0.01f / kMinDivisor, 1.0f);
}

TEST(roundedHexahedron_value_only_the_axis_past_its_own_extent_contributes)
{
    impRoundedHexahedron rh;
    float m[16];
    makeIdentity(m);
    rh.setMatrix(m);

    /* Distinct width/height/length (1, 2, 3): if any two were swapped in the
     * formula, one of the three checks below would land on the wrong side of
     * its extent and change from clamped-zero to positive or vice versa. */
    rh.setSize(1.0f, 2.0f, 3.0f);

    /* x=2 is 1 past width (2-1=1); y=0 and z=0 are within height and length. */
    float pastWidth[3] = {2.0f, 0.0f, 0.0f};
    CHECK_NEAR(rh.value(pastWidth), 0.01f / (1.0f + kMinDivisor), 1e-6f);

    /* y=3 is 1 past height (3-2=1); x=0 and z=0 are within width and length. */
    float pastHeight[3] = {0.0f, 3.0f, 0.0f};
    CHECK_NEAR(rh.value(pastHeight), 0.01f / (1.0f + kMinDivisor), 1e-6f);

    /* z=4 is 1 past length (4-3=1); x=0 and y=0 are within width and height. */
    float pastLength[3] = {0.0f, 0.0f, 4.0f};
    CHECK_NEAR(rh.value(pastLength), 0.01f / (1.0f + kMinDivisor), 1e-6f);
}

TEST(roundedHexahedron_value_pins_matrix_rotation_and_shear)
{
    impRoundedHexahedron rh;
    float m[16];
    makeCoupledMatrix(m);
    rh.setMatrix(m);

    /* At position (-2,-1,1), default width=height=length=1: (tx,ty,tz) =
     * (-1.097561, -0.609756, -0.073171). Only |tx|-width=0.097561 is
     * positive; y and z clamp to zero, so value = 0.01 / (0.097561^2 +
     * kMinDivisor) and every coefficient in the tx row (invtrmat[0..3])
     * feeds it. */
    float txDominant[3] = {-2.0f, -1.0f, 1.0f};
    CHECK_NEAR(rh.value(txDominant), 1.0397016f, 1e-3f);

    /* An earlier version of the second case below used position (5,5,5):
     * with x==y==z, swapping invtrmat[8] and invtrmat[9] -- the x and y
     * coefficients that feed tz -- left tz, and therefore the test,
     * unchanged, since it multiplies equal x and y by the swapped pair of
     * coefficients either way, and the point above has the same problem
     * for tz specifically (|tz| never clears length=1 there). Shrinking
     * length to 0.5 and moving to a point with three distinct, nonzero
     * components makes tz the only unclamped axis instead, so the tz
     * computation is what this second case actually pins.
     *
     * At position (1,-1,-2), (tx,ty,tz) = (-0.365854, -0.536585,
     * -1.024390): |tx|-width=-0.634146 and |ty|-height=-0.463415 are both
     * negative and clamp to zero; |tz|-length=0.524390 is the only positive
     * term, so value = 0.01 / (0.524390^2 + kMinDivisor). Reading tz from
     * the wrong invtrmat indices moves it well outside this tolerance. */
    rh.setSize(1.0f, 1.0f, 0.5f);
    float tzDominant[3] = {1.0f, -1.0f, -2.0f};
    CHECK_NEAR(rh.value(tzDominant), 0.0363524f, 1e-5f);
}
