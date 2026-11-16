# Kill-check fixture: Metal backend defect (alpha0): an RGB chain expanded with alpha 0, where GL samples alpha 1.
s/out\[j + 3\] = 255;/out[j + 3] = 0;/
