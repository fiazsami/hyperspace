// The frame's last draw: the scene, accumulated in half floats so additive
// layers no longer clip at each blend, is tone-mapped into the displayed
// attachment, one sample at a time, from tile memory (programmable blending).
// Compiled with Interface.metal prepended.

struct ToneMapVertex {
	float4 position [[position]];
};

// One triangle that covers the target.
vertex ToneMapVertex tonemap_vertex(uint vid [[vertex_id]]){
	const float2 p = float2((vid << 1) & 2, vid & 2);
	ToneMapVertex out;
	out.position = float4(p * 2.0 - 1.0, 0.0, 1.0);
	return out;
}

struct ToneMapOut {
	half4 color [[color(1)]];
};

// The identity up to the knee, so everything today's 8-bit frame showed below
// it is drawn as before; above it an exponential shoulder with the same slope
// at the knee, approaching 1 and never clipping.
constant half kKnee = 0.85h;

static half shoulder(half x){
	return x <= kKnee ? x : kKnee + (1.0h - kKnee) * (1.0h - exp(-(x - kKnee) / (1.0h - kKnee)));
}

// [[sample_id]] runs it per sample, so the tone map comes before the resolve:
// an edge between a highlight and the dark is averaged after its highlight is
// brought into range, not before. Neither the goldens (480x270) nor the cost
// (3440x1440) could tell it from once a pixel: a fixture without it survived.
fragment ToneMapOut tonemap_fragment(ToneMapVertex in [[stage_in]], half4 scene [[color(0)]],
	uint sample [[sample_id]]){
	ToneMapOut out;
	out.color = half4(shoulder(scene.r), shoulder(scene.g), shoulder(scene.b), 1.0h);
	return out;
}
