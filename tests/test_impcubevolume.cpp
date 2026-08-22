/* Characterization of impCubeVolume -- the marching-cubes pipeline the Metal
 * port is about to rewrite, and the whole of the gate's criterion 1 (ss-or3).
 *
 * The method, and why it is not a golden run.
 *
 * A golden-master test over this code would record the 294 vertices it emits
 * today and check for 294 tomorrow. That pins the output without ever saying
 * what is right about it, so it fails identically whether the port broke the
 * corner mask or merely reordered two triangles. Instead every assertion here
 * is derived from geometry that holds independently of the implementation.
 *
 * The field is an analytic sphere:
 *
 *     f(p) = 1 + R^2 - |p|^2,  with surfacevalue = 1
 *
 * so f(p) >= surfacevalue exactly when |p| <= R -- the solid is the ball, the
 * isosurface is the sphere, and "inside" matches the >= convention the code
 * uses. The +1 keeps the threshold off zero, so a bug that treated 0 specially
 * could not hide.
 *
 * THE TOLERANCE IS DERIVED, NOT MEASURED. Marching cubes places each vertex by
 * linearly interpolating f along one axis-aligned cube edge. Along an edge
 * where only x varies, f is a quadratic in x with f'' = -2, and the error of
 * linear interpolation of a quadratic over [a, a+h] is exactly
 *
 *     f(x) - L(x) = -(x - a)(x - (a + h)),   |error| <= h^2/4
 *
 * with the maximum at the edge midpoint. The interpolation solves L = 1, so at
 * the emitted vertex v the true field satisfies |f(v) - 1| <= h^2/4, which is
 * |R^2 - |v|^2| <= h^2/4 exactly. Better still, the sign is fixed: the
 * expression above is >= 0 across the whole edge, so f(v) >= 1 and therefore
 *
 *     R^2 - h^2/4  <=  |v|^2  <=  R^2
 *
 * A vertex outside the sphere is impossible, not merely unlikely. That
 * one-sided bound is the sharpest thing here and the easiest for a broken
 * interpolation to violate.
 *
 * Checked against reality before it was written down: with h = 0.25 the bound
 * is 0.015625 and the worst vertex sits at 0.0153061, 98% of the way to it and
 * never past. The tolerance is tight because it is the real bound, not padding.
 */

#include "harness.h"

#include <Implicit/impCubeVolume.h>
#include <Implicit/impCrawlPoint.h>
#include <Implicit/impSurface.h>

#include <algorithm>
#include <cmath>
#include <cstring>
#include <map>
#include <new>
#include <utility>
#include <vector>

namespace {

/* Grid: 16 cubes per side at width 0.25 spans [-2, 2], so a radius-1 sphere
 * clears the boundary by a full radius. A surface touching the edge of the
 * volume would exercise the boundary clamp instead of the geometry, which is a
 * different test and not this one. */
const float kCubeWidth = 0.25f;
const unsigned int kCubes = 16;
const float kRadius = 1.0f;
const float kSurfaceValue = 1.0f;

/* R^2 - h^2/4, the exact lower bound derived in the header comment. */
const double kR2 = double(kRadius) * kRadius;
const double kBound = double(kCubeWidth) * kCubeWidth / 4.0;

/* Float accumulation of x*x + y*y + z*z leaves a few ulps of slack that the
 * derivation does not model; 1e-6 is far below h^2/4 = 1.6e-2 and cannot
 * disguise a real interpolation error. */
const double kFloatSlack = 1e-6;

float sphereField(float *p, void *context)
{
    const float r2 = *(float *)context;
    return 1.0f + r2 - (p[0] * p[0] + p[1] * p[1] + p[2] * p[2]);
}

struct TwoSpheres {
    float r2;
    float centre;
};

/* Two disjoint balls of radius R at (+-centre, 0, 0), as the pointwise max of
 * two sphere fields. Disjoint matters: it is the only way to tell a crawl from
 * an exhaustive scan, because on one connected surface they agree exactly. */
float twoSphereField(float *p, void *context)
{
    const TwoSpheres *t = (const TwoSpheres *)context;
    const float dx0 = p[0] - t->centre;
    const float dx1 = p[0] + t->centre;
    const float a = 1.0f + t->r2 - (dx0 * dx0 + p[1] * p[1] + p[2] * p[2]);
    const float b = 1.0f + t->r2 - (dx1 * dx1 + p[1] * p[1] + p[2] * p[2]);
    return a > b ? a : b;
}

/* Every case wants the same volume, and impCubeVolume has no copy semantics
 * worth relying on, so this configures one in place. */
void configureSphere(impCubeVolume &volume, float &r2Storage)
{
    r2Storage = float(kR2);
    volume.function = sphereField;
    volume.contextInfoForFunction = &r2Storage;
    volume.init(kCubes, kCubes, kCubes, kCubeWidth);
    volume.setSurfaceValue(kSurfaceValue);
}

/* One emitted vertex, copied out of the surface so it survives the next
 * makeSurface call. Ordered so that a whole surface can be put in a canonical
 * order and compared as a set. */
struct Vertex {
    float data[6];

