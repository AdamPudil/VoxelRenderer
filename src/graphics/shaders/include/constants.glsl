#ifndef CONSTANTS
#define CONSTANTS

const int BLOCK_SIZE = HIERARCHY_BLOCK_SIZE;
const int CHUNK_BLOCKS = 16;
const int CHUNK_VOXEL_SIZE = HIERARCHY_CHUNK_SIZE;

const int BLOCK_VOXELS = BLOCK_SIZE * BLOCK_SIZE * BLOCK_SIZE;
const int CHUNK_BLOCK_COUNT = CHUNK_BLOCKS * CHUNK_BLOCKS * CHUNK_BLOCKS;
const int BLOCK_BITMAP_WORDS = BLOCK_VOXELS / 32;

const int CHUNK_STATE_FREE  = 0;
const int CHUNK_STATE_MONO  = 1;
const int CHUNK_STATE_BLOCK = 2;

const int BLOCK_STATE_FREE  = 0;
const int BLOCK_STATE_MONO  = 1;
const int BLOCK_STATE_VOXEL = 2;

// Traversal step budget; spatial reach is bounded by the streamed world window.
const int renderDistance = 1024;

const vec4 skyColor = vec4(BACKGROUND_RGB, 1.0);

#endif
