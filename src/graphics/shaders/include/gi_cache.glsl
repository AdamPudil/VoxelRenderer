#ifndef GI_CACHE
#define GI_CACHE
// Eight GL 4.2 image units. No payload is read in the draw that claims it.
layout(r32ui, binding=0) coherent uniform uimageBuffer uGiStamp;
layout(rgba32i, binding=1) uniform iimageBuffer uGiKey;
layout(rgba32f, binding=2) uniform imageBuffer uGiDirect;
layout(rgba32f, binding=3) uniform imageBuffer uGiSum;
layout(rgba32f, binding=4) uniform imageBuffer uGiResult;
// Per slot: queued, direct-ready frame, stage, last-used frame.
layout(r32ui, binding=5) coherent uniform uimageBuffer uGiState;
// Header: head, tail, batch base, batch count, rays, hits, misses, overflows.
// Followed by persistent ring, then a snapshot of this frame's jobs.
layout(r32ui, binding=6) coherent uniform uimageBuffer uGiQueue;
// Separate direct-only dependency marker: 1 until seen by a primary ray.
layout(r32ui, binding=7) coherent uniform uimageBuffer uGiDependency;
uniform uint uGiFrame;
uniform uint uGiValidFrom;

uint giHash(ivec4 key) {
    uvec4 k = uvec4(key);
    uint h = k.x * 0x8da6b343u ^ k.y * 0xd8163841u ^ k.z * 0xcb1ab31fu ^ k.w * 0x9e3779b9u;
    h ^= h >> 16u; h *= 0x7feb352du;
    return h ^ (h >> 15u);
}
ivec4 giKey(ivec3 cell, vec3 normal) {
    int axis = abs(normal.x) > 0.5 ? 0 : (abs(normal.y) > 0.5 ? 1 : 2);
    return ivec4(cell, axis * 2 + (normal[axis] > 0.0 ? 1 : 0));
}
vec3 giNormal(ivec4 key) {
    vec3 n = vec3(0.0); n[key.w / 2] = (key.w % 2 == 1) ? 1.0 : -1.0; return n;
}
void giEnqueue(int slot) {
    if (imageLoad(uGiState, slot * 4).r != 0u) return;
    if (imageAtomicCompSwap(uGiState, slot * 4, 0u, 1u) != 0u) return;
    // Bounded CAS retries: contention/full queue defers work, never spins.
    for (int attempt=0; attempt<16; ++attempt) {
        uint tail = imageLoad(uGiQueue, 1).r;
        uint head = imageLoad(uGiQueue, 0).r;
        if (tail - head >= uint(GI_QUEUE_CAPACITY)) break;
        if (imageAtomicCompSwap(uGiQueue, 1, tail, tail + 1u) == tail) {
            imageStore(uGiQueue, 8 + int(tail & uint(GI_QUEUE_CAPACITY-1)), uvec4(uint(slot)));
            return;
        }
    }
    imageAtomicExchange(uGiState, slot * 4, 0u);
    imageAtomicAdd(uGiQueue, 7, 1u);
}
int giFind(ivec4 key, bool primary) {
    uint hash = giHash(key);
    for (uint probe=0u; probe<16u; ++probe) {
        int slot = int((hash + probe) & uint(LIGHTING_CACHE_SIZE-1));
        uint stamp = imageLoad(uGiStamp, slot).r;
        if (stamp >= uGiValidFrom && stamp < uGiFrame) {
            if (!all(equal(imageLoad(uGiKey, slot), key))) continue;
            if (imageLoad(uGiState, slot * 4 + 3).r != uGiFrame)
                imageAtomicMax(uGiState, slot * 4 + 3, uGiFrame);
            if (primary && imageLoad(uGiDependency, slot).r != 0u)
                imageAtomicExchange(uGiDependency, slot, 0u);
            return slot;
        }
        if (stamp < uGiValidFrom) {
            if (imageAtomicCompSwap(uGiStamp, slot, stamp, uGiFrame) == stamp) {
                imageStore(uGiKey, slot, key);
                imageStore(uGiDirect, slot, vec4(0.0));
                imageStore(uGiSum, slot, vec4(0.0));
                imageStore(uGiResult, slot, vec4(0.0));
                for (int j=0; j<3; ++j) imageStore(uGiState, slot*4+j, uvec4(0u));
                imageStore(uGiState, slot*4+3, uvec4(uGiFrame));
                imageStore(uGiDependency, slot, uvec4(primary ? 0u : 1u));
                giEnqueue(slot);
                imageAtomicAdd(uGiQueue, 6, 1u);
            }
        }
        // Same-draw claim: do not read key/value or create duplicate entries.
        return -1;
    }
#if GI_DIAGNOSTICS
    imageAtomicAdd(uGiQueue, 7, 1u);
#endif
    return -1;
}
vec3 giLighting(ivec3 cell, vec3 normal) {
    if (uGiFrame == 0u || dot(normal, normal) == 0.0) return vec3(0.0);
    int slot = giFind(giKey(cell, normal), true);
    if (slot < 0) return vec3(0.0); // pending/pressure fallback: emission only
#if GI_DIAGNOSTICS
    imageAtomicAdd(uGiQueue, 5, 1u);
#endif
    if (imageLoad(uGiState, slot*4+2).r != 3u) giEnqueue(slot);
    return imageLoad(uGiResult, slot).rgb;
}
#endif
