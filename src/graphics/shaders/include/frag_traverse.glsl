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
    float diff = max(dot(normal, lightDir), 0.0);
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

bool isAir(VoxelData v) { return v.opacity == 0.0 && v.ior == 0.0; }
bool isGlass(VoxelData v) { return v.ior > 0.0 && v.opacity < 1.0; }

VoxelData sampleMaterial(ivec3 cell, out int regionSize) {
    bool valid;
    int slot;
    ChunkHeader ch = chunkHeaderAtWorld(cell, valid, slot);
    regionSize = CHUNK_VOXEL_SIZE;
    if (!valid || ch.state == uint(CHUNK_STATE_FREE)) return decodeVoxel(uvec2(0u));
    if (ch.state == uint(CHUNK_STATE_MONO)) return decodeVoxel(uvec2(ch.data0, ch.data1));
    BlockHeader bh = blockHeaderAtWorld(cell, ch);
    regionSize = BLOCK_SIZE;
    if (bh.state == uint(BLOCK_STATE_FREE)) return decodeVoxel(uvec2(0u));
    if (bh.state == uint(BLOCK_STATE_MONO)) return decodeVoxel(uvec2(bh.data0, bh.data1));
    regionSize = 1;
    return voxelPresentAtWorld(cell, bh) ? voxelAtWorld(cell, bh) : decodeVoxel(uvec2(0u));
}

bool sameMedium(VoxelData a, VoxelData b) {
    if (isAir(a) && isAir(b)) return true;
    return isGlass(a) && isGlass(b) && a.ior == b.ior && a.opacity == b.opacity &&
           all(equal(a.color, b.color)) && a.reflectiveness == b.reflectiveness &&
           a.metallic == b.metallic && a.luminescence == b.luminescence;
}

// Find a medium boundary, skipping internal faces of contiguous glass. Normals
// always face the incident ray, including glass-to-air exit boundaries.
bool traceBoundary(vec3 pos, vec3 dir, VoxelData medium, out ivec3 cell,
                   out vec3 normal, out vec3 point, out float distance,
                   out VoxelData material) {
    cell = ivec3(floor(pos));
    normal = vec3(0.0);
    point = pos;
    distance = 0.0;
    material = decodeVoxel(uvec2(0u));
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
    for (int i = 0; i < renderDistance; i++) {
        int regionSize;
        material = sampleMaterial(cell, regionSize);
        if (!sameMedium(material, medium)) {
            if (dot(normal, normal) > 0.0) {
                vec3 face = vec3(cell) + max(normal, vec3(0.0));
                distance = max(0.0, dot(face - pos, normal) / dot(dir, normal));
                point = pos + dir * distance;
            }
            return true;
        }
        if (regionSize > 1) {
            skipEmptyRegion(pos, dir, regionSize, cell, tMax, stepDir, normal);
        } else {
            int axis = tMax.x < tMax.y ? 0 : 1;
            if (tMax.z < tMax[axis]) axis = 2;
            cell[axis] += int(stepDir[axis]);
            tMax[axis] += tDelta[axis];
            normal = vec3(0.0);
            normal[axis] = -stepDir[axis];
        }
    }
    return false;
}

vec4 traceSurface(vec3 pos, vec3 dir, out ivec3 hitVoxel,
                  out vec3 hitNormal, out bool hit, out VoxelData material) {
    vec3 point;
    float distance;
    hit = traceBoundary(pos, dir, decodeVoxel(uvec2(0u)), hitVoxel, hitNormal, point, distance, material);
    return hit ? getShade(material, hitNormal) : (uIconMode ? vec4(0.0) : skyColor);
}

// Picking/selection vertex shaders need only the first hit, not reflection work.
vec4 castTraceRay(vec3 pos, vec3 dir, out ivec3 hitVoxel,
                  out vec3 hitNormal, out bool hit) {
    VoxelData material;
    return traceSurface(pos, dir, hitVoxel, hitNormal, hit, material);
}

// Environment used for reflected and transmitted rays that miss loaded geometry.
vec3 reflectionEnvironment(vec3 dir) {
    if (!uIconMode) return skyColor.rgb;
    // Isolated inventory previews have no surrounding scene. A neutral studio
    // environment makes metal colors readable without tinting them sky-red.
    float ambient = 0.2 + 0.45 * clamp(dir.y * 0.5 + 0.5, 0.0, 1.0);
    float softbox = pow(max(dot(dir, normalize(vec3(-0.6, 1.0, 0.8))), 0.0), 32.0);
    return vec3(ambient + 0.8 * softbox);
}

struct OpticalRay {
    vec3 pos;
    vec3 dir;
    vec3 weight;
    VoxelData medium;
    int reflections;
    int interfaces;
};

