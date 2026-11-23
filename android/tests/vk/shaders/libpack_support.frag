// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 S2Arm contributors
#version 450
// 出包预编库的片元：按 Dsh.cs 的原名 support_buffer 声明支撑缓冲（binding 52 = arg_id 8 × 6 + 片元阶段号 4，2608 字节），
// 写红色；用它让「vs+fs 那一笔」带一个真的片元绑定，之后换成只有 vs 的程序时后端不能还留着它。
layout(set = 0, binding = 52, std140) uniform SupportBlock { uvec4 data[163]; } support_buffer;
layout(location = 0) out vec4 o;
void main() { o = vec4(1.0, 0.0, 0.0, 1.0) + vec4(float(support_buffer.data[0].x & 0u)); }
