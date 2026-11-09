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

#if !USE_GI && (USE_FACE_SHADING || DIRECT_GEOMETRY_RING_COUNT > 0)
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
    ivec3 cell = rayOwnedCell(pos, dir);
    vec3 stepDir = sign(dir);
    vec3 tDelta = vec3(1e30), tMax = vec3(1e30);
    vec3 next = vec3(cell) + max(stepDir, vec3(0.0));
    for (int axis = 0; axis < 3; ++axis) {
        if (dir[axis] != 0.0) {
            tDelta[axis] = abs(1.0 / dir[axis]);
            tMax[axis] = (next[axis] - pos[axis]) / dir[axis];
        }
    }
    float distance = 0.0;
    vec3 normal = vec3(0.0);
    ivec3 previousChunk = ivec3(0);
    ChunkHeader header = ChunkHeader(0u, 0u, 0u, 0u);
    // Only emitter hits need the source material. Reuse it along a thick lamp.
    bool sourceLoaded = false;
    uvec2 source = uvec2(0u);
    ivec3 endpoint = ivec3(floor(pos + dir * maxDistance));
    ivec3 endpointBlock = worldToBlockLower(endpoint);
    for (int i = 0; i < SHADOW_STEPS; ++i) {
        DIAG_STEPS();
        if (distance >= maxDistance) return true; // endpoint is not an occluder
        ivec3 chunk = worldToChunkCoord(cell);
        if (!chunkInRegion(chunk)) return true;
        if (i == 0 || any(notEqual(chunk, previousChunk))) {
            header = fetchChunkHeader(chunkSlot(chunk));
            previousChunk = chunk;
        }
        int regionSize;
        uvec2 material = sampleMaterialPacked(cell, header, regionSize);
        if ((material.y & 255u) == 255u) {
            // A multi-voxel emitter (e.g. a glowing LED shaft) must not cast a
            // broad shadow from its own point light. Exempt only matching
            // emissive material in the endpoint's storage block. Keep walking:
            // opaque casing between this sample and the source still occludes.
            if (!emissiveEndpoint || (material.y & 0x00ff0000u) == 0u ||
                any(notEqual(worldToBlockLower(cell), endpointBlock))) return false;
            if (!sourceLoaded) {
                bool valid; int slot, endpointSize;
                ChunkHeader endpointHeader = chunkHeaderAtWorld(endpoint, valid, slot);
                source = sampleMaterialPacked(endpoint, endpointHeader, endpointSize);
                sourceLoaded = true;
            }
            if ((source.y & 0x00ff0000u) == 0u ||
                (source.x & 0x00ffffffu) != (material.x & 0x00ffffffu)) return false;
        }
        if (regionSize > 1) {
            skipEmptyRegion(pos, dir, regionSize, cell, tMax, stepDir, normal);
            vec3 face = vec3(cell) + max(normal, vec3(0.0));
            distance = max(0.0, dot(face - pos, normal) / dot(dir, normal));
        } else {
            int axis = tMax.x < tMax.y ? 0 : 1;
            if (tMax.z < tMax[axis]) axis = 2;
            distance = tMax[axis];
            float crossing = tMax[axis];
            // Half-open voxel ownership: edge/corner ties cross every tied axis.
            for (int j = 0; j < 3; ++j) {
                if (tMax[j] == crossing) {
                    cell[j] += int(stepDir[j]);
                    tMax[j] += tDelta[j];
                }
            }
        }
    }
    DIAG_EXHAUSTED();
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
        // Reject back-facing lights before normalization or any visibility work.
        if (dot(normal, delta) <= 0.0) continue;
        float radius = uLightPositionRadius[i].w;
        float distance2 = dot(delta, delta);
        if (distance2 >= radius * radius || distance2 <= 1e-10) continue;
        float distance = sqrt(distance2);
        vec3 direction = delta / distance;
        float exposure = max(dot(normal, direction), 0.0);
        if (exposure <= 0.0) continue;
        DIAG_CONTEXT(2);
        DIAG_ADD(13);
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
// The mandatory zenith sample never changes X/Z. March its Y intervals directly
// without rebuilding a three-axis DDA at every empty-region boundary. The same
// packed sampler preserves authored roofs, glass, terrain and edited overlays.
bool skyVisibleUp(vec3 origin) {
    ivec3 cell = ivec3(floor(origin));
    ivec3 previousChunk = ivec3(0);
    ChunkHeader header = ChunkHeader(0u, 0u, 0u, 0u);
    float distance = 0.0;
    for (int i = 0; i < SHADOW_STEPS; ++i) {
        DIAG_STEPS();
        if (distance >= SKY_MAX_DISTANCE) return true;
        ivec3 chunk = worldToChunkCoord(cell);
        if (!chunkInRegion(chunk)) return true;
        if (i == 0 || any(notEqual(chunk, previousChunk))) {
            header = fetchChunkHeader(chunkSlot(chunk));
            previousChunk = chunk;
        }
        int size;
        uvec2 material = sampleMaterialPacked(cell, header, size);
        if ((material.y & 255u) == 255u) return false;
        cell.y = floorDiv(cell.y, size) * size + size;
        distance = float(cell.y) - origin.y;
    }
    DIAG_EXHAUSTED();
    return false;
}
vec3 skyLighting(vec3 point, vec3 normal) {
    float exposure = clamp(0.5 + 0.5 * normal.y, 0.0, 1.0);
    if (exposure == 0.0) return vec3(0.0); // undersides/ceilings
    vec3 origin = point + normal * surfaceEpsilon(point);
    DIAG_CONTEXT(3);
    DIAG_ADD(14);
    float visible = skyVisibleUp(origin) ? 1.0 : 0.0;
    float totalWeight = 1.0; // straight up has full weight
#if SKY_EXTRA_RAYS > 0
    // Ordered rings precomputed in Zig: four cardinals, four diagonals, then
    // wider interleaved rings. Directions do not depend on pixel/frame/count.
    for (int i = 0; i < SKY_EXTRA_RAYS; ++i) {
        vec4 skySample = SKY_SAMPLES[i];
        totalWeight += skySample.w;
        DIAG_ADD(14);
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
    DIAG_ADD(10);
#if DIRECT_DIAGNOSTICS_ENABLED && !USE_GI
    int previousDiagnosticContext = diagnosticContext;
#endif
    vec3 illumination = vec3(0.0);
#if USE_POINT_LIGHTS
    illumination += pointLighting(point, normal);
#endif
#if USE_SKY_LIGHTING
    illumination += skyLighting(point, normal);
#endif
#if DIRECT_DIAGNOSTICS_ENABLED && !USE_GI
    diagnosticContext = previousDiagnosticContext;
#endif
    return illumination;
}
#if USE_GI
#include "gi_cache.glsl"
#else
#include "lighting_cache.glsl"
#endif
#endif

#if (USE_POINT_LIGHTS || USE_SKY_LIGHTING) && !USE_GI
bool directLightingInRange(ivec3 cell) {
#if DIRECT_GEOMETRY_RING_COUNT > 0
    // Use distance, not the sampled cell size: thin/edited distant geometry
    // can remain finest. A zero-ring policy is an isolated/reference draw.
    if (uGeometryRingCount > DIRECT_GEOMETRY_RING_COUNT) {
        float radius = uGeometryRings[DIRECT_GEOMETRY_RING_COUNT - 1].x;
        return hierarchyDistance(cell, 1) - uLodGuard <= radius;
    }
#endif
    return true;
}
vec3 directAtLevel(ivec3 cell, vec3 normal, vec3 point, int size) {
#if USE_LIGHTING_CACHE
    return cachedLightingLevel(cell, point, normal, size);
#else
    return evaluateLighting(point, normal);
#endif
}
vec3 ringLighting(ivec3 cell, vec3 normal, vec3 point) {
    int size = hierarchyLightingSize(cell, normal);
    vec3 illumination = vec3(0.0);
    float remaining = 1.0;
    for (int level = 0; level < 5; ++level) {
        ivec3 lower = hierarchyLower(cell, size);
        vec3 center = size == 1 ? point :
            vec3(lower) + vec3(float(size) * 0.5) + normal * (float(size) * 0.5);
        float weight = size == 1 ? 1.0 : hierarchyWeight(cell, size, true);
        illumination += remaining * weight * directAtLevel(lower, normal, center, size);
        remaining *= 1.0 - weight;
        if (remaining <= 0.0) break;
        size = hierarchyLightingSizeBelow(cell, normal, size / HIERARCHY_FACTOR);
    }
    return illumination;
}
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
        // The finest face is the fallback for ambiguous patches. Ring sampling
        // chooses the same occupied surface with caching enabled or disabled.
        vec3 samplePoint = dot(normal, normal) > 0.0 ?
            vec3(cell) + vec3(0.5) + normal * 0.5 : point;
#if USE_GI
        illumination = giLighting(cell, normal);
#else
#if DIRECT_GEOMETRY_RING_COUNT > 0
        if (!directLightingInRange(cell)) {
            // Match legacy face brightness after the final display encoding.
            // Bypass both cache lookup/population and all direct visibility rays.
            face = 1.0;
            illumination = vec3(pow(faceFactor(normal), 2.2));
        } else
#endif
        illumination = ringLighting(cell, normal, samplePoint);
#endif
    }
#endif
    vec3 emission = material.color * material.luminescence * 0.75;
    return vec4(material.color * face * illumination + emission, material.opacity);
}
#endif
