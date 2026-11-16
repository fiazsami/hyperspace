# Kill-check fixture: Metal backend defect (texswap): the nebula bound where the first normal map goes, and the reverse.
s/const unsigned int names\[3\] = {normals0, normals1, nebula};/const unsigned int names[3] = {nebula, normals1, normals0};/
