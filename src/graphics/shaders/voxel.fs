#version 420 core
#include "include/constants.glsl"
#include "include/frag_math.glsl"
#include "include/frag_traverse.glsl"
#include "include/world_functions.glsl"
#include "include/uniforms.glsl"

in vec2 uv;
out vec4 fragColor;

void main() {
    vec3 dir = getRay(gl_FragCoord.xy);
    fragColor = castTraceRay(uCamPos, dir);
}