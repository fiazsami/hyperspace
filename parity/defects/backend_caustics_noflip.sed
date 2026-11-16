# Kill-check fixture: Metal backend defect (noflip): the offscreen target read back top row first, where GL reads the bottom row first.
s/const unsigned char \*src = &rgba\[size_t(size - 1 - y) \* size \* 4\];/const unsigned char *src = \&rgba[size_t(y) * size * 4];/
