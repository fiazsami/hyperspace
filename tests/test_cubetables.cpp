/* Tests for the marching-cubes lookup tables.
 *
 * The helios file, ported. impCubeTables.h is identical between the two
 * submodules and impCubeTables.cpp differs only in the form of its own include,
 * so the tables and every expectation about them are the same. The wider
 * Implicit core has genuinely diverged here -- impCubeVolume::makeSurface takes
 * std::vector arguments in this copy -- but none of that reaches these two
 * tables.
 *
 * impCubeTables builds two 256-row tables in its constructor, one entry per
 * combination of "which of the eight cube corners are inside the surface".
 * Both are pure functions of cube topology, so the expectations here are
 * derived independently from that topology rather than read back from the
 * tables they are checking.
 *
 * The cube's edge list is duplicated below. That is deliberate: it is the
 * definition the tables must satisfy, and a test that asked the object for its
 * own edge list would agree with itself no matter what the object did. It is
 * also private, which is the same statement from the other direction.
 *
 * Encoding, from impCubeTables::addtotable: each row is a run of groups, each
 * group being a vertex count followed by that many edge indices, and a count of
 * 0 terminates the row. Edge indices are raw, 0 through 11.
 */

#include "harness.h"

#include "Implicit/impCubeTables.h"

namespace {

/* Which two corners each of the twelve edges joins. Matches the ec[][] table in
 * the constructor. */
const int kEdgeCorners[12][2] = {
    {0, 1}, {0, 2}, {1, 3}, {2, 3},
    {0, 4}, {1, 5}, {2, 6}, {3, 7},
    {4, 5}, {4, 6}, {5, 7}, {6, 7},
};

/* The four corners on each of the six faces, in the order crawlDirections uses:
 * -x, +x, -y, +y, -z, +z. Derived from which edges the constructor groups into
 * each face, and independently checked by kFaceEdges below. */
const int kFaceCorners[6][4] = {
    {0, 1, 2, 3},   /* -x */
    {4, 5, 6, 7},   /* +x */
    {0, 1, 4, 5},   /* -y */
    {2, 3, 6, 7},   /* +y */
    {0, 2, 4, 6},   /* -z */
    {1, 3, 5, 7},   /* +z */
};

const int kFaceEdges[6][4] = {
    {0, 1, 2, 3}, {8, 9, 10, 11}, {0, 4, 5, 8},
    {3, 6, 7, 11}, {1, 4, 6, 9}, {2, 5, 7, 10},
};

bool cornerIsInside(int mask, int corner)
{
    return (mask & (1 << corner)) != 0;
}

/* An edge crosses the surface when exactly one of its corners is inside. */
bool edgeCrosses(int mask, int edge)
{
    return cornerIsInside(mask, kEdgeCorners[edge][0])
        != cornerIsInside(mask, kEdgeCorners[edge][1]);
}

/* The tables are ~19KB together; keep them off the stack and build them once. */
impCubeTables &tables()
{
    static impCubeTables *instance = new impCubeTables();
    return *instance;
}

}  // namespace

TEST(face_corner_and_edge_groupings_agree)
{
    /* Guards the two hand-written tables above against each other, so a typo in
     * kFaceCorners cannot quietly make the crawl test vacuous. The four edges of
     * a face must touch exactly that face's four corners. */
    for (int face = 0; face < 6; face++) {
        for (int e = 0; e < 4; e++) {
            const int edge = kFaceEdges[face][e];
            for (int end = 0; end < 2; end++) {
                const int corner = kEdgeCorners[edge][end];
                bool found = false;
                for (int c = 0; c < 4; c++)
                    if (kFaceCorners[face][c] == corner) found = true;
                CHECK(found);
            }
        }
    }
}

