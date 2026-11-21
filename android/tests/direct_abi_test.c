// C0：直连 ABI 的 C 端布局/校验/NVN 风格实调探针。
// 同一份源码在主机（LP64 测试）和 Android ARM64（真机探针）编译：
//   direct_abi_test                    —— 主机 CTest，打印 JSON 并跑全部向量
//   aarch64-linux-android34-clang ...  —— 推到 /data/local/tmp 执行，证明 ARM64 真实调用
// 只使用本仓头文件，不链接 Vulkan/NVN；调用经函数指针（与 xstack 交付宿主实现的路径同型）。
#include "../native/direct/s2a_direct.h"
#include "../native/runtime/runtime.h"

#include <stdint.h>
#include <stdio.h>
#include <string.h>

static int g_failures;

static void check(int condition, const char *what) {
    if (!condition) {
        printf("FAIL %s\n", what);
        g_failures++;
    }
}

// ---------- NVN 风格的真实调用：窄整数、浮点、128 位向量、栈参数、回调 ----------
typedef struct { float x, y, z, w; } probe_vec;
typedef int32_t (*fn_wide)(uint8_t, uint16_t, int32_t, int64_t, uint32_t, float, double);
typedef int32_t (*fn_stack12)(uint64_t, uint64_t, uint64_t, uint64_t, uint64_t, uint64_t,
                              uint64_t, uint64_t, uint64_t, uint64_t, uint64_t, uint64_t);
typedef int32_t (*fn_vector)(probe_vec);
typedef int32_t (*fn_callback)(int32_t (*)(float, float), float, float);
typedef int32_t (*fn_nvn_draw)(void *, const float *, float, uint32_t, int32_t,
                               uint64_t, uint64_t, uint64_t, uint64_t, uint64_t, uint64_t, float);

static int32_t c_wide(uint8_t a, uint16_t b, int32_t c, int64_t d, uint32_t e, float f, double g) {
    // 仅低 8 位被 NVNboolean 消费的规则由调用方负责；这里核对象/参数没被截断或错位。
    return (int32_t)(a + b + c + (int32_t)d + (int32_t)e + (int32_t)(f * 4.0f) + (int32_t)(g * 2.0));
}
static int32_t c_stack12(uint64_t a, uint64_t b, uint64_t c, uint64_t d, uint64_t e, uint64_t f,
                         uint64_t g, uint64_t h, uint64_t i, uint64_t j, uint64_t k, uint64_t l) {
    // 手算：前 8 个走寄存器，后 4 个走栈；用互不相同的权重抓错位。
    return (int32_t)(a + 2*b + 3*c + 4*d + 5*e + 6*f + 7*g + 8*h + 9*i + 10*j + 11*k + 12*l);
}
static int32_t c_vector(probe_vec v) { return (int32_t)(v.x + 2*v.y + 3*v.z + 4*v.w); }
static int32_t c_add(float a, float b) { return (int32_t)(a * 100.0f + b); }
static int32_t c_callback(int32_t (*cb)(float, float), float a, float b) { return cb(a, b); }
static int32_t nvn_bool(uint32_t b) { return (int32_t)(b & 0xff); }
static int32_t c_nvn_draw(void *obj, const float *pos, float w, uint32_t color, int32_t count,
                          uint64_t a, uint64_t b, uint64_t c, uint64_t d, uint64_t e, uint64_t f,
                          float tail) {
    // 模拟 NVN draw：对象指针 + float3 + 窄 boolean 低 8 位 + 栈上整数 + 尾随 float。
    int32_t base = (obj == (void *)0x1122334455667788ull ? 1 : 0) + (int32_t)(pos[0] + pos[1] + pos[2])
        + (int32_t)(w * 10.0f) + (int32_t)(color & 0xff) + (count & 0xff)
        + (int32_t)a + (int32_t)b + (int32_t)c + (int32_t)d + (int32_t)e + (int32_t)f
        + (int32_t)(tail * 1000.0f);
    return base;
}

// ---------- 假 owner：只验函数表调用路径，不冒充 GPU ----------
typedef struct { int state; int stop_calls; } fake_owner;
static int32_t fake_activate(void *ctx) { ((fake_owner *)ctx)->state = S2A_DIRECT_ACTIVE; return S2A_DIRECT_RES_OK; }
static int32_t fake_stop(void *ctx) { ((fake_owner *)ctx)->stop_calls++; ((fake_owner *)ctx)->state = S2A_DIRECT_RES_STOPPED; return S2A_DIRECT_RES_OK; }
static int32_t fake_query(void *ctx, s2a_direct_status_v1 *out) {
    if (!out) return S2A_DIRECT_RES_ARGUMENT;
    if (s2a_direct_status_init(out)) return S2A_DIRECT_RES_ARGUMENT;
    out->state = (uint32_t)((fake_owner *)ctx)->state;
    return S2A_DIRECT_RES_OK;
}
static int32_t fake_poll(void *ctx, uint32_t budget_ms) { (void)ctx; return budget_ms <= 10 ? S2A_DIRECT_RES_OK : S2A_DIRECT_RES_ARGUMENT; }
static int32_t fake_destroy(void *ctx) { (void)ctx; return S2A_DIRECT_RES_OK; }

