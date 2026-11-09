#version 420 core
#include "../include/frag_traverse.glsl"
uniform ivec3 uQuery;
uniform vec3 uNormal;
uniform int uProbeMode;
out vec4 fragColor;
void main() {
    if (uProbeMode == 14 || uProbeMode == 15) {
        // Orthographic rays through an edited block, including misses between
        // sparse voxels. Pixel centers cover its full 16x16 cross section.
        vec3 origin = uCamPos + vec3(0.0, gl_FragCoord.xy / 6.0);
        if (uProbeMode == 15) {
            fragColor = vec4(lightVisible(origin, uNormal, 12.0, false) ? 1.0 : 0.0, 0.0, 0.0, 1.0);
            return;
        }
        ivec3 cell; vec3 normal, point; float distance; VoxelData material;
        bool hit = traceBoundary(origin, uNormal, decodeVoxel(uvec2(0u)), cell, normal, point, distance, material, false);
        fragColor = hit && distance < 32.0 ? vec4(mod(vec3(cell), 251.0) / 255.0, 1.0) : vec4(0.0);
        return;
    }
    if (uProbeMode == 12 || uProbeMode == 13) {
        VoxelData material = decodeVoxel(uvec2(0x00808080u, uProbeMode == 13 ? 0x00ff00ffu : 255u));
        vec4 shaded = getShade(material, uNormal, vec3(uQuery) + vec3(0.5) + uNormal * 0.5, uQuery);
        fragColor = vec4(displayColor(shaded.rgb), shaded.a);
        return;
    }
    if (uProbeMode == 11) {
        vec3 origin = vec3(uQuery) + uNormal;
        fragColor = vec4(skyVisibleUp(origin) ? 1.0 : 0.0,
            lightVisible(origin, vec3(0.0, 1.0, 0.0), SKY_MAX_DISTANCE, false) ? 1.0 : 0.0, 0.0, 1.0);
        return;
    }
    if (uProbeMode == 9) { fragColor = vec4(hierarchyWeight(uQuery, int(uNormal.x), false), 0.0, 0.0, 1.0); return; }
    if (uProbeMode == 7 || uProbeMode == 8 || uProbeMode == 10) {
        vec3 direction = normalize(uNormal);
        if (uProbeMode == 8) { fragColor = vec4(lightVisible(uCamPos, direction, 512.0, false) ? 1.0 : 0.0, 0.0, 0.0, 1.0); return; }
        ivec3 cell; vec3 normal, point; float distance; VoxelData material;
        bool hit = traceBoundary(uCamPos, direction, decodeVoxel(uvec2(0u)), cell, normal, point, distance, material, false);
        float reach = uProbeMode == 10 ? 8192.0 : 512.0;
        fragColor = hit && distance < reach ? vec4(mod(vec3(cell), 251.0) / 255.0, 1.0) : vec4(0.0);
        return;
    }
    if (uProbeMode == 6) {
        ivec3 cell = uQuery + ivec3(int(gl_FragCoord.x), 0, int(gl_FragCoord.y));
        vec3 normal = vec3(0.0, 1.0, 0.0);
        fragColor = vec4(ringLighting(cell, normal, vec3(cell) + vec3(0.5, 1.0, 0.5)), 1.0);
        return;
    }
    if (uProbeMode == 5) {
        ivec3 cell; vec3 normal, point; float distance; VoxelData material;
        bool hit = traceBoundary(uCamPos, getRay(gl_FragCoord.xy), decodeVoxel(uvec2(0u)), cell, normal, point, distance, material, false);
        fragColor = hit ? vec4(mod(vec3(cell), 251.0) / 255.0, 1.0) : vec4(0.0);
        return;
    }
    int size;
    VoxelData m = uProbeMode == 1 ? sampleRenderMaterial(uQuery, size) : sampleMaterial(uQuery, size);
    if (uProbeMode == 2) size = hierarchyLightingSize(uQuery, uNormal);
    if (uProbeMode == 3) {
        bool visible = lightVisible(vec3(uQuery) + vec3(0.5), uNormal, 512.0, false);
        fragColor = vec4(visible ? 1.0 : 0.0, 0.0, 0.0, 1.0);
    } else if (uProbeMode == 4) {
        vec3 point = vec3(uQuery) + vec3(0.5) + uNormal * 0.5;
        fragColor = vec4(ringLighting(uQuery, uNormal, point), 1.0);
    } else {
        fragColor = vec4(float(size) / 256.0, isAir(m) ? 0.0 : 1.0, m.color.r, 1.0);
    }
}
