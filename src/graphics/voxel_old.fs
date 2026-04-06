#version 420 core
#include "include/constants.glsl"
#include "include/frag_math.glsl"
#include "include/frag_traverse.glsl"
#include "include/frag_shade.glsl"
#include "include/world_functions.glsl"

in vec2 uv;
out vec4 fragColor;

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

void main() {
    vec3 dir = getRay(gl_FragCoord.xy);
    vec3 pos = uCamPos;

    ivec3 v = ivec3(floor(pos));

    vec3 stepDir = sign(dir);

    vec3 safeDir = vec3(
        abs(dir.x) < 0.0001 ? (dir.x < 0.0 ? -0.0001 : 0.0001) : dir.x,
        abs(dir.y) < 0.0001 ? (dir.y < 0.0 ? -0.0001 : 0.0001) : dir.y,
        abs(dir.z) < 0.0001 ? (dir.z < 0.0 ? -0.0001 : 0.0001) : dir.z
    );

    vec3 tDelta = abs(1.0 / safeDir);
    vec3 next = floor(pos) + stepDir * 0.5 + 0.5;
    vec3 tMax = (next - pos) / safeDir;

    vec3 normal = vec3(0.0);

    for (int i = 0; i < renderDistance; i++) {
        uint id = voxelAtWorld(v);
        if (id != 0u) {
            vec3 baseColor = voxelColor(id);

            vec3 lightDir = normalize(vec3(1.0, 1.0, 0.8));
            float diff = max(dot(normalize(normal), lightDir), 0.0);
            float light = 0.3 + diff * 0.7;

            float dirTint = 1.0;
            if (abs(normal.x) > 0.5) dirTint = 0.8;
            if (abs(normal.z) > 0.5) dirTint = 1.0;
            if (abs(normal.y) > 0.5) dirTint = 1.2;

            fragColor = vec4(baseColor * light * dirTint, 1.0);
            return;
        }

        if (tMax.x < tMax.y && tMax.x < tMax.z) {
            v.x += int(stepDir.x);
            tMax.x += tDelta.x;
            normal = vec3(-stepDir.x, 0.0, 0.0);
        } else if (tMax.y < tMax.z) {
            v.y += int(stepDir.y);
            tMax.y += tDelta.y;
            normal = vec3(0.0, -stepDir.y, 0.0);
        } else {
            v.z += int(stepDir.z);
            tMax.z += tDelta.z;
            normal = vec3(0.0, 0.0, -stepDir.z);
        }
    }

    fragColor = skyColor;
}