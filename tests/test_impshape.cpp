/* Tests for impShape itself -- the base class every implicit primitive
 * derives from. impShape has no pure virtual methods, so it is instantiated
 * directly here rather than through a subclass: every assertion below reads
 * impShape's own public members (mat/invmat/invtrmat/thickness/
 * thicknessSquared), so an effect that only showed up incidentally through a
 * subclass's own logic would not be enough to pass these -- the state
 * asserted on is exactly the state each function under test writes.
 *
 * Matrices are column-major (mat[12..14] is the translation column), matching
 * the convention noted in test_rsmath.cpp and test_imp_primitives.cpp.
 *
 * ss-3of: impShape.h declares `~impShape(){};` non-virtual, unlike helios'
 * `virtual ~impShape(){};` -- deleting a derived shape through an impShape*
 * skips the derived destructor. Nothing below deletes through a base
 * pointer or otherwise exercises destruction; the destructors are empty-body
 * bucket C regardless, so there is nothing here that would pin the bug as
 * intended behaviour. Not fixed here -- production source is untouched.
 *
 * ss-e5n: helios' twin of this file used only identity/pure-translation
 * matrices, so invtrmat's linear-part entries were never distinguishable
 * from each other. test_imp_primitives.cpp and test_impknot.cpp fixed this
 * for the primitives' value() functions with a shared "coupled" matrix whose
 * linear part is fully populated; setMatrix_and_invertMatrix below reuse
 * that same matrix rather than a weaker one.
 */

#include "harness.h"

#include <Implicit/impShape.h>

namespace {

const float kTol = 1e-4f;

void makeIdentity(float *m)
{
    for (int i = 0; i < 16; i++) m[i] = 0.0f;
    m[0] = m[5] = m[10] = m[15] = 1.0f;
}

/* Same matrix as test_imp_primitives.cpp's makeCoupledMatrix and
 * test_impknot.cpp's copy of it. Its 3x3 linear part is deliberately
 * non-symmetric ([[2,1.5,-1.5],[1,3,1],[1,1,4]] -- the storage is column-major,
 * so those rows are (m[0],m[4],m[8]), (m[1],m[5],m[9]), (m[2],m[6],m[10]), NOT
 * m[0..2]/m[4..6]/m[8..10], which would be its transpose and would lead anyone
 * re-deriving the inverse below to the wrong answer) -- an earlier version of
 * this fixture used the symmetric block
 * [[2,1,1],[1,3,1],[1,1,4]], which made its own inverse symmetric too and
 * left setMatrix_copies_mat_and_builds_invtrmat_as_the_transpose_of_invmat
 * below unable to tell a real transpose of the linear block from a
 * verbatim copy of it (the translation/bottom-row relocation still caught
 * a verbatim invtrmat=invmat copy, but not a transpose confined to the
 * linear block).
 *
 * invmat's linear part was solved independently as the analytic inverse of
 * that 3x3 (determinant 41/2): [[22,-15,12],[-6,19,-7],[-4,-1,9]]/41. Its
 * translation column is -R^-1 * (1,2,3) = (-28/41, -11/41, -21/41). */
void makeCoupledMatrix(float *m)
{
    makeIdentity(m);
    m[0] = 2.0f;  m[1] = 1.0f;  m[2] = 1.0f;
    m[4] = 1.5f;  m[5] = 3.0f;  m[6] = 1.0f;
    m[8] = -1.5f; m[9] = 1.0f;  m[10] = 4.0f;
    m[12] = 1.0f; m[13] = 2.0f; m[14] = 3.0f;
}

}  // namespace

/* --- impShape::impShape() ----------------------------------------------------
 *
 * The constructor sets mat and invmat to identity (invtrmat is left
 * uninitialised -- only setMatrix() fills it in) and gives thickness its
 * documented default of 0.1, with thicknessSquared precomputed from it. */

TEST(constructor_sets_mat_and_invmat_to_identity)
{
    impShape s;
    for (int i = 0; i < 16; i++) {
        const float expected = (i == 0 || i == 5 || i == 10 || i == 15) ? 1.0f : 0.0f;
        CHECK_NEAR(s.mat[i], expected, kTol);
        CHECK_NEAR(s.invmat[i], expected, kTol);
    }
    CHECK_NEAR(s.thickness, 0.1f, kTol);
    CHECK_NEAR(s.thicknessSquared, 0.01f, kTol);
}

/* --- impShape::setThickness --------------------------------------------------
 *
 * Stores thickness as given and precomputes thicknessSquared as its square,
 * not a copy -- a no-op or a mis-derived thicknessSquared both show up here. */

TEST(setThickness_stores_the_value_and_squares_it_separately)
{
    impShape s;
    s.setThickness(3.0f);
    CHECK_NEAR(s.thickness, 3.0f, kTol);
    CHECK_NEAR(s.thicknessSquared, 9.0f, kTol);
    CHECK(s.getThickness() == 3.0f);
}

