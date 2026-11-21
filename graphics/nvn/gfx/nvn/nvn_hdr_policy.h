// HDR 上屏策略（评审稿 v3 §2.2 接缝 / §2.3 上屏模式矩阵与判定次序 / §4 PR3a）：屏幕能力快照（纯数据）+ choose_mode 纯函数 + 层 tick 状态机与 peak 步进（纯逻辑）+ nvn2.c 侧存储与入口的声明。
//   策略单源（调研缺口 A7）：直连出图层（nvn_mtl.m，PR3b/PR4 接入）、vi 门控（PR5）、通用路径（gal_present.m，PR7）共用；
//   nxnative 的 dm_hdr_layer_tick / vi_screen_peak / present_mode 三处散布式全局态收进本层包裹（评审稿 §2.7）——状态全走参数、不藏全局：合成快照 + 合成时钟即可全分支单测（t_nvn2 V4 段）。
//   模式枚举 v3 重定义（§2.3）：S1 = PQ 直通层（RGB10A2Unorm + kCGColorSpaceITUR_2100_PQ + wantsExtendedDynamicRangeContent，主路径）；
//   v2 的 S1 载体（16F + ExtendedLinear + CAEDRMetadata）整体移出枚举 → PR8+ 实验（16F 层水面黑块 / metadata 全屏旧帧矩形，调研实查否决默认开）；S4（SDR→HDR 逆映射）同为 PR8+，不占判定次序。
//   纯 C，不引平台头（只带标准 C 的 math.h）：宿主侧（host_adapt.m / front_mac.m / nvn_mtl.m）与单测都能包。
//   事件档读策略（发布 / tick / 同源答案入口），出图热路径只读已算好的结果——不逐帧进这里（热路径逐帧只喂排空计数，PR4）。
#pragma once
#include <math.h>

// 上屏模式（§2.3 矩阵）：S0 = SDR 直通（BGRA8Unorm + 显式 sRGB tag——创建与从 PQ 层切回两处都设，PR4/PR7 落地）；S1 = PQ 直通层（主路径）；
//   S3 = HDR→SDR（宿主 mode 1 映射兜底：S2A_HDR=on ∧ can 不行 / s1_ready 未过时强制，净空塌缩兜底）
enum { HDR_S0 = 0, HDR_S1, HDR_S3 };
// S2A_HDR 三态（§2.5；PR4 起开关名按项目惯例 S2A_ 前缀——维护者 PR #1640 意见，覆盖 v3 文档口径的 S2ARM_HDR）：
//   off 缺省——字节级回现状（不变量：off ⇒ choose_mode 恒 HDR_S0 ∧ vi 恒 on=0，两处同时回退）；
//   auto 按快照自动；on 强制 HDR 管线（游戏 HDR 分支 + 宿主按屏选 S1/S3——can 不行 / s1_ready 未过走 S3）
enum { HDR_OFF = 0, HDR_AUTO, HDR_ON };

// 判定数值（评审稿 v3 定稿，照抄不发明）：can 滞回 500ms；排空两帧非 PQ 窗口；peak 十倍频 40 步（约 6%）量化 10 nit、
//   出带候选持稳 1s、地板 1.25×纸白、顶帽 10000 nit、无前端 1000
#define HDR_CAN_HYSTERESIS_MS 500ull
#define HDR_SDR_DRAIN_FRAMES 2
#define HDR_PEAK_STEPS_PER_DECADE 40
#define HDR_PEAK_QUANT_NITS 10
#define HDR_PEAK_HOLD_MS 1000ull
#define HDR_PEAK_FLOOR_TIMES 1.25
#define HDR_PEAK_CAP_NITS 10000
#define HDR_PEAK_NO_FRONTEND_NITS 1000

