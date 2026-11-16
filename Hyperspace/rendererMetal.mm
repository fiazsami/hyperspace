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
	id<MTLRenderPipelineState> ffPipeline, gooPipeline, tunnelPipeline;
	MTLPixelFormat pipelineFormat;
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
	std::vector<ImmediateVertex> tunnelStrip;   // reused: a tunnel draws about 200 strips a frame
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
};

static NSString *readSource(const char *dir, const char *file){
	NSString *path = [@(dir) stringByAppendingPathComponent:@(file)];
	NSError *err = nil;
	NSString *s = [NSString stringWithContentsOfFile:path encoding:NSUTF8StringEncoding error:&err];
	if(!s)
		fail("cannot read", path.UTF8String);
	return s;
}

// A texture the GPU renders into and the CPU then reads. Apple silicon shares
// memory, so Shared; an Intel Mac's GPU, which macOS 26 still runs on, cannot
// share a texture, so Managed, synchronized before the read. The macOS 27 SDK
// deprecates Managed because it does nothing on Apple silicon -- which is the
// branch that never uses it.
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
static MTLStorageMode readableStorage(id<MTLDevice> device){
	return device.hasUnifiedMemory ? MTLStorageModeShared : MTLStorageModeManaged;
}
static void synchronizeForCPU(id<MTLCommandBuffer> commands, id<MTLTexture> texture){
	if(texture.storageMode != MTLStorageModeManaged)
		return;
	id<MTLBlitCommandEncoder> blit = [commands blitCommandEncoder];
	[blit synchronizeResource:texture];
	[blit endEncoding];
}
#pragma clang diagnostic pop

// Each pass file is compiled with the interface prepended, as parity does.
static id<MTLLibrary> compilePass(id<MTLDevice> device, const char *dir, const char *file){
	NSString *src = [readSource(dir, "Interface.metal") stringByAppendingString:readSource(dir, file)];
	NSError *err = nil;
	id<MTLLibrary> lib = [device newLibraryWithSource:src options:nil error:&err];
	if(!lib)
		fail(file, err.localizedDescription.UTF8String);
	return lib;
}

// Everything Hyperspace draws is blended (SRC_ALPHA, ONE).
static id<MTLRenderPipelineState> additivePipeline(id<MTLDevice> device, id<MTLLibrary> lib,
	NSString *vfn, NSString *ffn, MTLPixelFormat format){
	MTLRenderPipelineDescriptor *pd = [MTLRenderPipelineDescriptor new];
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
	st->tunnelLibrary = compilePass(st->device, metalDir, "Tunnel.metal");
	st->ffPipeline = st->gooPipeline = st->tunnelPipeline = nil;
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
}

HSRendererMetal::~HSRendererMetal(){
	// An encoder released mid-frame asserts; end it, and drop the frame.
	if(st->encoder)
		[st->encoder endEncoding];
	if(st->offscreenEncoder)
		[st->offscreenEncoder endEncoding];
	delete st;
}

// Pipelines are built for the target's pixel format, so a new format rebuilds them.
static void useTarget(HSRendererMetalState *st, id<MTLTexture> target){
	st->target = target;
	if(st->target.pixelFormat == st->pipelineFormat)
		return;
	st->ffPipeline = additivePipeline(st->device, st->ffLibrary, @"ff_vertex", @"ff_fragment", st->target.pixelFormat);
	st->gooPipeline = additivePipeline(st->device, st->gooLibrary, @"goo_vertex", @"goo_fragment", st->target.pixelFormat);
	st->tunnelPipeline = additivePipeline(st->device, st->tunnelLibrary, @"tunnel_vertex", @"tunnel_fragment", st->target.pixelFormat);
	st->pipelineFormat = st->target.pixelFormat;
}

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

void *HSRendererMetal::texture(unsigned int name) const{
	std::map<unsigned int, Texture>::const_iterator t = st->textures.find(name);
	return t == st->textures.end() ? NULL : (__bridge void *)t->second.texture;
}

