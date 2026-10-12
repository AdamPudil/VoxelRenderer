#version 330 core
uniform vec4 uColor;
uniform bool uTextured;
uniform sampler2D uImage;
in vec2 uv;
out vec4 fragColor;
void main() {
    fragColor = uColor * (uTextured ? texture(uImage, uv) : vec4(1.0));
}
