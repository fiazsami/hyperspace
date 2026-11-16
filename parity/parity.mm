// GL -> Metal parity comparator for Hyperspace.
//
// Runs the unmodified OpenGL saver offscreen, deterministically, records every draw
// it makes, replays those draws through the Metal shaders in metal/, and compares
// the two images shot by shot. One pass is judged per run:
//
//   stars   goo and tunnels off: stars, lens flares (metal/FixedFunction.metal)
//   goo     goo on:   the GLSL goo program  (metal/Goo.metal)
//   tunnel  tunnel on: the GLSL tunnel program (metal/Tunnel.metal)
//   sun     the stars pass with the sun held in view (metal/FixedFunction.metal)
//
//   parity <pass> <metal-dir> <outdir> [shader=PATH] [inject=CASE] [frames=N] [every=N] [w=N] [h=N]
//
// shader= replaces the judged pass's shader file, and inject= adds one known fault
// to every shot; parity/killcheck.sh uses both to prove each rule rejects what it
// is for. Exit 0 = PASS, 1 = FAIL, 2 = harness or
// shader error. Each shot writes <outdir>/NNNNN_gl.png, _metal.png, _diffx8.png.
//
// renderer=metal instead draws the saver through HSRendererMetal, the Metal
// backend, and writes only <outdir>/NNNNN_backend.png; nothing is replayed or
// judged. `parity --compare-backend <pass> <gl-dir> <backend-dir>` then judges
// those against a plain run's _gl.png with the pass's rules
// (parity/backendcheck.sh does both). The two runs share the seed, so they
// draw the same frames. `parity --backend-textures <metal-dir>` uploads the
// same mip chains and cube faces through both backends and compares every
// level and face byte for byte, since no pass the backend draws samples them.
// `parity --backend-caustics <metal-dir>` makes the saver's caustic textures
// through both backends' offscreen targets and compares them, shot for shot.
//
// Nothing here is a golden image: GL and Metal render the same frame in the same
// process, so the reference is always the shipped renderer on this machine. The
// rules below were calibrated on one machine (Apple M5 Max, macOS 26); see
// parity/README.md for the measurements and for what a different GPU may need.

#import <Cocoa/Cocoa.h>
#import <OpenGL/gl.h>
#import <OpenGL/glext.h>
#import <OpenGL/glu.h>
#import <Metal/Metal.h>
#import <ImageIO/ImageIO.h>
#import <simd/simd.h>
#include <dlfcn.h>
#include <ctime>
#include <map>
#include <string>
#include <vector>
#include "Hyperspace.h"
#include "splinePath.h"
#include "starBurst.h"
#include "transform.h"
#include "rendererGL.h"
#include "causticTextures.h"
#include "rendererMetal.h"

extern GLhandleARB gooProgram, tunnelProgram;

// ---- determinism seams ----
//
// initSaver seeds with srand(time(NULL)). Defining time() in this executable binds
// that call here, so the seed is fixed without editing Hyperspace.
static time_t gSeed = 12345;
extern "C" time_t time(time_t *t) { if (t) *t = gSeed; return gSeed; }

// rand() is one generator for the whole process, and something else in it (the GL
// driver or a framework thread) advances it at timing-dependent moments: same-seed
// runs drifted apart without this. Hyperspace's calls bind to a private copy of
// macOS libc's own algorithm (Park-Miller, seed 0 -> 123459876), checked equal to
// libc rand() over 1.2M values from 6 seeds.
static uint32_t gRandState = 1;
extern "C" void srand(unsigned seed) { gRandState = seed; }
extern "C" int rand(void)
{
    long x = gRandState ? (long)gRandState : 123459876L;
    long hi = x / 127773, lo = x % 127773;
    x = 16807 * lo - 2836 * hi;
    if (x < 0) x += 0x7fffffff;
    gRandState = (uint32_t)x;
    return (int)(x % ((long)RAND_MAX + 1));
}

// ---- recorder ----
//
// The GL entry points Hyperspace draws with are defined here, record what they are
// given together with the GL state at that moment, and forward to the real ones via
// dlsym(RTLD_NEXT). Any draw this cannot record is counted, and a shot with an
// unrecorded draw fails: a replay that silently skipped geometry would compare
// against less than the saver drew.
//
// Interposing only catches the entry points named here, so two checks cover the
// rest. GL counts the primitives it generates in each shot, and the shot fails
// unless that equals the triangles recorded -- a draw through any other entry point
// (glDrawArrays, glCallLists, glVertex2f) shows up as a shortfall. And GL's current
// color and texcoord must equal the recorded ones after every recorded draw, which
// catches attributes set through an entry point not intercepted (glColor4ub).

enum class DrawKind { Immediate, Goo, Tunnel };

struct Vtx { simd_float3 p; simd_float2 uv; simd_float4 c; };   // metal/Interface.metal ImmediateVertex
struct State {
    simd_float4x4 mv, proj; simd_float4 color;
    bool texOn, fogOn, cullOn; GLint fogMode, cullFace; float fogStart, fogEnd; simd_float4 fogColor;
};
struct Batch {
    DrawKind kind; State st; GLuint tex = 0, tex1 = 0;
    std::vector<Vtx> tri;                                            // immediate and tunnel
    std::vector<float> gooVerts; std::vector<uint32_t> gooTri; GLuint cube[3] = {0, 0, 0};
};
// A list's vertices before its first glTexCoord take the texcoord current when it
// is called, not when it was compiled; callUV counts them.
struct ListOp {
    GLuint tex = 0; bool hasTex = false, unreplayable = false;
    bool uvSet = false; simd_float2 uv = {0, 0}; size_t callUV = 0;
    std::vector<std::vector<Vtx>> strips;
};

static bool gRecording = false;
static std::vector<Batch> gBatches;
static std::map<GLuint, ListOp> gLists;
static GLenum gMode = 0;
static std::vector<Vtx> gStrip;
static simd_float2 gUV = {0, 0};
static simd_float4 gColor = {1, 1, 1, 1};
static int gUnsupported = 0;

#define REAL(name, ret, args) static ret (*real_##name) args = (ret (*) args)dlsym(RTLD_NEXT, #name)
REAL(glBegin, void, (GLenum)); REAL(glEnd, void, (void));
REAL(glVertex3f, void, (GLfloat, GLfloat, GLfloat)); REAL(glVertex3fv, void, (const GLfloat *));
REAL(glTexCoord2f, void, (GLfloat, GLfloat)); REAL(glTexCoord2fv, void, (const GLfloat *));
REAL(glColor3f, void, (GLfloat, GLfloat, GLfloat)); REAL(glColor3fv, void, (const GLfloat *));
REAL(glColor4f, void, (GLfloat, GLfloat, GLfloat, GLfloat)); REAL(glColor4fv, void, (const GLfloat *));
REAL(glBindTexture, void, (GLenum, GLuint));
REAL(glNewList, void, (GLuint, GLenum)); REAL(glEndList, void, (void)); REAL(glCallList, void, (GLuint));
REAL(glMultiDrawElements, void, (GLenum, const GLsizei *, GLenum, const GLvoid *const *, GLsizei));
REAL(glDrawElements, void, (GLenum, GLsizei, GLenum, const GLvoid *));
REAL(glTexImage2D, void, (GLenum, GLint, GLint, GLsizei, GLsizei, GLint, GLenum, GLenum, const GLvoid *));
REAL(glTexSubImage2D, void, (GLenum, GLint, GLint, GLint, GLsizei, GLsizei, GLenum, GLenum, const GLvoid *));
REAL(glCopyTexImage2D, void, (GLenum, GLint, GLenum, GLint, GLint, GLsizei, GLsizei, GLint));
REAL(glCopyTexSubImage2D, void, (GLenum, GLint, GLint, GLint, GLint, GLint, GLsizei, GLsizei));
REAL(gluBuild2DMipmaps, GLint, (GLenum, GLint, GLsizei, GLsizei, GLenum, GLenum, const void *));
REAL(glTexParameteri, void, (GLenum, GLenum, GLint)); REAL(glTexParameterf, void, (GLenum, GLenum, GLfloat));
REAL(glTexParameteriv, void, (GLenum, GLenum, const GLint *)); REAL(glTexParameterfv, void, (GLenum, GLenum, const GLfloat *));
REAL(glDeleteTextures, void, (GLsizei, const GLuint *));

static simd_float4 currentColor() { float c[4]; glGetFloatv(GL_CURRENT_COLOR, c); return simd_make_float4(c[0], c[1], c[2], c[3]); }
static simd_float2 currentUV()   // unit 0's, which is the one glTexCoord2f sets
{
    GLint active; glGetIntegerv(GL_ACTIVE_TEXTURE, &active); glActiveTexture(GL_TEXTURE0);
    float t[4]; glGetFloatv(GL_CURRENT_TEXTURE_COORDS, t); glActiveTexture(active);
    return simd_make_float2(t[0], t[1]);
}
static simd_float4x4 getM(GLenum which) { float m[16]; glGetFloatv(which, m); simd_float4x4 r; memcpy(&r, m, sizeof m); return r; }
static State snap()
{
    State s; s.mv = getM(GL_MODELVIEW_MATRIX); s.proj = getM(GL_PROJECTION_MATRIX);
    float c[4]; glGetFloatv(GL_CURRENT_COLOR, c); s.color = simd_make_float4(c[0], c[1], c[2], c[3]);
    s.texOn = glIsEnabled(GL_TEXTURE_2D); s.fogOn = glIsEnabled(GL_FOG); s.cullOn = glIsEnabled(GL_CULL_FACE);
    glGetIntegerv(GL_FOG_MODE, &s.fogMode); glGetIntegerv(GL_CULL_FACE_MODE, &s.cullFace);
    glGetFloatv(GL_FOG_START, &s.fogStart); glGetFloatv(GL_FOG_END, &s.fogEnd);
    float fc[4]; glGetFloatv(GL_FOG_COLOR, fc); s.fogColor = simd_make_float4(fc[0], fc[1], fc[2], fc[3]);
    return s;
}
// The replay hard-wires what Hyperspace's draws use today: blend (SRC_ALPHA, ONE),
// GL_MODULATE, and for the fixed-function path no shader program, cube map or
// texture-coordinate generation. Anything else would be replayed wrongly, so it is
// counted as unrecorded instead of guessed at.
static bool blendSupported()
{
    GLint src, dst; glGetIntegerv(GL_BLEND_SRC, &src); glGetIntegerv(GL_BLEND_DST, &dst);
    return glIsEnabled(GL_BLEND) && src == GL_SRC_ALPHA && dst == GL_ONE;
}
static GLuint gCompiling = 0;   // the list being recorded, if GL_COMPILE
static bool gListOpen = false;  // any list open, in either mode
static bool gInBegin = false;
// While a GL_COMPILE_AND_EXECUTE list is open, every call is compiled as well as
// run -- including the binds and unit switches the recorder makes to inspect
// state -- so draws there are refused rather than recorded.
static bool executingList() { return gListOpen && !gCompiling; }
// One level-0 parameter of a texture, read without disturbing the binding. face is
// what to query: GL_TEXTURE_2D, or one face of a cube map.
static GLint level0(GLenum target, GLenum face, GLuint tex, GLenum pname)
{
    GLint saved, v = 0; glGetIntegerv(target == GL_TEXTURE_2D ? GL_TEXTURE_BINDING_2D : GL_TEXTURE_BINDING_CUBE_MAP, &saved);
    if ((GLuint)saved != tex) real_glBindTexture(target, tex);
    glGetTexLevelParameteriv(face, 0, pname, &v);
    if ((GLuint)saved != tex) real_glBindTexture(target, saved);
    return v;
}
// Texture name 0, or a name with no image, would be copied as a 0x0 Metal texture.
static bool hasImage2D(GLuint tex) { return tex && level0(GL_TEXTURE_2D, GL_TEXTURE_2D, tex, GL_TEXTURE_WIDTH) > 0; }
static bool hasImageCube(GLuint tex)
{
    if (!tex) return false;
    for (int f = 0; f < 6; f++) if (level0(GL_TEXTURE_CUBE_MAP, GL_TEXTURE_CUBE_MAP_POSITIVE_X + f, tex, GL_TEXTURE_WIDTH) <= 0) return false;
    return true;
}
static bool fixedFunctionSupported(GLuint boundTex)
{
    if (gListOpen) return false;   // the bind/restore below would be compiled into the open list
    if (!blendSupported() || glGetHandleARB(GL_PROGRAM_OBJECT_ARB)) return false;
    if (glIsEnabled(GL_TEXTURE_CUBE_MAP) || glIsEnabled(GL_TEXTURE_GEN_S) || glIsEnabled(GL_TEXTURE_GEN_T)) return false;
    if (!glIsEnabled(GL_TEXTURE_2D)) return true;
    GLint env; glGetTexEnviv(GL_TEXTURE_ENV, GL_TEXTURE_ENV_MODE, &env);
    if (env != GL_MODULATE) return false;
    // copy2D reads textures back with glGetTexImage(GL_RGBA), which reproduces only
    // RGB and RGBA. Measured on this driver: alpha-only reads back (0,0,0,A), and
    // luminance, luminance-alpha and intensity read back red-only, none of which
    // MODULATE would match.
    auto param = [&](GLenum pname) { return level0(GL_TEXTURE_2D, GL_TEXTURE_2D, boundTex, pname); };
    return param(GL_TEXTURE_RED_SIZE) && !param(GL_TEXTURE_LUMINANCE_SIZE) && !param(GL_TEXTURE_INTENSITY_SIZE);
}

