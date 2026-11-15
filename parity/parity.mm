// GL -> Metal parity comparator for Hyperspace.
//
// Runs the unmodified OpenGL saver offscreen, deterministically, records every draw
// it makes, replays those draws through the Metal shaders in metal/, and compares
// the two images shot by shot. One pass is judged per run:
//
//   stars   goo and tunnels off: stars, sun, lens flare (metal/FixedFunction.metal)
//   goo     goo on:   the GLSL goo program  (metal/Goo.metal)
//   tunnel  tunnel on: the GLSL tunnel program (metal/Tunnel.metal)
//
//   parity <pass> <metal-dir> <outdir> [shader=PATH] [frames=N] [every=N] [w=N] [h=N]
//
// shader= replaces the judged pass's shader file (parity/killcheck.sh uses it to
// prove each rule rejects known defects). Exit 0 = PASS, 1 = FAIL, 2 = harness or
// shader error. Each shot writes <outdir>/NNNNN_gl.png, _metal.png, _diffx8.png.
//
// Nothing here is a golden image: GL and Metal render the same frame in the same
// process, so the reference is always the shipped renderer on this machine. The
// rules below were calibrated on one machine (Apple M5 Max, macOS 26); see
// parity/README.md for the measurements and for what a different GPU may need.

#import <Cocoa/Cocoa.h>
#import <OpenGL/gl.h>
#import <OpenGL/glext.h>
#import <Metal/Metal.h>
#import <ImageIO/ImageIO.h>
#import <simd/simd.h>
#include <dlfcn.h>
#include <ctime>
#include <map>
#include <string>
#include <vector>
#include "Hyperspace.h"

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
struct ListOp { GLuint tex = 0; bool hasTex = false, unreplayable = false; std::vector<std::vector<Vtx>> strips; };

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
static GLuint gCompiling = 0;
static bool fixedFunctionSupported(GLuint boundTex)
{
    if (gCompiling) return false;   // the bind/restore below would be compiled into the open list
    if (!blendSupported() || glGetHandleARB(GL_PROGRAM_OBJECT_ARB)) return false;
    if (glIsEnabled(GL_TEXTURE_CUBE_MAP) || glIsEnabled(GL_TEXTURE_GEN_S) || glIsEnabled(GL_TEXTURE_GEN_T)) return false;
    if (!glIsEnabled(GL_TEXTURE_2D)) return true;
    GLint env; glGetTexEnviv(GL_TEXTURE_ENV, GL_TEXTURE_ENV_MODE, &env);
    if (env != GL_MODULATE) return false;
    // copy2D reads textures back with glGetTexImage(GL_RGBA), which reproduces only
    // RGB and RGBA. Measured on this driver: alpha-only reads back (0,0,0,A), and
    // luminance, luminance-alpha and intensity read back red-only, none of which
    // MODULATE would match.
    GLint saved, r = 0, l = 0, i = 0; glGetIntegerv(GL_TEXTURE_BINDING_2D, &saved);
    real_glBindTexture(GL_TEXTURE_2D, boundTex);
    glGetTexLevelParameteriv(GL_TEXTURE_2D, 0, GL_TEXTURE_RED_SIZE, &r);
    glGetTexLevelParameteriv(GL_TEXTURE_2D, 0, GL_TEXTURE_LUMINANCE_SIZE, &l);
    glGetTexLevelParameteriv(GL_TEXTURE_2D, 0, GL_TEXTURE_INTENSITY_SIZE, &i);
    real_glBindTexture(GL_TEXTURE_2D, saved);
    return r && !l && !i;
}

// Odd triangles swap their first two vertices so every triangle keeps the strip's winding.
template <typename T> static void stripToTris(const std::vector<T> &s, std::vector<T> &out)
{
    for (size_t i = 2; i < s.size(); i++) {
        if (i % 2 == 0) { out.push_back(s[i - 2]); out.push_back(s[i - 1]); out.push_back(s[i]); }
        else            { out.push_back(s[i - 1]); out.push_back(s[i - 2]); out.push_back(s[i]); }
    }
}

