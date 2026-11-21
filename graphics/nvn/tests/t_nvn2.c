#include <stdatomic.h>
#include <time.h>
// nvn2.c（Switch 2 / NVN2 宿主侧）：着色器键规则、sdk 里 NVN2 驱动设备信息跳表的扫描、设备值、GOB 内次序。不需要 GPU / 游戏。
// 期望值不跑被测实现得出：键是 Python hashlib 按 nvn2.h 写的规则算的（命令见 K 段注释）；跳表指令按 ARMv8 编码手拼，期望就是拼进去的立即数；GOB 偏移手算
#include <stdio.h>
#include <string.h>
#include <stdlib.h>
#include <unistd.h>
#include <sys/wait.h>
#include "nvn2.h"
#include "nvn2_cmd.h"
#include "nvn_hdr_policy.h"   // PR3a 策略抽象（评审稿 v3 §2.3 / §4 PR3a）：hdr_snapshot + choose_mode + 层 tick / peak 纯函数 + nvn2_hdr_* 入口声明（实现随后一个提交给）
#include "../gfx/tex/nvn_deswizzle.h"
static unsigned checks;
#define CHECK(c) do { checks++; if (!(c)) { fprintf(stderr, "t_nvn2:%d 失败：%s\n", __LINE__, #c); exit(1); } } while (0)

// 本测试给原生层与 host_adapt.m 的两个接口（nvn2.c 里是弱定义）
int s2a_platform_ounce(void) { return 1; }
int dm_nvn2_driver_item(unsigned item, int *out) {   // 装作本游戏 sdk 的驱动：API 次版本 30、顶点绑定 32（宿主不跟）、其余不是常量
    if (item == 1) { *out = 30; return 1; }
    if (item == 0x06) { *out = 32; return 1; }
    return 0;
}

void *nvn2_vi_entry(const char *name);
// 红桩被调到：子进程里调，期望非正常退出（die 中止），父进程不受影响
static void *g_fake_sev; static int g_fake_autoclear = -1, g_fake_calls;
static uint64_t fake_sev_attach(void *sev, int autoclear) { g_fake_sev = sev; g_fake_autoclear = autoclear; g_fake_calls++; return 1; }
static int dies(void *f) { fflush(stdout); fflush(stderr); pid_t p = fork(); if (!p) { ((uint64_t (*)(void))f)(); _exit(0); } int st = 0; waitpid(p, &st, 0); return !(WIFEXITED(st) && WEXITSTATUS(st) == 0); }
// 子进程里按客人约定调别名建池（句柄值 1、个数 4）：信号 / 非 0 退出 = 「死了」（P1-145：句柄被当地址写）
static int dies_alias(uint64_t (*f)(uint16_t, uint32_t)) { fflush(stdout); fflush(stderr); pid_t p = fork(); if (!p) { f(1, 4); _exit(0); } int st = 0; waitpid(p, &st, 0); return !(WIFEXITED(st) && WEXITSTATUS(st) == 0); }
int dm_opmode(void) { const char *d = getenv("S2A_DOCKED"); return d && !strcmp(d, "1"); }   // 替身：同 graphics/nvn/host_adapt.m（宿主不链进本单测）

static uint8_t img[0x4000];
static void put(size_t o, uint32_t w) { memcpy(img + o, &w, 4); }
static size_t pc;
static void emit(uint32_t w) { put(pc, w); pc += 4; }
static uint32_t movz_w(int rd, int imm) { return 0x52800000u | (uint32_t)imm << 5 | (uint32_t)rd; }
static uint32_t cmp_w(int rn, int imm) { return 0x7100001fu | (uint32_t)imm << 10 | (uint32_t)rn << 5; }
static uint32_t adrp(int rd, size_t at, size_t target) { int64_t d = ((int64_t)(target & ~0xfffu) - (int64_t)(at & ~0xfffu)) >> 12; return 0x90000000u | ((uint32_t)d & 3) << 29 | ((uint32_t)(d >> 2) & 0x7ffff) << 5 | (uint32_t)rd; }
static uint32_t add_imm(int rd, int rn, int imm) { return 0x91000000u | (uint32_t)imm << 10 | (uint32_t)rn << 5 | (uint32_t)rd; }
static uint32_t adr(int rd, size_t at, size_t target) { int64_t d = (int64_t)target - (int64_t)at; return 0x10000000u | ((uint32_t)d & 3) << 29 | ((uint32_t)(d >> 2) & 0x7ffff) << 5 | (uint32_t)rd; }
static uint32_t b_fwd(int words) { return 0x14000000u | ((uint32_t)words & 0x3ffffff); }