// Odd triangles swap their first two vertices so every triangle keeps the strip's winding.
template <typename T> static void stripToTris(const std::vector<T> &s, std::vector<T> &out)
{
    for (size_t i = 2; i < s.size(); i++) {
        if (i % 2 == 0) { out.push_back(s[i - 2]); out.push_back(s[i - 1]); out.push_back(s[i]); }
        else            { out.push_back(s[i - 1]); out.push_back(s[i - 2]); out.push_back(s[i]); }
    }
}

// GL_COMPILE leaves GL's current color and texcoord alone, so while a list compiles
// they go to the list, not to gColor and gUV.
extern "C" void glBegin(GLenum mode)
{
    gMode = mode; gStrip.clear(); gInBegin = true;
    if (gCompiling) { if (mode != GL_TRIANGLE_STRIP) gLists[gCompiling].unreplayable = true; }
    else if (gRecording && executingList()) gUnsupported++;
    else if (gRecording) {
        if (mode != GL_TRIANGLE_STRIP) gUnsupported++;
        // Picks up anything that changed them outside glBegin/glEnd without passing
        // through here: glPopAttrib, a list, an entry point not intercepted.
        gColor = currentColor(); gUV = currentUV();
    }
    real_glBegin(mode);
}
static void setTexCoord(simd_float2 uv)
{
    if (gCompiling) { ListOp &l = gLists[gCompiling]; l.uv = uv; l.uvSet = true; }
    else gUV = uv;
}
// A list that sets its own color would be replayed with the call-time color instead.
static void setColor(simd_float4 c) { if (gCompiling) gLists[gCompiling].unreplayable = true; else gColor = c; }
static void vertex(simd_float3 p)
{
    if (!gCompiling) { gStrip.push_back({p, gUV, gColor}); return; }
    ListOp &l = gLists[gCompiling];
    if (!l.uvSet) l.callUV++;
    gStrip.push_back({p, l.uv, gColor});
}
extern "C" void glTexCoord2f(GLfloat s, GLfloat t) { setTexCoord(simd_make_float2(s, t)); real_glTexCoord2f(s, t); }
extern "C" void glTexCoord2fv(const GLfloat *t) { setTexCoord(simd_make_float2(t[0], t[1])); real_glTexCoord2fv(t); }
extern "C" void glColor3f(GLfloat r, GLfloat g, GLfloat b) { setColor(simd_make_float4(r, g, b, 1)); real_glColor3f(r, g, b); }
extern "C" void glColor3fv(const GLfloat *c) { setColor(simd_make_float4(c[0], c[1], c[2], 1)); real_glColor3fv(c); }
extern "C" void glColor4f(GLfloat r, GLfloat g, GLfloat b, GLfloat a) { setColor(simd_make_float4(r, g, b, a)); real_glColor4f(r, g, b, a); }
extern "C" void glColor4fv(const GLfloat *c) { setColor(simd_make_float4(c[0], c[1], c[2], c[3])); real_glColor4fv(c); }
extern "C" void glVertex3f(GLfloat x, GLfloat y, GLfloat z) { vertex(simd_make_float3(x, y, z)); real_glVertex3f(x, y, z); }
extern "C" void glVertex3fv(const GLfloat *v) { vertex(simd_make_float3(v[0], v[1], v[2])); real_glVertex3fv(v); }
extern "C" void glBindTexture(GLenum target, GLuint tex)
{
    if (gCompiling && target == GL_TEXTURE_2D) {
        ListOp &l = gLists[gCompiling];
        if (l.hasTex) l.unreplayable = true;   // one texture per batch in the replay
        l.tex = tex; l.hasTex = true;
    }
    real_glBindTexture(target, tex);
}
extern "C" void glEnd(void)
{
    real_glEnd();
    gInBegin = false;
    if (gCompiling) { gLists[gCompiling].strips.push_back(gStrip); return; }
    if (!gRecording || gMode != GL_TRIANGLE_STRIP || executingList()) return;   // the last was counted in glBegin
    // After glEnd GL's current values are the last vertex's; a mismatch means one was
    // set through an entry point not intercepted, so the recorded strip is wrong.
    if (!simd_equal(currentColor(), gColor) || !simd_equal(currentUV(), gUV)) { gUnsupported++; return; }
    Batch b; b.st = snap();
    GLhandleARB prog = glGetHandleARB(GL_PROGRAM_OBJECT_ARB);
    b.kind = prog == tunnelProgram && prog ? DrawKind::Tunnel : DrawKind::Immediate;
    GLint active, tex; glGetIntegerv(GL_ACTIVE_TEXTURE, &active);
    glActiveTexture(GL_TEXTURE0); glGetIntegerv(GL_TEXTURE_BINDING_2D, &tex); b.tex = (GLuint)tex;
    glActiveTexture(GL_TEXTURE1); glGetIntegerv(GL_TEXTURE_BINDING_2D, &tex); b.tex1 = (GLuint)tex;
    glActiveTexture(active);
    bool supported = b.kind == DrawKind::Tunnel ? blendSupported() && hasImage2D(b.tex) && hasImage2D(b.tex1)
                                                : fixedFunctionSupported(b.tex);
    if (!supported) { gUnsupported++; return; }
    stripToTris(gStrip, b.tri);
    gBatches.push_back(std::move(b));
}
// Display lists are recorded when compiled -- every strip in them -- and expanded
// when called with the current color. A list is refused if it sets its own
// color, binds more than one texture, draws anything but triangle strips, or calls
// another list (which GL resolves when it runs, not when it compiles). Other state
// a list changes (glEnable, glBlendFunc) is not intercepted and would go unnoticed;
// Hyperspace's lists change none.
extern "C" void glNewList(GLuint list, GLenum mode)
{
    // Compiling a name again replaces the list. GL_COMPILE_AND_EXECUTE is not
    // recorded, so a later call of that name is refused. A call GL refuses -- inside
    // another list, inside glBegin, list 0, an unknown mode -- opens nothing.
    if (gListOpen || gInBegin || !list || (mode != GL_COMPILE && mode != GL_COMPILE_AND_EXECUTE)) { real_glNewList(list, mode); return; }
    gListOpen = true;
    if (mode == GL_COMPILE) { gCompiling = list; gLists[list] = ListOp{}; }
    else gLists.erase(list);
    real_glNewList(list, mode);
}
extern "C" void glEndList(void) { gCompiling = 0; gListOpen = false; real_glEndList(); }
extern "C" void glCallList(GLuint list)
{
    if (gCompiling) gLists[gCompiling].unreplayable = true;
    auto it = gLists.find(list);
    if (!gRecording || gCompiling) { real_glCallList(list); return; }
    // Inside glBegin/glEnd GL allows the call but not the state queries below.
    if (it == gLists.end() || gInBegin || executingList()) { gUnsupported++; real_glCallList(list); return; }
    const ListOp &l = it->second;
    Batch b; b.kind = DrawKind::Immediate; b.st = snap();
    GLint cur; glGetIntegerv(GL_TEXTURE_BINDING_2D, &cur);
    b.tex = l.hasTex ? l.tex : (GLuint)cur;
    simd_float2 callUV = currentUV();
    bool supported = !l.unreplayable && fixedFunctionSupported(b.tex);
    real_glCallList(list);
    // GL's current values after the call are what the list left them at, which
    // shows whether it set any through an entry point not intercepted.
    if (!supported || !simd_equal(currentColor(), b.st.color) || !simd_equal(currentUV(), l.uvSet ? l.uv : callUV)) {
        gUnsupported++;
        return;
    }
    size_t n = 0;
    for (std::vector<Vtx> s : l.strips) {
        for (auto &v : s) { v.c = b.st.color; if (n++ < l.callUV) v.uv = callUV; }
        stripToTris(s, b.tri);
    }
    gBatches.push_back(std::move(b));
}
// impSurface builds with USE_TRIANGLE_STRIPS 0 and VBOs on, so goo arrives as one
// glDrawElements(GL_TRIANGLES, n, GL_UNSIGNED_INT, offset) per surface.
extern "C" void glMultiDrawElements(GLenum mode, const GLsizei *count, GLenum type, const GLvoid *const *offsets, GLsizei n)
{
    if (gCompiling) gLists[gCompiling].unreplayable = true;
    if (gRecording) gUnsupported++;
    real_glMultiDrawElements(mode, count, type, offsets, n);
}
extern "C" void glDrawElements(GLenum mode, GLsizei count, GLenum type, const GLvoid *idx)
{
    if (gCompiling) gLists[gCompiling].unreplayable = true;
    if (gRecording) {
        GLhandleARB prog = glGetHandleARB(GL_PROGRAM_OBJECT_ARB);
        GLint ab, eb; glGetIntegerv(GL_ARRAY_BUFFER_BINDING, &ab); glGetIntegerv(GL_ELEMENT_ARRAY_BUFFER_BINDING, &eb);
        if (prog != gooProgram || !prog || mode != GL_TRIANGLES || type != GL_UNSIGNED_INT || !ab || !eb || !blendSupported() || executingList())
            gUnsupported++;
        else if (count > 0) {
            Batch b; b.kind = DrawKind::Goo; b.st = snap();
            GLint asz; glGetBufferParameteriv(GL_ARRAY_BUFFER, GL_BUFFER_SIZE, &asz);
            b.gooVerts.resize(asz / sizeof(float));
            glGetBufferSubData(GL_ARRAY_BUFFER, 0, asz, b.gooVerts.data());
            b.gooTri.resize(count);
            glGetBufferSubData(GL_ELEMENT_ARRAY_BUFFER, (GLintptr)idx, count * sizeof(uint32_t), b.gooTri.data());
            GLint active; glGetIntegerv(GL_ACTIVE_TEXTURE, &active);
            bool bound = true;
            for (int u = 0; u < 3; u++) {
                glActiveTexture(GL_TEXTURE0 + u);
                GLint t; glGetIntegerv(GL_TEXTURE_BINDING_CUBE_MAP, &t); b.cube[u] = (GLuint)t;
                bound &= hasImageCube(b.cube[u]);
            }
            glActiveTexture(active);
            if (bound) gBatches.push_back(std::move(b));
            else gUnsupported++;
        }
    }
    real_glDrawElements(mode, count, type, idx);
}
// Textures and their sampler settings are copied after the frame, so a change to
// either during a shot frame would replay the final state for draws GL made with
// the earlier one. gluBuild2DMipmaps is caught here, at Hyperspace's call, because
// its own uploads bypass the rest. A change compiled into a list happens when the
// list runs, so the list is refused instead -- except for glDeleteTextures, which
// GL never compiles and always runs at once. Not intercepted: glGenerateMipmap,
// compressed, 1D and 3D uploads, gluBuild2DMipmapLevels -- Hyperspace uses none.
static void noteTextureChange(bool compilable)
{
    if (compilable && gCompiling) gLists[gCompiling].unreplayable = true;
    else if (gRecording) gUnsupported++;
}
extern "C" void glTexImage2D(GLenum t, GLint l, GLint ifmt, GLsizei w, GLsizei h, GLint b, GLenum f, GLenum ty, const GLvoid *px)
{ noteTextureChange(true); real_glTexImage2D(t, l, ifmt, w, h, b, f, ty, px); }
extern "C" void glTexSubImage2D(GLenum t, GLint l, GLint x, GLint y, GLsizei w, GLsizei h, GLenum f, GLenum ty, const GLvoid *px)
{ noteTextureChange(true); real_glTexSubImage2D(t, l, x, y, w, h, f, ty, px); }
extern "C" void glCopyTexImage2D(GLenum t, GLint l, GLenum ifmt, GLint x, GLint y, GLsizei w, GLsizei h, GLint b)
{ noteTextureChange(true); real_glCopyTexImage2D(t, l, ifmt, x, y, w, h, b); }
extern "C" void glCopyTexSubImage2D(GLenum t, GLint l, GLint xo, GLint yo, GLint x, GLint y, GLsizei w, GLsizei h)
{ noteTextureChange(true); real_glCopyTexSubImage2D(t, l, xo, yo, x, y, w, h); }
extern "C" GLint gluBuild2DMipmaps(GLenum t, GLint ifmt, GLsizei w, GLsizei h, GLenum f, GLenum ty, const void *px)
{ noteTextureChange(true); return real_gluBuild2DMipmaps(t, ifmt, w, h, f, ty, px); }
extern "C" void glTexParameteri(GLenum t, GLenum p, GLint v) { noteTextureChange(true); real_glTexParameteri(t, p, v); }
extern "C" void glTexParameterf(GLenum t, GLenum p, GLfloat v) { noteTextureChange(true); real_glTexParameterf(t, p, v); }
extern "C" void glTexParameteriv(GLenum t, GLenum p, const GLint *v) { noteTextureChange(true); real_glTexParameteriv(t, p, v); }
extern "C" void glTexParameterfv(GLenum t, GLenum p, const GLfloat *v) { noteTextureChange(true); real_glTexParameterfv(t, p, v); }
extern "C" void glDeleteTextures(GLsizei n, const GLuint *t) { noteTextureChange(false); real_glDeleteTextures(n, t); }

