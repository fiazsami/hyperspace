// Kill-check fixture: goo build kernel with one deliberate defect (nomix): every vertex takes the normal of its edge's first corner, not the mix along the edge. parity/backendcheck.sh requires it to FAIL. base=82456adb187729b7b1179e957dcca72787e13a03
// The goo's surface, built on the GPU: impCubeVolume's polygonization of
// goo::function, one thread per cell, for HSRendererMetal::drawGooField.
// Compiled with Interface.metal prepended.
//
// The CPU crawls from surface it finds on the volume's sides and shares
// vertices between cells; this visits every cell and writes each triangle's
// three vertices, so the same triangles come out in another order, with
// nothing shared. Visiting every cell also finds a closed pocket that touches
// no side, which the CPU's crawl never reaches: measured over 300 frames,
// 5 of 12772 blocks at resolution 10 and 4 at 20, a dozen triangles in all. Measured
// against impCubeVolume on the same frames: equal triangle counts at
// resolutions 10 to 30. cos is precise here, where the CPU's rsCosf is a table
// lookup good to about 1e-4; at resolution 40 that moved 4 triangles of
// 404938.
//
// The normals are impCubeVolume's fast normals, not the field's gradient: at a
// corner, its value less the value one cell further along each axis, mixed
// along the edge. The exact gradient points far enough from that at these cell
// sizes that the reflections shift across the whole surface.

// Positions here are relative to the field's origin, as the vertices are
// written, so they stay small however far the camera travels; only the field
// itself is evaluated in the world, as goo::function adds a block's shift.

// goo::function at p, a point relative to the origin.
static float gooField(float3 p, constant GooBuildUniforms &u)
{
    const float y = p.y;
    const float px = p.x + u.origin.x, pz = p.z + u.origin.y;
    const float x = px - u.cam.x, z = pz - u.cam.y;
    return 1.25f * y * y
        + u.c.x * precise::cos(px - 2.71f * y)
        + u.c.y * precise::cos(4.21f * y + pz)
        + u.c.z * precise::cos(1.91f * px - 1.67f * pz)
        + u.c.w * precise::cos(1.53f * px + 1.11f * y + 2.11f * pz)
        - 0.1f / (x * x + y * y + z * z);
}

// A cell's corner i is at (i >> 2, i >> 1, i) & 1 in x, y, z, and is bit i of
// the configuration: impCubeVolume::findmask's LBF, LBN, LTF, LTN, RBF, RBN,
// RTF, RTN in that order. Edge e joins corners kEdge[e], lower corner first.
constant uchar2 kEdge[12] = {
    uchar2(0, 1), uchar2(0, 2), uchar2(1, 3), uchar2(2, 3), uchar2(0, 4), uchar2(1, 5),
    uchar2(2, 6), uchar2(3, 7), uchar2(4, 5), uchar2(4, 6), uchar2(5, 7), uchar2(6, 7)};

static float3 corner(uint i) { return float3((i >> 2) & 1, (i >> 1) & 1, i & 1); }

// impCubeVolume's fast normal at corner i: the corner's value less its
// neighbour's one cell along x, y and z -- another corner of this cell, or a
// point past it.
static float3 cornerNormal(uint i, float3 base, thread const float *value, constant GooBuildUniforms &u)
{
    float3 n;
    for (uint k = 0; k < 3; k++) {
        const uint bit = 4u >> k;   // x is bit 2, y bit 1, z bit 0
        float next;
        if (!(i & bit)) {
            next = value[i | bit];
        } else {
            float3 step = 0.0f;
            step[k] = 1.0f;
            next = gooField(base + (corner(i) + step) * u.unitSize, u);
        }
        n[k] = value[i] - next;
    }
    return n;
}

kernel void goo_build(constant GooBuildUniforms &u      [[buffer(0)]],
                      constant float2 *offsets           [[buffer(1)]],
                      constant short *table              [[buffer(2)]],   // hsGooTriangleTable
                      device atomic_uint *count          [[buffer(3)]],
                      device GooVertex *out              [[buffer(4)]],
                      uint3 id                           [[thread_position_in_grid]])
{
    // dispatchThreads launches exactly res x res x res * blocks threads.
    const uint res = u.resolution;
    const uint block = id.z / res;
    const float2 offset = offsets[block] - u.origin;
    // The cell's lowest corner; impCubeVolume centres its cells on the block.
    const float3 base = float3(offset.x, 0.0f, offset.y) - u.halfVolume
        + float3(id.x, id.y, id.z % res) * u.unitSize;
    float value[8];
    uint mask = 0;
    for (uint i = 0; i < 8; i++) {
        value[i] = gooField(base + corner(i) * u.unitSize, u);
        if (value[i] < u.surface)
            mask |= 1u << i;
    }
    constant short *row = table + mask * 16;   // HS_GOO_TABLE_ROW, which rendererMetal.mm asserts is 16
    const uint vertices = uint(row[0]) * 3;
    if (vertices == 0)
        return;
    // The counter keeps counting past the buffer, so the CPU learns how much
    // a frame needed. A cell that does not fit is dropped, and blanks what
    // part of it falls inside the buffer: the draw covers up to maxVertices,
    // and those must not be the last build's leftovers. Every cell writes
    // whole triangles from a multiple of 3, so a blank one is degenerate and
    // draws nothing.
    const uint at = atomic_fetch_add_explicit(count, vertices, memory_order_relaxed);
    if (at >= u.maxVertices || vertices > u.maxVertices - at) {   // no wrap in at + vertices
        for (uint v = at; v < u.maxVertices; v++)
            out[v].position = out[v].normal = packed_float3(0.0f);
        return;
    }
    // Each corner's normal once, and only for the corners on an edge the
    // surface crosses: a corner past the cell costs a field evaluation per
    // axis.
    uint used = 0;
    for (uint v = 0; v < vertices; v++) {
        const uchar2 e = kEdge[row[1 + v]];
        used |= (1u << e.x) | (1u << e.y);
    }
    float3 normal[8];
    for (uint i = 0; i < 8; i++)
        if (used & (1u << i))
            normal[i] = cornerNormal(i, base, value, u);
    for (uint v = 0; v < vertices; v++) {
        const uchar2 e = kEdge[row[1 + v]];
        const float t = (u.surface - value[e.x]) / (value[e.y] - value[e.x]);
        const float3 p = base + mix(corner(e.x), corner(e.y), t) * u.unitSize;
        out[at + v].position = packed_float3(p);
        out[at + v].normal = packed_float3(normal[e.x]);
    }
}

// One thread: the draw's arguments (MTLDrawPrimitivesIndirectArguments) from
// the count, capped at the buffer, so the draw never reads past it; and the
// most vertices any build has needed, which is never reset, so the CPU can
// read it at any time and size the buffer from it.
kernel void goo_build_count(constant GooBuildUniforms &u [[buffer(0)]],
                            device atomic_uint *count     [[buffer(3)]],
                            device uint *args             [[buffer(5)]],
                            device atomic_uint *peak      [[buffer(6)]])
{
    const uint n = atomic_load_explicit(count, memory_order_relaxed);
    atomic_fetch_max_explicit(peak, n, memory_order_relaxed);
    args[0] = min(n, u.maxVertices);   // vertexCount
    args[1] = 1;                       // instanceCount
    args[2] = 0;                       // vertexStart
    args[3] = 0;                       // baseInstance
}
