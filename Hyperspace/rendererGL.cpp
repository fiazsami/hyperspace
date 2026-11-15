/*
 * This file is part of Hyperspace.
 *
 * Hyperspace is free software; you can redistribute it and/or modify
 * it under the terms of the GNU General Public License version 2 as
 * published by the Free Software Foundation.
 *
 * Hyperspace is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
 * GNU General Public License for more details.
 */

#include <Hyperspace/rendererGL.h>
#include <Hyperspace/transform.h>
#include <OpenGL/gl.h>

unsigned int HSRendererGL::createTexture(int width, int height, const unsigned char *rgba){
	GLuint name;
	glGenTextures(1, &name);
	glBindTexture(GL_TEXTURE_2D, name);
	glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GL_LINEAR);
	glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_LINEAR);
	glTexImage2D(GL_TEXTURE_2D, 0, 4, width, height, 0, GL_RGBA, GL_UNSIGNED_BYTE, rgba);
	return name;
}

void HSRendererGL::drawQuad(unsigned int texture, const float color[4], const float model[16], float half){
	float identity[16];
	HSVertex v[4];
	hsIdentity(identity);
	hsQuad(identity, half, v);
	glBindTexture(GL_TEXTURE_2D, texture);
	glColor4fv(color);
	glPushMatrix();
	glMultMatrixf(model);
	glBegin(GL_TRIANGLE_STRIP);
	for(int i = 0; i < 4; i++){
		glTexCoord2fv(v[i].uv);
		glVertex3fv(v[i].pos);
	}
	glEnd();
	glPopMatrix();
}

void HSRendererGL::beginOverlay(float aspect){
	glBlendFunc(GL_SRC_ALPHA, GL_ONE);
	glEnable(GL_BLEND);
	glEnable(GL_TEXTURE_2D);
	glDisable(GL_LIGHTING);
	glMatrixMode(GL_PROJECTION);
	glPushMatrix();
	glLoadIdentity();
	glOrtho(0.0, aspect, 0.0, 1.0, -1.0, 1.0);   // gluOrtho2D
	glMatrixMode(GL_MODELVIEW);
	glPushMatrix();
	glLoadIdentity();
}

void HSRendererGL::endOverlay(){
	glMatrixMode(GL_PROJECTION);
	glPopMatrix();
	glMatrixMode(GL_MODELVIEW);
	glPopMatrix();
}

// Uploads every level of chain to target from tightly packed rows, as GLU
// did: byte alignment (a 2x2 RGB level is 6 bytes a row, which GL's default
// 4-byte alignment would misread) and no row length or skips, whatever the
// caller left set. An empty chain uploads nothing.
static void uploadChain(GLenum target, const HSMipChain &chain){
	static const GLenum formats[5] = {0, GL_LUMINANCE, GL_LUMINANCE_ALPHA, GL_RGB, GL_RGBA};
	if(chain.levels.empty() || chain.channels < 1 || chain.channels > 4)
		return;
	glPushClientAttrib(GL_CLIENT_PIXEL_STORE_BIT);
	glPixelStorei(GL_UNPACK_ALIGNMENT, 1);
	glPixelStorei(GL_UNPACK_ROW_LENGTH, 0);
	glPixelStorei(GL_UNPACK_SKIP_ROWS, 0);
	glPixelStorei(GL_UNPACK_SKIP_PIXELS, 0);
	int size = chain.size;
	for(size_t level = 0; level < chain.levels.size(); level++, size /= 2)
		glTexImage2D(target, GLint(level), chain.channels, size, size, 0, formats[chain.channels], GL_UNSIGNED_BYTE, &chain.levels[level][0]);
	glPopClientAttrib();
}

unsigned int HSRendererGL::createMipmappedTexture(const HSMipChain &chain){
	GLuint name;
	glGenTextures(1, &name);
	glBindTexture(GL_TEXTURE_2D, name);
	glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GL_LINEAR);
	glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_LINEAR_MIPMAP_LINEAR);
	uploadChain(GL_TEXTURE_2D, chain);
	return name;
}

unsigned int HSRendererGL::createCubeTexture(const HSMipChain faces[6]){
	static const GLenum targets[6] = {
		GL_TEXTURE_CUBE_MAP_NEGATIVE_X, GL_TEXTURE_CUBE_MAP_POSITIVE_X,
		GL_TEXTURE_CUBE_MAP_NEGATIVE_Y, GL_TEXTURE_CUBE_MAP_POSITIVE_Y,
		GL_TEXTURE_CUBE_MAP_NEGATIVE_Z, GL_TEXTURE_CUBE_MAP_POSITIVE_Z};
	GLuint name;
	glGenTextures(1, &name);
	glBindTexture(GL_TEXTURE_CUBE_MAP, name);
	glTexParameteri(GL_TEXTURE_CUBE_MAP, GL_TEXTURE_MIN_FILTER, GL_LINEAR_MIPMAP_LINEAR);
	glTexParameteri(GL_TEXTURE_CUBE_MAP, GL_TEXTURE_MAG_FILTER, GL_LINEAR);
	glTexParameteri(GL_TEXTURE_CUBE_MAP, GL_TEXTURE_WRAP_S, GL_CLAMP_TO_EDGE);
	glTexParameteri(GL_TEXTURE_CUBE_MAP, GL_TEXTURE_WRAP_T, GL_CLAMP_TO_EDGE);
	for(int f = 0; f < 6; f++)
		uploadChain(targets[f], faces[f]);
	return name;
}

// The offscreen target is the window's back buffer, as it always was: the
// caustics are drawn there before the first frame and read back.
void HSRendererGL::beginOffscreen(int size){
	offscreenSize = size;
	glGetIntegerv(GL_VIEWPORT, savedViewport);
	glViewport(0, 0, size, size);
	glMatrixMode(GL_PROJECTION);
	glPushMatrix();
	glLoadIdentity();
	glOrtho(0.0, 1.0, 0.0, 1.0, -0.5, 0.5);
	glMatrixMode(GL_MODELVIEW);
	glPushMatrix();
	glLoadIdentity();
	glReadBuffer(GL_BACK);
	glClearColor(0.0f, 0.0f, 0.0f, 1.0f);
	glDisable(GL_TEXTURE_2D);
	glBlendFunc(GL_SRC_ALPHA, GL_ONE);
	glEnable(GL_BLEND);
	glClear(GL_COLOR_BUFFER_BIT);
}

void HSRendererGL::drawColorStrip(const HSColorVertex *v, int count){
	glBegin(GL_TRIANGLE_STRIP);
	for(int i = 0; i < count; i++){
		glColor3f(v[i].color[0], v[i].color[1], v[i].color[2]);
		glVertex3f(v[i].pos[0], v[i].pos[1], v[i].pos[2]);
	}
	glEnd();
}

void HSRendererGL::endOffscreen(unsigned char *rgb){
	if(offscreenSize == 0)
		return;   // no beginOffscreen: nothing to read or restore
	GLint alignment;
	glGetIntegerv(GL_PACK_ALIGNMENT, &alignment);
	glPixelStorei(GL_PACK_ALIGNMENT, 1);
	glReadPixels(0, 0, offscreenSize, offscreenSize, GL_RGB, GL_UNSIGNED_BYTE, rgb);
	glPixelStorei(GL_PACK_ALIGNMENT, alignment);
	glMatrixMode(GL_PROJECTION);
	glPopMatrix();
	glMatrixMode(GL_MODELVIEW);
	glPopMatrix();
	glViewport(savedViewport[0], savedViewport[1], savedViewport[2], savedViewport[3]);
	offscreenSize = 0;
}
