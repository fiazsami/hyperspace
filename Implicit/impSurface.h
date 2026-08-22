/*
 * Copyright (C) 2001-2010  Terence M. Welsh
 *
 * This file is part of Implicit.
 *
 * Implicit is free software; you can redistribute it and/or
 * modify it under the terms of the GNU Lesser General Public
 * License as published by the Free Software Foundation; either
 * version 2.1 of the License, or (at your option) any later version.
 *
 * Implicit is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
 * GNU General Public License for more details.
 *
 * You should have received a copy of the GNU Lesser General Public
 * License along with this program; if not, write to the Free Software
 * Foundation, Inc., 59 Temple Place, Suite 330, Boston, MA  02111-1307  USA
 */


#ifndef IMPSURFACE_H
#define IMPSURFACE_H


#ifdef WIN32
	#include <windows.h>
#endif
#include <vector>
#include <OpenGL/OpenGL.h>
#include <OpenGL/gl.h>


#define USE_UNSIGNED_SHORT 0  // use short instead of int when passing indices to draw calls
#define USE_TRIANGLE_STRIPS 0  // use triangle strips instead of triangles


class impSurface{
private:
	unsigned int index_offset;
	unsigned int vertex_offset;
	unsigned int num_tristrips;
	std::vector<unsigned int> triStripLengths;
	std::vector<float> vertices;
	size_t vertex_data_size;
#if USE_UNSIGNED_SHORT
	std::vector<unsigned short> indices;
#else
	std::vector<unsigned int> indices;
#endif

	// display list
	//GLuint mDisplayList;

	// vbo stuff
	bool mUseVBOs;  // Default to true.  If extensions aren't found, set to false and use draw arrays.
	bool mCompile;  // If there is new data, set this to true to compile new VBO buffers.
	GLuint vbo_array_id;
	GLuint vbo_index_id;
	std::vector<GLvoid*> vbo_index_offsets;
#ifdef WIN32
	// extensions necessary for VBOs
	static PFNGLMULTIDRAWELEMENTSPROC glMultiDrawElements;
	static PFNGLGENBUFFERSPROC glGenBuffers;
	static PFNGLDELETEBUFFERSPROC glDeleteBuffers;
	static PFNGLBINDBUFFERPROC glBindBuffer;
	static PFNGLBUFFERDATAPROC glBufferData;
#endif

public:
	impSurface();
	~impSurface();

#ifdef WIN32
	int queryExtension(char* name);
	void* getProcAddr(char* name);
#endif

	// Set data counts to 0
	void reset();

	// Add data to surface
	// #if, not #ifdef. USE_TRIANGLE_STRIPS is #defined as 0, so #ifdef is true
	// and would have compiled this function in, while every call site -- which
	// all use #if -- compiled out. The result was a function that existed in
	// the binary, could never be called, and sat in the coverage denominator
	// as three permanently uncoverable regions. See ss-3c8.
#if USE_TRIANGLE_STRIPS
	void addTriStripLength(unsigned char length);
#endif
	void addIndex(unsigned int index);
	void addVertex(float* data);  // provide array of 6 floats (normal, position)

	void draw();
	//void draw_wireframe();

	// Read-only access to the geometry that draw() consumes. Added so that
	// impCubeVolume's output can be asserted on without a GL context (ss-or3);
	// nothing in the renderer calls these.
	//
	// The counts come from the offsets, NOT from vertices.size() or
	// indices.size(). Both vectors are grown a thousand elements at a time and
	// never shrunk, so their size() is the allocation and the tail of it is
	// stale data from an earlier frame or uninitialised memory.
	unsigned int getVertexCount() const {return vertex_offset / 6;}
	unsigned int getIndexCount() const {return index_offset;}

	// Six floats per vertex: normal in [0..2], position in [3..5]. That is the
	// order draw() feeds to glNormalPointer and glVertexPointer, and the order
	// addVertex documents for its argument.
	// getVertex uses data() because it only forms an address: a surface that
	// emitted nothing has an empty vector, and indexing one is undefined even
	// when the result is never read -- which the empty-field test case produces
	// on purpose.
	//
	// getIndex does NOT, and the difference is deliberate. It returns the
	// element, so the load happens either way and data()[i] would be the same
	// null dereference on an empty vector -- no safety gained. What it would
	// lose is real: operator[] is where libc++ puts its hardened bounds
	// assertion, so data()[i] turns a clean abort under
	// _LIBCPP_HARDENING_MODE_FAST into a silent out-of-range read, on exactly
	// the bug class these accessors exist to catch. This build does not enable
	// hardening today; the point is not to disarm it in advance.
	//
	// Neither bounds-checks by itself. Callers must not read past
	// getVertexCount() or getIndexCount(): the vectors are grown a thousand
	// elements at a time and never shrunk, so anything between the count and
	// size() is stale data from an earlier frame, returned without complaint.
	const float* getVertex(unsigned int i) const {return vertices.data() + i * 6;}
	unsigned int getIndex(unsigned int i) const {return indices[i];}
};



#endif
