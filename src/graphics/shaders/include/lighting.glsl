#ifndef LIGHTING
#define LIGHTING

vec3 displayColor(vec3 rgb) {
#if USE_POINT_LIGHTS || USE_SKY_LIGHTING || USE_GI
    // Match the existing non-sRGB framebuffer: encode once after compositing.
    return pow(clamp(rgb, 0.0, 1.0), vec3(1.0 / 2.2));
#else
    return rgb; // exact legacy face-only/unlit color path
#endif
}
vec3 environmentColor() {
#if USE_POINT_LIGHTS || USE_SKY_LIGHTING || USE_GI
    return pow(skyColor.rgb, vec3(2.2));
#else
    return skyColor.rgb;
#endif
}

#if USE_FACE_SHADING && !USE_GI
float faceFactor(vec3 normal) {
    float diff = max(dot(normal, normalize(vec3(1.0, 1.0, 0.8))), 0.0);
    float tint = abs(normal.x) > 0.5 ? 0.8 : (abs(normal.y) > 0.5 ? 1.2 : 1.0);
    return (0.25 + diff * 0.75) * tint;
}
#endif

#if USE_POINT_LIGHTS || USE_SKY_LIGHTING || USE_GI
float surfaceEpsilon(vec3 point) {
    return max(SHADOW_EPSILON, max(abs(point.x), max(abs(point.y), abs(point.z))) * 2.4e-7);
}
// Binary policy shared across all geometry levels. Glass is currently transparent
// to visibility rays; a future transmittance integrator can replace this predicate.
bool shadowOpaque(VoxelData material) { return material.opacity >= 1.0; }

bool lightVisible(vec3 pos, vec3 dir, float maxDistance, bool emissiveEndpoint) {
    ivec3 cell = ivec3(floor(pos));
    vec3 stepDir = sign(dir);
    vec3 tDelta = vec3(1e30), tMax = vec3(1e30);
    vec3 next = floor(pos) + max(stepDir, vec3(0.0));
    for (int axis = 0; axis < 3; ++axis) {
        if (dir[axis] != 0.0) {
            tDelta[axis] = abs(1.0 / dir[axis]);
            tMax[axis] = (next[axis] - pos[axis]) / dir[axis];
        }
    }
    float distance = 0.0;
    vec3 normal = vec3(0.0);
    for (int i = 0; i < SHADOW_STEPS; ++i) {
        if (distance >= maxDistance) return true; // endpoint is not an occluder
        if (!chunkInRegion(worldToChunkCoord(cell))) return true;
        int regionSize;
        VoxelData material = sampleMaterial(cell, regionSize);
        if (shadowOpaque(material)) {
            // A multi-voxel emitter (e.g. a glowing LED shaft) must not cast a
            // broad shadow from its own point light. Exempt only matching
            // emissive material in the endpoint's storage block. Keep walking:
            // opaque casing between this sample and the source still occludes.
            ivec3 endpoint = ivec3(floor(pos + dir * maxDistance));
            if (!emissiveEndpoint || material.luminescence <= 0.0 ||
                any(notEqual(worldToBlockLower(cell), worldToBlockLower(endpoint)))) return false;
            int endpointSize;
            VoxelData source = sampleMaterial(endpoint, endpointSize);
            if (source.luminescence <= 0.0 || any(notEqual(source.color, material.color))) return false;
        }
        if (regionSize > 1) {
            skipEmptyRegion(pos, dir, regionSize, cell, tMax, stepDir, normal);
            vec3 face = vec3(cell) + max(normal, vec3(0.0));
            distance = max(0.0, dot(face - pos, normal) / dot(dir, normal));
        } else {
            int axis = tMax.x < tMax.y ? 0 : 1;
            if (tMax.z < tMax[axis]) axis = 2;
            distance = tMax[axis];
            cell[axis] += int(stepDir[axis]);
            tMax[axis] += tDelta[axis];
        }
    }
    return false; // bounded work; never leak light through unvisited geometry
}
#endif

