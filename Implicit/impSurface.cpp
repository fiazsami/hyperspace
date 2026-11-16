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


#include <Implicit/impSurface.h>
#include <rsMath/rsMath.h>
#include <string.h>
#include <iostream>


impSurface::impSurface(){
	index_offset = 0;
	vertex_offset = 0;
	num_tristrips = 0;
	triStripLengths.resize(0);
	vertices.resize(0);
	indices.resize(0);
	vertex_data_size = sizeof(float) * 6;
}


impSurface::~impSurface(){
	triStripLengths.resize(0);
	indices.resize(0);
	vertices.resize(0);
}




void impSurface::reset(){
	num_tristrips = 0;
	index_offset = 0;
	vertex_offset = 0;
}


#if USE_TRIANGLE_STRIPS
void impSurface::addTriStripLength(unsigned char length){
	// make more tristrip storage if necessary
	const size_t tslsize(triStripLengths.size());
	if(num_tristrips == tslsize)
		triStripLengths.resize(tslsize + 1000);

	triStripLengths[num_tristrips++] = length;
}
#endif


void impSurface::addIndex(unsigned int index){
	// make more vertex data storage if necessary
	const size_t datasize(indices.size());
	if(index_offset == datasize)
		indices.resize(datasize + 1000);

#if USE_UNSIGNED_SHORT
	indices[index_offset++] = static_cast<unsigned short>(index);
#else
	indices[index_offset++] = index;
#endif
}


void impSurface::addVertex(float* data){
	// make more vertex data storage if necessary
	const size_t datasize(vertices.size());
	if((vertex_offset + 6) >= datasize)
		vertices.resize(datasize + 1000);

	memcpy(&(vertices[vertex_offset]), data, 24);//vertex_data_size);
	vertex_offset += 6;
}
