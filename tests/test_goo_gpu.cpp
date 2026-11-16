/* Tests for the goo built by the renderer (HSRenderer::buildsGoo): what goo
 * hands such a renderer, and the triangle table its build reads.
 *
 * The table is checked the strong way: metal/GooBuild.metal's algorithm --
 * every cell, its corner mask, the table's triangles -- run here on the CPU
 * over the blocks goo chose, must give the triangles impCubeVolume built for
 * the same blocks, wound the same way.
 */

#include "harness.h"
#include "recorder.h"

#include "Hyperspace/renderer.h"
#include "Hyperspace/goo.h"
#include "Hyperspace/Hyperspace.h"
#include "Implicit/impSurface.h"

#include <math.h>
#include <stdlib.h>
#include <string.h>
#include <algorithm>
#include <vector>

namespace {
struct Seeded { Seeded() { srand(7); } };

/* Corner i of a cell is at (i >> 2, i >> 1, i) & 1; GooBuild.metal's kEdge. */
const int kEdge[12][2] = {{0, 1}, {0, 2}, {1, 3}, {2, 3}, {0, 4}, {1, 5},
                          {2, 6}, {3, 7}, {4, 5}, {4, 6}, {5, 7}, {6, 7}};

/* A triangle as three points rounded to a grid well below a cell, rotated so
 * the smallest point leads: the same triangle, wound the same way, gives the
 * same key wherever it was built. */
typedef std::vector<long> Key;
Key keyOf(const float p[3][3])
{
    long q[3][3];
    for (int v = 0; v < 3; v++)
        for (int k = 0; k < 3; k++) q[v][k] = lround(p[v][k] * 1000.0f);
    int lead = 0;
    for (int v = 1; v < 3; v++)
        if (std::lexicographical_compare(q[v], q[v] + 3, q[lead], q[lead] + 3)) lead = v;
    Key key;
    for (int v = 0; v < 3; v++) key.insert(key.end(), q[(lead + v) % 3], q[(lead + v) % 3] + 3);
    return key;
}

/* GooBuild.metal's goo_build over one block, in the block's own coordinates
 * (as impCubeVolume places its vertices), with goo::function for the field. */
std::vector<Key> buildLikeTheKernel(goo &g, short table[256][HS_GOO_TABLE_ROW])
{
    std::vector<Key> out;
    const int res = g.resolution;
    const float half = 0.5f * g.volumeSize;
    for (int x = 0; x < res; x++) for (int y = 0; y < res; y++) for (int z = 0; z < res; z++) {
        float corner[8][3], value[8];
        int mask = 0;
        for (int i = 0; i < 8; i++) {
            corner[i][0] = (x + ((i >> 2) & 1)) * g.unitSize - half;
            corner[i][1] = (y + ((i >> 1) & 1)) * g.unitSize - half;
            corner[i][2] = (z + (i & 1)) * g.unitSize - half;
            value[i] = goo::function(corner[i], &g);
            if (value[i] < 0.4f) mask |= 1 << i;
        }
        for (int t = 0; t < table[mask][0]; t++) {
            float tri[3][3];
            for (int v = 0; v < 3; v++) {
                const int *e = kEdge[table[mask][1 + 3 * t + v]];
                const float f = (0.4f - value[e[0]]) / (value[e[1]] - value[e[0]]);
                for (int k = 0; k < 3; k++)
                    tri[v][k] = corner[e[0]][k] + f * (corner[e[1]][k] - corner[e[0]][k]);
            }
            out.push_back(keyOf(tri));
        }
    }
    return out;
}

std::vector<Key> trianglesOf(const impSurface *s)
{
    std::vector<Key> out;
    for (unsigned int i = 0; i + 2 < s->getIndexCount(); i += 3) {
        float tri[3][3];
        for (int v = 0; v < 3; v++)
            memcpy(tri[v], s->getVertex(s->getIndex(i + v)) + 3, sizeof tri[v]);
        out.push_back(keyOf(tri));
    }
    return out;
}
}

TEST(goo_triangle_table_rows_are_whole_triangles_of_real_edges)
{
    short table[256][HS_GOO_TABLE_ROW];
    hsGooTriangleTable(table);
    /* Nothing inside and everything inside cross no edge. */
    CHECK(table[0][0] == 0);
    CHECK(table[255][0] == 0);
    for (int m = 0; m < 256; m++) {
        CHECK(table[m][0] >= 0 && table[m][0] <= 5);
        for (int k = 1; k < 1 + 3 * table[m][0]; k++) CHECK(table[m][k] >= 0 && table[m][k] < 12);
        for (int k = 1 + 3 * table[m][0]; k < HS_GOO_TABLE_ROW; k++) CHECK(table[m][k] == 0);
    }
    /* Corner 0 alone inside cuts the three edges that meet there, 0 1 and 4,
     * and its complement cuts the same three. */
    CHECK(table[1][0] == 1);
    short one[3] = {table[1][1], table[1][2], table[1][3]};
    std::sort(one, one + 3);
    CHECK(one[0] == 0 && one[1] == 1 && one[2] == 4);
    CHECK(table[254][0] == 1);
}

