#ifndef CONSTANTS
#define CONSTANTS

const int BLOCK_SIZE = 16;
const int CHUNK_BLOCKS = 16;
const int CHUNK_VOXEL_SIZE = BLOCK_SIZE * CHUNK_BLOCKS;

const int BLOCK_VOXELS = BLOCK_SIZE * BLOCK_SIZE * BLOCK_SIZE;
const int CHUNK_BLOCK_COUNT = CHUNK_BLOCKS * CHUNK_BLOCKS * CHUNK_BLOCKS;
const int BLOCK_BITMAP_WORDS = BLOCK_VOXELS / 32;

const int CHUNK_STATE_FREE  = 0;
const int CHUNK_STATE_MONO  = 1;
const int CHUNK_STATE_BLOCK = 2;

const int BLOCK_STATE_FREE  = 0;
const int BLOCK_STATE_MONO  = 1;
const int BLOCK_STATE_VOXEL = 2;

const int renderDistance = 512;

const vec4 skyColor = vec4(0.4, 0.1, 0.1, 1.0);

#endif