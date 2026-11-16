# Kill-check fixture: Metal backend defect (nofogoff): setFog(false) ignored, so the sun is fogged. Only the sun pass draws a fog-off quad far enough away to show it.
s/st->fog = on;/st->fog = true;/