    bool operator==(const Vertex &other) const
    {
        for (int i = 0; i < 6; i++)
            if (data[i] != other.data[i]) return false;
        return true;
    }

    bool operator<(const Vertex &other) const
    {
        for (int i = 0; i < 6; i++) {
            if (data[i] < other.data[i]) return true;
            if (data[i] > other.data[i]) return false;
        }
        return false;
    }
};

std::vector<Vertex> collectVertices(const impSurface *surface)
{
    std::vector<Vertex> out;
    out.reserve(surface->getVertexCount());
    for (unsigned int i = 0; i < surface->getVertexCount(); i++) {
        Vertex v;
        const float *d = surface->getVertex(i);
        for (int k = 0; k < 6; k++) v.data[k] = d[k];
        out.push_back(v);
    }
    return out;
}

double squaredRadius(const float *vertex)
{
    return double(vertex[3]) * vertex[3] + double(vertex[4]) * vertex[4] +
           double(vertex[5]) * vertex[5];
}

/* cos of the angle between the emitted normal and the outward radial
 * direction. On a sphere centred at the origin the position vector *is* the
 * outward normal, so this is the whole error of the normal computation. */
double radialCosine(const float *vertex)
{
    const double dot = double(vertex[0]) * vertex[3] + double(vertex[1]) * vertex[4] +
                       double(vertex[2]) * vertex[5];
    const double nLen = std::sqrt(double(vertex[0]) * vertex[0] +
                                  double(vertex[1]) * vertex[1] +
                                  double(vertex[2]) * vertex[2]);
    const double pLen = std::sqrt(squaredRadius(vertex));
    if (nLen == 0.0 || pLen == 0.0) return 0.0;
    return dot / (nLen * pLen);
}

}  // namespace

/* The core claim: every vertex marching cubes emits lies on the sphere, within
 * the interpolation error and never outside it. This is what a port must not
 * change, and it exercises the corner mask, the edge interpolation, the vertex
 * cache and the field evaluation in one assertion. */
TEST(impcubevolume_every_vertex_lies_within_the_derived_bound)
{
    impCubeVolume volume;
    float r2;
    configureSphere(volume, r2);
    volume.makeSurface();

    const impSurface *surface = volume.getSurface();
    const unsigned int count = surface->getVertexCount();

    /* A silent zero would pass every per-vertex assertion below. */
    CHECK(count > 0);

    for (unsigned int i = 0; i < count; i++) {
        const double r2v = squaredRadius(surface->getVertex(i));
        CHECK(r2v <= kR2 + kFloatSlack);
        CHECK(r2v >= kR2 - kBound - kFloatSlack);
    }
}

/* The bound is only worth asserting if it is nearly attained -- a test that
 * allowed ten times the real error would pass a badly broken interpolation.
 * The worst vertex must sit in the top half of the permitted band. */
TEST(impcubevolume_the_bound_is_tight_not_generous)
{
    impCubeVolume volume;
    float r2;
    configureSphere(volume, r2);
    volume.makeSurface();

    const impSurface *surface = volume.getSurface();
    double worstDeficit = 0.0;
    for (unsigned int i = 0; i < surface->getVertexCount(); i++) {
        const double deficit = kR2 - squaredRadius(surface->getVertex(i));
        if (deficit > worstDeficit) worstDeficit = deficit;
    }

    CHECK(worstDeficit <= kBound);
    CHECK(worstDeficit > kBound * 0.5);
}

