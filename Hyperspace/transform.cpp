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

#include "transform.h"
#include <math.h>
#include <string.h>

void hsIdentity(float m[16])
{
	memset(m, 0, 16 * sizeof(float));
	m[0] = m[5] = m[10] = m[15] = 1.0f;
}

void hsMultiply(float m[16], const float by[16])
{
	float r[16];
	for(int c = 0; c < 4; c++)
		for(int row = 0; row < 4; row++)
			r[c * 4 + row] = m[row] * by[c * 4] + m[4 + row] * by[c * 4 + 1] + m[8 + row] * by[c * 4 + 2] + m[12 + row] * by[c * 4 + 3];
	memcpy(m, r, sizeof r);
}

void hsRotate(float m[16], float degrees, float x, float y, float z)
{
	float len = sqrtf(x * x + y * y + z * z);
	if(len == 0.0f)
		return;
	x /= len; y /= len; z /= len;
	float a = degrees * float(M_PI / 180.0);
	float c = cosf(a), s = sinf(a), t = 1.0f - c;
	const float r[16] = {
		x * x * t + c,     y * x * t + z * s, x * z * t - y * s, 0.0f,
		x * y * t - z * s, y * y * t + c,     y * z * t + x * s, 0.0f,
		x * z * t + y * s, y * z * t - x * s, z * z * t + c,     0.0f,
		0.0f,              0.0f,              0.0f,              1.0f};
	hsMultiply(m, r);
}

void hsTranslate(float m[16], float x, float y, float z)
{
	for(int row = 0; row < 4; row++)
		m[12 + row] += m[row] * x + m[4 + row] * y + m[8 + row] * z;
}

void hsScale(float m[16], float x, float y, float z)
{
	for(int row = 0; row < 4; row++){
		m[row] *= x;
		m[4 + row] *= y;
		m[8 + row] *= z;
	}
}

void hsRotationInverse(float out[16], const float m[16])
{
	float r[16];   // out may be m
	hsIdentity(r);
	for(int c = 0; c < 3; c++)
		for(int row = 0; row < 3; row++)
			r[c * 4 + row] = m[row * 4 + c];
	memcpy(out, r, sizeof r);
}

void hsApply(const float m[16], float x, float y, float z, float out[3])
{
	for(int row = 0; row < 3; row++)
		out[row] = m[row] * x + m[4 + row] * y + m[8 + row] * z + m[12 + row];
}

void hsPerspective(float m[16], double fovyDegrees, double aspect, double zNear, double zFar)
{
	hsIdentity(m);
	double radians = fovyDegrees / 2.0 * M_PI / 180.0;
	double deltaZ = zFar - zNear;
	double sine = sin(radians);
	if(deltaZ == 0.0 || sine == 0.0 || aspect == 0.0)
		return;
	double cotangent = cos(radians) / sine;
	m[0] = float(cotangent / aspect);
	m[5] = float(cotangent);
	m[10] = float(-(zFar + zNear) / deltaZ);
	m[11] = -1.0f;
	m[14] = float(-2.0 * zNear * zFar / deltaZ);
	m[15] = 0.0f;
}

static void transformPoint(const double m[16], const double in[4], double out[4])
{
	for(int row = 0; row < 4; row++)
		out[row] = m[row] * in[0] + m[4 + row] * in[1] + m[8 + row] * in[2] + m[12 + row] * in[3];
}

bool hsProject(double objx, double objy, double objz, const double model[16], const double proj[16],
               const int viewport[4], double win[3])
{
	double in[4] = {objx, objy, objz, 1.0}, eye[4], clip[4];
	transformPoint(model, in, eye);
	transformPoint(proj, eye, clip);
	if(clip[3] == 0.0)
		return false;
	for(int i = 0; i < 3; i++)
		clip[i] = clip[i] / clip[3] * 0.5 + 0.5;
	win[0] = clip[0] * viewport[2] + viewport[0];
	win[1] = clip[1] * viewport[3] + viewport[1];
	win[2] = clip[2];
	return true;
}
