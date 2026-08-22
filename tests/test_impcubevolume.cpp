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
 * cube for the FIRST time on the wrapping frame. So the volume runs one full
 * period minus one around a small sphere, and the sphere then grows on exactly
 * the call that wraps.
 *
 * The period comes from impCubeVolume::framePeriod(), not from a literal.
 * advanceFrame() names widening the counters as a live alternative to
 * re-zeroing, and a case counting to a hard-coded 65535 would then never reach
 * a wrap: it would pass while exercising nothing, and the only symptom would be
 * a coverage drop somebody attributes to a regression. Deriving it means a
 * change to the counter's type changes this case with it.
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

    /* frame is 0 after construction and call k leaves it at k, so call
     * framePeriod() is the one that wraps. Run one short of it first. */
    const unsigned long period = impCubeVolume::framePeriod();

    /* If the counter is ever widened, driving it to its wrap stops being
     * feasible in a unit test -- and this case must SAY so rather than quietly
     * pass having tested nothing. Failing here is the signal to whoever
     * widened it that the wrap now needs a different kind of test. */
    CHECK(period <= 65536);
    if (period > 65536) return;

    for (unsigned long i = 0; i + 1 < period; i++) volume.makeSurface(seed);

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

/* ------------------------------------------------------------------------
 * The crawl overloads, part two (ss-c49, ss-qsv).
 *
 * Everything above drives makeSurface(), makeSurface(eye) and the simplest
 * path through makeSurface(cpv): one seed at the centre of a ball, on a field
 * whose surface is nowhere near the edge of the volume. That is one walk
 * through a function full of conditionals, and it left three of them almost
 * entirely unreached -- the four-argument makeSurface(eye, cpv) at 0 regions
 * covered, crawl_sort at 0, and every crawlfromsides branch in both crawl
 * overloads.
 *
 * The fixtures below are chosen to make each of those the only thing that can
 * explain the result:
 *
 *   - two balls straddling one axis, so a single seed distinguishes a crawl
 *     from an exhaustive scan and says WHICH component it reached;
 *   - a ball too big for its volume, so the surface cuts all six faces and
 *     crawling from the sides has something to find that no seed points to;
 *   - seeds outside the volume entirely, which is what ss-qsv is about.
 *
 * The assertions stay relational for the reason the header gives: a count
 * pins a run, a relation pins the behaviour.
 * ---------------------------------------------------------------------- */

