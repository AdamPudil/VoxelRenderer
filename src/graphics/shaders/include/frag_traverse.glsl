#ifndef FRAG_TRAVERSE
#define FRAG_TRAVERSE

#include "constants.glsl"
#include "uniforms.glsl"
#include "world_functions.glsl"

vec3 getRay(vec2 fragCoord) {
    float aspect = uResolution.x / uResolution.y;
    vec2 p = (fragCoord / uResolution) * 2.0 - 1.0;
    p.x *= aspect;

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

void skipEmptyChunk(
    inout ivec3 v,
    inout vec3 tMax,
    vec3 tDelta,
    vec3 stepDir,
    inout vec3 normal
) {
    ivec3 lp = worldToLocalVoxelInChunk(v);

    int sx = (stepDir.x > 0.0) ? (CHUNK_VOXEL_SIZE - 1 - lp.x) : lp.x;
    int sy = (stepDir.y > 0.0) ? (CHUNK_VOXEL_SIZE - 1 - lp.y) : lp.y;
    int sz = (stepDir.z > 0.0) ? (CHUNK_VOXEL_SIZE - 1 - lp.z) : lp.z;

    float tx = tMax.x + float(sx) * tDelta.x;
    float ty = tMax.y + float(sy) * tDelta.y;
    float tz = tMax.z + float(sz) * tDelta.z;

    if (tx < ty && tx < tz) {
        v.x += int(stepDir.x) * (sx + 1);
        tMax.x += float(sx + 1) * tDelta.x;
        normal = vec3(-stepDir.x, 0.0, 0.0);
    } else if (ty < tz) {
        v.y += int(stepDir.y) * (sy + 1);
        tMax.y += float(sy + 1) * tDelta.y;
        normal = vec3(0.0, -stepDir.y, 0.0);
    } else {
        v.z += int(stepDir.z) * (sz + 1);
        tMax.z += float(sz + 1) * tDelta.z;
        normal = vec3(0.0, 0.0, -stepDir.z);
    }
}

void skipEmptyBlock(
    inout ivec3 v,
    inout vec3 tMax,
    vec3 tDelta,
    vec3 stepDir,
    inout vec3 normal
) {
    ivec3 lpChunk = worldToLocalVoxelInChunk(v);
    ivec3 lv = localChunkVoxelToVoxelInBlock(lpChunk);

    int sx = (stepDir.x > 0.0) ? (BLOCK_SIZE - 1 - lv.x) : lv.x;
    int sy = (stepDir.y > 0.0) ? (BLOCK_SIZE - 1 - lv.y) : lv.y;
    int sz = (stepDir.z > 0.0) ? (BLOCK_SIZE - 1 - lv.z) : lv.z;

    float tx = tMax.x + float(sx) * tDelta.x;
    float ty = tMax.y + float(sy) * tDelta.y;
    float tz = tMax.z + float(sz) * tDelta.z;

    if (tx < ty && tx < tz) {
        v.x += int(stepDir.x) * (sx + 1);
        tMax.x += float(sx + 1) * tDelta.x;
        normal = vec3(-stepDir.x, 0.0, 0.0);
    } else if (ty < tz) {
        v.y += int(stepDir.y) * (sy + 1);
        tMax.y += float(sy + 1) * tDelta.y;
        normal = vec3(0.0, -stepDir.y, 0.0);
    } else {
        v.z += int(stepDir.z) * (sz + 1);
        tMax.z += float(sz + 1) * tDelta.z;
        normal = vec3(0.0, 0.0, -stepDir.z);
    }
}

vec4 castTraceRay(vec3 pos, vec3 dir) {
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
        bool chunkValid;
        int slot;
        ChunkHeader ch = chunkHeaderAtWorld(v, chunkValid, slot);

        if (!chunkValid || ch.state == uint(CHUNK_STATE_FREE)) {
            skipEmptyChunk(v, tMax, tDelta, stepDir, normal);
            continue;
        }

        if (ch.state == uint(CHUNK_STATE_MONO)) {
            return getShade(decodeVoxel(uvec2(ch.data0, ch.data1)), normal);
        }

        BlockHeader bh = blockHeaderAtWorld(v, ch);

        if (bh.state == uint(BLOCK_STATE_FREE)) {
            skipEmptyBlock(v, tMax, tDelta, stepDir, normal);
            continue;
        }

        if (bh.state == uint(BLOCK_STATE_MONO)) {
            return getShade(decodeVoxel(uvec2(bh.data0, bh.data1)), normal);
        }

        if (voxelPresentAtWorld(v, bh)) {
            VoxelData voxel = voxelAtWorld(v, bh);
            if (voxel.opacity > 0.0) {
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

    return skyColor;
}

#endif