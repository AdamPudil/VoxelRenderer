#ifndef WORLD_FUNCTIONS
#define WORLD_FUNCTIONS

#include "frag_math.glsl"
#include "constants.glsl"
#include "uniforms.glsl"

struct VoxelData {
    vec3 color;
    float transparency;
    float opacity;
    float reflectiveness;
    float luminescence;
};

struct ChunkHeader {
    uint state;
    uint data0;
    uint data1;
    uint data2;
};

struct BlockHeader {
    uint state;
    uint data0;
    uint data1;
    uint data2;
};

struct VoxelBlockHeader {
    uint bitmap_base;
    uint palette_base;
    uint index_base;
    uint info;
};

ivec3 worldToChunkCoord(ivec3 wp) {
    return ivec3(
        floorDiv(wp.x, CHUNK_VOXEL_SIZE),
        floorDiv(wp.y, CHUNK_VOXEL_SIZE),
        floorDiv(wp.z, CHUNK_VOXEL_SIZE)
    );
}

ivec3 worldToLocalVoxelInChunk(ivec3 wp) {
    return ivec3(
        positiveMod(wp.x, CHUNK_VOXEL_SIZE),
        positiveMod(wp.y, CHUNK_VOXEL_SIZE),
        positiveMod(wp.z, CHUNK_VOXEL_SIZE)
    );
}

ivec3 localChunkVoxelToBlockCoord(ivec3 lp) {
    return ivec3(
        lp.x / BLOCK_SIZE,
        lp.y / BLOCK_SIZE,
        lp.z / BLOCK_SIZE
    );
}

ivec3 localChunkVoxelToVoxelInBlock(ivec3 lp) {
    return ivec3(
        lp.x % BLOCK_SIZE,
        lp.y % BLOCK_SIZE,
        lp.z % BLOCK_SIZE
    );
}

int localBlockIndex(ivec3 lb) {
    return lb.x
         + lb.y * CHUNK_BLOCKS
         + lb.z * CHUNK_BLOCKS * CHUNK_BLOCKS;
}

int localVoxelIndexInBlock(ivec3 lv) {
    return lv.x
         + lv.y * BLOCK_SIZE
         + lv.z * BLOCK_SIZE * BLOCK_SIZE;
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

ChunkHeader fetchChunkHeader(int slot) {
    int base = slot * 4;
    return ChunkHeader(
        texelFetch(uChunkHeaderTex, base + 0).r,
        texelFetch(uChunkHeaderTex, base + 1).r,
        texelFetch(uChunkHeaderTex, base + 2).r,
        texelFetch(uChunkHeaderTex, base + 3).r
    );
}

BlockHeader fetchBlockHeader(uint index) {
    int base = int(index) * 4;
    return BlockHeader(
        texelFetch(uBlockHeaderTex, base + 0).r,
        texelFetch(uBlockHeaderTex, base + 1).r,
        texelFetch(uBlockHeaderTex, base + 2).r,
        texelFetch(uBlockHeaderTex, base + 3).r
    );
}

VoxelBlockHeader fetchVoxelBlockHeader(uint index) {
    int base = int(index) * 4;
    return VoxelBlockHeader(
        texelFetch(uVoxelBlockHeaderTex, base + 0).r,
        texelFetch(uVoxelBlockHeaderTex, base + 1).r,
        texelFetch(uVoxelBlockHeaderTex, base + 2).r,
        texelFetch(uVoxelBlockHeaderTex, base + 3).r
    );
}

VoxelData decodeVoxel(uvec2 voxelPacked) {
    uint lo = voxelPacked.x;
    uint hi = voxelPacked.y;

    VoxelData v;
    v.color = vec3(
        float((lo >> 0u) & 0xFFu),
        float((lo >> 8u) & 0xFFu),
        float((lo >> 16u) & 0xFFu)
    ) / 255.0;

    v.transparency   = float((lo >> 24u) & 0xFFu) / 255.0;
    v.opacity        = float((hi >> 0u)  & 0xFFu) / 255.0;
    v.reflectiveness = float((hi >> 8u)  & 0xFFu) / 255.0;
    v.luminescence   = float((hi >> 16u) & 0xFFu) / 255.0;
    return v;
}

VoxelData voxelFromPalette(uint paletteBase, uint paletteIndex) {
    int base = int(paletteBase + paletteIndex * 2u);
    return decodeVoxel(uvec2(
        texelFetch(uPaletteTex, base + 0).r,
        texelFetch(uPaletteTex, base + 1).r
    ));
}

VoxelData voxelFromBlockId(uint blockId) {
    VoxelData v;
    v.transparency = 0.0;
    v.opacity = 1.0;
    v.reflectiveness = 0.0;
    v.luminescence = 0.0;

    if (blockId == 0u) {
        v.color = vec3(0.0);
        v.opacity = 0.0;
    } else if (blockId == 1u) {
        v.color = vec3(120.0, 120.0, 120.0) / 255.0;
    } else if (blockId == 2u) {
        v.color = vec3(70.0, 70.0, 70.0) / 255.0;
    } else if (blockId == 3u) {
        v.color = vec3(50.0, 90.0, 220.0) / 255.0;
    } else {
        v.color = vec3(1.0, 0.0, 1.0);
    }

    return v;
}

bool voxelBitSet(uint bitmapBase, int voxelIndex) {
    int word = voxelIndex >> 5;
    int bit = voxelIndex & 31;
    uint bits = texelFetch(uBitmapTex, int(bitmapBase) + word).r;
    return ((bits >> bit) & 1u) != 0u;
}

uint voxelPaletteIndex(uint indexBase, int voxelIndex) {
    return texelFetch(uIndexTex, int(indexBase) + voxelIndex).r;
}

ChunkHeader chunkHeaderAtWorld(ivec3 wp, out bool valid, out int slot) {
    ivec3 cc = worldToChunkCoord(wp);
    if (!chunkInRegion(cc)) {
        valid = false;
        slot = -1;
        return ChunkHeader(0u, 0u, 0u, 0u);
    }

    valid = true;
    slot = chunkSlot(cc);
    return fetchChunkHeader(slot);
}

BlockHeader blockHeaderAtWorld(ivec3 wp, ChunkHeader ch) {
    ivec3 lp = worldToLocalVoxelInChunk(wp);
    ivec3 lb = localChunkVoxelToBlockCoord(lp);
    int blockIndex = localBlockIndex(lb);
    return fetchBlockHeader(ch.data0 + uint(blockIndex));
}

bool voxelPresentAtWorld(ivec3 wp, BlockHeader bh) {
    ivec3 lp = worldToLocalVoxelInChunk(wp);
    ivec3 lv = localChunkVoxelToVoxelInBlock(lp);
    int localVoxel = localVoxelIndexInBlock(lv);

    VoxelBlockHeader vh = fetchVoxelBlockHeader(bh.data0);
    return voxelBitSet(vh.bitmap_base, localVoxel);
}

VoxelData voxelAtWorld(ivec3 wp, BlockHeader bh) {
    ivec3 lp = worldToLocalVoxelInChunk(wp);
    ivec3 lv = localChunkVoxelToVoxelInBlock(lp);
    int localVoxel = localVoxelIndexInBlock(lv);

    VoxelBlockHeader vh = fetchVoxelBlockHeader(bh.data0);
    uint pIndex = voxelPaletteIndex(vh.index_base, localVoxel);
    return voxelFromPalette(vh.palette_base, pIndex);
}

#endif