/*
 * HSRenderer on Metal. See rendererMetal.h.
 */

#import <Metal/Metal.h>
#import <QuartzCore/CAMetalLayer.h>
#import <simd/simd.h>
#include <Hyperspace/rendererMetal.h>
#include <Hyperspace/transform.h>
#include <Implicit/impSurface.h>
#include <stdio.h>
#include <stdlib.h>
#include <map>
#include <string>
#include <vector>
#include <algorithm>

namespace {

// Mirrors of metal/Interface.metal; the layouts must match.
struct ImmediateVertex {
	float position[3];
	float pad0;
	float texcoord[2];
	float pad1[2];
	float color[4];
};

struct FFUniforms {
	simd_float4x4 mvp;
	simd_float4x4 modelview;
	simd_float4 fogColor;
	float fogStart;
	float fogEnd;
	int fogOn;
	int texOn;
};

struct QuadInstance {
	simd_float4x4 mvp;
	simd_float4 modelviewZ;
	simd_float4 color;
	float halfSize;
	float pad[3];
};

struct GooUniforms {
	simd_float4x4 mvp;
	simd_float4x4 modelview;
	simd_float4 color;
	simd_float4 fogColor;
	float fogEnd;
	float fogScale;
	simd_float4x4 projection;
};

// The offsets Metal gives the shader's structs; a mirror that drifts from
// them fails to compile instead of reading fog from the wrong place.
static_assert(sizeof(ImmediateVertex) == 48 && offsetof(ImmediateVertex, texcoord) == 16 &&
	offsetof(ImmediateVertex, color) == 32, "ImmediateVertex must match Interface.metal");
static_assert(sizeof(FFUniforms) == 160 && offsetof(FFUniforms, fogColor) == 128 &&
	offsetof(FFUniforms, fogStart) == 144 && offsetof(FFUniforms, texOn) == 156, "FFUniforms must match Interface.metal");
static_assert(sizeof(QuadInstance) == 112 && offsetof(QuadInstance, modelviewZ) == 64 &&
	offsetof(QuadInstance, color) == 80 && offsetof(QuadInstance, halfSize) == 96, "QuadInstance must match Interface.metal");
static_assert(sizeof(GooUniforms) == 240 && offsetof(GooUniforms, color) == 128 &&
	offsetof(GooUniforms, fogEnd) == 160 && offsetof(GooUniforms, fogScale) == 164 &&
	offsetof(GooUniforms, projection) == 176, "GooUniforms must match Interface.metal");

struct GooBuildUniforms {
	simd_float4 c;
	simd_float2 cam;
	simd_float2 origin;
	float unitSize;
	float halfVolume;
	float surface;
	uint32_t resolution;
	uint32_t maxVertices;
	uint32_t pad[3];
};
static_assert(sizeof(GooBuildUniforms) == 64 && offsetof(GooBuildUniforms, cam) == 16 &&
	offsetof(GooBuildUniforms, unitSize) == 32 && offsetof(GooBuildUniforms, resolution) == 44 &&
	offsetof(GooBuildUniforms, maxVertices) == 48, "GooBuildUniforms must match Interface.metal");

struct TunnelUniforms {
	simd_float4x4 mvp;
	simd_float4x4 modelview;
	simd_float4x4 projection;
	simd_float4 fogColor;
	float fogEnd;
	float fogScale;
};
static_assert(sizeof(TunnelUniforms) == 224 && offsetof(TunnelUniforms, fogColor) == 192 &&
	offsetof(TunnelUniforms, fogEnd) == 208 && offsetof(TunnelUniforms, fogScale) == 212,
	"TunnelUniforms must match Interface.metal");

struct StarUniforms {
	simd_float4x4 view;
	simd_float4x4 clipProjection;
	simd_float4x4 projView;
	simd_float4x4 lastProjView;
	simd_float4 eye;
	simd_float4 lastEye;
	simd_float2 viewport;
	simd_float2 lastViewport;
	float unroll;
	float pad[3];
};
static_assert(HS_STAR_FLOATS == 7, "star_vertex reads 7 floats a star");
static_assert(sizeof(StarUniforms) == 320 && offsetof(StarUniforms, eye) == 256 &&
	offsetof(StarUniforms, viewport) == 288 && offsetof(StarUniforms, unroll) == 304,
	"StarUniforms must match Interface.metal");

struct TunnelShape {
	float radius;
	float widthOffset;
	float texShift;
	float texcoordMult;
	float maxSaturation;
	float alpha;
	float huelo, satlo, sathi, lumlo, lumhi;
	uint32_t resolution;
	uint32_t numPoints;
};
static_assert(sizeof(TunnelShape) == 52 && offsetof(TunnelShape, alpha) == 20 &&
	offsetof(TunnelShape, lumhi) == 40 && offsetof(TunnelShape, numPoints) == 48,
	"TunnelShape must match Interface.metal");

struct Texture {
	id<MTLTexture> texture;
	id<MTLSamplerState> sampler;
};

[[noreturn]] void fail(const char *what, const char *detail){
	std::string message = std::string("HSRendererMetal: ") + what + (detail ? std::string(": ") + detail : std::string());
	fprintf(stderr, "%s\n", message.c_str());
	throw HSRendererMetalError(message);
}

simd_float4x4 fromGL(const float m[16]){
	simd_float4x4 r;
	for(int c = 0; c < 4; c++)
		r.columns[c] = simd_make_float4(m[4 * c], m[4 * c + 1], m[4 * c + 2], m[4 * c + 3]);
	return r;
}

// GL's clip z runs -w..w and Metal's 0..w.
simd_float4x4 clipZ(){
	simd_float4x4 z = matrix_identity_float4x4;
	z.columns[2] = simd_make_float4(0, 0, 0.5f, 0);
	z.columns[3] = simd_make_float4(0, 0, 0.5f, 1);
	return z;
}

// glOrtho(l, r, b, t, n, f), as GL takes it.
simd_float4x4 orthoProjection(float l, float r, float b, float t, float n, float f){
	simd_float4x4 m = matrix_identity_float4x4;
	m.columns[0] = simd_make_float4(2.0f / (r - l), 0, 0, 0);
	m.columns[1] = simd_make_float4(0, 2.0f / (t - b), 0, 0);
	m.columns[2] = simd_make_float4(0, 0, -2.0f / (f - n), 0);
	m.columns[3] = simd_make_float4(-(r + l) / (r - l), -(t + b) / (t - b), -(f + n) / (f - n), 1);
	return m;
}

// The lens-flare plane, gluOrtho2D(0, aspect, 0, 1).
simd_float4x4 overlayProjection(float aspect){
	return orthoProjection(0.0f, aspect, 0.0f, 1.0f, -1.0f, 1.0f);
}

// A level of a mip chain as RGBA: GL samples a 3-channel texture with alpha 1.
std::vector<unsigned char> rgbaLevel(const HSMipChain &chain, int level){
	const std::vector<unsigned char> &src = chain.levels[level];
	if(chain.channels == 4)
		return src;
	if(chain.channels != 3)
		fail("mip chain", "only 3 or 4 channels are supported");
	std::vector<unsigned char> out(src.size() / 3 * 4);
	for(size_t i = 0, j = 0; i + 2 < src.size(); i += 3, j += 4){
		out[j] = src[i]; out[j + 1] = src[i + 1]; out[j + 2] = src[i + 2]; out[j + 3] = 255;
	}
	return out;
}

}  // namespace