int main(void) {
    // ---------- K 着色器键：sha256(ctl[0:0x48]，+0x20..+0x27 与 +0x30..+0x33 置 0 ‖ code[0:ctl+0x44]) 前 8 字节 ----------
    // ctl[i] = (i*7+3)&0xff，再写魔数 0x98761234、+4 = 0xc9、+0x44 = 64；code[i] = (i*13+5)&0xff，64 字节。Python 算的：
    //   k = bytearray(ctl[:0x48]); k[0x20:0x28] = bytes(8); k[0x30:0x34] = bytes(4); hashlib.sha256(bytes(k) + code).hexdigest()[:16] = 291eb4556e0fcc0c
    //   只哈希控制段（code 缺）= 6b89329b3062d5d6
    uint8_t ctl[0xe0], code[64], k[8], k2[8];
    for (int i = 0; i < 0xe0; i++) ctl[i] = (uint8_t)(i * 7 + 3);
    uint32_t v = NVN2_CTL_MAGIC; memcpy(ctl, &v, 4); v = NVN2_CTL_VERSION; memcpy(ctl + 4, &v, 4); v = 64; memcpy(ctl + 0x44, &v, 4);
    for (int i = 0; i < 64; i++) code[i] = (uint8_t)(i * 13 + 5);
    static const uint8_t want[8] = {0x29, 0x1e, 0xb4, 0x55, 0x6e, 0x0f, 0xcc, 0x0c}, want_ctl[8] = {0x6b, 0x89, 0x32, 0x9b, 0x30, 0x62, 0xd5, 0xd6};
    CHECK(nvn2_ctl(ctl) && nvn2_code_len(ctl) == 64);
    CHECK(nvn2_key(ctl, code, k) && !memcmp(k, want, 8));
    CHECK(nvn2_key(ctl, NULL, k2) && !memcmp(k2, want_ctl, 8));
    // 按 0 处理的字节、0x48 以后的字节不进键；+0x28、代码字节进键
    uint8_t c2[0xe0]; memcpy(c2, ctl, sizeof c2); memset(c2 + 0x20, 0xee, 8); memset(c2 + 0x30, 0xee, 4); memset(c2 + 0x48, 0xee, 0xe0 - 0x48);
    CHECK(nvn2_key(c2, code, k2) && !memcmp(k2, want, 8));
    memcpy(c2, ctl, sizeof c2); c2[0x28] ^= 1; CHECK(nvn2_key(c2, code, k2) && memcmp(k2, want, 8));
    code[63] ^= 1; CHECK(nvn2_key(ctl, code, k2) && memcmp(k2, want, 8)); code[63] ^= 1;
    // Switch 1 控制段（+4 = 1）不认作 NVN2
    memcpy(c2, ctl, sizeof c2); v = 1; memcpy(c2 + 4, &v, 4); CHECK(!nvn2_ctl(c2));

    // ---------- D sdk 里 NVN2 驱动的跳表 ----------
    // 代码在 0x100：cmp w1, #0xa9 ; b.hi ; adr x9, L ; adrp x10, T ; add x10, x10, #T ; ldrb w11, [x10, x1] ; mov w0, #231 ; add x9, x9, x11, lsl #2 ; br x9
    // L = 0x200：+0 ret（0 号：w0 已是 231）；+4 mov w0, #30 ; b（1 号）；+0xc ldr w0, [x8]（读别的）；+0x14 mov w0, #201 ; b（0x2E 号）。表 T = 0x3000（只读段 [0x3000, 0x4000)）
    pc = 0x100;
    emit(cmp_w(1, 0xa9)); emit(0x54000408u /* b.hi */); emit(adr(9, pc, 0x200)); emit(adrp(10, pc, 0x3000)); emit(add_imm(10, 10, 0));
    emit(0x38616942u | 0 /* ldrb w2, [x10, x1] */); emit(0x52801CE0u /* mov w0, #231 */); emit(0x8b020929u /* add x9, x9, x2, lsl #2 */); emit(0xd61f0120u /* br x9 */);
    pc = 0x200; emit(0xd65f03c0u); emit(movz_w(0, 30)); emit(b_fwd(8)); emit(0xb9400100u /* ldr w0, [x8] */); emit(0xd65f03c0u); emit(movz_w(0, 201)); emit(b_fwd(4));
    img[0x3000 + 0] = 0; img[0x3000 + 1] = 1; img[0x3000 + 0x17] = 3; img[0x3000 + 0x2E] = 5;
    nvn2_drv d; int out = -1;
    CHECK(nvn2_drv_scan(img, 0x3000, 0x3000, 0x4000, &d) && d.at == 0x118 && d.last == 0xa9 && d.table == 0x3000 && d.cases == 0x200);
    CHECK(nvn2_drv_item(&d, 1, &out) && out == 30);
    CHECK(nvn2_drv_item(&d, 0x2E, &out) && out == 201);
    CHECK(!nvn2_drv_item(&d, 0x17, &out) && !nvn2_drv_item(&d, 0, &out) && !nvn2_drv_item(&d, 0xaa, &out));
    // 表不在只读段里 = 不认
    CHECK(!nvn2_drv_scan(img, 0x3000, 0x3800, 0x4000, &d));

    // ---------- I 设备值 ----------
    CHECK(nvn2_device_integer(0, &out) && out == 231);
    CHECK(nvn2_device_integer(1, &out) && out == 30);          // 驱动常量
    CHECK(nvn2_device_integer(0x06, &out) && out == 16);       // 宿主 16 个顶点槽，不跟驱动的 32
    CHECK(nvn2_device_integer(0x2E, &out) && out == 201);      // 表里的 GPU 代码主版本（驱动这项不是常量）
    CHECK(!nvn2_device_integer(0x17, &out));                   // 运行时项、0x60 以下：交回 X1 表
    out = -1; CHECK(nvn2_device_integer(0x62, &out) && out == 0);   // 运行时项、0x60 以上：报红回 0
    CHECK(!nvn2_device_integer(0xAA, &out));                   // 表外：交回（X1 表报未知）

    // ---------- G GOB 内次序（Switch 2：x5 y2 x4 y1 y0）：(16,0) 64、(0,2) 32、(21,5) 128+64+16+5 = 213；X1 依次 32、64、181 ----------
    CHECK(nvn2_on());
    CHECK(nvn_bl_offset(16, 0, 0, 128, 32, 1, 0) == 32 && nvn_bl_offset(0, 2, 0, 128, 32, 1, 0) == 64 && nvn_bl_offset(21, 5, 0, 128, 32, 1, 0) == 181);
    nvn2_device_init();
    CHECK(nvn_gob_switch2 == 1);
    CHECK(nvn_bl_offset(16, 0, 0, 128, 32, 1, 0) == 64 && nvn_bl_offset(0, 2, 0, 128, 32, 1, 0) == 32 && nvn_bl_offset(21, 5, 0, 128, 32, 1, 0) == 213);
    CHECK(nvn_bl_offset(70, 9, 0, 128, 32, 1, 0) == 1558);   // 两位同为 1 / 同为 0：两种次序一致（块列 1024 + 块内 GOB 512 + 16 + 6）

    // ---------- N nv::（Switch 2 直连不进 nn::gs）：导入的三个名字接到宿主，别的名字回 NULL（照原路径）；初始化后 InitCheck 不中止 ----------
    void (*init)(void *, size_t) = (void (*)(void *, size_t))s2a_nv_entry("_ZN2nv18InitializeGraphicsEPvm");
    void (*check)(void) = (void (*)(void))s2a_nv_entry("_ZN2nv9InitCheckEv");
    CHECK(init && check && s2a_nv_entry("_ZN2nv20SetGraphicsAllocatorEPFPvmmS0_EPFvS0_S0_EPFS0_S0_mS0_ES0_"));
    CHECK(!s2a_nv_entry("nvnBootstrapLoader"));
    {   // streamplay 碰显示层的三个由宿主答：建客机画面回成功（0）、客机窗口回空、拆客机画面；其余 streamplay 函数不接（走 stpl:u）
        uint32_t (*disp)(int) = (uint32_t (*)(int))s2a_nv_entry("_ZN2nn10streamplay24CreateIndividualDisplaysEi");
        void *(*win)(int) = (void *(*)(int))s2a_nv_entry("_ZN2nn10streamplay21GetNativeWindowHandleENS0_7GuestIdE");
        CHECK(disp && win && disp(1) == 0 && win(0) == NULL && !s2a_nv_entry("_ZN2nn10streamplay8FinalizeEv"));
        CHECK(s2a_nv_entry("_ZN2nn10streamplay25DestroyIndividualDisplaysEv"));
    }
    static uint8_t pool[64]; init(pool, sizeof pool); check();
    // ---------- N2 nv:: 导出表 16 个全接（11-04 接口面全量）：分配器 Set → Get 读回同一份，调试工具分配器分开记；内存信息报游戏给的池（0x40 字节，已用 0）；
    //   Finalize 后「已启动」落下；IsCapableNoVsyncForDebug 回 0（sdk 实现读驱动状态，直连档中止）。期望值：Set 进去的指针 / 上面 init 给的 64 字节
    {
        static const char *const all16[] = { "_ZN2nv16FinalizeGraphicsEv", "_ZN2nv18InitializeGraphicsEv", "_ZN2nv20EnablePreemptionGFXPEv", "_ZN2nv22DumpGraphicsMemoryInfoEv",
            "_ZN2nv22SetGraphicsServiceNameEPKc", "_ZN2nv24IsCapableNoVsyncForDebugEv", "_ZN2nv26InitializeGraphicsDevtoolsEPvm", "_ZN2nv27EnableGraphicsMemoryTracingEv",
            "_ZN2nv28DisableGpuSemaAcquireTimeoutEv", "_ZN2nv21GetGraphicsMemoryInfoEPNS_10MemoryInfoE",
            "_ZN2nv20GetGraphicsAllocatorEPPFPvmmS0_EPPFvS0_S0_EPPFS0_S0_mS0_EPS0_", "_ZN2nv28SetGraphicsDevtoolsAllocatorEPFPvmmS0_EPFvS0_S0_EPFS0_S0_mS0_ES0_",
            "_ZN2nv28GetGraphicsDevtoolsAllocatorEPPFPvmmS0_EPPFvS0_S0_EPPFS0_S0_mS0_EPS0_" };
        for (unsigned i = 0; i < sizeof all16 / sizeof *all16; i++) CHECK(s2a_nv_entry(all16[i]) && !nvn2_red_of(s2a_nv_entry(all16[i])));
        void (*set)(void *, void *, void *, void *) = (void (*)(void *, void *, void *, void *))s2a_nv_entry("_ZN2nv20SetGraphicsAllocatorEPFPvmmS0_EPFvS0_S0_EPFS0_S0_mS0_ES0_");
        void (*get)(void **, void **, void **, void **) = (void (*)(void **, void **, void **, void **))s2a_nv_entry(all16[10]);
        void (*dset)(void *, void *, void *, void *) = (void (*)(void *, void *, void *, void *))s2a_nv_entry(all16[11]);
        void (*dget)(void **, void **, void **, void **) = (void (*)(void **, void **, void **, void **))s2a_nv_entry(all16[12]);
        int A, F, R, U, D;
        set(&A, &F, &R, &U); dset(&D, &D, &D, &D);
        void *a = 0, *f = 0, *r = 0, *u = 0; get(&a, &f, &r, &u); CHECK(a == &A && f == &F && r == &R && u == &U);
        dget(&a, &f, &r, &u); CHECK(a == &D && u == &D);
        void *o[4]; nvn2_gs_allocator(o); CHECK(o[0] == &A && o[3] == &U);   // gs::sdk 的分配器与 nv:: 同一份
        uint64_t mi[9]; memset(mi, 0x5a, sizeof mi);
        ((void (*)(uint64_t *))s2a_nv_entry(all16[9]))(mi);
        CHECK(mi[0] == sizeof pool && mi[1] == 0 && mi[2] == sizeof pool && mi[7] == 0 && mi[8] == 0x5a5a5a5a5a5a5a5aull);   // 写满 0x40、不越界
        CHECK(((uint32_t (*)(void))s2a_nv_entry(all16[5]))() == 0);
        CHECK(nvn2_gs_booted()); ((void (*)(void))s2a_nv_entry(all16[0]))(); CHECK(!nvn2_gs_booted());
        CHECK(dies((void *)check));   // Finalize 后 InitCheck 照 sdk 语义中止
        init(pool, sizeof pool); check();
    }
    // ---------- R 其他命名空间里依赖 gs / gsv / 驱动启动的函数：chat / camera Initialize 成功返回，其他红桩；同族不依赖的照原路径 ----------
    {
        // nn::chat「没在聊」：公开接口整组接管（11-09 #299 塞尔达无双封印战记——只接 Initialize、不建 sdk 服务对象时，Initialize 后任一公开接口读空对象虚表 SIGSEGV）。
        //   名单 = Splatoon Raiders sdk 的 nn::chat 公开导出（去掉 detail / gsv / 全局变量），共 66 个；屏幕共享替代图层单列（红桩）。期望按真机「没有会话」推，不读实现
        static const char *const chat_api[] = {
            "_ZN2nn4chat10InitializeEv",
            "_ZN2nn4chat8FinalizeEv",
            "_ZN2nn4chat30InitializeWithoutVirtualCameraEv",
            "_ZN2nn4chat28FinalizeWithoutVirtualCameraEv",
            "_ZN2nn4chat10IsChattingEv",
            "_ZN2nn4chat33AttachToChattingStateChangedEventEPNS_2os11SystemEventE",
            "_ZN2nn4chat14GetChattingUidEv",
            "_ZN2nn4chat20SetScreenSharingModeENS0_17ScreenSharingModeE",
            "_ZN2nn4chat11GetRoomInfoEPNS0_8RoomInfoE",
            "_ZN2nn4chat18GetRoomInfoForTestEPNS0_8RoomInfoE",
            "_ZN2nn4chat28AttachToRoomInfoChangedEventEPNS_2os11SystemEventE",
            "_ZN2nn4chat35AttachToRoomInfoChangedEventForTestEPNS_2os11SystemEventE",
            "_ZN2nn4chat28SetScreenSharingDisallowListEPKNS_7account23NetworkServiceAccountIdEi",
            "_ZN2nn4chat30ClearScreenSharingDisallowListEv",
            "_ZN2nn4chat22GetRealtimeAudioLevelsEPNS0_10AudioLevelEiPKNS_7account23NetworkServiceAccountIdEi",
            "_ZN2nn4chat42CalculateRequiredAudioStreamWorkBufferSizeEi",
            "_ZN2nn4chat27CreateAudioStreamWorkBufferEPvmi",
            "_ZN2nn4chat28DestroyAudioStreamWorkBufferEv",
            "_ZN2nn4chat32GetAudioStreamCapacityFrameCountEv",
            "_ZN2nn4chat25StartAudioStreamRecordingERKNS_7account23NetworkServiceAccountIdE",
            "_ZN2nn4chat24StopAudioStreamRecordingERKNS_7account23NetworkServiceAccountIdE",
            "_ZN2nn4chat28GetAudioStreamFreeFrameCountERKNS_7account23NetworkServiceAccountIdE",
            "_ZN2nn4chat30GetAudioStreamFilledFrameCountERKNS_7account23NetworkServiceAccountIdE",
            "_ZN2nn4chat15ReadAudioStreamEPmPvmRKNS_7account23NetworkServiceAccountIdE",
            "_ZN2nn4chat33GetLocalCameraImageProcessingModeEPNS0_25CameraImageProcessingModeE",
            "_ZN2nn4chat54GetLocalCameraImageProcessingMode_Deprecated_OAAA51548EPNS0_25CameraImageProcessingModeE",
            "_ZN2nn4chat50AttachToLocalCameraImageProcessingModeChangedEventEPNS_2os11SystemEventE",
            "_ZN2nn4chat71AttachToLocalCameraImageProcessingModeChangedEvent_Deprecated_OAAA51548EPNS_2os11SystemEventE",
            "_ZN2nn4chat31SetLocalCameraZoomMagnificationEf",
            "_ZN2nn4chat31GetLocalCameraZoomMagnificationEv",
            "_ZN2nn4chat48AttachToLocalCameraZoomMagnificationChangedEventEPNS_2os11SystemEventE",
            "_ZN2nn4chat13SetSharingKeyERKNS0_10SharingKeyE",
            "_ZN2nn4chat15ClearSharingKeyEv",
            "_ZN2nn4chat13ShowChatStartERKNS_7account3UidE",
            "_ZN2nn4chat22ShowCameraSharingGuideEv",
            "_ZN2nn4chat28ShowLocalCameraConfigurationENS0_25CameraImageProcessingModeE",
            "_ZN2nn4chat36ShowLocalCameraConfigurationVersion0ENS0_25CameraImageProcessingModeE",
            "_ZN2nn4chat46BeginFullScreenWithLocalCameraAvailableSectionEbb",
            "_ZN2nn4chat46BeginFullScreenWithLocalCameraAvailableSectionEb",
            "_ZN2nn4chat44EndFullScreenWithLocalCameraAvailableSectionEv",
            "_ZN2nn4chat25StartLocalCameraStreamingEv",
            "_ZN2nn4chat24StopLocalCameraStreamingEv",
            "_ZN2nn4chat35CalculateLocalCameraVideoBufferSizeEiii",
            "_ZN2nn4chat33InitializeLocalCameraVideoStorageEPNS0_20LocalCameraVideoTypeEiiiPvm",
            "_ZN2nn4chat31FinalizeLocalCameraVideoStorageEPNS0_20LocalCameraVideoTypeE",
            "_ZN2nn4chat25GetLocalCameraImageHandleEPKNS0_20LocalCameraVideoTypeEi",
            "_ZN2nn4chat27RequestNextLocalCameraImageEPNS_2gs16NativeSyncHandleEPNS0_20LocalCameraVideoTypeEiS2_",
            "_ZN2nn4chat26StartRemoteCameraStreamingERKNS_7account23NetworkServiceAccountIdE",
            "_ZN2nn4chat33StartRemoteCameraStreamingForTestERKNS_7account23NetworkServiceAccountIdE",
            "_ZN2nn4chat25StopRemoteCameraStreamingERKNS_7account23NetworkServiceAccountIdE",
            "_ZN2nn4chat32StopRemoteCameraStreamingForTestERKNS_7account23NetworkServiceAccountIdE",
            "_ZN2nn4chat36CalculateRemoteCameraVideoBufferSizeEiii",
            "_ZN2nn4chat34InitializeRemoteCameraVideoStorageEPNS0_21RemoteCameraVideoTypeEiiiPvm",
            "_ZN2nn4chat32FinalizeRemoteCameraVideoStorageEPNS0_21RemoteCameraVideoTypeE",
            "_ZN2nn4chat26GetRemoteCameraImageHandleEPKNS0_21RemoteCameraVideoTypeEi",
            "_ZN2nn4chat28RequestNextRemoteCameraImageEPNS_2gs16NativeSyncHandleEPNS0_21RemoteCameraVideoTypeEiS2_RKNS_7account23NetworkServiceAccountIdE",
            "_ZN2nn4chat39SetAlternativeScreenSharingLayerEnabledEb",
            "_ZN2nn4chat23InitializeVirtualCameraEPNS0_17VirtualCameraTypeE",
            "_ZN2nn4chat21FinalizeVirtualCameraEPNS0_17VirtualCameraTypeE",
            "_ZN2nn4chat34GetVirtualCameraNativeWindowHandleEPKNS0_17VirtualCameraTypeE",
            "_ZN2nn4chat19EnableVirtualCameraEPNS0_17VirtualCameraTypeE",
            "_ZN2nn4chat20DisableVirtualCameraEPNS0_17VirtualCameraTypeE",
            "_ZN2nn4chat43SetVirtualCameraContainPhotographedContentsEPNS0_17VirtualCameraTypeEb",
            "_ZN2nn4chat44GetCameraImageProcessingModeForVirtualCameraEv",
            "_ZN2nn4chat61AttachToCameraImageProcessingModeForVirtualCameraChangedEventEPNS_2os11SystemEventE"
        };
        CHECK(sizeof chat_api / sizeof *chat_api == 65);
        {   // #116 摄像头视频存储：没登记实现（本单测不链 nvn2_codec.c）时照「没在聊」回 0；登记后 chat_entry 交的就是登记的那四个
            uint64_t (*sz0)(int, int, int) = (uint64_t (*)(int, int, int))s2a_nv_entry("_ZN2nn4chat35CalculateLocalCameraVideoBufferSizeEiii");
            CHECK(sz0 && sz0(384, 216, 4) == 0);
            void nvn2_chat_video_register(void *, void *, void *, void *);   // nvn2.c（声明不放 nvn2.h）
            static int fake;
            nvn2_chat_video_register(&fake, &fake + 1, &fake + 2, &fake + 3);
            CHECK(s2a_nv_entry("_ZN2nn4chat36CalculateRemoteCameraVideoBufferSizeEiii") == (void *)&fake);
            CHECK(s2a_nv_entry("_ZN2nn4chat33InitializeLocalCameraVideoStorageEPNS0_20LocalCameraVideoTypeEiiiPvm") == (void *)(&fake + 1));
            CHECK(s2a_nv_entry("_ZN2nn4chat32FinalizeRemoteCameraVideoStorageEPNS0_21RemoteCameraVideoTypeE") == (void *)(&fake + 2));
            CHECK(s2a_nv_entry("_ZN2nn4chat25GetLocalCameraImageHandleEPKNS0_20LocalCameraVideoTypeEi") == (void *)(&fake + 3));
            nvn2_chat_video_register(NULL, NULL, NULL, NULL);
        }
        for (unsigned i = 0; i < sizeof chat_api / sizeof *chat_api; i++) {
            void *f = s2a_nv_entry(chat_api[i]);
            int attach = strstr(chat_api[i], "AttachTo") != NULL;
            if (attach) CHECK(!f);   // 事件工具没登记（本单测不链 nvn2_codec.c）：Attach 这一族不接管
            else { if (!f || nvn2_red_of(f)) fprintf(stderr, "t_nvn2: chat 漏接 %s\n", chat_api[i]); CHECK(f && !nvn2_red_of(f)); }
        }
        uint64_t (*ci)(void) = (uint64_t (*)(void))s2a_nv_entry("_ZN2nn4chat10InitializeEv");
        uint64_t (*ci2)(void) = (uint64_t (*)(void))s2a_nv_entry("_ZN2nn4chat30InitializeWithoutVirtualCameraEv");
        CHECK(ci && ci2 && ci() == 0 && ci2() == 0 && !dies((void *)ci));   // 成功返回，不中止
        // 玩家崩点同形态的 7 个接口（同版 sdk 里「锁后 +0x14 处读空对象虚表」的全部）：都拿到「没有会话」的真实空值、不读空对象
        uint8_t room[0x100];
        uint64_t (*gri)(void *) = (uint64_t (*)(void *))s2a_nv_entry("_ZN2nn4chat11GetRoomInfoEPNS0_8RoomInfoE");
        uint64_t (*grt)(void *) = (uint64_t (*)(void *))s2a_nv_entry("_ZN2nn4chat18GetRoomInfoForTestEPNS0_8RoomInfoE");
        for (int k = 0; k < 2; k++) {
            memset(room, 0xEE, sizeof room);
            CHECK((k ? grt : gri)(room) == 0);
            int zero = 1; for (int i = 0; i < 0xF0; i++) zero &= room[i] == 0;
            CHECK(zero && room[0xF0] == 0xEE);   // RoomInfo 0xF0 字节全 0（没有房间），界外不动
        }
        uint8_t mode[2];
        uint64_t (*gm)(void *) = (uint64_t (*)(void *))s2a_nv_entry("_ZN2nn4chat33GetLocalCameraImageProcessingModeEPNS0_25CameraImageProcessingModeE");
        uint64_t (*gmd)(void *) = (uint64_t (*)(void *))s2a_nv_entry("_ZN2nn4chat54GetLocalCameraImageProcessingMode_Deprecated_OAAA51548EPNS0_25CameraImageProcessingModeE");
        memset(mode, 0xEE, 2); CHECK(gm(mode) == 0 && mode[0] == 0 && mode[1] == 0xEE);    // 出参 1 字节（代理模板 strb）
        memset(mode, 0xEE, 2); CHECK(gmd(mode) == 0 && mode[0] == 0 && mode[1] == 0xEE);
        uint64_t (*szoom)(float) = (uint64_t (*)(float))s2a_nv_entry("_ZN2nn4chat31SetLocalCameraZoomMagnificationEf");
        uint64_t (*smode)(int) = (uint64_t (*)(int))s2a_nv_entry("_ZN2nn4chat20SetScreenSharingModeENS0_17ScreenSharingModeE");
        uint64_t (*skey)(const void *) = (uint64_t (*)(const void *))s2a_nv_entry("_ZN2nn4chat13SetSharingKeyERKNS0_10SharingKeyE");
        uint64_t key = 0x1122334455667788ull;
        CHECK(szoom(2.0f) == 0 && smode(1) == 0 && skey(&key) == 0);
        // 其余有返回值的：没在聊（Uid 全 0、IsChatting 假）、缩放 1.0
        typedef struct { uint64_t lo, hi; } uid_t2;   // nn::account::Uid：16 字节，x0 / x1 返回
        uid_t2 (*uid)(void) = (uid_t2 (*)(void))s2a_nv_entry("_ZN2nn4chat14GetChattingUidEv");
        CHECK(uid().lo == 0 && uid().hi == 0);
        CHECK(((uint64_t (*)(void))s2a_nv_entry("_ZN2nn4chat10IsChattingEv"))() == 0);
        CHECK(((float (*)(void))s2a_nv_entry("_ZN2nn4chat31GetLocalCameraZoomMagnificationEv"))() == 1.0f);
        uint64_t got = 7; CHECK(((uint64_t (*)(uint64_t *, void *, uint64_t, const void *))s2a_nv_entry("_ZN2nn4chat15ReadAudioStreamEPmPvmRKNS_7account23NetworkServiceAccountIdE"))(&got, room, 16, &key) == 0 && got == 0);
        // Attach*ChangedEvent：登记事件工具后接管，把游戏的 SystemEvent 交给它（手动清除）
        nvn2_sev_attach_register(fake_sev_attach);
        void (*at)(void *) = (void (*)(void *))s2a_nv_entry("_ZN2nn4chat33AttachToChattingStateChangedEventEPNS_2os11SystemEventE");
        uint8_t sev[0x30]; CHECK(at && !nvn2_red_of((void *)at)); at(sev); CHECK(g_fake_sev == sev && g_fake_autoclear == 0 && g_fake_calls == 1);
        nvn2_sev_attach_register(NULL);
        // 不接管的：屏幕共享替代图层（红桩点名）、gsv / detail 内部入口（红桩）；认不得的新名字交回原路径（红行提示补表）
        void *alt = s2a_nv_entry("_ZN2nn4chat35CreateAlternativeScreenSharingLayerEPPNS_2vi5LayerEPNS1_7DisplayEPKNS1_21LayerCreationSettingsE");
        void *ius = s2a_nv_entry("_ZN2nn4chat6detail21InitializeUserServiceEv");
        CHECK(alt && nvn2_red_of(alt) && ius && nvn2_red_of(ius) && !s2a_nv_entry("_ZN2nn4chat9FutureApiEv"));
        // camera CalculateImageArraySize：输出参数写 0
        void (*cam_calc)(void *, void *, const void *, uint32_t) = (void (*)(void *, void *, const void *, uint32_t))s2a_nv_entry("_ZN2nn6camera3sdk23CalculateImageArraySizeEPNS_3gsv10MemorySizeES4_RKNS2_25CameraUserImagePreferenceEj");
        CHECK(cam_calc && !nvn2_red_of(cam_calc));
        uint64_t sz = 0x5a5a5a5a5a5a5a5aull, al = 0x5a5a5a5a5a5a5a5aull; cam_calc(&sz, &al, NULL, 1); CHECK(sz == 0 && al == 0);
        // camera CreateOutputBufferPool：输出参数写 0（无效句柄）
        void (*cam_pool)(void *, const void *, uint32_t, void *) = (void (*)(void *, const void *, uint32_t, void *))s2a_nv_entry("_ZN2nn6camera3sdk22CreateOutputBufferPoolEPNS_3gsv15UserImageHandleERKNS2_25CameraUserImagePreferenceEjNS2_16UserMemoryHandleE");
        CHECK(cam_pool && !nvn2_red_of(cam_pool));
        uint16_t h = 0x5a5a; cam_pool(&h, NULL, 0, NULL); CHECK(h == 0);
        // camera Destroy：空操作（不中止）
        void (*cam_del)(uint16_t) = (void (*)(uint16_t))s2a_nv_entry("_ZN2nn6camera3sdk23DestroyOutputBufferPoolENS_3gsv15UserImageHandleE");
        CHECK(cam_del && !nvn2_red_of(cam_del)); cam_del(0);
        // camera CreateAliasOutputBufferPool(UserImageHandle, unsigned)：句柄按值。按客人约定传句柄 1：不当地址写（原先写地址 1 → 信号 11，审计 P1-145），回 0
        uint64_t (*cam_alias)(uint16_t, uint32_t) = (uint64_t (*)(uint16_t, uint32_t))s2a_nv_entry("_ZN2nn6camera3sdk27CreateAliasOutputBufferPoolENS_3gsv15UserImageHandleEj");
        CHECK(cam_alias && !nvn2_red_of(cam_alias)); CHECK(!dies_alias(cam_alias)); CHECK(cam_alias(1, 4) == 0);
        // camera CreateCameraContext：输出参数是 32 位句柄，只写 4 字节；服务层没链（本单测）时句柄 0
        void (*cam_ctx)(uint32_t *) = (void (*)(uint32_t *))s2a_nv_entry("_ZN2nn6camera3sdk19CreateCameraContextEPNS_5gsdrv18UniqueNativeHandleE");
        CHECK(cam_ctx && !nvn2_red_of(cam_ctx));
        uint32_t ch[2] = {0x5a5a, 0xa5a5}; cam_ctx(ch); CHECK(ch[0] == 0 && ch[1] == 0xa5a5);
        // 其他 chat / camera 接口仍是红桩
        void *cg = s2a_nv_entry("_ZN2nn4chat3gsv10InitializeEv");
        CHECK(cg && nvn2_red_of(cg) && strstr(nvn2_red_of(cg), "GameChat"));
        // 其他红桩
        void *nr = s2a_nv_entry("NvRmChannelOpen"), *vi2 = s2a_nv_entry("_ZN2nn3vi23sdk10InitializeEv");
        void *gb = s2a_nv_entry("_ZN2nn3gsv4shim6detail33InitializeInterModuleImageContextEv"), *mm = s2a_nv_entry("_ZN2nn5album28InitializeMovieMakerInternalEONS_2sf13SharedPointerINS_6grcsrv11IMovieMakerEEEm");
        CHECK(nr && vi2 && gb && mm);
        CHECK(nvn2_red_of(nr) && strstr(nvn2_red_of(nr), "NVIDIA") && nvn2_red_of(gb) && nvn2_red_of(mm));
        CHECK(nr != vi2);                                                           // 不同名不同桩（被调到时点得出是谁）
        CHECK(dies(nr));
        // 负对照：没有「原路径必中止」实证的照原路径——album 截图、火纹 CUDA 模块导入的 NvRmGpuLibOpen（模拟执行没进 nv::InitCheck）、
        //   gsv 的 IsInitialized 与 BootWithTransferMemory（只是直读会话全局量、调用图可达）、album::InitializeMovieMaker（调用图直达 gs Check、模拟执行没进）
        CHECK(!s2a_nv_entry("_ZN2nn3gsv22BootWithTransferMemoryENS0_12MemoryRegionEPvm") && !s2a_nv_entry("_ZN2nn5album20InitializeMovieMakerEPvm"));
        CHECK(!s2a_nv_entry("_ZN2nn5album14SaveScreenshotEPKvmNS0_9ImageSizeENS0_17AlbumReportOptionE")
              && !s2a_nv_entry("NvRmGpuLibOpen") && !s2a_nv_entry("_ZN2nn3gsv13IsInitializedEv") && !s2a_nv_entry("_ZN2nn2os9LockMutexEPNS0_9MutexTypeE"));
    }

    // ---------- V nn::vi（Switch 2 直连档宿主答）：显示 / 图层 / 原生窗口都给非空句柄，结果码 0；没接的名字回 NULL ----------
    uint32_t (*open)(void **) = (uint32_t (*)(void **))nvn2_vi_entry("_ZN2nn2vi18OpenDefaultDisplayEPPNS0_7DisplayE");
    uint32_t (*mk)(void **, void *) = (uint32_t (*)(void **, void *))nvn2_vi_entry("_ZN2nn2vi11CreateLayerEPPNS0_5LayerEPNS0_7DisplayE");
    uint32_t (*nw)(void **, void *) = (uint32_t (*)(void **, void *))nvn2_vi_entry("_ZN2nn2vi15GetNativeWindowEPPvPNS0_5LayerE");
    CHECK(open && mk && nw && nvn2_vi_entry("_ZN2nn2vi10InitializeEv") && nvn2_vi_entry("_ZN2nn2vi8FinalizeEv"));
    void *dp = NULL, *ly = NULL, *win = NULL;
    CHECK(open(&dp) == 0 && dp && mk(&ly, dp) == 0 && ly && nw(&win, ly) == 0 && win);
    CHECK(!nvn2_vi_entry("_ZN2nn2vi12ListDisplaysEPNS0_11DisplayInfoEi"));   // 纯函数（sdk 直接写「Default」一项），照原路径
    // ---------- V2 nn::vi 公有函数全量（11-04）：句柄族——显示 / 图层是宿主静态对象，sdk 会拿它和自己的 DefaultDisplay 比（不是就 0x272）或当 vi2 图层转发（跳空）----------
    {
        uint32_t (*opn)(void **, const char *) = (uint32_t (*)(void **, const char *))nvn2_vi_entry("_ZN2nn2vi11OpenDisplayEPPNS0_7DisplayEPKc");
        void *d2 = (void *)1; CHECK(opn && opn(&d2, "default") == 0 && d2 == dp);                 // 大小写不敏感（sdk strcasecmp），同一个默认显示
        d2 = (void *)1; CHECK(opn(&d2, "External") == 0xe72 && d2 == NULL);                       // sdk 对不认识的名字回 0xe72（火纹 sdk+0x5dfa7c）
        uint32_t (*mkwh)(void **, void *, int, int) = (uint32_t (*)(void **, void *, int, int))nvn2_vi_entry("_ZN2nn2vi11CreateLayerEPPNS0_5LayerEPNS0_7DisplayEii");
        uint32_t (*mkcs)(void **, void *, const int32_t *) = (uint32_t (*)(void **, void *, const int32_t *))nvn2_vi_entry("_ZN2nn2vi11CreateLayerEPPNS0_5LayerEPNS0_7DisplayEPKNS0_21LayerCreationSettingsE");
        void *l2 = NULL, *l3 = NULL; static const int32_t cs[3] = {1920, 1080, 2};
        CHECK(mkwh && mkcs && mkwh(&l2, dp, 1280, 720) == 0 && l2 == ly && mkcs(&l3, dp, cs) == 0 && l3 == ly);
        uint32_t (*shr)(void **, void *, const void *) = (uint32_t (*)(void **, void *, const void *))nvn2_vi_entry("_ZN2nn2vi18CreateSharingLayerEPPNS0_5LayerEPNS0_7DisplayEPKNS0_21LayerCreationSettingsE");
        l2 = (void *)1; CHECK(shr && shr(&l2, dp, cs) != 0 && l2 == NULL);                          // 宿主不串流：没有共享图层，回失败不给假图层
        uint32_t (*rr)(uint32_t *, const void *) = (uint32_t (*)(uint32_t *, const void *))nvn2_vi_entry("_ZN2nn2vi30QueryDisplayCurrentRefreshRateEPNS0_11RefreshRateEPKNS0_7DisplayE");
        uint32_t (*rr2)(uint32_t *, uint8_t *, const void *) = (uint32_t (*)(uint32_t *, uint8_t *, const void *))nvn2_vi_entry("_ZN2nn2vi30QueryDisplayCurrentRefreshRateEPNS0_11RefreshRateEPbPKNS0_7DisplayE");
        uint32_t hz = 0; uint8_t vrr = 9; CHECK(rr && rr(&hz, dp) == 0 && hz == 60 && rr2 && rr2(&hz, &vrr, dp) == 0 && hz == 60 && vrr == 0);
        uint32_t (*av)(int *, void *, int, void *) = (uint32_t (*)(int *, void *, int, void *))nvn2_vi_entry("_ZN2nn2vi33QueryDisplayAvailableRefreshRatesEPiPNS0_20AvailableRefreshRateEiPNS0_7DisplayE");
        int nav = 7; uint8_t avb[0x38]; CHECK(av && av(&nav, avb, 1, dp) != 0 && nav == 0);   // 表项布局未全核：回失败，不编
        uint32_t (*fno)(uint64_t *, const void *) = (uint32_t (*)(uint64_t *, const void *))nvn2_vi_entry("_ZN2nn2vi20GetLatestFrameNumberEPmPKNS0_5LayerE");
        uint64_t fn = 9; CHECK(fno && fno(&fn, ly) == 0 && fn == 0);                              // 单测不链 hle_nvn：帧数弱定义 0
        CHECK(((void *(*)(const void *))nvn2_vi_entry("_ZN2nn2vi16GetInternalLayerEPKNS0_5LayerE"))(ly) == NULL);
        CHECK(nvn2_vi_entry("_ZN2nn2vi27InitializeWithVrrLfcEnabledEv"));   // void，同 Initialize
        static const char *const ok0[] = { "_ZN2nn2vi23SetDisplayHdrCapabilityEPNS0_7DisplayEb", "_ZN2nn2vi36SetDisplay120HzRefreshRateCapabilityEPNS0_7DisplayEb",
            "_ZN2nn2vi39SetLayerNextHdrAdjustableBezierMetadataEPNS0_5LayerEfff", "_ZN2nn2vi41ClearLayerNextHdrAdjustableBezierMetadataEPNS0_5LayerE", "_ZN2nn2vi37ClearLayerNextHdrContentGamutMetadataEPNS0_5LayerE",
            "_ZN2nn2vi30InitializeCopyrightFramebufferEPvm", "_ZN2nn2vi27WriteToCopyrightFramebufferEPKvmiiiiNS0_10OriginModeE", "_ZN2nn2vi16ListFrameHistoryEPNS0_9FrameInfoEiPKNS0_5LayerE",
            "_ZN2nn2vi16SetLayerUserDataEPNS0_5LayerEm" };
        for (unsigned i = 0; i < sizeof ok0 / sizeof *ok0; i++) { void *f = nvn2_vi_entry(ok0[i]); CHECK(f && !nvn2_red_of(f) && ((uint32_t (*)(void *, uint64_t, uint64_t))f)(ly, 0, 0) == 0); }
        // LayerCreationSettings 纯值对象、Set*LayerEnabled 转 am 服务：照原路径
        //   类成员 / detail：没有原路径必中止的实证，不做红桩，照原路径（打红行）
        CHECK(!nvn2_vi_entry("_ZN2nn2vi5Layer4OpenEPKNS0_21LayerCreationSettingsEPNS0_7DisplayEPKc") && !nvn2_vi_entry("_ZN2nn2vi6detail14DefaultDisplay3GetEv"));
        CHECK(!nvn2_vi_entry("_ZN2nn2vi21LayerCreationSettings8SetWidthEi") && !nvn2_vi_entry("_ZN2nn2vi22SetSharingLayerEnabledEb"));
    }
    // 火纹的 nn::vi：显示最大缓冲按档位（掌机 1 = 1080p、主机 3 = 4K；回 0 游戏按 720p 出图）、HDR 关、VRR / 扩展交换间隔 / 色域元数据都接管
    uint32_t (*mr)(uint32_t *, const void *) = (uint32_t (*)(uint32_t *, const void *))nvn2_vi_entry("_ZN2nn2vi31QueryDisplayBufferMaxResolutionEPNS0_19BufferMaxResolutionEPKNS0_7DisplayE");
    uint32_t (*hs)(uint8_t *, uint32_t *, uint16_t *, const void *) = (uint32_t (*)(uint8_t *, uint32_t *, uint16_t *, const void *))nvn2_vi_entry("_ZN2nn2vi21QueryDisplayHdrStatusEPbPNS0_15HdrOutputFormatEPtPKNS0_7DisplayE");
    CHECK(mr && hs && nvn2_vi_entry("_ZN2nn2vi25QueryDisplayHdrPaperWhiteEPtPKNS0_7DisplayE") && nvn2_vi_entry("_ZN2nn2vi24QueryDisplayVrrSupportedEPbPKNS0_7DisplayE")
          && nvn2_vi_entry("_ZN2nn2vi28SetLayerExtendedSwapIntervalEPNS0_5LayerEii") && nvn2_vi_entry("_ZN2nn2vi30ClearLayerExtendedSwapIntervalEPNS0_5LayerE")
          && nvn2_vi_entry("_ZN2nn2vi35SetLayerNextHdrContentGamutMetadataEPNS0_5LayerENS0_15HdrContentGamutE"));
    uint32_t res = 0xff; unsetenv("S2A_DOCKED"); CHECK(mr(&res, dp) == 0 && res == 1);
    setenv("S2A_DOCKED", "1", 1); res = 0xff; CHECK(mr(&res, dp) == 0 && res == 3); unsetenv("S2A_DOCKED");
    uint8_t on = 1; uint32_t fmt = 9; uint16_t peak = 9; CHECK(hs(&on, &fmt, &peak, dp) == 0 && on == 0 && fmt == 0 && peak == 0);
    // 金刚 / raiders 的 nn::vi（11-04）：HDR → SDR 色调映射元数据回成功
    uint32_t (*tm)(void *, int) = (uint32_t (*)(void *, int))nvn2_vi_entry("_ZN2nn2vi39SetLayerNextHdrToSdrToneMappingMetadataEPNS0_5LayerENS0_14HdrToneMappingE");
    CHECK(tm && tm(ly, 1) == 0 && nvn2_vi_entry("_ZN2nn2vi41ClearLayerNextHdrToSdrToneMappingMetadataEPNS0_5LayerE"));
    // 显示 vsync 事件的实现在 nvn2_codec.c（弱引用）：本单测不链 codec → 这个名字回落（宿主没接管，红行），实现与触发在 t_nvn2_codec 里测
    CHECK(!nvn2_vi_entry("_ZN2nn2vi20GetDisplayVsyncEventEPNS_2os15SystemEventTypeEPNS0_7DisplayE"));
    // ---------- V3 PR1 探针（HDR 元数据接收即存储；查询回答不变）：Set* 已知值 → 探针读数逐项相等 → Clear 恢复默认 ----------
    //   读数接口 nvn2_vi_hdr_probe 在 nvn2.c（声明不放 nvn2.h，同 nvn2_chat_video_register）：main 上没有实现（链接红），PR1 上绿
    {
        void nvn2_vi_hdr_probe(unsigned *cap, unsigned *lo, unsigned *hi, int *gamut, int *tonemap, float bez[3]);
        uint32_t (*cap1)(void *, unsigned) = (uint32_t (*)(void *, unsigned))nvn2_vi_entry("_ZN2nn2vi23SetDisplayHdrCapabilityEPNS0_7DisplayEb");
        uint32_t (*lumx)(void *, unsigned, unsigned) = (uint32_t (*)(void *, unsigned, unsigned))nvn2_vi_entry("_ZN2nn2vi52SetLayerNextHdrExtendedContentLuminanceRangeMetadataEPNS0_5LayerEtt");
        uint32_t (*lums)(void *, unsigned, unsigned) = (uint32_t (*)(void *, unsigned, unsigned))nvn2_vi_entry("_ZN2nn2vi52SetLayerNextHdrStandardContentLuminanceRangeMetadataEPNS0_5LayerEtt");
        uint32_t (*gam)(void *, int) = (uint32_t (*)(void *, int))nvn2_vi_entry("_ZN2nn2vi35SetLayerNextHdrContentGamutMetadataEPNS0_5LayerENS0_15HdrContentGamutE");
        uint32_t (*tms)(void *, int) = (uint32_t (*)(void *, int))nvn2_vi_entry("_ZN2nn2vi39SetLayerNextHdrToSdrToneMappingMetadataEPNS0_5LayerENS0_14HdrToneMappingE");
        uint32_t (*bez)(void *, float, float, float) = (uint32_t (*)(void *, float, float, float))nvn2_vi_entry("_ZN2nn2vi39SetLayerNextHdrAdjustableBezierMetadataEPNS0_5LayerEfff");
        uint32_t (*clr)(void *) = (uint32_t (*)(void *))nvn2_vi_entry("_ZN2nn2vi37ClearLayerNextHdrContentGamutMetadataEPNS0_5LayerE");
        CHECK(cap1 && lumx && lums && gam && tms && bez && clr);
        unsigned pr1_cap = 9, pr1_lo = 9, pr1_hi = 9; int pr1_g = 9, pr1_m = 9; float pr1_bez[3] = {9, 9, 9};
        // V2 段的泛型循环 / tonemap 试调已把探针写脏（bezier 那条经整型实参调，浮点寄存器是垃圾值）：先整组清回默认，从这里开始断言
        CHECK(clr(ly) == 0);
        nvn2_vi_hdr_probe(&pr1_cap, &pr1_lo, &pr1_hi, &pr1_g, &pr1_m, pr1_bez);
        CHECK(pr1_cap == 0 && pr1_lo == 0 && pr1_hi == 0 && pr1_g == 0 && pr1_m == 0 && pr1_bez[0] == 0 && pr1_bez[1] == 0 && pr1_bez[2] == 0);   // PR1 探针：清过之后缺省全 0
        CHECK(cap1(dp, 1) == 0 && lumx(ly, 1000, 400) == 0);
        pr1_lo = 9; pr1_hi = 9; nvn2_vi_hdr_probe(&pr1_cap, &pr1_lo, &pr1_hi, &pr1_g, &pr1_m, pr1_bez);
        CHECK(pr1_cap == 1 && pr1_lo == 1000 && pr1_hi == 400);   // PR1 探针：SetDisplayHdrCapability(1) 与 Extended 亮度范围存进
        CHECK(lums(ly, 100, 320) == 0);
        pr1_lo = 9; pr1_hi = 9; nvn2_vi_hdr_probe(&pr1_cap, &pr1_lo, &pr1_hi, &pr1_g, &pr1_m, pr1_bez);
        CHECK(pr1_lo == 100 && pr1_hi == 320);                    // PR1 探针：Standard 亮度范围盖写同一对（两个注册名一个存储槽）
        CHECK(gam(ly, 2) == 0 && tms(ly, 3) == 0 && bez(ly, 0.25f, 0.5f, 0.75f) == 0);
        pr1_cap = 9; pr1_lo = 9; pr1_hi = 9; pr1_g = 9; pr1_m = 9; pr1_bez[0] = pr1_bez[1] = pr1_bez[2] = 9;
        nvn2_vi_hdr_probe(&pr1_cap, &pr1_lo, &pr1_hi, &pr1_g, &pr1_m, pr1_bez);
        CHECK(pr1_g == 2 && pr1_m == 3 && pr1_bez[0] == 0.25f && pr1_bez[1] == 0.5f && pr1_bez[2] == 0.75f);   // PR1 探针：色域 / tonemap / bezier 逐项相等
        uint8_t on2 = 1; uint32_t fmt2 = 9; uint16_t peak2 = 9; CHECK(hs(&on2, &fmt2, &peak2, dp) == 0 && on2 == 0 && fmt2 == 0 && peak2 == 0);   // PR1 探针只存不改答：Set* 过后 HDR 状态查询仍 on=0 / fmt=0 / peak=0
        CHECK(clr(ly) == 0);
        pr1_cap = 9; pr1_lo = 9; pr1_hi = 9; pr1_g = 9; pr1_m = 9; pr1_bez[0] = pr1_bez[1] = pr1_bez[2] = 9;
        nvn2_vi_hdr_probe(&pr1_cap, &pr1_lo, &pr1_hi, &pr1_g, &pr1_m, pr1_bez);
        CHECK(pr1_lo == 0 && pr1_hi == 0 && pr1_g == 0 && pr1_m == 0 && pr1_bez[0] == 0 && pr1_bez[1] == 0 && pr1_bez[2] == 0);   // PR1 探针：Clear 后层级元数据整组回缺省
        CHECK(pr1_cap == 1);   // 显示级能力开关不随层 Clear（sdk 没有对应 Clear*）
        on2 = 1; CHECK(hs(&on2, &fmt2, &peak2, dp) == 0 && on2 == 0 && fmt2 == 0 && peak2 == 0);   // Clear 后查询回答仍不变
    }

    // ---------- V4 PR3a 策略抽象重写（评审稿 v3 §2.3 判定次序 / §2.5 开关 / §4 PR3a）：choose_mode 全分支（合成快照）+ 层 tick 滞回 / 排空（合成时钟）+ peak 步进 / 带内 / 地板 / 顶帽 + nvn2_hdr_* 存储与入口 ----------
    //   声明在 nvn_hdr_policy.h（v3 重写：模式枚举 HDR_S0 / HDR_S1（PQ 层）/ HDR_S3——16F 移出枚举），实现分两处：纯函数在头（static inline），
    //   存储与入口在 nvn2.c 随后一个提交给——基线（hdr-pr1-final）上头文件不存在，编译必红；实现提交上绿。负对照另行撤掉新判定次序再红。
    //   期望值全部手算、不跑被测实现得出（同 K 段口径）：peak 格点 40 步/十倍频锚在纸白（10^(s/40)）——
    //   v(12)=100×10^0.3=199.53→量化 200、v(16)=251.19→250、v(19)=298.54→300、v(22)=354.81→350、v(4)=125.89→130、v(7)=149.56→150、v(80)=10000、v(24)=398.11→400；
    //   步号 = lround(40×log10(值/纸白))，量化值反推步号有 ±1 步漂（130→5），带宽容 ±2 步吸收。
    {
        hdr_decision dec;
        // off 不变量（§2.3 第 1 条，必含）：off ⇒ 恒 S0 ∧ vi 恒 on=0 / fmt=0 / peak=0——无视源与快照（出图 S0 直通 + 游戏回 SDR 分支，两处同时回退）
        hdr_snapshot hs0 = {0};   // 缺省全 0 = 「无 HDR」= 现状：can 未持稳 / 层未持 PQ / G1 未跑 / 纸白未发布（peak 按 PQ 锚 100）
        dec = hdr_choose_mode(HDR_OFF, 0, &hs0, NULL, 0);
        CHECK(dec.mode == HDR_S0 && dec.vi_on == 0 && dec.vi_fmt == 0 && dec.vi_peak == 0);
        {   hdr_snapshot big = { .potential_edr = 4.555, .current_headroom = 2.0, .can_settled = 1, .layer_pq = 1, .s1_ready = 1, .paper_white = 100 };   // U2720QM 开态全就绪形状
            dec = hdr_choose_mode(HDR_OFF, 1, &big, NULL, 0);
            CHECK(dec.mode == HDR_S0 && dec.vi_on == 0 && dec.vi_fmt == 0 && dec.vi_peak == 0); }   // off：已持 PQ 层 + HDR 屏快照也判 S0 / on=0
        // 源非 HDR（8 位窗 / color_space=0 / 未知枚举一律按非 HDR——Q1 口径）：SDR 语义，vi 不答 on=1；层不因源切回（层在 PQ 态仍 S1：逐帧 mode 2 转换上屏，PR3b）
        dec = hdr_choose_mode(HDR_AUTO, 0, &hs0, NULL, 0);
        CHECK(dec.mode == HDR_S0 && dec.vi_on == 0 && dec.vi_fmt == 0 && dec.vi_peak == 0);
        {   hdr_snapshot lpq = { .layer_pq = 1 };
            dec = hdr_choose_mode(HDR_ON, 0, &lpq, NULL, 0);
            CHECK(dec.mode == HDR_S1 && dec.vi_on == 0 && dec.vi_fmt == 0 && dec.vi_peak == 0);   // on + 源非 HDR：层持 PQ 不切回，vi 仍不答
            dec = hdr_choose_mode(HDR_ON, 0, &hs0, NULL, 0);
            CHECK(dec.mode == HDR_S0 && dec.vi_on == 0); }   // 层也不在：S0
        // can=false（500ms 滞回后 can_settled=0）：auto → vi on=0 游戏自降（§2.3 注意②：SDR 屏上游戏自画比宿主映射少饱和 / 更准）；on → S3 强制（vi 仍答 on=1，宿主 mode 1 映射上屏）
        {   hdr_snapshot can0 = { .potential_edr = 1.0, .current_headroom = 1.0, .paper_white = 100 };   // SDR 屏形状：potentialEDR 恰 1.0
            dec = hdr_choose_mode(HDR_AUTO, 1, &can0, NULL, 0);
            CHECK(dec.mode == HDR_S0 && dec.vi_on == 0 && dec.vi_fmt == 0 && dec.vi_peak == 0);
            hdr_peak_state pk = {0};
            dec = hdr_choose_mode(HDR_ON, 1, &can0, &pk, 0);
            CHECK(dec.mode == HDR_S3 && dec.vi_on == 1 && dec.vi_fmt == 1 && dec.vi_peak == 130);   // on：S3 强制 + peak 地板（headroom 1.0 → 100 < 1.25×100=125 夹地板 → 步 4 → 125.89 → 量化 130，绝不答 0）
            hdr_snapshot drain = { .layer_pq = 1 };   // can 已塌、层还没排完（过渡）：按层现态答 S1（present 逐帧按实际格式选转换），vi 不答
            dec = hdr_choose_mode(HDR_AUTO, 1, &drain, NULL, 0);
            CHECK(dec.mode == HDR_S1 && dec.vi_on == 0); }
        // can=true 但 s1_ready=0（G1 大面积烟囱未过——S1 硬门槛，不虚假宣传）：auto → 游戏自降；on → 宿主按屏选 S1/S3 的 S3 档
        {   hdr_snapshot nos1 = { .potential_edr = 4.555, .current_headroom = 2.0, .can_settled = 1, .paper_white = 100 };
            dec = hdr_choose_mode(HDR_AUTO, 1, &nos1, NULL, 0);
            CHECK(dec.mode == HDR_S0 && dec.vi_on == 0);
            hdr_peak_state pk = {0};
            dec = hdr_choose_mode(HDR_ON, 1, &nos1, &pk, 0);
            CHECK(dec.mode == HDR_S3 && dec.vi_on == 1 && dec.vi_fmt == 1 && dec.vi_peak == 200); }   // on：S3 + peak=纸白 100 × headroom 2.0 → 步 12 → 199.53 → 量化 200
        // can=true ∧ s1_ready=1：「先持层再答」——layer_pq 入参不 =1 不放行（次序以断言入参表达）；=1 才答 on=1 / fmt=1 / peak（Bananza 首查询即定窗口）
        {   hdr_snapshot ready = { .potential_edr = 4.555, .current_headroom = 2.5, .can_settled = 1, .s1_ready = 1, .paper_white = 100 };
            hdr_peak_state pk = {0};
            dec = hdr_choose_mode(HDR_AUTO, 1, &ready, &pk, 0);
            CHECK(dec.mode == HDR_S1 && dec.vi_on == 0 && dec.vi_fmt == 0 && dec.vi_peak == 0);   // 层未持 PQ：只答 mode=S1，本问不放行
            ready.layer_pq = 1;
            dec = hdr_choose_mode(HDR_AUTO, 1, &ready, &pk, 500);
            CHECK(dec.mode == HDR_S1 && dec.vi_on == 1 && dec.vi_fmt == 1 && dec.vi_peak == 250);   // 首答直接采纳：headroom 2.5 → 步 16 → 251.19 → 量化 250
            dec = hdr_choose_mode(HDR_ON, 1, &ready, &pk, 600);
            CHECK(dec.mode == HDR_S1 && dec.vi_on == 1 && dec.vi_peak == 250); }   // 同值带内：答案不动（headroom 波动不切层、peak 吸收——§2.3 第 5 条）
        // 没发布过快照（空指针）= 全 0「无 HDR」：auto 判 S0；on 强制 S3，vi on=1 / fmt=1 / 无前端 peak 1000（绝不答 0）
        dec = hdr_choose_mode(HDR_AUTO, 1, NULL, NULL, 0);
        CHECK(dec.mode == HDR_S0 && dec.vi_on == 0);
        dec = hdr_choose_mode(HDR_ON, 1, NULL, NULL, 0);
        CHECK(dec.mode == HDR_S3 && dec.vi_on == 1 && dec.vi_fmt == 1 && dec.vi_peak == 1000);

        // 层 tick——can 滞回 500ms + 进层（合成时钟进参，纯逻辑）：raw can 持稳 500ms 才写 can_settled（拖窗沿两屏边缘 flap 永不持稳、不来回切层）；
        //   持稳 ∧ s1_ready ∧ 三态非 off → 进层（即时——排空只在退出时等，进入不等：开机预挂赶首查询前）
        {   hdr_snapshot tst = { .s1_ready = 1 };
            hdr_layer_tick_can(&tst, HDR_AUTO, 1, 1000); CHECK(tst.can_settled == 0 && tst.layer_pq == 0);   // 变化只记时刻，未满 500ms
            hdr_layer_tick_can(&tst, HDR_AUTO, 1, 1499); CHECK(tst.can_settled == 0 && tst.layer_pq == 0);   // 499ms：差 1ms 不算
            hdr_layer_tick_can(&tst, HDR_AUTO, 1, 1500); CHECK(tst.can_settled == 1 && tst.layer_pq == 1 && tst.sdr_run == 0);   // 满 500ms：持稳 + 即进层
            hdr_layer_tick_can(&tst, HDR_AUTO, 0, 1600); CHECK(tst.can_settled == 1 && tst.layer_pq == 1);   // 掉侧只记变化：滞回期内层不动
            hdr_layer_tick_can(&tst, HDR_AUTO, 0, 2100); CHECK(tst.can_settled == 0 && tst.layer_pq == 1);   // 掉侧持稳：can 落；层等排空（tick_frame），不在这里切
            hdr_snapshot flp = { .s1_ready = 1 };
            hdr_layer_tick_can(&flp, HDR_AUTO, 1, 0);    CHECK(flp.can_settled == 0);
            hdr_layer_tick_can(&flp, HDR_AUTO, 0, 100);  CHECK(flp.can_settled == 0);
            hdr_layer_tick_can(&flp, HDR_AUTO, 1, 200);  CHECK(flp.can_settled == 0);
            hdr_layer_tick_can(&flp, HDR_AUTO, 0, 300);  CHECK(flp.can_settled == 0);
            hdr_layer_tick_can(&flp, HDR_AUTO, 1, 400);  CHECK(flp.can_settled == 0);   // 500ms 内来回翻：flap 永不持稳
            hdr_layer_tick_can(&flp, HDR_AUTO, 1, 899);  CHECK(flp.can_settled == 0);   // 400 起持稳到 899 = 499ms
            hdr_layer_tick_can(&flp, HDR_AUTO, 1, 900);  CHECK(flp.can_settled == 1 && flp.layer_pq == 1);   // 满 500ms：持稳 + 进层
            hdr_snapshot offst = { .s1_ready = 1 };
            hdr_layer_tick_can(&offst, HDR_OFF, 1, 1000); CHECK(offst.can_settled == 0);
            hdr_layer_tick_can(&offst, HDR_OFF, 1, 2000); CHECK(offst.can_settled == 1 && offst.layer_pq == 0); }   // off：can 持稳但三态关 → 不进层
        // 层 tick——排空喂入（每帧，nvn_mtl.m 每帧喂计数——PR4 接线）：不再 want（can 塌 / 三态 off / s1_ready 掉）时连续两帧非 PQ 窗口才切回 SDR——无 HDR 帧落进 SDR 层
        {   hdr_snapshot drn = { .can_settled = 0, .layer_pq = 1, .s1_ready = 1 };   // can 塌了、层还持 PQ：排空计数中
            hdr_layer_tick_frame(&drn, HDR_AUTO, 1); CHECK(drn.sdr_run == 0 && drn.layer_pq == 1);   // 还有 PQ 窗口在出（游戏未降）：清零重等
            hdr_layer_tick_frame(&drn, HDR_AUTO, 0); CHECK(drn.sdr_run == 1 && drn.layer_pq == 1);   // 第 1 帧非 PQ：计数，层不动
            hdr_layer_tick_frame(&drn, HDR_AUTO, 1); CHECK(drn.sdr_run == 0 && drn.layer_pq == 1);   // 又来 PQ 帧：清零重等
            hdr_layer_tick_frame(&drn, HDR_AUTO, 0); CHECK(drn.sdr_run == 1 && drn.layer_pq == 1);
            hdr_layer_tick_frame(&drn, HDR_AUTO, 0); CHECK(drn.sdr_run == 0 && drn.layer_pq == 0);   // 连续两帧非 PQ：排空 → 切回 SDR
            hdr_layer_tick_frame(&drn, HDR_AUTO, 0); CHECK(drn.sdr_run == 0 && drn.layer_pq == 0);   // 已在 SDR：计数不涨
            hdr_snapshot wnt = { .can_settled = 1, .layer_pq = 1, .s1_ready = 1 };
            hdr_layer_tick_frame(&wnt, HDR_AUTO, 0); CHECK(wnt.sdr_run == 0 && wnt.layer_pq == 1);   // 还要 PQ（层不因源切回）：非 PQ 帧也不排空
            hdr_layer_tick_frame(&wnt, HDR_OFF, 0);  CHECK(wnt.sdr_run == 1 && wnt.layer_pq == 1);   // 三态拨 off：不再 want → 开始排空
            hdr_layer_tick_frame(&wnt, HDR_OFF, 0);  CHECK(wnt.sdr_run == 0 && wnt.layer_pq == 0); } // 两帧 → 切回 SDR
        // peak 步进（vi_screen_peak 收编为纯函数，合成时钟）：目标=纸白×headroom 夹 [1.25×纸白, 10000]；40 步/十倍频（约 6%）+ 量化 10 nit；
        //   与当前答案差 ≤2 步（带内）答案不动（带内保持、候选撤销）；出带候选持稳 1s 才采纳（防闪烁）；无前端恒 1000；绝不答 0
        {   hdr_snapshot pqs = { .paper_white = 100, .current_headroom = 2.0 };
            hdr_peak_state pk = {0};
            CHECK(hdr_vi_peak_nits(&pqs, &pk, 0) == 200);          // 首答直接采纳：200 → 步 12 → 199.53 → 量化 200
            CHECK(pk.answered_nits == 200);
            pqs.current_headroom = 2.2;
            CHECK(hdr_vi_peak_nits(&pqs, &pk, 100000) == 200);     // 220 → 步 14，与当前差 +2（带缘）：持稳再久也不动
            pqs.current_headroom = 1.8;
            CHECK(hdr_vi_peak_nits(&pqs, &pk, 200000) == 200);     // 180 → 步 10，差 -2：带内另一侧同样不动
            pqs.current_headroom = 2.5;
            CHECK(hdr_vi_peak_nits(&pqs, &pk, 300000) == 200);     // 250 → 步 16，差 +4 出带：候选开始计时，未满 1s 不动
            CHECK(hdr_vi_peak_nits(&pqs, &pk, 300999) == 200);     // 999ms：还差 1ms
            CHECK(hdr_vi_peak_nits(&pqs, &pk, 301000) == 250);     // 满 1s：采纳 250（瞬时尖峰被 1s 持稳滤掉）
            CHECK(pk.answered_nits == 250);
            pqs.current_headroom = 3.0;
            CHECK(hdr_vi_peak_nits(&pqs, &pk, 400000) == 250);     // 300 → 步 19：新候选开始计时
            pqs.current_headroom = 3.5;
            CHECK(hdr_vi_peak_nits(&pqs, &pk, 401000) == 250);     // 候选变 350（步 22）：计时重起，仍答旧值
            pqs.current_headroom = 2.2;
            CHECK(hdr_vi_peak_nits(&pqs, &pk, 500000) == 250);     // 回带内（步 14，差 -2）：候选撤销
            pqs.current_headroom = 3.0;
            CHECK(hdr_vi_peak_nits(&pqs, &pk, 600000) == 250);     // 重出带：从 600000 重计（带内那 500ms 不折抵）
            CHECK(hdr_vi_peak_nits(&pqs, &pk, 701000) == 300);     // 满 1s：采纳 300
            hdr_snapshot dnp = { .paper_white = 100, .current_headroom = 3.0 };
            hdr_peak_state dk = {0};
            CHECK(hdr_vi_peak_nits(&dnp, &dk, 0) == 300);          // 首答 300（步 19 → 298.54 → 300）
            dnp.current_headroom = 1.5;
            CHECK(hdr_vi_peak_nits(&dnp, &dk, 1000) == 300);       // 150 → 步 7：向下出带，计时未满不动
            CHECK(hdr_vi_peak_nits(&dnp, &dk, 2000) == 150);       // 满 1s：向下采纳（headroom 掉了答案跟着掉，层不动）
            hdr_snapshot flr = { .paper_white = 100, .current_headroom = 0.5 };
            hdr_peak_state fk = {0};
            CHECK(hdr_vi_peak_nits(&flr, &fk, 0) == 130);          // 50 < 地板 125：夹地板 → 步 4 → 125.89 → 量化 130（≥125）
            flr.current_headroom = 0.1;
            CHECK(hdr_vi_peak_nits(&flr, &fk, 1000) == 130);       // 更低同样夹地板：同步号带内不动
            flr.current_headroom = 200;
            CHECK(hdr_vi_peak_nits(&flr, &fk, 2000) == 130);       // 20000 > 顶帽 10000：夹帽出带候选开始计时，仍答地板
            CHECK(hdr_vi_peak_nits(&flr, &fk, 3000) == 10000);     // 满 1s：顶帽采纳
            {   hdr_snapshot nfe = { .paper_white = 100 };
                hdr_peak_state nk = {0};
                CHECK(hdr_vi_peak_nits(&nfe, &nk, 0) == 1000); }   // 无前端（headroom ≤ 0 未发布）：恒 1000（nxnative DM 缺省同值）
            {   hdr_snapshot npw = { .current_headroom = 2.0 };    // 纸白未发布（0）：按 PQ 锚 100
                hdr_peak_state nk = {0};
                CHECK(hdr_vi_peak_nits(&npw, &nk, 0) == 200); } }

        // nvn2.c 存储与入口（同 PR1 nvn2_vi_hdr_probe 的直调口径）：S2A_HDR 三态解析、发布 / 读回、层 tick 接入与同源答案入口
        {   hdr_snapshot rb, pub = { .potential_edr = 4.555, .current_headroom = 2.0, .s1_ready = 1, .paper_white = 100 };
            unsetenv("S2A_HDR");
            CHECK(nvn2_hdr_switch() == HDR_OFF);                        // 不设 = off 缺省（字节级回现状）
            setenv("S2A_HDR", "off", 1);  CHECK(nvn2_hdr_switch() == HDR_OFF);
            setenv("S2A_HDR", "auto", 1); CHECK(nvn2_hdr_switch() == HDR_AUTO);
            setenv("S2A_HDR", "on", 1);   CHECK(nvn2_hdr_switch() == HDR_ON);
            setenv("S2A_HDR", "1", 1);    CHECK(nvn2_hdr_switch() == HDR_OFF);   // 看不懂按 off（打一次红行，断言只认值）
            nvn2_hdr_snapshot_publish(&pub);
            rb = (hdr_snapshot){0};
            nvn2_hdr_snapshot_probe(&rb);
            CHECK(rb.potential_edr == 4.555 && rb.current_headroom == 2.0 && rb.s1_ready == 1 && rb.paper_white == 100);   // 发布 / 读回：环境读数逐项相等
            CHECK(rb.can_settled == 0 && rb.layer_pq == 0 && rb.sdr_run == 0);   // 层簿记缺省 0（tick 还没跑）
            setenv("S2A_HDR", "auto", 1);
            nvn2_hdr_tick(HDR_AUTO, 1, 1000);   // 记变化
            nvn2_hdr_tick(HDR_AUTO, 1, 1500);   // 持稳 500ms → can_settled=1 ∧ s1_ready=1 → 进层
            nvn2_hdr_snapshot_probe(&rb);
            CHECK(rb.can_settled == 1 && rb.layer_pq == 1 && rb.sdr_run == 0);
            pub.current_headroom = 2.5;
            nvn2_hdr_snapshot_publish(&pub);    // 重探发布（换屏 / 拨 HDR 开关后的重探是 PR4 的活，这里只验发布语义）
            nvn2_hdr_snapshot_probe(&rb);
            CHECK(rb.layer_pq == 1 && rb.current_headroom == 2.5);   // 发布只刷环境读数，层状态不回卷（PR4 排空语义的前提）
            hdr_decision ad = nvn2_hdr_answer(1, 1500);
            CHECK(ad.mode == HDR_S1 && ad.vi_on == 1 && ad.vi_fmt == 1 && ad.vi_peak == 250);   // 同源答案入口：三态 + 快照 + tick 状态进 choose_mode；headroom 2.5 首答 250
            ad = nvn2_hdr_answer(1, 1600);
            CHECK(ad.mode == HDR_S1 && ad.vi_on == 1 && ad.vi_peak == 250);   // 同值带内：答案与层都不动
            setenv("S2A_HDR", "off", 1);
            ad = nvn2_hdr_answer(1, 1700);
            CHECK(ad.mode == HDR_S0 && ad.vi_on == 0 && ad.vi_fmt == 0 && ad.vi_peak == 0);   // off 不变量经存储入口同成立
            nvn2_hdr_tick_frame(HDR_OFF, 0);
            nvn2_hdr_tick_frame(HDR_OFF, 0);
            nvn2_hdr_snapshot_probe(&rb);
            CHECK(rb.layer_pq == 0 && rb.sdr_run == 0);   // off：不再 want，两帧非 PQ 排空切回 SDR
            unsetenv("S2A_HDR");
            memset(&pub, 0, sizeof pub);
            nvn2_hdr_snapshot_publish(&pub);   // 段末清回缺省（照 V3 段 Clear 恢复默认收尾；层已排空、簿记本就 0）
        }
    }

    // ---------- V5 PR5 vi 门控（评审稿 v3 §2.3 判定次序 / §2.5 S2A_HDR_PEAK / §4 PR5）：vi 入口按 L2 快照 + 层状态回答——假屏注入 × 三态 × 层状态 × peak 步进 × 纸白 × off 不变量 ----------
    //   假屏注入走本文件既定的弱符号替身接缝（文件头注口径：t_nvn2 给 nvn2.c 的弱定义/宿主接口提供替身；V4 段同款——nvn2_hdr_snapshot_publish 合成快照 +
    //   nvn2_hdr_tick 合成时钟 + setenv S2A_HDR / S2A_HDR_PEAK；t_present_hdr 前端替身同源），vi 侧经 nvn2_vi_entry 注册表条目直调（游戏真实路径）。
    //   基线（无 PR5 实现）上 vi_paper_white 答 203、vi_hdr_status 恒 on=0/fmt=0/peak=0——本段红；PR5 上绿。峰值期望全部手算、不跑被测实现得出（V4 段口径）：
    //   地板 125 → 步 4 → 125.89 → 量化 130；200 → 步 12；250 → 步 16；400 → 步 24；1000 → 步 40；10000 → 步 80；890 → 步 78；
    //   带宽容 ±2 步（带内答案不动）、出带候选持稳 1s 采纳。层簿记走合成时钟（tick 进参），peak 持稳走真实单调钟（vi 入口内部取）——跨 1s 用 usleep。
    {   // V4 存储段遗留的共享状态（同文件已定）：快照全 0、层已排空、已答 peak=250（步 16）、S2A_HDR 已 unset
        uint32_t (*pw)(uint16_t *, const void *) = (uint32_t (*)(uint16_t *, const void *))nvn2_vi_entry("_ZN2nn2vi25QueryDisplayHdrPaperWhiteEPtPKNS0_7DisplayE");
        CHECK(pw);
        // ① 纸白 100（§1.4 判读③：v3 定稿 PQ 相对模型锚 EDR=nits/100——203 是 BT.2408 参考白、游戏缺省声明值，m0b 实证被 told peak 覆盖；游戏侧后果未实测 T15 专项）
        //   HDR 关（此处 S2A_HDR 未设 = 缺省关）答 203，与 0.5.8 一样；auto / on 答 100
        uint16_t pwv = 9; CHECK(pw(&pwv, dp) == 0 && pwv == 203);
        setenv("S2A_HDR", "auto", 1); pwv = 9; CHECK(pw(&pwv, dp) == 0 && pwv == 100);
        setenv("S2A_HDR", "on", 1); pwv = 9; CHECK(pw(&pwv, dp) == 0 && pwv == 100);
        setenv("S2A_HDR", "off", 1); pwv = 9; CHECK(pw(&pwv, dp) == 0 && pwv == 203);
        unsetenv("S2A_HDR");
        // ② 假 HDR 屏注入（U2720QM 开态形状）+ auto 进层：快照发布 + tick 持稳（合成时钟：V4 末次 raw 变化 1500 起，100000 早过 500ms）→ can_settled ∧ s1_ready ∧ 层已排空 → 即进层
        hdr_snapshot pub5 = { .potential_edr = 4.555, .current_headroom = 0.5, .s1_ready = 1, .paper_white = 100 };
        unsetenv("S2A_HDR_PEAK");
        nvn2_hdr_snapshot_publish(&pub5);
        setenv("S2A_HDR", "auto", 1);
        nvn2_hdr_tick(HDR_AUTO, 1, 100000);
        hdr_snapshot rb5; nvn2_hdr_snapshot_probe(&rb5);
        CHECK(rb5.can_settled == 1 && rb5.layer_pq == 1);   // 层已持 PQ——「先持层再答」的前提就位
        // ③ off 不变量：off + 假 HDR 屏 + 层已持 PQ → vi 恒 on=0 / fmt=0 / peak=0（无视快照与层状态，§2.3 第 1 条）
        setenv("S2A_HDR", "off", 1);
        uint8_t on5 = 1; uint32_t fmt5 = 9; uint16_t peak5 = 9;
        CHECK(hs(&on5, &fmt5, &peak5, dp) == 0 && on5 == 0 && fmt5 == 0 && peak5 == 0);
        // ④ auto + 层已持：首查询即答 on=1 / fmt=1（Bananza 首查询即定窗口，不等 headroom 爬坡）；peak=纸白×headroom 步进——headroom 0.5 目标 130（地板），
        //   与已答 250（V4 遗留，步 16）差 12 步出带 → 候选计时中，本问仍答 250（出带候选持稳 1s 才采纳，绝不答 0）
        setenv("S2A_HDR", "auto", 1);
        on5 = 1; fmt5 = 9; peak5 = 9; CHECK(hs(&on5, &fmt5, &peak5, dp) == 0 && on5 == 1 && fmt5 == 1 && peak5 == 250 && peak5 > 0);
        usleep(1100000);   // 跨 1s 持稳（vi 入口走真实单调钟）
        on5 = 1; peak5 = 9; CHECK(hs(&on5, &fmt5, &peak5, dp) == 0 && on5 == 1 && peak5 == 130);   // 地板 1.25×纸白=125 夹入 → 步 4 → 125.89 → 量化 130 采纳
        // ⑤ 带内（同值）：headroom 0.6 → 原料 60 仍夹地板 125 → 130，与已答差 ±0 → 答案不动、候选撤销（带内保持，1s 不参与）
        pub5.current_headroom = 0.6; nvn2_hdr_snapshot_publish(&pub5);
        on5 = 1; peak5 = 9; CHECK(hs(&on5, &fmt5, &peak5, dp) == 0 && on5 == 1 && peak5 == 130);
        // ⑥ S2A_HDR_PEAK 固定值（诊断）：180 盖过步进算法（已告知 peak 与 vi 回答同源——present 经 latch 读到同一份）
        setenv("S2A_HDR_PEAK", "180", 1);
        on5 = 1; peak5 = 9; CHECK(hs(&on5, &fmt5, &peak5, dp) == 0 && on5 == 1 && fmt5 == 1 && peak5 == 180);
        // ⑦ 非法值当 unset（红日志打一次）：abc / 0 / 上界外都回步进算法的答案——0 也非法（绝不答 0：固定值 0 不生效，答 130）
        setenv("S2A_HDR_PEAK", "abc", 1);
        on5 = 1; peak5 = 9; CHECK(hs(&on5, &fmt5, &peak5, dp) == 0 && on5 == 1 && peak5 == 130);
        setenv("S2A_HDR_PEAK", "0", 1);
        on5 = 1; peak5 = 9; CHECK(hs(&on5, &fmt5, &peak5, dp) == 0 && on5 == 1 && peak5 == 130 && peak5 != 0);
        unsetenv("S2A_HDR_PEAK");
        // ⑧ 顶帽：headroom 200 → 原料 20000 夹顶帽 10000（步 80，与已答 130 步 5 差 75 出带）→ 候选计时中仍答 130，持稳 1s 采纳 10000
        pub5.current_headroom = 200.0; nvn2_hdr_snapshot_publish(&pub5);
        on5 = 1; peak5 = 9; CHECK(hs(&on5, &fmt5, &peak5, dp) == 0 && on5 == 1 && peak5 == 130);
        usleep(1100000);
        on5 = 1; peak5 = 9; CHECK(hs(&on5, &fmt5, &peak5, dp) == 0 && on5 == 1 && peak5 == 10000);
        // ⑨ 带内 ±2 步：headroom 90 → 目标 890（步 78）与已答 10000（步 80）差 2 → 带内答案不动（10000，不降到 890）
        pub5.current_headroom = 90.0; nvn2_hdr_snapshot_publish(&pub5);
        on5 = 1; peak5 = 9; CHECK(hs(&on5, &fmt5, &peak5, dp) == 0 && on5 == 1 && peak5 == 10000);
        // ⑩ 无前端：headroom 未发布（0）→ 恒 1000（步 40，出带候选）→ 持稳 1s 采纳
        pub5.current_headroom = 0.0; nvn2_hdr_snapshot_publish(&pub5);
        on5 = 1; peak5 = 9; CHECK(hs(&on5, &fmt5, &peak5, dp) == 0 && on5 == 1 && peak5 == 10000);
        usleep(1100000);
        on5 = 1; peak5 = 9; CHECK(hs(&on5, &fmt5, &peak5, dp) == 0 && on5 == 1 && peak5 == 1000);
        // ⑪ 先层后答（§2.3 第 4 条）——两道门各自断言：
        //   a. s1_ready 硬门槛（G1 大面积烟囱未过）：can 持稳 ∧ 层已持 → auto 仍恒 on=0（不虚假宣传）
        pub5.current_headroom = 2.5; pub5.s1_ready = 0; nvn2_hdr_snapshot_publish(&pub5);
        on5 = 1; peak5 = 9; CHECK(hs(&on5, &fmt5, &peak5, dp) == 0 && on5 == 0 && fmt5 == 0 && peak5 == 0);
        //   b. 排空（层未持）：s1 未过时连续两帧非 PQ → 层切回 SDR；随后 can/s1 都就绪、层未持 → 本问不放行（Bananza 下一发布周期补答）
        nvn2_hdr_tick_frame(HDR_AUTO, 0);
        nvn2_hdr_tick_frame(HDR_AUTO, 0);
        nvn2_hdr_snapshot_probe(&rb5);
        CHECK(rb5.layer_pq == 0 && rb5.sdr_run == 0);   // 排空切回 SDR
        pub5.s1_ready = 1; nvn2_hdr_snapshot_publish(&pub5);
        on5 = 1; peak5 = 9; CHECK(hs(&on5, &fmt5, &peak5, dp) == 0 && on5 == 0 && fmt5 == 0 && peak5 == 0);   // 层未就绪恒 on=0（先层后答次序）
        //   c. 层重进（tick 即时进层——进入不等排空）后：同快照同问 → on=1 / fmt=1；peak：目标 250（步 16）与已答 1000（步 40）差 24 出带 → 候选计时中仍答 1000
        nvn2_hdr_tick(HDR_AUTO, 1, 110000);
        nvn2_hdr_snapshot_probe(&rb5);
        CHECK(rb5.layer_pq == 1);
        on5 = 1; peak5 = 9; CHECK(hs(&on5, &fmt5, &peak5, dp) == 0 && on5 == 1 && fmt5 == 1 && peak5 == 1000);
        // ⑫ on 强制（S2A_HDR=on）：can 持稳但 s1_ready 未过 → S3 强制路径 vi 仍答 on=1 / fmt=1（宿主 mode 1 映射上屏）；peak 目标 400（步 24）出带候选中仍答 1000
        setenv("S2A_HDR", "on", 1);
        {   hdr_snapshot s3 = { .potential_edr = 2.0, .current_headroom = 4.0, .s1_ready = 0, .paper_white = 100 };
            nvn2_hdr_snapshot_publish(&s3); }
        on5 = 1; peak5 = 9; CHECK(hs(&on5, &fmt5, &peak5, dp) == 0 && on5 == 1 && fmt5 == 1 && peak5 == 1000);
        // ⑬ 段末清回缺省（照 V4 段口径）：off 排空两层、开关与环境全 unset、快照清零（后继段不触 HDR 态，仅防跨段污染）
        setenv("S2A_HDR", "off", 1);
        nvn2_hdr_tick_frame(HDR_OFF, 0);
        nvn2_hdr_tick_frame(HDR_OFF, 0);
        unsetenv("S2A_HDR");
        unsetenv("S2A_HDR_PEAK");
        memset(&pub5, 0, sizeof pub5);
        nvn2_hdr_snapshot_publish(&pub5);
    }

    // ---------- P 推常量的参数规整（nvn2_cmd.h nvn2_push_range）：槽取低 3 位、偏移取低 8 位、字节数夹到 256 且不越过槽尾、不足 4 字节不发 ----------
    unsigned ps, po, pn;
    CHECK(nvn2_push_range(0, 0, 16, &ps, &po, &pn) && ps == 0 && po == 0 && pn == 16);   // 马车世界的唯一一次：(0, 0, 16, float[4])
    CHECK(nvn2_push_range(9, 0, 300, &ps, &po, &pn) && ps == 1 && pn == 256);              // 9 & 7 = 1；300 夹到 256
    CHECK(nvn2_push_range(2, 0x1f0, 64, &ps, &po, &pn) && ps == 2 && po == 0xf0 && pn == 16);   // 0x1f0 & 0xff = 0xf0，0xf0 + 16 = 256 到槽尾
    CHECK(!nvn2_push_range(0, 0, 3, &ps, &po, &pn));                                         // 不足 4 字节：驱动不发

    // ---------- D DLSS 对象布局（kartnative nvn2.md：Parameters SetDefaults 写满 0..0xc7，+0x58/+0x5c/+0x60 = 1.0f，+0xb0..+0xbf = -1；Builder 条目缺省 1、设备不清）----------
    uint8_t par[DLP_SIZE]; memset(par, 0x5a, sizeof par); nvn2_dlss_params_defaults(par);
    CHECK(nvn2_getf(par, DLP_MVSCALE) == 1.0f && nvn2_getf(par, DLP_MVSCALE + 4) == 1.0f && nvn2_getf(par, DLP_PREEXP) == 1.0f);
    CHECK(nvn2_get32(par, 0xb0) == 0xffffffffu && nvn2_get32(par, 0xbc) == 0xffffffffu && par[DLP_RESET] == 0 && nvn2_get32(par, DLP_INSIZE) == 0 && nvn2_get32(par, 0xc4) == 0);
    uint8_t bld[DLB_SIZE]; memset(bld, 0x5a, sizeof bld); nvn2_dlss_builder_defaults(bld);
    CHECK(bld[0] == 0x5a && bld[7] == 0x5a && bld[8] == 0 && nvn2_get32(bld, DLB_MAXENT) == 1 && nvn2_get32(bld, DLB_FLAGS) == 0 && bld[DLB_SIZE - 1] == 0);
    CHECK(DLT_N == 6 && nvn2_dlss_tex_at[DLT_DEPTH] == 0x30 && nvn2_dlss_tex_at[DLT_EXPOSURE] == 0x68);

    // ---------- O GetOptimalSettings（NGX 次序：最佳、最大、最小；宿主放大上限 m 倍）：手算 ----------
    //   火纹：输出 3840x2160、方法 2（质量 2/3）、上限 3 → 最佳 2560x1440、最大 3840x2160、最小 1280x720
    int o6[6];
    nvn2_dlss_optimal(3840, 2160, 2, 3.0, o6); CHECK(o6[0] == 2560 && o6[1] == 1440 && o6[2] == 3840 && o6[3] == 2160 && o6[4] == 1280 && o6[5] == 720);
    //   1920x1080 性能档（1/2）→ 最佳 960x540；最小 640x360
    nvn2_dlss_optimal(1920, 1080, 0, 3.0, o6); CHECK(o6[0] == 960 && o6[1] == 540 && o6[4] == 640 && o6[5] == 360);
    //   上限 2 倍时超性能档（1/3 = 1280x720）抬到最小 1920x1080
    nvn2_dlss_optimal(3840, 2160, 3, 2.0, o6); CHECK(o6[0] == 1920 && o6[1] == 1080 && o6[4] == 1920 && o6[5] == 1080);
    //   除不尽向上取整：1000 / 3 → 334
    nvn2_dlss_optimal(1000, 1000, 5, 3.0, o6); CHECK(o6[0] == 1000 && o6[4] == 334);

    // ---------- H 张量核矩阵乘计数（nvn2_hmma_count）：16 字节一条，只看前 8 字节低 12 位 == 0x23c；手排 4 条 + 8 字节残尾 ----------
    //   第 0 条 0x...a23c（高位任意、低 12 位 0x23c）计；第 1 条 0x13c 不计；第 2 条前 8 字节 0x23d 不计、后 8 字节（控制位）放 0x23c 也不计；
    //   第 3 条 0x23c 计；残尾 8 字节放 0x23c 不足一条不计 → 期望 2
    uint8_t hm[72] = {0}; uint64_t w;
    w = 0xdeadbeef0000a23cull; memcpy(hm + 0, &w, 8);
    w = 0x13c; memcpy(hm + 16, &w, 8);
    w = 0x23d; memcpy(hm + 32, &w, 8); w = 0x23c; memcpy(hm + 40, &w, 8);
    w = 0x23c; memcpy(hm + 48, &w, 8);
    w = 0x23c; memcpy(hm + 64, &w, 8);
    CHECK(nvn2_hmma_count(hm, 72) == 2);
    CHECK(nvn2_hmma_count(hm, 48) == 1);    // 截到前 3 条
    CHECK(nvn2_hmma_count(hm, 0) == 0 && nvn2_hmma_count(hm, 15) == 0);

    // ---------- S 半精度带符号平方计数（nvn2_hsq_count）：HMUL2 Rd, Ra, |Ra|，手排 8 条 + 8 字节残尾 ----------
    //   基本式 lo = 0x232 | Ra<<24 | Rb<<32 | |B|<<62，hi 位 8 / 9 / 10..11 = A 的取负 / 绝对值 / 半字选择：
    //   ① R2, |R2| 计；② |R5|·R5（绝对值在 A 侧，hi 位 9）计；③ R2·R3 不同寄存器不计；④ RZ·|RZ| 不计；⑤ R2·|R2| 但 B 取负（位 63）不计；
    //   ⑥ R2·|R2| 但半字选择不同（B 位 60 = 1、A 0）不计；⑦ 0x032 形式 0（不是 0x232）不计；⑧ 同 ① 但操作码 0x220（FMUL）不计；残尾放 ① 不足一条不计 → 期望 2
    uint8_t hq[136] = {0};
    #define HS(i, LO, HI) do { uint64_t l_ = (LO), h_ = (HI); memcpy(hq + 16 * (i), &l_, 8); memcpy(hq + 16 * (i) + 8, &h_, 8); } while (0)
    HS(0, 0x232ull | 2ull << 24 | 2ull << 32 | 1ull << 62, 0);
    HS(1, 0x232ull | 5ull << 24 | 5ull << 32, 1ull << 9);
    HS(2, 0x232ull | 2ull << 24 | 3ull << 32 | 1ull << 62, 0);
    HS(3, 0x232ull | 255ull << 24 | 255ull << 32 | 1ull << 62, 0);
    HS(4, 0x232ull | 2ull << 24 | 2ull << 32 | 1ull << 62 | 1ull << 63, 0);
    HS(5, 0x232ull | 2ull << 24 | 2ull << 32 | 1ull << 62 | 1ull << 60, 0);
    HS(6, 0x032ull | 2ull << 24 | 2ull << 32 | 1ull << 62, 0);
    HS(7, 0x220ull | 2ull << 24 | 2ull << 32 | 1ull << 62, 0);
    w = 0x232ull | 2ull << 24 | 2ull << 32 | 1ull << 62; memcpy(hq + 128, &w, 8);
    #undef HS
    CHECK(nvn2_hsq_count(hq, 136) == 2);
    CHECK(nvn2_hsq_count(hq, 16) == 1);     // 截到第 1 条
    CHECK(nvn2_hsq_count(hm, 72) == 0);     // 上面 HMMA 那段里没有 HMUL2

    // ---------- T sRGB 解码门限计数（nvn2_srgb_count）：HSETP2 Rd, Ra, 0.04045（0x434，立即数两半字 0x292d），手排 5 条 + 8 字节残尾 ----------
    //   ① 0x434 + 0x292d292d 计；② 同 ① 换寄存器（Ra 位 24..31 = 7）计；③ 只一个半字是 0x292d 不计；④ 0x234（寄存器形式）不计；⑤ 0x832 × 0x2cf5（1/12.92 的 HMUL2）不计；
    //   残尾放 ① 不足一条不计 → 期望 2。立即数取自出口层 725bcf5c3f4bb3f3 的实码（第 1227 条：0x434 Rd 0, Ra 2, 0x292d292d）
    uint8_t sr[88] = {0};
    #define SR(i, LO) do { uint64_t l_ = (LO), h_ = 0; memcpy(sr + 16 * (i), &l_, 8); memcpy(sr + 16 * (i) + 8, &h_, 8); } while (0)
    SR(0, 0x434ull | 2ull << 24 | 0x292d292dull << 32);
    SR(1, 0x434ull | 7ull << 24 | 0x292d292dull << 32);
    SR(2, 0x434ull | 2ull << 24 | 0x3c00292dull << 32);
    SR(3, 0x234ull | 2ull << 24 | 0x292d292dull << 32);
    SR(4, 0x832ull | 2ull << 24 | 0x2cf52cf5ull << 32);
    w = 0x434ull | 2ull << 24 | 0x292d292dull << 32; memcpy(sr + 80, &w, 8);
    #undef SR
    CHECK(nvn2_srgb_count(sr, 88) == 2);
    CHECK(nvn2_srgb_count(sr, 16) == 1);    // 截到第 1 条
    CHECK(nvn2_srgb_count(hq, 136) == 0 && nvn2_srgb_count(hm, 72) == 0);   // 平方 / HMMA 那两段里没有

    printf("✓ t_nvn2：%u 项全过（Switch 2 NVN2：名字表 / 设备值 / GOB 次序 / 接管入口 / 推常量 / DLSS 布局 / 张量核计数 / 半精度平方计数 / sRGB 解码门限计数）\n", checks);   // 门禁按「✓ t_」认结论行
    return 0;
}