TEST(goo_built_from_the_table_is_the_surface_impcubevolume_builds)
{
    Seeded seed;
    short table[256][HS_GOO_TABLE_ROW];
    hsGooTriangleTable(table);
    HyperspaceSaverSettings s;
    memset(&s, 0, sizeof s);
    s.frameTime = 1.0f / 60.0f;
    goo g(12, 6.0f);
    g.update(0.3f, 0.2f, 0.1f, 1.75f, &s);   // no renderer: built on the CPU

    int blocks = 0;
    size_t triangles = 0;
    for (int i = 0; i < g.arraySize; i++) for (int j = 0; j < g.arraySize; j++) {
        if (!g.useSurface[i][j]) continue;
        /* goo::function reads the block's shift, which update leaves at the
         * last block it built. */
        g.shiftx = g.centerx + g.volumeSize * (0.5f + float(i - g.arraySize / 2));
        g.shiftz = g.centerz + g.volumeSize * (0.5f + float(j - g.arraySize / 2));
        std::vector<Key> cpu = trianglesOf(g.surface[i][j]);
        std::vector<Key> gpu = buildLikeTheKernel(g, table);
        std::sort(cpu.begin(), cpu.end());
        std::sort(gpu.begin(), gpu.end());
        CHECK(gpu.size() == cpu.size());
        CHECK(gpu == cpu);
        blocks++;
        triangles += cpu.size();
    }
    CHECK(blocks > 4);
    CHECK(triangles > 10000);
}

TEST(goo_hands_a_renderer_that_builds_it_the_field_and_builds_nothing)
{
    Seeded seed;
    Recorder gpu;
    gpu.gooOnGPU = true;
    HyperspaceSaverSettings s;
    memset(&s, 0, sizeof s);
    s.frameTime = 0.5f;
    s.renderer = &gpu;
    goo g(4, 5.0f);
    for (int i = 0; i < 4; i++) { g.cp[i] = 0.0f; g.cs[i] = 0.2f * (i + 1); }
    g.update(0.7f, -0.3f, 0.4f, 1.0f, &s);

    /* The same blocks are chosen, and none is built. */
    int used = 0;
    for (int i = 0; i < 6; i++) for (int j = 0; j < 6; j++) {
        used += g.useSurface[i][j];
        CHECK(g.surface[i][j]->getIndexCount() == 0);
    }
    CHECK(used > 0);

    g.draw(&gpu);
    CHECK(gpu.goo.empty());
    CHECK(gpu.gooFields.size() == 1);
    const HSGooField &f = gpu.gooFields[0];
    for (int i = 0; i < 4; i++) CHECK(f.c[i] == g.c[i]);
    CHECK(f.camx == g.camx && f.camz == g.camz);
    CHECK_NEAR(f.origin[0], 0.8, 1e-5);
    CHECK_NEAR(f.origin[1], 0.0, 1e-5);
    CHECK(f.unitSize == g.unitSize);
    CHECK(f.volumeSize == g.volumeSize);
    CHECK(f.resolution == 5);
    CHECK_NEAR(f.surface, 0.4, 1e-7);
    CHECK(f.offsets.size() == size_t(2 * used));
    /* Block (0, 0), whose centre the CPU path draws its surface at. */
    CHECK_NEAR(f.offsets[0], 0.8 - 5.0, 1e-5);
    CHECK_NEAR(f.offsets[1], -5.0, 1e-5);

    /* Drawn once per update, as surfaces are. */
    Recorder again;
    again.gooOnGPU = true;
    g.draw(&again);
    CHECK(again.gooFields.empty());
}

TEST(goo_builds_the_surfaces_it_skipped_for_a_renderer_that_wants_them)
{
    /* The same goo, updated twice from the same state: once for a CPU
     * renderer, once for one that builds the goo -- then drawn through a CPU
     * renderer, which must get the surfaces the first built. */
    HyperspaceSaverSettings s;
    memset(&s, 0, sizeof s);
    s.frameTime = 0.5f;
    Recorder cpu, gpu;
    gpu.gooOnGPU = true;

    srand(7);
    goo want(6, 5.0f);
    s.renderer = &cpu;
    want.update(0.7f, -0.3f, 0.4f, 1.0f, &s);
    srand(7);
    goo got(6, 5.0f);
    s.renderer = &gpu;
    got.update(0.7f, -0.3f, 0.4f, 1.0f, &s);

    Recorder drawn;
    got.draw(&drawn);
    CHECK(!drawn.goo.empty());
    for (size_t n = 0; n < drawn.goo.size(); n++) {
        const impSurface *a = drawn.goo[n].surface;
        bool found = false;
        for (int i = 0; i < want.arraySize; i++) for (int j = 0; j < want.arraySize; j++) {
            if (got.surface[i][j] != a) continue;
            found = true;
            std::vector<Key> have = trianglesOf(a), expect = trianglesOf(want.surface[i][j]);
            CHECK(!expect.empty() || want.surface[i][j]->getIndexCount() == 0);
            CHECK(have == expect);
        }
        CHECK(found);
    }
}