// 屏幕能力快照（§2.3 的判定输入，主线程查屏后发布；全 0 = 「无 HDR」缺省 = 现状行为）。
//   字段分两主（nvn2_hdr_snapshot_publish 只刷前者、层状态机独占后者——发布不回卷层状态，PR4 重探排空语义的前提）：
//   环境读数（host 查屏 / G1 烟囱填）：potential_edr / current_headroom / s1_ready / paper_white；
//   层状态机簿记（hdr_layer_tick_can / hdr_layer_tick_frame 增改）：can_settled / layer_pq / sdr_run + 滞回时间戳两枚
typedef struct {
    double potential_edr;    // 挂层屏 potentialEDR（倍数，1.0 = SDR 白锚；§1.3 实测：U2720QM 开态 4.555 / 内建 2.0 / 关态 1.0）：raw can = > 1.0（调用方口径）
    double current_headroom; // 运行时净空 currentEDR（peak=纸白×headroom 的原料；后台窗恒 1.2 的口径与前台判定是 PR4 的活）：≤ 0 = 无前端读数 → peak 答无前端值 1000
    int    can_settled;      // can 过 500ms 滞回后的持稳值（hdr_layer_tick_can 维护）：0 = 未持稳 / 未运行——按保守（SDR 语义）处理
    int    layer_pq;         // 层现持 PQ（S1 已挂）——「先持层再答」的输入：choose_mode 不见它 =1 不答 vi on=1
    int    sdr_run;          // 排空计数：不再 want 后连续非 PQ 窗口帧数（出图每帧喂），≥ 2 层才切回 SDR——保证无 HDR 帧落进 SDR 层
    int    s1_ready;         // G1 双面积烟囱大面积档就绪（§4 G1 第 4 条：大面积 currentEDR>1.0）：G1 未跑缺省 0——S1 的硬门槛（不虚假宣传）
    int    paper_white;      // 纸白（nit）：v3 定稿 100（PQ 相对模型 EDR=nits/100 的锚，§1.4 判读②）；vi_paper_white 改答 100 是 PR5 的活，本快照只供 peak 公式用；未发布按 100
    unsigned long long can_chg_ms;  // 滞回簿记：raw can 上次变化的时刻（合成时钟，ms）
    int    last_can_raw;     // 滞回簿记：上一次喂入的 raw can
} hdr_snapshot;

// peak 步进状态（vi_screen_peak 收编为纯函数后由调用方持有——nvn2.c 存储侧持一份，单测自持；全 0 = 尚未答过）
typedef struct {
    int answered_nits;           // 当前已告知游戏的 peak（nit；0 = 还没答过——首答直接采纳，不等持稳）
    int hold_nits;               // 候选步的量化值（0 = 无候选；候选变化即重计）
    unsigned long long hold_ms;  // 候选步开始持稳的时刻（合成时钟）
} hdr_peak_state;

// 答案包（choose_mode 的一次判定输出）：mode 供出图层 / present 选路（PR3b/PR4），vi 三元组供 vi_hdr_status 照抄（PR5 接线）
typedef struct {
    int mode;      // HDR_S0 / HDR_S1 / HDR_S3
    int vi_on;     // vi_hdr_status 的 on（0 = off / 源非 HDR / auto 下 can 不行或层未持——游戏自降）
    int vi_fmt;    // 恒 1（fmt>1 是 SDK 错误 0x272——答 on=1 时；on=0 时 0 照现状）
    int vi_peak;   // peak（nit）：答 on=1 时按 hdr_vi_peak_nits 步进；on=0 时 0 照现状
} hdr_decision;