/* Indices are triangles into the vertex array. Nothing about the geometry
 * checks this: a pipeline could emit perfect vertices and index them wrongly,
 * and every assertion above would still pass. */
TEST(impcubevolume_indices_are_triangles_into_the_vertex_array)
{
    impCubeVolume volume;
    float r2;
    configureSphere(volume, r2);
    volume.makeSurface();

    const impSurface *surface = volume.getSurface();
    const unsigned int vertices = surface->getVertexCount();
    const unsigned int indices = surface->getIndexCount();

    CHECK(indices > 0);
    CHECK(indices % 3 == 0);

    unsigned int highest = 0;
    for (unsigned int i = 0; i < indices; i++) {
        const unsigned int index = surface->getIndex(i);
        CHECK(index < vertices);
        if (index > highest) highest = index;
    }

    /* Every vertex is referenced, so the array has no dead entries: the
     * highest index reaches the last one. */
    CHECK(highest == vertices - 1);
}

/* The mesh is watertight: every edge is shared by exactly two triangles.
 *
 * This is the invariant that says the surface has no holes, and none of the
 * per-vertex assertions above can see it -- a pipeline that dropped whole
 * cubes would still place every vertex it *did* emit perfectly on the sphere.
 * The isosurface of a continuous field over a closed region is a closed
 * manifold, so this must hold for any correct implementation, whatever
 * tessellation it chooses. */
TEST(impcubevolume_the_mesh_is_a_closed_manifold)
{
    impCubeVolume volume;
    float r2;
    configureSphere(volume, r2);
    volume.makeSurface();

    const impSurface *surface = volume.getSurface();
    const unsigned int indices = surface->getIndexCount();
    CHECK(indices > 0);

    const unsigned int vertices = surface->getVertexCount();

    std::map<std::pair<unsigned int, unsigned int>, int> edges;
    for (unsigned int t = 0; t + 2 < indices; t += 3) {
        const unsigned int corner[3] = {surface->getIndex(t), surface->getIndex(t + 1),
                                        surface->getIndex(t + 2)};
        /* Range-check here rather than trusting the case that asserts it.
         * harness_fail records and continues, so a failure over there does not
         * stop this loop, and getVertex does not bounds-check -- an out-of-
         * range index reads unmapped memory and takes the whole binary down,
         * which coverage.sh reports as a build error rather than a test
         * failure. ss-ma1 produces exactly that state. */
        if (corner[0] >= vertices || corner[1] >= vertices || corner[2] >= vertices) {
            CHECK(corner[0] < vertices && corner[1] < vertices && corner[2] < vertices);
            return;
        }
        for (int k = 0; k < 3; k++) {
            unsigned int a = corner[k];
            unsigned int b = corner[(k + 1) % 3];
            if (a > b) { const unsigned int tmp = a; a = b; b = tmp; }
            edges[std::make_pair(a, b)]++;
        }
    }

    CHECK(edges.size() > 0);
    unsigned int nonManifold = 0;
    for (std::map<std::pair<unsigned int, unsigned int>, int>::const_iterator it = edges.begin();
         it != edges.end(); ++it)
        if (it->second != 2) nonManifold++;
    CHECK(nonManifold == 0);
}

/* The triangulated area matches the sphere it approximates.
 *
 * BOTH BOUNDS ARE EMPIRICAL. An earlier version of this comment called the
 * upper bound analytic, reasoning that every vertex lies on or inside the
 * sphere so the surface is inscribed and cannot exceed the sphere's area.
 * That is not a theorem. Inscribing does not bound area: the Schwarz lantern
 * is a cylinder-inscribed triangulation whose area diverges as it is refined,
 * and the argument would need convexity of the polyhedron, which nothing here
 * establishes -- vertices may sit anywhere in the shell R^2 - h^2/4 <= |v|^2
 * <= R^2 and a crinkled tessellation of that shell can have more area than the
 * sphere.
 *
 * What is true is that marching cubes on a uniform grid produces a
 * well-shaped tessellation whose area converges from below at order (h/R)^2.
 * Here h/R = 0.25 and the measured ratio is 0.9735. The bounds are 0.95 and
 * 1.0: wide enough for a different but still-correct tessellation, tight
 * enough to catch a mesh that has lost whole regions. If a port ever trips the
 * upper bound, the honest reading is "this tessellation is rougher than the
 * one we characterized", not "this is mathematically impossible".
 *
 * This is the assertion that would catch triangles going missing, which is
 * worth stating because a kill-check found the one mutation that does *not*
 * disturb it: changing the corner mask's `<` to `<=` moves 24 vertices and 48
 * triangles, and leaves the area identical to six decimal places. Those
 * triangles are zero-area slivers emitted where a grid corner sits exactly on
 * the threshold -- with this field, six corners do. Emitting them or not is a
 * tessellation detail a port is free to change; losing real area is not. The
 * suite deliberately draws the line there. */