/* --- impShape::setPosition(float, float, float) ------------------------------
 *
 * Writes the translation column of mat, the negated translation column of
 * invmat, and the negated translation entries of invtrmat (indices 3, 7, 11 --
 * the last column of each row in the transposed-inverse layout). setMatrix()
 * is called first with the coupled matrix (not identity) so invtrmat starts
 * with a real translation-of-inverse value in those slots, not zero -- a
 * no-op setPosition would leave the coupled matrix's own (-28/41, -11/41,
 * -21/41) sitting there instead of being overwritten. */

TEST(setPosition_xyz_sets_the_translation_column_and_its_negated_inverses)
{
    impShape s;
    float coupled[16];
    makeCoupledMatrix(coupled);
    s.setMatrix(coupled);

    s.setPosition(7.0f, 8.0f, 9.0f);

    CHECK_NEAR(s.mat[12], 7.0f, kTol);
    CHECK_NEAR(s.mat[13], 8.0f, kTol);
    CHECK_NEAR(s.mat[14], 9.0f, kTol);

    CHECK_NEAR(s.invmat[12], -7.0f, kTol);
    CHECK_NEAR(s.invmat[13], -8.0f, kTol);
    CHECK_NEAR(s.invmat[14], -9.0f, kTol);

    CHECK_NEAR(s.invtrmat[3], -7.0f, kTol);
    CHECK_NEAR(s.invtrmat[7], -8.0f, kTol);
    CHECK_NEAR(s.invtrmat[11], -9.0f, kTol);
}

/* --- impShape::setPosition(float*) --------------------------------------------
 *
 * The pointer overload is a thin forward to the three-float version; the
 * point of this test is that the array's elements land in the same x/y/z
 * slots, not just that some position got set. */

TEST(setPosition_array_overload_forwards_elements_in_order)
{
    impShape s;
    float pos[3] = {40.0f, 50.0f, 60.0f};

    s.setPosition(pos);

    CHECK_NEAR(s.mat[12], 40.0f, kTol);
    CHECK_NEAR(s.mat[13], 50.0f, kTol);
    CHECK_NEAR(s.mat[14], 60.0f, kTol);
}

/* --- impShape::determinant3 ---------------------------------------------------
 *
 * Plain 3x3 determinant, called with (row-major) aa..cc. */

TEST(determinant3_computes_the_determinant_of_a_nonsingular_matrix)
{
    impShape s;

    /* | 1 2 3 |
     * | 0 1 4 |
     * | 5 6 0 |   -> classic textbook example, det = 1. */
    const float det = s.determinant3(1.0f, 2.0f, 3.0f,
                                      0.0f, 1.0f, 4.0f,
                                      5.0f, 6.0f, 0.0f);
    CHECK_NEAR(det, 1.0f, kTol);
}

TEST(determinant3_is_zero_for_linearly_dependent_rows)
{
    impShape s;

    /* Row 2 is exactly twice row 1, so the matrix is singular. */
    const float det = s.determinant3(1.0f, 2.0f, 3.0f,
                                      2.0f, 4.0f, 6.0f,
                                      0.0f, 0.0f, 1.0f);
    CHECK_NEAR(det, 0.0f, kTol);
}

/* --- impShape::invertMatrix ---------------------------------------------------
 *
 * Reads mat, writes invmat, and reports whether mat was invertible. Exercised
 * directly (not just through setMatrix) so failure is attributable to
 * invertMatrix's own arithmetic rather than setMatrix's forwarding of it.
 * The coupled matrix's fully-populated, non-0/1 linear part means a formula
 * that reads or combines the wrong mat entries moves invmat's result well
 * outside kTol rather than coincidentally matching -- see the analytic
 * derivation in makeCoupledMatrix's comment above. */

TEST(invertMatrix_inverts_the_coupled_matrix)
{
    impShape s;
    makeCoupledMatrix(s.mat);

    const bool ok = s.invertMatrix();

    CHECK(ok);
    CHECK_NEAR(s.invmat[0], 22.0f / 41.0f, 1e-5f);
    CHECK_NEAR(s.invmat[1], -6.0f / 41.0f, 1e-5f);
    CHECK_NEAR(s.invmat[2], -4.0f / 41.0f, 1e-5f);
    CHECK_NEAR(s.invmat[4], -15.0f / 41.0f, 1e-5f);
    CHECK_NEAR(s.invmat[5], 19.0f / 41.0f, 1e-5f);
    CHECK_NEAR(s.invmat[6], -1.0f / 41.0f, 1e-5f);
    CHECK_NEAR(s.invmat[8], 12.0f / 41.0f, 1e-5f);
    CHECK_NEAR(s.invmat[9], -7.0f / 41.0f, 1e-5f);
    CHECK_NEAR(s.invmat[10], 9.0f / 41.0f, 1e-5f);
    CHECK_NEAR(s.invmat[12], -28.0f / 41.0f, 1e-5f);
    CHECK_NEAR(s.invmat[13], -11.0f / 41.0f, 1e-5f);
    CHECK_NEAR(s.invmat[14], -21.0f / 41.0f, 1e-5f);
    CHECK_NEAR(s.invmat[15], 1.0f, kTol);
}