// peak 步进（vi_screen_peak 收编为纯函数；§4 PR5 公式 + §2.3 第 5 条「headroom 波动不切层、peak 步进吸收」）：
//   目标 = 纸白 × 当前 headroom（≤ 0 视为无前端 → 1000），夹到 [1.25×纸白, 10000]；格点十倍频 40 步锚在纸白（headroom 1.0 = 0 步）、值量化到 10 nit；
//   与当前答案差 ≤ 2 步（带内）答案不动、候选撤销——「带内保持」的读法：带内抖动被吸收，答案保持不变（1s 不参与）；
//   出带候选持稳 1s 才采纳（瞬时尖峰滤掉，防闪烁）；候选中途变化重计 1s。绝不答 0（地板兜底）。
//   快照指针为空按纸白 100 / 无前端处理；状态指针为空 = 无步进记忆，直接按目标答（正常调用方别这么用）。
static inline int hdr_vi_peak_nits(const hdr_snapshot *s, hdr_peak_state *st, unsigned long long now_ms) {
    double pw = (s && s->paper_white > 0) ? (double)s->paper_white : 100.0;   // 未发布按 PQ 锚 100
    double head = (s && s->current_headroom > 0) ? s->current_headroom : 0.0;
    double raw = head > 0 ? pw * head : (double)HDR_PEAK_NO_FRONTEND_NITS;    // 无前端：恒 1000（nxnative DM 缺省同值）
    double floor_nits = HDR_PEAK_FLOOR_TIMES * pw;
    if (raw < floor_nits) raw = floor_nits;
    if (raw > (double)HDR_PEAK_CAP_NITS) raw = (double)HDR_PEAK_CAP_NITS;
    int step = (int)lround(log10(raw / pw) * (double)HDR_PEAK_STEPS_PER_DECADE);   // 格点锚在纸白：headroom 1.0 = 0 步
    if (step < 0) step = 0;   // raw 已夹地板（≥ 1.25×纸白）：步号不会为负（headroom < 1 也夹到地板）
    int nits = (int)lround(pw * pow(10.0, (double)step / (double)HDR_PEAK_STEPS_PER_DECADE) / (double)HDR_PEAK_QUANT_NITS) * HDR_PEAK_QUANT_NITS;
    if (nits < (int)(ceil(floor_nits / (double)HDR_PEAK_QUANT_NITS)) * HDR_PEAK_QUANT_NITS)   // 量化后不破地板（125 → 130）
        nits = (int)(ceil(floor_nits / (double)HDR_PEAK_QUANT_NITS)) * HDR_PEAK_QUANT_NITS;
    if (nits > HDR_PEAK_CAP_NITS) nits = HDR_PEAK_CAP_NITS;
    if (!st) return nits;   // 无状态：直接按目标答，无步进记忆
    if (st->answered_nits <= 0) { st->answered_nits = nits; st->hold_nits = nits; st->hold_ms = now_ms; return nits; }   // 首答直接采纳
    int cur = (int)lround(log10((double)st->answered_nits / pw) * (double)HDR_PEAK_STEPS_PER_DECADE);   // 当前答案的步号（量化值反推有 ±1 步漂，带宽容 ±2 吸收）
    if (step >= cur - 2 && step <= cur + 2) { st->hold_nits = 0; return st->answered_nits; }   // 带内（±2 步）：保持不动、撤销候选
    if (st->hold_nits != nits) { st->hold_nits = nits; st->hold_ms = now_ms; return st->answered_nits; }   // 出带新候选（或候选变了）：重计 1s
    if (now_ms - st->hold_ms >= HDR_PEAK_HOLD_MS) { st->answered_nits = nits; st->hold_nits = nits; return nits; }   // 候选持稳 1s：采纳
    return st->answered_nits;
}

// 层 tick——can 滞回 + 进层（事件档：250ms tick / 换屏通知 / 开机预挂，PR4 接线；纯逻辑，合成时钟进参）：
//   raw can（potential_edr > 1.0 的调用方口径）持稳 HDR_CAN_HYSTERESIS_MS 才写 can_settled（flap 永不持稳——拖窗沿两屏边缘不来回切层）；
//   持稳 ∧ s1_ready ∧ 三态非 off ∧ 层未持 PQ → 进层（即时——排空只在退出时等，进入不等：开机预挂赶首查询前，§2.3 第 4 条）
static inline void hdr_layer_tick_can(hdr_snapshot *s, int sw, int raw_can, unsigned long long now_ms) {
    if (raw_can != s->last_can_raw) { s->last_can_raw = raw_can; s->can_chg_ms = now_ms; }   // 变化只记时刻（合成时钟）
    else if (now_ms - s->can_chg_ms >= HDR_CAN_HYSTERESIS_MS) s->can_settled = raw_can;      // 持稳 500ms 才算
    if (sw != HDR_OFF && s->can_settled && s->s1_ready && !s->layer_pq) { s->layer_pq = 1; s->sdr_run = 0; }   // 持稳 ∧ s1_ready → 进层
}

// 层 tick——排空喂入（每帧，nvn_mtl.m present 档喂计数，PR4 接线；纯逻辑）：层在 PQ 态且不再 want（三态 off / can 未持稳 / s1_ready 掉）时，
//   连续 HDR_SDR_DRAIN_FRAMES 帧非 PQ 窗口才切回 SDR——无 HDR 帧落进 SDR 层；want 期间（层不因源切回，§2.3 第 2 条）与 PQ 窗口帧都清零重等
static inline void hdr_layer_tick_frame(hdr_snapshot *s, int sw, int frame_is_pq) {
    if (!s->layer_pq) { s->sdr_run = 0; return; }
    if (sw != HDR_OFF && s->can_settled && s->s1_ready) { s->sdr_run = 0; return; }   // 还要 PQ：非 PQ 帧也不排空
    if (frame_is_pq) { s->sdr_run = 0; return; }   // 排空途中又有 PQ 窗口（游戏未降）：清零重等
    if (++s->sdr_run >= HDR_SDR_DRAIN_FRAMES) { s->layer_pq = 0; s->sdr_run = 0; }   // 连续两帧非 PQ：排空切回 SDR
}