namespace {

/* Set comparison over emitted vertices. Taken by value because both sides are
 * sorted into a canonical order first, and the caller's order usually still
 * matters to the case that is comparing them. */
bool sameVertexSet(std::vector<Vertex> a, std::vector<Vertex> b)
{
    std::sort(a.begin(), a.end());
    std::sort(b.begin(), b.end());
    return a == b;
}

/* One crawl, through whichever of the two crawl overloads a case is
 * exercising. They convert and clamp crawl points with identical code -- which
 * is the point: ss-qsv was a divergence between two copies of it, so a case
 * that drives only one of them pins only half the fix. The four-argument one
 * also sorts, which every assertion phrased as a set is indifferent to. */
void crawlWith(impCubeVolume &volume, impCrawlPointVector &cpv, bool withEyepoint)
{
    if (withEyepoint)
        volume.makeSurface(0.0f, 0.0f, 10.0f, cpv);
    else
        volume.makeSurface(cpv);
}

/* Two disjoint balls of radius kClampRadius at +-kClampCentre along one axis.
 *
 * The radius and the centre are not free. The volume spans [-4, 4] along the
 * tested axis, so cube 0 covers [-4, -3.75] and cube w-1 covers [3.75, 4]; a
 * ball at -3.0 with R = 0.9 reaches -3.9, so along the axis's centre line the
 * surface falls inside cube 0. That is what makes a seed clamped to the near
 * face land on a cube whose corner mask is mixed, so the crawl starts
 * immediately.
 *
 * The two ends being symmetric is deliberate too. When a seed lands inside
 * solid material the two overloads walk in opposite directions -- ++i in
 * makeSurface(cpv), --i in the four-argument one (ss-raf) -- so a fixture that
 * only straddled one end would exercise the walk in one of them and the crawl
 * in the other, and a failure would not say which. Here neither walks. */
struct AxisBalls {
    float r2;
    float centre;
    int axis;
};

float axisBallField(float *p, void *context)
{
    const AxisBalls *b = (const AxisBalls *)context;
    const float along = p[b->axis];
    const float o1 = p[(b->axis + 1) % 3];
    const float o2 = p[(b->axis + 2) % 3];
    const float dPos = along - b->centre;
    const float dNeg = along + b->centre;
    const float a = 1.0f + b->r2 - (dPos * dPos + o1 * o1 + o2 * o2);
    const float c = 1.0f + b->r2 - (dNeg * dNeg + o1 * o1 + o2 * o2);
    return a > c ? a : c;
}

const float kClampRadius = 0.9f;
const float kClampCentre = 3.0f;
const unsigned int kClampCubes = 32;  /* along the tested axis only: [-4, 4] */
const float kClampHalfExtent = 0.5f * float(kClampCubes) * kCubeWidth;

void configureAxisBalls(impCubeVolume &volume, AxisBalls &field, int axis)
{
    field.r2 = kClampRadius * kClampRadius;
    field.centre = kClampCentre;
    field.axis = axis;

    unsigned int dim[3] = {kCubes, kCubes, kCubes};
    dim[axis] = kClampCubes;

    volume.function = axisBallField;
    volume.contextInfoForFunction = &field;
    volume.init(dim[0], dim[1], dim[2], kCubeWidth);
    volume.setSurfaceValue(kSurfaceValue);
}

impCrawlPointVector seedOnAxis(int axis, float along)
{
    float p[3] = {0.0f, 0.0f, 0.0f};
    p[axis] = along;
    impCrawlPointVector cpv;
    cpv.push_back(impCrawlPoint(p[0], p[1], p[2]));
    return cpv;
}

/* ss-qsv, one axis at a time.
 *
 * makeSurface(cpv) converts a crawl point to a grid index and clamps it into
 * the volume. It declared those indices 'unsigned int' and then tested
 * 'if(i < 0)', which is not a branch an unsigned value can take: a crawl point
 * left of the volume produced a negative int, wrapped to a huge unsigned,
 * passed the 'i >= int(w)' test underneath and clamped to w-1. The seed
 * started on the face OPPOSITE the one it asked for.
 *
 * Two balls make that visible rather than merely absent. A seed off the -x end
 * must find the -x ball; under the defect it finds the +x one, so the case
 * fails by finding the wrong component and not by finding nothing -- which is
 * the difference between a test that says "the clamp is broken" and one that
 * says "something returned zero".
 *
 * The reference is another seed rather than a count: whatever the near ball
 * tessellates to, a point outside the volume and a point just inside it are
 * asking for the same cube and must get the same surface. */
void checkOutOfVolumeSeedsClampToTheNearFace(int axis, bool withEyepoint)
{
    impCubeVolume volume;
    AxisBalls field;
    configureAxisBalls(volume, field, axis);

    volume.makeSurface();
    const unsigned int exhaustive = volume.getSurface()->getVertexCount();
    CHECK(exhaustive > 0);

    /* Inside cube 0 along the tested axis. The seed itself is just INSIDE the
     * ball -- 0.875 from a centre at 3.0 with R = 0.9 -- and an earlier
     * version of this comment claimed the opposite. Where it sits relative to
     * the ball is not the property to preserve: what matters is that CUBE 0
     * straddles the surface, so a seed clamped to the near face lands on a
     * mixed corner mask and the crawl starts without walking. Shrinking
     * kClampRadius to "restore" the seed to the outside would move the surface
     * out of cube 0, make the mask 255, and fail this case with the production
     * code entirely correct. */
    impCrawlPointVector justInside =
        seedOnAxis(axis, -(kClampHalfExtent - 0.5f * kCubeWidth));
    crawlWith(volume, justInside, withEyepoint);
    const std::vector<Vertex> nearFromInside = collectVertices(volume.getSurface());

    /* Far enough out that the wrapped index is unmistakably huge, not merely
     * off by one. */
    impCrawlPointVector wellBeforeIt = seedOnAxis(axis, -10.0f * kClampHalfExtent);
    crawlWith(volume, wellBeforeIt, withEyepoint);
    const std::vector<Vertex> nearFromOutside = collectVertices(volume.getSurface());

    impCrawlPointVector wellPastIt = seedOnAxis(axis, 10.0f * kClampHalfExtent);
    crawlWith(volume, wellPastIt, withEyepoint);
    const std::vector<Vertex> farFromOutside = collectVertices(volume.getSurface());

    /* Each seed reaches one of two mirror-image components. */
    CHECK(nearFromInside.size() > 0);
    CHECK(nearFromInside.size() * 2 == exhaustive);
    CHECK(farFromOutside.size() * 2 == exhaustive);

    /* Clamping to the near face: outside and just-inside ask for the same
     * cube, so they must agree exactly. */
    CHECK(sameVertexSet(nearFromOutside, nearFromInside));

    /* And it is a real discrimination, not two seeds landing on one surface:
     * the far end is a different component. This is the assertion the
     * unsigned index fails. */
    CHECK(!sameVertexSet(farFromOutside, nearFromInside));
}

}  // namespace

