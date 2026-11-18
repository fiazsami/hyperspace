// GL -> Metal parity for Hyperspace.
//
// Runs the unmodified saver offscreen, deterministically, through one renderer
// and writes a PNG every few frames. One pass per run:
//
//   stars   goo and tunnels off: stars and lens flares
//   goo     goo on
//   tunnel  tunnels on
//   burst   goo on, with a starburst set off at 1 s
//   sun     the stars pass with the sun held in view
//
//   parity <pass> <metal-dir> <outdir> [renderer=metal] [frames=N] [every=N|shots=N] [w=N] [h=N] [samples=N] [tunneldetail=N]
//          [look=saver] [time]
//
// shots=N shoots every frames/N frames, so a caller that wants N shots of a
// pass need not know its length (parity/goldencheck.sh). samples=N is the
// backend's samples per pixel, 1 unless given: GL draws aliased, so the
// backend is judged against it at 1, and against its goldens at the saver's 4.
// look=saver draws with the backend's own settings, as the saver does, in
// place of parity's GL-faithful ones (samples, tunneldetail, and the goo
// sharp): the same words mean "as the saver draws" at every commit, which is
// what parity/refcheck.sh compares two commits by. time prints the backend's
// GPU milliseconds a frame and the drawing thread's CPU milliseconds, median and
// 95th percentile, and the whole process's CPU milliseconds a frame, user and
// system, as a mean (getrusage): Metal's driver threads and the kernel's work
// submitting each frame cost several times the drawing thread itself (0.14
// against 0.027 ms a frame for the goo, measured), and a quiet saver is the total. The
// first 30 frames are left out (pipelines and buffers warming up), and so is
// the CPU spent reading back and writing shots, which the saver does not do.
// tunneldetail=N is how much finer the backend builds the tunnel
// (HSRendererMetal::setTunnelDetail), likewise 1 unless given, as GL builds,
// and the saver's 2 for the goldens.
//
// Plain, it draws through HSRendererGL and writes <outdir>/NNNNN_gl.png.
// renderer=metal draws through HSRendererMetal, compiled from <metal-dir>, and
// writes NNNNN_backend.png; a shot in which anything still drew through GL is
// an error, and so is a goo or tunnel pass whose goo or tunnel never drew.
// A plain run does not read <metal-dir>: it stays in the usage so that
// seamcheck.sh can run older parity builds, which did, with the same arguments. Both share the seed, so they draw the same frames, and
// `parity --compare-backend <pass> <gl-dir> <backend-dir>` judges one against the
// other under the pass's rules (parity/backendcheck.sh). `parity --compare` judges
// two GL runs against each other (parity/seamcheck.sh), and `parity --compare-golden`
// a backend run against approved backend images (parity/goldencheck.sh). `--backend-textures` and
// `--backend-caustics` check texture uploads and the offscreen target directly.
// Exit 0 = written (or PASS), 1 = FAIL, 2 = a run or setup error.
//
// Apart from --compare-golden, nothing here is a golden image: both renderers draw
// the same frame in the same process, so the reference is always the shipped
// renderer on this machine. The
// rules below were calibrated on one machine (Apple M5 Max, macOS 26); see
// parity/README.md for the measurements and for what a different GPU may need.

#import <Cocoa/Cocoa.h>
#import <OpenGL/gl.h>
#import <OpenGL/glext.h>
#import <Metal/Metal.h>
#import <ImageIO/ImageIO.h>
#include <dlfcn.h>
#include <sys/resource.h>
#include <ctime>
#include <vector>
#include <algorithm>
#include "Hyperspace.h"
#include "splinePath.h"
#include "starBurst.h"
#include "transform.h"
#include "rendererGL.h"
#include "causticTextures.h"
#include "rendererMetal.h"

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