TEST(impcubevolume_the_triangulated_area_matches_the_sphere)
{
    impCubeVolume volume;
    float r2;
    configureSphere(volume, r2);
    volume.makeSurface();

    const impSurface *surface = volume.getSurface();
    const unsigned int indices = surface->getIndexCount();
    CHECK(indices > 0);

    const unsigned int vertices = surface->getVertexCount();

    double area = 0.0;
    for (unsigned int t = 0; t + 2 < indices; t += 3) {
        const unsigned int ia = surface->getIndex(t);
        const unsigned int ib = surface->getIndex(t + 1);
        const unsigned int ic = surface->getIndex(t + 2);
        /* Same reason as the manifold case: getVertex does not bounds-check,
         * and a bad index here is a crash rather than a failed assertion. */
        if (ia >= vertices || ib >= vertices || ic >= vertices) {
            CHECK(ia < vertices && ib < vertices && ic < vertices);
            return;
        }
        const float *a = surface->getVertex(ia);
        const float *b = surface->getVertex(ib);
        const float *c = surface->getVertex(ic);
        const double ux = double(b[3]) - a[3], uy = double(b[4]) - a[4], uz = double(b[5]) - a[5];
        const double vx = double(c[3]) - a[3], vy = double(c[4]) - a[4], vz = double(c[5]) - a[5];
        const double cx = uy * vz - uz * vy;
        const double cy = uz * vx - ux * vz;
        const double cz = ux * vy - uy * vx;
        area += 0.5 * std::sqrt(cx * cx + cy * cy + cz * cz);
    }

    const double sphereArea = 4.0 * 3.14159265358979323846 * kR2;
    /* Both empirical -- see the header comment. Inscribing does not bound
     * area, so this pair brackets the measured 0.9735 rather than proving it. */
    CHECK(area < sphereArea);
    CHECK(area > sphereArea * 0.95);
}

/* Normals point out of the solid, not into it. Getting this backwards is the
 * classic marching-cubes sign error, it is invisible in vertex positions, and
 * on a real renderer it shows up only as lighting that looks subtly wrong. */
TEST(impcubevolume_normals_point_outward)
{
    impCubeVolume volume;
    float r2;
    configureSphere(volume, r2);
    volume.useFastNormals(false);
    volume.makeSurface();

    const impSurface *surface = volume.getSurface();
    CHECK(surface->getVertexCount() > 0);
    for (unsigned int i = 0; i < surface->getVertexCount(); i++)
        CHECK(radialCosine(surface->getVertex(i)) > 0.0);
}

/* useFastNormals trades accuracy for a cheaper difference, and both paths are
 * live code. Asserting the *ordering* rather than two magic angles pins the
 * trade-off itself: whichever way the constants drift, the accurate path has
 * to stay the accurate one. */
TEST(impcubevolume_fast_normals_are_coarser_than_accurate_ones)
{
    double worst[2];

    for (int fast = 0; fast < 2; fast++) {
        impCubeVolume volume;
        float r2;
        configureSphere(volume, r2);
        volume.useFastNormals(fast != 0);
        volume.makeSurface();

        const impSurface *surface = volume.getSurface();
        CHECK(surface->getVertexCount() > 0);

        worst[fast] = 1.0;
        for (unsigned int i = 0; i < surface->getVertexCount(); i++) {
            const double c = radialCosine(surface->getVertex(i));
            CHECK(c > 0.0);  /* both paths must still face outward */
            if (c < worst[fast]) worst[fast] = c;
        }
    }

    /* Accurate normals land within a fraction of a degree of radial; the fast
     * forward difference is visibly worse but still well inside a right
     * angle. Both figures are properties of a quadratic field on a uniform
     * grid, not of this particular sphere. */
    CHECK(worst[0] > 0.99);
    CHECK(worst[1] > 0.9);
    CHECK(worst[1] < worst[0]);
}