TEST(impcubevolume_a_crawl_point_off_the_x_end_clamps_to_the_near_face)
{
    checkOutOfVolumeSeedsClampToTheNearFace(0, false);
}

TEST(impcubevolume_a_crawl_point_off_the_y_end_clamps_to_the_near_face)
{
    checkOutOfVolumeSeedsClampToTheNearFace(1, false);
}

TEST(impcubevolume_a_crawl_point_off_the_z_end_clamps_to_the_near_face)
{
    checkOutOfVolumeSeedsClampToTheNearFace(2, false);
}

/* The same three, through the overload that sorts.
 *
 * Not redundant, and not a copy for symmetry's sake. The four-argument
 * overload has its own copy of the conversion and all six clamps, and it is
 * the copy that was already right -- so these three cases are what makes
 * "the signed/unsigned mismatch is gone from BOTH overloads" a checked claim
 * rather than a read of the diff. Measured before they were written: all six
 * of its clamp branches were uncovered, because nothing in the suite had ever
 * handed it a seed outside the volume. */
TEST(impcubevolume_a_sorted_crawl_point_off_the_x_end_clamps_to_the_near_face)
{
    checkOutOfVolumeSeedsClampToTheNearFace(0, true);
}

TEST(impcubevolume_a_sorted_crawl_point_off_the_y_end_clamps_to_the_near_face)
{
    checkOutOfVolumeSeedsClampToTheNearFace(1, true);
}

TEST(impcubevolume_a_sorted_crawl_point_off_the_z_end_clamps_to_the_near_face)
{
    checkOutOfVolumeSeedsClampToTheNearFace(2, true);
}

/* A seed in empty space reaches nothing, and does not spoil a seed that does.
 *
 * makeSurface's crawl has two escapes side by side: mask == 255 means the seed
 * is outside the solid and there is nothing to walk towards, mask == 0 means
 * it is buried inside and the code steps to an adjacent cube and tries again.
 * Transposing them is a one-line mistake and the branch that says so was
 * unreached -- every seed in the suite until now was inside a ball.
 *
 * The second assertion is what makes this discriminating rather than
 * decorative: with the escapes swapped, the empty-space seed walks +x out of
 * the void, finds the ball, and returns a full surface where zero was
 * expected. */
TEST(impcubevolume_a_seed_in_empty_space_finds_nothing)
{
    impCubeVolume volume;
    float r2;
    configureSphere(volume, r2);

    for (int sorted = 0; sorted < 2; sorted++) {
        const bool withEyepoint = (sorted != 0);

        impCrawlPointVector centre;
        centre.push_back(impCrawlPoint(0.0f, 0.0f, 0.0f));
        crawlWith(volume, centre, withEyepoint);
        const std::vector<Vertex> fromCentre = collectVertices(volume.getSurface());
        CHECK(fromCentre.size() > 0);

        /* Inside the volume, well outside the R = 1 ball: every corner of this
         * cube is below the threshold, so the mask is 255. */
        impCrawlPointVector void_;
        void_.push_back(impCrawlPoint(-1.9f, 0.0f, 0.0f));
        crawlWith(volume, void_, withEyepoint);
        CHECK(volume.getSurface()->getVertexCount() == 0);

        impCrawlPointVector both;
        both.push_back(impCrawlPoint(-1.9f, 0.0f, 0.0f));
        both.push_back(impCrawlPoint(0.0f, 0.0f, 0.0f));
        crawlWith(volume, both, withEyepoint);
        CHECK(sameVertexSet(collectVertices(volume.getSurface()), fromCentre));
    }
}