// ---- injected faults ----
//
// inject=<case> draws one more thing at the end of every shot frame, through the
// interposers above, so parity/killcheck.sh can show each recorder check failing on
// the shape it exists for. A case named *_ok draws something the recorder must
// replay correctly and still PASS; every other case must FAIL. The refused cases
// draw with alpha 0 or off screen, so only the recorder check -- not the image
// comparison -- can be what fails them.
static const char *const kInjectCases[] = {
    "strip_ok", "recompile_ok", "listcalluv_ok",
    "drawarrays", "colorub", "texcoordd", "listcolorub", "listquads", "nestedlist", "listinbegin",
    "compileexecute", "nestednewlist", "tunnelnotex", "goopartialcube", "texupload", "listupload", "texparam", "texdelete",
};
static GLuint gInjectTex = 0, gInjectCube = 0, gInjectList = 0, gInjectVBO[2] = {0, 0};
// A case that provokes a GL error on purpose takes it here, and only that error:
// any other, or none, is reported as the shot's GL error.
static GLenum gInjectGLError = GL_NO_ERROR;
static void expectGLError(GLenum want)
{
    GLenum e = glGetError();
    if (e != want && gInjectGLError == GL_NO_ERROR) gInjectGLError = e == GL_NO_ERROR ? 0xFFFF : e;
}
// Made before the first frame, because an upload during a shot frame is itself
// refused, and with every binding put back so the saver draws exactly as it would.
static void injectSetup(const char *which)
{
    GLint saved2D, savedCube, savedAB, savedEB;
    glGetIntegerv(GL_TEXTURE_BINDING_2D, &saved2D); glGetIntegerv(GL_TEXTURE_BINDING_CUBE_MAP, &savedCube);
    glGetIntegerv(GL_ARRAY_BUFFER_BINDING, &savedAB); glGetIntegerv(GL_ELEMENT_ARRAY_BUFFER_BINDING, &savedEB);
    uint8_t px[4 * 4 * 4];
    for (int i = 0; i < 16; i++) { px[i * 4] = (uint8_t)(i * 16); px[i * 4 + 1] = (uint8_t)(255 - i * 16); px[i * 4 + 2] = (uint8_t)((i * 97) & 255); px[i * 4 + 3] = 255; }
    glGenTextures(1, &gInjectTex); glBindTexture(GL_TEXTURE_2D, gInjectTex);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_NEAREST); glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GL_NEAREST);
    glTexImage2D(GL_TEXTURE_2D, 0, GL_RGBA8, 4, 4, 0, GL_RGBA, GL_UNSIGNED_BYTE, px);
    // A cube map with only its +X face: the goo check must look at all six.
    glGenTextures(1, &gInjectCube); glBindTexture(GL_TEXTURE_CUBE_MAP, gInjectCube);
    glTexParameteri(GL_TEXTURE_CUBE_MAP, GL_TEXTURE_MIN_FILTER, GL_NEAREST);
    glTexImage2D(GL_TEXTURE_CUBE_MAP_POSITIVE_X, 0, GL_RGBA8, 4, 4, 0, GL_RGBA, GL_UNSIGNED_BYTE, px);
    // One off-screen goo triangle, laid out as impSurface's VBOs are: normal, then position.
    static const float verts[] = {0, 0, 1, 5, 5, 0,  0, 0, 1, 6, 5, 0,  0, 0, 1, 5, 6, 0};
    static const uint32_t idx[] = {0, 1, 2};
    glGenBuffers(2, gInjectVBO);
    glBindBuffer(GL_ARRAY_BUFFER, gInjectVBO[0]); glBufferData(GL_ARRAY_BUFFER, sizeof verts, verts, GL_STATIC_DRAW);
    glBindBuffer(GL_ELEMENT_ARRAY_BUFFER, gInjectVBO[1]); glBufferData(GL_ELEMENT_ARRAY_BUFFER, sizeof idx, idx, GL_STATIC_DRAW);
    gInjectList = glGenLists(2);
    // Compiled here, outside any shot frame, so the upload inside it is seen only
    // when the list runs.
    if (!strcmp(which, "listupload")) {
        static const uint8_t zeros[4 * 4 * 4] = {0};
        glNewList(gInjectList, GL_COMPILE);
        glBindTexture(GL_TEXTURE_2D, gInjectTex); glTexSubImage2D(GL_TEXTURE_2D, 0, 0, 0, 4, 4, GL_RGBA, GL_UNSIGNED_BYTE, zeros);
        glEndList();
    }
    glBindTexture(GL_TEXTURE_2D, saved2D); glBindTexture(GL_TEXTURE_CUBE_MAP, savedCube);
    glBindBuffer(GL_ARRAY_BUFFER, savedAB); glBindBuffer(GL_ELEMENT_ARRAY_BUFFER, savedEB);
}
static void quad(float x0, float x1) { glVertex3f(x0, -0.5f, 0); glVertex3f(x1, -0.5f, 0); glVertex3f(x0, 0.5f, 0); glVertex3f(x1, 0.5f, 0); }
static void injectFault(const char *which)
{
    const GLuint tex = gInjectTex, list = gInjectList;
    GLint savedAB, savedEB; glGetIntegerv(GL_ARRAY_BUFFER_BINDING, &savedAB); glGetIntegerv(GL_ELEMENT_ARRAY_BUFFER_BINDING, &savedEB);
    GLhandleARB prog = glGetHandleARB(GL_PROGRAM_OBJECT_ARB);
    GLint active; glGetIntegerv(GL_ACTIVE_TEXTURE, &active);
    glPushAttrib(GL_ALL_ATTRIB_BITS); glPushClientAttrib(GL_CLIENT_ALL_ATTRIB_BITS);
    glUseProgramObjectARB(0); glActiveTexture(GL_TEXTURE0);
    glDisable(GL_FOG); glDisable(GL_CULL_FACE); glDisable(GL_TEXTURE_2D); glDisable(GL_TEXTURE_CUBE_MAP);
    glDisable(GL_TEXTURE_GEN_S); glDisable(GL_TEXTURE_GEN_T);
    glEnable(GL_BLEND); glBlendFunc(GL_SRC_ALPHA, GL_ONE); glTexEnvi(GL_TEXTURE_ENV, GL_TEXTURE_ENV_MODE, GL_MODULATE);
    glMatrixMode(GL_PROJECTION); glPushMatrix(); glLoadIdentity();
    glMatrixMode(GL_MODELVIEW); glPushMatrix(); glLoadIdentity();

    std::string c = which;
    if (c == "strip_ok") {
        glColor4f(0.5f, 0.3f, 0.2f, 1); glBegin(GL_TRIANGLE_STRIP); quad(-0.5f, 0.5f); glEnd();
    } else if (c == "recompile_ok") {   // only the second compile may be drawn
        glNewList(list, GL_COMPILE); glBegin(GL_TRIANGLE_STRIP); quad(-0.9f, -0.1f); glEnd(); glEndList();
        glNewList(list, GL_COMPILE); glBegin(GL_TRIANGLE_STRIP); quad(0.1f, 0.9f); glEnd(); glEndList();
        glColor4f(0.5f, 0.3f, 0.2f, 1); glCallList(list);
    } else if (c == "listcalluv_ok") {  // the first two vertices take the call-time texcoord
        glBindTexture(GL_TEXTURE_2D, tex); glEnable(GL_TEXTURE_2D);
        glTexCoord2f(0.1f, 0.1f);
        glNewList(list, GL_COMPILE); glBegin(GL_TRIANGLE_STRIP);
        glVertex3f(-0.5f, -0.5f, 0); glVertex3f(0.5f, -0.5f, 0);
        glTexCoord2f(0.9f, 0.9f); glVertex3f(-0.5f, 0.5f, 0); glVertex3f(0.5f, 0.5f, 0);
        glEnd(); glEndList();
        glColor4f(1, 1, 1, 1); glTexCoord2f(0.6f, 0.4f); glCallList(list);
    } else if (c == "drawarrays") {     // off screen: only the primitive count sees it
        static const float tri[] = {5, 5, 0, 6, 5, 0, 5, 6, 0};
        glEnableClientState(GL_VERTEX_ARRAY); glVertexPointer(3, GL_FLOAT, 0, tri); glDrawArrays(GL_TRIANGLES, 0, 3);
    } else if (c == "colorub") {
        glBegin(GL_TRIANGLE_STRIP); glColor4f(1, 1, 1, 0);
        glVertex3f(-0.5f, -0.5f, 0); glVertex3f(0.5f, -0.5f, 0); glVertex3f(-0.5f, 0.5f, 0);
        glColor4ub(255, 0, 0, 0); glVertex3f(0.5f, 0.5f, 0); glEnd();
    } else if (c == "texcoordd") {
        glColor4f(1, 1, 1, 0); glBegin(GL_TRIANGLE_STRIP); glTexCoord2f(0, 0);
        glVertex3f(-0.5f, -0.5f, 0); glVertex3f(0.5f, -0.5f, 0); glVertex3f(-0.5f, 0.5f, 0);
        glTexCoord2d(0.5, 0.5); glVertex3f(0.5f, 0.5f, 0); glEnd();
    } else if (c == "listcolorub") {
        glNewList(list, GL_COMPILE); glColor4ub(255, 0, 0, 0); glBegin(GL_TRIANGLE_STRIP); quad(-0.5f, 0.5f); glEnd(); glEndList();
        glColor4f(1, 1, 1, 0); glCallList(list);
    } else if (c == "listquads") {
        glNewList(list, GL_COMPILE); glBegin(GL_QUADS); glVertex3f(-0.5f, -0.5f, 0); glVertex3f(0.5f, -0.5f, 0);
        glVertex3f(0.5f, 0.5f, 0); glVertex3f(-0.5f, 0.5f, 0); glEnd(); glEndList();
        glColor4f(1, 1, 1, 0); glCallList(list);
    } else if (c == "nestedlist") {
        glNewList(list + 1, GL_COMPILE); glBegin(GL_TRIANGLE_STRIP); quad(-0.5f, 0.5f); glEnd(); glEndList();
        glNewList(list, GL_COMPILE); glCallList(list + 1); glEndList();
        glColor4f(1, 1, 1, 0); glCallList(list);
    } else if (c == "compileexecute") {   // drawn now, but compiled as well
        glNewList(list, GL_COMPILE_AND_EXECUTE);
        glColor4f(1, 1, 1, 0); glBegin(GL_TRIANGLE_STRIP); quad(-0.5f, 0.5f); glEnd();
        glEndList();
    } else if (c == "nestednewlist") {
        // GL refuses the inner glNewList, so list + 1 never exists; calling it must
        // not replay a list the recorder believed it was compiling.
        glNewList(list, GL_COMPILE_AND_EXECUTE);
        glNewList(list + 1, GL_COMPILE); expectGLError(GL_INVALID_OPERATION);
        glEndList();
        glCallList(list + 1);
    } else if (c == "listinbegin") {
        // GL allows a list call there but no state query, so the recorder must
        // refuse before querying; a query would raise a GL error. The list is
        // empty, so the primitive count cannot be what fails it.
        glNewList(list, GL_COMPILE); glEndList();
        glColor4f(1, 1, 1, 0); glBegin(GL_TRIANGLE_STRIP);
        glVertex3f(-0.5f, -0.5f, 0); glVertex3f(0.5f, -0.5f, 0); glVertex3f(-0.5f, 0.5f, 0);
        glCallList(list); glEnd();
    } else if (c == "goopartialcube") {   // off screen, through the goo program
        glUseProgramObjectARB(gooProgram);   // main refuses to run this case without one
        for (int u = 0; u < 3; u++) { glActiveTexture(GL_TEXTURE0 + u); glBindTexture(GL_TEXTURE_CUBE_MAP, gInjectCube); }
        glActiveTexture(GL_TEXTURE0);
        glBindBuffer(GL_ARRAY_BUFFER, gInjectVBO[0]); glBindBuffer(GL_ELEMENT_ARRAY_BUFFER, gInjectVBO[1]);
        glEnableClientState(GL_VERTEX_ARRAY); glEnableClientState(GL_NORMAL_ARRAY);
        glNormalPointer(GL_FLOAT, 6 * sizeof(float), (const GLvoid *)0);
        glVertexPointer(3, GL_FLOAT, 6 * sizeof(float), (const GLvoid *)(3 * sizeof(float)));
        glDrawElements(GL_TRIANGLES, 3, GL_UNSIGNED_INT, (const GLvoid *)0);
    } else if (c == "texupload") {     // any upload during a shot frame is refused, used or not
        static const uint8_t zeros[4 * 4 * 4] = {0};
        glBindTexture(GL_TEXTURE_2D, tex);
        glTexSubImage2D(GL_TEXTURE_2D, 0, 0, 0, 4, 4, GL_RGBA, GL_UNSIGNED_BYTE, zeros);
    } else if (c == "listupload") {    // compiled in injectSetup; the upload runs now
        glColor4f(1, 1, 1, 0); glCallList(list);
    } else if (c == "texparam") {      // a sampler change; copies are taken after the frame
        GLint nearest = GL_NEAREST;
        glBindTexture(GL_TEXTURE_2D, tex); glTexParameteriv(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, &nearest);
    } else if (c == "texdelete") {     // runs at once even while a list compiles
        GLuint t; glGenTextures(1, &t);
        glNewList(list, GL_COMPILE); glDeleteTextures(1, &t); glEndList();
    } else if (c == "tunnelnotex") {    // the tunnel program with nothing bound on unit 1
        glUseProgramObjectARB(tunnelProgram);
        glActiveTexture(GL_TEXTURE1); glBindTexture(GL_TEXTURE_2D, 0); glActiveTexture(GL_TEXTURE0); glBindTexture(GL_TEXTURE_2D, tex);
        glBegin(GL_TRIANGLE_STRIP); quad(5, 6); glEnd();
    }

    glMatrixMode(GL_PROJECTION); glPopMatrix(); glMatrixMode(GL_MODELVIEW); glPopMatrix();
    glBindBuffer(GL_ARRAY_BUFFER, savedAB); glBindBuffer(GL_ELEMENT_ARRAY_BUFFER, savedEB);
    glPopClientAttrib(); glPopAttrib();
    glUseProgramObjectARB(prog); glActiveTexture(active);
}