// ---------- PR4：层配置解析（§2.3 S0/S1 行 + 注意事项①）----------
//   出图层两个物理配置，宿主两平台（host_adapt.m iOS 挂层 / Mac 前端窗口层被直连取用）共用这一份——策略单源（§2.2 接缝）：
//   S0 = 8 位 SDR（BGRA8Unorm）+ 显式 sRGB tag、无 EDR；S1 = 10 位 PQ（RGB10A2Unorm）+ ITU-R BT.2100 PQ 标签 + wantsExtendedDynamicRangeContent；
//   CAEDRMetadata 两态都不挂（默认关——PR8+ 经 S2A_HDR_META 实验；「不挂」由 metadata 恒 0 表达，平台侧照它不写 CAEDRMetadata）。
//   注意事项①：从 PQ 层切回的层保留 PQ 色彩空间——S0 的显式 sRGB tag 在创建点与切回点都要设（平台侧两处调 hdr_layer_config 同一份配置）；
//   色彩标签种类由平台映射到 kCGColorSpaceSRGB / kCGColorSpaceITUR_2100_PQ（纯 C 不引平台头，同本头口径）。
//   层持不持 PQ（快照 layer_pq）是唯一输入：off / can 不行 / 排空完成都落 S0 配置（off 不变量的层侧由 hdr_layer_tick_* 保证——off 不进层、喂入排空）。
enum { HDR_LPF_SDR8 = 0, HDR_LPF_PQ10 };   // 像素格式种类：8 位 SDR 直通（BGRA8Unorm）/ 10 位 PQ 直通层（RGB10A2Unorm）
enum { HDR_LCS_SRGB = 0, HDR_LCS_PQ };     // 色彩空间标签：显式 sRGB（S0）/ BT.2100 PQ（S1）
typedef struct { int pf; int color; int wants_edr; int metadata; } hdr_layer_cfg;
static inline hdr_layer_cfg hdr_layer_config(int layer_pq) {
    hdr_layer_cfg c = { HDR_LPF_SDR8, HDR_LCS_SRGB, 0, 0 };   // S0（层不持 PQ 的唯一配置）
    if (layer_pq) { c.pf = HDR_LPF_PQ10; c.color = HDR_LCS_PQ; c.wants_edr = 1; }   // S1（层已持 PQ——hdr_layer_tick_can 进层 / 开机预挂后）
    return c;
}

// 判定次序（§2.3，纯函数；合成快照 + 合成时钟全分支单测，t_nvn2 V4 段）：
//   1. off → 恒 S0 ∧ vi 恒 on=0（不变量，无视快照与层状态——出图 S0 直通 + 游戏回 SDR 分支，两处同时回退）；
//   2. 源非 HDR（8 位窗 / color_space=0 / 未知枚举一律按非 HDR——Q1 口径，调用方传 src_hdr=0）→ SDR 语义：vi 不答 on=1，层不因源切回（层在 PQ 态仍 S1，逐帧 mode 2 上屏——PR3b）；
//   3. can 未持稳（500ms 滞回后）或 s1_ready 未过（G1 大面积烟囱硬门槛——不虚假宣传）：auto → vi on=0 游戏自降（SDR 屏上游戏自画比宿主映射少饱和 / 更准，§2.3 注意②），层没排完前按层现态答 S1（present 逐帧按实际格式选转换）；on → S3 强制（vi 仍答 on=1 / fmt=1 / peak，宿主 mode 1 映射上屏）；
//   4. can=true ∧ s1_ready → mode=S1：「先持层再答」——layer_pq 入参 =1 才放行 vi on=1 / fmt=1 / peak（Bananza 首查询即定窗口，等 headroom 爬坡会永久困在 SDR——§1.4 判读②）；层未持只答 mode，下一发布周期补答；
//   headroom 波动不在这里切层（peak 步进吸收，答案变层不动）；净空塌缩 120 帧滞回（v3 保留的唯一帧级滞回）是 PR4/PR5 的层 / 门控活，不在本函数。
//   快照指针为空 = 没发布过，按全 0「无 HDR」处理；peak 状态指针为空 = 无步进记忆。
static inline hdr_decision hdr_choose_mode(int sw, int src_hdr, const hdr_snapshot *s, hdr_peak_state *pk, unsigned long long now_ms) {
    static const hdr_snapshot none;   // 全 0 = 无 HDR（没发布过 / 单测 / 安卓）
    hdr_decision d = { HDR_S0, 0, 0, 0 };
    if (!s) s = &none;
    if (sw == HDR_OFF) return d;   // §2.3 第 1 条（不变量）
    if (!src_hdr) { d.mode = s->layer_pq ? HDR_S1 : HDR_S0; return d; }   // 第 2 条：源非 HDR → SDR 语义；层不因源切回
    if (!s->can_settled || !s->s1_ready) {   // 第 3 条（can=false，500ms 滞回后）+ S1 硬门槛（s1_ready=0）
        if (sw == HDR_ON) { d.mode = HDR_S3; d.vi_on = 1; d.vi_fmt = 1; d.vi_peak = hdr_vi_peak_nits(s, pk, now_ms); }   // on：S3 强制（vi 仍答 on=1，宿主 mode 1 映射上屏）
        else if (s->layer_pq) d.mode = HDR_S1;   // auto：vi on=0 游戏自降；层没排完前按层现态答 S1
        return d;
    }
    d.mode = HDR_S1;   // 第 4 条：can=true ∧ s1_ready → 层持 PQ（hdr_layer_tick_can 进层，开机预挂赶首查询前）
    if (s->layer_pq) { d.vi_on = 1; d.vi_fmt = 1; d.vi_peak = hdr_vi_peak_nits(s, pk, now_ms); }   // 「先持层再答」：layer_pq 入参不 =1 不放行
    return d;
}

