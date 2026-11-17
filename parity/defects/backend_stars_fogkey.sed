# Kill-check fixture: Metal backend defect (fogkey): a run of quads ends on a new texture only, not on a change of fog, so quads drawn unfogged (the overlay's flares) can be drawn with the fog of the run before them.
s/if(!st->quads.empty() \&\& (texture != st->quadTexture || fog != st->quadFog))/if(!st->quads.empty() \&\& texture != st->quadTexture)/
