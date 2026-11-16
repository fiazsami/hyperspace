# Kill-check fixture: Metal backend defect (alphahalf): offscreen strips drawn with alpha 0.5, where glColor3f gives 1.
s|o.color\[3\] = 1.0f;   // glColor3f|o.color[3] = 0.5f;   // glColor3f|