struct HSRendererMetalState {
	id<MTLDevice> device;
	id<MTLCommandQueue> queue;
	id<MTLLibrary> ffLibrary, gooLibrary, tunnelLibrary;
	// drawQuad's queue: quads in a run that shares a texture and fog, drawn
	// instanced by flushQuads when the run ends or anything else draws.
	id<MTLRenderPipelineState> quadPipeline;   // for pipelineFormat, rebuilt with the others
	id<MTLRenderPipelineState> starPipeline;   // likewise
	// drawStarField's: the stars, uploaded once a generation, and last frame's camera.
	id<MTLBuffer> stars;
	unsigned int starGeneration;
	int starCount;
	bool starsDrawn;   // a last frame to measure the stars' motion from
	simd_float4x4 lastStarProjView;
	simd_float3 lastStarEye;
	simd_float2 lastStarViewport;
	std::vector<QuadInstance> quads;
	unsigned int quadTexture;
	bool quadFog;
	id<MTLRenderPipelineState> gooPipeline, tunnelPipeline;
	id<MTLRenderPipelineState> gooTargetPipeline;   // the goo into gooTarget, one sample
	MTLPixelFormat pipelineFormat;
	NSUInteger samples, pipelineSamples;   // setSampleCount's; those the pipelines were built for
	int tunnelDetail;                      // setTunnelDetail's
	double lastGPUms;                      // lastFrameGPUMilliseconds's
	id<MTLTexture> multisample;            // the frame's samples, memoryless, when samples > 1
	id<MTLTexture> target;
	id<CAMetalDrawable> drawable;   // set for one frame by setDrawable, presented by endFrame
	id<MTLCommandBuffer> commands;
	id<MTLRenderCommandEncoder> encoder;
	std::map<unsigned int, Texture> textures;
	// GL's filters and wraps, as the create* calls set them: linear with no
	// mipmaps and REPEAT; linear mipmapped and REPEAT; and the cube's.
	id<MTLSamplerState> linear, mipmapped, cube;
	unsigned int nextName;
	simd_float4x4 projection, view;   // the frame's, as GL takes them
	simd_float4x4 clipProjection;     // projection, with clip z mapped to Metal's
	simd_float4x4 savedProjection, savedView;
	bool inOverlay;
	bool fog;
	float fogStart, fogEnd;
	int draws, gooDraws, tunnelDraws;
	bool inGoo;
	simd_float4 gooColor;
	unsigned int gooTextures[3];   // normals0, normals1, nebula: Goo.metal's texture(0..2)
	id<MTLBuffer> sphere;          // hsSphereBand's bands, one after another, as GooVertex
	// The offscreen target is a pass of its own, so it works inside a frame or
	// outside one (the caustics are made before the first beginFrame).
	id<MTLRenderPipelineState> offscreenPipeline;   // fixed function, into RGBA8
	id<MTLTexture> offscreenTarget;
	id<MTLCommandBuffer> offscreenCommands;
	id<MTLRenderCommandEncoder> offscreenEncoder;
	std::vector<ImmediateVertex> offscreenVertices;   // the pass's strips, uploaded once at the end
	std::vector<int> offscreenStrips;                 // each strip's vertex count, in order
	id<MTLTexture> blank;   // bound where a shader declares a texture it is told not to sample
	bool inTunnel;
	float tunnelAlpha;   // the caustics' mix, carried in every vertex's alpha
	std::vector<simd_float4> tunnelPath;        // drawTunnelField's, reused
	// The goo built on the GPU (drawGooField). The vertices are written and
	// drawn by the GPU alone, so one buffer serves every frame: Metal orders
	// the next frame's build after this frame's draw.
	id<MTLLibrary> gooBuildLibrary;
	id<MTLComputePipelineState> gooBuild, gooBuildCount;
	id<MTLBuffer> gooTable;      // hsGooTriangleTable
	id<MTLBuffer> gooCounter;    // vertices this build needed
	id<MTLBuffer> gooPeak;       // the most any build has needed: never reset, read to size the buffer
	id<MTLBuffer> gooArgs;       // the draw's MTLDrawPrimitivesIndirectArguments
	id<MTLBuffer> gooVertices;
	NSUInteger gooCapacity;      // in vertices, a multiple of 3
	id<MTLCommandBuffer> gooBuildCommands;   // this frame's build, nil until drawGooField
	// The soft goo (setSoftGoo): drawn into gooTarget, in the frame's format,
	// in a command buffer of its own (softCommands) committed after the build
	// and before the frame; then added over the frame by softenPipeline. The
	// format is the frame's on purpose: a half-float target was measured
	// brighter than GL (parity goosoft bias 3.07, faithful 8-bit 0.66), since
	// it keeps light GL's 8-bit blending rounds away.
	bool softGoo;
	id<MTLLibrary> softenLibrary;
	id<MTLRenderPipelineState> softenPipeline;   // for pipelineFormat, rebuilt with the others
	id<MTLTexture> gooTarget;
	id<MTLCommandBuffer> softCommands;   // this frame's soft goo, nil until drawGooField
	MTLViewport viewport;   // the frame's
};

static NSString *readSource(const char *dir, const char *file){
	NSString *path = [@(dir) stringByAppendingPathComponent:@(file)];
	NSError *err = nil;
	NSString *s = [NSString stringWithContentsOfFile:path encoding:NSUTF8StringEncoding error:&err];
	if(!s)
		fail("cannot read", path.UTF8String);
	return s;
}


// Each pass file is compiled with the interface prepended, as parity does.
// safeMath compiles without fast math: Tunnel.metal's colour waves take cos of
// arguments in the hundreds and more, where fast math's cos loses accuracy.
static id<MTLLibrary> compilePass(id<MTLDevice> device, const char *dir, const char *file, bool safeMath = false){
	NSString *src = [readSource(dir, "Interface.metal") stringByAppendingString:readSource(dir, file)];
	NSError *err = nil;
	MTLCompileOptions *options = nil;
	if(safeMath){
		options = [MTLCompileOptions new];
		options.mathMode = MTLMathModeSafe;
	}
	id<MTLLibrary> lib = [device newLibraryWithSource:src options:options error:&err];
	if(!lib)
		fail(file, err.localizedDescription.UTF8String);
	return lib;
}

// Everything Hyperspace draws is blended (SRC_ALPHA, ONE).
static id<MTLRenderPipelineState> additivePipeline(id<MTLDevice> device, id<MTLLibrary> lib,
	NSString *vfn, NSString *ffn, MTLPixelFormat format, NSUInteger samples = 1){
	MTLRenderPipelineDescriptor *pd = [MTLRenderPipelineDescriptor new];
	pd.rasterSampleCount = samples;
	pd.vertexFunction = [lib newFunctionWithName:vfn];
	pd.fragmentFunction = [lib newFunctionWithName:ffn];
	if(!pd.vertexFunction || !pd.fragmentFunction)
		fail("missing entry point", [vfn stringByAppendingFormat:@" / %@", ffn].UTF8String);
	pd.colorAttachments[0].pixelFormat = format;
	pd.colorAttachments[0].blendingEnabled = YES;
	pd.colorAttachments[0].sourceRGBBlendFactor = pd.colorAttachments[0].sourceAlphaBlendFactor = MTLBlendFactorSourceAlpha;
	pd.colorAttachments[0].destinationRGBBlendFactor = pd.colorAttachments[0].destinationAlphaBlendFactor = MTLBlendFactorOne;
	NSError *err = nil;
	id<MTLRenderPipelineState> ps = [device newRenderPipelineStateWithDescriptor:pd error:&err];
	if(!ps)
		fail("pipeline", err.localizedDescription.UTF8String);
	return ps;
}

static id<MTLComputePipelineState> computePipeline(id<MTLDevice> device, id<MTLLibrary> lib, NSString *fn){
	id<MTLFunction> f = [lib newFunctionWithName:fn];
	if(!f)
		fail("missing entry point", fn.UTF8String);
	NSError *err = nil;
	id<MTLComputePipelineState> ps = [device newComputePipelineStateWithFunction:f error:&err];
	if(!ps)
		fail("compute pipeline", err.localizedDescription.UTF8String);
	return ps;
}

