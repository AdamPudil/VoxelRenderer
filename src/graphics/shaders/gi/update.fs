#version 420 core
#include "../include/frag_traverse.glsl"
#include "../include/gi_update.glsl"
out vec4 fragColor;
void main() {
    giUpdate(int(gl_FragCoord.x));
    fragColor = vec4(0.0);
}
