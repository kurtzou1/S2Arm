// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 S2Arm contributors
#version 450
layout(location=0) flat in uint observedVS;
layout(set=0,binding=1,std140) uniform DriverFS { layout(offset=1604) uint base; } fs;
layout(location=0) out vec4 color;
void main(){color=vec4(observedVS==0u||observedVS==3u?1.0:0.0,observedVS==0u||observedVS==7u?1.0:0.0,fs.base==0u||fs.base==3u?1.0:0.0,1.0);}