// ---- passes and their rules ----
//
// A shot passes when, over pixels lit (any channel > 8) in either image: the share
// more than 2 levels off is <= max2 %, the share more than 8 off is <= max8 %, and
// the signed mean difference (Metal - GL, worst channel) is <= maxBias levels.
// The goo and tunnel GLSL passes leave a symmetric residual on silhouettes and on
// minified texture that nine tested causes did not explain; signed bias is what
// separates a faithful translation from a wrong one there. Every limit was fixed
// from faithful-vs-defect measurements before any candidate shader was scored, and
// parity/killcheck.sh re-proves the separation. Measurements: parity/README.md.

struct Pass {
    const char *name, *file, *vfn, *ffn;
    bool goo, tunnels; int frames, every;
    double max2, max8, maxBias;
    int burstAt;   // frame at which to set off the starburst; 0 leaves it to the saver's timer
    float sunAhead;   // distance ahead of the camera to hold the sun at; 0 leaves it where the saver puts it
};
static const Pass kPasses[] = {
    // 60 s; stars are tiny, so the lit-pixel normalization matters most here.
    {"stars",  "FixedFunction.metal", "ff_vertex",     "ff_fragment",     false, false, 3600, 300, 1.0, 0.1, 0.06, 0},
    // 60 s; faithful worst 5.28% / 1.35% / bias 0.012, weakest defect bias 0.357.
    {"goo",    "Goo.metal",           "goo_vertex",    "goo_fragment",    true,  false, 3600, 300, 8.0, 2.5, 0.06, 0},
    // 2 min: one minute rarely puts the camera inside a tunnel. Faithful worst
    // 1.50% / 0.28% / 0.012; weakest defects 4.81% / bias 0.197 and 3.92% / 0.220.
    {"tunnel", "Tunnel.metal",        "tunnel_vertex", "tunnel_fragment", false, true,  7200, 200, 3.0, 0.6, 0.06, 0},
    // 8 s with a starburst set off at 1 s; the saver's own timer would wait five
    // minutes. Goo is on, as the saver's default is, because the sphere shares
    // the goo's program and textures. The sphere is refused (a display list drawn
    // with the goo program), so every shot until it is gone (about frame 420)
    // FAILs; later shots judge the goo with the goo pass's shader and limits.
    // The pass is there for seamcheck.sh, which compares GL with GL and ignores
    // that verdict.
    {"burst",  "Goo.metal",           "goo_vertex",    "goo_fragment",    true,  false, 480,  30,  8.0, 2.5, 0.06, 60},
    // 20 s of the stars pass with the sun held 12 units ahead of the camera. Where
    // the saver puts it, at (0, 2, 0), no stars-pass shot has it in frame: the path
    // leaves it behind or off to the side at every one. 12 is past the fog's end
    // (depth, 9.8 by default), as the saver's sun usually is, so a sun drawn with
    // fog on comes out black. The stars pass's shader and limits. Its lens flare
    // stays at (0, 2, 0): drawn on the sun, its core hides it.
    {"sun",    "FixedFunction.metal", "ff_vertex",     "ff_fragment",     false, false, 1200, 100, 1.0, 0.1, 0.06, 0, 12.0f},
};

// ---- Metal ----
// C++ mirrors of metal/Interface.metal.
struct FFU { simd_float4x4 mvp, mv; simd_float4 fogColor; float fogStart, fogEnd; int fogOn, texOn; };
struct GooU { simd_float4x4 mvp, modelview; simd_float4 color, fogColor; float fogEnd, fogScale; simd_float4x4 projection; };
struct TunnelU { simd_float4x4 mvp, modelview, projection; simd_float4 fogColor; float fogEnd, fogScale; };

static void writePNG(NSString *path, const uint8_t *rgba, int w, int h)
{
    CGColorSpaceRef cs = CGColorSpaceCreateDeviceRGB();
    CGContextRef bc = CGBitmapContextCreate((void *)rgba, w, h, 8, (size_t)w * 4, cs, (CGBitmapInfo)kCGImageAlphaNoneSkipLast);
    CGImageRef img = CGBitmapContextCreateImage(bc);
    CGImageDestinationRef dst = CGImageDestinationCreateWithURL((__bridge CFURLRef)[NSURL fileURLWithPath:path], CFSTR("public.png"), 1, NULL);
    CGImageDestinationAddImage(dst, img, NULL); CGImageDestinationFinalize(dst);
    CFRelease(dst); CGImageRelease(img); CGContextRelease(bc); CGColorSpaceRelease(cs);
}

static MTLSamplerMinMagFilter mmf(GLint f) { return (f == GL_NEAREST || f == GL_NEAREST_MIPMAP_NEAREST || f == GL_NEAREST_MIPMAP_LINEAR) ? MTLSamplerMinMagFilterNearest : MTLSamplerMinMagFilterLinear; }
static MTLSamplerMipFilter mipf(GLint f)
{
    if (f == GL_NEAREST || f == GL_LINEAR) return MTLSamplerMipFilterNotMipmapped;
    return (f == GL_LINEAR_MIPMAP_LINEAR || f == GL_NEAREST_MIPMAP_LINEAR) ? MTLSamplerMipFilterLinear : MTLSamplerMipFilterNearest;
}
static MTLSamplerAddressMode addr(GLint m) { return m == GL_REPEAT ? MTLSamplerAddressModeRepeat : MTLSamplerAddressModeClampToEdge; }