/* Where the crawl starts inside a component does not change what it finds.
 *
 * The suite's only crawl seed until now was the exact centre of a ball, which
 * walks one fixed path out to the surface and then follows one fixed
 * traversal. Four seeds -- the centre and three points close under the surface
 * on different axes -- enter the traversal at four different cubes. A crawl
 * that has lost a direction, or whose done-marking depends on visit order,
 * gives four different answers; a correct one gives the same surface every
 * time, because the component is the component. */
TEST(impcubevolume_the_crawl_is_independent_of_where_in_the_component_it_starts)
{
    impCubeVolume volume;
    float r2;
    configureSphere(volume, r2);

    const float seeds[4][3] = {
        {0.0f, 0.0f, 0.0f},
        {0.9f, 0.0f, 0.0f},
        {0.0f, 0.9f, 0.0f},
        {0.0f, 0.0f, -0.9f},
    };

    std::vector<Vertex> reference;
    for (int s = 0; s < 4; s++) {
        impCrawlPointVector cpv;
        cpv.push_back(impCrawlPoint(seeds[s][0], seeds[s][1], seeds[s][2]));
        volume.makeSurface(cpv);
        const std::vector<Vertex> found = collectVertices(volume.getSurface());
        CHECK(found.size() > 0);
        if (s == 0)
            reference = found;
        else
            CHECK(sameVertexSet(found, reference));
    }
}

/* The four-argument overload is a crawl, not an exhaustive scan with a sort
 * bolted on.
 *
 * Exactly the claim the two-argument crawl case above makes, made again
 * against the overload that owns crawl_sort -- and it is not redundant,
 * because they are separate code with a separate traversal. Two disjoint balls
 * are the only configuration where the difference is observable at all: on one
 * connected surface a crawl and a scan agree exactly. The fixture's disjointness
 * is a condition on kRadius versus field.centre, as the two-argument case
 * explains at more length. */
TEST(impcubevolume_the_sorted_crawl_visits_only_the_component_it_is_seeded_from)
{
    TwoSpheres field;
    field.r2 = float(kR2);
    field.centre = 2.0f;

    impCubeVolume volume;
    volume.function = twoSphereField;
    volume.contextInfoForFunction = &field;
    volume.init(kCubes * 2, kCubes, kCubes, kCubeWidth);
    volume.setSurfaceValue(kSurfaceValue);

    volume.makeSurface(0.0f, 0.0f, 10.0f);
    const unsigned int exhaustive = volume.getSurface()->getVertexCount();
    CHECK(exhaustive > 0);

    impCrawlPointVector oneSeed;
    oneSeed.push_back(impCrawlPoint(field.centre, 0.0f, 0.0f));
    volume.makeSurface(0.0f, 0.0f, 10.0f, oneSeed);
    const unsigned int fromOne = volume.getSurface()->getVertexCount();

    impCrawlPointVector bothSeeds;
    bothSeeds.push_back(impCrawlPoint(field.centre, 0.0f, 0.0f));
    bothSeeds.push_back(impCrawlPoint(-field.centre, 0.0f, 0.0f));
    volume.makeSurface(0.0f, 0.0f, 10.0f, bothSeeds);
    const unsigned int fromBoth = volume.getSurface()->getVertexCount();

    impCrawlPointVector noSeeds;
    volume.makeSurface(0.0f, 0.0f, 10.0f, noSeeds);
    const unsigned int fromNone = volume.getSurface()->getVertexCount();

    CHECK(fromOne * 2 == exhaustive);
    CHECK(fromBoth == exhaustive);
    CHECK(fromNone == 0);
}

