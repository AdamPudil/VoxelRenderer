#version 460 core

#include "../include/frag_traverse.glsl"

out vec2 uv;
flat out ivec3 targetVoxel;
flat out int targetValid;

void main() {
    // Three fullscreen vertices share the same center-screen target.
    // This avoids tracing the selection ray again for every fragment.
    vec3 targetNormal;
    bool hit = false;
    targetVoxel = ivec3(0);
    if (!uIconMode) castTraceRay(uCamPos, getRay(uResolution * 0.5), targetVoxel, targetNormal, hit);
    targetValid = hit ? 1 : 0;

    vec2 pos = vec2(
        (gl_VertexID == 1) ? 3.0 : -1.0,
        (gl_VertexID == 2) ? 3.0 : -1.0
    );

    uv = pos * 0.5 + 0.5;
    gl_Position = vec4(pos, 0.0, 1.0);

}