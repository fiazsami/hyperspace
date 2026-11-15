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

void HSRendererGL::drawStrip(unsigned int texture, const float color[4], const HSVertex *v, int count){
	glBindTexture(GL_TEXTURE_2D, texture);
	glColor4fv(color);
	glBegin(GL_TRIANGLE_STRIP);
	for(int i = 0; i < count; i++){
		glTexCoord2fv(v[i].uv);
		glVertex3fv(v[i].pos);
	}
	glEnd();
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
