/*
 * HSRenderer on Metal. See rendererMetal.h.
 */

#import <Metal/Metal.h>
#import <simd/simd.h>
#include <Hyperspace/rendererMetal.h>
#include <Hyperspace/transform.h>
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
	id<MTLLibrary> ffLibrary;
	id<MTLRenderPipelineState> ffPipeline;
	MTLPixelFormat pipelineFormat;
	id<MTLTexture> target;
	id<MTLCommandBuffer> commands;
	id<MTLRenderCommandEncoder> encoder;
	std::map<unsigned int, Texture> textures;
	unsigned int nextName;
	simd_float4x4 projection, view;   // the frame's, as GL takes them
	simd_float4x4 savedProjection, savedView;
	bool inOverlay;
	bool fog;
	float fogStart, fogEnd;
	int draws;
};

static NSString *readSource(const char *dir, const char *file){
	NSString *path = [@(dir) stringByAppendingPathComponent:@(file)];
	NSError *err = nil;
	NSString *s = [NSString stringWithContentsOfFile:path encoding:NSUTF8StringEncoding error:&err];
	if(!s)
		fail("cannot read", path.UTF8String);
	return s;
}

HSRendererMetal::HSRendererMetal(void *device, const char *metalDir) : st(new HSRendererMetalState){
	st->device = (__bridge id<MTLDevice>)device;
	st->queue = [st->device newCommandQueue];
	// Each pass file is compiled with the interface prepended, as parity does.
	NSString *src = [readSource(metalDir, "Interface.metal") stringByAppendingString:readSource(metalDir, "FixedFunction.metal")];
	NSError *err = nil;
	st->ffLibrary = [st->device newLibraryWithSource:src options:nil error:&err];
	if(!st->ffLibrary)
		fail("FixedFunction.metal does not compile", err.localizedDescription.UTF8String);
	st->ffPipeline = nil;
	st->pipelineFormat = MTLPixelFormatInvalid;
	st->target = nil;
	st->commands = nil;
	st->encoder = nil;
	st->nextName = 1;
	st->projection = st->view = matrix_identity_float4x4;
	st->savedProjection = st->savedView = matrix_identity_float4x4;
	st->inOverlay = false;
	st->fog = true;
	st->fogStart = st->fogEnd = 0.0f;
	st->draws = 0;
}

HSRendererMetal::~HSRendererMetal(){
	delete st;
}

void HSRendererMetal::setTarget(void *target){
	st->target = (__bridge id<MTLTexture>)target;
	if(st->target.pixelFormat == st->pipelineFormat)
		return;
	MTLRenderPipelineDescriptor *pd = [MTLRenderPipelineDescriptor new];
	pd.vertexFunction = [st->ffLibrary newFunctionWithName:@"ff_vertex"];
	pd.fragmentFunction = [st->ffLibrary newFunctionWithName:@"ff_fragment"];
	pd.colorAttachments[0].pixelFormat = st->target.pixelFormat;
	// Everything Hyperspace draws is blended (SRC_ALPHA, ONE).
	pd.colorAttachments[0].blendingEnabled = YES;
	pd.colorAttachments[0].sourceRGBBlendFactor = pd.colorAttachments[0].sourceAlphaBlendFactor = MTLBlendFactorSourceAlpha;
	pd.colorAttachments[0].destinationRGBBlendFactor = pd.colorAttachments[0].destinationAlphaBlendFactor = MTLBlendFactorOne;
	NSError *err = nil;
	st->ffPipeline = [st->device newRenderPipelineStateWithDescriptor:pd error:&err];
	if(!st->ffPipeline)
		fail("fixed-function pipeline", err.localizedDescription.UTF8String);
	st->pipelineFormat = st->target.pixelFormat;
}

int HSRendererMetal::drawCount() const{
	return st->draws;
}

void HSRendererMetal::beginFrame(const HSFrame &frame){
	if(!st->target)
		fail("beginFrame", "no target: call setTarget first");
	if(st->encoder)
		fail("beginFrame", "the last frame was not ended");
	st->projection = fromGL(frame.projection);
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
	// GL's viewport origin is the bottom left, Metal's the top left.
	MTLViewport vp = {double(frame.viewport[0]), double(st->target.height - frame.viewport[1] - frame.viewport[3]),
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
	MTLSamplerDescriptor *sd = [MTLSamplerDescriptor new];
	sd.minFilter = sd.magFilter = MTLSamplerMinMagFilterLinear;
	sd.mipFilter = MTLSamplerMipFilterNotMipmapped;
	sd.sAddressMode = sd.tAddressMode = MTLSamplerAddressModeRepeat;
	unsigned int name = st->nextName++;
	st->textures[name] = Texture{t, [st->device newSamplerStateWithDescriptor:sd]};
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
	MTLSamplerDescriptor *sd = [MTLSamplerDescriptor new];
	sd.minFilter = sd.magFilter = MTLSamplerMinMagFilterLinear;
	sd.mipFilter = MTLSamplerMipFilterLinear;
	sd.sAddressMode = sd.tAddressMode = MTLSamplerAddressModeRepeat;
	unsigned int name = st->nextName++;
	st->textures[name] = Texture{t, [st->device newSamplerStateWithDescriptor:sd]};
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
	MTLSamplerDescriptor *sd = [MTLSamplerDescriptor new];
	sd.minFilter = sd.magFilter = MTLSamplerMinMagFilterLinear;
	sd.mipFilter = MTLSamplerMipFilterLinear;
	sd.sAddressMode = sd.tAddressMode = sd.rAddressMode = MTLSamplerAddressModeClampToEdge;
	unsigned int name = st->nextName++;
	st->textures[name] = Texture{t, [st->device newSamplerStateWithDescriptor:sd]};
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
	u.mvp = simd_mul(clipZ(), simd_mul(st->projection, u.modelview));
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
	st->savedProjection = st->projection;
	st->savedView = st->view;
	st->projection = overlayProjection(aspect);
	st->view = matrix_identity_float4x4;
	st->inOverlay = true;
}

void HSRendererMetal::endOverlay(){
	st->projection = st->savedProjection;
	st->view = st->savedView;
	st->inOverlay = false;
}

void HSRendererMetal::beginOffscreen(int){ notYet("beginOffscreen"); }
void HSRendererMetal::drawColorStrip(const HSColorVertex *, int){ notYet("drawColorStrip"); }
void HSRendererMetal::endOffscreen(unsigned char *){ notYet("endOffscreen"); }
void HSRendererMetal::beginGoo(const float [4], unsigned int, unsigned int, unsigned int, bool){ notYet("beginGoo"); }
void HSRendererMetal::drawGooSurface(impSurface *, const float [3]){ notYet("drawGooSurface"); }
void HSRendererMetal::drawGooSphere(const float [3], float){ notYet("drawGooSphere"); }
void HSRendererMetal::endGoo(){ notYet("endGoo"); }
void HSRendererMetal::beginTunnel(unsigned int, unsigned int, float, bool){ notYet("beginTunnel"); }
void HSRendererMetal::drawTunnelStrip(const HSTunnelVertex *, int){ notYet("drawTunnelStrip"); }
void HSRendererMetal::endTunnel(){ notYet("endTunnel"); }
