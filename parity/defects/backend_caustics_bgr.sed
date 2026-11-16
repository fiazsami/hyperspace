# Kill-check fixture: Metal backend defect (bgr): the offscreen readback's red and blue swapped.
s/dst\[3 \* x\] = src\[4 \* x\]; dst\[3 \* x + 1\] = src\[4 \* x + 1\]; dst\[3 \* x + 2\] = src\[4 \* x + 2\];/dst[3 * x] = src[4 * x + 2]; dst[3 * x + 1] = src[4 * x + 1]; dst[3 * x + 2] = src[4 * x];/
