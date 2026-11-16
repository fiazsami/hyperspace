/*
 * HSRenderer on Metal. See rendererMetal.h.
 */

#import <Metal/Metal.h>
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

struct Texture {
	id<MTLTexture> texture;
	id<MTLSamplerState> sampler;
};

[[noreturn]] void fail(const char *what, const char *detail){
	fprintf(stderr, "HSRendererMetal: %s%s%s\n", what, detail ? ": " : "", detail ? detail : "");
	abort();
}

[[noreturn]] void notYet(const char *call){
	fail(call, "not implemented on Metal yet (ss-a4a.4.2)");
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

// glOrtho(0, aspect, 0, 1, -1, 1).
simd_float4x4 overlayProjection(float aspect){
	simd_float4x4 m = matrix_identity_float4x4;
	m.columns[0] = simd_make_float4(2.0f / aspect, 0, 0, 0);
	m.columns[1] = simd_make_float4(0, 2.0f, 0, 0);
	m.columns[2] = simd_make_float4(0, 0, -1.0f, 0);
	m.columns[3] = simd_make_float4(-1.0f, -1.0f, 0, 1);
	return m;
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
	id<MTLLibrary> ffLibrary, gooLibrary;
	id<MTLRenderPipelineState> ffPipeline, gooPipeline;
	MTLPixelFormat pipelineFormat;
	id<MTLTexture> target;
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
	int draws;
	bool inGoo;
	simd_float4 gooColor;
	unsigned int gooTextures[3];   // normals0, normals1, nebula: Goo.metal's texture(0..2)
	id<MTLBuffer> sphere;          // hsSphereBand's bands, one after another, as GooVertex
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

HSRendererMetal::HSRendererMetal(void *device, const char *metalDir) : st(new HSRendererMetalState){
	st->device = (__bridge id<MTLDevice>)device;
	st->queue = [st->device newCommandQueue];
	st->ffLibrary = compilePass(st->device, metalDir, "FixedFunction.metal");
	st->gooLibrary = compilePass(st->device, metalDir, "Goo.metal");
	st->ffPipeline = st->gooPipeline = nil;
	st->pipelineFormat = MTLPixelFormatInvalid;
	st->target = nil;
	st->commands = nil;
	st->encoder = nil;
	st->nextName = 1;
	st->projection = st->view = st->clipProjection = matrix_identity_float4x4;
	st->savedProjection = st->savedView = matrix_identity_float4x4;
	st->inOverlay = false;
	st->fog = true;
	st->fogStart = st->fogEnd = 0.0f;
	st->draws = 0;
	MTLSamplerDescriptor *sd = [MTLSamplerDescriptor new];
	sd.minFilter = sd.magFilter = MTLSamplerMinMagFilterLinear;
	sd.mipFilter = MTLSamplerMipFilterNotMipmapped;
	sd.sAddressMode = sd.tAddressMode = MTLSamplerAddressModeRepeat;
	st->linear = [st->device newSamplerStateWithDescriptor:sd];
	sd.mipFilter = MTLSamplerMipFilterLinear;
	st->mipmapped = [st->device newSamplerStateWithDescriptor:sd];
	// GL clamps s and t and leaves r at REPEAT, and filters each face alone;
	// Metal filters cube maps across faces. Whether either shows is the goo's
	// parity to judge (ss-a4a.4.2 slice 3): nothing samples a cube before it.
	sd.sAddressMode = sd.tAddressMode = sd.rAddressMode = MTLSamplerAddressModeClampToEdge;
	st->cube = [st->device newSamplerStateWithDescriptor:sd];
	st->inGoo = false;
	st->gooColor = simd_make_float4(1, 1, 1, 1);
	st->gooTextures[0] = st->gooTextures[1] = st->gooTextures[2] = 0;

	std::vector<float> sphere;
	float band[HS_SPHERE_BAND_POINTS][3];
	for(int b = 0; b < HS_SPHERE_BANDS; b++){
		hsSphereBand(b, band);
		for(int i = 0; i < HS_SPHERE_BAND_POINTS; i++)
			for(int n = 0; n < 2; n++)   // the unit sphere's normal is its position
				sphere.insert(sphere.end(), band[i], band[i] + 3);
	}
	st->sphere = [st->device newBufferWithBytes:sphere.data() length:sphere.size() * sizeof(float) options:MTLResourceStorageModeShared];
}

HSRendererMetal::~HSRendererMetal(){
	// An encoder released mid-frame asserts; end it, and drop the frame.
	if(st->encoder)
		[st->encoder endEncoding];
	delete st;
}

void HSRendererMetal::setTarget(void *target){
	if(st->encoder)
		fail("setTarget", "called inside a frame");
	st->target = (__bridge id<MTLTexture>)target;
	if(st->target.pixelFormat == st->pipelineFormat)
		return;
	st->ffPipeline = additivePipeline(st->device, st->ffLibrary, @"ff_vertex", @"ff_fragment", st->target.pixelFormat);
	st->gooPipeline = additivePipeline(st->device, st->gooLibrary, @"goo_vertex", @"goo_fragment", st->target.pixelFormat);
	st->pipelineFormat = st->target.pixelFormat;
}

int HSRendererMetal::drawCount() const{
	return st->draws;
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
	st->draws = 0;

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
	[st->encoder endEncoding];
	[st->commands commit];
	[st->commands waitUntilCompleted];
	if(st->commands.status == MTLCommandBufferStatusError)
		fail("the GPU failed the frame", st->commands.error.localizedDescription.UTF8String);
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

void HSRendererMetal::beginOffscreen(int){ notYet("beginOffscreen"); }
void HSRendererMetal::drawColorStrip(const HSColorVertex *, int){ notYet("drawColorStrip"); }
void HSRendererMetal::endOffscreen(unsigned char *){ notYet("endOffscreen"); }
void HSRendererMetal::beginGoo(const float color[4], unsigned int nebula,
	unsigned int normals0, unsigned int normals1, bool shaded){
	if(!st->encoder)
		fail("beginGoo", "outside a frame");
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

// One goo draw: vertices are GooVertex (normal, then position), placed by model
// after the camera, as glTranslatef/glScalef on the modelview did.
static void drawGoo(HSRendererMetalState *st, const simd_float4x4 &model, id<MTLBuffer> vertices,
	id<MTLBuffer> indices, NSUInteger count, MTLPrimitiveType type, NSUInteger start){
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
	if(indices)
		[st->encoder drawIndexedPrimitives:type indexCount:count indexType:MTLIndexTypeUInt32 indexBuffer:indices indexBufferOffset:0];
	else
		[st->encoder drawPrimitives:type vertexStart:start vertexCount:count];
	st->draws++;
}

void HSRendererMetal::drawGooSurface(impSurface *surface, const float offset[3]){
	if(!st->inGoo)
		fail("drawGooSurface", "outside beginGoo/endGoo");
	const unsigned int vertexCount = surface->getVertexCount(), indexCount = surface->getIndexCount();
	if(vertexCount == 0 || indexCount == 0)
		return;
	std::vector<unsigned int> indices(indexCount);
	for(unsigned int i = 0; i < indexCount; i++)
		indices[i] = surface->getIndex(i);
	id<MTLBuffer> vb = [st->device newBufferWithBytes:surface->getVertex(0) length:size_t(vertexCount) * 6 * sizeof(float)
		options:MTLResourceStorageModeShared];
	id<MTLBuffer> ib = [st->device newBufferWithBytes:indices.data() length:indices.size() * sizeof(unsigned int)
		options:MTLResourceStorageModeShared];
	simd_float4x4 model = matrix_identity_float4x4;
	model.columns[3] = simd_make_float4(offset[0], offset[1], offset[2], 1.0f);
	drawGoo(st, model, vb, ib, indexCount, MTLPrimitiveTypeTriangle, 0);
}

void HSRendererMetal::drawGooSphere(const float center[3], float radius){
	if(!st->inGoo)
		fail("drawGooSphere", "outside beginGoo/endGoo");
	simd_float4x4 model = matrix_identity_float4x4;
	model.columns[0].x = model.columns[1].y = model.columns[2].z = radius;
	model.columns[3] = simd_make_float4(center[0], center[1], center[2], 1.0f);
	for(int b = 0; b < HS_SPHERE_BANDS; b++)
		drawGoo(st, model, st->sphere, nil, HS_SPHERE_BAND_POINTS, MTLPrimitiveTypeTriangleStrip, NSUInteger(b) * HS_SPHERE_BAND_POINTS);
}

void HSRendererMetal::endGoo(){
	if(!st->inGoo)
		fail("endGoo", "no beginGoo");
	st->inGoo = false;
	[st->encoder setRenderPipelineState:st->ffPipeline];
}
void HSRendererMetal::beginTunnel(unsigned int, unsigned int, float, bool){ notYet("beginTunnel"); }
void HSRendererMetal::drawTunnelStrip(const HSTunnelVertex *, int){ notYet("drawTunnelStrip"); }
void HSRendererMetal::endTunnel(){ notYet("endTunnel"); }
