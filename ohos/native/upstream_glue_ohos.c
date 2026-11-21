// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 S2Arm contributors
// 上游 main（2026-10-31 合并）新增、由共享运行时调用的平台钩子的鸿蒙实现。
// 地址布局与安卓同一过渡预算（快照里鸿蒙一直用这套旧布局）；客体 Vulkan 直通（安卓 direct_vk.c /
// direct_session.c，"vk-direct"）鸿蒙未接：按"本局从未配置"作答，不伪造排空或会话。
#ifndef _GNU_SOURCE
#define _GNU_SOURCE
#endif
#include <errno.h>
#include <stdio.h>
#include <string.h>
#include "../../runtime/src/native.h"
#include "../../android/native/runtime/platform/layout_android.inc"

int plat_layout_override(const char *npdm, uint32_t as_type, uint64_t sysres,
                         uint64_t program_id, uint64_t window_base, uint64_t window_size,
                         struct s2a_layout *out, uint64_t *need, char *detail, size_t detail_size) {
    if (!npdm || !out || !need || !detail || !detail_size) return EINVAL;
    char path[1100]; snprintf(path, sizeof path, "%s", npdm);
    char *slash = strrchr(path, '/');
    snprintf(slash ? slash + 1 : path, sizeof path - (size_t)(slash ? slash + 1 - path : 0), "addr_need.tsv");
    s2a_layout_requirements req; const char *why = NULL;
    if (s2a_android_layout_requirements_read(path, program_id, &req, &why) < 0) {
        snprintf(detail, detail_size, "%s", why ? why : "读取地址需求失败"); return EINVAL;
    }
    if (s2a_android_layout_split(&req, 0, &why, detail, detail_size) < 0) {
        snprintf(detail, detail_size, "%s", why ? why : "地址预算无效"); return EINVAL;
    }
    *need = s2a_android_layout_need(as_type, sysres, &req);
    int rc = s2a_android_layout_compute(as_type, sysres, &req, window_base, window_size, out);
    if (rc) { snprintf(detail, detail_size, "OHOS 地址布局失败：%d", rc); return EINVAL; }
    return 0;
}

struct s2a_wsi_api;
int s2a_android_vk_session_prepare(const struct s2a_wsi_api *api, const char *game_dir, const char *state_dir) {
    (void)api; (void)game_dir; (void)state_dir; return 0;
}
int s2a_android_vk_skip_module(const char *name) { (void)name; return 0; }
int s2a_android_vk_quiesce(void) { return -1; }
int s2a_android_vk_drain_admitted(void) { return 0; }

// v0.1.0 新增钩子：客体 Vulkan 直通鸿蒙未接，NVN 客体走 NVN 直连表，这里按"不是 vk-direct 的 NVN 客体"作答。
int s2a_android_vk_nvn_guest(void) { return 0; }
// GS+遮挡查询探测（安卓 posix_spawn 打包进 APK 的探测程序）鸿蒙没有这个可执行件：
// 返回非零 = 无结果，能力层读到"不支持"，方向安全；device lost 回写同样无处可写。
int s2a_capprobe_ensure(void) { return -1; }
void s2a_capprobe_runtime_lost(void) {}
// 安卓 QA 调试开关（关 swapchain_maintenance1 的 present fence）；鸿蒙 Maleoon 本来就没有这个扩展。
int s2a_android_qa_no_present_fence(void) { return 0; }
// 安卓按 CPU 容量给游戏线程分大小核（capacity_affinity.cpp，C++ 运行时）；鸿蒙线程调度走 QoS（fps_ohos.c），
// 引擎不带 C++ 运行时，这里与快照口径一致：不改亲和性。
void s2a_capacity_enter(int role) { (void)role; }
void s2a_capacity_leave(int role) { (void)role; }
void s2a_capacity_check(void) {}
void s2a_capacity_foreground(int foreground) { (void)foreground; }
void s2a_capacity_stop(void) {}

// ---- O-2（同步上游 v0.2.6）：上游安卓新接线，鸿蒙暂不接，给空实现保持合并前行为 ----
// S2A_DOCS 文档根绑定（docs_android.c）：合并前鸿蒙不设 S2A_DOCS，这里继续不设。
int s2a_android_docs_bind(const char *state_dir) { (void)state_dir; return 0; }
// 停帧救场「这款下次也关」标记（docs_android.c，main 9df13c4c2）：鸿蒙不设 S2A_DOCS、没有游戏库面板，不读标记。
int s2a_android_stall_off_apply(const char *docs) { (void)docs; return 0; }
// 直连安全网武装（dguard_android.c + runtime/src/dguard.c）：鸿蒙不武装，恒放行。
int s2a_android_dguard_launch(uint64_t program_id, const char *game_data_dir, unsigned direct_abi) {
    (void)program_id; (void)game_data_dir; (void)direct_abi; return 0;
}
