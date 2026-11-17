# Kill-check fixture: Metal backend defect (wholevolume): each block's cells start a whole block, not half of one, from its centre.
s/u.halfVolume = 0.5f \* field.volumeSize;/u.halfVolume = field.volumeSize;/