void HSRendererMetal::beginFrame(const HSFrame &frame){
	if(!st->target)
		fail("beginFrame", "no target: call setTarget first");
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

	MTLRenderPassDescriptor *rp = [MTLRenderPassDescriptor renderPassDescriptor];
	rp.colorAttachments[0].texture = st->target;
	rp.colorAttachments[0].loadAction = MTLLoadActionClear;
	rp.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 0, 1);
	rp.colorAttachments[0].storeAction = MTLStoreActionStore;
	st->commands = [st->queue commandBuffer];
	st->encoder = [st->commands renderCommandEncoderWithDescriptor:rp];
	// GL's viewport origin is the bottom left, Metal's the top left. Signed:
	// a viewport taller than the target hangs off its top, as it would in GL.
	MTLViewport vp = {double(frame.viewport[0]), double(st->target.height) - frame.viewport[1] - frame.viewport[3],
		double(frame.viewport[2]), double(frame.viewport[3]), 0.0, 1.0};
	[st->encoder setViewport:vp];
	[st->encoder setCullMode:MTLCullModeNone];
	[st->encoder setRenderPipelineState:st->ffPipeline];
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

void HSRendererMetal::drawQuad(unsigned int texture, const float color[4], const float model[16], float half){
	if(!st->encoder)
		fail("drawQuad", "outside a frame");
	// The goo's pipeline and cube textures are bound until endGoo.
	if(st->inGoo || st->inTunnel)
		fail("drawQuad", "inside beginGoo/endGoo or beginTunnel/endTunnel");
	std::map<unsigned int, Texture>::const_iterator tex = st->textures.find(texture);
	if(tex == st->textures.end())
		fail("drawQuad", "unknown texture");

	float identity[16];
	HSVertex q[4];
	hsIdentity(identity);
	hsQuad(identity, half, q);
	ImmediateVertex v[4];
	for(int i = 0; i < 4; i++){
		v[i].position[0] = q[i].pos[0]; v[i].position[1] = q[i].pos[1]; v[i].position[2] = q[i].pos[2];
		v[i].pad0 = 0.0f;
		v[i].texcoord[0] = q[i].uv[0]; v[i].texcoord[1] = q[i].uv[1];
		v[i].pad1[0] = v[i].pad1[1] = 0.0f;
		for(int c = 0; c < 4; c++)
			v[i].color[c] = color[c];
	}

	// The model matrix applies after the camera, as GL's matrix stack did.
	FFUniforms u;
	u.modelview = simd_mul(st->view, fromGL(model));
	u.mvp = simd_mul(st->clipProjection, u.modelview);
	u.fogColor = simd_make_float4(0, 0, 0, 1);
	u.fogStart = st->fogStart;
	u.fogEnd = st->fogEnd;
	u.fogOn = st->fog && !st->inOverlay;
	u.texOn = 1;
	[st->encoder setVertexBytes:v length:sizeof v atIndex:0];
	[st->encoder setVertexBytes:&u length:sizeof u atIndex:1];
	[st->encoder setFragmentBytes:&u length:sizeof u atIndex:1];
	[st->encoder setFragmentTexture:tex->second.texture atIndex:0];
	[st->encoder setFragmentSamplerState:tex->second.sampler atIndex:0];
	[st->encoder drawPrimitives:MTLPrimitiveTypeTriangleStrip vertexStart:0 vertexCount:4];
	st->draws++;
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
		td.storageMode = readableStorage(st->device);
		st->offscreenTarget = [st->device newTextureWithDescriptor:td];
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
	synchronizeForCPU(st->offscreenCommands, st->offscreenTarget);
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
	// The Metal port draws the shaded look only; the shaders-off look is ss-5dl.
	if(!shaded)
		fail("beginGoo", "the shaders-off goo is not drawn on Metal (ss-5dl)");
	const unsigned int names[3] = {normals0, normals1, nebula};
	for(int t = 0; t < 3; t++){
		std::map<unsigned int, Texture>::const_iterator tex = st->textures.find(names[t]);
		if(tex == st->textures.end() || tex->second.texture.textureType != MTLTextureTypeCube)
			fail("beginGoo", "a goo texture is not a cube map this backend made");
		[st->encoder setFragmentTexture:tex->second.texture atIndex:t];
		[st->encoder setFragmentSamplerState:tex->second.sampler atIndex:t];
		st->gooTextures[t] = names[t];
	}
	st->gooColor = simd_make_float4(color[0], color[1], color[2], color[3]);
	st->inGoo = true;
	[st->encoder setRenderPipelineState:st->gooPipeline];
}