// ---------- PR3b：present_mode 数学（评审稿 v3 §2.4 模式矩阵 / §4 PR3b；数学移植自 nxnative #1176，登记口径 §2.7）----------
//   着色器六分支的数值与 nxnative present.metal 逐条对齐（ST 2084 EOTF/逆 EOTF、BT.709↔BT.2020 矩阵、present_shoulder 有理肩部）；
//   这一层只做模式判定与 UV 常量缓冲参数包（纯函数、无状态），状态由 nvn2.c 存储侧喂进来。
// 纸白锚：PQ 相对模型 EDR = nits/100 的锚（§1.4 判读②，v3 定稿 100；present 侧恒 100——nxnative dm_hdr_sdr_white 同值，非 vi 答询值）
#define HDR_PAPER_WHITE_NITS 100.0

// present 源格式种类（纯分类：nvn_mtl.m 把 MTLPixelFormat 归好类再进来，本头不引平台头）
enum { HDR_PF_SDR8 = 0, HDR_PF_HDR10, HDR_PF_FLOAT, HDR_PF_OTHER };
//   HDR_PF_SDR8：8 位 SDR 窗（RGBA8/BGRA8 含 sRGB 变体——scan-out 语义按原样字节，sRGB 存量经非 sRGB 视图读，present_raw_src 先例）
//   HDR_PF_HDR10：RGB10A2 窗（vi 答过 HDR 才当 PQ 码值——m0b 实证游戏在 on=1 后才建 0x3d 窗；未答过按 10 位 gamma SDR 读，即 mode 2 语义）
//   HDR_PF_FLOAT：float 窗（线性 BT.709，负值矩阵后才截断——scRGB 广色域保真；本作无样本，占位。四款与 nxnative present_mode 逐一同：
//     RGBA16F / RGBA32F / RG11B10F / RGB9E5F，归类在 nvn_mtl.m present_hdr_pf）
// present 目标种类：PR3b 阶段 dst 恒 SDR8（PQ 层 PR4 落地）；单测直接建 RGB10A2 目标驱动全矩阵
enum { HDR_PT_SDR8 = 0, HDR_PT_PQ10 };

// present 六个语义态（Q11：nxnative 着色器编号 0–4 共五个 + 「SDR 平凡直通」——后者即本仓现状 trivial 采样，
//   nxnative 把它折进 mode 0「as stored」（其 present.metal：Mode 0 is origin/main's sample, bit for bit）；本枚举把第六态显式单列，
//   经 hdr_present_shader_mode 折回着色器模式号 0——平凡直通与 PQ 直通在着色器里同走「原样采样」出口，逐字节一致）。
enum {
    HDR_PV_TRIVIAL = 0,  // 平凡直通：现状 trivial 采样（S0/off 不变量所在；无任何色彩转换，alpha 原样）
    HDR_PV_SDR     = 1,  // 着色器 mode 1：HDR10 窗 → 8 位 SDR（S3 兜底 + PR6 截图/判定/录像共用）：先 BT.2020→BT.709 矩阵（负值截断在矩阵后）→ 肩部压缩到 SDR 白 → SDR gamma 编码
    HDR_PV_TO_PQ   = 2,  // 着色器 mode 2：SDR8（含未答过的 10 位窗）→ PQ 层：gamma 解码 → BT.709→BT.2020 → PQ 编码到纸白
    HDR_PV_FLOAT   = 3,  // 着色器 mode 3：float 线性 BT.709 → PQ 层：BT.2020 矩阵（负值截断在矩阵后）→ PQ 编码到纸白
    HDR_PV_ROLL    = 4,  // 着色器 mode 4：HDR10 窗 → PQ 层（无 metadata）：有理肩部滚降，膝点码值以下逐位直通
    HDR_PV_PASS    = 5,  // 着色器 mode 0 的 PQ 直通语义：游戏已按 told peak 自 tone-map，PQ 码值原样写进 PQ 层（主路径）
};