HSRendererMetal::HSRendererMetal(void *device, const char *metalDir) : st(new HSRendererMetalState){
	st->device = (__bridge id<MTLDevice>)device;
	st->queue = [st->device newCommandQueue];
	st->ffLibrary = compilePass(st->device, metalDir, "FixedFunction.metal");
	st->gooLibrary = compilePass(st->device, metalDir, "Goo.metal");
	st->tunnelLibrary = compilePass(st->device, metalDir, "Tunnel.metal", true);
	st->gooPipeline = st->tunnelPipeline = st->quadPipeline = st->starPipeline = nil;
	st->stars = nil;
	st->starGeneration = 0;
	st->starCount = 0;
	st->starsDrawn = false;
	st->quadTexture = 0;
	st->quadFog = false;
	st->pipelineFormat = MTLPixelFormatInvalid;
	st->target = nil;
	st->drawable = nil;
	st->commands = nil;
	st->encoder = nil;
	st->nextName = 1;
	st->projection = st->view = st->clipProjection = matrix_identity_float4x4;
	st->savedProjection = st->savedView = matrix_identity_float4x4;
	st->inOverlay = false;
	st->fog = true;
	st->fogStart = st->fogEnd = 0.0f;
	st->draws = st->gooDraws = st->tunnelDraws = 0;
	MTLSamplerDescriptor *sd = [MTLSamplerDescriptor new];
	sd.minFilter = sd.magFilter = MTLSamplerMinMagFilterLinear;
	sd.mipFilter = MTLSamplerMipFilterNotMipmapped;
	sd.sAddressMode = sd.tAddressMode = MTLSamplerAddressModeRepeat;
	st->linear = [st->device newSamplerStateWithDescriptor:sd];
	sd.mipFilter = MTLSamplerMipFilterLinear;
	st->mipmapped = [st->device newSamplerStateWithDescriptor:sd];
	// GL clamps s and t and leaves r at REPEAT, and filters each face alone;
	// Metal filters cube maps across faces. The goo passes with this, but no
	// measurement isolates a seam (parity/README.md, Backend check).
	sd.sAddressMode = sd.tAddressMode = sd.rAddressMode = MTLSamplerAddressModeClampToEdge;
	st->cube = [st->device newSamplerStateWithDescriptor:sd];
	st->inGoo = false;
	st->gooColor = simd_make_float4(1, 1, 1, 1);
	st->gooTextures[0] = st->gooTextures[1] = st->gooTextures[2] = 0;
	st->sphere = nil;   // built on the first drawGooSphere, as GL builds its list
	st->offscreenPipeline = nil;
	st->offscreenTarget = nil;
	st->offscreenCommands = nil;
	st->offscreenEncoder = nil;
	MTLTextureDescriptor *bd = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA8Unorm
		width:1 height:1 mipmapped:NO];
	st->blank = [st->device newTextureWithDescriptor:bd];
	const unsigned char white[4] = {255, 255, 255, 255};
	[st->blank replaceRegion:MTLRegionMake2D(0, 0, 1, 1) mipmapLevel:0 withBytes:white bytesPerRow:4];
	st->inTunnel = false;
	st->tunnelAlpha = 1.0f;
	st->gooBuildLibrary = compilePass(st->device, metalDir, "GooBuild.metal");
	st->gooBuild = computePipeline(st->device, st->gooBuildLibrary, @"goo_build");
	st->gooBuildCount = computePipeline(st->device, st->gooBuildLibrary, @"goo_build_count");
	short table[256][HS_GOO_TABLE_ROW];
	hsGooTriangleTable(table);
	st->gooTable = [st->device newBufferWithBytes:table length:sizeof table options:MTLResourceStorageModeShared];
	st->gooCounter = [st->device newBufferWithLength:sizeof(uint32_t) options:MTLResourceStorageModeShared];
	st->gooPeak = [st->device newBufferWithLength:sizeof(uint32_t) options:MTLResourceStorageModeShared];
	*(uint32_t *)st->gooPeak.contents = 0;
	st->gooBuildCommands = nil;
	// Zeroed, so a first build that fails draws nothing rather than reading
	// a vertex count from uninitialized memory.
	const MTLDrawPrimitivesIndirectArguments noDraw = {0, 0, 0, 0};
	st->gooArgs = [st->device newBufferWithBytes:&noDraw length:sizeof noDraw options:MTLResourceStorageModeShared];
	st->gooVertices = nil;
	st->gooCapacity = 0;
	st->softGoo = true;
	st->tunnelDetail = 2;
	st->lastGPUms = 0.0;
	st->samples = 4;
	if(![st->device supportsTextureSampleCount:st->samples])
		st->samples = 1;
	st->pipelineSamples = 0;
	st->multisample = nil;
	st->gooTargetPipeline = nil;
	st->softenLibrary = compilePass(st->device, metalDir, "Soften.metal");
	st->softenPipeline = nil;
	st->gooTarget = nil;
	st->softCommands = nil;
}

HSRendererMetal::~HSRendererMetal(){
	// An encoder released mid-frame asserts; end it, and drop the frame.
	if(st->encoder)
		[st->encoder endEncoding];
	if(st->offscreenEncoder)
		[st->offscreenEncoder endEncoding];
	delete st;
}

// The soften pass adds the goo target over the frame: (ONE, ONE), since the
// target already holds the goo's own (SRC_ALPHA, ONE) blending.
static id<MTLRenderPipelineState> softenPipeline(id<MTLDevice> device, id<MTLLibrary> lib, MTLPixelFormat format,
	NSUInteger samples){
	MTLRenderPipelineDescriptor *pd = [MTLRenderPipelineDescriptor new];
	pd.rasterSampleCount = samples;
	pd.vertexFunction = [lib newFunctionWithName:@"soften_vertex"];
	pd.fragmentFunction = [lib newFunctionWithName:@"soften_fragment"];
	if(!pd.vertexFunction || !pd.fragmentFunction)
		fail("missing entry point", "soften_vertex / soften_fragment");
	pd.colorAttachments[0].pixelFormat = format;
	pd.colorAttachments[0].blendingEnabled = YES;
	pd.colorAttachments[0].sourceRGBBlendFactor = pd.colorAttachments[0].sourceAlphaBlendFactor = MTLBlendFactorOne;
	pd.colorAttachments[0].destinationRGBBlendFactor = pd.colorAttachments[0].destinationAlphaBlendFactor = MTLBlendFactorOne;
	NSError *err = nil;
	id<MTLRenderPipelineState> ps = [device newRenderPipelineStateWithDescriptor:pd error:&err];
	if(!ps)
		fail("pipeline", err.localizedDescription.UTF8String);
	return ps;
}

// Pipelines are built for the target's pixel format and the frame's samples,
// so a new format or sample count rebuilds them.
static void useTarget(HSRendererMetalState *st, id<MTLTexture> target){
	st->target = target;
	if(st->target.pixelFormat == st->pipelineFormat && st->samples == st->pipelineSamples)
		return;
	const MTLPixelFormat f = st->target.pixelFormat;
	const NSUInteger n = st->samples;
	st->quadPipeline = additivePipeline(st->device, st->ffLibrary, @"ff_quad_vertex", @"ff_fragment", f, n);
	st->starPipeline = additivePipeline(st->device, st->ffLibrary, @"star_vertex", @"ff_fragment", f, n);
	st->gooPipeline = additivePipeline(st->device, st->gooLibrary, @"goo_vertex", @"goo_fragment", f, n);
	st->gooTargetPipeline = additivePipeline(st->device, st->gooLibrary, @"goo_vertex", @"goo_fragment", f);
	st->tunnelPipeline = additivePipeline(st->device, st->tunnelLibrary, @"tunnel_build_vertex", @"tunnel_fragment", f, n);
	st->softenPipeline = softenPipeline(st->device, st->softenLibrary, f, n);
	st->pipelineFormat = f;
	st->pipelineSamples = n;
}

static void flushQuads(HSRendererMetalState *st);
static void bindGooTextures(HSRendererMetalState *st, id<MTLRenderCommandEncoder> encoder);

void HSRendererMetal::setTarget(void *target){
	if(st->encoder)
		fail("setTarget", "called inside a frame");
	st->drawable = nil;
	useTarget(st, (__bridge id<MTLTexture>)target);
}

void HSRendererMetal::setDrawable(void *drawable){
	if(st->encoder)
		fail("setDrawable", "called inside a frame");
	st->drawable = (__bridge id<CAMetalDrawable>)drawable;
	useTarget(st, st->drawable.texture);
}

int HSRendererMetal::drawCount() const{
	return st->draws;
}

int HSRendererMetal::gooDrawCount() const{
	return st->gooDraws;
}

int HSRendererMetal::tunnelDrawCount() const{
	return st->tunnelDraws;
}

void HSRendererMetal::setSoftGoo(bool soft){
	if(st->encoder)
		fail("setSoftGoo", "called inside a frame");
	st->softGoo = soft;
}

void HSRendererMetal::setTunnelDetail(int detail){
	st->tunnelDetail = std::max(1, detail);
}

int HSRendererMetal::tunnelDetail() const{
	return st->tunnelDetail;
}

double HSRendererMetal::lastFrameGPUMilliseconds() const{
	return st->lastGPUms;
}

void HSRendererMetal::setSampleCount(int samples){
	if(st->encoder)
		fail("setSampleCount", "called inside a frame");
	st->samples = samples > 1 && [st->device supportsTextureSampleCount:NSUInteger(samples)] ? NSUInteger(samples) : 1;
	if(st->target)
		useTarget(st, st->target);
}

void *HSRendererMetal::texture(unsigned int name) const{
	std::map<unsigned int, Texture>::const_iterator t = st->textures.find(name);
	return t == st->textures.end() ? NULL : (__bridge void *)t->second.texture;
}

