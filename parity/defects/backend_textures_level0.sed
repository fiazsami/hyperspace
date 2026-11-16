# Kill-check fixture: Metal backend defect (level0): every level of a 2D mip chain uploaded from level 0's pixels.
s/std::vector<unsigned char> px = rgbaLevel(chain, int(l));/std::vector<unsigned char> px = rgbaLevel(chain, 0);/
