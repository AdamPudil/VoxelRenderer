#ifndef LIGHTING_CACHE
#define LIGHTING_CACHE
#if USE_LIGHTING_CACHE
// GL 4.2 image buffers: no compute shaders or SSBOs required. Each entry is
// immutable within a geometry/light revision, and stores the full signed key.
layout(r32ui, binding = 0) coherent uniform uimageBuffer uLightingCacheStamp;
layout(rgba32i, binding = 1) uniform iimageBuffer uLightingCacheKey;
layout(rgba32f, binding = 2) uniform imageBuffer uLightingCacheValue;
uniform uint uLightingCacheFrame; // 0: uncached reference / isolated icon tools
uniform uint uLightingCacheValidFrom;
uniform uint uLightingCacheBudget; // maximum new entries per draw; zero is read-only

uint faceHash(ivec4 key) {
    uvec4 k = uvec4(key);
    uint h = k.x * 0x8da6b343u ^ k.y * 0xd8163841u ^ k.z * 0xcb1ab31fu ^ k.w * 0x9e3779b9u;
    h ^= h >> 16u;
    h *= 0x7feb352du;
    return h ^ (h >> 15u);
}
vec3 cachedLightingLevel(ivec3 cell, vec3 point, vec3 normal, int size) {
    if (uLightingCacheFrame == 0u || dot(normal, normal) == 0.0)
        return evaluateLighting(point, normal);
    int axis = abs(normal.x) > 0.5 ? 0 : (abs(normal.y) > 0.5 ? 1 : 2);
    int level = size == 256 ? 4 : (size == 64 ? 3 : (size == 16 ? 2 : (size == 4 ? 1 : 0)));
    ivec4 key = ivec4(cell, level * 6 + axis * 2 + (normal[axis] > 0.0 ? 1 : 0));
    DIAG_ADD(1);
    uint hash = faceHash(key);
    int owned = -1;
    for (uint probe = 0u; probe < 4u; ++probe) {
        int slot = int((hash + probe) & uint(LIGHTING_CACHE_SIZE - 1));
        uint stamp = imageLoad(uLightingCacheStamp, slot).r;
        if (stamp >= uLightingCacheValidFrom && stamp < uLightingCacheFrame) {
            if (all(equal(imageLoad(uLightingCacheKey, slot), key))) {
                DIAG_ADD(2);
                return imageLoad(uLightingCacheValue, slot).rgb;
            }
            DIAG_ADD(7);
            if (probe == 3u) { DIAG_ADD(8); }
        } else if (stamp < uLightingCacheValidFrom) {
            // Rotate a bounded ownership window through the table. A slot can
            // be claimed only once this draw, so writes cannot exceed budget.
            // Uncached evaluation remains exact even when population is paused.
            uint start = (uLightingCacheFrame * uLightingCacheBudget) & uint(LIGHTING_CACHE_SIZE - 1);
            if (((uint(slot) - start) & uint(LIGHTING_CACHE_SIZE - 1)) >= uLightingCacheBudget) { DIAG_ADD(9); break; }
            if (imageAtomicCompSwap(uLightingCacheStamp, slot, stamp, uLightingCacheFrame) == stamp) {
                owned = slot;
                DIAG_ADD(4);
            } else { DIAG_ADD(6); }
            break; // a failed claim also uses the uncached fallback
        } else {
            DIAG_ADD(5);
            // A writer is producing this entry in the same draw. Never spin,
            // read partially written payload, or fill extra slots with duplicates.
            break;
        }
    }
    DIAG_ADD(3);
    // getShade supplies the same face center for every pixel and fallback.
    vec3 illumination = evaluateLighting(point, normal);
    if (owned >= 0) {
        imageStore(uLightingCacheKey, owned, key);
        imageStore(uLightingCacheValue, owned, vec4(illumination, 1.0));
        // Explicitly finish the claimed entry. It remains unreadable this draw;
        // the CPU barrier publishes key, value and stamp together next frame.
        imageStore(uLightingCacheStamp, owned, uvec4(uLightingCacheFrame));
    }
    // Published only to subsequent draws, after the CPU's image memory barrier.
    return illumination;
}
#endif
#endif
