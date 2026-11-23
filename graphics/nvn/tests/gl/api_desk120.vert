#version 120
attribute vec2 aPos;
attribute vec3 aCol;
uniform vec2 uOff;
varying vec3 vCol;
void main() { vCol = aCol; gl_Position = vec4(aPos + uOff, 0.0, 1.0); }