static std::vector<uint8_t> readPNG(NSString *path, int &w, int &h)
{
    std::vector<uint8_t> px;
    CGImageSourceRef src = CGImageSourceCreateWithURL((__bridge CFURLRef)[NSURL fileURLWithPath:path], NULL);
    CGImageRef img = src ? CGImageSourceCreateImageAtIndex(src, 0, NULL) : NULL;
    if (img) {
        w = (int)CGImageGetWidth(img); h = (int)CGImageGetHeight(img);
        px.resize((size_t)w * h * 4);
        CGColorSpaceRef cs = CGColorSpaceCreateDeviceRGB();
        CGContextRef bc = CGBitmapContextCreate(px.data(), w, h, 8, (size_t)w * 4, cs, (CGBitmapInfo)kCGImageAlphaNoneSkipLast);
        CGContextDrawImage(bc, CGRectMake(0, 0, w, h), img);
        CGContextRelease(bc); CGColorSpaceRelease(cs); CGImageRelease(img);
    }
    if (src) CFRelease(src);
    return px;
}

// parity --compare <ref-dir> <new-dir>: the GL images of two runs of the same pass,
// shot by shot (parity/seamcheck.sh). Both sides are the GL renderer, so nothing
// here is a translation residual: the rule is the tightest any pass uses.
// parity --compare-backend compares one run's GL images with another's
// _backend.png (renderer=metal), under the pass's rules. Either way a shot
// missing from either side is an error.
static int compareRuns(NSString *refDir, NSString *newDir, NSString *newSuffix,
                       double max2, double max8, double maxBias, const char *same, const char *different)
{
    auto shots = [](NSString *dir, NSString *suffix) -> NSArray<NSString *> * {
        NSArray<NSString *> *all = [[NSFileManager defaultManager] contentsOfDirectoryAtPath:dir error:nil];
        if (!all) { printf("ERROR cannot read %s\n", dir.UTF8String); return nil; }
        NSArray<NSString *> *found = [all filteredArrayUsingPredicate:[NSPredicate predicateWithFormat:@"self ENDSWITH %@", suffix]];
        if (!found.count) { printf("ERROR no *%s in %s\n", suffix.UTF8String, dir.UTF8String); return nil; }
        NSMutableArray<NSString *> *frames = [NSMutableArray array];
        for (NSString *n in found) [frames addObject:[n substringToIndex:n.length - suffix.length]];
        return [frames sortedArrayUsingSelector:@selector(compare:)];
    };
    NSArray<NSString *> *names = shots(refDir, @"_gl.png"), *newNames = shots(newDir, newSuffix);
    if (!names || !newNames) return 2;
    if (![names isEqualToArray:newNames]) {
        NSMutableSet *onlyRef = [NSMutableSet setWithArray:names], *onlyNew = [NSMutableSet setWithArray:newNames];
        [onlyRef minusSet:[NSSet setWithArray:newNames]]; [onlyNew minusSet:[NSSet setWithArray:names]];
        printf("ERROR the two runs shot different frames: only in ref %s; only in new %s\n",
               [[onlyRef.allObjects componentsJoinedByString:@" "] UTF8String], [[onlyNew.allObjects componentsJoinedByString:@" "] UTF8String]);
        return 2;
    }
    bool ok = true; double worst2 = 0, worst8 = 0, worstBias = 0; int worstMax = 0;
    for (NSString *n in names) {
        int rw = 0, rh = 0, nw = 0, nh = 0;
        std::vector<uint8_t> a = readPNG([refDir stringByAppendingPathComponent:[n stringByAppendingString:@"_gl.png"]], rw, rh);
        std::vector<uint8_t> b = readPNG([newDir stringByAppendingPathComponent:[n stringByAppendingString:newSuffix]], nw, nh);
        if (a.empty() || b.empty() || rw != nw || rh != nh) { printf("ERROR %s missing or a different size\n", n.UTF8String); return 2; }
        size_t lit = 0, l2 = 0, l8 = 0; int maxd = 0; double sb[3] = {0, 0, 0};
        for (size_t i = 0; i < (size_t)rw * rh; i++) {
            int pm = 0; bool isLit = false;
            for (int c = 0; c < 3; c++) {
                int d = abs((int)a[i * 4 + c] - (int)b[i * 4 + c]); pm = MAX(pm, d);
                isLit |= a[i * 4 + c] > 8 || b[i * 4 + c] > 8;
            }
            maxd = MAX(maxd, pm);
            if (isLit) { lit++; l2 += pm > 2; l8 += pm > 8; for (int c = 0; c < 3; c++) sb[c] += (int)b[i * 4 + c] - (int)a[i * 4 + c]; }
        }
        double bias = 0; for (int c = 0; c < 3; c++) bias = MAX(bias, fabs(sb[c] / MAX((size_t)1, lit)));
        double p2 = lit ? 100.0 * l2 / lit : 0, p8 = lit ? 100.0 * l8 / lit : 0;
        bool shotOk = p2 <= max2 && p8 <= max8 && bias <= maxBias;
        ok &= shotOk; worst2 = MAX(worst2, p2); worst8 = MAX(worst8, p8); worstBias = MAX(worstBias, bias); worstMax = MAX(worstMax, maxd);
        printf("%s  max %3d  lit>2 %6.3f%%  lit>8 %6.3f%%  bias %5.3f  %s\n", n.UTF8String, maxd, p2, p8, bias, shotOk ? "ok" : "FAIL");
    }
    printf("%s shots=%lu worst_max=%d worst_lit>2=%.3f%% worst_lit>8=%.3f%% worst_bias=%.3f (limits %.2f%% / %.2f%% / %.3f)\n",
           ok ? same : different, (unsigned long)names.count, worstMax, worst2, worst8, worstBias, max2, max8, maxBias);
    return ok ? 0 : 1;
}

// parity --backend-textures: both backends' textures, read back level by level.
// Six different faces, so a face out of order shows; GL's are read back by its
// own target names (+x -x +y -y +z -z, which is also Metal's slice order), so
// the comparison does not trust either side's mapping. Exit 0 = the same bytes.
static int compareBackendTextures(NSString *metalDir)
{
    NSOpenGLPixelFormatAttribute attrs[] = { NSOpenGLPFAAccelerated, NSOpenGLPFAColorSize, 32, NSOpenGLPFAAllowOfflineRenderers, 0 };
    NSOpenGLContext *glctx = [[NSOpenGLContext alloc] initWithFormat:[[NSOpenGLPixelFormat alloc] initWithAttributes:attrs] shareContext:nil];
    if (!glctx) { printf("ERROR no GL context\n"); return 2; }
    [glctx makeCurrentContext];
    id<MTLDevice> dev = MTLCreateSystemDefaultDevice();
    HSRendererGL gl;
    HSRendererMetal metal((__bridge void *)dev, metalDir.fileSystemRepresentation);

    const int size = 32;
    auto image = [&](int channels, uint32_t seed) {
        std::vector<unsigned char> px((size_t)size * size * channels);
        for (unsigned char &c : px) { seed = seed * 1664525u + 1013904223u; c = (unsigned char)(seed >> 24); }
        return px;
    };
    int bad = 0, compared = 0;
    // GL's level as RGBA (an RGB texture reads back with alpha 255) against Metal's.
    auto compare = [&](const char *what, GLenum target, GLuint glName, unsigned int mtName, int level, int slice) {
        const int s = MAX(1, size >> level);
        std::vector<unsigned char> a((size_t)s * s * 4), b((size_t)s * s * 4);
        glGetTexImage(target, level, GL_RGBA, GL_UNSIGNED_BYTE, a.data());
        id<MTLTexture> t = (__bridge id<MTLTexture>)metal.texture(mtName);
        if (!t || level >= (int)t.mipmapLevelCount) { printf("FAIL %s level %d: missing on Metal\n", what, level); bad++; return; }
        [t getBytes:b.data() bytesPerRow:(size_t)s * 4 bytesPerImage:(size_t)s * s * 4 fromRegion:MTLRegionMake2D(0, 0, s, s) mipmapLevel:level slice:slice];
        size_t diff = 0; for (size_t i = 0; i < a.size(); i++) diff += a[i] != b[i];
        compared++;
        if (diff) { printf("FAIL %s level %d: %zu of %zu bytes differ\n", what, level, diff, a.size()); bad++; }
    };

    std::vector<unsigned char> rgba = image(4, 1);
    unsigned int g = gl.createTexture(size, size, rgba.data()), m = metal.createTexture(size, size, rgba.data());
    glBindTexture(GL_TEXTURE_2D, g); compare("createTexture", GL_TEXTURE_2D, g, m, 0, 0);

    for (int channels = 3; channels <= 4; channels++) {
        std::vector<unsigned char> px = image(channels, 2 + channels);
        HSMipChain chain; hsBuildMipmaps(px.data(), size, channels, chain);
        g = gl.createMipmappedTexture(chain); m = metal.createMipmappedTexture(chain);
        glBindTexture(GL_TEXTURE_2D, g);
        char what[64]; snprintf(what, sizeof what, "createMipmappedTexture (%d channels)", channels);
        for (size_t l = 0; l < chain.levels.size(); l++) compare(what, GL_TEXTURE_2D, g, m, (int)l, 0);
    }

    HSMipChain faces[6];
    for (int f = 0; f < 6; f++) { std::vector<unsigned char> px = image(3, 10 + f); hsBuildMipmaps(px.data(), size, 3, faces[f]); }
    g = gl.createCubeTexture(faces); m = metal.createCubeTexture(faces);
    glBindTexture(GL_TEXTURE_CUBE_MAP, g);
    static const char *const names[6] = {"+x", "-x", "+y", "-y", "+z", "-z"};
    for (int s = 0; s < 6; s++) {
        char what[64]; snprintf(what, sizeof what, "createCubeTexture face %s", names[s]);
        for (size_t l = 0; l < faces[0].levels.size(); l++) compare(what, GL_TEXTURE_CUBE_MAP_POSITIVE_X + s, g, m, (int)l, s);
    }
    GLenum err = glGetError();
    if (err != GL_NO_ERROR) { printf("ERROR GL error 0x%x\n", err); return 2; }
    printf("%s textures: %d levels and faces compared, %d differ\n", bad ? "FAIL" : "PASS", compared, bad);
    return bad ? 1 : 0;
}

