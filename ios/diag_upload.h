// 诊断一键上传的纯判断（ios/diag.m 用；纯 C、无 UIKit，单测 runtime/tests/t_diag_upload.c）。
//   协议：POST https://diag.s2arm.com/v1/upload，正文是诊断包 ZIP 原样；200 回 {"code":"D-XXXX","expiresAt":…}，
//   400 / 413 回 {"error","message"}，429 回 {"error":"rate_limited","retryAfter":…}；只用这一个域名（*.workers.dev 国内不通）。
#ifndef S2A_DIAG_UPLOAD_H
#define S2A_DIAG_UPLOAD_H
#include <stdbool.h>
#include <string.h>

typedef enum {
    S2A_UP_OK,      // 拿到短码：显示短码 +「复制」
    S2A_UP_RETRY,   // 再试一次（只试一次）
    S2A_UP_FAIL,    // 失败：说原因，退回「导出诊断包」
} s2a_up_verdict;

// 短码：D- + 4 位，字符集 23456789ABCDEFGHJKMNPQRSTVWXYZ（去掉 0 1 I L O U）
static inline bool s2a_diag_code_ok(const char *c) {
    static const char set[] = "23456789ABCDEFGHJKMNPQRSTVWXYZ";
    if (!c || strlen(c) != 6 || c[0] != 'D' || c[1] != '-') return false;
    for (int i = 2; i < 6; i++) if (!c[i] || !strchr(set, c[i])) return false;
    return true;
}

// status：HTTP 状态码（网络不通时 0）；net_error：请求没拿到回应；attempt：第几次（0 起）；code：200 回应里的短码（可为 NULL）。
//   网络不通 / 5xx 重试一次；429 是限频（同一来源每 60 秒 5 次），马上重试照样被拒，直接提示稍后再试；
//   400 / 413 是包本身不合规，重试也一样，直接失败；200 但短码不合格式当失败（不给玩家一个对不上的码）
static inline s2a_up_verdict s2a_diag_up_verdict(int status, bool net_error, int attempt, const char *code) {
    if (!net_error && status == 200) return s2a_diag_code_ok(code) ? S2A_UP_OK : S2A_UP_FAIL;
    if (attempt == 0 && (net_error || status >= 500)) return S2A_UP_RETRY;
    return S2A_UP_FAIL;
}

// 短码页「去 GitHub 发帖」（方案「短码页链接格式」，Mac / Windows 同一格式）：
//   https://github.com/jhaizhou-ops/S2Arm/issues/new?template=问题回报.yml&logs=<短码>&version=<版本>&platform=<平台选项原文>&title=[问题] （各值 URL 编码）
//   platform 必须与 .github/ISSUE_TEMPLATE/问题回报.yml 的下拉选项逐字相同，GitHub 才预选；单测核对
#define S2A_DIAG_REPO "github.com/jhaizhou-ops/S2Arm"
#define S2A_DIAG_ISSUE_NEW "https://github.com/jhaizhou-ops/S2Arm/issues/new"
#define S2A_DIAG_ISSUE_TEMPLATE "问题回报.yml"
#define S2A_DIAG_ISSUE_TITLE "[问题] "
static inline const char *s2a_diag_issue_platform(bool ipad) { return ipad ? "iPad" : "iPhone"; }

// 上传断网时是不是「无线数据」授权挡的（国行 iPhone：第一次联网系统弹「允许 S2Arm 使用无线数据？」，点了「不允许」就一直断网）。
//   url_error：NSURLError 码（-1009 = NSURLErrorNotConnectedToInternet）；restricted：CTCellularData.restrictedState（0 未知 / 1 受限 / 2 不受限）。
//   只有系统明说「受限」才判授权；未知（弹框还没答）照普通断网说，那句里也提了弹框
static inline bool s2a_diag_net_denied(int url_error, int restricted) { return url_error == -1009 && restricted == 1; }
#endif
