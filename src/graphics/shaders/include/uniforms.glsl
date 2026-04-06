#ifndef UNIFORMS
#define UNIFORMS

uniform vec2 uResolution;
uniform vec3 uCamPos;
uniform vec3 uCamDir;

uniform ivec3 uRegionOriginChunk;
uniform ivec3 uRegionSizeChunks;

uniform usamplerBuffer uChunkHeaderTex;
uniform usamplerBuffer uBlockHeaderTex;
uniform usamplerBuffer uVoxelBlockHeaderTex;
uniform usamplerBuffer uBitmapTex;
uniform usamplerBuffer uPaletteTex;
uniform usamplerBuffer uIndexTex;

#endif