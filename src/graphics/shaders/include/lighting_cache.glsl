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

uint faceHash(ivec4 key) {
    uvec4 k = uvec4(key);
    uint h = k.x * 0x8da6b343u ^ k.y * 0xd8163841u ^ k.z * 0xcb1ab31fu ^ k.w * 0x9e3779b9u;
    h ^= h >> 16u;
    h *= 0x7feb352du;
    return h ^ (h >> 15u);
}
vec3 cachedLighting(ivec3 cell, vec3 point, vec3 normal) {
    if (uLightingCacheFrame == 0u || dot(normal, normal) == 0.0)
        return evaluateLighting(point, normal);
    int axis = abs(normal.x) > 0.5 ? 0 : (abs(normal.y) > 0.5 ? 1 : 2);
    ivec4 key = ivec4(cell, axis * 2 + (normal[axis] > 0.0 ? 1 : 0));
    uint hash = faceHash(key);
    int owned = -1;
    for (uint probe = 0u; probe < 4u; ++probe) {
        int slot = int((hash + probe) & uint(LIGHTING_CACHE_SIZE - 1));
        uint stamp = imageLoad(uLightingCacheStamp, slot).r;
        if (stamp >= uLightingCacheValidFrom && stamp < uLightingCacheFrame) {
            if (all(equal(imageLoad(uLightingCacheKey, slot), key)))
                return imageLoad(uLightingCacheValue, slot).rgb;
        } else if (stamp < uLightingCacheValidFrom) {
            if (imageAtomicCompSwap(uLightingCacheStamp, slot, stamp, uLightingCacheFrame) == stamp) {
                owned = slot;
            }
            break; // a failed claim also uses the uncached fallback
        } else {
            // A writer is producing this entry in the same draw. Never spin,
            // read partially written payload, or fill extra slots with duplicates.
            break;
        }
    }
    // getShade supplies the same face center for every pixel and fallback.
    vec3 illumination = evaluateLighting(point, normal);
    if (owned >= 0) {
        imageStore(uLightingCacheKey, owned, key);
        imageStore(uLightingCacheValue, owned, vec4(illumination, 1.0));
    }
    // Published only to subsequent draws, after the CPU's image memory barrier.
    return illumination;
}
#endif
#endif