void HSRendererMetal::beginFrame(const HSFrame &frame){
	if(!st->target)
		fail("beginFrame", "no target: call setTarget first");
	st->lastGPUms = 0.0;   // set again by endFrame for a target's frame only
	if(st->encoder)
		fail("beginFrame", "the last frame was not ended");
	st->projection = fromGL(frame.projection);
	st->clipProjection = simd_mul(clipZ(), st->projection);
	st->view = fromGL(frame.view);
	st->fogStart = frame.fogStart;
	st->fogEnd = frame.fogEnd;
	st->fog = true;
	st->inOverlay = false;
	st->draws = st->gooDraws = st->tunnelDraws = 0;
	st->gooBuildCommands = nil;
	st->softCommands = nil;

	MTLRenderPassDescriptor *rp = [MTLRenderPassDescriptor renderPassDescriptor];
	rp.colorAttachments[0].loadAction = MTLLoadActionClear;
	rp.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 0, 1);
	if(st->samples > 1){
		// Memoryless: the samples never leave tile memory, so the frame costs
		// no more memory or bandwidth than an aliased one, only the resolve.
		id<MTLTexture> ms = st->multisample;
		if(!ms || ms.width != st->target.width || ms.height != st->target.height ||
			ms.pixelFormat != st->target.pixelFormat || ms.sampleCount != st->samples){
			MTLTextureDescriptor *td = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:st->target.pixelFormat
				width:st->target.width height:st->target.height mipmapped:NO];
			td.textureType = MTLTextureType2DMultisample;
			td.sampleCount = st->samples;
			td.usage = MTLTextureUsageRenderTarget;
			td.storageMode = MTLStorageModeMemoryless;
			st->multisample = [st->device newTextureWithDescriptor:td];
			if(!st->multisample){
				// Drawn aliased rather than not at all, as the header promises.
				NSLog(@"HSRendererMetal: no memoryless %lux texture; drawing with 1 sample", (unsigned long)st->samples);
				st->samples = 1;
				useTarget(st, st->target);
			}
		}
	}
	if(st->samples > 1){
		rp.colorAttachments[0].texture = st->multisample;
		rp.colorAttachments[0].resolveTexture = st->target;
		rp.colorAttachments[0].storeAction = MTLStoreActionMultisampleResolve;
	}
	else{
		rp.colorAttachments[0].texture = st->target;
		rp.colorAttachments[0].storeAction = MTLStoreActionStore;
	}
	st->commands = [st->queue commandBuffer];
	st->encoder = [st->commands renderCommandEncoderWithDescriptor:rp];
	// GL's viewport origin is the bottom left, Metal's the top left. Signed:
	// a viewport taller than the target hangs off its top, as it would in GL.
	MTLViewport vp = {double(frame.viewport[0]), double(st->target.height) - frame.viewport[1] - frame.viewport[3],
		double(frame.viewport[2]), double(frame.viewport[3]), 0.0, 1.0};
	[st->encoder setViewport:vp];
	[st->encoder setCullMode:MTLCullModeNone];
	st->viewport = vp;
}

void HSRendererMetal::endFrame(){
	if(!st->encoder)
		fail("endFrame", "no frame was begun");
	if(st->inGoo)
		fail("endFrame", "beginGoo was not ended");
	if(st->inTunnel)
		fail("endFrame", "beginTunnel was not ended");
	if(st->inOverlay)
		fail("endFrame", "beginOverlay was not ended");
	flushQuads(st);
	[st->encoder endEncoding];
	if(st->drawable){
		// The saver's frame: present it and go on to the next while the GPU
		// draws. A failed frame is one frame lost, not a reason to stop.
		[st->commands presentDrawable:st->drawable];
		[st->commands addCompletedHandler:^(id<MTLCommandBuffer> done){
			if(done.status == MTLCommandBufferStatusError)
				NSLog(@"HSRendererMetal: the GPU failed a frame: %@", done.error.localizedDescription);
		}];
		[st->commands commit];
		st->drawable = nil;
		st->target = nil;
	}
	else{
		[st->commands commit];
		[st->commands waitUntilCompleted];
		if(st->commands.status == MTLCommandBufferStatusError)
			fail("the GPU failed the frame", st->commands.error.localizedDescription.UTF8String);
		if(st->softCommands){
			[st->softCommands waitUntilCompleted];
			if(st->softCommands.status == MTLCommandBufferStatusError)
				fail("the GPU failed the soft goo", st->softCommands.error.localizedDescription.UTF8String);
		}
		if(st->gooBuildCommands){
			[st->gooBuildCommands waitUntilCompleted];
			if(st->gooBuildCommands.status == MTLCommandBufferStatusError)
				fail("the GPU failed the goo's build", st->gooBuildCommands.error.localizedDescription.UTF8String);
			// A build that made no triangles drew nothing, which only a frame
			// waited for can know: parity's check that the goo drew relies on it.
			if(*(const uint32_t *)st->gooCounter.contents == 0){
				st->gooDraws--;
				st->draws--;
			}
		}
		// The union of the frame's command buffers' spans: the time the GPU was
		// busy with the frame at all, as parity/saverprofile.py measures the
		// saver. A sum would count twice whatever overlaps, or one waiting on
		// another, and so move with scheduling rather than with the work.
		std::vector<std::pair<double, double>> spans{{st->commands.GPUStartTime, st->commands.GPUEndTime}};
		if(st->softCommands)
			spans.push_back({st->softCommands.GPUStartTime, st->softCommands.GPUEndTime});
		if(st->gooBuildCommands)
			spans.push_back({st->gooBuildCommands.GPUStartTime, st->gooBuildCommands.GPUEndTime});
		std::sort(spans.begin(), spans.end());
		double seconds = 0.0, reached = spans[0].first;
		for(const auto &span : spans){
			double from = std::max(span.first, reached);
			if(span.second > from)
				seconds += span.second - from;
			reached = std::max(reached, span.second);
		}
		st->lastGPUms = seconds * 1000.0;
	}
	st->encoder = nil;
	st->commands = nil;
}

void HSRendererMetal::setFog(bool on){
	st->fog = on;
}

unsigned int HSRendererMetal::createTexture(int width, int height, const unsigned char *rgba){
	MTLTextureDescriptor *td = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA8Unorm
		width:width height:height mipmapped:NO];
	id<MTLTexture> t = [st->device newTextureWithDescriptor:td];
	[t replaceRegion:MTLRegionMake2D(0, 0, width, height) mipmapLevel:0 withBytes:rgba bytesPerRow:size_t(width) * 4];
	// Linear, no mipmaps, and GL's default wrap, repeat.
	unsigned int name = st->nextName++;
	st->textures[name] = Texture{t, st->linear};
	return name;
}

unsigned int HSRendererMetal::createMipmappedTexture(const HSMipChain &chain){
	if(chain.levels.empty())
		fail("createMipmappedTexture", "empty mip chain");
	MTLTextureDescriptor *td = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA8Unorm
		width:chain.size height:chain.size mipmapped:YES];
	td.mipmapLevelCount = chain.levels.size();
	id<MTLTexture> t = [st->device newTextureWithDescriptor:td];
	for(size_t l = 0; l < chain.levels.size(); l++){
		const int s = chain.size >> l > 0 ? chain.size >> l : 1;
		std::vector<unsigned char> px = rgbaLevel(chain, int(l));
		[t replaceRegion:MTLRegionMake2D(0, 0, s, s) mipmapLevel:l withBytes:px.data() bytesPerRow:size_t(s) * 4];
	}
	unsigned int name = st->nextName++;
	st->textures[name] = Texture{t, st->mipmapped};
	return name;
}

unsigned int HSRendererMetal::createCubeTexture(const HSMipChain faces[6]){
	const HSMipChain &first = faces[0];
	if(first.levels.empty())
		fail("createCubeTexture", "empty mip chain");
	MTLTextureDescriptor *td = [MTLTextureDescriptor textureCubeDescriptorWithPixelFormat:MTLPixelFormatRGBA8Unorm
		size:first.size mipmapped:YES];
	td.mipmapLevelCount = first.levels.size();
	id<MTLTexture> t = [st->device newTextureWithDescriptor:td];
	// HSRenderer orders faces -x +x -y +y -z +z; Metal's slices are +x -x +y -y +z -z.
	static const int slice[6] = {1, 0, 3, 2, 5, 4};
	for(int f = 0; f < 6; f++){
		if(faces[f].size != first.size || faces[f].levels.size() != first.levels.size())
			fail("createCubeTexture", "faces differ in size");
		for(size_t l = 0; l < faces[f].levels.size(); l++){
			const int s = first.size >> l > 0 ? first.size >> l : 1;
			std::vector<unsigned char> px = rgbaLevel(faces[f], int(l));
			[t replaceRegion:MTLRegionMake2D(0, 0, s, s) mipmapLevel:l slice:slice[f]
				withBytes:px.data() bytesPerRow:size_t(s) * 4 bytesPerImage:0];
		}
	}
	unsigned int name = st->nextName++;
	st->textures[name] = Texture{t, st->cube};
	return name;
}