// present_mode 纯函数（§2.4：src/dst 格式 + vi 答过 latch 三元判定；nxnative present_mode 同参——模式选择只看格式与 latch，不看三态开关：
//   off 从头 ⇒ vi 永不答 on=1 ⇒ latch 恒 0 ⇒ 恒 TRIVIAL，off 不变量由此成立；层还持 PQ 的排空帧按实际格式选转换，PR4 语义）
static inline int hdr_present_mode(int src_pf, int dst_pt, int vi_answered) {
    if (dst_pt == HDR_PT_PQ10) {   // PQ 层目标（PR4 起的层；PR3b 阶段仅单测驱动）
        if (src_pf == HDR_PF_HDR10) return vi_answered ? HDR_PV_PASS : HDR_PV_TO_PQ;   // 未答过的 10 位窗按 gamma SDR 编进 PQ 层
        if (src_pf == HDR_PF_FLOAT) return HDR_PV_FLOAT;
        if (src_pf == HDR_PF_SDR8) return HDR_PV_TO_PQ;
        return HDR_PV_TRIVIAL;
    }
    if (src_pf == HDR_PF_HDR10 && vi_answered) return HDR_PV_SDR;   // mode 1：S3 强制路径与 PR6 截图共用（vi 答过才当 PQ 码值解码）
    return HDR_PV_TRIVIAL;   // 8 位 SDR 源 / 未答过的 10 位窗 / float 窗 → 8 位目标：原样直通
}

// 六态 → 着色器模式号（平凡直通与 PQ 直通都折 0：mode 0 即「原样采样」，第六态与 PQ 直通同出口）
static inline int hdr_present_shader_mode(int pv) { return pv == HDR_PV_PASS ? 0 : pv; }

// ST 2084 双精度换算（nxnative t_present_hdr 的 pq_code/pq_nits 口径；膝点码值与单测期望共用同一份）：
//   nit → 10 位码值；10 位码值 → nit（着色器 10 位解出的码值换回亮度，对拍期望用）
static inline double hdr_pq_code(double nits) {
    const double m1 = 2610.0 / 16384, m2 = 2523.0 / 32, c1 = 3424.0 / 4096, c2 = 2413.0 / 128, c3 = 2392.0 / 128;
    double y = pow(nits / 10000.0, m1);
    return pow((c1 + c2 * y) / (1.0 + c3 * y), m2) * 1023.0;
}
static inline double hdr_pq_nits(double code) {
    const double m1 = 2610.0 / 16384, m2 = 2523.0 / 32, c1 = 3424.0 / 4096, c2 = 2413.0 / 128, c3 = 2392.0 / 128;
    double e = pow(code / 1023.0, 1.0 / m2);
    return 10000.0 * pow(fmax(e - c1, 0.0) / (c2 - c3 * e), 1.0 / m1);
}

// 游戏可能画到的峰值（nit）：声明范围 hi 与已告知 peak 取小；都没说 → 0（MKW 声明 1801 只画 357 nit——只看声明会压它没画的高光，
//   nxnative dm_hdr_source_peak 口径；声明 0 → 取告知的峰值）
static inline int hdr_source_peak_nits(int declared_hi, int told_peak) {
    int d = declared_hi, t = told_peak;
    if (t > 0 && (d <= 0 || t < d)) d = t;
    return d;   // 0 = 都没说（mode 1 的肩部退化为膝点以上线性到 target、只在 target 处截断）
}