/* Adding an eyepoint to a crawl reorders it and changes nothing else.
 *
 * The same contract the exhaustive sort case states, for the other sorted
 * path. Both halves are needed for the same reason: set equality alone passes
 * a sort that quietly became a no-op, and a difference in order alone passes a
 * sort that corrupted the geometry.
 *
 * THE ORDER HALF COMPARES TWO EYEPOINTS, NOT SORTED AGAINST UNSORTED, and the
 * kill-check is why. An earlier draft compared makeSurface(cpv) with
 * makeSurface(eye, cpv) and asserted the arrays differed -- which they do even
 * with the sort deleted, because the two overloads step in opposite directions
 * when a seed lands inside solid material. makeSurface(cpv) walks ++i and
 * enters the traversal on the +x side of the ball; the four-argument overload
 * walks --i and enters on the -x side. So the emission orders differ for a
 * reason that has nothing to do with sorting, and commenting out
 * sortableCubes.sort() left that draft GREEN. The asymmetry between the two
 * overloads is ss-raf; this case only has to stop relying on it.
 *
 * Two eyepoints on opposite sides of the same surface, through the same
 * overload, leave the sort as the only thing that can separate them: delete it
 * and the two runs are identical.
 *
 * Measured: not one of the 294 vertices holds its index between the two
 * eyepoints, so the permutation is total and the margin below has room to
 * spare. */
TEST(impcubevolume_sorting_the_crawl_permutes_it_without_changing_it)
{
    impCubeVolume volume;
    float r2;
    configureSphere(volume, r2);

    impCrawlPointVector seed;
    seed.push_back(impCrawlPoint(0.0f, 0.0f, 0.0f));

    volume.makeSurface(seed);
    const std::vector<Vertex> unsorted = collectVertices(volume.getSurface());
    CHECK(unsorted.size() > 0);

    volume.makeSurface(0.0f, 0.0f, 10.0f, seed);
    const std::vector<Vertex> nearSide = collectVertices(volume.getSurface());

    volume.makeSurface(0.0f, 0.0f, -10.0f, seed);
    const std::vector<Vertex> farSide = collectVertices(volume.getSurface());

    /* Changes nothing: whichever way it is ordered, it is the same surface the
     * unsorted crawl produced. */
    CHECK(nearSide.size() == unsorted.size());
    CHECK(farSide.size() == unsorted.size());
    CHECK(sameVertexSet(nearSide, unsorted));
    CHECK(sameVertexSet(farSide, unsorted));

    /* Reorders it: and the eyepoint is what decides the order. */
    unsigned int unmoved = 0;
    for (unsigned int i = 0; i < nearSide.size() && i < farSide.size(); i++)
        if (nearSide[i] == farSide[i]) unmoved++;
    CHECK(unmoved < nearSide.size() / 2);
}

namespace {

/* Mean squared distance from an eyepoint over a contiguous slice of the
 * emitted vertices. Vertices are appended the first time an edge is crossed,
 * so their order IS the order the cubes were polygonized in, which is what the
 * sort rearranges. */
double meanDepth(const std::vector<Vertex> &v, size_t first, size_t last, const float *eye)
{
    double total = 0.0;
    for (size_t i = first; i < last; i++) {
        const double dx = double(v[i].data[3]) - eye[0];
        const double dy = double(v[i].data[4]) - eye[1];
        const double dz = double(v[i].data[5]) - eye[2];
        total += dx * dx + dy * dy + dz * dz;
    }
    return total / double(last - first);
}

}  // namespace

/* The eyepoint sort emits NEAR geometry first.
 *
 * Stated as a characterization and not as an endorsement. impCubeVolume.h says
 * an eyepoint means "you want to sort the surface so that transparent surfaces
 * will be drawn back-to-front", and back-to-front is far-first; sortableCube's
 * operator< compares depth and std::list::sort is ascending, so what the code
 * actually emits is near-first. Both sorted overloads agree with each other
 * and disagree with the header. That is ss-en3 and is deliberately not fixed
 * here -- a test wave is the wrong place to change what a renderer draws, and
 * pinning the current direction is what makes the fix visible when it comes.
 *
 * Asserted as a comparison between the two ends of the array and repeated with
 * the eyepoint on the far side, so it is the eyepoint that decides the order
 * and not something about the sphere. A quarter at each end rather than half
 * and half: the middle of a sorted sphere is where the depths bunch up, and
 * excluding it is what gives the margin below its room. */
