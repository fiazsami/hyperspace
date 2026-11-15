/* Tests for Hyperspace's texture generation through HSRenderer: the CPU mip
 * chain that replaced gluBuild2DMipmaps, the caustics rendered offscreen and
 * read back, and the wavy normal cube maps.
 *
 * hsBuildMipmaps' contract is "what Apple's GLU builds", which was measured
 * byte for byte on random 32, 128 and 256 images; here it is pinned on inputs
 * small enough to work out by hand, including the rounding that measurement
 * settled.
 */

#include "harness.h"
#include "recorder.h"

#include "Hyperspace/renderer.h"
#include "Hyperspace/causticTextures.h"
#include "Hyperspace/wavyNormalCubeMaps.h"

#include <math.h>

namespace {
const double kTol = 1e-5;
}

TEST(textures_mip_chain_halves_to_one_texel)
{
    unsigned char img[8 * 8 * 3];
    for (int i = 0; i < 8 * 8 * 3; i++) img[i] = (unsigned char)i;
    HSMipChain c;
    CHECK(hsBuildMipmaps(img, 8, 3, c));
    CHECK(c.size == 8);
    CHECK(c.channels == 3);
    CHECK(c.levels.size() == 4);
    const int sizes[4] = {8, 4, 2, 1};
    for (size_t l = 0; l < c.levels.size() && l < 4; l++)
        CHECK(c.levels[l].size() == size_t(sizes[l] * sizes[l] * 3));
    CHECK(c.levels[0][100] == 100);             /* level 0 is the image */
}

TEST(textures_mip_texel_is_the_rounded_mean_of_its_block)
{
    /* 2x2 RGBA. Red sums to 2: (2+2)/4 = 1 -- a truncating mean gives 0.
     * Green sums to 1: (1+2)/4 = 0 -- rounding half up from 0.25 is still 0.
     * Blue 255s stay 255. Alpha 10, 20, 30, 40 -> (100+2)/4 = 25. Rows are
     * taken from the right place: the second row is the bottom pair. */
    const unsigned char img[16] = {0, 0, 255, 10,   1, 1, 255, 20,
                                   1, 0, 255, 30,   0, 0, 255, 40};
    HSMipChain c;
    CHECK(hsBuildMipmaps(img, 2, 4, c));
    CHECK(c.levels.size() == 2);
    CHECK(c.levels[1][0] == 1);
    CHECK(c.levels[1][1] == 0);
    CHECK(c.levels[1][2] == 255);
    CHECK(c.levels[1][3] == 25);

    /* Each texel averages its own block: in a 4x4 one-channel image, only the
     * top-right block is 4s. */
    unsigned char grey[16] = {0};
    grey[2] = grey[3] = grey[6] = grey[7] = 4;
    CHECK(hsBuildMipmaps(grey, 4, 1, c));
    CHECK(c.levels[1][0] == 0);
    CHECK(c.levels[1][1] == 4);
    CHECK(c.levels[1][2] == 0);
    CHECK(c.levels[1][3] == 0);
    CHECK(c.levels[2][0] == 1);                 /* (0+4+0+0+2)/4 */
}

TEST(textures_mip_chain_refuses_what_glu_would_rescale)
{
    unsigned char img[12 * 12 * 3] = {0};
    HSMipChain c;
    c.size = 77;
    CHECK(!hsBuildMipmaps(img, 12, 3, c));
    CHECK(c.size == 77);                        /* untouched */
    CHECK(!hsBuildMipmaps(img, 0, 3, c));
    CHECK(!hsBuildMipmaps(img, 4, 0, c));
    CHECK(hsBuildMipmaps(img, 1, 3, c));        /* 1 is a power of two */
    CHECK(c.levels.size() == 1);
}

TEST(textures_caustics_render_each_frame_offscreen_and_keep_the_readback)
{
    Recorder r;
    /* 2 keys, 4 frames, a 10x10 mesh, 8x8 textures, refraction 2. */
    causticTextures ct(&r, 2, 4, 10, 8, 1.0f, 0.01f, 2.0f);

    CHECK(r.offscreens.size() == 4);
    CHECK(r.mipmapped.size() == 4);
    for (size_t k = 0; k < r.offscreens.size(); k++) CHECK(r.offscreens[k].size == 8);
    for (size_t k = 0; k < r.mipmapped.size(); k++) {
        CHECK(r.mipmapped[k].size == 8);
        CHECK(r.mipmapped[k].channels == 3);
        CHECK(r.mipmapped[k].levels.size() == 4);
        /* the texture is frame k's readback, not another frame's */
        CHECK(r.mipmapped[k].levels[0][0] == (unsigned char)k);
        CHECK(ct.caustictex[k] == 101u + k);
    }
    CHECK(!r.inOffscreen);
}