// mode 4 滚降门与参数（nxnative dm_hdr_rolloff 收编为纯函数；无 metadata 前提——S2Arm 默认不挂 CAEDRMetadata，PR8+ 实验开关）：
//   target = 纸白 × 当前净空（跟着净空走，不跟已告知 peak 的步进保持）；knee = max(纸白, 0.75×target)——游戏的白永不被碰；
//   source = min(声明 hi, 已告知 peak)。不滚降的三个门（返回 0 = 维持直通）：无净空读数（≤0/NaN）或 source 无值；
//   source ≤ 1.05×target（自动 peak 量化到 10 nit 的余量）；knee > 0.9×target（白上没余量：让屏去截断，不硬滚）。
static inline int hdr_present_rolloff(double *knee, double *target, double *source,
                                     double headroom, int declared_hi, int told_peak, double paper_white) {
    int d = hdr_source_peak_nits(declared_hi, told_peak);
    if (!(headroom > 0.0) || !isfinite(headroom) || d <= 0) return 0;
    double t = paper_white * headroom, k = 0.75 * t;
    if (k < paper_white) k = paper_white;
    if ((double)d <= 1.05 * t || k > 0.9 * t) return 0;
    if (knee) *knee = k; if (target) *target = t; if (source) *source = (double)d;
    return 1;
}

// present 出图参数包（UV 常量缓冲 p[0..7]，照 nxnative present.metal 的 mode/xf 两组并一行）：
//   p[0] = 着色器模式号（0–4；平凡直通与 PQ 直通都 0）；p[1] = 纸白（nit，mode 1/2/3 的 PQ/SDR 白锚）；
//   p[2] = knee（mode 1 是纸白倍数 0.75；mode 4 是 nit）；p[3] = target（mode 1 是纸白倍数 1；mode 4 是 nit）；
//   p[4] = 源峰（mode 1 是纸白倍数——肩部精确落 target 的锚；mode 4 是 nit）；
//   p[5] = 膝点 PQ 码值（mode 4：归一化 0–1，各通道都 ≤ 它的像素逐位直通）；
//   p[6] = SDR gamma（mode 1/2：>0 纯幂曲线（缺省 2.2，Q13 留可调）；0 = 分段 sRGB 曲线——会抬暗部）。
//   返回六态模式；直通两态全 0（mode 0 = 原样采样，逐字节同改前）。纯函数，全分支合成参数单测 + 着色器对拍（t_present_hdr）
static inline int hdr_present_fill(float p[8], int src_pf, int dst_pt, int vi_answered,
                                   double headroom, int declared_hi, int told_peak, double sdr_gamma) {
    int pv = hdr_present_mode(src_pf, dst_pt, vi_answered);
    if (!p) return pv;
    for (int i = 0; i < 8; i++) p[i] = 0.0f;
    if (pv == HDR_PV_PASS) {   // PQ 直通的滚降细化（§2.4 mode 4）：门限不过维持直通，过了升 mode 4
        double k, t, s;
        if (hdr_present_rolloff(&k, &t, &s, headroom, declared_hi, told_peak, HDR_PAPER_WHITE_NITS)) {
            pv = HDR_PV_ROLL;
            p[0] = 4.0f; p[1] = (float)HDR_PAPER_WHITE_NITS; p[2] = (float)k; p[3] = (float)t; p[4] = (float)s;
            p[5] = (float)(hdr_pq_code(k) / 1023.0);   // 归一化膝点码值（着色器采样值同为归一化码值）
        }
    } else if (pv == HDR_PV_SDR) {   // mode 1：knee/target = 0.75/1（纸白倍数），源峰 = min(声明 hi, 已告知 peak)/纸白
        p[0] = 1.0f; p[1] = (float)HDR_PAPER_WHITE_NITS; p[2] = 0.75f; p[3] = 1.0f;
        p[4] = (float)((double)hdr_source_peak_nits(declared_hi, told_peak) / HDR_PAPER_WHITE_NITS);
        p[6] = (float)sdr_gamma;
    } else if (pv == HDR_PV_TO_PQ) {   // mode 2：SDR 源按 gamma 解码、纸白 100 nit 编进 PQ 层
        p[0] = 2.0f; p[1] = (float)HDR_PAPER_WHITE_NITS; p[6] = (float)sdr_gamma;
    } else if (pv == HDR_PV_FLOAT) {   // mode 3：float 线性源（已线性，无 gamma 参数）
        p[0] = 3.0f; p[1] = (float)HDR_PAPER_WHITE_NITS;
    }
    return pv;
}

