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

#include <Hyperspace/renderer.h>
#include <Hyperspace/transform.h>
#include <rsMath/rsMath.h>
#include <Implicit/impCubeTables.h>
#include <math.h>

void hsQuad(const float m[16], float half, HSVertex out[4]){
	for(int i = 0; i < 4; i++){
		float u = float(i & 1), v = float(i >> 1);
		hsApply(m, (2.0f * u - 1.0f) * half, (2.0f * v - 1.0f) * half, 0.0f, out[i].pos);
		out[i].uv[0] = u;
		out[i].uv[1] = v;
	}
}

bool hsBuildMipmaps(const unsigned char *pixels, int size, int channels, HSMipChain &out){
	if(size < 1 || (size & (size - 1)) != 0 || channels < 1 || channels > 4)
		return false;
	out.size = size;
	out.channels = channels;
	out.levels.clear();
	out.levels.push_back(std::vector<unsigned char>(pixels, pixels + size * size * channels));
	for(int from = size; from > 1; from /= 2){
		const std::vector<unsigned char> &a = out.levels.back();
		int to = from / 2;
		std::vector<unsigned char> b(to * to * channels);
		for(int y = 0; y < to; y++)
			for(int x = 0; x < to; x++)
				for(int c = 0; c < channels; c++){
					int i = ((2 * y) * from + 2 * x) * channels + c;
					int row = from * channels;
					b[(y * to + x) * channels + c] = (unsigned char)((a[i] + a[i + channels] + a[i + row] + a[i + row + channels] + 2) / 4);
				}
		out.levels.push_back(b);
	}
	return true;
}

// The expressions are the display list's, unchanged, so the floats are too.
void hsSphereBand(int band, float out[HS_SPHERE_BAND_POINTS][3]){
	const float n = float(HS_SPHERE_BANDS);   // 32: also the longitude count
	const float cj = cosf(float(band) * RS_PIx2 / n);
	const float sj = sinf(float(band) * RS_PIx2 / n);
	const float cjj = cosf(float(band+1) * RS_PIx2 / n);
	const float sjj = sinf(float(band+1) * RS_PIx2 / n);
	for(int i=0; i<=HS_SPHERE_BANDS; i++){
		const float ci = cosf(float(i) * RS_PIx2 / n);
		const float si = sinf(float(i) * RS_PIx2 / n);
		out[2*i][0] = sj * ci;
		out[2*i][1] = cj;
		out[2*i][2] = sj * si;
		out[2*i+1][0] = sjj * ci;
		out[2*i+1][1] = cjj;
		out[2*i+1][2] = sjj * si;
	}
}

// polygonize walks each strip of a row and emits strip triangle i (i from 1)
// as entries i, i+1, i+2 when i is odd and i+2, i+1, i when it is even: the
// same triangles, every other one turned to keep the winding.
void hsGooTriangleTable(short out[256][HS_GOO_TABLE_ROW]){
	const impCubeTables tables;
	for(int mask = 0; mask < 256; mask++){
		const int *row = tables.triStripPatterns[mask];
		int count = 0;
		for(int at = 0; row[at] != 0; at += row[at] + 1)
			for(int i = 1; i < row[at] - 1; i++){
				for(int j = 0; j < 3; j++)
					out[mask][1 + 3 * count + j] = short(row[at + ((i % 2) ? i + j : i + (2 - j))]);
				count++;
			}
		out[mask][0] = short(count);
		for(int k = 1 + 3 * count; k < HS_GOO_TABLE_ROW; k++)
			out[mask][k] = 0;
	}
}