// HSRendererGL::beginOffscreen selects GL_BACK to read the caustics from,
// which is an INVALID_OPERATION under parity's FBO. Both read and draw stay on
// its color attachment, so skipping the call reads what was drawn -- and keeps
// every other GL error an error.
static void (*real_glReadBuffer)(GLenum) = (void (*)(GLenum))dlsym(RTLD_NEXT, "glReadBuffer");
extern "C" void glReadBuffer(GLenum mode)
{
    GLint fbo = 0; glGetIntegerv(GL_FRAMEBUFFER_BINDING_EXT, &fbo);
    if (fbo && mode == GL_BACK) return;
    real_glReadBuffer(mode);
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
// parity/backendcheck.sh re-proves the separation. Measurements: parity/README.md.

struct Pass {
    const char *name;
    bool goo, tunnels; int frames, every;
    double max2, max8, maxBias;
    int burstAt;   // frame at which to set off the starburst; 0 leaves it to the saver's timer
    float sunAhead;   // distance ahead of the camera to hold the sun at; 0 leaves it where the saver puts it
    bool softGoo;     // the backend draws the goo soft, as the saver does (HSRendererMetal::setSoftGoo)
    int block;        // >1: both images averaged over block x block pixels before they are compared
};
static const Pass kPasses[] = {
    // 60 s; stars are tiny, so the lit-pixel normalization matters most here.
    {"stars",  false, false, 3600, 300, 1.0, 0.1, 0.06, 0},
    // 60 s; faithful worst 5.28% / 1.35% / bias 0.012, weakest defect bias 0.357.
    {"goo",    true,  false, 3600, 300, 8.0, 2.5, 0.06, 0},
    // 2 min: one minute rarely puts the camera inside a tunnel. Faithful worst
    // 1.50% / 0.28% / 0.012; weakest defects 4.81% / bias 0.197 and 3.92% / 0.220.
    {"tunnel", false, true,  7200, 200, 3.0, 0.6, 0.06, 0},
    // 8 s with a starburst set off at 1 s; the saver's own timer would wait five
    // minutes. Goo is on, as the saver's default is, because the sphere shares
    // the goo's program and textures. The goo pass's limits.
    {"burst",  true,  false, 480,  30,  8.0, 2.5, 0.06, 60},
    // 20 s of the stars pass with the sun held 12 units ahead of the camera. Where
    // the saver puts it, at (0, 2, 0), no stars-pass shot has it in frame: the path
    // leaves it behind or off to the side at every one. 12 is past the fog's end
    // (depth, 9.8 by default), as the saver's sun usually is, so a sun drawn with
    // fog on comes out black. The stars pass's limits. Its lens flare
    // stays at (0, 2, 0): drawn on the sun, its core hides it.
    {"sun",    false, false, 1200, 100, 1.0, 0.1, 0.06, 0, 12.0f},
    // The goo pass with the backend's goo soft, as the saver draws it, against
    // GL's sharp goo, both averaged over 16x16 blocks: softening moves light
    // a few pixels, which blocks that size mostly absorb, while goo drawn in
    // the wrong place still shows. Measured at resolution 20, worst shot:
    // faithful 34.2% / 4.48% / bias 0.665; drawn two pixels off 62.9% / 25.5%
    // / 0.801; upside down 98.6% / 96.3% / 0.586 (brightness alone passes
    // both); the tent divided by 15, bias 7.231; never added back, 121.6.
    {"goosoft", true, false, 3600, 300, 50.0, 12.0, 2.0, 0, 0.0f, true, 16},
};

static void writePNG(NSString *path, const uint8_t *rgba, int w, int h)
{
    CGColorSpaceRef cs = CGColorSpaceCreateDeviceRGB();
    CGContextRef bc = CGBitmapContextCreate((void *)rgba, w, h, 8, (size_t)w * 4, cs, (CGBitmapInfo)kCGImageAlphaNoneSkipLast);
    CGImageRef img = CGBitmapContextCreateImage(bc);
    CGImageDestinationRef dst = CGImageDestinationCreateWithURL((__bridge CFURLRef)[NSURL fileURLWithPath:path], CFSTR("public.png"), 1, NULL);
    CGImageDestinationAddImage(dst, img, NULL); CGImageDestinationFinalize(dst);
    CFRelease(dst); CGImageRelease(img); CGContextRelease(bc); CGColorSpaceRelease(cs);
}

static std::vector<uint8_t> readPNG(NSString *path, int &w, int &h)
{
    std::vector<uint8_t> px;
    CGImageSourceRef src = CGImageSourceCreateWithURL((__bridge CFURLRef)[NSURL fileURLWithPath:path], NULL);
    CGImageRef img = src ? CGImageSourceCreateImageAtIndex(src, 0, NULL) : NULL;
    // The decoded bytes as stored, not drawn into a context: drawing converts
    // from the file's colour profile, and goldens (--compare-golden) are read
    // on machines other than the one that wrote them. writePNG writes 8-bit
    // RGB or RGBX; anything else is refused rather than guessed at.
    if (img) {
        w = (int)CGImageGetWidth(img); h = (int)CGImageGetHeight(img);
        size_t bpp = CGImageGetBitsPerPixel(img), bpr = CGImageGetBytesPerRow(img);
        CGImageAlphaInfo alpha = CGImageGetAlphaInfo(img);
        CGBitmapInfo order = CGImageGetBitmapInfo(img) & kCGBitmapByteOrderMask;
        bool rgbFirst = order == kCGBitmapByteOrderDefault || order == kCGBitmapByteOrder32Big;
        bool rgb = bpp == 24 ? alpha == kCGImageAlphaNone
                 : bpp == 32 && rgbFirst && (alpha == kCGImageAlphaNoneSkipLast || alpha == kCGImageAlphaLast ||
                                             alpha == kCGImageAlphaPremultipliedLast);
        CFDataRef data = (CGImageGetBitsPerComponent(img) == 8 && rgb)
            ? CGDataProviderCopyData(CGImageGetDataProvider(img)) : NULL;
        if (data && (size_t)CFDataGetLength(data) >= bpr * h) {
            const uint8_t *in = CFDataGetBytePtr(data);
            px.resize((size_t)w * h * 4);
            for (int y = 0; y < h; y++)
                for (int x = 0; x < w; x++) {
                    const uint8_t *s = in + y * bpr + x * (bpp / 8);
                    uint8_t *d = &px[((size_t)y * w + x) * 4];
                    d[0] = s[0]; d[1] = s[1]; d[2] = s[2]; d[3] = 255;
                }
        }
        if (data) CFRelease(data);
        CGImageRelease(img);
    }
    if (src) CFRelease(src);
    if (px.empty()) w = h = 0;   // callers read empty as missing
    return px;
}

// The mean of each whole block x block square of an RGBA image, rounded; a
// partial block at the right or bottom edge is dropped.
static std::vector<uint8_t> blockMean(const std::vector<uint8_t> &img, int &w, int &h, int block)
{
    const int bw = w / block, bh = h / block;
    std::vector<uint8_t> out((size_t)bw * bh * 4);
    for (int by = 0; by < bh; by++)
        for (int bx = 0; bx < bw; bx++)
            for (int c = 0; c < 4; c++) {
                int sum = 0;
                for (int y = 0; y < block; y++)
                    for (int x = 0; x < block; x++)
                        sum += img[((size_t)(by * block + y) * w + bx * block + x) * 4 + c];
                out[((size_t)by * bw + bx) * 4 + c] = (uint8_t)((sum + block * block / 2) / (block * block));
            }
    w = bw; h = bh;
    return out;
}

// parity --compare <ref-dir> <new-dir>: the GL images of two runs of the same pass,
// shot by shot (parity/seamcheck.sh). Both sides are the GL renderer, so nothing
// here is a translation residual: the rule is the tightest any pass uses.
// parity --compare-backend compares one run's GL images with another's
// _backend.png (renderer=metal), under the pass's rules. parity --compare-golden
// compares approved _backend.png images (parity/golden/<pass>) with a new run's,
// under --compare's rule: the backend draws the same bytes run to run on one
// machine, so anything past that rule is a change in the picture. Either way a shot
// missing from either side is an error, and a shot outside the rule writes
// <new-dir>/NNNNN_diffx8.png: the per-pixel difference, times 8. A pass with
// block > 1 compares block means, and its diff is of those: NNNNN_diffx8_blockN.png,
// one pixel a block.
// The frames two runs shot (NNNNN, sorted), or nil after printing why: a side
// unreadable, empty, or with frames the other lacks.
static NSArray<NSString *> *sameShots(NSString *refDir, NSString *refSuffix, NSString *newDir, NSString *newSuffix)
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
    NSArray<NSString *> *names = shots(refDir, refSuffix), *newNames = shots(newDir, newSuffix);
    if (!names || !newNames) return nil;
    if (![names isEqualToArray:newNames]) {
        NSMutableSet *onlyRef = [NSMutableSet setWithArray:names], *onlyNew = [NSMutableSet setWithArray:newNames];
        [onlyRef minusSet:[NSSet setWithArray:newNames]]; [onlyNew minusSet:[NSSet setWithArray:names]];
        printf("ERROR the two runs shot different frames: only in ref %s; only in new %s\n",
               [[onlyRef.allObjects componentsJoinedByString:@" "] UTF8String], [[onlyNew.allObjects componentsJoinedByString:@" "] UTF8String]);
        return nil;
    }
    return names;
}

