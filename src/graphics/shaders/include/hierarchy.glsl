#ifndef RENDER_HIERARCHY
#define RENDER_HIERARCHY
// The index buffer also owns derived nodes: flags, material low/high, occupancy.
// Zero pointers retain compatibility with isolated/older producers.
uniform int uGeometryRingCount;
uniform int uLightingRingCount;
uniform vec2 uGeometryRings[HIERARCHY_MAX_RINGS];
uniform vec2 uLightingRings[HIERARCHY_MAX_RINGS];
uniform vec3 uLodFocus;
uniform float uLodGuard;
uniform float uLodTransition;
uniform float uInteractionRadius;

ivec3 hierarchyLower(ivec3 cell, int size) {
    return ivec3(floor(vec3(cell) / float(size))) * size;
}
float hierarchyDistance(ivec3 cell, int size) {
    vec2 lower = vec2(hierarchyLower(cell, size).xz);
    vec2 delta = max(max(lower - uLodFocus.xz, uLodFocus.xz - lower - float(size)), vec2(0.0));
    return length(delta);
}
// A node touching a finer ring belongs to that ring in its entirety. Geometry
// has no change in occupancy, so its transition blends material, never ray steps.
float hierarchyWeight(ivec3 cell, int size, bool lighting) {
    if (uIconMode) return 0.0;
    int count = lighting ? uLightingRingCount : uGeometryRingCount;
    if (count == 0) return 0.0;
    float distance = hierarchyDistance(cell, size) - uLodGuard;
    if (!lighting && distance <= uInteractionRadius) return 0.0;
    float start = 0.0;
    for (int i = 0; i < HIERARCHY_MAX_RINGS; ++i) {
        if (i >= count) break;
        vec2 ring = lighting ? uLightingRings[i] : uGeometryRings[i];
        if (ring.y >= float(size)) {
            if (i == 0) return 1.0;
            return uLodTransition > 0.0 ? smoothstep(start, start + uLodTransition, distance) : (distance > start ? 1.0 : 0.0);
        }
        start = ring.x;
    }
    return 0.0;
}
uvec4 hierarchyFetch(uint pointer, int child) {
    DIAG_NODES();
    int base = int(pointer - 1u) + child * 4;
    return uvec4(texelFetch(uIndexTex, base).r, texelFetch(uIndexTex, base+1).r,
                 texelFetch(uIndexTex, base+2).r, texelFetch(uIndexTex, base+3).r);
}
int hierarchyChild(ivec3 cell, int parentSize, int size) {
    ivec3 p = (cell - hierarchyLower(cell, parentSize)) / size;
    return 1 + p.x + 4 * p.y + HIERARCHY_BLOCK_SIZE * p.z;
}
uvec4 hierarchyMono(uint lo, uint hi, int size) {
    VoxelData m = decodeVoxel(uvec2(lo, hi));
    if (m.opacity == 0.0 && m.ior == 0.0) return uvec4(0u);
    uint flags = 1u | (m.opacity == 1.0 ? 4u : 8u) | (m.luminescence > 0.0 ? 16u : 0u);
    return uvec4(flags, lo, hi, uint(size * size * size));
}
// Procedural descriptor (chunk state 3): root word offset + 1, optional
// authored overlay header base + 1, opaque material low word. Column nodes
// contain relative child indices, signed exclusive height and subtree min/max. A leaf's side
// defines published geometry; it never claims canonical fine occupancy.
uvec2 sampleTerrainPacked(ivec3 cell, ChunkHeader ch, out int size) {
    size = HIERARCHY_CHUNK_SIZE;
    if (ch.data1 != 0u) {
        BlockHeader bh = fetchBlockHeader(ch.data1 - 1u + uint(localBlockIndex(localChunkVoxelToBlockCoord(worldToLocalVoxelInChunk(cell)))));
        if (bh.state != 3u) {
            size = HIERARCHY_BLOCK_SIZE;
            if (bh.state == 0u) return uvec2(0u);
            if (bh.state == 1u) return uvec2(bh.data0, bh.data1);
#if TERRAIN_OVERLAY_SKIPS
            // Reuse the exact summaries already packed for edited voxel blocks.
            // Only proven-empty regions may skip; mixed groups retain exact
            // voxel lookup, including thin geometry, emitters and clear glass.
            if (bh.data2 != 0u) {
                uvec4 node = hierarchyFetch(bh.data2, 0);
                if ((node.x & 3u) == 0u) return uvec2(0u);
                node = hierarchyFetch(bh.data2, hierarchyChild(cell, HIERARCHY_BLOCK_SIZE, HIERARCHY_VOXEL_GROUP));
                if ((node.x & 3u) == 0u) {
                    size = HIERARCHY_VOXEL_GROUP;
                    return uvec2(0u);
                }
            }
#endif
            size = 1;
            return voxelPackedAtWorld(cell, bh);
        }
    }
    if (ch.data0 == 0u) { size = ch.data1 != 0u ? HIERARCHY_BLOCK_SIZE : HIERARCHY_CHUNK_SIZE; return uvec2(0u); }
    int root = int(ch.data0 - 1u);
    int node = 0;
    ivec2 local = worldToLocalVoxelInChunk(cell).xz;
    int height = 0;
    for (int level = 0; level < 5; ++level) {
        DIAG_NODES();
        uint children = texelFetch(uIndexTex, root + node * 4).r;
        height = int(texelFetch(uIndexTex, root + node * 4 + 1).r);
        int lower = hierarchyLower(cell, size).y;
        int minimum = int(texelFetch(uIndexTex, root + node * 4 + 2).r);
        int maximum = int(texelFetch(uIndexTex, root + node * 4 + 3).r);
        if (lower >= maximum || lower + size <= minimum) {
            if (ch.data1 != 0u) size = min(size, HIERARCHY_BLOCK_SIZE);
            return lower >= maximum ? uvec2(0u) : uvec2(ch.data2, 255u);
        }
        if (children == 0u) break;
        size /= HIERARCHY_FACTOR;
        ivec2 child = (local / size) % HIERARCHY_FACTOR;
        node = int(children) + child.x + HIERARCHY_FACTOR * child.y;
    }
    // Do not step across any edited block while traversing a coarse base leaf.
    if (ch.data1 != 0u) size = min(size, HIERARCHY_BLOCK_SIZE);
    return cell.y < height ? uvec2(ch.data2, 255u) : uvec2(0u);
}
VoxelData sampleTerrain(ivec3 cell, ChunkHeader ch, out int size) {
    return decodeVoxel(sampleTerrainPacked(cell, ch, size));
}