/* The crawl overloads walk outward from seed points; makeSurface() with no
 * arguments visits every cube. On one connected surface the two agree exactly,
 * which is why this uses two disjoint balls -- it is the only configuration
 * where the difference between the code paths is observable at all.
 *
 * The counts are asserted as relations, not as the numbers a run produced.
 * "One seed finds exactly half" follows from the two balls being mirror
 * images -- but it needs them to stay DISJOINT, which is a condition on the
 * fixture and not a free consequence of symmetry. Raise kRadius toward
 * field.centre and the balls merge into one component; a single seed then
 * reaches all of it, fromOne == exhaustive, and this case fails with the code
 * entirely correct. The invariant survives a change of grid, and a change of
 * radius only while 2*R stays clear of 2*centre. */
TEST(impcubevolume_crawl_finds_only_what_it_is_seeded_from)
{
    TwoSpheres field;
    field.r2 = float(kR2);
    field.centre = 2.0f;

    impCubeVolume volume;
    volume.function = twoSphereField;
    volume.contextInfoForFunction = &field;
    volume.init(kCubes * 2, kCubes, kCubes, kCubeWidth);
    volume.setSurfaceValue(kSurfaceValue);

    volume.makeSurface();
    const unsigned int exhaustive = volume.getSurface()->getVertexCount();
    CHECK(exhaustive > 0);

    impCrawlPointVector oneSeed;
    oneSeed.push_back(impCrawlPoint(field.centre, 0.0f, 0.0f));
    volume.makeSurface(oneSeed);
    const unsigned int fromOne = volume.getSurface()->getVertexCount();

    impCrawlPointVector bothSeeds;
    bothSeeds.push_back(impCrawlPoint(field.centre, 0.0f, 0.0f));
    bothSeeds.push_back(impCrawlPoint(-field.centre, 0.0f, 0.0f));
    volume.makeSurface(bothSeeds);
    const unsigned int fromBoth = volume.getSurface()->getVertexCount();

    impCrawlPointVector noSeeds;
    volume.makeSurface(noSeeds);
    const unsigned int fromNone = volume.getSurface()->getVertexCount();

    CHECK(fromOne * 2 == exhaustive);  /* one of two mirror-image components */
    CHECK(fromBoth == exhaustive);     /* both seeds reach everything */
    CHECK(fromNone == 0);              /* no seed reaches nothing */
}

/* Passing an eyepoint asks for back-to-front ordering so that transparency
 * composites correctly. That is a draw-order concern, so it must permute the
 * vertex array without changing what is in it.
 *
 * Both halves are asserted, and neither is redundant. Set equality alone would
 * pass if the sort quietly became a no-op -- transparency would break in the
 * renderer and nothing here would notice. Order-difference alone would pass if
 * the sort corrupted the geometry. Together they say "same vertices, different
 * order", which is the whole contract.
 *
 * Measured while writing this: exactly 1 of 294 vertices keeps its index, so
 * the permutation is near-total and the second assertion has real margin. An
 * earlier draft of this case asserted the arrays were element-wise identical
 * and failed immediately -- the assumption was wrong and the test caught it,
 * which is the only reason this comment can state the contract correctly. */
TEST(impcubevolume_sorting_permutes_the_vertices_without_changing_them)
{
    impCubeVolume volume;
    float r2;
    configureSphere(volume, r2);

    volume.makeSurface();
    const impSurface *surface = volume.getSurface();
    const unsigned int count = surface->getVertexCount();
    CHECK(count > 0);

    std::vector<Vertex> unsorted = collectVertices(surface);

    volume.makeSurface(0.0f, 0.0f, 10.0f);
    CHECK(surface->getVertexCount() == count);
    std::vector<Vertex> sorted = collectVertices(surface);

    /* Same set: sort both into a canonical order and compare exactly. These
     * are the same computed floats, so exact equality is correct here -- a
     * tolerance would let a genuinely moved vertex through. */
    std::vector<Vertex> a = unsorted;
    std::vector<Vertex> b = sorted;
    std::sort(a.begin(), a.end());
    std::sort(b.begin(), b.end());
    CHECK(a == b);

    /* Different order: the eyepoint sort must actually have done something. */
    unsigned int unmoved = 0;
    for (unsigned int i = 0; i < count; i++)
        if (unsorted[i] == sorted[i]) unmoved++;
    CHECK(unmoved < count / 2);
}

