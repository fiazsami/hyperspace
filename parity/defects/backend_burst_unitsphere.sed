# Kill-check fixture: Metal backend defect (unitsphere): the starburst sphere drawn at radius 1, its size ignored.
s/model.columns\[0\].x = model.columns\[1\].y = model.columns\[2\].z = radius;/model.columns[0].x = model.columns[1].y = model.columns[2].z = 1.0f;/
