# Kill-check fixture: Metal backend defect (halfsphere): only half of the sphere's bands drawn.
/against 0.490%)\./,/drawPrimitives/ s/b < HS_SPHERE_BANDS; b++/b < HS_SPHERE_BANDS \/ 2; b++/
