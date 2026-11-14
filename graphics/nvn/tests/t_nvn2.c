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
        // camera CreateCameraContext：输出参数写 NULL
        void (*cam_ctx)(void **) = (void (*)(void **))s2a_nv_entry("_ZN2nn6camera3sdk19CreateCameraContextEPNS_5gsdrv18UniqueNativeHandleE");
        CHECK(cam_ctx && !nvn2_red_of(cam_ctx));
        void *p = (void *)0x5a5a; cam_ctx(&p); CHECK(p == NULL);
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
