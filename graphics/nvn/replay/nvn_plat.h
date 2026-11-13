// 回放层的平台接口：换操作系统就要重写的东西只从这里进入回放核心与 Vulkan 后端（docs/设计_Vulkan回放层重搭.md §2）。
// 安卓实现在 android/native/gfx_plat/；鸿蒙实现由鸿蒙侧提供。本头不出现任何图形 API 类型与平台类型；
// 与 Vulkan 有关的平台入口（窗口 → 表面）在 nvn_plat_vk.h，只有 Vulkan 后端 include 它。
// 显示节拍源已有独立接口 graphics/nvn/gfx/nvn/nvn_vsync.h，不在这里重复。
#pragma once
#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

#define NVN_PLAT_API_VERSION 2   // 改签名或语义 +1，各平台实现同批改

enum { NVN_PLAT_LOG_INFO = 0, NVN_PLAT_LOG_WARN = 1, NVN_PLAT_LOG_RED = 2 };
// 一行日志。cls：类别（"replay" / "gpu" / "unimpl" …），text：不带换行。线程：任意。
// 安卓 → logcat，鸿蒙 → hilog；RED 级同时进各平台的红行通道（玩家诊断包收它）。
void nvn_plat_log(int level, const char *cls, const char *text);

// 调试开关的唯一入口：没设置返回 dflt。name 不带平台前缀（安卓实现读 debug.s2a.<name>）。线程：任意。
// 回放核心与后端不许直接读系统属性或环境变量。
int nvn_plat_flag(const char *name, int dflt);

enum { NVN_PLAT_DIR_CACHE = 0, NVN_PLAT_DIR_DIAG = 1 };
// 可写目录（管线缓存 / 诊断输出）。返回的指针进程内一直有效；没有这类目录返回 NULL，调用方不落盘。线程：任意。
const char *nvn_plat_dir(int which);

// 回放循环的安全点：回放核心每执行一条命令前调一次（线程：回放所在线程，不持回放核心以外的锁）。
// 一次提交的回放可以连续跑几秒（现场编着色器、建管线），平台若有「要所有游戏线程停下」的事务（安卓运行时改内存映射），
// 在这里让本线程停到事务结束；没有这类事务的平台实现成空函数。没有事务时必须便宜（一次原子读的量级）。
void nvn_plat_safepoint(void);

#ifdef __cplusplus
}
#endif