TEST(impcubevolume_the_eyepoint_sort_emits_near_geometry_first)
{
    impCubeVolume volume;
    float r2;
    configureSphere(volume, r2);

    impCrawlPointVector seed;
    seed.push_back(impCrawlPoint(0.0f, 0.0f, 0.0f));

    const float eyes[2][3] = {{0.0f, 0.0f, 10.0f}, {0.0f, 0.0f, -10.0f}};

    for (int e = 0; e < 2; e++) {
        volume.makeSurface(eyes[e][0], eyes[e][1], eyes[e][2], seed);
        const std::vector<Vertex> v = collectVertices(volume.getSurface());
        CHECK(v.size() >= 8);
        const size_t quarter = v.size() / 4;

        const double near_ = meanDepth(v, 0, quarter, eyes[e]);
        const double far_ = meanDepth(v, v.size() - quarter, v.size(), eyes[e]);

        /* A 10% separation, against a measured 86.3 versus 115.7. Wide enough
         * that a different tessellation does not trip it, narrow enough that
         * an unsorted array -- where the two ends differ by a few percent at
         * most -- cannot pass. */
        CHECK(near_ * 1.1 < far_);
    }
}

namespace {

/* Six disjoint balls, one straddling the centre of each face of the volume.
 *
 * THE DISJOINTNESS IS THE WHOLE POINT, and the first version of these cases
 * did not have it. It used one ball too big for its volume -- R = 2.5 in a
 * volume spanning [-2, 2] -- whose isosurface cuts all six faces, and asserted
 * that crawling from the sides reached everything the exhaustive scan did.
 *
 * That assertion is satisfied by any side scan that finds ONE solid boundary
 * corner anywhere, because the surface is a single connected component and the
 * crawl spreads over all of it from wherever it starts. Measured: deleting the
 * bottom/top loop group and the back/front loop group outright -- four of the
 * six faces, two thirds of the code the case exists to characterize -- left
 * the suite GREEN. The review that caught it named the regression it would
 * miss: a port that keeps the left/right scan and drops the rest, so geometry
 * entering through the top or the back silently stops being drawn.
 *
 * Six separated components fix that by construction. Each face's scan is the
 * only thing that can reach its ball, so losing a loop group loses two whole
 * components and the set comparison says so.
 *
 * Geometry: R = 0.5 balls centred on the six face centres of a [-2, 2] volume.
 * Half of each ball is outside, so the surface inside the volume is a cap that
 * the boundary cuts -- which is what makes the corner at the face centre solid
 * and the scan able to see it. Nearest centres are 2*sqrt(2) apart against a
 * diameter of 1, so they are disjoint with room to spare. */
const float kFaceBallRadius = 0.5f;

/* Face centres, in the order -x, +x, -y, +y, -z, +z. kCubes * kCubeWidth / 2
 * is the half-extent, so each sits exactly on its face. */
const float kFaceBallCentres[6][3] = {
    {-2.0f, 0.0f, 0.0f}, {2.0f, 0.0f, 0.0f},
    {0.0f, -2.0f, 0.0f}, {0.0f, 2.0f, 0.0f},
    {0.0f, 0.0f, -2.0f}, {0.0f, 0.0f, 2.0f},
};

float faceBallField(float *p, void *context)
{
    const float r2 = *(const float *)context;
    float best = -1.0e30f;
    for (int b = 0; b < 6; b++) {
        const float dx = p[0] - kFaceBallCentres[b][0];
        const float dy = p[1] - kFaceBallCentres[b][1];
        const float dz = p[2] - kFaceBallCentres[b][2];
        const float v = 1.0f + r2 - (dx * dx + dy * dy + dz * dz);
        if (v > best) best = v;
    }
    return best;
}

void configureFaceBalls(impCubeVolume &volume, float &r2Storage)
{
    r2Storage = kFaceBallRadius * kFaceBallRadius;
    volume.function = faceBallField;
    volume.contextInfoForFunction = &r2Storage;
    volume.init(kCubes, kCubes, kCubes, kCubeWidth);
    volume.setSurfaceValue(kSurfaceValue);

    /* The half-extent the centres above assume. Asserted rather than derived
     * so that changing kCubes or kCubeWidth fails here, loudly, instead of
     * quietly moving the balls off their faces and leaving the side scans
     * with nothing to find. */
    CHECK(0.5f * float(kCubes) * kCubeWidth == 2.0f);
}

/* How many emitted vertices belong to each of the six balls. A vertex is
 * within h*sqrt(3)/2 of its cap, and the caps are 2*sqrt(2) apart, so nearest-
 * centre attribution is unambiguous -- but it is checked rather than assumed:
 * anything further than one ball diameter from every centre is counted as
 * stray, and the cases assert there are none. */
void countByFace(const std::vector<Vertex> &v, unsigned int perFace[6], unsigned int &stray)
{
    for (int b = 0; b < 6; b++) perFace[b] = 0;
    stray = 0;
    for (unsigned int i = 0; i < v.size(); i++) {
        int best = -1;
        double bestD2 = 4.0 * double(kFaceBallRadius) * kFaceBallRadius;
        for (int b = 0; b < 6; b++) {
            const double dx = double(v[i].data[3]) - kFaceBallCentres[b][0];
            const double dy = double(v[i].data[4]) - kFaceBallCentres[b][1];
            const double dz = double(v[i].data[5]) - kFaceBallCentres[b][2];
            const double d2 = dx * dx + dy * dy + dz * dz;
            if (d2 < bestD2) { bestD2 = d2; best = b; }
        }
        if (best < 0) stray++;
        else perFace[best]++;
    }
}

}  // namespace