static int compareRuns(NSString *refDir, NSString *refSuffix, NSString *newDir, NSString *newSuffix,
                       double max2, double max8, double maxBias, const char *same, const char *different,
                       int block = 1)
{
    NSArray<NSString *> *names = sameShots(refDir, refSuffix, newDir, newSuffix);
    if (!names) return 2;
    bool ok = true; double worst2 = 0, worst8 = 0, worstBias = 0; int worstMax = 0;
    for (NSString *n in names) {
        int rw = 0, rh = 0, nw = 0, nh = 0;
        std::vector<uint8_t> a = readPNG([refDir stringByAppendingPathComponent:[n stringByAppendingString:refSuffix]], rw, rh);
        std::vector<uint8_t> b = readPNG([newDir stringByAppendingPathComponent:[n stringByAppendingString:newSuffix]], nw, nh);
        if (a.empty() || b.empty() || rw != nw || rh != nh) { printf("ERROR %s missing or a different size\n", n.UTF8String); return 2; }
        if (block > 1) {
            if (rw < block || rh < block) { printf("ERROR %s is %dx%d, smaller than one %d-pixel block\n", n.UTF8String, rw, rh, block); return 2; }
            a = blockMean(a, rw, rh, block); b = blockMean(b, nw, nh, block);
        }
        size_t lit = 0, l2 = 0, l8 = 0; int maxd = 0; double sb[3] = {0, 0, 0};
        std::vector<uint8_t> heat((size_t)rw * rh * 4);
        for (size_t i = 0; i < (size_t)rw * rh; i++) {
            int pm = 0; bool isLit = false;
            for (int c = 0; c < 3; c++) {
                int d = abs((int)a[i * 4 + c] - (int)b[i * 4 + c]); pm = MAX(pm, d);
                isLit |= a[i * 4 + c] > 8 || b[i * 4 + c] > 8;
            }
            maxd = MAX(maxd, pm);
            heat[i * 4] = heat[i * 4 + 1] = heat[i * 4 + 2] = (uint8_t)MIN(255, pm * 8); heat[i * 4 + 3] = 255;
            if (isLit) { lit++; l2 += pm > 2; l8 += pm > 8; for (int c = 0; c < 3; c++) sb[c] += (int)b[i * 4 + c] - (int)a[i * 4 + c]; }
        }
        double bias = 0; for (int c = 0; c < 3; c++) bias = MAX(bias, fabs(sb[c] / MAX((size_t)1, lit)));
        double p2 = lit ? 100.0 * l2 / lit : 0, p8 = lit ? 100.0 * l8 / lit : 0;
        bool shotOk = p2 <= max2 && p8 <= max8 && bias <= maxBias;
        ok &= shotOk; worst2 = MAX(worst2, p2); worst8 = MAX(worst8, p8); worstBias = MAX(worstBias, bias); worstMax = MAX(worstMax, maxd);
        printf("%s  max %3d  lit>2 %6.3f%%  lit>8 %6.3f%%  bias %5.3f  %s\n", n.UTF8String, maxd, p2, p8, bias, shotOk ? "ok" : "FAIL");
        if (!shotOk) writePNG([newDir stringByAppendingPathComponent:[n stringByAppendingString:
                                  block > 1 ? [NSString stringWithFormat:@"_diffx8_block%d.png", block] : @"_diffx8.png"]], heat.data(), rw, rh);
    }
    printf("%s shots=%lu worst_max=%d worst_lit>2=%.3f%% worst_lit>8=%.3f%% worst_bias=%.3f (limits %.2f%% / %.2f%% / %.3f)\n",
           ok ? same : different, (unsigned long)names.count, worstMax, worst2, worst8, worstBias, max2, max8, maxBias);
    return ok ? 0 : 1;
}

