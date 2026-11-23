#version 300 es
in vec2 aPos;
in vec3 aCol;
uniform vec2 uOff;
uniform highp float uZero;
const int K = 0;
out vec3 vCol;
void main() { vCol = aCol; gl_Position = vec4(aPos + uOff, uZero - K, 1.0); }
