/* Tests for Hyperspace/transform: the GL matrix stack and GLU maths, without GL.
 *
 * The contract is "does what the GL call it replaces does", so the assertions
 * are the GL-spec results: where a vector goes under a rotation, the order a
 * composition applies in, gluPerspective's entries. gluProject needs no GL
 * context, so hsProject is checked against the real one on the same inputs.
 */

#include "harness.h"

#include "Hyperspace/transform.h"

#include <OpenGL/glu.h>
#include <math.h>

namespace {
const double kTol = 1e-5;

/* Column-major m applied to (x, y, z, 1). */
void apply(const float m[16], float x, float y, float z, float out[3])
{
    for (int r = 0; r < 3; r++)
        out[r] = m[r] * x + m[4 + r] * y + m[8 + r] * z + m[12 + r];
}
}

TEST(transform_identity_is_identity)
{
    float m[16];
    for (int i = 0; i < 16; i++) m[i] = 7.0f;
    hsIdentity(m);
    for (int i = 0; i < 16; i++) CHECK(m[i] == (i % 5 == 0 ? 1.0f : 0.0f));
}

TEST(transform_rotate_turns_counterclockwise_about_the_axis)
{
    float m[16], p[3];
    hsIdentity(m);
    hsRotate(m, 90.0f, 0, 0, 1);            /* +x goes to +y, as glRotatef does */
    apply(m, 1, 0, 0, p);
    CHECK_NEAR(p[0], 0.0, kTol); CHECK_NEAR(p[1], 1.0, kTol); CHECK_NEAR(p[2], 0.0, kTol);

    hsIdentity(m);
    hsRotate(m, 90.0f, 0, 1, 0);            /* about +y: +z goes to +x */
    apply(m, 0, 0, 1, p);
    CHECK_NEAR(p[0], 1.0, kTol); CHECK_NEAR(p[1], 0.0, kTol); CHECK_NEAR(p[2], 0.0, kTol);
}

TEST(transform_rotate_normalizes_its_axis_and_ignores_a_zero_one)
{
    float a[16], b[16];
    hsIdentity(a); hsRotate(a, 33.0f, 0, 0, 1);
    hsIdentity(b); hsRotate(b, 33.0f, 0, 0, 5);
    for (int i = 0; i < 16; i++) CHECK_NEAR(a[i], b[i], kTol);

    hsIdentity(a); hsRotate(a, 33.0f, 0, 0, 0);
    for (int i = 0; i < 16; i++) CHECK(a[i] == (i % 5 == 0 ? 1.0f : 0.0f));
}

TEST(transform_calls_compose_like_the_gl_stack)
{
    /* glTranslatef then glRotatef: the rotation applies to the vertex first. */
    float m[16], p[3];
    hsIdentity(m);
    hsTranslate(m, 10, 0, 0);
    hsRotate(m, 90.0f, 0, 0, 1);
    apply(m, 1, 0, 0, p);
    CHECK_NEAR(p[0], 10.0, kTol); CHECK_NEAR(p[1], 1.0, kTol);

    hsIdentity(m);
    hsRotate(m, 90.0f, 0, 0, 1);
    hsTranslate(m, 10, 0, 0);
    apply(m, 1, 0, 0, p);
    CHECK_NEAR(p[0], 0.0, kTol); CHECK_NEAR(p[1], 11.0, kTol);
}

TEST(transform_translations_accumulate)
{
    float m[16], p[3];
    hsIdentity(m);
    hsTranslate(m, 1, 2, 3);
    hsTranslate(m, 10, 0, 0);
    apply(m, 0, 0, 0, p);
    CHECK_NEAR(p[0], 11.0, kTol); CHECK_NEAR(p[1], 2.0, kTol); CHECK_NEAR(p[2], 3.0, kTol);
    CHECK(m[15] == 1.0f);                   /* w stays 1: a translation is affine */
}

TEST(transform_scale_and_multiply_apply_on_the_right)
{
    float m[16], p[3];
    hsIdentity(m);
    hsTranslate(m, 0, 5, 0);
    hsScale(m, 2, 3, 4);
    apply(m, 1, 1, 1, p);
    CHECK_NEAR(p[0], 2.0, kTol); CHECK_NEAR(p[1], 8.0, kTol); CHECK_NEAR(p[2], 4.0, kTol);

    float by[16];
    hsIdentity(by); by[12] = 1; by[13] = 2; by[14] = 3;   /* a translation */
    hsIdentity(m); hsScale(m, 2, 2, 2);
    hsMultiply(m, by);                                     /* scale(translate(v)) */
    apply(m, 0, 0, 0, p);
    CHECK_NEAR(p[0], 2.0, kTol); CHECK_NEAR(p[1], 4.0, kTol); CHECK_NEAR(p[2], 6.0, kTol);
}

