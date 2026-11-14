// NVN2（Switch 2 的 NVN，SDK 20 起「spec: Ounce」）宿主侧：平台判别、设备值、着色器控制段的键规则。
// 只在 Switch 2 进程上生效（s2a_platform_ounce：原生层按 NPDM ACID 在 +0x300 认，runtime/src/svc_mem.c）；Switch 1 游戏走的每一条路径不变。
// 来源：参考实现（MIT）8dd0c98a / d3995ca4 / fdb3710d / c4b0618c 的 NVN2 部分，pokopia-native（MIT）对 Pokopia 的实测；见 docs/直连图形层_改动清单.md
#pragma once
#include <stdint.h>
#include <string.h>

int s2a_platform_ounce(void);   // 原生层导出；直连层单测不链原生层，nvn2.c 里有弱定义缺省 0
int nvn2_on(void);              // 本进程是 Switch 2 游戏（首次调用时读一次）

// ---------- 着色器控制段（GLSLC 0x00220015 输出，魔数 0x98761234、+4 版本 0xc9）----------
// 布局（the reference port docs/reference/shaders.md、pokopia-recomp AMPERE.md §3）：+0x20 起 16 字节着色器哈希，+0x30 控制段自身长度（文件 0xd8 / 0xe0，有的 0），
//   +0x44 代码区长度（游戏放进 GPU 内存、要哈希的那段：指令 + 填充，不含 0xe0 段尾的反射信息），+0x56 u16 阶段。控制段只有 0xd8 / 0xe0 字节，
//   Switch 1 的 +0x704 / 0x880 读法会读出控制段之外。
enum { NVN2_CTL_MAGIC = 0x98761234u, NVN2_CTL_VERSION = 0xc9u,
       NVN2_KEY_CTL = 0x48,     // 键哈希的控制段字节数：到代码长（+0x44）为止，不越过最短的控制段
       NVN2_CTL_COPY = 0xe0 };  // 控制段最长的字节数（有段尾时；DM_NVN_SHDUMP 存盘用）
static inline int nvn2_ctl(const void *control) {
    uint32_t m, v; memcpy(&m, control, 4); memcpy(&v, (const uint8_t *)control + 4, 4);
    return m == NVN2_CTL_MAGIC && v == NVN2_CTL_VERSION;
}
static inline uint32_t nvn2_code_len(const void *control) { uint32_t n; memcpy(&n, (const uint8_t *)control + 0x44, 4); return n; }
// 代码区里 Ampere 张量核矩阵乘（HMMA）的条数：Switch 2 机器码 16 字节一条，前 8 字节低 12 位 = 操作码，HMMA = 0x23c（后 8 字节是调度控制位，不看）。
//   直连层用它认出游戏自带的超分神经网络（nvn_tensor.inc）；Maxwell（Switch 1）没有这条指令，只对 NVN2 控制段的程序调
static inline unsigned nvn2_hmma_count(const void *code, uint32_t ncode) {
    unsigned n = 0; const uint8_t *c = (const uint8_t *)code;
    for (uint32_t o = 0; o + 16 <= ncode; o += 16) { uint64_t lo; memcpy(&lo, c + o, 8); if ((lo & 0xfff) == 0x23c) n++; }
    return n;
}
// 代码区里半精度「自己乘自己的绝对值」HMUL2 Rd, Ra, |Ra|（带符号平方 x·|x|）的条数。字段（InstEmitAmpereAlu.cs AHalfSrcs / InstEmitAmpere.cs AAluSrcs）：操作码 12 位 0x232
//   （低 9 位 0x032 = HMUL2、位 9..11 形式 1 = 寄存器 × 寄存器）；A = 位 24..31、B = 位 32..39（255 = RZ）；B 的取负 / 绝对值位 63 / 62、半字选择 60..61；
//   A 的取负 / 绝对值位 72 / 73、半字选择 74..75。计：A == B 且不是 RZ、两个半字选择相同、两边都不取负、恰好一边带绝对值。
//   直连层用它认张量核超分网络出口层的输出域（nvn_tensor.inc）：时之笛游玩时 5 支出口层各 32–36 条（读的低分辨率画面平方后加网络残差写出），标题画面 11 支网络 0 条
static inline unsigned nvn2_hsq_count(const void *code, uint32_t ncode) {
    unsigned n = 0; const uint8_t *c = (const uint8_t *)code;
    for (uint32_t o = 0; o + 16 <= ncode; o += 16) {
        uint64_t lo, hi; memcpy(&lo, c + o, 8); memcpy(&hi, c + o + 8, 8);
        if ((lo & 0xfff) != 0x232) continue;
        unsigned ra = (unsigned)(lo >> 24) & 0xff, rb = (unsigned)(lo >> 32) & 0xff;
        unsigned babs = (unsigned)(lo >> 62) & 1, bneg = (unsigned)(lo >> 63) & 1, bsw = (unsigned)(lo >> 60) & 3;
        unsigned aneg = (unsigned)(hi >> 8) & 1, aabs = (unsigned)(hi >> 9) & 1, asw = (unsigned)(hi >> 10) & 3;
        if (ra == rb && ra != 255 && asw == bsw && !aneg && !bneg && (aabs ^ babs)) n++;
    }
    return n;
}
// 代码区里半精度「与 sRGB 解码门限 0.04045 比较」HSETP2 Rd, Ra, 0.04045 的条数：操作码 12 位 0x434（低 9 位 0x034 = HSETP2、位 9..11 形式 2 = 寄存器 × 立即数），
//   立即数在位 32..63、两个半字都是 0x292d（fp16 0.04045）。sRGB → 线性（IEC 61966-2-1：x ≤ 0.04045 → x / 12.92，否则 ((x + 0.055) / 1.055)^2.4）的门限判断就是这一条，
//   同一段里还有 HMUL2 × 1/12.92（0x2cf5）、HFMA2 + 0.055/1.055（0x2aad）、MUFU LG2 / EX2 与 × 2.4。
//   直连层用它认张量核超分网络出口层的输出域（nvn_tensor.inc）：一款体育游戏 10 支出口层各 30–80 条（网络在 sRGB 域算、出口解码成线性写出），中间层 0 条
static inline unsigned nvn2_srgb_count(const void *code, uint32_t ncode) {
    unsigned n = 0; const uint8_t *c = (const uint8_t *)code;
    for (uint32_t o = 0; o + 16 <= ncode; o += 16) {
        uint64_t lo; memcpy(&lo, c + o, 8);
        if ((lo & 0xfff) == 0x434 && (uint32_t)(lo >> 32) == 0x292d292du) n++;
    }
    return n;
}
// 着色器键（直连库 / 映射表按它找，抽取器必须同一规则）：sha256(控制段前 0x48 字节，其中 +0x20..+0x27 与 +0x30..+0x33 按 0 ‖ 代码区前 (+0x44) 字节) 的前 8 字节。
//   +0x20..+0x27：pokopia-native 在 Pokopia 上实测，71 次请求里 6 次只差这 8 字节（运行时被改写）；+0x30：参考实现 在大金刚 Bananza 上实测，文件里是段长、
//   引擎自建的是 0。code = 代码区的 CPU 地址（NULL / 长度 0 = 只哈希控制段）。返回 1
int nvn2_key(const void *control, const void *code, uint8_t out[8]);

