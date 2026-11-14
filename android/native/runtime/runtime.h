// Android 启动组合层，直接复用既有原生核心。
#pragma once
#include "services_abi.h"

#ifdef __cplusplus
extern "C" {
#endif
enum s2a_android_runtime_state {
    S2A_RUNTIME_CREATED, S2A_RUNTIME_LOADING, S2A_RUNTIME_MEMORY_READY,
    S2A_RUNTIME_SERVICES_READY, S2A_RUNTIME_GUEST_RUNNING,
    S2A_RUNTIME_FAILED, S2A_RUNTIME_STOP_REQUESTED,
};
enum s2a_android_runtime_error {
    S2A_RUNTIME_ARGUMENT = -100, S2A_RUNTIME_ALREADY_USED = -101,
    S2A_RUNTIME_WINDOW = -102, S2A_RUNTIME_IMPORT = -103,
    S2A_RUNTIME_MEMORY = -104, S2A_RUNTIME_SERVICES = -105,
    S2A_RUNTIME_SDK = -106, S2A_RUNTIME_THREAD = -107,
    S2A_RUNTIME_STOP = -108, S2A_RUNTIME_RETURNED = -109,
    S2A_RUNTIME_SIGNALS = -110, S2A_RUNTIME_TRACKING = -111, S2A_RUNTIME_SELFCHECK = -112,
    S2A_RUNTIME_LOG = -113,
    // C1：relocation 前的 direct 准入/选择/attempt 事务失败；不是 generic 路径错误。
    S2A_RUNTIME_DIRECT = -114,
};
struct s2a_loader_source; // 私有只读APK来源，布局由shared loader.h定义。

// 运行时 v2：显式 size/version + v2 services 前缀 + 既有模块来源/NPDM/program 字段 +
// 带长度的已验证 graphics descriptor + modePreference。全部指针由外壳保活到进程退出。
// services.graphics 必须为 NULL、graphics_mode=0：native 在 Prepare/commit 后构造局部 v2 请求。
#define S2A_ANDROID_RUNTIME_ABI_V2 2u
#define S2A_ANDROID_RUNTIME_REQUEST_V2_SIZE 160u
struct s2a_android_graphics_descriptor {
    const uint8_t *json;   // 已验证的 graphics.v1.json 原文；native 自己解析并复制
    uint64_t bytes;        // 必须 > 0 且 <= 1 MiB
};
struct s2a_android_runtime_request_v2 {
    uint32_t size, version;
    uint32_t mode_preference, reserved;   // 0 auto / 1 generic / 2 direct，见 s2a_direct_mode_preference
    struct s2a_android_services_request_v2 services;
    const char *module_dir;
    const char *const *module_names;
    uint32_t module_count, reserved0;
    uint64_t program_id;
    const struct s2a_loader_source *module_source;
    const char *npdm_path;
    struct s2a_android_graphics_descriptor graphics;
};

struct s2a_android_runtime_request {
    struct s2a_android_services_request services;
    const char *module_dir;
    const char *const *module_names; // 显式有序的冻结产物选择。
    uint32_t module_count;
    uint64_t program_id; // 初始化后必须与已选 NPDM 的程序号一致。
    const struct s2a_loader_source *module_source; // 非空时只读签名APK源；不再从module_dir取代码。
    const char *npdm_path; // source模式必需的已验只读NPDM；目录模式可省略。
};
struct s2a_android_runtime_status {
    uint64_t session_id;
    uint32_t state;
    int32_t error;
    int32_t services_error;
    uint32_t last_phase; // 最近完成的启动阶段；失败/停止不抹掉它，不代表线程已经清场。
};

#ifdef __cplusplus
static_assert(sizeof(struct s2a_android_runtime_status) == 24, "runtime status ABI");
static_assert(offsetof(struct s2a_android_runtime_status, last_phase) == 20, "runtime phase ABI");
static_assert(sizeof(struct s2a_android_runtime_request_v2) == S2A_ANDROID_RUNTIME_REQUEST_V2_SIZE, "runtime v2 request ABI");
static_assert(offsetof(struct s2a_android_runtime_request_v2, services) == 16, "runtime v2 services offset");
static_assert(offsetof(struct s2a_android_runtime_request_v2, module_dir) == 96, "runtime v2 module dir offset");
static_assert(offsetof(struct s2a_android_runtime_request_v2, module_names) == 104, "runtime v2 names offset");
static_assert(offsetof(struct s2a_android_runtime_request_v2, module_count) == 112, "runtime v2 count offset");
static_assert(offsetof(struct s2a_android_runtime_request_v2, program_id) == 120, "runtime v2 program offset");
static_assert(offsetof(struct s2a_android_runtime_request_v2, module_source) == 128, "runtime v2 source offset");
static_assert(offsetof(struct s2a_android_runtime_request_v2, npdm_path) == 136, "runtime v2 npdm offset");
static_assert(offsetof(struct s2a_android_runtime_request_v2, graphics) == 144, "runtime v2 graphics offset");
#else
_Static_assert(sizeof(struct s2a_android_runtime_status) == 24, "runtime status ABI");
_Static_assert(offsetof(struct s2a_android_runtime_status, last_phase) == 20, "runtime phase ABI");
_Static_assert(sizeof(struct s2a_android_runtime_request_v2) == S2A_ANDROID_RUNTIME_REQUEST_V2_SIZE, "runtime v2 request ABI");
_Static_assert(offsetof(struct s2a_android_runtime_request_v2, services) == 16, "runtime v2 services offset");
_Static_assert(offsetof(struct s2a_android_runtime_request_v2, module_dir) == 96, "runtime v2 module dir offset");
_Static_assert(offsetof(struct s2a_android_runtime_request_v2, module_names) == 104, "runtime v2 names offset");
_Static_assert(offsetof(struct s2a_android_runtime_request_v2, module_count) == 112, "runtime v2 count offset");
_Static_assert(offsetof(struct s2a_android_runtime_request_v2, program_id) == 120, "runtime v2 program offset");
_Static_assert(offsetof(struct s2a_android_runtime_request_v2, module_source) == 128, "runtime v2 source offset");
_Static_assert(offsetof(struct s2a_android_runtime_request_v2, npdm_path) == 136, "runtime v2 npdm offset");
_Static_assert(offsetof(struct s2a_android_runtime_request_v2, graphics) == 144, "runtime v2 graphics offset");
#endif

// 单进程单次、同步执行：只能由外壳独立 host worker 调用，不能占 UI 线程。
// 调用方保活路径、DSO owner、HostApi 和 lease 到进程退出。
// 创建并等待真实 guest pthread，不接管外壳 / WSI 的销毁。
// 旧 native 致命错误仍会 abort；函数返回不证明所有线程已停止。
int s2a_android_runtime_run(const struct s2a_android_runtime_request *);
int s2a_android_runtime_run_v2(const struct s2a_android_runtime_request_v2 *);
int s2a_android_runtime_status(uint64_t session_id, struct s2a_android_runtime_status *);
int s2a_android_runtime_request_stop(uint64_t session_id);
// 私有native组合接缝。每条guest pthread已备妥真实host xstack/fault状态后、SDK前调用；
// 同线程managed attach→fault self-probe→final tracking gate，任一失败禁止进入guest。
uint64_t s2a_android_runtime_session(void);
int s2a_android_runtime_enter_guest_thread(void);
// 只由主 guest 在上面的逐线程准入成功之后、进 SDK 之前调一次：共用会话本代 STARTING→RUNNING（#961）。
// 停止先被接受或会话已失败 / 终局：不发布，走既有 HostApi 停机并返回非 0，调用方不得进 SDK。
// 其余没对上（状态不是本代 STARTING，但没人要求停、也没失败）：报红记下实际状态，返回 0 照常进 SDK。
int s2a_android_runtime_publish_running(void);
// shared lifecycle调用实际CsApi.Shutdown之后的结果核验；不是停止请求或guest停车证明。
int s2a_android_runtime_shutdown_result(void);
#ifdef __cplusplus
}
#endif
