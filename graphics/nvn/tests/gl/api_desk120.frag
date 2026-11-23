#version 120
varying vec3 vCol;
uniform vec4 uTint;
void main() { gl_FragColor = vec4(vCol, 1.0) * uTint; }