/* Crawling from the sides finds surfaces no crawl point points to -- through
 * every one of the six faces.
 *
 * This is what setCrawlFromSides is for: geometry that enters the volume from
 * outside, where the saver has no seed to offer because it does not know where
 * the surface came in. Stated as a contrast, with the same field and the same
 * empty crawl point list throughout -- off finds nothing, on finds everything
 * the exhaustive scan does. Neither half means much alone: a count would pass
 * a crawlfromsides that had quietly become an exhaustive scan, and "off finds
 * nothing" is already known.
 *
 * The per-face assertion is what makes the set comparison worth making. See
 * the fixture comment: with one connected surface, set equality is satisfied
 * by a scan that finds a single boundary corner, and four of the six face
 * scans could be deleted unnoticed. Six disjoint balls turn "reached every
 * cube the scan reaches" back into a real claim, and counting per ball turns
 * a failure into a statement about WHICH face stopped being scanned.
 *
 * What this does NOT pin: how densely each face is sampled. The scans walk a
 * checkerboard of boundary corners, and a coarser stride that still lands
 * inside every cap passes here. Pinning the stride means sizing a cap to fall
 * between samples, which fixes the test to one particular scan pattern -- and
 * a port is entitled to choose a different one that still finds everything.
 * The loop groups are pinned; the stride within them is not. */
TEST(impcubevolume_crawling_from_the_sides_reaches_all_six_faces)
{
    impCubeVolume volume;
    float r2;
    configureFaceBalls(volume, r2);

    volume.makeSurface();
    const std::vector<Vertex> exhaustive = collectVertices(volume.getSurface());
    CHECK(exhaustive.size() > 0);

    /* The fixture is only a fixture if all six balls are actually there. */
    unsigned int expected[6], strayExpected;
    countByFace(exhaustive, expected, strayExpected);
    CHECK(strayExpected == 0);
    for (int b = 0; b < 6; b++) CHECK(expected[b] > 0);

    impCrawlPointVector noSeeds;

    for (int sorted = 0; sorted < 2; sorted++) {
        const bool withEyepoint = (sorted != 0);

        volume.setCrawlFromSides(false);
        crawlWith(volume, noSeeds, withEyepoint);
        CHECK(volume.getSurface()->getVertexCount() == 0);

        volume.setCrawlFromSides(true);
        crawlWith(volume, noSeeds, withEyepoint);
        const std::vector<Vertex> fromSides = collectVertices(volume.getSurface());

        CHECK(fromSides.size() == exhaustive.size());
        CHECK(sameVertexSet(fromSides, exhaustive));

        /* Every face, not just enough of them to reach the total. Each ball is
         * a separate component, so the only thing that can put its vertices
         * here is the scan of the face it sits on. */
        unsigned int found[6], stray;
        countByFace(fromSides, found, stray);
        CHECK(stray == 0);
        for (int b = 0; b < 6; b++) CHECK(found[b] == expected[b]);
    }
}
