# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 S2Arm contributors
"""Generate the small, original V0 compute fixture; no game shaders or compiler download."""
from pathlib import Path
import struct
import argparse

words = [0x07230203, 0x00010000, 0, 24, 0]
def op(code, *args): words.extend([((len(args)+1)<<16)|code, *args])
def string(s):
    b=s.encode()+b'\0'; b+=b'\0'*(-len(b)%4)
    return struct.unpack('<'+'I'*(len(b)//4),b)
op(17,1)                         # Shader
op(14,0,1)                       # Logical GLSL450
op(15,5,15,*string('main'),6)      # GLCompute, interface gid
op(16,15,17,64,1,1)              # LocalSize
op(71,6,11,28)                   # gid BuiltIn GlobalInvocationId
op(71,7,6,4)                     # runtime array stride
op(72,8,0,35,0)                  # member offset
op(71,8,3)                       # BufferBlock (SPIR-V 1.0 storage buffer)
op(71,10,34,0); op(71,10,33,0)    # set 0, binding 0
op(19,1); op(33,2,1)             # void, function type
op(21,3,32,0); op(23,4,3,3)      # uint, uvec3
op(32,5,1,4); op(59,5,6,1)       # Input pointer, gid
op(29,7,3); op(30,8,7)           # runtime uint array, block
op(32,9,2,8); op(59,9,10,2)      # Uniform block pointer/variable
op(32,11,2,3)                    # Uniform uint pointer
op(43,3,12,0); op(43,3,13,1664525); op(43,3,14,1013904223)
op(54,1,15,0,2); op(248,16)
op(61,4,17,6); op(81,3,18,17,0)  # gid.x
op(65,11,19,10,12,18)            # &buffer.words[gid.x]
op(61,3,20,19); op(132,3,21,20,13); op(128,3,22,21,14); op(198,3,23,22,18)
op(62,19,23); op(253); op(56)
parser=argparse.ArgumentParser()
parser.add_argument('--output-dir',type=Path,default=Path(__file__).resolve().parent)
base=parser.parse_args().output_dir.resolve()
base.mkdir(parents=True,exist_ok=True)
(base/'transform.spv').write_bytes(struct.pack('<'+'I'*len(words),*words))
(base/'transform_spv.h').write_text('#pragma once\n#include <stdint.h>\nstatic const uint32_t transform_spv[] = {\n'+''.join('    '+', '.join(f'0x{x:08x}u' for x in words[i:i+8])+',\n' for i in range(0,len(words),8))+'};\n',encoding='utf-8')
print(f'generated {len(words)*4} bytes; run spirv-val --target-env vulkan1.1 transform.spv')
