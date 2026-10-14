#version 330 core
uniform vec2 uScreen;
uniform vec4 uRect;
out vec2 uv;
void main() {
    const vec2 corners[6] = vec2[6](vec2(0,0), vec2(1,0), vec2(0,1), vec2(0,1), vec2(1,0), vec2(1,1));
    uv = corners[gl_VertexID];
    vec2 p = (uRect.xy + uv * uRect.zw) / uScreen;
    gl_Position = vec4(p.x * 2.0 - 1.0, 1.0 - p.y * 2.0, 0.0, 1.0);
}
