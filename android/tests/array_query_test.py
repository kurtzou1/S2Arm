#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 S2Arm contributors
# 门禁间接：android/tests/vk/standalone/array-query.sh 调它（vk 车道 run.sh 默认档按 standalone/*.sh 逐个跑）
"""Static validation of array-coordinate lowering; NOT a GPU gate.

Requires a C compiler and glslc/spirv-val (PATH, or the explicit options below).
The independent device probe supplies the red/green sampling criterion.
"""
import argparse
from pathlib import Path
import shutil
import struct
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[2]
P = argparse.ArgumentParser(description=__doc__)
P.add_argument('--cc', default=shutil.which('cc') or shutil.which('clang'))
P.add_argument('--shader-tools', type=Path)
A = P.parse_args()


def tool(name):
    if A.shader_tools:
        for suffix in ('', '.exe'):
            p = A.shader_tools / (name + suffix)
            if p.is_file():
                return str(p)
    p = shutil.which(name)
    if not p:
        P.error('missing ' + name)
    return p


if not A.cc:
    P.error('missing C compiler; pass --cc')
GLSLC, VAL = tool('glslc'), tool('spirv-val')
CASES = {
    'array.frag': (6, '''#version 450
layout(set=0,binding=0) uniform sampler2DArray tex;
layout(location=0) out vec4 color;
void main(){int x=int(gl_FragCoord.x);float a=float(x&1);
vec4 i0=texture(tex,vec3(.5,.5,0));vec4 i1=texture(tex,vec3(.5,.5,1));
vec4 id=texture(tex,vec3(.5,.5,a));
vec4 e0=textureLod(tex,vec3(.5,.5,0),0);vec4 e1=textureLod(tex,vec3(.5,.5,1),0);
vec4 ed=textureLod(tex,vec3(.5,.5,a),0);
color=x==0?i0:x==1?i1:x<4?id:x==4?e0:x==5?e1:ed;}
'''),
    'dimensions.frag': (4, '''#version 450
layout(set=0,binding=0) uniform sampler1DArray a;
layout(set=0,binding=1) uniform samplerCubeArray b;
layout(set=0,binding=2) uniform sampler2DArrayShadow c;
layout(location=0) out vec4 o;
void main(){o=texture(a,vec2(.5,1))+textureLod(b,vec4(1,0,0,1),0)
+vec4(texture(c,vec4(.5,.5,1,.5)))+textureGather(c,vec3(.5,.5,1),.5);}
'''),
    'plain.frag': (0, '''#version 450
layout(set=0,binding=0) uniform sampler2D a;
layout(location=0) out vec4 o;
void main(){o=texture(a,vec2(.5));}
'''),
    'multisample.frag': (0, '''#version 450
layout(set=0,binding=0) uniform sampler2DMSArray a;
layout(location=0) out vec4 o;
void main(){o=texelFetch(a,ivec3(0,0,1),0);}
'''),
}
HELPER = r'''
#include <stdio.h>
#include "nvn_vk_array_query.h"
int main(int argc, char **argv) {
    if (argc != 4) { return 2; }
    FILE *f = fopen(argv[1], "rb");
    if (!f) { return 3; }
    fseek(f, 0, SEEK_END);
    long z = ftell(f);
    rewind(f);
    if (z < 0 || z % 4) { return 4; }
    uint32_t *w = malloc((size_t)z), *copy = malloc((size_t)z);
    if (!w || !copy) { return 4; }
    if (fread(w, 1, (size_t)z, f) != (size_t)z) { return 4; }
    fclose(f);
    memcpy(copy, w, (size_t)z);
    uint32_t n = 0, c = 0;
    uint32_t *o = nvn_vk_array_query(w, (uint32_t)(z / 4), &n, &c);
    if (c != (uint32_t)atoi(argv[3]) || memcmp(w, copy, (size_t)z)) { return 5; }
    if (!c && (o || n != (uint32_t)z / 4)) { return 6; }
    f = fopen(argv[2], "wb");
    if (!f) { return 7; }
    fwrite(o ? o : w, 4, n, f);
    fclose(f);
    free(o);
    free(copy);
    free(w);
    return 0;
}
'''
with tempfile.TemporaryDirectory(prefix='s2a-array-query-') as tmp:
    d = Path(tmp)
    (d / 'check.c').write_text(HELPER)
    exe = d / 'check.exe'
    subprocess.run([A.cc, '-std=c11', '-Wall', '-Wextra', '-Werror',
                    '-I' + str(ROOT / 'android/native/nvn'), str(d / 'check.c'), '-o', str(exe)], check=True)
    for name, (count, glsl) in CASES.items():
        src, spv, patched = d/name, d/(name+'.spv'), d/(name+'.query.spv')
        src.write_text(glsl)
        subprocess.run([GLSLC, str(src), '-o', str(spv)], check=True)
        subprocess.run([exe, spv, patched, str(count)], check=True)
        subprocess.run([VAL, '--target-env', 'vulkan1.1', patched], check=True)
        if not count:
            assert spv.read_bytes() == patched.read_bytes(), name
        print(name, 'rewritten sites', count, 'valid')
    # Invalid instruction lengths must leave input untouched, without probing
    # operands beyond the module. This is bounds coverage, not a full validator.
    for name, words in [('short', [0x07230203]),
                        ('zero-length', [0x07230203,0x10000,0,10,0,0]),
                        ('truncated', [0x07230203,0x10000,0,10,0,9<<16|25])]:
        src, dst = d/(name+'.spv'), d/(name+'.out')
        src.write_bytes(struct.pack('<'+'I'*len(words), *words))
        subprocess.run([exe, src, dst, '0'], check=True)
        assert src.read_bytes() == dst.read_bytes()
    print('4 shader modules + 3 bounds cases passed; GPU/VVL not exercised')
