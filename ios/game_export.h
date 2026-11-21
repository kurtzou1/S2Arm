// 手机上导出已装好的一款（0.6.3）：生成和电脑端「导出」同格式的 <名>.s2arm + <名>.img，交「文件」App 存走，
//   换签名重装 S2Arm 后放进「放这里导入」导回（runtime/src/pack_apply.c s2a_s2arm_import + img_place）。实现 ios/game_export.m，单测 runtime/tests/t_game_export.m
#pragma once
#include <stddef.h>
// 返回 0 = 写好（s2arm_out / img_out 是两个文件的完整路径）；负数 = 导不出（why 写一句原因，日志用；界面按码说人话）
enum {
    S2A_GEXP_NO_PROGRAM = -1,   // 没有程序包（program/catalogue.json / 清单的 dir / 版本目录不在：0.5 老款、只放了 .img 的款）
    S2A_GEXP_IN_BUNDLE = -2,    // 资源包在 App 包里（只读，Apple TV 安装包）
    S2A_GEXP_PARTIAL = -3,      // 资源包只部分可玩（有 .partial；romfs.img 布局缺 index.tsv 列的文件）
    S2A_GEXP_NO_IMG = -4,       // 资源包里既没有 game.img 也没有 romfs.img（老布局）
    S2A_GEXP_IO = -5,           // 读写失败、路径放不进 ustar 等
};
// proc_docs = 进程级 <容器>/Documents；out_dir 必须已存在、和资源包同一个卷（.img 用硬链接）
int s2a_game_export(const char *proc_docs, const char *gid, const char *out_dir, char *s2arm_out, size_t s2arm_n, char *img_out, size_t img_n, char *why, size_t why_n);
