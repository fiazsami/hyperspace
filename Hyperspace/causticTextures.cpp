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


#ifdef WIN32
	#include <windows.h>
	extern HDC hdc;
#endif
#ifdef RS_XSCREENSAVER
#include <rsXScreenSaver/rsXScreenSaver.h>
#endif
#include <iostream>
#include <Hyperspace/causticTextures.h>
#include <math.h>
#include <OpenGL/OpenGL.h>
#include <rsMath/rsMath.h>
#include <Hyperspace/renderer.h>
#include <vector>


causticTextures::causticTextures(HSRenderer *renderer, int keys, int frames, int res, int size, float depth, float wa, float rm){
	int i, j, k;
	int xminus, xplus, zminus, zplus;

	// initialize dimensions
	numKeys = keys;
	if(numKeys < 2)
		numKeys = 2;
	numFrames = frames;
	if(numFrames < numKeys * 2)
		numFrames = numKeys * 2;
	geoRes = res;
	if(geoRes < 8)
		geoRes = 8;
	texSize = size;
	if(texSize < 8)
		texSize = 8;
	waveAmp = wa;
	refractionMult = rm;

	// Sized from the clamped texSize: the readback writes texSize squared.
	unsigned char* bitmap = new unsigned char[texSize * texSize * 3];

	caustictex = new GLuint[numFrames];

	// allocate memory
	x = new float[geoRes + 1];
	z = new float[geoRes + 1];
	y = new float**[numFrames];
	for(k=0; k<numFrames; k++){
		y[k] = new float*[geoRes];
		for(i=0; i<geoRes; i++)
			y[k][i] = new float[geoRes];
	}
	xz = new float**[geoRes + 1];
	for(i=0; i<=geoRes; i++){
		xz[i] = new float*[geoRes + 1];
		for(j=0; j<=geoRes; j++)
			xz[i][j] = new float[2];
	}
	intensity = new float*[geoRes + 1];
	for(i=0; i<=geoRes; i++)
		intensity[i] = new float[geoRes + 1];

	// set x and z geometry positions
	for(i=0; i<=geoRes; i++){
		x[i] = float(i) / float(geoRes);
		z[i] = float(i) / float(geoRes);
	}

	// set y geometry positions (altitudes). Upstream also carried a fractal
	// generator it never called ("sort of ugly"); the port removed it.
	makeTrigAltitudes();


	// project vertices and create textures
	float recvert = float(geoRes) * 0.5f;  // reciprocal of vertical component of light ray
	for(k=0; k<numFrames; k++){
		// compute projected offsets
		// (this uses surface normals, not actual refractions, but it's faster this way)
		for(i=0; i<geoRes; i++){
			for(j=0; j<geoRes; j++){
				makeIndices(i, &xminus, &xplus);
				xz[i][j][0] = (y[k][xplus][j] - y[k][xminus][j]) * recvert * (depth + y[k][i][j]);
				makeIndices(j, &zminus, &zplus);
				xz[i][j][1] = (y[k][i][zplus] - y[k][i][zminus]) * recvert * (depth + y[k][i][j]);
			}
		}
		
		// copy offsets to edges of xz array
		for(i=0; i<geoRes; i++){
			xz[i][geoRes][0] = xz[i][0][0];
			xz[i][geoRes][1] = xz[i][0][1];
		}
		for(j=0; j<=geoRes; j++){
			xz[geoRes][j][0] = xz[0][j][0];
			xz[geoRes][j][1] = xz[0][j][1];
		}
		
		// compute light intensities
		float space = 1.0f / float(geoRes);
		for(i=0; i<geoRes; i++){
			for(j=0; j<geoRes; j++){
				makeIndices(i, &xminus, &xplus);
				makeIndices(j, &zminus, &zplus);
				// this assumes nominal light intensity is 0.25
				intensity[i][j] = (1.0f / (float(geoRes) * float(geoRes)))
					/ ((myFabs(xz[xplus][j][0] - xz[i][j][0] + space)
					+ myFabs(xz[i][j][0] - xz[xminus][j][0] + space))
					* (myFabs(xz[i][zplus][1] - xz[i][j][1] + space)
					+ myFabs(xz[i][j][1] - xz[i][zminus][1] + space)))
					- 0.125f;
				if(intensity[i][j] > 1.0f)
					intensity[i][j] = 1.0f;
			}
		}
		
		// copy intensities to edges of intensity array
		for(i=0; i<geoRes; i++)
			intensity[i][geoRes] = intensity[i][0];
		for(j=0; j<=geoRes; j++)
			intensity[geoRes][j] = intensity[0][j];

		// draw texture
		renderer->beginOffscreen(texSize);
		// draw most of texture
		draw(renderer, 0, geoRes, 0, geoRes, 0.0f, 0.0f);
		// draw edges of texture that wrap around from opposite sides
		int numRows = geoRes / 10;
		draw(renderer, geoRes - numRows, geoRes, 0, geoRes, -1.0f, 0.0f);
		draw(renderer, 0, numRows, 0, geoRes, 1.0f, 0.0f);
		draw(renderer, 0, geoRes, geoRes - numRows, geoRes, 0.0f, -1.0f);
		draw(renderer, 0, geoRes, 0, numRows, 0.0f, 1.0f);
		// draw corners too
		draw(renderer, geoRes - numRows, geoRes, geoRes - numRows, geoRes, -1.0f, -1.0f);
		draw(renderer, 0, numRows, geoRes - numRows, geoRes, 1.0f, -1.0f);
		draw(renderer, geoRes - numRows, geoRes, 0, numRows, -1.0f, 1.0f);
		draw(renderer, 0, numRows, 0, numRows, 1.0f, 1.0f);

		// read back texture
		renderer->endOffscreen(bitmap);

		// create texture object
		HSMipChain chain;
		hsBuildMipmaps(bitmap, texSize, 3, chain);
		caustictex[k] = renderer->createMipmappedTexture(chain);
		
#ifdef WIN32
		wglSwapLayerBuffers(hdc, WGL_SWAP_MAIN_PLANE);
#endif
#ifdef RS_XSCREENSAVER
		glXSwapBuffers(xdisplay, xwindow);
#endif
	}

	delete[] x;
	delete[] y;
	delete[] z;
	delete[] xz;
	delete[] intensity;
	delete[] bitmap;
}


