// 文档根（唯一取法，11-07 Mac 新前端 Hades 白屏 90 秒根修）：S2A_DOCS 有就用它，没有才用 $HOME/Documents。
//   iOS：$HOME/Documents 是 App 沙盒；多款容器由启动上下文冻结时设 S2A_DOCS = Documents/games/<gid>（runtime/src/launchctx.c）。
//   Mac：宿主不在沙盒里，$HOME/Documents 是用户真实的文稿夹，受隐私保护——新签名的程序第一次 open 里面的东西，系统要弹授权框，
//        点之前 open 不返回（11-07 Hades：rt_preload 在 opendir(~/Documents/wire/<程序号>/shaders/vk) 卡住、游戏窗口白屏）。
//        Mac 局一律由起局方给 S2A_DOCS（作业层 pack/jobs/build.py = 游戏库/temp/<gid>；开发局 runtime/run_mac.sh = 局目录），
//        兜底只给没设它的开发 / 单测进程。
//   源码里不许再自己拼 $HOME/Documents：tools/shared_path_lint.py 的「文档根」规则查（白名单只放本文件与启动上下文）。
//   纯 C、头文件即实现，单测 runtime/tests/t_docs.c
#pragma once
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#if defined(__APPLE__)
#include <TargetConditionals.h>
#endif

// 文档根写进 out；返回 snprintf 的长度（截断时 ≥ n）
static inline int s2a_docs_root(char *out, size_t n) {
    const char *d = getenv("S2A_DOCS"), *h = getenv("HOME");
    if (d && *d) return snprintf(out, n, "%s", d);
    return snprintf(out, n, "%s/Documents", h && *h ? h : ".");
}

// <文档根>/<按 fmt 拼的相对路径> 写进 out（fmt 为 NULL / 空 = 文档根本身）；返回总长度（截断时 ≥ n）
static inline int s2a_docs_path(char *out, size_t n, const char *fmt, ...) __attribute__((format(printf, 3, 4)));
static inline int s2a_docs_path(char *out, size_t n, const char *fmt, ...) {
    int k = s2a_docs_root(out, n);
    if (k < 0 || !fmt || !*fmt) return k;
    size_t at = (size_t)k < n ? (size_t)k : n;
    int s = snprintf(out + at, n - at, "/");
    if (s < 0) return s;
    at = at + 1 < n ? at + 1 : n;
    va_list ap; va_start(ap, fmt); int m = vsnprintf(out + at, n - at, fmt, ap); va_end(ap);
    return m < 0 ? m : k + 1 + m;
}

// 资源包根（v0.3.0 起挪出 Documents，11-11 真机复现「文件」App / 选择器「最近项目」被 Documents 里几万个资源包文件拖住、一直「正在加载」）：
//   多款容器每款文档根是 <容器>/Documents/games/<游戏号>（存档 S2A/ryujinx、金手指、unpack.log 留在那里，玩家在「文件」里看得见），
//   它的资源包放 <容器>/Library/Application Support/S2Arm/games/<游戏号>/资源包（不在「文件」里、不进 iCloud 备份）；
//   别的文档根（单款兼容 App、Mac 局、单测临时目录）资源包照旧在 <文档根>/资源包。唯一取法：宿主、电脑端推包（pack/jobs/install.py game_pack）、
//   出容器（pack/ship_ext.py launch.ctx game_data）都按这一条，不许另拼。纯字符串，不碰磁盘
#define S2A_PACK_BASE_REL "Library/Application Support/S2Arm"
static inline int s2a_pack_legacy_root(char *out, size_t n, const char *docs) { return snprintf(out, n, "%s/资源包", docs); }
static inline int s2a_pack_root(char *out, size_t n, const char *docs) {
    static const char key[] = "/Documents/games/";
    const char *k = docs ? strstr(docs, key) : NULL;
    if (k) {
        const char *gid = k + sizeof key - 1;
        if (*gid && *gid != '.' && !strchr(gid, '/'))
            return snprintf(out, n, "%.*s/" S2A_PACK_BASE_REL "/games/%s/资源包", (int)(k - docs), docs, gid);
    }
    return s2a_pack_legacy_root(out, n, docs ? docs : ".");
}
// 进程级 Documents（<容器>/Documents）→ 新位置的根 <容器>/Library/Application Support/S2Arm（迁移、#569 写不进修复扫这里的 games/）；
//   proc_docs 不以 /Documents 结尾返回 -1（不猜）
static inline int s2a_pack_base(char *out, size_t n, const char *proc_docs) {
    size_t l = proc_docs ? strlen(proc_docs) : 0;
    if (l < 10 || strcmp(proc_docs + l - 10, "/Documents")) return -1;
    return snprintf(out, n, "%.*s/" S2A_PACK_BASE_REL, (int)(l - 10), proc_docs);
}

#if defined(__APPLE__) && TARGET_OS_IPHONE
// 进程级 App 容器 Documents（不看 S2A_DOCS）：只给 iOS 上本来就按容器、不按款的东西用（host.log 与日志归档、资源导入闸门、手柄录制）。
//   只在 iOS 编出来：Mac 代码调不到它，不会再落到用户文稿夹
static inline int s2a_container_docs(char *out, size_t n) {
    const char *h = getenv("HOME");
    return snprintf(out, n, "%s/Documents", h && *h ? h : ".");
}
#endif