/* surfacevalue chooses which isosurface of the field to extract, so moving it
 * must move the radius by the amount the field's algebra says. With
 * f = 1 + R^2 - |p|^2, the surface at threshold s is |p|^2 = 1 + R^2 - s.
 *
 * This is what catches a setSurfaceValue that is stored but never reaches the
 * interpolation -- the vertices would keep landing on the original radius and
 * every other case in this file would still pass. */
TEST(impcubevolume_surface_value_selects_the_radius)
{
    impCubeVolume volume;
    float r2;
    configureSphere(volume, r2);

    const float shifted = 1.4f;              /* a smaller ball: 1 + 1 - 1.4 */
    const double expectedR2 = 1.0 + kR2 - double(shifted);
    volume.setSurfaceValue(shifted);
    volume.makeSurface();

    const impSurface *surface = volume.getSurface();
    CHECK(surface->getVertexCount() > 0);

    /* Same derivation, same bound -- only the target radius has moved. */
    for (unsigned int i = 0; i < surface->getVertexCount(); i++) {
        const double r2v = squaredRadius(surface->getVertex(i));
        CHECK(r2v <= expectedR2 + kFloatSlack);
        CHECK(r2v >= expectedR2 - kBound - kFloatSlack);
    }

    /* And it really is a different sphere, not the old one within tolerance. */
    CHECK(expectedR2 < kR2 - kBound);
}

/* The generation counter survives hostile storage (ss-ma1).
 *
 * impCubeVolume::frame is the counter the per-edge vertex cache compares
 * against, and init() zeroes every cubedata *_frame field to 0. The
 * constructor used not to initialise `frame` at all, so a storage slot holding
 * 0xFFFF wrapped to 0 on the first makeSurface and every edge reported a cache
 * hit before anything had been cached: addVertexToSurface took the early
 * return, pushed cubes[index].x_vertex_index, and never called addVertex. The
 * surface came back with a full index array over ZERO vertices.
 *
 * Those indices were all 0 rather than garbage -- cubedata is an aggregate
 * with no user-provided constructor, so cubes.resize() value-initialises it,
 * even across a clear() that leaves poisoned capacity behind. Index 0 is out
 * of range for an empty vertex array all the same. An earlier version of this
 * comment called them uninitialised, which was wrong, and the review that
 * caught it is also why the area case above range-checks before it
 * dereferences.
 *
 * Reproducing that needs the storage to be hostile on purpose. Placement-new
 * over a buffer of 0xFF makes the old failure deterministic instead of a
 * 1-in-65536 flake, and with the fix in place the whole case is ordinary
 * defined behaviour -- the constructor writes `frame` before anything reads
 * it.
 *
 * WHAT THIS CASE DOES AND DOES NOT PIN, because the kill-check moved under it.
 * It no longer discriminates the constructor's `frame = 0;` on its own:
 * removing that line alone leaves the suite green, because advanceFrame()
 * covers the same ground. 0xFFFF is the only dangerous starting value -- every
 * other one increments to something no cubedata counter holds -- and 0xFFFF
 * increments to 0, which is exactly the wrap advanceFrame() now handles by
 * re-zeroing and restarting at 1.
 *
 * So `frame = 0;` is belt-and-braces relative to the wrap handler, kept
 * because leaning on a wrap to double as construction-time initialisation is
 * a coupling nobody should have to notice. What this case still pins, and what
 * actually matters, is that construction over hostile storage yields a correct
 * surface: removing BOTH the constructor line and the wrap handling fails it.
 * Verified all three ways.
 *
 * This is the one case here that is not about geometry. It is here rather than
 * in test_impsurface.cpp because the counter belongs to impCubeVolume and the
 * damage shows up in what makeSurface emits. */