TEST(crawl_directions_flag_exactly_the_straddled_faces)
{
    /* The surface enters a neighbouring cube through a face when that face's
     * four corners are not all inside and not all outside. Checked for all 256
     * corner combinations against all six faces -- 1536 independent
     * derivations, none of them read off the table. */
    impCubeTables &t = tables();

    for (int mask = 0; mask < 256; mask++) {
        for (int face = 0; face < 6; face++) {
            int inside = 0;
            for (int c = 0; c < 4; c++)
                if (cornerIsInside(mask, kFaceCorners[face][c])) inside++;

            const bool straddled = (inside != 0 && inside != 4);
            CHECK(t.crawlDirections[mask][face] == straddled);
        }
    }
}

TEST(crawl_directions_are_empty_for_a_uniform_cube)
{
    /* Wholly outside and wholly inside are the two cases with no surface at
     * all, and the two most likely to be special-cased wrongly. */
    impCubeTables &t = tables();
    for (int face = 0; face < 6; face++) {
        CHECK(t.crawlDirections[0][face] == false);
        CHECK(t.crawlDirections[255][face] == false);
    }
}

TEST(crawl_directions_are_symmetric_under_complement)
{
    /* Swapping inside for outside leaves the surface where it was, so a cube
     * and its complement must crawl in the same directions. */
    impCubeTables &t = tables();
    for (int mask = 0; mask < 256; mask++)
        for (int face = 0; face < 6; face++)
            CHECK(t.crawlDirections[mask][face] == t.crawlDirections[255 - mask][face]);
}

TEST(tri_strip_rows_are_well_formed)
{
    /* Structure before content: every row must parse as groups of
     * (count, count edges) and terminate inside its 17 slots. A row that runs
     * off the end would be read as garbage by the renderer. */
    impCubeTables &t = tables();

    for (int mask = 0; mask < 256; mask++) {
        int i = 0;
        while (i < 17 && t.triStripPatterns[mask][i] != 0) {
            const int count = t.triStripPatterns[mask][i];
            /* A triangle strip needs at least 3 vertices, and the comment in
             * addtotable caps a single strip at 7. */
            CHECK(count >= 3);
            CHECK(count <= 7);
            for (int e = 1; e <= count && i + e < 17; e++) {
                const int edge = t.triStripPatterns[mask][i + e];
                CHECK(edge >= 0);
                CHECK(edge < 12);
            }
            i += count + 1;
        }
        CHECK(i < 17);          /* the terminating zero is inside the row */
    }
}

TEST(tri_strips_reference_exactly_the_crossing_edges)
{
    /* The strongest statement available without reimplementing the algorithm:
     * a surface may only have vertices on edges that cross it, and every
     * crossing edge must carry at least one vertex or the surface has a hole.
     *
     * Derived per mask from the edge table, then compared against the row --
     * 256 independent checks of both directions. */
    impCubeTables &t = tables();

    for (int mask = 0; mask < 256; mask++) {
        bool referenced[12] = {false, false, false, false, false, false,
                               false, false, false, false, false, false};

        int i = 0;
        while (i < 17 && t.triStripPatterns[mask][i] != 0) {
            const int count = t.triStripPatterns[mask][i];
            for (int e = 1; e <= count && i + e < 17; e++) {
                const int edge = t.triStripPatterns[mask][i + e];
                if (edge >= 0 && edge < 12) referenced[edge] = true;
            }
            i += count + 1;
        }

        for (int edge = 0; edge < 12; edge++)
            CHECK(referenced[edge] == edgeCrosses(mask, edge));
    }
}

TEST(tri_strips_are_empty_for_a_uniform_cube)
{
    impCubeTables &t = tables();
    CHECK(t.triStripPatterns[0][0] == 0);
    CHECK(t.triStripPatterns[255][0] == 0);
}

TEST(every_non_uniform_cube_produces_a_surface)
{
    /* If any corner differs from any other, the surface passes through this
     * cube and the row must not be empty. A row that came back empty here would
     * be a hole in the mesh rather than a wrong triangle. */
    impCubeTables &t = tables();
    for (int mask = 1; mask < 255; mask++)
        CHECK(t.triStripPatterns[mask][0] != 0);
}
