# Kill-check fixture: Metal backend defect (onerun): only the first setVertexBytes-sized run of a flush is drawn.
s/for(size_t at = 0; at < st->quads.size(); at += run){/for(size_t at = 0; at < std::min(run, st->quads.size()); at += run){/