void causticTextures::makeTrigAltitudes(){
	int i, j, k;
	float xx, zz, offset;

	for(k=0; k<numFrames; k++){
		offset = RS_PIx2 * float(k) / float(numFrames);
		for(i=0; i<geoRes; i++){
			xx = RS_PIx2 * float(i) / float(geoRes);
			for(j=0; j<geoRes; j++){
				zz = RS_PIx2 * float(j) / float(geoRes);
				/*y[k][i][j] = waveAmp
					* (0.12f * rsCosf(xx + 2.0f * offset)
					+ 0.08f * rsCosf(-1.0f * xx + 2.0f * zz + offset)
					+ 0.04f * rsCosf(-2.0f * xx - 4.0f * zz + offset)
					+ 0.014f * rsCosf(xx - 7.0f * zz - 2.0f * offset)
					+ 0.014f * rsCosf(3.0f * xx + 5.0f * zz + offset)
					+ 0.014f * rsCosf(9.0f * xx + zz - offset)
					+ 0.007f * rsCosf(11.0f * xx + 7.0f * zz - offset)
					+ 0.007f * rsCosf(4.0f * xx - 13.0f * zz + offset)
					+ 0.007f * rsCosf(19.0f * xx - 9.0f * zz - offset));*/
				y[k][i][j] = waveAmp
					* (0.08f * rsCosf(xx * 2.0f + offset)
					+ 0.06f * rsCosf(-1.0f * xx + 2.0f * zz + offset)
					+ 0.04f * rsCosf(-2.0f * xx - 3.0f * zz + offset)
					+ 0.01f * rsCosf(xx - 7.0f * zz - 2.0f * offset)
					+ 0.01f * rsCosf(3.0f * xx + 5.0f * zz + offset)
					+ 0.01f * rsCosf(9.0f * xx + zz - offset)
					+ 0.005f * rsCosf(11.0f * xx + 7.0f * zz - offset)
					+ 0.005f * rsCosf(4.0f * xx - 13.0f * zz + offset)
					+ 0.003f * rsCosf(19.0f * xx - 9.0f * zz - offset));
			}
		}
	}
}


// One row of the caustic mesh per j, as three strips (red, green, blue, each
// refracted by a different amount), shifted by (dx, dz) for the wrapped
// edges. The mesh lies in x-z; offscreen x and y are its x and z.
void causticTextures::draw(HSRenderer *renderer, int xlo, int xhi, int zlo, int zhi, float dx, float dz){
	int i, j;
	std::vector<HSColorVertex> strip((xhi - xlo + 1) * 2);
	const float mults[3] = {1.0f - refractionMult / float(geoRes), 1.0f, 1.0f + refractionMult / float(geoRes)};

	for(j=zlo; j<zhi; j++){
		for(int c=0; c<3; c++){
			float mult = mults[c];
			HSColorVertex *v = &strip[0];
			for(i=xlo; i<=xhi; i++, v += 2){
				v[0].pos[0] = x[i] + xz[i][j+1][0] * mult + dx;
				v[0].pos[1] = z[j+1] + xz[i][j+1][1] * mult + dz;
				v[1].pos[0] = x[i] + xz[i][j][0] * mult + dx;
				v[1].pos[1] = z[j] + xz[i][j][1] * mult + dz;
				v[0].pos[2] = v[1].pos[2] = 0.0f;
				v[0].color[0] = v[0].color[1] = v[0].color[2] = 0.0f;
				v[1].color[0] = v[1].color[1] = v[1].color[2] = 0.0f;
				v[0].color[c] = intensity[i][j+1];
				v[1].color[c] = intensity[i][j];
			}
			renderer->drawColorStrip(&strip[0], int(strip.size()));
		}
	}
}


void causticTextures::makeIndices(int index, int* minus, int* plus){
	*minus = index - 1;
	if(*minus < 0)
		*minus = geoRes - 1;
	*plus = index + 1;
	if(*plus >= geoRes)
		*plus = 0;
}
