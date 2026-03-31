#ifndef CONSTANTS
#define CONSTANTS

const int CHUNK_SIZE = 16;
const int CHUNK_VOXELS = CHUNK_SIZE * CHUNK_SIZE * CHUNK_SIZE;   // 4096
const int BITMAP_WORDS = CHUNK_VOXELS / 32;                      // 128

const int renderDistance = 256;

const vec4 skyColor = vec4(0.4, 0.1, 0.1, 1.0);
#endif