// parity --backend-caustics: causticTextures, as the saver builds it for the
// tunnel, made once through HSRendererGL and once through HSRendererMetal. No
// randomness goes into it, so the only difference is how each backend
// rasterizes the strips. Every level of every frame is compared under the
// stars pass's rule, over pixels lit in either.
static int compareBackendCaustics(NSString *metalDir)
{
    NSOpenGLPixelFormatAttribute attrs[] = { NSOpenGLPFAAccelerated, NSOpenGLPFAColorSize, 32, NSOpenGLPFAAllowOfflineRenderers, 0 };
    NSOpenGLContext *glctx = [[NSOpenGLContext alloc] initWithFormat:[[NSOpenGLPixelFormat alloc] initWithAttributes:attrs] shareContext:nil];
    if (!glctx) { printf("ERROR no GL context\n"); return 2; }
    [glctx makeCurrentContext];
    // GL's offscreen pass draws into the bound framebuffer.
    const int size = 256;
    GLuint fbo, color;
    glGenFramebuffersEXT(1, &fbo); glBindFramebufferEXT(GL_FRAMEBUFFER_EXT, fbo);
    glGenRenderbuffersEXT(1, &color); glBindRenderbufferEXT(GL_RENDERBUFFER_EXT, color);
    glRenderbufferStorageEXT(GL_RENDERBUFFER_EXT, GL_RGBA8, size, size);
    glFramebufferRenderbufferEXT(GL_FRAMEBUFFER_EXT, GL_COLOR_ATTACHMENT0_EXT, GL_RENDERBUFFER_EXT, color);
    if (glCheckFramebufferStatusEXT(GL_FRAMEBUFFER_EXT) != GL_FRAMEBUFFER_COMPLETE_EXT) { printf("ERROR framebuffer incomplete\n"); return 2; }
    id<MTLDevice> dev = MTLCreateSystemDefaultDevice();
    HSRendererGL gl;
    HSRendererMetal metal((__bridge void *)dev, metalDir.fileSystemRepresentation);
    // Hyperspace.cpp's arguments, with the shaded look's 20 frames.
    // beginOffscreen's glReadBuffer(GL_BACK) raises INVALID_OPERATION under an
    // FBO, as in the main loop; read and draw both stay on the FBO's color
    // attachment, so what it reads back is what it drew. Any other error fails.
    causticTextures a(&gl, 8, 20, 100, size, 1.0f, 0.01f, 20.0f);
    for (GLenum err; (err = glGetError()) != GL_NO_ERROR; )
        if (err != GL_INVALID_OPERATION) { printf("ERROR GL error 0x%x\n", err); return 2; }
    causticTextures b(&metal, 8, 20, 100, size, 1.0f, 0.01f, 20.0f);

    const double max2 = 1.0, max8 = 0.1, maxBias = 0.06;
    bool ok = true; double worst2 = 0, worst8 = 0, worstBias = 0; int worstMax = 0, compared = 0;
    for (int k = 0; k < a.numFrames; k++) {
        id<MTLTexture> t = (__bridge id<MTLTexture>)metal.texture(b.caustictex[k]);
        if (!t) { printf("ERROR frame %d has no Metal texture\n", k); return 2; }
        glBindTexture(GL_TEXTURE_2D, a.caustictex[k]);
        for (int l = 0; l < (int)t.mipmapLevelCount; l++) {
            const int s = MAX(1, size >> l);
            std::vector<unsigned char> pa((size_t)s * s * 4), pb((size_t)s * s * 4);
            glGetTexImage(GL_TEXTURE_2D, l, GL_RGBA, GL_UNSIGNED_BYTE, pa.data());
            [t getBytes:pb.data() bytesPerRow:(size_t)s * 4 fromRegion:MTLRegionMake2D(0, 0, s, s) mipmapLevel:l];
            size_t lit = 0, l2 = 0, l8 = 0; int maxd = 0; double sb[3] = {0, 0, 0};
            for (size_t i = 0; i < (size_t)s * s; i++) {
                int pm = 0; bool isLit = false;
                for (int c = 0; c < 3; c++) {
                    pm = MAX(pm, abs((int)pa[i * 4 + c] - (int)pb[i * 4 + c]));
                    isLit |= pa[i * 4 + c] > 8 || pb[i * 4 + c] > 8;
                }
                maxd = MAX(maxd, pm);
                if (isLit) { lit++; l2 += pm > 2; l8 += pm > 8; for (int c = 0; c < 3; c++) sb[c] += (int)pb[i * 4 + c] - (int)pa[i * 4 + c]; }
            }
            double bias = 0; for (int c = 0; c < 3; c++) bias = MAX(bias, fabs(sb[c] / MAX((size_t)1, lit)));
            double p2 = lit ? 100.0 * l2 / lit : 0, p8 = lit ? 100.0 * l8 / lit : 0;
            // A level with nothing lit on either side would pass by comparing black.
            if (l == 0 && !lit) { printf("ERROR caustic frame %d is black on both sides\n", k); return 2; }
            bool levelOk = p2 <= max2 && p8 <= max8 && bias <= maxBias;
            if (!levelOk) printf("FAIL caustic frame %d level %d: max %d lit>2 %.3f%% lit>8 %.3f%% bias %.3f\n", k, l, maxd, p2, p8, bias);
            ok &= levelOk; compared++;
            worst2 = MAX(worst2, p2); worst8 = MAX(worst8, p8); worstBias = MAX(worstBias, bias); worstMax = MAX(worstMax, maxd);
        }
    }
    printf("%s caustics: %d frames, %d levels compared, worst_max=%d worst_lit>2=%.3f%% worst_lit>8=%.3f%% worst_bias=%.3f (limits %.2f%% / %.2f%% / %.3f)\n",
           ok ? "PASS" : "FAIL", a.numFrames, compared, worstMax, worst2, worst8, worstBias, max2, max8, maxBias);
    return ok ? 0 : 1;
}

static NSString *readFile(NSString *path)
{
    NSString *s = [NSString stringWithContentsOfFile:path encoding:NSUTF8StringEncoding error:nil];
    if (!s) printf("ERROR cannot read %s\n", path.UTF8String);
    return s;
}

