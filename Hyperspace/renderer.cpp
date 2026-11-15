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

void hsQuad(const float m[16], float half, HSVertex out[4]){
	for(int i = 0; i < 4; i++){
		float u = float(i & 1), v = float(i >> 1);
		hsApply(m, (2.0f * u - 1.0f) * half, (2.0f * v - 1.0f) * half, 0.0f, out[i].pos);
		out[i].uv[0] = u;
		out[i].uv[1] = v;
	}
}