// Draws drawQuad's queue, instanced, in runs that fit setVertexBytes' 4 KB:
// no per-frame buffer, so nothing to keep from the GPU while it reads one.
// Every other draw, and endFrame, flushes first, so the order of draws is
// the order of calls: beginGoo, beginTunnel and endFrame call it, and a new
// way to draw on the frame's encoder must too. Every draw binds its own
// pipeline; nothing relies on one left bound.
static void flushQuads(HSRendererMetalState *st){
	if(st->quads.empty())
		return;
	std::map<unsigned int, Texture>::const_iterator found = st->textures.find(st->quadTexture);
	if(found == st->textures.end())
		fail("drawQuad", "a queued quad's texture is gone");
	const Texture &tex = found->second;
	FFUniforms u;
	u.modelview = u.mvp = matrix_identity_float4x4;   // per quad, in the instances
	u.fogColor = simd_make_float4(0, 0, 0, 1);
	u.fogStart = st->fogStart;
	u.fogEnd = st->fogEnd;
	u.fogOn = st->quadFog;
	u.texOn = 1;
	[st->encoder setRenderPipelineState:st->quadPipeline];
	[st->encoder setFragmentBytes:&u length:sizeof u atIndex:1];
	[st->encoder setFragmentTexture:tex.texture atIndex:0];
	[st->encoder setFragmentSamplerState:tex.sampler atIndex:0];
	const size_t run = 4096 / sizeof(QuadInstance);
	for(size_t at = 0; at < st->quads.size(); at += run){
		const size_t n = std::min(run, st->quads.size() - at);
		[st->encoder setVertexBytes:&st->quads[at] length:n * sizeof(QuadInstance) atIndex:0];
		[st->encoder drawPrimitives:MTLPrimitiveTypeTriangleStrip vertexStart:0 vertexCount:4 instanceCount:n];
	}
	st->quads.clear();
}

void HSRendererMetal::drawQuad(unsigned int texture, const float color[4], const float model[16], float half){
	if(!st->encoder)
		fail("drawQuad", "outside a frame");
	// The goo's pipeline and cube textures are bound until endGoo.
	if(st->inGoo || st->inTunnel)
		fail("drawQuad", "inside beginGoo/endGoo or beginTunnel/endTunnel");
	if(st->textures.find(texture) == st->textures.end())
		fail("drawQuad", "unknown texture");

	const bool fog = st->fog && !st->inOverlay;
	if(!st->quads.empty() && (texture != st->quadTexture || fog != st->quadFog))
		flushQuads(st);
	st->quadTexture = texture;
	st->quadFog = fog;
	// The model matrix applies after the camera, as GL's matrix stack did.
	const simd_float4x4 modelview = simd_mul(st->view, fromGL(model));
	QuadInstance q;
	q.mvp = simd_mul(st->clipProjection, modelview);
	q.modelviewZ = simd_make_float4(modelview.columns[0].z, modelview.columns[1].z,
		modelview.columns[2].z, modelview.columns[3].z);
	q.color = simd_make_float4(color[0], color[1], color[2], color[3]);
	q.halfSize = half;
	q.pad[0] = q.pad[1] = q.pad[2] = 0.0f;
	st->quads.push_back(q);
	st->draws++;
}

bool HSRendererMetal::drawsStars() const{
	return true;
}

// One instanced draw of two quads a star (star_vertex). The stars are
// uploaded once a generation; each frame sends only the camera, and keeps it
// for the next frame's motion.
void HSRendererMetal::drawStarField(const HSStarField &field){
	if(!st->encoder)
		fail("drawStarField", "outside a frame");
	if(st->inGoo || st->inTunnel || st->inOverlay)
		fail("drawStarField", "inside the goo, the tunnel or the overlay");
	std::map<unsigned int, Texture>::const_iterator tex = st->textures.find(field.texture);
	if(tex == st->textures.end())
		fail("drawStarField", "unknown texture");
	if(field.count < 1)
		return;
	flushQuads(st);
	if(!st->stars || field.generation != st->starGeneration || field.count != st->starCount){
		st->stars = [st->device newBufferWithBytes:field.stars
			length:sizeof(float) * HS_STAR_FLOATS * size_t(field.count) options:MTLResourceStorageModeShared];
		st->starGeneration = field.generation;
		st->starCount = field.count;
		st->starsDrawn = false;
	}
	const simd_float3 eye = simd_make_float3(field.eye[0], field.eye[1], field.eye[2]);
	StarUniforms u;
	u.view = fromGL(field.view);
	u.clipProjection = st->clipProjection;
	u.projView = simd_mul(st->projection, u.view);
	u.lastProjView = st->starsDrawn ? st->lastStarProjView : u.projView;
	u.eye = simd_make_float4(eye, field.depth);
	u.lastEye = simd_make_float4(st->starsDrawn ? eye - st->lastStarEye : simd_make_float3(0, 0, 0),
		st->starsDrawn ? 1.0f : 0.0f);
	u.viewport = simd_make_float2(float(st->viewport.width), float(st->viewport.height));
	u.lastViewport = st->starsDrawn ? st->lastStarViewport : u.viewport;
	u.unroll = field.unroll;
	u.pad[0] = u.pad[1] = u.pad[2] = 0.0f;
	FFUniforms f;
	f.modelview = f.mvp = matrix_identity_float4x4;   // per star, in star_vertex
	f.fogColor = simd_make_float4(0, 0, 0, 1);
	f.fogStart = st->fogStart;
	f.fogEnd = st->fogEnd;
	f.fogOn = st->fog;
	f.texOn = 1;
	[st->encoder setRenderPipelineState:st->starPipeline];
	[st->encoder setVertexBuffer:st->stars offset:0 atIndex:0];
	[st->encoder setVertexBytes:&u length:sizeof u atIndex:1];
	[st->encoder setFragmentBytes:&f length:sizeof f atIndex:1];
	[st->encoder setFragmentTexture:tex->second.texture atIndex:0];
	[st->encoder setFragmentSamplerState:tex->second.sampler atIndex:0];
	[st->encoder drawPrimitives:MTLPrimitiveTypeTriangleStrip vertexStart:0 vertexCount:4
		instanceCount:NSUInteger(2 * field.count)];
	// As many as the drawQuad pairs it replaces.
	st->draws += 2 * field.count;
	st->lastStarProjView = u.projView;
	st->lastStarEye = eye;
	st->lastStarViewport = u.viewport;
	st->starsDrawn = true;
}

void HSRendererMetal::beginOverlay(float aspect){
	if(!st->encoder)
		fail("beginOverlay", "outside a frame");
	// GL's matrix stack would nest; one saved camera cannot.
	if(st->inOverlay)
		fail("beginOverlay", "already in the overlay");
	if(st->inGoo || st->inTunnel)
		fail("beginOverlay", "inside the goo or the tunnel");
	st->savedProjection = st->projection;
	st->savedView = st->view;
	st->projection = overlayProjection(aspect);
	st->clipProjection = simd_mul(clipZ(), st->projection);
	st->view = matrix_identity_float4x4;
	st->inOverlay = true;
}

void HSRendererMetal::endOverlay(){
	if(!st->inOverlay)
		fail("endOverlay", "no beginOverlay");
	st->projection = st->savedProjection;
	st->clipProjection = simd_mul(clipZ(), st->projection);
	st->view = st->savedView;
	st->inOverlay = false;
}

