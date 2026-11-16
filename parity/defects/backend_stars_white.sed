# Kill-check fixture: Metal backend defect (white): the quad's color ignored, drawn white.
s/v\[i\].color\[c\] = color\[c\];/v[i].color[c] = 1.0f;/