static void print_layout(void) {
    printf("{\"schema\":\"s2a-direct-abi-v1\",\"ptr\":%u", (unsigned)sizeof(void *));
    printf(",\"sizes\":{\"status\":%u,\"table\":%u,\"services_request\":%u,\"services_request_v2\":%u,"
           "\"runtime_status\":%u,\"runtime_request_v2\":%u}",
           (unsigned)sizeof(s2a_direct_status_v1), (unsigned)sizeof(s2a_direct_api_v1),
           (unsigned)sizeof(struct s2a_android_services_request),
           (unsigned)sizeof(struct s2a_android_services_request_v2),
           (unsigned)sizeof(struct s2a_android_runtime_status),
           (unsigned)sizeof(struct s2a_android_runtime_request_v2));
    printf(",\"offsets\":{");
    printf("\"status.state\":%u,\"status.blockers\":%u,\"status.error\":%u,\"status.reserved\":%u,",
           (unsigned)offsetof(s2a_direct_status_v1, state), (unsigned)offsetof(s2a_direct_status_v1, blockers),
           (unsigned)offsetof(s2a_direct_status_v1, error), (unsigned)offsetof(s2a_direct_status_v1, reserved));
    printf("\"table.session\":%u,\"table.context\":%u,\"table.activate\":%u,\"table.request_stop\":%u,"
           "\"table.query\":%u,\"table.poll\":%u,\"table.destroy\":%u,",
           (unsigned)offsetof(s2a_direct_api_v1, session), (unsigned)offsetof(s2a_direct_api_v1, context),
           (unsigned)offsetof(s2a_direct_api_v1, activate), (unsigned)offsetof(s2a_direct_api_v1, request_stop),
           (unsigned)offsetof(s2a_direct_api_v1, query), (unsigned)offsetof(s2a_direct_api_v1, poll),
           (unsigned)offsetof(s2a_direct_api_v1, destroy));
    printf("\"services_v2.graphics\":%u,\"services_v2.graphics_mode\":%u,\"services_v2.flags\":%u,",
           (unsigned)offsetof(struct s2a_android_services_request_v2, graphics),
           (unsigned)offsetof(struct s2a_android_services_request_v2, graphics_mode),
           (unsigned)offsetof(struct s2a_android_services_request_v2, flags));
    printf("\"runtime_v2.services\":%u,\"runtime_v2.module_dir\":%u,\"runtime_v2.module_names\":%u,"
           "\"runtime_v2.module_count\":%u,\"runtime_v2.program_id\":%u,\"runtime_v2.module_source\":%u,"
           "\"runtime_v2.npdm_path\":%u,\"runtime_v2.graphics\":%u}",
           (unsigned)offsetof(struct s2a_android_runtime_request_v2, services),
           (unsigned)offsetof(struct s2a_android_runtime_request_v2, module_dir),
           (unsigned)offsetof(struct s2a_android_runtime_request_v2, module_names),
           (unsigned)offsetof(struct s2a_android_runtime_request_v2, module_count),
           (unsigned)offsetof(struct s2a_android_runtime_request_v2, program_id),
           (unsigned)offsetof(struct s2a_android_runtime_request_v2, module_source),
           (unsigned)offsetof(struct s2a_android_runtime_request_v2, npdm_path),
           (unsigned)offsetof(struct s2a_android_runtime_request_v2, graphics));
    printf("}\n");
}

