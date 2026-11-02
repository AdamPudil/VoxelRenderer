#ifndef GI_UPDATE
#define GI_UPDATE
uniform int uGiPass;
uniform int uGiJobs;
uniform uint uGiMaintenanceStart;

void giRay() { imageAtomicAdd(uGiQueue, 4, 1u); }
vec3 giFinite(vec3 value) {
    if (any(isnan(value)) || any(isinf(value))) return vec3(0.0);
    return clamp(value, vec3(0.0), vec3(GI_MAX_RADIANCE));
}

// First opaque hit, with the same hierarchy skip/boundary ownership as shadows.
// Glass is binary-transparent to diffuse probes, matching direct visibility.
// Escapes and capped paths return zero: broad sky is already stage 1, so it
// must not be added again by normal/hemisphere probes.
bool giIncoming(vec3 origin, vec3 dir, out vec3 incoming) {
    giRay(); incoming = vec3(0.0);
    ivec3 cell = ivec3(floor(origin));
    vec3 stepDir = sign(dir), normal = vec3(0.0);
    vec3 next = floor(origin) + max(stepDir, vec3(0.0));
    vec3 tMax = vec3(1e30), delta = vec3(1e30);
    for (int axis=0; axis<3; ++axis) if (dir[axis] != 0.0) {
        tMax[axis] = (next[axis]-origin[axis])/dir[axis];
        delta[axis] = abs(1.0/dir[axis]);
    }
    float distance = 0.0;
    for (int step=0; step<SHADOW_STEPS; ++step) {
        if (distance >= GI_MAX_DISTANCE || !chunkInRegion(worldToChunkCoord(cell))) return true;
        int size; VoxelData m = sampleMaterial(cell, size);
        if (shadowOpaque(m)) {
            incoming = m.color * m.luminescence * 0.75;
            if (dot(normal, normal) == 0.0) return true;
            int slot = giFind(giKey(cell, normal), false);
            if (slot < 0) return false;
            uint ready = imageLoad(uGiState, slot*4+1).r;
            if (ready < uGiValidFrom || ready >= uGiFrame) {
                giEnqueue(slot); return false;
            }
            // Direct-only reads from an earlier draw/frame: exactly one diffuse
            // bounce, no recursive dependency or indirect feedback cycles.
            incoming += clamp(m.color, vec3(0.0), vec3(0.95)) * imageLoad(uGiDirect, slot).rgb;
            incoming = giFinite(incoming);
            return true;
        }
        if (size > 1) {
            skipEmptyRegion(origin, dir, size, cell, tMax, stepDir, normal);
            vec3 face = vec3(cell) + max(normal, vec3(0.0));
            distance = max(0.0, dot(face-origin,normal)/dot(dir,normal));
        } else {
            int axis = tMax.x < tMax.y ? 0 : 1;
            if (tMax.z < tMax[axis]) axis=2;
            distance=tMax[axis]; cell[axis]+=int(stepDir[axis]); tMax[axis]+=delta[axis];
            normal=vec3(0.0); normal[axis]=-stepDir[axis];
        }
    }
    return true;
}
vec3 giHemisphere(uint index, vec3 n, out float weight) {
    uint k = bitfieldReverse(index) >> uint(32-GI_SAMPLE_BITS);
    float y = (float(k)+0.5)/float(GI_SAMPLES);
    float r = sqrt(max(0.0,1.0-y*y));
    float theta = float(k)*2.399963229728653;
    vec3 tangent = normalize(cross(abs(n.y)<0.5 ? vec3(0,1,0) : vec3(1,0,0), n));
    vec3 bitangent = cross(n,tangent);
    weight=2.0*y; // uniform hemisphere PDF 1/(2*pi), diffuse E/pi
    return tangent*(r*cos(theta)) + n*y + bitangent*(r*sin(theta));
}
void giUpdate(int job) {
    if (uGiPass == 3) {
        int slot = int((uGiMaintenanceStart + uint(job)) & uint(LIGHTING_CACHE_SIZE-1));
        uint last = imageLoad(uGiState, slot*4+3).r;
        if (imageLoad(uGiStamp,slot).r >= uGiValidFrom &&
            imageLoad(uGiState,slot*4).r == 0u && uGiFrame > last && uGiFrame-last > GI_RETENTION_FRAMES)
            imageStore(uGiStamp,slot,uvec4(0u));
        return;
    }
    if (uGiPass == 0) {
        if (job != 0) return;
        uint head=imageLoad(uGiQueue,0).r, tail=imageLoad(uGiQueue,1).r;
        imageStore(uGiQueue,2,uvec4(head));
        imageStore(uGiQueue,3,uvec4(min(tail-head,uint(uGiJobs))));
        return;
    }
    uint count=imageLoad(uGiQueue,3).r;
    if (uint(job)>=count) return;
    int jobsBase=8+GI_QUEUE_CAPACITY;
    if (uGiPass == 1) {
        uint ticket=imageLoad(uGiQueue,2).r+uint(job);
        imageStore(uGiQueue,jobsBase+job,imageLoad(uGiQueue,8+int(ticket & uint(GI_QUEUE_CAPACITY-1))));
        return;
    }
    // The previous draw copied ALL jobs before any producer can reuse ring slots.
    if (job == 0) imageAtomicAdd(uGiQueue,0,count);
    int slot=int(imageLoad(uGiQueue,jobsBase+job).r);
    uint generation=imageLoad(uGiStamp,slot).r;
    if (generation < uGiValidFrom || generation > uGiFrame) return;
    ivec4 key=imageLoad(uGiKey,slot);
    vec3 normal=giNormal(key), point=vec3(key.xyz)+vec3(0.5)+normal*0.5;
    vec3 origin=point+normal*surfaceEpsilon(point);
    uint ready=imageLoad(uGiState,slot*4+1).r;
    if (ready < uGiValidFrom) {
        vec3 direct=giFinite(evaluateLighting(point,normal));
        // Count conservative direct rays; point lights rejected before tracing
        // may make the actual number smaller, never larger.
        uint rays=0u;
#if USE_SKY_LIGHTING
        rays+=uint(1+SKY_EXTRA_RAYS);
#endif
#if USE_POINT_LIGHTS
        rays+=uint(uLightCount);
#endif
        imageAtomicAdd(uGiQueue,4,rays);
        if (generation != imageLoad(uGiStamp,slot).r) return;
        imageStore(uGiDirect,slot,vec4(direct,1.0));
        imageStore(uGiResult,slot,vec4(direct,0.0));
        imageStore(uGiState,slot*4+1,uvec4(uGiFrame));
        imageStore(uGiState,slot*4+2,uvec4(1u)); // direct-ready
    } else if (imageLoad(uGiDependency,slot).r == 0u) {
        vec3 direct=imageLoad(uGiDirect,slot).rgb;
        vec4 result=imageLoad(uGiResult,slot);
#if GI_NORMAL_PROBES
        if (result.a == 0.0) {
            vec3 incoming;
            if (giIncoming(origin,normal,incoming)) {
                // Normal probe is a temporary pilot, REPLACED by hemisphere
                // integration, not added a second time to the final estimator.
                imageStore(uGiResult,slot,vec4(giFinite(direct+incoming),1.0));
#if !GI_INDIRECT
                imageStore(uGiState,slot*4+2,uvec4(3u));
#endif
            }
        } else
#endif
        {
#if GI_INDIRECT
            vec4 sum=imageLoad(uGiSum,slot);
            uint samples=uint(sum.a);
            uint batch=min(uint(GI_MAX_BATCH),samples+1u); // 1,2,4,8,...
            for (uint i=0u; i<batch && samples<uint(GI_SAMPLES); ++i) {
                float weight; vec3 dir=giHemisphere(samples,normal,weight), incoming;
                if (!giIncoming(origin,dir,incoming)) break; // retry missing dependency, preserve all previous work
                sum.rgb+=incoming*weight; ++samples;
            }
            sum.a=float(samples);
            if (generation != imageLoad(uGiStamp,slot).r) return;
            imageStore(uGiSum,slot,sum);
            if (samples>0u) imageStore(uGiResult,slot,vec4(giFinite(direct+sum.rgb/float(samples)),1.0));
            imageStore(uGiState,slot*4+2,uvec4(samples==uint(GI_SAMPLES) ? 3u : 2u));
#else
            imageStore(uGiState,slot*4+2,uvec4(3u));
#endif
        }
    }
    imageAtomicExchange(uGiState,slot*4,0u);
    if (imageLoad(uGiDependency,slot).r == 0u && imageLoad(uGiState,slot*4+2).r != 3u) giEnqueue(slot);
}
#endif
