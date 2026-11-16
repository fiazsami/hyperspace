# Kill-check fixture: Metal backend defect (texswap): the two caustic frames bound in each other's place.
s/const unsigned int names\[2\] = {caustic0, caustic1};/const unsigned int names[2] = {caustic1, caustic0};/
