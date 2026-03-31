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

vec4 getShade(uint id, vec3 normal) {
    vec3 baseColor = voxelColor(id);

    vec3 lightDir = normalize(vec3(1.0, 1.0, 0.8));
    float diff = max(dot(normalize(normal), lightDir), 0.0);
    float light = 0.3 + diff * 0.7;

    float dirTint = 1.0;
    if (abs(normal.x) > 0.5) dirTint = 0.8;
    if (abs(normal.z) > 0.5) dirTint = 1.0;
    if (abs(normal.y) > 0.5) dirTint = 1.2;

    return vec4(baseColor * light * dirTint, 1.0);
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
        uint id = voxelAtWorld(v);
        if (id != 0u) {
            return getShade(id, normal);
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