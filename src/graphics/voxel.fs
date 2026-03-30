#version 420 core

in vec2 uv;
out vec4 fragColor;

uniform vec2 uResolution;
uniform vec3 uCamPos;
uniform vec3 uCamDir;

// region origin in chunk coordinates, not voxel coordinates
uniform ivec3 uRegionOriginChunk;
uniform ivec3 uRegionSizeChunks;

// one uint per slot: 0 = inactive, nonzero = active
uniform usamplerBuffer uChunkActiveTex;

// packed bitmap data for all slots
uniform usamplerBuffer uBitmapTex;

// voxel ids for all slots
uniform usamplerBuffer uVoxelTex;

const int CHUNK_SIZE = 16;
const int CHUNK_VOXELS = CHUNK_SIZE * CHUNK_SIZE * CHUNK_SIZE;   // 4096
const int BITMAP_WORDS = CHUNK_VOXELS / 32;                      // 128

const int renderDistance = 1024;
const vec4 skyColor = vec4(0.4, 0.1, 0.1, 1.0);

int floorDiv(int a, int b) {
    int q = a / b;
    int r = a % b;
    if (r != 0 && ((r < 0) != (b < 0))) q -= 1;
    return q;
}

int positiveMod(int a, int b) {
    int m = a % b;
    return (m < 0) ? (m + b) : m;
}

ivec3 worldToChunkCoord(ivec3 wp) {
    return ivec3(
        floorDiv(wp.x, CHUNK_SIZE),
        floorDiv(wp.y, CHUNK_SIZE),
        floorDiv(wp.z, CHUNK_SIZE)
    );
}

ivec3 worldToLocalVoxel(ivec3 wp) {
    return ivec3(
        positiveMod(wp.x, CHUNK_SIZE),
        positiveMod(wp.y, CHUNK_SIZE),
        positiveMod(wp.z, CHUNK_SIZE)
    );
}

int localVoxelIndex(ivec3 lp) {
    return lp.x + lp.y * CHUNK_SIZE + lp.z * CHUNK_SIZE * CHUNK_SIZE;
}

bool chunkInRegion(ivec3 cc) {
    ivec3 r = cc - uRegionOriginChunk;
    return r.x >= 0 && r.y >= 0 && r.z >= 0 &&
           r.x < uRegionSizeChunks.x &&
           r.y < uRegionSizeChunks.y &&
           r.z < uRegionSizeChunks.z;
}

int chunkSlot(ivec3 cc) {
    ivec3 r = cc - uRegionOriginChunk;
    return r.x
         + r.y * uRegionSizeChunks.x
         + r.z * uRegionSizeChunks.x * uRegionSizeChunks.y;
}

bool slotActive(int slot) {
    return texelFetch(uChunkActiveTex, slot).r != 0u;
}

bool voxelOccupiedInSlot(int slot, ivec3 localPos) {
    int local = localVoxelIndex(localPos);
    int word = local >> 5;
    int bit = local & 31;

    int bitmapIndex = slot * BITMAP_WORDS + word;
    uint bitsWord = texelFetch(uBitmapTex, bitmapIndex).r;

    return ((bitsWord >> bit) & 1u) != 0u;
}

uint voxelIdInSlot(int slot, ivec3 localPos) {
    int local = localVoxelIndex(localPos);
    int voxelIndex = slot * CHUNK_VOXELS + local;
    return texelFetch(uVoxelTex, voxelIndex).r;
}

uint voxelAtWorld(ivec3 wp) {
    ivec3 cc = worldToChunkCoord(wp);

    if (!chunkInRegion(cc)) return 0u;

    int slot = chunkSlot(cc);
    if (!slotActive(slot)) return 0u;

    ivec3 lp = worldToLocalVoxel(wp);

    if (!voxelOccupiedInSlot(slot, lp)) return 0u;

    return voxelIdInSlot(slot, lp);
}

vec3 voxelColor(uint id) {
    if (id == 1u) return vec3(0.376, 0.239, 0.114);
    if (id == 2u) return vec3(0.35, 0.8, 0.35);
    if (id == 3u) return vec3(0.5, 0.5, 0.5);
    return vec3(1.0, 0.0, 1.0);
}

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

void main() {
    vec3 dir = getRay(gl_FragCoord.xy);
    vec3 pos = uCamPos;

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
            vec3 baseColor = voxelColor(id);

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
    }

    fragColor = skyColor;
}