extern "C" void glBegin(GLenum mode) { gMode = mode; gStrip.clear(); if (gRecording && mode != GL_TRIANGLE_STRIP) gUnsupported++; real_glBegin(mode); }
extern "C" void glTexCoord2f(GLfloat s, GLfloat t) { gUV = simd_make_float2(s, t); real_glTexCoord2f(s, t); }
extern "C" void glTexCoord2fv(const GLfloat *t) { gUV = simd_make_float2(t[0], t[1]); real_glTexCoord2fv(t); }
// A list that sets its own colour would be replayed with the call-time colour instead.
static void noteListColour() { if (gCompiling) gLists[gCompiling].unreplayable = true; }
extern "C" void glColor3f(GLfloat r, GLfloat g, GLfloat b) { noteListColour(); gColor = simd_make_float4(r, g, b, 1); real_glColor3f(r, g, b); }
extern "C" void glColor3fv(const GLfloat *c) { noteListColour(); gColor = simd_make_float4(c[0], c[1], c[2], 1); real_glColor3fv(c); }
extern "C" void glColor4f(GLfloat r, GLfloat g, GLfloat b, GLfloat a) { noteListColour(); gColor = simd_make_float4(r, g, b, a); real_glColor4f(r, g, b, a); }
extern "C" void glColor4fv(const GLfloat *c) { noteListColour(); gColor = simd_make_float4(c[0], c[1], c[2], c[3]); real_glColor4fv(c); }
extern "C" void glVertex3f(GLfloat x, GLfloat y, GLfloat z) { gStrip.push_back({simd_make_float3(x, y, z), gUV, gColor}); real_glVertex3f(x, y, z); }
extern "C" void glVertex3fv(const GLfloat *v) { gStrip.push_back({simd_make_float3(v[0], v[1], v[2]), gUV, gColor}); real_glVertex3fv(v); }
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
    if (gCompiling) { gLists[gCompiling].strips.push_back(gStrip); return; }
    if (!gRecording || gMode != GL_TRIANGLE_STRIP) return;
    Batch b; b.st = snap();
    GLhandleARB prog = glGetHandleARB(GL_PROGRAM_OBJECT_ARB);
    b.kind = prog == tunnelProgram && prog ? DrawKind::Tunnel : DrawKind::Immediate;
    GLint active, tex; glGetIntegerv(GL_ACTIVE_TEXTURE, &active);
    glActiveTexture(GL_TEXTURE0); glGetIntegerv(GL_TEXTURE_BINDING_2D, &tex); b.tex = (GLuint)tex;
    glActiveTexture(GL_TEXTURE1); glGetIntegerv(GL_TEXTURE_BINDING_2D, &tex); b.tex1 = (GLuint)tex;
    glActiveTexture(active);
    bool supported = b.kind == DrawKind::Tunnel ? blendSupported() : fixedFunctionSupported(b.tex);
    if (!supported) { gUnsupported++; return; }
    stripToTris(gStrip, b.tri);
    gBatches.push_back(std::move(b));
}
// Display lists are recorded when compiled -- every strip in them -- and expanded
// when called with the current colour. A list that sets its own colour or binds
// more than one texture is refused. Other state a list changes (glEnable,
// glBlendFunc) is not intercepted and would go unnoticed; Hyperspace's lists
// change none.
extern "C" void glNewList(GLuint list, GLenum mode) { if (mode == GL_COMPILE) gCompiling = list; real_glNewList(list, mode); }
extern "C" void glEndList(void) { gCompiling = 0; real_glEndList(); }
extern "C" void glCallList(GLuint list)
{
    auto it = gLists.find(list);
    if (gRecording && it != gLists.end()) {
        Batch b; b.kind = DrawKind::Immediate; b.st = snap();
        GLint cur; glGetIntegerv(GL_TEXTURE_BINDING_2D, &cur);
        b.tex = it->second.hasTex ? it->second.tex : (GLuint)cur;
        if (it->second.unreplayable || !fixedFunctionSupported(b.tex)) gUnsupported++;
        else {
            for (std::vector<Vtx> s : it->second.strips) {
                for (auto &v : s) v.c = b.st.color;
                stripToTris(s, b.tri);
            }
            gBatches.push_back(std::move(b));
        }
    } else if (gRecording) gUnsupported++;
    real_glCallList(list);
}
// impSurface builds with USE_TRIANGLE_STRIPS 0 and VBOs on, so goo arrives as one
// glDrawElements(GL_TRIANGLES, n, GL_UNSIGNED_INT, offset) per surface.
extern "C" void glMultiDrawElements(GLenum mode, const GLsizei *count, GLenum type, const GLvoid *const *offsets, GLsizei n)
{
    if (gRecording) gUnsupported++;
    real_glMultiDrawElements(mode, count, type, offsets, n);
}
extern "C" void glDrawElements(GLenum mode, GLsizei count, GLenum type, const GLvoid *idx)
{
    if (gRecording) {
        GLhandleARB prog = glGetHandleARB(GL_PROGRAM_OBJECT_ARB);
        GLint ab, eb; glGetIntegerv(GL_ARRAY_BUFFER_BINDING, &ab); glGetIntegerv(GL_ELEMENT_ARRAY_BUFFER_BINDING, &eb);
        if (prog != gooProgram || !prog || mode != GL_TRIANGLES || type != GL_UNSIGNED_INT || !ab || !eb || !blendSupported()) gUnsupported++;
        else if (count > 0) {
            Batch b; b.kind = DrawKind::Goo; b.st = snap();
            GLint asz; glGetBufferParameteriv(GL_ARRAY_BUFFER, GL_BUFFER_SIZE, &asz);
            b.gooVerts.resize(asz / sizeof(float));
            glGetBufferSubData(GL_ARRAY_BUFFER, 0, asz, b.gooVerts.data());
            b.gooTri.resize(count);
            glGetBufferSubData(GL_ELEMENT_ARRAY_BUFFER, (GLintptr)idx, count * sizeof(uint32_t), b.gooTri.data());
            GLint active; glGetIntegerv(GL_ACTIVE_TEXTURE, &active);
            for (int u = 0; u < 3; u++) {
                glActiveTexture(GL_TEXTURE0 + u);
                GLint t; glGetIntegerv(GL_TEXTURE_BINDING_CUBE_MAP, &t); b.cube[u] = (GLuint)t;
            }
            glActiveTexture(active);
            gBatches.push_back(std::move(b));
        }
    }
    real_glDrawElements(mode, count, type, idx);
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
};
static const Pass kPasses[] = {
    // 60 s; stars are tiny, so the lit-pixel normalisation matters most here.
    {"stars",  "FixedFunction.metal", "ff_vertex",     "ff_fragment",     false, false, 3600, 300, 1.0, 0.1, 0.06},
    // 60 s; faithful worst 5.28% / 1.35% / bias 0.012, weakest defect bias 0.357.
    {"goo",    "Goo.metal",           "goo_vertex",    "goo_fragment",    true,  false, 3600, 300, 8.0, 2.5, 0.06},
    // 2 min: one minute rarely puts the camera inside a tunnel. Faithful worst
    // 1.50% / 0.28% / 0.012; weakest defects 4.81% / bias 0.197 and 3.92% / 0.220.
    {"tunnel", "Tunnel.metal",        "tunnel_vertex", "tunnel_fragment", false, true,  7200, 200, 3.0, 0.6, 0.06},
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

static NSString *readFile(NSString *path)
{
    NSString *s = [NSString stringWithContentsOfFile:path encoding:NSUTF8StringEncoding error:nil];
    if (!s) printf("ERROR cannot read %s\n", path.UTF8String);
    return s;
}

int main(int argc, const char *argv[])
{
    @autoreleasepool {
        if (argc < 4) {
            fprintf(stderr, "usage: parity <stars|goo|tunnel> <metal-dir> <outdir> [shader=PATH] [frames=N] [every=N] [w=N] [h=N]\n");
            return 2;
        }
        const Pass *pass = nullptr;
        for (const Pass &p : kPasses) if (!strcmp(argv[1], p.name)) pass = &p;
        if (!pass) { fprintf(stderr, "unknown pass %s\n", argv[1]); return 2; }
        NSString *metalDir = @(argv[2]), *outdir = @(argv[3]);
        NSString *shaderPath = [metalDir stringByAppendingPathComponent:@(pass->file)];
        int frames = pass->frames, every = pass->every, w = 1280, h = 720;
        auto intOpt = [](const char *arg, const char *key, int &out) {
            size_t n = strlen(key);
            if (strncmp(arg, key, n)) return false;
            char *end; long v = strtol(arg + n, &end, 10);
            if (end == arg + n || *end || v < 1 || v > 1000000) { fprintf(stderr, "bad value in %s\n", arg); exit(2); }
            out = (int)v; return true;
        };
        for (int i = 4; i < argc; i++) {
            if (!strncmp(argv[i], "shader=", 7) && argv[i][7]) shaderPath = @(argv[i] + 7);
            else if (intOpt(argv[i], "frames=", frames) || intOpt(argv[i], "every=", every) ||
                     intOpt(argv[i], "w=", w) || intOpt(argv[i], "h=", h)) {}
            else { fprintf(stderr, "bad option %s\n", argv[i]); return 2; }
        }
        [[NSFileManager defaultManager] createDirectoryAtPath:outdir withIntermediateDirectories:YES attributes:nil error:nil];
        const float dt = 1.0f / 60.0f;

        // Two libraries, each with the interface prepended: the fixed-function path
        // (always needed -- stars draw in every pass) and the judged pass's shader.
        NSString *iface = readFile([metalDir stringByAppendingPathComponent:@"Interface.metal"]);
        bool starsPass = !strcmp(pass->name, "stars");
        NSString *ffPath = starsPass ? shaderPath : [metalDir stringByAppendingPathComponent:@"FixedFunction.metal"];
        NSString *ffSrc = readFile(ffPath), *passSrc = starsPass ? ffSrc : readFile(shaderPath);
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
        id<MTLRenderPipelineState> passPS = starsPass ? ffPS : pipeline(passSrc, shaderPath, pass->vfn, pass->ffn);
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
        initSaver(&s);
        printf("renderer: %s\n", glGetString(GL_RENDERER));
        printf("config: pass=%s seed=%ld goo=%d tunnels=%d shaders=%d %dx%d frames=%d every=%d shader=%s\n",
               pass->name, (long)gSeed, s.dUseGoo, s.dUseTunnels, s.dShaders, w, h, frames, every, shaderPath.UTF8String);

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
            GLint minF, magF, ws, wt;
            glGetTexParameteriv(tgt, GL_TEXTURE_MIN_FILTER, &minF); glGetTexParameteriv(tgt, GL_TEXTURE_MAG_FILTER, &magF);
            glGetTexParameteriv(tgt, GL_TEXTURE_WRAP_S, &ws); glGetTexParameteriv(tgt, GL_TEXTURE_WRAP_T, &wt);
            MTLSamplerDescriptor *sd = [MTLSamplerDescriptor new];
            sd.minFilter = mmf(minF); sd.magFilter = mmf(magF); sd.mipFilter = mipf(minF);
            sd.sAddressMode = addr(ws); sd.tAddressMode = addr(wt); sd.rAddressMode = addr(wt);
            return [dev newSamplerStateWithDescriptor:sd];
        };
        // Textures are copied out of GL with every mip level it holds, so neither
        // texture generation nor mip generation can differ between the two sides.
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

        for (int f = 0; f < frames; f++) {
            bool shot = f > 0 && (f % every == 0 || f == frames - 1);
            gRecording = shot; gBatches.clear(); gUnsupported = 0;
            s.frameTime = dt;
            draw(&s);
            glFinish();
            gRecording = false;
            if (!shot) continue;

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
                    judged += !strcmp(pass->name, "goo");
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
                    judged += starsPass;
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
            bool shotOk = p2 <= pass->max2 && p8 <= pass->max8 && bias <= pass->maxBias && gUnsupported == 0;
            ok &= shotOk; shots++; judgedTotal += judged;
            worst2 = MAX(worst2, p2); worst8 = MAX(worst8, p8); worstBias = MAX(worstBias, bias);
            printf("%5d  %12d  %3d  %5.2f  %6.2f  %6.2f  %5.3f  %s%s\n", f, judged, maxd, 100.0 * lit / npx, p2, p8, bias,
                   shotOk ? "ok" : "FAIL", gUnsupported ? " (unrecorded GL draw calls)" : "");
            NSString *base = [outdir stringByAppendingPathComponent:[NSString stringWithFormat:@"%05d", f]];
            writePNG([base stringByAppendingString:@"_gl.png"], glflip.data(), w, h);
            writePNG([base stringByAppendingString:@"_metal.png"], mtl.data(), w, h);
            writePNG([base stringByAppendingString:@"_diffx8.png"], heat.data(), w, h);
        }
        // A pass that drew nothing would compare black with black and pass.
        if (judgedTotal == 0) { printf("ERROR the %s pass drew nothing in any shot; nothing was compared\n", pass->name); return 2; }
        printf("%s pass=%s shots=%d worst_lit>2=%.2f%% worst_lit>8=%.2f%% worst_bias=%.3f (limits %.2f%% / %.2f%% / %.3f)\n",
               ok ? "PASS" : "FAIL", pass->name, shots, worst2, worst8, worstBias, pass->max2, pass->max8, pass->maxBias);
        return ok ? 0 : 1;
    }
}