TEST(impcubevolume_survives_construction_over_poisoned_storage)
{
    alignas(impCubeVolume) static unsigned char storage[sizeof(impCubeVolume)];
    std::memset(storage, 0xFF, sizeof(storage));

    impCubeVolume *volume = new (storage) impCubeVolume();
    float r2;
    configureSphere(*volume, r2);
    volume->makeSurface();

    const impSurface *surface = volume->getSurface();
    const unsigned int count = surface->getVertexCount();

    /* The exact signature of the bug: indices emitted, vertices not. Asserting
     * both directions means neither a silent zero nor a silent index array can
     * pass. */
    CHECK(count > 0);
    CHECK(surface->getIndexCount() > 0);

    for (unsigned int i = 0; i < surface->getIndexCount(); i++) {
        if (surface->getIndex(i) >= count) {
            CHECK(surface->getIndex(i) < count);
            break;
        }
    }

    /* Geometry is still geometry, even here: a cache that mistakenly reported
     * hits would return in-range indices to vertices that were never placed. */
    for (unsigned int i = 0; i < count; i++) {
        const double r2v = squaredRadius(surface->getVertex(i));
        CHECK(r2v <= kR2 + kFloatSlack);
        CHECK(r2v >= kR2 - kBound - kFloatSlack);
    }

    volume->~impCubeVolume();
}

/* The generation counter survives its own wrap (ss-ma1, second half).
 *
 * Initialising `frame` fixes the first frame. It does not fix the 65536th.
 * `frame` is an unsigned short and init() zeroes every cubedata *_frame to 0,
 * so when the counter wraps back to 0 it collides with "not touched since
 * init" all over again -- once every 65536 calls, roughly every 18 minutes at
 * 60fps.
 *
 * A static field hides this completely, which is why the first attempt at this
 * case found nothing: the same edges are crossed every frame, so no cube the
 * crawl visits still carries 0. The collision needs the surface to reach a
 * cube for the FIRST time on the wrapping frame. So the volume runs 65535
 * times around a small sphere, and the sphere then grows on exactly the call
 * that wraps.
 *
 * Measured before the fix, and it is not a subtle corruption: the crawl seed
 * itself reads as already-done, crawl_nosort returns immediately, and the
 * surface comes back with ZERO vertices where it should have 294. One frame in
 * every 65536, the object disappears.
 *
 * The expected count comes from a freshly-constructed volume rather than a
 * literal, so this stays a relation between two runs of the same code rather
 * than a golden number. */
TEST(impcubevolume_survives_the_generation_counter_wrapping)
{
    const float smallR2 = 0.0625f;  /* R = 0.25 */
    float bigR2 = float(kR2);       /* R = 1.0, needs cubes the small one never touches */

    impCrawlPointVector seed;
    seed.push_back(impCrawlPoint(0.0f, 0.0f, 0.0f));

    /* What the big sphere looks like with no history behind it. */
    unsigned int expected;
    {
        impCubeVolume fresh;
        fresh.function = sphereField;
        fresh.contextInfoForFunction = &bigR2;
        fresh.init(kCubes, kCubes, kCubes, kCubeWidth);
        fresh.setSurfaceValue(kSurfaceValue);
        fresh.makeSurface(seed);
        expected = fresh.getSurface()->getVertexCount();
        CHECK(expected > 0);
    }

    float small = smallR2;
    impCubeVolume volume;
    volume.function = sphereField;
    volume.contextInfoForFunction = &small;
    volume.init(kCubes, kCubes, kCubes, kCubeWidth);
    volume.setSurfaceValue(kSurfaceValue);

    /* frame is 0 after construction and call k leaves it at k, so call 65536
     * is the one that wraps. Run 65535 first. */
    for (long i = 0; i < 65535; i++) volume.makeSurface(seed);

    volume.contextInfoForFunction = &bigR2;
    volume.makeSurface(seed);

    CHECK(volume.getSurface()->getVertexCount() == expected);
}

/* A field that never reaches the threshold has no isosurface, and the pipeline
 * must emit nothing rather than a degenerate something. This is also the only
 * case that reaches getVertexCount() == 0, which is why getVertex uses
 * data() -- indexing an empty vector to form an address is undefined even when
 * the address is never read. */
TEST(impcubevolume_a_field_below_the_threshold_emits_nothing)
{
    impCubeVolume volume;
    float r2;
    configureSphere(volume, r2);

    /* The field maxes out at 1 + R^2 at the origin; ask for more than that. */
    volume.setSurfaceValue(1.0f + float(kR2) + 1.0f);
    volume.makeSurface();

    CHECK(volume.getSurface()->getVertexCount() == 0);
    CHECK(volume.getSurface()->getIndexCount() == 0);
}
