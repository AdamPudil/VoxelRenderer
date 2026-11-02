#version 420 core
#include "../include/frag_traverse.glsl"
uniform ivec3 uProbeOrigin;
uniform bool uProbeTrace;
uniform vec2 uProbeSubface;
out vec4 fragColor;
void main() {
    if (uProbeTrace) {
        ivec3 cell;
        vec3 normal;
        bool hit;
        fragColor = castReflectedRay(uCamPos, getRay(gl_FragCoord.xy), cell, normal, hit);
        return;
    }
    ivec3 cell = uProbeOrigin + ivec3(ivec2(gl_FragCoord.xy).x, -1, ivec2(gl_FragCoord.xy).y);
    vec3 normal = vec3(0.0, 1.0, 0.0);
    vec3 point = vec3(cell) + vec3(0.5, 1.0, 0.5);
    point.xz += uProbeSubface; // move the pixel within the same voxel face
    VoxelData material = decodeVoxel(uvec2(0u));
    material.color = vec3(1.0);
    material.opacity = 1.0;
    fragColor = getShade(material, normal, point, cell);
}