static void check_validation(void) {
    s2a_direct_status_v1 s;
    memset(&s, 0, sizeof s);
    check(s2a_direct_status_init(&s) == S2A_DIRECT_RES_OK && s.size == 24 && s.version == 1, "status init");
    check(s2a_direct_status_check(&s) == S2A_DIRECT_RES_OK, "status check ok");
    s.version = 2; check(s2a_direct_status_check(&s) == S2A_DIRECT_RES_VERSION, "status version rejected"); s.version = 1;
    s.size = 16; check(s2a_direct_status_check(&s) == S2A_DIRECT_RES_ARGUMENT, "status short rejected"); s.size = 24;
    s.blockers = 64; check(s2a_direct_status_check(&s) == S2A_DIRECT_RES_ARGUMENT, "unknown blocker rejected"); s.blockers = 0;
    s.state = S2A_DIRECT_STOPPED; s.blockers = S2A_DIRECT_BLOCK_PRESENT;
    check(s2a_direct_status_check(&s) == S2A_DIRECT_RES_ARGUMENT, "stopped with blockers rejected"); s.blockers = 0;
    s.state = S2A_DIRECT_FAILED;
    check(s2a_direct_status_check(&s) == S2A_DIRECT_RES_ARGUMENT, "failed without cause rejected");
    s.error = S2A_DIRECT_RES_DRIVER; check(s2a_direct_status_check(&s) == S2A_DIRECT_RES_OK, "failed cause accepted");
    s.error = 7; check(s2a_direct_status_check(&s) == S2A_DIRECT_RES_ARGUMENT, "positive error rejected");
    s = (s2a_direct_status_v1){0}; s2a_direct_status_init(&s); s.reserved = 1;
    check(s2a_direct_status_check(&s) == S2A_DIRECT_RES_ARGUMENT, "status reserved rejected");

    fake_owner owner = { S2A_DIRECT_PREPARED, 0 };
    s2a_direct_api_v1 table;
    memset(&table, 0, sizeof table);
    check(s2a_direct_table_check(&table) == S2A_DIRECT_RES_ARGUMENT, "empty table rejected");
    table.size = S2A_DIRECT_TABLE_SIZE; table.version = S2A_DIRECT_ABI; table.session = 0xabc;
    table.context = &owner; table.activate = fake_activate; table.request_stop = fake_stop;
    table.query = fake_query; table.poll = fake_poll; table.destroy = fake_destroy;
    check(s2a_direct_table_check(&table) == S2A_DIRECT_RES_OK, "table accepted");
    table.version = 2; check(s2a_direct_table_check(&table) == S2A_DIRECT_RES_VERSION, "table version rejected"); table.version = 1;
    table.session = 0; check(s2a_direct_table_check(&table) == S2A_DIRECT_RES_ARGUMENT, "table session rejected"); table.session = 0xabc;
    table.destroy = NULL; check(s2a_direct_table_check(&table) == S2A_DIRECT_RES_ARGUMENT, "table missing entry rejected"); table.destroy = fake_destroy;
    check(table.activate(table.context) == S2A_DIRECT_RES_OK && owner.state == S2A_DIRECT_ACTIVE, "table activate");
    check(table.poll(table.context, 10) == S2A_DIRECT_RES_OK && table.poll(table.context, 11) == S2A_DIRECT_RES_ARGUMENT, "table poll budget");
    s2a_direct_status_v1 q;
    check(table.query(table.context, &q) == S2A_DIRECT_RES_OK && q.state == S2A_DIRECT_ACTIVE, "table query");
    check(table.request_stop(table.context) == S2A_DIRECT_RES_OK && owner.stop_calls == 1, "table stop");
}

static void check_calls(void) {
    fn_wide wide = c_wide;
    int32_t got = wide(0xF2, 0x1234, -7, 0x100000000ll, 0x95u, 1.5f, 2.25);
    // 手算：0xF2=242, 0x1234=4660, -7, 0x100000000 截为 0, 0x95=149, 1.5*4=6, 2.25*2=4.5→4
    int32_t want = 242 + 4660 - 7 + 0 + 149 + 6 + 4;
    check(got == want, "wide narrow/float call");
    check(wide((uint8_t)0x1F2, 0x1234, -7, 0x100000000ll, 0x95u, 1.5f, 2.25) ==
          0xF2 + 4660 - 7 + 0 + 149 + 6 + 4, "explicit narrow truncation");

    fn_stack12 stack = c_stack12;
    int32_t sum = stack(1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12);
    check(sum == (1 + 2*2 + 3*3 + 4*4 + 5*5 + 6*6 + 7*7 + 8*8 + 9*9 + 10*10 + 11*11 + 12*12),
          "twelve-argument stack call");

    fn_vector vector = (fn_vector)c_vector;
    // 该函数在主机是 4 个 float（HFA）按 SSE/AAPCS64 传递：
    // x86-64 走 xmm0/xmm1；AArch64 走 v0/v1。两种 ABI 下列表调用都必须一致。
    probe_vec v = { 1.0f, 2.0f, 3.0f, 4.0f };
    check(vector(v) == (int32_t)(1 + 4 + 9 + 16), "four-float HFA call");

    fn_callback cb = c_callback;
    check(cb(c_add, 1.0f, 2.0f) == 102, "callback call");
    // NVNboolean 按契约以 uint32_t 接收、只消费低 8 位；高 24 位垃圾不得改变结果。
    check(nvn_bool(0x1F201u) == 1 && nvn_bool(0x1F200u) == 0, "NVNboolean low-8-bit rule");

    fn_nvn_draw draw = c_nvn_draw;
    const float pos[3] = { 1.5f, 2.5f, 3.0f };
    got = draw((void *)0x1122334455667788ull, pos, 1.25f, 0x7F00FFu, 0x1FF,
               1, 2, 3, 4, 5, 6, 0.125f);
    want = 1 + 7 + 12 + 0xFF + 0xFF + 1 + 2 + 3 + 4 + 5 + 6 + 125;
    check(got == want, "nvn-style draw call");
}

int main(int argc, char **argv) {
    print_layout();
    check_validation();
    check_calls();
    if (argc > 1 && !strcmp(argv[1], "--quiet")) return g_failures ? 1 : 0;
    if (g_failures) { printf("direct-abi: %d FAILURES\n", g_failures); return 1; }
    printf("direct-abi: ok\n");
    return 0;
}