#if USE_POINT_LIGHTS
uniform int uLightCount;
uniform vec4 uLightPositionRadius[MAX_POINT_LIGHTS];
uniform vec4 uLightColorIntensity[MAX_POINT_LIGHTS];
vec3 pointLighting(vec3 point, vec3 normal) {
    vec3 sum = vec3(0.0);
    vec3 origin = point + normal * surfaceEpsilon(point);
    for (int i = 0; i < MAX_POINT_LIGHTS; ++i) {
        if (i >= uLightCount) break;
        vec3 delta = uLightPositionRadius[i].xyz - origin;
        float distance = length(delta);
        float radius = uLightPositionRadius[i].w;
        if (distance >= radius || distance <= 0.00001) continue;
        vec3 direction = delta / distance;
        float exposure = max(dot(normal, direction), 0.0);
        if (exposure <= 0.0) continue;
        if (!lightVisible(origin, direction, distance, true)) continue;
        float r = distance / radius;
        float cutoff = max(1.0 - r * r, 0.0);
        // Softened inverse square scaled to radius; intensity remains intuitive.
        float attenuation = cutoff * cutoff / (1.0 + POINT_ATTENUATION * r * r);
        sum += uLightColorIntensity[i].rgb * uLightColorIntensity[i].w * attenuation * exposure;
    }
    return sum;
}
#endif

#if USE_SKY_LIGHTING
vec3 skyLighting(vec3 point, vec3 normal) {
    float exposure = clamp(0.5 + 0.5 * normal.y, 0.0, 1.0);
    if (exposure == 0.0) return vec3(0.0); // undersides/ceilings
    vec3 origin = point + normal * surfaceEpsilon(point);
    float visible = lightVisible(origin, vec3(0.0, 1.0, 0.0), SKY_MAX_DISTANCE, false) ? 1.0 : 0.0;
    float totalWeight = 1.0; // straight up has full weight
#if SKY_EXTRA_RAYS > 0
    // Ordered rings precomputed in Zig: four cardinals, four diagonals, then
    // wider interleaved rings. Directions do not depend on pixel/frame/count.
    for (int i = 0; i < SKY_EXTRA_RAYS; ++i) {
        vec4 skySample = SKY_SAMPLES[i];
        totalWeight += skySample.w;
        if (lightVisible(origin, skySample.xyz, SKY_MAX_DISTANCE, false)) visible += skySample.w;
    }
#endif
    // cos(tilt) reduces the influence of wider rays. Normalize by every ray's
    // weight, including occluded rays, so adding rays never brightens open sky.
    return SKY_RGB * SKY_INTENSITY * exposure * visible / totalWeight;
}
#endif

#if USE_POINT_LIGHTS || USE_SKY_LIGHTING || USE_GI
vec3 evaluateLighting(vec3 point, vec3 normal) {
    vec3 illumination = vec3(0.0);
#if USE_POINT_LIGHTS
    illumination += pointLighting(point, normal);
#endif
#if USE_SKY_LIGHTING
    illumination += skyLighting(point, normal);
#endif
    return illumination;
}
#if USE_GI
#include "gi_cache.glsl"
#else
#include "lighting_cache.glsl"
#endif
#endif

vec4 getShade(VoxelData material, vec3 normal, vec3 point, ivec3 cell) {
    float face = 1.0;
#if USE_FACE_SHADING && !USE_GI
    face = faceFactor(normal);
#endif
    vec3 illumination = vec3(1.0);
#if USE_POINT_LIGHTS || USE_SKY_LIGHTING || USE_GI
    // Inventory previews use a studio baseline and do not trace world lighting.
    if (!uIconMode) {
        // Per-voxel-face illumination is a shading rule, not a cache side effect.
        // Point-light attenuation, exposure and all visibility rays use this
        // same origin with caching enabled, disabled, cold, or full.
        vec3 samplePoint = dot(normal, normal) > 0.0 ?
            vec3(cell) + vec3(0.5) + normal * 0.5 : point;
#if USE_GI
        illumination = giLighting(cell, normal);
#elif USE_LIGHTING_CACHE
        illumination = cachedLighting(cell, samplePoint, normal);
#else
        illumination = evaluateLighting(samplePoint, normal);
#endif
    }
#endif
    vec3 emission = material.color * material.luminescence * 0.75;
    return vec4(material.color * face * illumination + emission, material.opacity);
}
#endif
