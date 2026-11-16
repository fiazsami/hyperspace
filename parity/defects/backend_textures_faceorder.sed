# Kill-check fixture: Metal backend defect (faceorder): cube faces uploaded in HSRenderer's order (-x +x ...) rather than Metal's (+x -x ...).
s/static const int slice\[6\] = {1, 0, 3, 2, 5, 4};/static const int slice[6] = {0, 1, 2, 3, 4, 5};/