// Deterministic bounded ray tree: transmission and reflection both contribute.
// Color/opacity are specified per 16 voxels of travel, not per internal voxel face.
vec4 castReflectedRay(vec3 pos, vec3 dir, out ivec3 hitVoxel,
                     out vec3 hitNormal, out bool hit) {
    const int maxSegments = 32;
    const int maxReflections = 6;
    const int maxInterfaces = 12;
    OpticalRay pending[16];
    int count = 1;
    int region;
    VoxelData initial = sampleMaterial(ivec3(floor(pos)), region);
    VoxelData air = decodeVoxel(uvec2(0u));
    pending[0] = OpticalRay(pos, dir, vec3(1.0), isGlass(initial) ? initial : air, 0, 0);
    vec3 radiance = vec3(0.0);
    hit = isGlass(initial);
    hitVoxel = ivec3(floor(pos));
    hitNormal = vec3(0.0);

    for (int segment = 0; segment < maxSegments && count > 0; ++segment) {
        OpticalRay ray = pending[--count];
        ivec3 cell;
        vec3 normal, point;
        float distance;
        VoxelData material;
        bool found = traceBoundary(ray.pos, ray.dir, ray.medium, cell, normal, point, distance, material);
        if (segment == 0 && !hit) {
            hit = found;
            hitVoxel = cell;
            hitNormal = normal;
        }
        if (!found) {
            // A primary icon miss remains transparent; other misses show environment.
            if (segment != 0 || hit || !uIconMode) radiance += ray.weight * reflectionEnvironment(ray.dir);
            continue;
        }
        if (isGlass(ray.medium)) {
            float thickness = distance / float(BLOCK_SIZE);
            float transmission = pow(max(1.0 - ray.medium.opacity, 0.00001), thickness);
            vec3 filterColor = pow(max(ray.medium.color, vec3(0.00001)), vec3(thickness));
            // Simple haze approximation for sanded glass, not stochastic roughness.
            radiance += ray.weight * (1.0 - transmission) * ray.medium.color * 0.6;
            ray.weight *= transmission * filterColor;
        }
        if (max(ray.weight.r, max(ray.weight.g, ray.weight.b)) < 0.001) continue;
        float bias = max(0.001, max(abs(point.x), max(abs(point.y), abs(point.z))) * 2.4e-7);
        if (!isGlass(material) && !isAir(material)) {
            vec3 local = getShade(material, normal).rgb;
            if (material.reflectiveness <= 0.0 || dot(normal, normal) == 0.0 || ray.reflections >= maxReflections) {
                radiance += ray.weight * local;
                continue;
            }
            vec3 f0 = material.reflectiveness * mix(vec3(1.0), material.color, material.metallic);
            float cosine = clamp(dot(-ray.dir, normal), 0.0, 1.0);
            vec3 fresnel = f0 + (vec3(1.0) - f0) * pow(1.0 - cosine, 5.0);
            radiance += ray.weight * (vec3(1.0) - fresnel) * local;
            if (count < 16) pending[count++] = OpticalRay(point + normal * bias,
                normalize(reflect(ray.dir, normal)), ray.weight * fresnel, ray.medium, ray.reflections + 1, ray.interfaces);
            continue;
        }
        if (ray.interfaces >= maxInterfaces || dot(normal, normal) == 0.0) continue;
        float n1 = isGlass(ray.medium) ? ray.medium.ior : 1.0;
        float n2 = isGlass(material) ? material.ior : 1.0;
        vec3 transmitted = refract(ray.dir, normal, n1 / n2);
        bool totalInternalReflection = dot(transmitted, transmitted) < 1e-8;
        // Internal glass boundaries only change the transmission medium. Never
        // branch a reflected ray, even when tint, opacity or reflectivity differs.
        // Preserve refraction for differing IORs where possible; otherwise keep
        // travelling straight rather than internally reflecting between glasses.
        if (isGlass(ray.medium) && isGlass(material)) {
            if (count < 16) pending[count++] = OpticalRay(point - normal * bias,
                totalInternalReflection ? ray.dir : normalize(transmitted),
                ray.weight, material, ray.reflections, ray.interfaces + 1);
            continue;
        }
        float f0 = pow((n1 - n2) / (n1 + n2), 2.0);
        f0 = max(f0, max(material.reflectiveness, ray.medium.reflectiveness));
        float cosine = clamp(dot(-ray.dir, normal), 0.0, 1.0);
        float fresnel = totalInternalReflection ? 1.0 :
            (n1 == n2 && f0 == 0.0 ? 0.0 : f0 + (1.0 - f0) * pow(1.0 - cosine, 5.0));
        if (ray.reflections < maxReflections && fresnel > 0.001 && count < 15) {
            pending[count++] = OpticalRay(point + normal * bias, normalize(reflect(ray.dir, normal)),
                ray.weight * fresnel, ray.medium, ray.reflections + 1, ray.interfaces + 1);
        }
        // Push transmission last, so the principal view is processed first.
        if (!totalInternalReflection && fresnel < 1.0 && count < 16) {
            pending[count++] = OpticalRay(point - normal * bias, normalize(transmitted),
                ray.weight * (1.0 - fresnel), material, ray.reflections, ray.interfaces + 1);
        }
    }
    // Scene transmission is already composited here, not by OpenGL alpha blending.
    return vec4(radiance, uIconMode && !hit ? 0.0 : 1.0);
}

#endif
