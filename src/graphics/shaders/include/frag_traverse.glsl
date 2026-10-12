#ifndef FRAG_TRAVERSE
#define FRAG_TRAVERSE

#include "constants.glsl"
#include "uniforms.glsl"
#include "world_functions.glsl"

vec3 getRay(vec2 fragCoord) {
    float aspect = uResolution.x / uResolution.y;
    vec2 p = (fragCoord / uResolution) * 2.0 - 1.0;
    p.x *= aspect;
    if (uIconMode) p *= 0.45;

    vec3 forward = normalize(uCamDir);

    vec3 upRef = vec3(0.0, 1.0, 0.0);
    if (abs(dot(forward, upRef)) > 0.999) {
        upRef = vec3(0.0, 0.0, 1.0);
    }

    vec3 right = normalize(cross(forward, upRef));
    vec3 up = normalize(cross(right, forward));

    return normalize(forward + p.x * right + p.y * up);
}

vec4 getShade(VoxelData voxel, vec3 normal) {
    vec3 lightDir = normalize(vec3(1.0, 1.0, 0.8));
    float diff = max(dot(normalize(normal), lightDir), 0.0);
    float light = 0.25 + diff * 0.75;

    float dirTint = 1.0;
    if (abs(normal.x) > 0.5) dirTint = 0.8;
    if (abs(normal.z) > 0.5) dirTint = 1.0;
    if (abs(normal.y) > 0.5) dirTint = 1.2;

    vec3 lit = voxel.color * light * dirTint;
    lit += voxel.color * voxel.luminescence * 0.75;

    return vec4(lit, voxel.opacity);
}

// Advance every coordinate to the ray's exit from an empty region.
// Updating only the exit axis leaves the other coordinates behind the ray.
void skipEmptyRegion(vec3 pos, vec3 dir, int size,
                     inout ivec3 v, inout vec3 tMax,
                     vec3 stepDir, inout vec3 normal) {
    ivec3 lower = ivec3(floor(vec3(v) / float(size))) * size;
    ivec3 upper = lower + ivec3(size);
    vec3 boundary = mix(vec3(lower), vec3(upper), greaterThan(dir, vec3(0.0)));
    vec3 exitTimes = vec3(1e30);
    for (int axis = 0; axis < 3; axis++) {
        if (dir[axis] != 0.0) exitTimes[axis] = (boundary[axis] - pos[axis]) / dir[axis];
    }
    int axis = exitTimes.x < exitTimes.y ? 0 : 1;
    if (exitTimes.z < exitTimes[axis]) axis = 2;
    float t = exitTimes[axis];
    v = ivec3(floor(pos + dir * t));
    // Exact boundary ownership, including negative rays and corner ties.
    for (int i = 0; i < 3; i++) {
        if (exitTimes[i] == t) v[i] = dir[i] > 0.0 ? upper[i] : lower[i] - 1;
    }
    normal = vec3(0.0);
    normal[axis] = -stepDir[axis];
    vec3 next = vec3(v) + max(stepDir, vec3(0.0));
    tMax = vec3(1e30);
    for (int i = 0; i < 3; i++) {
        if (dir[i] != 0.0) tMax[i] = (next[i] - pos[i]) / dir[i];
    }
}

vec4 castTraceRay(vec3 pos, vec3 dir, out ivec3 hitVoxel,
                  out vec3 hitNormal, out bool hit) {
    hit = false;
    hitVoxel = ivec3(0);
    hitNormal = vec3(0.0);
    ivec3 v = ivec3(floor(pos));

    vec3 stepDir = sign(dir);

    vec3 tDelta = vec3(1e30);
    vec3 tMax = vec3(1e30);
    vec3 next = floor(pos) + max(stepDir, vec3(0.0));
    for (int axis = 0; axis < 3; axis++) {
        if (dir[axis] != 0.0) {
            tDelta[axis] = abs(1.0 / dir[axis]);
            tMax[axis] = (next[axis] - pos[axis]) / dir[axis];
        }
    }

    vec3 normal = vec3(0.0);

    for (int i = 0; i < renderDistance; i++) {
        bool chunkValid;
        int slot;
        ChunkHeader ch = chunkHeaderAtWorld(v, chunkValid, slot);

        if (!chunkValid || ch.state == uint(CHUNK_STATE_FREE)) {
            skipEmptyRegion(pos, dir, CHUNK_VOXEL_SIZE, v, tMax, stepDir, normal);
            continue;
        }

        if (ch.state == uint(CHUNK_STATE_MONO)) {
            hit = true;
            hitVoxel = v;
            hitNormal = normal;
            return getShade(decodeVoxel(uvec2(ch.data0, ch.data1)), normal);
        }

        BlockHeader bh = blockHeaderAtWorld(v, ch);

        if (bh.state == uint(BLOCK_STATE_FREE)) {
            skipEmptyRegion(pos, dir, BLOCK_SIZE, v, tMax, stepDir, normal);
            continue;
        }

        if (bh.state == uint(BLOCK_STATE_MONO)) {
            hit = true;
            hitVoxel = v;
            hitNormal = normal;
            return getShade(decodeVoxel(uvec2(bh.data0, bh.data1)), normal);
        }

        if (voxelPresentAtWorld(v, bh)) {
            VoxelData voxel = voxelAtWorld(v, bh);
            if (voxel.opacity > 0.0) {
                hit = true;
                hitVoxel = v;
                hitNormal = normal;
                return getShade(voxel, normal);
            }
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

    return uIconMode ? vec4(0.0) : skyColor;
}

#endif
