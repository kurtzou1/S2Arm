// 片元颜色出口 half 舍入改写（gal_colorround.c）的声明：不引 Metal 头，Linux / Windows 出包机单独编那份 .c 时也用（#783）。
//   gal_internal.h 在 Metal 4 可用性区之前包含本头，各块文件照旧经 gal_internal.h 看到这些声明。
#pragma once
#include <stdint.h>
#define GAL_PB_FC0 110   // 可编程混合（#674）：颜色输出 n 的开关是函数常量 s2a_pb<n>_c，编号 GAL_PB_FC0 + n（110..117；Fetch.cs 用 0..39 / 64..95 / 128..，FsFout 100..103）
#define GAL_COLOR_ROUND_SLOT 27   // 片元阶段：无混合 half 颜色附件的 RTZ 位图；计算阶段的 27 号仍给共享内存溢出
char *gal_color_round_msl(const char *msl, const char *entry, char *why);   // 片元主入口按附件位图量化 half 输出（gal_colorround.c）
char *gal_color_round_pb_msl(const char *msl, const char *entry, char *why);   // 同上，另加可编程混合开关（#674，直连链 nxgal_dmsh_color_round 用）
const char *gal_color_round_helpers(void);   // 主入口与真实 Metal 回归共用的 RTZ 量化函数
