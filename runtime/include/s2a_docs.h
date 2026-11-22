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
#include <sys/stat.h>
#if defined(__APPLE__)
#include <TargetConditionals.h>
#endif
// 容器文档根相对 HOME 的位置（11-15 Apple TV 版）：iOS / Mac = Documents；tvOS 不让 App 写 Documents、大文件只能放 Caches（系统空间紧时可清），
//   电视上用 Library/Caches/S2Arm：多款容器 games/<游戏号>、资源包 games/<游戏号>/资源包 都在它下面（资源包被清后电脑端「装到 Apple TV」重推）
#if defined(__APPLE__) && TARGET_OS_TV
#define S2A_CONTAINER_DOCS_REL "Library/Caches/S2Arm"
#else
#define S2A_CONTAINER_DOCS_REL "Documents"
#endif

// 文档根写进 out；返回 snprintf 的长度（截断时 ≥ n）
static inline int s2a_docs_root(char *out, size_t n) {
    const char *d = getenv("S2A_DOCS"), *h = getenv("HOME");
    if (d && *d) return snprintf(out, n, "%s", d);
    return snprintf(out, n, "%s/" S2A_CONTAINER_DOCS_REL, h && *h ? h : ".");
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
//   出容器（pack/ship_ext.py launch.ctx game_data）都按这一条，不许另拼。只看一处目录在不在（下面的备用位置），不读别的
// 备用位置 <容器>/Library/S2Arm（v0.3.3，iOS 27 玩家机上 Library/Application Support/S2Arm 整条归 root、App 写不进，连迁移的新树都建不出来）：
//   Library 本身归 App。<容器>/Library/S2Arm/games 在就用它（v0.3.3–v0.4.4 的迁移建过的玩家机上还在用；迁移已撤，不再新建；电脑端推包同一判据，pack/jobs/install.py pack_listing）
#define S2A_PACK_BASE_REL "Library/Application Support/S2Arm"
#define S2A_PACK_BASE_ALT_REL "Library/S2Arm"
static inline int s2a_pack_legacy_root(char *out, size_t n, const char *docs) { return snprintf(out, n, "%s/资源包", docs); }
static inline const char *s2a_pack_base_rel(const char *container, int clen) {   // 容器根（前 clen 字节）下用哪一处
    char alt[1200]; struct stat st;
    snprintf(alt, sizeof alt, "%.*s/" S2A_PACK_BASE_ALT_REL "/games", clen, container);
    return !stat(alt, &st) && S_ISDIR(st.st_mode) ? S2A_PACK_BASE_ALT_REL : S2A_PACK_BASE_REL;
}
// App 包内的资源包（11-16 Apple TV 安装包导出：pack/jobs/tvos.py export_tv 把这款资源包整份打进 App 本体 <App>/Games/<游戏号>/资源包/，
//   包内带 .applied，电视上闸门判「已应用」、不在只读区写）：docs 以 /games/<游戏号> 结尾、<bundle>/Games/<游戏号>/资源包/manifest.json 在
//   → 写包内路径、回长度；否则回 0（照旧找 Library/Caches）。纯函数，单测 runtime/tests/t_docs.c；只在 tvOS 上由 s2a_pack_root 先调（没上电视验过）
static inline int s2a_pack_root_in_bundle(char *out, size_t n, const char *bundle, const char *docs) {
    const char *k = docs ? strrchr(docs, '/') : NULL;
    if (!bundle || !*bundle || !k || k - docs < 6 || strncmp(k - 6, "/games", 6) || !k[1] || k[1] == '.') return 0;
    char m[2048]; struct stat st;
    if (snprintf(m, sizeof m, "%s/Games/%s/资源包/manifest.json", bundle, k + 1) >= (int)sizeof m || stat(m, &st) || !S_ISREG(st.st_mode)) return 0;
    int r = snprintf(out, n, "%s/Games/%s/资源包", bundle, k + 1);
    return r > 0 ? r : 0;
}
#if defined(__APPLE__) && TARGET_OS_TV
const char *s2a_launch_ctx_bundle_dir(void) __attribute__((weak_import));   // runtime/src/launchctx.c：App 包根（单测不链它）
#endif
static inline int s2a_pack_root(char *out, size_t n, const char *docs) {
#if defined(__APPLE__) && TARGET_OS_TV
    { int r = s2a_launch_ctx_bundle_dir ? s2a_pack_root_in_bundle(out, n, s2a_launch_ctx_bundle_dir(), docs) : 0; if (r) return r; }   // 电视：先找包内，没有再找 Library/Caches
#endif
    static const char key[] = "/Documents/games/";
    const char *k = docs ? strstr(docs, key) : NULL;
    if (k) {
        const char *gid = k + sizeof key - 1;
        if (*gid && *gid != '.' && !strchr(gid, '/'))
            return snprintf(out, n, "%.*s/%s/games/%s/资源包", (int)(k - docs), docs, s2a_pack_base_rel(docs, (int)(k - docs)), gid);
    }
    return s2a_pack_legacy_root(out, n, docs ? docs : ".");
}
// 进程级 Documents（<容器>/Documents）→ 资源包位置的根（备用位置在就是它，否则 Library/Application Support/S2Arm；迁移、#569 写不进修复扫这里的 games/）；
//   proc_docs 不以 /Documents 结尾返回 -1（不猜；tvOS 见上面 s2a_pack_base_tv）。s2a_pack_base_main / _alt：固定取其中一处（修复时两处都要看）
// Apple TV（11-21 D-SDS6：电视上 .s2arm 导入全拒「文档根 …/Library/Caches/S2Arm 不是 …/Documents」）：容器文档根就是 <容器>/Library/Caches/S2Arm，
//   每款资源包按 s2a_pack_root 的旧位置在 <文档根>/games/<号>/资源包、程序在 <文档根>/games/<号>/program（s2a_program_games_root 同一套推出来）——
//   资源位置的根就是文档根本身，没有 Library/Application Support 那一层、也没有备用位置。proc_docs 不以 /Library/Caches/S2Arm 结尾返回 -1（不猜）。
//   纯函数，各平台都编、单测 runtime/tests/t_docs.c；只在 tvOS 上由 s2a_pack_base_at 用
static inline int s2a_pack_base_tv(char *out, size_t n, const char *proc_docs) {
    static const char tail[] = "/Library/Caches/S2Arm";
    size_t l = proc_docs ? strlen(proc_docs) : 0, t = sizeof tail - 1;
    if (l <= t || strcmp(proc_docs + l - t, tail)) return -1;
    return snprintf(out, n, "%s", proc_docs);
}
static inline int s2a_pack_base_at(char *out, size_t n, const char *proc_docs, const char *rel) {
#if defined(__APPLE__) && TARGET_OS_TV
    (void)rel; return s2a_pack_base_tv(out, n, proc_docs);   // 电视只有一处，_main / _alt 都是它
#endif
    size_t l = proc_docs ? strlen(proc_docs) : 0;
    if (l < 10 || strcmp(proc_docs + l - 10, "/Documents")) return -1;
    return snprintf(out, n, "%.*s/%s", (int)(l - 10), proc_docs, rel ? rel : s2a_pack_base_rel(proc_docs, (int)(l - 10)));
}
static inline int s2a_pack_base(char *out, size_t n, const char *proc_docs) { return s2a_pack_base_at(out, n, proc_docs, NULL); }
static inline int s2a_pack_base_main(char *out, size_t n, const char *proc_docs) { return s2a_pack_base_at(out, n, proc_docs, S2A_PACK_BASE_REL); }
static inline int s2a_pack_base_alt(char *out, size_t n, const char *proc_docs) { return s2a_pack_base_at(out, n, proc_docs, S2A_PACK_BASE_ALT_REL); }

#if defined(__APPLE__) && TARGET_OS_IPHONE
// 进程级 App 容器 Documents（不看 S2A_DOCS）：只给 iOS 上本来就按容器、不按款的东西用（host.log 与日志归档、资源导入闸门、手柄录制）。
//   只在 iOS 编出来：Mac 代码调不到它，不会再落到用户文稿夹
static inline int s2a_container_docs(char *out, size_t n) {
    const char *h = getenv("HOME");
    return snprintf(out, n, "%s/" S2A_CONTAINER_DOCS_REL, h && *h ? h : ".");
}
#endif
