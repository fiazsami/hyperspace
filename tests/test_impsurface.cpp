/* Tests that impSurface and impCubeVolume can be built with no GL context.
 *
 * This file exists to hold open a door rather than to characterize behaviour.
 * impSurface's constructor used to call glGenBuffers, which needs a context a
 * constructor has no way to require, so `new impSurface` exited 139 in any
 * test binary. impCubeVolume's constructor does `surface = new impSurface`, so
 * the whole marching-cubes pipeline -- the largest testable surface in this
 * submodule and the code the Metal port is about to rewrite -- inherited that
 * and sat in triage bucket B, unreachable. ss-aio deferred the two
 * glGenBuffers calls to the first draw(); these cases are what stops them
 * being moved back.
 *
 * They fail loudly if that happens: reverting the fix makes the constructor
 * segfault, which takes the binary down with exit 139 and no coverage report
 * at all. That is a blunter signal than a CHECK failure, but it is not a
 * silent one, and it is the only signal available -- the thing under test is
 * whether a constructor returns.
 *
 * What is deliberately NOT here:
 *
 *   impSurface's own mutators -- addVertex and addIndex. addTriStripLength was
 *   listed here too until ss-3c8, and no longer belongs: it is not deliberately
 *   untested, it is absent from the build. See below.
 *
 *   OVERTAKEN BY ss-or3 -- read the next paragraph before trusting this one.
 *   As written, the reason was that every byte they write goes into private
 *   members with no accessor and no observer short of draw(), which needs a
 *   context; a test calling them and asserting nothing would be one more
 *   undiscriminating path of the kind this project already has twenty of.
 *
 *   That is no longer true of two of the three. ss-or3 added const accessors
 *   to impSurface -- getVertexCount, getVertex, getIndexCount, getIndex --
 *   precisely so impCubeVolume's output could be asserted on, and addVertex
 *   and addIndex are now fully covered through them by
 *   test_impcubevolume.cpp. They are bucket A.
 *
 *   addTriStripLength is not covered and not uncovered, because it is no
 *   longer COMPILED. ss-3c8 found its declaration and definition guarded '#ifdef
 *   USE_TRIANGLE_STRIPS' while every call site uses '#if'; the macro is
 *   #defined as 0, so #ifdef was true and #if was false, and the function
 *   went into the binary with no caller anywhere. Both guards are '#if' now,
 *   so it is neither covered nor uncovered -- it is absent, and out of the
 *   coverage denominator entirely. Set USE_TRIANGLE_STRIPS to 1 and it comes
 *   back, compiled and measured, along with the paths that call it.
 *
 *   The geometry itself -- makeSurface, polygonize, crawl_sort and the rest.
 *   DONE, by ss-or3, in test_impcubevolume.cpp: an analytic sphere field, a
 *   tolerance derived from the interpolation error rather than measured, and
 *   assertions on manifold topology and triangulated area. What remains is
 *   the crawl-and-sort paths (ss-c49).
 *   This file only establishes that ss-or3 is now possible.
 *
 *   The trivial accessors (getSurface, setSurfaceValue and friends), which
 *   triage classifies C. They are exercised incidentally below where a case
 *   needs them to observe something; none is tested for its own sake.
 */

#include "harness.h"

#include <Implicit/impCubeVolume.h>
#include <Implicit/impSurface.h>

/* The bare fact ss-aio turned from false to true. Before the fix this line
 * did not return. */
TEST(impsurface_constructs_without_a_gl_context)
{
    impSurface *surface = new impSurface();
    CHECK(surface != 0);
    delete surface;
}

/* Stack construction as well as heap: the destructor runs here at scope exit
 * rather than on an explicit delete, and it is the destructor that holds the
 * other half of the fix -- it must not call glDeleteBuffers on a surface whose
 * buffer names were never generated. */
TEST(impsurface_destructs_without_a_gl_context)
{
    impSurface surface;
    CHECK(true);  /* reaching the closing brace is the assertion */
}

/* impCubeVolume was never the thing calling GL. It was blocked transitively,
 * through the impSurface its constructor allocates, which is why triage read
 * its functions as testable when they were not -- the classifier reads each
 * function's own source text and none of them names a GL call.
 *
 * getSurface() is the observation rather than the subject: a non-null surface
 * proves the constructor ran past `surface = new impSurface` to completion,
 * which a bare "it did not crash" would not distinguish from a constructor
 * that had stopped allocating one. */
TEST(impcubevolume_constructs_and_owns_a_surface)
{
    impCubeVolume volume;
    CHECK(volume.getSurface() != 0);
}

/* init() allocates the cube grid and builds the crawl tables, and at 10
 * uncovered regions it is the largest single function this fix unblocks.
 * Calling it here is not a characterization of what it computes -- that is
 * ss-or3 -- but it does prove the allocation path survives outside a
 * renderer, which is what ss-or3 will be standing on.
 *
 * The constructor already calls init(4, 4, 4, 0.2f), so this is a re-init on
 * a live object rather than a first one. The cube width differs from that
 * default deliberately: an init() that ignored its arguments and left the
 * constructor's grid in place would be indistinguishable from a working one
 * if the case passed 0.2f back in. */
TEST(impcubevolume_init_allocates_without_a_gl_context)
{
    impCubeVolume volume;
    volume.init(4, 4, 4, 0.25f);
    CHECK(volume.getSurface() != 0);
}

/* The surface value is the one piece of impCubeVolume's state that is both
 * settable and readable, so it is the only round-trip available to show the
 * object is functional after construction rather than merely allocated.
 * 0.42f is arbitrary, but it is specifically not the 0.5f the constructor
 * assigns: an accessor stubbed to return that default would otherwise pass.
 * Confirmed by mutation -- stubbing getSurfaceValue to 0.5f fails this case
 * and only this case. */
TEST(impcubevolume_state_survives_construction)
{
    impCubeVolume volume;
    volume.setSurfaceValue(0.42f);
    CHECK_NEAR(volume.getSurfaceValue(), 0.42f, 1e-6);
}