TEST(transform_perspective_matches_glu_formula)
{
    float m[16];
    hsPerspective(m, 90.0, 2.0, 1.0, 3.0);
    /* f = cot(45 deg) = 1 */
    CHECK_NEAR(m[0], 0.5, kTol);
    CHECK_NEAR(m[5], 1.0, kTol);
    CHECK_NEAR(m[10], -2.0, kTol);           /* -(far + near) / (far - near) */
    CHECK_NEAR(m[11], -1.0, kTol);
    CHECK_NEAR(m[14], -3.0, kTol);           /* -2 far near / (far - near) */
    CHECK(m[15] == 0.0f);
    CHECK(m[1] == 0.0f && m[4] == 0.0f && m[12] == 0.0f);
}

TEST(transform_perspective_leaves_identity_where_glu_returns_early)
{
    const double bad[][4] = {{60, 0, 0.1, 10},     /* aspect 0: a zero-width view */
                             {60, 1, 5, 5},        /* zNear == zFar */
                             {0, 1, 0.1, 10}};     /* no field of view */
    for (const auto &b : bad) {
        float m[16];
        for (int i = 0; i < 16; i++) m[i] = 9.0f;
        hsPerspective(m, b[0], b[1], b[2], b[3]);
        for (int i = 0; i < 16; i++) CHECK(m[i] == (i % 5 == 0 ? 1.0f : 0.0f));
    }
}

TEST(transform_perspective_is_stored_in_float)
{
    float m[16];
    /* At these planes double-then-round and float arithmetic give different floats
     * (-1.000100017 against -1.000099897), so only computing in double passes. */
    hsPerspective(m, 50.0, 16.0 / 9.0, 0.01, 200.0);
    double expected = -(200.0 + 0.01) / (200.0 - 0.01);
    CHECK(m[10] == (float)expected);         /* rounded once, the way GL's stack keeps it */
}

TEST(transform_rotation_inverse_undoes_the_rotation)
{
    float r[16], inv[16], p[3], q[3];
    hsIdentity(r);
    hsRotate(r, -20.0f, 0, 0, 1);
    hsRotate(r, 70.0f, 0, 1, 0);
    hsTranslate(r, 3, 4, 5);                 /* dropped by the inverse */
    hsRotationInverse(inv, r);
    apply(r, 0.2f, -0.5f, 0.9f, p);
    p[0] -= r[12]; p[1] -= r[13]; p[2] -= r[14];
    apply(inv, p[0], p[1], p[2], q);
    CHECK_NEAR(q[0], 0.2, kTol); CHECK_NEAR(q[1], -0.5, kTol); CHECK_NEAR(q[2], 0.9, kTol);
    CHECK(inv[12] == 0.0f && inv[13] == 0.0f && inv[14] == 0.0f && inv[15] == 1.0f);

    hsRotationInverse(r, r);                 /* in place */
    for (int i = 0; i < 16; i++) CHECK(r[i] == inv[i]);
}

TEST(transform_project_matches_gluProject)
{
    double model[16] = {0}, proj[16];
    float mf[16], pf[16];
    hsIdentity(mf);
    hsRotate(mf, 25.0f, 0, 1, 0);
    hsRotate(mf, -10.0f, 0, 0, 1);
    hsTranslate(mf, -1.5f, 0.25f, 4.0f);
    for (int i = 0; i < 16; i++) model[i] = mf[i];
    hsPerspective(pf, 50.0, 16.0 / 9.0, 0.001, 200.0);
    for (int i = 0; i < 16; i++) proj[i] = pf[i];
    const int viewport[4] = {0, 0, 1280, 720};
    const GLint glViewportArg[4] = {0, 0, 1280, 720};

    const double pts[][3] = {{0, 0, -5}, {1.2, -0.7, -3}, {-4, 2, -20}, {0.3, 0.1, 6}};
    for (const auto &p : pts) {
        double ours[3] = {0, 0, 0}, glu[3] = {0, 0, 0};
        bool ok = hsProject(p[0], p[1], p[2], model, proj, viewport, ours);
        GLint gluOk = gluProject(p[0], p[1], p[2], model, proj, glViewportArg, &glu[0], &glu[1], &glu[2]);
        CHECK(ok == (gluOk == GL_TRUE));
        for (int i = 0; i < 3; i++) CHECK_NEAR(ours[i], glu[i], 1e-9 * (1.0 + fabs(glu[i])));
    }
}

TEST(transform_project_refuses_w_zero_and_leaves_win_alone)
{
    double model[16] = {1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1}, proj[16];
    float pf[16];
    hsPerspective(pf, 60.0, 1.0, 0.1, 10.0);
    for (int i = 0; i < 16; i++) proj[i] = pf[i];
    const int viewport[4] = {0, 0, 100, 100};
    double win[3] = {-7, -7, -7};
    CHECK(!hsProject(1, 1, 0, model, proj, viewport, win));   /* eye z = 0, so w = 0 */
    CHECK(win[0] == -7 && win[1] == -7 && win[2] == -7);

    CHECK(hsProject(0, 0, -1, model, proj, viewport, win));   /* on the axis: centre */
    CHECK_NEAR(win[0], 50.0, kTol); CHECK_NEAR(win[1], 50.0, kTol);
}
