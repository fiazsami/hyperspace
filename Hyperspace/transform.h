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

// The matrix maths Hyperspace used to get from the GL matrix stack and GLU, as
// plain functions, so the simulation can compute its camera without a GL context.
//
// Matrices are column-major float[16] or double[16], laid out exactly as
// glLoadMatrix takes them. Each function follows the formula its GL or GLU
// counterpart is specified with, including the right-multiplication: hsRotate(m,
// ...) does what glRotatef does to the current matrix. Precision follows GL too:
// the matrix stack is float, while gluPerspective and gluProject work in double.

#ifndef HYPERSPACE_TRANSFORM_H
#define HYPERSPACE_TRANSFORM_H

void hsIdentity(float m[16]);
void hsMultiply(float m[16], const float by[16]);                  // m = m * by (glMultMatrixf)
void hsRotate(float m[16], float degrees, float x, float y, float z); // glRotatef
void hsTranslate(float m[16], float x, float y, float z);           // glTranslatef
void hsScale(float m[16], float x, float y, float z);               // glScalef

// gluPerspective's matrix, on its own (GLU multiplies it onto the current one).
void hsPerspective(double m[16], double fovyDegrees, double aspect, double zNear, double zFar);

// gluProject: false where GLU returns GL_FALSE (w = 0), leaving win untouched.
bool hsProject(double objx, double objy, double objz, const double model[16], const double proj[16],
               const int viewport[4], double win[3]);

#endif