void HSRendererMetal::beginOffscreen(int size){
	if(st->offscreenEncoder)
		fail("beginOffscreen", "already offscreen");
	if(size <= 0)
		fail("beginOffscreen", "size must be positive");
	if(!st->offscreenPipeline)
		st->offscreenPipeline = additivePipeline(st->device, st->ffLibrary, @"ff_vertex", @"ff_fragment", MTLPixelFormatRGBA8Unorm);
	if(!st->offscreenTarget || int(st->offscreenTarget.width) != size){
		MTLTextureDescriptor *td = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA8Unorm
			width:size height:size mipmapped:NO];
		td.usage = MTLTextureUsageRenderTarget;
		td.storageMode = MTLStorageModeShared;	// the CPU reads it back; Apple silicon shares memory
		st->offscreenTarget = [st->device newTextureWithDescriptor:td];
		if(!st->offscreenTarget)
			fail("offscreen target", "no Shared texture on this device");
	}
	st->offscreenVertices.clear();
	st->offscreenStrips.clear();
	MTLRenderPassDescriptor *rp = [MTLRenderPassDescriptor renderPassDescriptor];
	rp.colorAttachments[0].texture = st->offscreenTarget;
	rp.colorAttachments[0].loadAction = MTLLoadActionClear;
	rp.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 0, 1);
	rp.colorAttachments[0].storeAction = MTLStoreActionStore;
	st->offscreenCommands = [st->queue commandBuffer];
	st->offscreenEncoder = [st->offscreenCommands renderCommandEncoderWithDescriptor:rp];
	[st->offscreenEncoder setCullMode:MTLCullModeNone];
	[st->offscreenEncoder setRenderPipelineState:st->offscreenPipeline];
	// Untextured and unfogged. ff_fragment still declares texture(0), and
	// Metal's validation requires it bound whether or not it is sampled.
	[st->offscreenEncoder setFragmentTexture:st->blank atIndex:0];
	[st->offscreenEncoder setFragmentSamplerState:st->linear atIndex:0];
	FFUniforms u;
	u.modelview = matrix_identity_float4x4;
	u.mvp = simd_mul(clipZ(), orthoProjection(0.0f, 1.0f, 0.0f, 1.0f, -0.5f, 0.5f));
	u.fogColor = simd_make_float4(0, 0, 0, 1);
	u.fogStart = u.fogEnd = 0.0f;
	u.fogOn = 0;
	u.texOn = 0;
	[st->offscreenEncoder setVertexBytes:&u length:sizeof u atIndex:1];
	[st->offscreenEncoder setFragmentBytes:&u length:sizeof u atIndex:1];
}

void HSRendererMetal::drawColorStrip(const HSColorVertex *v, int count){
	if(!st->offscreenEncoder)
		fail("drawColorStrip", "outside beginOffscreen/endOffscreen");
	if(count < 3)
		return;
	// Collected, and drawn from one buffer at endOffscreen: the caustics draw
	// about 1600 strips a frame.
	for(int i = 0; i < count; i++){
		ImmediateVertex o;
		o.position[0] = v[i].pos[0]; o.position[1] = v[i].pos[1]; o.position[2] = v[i].pos[2];
		o.pad0 = 0.0f;
		o.texcoord[0] = o.texcoord[1] = 0.0f;
		o.pad1[0] = o.pad1[1] = 0.0f;
		o.color[0] = v[i].color[0]; o.color[1] = v[i].color[1]; o.color[2] = v[i].color[2];
		o.color[3] = 1.0f;   // glColor3f
		st->offscreenVertices.push_back(o);
	}
	st->offscreenStrips.push_back(count);
}

void HSRendererMetal::endOffscreen(unsigned char *rgb){
	if(!st->offscreenEncoder)
		return;   // no beginOffscreen: nothing to read, as in GL
	if(!st->offscreenVertices.empty()){
		id<MTLBuffer> vb = [st->device newBufferWithBytes:st->offscreenVertices.data()
			length:st->offscreenVertices.size() * sizeof(ImmediateVertex) options:MTLResourceStorageModeShared];
		[st->offscreenEncoder setVertexBuffer:vb offset:0 atIndex:0];
		NSUInteger start = 0;
		for(size_t i = 0; i < st->offscreenStrips.size(); i++){
			[st->offscreenEncoder drawPrimitives:MTLPrimitiveTypeTriangleStrip vertexStart:start vertexCount:NSUInteger(st->offscreenStrips[i])];
			start += NSUInteger(st->offscreenStrips[i]);
		}
	}
	[st->offscreenEncoder endEncoding];
	[st->offscreenCommands commit];
	[st->offscreenCommands waitUntilCompleted];
	if(st->offscreenCommands.status == MTLCommandBufferStatusError)
		fail("the GPU failed the offscreen pass", st->offscreenCommands.error.localizedDescription.UTF8String);
	st->offscreenEncoder = nil;
	st->offscreenCommands = nil;
	const int size = int(st->offscreenTarget.width);
	std::vector<unsigned char> rgba(size_t(size) * size * 4);
	[st->offscreenTarget getBytes:rgba.data() bytesPerRow:size_t(size) * 4 fromRegion:MTLRegionMake2D(0, 0, size, size) mipmapLevel:0];
	// Metal's row 0 is the top; GL reads the bottom row first.
	for(int y = 0; y < size; y++){
		const unsigned char *src = &rgba[size_t(size - 1 - y) * size * 4];
		unsigned char *dst = rgb + size_t(y) * size * 3;
		for(int x = 0; x < size; x++){
			dst[3 * x] = src[4 * x]; dst[3 * x + 1] = src[4 * x + 1]; dst[3 * x + 2] = src[4 * x + 2];
		}
	}
}

void HSRendererMetal::beginGoo(const float color[4], unsigned int nebula,
	unsigned int normals0, unsigned int normals1, bool shaded){
	if(!st->encoder)
		fail("beginGoo", "outside a frame");
	if(st->inGoo || st->inTunnel || st->inOverlay)
		fail("beginGoo", "inside the goo, the tunnel or the overlay");
	flushQuads(st);
	// The Metal port draws the shaded look only; the shaders-off look is ss-5dl.
	if(!shaded)
		fail("beginGoo", "the shaders-off goo is not drawn on Metal (ss-5dl)");
	const unsigned int names[3] = {normals0, normals1, nebula};
	for(int t = 0; t < 3; t++){
		std::map<unsigned int, Texture>::const_iterator tex = st->textures.find(names[t]);
		if(tex == st->textures.end() || tex->second.texture.textureType != MTLTextureTypeCube)
			fail("beginGoo", "a goo texture is not a cube map this backend made");
		st->gooTextures[t] = names[t];
	}
	bindGooTextures(st, st->encoder);
	st->gooColor = simd_make_float4(color[0], color[1], color[2], color[3]);
	st->inGoo = true;
	[st->encoder setRenderPipelineState:st->gooPipeline];
}

// Binds goo vertices, GooVertex (normal, then position), placed by model after
// the camera, as glTranslatef/glScalef on the modelview did.
static void bindGoo(HSRendererMetalState *st, id<MTLRenderCommandEncoder> encoder,
	const simd_float4x4 &model, id<MTLBuffer> vertices){
	GooUniforms u;
	u.modelview = simd_mul(st->view, model);
	u.mvp = simd_mul(st->clipProjection, u.modelview);
	u.color = st->gooColor;
	u.fogColor = simd_make_float4(0, 0, 0, 1);
	u.fogEnd = st->fogEnd;
	u.fogScale = 1.0f / (st->fogEnd - st->fogStart);
	u.projection = st->clipProjection;
	[encoder setVertexBuffer:vertices offset:0 atIndex:0];
	[encoder setVertexBytes:&u length:sizeof u atIndex:1];
	[encoder setFragmentBytes:&u length:sizeof u atIndex:1];
}

// The textures beginGoo checked, Goo.metal's texture(0..2), bound on encoder.
static void bindGooTextures(HSRendererMetalState *st, id<MTLRenderCommandEncoder> encoder){
	for(int t = 0; t < 3; t++){
		const Texture &tex = st->textures.find(st->gooTextures[t])->second;
		[encoder setFragmentTexture:tex.texture atIndex:t];
		[encoder setFragmentSamplerState:tex.sampler atIndex:t];
	}
}

// This backend builds the goo itself (buildsGoo), so goo::draw never hands it
// a surface; one arriving means a caller that skipped the field.
void HSRendererMetal::drawGooSurface(impSurface *surface, const float offset[3]){
	(void)surface;
	(void)offset;
	fail("drawGooSurface", "this backend builds the goo itself: draw it with drawGooField");
}

bool HSRendererMetal::buildsGoo() const{
	return true;
}

// metal/GooBuild.metal reads the table's rows 16 entries apart.
static_assert(HS_GOO_TABLE_ROW == 16, "GooBuild.metal's goo_build hardcodes the table's row length");

// A block's surface measured 6 triangles per res^2 on average (2407 a block at
// resolution 20); the buffer starts at 8, and grows when a frame needed more.
static const NSUInteger kGooTrianglesPerSquare = 8;