int main(int argc, const char *argv[])
{
    @autoreleasepool {
        if (argc == 4 && !strcmp(argv[1], "--compare")) return compareRuns(@(argv[2]), @(argv[3]), @"_gl.png", 0.1, 0.01, 0.06, "SAME", "DIFFERENT");
        if (argc == 3 && !strcmp(argv[1], "--backend-textures")) return compareBackendTextures(@(argv[2]));
        if (argc == 3 && !strcmp(argv[1], "--backend-caustics")) return compareBackendCaustics(@(argv[2]));
        if (argc == 5 && !strcmp(argv[1], "--compare-backend")) {
            for (const Pass &p : kPasses)
                if (!strcmp(argv[2], p.name)) return compareRuns(@(argv[3]), @(argv[4]), @"_backend.png", p.max2, p.max8, p.maxBias, "PASS", "FAIL");
            fprintf(stderr, "unknown pass %s\n", argv[2]); return 2;
        }
        if (argc == 2 && !strcmp(argv[1], "--inject-cases")) { for (const char *k : kInjectCases) printf("%s\n", k); return 0; }
        if (argc < 4) {
            fprintf(stderr, "usage: parity <stars|goo|tunnel|burst|sun> <metal-dir> <outdir> [shader=PATH] [inject=CASE] [renderer=metal] [frames=N] [every=N] [w=N] [h=N]\n"
                            "       parity --compare <ref-dir> <new-dir>\n"
                            "       parity --compare-backend <pass> <gl-dir> <backend-dir>\n"
                            "       parity --backend-textures <metal-dir>\n"
                            "       parity --backend-caustics <metal-dir>\n");
            return 2;
        }
        const Pass *pass = nullptr;
        for (const Pass &p : kPasses) if (!strcmp(argv[1], p.name)) pass = &p;
        if (!pass) { fprintf(stderr, "unknown pass %s\n", argv[1]); return 2; }
        NSString *metalDir = @(argv[2]), *outdir = @(argv[3]);
        NSString *shaderPath = [metalDir stringByAppendingPathComponent:@(pass->file)];
        int frames = pass->frames, every = pass->every, w = 1280, h = 720;
        const char *inject = nullptr;
        bool backend = false, shaderGiven = false;
        auto intOpt = [](const char *arg, const char *key, int &out) {
            size_t n = strlen(key);
            if (strncmp(arg, key, n)) return false;
            char *end; long v = strtol(arg + n, &end, 10);
            if (end == arg + n || *end || v < 1 || v > 1000000) { fprintf(stderr, "bad value in %s\n", arg); exit(2); }
            out = (int)v; return true;
        };
        for (int i = 4; i < argc; i++) {
            if (!strncmp(argv[i], "shader=", 7) && argv[i][7]) { shaderPath = @(argv[i] + 7); shaderGiven = true; }
            else if (!strcmp(argv[i], "renderer=metal")) backend = true;
            else if (!strncmp(argv[i], "inject=", 7)) {
                inject = argv[i] + 7;
                bool known = false; for (const char *k : kInjectCases) known |= !strcmp(k, inject);
                if (!known) { fprintf(stderr, "unknown inject case %s\n", inject); return 2; }
            }
            else if (intOpt(argv[i], "frames=", frames) || intOpt(argv[i], "every=", every) ||
                     intOpt(argv[i], "w=", w) || intOpt(argv[i], "h=", h)) {}
            else { fprintf(stderr, "bad option %s\n", argv[i]); return 2; }
        }
        // The backend draws with metal/ as it stands, and has no tunnel yet.
        if (backend && (shaderGiven || inject)) { fprintf(stderr, "renderer=metal takes no shader= or inject=\n"); return 2; }
        if (backend && pass->tunnels) {
            fprintf(stderr, "renderer=metal cannot draw the %s pass yet: the backend has no tunnel\n", pass->name); return 2;
        }
        const float dt = 1.0f / 60.0f;
        [[NSFileManager defaultManager] createDirectoryAtPath:outdir withIntermediateDirectories:YES attributes:nil error:nil];

        // Two libraries, each with the interface prepended: the fixed-function path
        // (always needed -- stars draw in every pass) and the judged pass's shader.
        NSString *iface = readFile([metalDir stringByAppendingPathComponent:@"Interface.metal"]);
        // The passes whose judged shader is the fixed-function one: stars and sun.
        bool ffPass = !strcmp(pass->file, "FixedFunction.metal");
        NSString *ffPath = ffPass ? shaderPath : [metalDir stringByAppendingPathComponent:@"FixedFunction.metal"];
        NSString *ffSrc = readFile(ffPath), *passSrc = ffPass ? ffSrc : readFile(shaderPath);
        if (!iface || !ffSrc || !passSrc) return 2;

        NSError *err = nil;
        id<MTLDevice> dev = MTLCreateSystemDefaultDevice();
        auto pipeline = [&](NSString *src, NSString *path, const char *vfn, const char *ffn) -> id<MTLRenderPipelineState> {
            id<MTLLibrary> lib = [dev newLibraryWithSource:[iface stringByAppendingString:src] options:nil error:&err];
            if (!lib) { printf("ERROR %s does not compile:\n%s\n", path.UTF8String, err.localizedDescription.UTF8String); return nil; }
            id<MTLFunction> vf = [lib newFunctionWithName:@(vfn)], ff = [lib newFunctionWithName:@(ffn)];
            if (!vf || !ff) { printf("ERROR %s must define %s and %s\n", path.UTF8String, vfn, ffn); return nil; }
            MTLRenderPipelineDescriptor *pd = [MTLRenderPipelineDescriptor new];
            pd.colorAttachments[0].pixelFormat = MTLPixelFormatRGBA8Unorm;
            pd.colorAttachments[0].blendingEnabled = YES;   // Hyperspace draws everything with (SRC_ALPHA, ONE)
            pd.colorAttachments[0].sourceRGBBlendFactor = pd.colorAttachments[0].sourceAlphaBlendFactor = MTLBlendFactorSourceAlpha;
            pd.colorAttachments[0].destinationRGBBlendFactor = pd.colorAttachments[0].destinationAlphaBlendFactor = MTLBlendFactorOne;
            pd.vertexFunction = vf; pd.fragmentFunction = ff;
            id<MTLRenderPipelineState> ps = [dev newRenderPipelineStateWithDescriptor:pd error:&err];
            if (!ps) printf("ERROR pipeline for %s: %s\n", path.UTF8String, err.localizedDescription.UTF8String);
            return ps;
        };
        id<MTLRenderPipelineState> ffPS = pipeline(ffSrc, ffPath, "ff_vertex", "ff_fragment");
        id<MTLRenderPipelineState> passPS = ffPass ? ffPS : pipeline(passSrc, shaderPath, pass->vfn, pass->ffn);
        if (!ffPS || !passPS) return 2;

        // The saver's pixel format has no depth buffer, so neither does this target.
        NSOpenGLPixelFormatAttribute attrs[] = { NSOpenGLPFAAccelerated, NSOpenGLPFAColorSize, 32, NSOpenGLPFAMinimumPolicy, NSOpenGLPFAAllowOfflineRenderers, 0 };
        NSOpenGLContext *glctx = [[NSOpenGLContext alloc] initWithFormat:[[NSOpenGLPixelFormat alloc] initWithAttributes:attrs] shareContext:nil];
        if (!glctx) { printf("ERROR no GL context\n"); return 2; }
        [glctx makeCurrentContext];
        GLuint fbo, color;
        glGenFramebuffersEXT(1, &fbo); glBindFramebufferEXT(GL_FRAMEBUFFER_EXT, fbo);
        glGenRenderbuffersEXT(1, &color); glBindRenderbufferEXT(GL_RENDERBUFFER_EXT, color);
        glRenderbufferStorageEXT(GL_RENDERBUFFER_EXT, GL_RGBA8, w, h);
        glFramebufferRenderbufferEXT(GL_FRAMEBUFFER_EXT, GL_COLOR_ATTACHMENT0_EXT, GL_RENDERBUFFER_EXT, color);
        if (glCheckFramebufferStatusEXT(GL_FRAMEBUFFER_EXT) != GL_FRAMEBUFFER_COMPLETE_EXT) { printf("ERROR framebuffer incomplete\n"); return 2; }

        // HyperspaceView.mm's call order. (causticTextures.cpp's glReadBuffer(GL_BACK)
        // raises INVALID_OPERATION under an FBO; read and draw buffers both stay on
        // COLOR_ATTACHMENT0, so the caustic readback reads what it drew.)
        static HyperspaceSaverSettings s;
        setDefaults(&s);
        s.dUseGoo = pass->goo; s.dUseTunnels = pass->tunnels;
        s.first = 1;
        reshape(w, h, &s);
        glClearColor(0, 0, 0, 0); glClear(GL_COLOR_BUFFER_BIT); glFlush();
        // The GL context stays in backend mode: initSaver still builds the GL
        // programs and rsText, and a draw that slips past the backend into GL is
        // caught below rather than crashing.
        HSRendererMetal *metalRenderer = nullptr;
        id<MTLTexture> backendTarget = nil;
        if (backend) {
            MTLTextureDescriptor *bd = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA8Unorm width:w height:h mipmapped:NO];
            bd.usage = MTLTextureUsageRenderTarget; bd.storageMode = MTLStorageModeShared;
            backendTarget = [dev newTextureWithDescriptor:bd];
            metalRenderer = new HSRendererMetal((__bridge void *)dev, metalDir.fileSystemRepresentation);
            metalRenderer->setTarget((__bridge void *)backendTarget);
        }
        initSaver(&s, metalRenderer);
        printf("renderer: %s\n", backend ? "HSRendererMetal" : (const char *)glGetString(GL_RENDERER));
        printf("config: pass=%s seed=%ld goo=%d tunnels=%d shaders=%d %dx%d frames=%d every=%d shader=%s%s%s\n",
               pass->name, (long)gSeed, s.dUseGoo, s.dUseTunnels, s.dShaders, w, h, frames, every,
               backend ? "(backend: metal/)" : shaderPath.UTF8String, inject ? " inject=" : "", inject ? inject : "");
        if (inject) injectSetup(inject);
        if (inject && !strcmp(inject, "tunnelnotex") && !tunnelProgram) { printf("ERROR inject=tunnelnotex needs the tunnel program\n"); return 2; }
        if (inject && !strcmp(inject, "goopartialcube") && !gooProgram) { printf("ERROR inject=goopartialcube needs the goo program\n"); return 2; }

        MTLTextureDescriptor *cd = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA8Unorm width:w height:h mipmapped:NO];
        cd.usage = MTLTextureUsageRenderTarget; cd.storageMode = MTLStorageModeShared;
        id<MTLTexture> target = [dev newTextureWithDescriptor:cd];
        id<MTLCommandQueue> q = [dev newCommandQueue];
        std::map<GLuint, id<MTLTexture>> tex2d, texCube;
        std::map<GLuint, id<MTLSamplerState>> samp2d, sampCube;
        // GL clip z is [-w, w]; Metal's is [0, w].
        simd_float4x4 zfix = matrix_identity_float4x4;
        zfix.columns[2] = simd_make_float4(0, 0, 0.5f, 0); zfix.columns[3] = simd_make_float4(0, 0, 0.5f, 1);

        // Filters and wrap are queried from GL, not assumed.
        auto sampler = [&](GLenum tgt) {
            GLint minF, magF, ws, wt, wr;
            glGetTexParameteriv(tgt, GL_TEXTURE_MIN_FILTER, &minF); glGetTexParameteriv(tgt, GL_TEXTURE_MAG_FILTER, &magF);
            glGetTexParameteriv(tgt, GL_TEXTURE_WRAP_S, &ws); glGetTexParameteriv(tgt, GL_TEXTURE_WRAP_T, &wt);
            glGetTexParameteriv(tgt, GL_TEXTURE_WRAP_R, &wr);
            MTLSamplerDescriptor *sd = [MTLSamplerDescriptor new];
            sd.minFilter = mmf(minF); sd.magFilter = mmf(magF); sd.mipFilter = mipf(minF);
            sd.sAddressMode = addr(ws); sd.tAddressMode = addr(wt); sd.rAddressMode = addr(wr);
            return [dev newSamplerStateWithDescriptor:sd];
        };
        // Textures are copied out of GL with every mip level it holds, so neither
        // texture generation nor mip generation can differ between the two sides.
        // A texture changed during a shot frame fails the shot (noteTextureChange); the
        // copies are dropped after every shot so that one changed between shots
        // is copied again.
        auto copyCube = [&](GLuint t) {
            real_glBindTexture(GL_TEXTURE_CUBE_MAP, t);
            GLint sz, minF; glGetTexLevelParameteriv(GL_TEXTURE_CUBE_MAP_POSITIVE_X, 0, GL_TEXTURE_WIDTH, &sz);
            glGetTexParameteriv(GL_TEXTURE_CUBE_MAP, GL_TEXTURE_MIN_FILTER, &minF);
            int levels = 1;
            if (minF != GL_NEAREST && minF != GL_LINEAR) for (int m = sz; m > 1; m /= 2) levels++;
            MTLTextureDescriptor *td = [MTLTextureDescriptor textureCubeDescriptorWithPixelFormat:MTLPixelFormatRGBA8Unorm size:sz mipmapped:levels > 1];
            td.mipmapLevelCount = levels;
            id<MTLTexture> mt = [dev newTextureWithDescriptor:td];
            for (int l = 0; l < levels; l++) {
                int ls = MAX(1, sz >> l);
                std::vector<uint8_t> px((size_t)ls * ls * 4);
                for (int face = 0; face < 6; face++) {
                    glGetTexImage(GL_TEXTURE_CUBE_MAP_POSITIVE_X + face, l, GL_RGBA, GL_UNSIGNED_BYTE, px.data());
                    [mt replaceRegion:MTLRegionMake2D(0, 0, ls, ls) mipmapLevel:l slice:face withBytes:px.data() bytesPerRow:(size_t)ls * 4 bytesPerImage:0];
                }
            }
            texCube[t] = mt; sampCube[t] = sampler(GL_TEXTURE_CUBE_MAP);
        };
        auto copy2D = [&](GLuint t) {
            real_glBindTexture(GL_TEXTURE_2D, t);
            GLint tw, th, minF;
            glGetTexLevelParameteriv(GL_TEXTURE_2D, 0, GL_TEXTURE_WIDTH, &tw); glGetTexLevelParameteriv(GL_TEXTURE_2D, 0, GL_TEXTURE_HEIGHT, &th);
            glGetTexParameteriv(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, &minF);
            int levels = 1;
            if (minF != GL_NEAREST && minF != GL_LINEAR) for (int m = MAX(tw, th); m > 1; m /= 2) levels++;
            MTLTextureDescriptor *td = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA8Unorm width:tw height:th mipmapped:levels > 1];
            td.mipmapLevelCount = levels;
            id<MTLTexture> mt = [dev newTextureWithDescriptor:td];
            for (int l = 0; l < levels; l++) {
                int lw = MAX(1, tw >> l), lh = MAX(1, th >> l);
                std::vector<uint8_t> px((size_t)lw * lh * 4);
                glGetTexImage(GL_TEXTURE_2D, l, GL_RGBA, GL_UNSIGNED_BYTE, px.data());
                [mt replaceRegion:MTLRegionMake2D(0, 0, lw, lh) mipmapLevel:l withBytes:px.data() bytesPerRow:(size_t)lw * 4];
            }
            tex2d[t] = mt; samp2d[t] = sampler(GL_TEXTURE_2D);
        };

        size_t npx = (size_t)w * h;
        std::vector<uint8_t> glbuf(npx * 4), glflip(npx * 4), mtl(npx * 4), heat(npx * 4);
        printf(" shot  judged-draws  max   lit%%  lit>2%%  lit>8%%   bias  verdict\n");
        bool ok = true; int shots = 0; double worst2 = 0, worst8 = 0, worstBias = 0; long judgedTotal = 0;
        GLuint primQuery; glGenQueries(1, &primQuery);

        for (int f = 0; f < frames; f++) {
            bool shot = f > 0 && (f % every == 0 || f == frames - 1);
            gRecording = shot; gBatches.clear(); gUnsupported = 0;
            s.frameTime = dt;
            if (shot) while (glGetError() != GL_NO_ERROR) {}
            if (shot) glBeginQuery(GL_PRIMITIVES_GENERATED_EXT, primQuery);
            if (pass->burstAt > 0 && f == pass->burstAt) {
                // Where the saver puts one, ahead of the camera along the path, with
                // its random distance (0.5 to 1.0 of depth) and height (-1 to 1)
                // fixed at their middles. The saver places it after this frame's
                // path update; this uses the last frame's camera, a frame behind.
                float dir[3], at[3];
                s.thePath->getBaseDirection(s.dDepth + 2, s.thePath->step, dir);
                for (int i = 0; i < 3; i++) at[i] = s.camPos[i] + dir[i] * s.depth * 0.75f;
                at[1] = 0.0f;
                s.theStarBurst->restart(at);
                // restart() declines silently when a burst is already running; then
                // this pass would be a short goo pass with nothing of the burst in it.
                if (s.theStarBurst->size != 0.0f) { printf("ERROR the starburst did not start at frame %d\n", f); return 2; }
            }
            if (pass->sunAhead > 0 && f > 0) {
                // Along last frame's view direction (the view matrix's third row,
                // negated), so the sun is near the middle of this frame. The first
                // time, its last position moves too, or it would draw stretched
                // from where the saver put it.
                const double *m = s.modelMat;
                for (int i = 0; i < 3; i++) {
                    s.sunStar->pos[i] = s.camPos[i] - float(m[4 * i + 2]) * pass->sunAhead;
                    if (f == 1) s.sunStar->lastPos[i] = s.sunStar->pos[i];
                }
            }
            // One pool a frame: the backend's command buffer and encoder are
            // autoreleased, and main's pool would hold every frame's to the end.
            @autoreleasepool { draw(&s); }
            if (shot && pass->sunAhead > 0) {
                // Checked where the sun was drawn this frame, drawPos. A sun off
                // to the side would leave a shot judging the stars alone, and one
                // inside the fog's end would not show whether it draws unfogged.
                const float *p = s.sunStar->drawPos; double win[3];
                bool inFront = hsProject(p[0], p[1], p[2], s.modelMat, s.projMat, s.viewport, win) && win[2] > 0 && win[2] < 1;
                if (!inFront || fabs(win[0] - w / 2.0) > w / 4.0 || fabs(win[1] - h / 2.0) > h / 4.0) {
                    printf("ERROR the sun is not in the middle of frame %d\n", f); return 2;
                }
                // Fog runs on eye-plane depth: the view matrix's third row.
                const double *m = s.modelMat;
                double depth = -(m[2] * p[0] + m[6] * p[1] + m[10] * p[2] + m[14]);
                if (depth <= s.depth) {
                    printf("ERROR the sun at depth %.2f is inside the fog's end (%.2f) at frame %d\n", depth, s.depth, f); return 2;
                }
            }
            if (shot && inject) injectFault(inject);
            if (shot) glEndQuery(GL_PRIMITIVES_GENERATED_EXT);
            glFinish();
            gRecording = false;
            if (!shot) continue;

            if (backend) {
                // Nothing may draw through GL: every draw goes to the backend.
                GLuint generated = 0; glGetQueryObjectuiv(primQuery, GL_QUERY_RESULT, &generated);
                if (generated || gUnsupported || !gBatches.empty()) {
                    printf("ERROR frame %d drew through GL in backend mode (%u primitives)\n", f, generated); return 2;
                }
                [backendTarget getBytes:mtl.data() bytesPerRow:(size_t)w * 4 fromRegion:MTLRegionMake2D(0, 0, w, h) mipmapLevel:0];
                int draws = metalRenderer->drawCount();
                shots++; judgedTotal += draws;
                printf("%5d  %12d  backend\n", f, draws);
                NSString *base = [outdir stringByAppendingPathComponent:[NSString stringWithFormat:@"%05d", f]];
                writePNG([base stringByAppendingString:@"_backend.png"], mtl.data(), w, h);
                continue;
            }

            // A GL error means some call -- the saver's or the recorder's -- did not do
            // what the recording assumes it did.
            GLenum glErr = glGetError();
            if (glErr == GL_NO_ERROR) glErr = gInjectGLError;
            gInjectGLError = GL_NO_ERROR;
            // Every primitive GL generated must be a recorded triangle.
            GLuint generated = 0; glGetQueryObjectuiv(primQuery, GL_QUERY_RESULT, &generated);
            size_t recorded = 0;
            for (auto &b : gBatches) recorded += (b.kind == DrawKind::Goo ? b.gooTri.size() : b.tri.size()) / 3;
            bool complete = gUnsupported == 0 && generated == recorded && glErr == GL_NO_ERROR;
            tex2d.clear(); texCube.clear(); samp2d.clear(); sampCube.clear();

            glReadPixels(0, 0, w, h, GL_RGBA, GL_UNSIGNED_BYTE, glbuf.data());
            for (int y = 0; y < h; y++) memcpy(&glflip[(size_t)y * w * 4], &glbuf[(size_t)(h - 1 - y) * w * 4], (size_t)w * 4);
            GLint savedActive; glGetIntegerv(GL_ACTIVE_TEXTURE, &savedActive);
            glActiveTexture(GL_TEXTURE0);

            MTLRenderPassDescriptor *rp = [MTLRenderPassDescriptor renderPassDescriptor];
            rp.colorAttachments[0].texture = target; rp.colorAttachments[0].loadAction = MTLLoadActionClear;
            rp.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 0, 1); rp.colorAttachments[0].storeAction = MTLStoreActionStore;
            id<MTLCommandBuffer> cb = [q commandBuffer];
            id<MTLRenderCommandEncoder> enc = [cb renderCommandEncoderWithDescriptor:rp];
            [enc setFrontFacingWinding:MTLWindingCounterClockwise];   // GL_CCW; measured: CW culls the wrong faces
            int judged = 0;
            for (auto &b : gBatches) {
                [enc setCullMode:b.st.cullOn ? (b.st.cullFace == GL_BACK ? MTLCullModeBack : MTLCullModeFront) : MTLCullModeNone];
                simd_float4x4 mvp = simd_mul(zfix, simd_mul(b.st.proj, b.st.mv));
                if (b.kind == DrawKind::Goo) {
                    if (b.gooTri.empty()) continue;
                    for (int u = 0; u < 3; u++) if (!texCube.count(b.cube[u])) copyCube(b.cube[u]);
                    // Expand indices so the shader sees plain triangles of GooVertex.
                    std::vector<float> tv; tv.reserve(b.gooTri.size() * 6);
                    for (uint32_t ix : b.gooTri) {
                        if ((size_t)ix * 6 + 6 > b.gooVerts.size()) { printf("ERROR goo index %u outside its VBO\n", ix); return 2; }
                        tv.insert(tv.end(), &b.gooVerts[(size_t)ix * 6], &b.gooVerts[(size_t)ix * 6 + 6]);
                    }
                    id<MTLBuffer> vb = [dev newBufferWithBytes:tv.data() length:tv.size() * sizeof(float) options:MTLResourceStorageModeShared];
                    GooU u = { mvp, b.st.mv, b.st.color, b.st.fogColor, b.st.fogEnd, 1.0f / (b.st.fogEnd - b.st.fogStart), simd_mul(zfix, b.st.proj) };
                    [enc setRenderPipelineState:passPS];
                    [enc setVertexBuffer:vb offset:0 atIndex:0];
                    [enc setVertexBytes:&u length:sizeof u atIndex:1]; [enc setFragmentBytes:&u length:sizeof u atIndex:1];
                    for (int t = 0; t < 3; t++) { [enc setFragmentTexture:texCube[b.cube[t]] atIndex:t]; [enc setFragmentSamplerState:sampCube[b.cube[t]] atIndex:t]; }
                    [enc drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:b.gooTri.size()];
                    judged += pass->goo;   // the goo and burst passes
                } else if (b.kind == DrawKind::Tunnel) {
                    if (b.tri.empty()) continue;
                    if (!tex2d.count(b.tex)) copy2D(b.tex);
                    if (!tex2d.count(b.tex1)) copy2D(b.tex1);
                    TunnelU u = { mvp, b.st.mv, simd_mul(zfix, b.st.proj), b.st.fogColor, b.st.fogEnd, 1.0f / (b.st.fogEnd - b.st.fogStart) };
                    id<MTLBuffer> vb = [dev newBufferWithBytes:b.tri.data() length:b.tri.size() * sizeof(Vtx) options:MTLResourceStorageModeShared];
                    [enc setRenderPipelineState:passPS];
                    [enc setVertexBuffer:vb offset:0 atIndex:0];
                    [enc setVertexBytes:&u length:sizeof u atIndex:1]; [enc setFragmentBytes:&u length:sizeof u atIndex:1];
                    [enc setFragmentTexture:tex2d[b.tex] atIndex:0]; [enc setFragmentSamplerState:samp2d[b.tex] atIndex:0];
                    [enc setFragmentTexture:tex2d[b.tex1] atIndex:1]; [enc setFragmentSamplerState:samp2d[b.tex1] atIndex:1];
                    [enc drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:b.tri.size()];
                    judged += !strcmp(pass->name, "tunnel");
                } else {
                    if (b.tri.empty()) continue;
                    if (b.st.texOn && !tex2d.count(b.tex)) copy2D(b.tex);
                    FFU u = { mvp, b.st.mv, b.st.fogColor, b.st.fogStart, b.st.fogEnd, b.st.fogOn && b.st.fogMode == GL_LINEAR, b.st.texOn };
                    id<MTLBuffer> vb = [dev newBufferWithBytes:b.tri.data() length:b.tri.size() * sizeof(Vtx) options:MTLResourceStorageModeShared];
                    [enc setRenderPipelineState:ffPS];
                    [enc setVertexBuffer:vb offset:0 atIndex:0];
                    [enc setVertexBytes:&u length:sizeof u atIndex:1]; [enc setFragmentBytes:&u length:sizeof u atIndex:1];
                    if (b.st.texOn) { [enc setFragmentTexture:tex2d[b.tex] atIndex:0]; [enc setFragmentSamplerState:samp2d[b.tex] atIndex:0]; }
                    [enc drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:b.tri.size()];
                    judged += ffPass;
                }
            }
            [enc endEncoding]; [cb commit]; [cb waitUntilCompleted];
            glActiveTexture(savedActive);
            [target getBytes:mtl.data() bytesPerRow:(size_t)w * 4 fromRegion:MTLRegionMake2D(0, 0, w, h) mipmapLevel:0];

            // Rates over pixels lit in either image: a whole-frame rate dilutes on
            // dark frames (stars are 0.3-4% lit), and every defect then passed.
            int maxd = 0; size_t lit = 0, l2 = 0, l8 = 0; double sb[3] = {0, 0, 0};
            for (size_t i = 0; i < npx; i++) {
                int pm = 0; bool isLit = false;
                for (int c = 0; c < 3; c++) {
                    int d = abs((int)glflip[i * 4 + c] - (int)mtl[i * 4 + c]); if (d > pm) pm = d;
                    isLit |= glflip[i * 4 + c] > 8 || mtl[i * 4 + c] > 8;
                }
                if (pm > maxd) maxd = pm;
                if (isLit) {
                    lit++; l2 += pm > 2; l8 += pm > 8;
                    for (int c = 0; c < 3; c++) sb[c] += (int)mtl[i * 4 + c] - (int)glflip[i * 4 + c];
                }
                uint8_t hv = (uint8_t)MIN(255, pm * 8); heat[i * 4] = heat[i * 4 + 1] = heat[i * 4 + 2] = hv; heat[i * 4 + 3] = 255;
            }
            double bias = 0; for (int c = 0; c < 3; c++) bias = MAX(bias, fabs(sb[c] / MAX((size_t)1, lit)));
            double p2 = lit ? 100.0 * l2 / lit : 0, p8 = lit ? 100.0 * l8 / lit : 0;
            bool shotOk = p2 <= pass->max2 && p8 <= pass->max8 && bias <= pass->maxBias && complete;
            ok &= shotOk; shots++; judgedTotal += judged;
            worst2 = MAX(worst2, p2); worst8 = MAX(worst8, p8); worstBias = MAX(worstBias, bias);
            printf("%5d  %12d  %3d  %5.2f  %6.2f  %6.2f  %5.3f  %s", f, judged, maxd, 100.0 * lit / npx, p2, p8, bias, shotOk ? "ok" : "FAIL");
            if (!(p2 <= pass->max2 && p8 <= pass->max8 && bias <= pass->maxBias)) printf(" (outside limits)");
            if (gUnsupported) printf(" (unrecorded GL draw calls)");
            if (glErr != GL_NO_ERROR) printf(" (GL error 0x%x)", glErr);
            if (!gUnsupported && generated != recorded) printf(" (GL drew %u primitives, %zu recorded)", generated, recorded);
            printf("\n");
            NSString *base = [outdir stringByAppendingPathComponent:[NSString stringWithFormat:@"%05d", f]];
            writePNG([base stringByAppendingString:@"_gl.png"], glflip.data(), w, h);
            writePNG([base stringByAppendingString:@"_metal.png"], mtl.data(), w, h);
            writePNG([base stringByAppendingString:@"_diffx8.png"], heat.data(), w, h);
        }
        // A pass that drew nothing would compare black with black and pass.
        if (judgedTotal == 0) { printf("ERROR the %s pass drew nothing in any shot; nothing was compared\n", pass->name); return 2; }
        if (backend) { printf("WROTE pass=%s shots=%d through HSRendererMetal\n", pass->name, shots); return 0; }
        printf("%s pass=%s shots=%d worst_lit>2=%.2f%% worst_lit>8=%.2f%% worst_bias=%.3f (limits %.2f%% / %.2f%% / %.3f)\n",
               ok ? "PASS" : "FAIL", pass->name, shots, worst2, worst8, worstBias, pass->max2, pass->max8, pass->maxBias);
        return ok ? 0 : 1;
    }
}