TEST(textures_caustics_tile_the_mesh_with_wrapped_edges)
{
    Recorder r;
    causticTextures ct(&r, 2, 4, 10, 8, 1.0f, 0.01f, 2.0f);
    const Offscreen &o = r.offscreens[0];

    /* Rows drawn, numRows = 1: the full mesh (10), the left and right
     * wraps (10 each), the far and near wraps (1 each), four corners (1
     * each). Three strips -- red, green, blue -- per row. */
    CHECK(o.strips.size() == size_t(3 * (10 + 10 + 10 + 1 + 1 + 4)));
    CHECK(o.strips[0].size() == 22);            /* 11 columns, 2 vertices each */

    /* The left wrap starts after the full mesh, shifted one texture left:
     * its first vertex sits at x = 9/10 - 1 plus the refraction offset. */
    const std::vector<HSColorVertex> &left = o.strips[30];
    CHECK(left.size() == 4);
    CHECK(left[0].pos[0] < 0.0f);
    CHECK(left[0].pos[0] > -0.2f);
    /* The near wrap (shifted +1 in z) lands above the target. */
    const std::vector<HSColorVertex> &nearRow = o.strips[3 * (10 + 10 + 10 + 1)];
    CHECK(nearRow[0].pos[1] > 1.0f);

    /* Red, green and blue strips carry one channel each, the same intensity. */
    for (int c = 0; c < 3; c++) {
        const HSColorVertex &v = o.strips[c][0];
        for (int other = 0; other < 3; other++)
            if (other != c) CHECK(v.color[other] == 0.0f);
        CHECK(v.color[c] == o.strips[0][0].color[0]);
        CHECK(v.pos[2] == 0.0f);
    }
}

TEST(textures_caustics_refract_red_less_and_blue_more_than_green)
{
    Recorder r;
    causticTextures ct(&r, 2, 4, 10, 8, 1.0f, 0.01f, 2.0f);
    const Offscreen &o = r.offscreens[0];
    /* At column 0 the mesh x is 0, so a vertex's x is its refraction offset:
     * green's unscaled, red's times 1 - 2/10, blue's times 1 + 2/10. */
    int checked = 0;
    for (size_t row = 0; row + 2 < 30; row += 3) {
        float red = o.strips[row][0].pos[0], green = o.strips[row + 1][0].pos[0], blue = o.strips[row + 2][0].pos[0];
        if (fabsf(green) < 1e-4f) continue;
        CHECK_NEAR(red / green, 0.8, 1e-4);
        CHECK_NEAR(blue / green, 1.2, 1e-4);
        checked++;
    }
    CHECK(checked > 0);
}

TEST(textures_normal_cube_faces_point_their_own_way)
{
    Recorder r;
    wavyNormalCubeMaps w(&r, 2, 4);
    CHECK(r.cubes.size() == 2);
    CHECK(w.texture[0] == 101u && w.texture[1] == 102u);
    for (size_t g = 0; g < r.cubes.size(); g++) {
        CHECK(r.cubes[g].size() == 6);
        for (int f = 0; f < 6; f++) {
            const HSMipChain &face = r.cubes[g][f];
            CHECK(face.size == 4);
            CHECK(face.levels.size() == 3);
            if (face.levels.empty()) return;    /* a face never built: stop here */
        }
        /* Near a face's centre the normal is close to the face's axis. Bytes
         * are n * 127.999 + 128, except blue, which is stored negated. Faces
         * are ordered -x +x -y +y -z +z. */
        const int texel = (1 + 1 * 4) * 3;
        const std::vector<unsigned char> *l0[6];
        for (int f = 0; f < 6; f++) l0[f] = &r.cubes[g][f].levels[0];
        CHECK((*l0[0])[texel + 0] < 64);
        CHECK((*l0[1])[texel + 0] > 192);
        CHECK((*l0[2])[texel + 1] < 64);
        CHECK((*l0[3])[texel + 1] > 192);
        CHECK((*l0[4])[texel + 2] > 192);
        CHECK((*l0[5])[texel + 2] < 64);
    }
    /* Consecutive frames differ: the phase advances. */
    CHECK(r.cubes[0][0].levels[0] != r.cubes[1][0].levels[0]);
}

TEST(textures_caustics_clamp_their_inputs)
{
    /* keys to 2, frames to 2 * keys, the mesh and the texture to 8. */
    Recorder r;
    causticTextures ct(&r, 1, 3, 4, 4, 1.0f, 0.01f, 2.0f);
    CHECK(ct.numKeys == 2);
    CHECK(ct.numFrames == 4);
    CHECK(ct.geoRes == 8);
    CHECK(ct.texSize == 8);
    CHECK(r.offscreens.size() == 4);
    for (size_t k = 0; k < r.offscreens.size(); k++) CHECK(r.offscreens[k].size == 8);
    CHECK(r.offscreens[0].strips[0].size() == 18);   /* 9 columns */
}

TEST(textures_caustics_clamp_focused_light_to_full_intensity)
{
    /* Waves of amplitude 0.05 focus the light enough that the intensity
     * formula exceeds 1 (it peaks at 0.56 for 0.03), and it is held at 1. */
    Recorder r;
    causticTextures ct(&r, 2, 4, 10, 8, 1.0f, 0.05f, 2.0f);
    float brightest = 0.0f;
    const Offscreen &o = r.offscreens[0];
    for (size_t s = 0; s < 30; s += 3)
        for (size_t v = 0; v < o.strips[s].size(); v++)
            if (o.strips[s][v].color[0] > brightest) brightest = o.strips[s][v].color[0];
    CHECK(brightest == 1.0f);
}
