/*
 * Copyright (C) 2005-2010  Terence M. Welsh
 *
 * This file is part of Hyperspace.
 *
 * Hyperspace is free software; you can redistribute it and/or modify
 * it under the terms of the GNU General Public License as published
 * by the Free Software Foundation; either version 2 of the License,
 * or (at your option) any later version.
 *
 * Hyperspace is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
 * GNU General Public License for more details.
 *
 * You should have received a copy of the GNU General Public License
 * along with this program; if not, write to the Free Software
 * Foundation, Inc., 59 Temple Place, Suite 330, Boston, MA  02111-1307  USA
 */


#include <Hyperspace/wavyNormalCubeMaps.h>
#include <rsMath/rsMath.h>
#include <math.h>
#include <Hyperspace/renderer.h>



wavyNormalCubeMaps::wavyNormalCubeMaps(HSRenderer *renderer, int frames, int size){
	int g, i, j;

	numFrames = frames;
	texSize = size;

	unsigned char* map = new unsigned char[texSize * texSize * 3];
	
	// allocate memory for pointers to texture objects
	texture = new unsigned int[numFrames];

	// calculate normal cube maps
	float vec[3];
	float norm[3];
	float offset = -0.5f * float(texSize) + 0.5f;
	for(g=0; g<numFrames; g++){
		HSMipChain faces[6];  // -x +x -y +y -z +z
		phase = RS_PIx2 * float(g) / float(numFrames);

		// left
		for(i=0; i<texSize; i++){
			for(j=0; j<texSize; j++){
				vec[0] = -0.5f;
				vec[1] = -(float(j) + offset) / float(texSize);
				vec[2] = (float(i) + offset) / float(texSize);
				normalize(vec);
				wavyfunc(vec, norm);
				map[(i + j * texSize) * 3] = (unsigned char)(norm[0] * 127.999f + 128.0f);
				map[(i + j * texSize) * 3 + 1] = (unsigned char)(norm[1] * 127.999f + 128.0f);
				map[(i + j * texSize) * 3 + 2] = (unsigned char)(norm[2] * -127.999f + 128.0f);
			}
		}
		hsBuildMipmaps(map, texSize, 3, faces[0]);

		// right
		for(i=0; i<texSize; i++){
			for(j=0; j<texSize; j++){
				vec[0] = 0.5f;
				vec[1] = -(float(j) + offset) / float(texSize);
				vec[2] = -(float(i) + offset) / float(texSize);
				normalize(vec);
				wavyfunc(vec, norm);
				map[(i + j * texSize) * 3] = (unsigned char)(norm[0] * 127.999f + 128.0f);
				map[(i + j * texSize) * 3 + 1] = (unsigned char)(norm[1] * 127.999f + 128.0f);
				map[(i + j * texSize) * 3 + 2] = (unsigned char)(norm[2] * -127.999f + 128.0f);
			}
		}
		hsBuildMipmaps(map, texSize, 3, faces[1]);

		// back
		for(i=0; i<texSize; i++){
			for(j=0; j<texSize; j++){
				vec[0] = -(float(i) + offset) / float(texSize);
				vec[1] = -(float(j) + offset) / float(texSize);
				vec[2] = -0.5f;
				normalize(vec);
				wavyfunc(vec, norm);
				map[(i + j * texSize) * 3] = (unsigned char)(norm[0] * 127.999f + 128.0f);
				map[(i + j * texSize) * 3 + 1] = (unsigned char)(norm[1] * 127.999f + 128.0f);
				map[(i + j * texSize) * 3 + 2] = (unsigned char)(norm[2] * -127.999f + 128.0f);
			}
		}
		hsBuildMipmaps(map, texSize, 3, faces[4]);

		// front
		for(i=0; i<texSize; i++){
			for(j=0; j<texSize; j++){
				vec[0] = (float(i) + offset) / float(texSize);
				vec[1] = -(float(j) + offset) / float(texSize);
				vec[2] = 0.5f;
				normalize(vec);
				wavyfunc(vec, norm);
				map[(i + j * texSize) * 3] = (unsigned char)(norm[0] * 127.999f + 128.0f);
				map[(i + j * texSize) * 3 + 1] = (unsigned char)(norm[1] * 127.999f + 128.0f);
				map[(i + j * texSize) * 3 + 2] = (unsigned char)(norm[2] * -127.999f + 128.0f);
			}
		}
		hsBuildMipmaps(map, texSize, 3, faces[5]);

		// bottom
		for(i=0; i<texSize; i++){
			for(j=0; j<texSize; j++){
				vec[0] = (float(i) + offset) / float(texSize);
				vec[1] = -0.5f;
				vec[2] = -(float(j) + offset) / float(texSize);
				normalize(vec);
				wavyfunc(vec, norm);
				map[(i + j * texSize) * 3] = (unsigned char)(norm[0] * 127.999f + 128.0f);
				map[(i + j * texSize) * 3 + 1] = (unsigned char)(norm[1] * 127.999f + 128.0f);
				map[(i + j * texSize) * 3 + 2] = (unsigned char)(norm[2] * -127.999f + 128.0f);
			}
		}
		hsBuildMipmaps(map, texSize, 3, faces[2]);

		// top
		for(i=0; i<texSize; i++){
			for(j=0; j<texSize; j++){
				vec[0] = (float(i) + offset) / float(texSize);
				vec[1] = 0.5f;
				vec[2] = (float(j) + offset) / float(texSize);
				normalize(vec);
				wavyfunc(vec, norm);
				map[(i + j * texSize) * 3] = (unsigned char)(norm[0] * 127.999f + 128.0f);
				map[(i + j * texSize) * 3 + 1] = (unsigned char)(norm[1] * 127.999f + 128.0f);
				map[(i + j * texSize) * 3 + 2] = (unsigned char)(norm[2] * -127.999f + 128.0f);
			}
		}
		hsBuildMipmaps(map, texSize, 3, faces[3]);
		texture[g] = renderer->createCubeTexture(faces);
	}

	delete[] map;
}


void wavyNormalCubeMaps::wavyfunc(float* point, float* normal){
	for(int i=0; i<3; i++)
		normal[i] = point[i];

	normal[0] += 0.2f * rsCosf((1.0f * point[0] + 4.0f * point[1]) * RS_PI + phase)
		+ 0.1f * rsCosf((3.0f * point[1] + 13.0f * point[2]) * RS_PI - phase);
	normal[1] += 0.2f * rsCosf((2.0f * point[1] - 5.0f * point[2]) * RS_PI + phase)
		+ 0.1f * rsCosf((2.0f * point[2] + 12.0f * point[0]) * RS_PI - phase);
	normal[2] += 0.2f * rsCosf((1.0f * point[2] + 6.0f * point[0]) * RS_PI + phase)
		+ 0.1f * rsCosf((1.0f * point[0] - 11.0f * point[1]) * RS_PI - phase);

	normalize(normal);
}


inline void wavyNormalCubeMaps::normalize(float* vector){
	static float normalizer;

	normalizer = 1.0f / sqrtf(vector[0] * vector[0] + vector[1] * vector[1] + vector[2] * vector[2]);
	vector[0] *= normalizer;
	vector[1] *= normalizer;
	vector[2] *= normalizer;
}