void HSRendererMetal::drawGooField(const HSGooField &field){
	if(!st->inGoo)
		fail("drawGooField", "outside beginGoo/endGoo");
	// One vertex buffer serves the frame, and a second build would overwrite
	// the first before either is drawn.
	if(st->gooBuildCommands)
		fail("drawGooField", "called twice in a frame");
	const NSUInteger blocks = field.offsets.size() / 2;
	const NSUInteger res = NSUInteger(field.resolution);
	if(blocks == 0 || res == 0)
		return;
	// Sized for this frame's blocks, and for the most any build has needed,
	// with a quarter to spare. The peak is read without waiting, so a frame
	// that needs more than ever before drops cells until its build has
	// finished -- a frame or two -- and the buffer grows.
	NSUInteger want = blocks * res * res * kGooTrianglesPerSquare * 3;
	want = std::max(want, NSUInteger(*(const uint32_t *)st->gooPeak.contents) * 5 / 4);
	// Capped at what the device can allocate and a 32-bit count can index:
	// Resolution and Depth read from the defaults are not clamped, and a
	// field too big for the cap draws what fits.
	want = std::min(want, NSUInteger(st->device.maxBufferLength / (sizeof(float) * 6)));
	want = std::min(want, NSUInteger(UINT32_MAX / 2));
	want = want / 3 * 3;   // whole triangles: the draw stops at the capacity
	if(want > st->gooCapacity){
		id<MTLBuffer> grown = [st->device newBufferWithLength:want * sizeof(float) * 6 options:MTLResourceStorageModePrivate];
		if(grown){   // out of memory: keep drawing into what there is
			st->gooVertices = grown;
			st->gooCapacity = want;
		}
	}
	if(!st->gooVertices)
		return;
	// The kernel's counter is 32 bits and counts every vertex the field
	// needs, fitted or not: at most 15 a cell. Past 2^32 it would wrap, so a
	// field that could reach that is cut to the blocks that cannot.
	const NSUInteger maxBlocks = NSUInteger(UINT32_MAX) / (15 * res * res * res);
	const NSUInteger built = std::min(blocks, maxBlocks);
	GooBuildUniforms u;
	u.c = simd_make_float4(field.c[0], field.c[1], field.c[2], field.c[3]);
	u.cam = simd_make_float2(field.camx, field.camz);
	u.origin = simd_make_float2(field.origin[0], field.origin[1]);
	u.unitSize = field.unitSize;
	u.halfVolume = 0.5f * field.volumeSize;
	u.surface = field.surface;
	u.resolution = uint32_t(res);
	u.maxVertices = uint32_t(st->gooCapacity);
	u.pad[0] = u.pad[1] = u.pad[2] = 0;

	// Built in a command buffer of its own, committed now, ahead of the
	// frame's, which is committed at endFrame. Commit order alone only orders
	// when the two start: what makes the frame's draw wait for the build, and
	// the next build wait for this frame's draw, is Metal's hazard tracking on
	// gooVertices, gooArgs and gooCounter -- the default for buffers made with
	// newBuffer, as these are. Moving them onto a heap, or making them
	// untracked, needs an MTLEvent in its place. Building inside the frame's
	// buffer would mean ending its render pass and reloading the target.
	id<MTLCommandBuffer> build = [st->queue commandBuffer];
	id<MTLBlitCommandEncoder> blit = [build blitCommandEncoder];
	[blit fillBuffer:st->gooCounter range:NSMakeRange(0, sizeof(uint32_t)) value:0];
	[blit endEncoding];
	id<MTLComputeCommandEncoder> ce = [build computeCommandEncoder];
	[ce setComputePipelineState:st->gooBuild];
	[ce setBytes:&u length:sizeof u atIndex:0];
	[ce setBuffer:st->gooTable offset:0 atIndex:2];
	[ce setBuffer:st->gooCounter offset:0 atIndex:3];
	[ce setBuffer:st->gooVertices offset:0 atIndex:4];
	// setBytes carries 4 KB at most, 512 blocks' offsets, so the blocks go in
	// dispatches of that many. The saver's own settings choose 400 at most, so
	// it is one dispatch; a Depth written to the defaults directly is not
	// clamped, and can choose more. All share the counter, so their triangles
	// land one after another.
	const NSUInteger kBlocksPerDispatch = 4096 / (2 * sizeof(float));
	for(NSUInteger first = 0; first < built; first += kBlocksPerDispatch){
		const NSUInteger n = std::min(kBlocksPerDispatch, built - first);
		[ce setBytes:field.offsets.data() + 2 * first length:n * 2 * sizeof(float) atIndex:1];
		[ce dispatchThreads:MTLSizeMake(res, res, res * n) threadsPerThreadgroup:MTLSizeMake(4, 4, 4)];
	}
	[ce setComputePipelineState:st->gooBuildCount];
	[ce setBuffer:st->gooArgs offset:0 atIndex:5];
	[ce setBuffer:st->gooPeak offset:0 atIndex:6];
	[ce dispatchThreads:MTLSizeMake(1, 1, 1) threadsPerThreadgroup:MTLSizeMake(1, 1, 1)];
	[ce endEncoding];
	[build addCompletedHandler:^(id<MTLCommandBuffer> done){
		if(done.status == MTLCommandBufferStatusError)
			NSLog(@"HSRendererMetal: the GPU failed the goo's build: %@", done.error.localizedDescription);
	}];
	[build commit];
	st->gooBuildCommands = build;

	simd_float4x4 model = matrix_identity_float4x4;
	model.columns[3] = simd_make_float4(field.origin[0], 0.0f, field.origin[1], 1.0f);
	st->gooDraws++;
	// Soft: drawn into a target half the frame's width and height. A target
	// that cannot be had draws the goo sharp rather than not at all.
	const NSUInteger w = std::max<NSUInteger>(1, (st->target.width + 1) / 2);
	const NSUInteger h = std::max<NSUInteger>(1, (st->target.height + 1) / 2);
	if(st->softGoo && (!st->gooTarget || st->gooTarget.width != w || st->gooTarget.height != h ||
		st->gooTarget.pixelFormat != st->pipelineFormat)){
		MTLTextureDescriptor *td = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:st->pipelineFormat
			width:w height:h mipmapped:NO];
		td.usage = MTLTextureUsageRenderTarget | MTLTextureUsageShaderRead;
		td.storageMode = MTLStorageModePrivate;
		st->gooTarget = [st->device newTextureWithDescriptor:td];
	}
	if(!st->softGoo || !st->gooTarget){
		bindGoo(st, st->encoder, model, st->gooVertices);
		[st->encoder drawPrimitives:MTLPrimitiveTypeTriangle indirectBuffer:st->gooArgs indirectBufferOffset:0];
		st->draws++;
		return;
	}

	// In a command buffer committed now -- after the build, before the frame
	// -- so the frame's render pass is not split; then added over the frame.
	MTLRenderPassDescriptor *rp = [MTLRenderPassDescriptor renderPassDescriptor];
	rp.colorAttachments[0].texture = st->gooTarget;
	rp.colorAttachments[0].loadAction = MTLLoadActionClear;
	rp.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 0, 0);
	rp.colorAttachments[0].storeAction = MTLStoreActionStore;
	id<MTLCommandBuffer> soft = [st->queue commandBuffer];
	id<MTLRenderCommandEncoder> se = [soft renderCommandEncoderWithDescriptor:rp];
	// The frame's viewport, scaled as the target is.
	const double sx = double(w) / double(st->target.width), sy = double(h) / double(st->target.height);
	MTLViewport vp = {st->viewport.originX * sx, st->viewport.originY * sy,
		st->viewport.width * sx, st->viewport.height * sy, 0.0, 1.0};
	[se setViewport:vp];
	[se setCullMode:MTLCullModeNone];
	[se setRenderPipelineState:st->gooTargetPipeline];
	bindGooTextures(st, se);
	bindGoo(st, se, model, st->gooVertices);
	[se drawPrimitives:MTLPrimitiveTypeTriangle indirectBuffer:st->gooArgs indirectBufferOffset:0];
	[se endEncoding];
	[soft addCompletedHandler:^(id<MTLCommandBuffer> done){
		if(done.status == MTLCommandBufferStatusError)
			NSLog(@"HSRendererMetal: the GPU failed the soft goo: %@", done.error.localizedDescription);
	}];
	[soft commit];
	st->softCommands = soft;

	// Added over the whole target, which the goo target spans, but cut to the
	// frame's viewport, which the blur would otherwise spread past. Nothing
	// else draws in the goo pass (a second drawGooField fails), and every
	// draw binds its own pipeline and textures, so softenPipeline and the goo
	// target may stay bound; only the viewport and scissor are put back.
	const NSUInteger tw = st->target.width, th = st->target.height;
	const double x0 = std::max(0.0, st->viewport.originX), y0 = std::max(0.0, st->viewport.originY);
	const double x1 = std::min(double(tw), st->viewport.originX + st->viewport.width);
	const double y1 = std::min(double(th), st->viewport.originY + st->viewport.height);
	if(x1 > x0 && y1 > y0){
		const MTLScissorRect cut = {NSUInteger(x0), NSUInteger(y0), NSUInteger(x1) - NSUInteger(x0), NSUInteger(y1) - NSUInteger(y0)};
		MTLViewport whole = {0.0, 0.0, double(tw), double(th), 0.0, 1.0};
		[st->encoder setViewport:whole];
		[st->encoder setScissorRect:cut];
		[st->encoder setRenderPipelineState:st->softenPipeline];
		[st->encoder setFragmentTexture:st->gooTarget atIndex:0];
		[st->encoder drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3];
		[st->encoder setScissorRect:(MTLScissorRect){0, 0, tw, th}];
		[st->encoder setViewport:st->viewport];
		st->draws++;
	}
	st->draws++;
}