// Binds goo vertices, GooVertex (normal, then position), placed by model after
// the camera, as glTranslatef/glScalef on the modelview did.
static void bindGoo(HSRendererMetalState *st, const simd_float4x4 &model, id<MTLBuffer> vertices){
	GooUniforms u;
	u.modelview = simd_mul(st->view, model);
	u.mvp = simd_mul(st->clipProjection, u.modelview);
	u.color = st->gooColor;
	u.fogColor = simd_make_float4(0, 0, 0, 1);
	u.fogEnd = st->fogEnd;
	u.fogScale = 1.0f / (st->fogEnd - st->fogStart);
	u.projection = st->clipProjection;
	[st->encoder setVertexBuffer:vertices offset:0 atIndex:0];
	[st->encoder setVertexBytes:&u length:sizeof u atIndex:1];
	[st->encoder setFragmentBytes:&u length:sizeof u atIndex:1];
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
	want = (want + 2) / 3 * 3;   // whole triangles: the draw stops at the capacity
	if(want > st->gooCapacity){
		st->gooVertices = [st->device newBufferWithLength:want * sizeof(float) * 6 options:MTLResourceStorageModePrivate];
		st->gooCapacity = want;
	}
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
	for(NSUInteger first = 0; first < blocks; first += kBlocksPerDispatch){
		const NSUInteger n = std::min(kBlocksPerDispatch, blocks - first);
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
	bindGoo(st, model, st->gooVertices);
	[st->encoder drawPrimitives:MTLPrimitiveTypeTriangle indirectBuffer:st->gooArgs indirectBufferOffset:0];
	st->draws++;
	st->gooDraws++;
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
		bindGoo(st, model, st->sphere);
		[st->encoder drawPrimitives:MTLPrimitiveTypeTriangleStrip vertexStart:NSUInteger(b) * HS_SPHERE_BAND_POINTS vertexCount:HS_SPHERE_BAND_POINTS];
	}
	st->draws += HS_SPHERE_BANDS;
}

void HSRendererMetal::endGoo(){
	if(!st->inGoo)
		fail("endGoo", "no beginGoo");
	st->inGoo = false;
	[st->encoder setRenderPipelineState:st->ffPipeline];
}
void HSRendererMetal::beginTunnel(unsigned int caustic0, unsigned int caustic1, float lerp, bool shaded){
	if(!st->encoder)
		fail("beginTunnel", "outside a frame");
	if(st->inGoo || st->inTunnel || st->inOverlay)
		fail("beginTunnel", "inside the goo, the tunnel or the overlay");
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

void HSRendererMetal::drawTunnelStrip(const HSTunnelVertex *v, int count){
	if(!st->inTunnel)
		fail("drawTunnelStrip", "outside beginTunnel/endTunnel");
	if(count < 3)
		return;
	std::vector<ImmediateVertex> &verts = st->tunnelStrip;
	verts.resize(count);
	for(int i = 0; i < count; i++){
		ImmediateVertex &o = verts[i];
		o.position[0] = v[i].pos[0]; o.position[1] = v[i].pos[1]; o.position[2] = v[i].pos[2];
		o.pad0 = 0.0f;
		o.texcoord[0] = v[i].uv[0]; o.texcoord[1] = v[i].uv[1];
		o.pad1[0] = o.pad1[1] = 0.0f;
		o.color[0] = v[i].color[0]; o.color[1] = v[i].color[1]; o.color[2] = v[i].color[2];
		o.color[3] = st->tunnelAlpha;
	}
	// The saver's strips are 42 vertices, about 2 KB: small enough for
	// setVertexBytes, which Metal limits to 4 KB. A longer strip gets a buffer.
	const size_t bytes = verts.size() * sizeof(ImmediateVertex);
	if(bytes <= 4096)
		[st->encoder setVertexBytes:verts.data() length:bytes atIndex:0];
	else
		[st->encoder setVertexBuffer:[st->device newBufferWithBytes:verts.data() length:bytes
			options:MTLResourceStorageModeShared] offset:0 atIndex:0];
	[st->encoder drawPrimitives:MTLPrimitiveTypeTriangleStrip vertexStart:0 vertexCount:NSUInteger(count)];
	st->draws++;
	st->tunnelDraws++;
}

void HSRendererMetal::endTunnel(){
	if(!st->inTunnel)
		fail("endTunnel", "no beginTunnel");
	st->inTunnel = false;
	[st->encoder setCullMode:MTLCullModeNone];
	[st->encoder setFrontFacingWinding:MTLWindingClockwise];   // Metal's default, as beginFrame left it
	[st->encoder setRenderPipelineState:st->ffPipeline];
}
