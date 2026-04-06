#version 420 core
#include "include/frag_traverse.glsl"

in vec2 uv;
out vec4 fragColor;

void main() {
    vec3 dir = getRay(gl_FragCoord.xy);
    fragColor = castTraceRay(uCamPos, dir);
}