bool hierarchyInteractionAvailable(ivec3 cell) {
    bool valid; int slot;
    ChunkHeader ch = chunkHeaderAtWorld(cell, valid, slot);
    if (!valid) return false;
    if (ch.state != 3u) return true;
    if (ch.data1 != 0u) {
        BlockHeader overlay = fetchBlockHeader(ch.data1 - 1u + uint(localBlockIndex(localChunkVoxelToBlockCoord(worldToLocalVoxelInChunk(cell)))));
        if (overlay.state != 3u) return true;
    }
    if (ch.data0 == 0u) return false;
    int root = int(ch.data0 - 1u), node = 0, size = HIERARCHY_CHUNK_SIZE;
    ivec2 local = worldToLocalVoxelInChunk(cell).xz;
    for (int level = 0; level < 5; ++level) {
        DIAG_NODES();
        uint children = texelFetch(uIndexTex, root + node * 4).r;
        if (children == 0u) return size == 1;
        size /= HIERARCHY_FACTOR;
        ivec2 child = (local / size) % HIERARCHY_FACTOR;
        node = int(children) + child.x + HIERARCHY_FACTOR * child.y;
    }
    return false;
}

// Query a specific aligned level. Larger proven-uniform nodes answer directly;
// mixed nodes always descend. Missing summary pointers are deliberately mixed.
uvec4 hierarchyAt(ivec3 cell, int size) {
    bool valid; int slot;
    ChunkHeader ch = chunkHeaderAtWorld(cell, valid, slot);
    if (!valid || ch.state == 0u) return uvec4(0u);
    if (ch.state == 1u) return hierarchyMono(ch.data0, ch.data1, size);
    if (ch.state == 3u) {
        // No proxy occupancy enters canonical Summary fields, even at size 1.
        // Edited blocks may still answer through their exact authored headers.
        if (size > HIERARCHY_BLOCK_SIZE || ch.data1 == 0u) return uvec4(2u, 0u, 0u, 0u);
        BlockHeader overlay = fetchBlockHeader(ch.data1 - 1u + uint(localBlockIndex(localChunkVoxelToBlockCoord(worldToLocalVoxelInChunk(cell)))));
        if (overlay.state == 3u) return uvec4(2u, 0u, 0u, 0u);
        ch = ChunkHeader(2u, ch.data1 - 1u, 0u, 0u);
    }
    if (size >= HIERARCHY_BLOCK_GROUP) return ch.data2 == 0u ? uvec4(2u,0u,0u,0u) :
        hierarchyFetch(ch.data2, size == HIERARCHY_CHUNK_SIZE ? 0 : hierarchyChild(cell, HIERARCHY_CHUNK_SIZE, HIERARCHY_BLOCK_GROUP));
    BlockHeader bh = blockHeaderAtWorld(cell, ch);
    if (bh.state == 0u) return uvec4(0u);
    if (bh.state == 1u) return hierarchyMono(bh.data0, bh.data1, size);
    if (size >= HIERARCHY_VOXEL_GROUP) return bh.data2 == 0u ? uvec4(2u,0u,0u,0u) :
        hierarchyFetch(bh.data2, size == HIERARCHY_BLOCK_SIZE ? 0 : hierarchyChild(cell, HIERARCHY_BLOCK_SIZE, HIERARCHY_VOXEL_GROUP));
    if (!voxelPresentAtWorld(cell, bh)) return uvec4(0u);
    VoxelBlockHeader vh = fetchVoxelBlockHeader(bh.data0);
    int index = localVoxelIndexInBlock(localChunkVoxelToVoxelInBlock(worldToLocalVoxelInChunk(cell)));
    int base = int(vh.palette_base + voxelPaletteIndex(vh.index_base, index) * 2u);
    return hierarchyMono(texelFetch(uPaletteTex,base).r, texelFetch(uPaletteTex,base+1).r, 1);
}
bool hierarchyFullOpaque(uvec4 node, int size) {
    return node.w == uint(size * size * size) && (node.x & 28u) == 4u;
}
bool hierarchyAccept(uvec4 node, ivec3 cell, int size, bool renderLod, int maximumSize) {
    return (node.x & 3u) != 2u ||
        (renderLod && size <= maximumSize && hierarchyFullOpaque(node, size) && hierarchyWeight(cell, size, false) > 0.0);
}
uvec2 sampleHierarchyPacked(ivec3 cell, ChunkHeader ch, out int size, bool renderLod, int maximumSize) {
    size = HIERARCHY_CHUNK_SIZE;
    if (ch.state == 0u) return uvec2(0u);
    if (ch.state == 1u) return uvec2(ch.data0, ch.data1);
    if (ch.state == 3u) return sampleTerrainPacked(cell, ch, size);
    if (ch.data2 != 0u) {
        uvec4 node = hierarchyFetch(ch.data2, 0);
        if (hierarchyAccept(node, cell, size, renderLod, maximumSize)) return node.yz;
        size = HIERARCHY_BLOCK_GROUP;
        node = hierarchyFetch(ch.data2, hierarchyChild(cell, HIERARCHY_CHUNK_SIZE, HIERARCHY_BLOCK_GROUP));
        if (hierarchyAccept(node, cell, size, renderLod, maximumSize)) return node.yz;
    }
    BlockHeader bh = blockHeaderAtWorld(cell, ch);
    size = HIERARCHY_BLOCK_SIZE;
    if (bh.state == 0u) return uvec2(0u);
    if (bh.state == 1u) return uvec2(bh.data0, bh.data1);
    if (bh.data2 != 0u) {
        uvec4 node = hierarchyFetch(bh.data2, 0);
        if (hierarchyAccept(node, cell, size, renderLod, maximumSize)) return node.yz;
        size = HIERARCHY_VOXEL_GROUP;
        node = hierarchyFetch(bh.data2, hierarchyChild(cell, HIERARCHY_BLOCK_SIZE, HIERARCHY_VOXEL_GROUP));
        if (hierarchyAccept(node, cell, size, renderLod, maximumSize)) return node.yz;
    }
    size = 1;
    return voxelPackedAtWorld(cell, bh);
}
VoxelData sampleHierarchy(ivec3 cell, out int size, bool renderLod, int maximumSize) {
    bool valid; int slot;
    ChunkHeader ch = chunkHeaderAtWorld(cell, valid, slot);
    return decodeVoxel(sampleHierarchyPacked(cell, ch, size, renderLod, maximumSize));
}
VoxelData sampleHierarchy(ivec3 cell, out int size, bool renderLod) {
    return sampleHierarchy(cell, size, renderLod, HIERARCHY_CHUNK_SIZE);
}
// Lighting queries published geometry explicitly. These counts describe only
// the visible column union, never canonical occupancy of ungenerated terrain.
uvec4 hierarchyPublishedAt(ivec3 cell, int size) {
    bool valid; int slot;
    ChunkHeader ch = chunkHeaderAtWorld(cell, valid, slot);
    if (!valid || ch.state != 3u) return hierarchyAt(cell, size);
    if (ch.data0 == 0u && ch.data1 == 0u) return uvec4(2u, 0u, 0u, 0u);
    int regionSize;
    VoxelData material = sampleTerrain(cell, ch, regionSize);
    if (regionSize < size) return uvec4(2u, 0u, 0u, 0u);
    if (isAir(material)) return uvec4(0u);
    uint flags = 1u | (material.opacity == 1.0 ? 4u : 8u) | (material.luminescence > 0.0 ? 16u : 0u);
    return uvec4(flags, 0u, 0u, uint(size * size * size));
}