// ---------- PR3d：AA/FX/FI 旁路判定（评审稿 v3 §2.5 开关矩阵 / §3 A3 行 / §4 PR3d）----------
//   直连上屏增强一族（上屏抗锯齿 nvn_present_aa.inc / MetalFX 空间放大 nvn_present_fx.inc / FSR nvn_present_fsr.inc /
//   出图补帧 nvn_present_fi.inc）的中间图与 MetalFX 纹理全是 8 位 sRGB 感知空间（BGRA8Unorm）：对 PQ 码值不适配——
//   PQ 1.0 = 10000 nit，感知锐化在高光无界过冲（nxnative 合成实测 ΔE_ITP 比 bilinear 差 65%/31% @1.25×/1.5×，未复测）。
//   HDR 窗口（RGB10A2 ∧ vi 答过——才当 PQ 码值，m0b 实证游戏在 on=1 后才建 0x3d 窗）旁路这一族、画质按 present 直通；
//   SDR 窗口（8 位 / 未答过的 10 位 gamma / float / 未知）照常走——层在 PQ 态的排空帧先缩放后 mode 2 转换
//   （§2.5「SDR 窗入 PQ 层仍走 MetalFX」先例）。旁路是产品限制（写入 docs/画面设置.md），不静默降画质。
//   判定三输入：窗口格式（nvn_mtl.m present_hdr_pf 归类）× S2A_HDR 三态 × vi 答过 latch（答过永不清，PR3b 簿记）。
//   off 恒不旁路（缺省字节级零行为变化——off 局 latch 本就恒 0，开关再挡一道：不假设簿记永不出错）。
//   纯函数、无状态；出图热路径经 nvn2_hdr_bypass_upscale 读已算好的 latch（快路径一次宽松原子读，nvn2_hdr_present 同款口径）。
static inline int hdr_bypass_upscale(int sw, int src_pf, int vi_answered) {
    return sw != HDR_OFF && vi_answered && src_pf == HDR_PF_HDR10;
}

// nvn2.c 侧的存储与入口（实现都在 nvn2.c：同 PR1 探针 nvn2_vi_hdr_probe 的口径，声明不进 nvn2.h，统一收在本头）。
//   快照与层状态机 / peak 状态都存 nvn2.c（PR1 g_hdr 探针存储同款先例，同一把锁）：nvn2.c 仍纯 C、不引平台头、不对宿主符号有链接依赖（宿主侧调进来，方向同 nvn2_sev_attach_register）；
//   nxnative dm_hdr_layer_tick / vi_screen_peak 的散布式全局态由此收进本文件单点（评审稿 §2.7）。
//   缺省全 0 = 「无 HDR」：不发布（单测 / 安卓 / 无头局）——现状行为分毫不差
void nvn2_hdr_snapshot_publish(const hdr_snapshot *s);   // 平台侧（host_adapt.m 挂层块 / front_mac.m screen_edr_note）发布环境读数；只刷 potential_edr / current_headroom / s1_ready / paper_white，层簿记不回卷；空指针忽略
void nvn2_hdr_snapshot_probe(hdr_snapshot *out);         // 读回整份（含层簿记；出图 / 门控 / 单测只读）；空指针忽略
int  nvn2_hdr_switch(void);                              // S2A_HDR 三态解析：不设 / off / 看不懂 = off 缺省（缺省关，字节级回现状；看不懂打一次红行）
void nvn2_hdr_tick(int sw, int raw_can, unsigned long long now_ms);      // 层 tick——can 滞回 + 进层，对存储快照（事件档：250ms timer / 换屏通知，PR4 接线）
void nvn2_hdr_tick_frame(int sw, int frame_is_pq);                       // 层 tick——排空喂入，对存储快照（每帧，PR4 接线）
void nvn2_hdr_preattach(int raw_can, unsigned long long now_ms);         // PR4 开机预挂的存储侧：识别 Switch 2 游戏即进层——不滞回（开机无翻屏史），赶在首查询前（§4 PR4 ③）；SDR 屏 / off / 已在层内各自让位
hdr_decision nvn2_hdr_answer(int src_hdr, unsigned long long now_ms);    // 同源答案入口：三态开关 + 已发布快照 + 存储的 peak 状态进 choose_mode——vi 门控 / 出图都从这读，不各自判
int nvn2_hdr_present(float p[8], int src_pf, int dst_pt);   // PR3b 出图热路径读已算好的结果：返回六态模式（HDR_PV_*）并填 UV 常量缓冲 p[0..7]（hdr_present_fill 喂存储态：vi 答过 latch + 已告知 peak + PR1 声明的范围 hi + 快照净空）
int nvn2_hdr_bypass_upscale(int src_pf);                    // PR3d 出图热路径旁路判定（AA/FX/FSR/补帧，§4 PR3d）：窗口格式进、bool 出——非 HDR10 窗零开销直返（连原子读都不进），HDR10 窗一次宽松原子读 latch，vi 答过才读 S2A_HDR（getenv 只发生在 HDR 管线已接手的局）