// ---------- 游戏 sdk 里 NVN2 驱动的设备信息常量（移植自 the reference port loader.c dm_sdk_nvn2_item，MIT）----------
// 驱动 nvnDeviceGetInteger 的 switch：先 mov w0, #231（主版本），再按字节表跳 —— cmp wN, #最后一项 / adr L / adrp + add T / ldrb / add, lsl #2 / br，前后 8 条指令内；
//   常量项是 mov w0, #v ; b。img = 模块映像（偏移 0 = 基址），在 [0, text_end) 里找代码，字节表须落在 [ro_lo, ro_hi)。认出返回 1 并填 *d
typedef struct { size_t at, table, cases; unsigned last; const uint8_t *img; size_t text_end; } nvn2_drv;
int nvn2_drv_scan(const uint8_t *img, size_t text_end, size_t ro_lo, size_t ro_hi, nvn2_drv *d);
// 该项是常量：返回 1、*out = 立即数；否则 0（项读别的：查表、读 GPU 描述）
int nvn2_drv_item(const nvn2_drv *d, unsigned item, int *out);

// ---------- nn::vi（显示层）----------
// Switch 2 直连档：游戏导入的 nn::vi 显示层函数由宿主答（sdk 的实现要 nn::gs 已启动，而直连档不启动它）；Switch 1 / 没接的名字回 NULL
void *nvn2_vi_entry(const char *name);

// ---------- 设备 ----------
// nvnDeviceGetInteger 的 NVN2 答复：处理了返回 1（*out 已填）；返回 0 = 交回 Switch 1 那张表（NVN2 运行时从 GPU 读的项，宿主照 X1 表）
int nvn2_device_integer(unsigned item, int *out);
// nvnDeviceInitialize 时调：贴图 GOB 内次序切到 Switch 2（gfx/tex/nvn_deswizzle.h nvn_gob_switch2），记一行日志
void nvn2_device_init(void);
void nvn2_vi_vsync_register(void *f);   // nvn2_codec.c 构造函数登记 vi::GetDisplayVsyncEvent 的实现（nvn2.c 不对视频解码有链接依赖）
void nvn2_sev_attach_register(uint64_t (*f)(void *sev, int autoclear));   // nvn2_codec.c 构造函数登记「宿主事件挂到游戏 SystemEvent」（nn::chat 的 Attach*ChangedEvent 用；同上，无链接依赖）

// ---------- 宿主做不到的 SDK 函数：红桩（nvn2.c）----------
// 回一个桩：装载时打红行，被调到就中止并点名 name 与 why（与 sdk 原路径同样中止，但可诊断）；同名复用一个槽，256 槽满回 NULL
void *nvn2_red(const char *name, const char *why);
const char *nvn2_red_of(const void *f);   // f 是红桩时回它的原因，否则 NULL（单测 / 覆盖率统计用）
void *s2a_nv_entry(const char *name);     // nv:: / streamplay 显示三个 / 其他命名空间依赖 gs 的函数（chat、camera、gpu、wsi、vi2、gsv…）

// ---------- nn::gs::sdk 的图形分配器与启动（与 nv:: 同一份状态；nvn2_codec.c 的 gs 接管用）----------
void nvn2_gs_allocator(void *out[4]);                            // {alloc, free, realloc, user}
void nvn2_gs_set_allocator(void *a, void *f, void *r, void *u);
void nvn2_gs_boot(void *mem, size_t size, const char *who);     // 记图形池、标「已启动」
void nvn2_gs_shutdown(void);
int nvn2_gs_booted(void);