// Only a complete opaque cell with a completely empty adjoining cell may share
// irradiance. This proves a connected planar patch with an actual occupied
// center; inset, opposing, sparse, glass and emissive surfaces stay finest.
int hierarchyLightingSizeBelow(ivec3 cell, vec3 normal, int maximumSize) {
    if (dot(normal, normal) == 0.0 || uLightingRingCount == 0 || uIconMode) return 1;
    int axis = abs(normal.x) > 0.5 ? 0 : (abs(normal.y) > 0.5 ? 1 : 2);
    for (int size = maximumSize; size >= HIERARCHY_VOXEL_GROUP; size /= HIERARCHY_FACTOR) {
        if (hierarchyWeight(cell, size, true) <= 0.0) continue;
        ivec3 lower = hierarchyLower(cell, size);
        int face = lower[axis] + (normal[axis] > 0.0 ? size - 1 : 0);
        if (cell[axis] != face) continue;
        if (!hierarchyFullOpaque(hierarchyPublishedAt(cell, size), size)) continue;
        ivec3 neighbor = lower + ivec3(normal) * size;
        // Do not share across the streaming boundary where occluders are unknown.
        if (!chunkInRegion(worldToChunkCoord(neighbor))) continue;
        if ((hierarchyPublishedAt(neighbor, size).x & 3u) == 0u) return size;
    }
    return 1;
}
int hierarchyLightingSize(ivec3 cell, vec3 normal) {
    return hierarchyLightingSizeBelow(cell, normal, HIERARCHY_CHUNK_SIZE);
}
#endif
