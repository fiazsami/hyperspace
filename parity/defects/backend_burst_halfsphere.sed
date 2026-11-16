# Kill-check fixture: Metal backend defect (halfsphere): only half of the sphere's bands drawn.
s/for(int b = 0; b < HS_SPHERE_BANDS; b++)$/for(int b = 0; b < HS_SPHERE_BANDS \/ 2; b++)/
