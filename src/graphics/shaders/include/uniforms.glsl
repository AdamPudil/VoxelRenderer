#ifndef UNIFORMS
#define UNIFORMS

uniform vec2 uResolution;
uniform vec3 uCamPos;
uniform vec3 uCamDir;

// region origin in chunk coordinates, not voxel coordinates
uniform ivec3 uRegionOriginChunk;
uniform ivec3 uRegionSizeChunks;

// one uint per slot: 0 = inactive, nonzero = active
uniform usamplerBuffer uChunkActiveTex;

// packed bitmap data for all slots
uniform usamplerBuffer uBitmapTex;

// voxel ids for all slots
uniform usamplerBuffer uVoxelTex;

#endif