// A process's user and system CPU, in seconds.
static double cpuSeconds(const rusage &u)
{
    return u.ru_utime.tv_sec + u.ru_utime.tv_usec / 1e6 + u.ru_stime.tv_sec + u.ru_stime.tv_usec / 1e6;
}

// parity --compare-look <ref-dir> <new-dir>: two backend runs' _backend.png,
// shot by shot, by what a change of look must keep (parity/refcheck.sh):
//   mid-tones  pixels whose reference luminance is 16-200 move by a mean of at
//              most 2 levels, and 99% of them by at most 8; and no colour
//              channel of theirs by a mean of more than 3 (luminance alone
//              would pass a change of hue that kept brightness);
//   highlights pixels over 200 are not judged one by one, on purpose: they
//              are what a tone curve exists to change. Their clipping is
//              reported; the brightness rule below still sees them;
//   blacks     pixels whose reference luminance is under 16 rise by a mean of
//              at most 2 levels, and at most 1% of them by more than 4 (a
//              haze over the background, or light where there was none: the
//              share catches a faint one over part of a frame, which the
//              mean, over a mostly black frame, would dilute). Only rises
//              count, so pixels that darkened cannot cancel a haze;
//   brightness no shot's mean luminance falls by more than 2%.
// It also reports the pixels clipped (any channel 255) on each side, which a
// change meant to soften highlights should lower; whether it must is the
// caller's rule, not this one's. Luminance is Rec. 709 on the stored bytes.
// Exit 0 = KEPT, 1 = CHANGED, 2 = a shot missing or a different size.
static int compareLook(NSString *refDir, NSString *newDir)
{
    NSArray<NSString *> *frames = sameShots(refDir, @"_backend.png", newDir, @"_backend.png");
    if (!frames) return 2;
    NSMutableArray<NSString *> *names = [NSMutableArray array];
    for (NSString *f in frames) [names addObject:[f stringByAppendingString:@"_backend.png"]];
    bool kept = true; double worstMean = 0, worstHue = 0, worstRise = 0, worstLit = 0, worstDark = 0; int worstP99 = 0; size_t clipRef = 0, clipNew = 0, total = 0;
    for (NSString *n in names) {
        int rw = 0, rh = 0, nw = 0, nh = 0;
        std::vector<uint8_t> a = readPNG([refDir stringByAppendingPathComponent:n], rw, rh);
        std::vector<uint8_t> b = readPNG([newDir stringByAppendingPathComponent:n], nw, nh);
        if (a.empty() || b.empty() || rw != nw || rh != nh) { printf("ERROR %s missing or a different size\n", n.UTF8String); return 2; }
        size_t hist[256] = {0}, mids = 0, darks = 0, lit = 0, cr = 0, cn = 0; double chan[3] = {0, 0, 0}; double sumD = 0, lift = 0, lumA = 0, lumB = 0;
        for (size_t i = 0; i < (size_t)rw * rh; i++) {
            const uint8_t *p = &a[i * 4], *q = &b[i * 4];
            double la = 0.2126 * p[0] + 0.7152 * p[1] + 0.0722 * p[2], lb = 0.2126 * q[0] + 0.7152 * q[1] + 0.0722 * q[2];
            lumA += la; lumB += lb;
            cr += p[0] == 255 || p[1] == 255 || p[2] == 255;
            cn += q[0] == 255 || q[1] == 255 || q[2] == 255;
            if (la < 16) { lift += MAX(0.0, lb - la); darks++; lit += lb - la > 4; }
            else if (la <= 200) {
                // Ceiling, so "at most 8" means at most 8.0, not 8.49.
                int d = (int)ceil(fabs(lb - la)); hist[MIN(d, 255)]++; sumD += fabs(lb - la); mids++;
                for (int c = 0; c < 3; c++) chan[c] += fabs(double(q[c]) - p[c]);
            }
        }
        int p99 = 0;
        for (size_t c = 0, need = (size_t)ceil(0.99 * mids); p99 < 255 && (c += hist[p99]) < need; p99++) {}
        double mean = mids ? sumD / mids : 0, dark = lumA > 0 ? 100.0 * (lumA - lumB) / lumA : 0, rise = darks ? lift / darks : 0,
               litShare = darks ? 100.0 * lit / darks : 0;
        const double hue = mids ? MAX(chan[0], MAX(chan[1], chan[2])) / mids : 0;
        bool ok = mean <= 2.0 && p99 <= 8 && hue <= 3.0 && rise <= 2.0 && litShare <= 1.0 && dark <= 2.0;
        kept &= ok; worstMean = MAX(worstMean, mean); worstHue = MAX(worstHue, hue); worstRise = MAX(worstRise, rise); worstLit = MAX(worstLit, litShare); worstP99 = MAX(worstP99, mids ? p99 : 0); worstDark = MAX(worstDark, dark);
        clipRef += cr; clipNew += cn; total += (size_t)rw * rh;
        printf("%s  mid mean %5.2f p99 %3d colour %5.2f  blacks %+5.2f lit %5.2f%%  darker %6.2f%%  clipped %6.3f%% -> %6.3f%%  %s\n", n.UTF8String, mean, mids ? p99 : 0, hue,
               rise, litShare, dark, 100.0 * cr / ((size_t)rw * rh), 100.0 * cn / ((size_t)rw * rh), ok ? "ok" : "CHANGED");
    }
    printf("%s shots=%lu worst_mid_mean=%.2f worst_mid_p99=%d worst_mid_colour=%.2f worst_black_rise=%.2f worst_black_lit=%.2f%% worst_darker=%.2f%% clipped=%.3f%%->%.3f%% (limits 2 / 8 / 3 / 2 / 1%% / 2%%)\n",
           kept ? "KEPT" : "CHANGED", (unsigned long)names.count, worstMean, worstP99, worstHue, worstRise, worstLit, worstDark,
           100.0 * clipRef / total, 100.0 * clipNew / total);
    return kept ? 0 : 1;
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
    if (!dev) { printf("ERROR no Metal device\n"); return 2; }
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
    if (!dev) { printf("ERROR no Metal device\n"); return 2; }
    HSRendererGL gl;
    HSRendererMetal metal((__bridge void *)dev, metalDir.fileSystemRepresentation);
    // Hyperspace.cpp's arguments, with the shaded look's 20 frames.
    causticTextures a(&gl, 8, 20, 100, size, 1.0f, 0.01f, 20.0f);
    GLenum err = glGetError();
    if (err != GL_NO_ERROR) { printf("ERROR GL error 0x%x\n", err); return 2; }
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

int main(int argc, const char *argv[])
{
    @autoreleasepool {
        if (argc == 4 && !strcmp(argv[1], "--compare")) return compareRuns(@(argv[2]), @"_gl.png", @(argv[3]), @"_gl.png", 0.1, 0.01, 0.06, "SAME", "DIFFERENT");
        if (argc == 4 && !strcmp(argv[1], "--compare-look")) return compareLook(@(argv[2]), @(argv[3]));
        if (argc == 4 && !strcmp(argv[1], "--compare-golden"))
            return compareRuns(@(argv[2]), @"_backend.png", @(argv[3]), @"_backend.png", 0.1, 0.01, 0.06, "SAME", "DIFFERENT");
        if (argc == 3 && !strcmp(argv[1], "--backend-textures")) return compareBackendTextures(@(argv[2]));
        if (argc == 3 && !strcmp(argv[1], "--backend-caustics")) return compareBackendCaustics(@(argv[2]));
        if (argc == 5 && !strcmp(argv[1], "--compare-backend")) {
            for (const Pass &p : kPasses)
                if (!strcmp(argv[2], p.name)) return compareRuns(@(argv[3]), @"_gl.png", @(argv[4]), @"_backend.png", p.max2, p.max8, p.maxBias, "PASS", "FAIL", p.block);
            fprintf(stderr, "unknown pass %s\n", argv[2]); return 2;
        }
        if (argc < 4) {
            fprintf(stderr, "usage: parity <stars|goo|tunnel|burst|sun|goosoft> <metal-dir> <outdir> [renderer=metal] [frames=N] [every=N|shots=N] [w=N] [h=N] [samples=N] [tunneldetail=N] [look=saver] [time]\n"
                            "       parity --compare-look <ref-dir> <new-dir>\n"
                            "       parity --compare <ref-dir> <new-dir>\n"
                            "       parity --compare-backend <pass> <gl-dir> <backend-dir>\n"
                            "       parity --compare-golden <golden-dir> <backend-dir>\n"
                            "       parity --backend-textures <metal-dir>\n"
                            "       parity --backend-caustics <metal-dir>\n");
            return 2;
        }
        const Pass *pass = nullptr;
        for (const Pass &p : kPasses) if (!strcmp(argv[1], p.name)) pass = &p;
        if (!pass) { fprintf(stderr, "unknown pass %s\n", argv[1]); return 2; }
        NSString *metalDir = @(argv[2]), *outdir = @(argv[3]);
        int frames = pass->frames, every = pass->every, wantShots = 0, samples = 1, tunnelDetail = 1, w = 1280, h = 720;
        bool backend = false, saverLook = false, timed = false, settingsGiven = false;
        auto intOpt = [](const char *arg, const char *key, int &out) {
            size_t n = strlen(key);
            if (strncmp(arg, key, n)) return false;
            char *end; long v = strtol(arg + n, &end, 10);
            if (end == arg + n || *end || v < 1 || v > 1000000) { fprintf(stderr, "bad value in %s\n", arg); exit(2); }
            out = (int)v; return true;
        };
        for (int i = 4; i < argc; i++) {
            if (!strcmp(argv[i], "renderer=metal")) backend = true;
            else if (!strcmp(argv[i], "look=saver")) saverLook = true;
            else if (!strcmp(argv[i], "time")) timed = true;
            else if (intOpt(argv[i], "frames=", frames) || intOpt(argv[i], "every=", every) || intOpt(argv[i], "shots=", wantShots) ||
                     intOpt(argv[i], "w=", w) || intOpt(argv[i], "h=", h)) {}
            else if (intOpt(argv[i], "samples=", samples) || intOpt(argv[i], "tunneldetail=", tunnelDetail)) settingsGiven = true;
            else { fprintf(stderr, "bad option %s\n", argv[i]); return 2; }
        }
        if (wantShots) every = MAX(1, frames / wantShots);
        if ((saverLook || timed) && !backend) { fprintf(stderr, "look=saver and time are the backend's: add renderer=metal\n"); return 2; }
        if (saverLook && settingsGiven) { fprintf(stderr, "look=saver draws with the backend's own samples and tunneldetail: drop them\n"); return 2; }
        const float dt = 1.0f / 60.0f;
        [[NSFileManager defaultManager] createDirectoryAtPath:outdir withIntermediateDirectories:YES attributes:nil error:nil];

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

        // HyperspaceView.mm's call order. (The caustics' glReadBuffer(GL_BACK) is
        // skipped under the FBO; see glReadBuffer above.)
        static HyperspaceSaverSettings s;
        setDefaults(&s);
        s.dUseGoo = pass->goo; s.dUseTunnels = pass->tunnels;
        // The backend stops on the shaders-off goo and tunnel (ss-5dl); say so
        // here, with the exit code a failed run has.
        if (backend && !s.dShaders && (s.dUseGoo || s.dUseTunnels)) {
            fprintf(stderr, "renderer=metal draws the shaded look only; the shaders-off goo and tunnel are ss-5dl\n"); return 2;
        }
        s.first = 1;
        reshape(w, h, &s);
        glClearColor(0, 0, 0, 0); glClear(GL_COLOR_BUFFER_BIT); glFlush();
        // In backend mode the GL context stays only so that a draw slipping past
        // the backend into GL is counted below rather than crashing.
        HSRendererMetal *metalRenderer = nullptr;
        id<MTLTexture> backendTarget = nil;
        if (backend) {
            id<MTLDevice> dev = MTLCreateSystemDefaultDevice();
            if (!dev) { printf("ERROR no Metal device\n"); return 2; }
            MTLTextureDescriptor *bd = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA8Unorm width:w height:h mipmapped:NO];
            bd.usage = MTLTextureUsageRenderTarget; bd.storageMode = MTLStorageModeShared;
            backendTarget = [dev newTextureWithDescriptor:bd];
            metalRenderer = new HSRendererMetal((__bridge void *)dev, metalDir.fileSystemRepresentation);
            if (!saverLook) {
                metalRenderer->setSampleCount(samples);   // before the target, so the pipelines are built once
                metalRenderer->setTunnelDetail(tunnelDetail);
            }
            metalRenderer->setTarget((__bridge void *)backendTarget);
            if (!saverLook) metalRenderer->setSoftGoo(pass->softGoo);
        }
        HSRenderer *renderer = metalRenderer;
        if (!backend) renderer = new HSRendererGL;
        initSaver(&s, renderer);   // which then owns it
        if (!s.readyToDraw) { printf("ERROR initSaver did not finish\n"); return 2; }
        printf("renderer: %s\n", backend ? "HSRendererMetal" : (const char *)glGetString(GL_RENDERER));
        printf("config: pass=%s seed=%ld goo=%d tunnels=%d shaders=%d %dx%d frames=%d every=%d burst=%d sun=%g%s%s\n",
               pass->name, (long)gSeed, s.dUseGoo, s.dUseTunnels, s.dShaders, w, h, frames, every, pass->burstAt, pass->sunAhead,
               backend ? " metal=" : "", backend ? metalDir.UTF8String : "");

        size_t npx = (size_t)w * h;
        std::vector<uint8_t> px(npx * 4), flip(npx * 4);
        const char *judgedKind = pass->goo ? "goo" : pass->tunnels ? "tunnel" : "all";
        if (backend) printf(" shot  backend draws (%s)\n", judgedKind); else printf(" shot  GL primitives\n");
        int shots = 0; long drawnTotal = 0;
        std::vector<double> gpuMs, cpuMs;   // time's, a frame each after the warm-up
        long timedDraws = 0;                 // the pass's own draws over every timed frame
        const int warmup = 30;
        rusage usage0 = {};
        double shotCpuSeconds = 0;   // reading back and writing shots, left out of the process figure
        // Counts every primitive GL generates, whatever entry point drew it.
        GLuint primQuery; glGenQueries(1, &primQuery);

        for (int f = 0; f < frames; f++) {
            bool shot = f > 0 && (f % every == 0 || f == frames - 1);
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
            timespec cpu0, cpu1;
            if (timed && f == warmup) getrusage(RUSAGE_SELF, &usage0);
            if (timed) clock_gettime(CLOCK_THREAD_CPUTIME_ID, &cpu0);
            @autoreleasepool { draw(&s); }
            if (timed) clock_gettime(CLOCK_THREAD_CPUTIME_ID, &cpu1);
            if (timed && f >= warmup) {
                // Thread CPU time leaves out endFrame's wait for the GPU.
                cpuMs.push_back((cpu1.tv_sec - cpu0.tv_sec) * 1e3 + (cpu1.tv_nsec - cpu0.tv_nsec) / 1e6);
                gpuMs.push_back(metalRenderer->lastFrameGPUMilliseconds());
                timedDraws += pass->goo ? metalRenderer->gooDrawCount() : pass->tunnels ? metalRenderer->tunnelDrawCount() : metalRenderer->drawCount();
            }
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
            rusage shot0 = {};   // from here a shot's work is not the saver's
            if (shot && timed) getrusage(RUSAGE_SELF, &shot0);
            if (shot) glEndQuery(GL_PRIMITIVES_GENERATED_EXT);
            // The backend waits for its own frame; GL has nothing to finish
            // there but a shot's query, and its cost is not the saver's.
            if (!backend || shot) glFinish();
            if (!shot) continue;
            auto shotDone = [&] {
                if (!timed || f < warmup) return;
                rusage shot1; getrusage(RUSAGE_SELF, &shot1);
                shotCpuSeconds += cpuSeconds(shot1) - cpuSeconds(shot0);
            };

            GLuint generated = 0; glGetQueryObjectuiv(primQuery, GL_QUERY_RESULT, &generated);
            NSString *base = [outdir stringByAppendingPathComponent:[NSString stringWithFormat:@"%05d", f]];
            shots++;
            if (backend) {
                // Nothing may draw through GL: every draw goes to the backend.
                if (generated) { printf("ERROR frame %d drew through GL in backend mode (%u primitives)\n", f, generated); return 2; }
                [backendTarget getBytes:px.data() bytesPerRow:(size_t)w * 4 fromRegion:MTLRegionMake2D(0, 0, w, h) mipmapLevel:0];
                // The pass's own surface: stars draw in every pass, so the
                // goo or tunnel failing to draw would leave a stars comparison.
                int draws = pass->goo ? metalRenderer->gooDrawCount() : pass->tunnels ? metalRenderer->tunnelDrawCount() : metalRenderer->drawCount();
                drawnTotal += draws;
                printf("%5d  %d of %d\n", f, draws, metalRenderer->drawCount());
                writePNG([base stringByAppendingString:@"_backend.png"], px.data(), w, h);
                shotDone();
                continue;
            }
            // A GL error means some call did not do what the saver assumes it did.
            GLenum glErr = glGetError();
            if (glErr != GL_NO_ERROR) { printf("ERROR GL error 0x%x in frame %d\n", glErr, f); return 2; }
            drawnTotal += generated;
            printf("%5d  %u\n", f, generated);
            glReadPixels(0, 0, w, h, GL_RGBA, GL_UNSIGNED_BYTE, px.data());
            for (int y = 0; y < h; y++) memcpy(&flip[(size_t)y * w * 4], &px[(size_t)(h - 1 - y) * w * 4], (size_t)w * 4);
            writePNG([base stringByAppendingString:@"_gl.png"], flip.data(), w, h);
        }
        // A pass that drew nothing would compare black with black and pass. In
        // backend mode, nothing of the pass's own surface (judgedKind); a GL run
        // counts every primitive, and the backend run it is compared with
        // carries that check. A timed run counts every timed frame instead,
        // since it may take a single shot of a frame with nothing of its own.
        if (timed && gpuMs.empty()) { printf("ERROR time needs more than %d frames\n", warmup); return 2; }
        if ((timed ? timedDraws : drawnTotal) == 0) {
            printf("ERROR the %s pass drew %s in any %s\n", pass->name, backend && strcmp(judgedKind, "all") ? (pass->goo ? "no goo" : "no tunnel") : "nothing",
                   timed ? "timed frame" : "shot");
            return 2;
        }
        if (timed) {
            std::sort(gpuMs.begin(), gpuMs.end());
            std::sort(cpuMs.begin(), cpuMs.end());
            auto pct = [](const std::vector<double> &sorted, double p) {
                return sorted[std::min(sorted.size() - 1, size_t(p * (sorted.size() - 1) + 0.5))];
            };
            rusage usage1; getrusage(RUSAGE_SELF, &usage1);
            const double processMs = 1e3 * (cpuSeconds(usage1) - cpuSeconds(usage0) - shotCpuSeconds) / gpuMs.size();
            printf("TIME pass=%s %dx%d frames=%zu gpu_ms median=%.5f p95=%.5f draw_cpu_ms median=%.5f p95=%.5f process_cpu_ms mean=%.5f\n",
                   pass->name, w, h, gpuMs.size(), pct(gpuMs, 0.5), pct(gpuMs, 0.95), pct(cpuMs, 0.5), pct(cpuMs, 0.95), processMs);
        }
        printf("WROTE pass=%s shots=%d through %s\n", pass->name, shots, backend ? "HSRendererMetal" : "HSRendererGL");
        return 0;
    }
}