TEST(invertMatrix_returns_false_for_a_singular_matrix)
{
    impShape s;
    for (int i = 0; i < 16; i++) s.mat[i] = 0.0f;

    const bool ok = s.invertMatrix();

    CHECK(!ok);
}

/* --- impShape::setMatrix -------------------------------------------------------
 *
 * Copies m into mat, inverts it into invmat via invertMatrix(), then builds
 * invtrmat by relocating invmat's entries: the linear 3x3 block transposed,
 * the translation column (invmat[12..14]) moved into the bottom row
 * (invtrmat[3,7,11]), and the all-zero bottom row (invmat[3,7,11]) moved
 * into the translation column (invtrmat[12..14]). The coupled matrix's
 * linear part is non-symmetric (see makeCoupledMatrix's comment), so a
 * verbatim invtrmat[k]=invmat[k] copy of any of the six off-diagonal
 * entries now disagrees with a real transpose -- and separately, the
 * translation/bottom-row swap: a verbatim invtrmat=invmat copy would leave
 * invtrmat[3]=invmat[3]=0 and invtrmat[12]=invmat[12]=-28/41, the opposite
 * of what setMatrix is supposed to produce. */

TEST(setMatrix_copies_mat_and_builds_invtrmat_as_the_transpose_of_invmat)
{
    impShape s;
    float m[16];
    makeCoupledMatrix(m);

    s.setMatrix(m);

    /* mat is copied verbatim. */
    for (int i = 0; i < 16; i++) CHECK_NEAR(s.mat[i], m[i], kTol);

    /* invertMatrix's own arithmetic is covered separately above; here it is
     * only the anchor values that setMatrix's relocation step has to move. */
    CHECK_NEAR(s.invmat[1], -6.0f / 41.0f, 1e-5f);
    CHECK_NEAR(s.invmat[12], -28.0f / 41.0f, 1e-5f);

    /* Linear block: each off-diagonal entry is checked two ways. The
     * hardcoded constant pins the value; the cross-check against invmat's
     * own (differently-indexed) entry confirms it is a transpose and not a
     * coincidence -- with a non-symmetric block, invmat[k] and invmat's
     * mirror entry now disagree, so a verbatim invtrmat[k]=invmat[k] copy
     * fails the second check even if it happened to pass the first. */
    CHECK_NEAR(s.invtrmat[1], -15.0f / 41.0f, 1e-5f);
    CHECK_NEAR(s.invtrmat[1], s.invmat[4], 1e-5f);
    CHECK_NEAR(s.invtrmat[4], -6.0f / 41.0f, 1e-5f);
    CHECK_NEAR(s.invtrmat[4], s.invmat[1], 1e-5f);
    CHECK_NEAR(s.invtrmat[2], 12.0f / 41.0f, 1e-5f);
    CHECK_NEAR(s.invtrmat[2], s.invmat[8], 1e-5f);
    CHECK_NEAR(s.invtrmat[8], -4.0f / 41.0f, 1e-5f);
    CHECK_NEAR(s.invtrmat[8], s.invmat[2], 1e-5f);
    CHECK_NEAR(s.invtrmat[6], -7.0f / 41.0f, 1e-5f);
    CHECK_NEAR(s.invtrmat[6], s.invmat[9], 1e-5f);
    CHECK_NEAR(s.invtrmat[9], -1.0f / 41.0f, 1e-5f);
    CHECK_NEAR(s.invtrmat[9], s.invmat[6], 1e-5f);

    /* Translation/bottom-row swap: this is what a verbatim copy would get
     * backwards. */
    CHECK_NEAR(s.invtrmat[3], -28.0f / 41.0f, 1e-5f);
    CHECK_NEAR(s.invtrmat[7], -11.0f / 41.0f, 1e-5f);
    CHECK_NEAR(s.invtrmat[11], -21.0f / 41.0f, 1e-5f);
    CHECK_NEAR(s.invtrmat[12], 0.0f, kTol);
    CHECK_NEAR(s.invtrmat[13], 0.0f, kTol);
    CHECK_NEAR(s.invtrmat[14], 0.0f, kTol);
    CHECK_NEAR(s.invtrmat[15], 1.0f, kTol);
}

/* --- impShape::addCrawlPoint ---------------------------------------------------
 *
 * Appends exactly one crawl point at the shape's translation (mat[12..14]). */

TEST(addCrawlPoint_appends_one_point_at_the_shapes_position)
{
    impShape s;
    s.setPosition(10.0f, 20.0f, 30.0f);

    impCrawlPointVector cpv;
    s.addCrawlPoint(cpv);

    CHECK(cpv.size() == 1);
    CHECK_NEAR(cpv[0].position[0], 10.0f, kTol);
    CHECK_NEAR(cpv[0].position[1], 20.0f, kTol);
    CHECK_NEAR(cpv[0].position[2], 30.0f, kTol);
}

TEST(addCrawlPoint_appends_rather_than_replaces)
{
    impShape s;

    impCrawlPointVector cpv;
    s.addCrawlPoint(cpv);
    CHECK(cpv.size() == 1);

    s.addCrawlPoint(cpv);
    CHECK(cpv.size() == 2);
}