void HSRendererMetal::drawGooSphere(const float center[3], float radius){
	if(!st->inGoo)
		fail("drawGooSphere", "outside beginGoo/endGoo");
	simd_float4x4 model = matrix_identity_float4x4;
	model.columns[0].x = model.columns[1].y = model.columns[2].z = radius;
	model.columns[3] = simd_make_float4(center[0], center[1], center[2], 1.0f);
	if(!st->sphere){
		std::vector<float> sphere;
		float band[HS_SPHERE_BAND_POINTS][3];
		for(int b = 0; b < HS_SPHERE_BANDS; b++){
			hsSphereBand(b, band);
			for(int i = 0; i < HS_SPHERE_BAND_POINTS; i++)
				for(int n = 0; n < 2; n++)   // the unit sphere's normal is its position
					sphere.insert(sphere.end(), band[i], band[i] + 3);
		}
		st->sphere = [st->device newBufferWithBytes:sphere.data() length:sphere.size() * sizeof(float)
			options:MTLResourceStorageModeShared];
	}
	// Bound again for every band, though nothing changes: bound once, the 32
	// draws rasterize differently along the band seams (measured: 3-19 pixels
	// a shot more than 8 levels off), and further from GL (burst 0.512% lit>2
	// against 0.490%).
	for(int b = 0; b < HS_SPHERE_BANDS; b++){
		bindGoo(st, st->encoder, model, st->sphere);
		[st->encoder drawPrimitives:MTLPrimitiveTypeTriangleStrip vertexStart:NSUInteger(b) * HS_SPHERE_BAND_POINTS vertexCount:HS_SPHERE_BAND_POINTS];
	}
	st->draws += HS_SPHERE_BANDS;
}

void HSRendererMetal::endGoo(){
	if(!st->inGoo)
		fail("endGoo", "no beginGoo");
	st->inGoo = false;
}
void HSRendererMetal::beginTunnel(unsigned int caustic0, unsigned int caustic1, float lerp, bool shaded){
	if(!st->encoder)
		fail("beginTunnel", "outside a frame");
	if(st->inGoo || st->inTunnel || st->inOverlay)
		fail("beginTunnel", "inside the goo, the tunnel or the overlay");
	flushQuads(st);
	// The Metal port draws the shaded look only; the shaders-off look is ss-5dl.
	if(!shaded)
		fail("beginTunnel", "the shaders-off tunnel is not drawn on Metal (ss-5dl)");
	const unsigned int names[2] = {caustic0, caustic1};
	for(int t = 0; t < 2; t++){
		std::map<unsigned int, Texture>::const_iterator tex = st->textures.find(names[t]);
		if(tex == st->textures.end() || tex->second.texture.textureType != MTLTextureType2D)
			fail("beginTunnel", "a caustic texture is not a 2D texture this backend made");
		[st->encoder setFragmentTexture:tex->second.texture atIndex:t];
		[st->encoder setFragmentSamplerState:tex->second.sampler atIndex:t];
	}
	st->tunnelAlpha = lerp;
	st->inTunnel = true;
	[st->encoder setRenderPipelineState:st->tunnelPipeline];
	// GL culls back faces, front faces counter-clockwise; Metal's default
	// winding is clockwise.
	[st->encoder setFrontFacingWinding:MTLWindingCounterClockwise];
	[st->encoder setCullMode:MTLCullModeBack];
	// The tunnel is in world space: the camera is its whole modelview.
	TunnelUniforms u;
	u.modelview = st->view;
	u.mvp = simd_mul(st->clipProjection, st->view);
	u.projection = st->clipProjection;
	u.fogColor = simd_make_float4(0, 0, 0, 1);
	u.fogEnd = st->fogEnd;
	u.fogScale = 1.0f / (st->fogEnd - st->fogStart);
	[st->encoder setVertexBytes:&u length:sizeof u atIndex:1];
	[st->encoder setFragmentBytes:&u length:sizeof u atIndex:1];
}

// This backend builds the tunnel itself (buildsTunnel), so tunnel::draw never
// hands it strips.
void HSRendererMetal::drawTunnelStrip(const HSTunnelVertex *v, int count){
	(void)v;
	(void)count;
	fail("drawTunnelStrip", "this backend builds the tunnel itself: draw it with drawTunnelField");
}

bool HSRendererMetal::buildsTunnel() const{
	return true;
}

// One instanced draw: instance k * resolution + i is section k's strip
// between rings i and i + 1, built by tunnel_build_vertex from the path.
void HSRendererMetal::drawTunnelField(const HSTunnelField &field){
	if(!st->inTunnel)
		fail("drawTunnelField", "outside beginTunnel/endTunnel");
	const int numPoints = int(field.points.size() / 3);
	if(field.directions.size() != field.points.size())
		fail("drawTunnelField", "the path has as many directions as points");
	if(field.numSections < 1 || field.resolution < 1)
		return;
	if(field.numSections + 4 > numPoints)
		fail("drawTunnelField", "a section needs the path's points k + 1 to k + 4");
	std::vector<simd_float4> &path = st->tunnelPath;
	path.resize(2 * size_t(numPoints));
	for(int p = 0; p < numPoints; p++){
		const float *x = &field.points[3 * p], *d = &field.directions[3 * p];
		path[p] = simd_make_float4(x[0], x[1], x[2], 0.0f);
		path[numPoints + p] = simd_make_float4(d[0], d[1], d[2], 0.0f);
	}
	TunnelShape shape;
	shape.radius = field.radius;
	shape.widthOffset = field.widthOffset;
	shape.texShift = field.texShift;
	shape.texcoordMult = field.texcoordMult;
	shape.maxSaturation = field.maxSaturation;
	shape.alpha = st->tunnelAlpha;
	shape.huelo = field.huelo;
	shape.satlo = field.satlo;
	shape.sathi = field.sathi;
	shape.lumlo = field.lumlo;
	shape.lumhi = field.lumhi;
	shape.resolution = uint32_t(field.resolution);
	shape.numPoints = uint32_t(numPoints);
	[st->encoder setVertexBytes:&shape length:sizeof shape atIndex:0];
	// The saver's longest path, depth 10, is 26 points: 832 bytes.
	const size_t bytes = path.size() * sizeof(simd_float4);
	if(bytes <= 4096)
		[st->encoder setVertexBytes:path.data() length:bytes atIndex:2];
	else
		[st->encoder setVertexBuffer:[st->device newBufferWithBytes:path.data() length:bytes
			options:MTLResourceStorageModeShared] offset:0 atIndex:2];
	[st->encoder drawPrimitives:MTLPrimitiveTypeTriangleStrip vertexStart:0
		vertexCount:NSUInteger(2 * (field.resolution + 1))
		instanceCount:NSUInteger(field.numSections * field.resolution)];
	st->draws++;
	st->tunnelDraws++;
}

void HSRendererMetal::endTunnel(){
	if(!st->inTunnel)
		fail("endTunnel", "no beginTunnel");
	st->inTunnel = false;
	[st->encoder setCullMode:MTLCullModeNone];
	[st->encoder setFrontFacingWinding:MTLWindingClockwise];   // Metal's default, as beginFrame left it
}
