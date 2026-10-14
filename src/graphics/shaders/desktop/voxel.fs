#version 460 core
// Desktop entry point; keep the world format shared with the ThinkPad shader.
#include "../include/frag_traverse.glsl"

#include "../include/selection_outline.glsl"

in vec2 uv;
flat in ivec3 targetVoxel;
flat in int targetValid;
out vec4 fragColor;

void main() {
    vec3 dir = getRay(gl_FragCoord.xy);
    fragColor = shadeSelectionOutline(dir, targetVoxel, targetValid);
}
