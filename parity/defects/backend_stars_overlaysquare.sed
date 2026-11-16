# Kill-check fixture: Metal backend defect (overlaysquare): the overlay plane ignores the aspect ratio.
s/st->projection = overlayProjection(aspect);/st->projection = overlayProjection(1.0f);/
