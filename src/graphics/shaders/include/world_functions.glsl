#ifndef WORLD_FUNCTIONS
#define WORLD_FUNCTIONS

#include "frag_math.glsl"
#include "constants.glsl"
#include "uniforms.glsl"

ivec3 worldToChunkCoord(ivec3 wp) {
    return ivec3(
        floorDiv(wp.x, CHUNK_SIZE),
        floorDiv(wp.y, CHUNK_SIZE),
        floorDiv(wp.z, CHUNK_SIZE)
    );
}

ivec3 worldToLocalVoxel(ivec3 wp) {
    return ivec3(
        positiveMod(wp.x, CHUNK_SIZE),
        positiveMod(wp.y, CHUNK_SIZE),
        positiveMod(wp.z, CHUNK_SIZE)
    );
}

int localVoxelIndex(ivec3 lp) {
    return lp.x + lp.y * CHUNK_SIZE + lp.z * CHUNK_SIZE * CHUNK_SIZE;
}

bool chunkInRegion(ivec3 cc) {
    ivec3 r = cc - uRegionOriginChunk;
    return r.x >= 0 && r.y >= 0 && r.z >= 0 &&
           r.x < uRegionSizeChunks.x &&
           r.y < uRegionSizeChunks.y &&
           r.z < uRegionSizeChunks.z;
}

int chunkSlot(ivec3 cc) {
    ivec3 r = cc - uRegionOriginChunk;
    return r.x
         + r.y * uRegionSizeChunks.x
         + r.z * uRegionSizeChunks.x * uRegionSizeChunks.y;
}

bool slotActive(int slot) {
    return texelFetch(uChunkActiveTex, slot).r != 0u;
}

bool voxelOccupiedInSlot(int slot, ivec3 localPos) {
    int local = localVoxelIndex(localPos);
    int word = local >> 5;
    int bit = local & 31;

    int bitmapIndex = slot * BITMAP_WORDS + word;
    uint bitsWord = texelFetch(uBitmapTex, bitmapIndex).r;

    return ((bitsWord >> bit) & 1u) != 0u;
}

uint voxelIdInSlot(int slot, ivec3 localPos) {
    int local = localVoxelIndex(localPos);
    int voxelIndex = slot * CHUNK_VOXELS + local;
    return texelFetch(uVoxelTex, voxelIndex).r;
}

uint voxelAtWorld(ivec3 wp) {
    ivec3 cc = worldToChunkCoord(wp);

    if (!chunkInRegion(cc)) return 0u;

    int slot = chunkSlot(cc);
    if (!slotActive(slot)) return 0u;

    ivec3 lp = worldToLocalVoxel(wp);

    if (!voxelOccupiedInSlot(slot, lp)) return 0u;

    return voxelIdInSlot(slot, lp);
}

vec3 voxelColor(uint id) {
    if (id == 1u) return vec3(0.376, 0.239, 0.114);
    if (id == 2u) return vec3(0.35, 0.8, 0.35);
    if (id == 3u) return vec3(0.5, 0.5, 0.5);
    return vec3(1.0, 0.0, 1.0);
}

#endif