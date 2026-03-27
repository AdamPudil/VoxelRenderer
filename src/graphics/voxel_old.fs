#version 340

in vec2 uv;
out vec4 fragColor;

//uniform usampler3D voxels;
uniform vec3 camPos;
uniform vec3 camDir;
uniform vec2 res;
uniform ivec3 worldOrigin;
//uniform ivec3 streamedSize;

const int renderDistance = 256;
const vec4 skyColor = vec4(0.4, 0.1, 0.1, 1.0);
const vec3 baseColor = vec3(0.376, 0.239, 0.114);

layout(std430, binding = 0) readonly buffer VoxelBitmap {
    uint bitmap[];
};

layout(std430, binding = 1) readonly buffer Voxels {
    uint voxels[];
};

vec3 getRay(vec2 uv) {
    float aspect = res.x / res.y;
    vec2 p = uv * 2.0 - 1.0;
    p.x *= aspect;

    vec3 right = normalize(cross(camDir, vec3(0.0, 1.0, 0.0)));
    vec3 up = normalize(cross(right, camDir));

    return normalize(camDir + p.x * right + p.y * up);
}

bool voxelAt(ivec3 p) {
    if (p.x < 0 || p.y < 0 || p.z < 0 ||
        p.x >= streamedSize.x ||
        p.y >= streamedSize.y ||
        p.z >= streamedSize.z) return false;

    return texelFetch(voxels, p, 0).r > 0u;
}

void main() {
    vec3 dir = getRay(uv);
    vec3 pos = camPos - vec3(worldOrigin);

    ivec3 v = ivec3(floor(pos));

    vec3 stepDir = sign(dir);
    vec3 tDelta = abs(1.0 / dir);

    vec3 next = floor(pos) + stepDir * 0.5 + 0.5;
    vec3 tMax = (next - pos) / dir;

    vec3 normal = vec3(0.0);

    for (int i = 0; i < renderDistance; i++) {
        if (voxelAt(v)) {
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
        if(!inBounds(v)) break;
    }

    fragColor = skyColor;
}