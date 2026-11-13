// 自动玩家「AI 看屏驾驶」（10-31 维护者：人眼看一个移植好的游戏根据提示点按就可以完成鉴定）：任何一款游戏装上就自己走到可玩、打 MARK、再跑一段局内随机动作、写小结、收局。
// 分工（体验线_AI驾驶重构规格.md）：
//   判定交宿主读数——进局 = 模型说可操控 + 每帧绘制 / 渲染遍数到场景量级（相对开局基线）；直连 / 满屏 / 帧率由 host.log 模式行、每次出图满屏判据、frames.tsv 另判，这里不碰。
//   导航交 AI——每一步截一张图交 tests/autoplay/vision.sh（S2A_VISION_SH 可覆盖），回「按哪些键 + 现在可玩吗 + 为什么」，照键按；没有手录路线、没有盲按轮转、没有按秒数放行的状态机。
//   放行按画面不按秒：按下保持到游戏真出了新帧才松，松开后看每个新帧的 32×18 亮度摘要，变了且连续 3 帧稳定 = 这键有效；连续 30 新帧没变 = 没效（低帧款一样对）。
//   学路线：第一次走到 MARK 把「每页摘要 + 按的键」写进 ~/.s2arm/run/s2arm/ap_learn/<程序号>.tsv，末行是进局页（键 = MARK）；
//     下一局同一页（结构相关 ≥ 0.9）照做不问模型，回放到进局页且读数到场景量级就打 MARK（双证：上一局 AI 判过可操控 + 本局读数）；对不上交回 AI。
// 宿主接口见 autoplay_host.h；只用系统层看得见的共同信号，不按游戏分支（不许出现游戏名 / 标题号 / 游戏专用地址）。
// 必须原样保留的下游字面：「S2A 标记 MARK：帧 N」、「自动玩家结论：到 MARK / 没到 MARK；…；按键 N 下（翻页 M）…点触没反应 K 次…；小结 <路径>」、
//   ap_mark.png（原尺寸）/ ap_mid.png / ap_end.png / ap_stuck.png、vision/vNN.png、ap_summary.json 字段（见 finish）。
#include "autoplay_host.h"
#include "ap_default.h"
#include "../../runtime/include/s2a_docs.h"   // 文档根唯一取法
#include <TargetConditionals.h>
#include <dirent.h>
#include <fcntl.h>
#include <math.h>
#include <dlfcn.h>
#include <pthread.h>
#include <stdatomic.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <time.h>
#include <unistd.h>
#include <CoreGraphics/CoreGraphics.h>
#include <CoreFoundation/CoreFoundation.h>
#include <ImageIO/ImageIO.h>
#define LOG s2a_ap_log
// 弱链接[autoplay]：s2a_ap_passes（渲染器提供；没登记时进局读数只用绘制数）
// 弱链接[autoplay]：s2a_ap_audio_mark（声音层提供；没登记时 MARK 处报红）
// 弱链接[autoplay]：s2a_thread_dump（原生层 thread.c 提供；单测假宿主 / 真值垫片没有）
// 弱链接[autoplay]：s2a_dump_threads（渲染器 gal_core.m 提供；同上）
// 弱链接[autoplay]：s2a_widen_game（runtime/src/widen.c 提供：游戏自己出宽图 = 第二层；没登记按游戏不知道宽屏、触点画布 1280×720）
#pragma weak s2a_ap_passes       // 没登记（老宿主 / 单测假宿主 / 通用模式）：进局读数只用绘制数这一路
#pragma weak s2a_ap_audio_mark   // 声音层没登记时不挡链接：MARK 时报红
// 原生层现场导出（runtime/include/s2a_native.h）：没进可玩就收局时打一份。弱引用：单测假宿主没有
void s2a_thread_dump(void); int s2a_dump_threads(const char *why);
#pragma weak s2a_thread_dump
#pragma weak s2a_dump_threads
// 驾驶员点触换算的画布宽（同 ios/vpad.m switchPoint，11-02 体验线 touch-space）：游戏不知道宽屏（宿主放宽 / 原比例）读 1280×720；
//   游戏自己出宽图（第二层）读真实出图宽，这时交 0 = 驾驶员按截图画面比例算宽（宽 = 高 720 × 宽高比）。11-02 普查银河2（宿主放宽）按 1564 宽换算，点「开始」偏右约 22%
int s2a_widen_game(void);
#pragma weak s2a_widen_game
static int touch_canvas_w(void) { return s2a_widen_game && s2a_widen_game() ? 0 : 1280; }

// ---- 时钟 / 开关 ----
static uint64_t real_ns(void) { struct timespec ts; clock_gettime(CLOCK_MONOTONIC, &ts); return (uint64_t)ts.tv_sec * 1000000000ull + (uint64_t)ts.tv_nsec; }
static double envd(const char *k, double d) { const char *e = getenv(k); return e && *e ? atof(e) : d; }
// 判据时钟：S2A_AP_TIMESCALE=k（缺省 1）时自动玩家的秒按真秒的 1/k 走（单测注入时间：模拟游戏同倍率出帧）。等出图 / 等模型按真秒
static double tscale(void) { static double k; if (k <= 0) { k = envd("S2A_AP_TIMESCALE", 1); if (k <= 0) k = 1; } return k; }
static uint64_t now_ns(void) { return (uint64_t)((double)real_ns() * tscale()); }
static void ap_sleep_us(double us) { usleep((useconds_t)(us / tscale())); }
static uint64_t g_t0;   // 自动玩家起点（判据时钟）
// 局时预算：S2A_RUN_S（run_mac.sh 设的局秒数，宿主到点收局）给了时，离收局不足 S2A_AP_VIS_LEFT_S（缺省 45）秒不再问模型（一问 5–90 秒），
//   不足 S2A_AP_END_LEFT_S（缺省 20）秒还没进局就主动收尾写结论
static double g_vis_s;
static double run_left_s(void) {   // 宿主开了局时顺延（S2A_RUN_EXTEND_MAX）就把等模型的秒数（封顶）加回来，与 host_main.c run_timer 同口径
    static double rs = -1, ext = -1; if (rs < 0) { rs = envd("S2A_RUN_S", 0); ext = envd("S2A_RUN_EXTEND_MAX", 0); }
    return rs > 0 ? rs + (g_vis_s < ext ? g_vis_s : ext) - (double)(now_ns() - g_t0) / 1e9 / tscale() : 1e9; }
// ---- MARK 后段登记（autoplay_host.h s2a_ap_seg_open；11-04 普查提前收局）：段表只增不删，销号记结束时刻；收局判据只看「还有没有没销号的段」----
enum { SEG_MAX = 16 };
static struct { char name[48]; int open, perturb; } g_seg[SEG_MAX]; static int g_seg_n; static uint64_t g_seg_perturb_end;   // 最后一个改出帧状态的段销号时刻（判据时钟）
static pthread_mutex_t g_seg_mu = PTHREAD_MUTEX_INITIALIZER;
__attribute__((visibility("default"), used)) int s2a_ap_seg_open(const char *name, int perturb) {
    pthread_mutex_lock(&g_seg_mu); int id = g_seg_n < SEG_MAX ? g_seg_n++ : -1;
    if (id >= 0) { snprintf(g_seg[id].name, sizeof g_seg[id].name, "%s", name ? name : "?"); g_seg[id].open = 1; g_seg[id].perturb = perturb; }
    pthread_mutex_unlock(&g_seg_mu);
    if (id < 0) LOG("【红】自动玩家：MARK 后段表满（%d 段），「%s」没登记上，提前收局不等它", SEG_MAX, name ? name : "?");
    else LOG("自动玩家：MARK 后段开始「%s」（#%d%s，帧 %llu）", g_seg[id].name, id, perturb ? "，改出帧状态" : "", (unsigned long long)s2a_ap_frames());   // 帧号给判据剔帧（tools/ab_span.py）
    return id;
}
__attribute__((visibility("default"), used)) void s2a_ap_seg_close(int id) {
    if (id < 0 || id >= SEG_MAX) return;
    pthread_mutex_lock(&g_seg_mu); int was = g_seg[id].open; g_seg[id].open = 0; if (was && g_seg[id].perturb) g_seg_perturb_end = now_ns(); pthread_mutex_unlock(&g_seg_mu);
    if (was) LOG("自动玩家：MARK 后段结束「%s」（#%d，帧 %llu）", g_seg[id].name, id, (unsigned long long)s2a_ap_frames());
}
static int seg_pending(char *names, size_t cap) {   // 没销号的段数；names 拼上段名（日志用）
    int n = 0; if (cap) *names = 0; pthread_mutex_lock(&g_seg_mu);
    for (int i = 0; i < g_seg_n; i++) if (g_seg[i].open) { n++; if (cap) snprintf(names + strlen(names), cap - strlen(names), "%s「%s」", n > 1 ? "、" : "", g_seg[i].name); }
    pthread_mutex_unlock(&g_seg_mu); return n;
}
static uint64_t seg_perturb_end(void) { pthread_mutex_lock(&g_seg_mu); uint64_t t = g_seg_perturb_end; pthread_mutex_unlock(&g_seg_mu); return t; }
static int g_on = -1; static pthread_once_t g_once = PTHREAD_ONCE_INIT;
static void *ap_main(void *);
// ---- 实时通道（S2A_AP_LIVE=<文件>）：人边看边往文件里追加行，只认两种：REC:<名> = 录下一次出图（graphics/nvn/docs/frame_replay.md，
//   要同时开 S2A_FRAME_REC=<目录>）；PASS:<名> = 实局下一帧打逐笔日志（host.log [pass] 行）并截图存 <帧录目录或局目录>/<名>.png
//   （直连缺陷线 11-01：双人成行录像回放写不回 250 张 GPU 私有贴图，查黑圆盘只能看实局那一帧的逐笔）。11-01 驾驶员重构时整条通道被删，文档仍写着 REC，直连缺陷线为双人成行黑圆盘白跑一局；
//   导航归 AI 驾驶员，按键 / 点触行不再收（记「不认」） ----
// 帧录接口 nvn_frec_request 在直连图形层（graphics/nvn/gfx/nvn/nvn_frame_rec.inc）：直连库是按游戏运行时加载的动态库、不链进宿主，
//   每次收到 REC 时按名字现找（同 graphics/metal s2a_ap_passes）；单测假宿主自己导出同名函数
static char g_dir[1024]; static void out_dir(void);   // 下面定义（实时通道单独起时也要用输出目录）
static int live_key(const char *keys);   // 实时通道 KEY:<键串>：只在自动玩家没开时按（下面 key_parse 之后定义）
static void *live_main(void *a) {
    const char *path = a; long off = 0; char line[256];
    for (;;) {
        FILE *f = fopen(path, "r");
        if (f) { fseek(f, off, SEEK_SET);
            while (fgets(line, sizeof line, f)) { if (!strchr(line, '\n')) break;   // 半行（还在写）：下回再读
                off = ftell(f); line[strcspn(line, "\r\n")] = 0; if (!*line) continue;
                // 读到就先记一行（帧号）、再找接口 / 处理：11-01 直连缺陷线双人成行局 8 条 PASS 只生效第 1 条、后 7 条没有任何记录，分不清没读到还是卡在处理里
                LOG("自动玩家：实时通道读到「%s」（帧 %llu）", line, (unsigned long long)s2a_ap_frames());
                if (!strncmp(line, "REC:", 4) && line[4]) {
                    static void (*rec)(const char *); if (!rec) rec = (void (*)(const char *))dlsym(RTLD_DEFAULT, "nvn_frec_request");   // 找到一次就留着，不每条都拿动态库加载锁
                    if (rec) { LOG("自动玩家：实时通道 %s → 录下一次出图（帧 %llu）", line, (unsigned long long)s2a_ap_frames()); rec(line + 4); }
                    else LOG("【红】自动玩家：实时通道 %s 录不了：找不到直连图形层的帧录（nvn_frec_request；通用模式 / 直连库没加载）", line);
                } else if (!strncmp(line, "PASS:", 5) && line[5] && !strchr(line + 5, '/')) {
                    static void (*pd)(long); static void (*sh)(long, const char *);
                    if (!pd) pd = (void (*)(long))dlsym(RTLD_DEFAULT, "dm_gfx_passdump_next");
                    if (!sh) sh = (void (*)(long, const char *))dlsym(RTLD_DEFAULT, "dm_gfx_shot_at");
                    // 截图目录：S2A_FRAME_REC（可带「<帧号>[,…]:」前缀）的目录，没开帧录就局目录
                    const char *fr = getenv("S2A_FRAME_REC"), *dir = fr && *fr ? fr : g_dir; const char *c = fr && dir == fr ? strchr(fr, ':') : NULL;
                    if (c && strspn(fr, "0123456789,") == (size_t)(c - fr)) dir = c + 1;
                    if (pd && sh && dir) { char shot[1200]; mkdir(dir, 0755); snprintf(shot, sizeof shot, "%s/%s.png", dir, line + 5);
                        LOG("自动玩家：实时通道 %s → 下一帧逐笔日志 + 截图 %s（帧 %llu）", line, shot, (unsigned long long)s2a_ap_frames()); pd(1); sh(1, shot);
                        LOG("自动玩家：实时通道 %s 已交给直连层", line); }
                    else LOG("【红】自动玩家：实时通道 %s 做不了：%s", line, !dir ? "没有截图目录（S2A_FRAME_REC / S2A_AUTOPLAY_OUT 都没设）" : "找不到直连图形层的 dm_gfx_passdump_next / dm_gfx_shot_at（通用模式 / 直连库没加载）");
                } else if (!strncmp(line, "KEY:", 4) && g_on == 0) {   // 自动玩家没开（人玩 / 脚本局）：按脚本给的键，按完才读下一行
                    if (!live_key(line + 4)) LOG("【红】自动玩家：实时通道 %s 认不得（键串同驾驶员答案：A、A:2、L|R、LS_RIGHT:3，长按 ≤ 3 秒；不收点触 / 二号手柄）", line);
                } else LOG("自动玩家：实时通道不认的行「%s」（只认 REC:<名> / PASS:<名>，自动玩家没开时另认 KEY:<键串>；开着时导航归 AI 驾驶员）", line); }
            fclose(f); }
        usleep(200000);
    }
    return NULL;
}
// 实时通道单独起（11-02 维护者「为什么各线都要我配合真机」：自动玩家走不到的页（派对玩家人数页）、人手玩的局也要能按需抓逐笔）：
//   设了 S2A_AP_LIVE 就起读通道线程，自动玩家开不开都起；只认 REC / PASS，不碰按键、不触发自动玩家收局。相对路径按输出目录（iOS = App 的 Documents）解析
static pthread_once_t g_live_once = PTHREAD_ONCE_INIT;
static void live_start(void) {
    const char *live = getenv("S2A_AP_LIVE"); if (!live || !*live) return;
    out_dir(); static char lp[1100]; if (live[0] == '/') snprintf(lp, sizeof lp, "%s", live); else snprintf(lp, sizeof lp, "%s/%s", g_dir, live);
    pthread_t lt; pthread_create(&lt, NULL, live_main, lp); pthread_detach(lt); LOG("自动玩家：实时通道 %s（只认 REC:<名> / PASS:<名>；截图目录 %s）", lp, g_dir);
}
static void ap_start(void) {
    const char *hud = getenv("MTL_HUD_ENABLED");
    if ((hud && !strcmp(hud, "1")) || CFPreferencesGetAppBooleanValue(CFSTR("MetalHUDForceEnabled"), kCFPreferencesCurrentApplication, NULL))
        LOG("【黄】自动玩家：Metal HUD 已请求，仅供手动观察；本局截图、存帧、自动玩家与满屏判据不可用。请关闭 Metal HUD 后重新起局验收。");
    g_t0 = now_ns(); pthread_t th; pthread_create(&th, NULL, ap_main, NULL); pthread_detach(th);
    pthread_once(&g_live_once, live_start);
}
int s2a_autoplay_on(void) {   // 缺省开不开见 ap_default.h（玩家入口 iPhone / Mac 前端缺省关，开发用 Mac 宿主缺省开）
    if (g_on < 0) g_on = s2a_autoplay_default(getenv("S2A_AUTOPLAY"));
    if (g_on) pthread_once(&g_once, ap_start); else pthread_once(&g_live_once, live_start);
    return g_on;
}

// ---- 按键 / 点触注入（服务接入线 HID 每次采样来取）----
static _Atomic uint32_t g_mask, g_mask2; static _Atomic int g_pads = 1;
uint32_t s2a_autoplay_keys(void) { return atomic_load(&g_mask); }
// 二号手柄（强制本地合作，如双人成行要二号玩家「Join」、两人分选角色）：驾驶员答「2:键」时只按二号手柄、不带前缀的只按一号（各管各的）；
//   第一次用到时 s2a_autoplay_pads 变 2，服务接入线 HID 据此接上第二个手柄
__attribute__((visibility("default"), used)) uint32_t s2a_autoplay_keys2(void) { return atomic_load(&g_mask2); }
__attribute__((visibility("default"), used)) int s2a_autoplay_pads(void) { return atomic_load(&g_pads); }
// 点触：从帧 g_tc_at 起按住到 g_tc_until；Start / End 按「服务层来取」给（服务层采样触屏的节奏和游戏帧不同步，按帧号给时那一帧没被采到，游戏就永远收不到 Start）。
//   一次点触里：到帧后第一次来取给 Start，到时（≥ 最后一帧）后第一次来取给 End、随即结束，各一次
enum { TC_IDLE, TC_PEND, TC_DOWN };
static _Atomic uint64_t g_tc_at, g_tc_until, g_tc_end_f; static _Atomic uint32_t g_tc_xy; static _Atomic int g_tc_st;
static void tc_set(int32_t x, int32_t y, uint32_t hold) {
    // 上一下还没松开就等它松开、再空 2 帧没触点，游戏才认得出是新的一下（墙钟上限 3 秒，游戏停帧不死等）
    uint64_t dl = real_ns() + 3000000000ull;
    while (atomic_load(&g_tc_st) != TC_IDLE && real_ns() < dl) usleep(2000);
    while (s2a_ap_frames() < atomic_load(&g_tc_end_f) + 2 && real_ns() < dl) usleep(2000);
    uint64_t at = s2a_ap_frames() + 1; atomic_store(&g_tc_st, TC_IDLE); atomic_store(&g_tc_xy, (uint32_t)x << 16 | (uint32_t)y);
    atomic_store(&g_tc_at, at); atomic_store(&g_tc_until, at + hold); atomic_store(&g_tc_st, TC_PEND);
}
__attribute__((visibility("default"), used)) int s2a_autoplay_touch(int32_t *xy, uint32_t *attr) {
    int st = atomic_load(&g_tc_st); if (st == TC_IDLE) return 0;
    uint64_t f = s2a_ap_frames(); if (f < atomic_load(&g_tc_at)) return 0;
    uint32_t p = atomic_load(&g_tc_xy); xy[0] = (int32_t)(p >> 16); xy[1] = (int32_t)(p & 0xffff);
    int last = f + 1 >= atomic_load(&g_tc_until);
    attr[0] = (st == TC_PEND ? 1u : 0u) | (last ? 2u : 0u);   // TouchAttribute：Start = 1、End = 2
    if (last) atomic_store(&g_tc_end_f, f);
    atomic_compare_exchange_strong(&g_tc_st, &st, last ? TC_IDLE : TC_DOWN);
    return 1;
}
// 摇杆模拟量（services InputPump 按符号查）：不再回放录手柄，恒返回 0 = 没有模拟量，服务层按伪键满偏
__attribute__((visibility("default"), used)) int s2a_autoplay_sticks(int32_t *s) { (void)s; return 0; }

// ---- 截图 / 摘要（32×18 格亮度均值）----
#define GW 32
#define GH 18
#define NG (GW * GH)
static uint8_t *g_buf; static int32_t g_cap, g_w, g_h;
static _Atomic uint64_t g_grab_t0;   // 正在等出图的起点（real_ns，0 = 没在等）：「显卡卡住」只量这一段
static int grab_(void) {   // 取最近一次出图到 g_buf；返回 1 = 有图
    int32_t w = 0, h = 0, need = nxgal_screenshot(NULL, 0, &w, &h); if (need <= 0) return 0;
    if (need > g_cap) { free(g_buf); g_buf = malloc((size_t)need); g_cap = g_buf ? need : 0; if (!g_buf) return 0; }
    if (nxgal_screenshot(g_buf, g_cap, &w, &h) != need) return 0;
    g_w = w; g_h = h; return 1;
}
static int grab(void) { atomic_store(&g_grab_t0, real_ns()); int r = grab_(); atomic_store(&g_grab_t0, 0); return r; }
static void digest_buf(const uint8_t *buf, int32_t w, int32_t h, float out[NG]) {   // 每格隔 4 像素取亮度均值（tools/widen_accept.py 离线同算法）
    for (int gy = 0; gy < GH; gy++) for (int gx = 0; gx < GW; gx++) {
        int x0 = gx * w / GW, x1 = (gx + 1) * w / GW, y0 = gy * h / GH, y1 = (gy + 1) * h / GH; double s = 0; int n = 0;
        for (int y = y0; y < y1; y += 4) { const uint8_t *r = buf + (size_t)y * w * 4; for (int x = x0; x < x1; x += 4) { const uint8_t *p = r + x * 4; s += 0.114 * p[0] + 0.587 * p[1] + 0.299 * p[2]; n++; } }
        out[gy * GW + gx] = n ? (float)(s / n) : 0; }
}
// 细节摘要（11-02 导航 N4 Minecraft「准备游玩」页）：焦点框 / 高亮是约 2 像素的细线，每格隔 4 像素取均值的摘要采不到、也改不动均值，
//   方向键挪了焦点被判「画面没变」拉黑，焦点到了「游玩」上 A 又因先前焦点在「返回」时按过被拒收。每格再记亮度梯度均值：
//   隔 2 行逐像素算横向梯度、隔 2 列逐像素算纵向梯度，细线进出格子时这个值变化大，均值几乎不动
// 隔点采样（11-04 能耗线 / 维护者定）：行、列方向都每 2 个像素取一对相邻差，每格仍是均值，工作量约为原来的 1/2（截图线程 86.9% 在这里）
static void edge_buf(const uint8_t *buf, int32_t w, int32_t h, float out[NG]) {
    static double s[NG]; static int n[NG]; memset(s, 0, sizeof s); memset(n, 0, sizeof n);
    for (int y = 0; y < h; y += 2) { const uint8_t *r = buf + (size_t)y * w * 4; int gy = y * GH / h;
        for (int x = 0; x + 1 < w; x += 2) { const uint8_t *p = r + x * 4, *q = p + 4; int c = gy * GW + x * GW / w;
            s[c] += fabs((0.114 * p[0] + 0.587 * p[1] + 0.299 * p[2]) - (0.114 * q[0] + 0.587 * q[1] + 0.299 * q[2])); n[c]++; } }
    for (int x = 0; x < w; x += 2) { int gx = x * GW / w;
        for (int y = 0; y + 1 < h; y += 2) { const uint8_t *p = buf + ((size_t)y * w + x) * 4, *q = p + (size_t)w * 4; int c = (y * GH / h) * GW + gx;
            s[c] += fabs((0.114 * p[0] + 0.587 * p[1] + 0.299 * p[2]) - (0.114 * q[0] + 0.587 * q[1] + 0.299 * q[2])); n[c]++; } }
    for (int i = 0; i < NG; i++) out[i] = n[i] ? (float)(s[i] / n[i]) : 0;
}
// 半分辨率亮度（逐像素判据 pix_moved 用）：截图线程算进 g_wl_buf，锁里换到 g_wl_pub，驾驶线程取走时拷进 g_cur_lum（不碰截图线程正在写的 g_buf）
static uint8_t *g_wl_buf, *g_wl_pub, *g_cur_lum; static int32_t g_wl_w, g_wl_h, g_pub_w, g_pub_h, g_cur_lw, g_cur_lh;
static void lum_buf(const uint8_t *buf, int32_t w, int32_t h) {
    int32_t lw = w / 2, lh = h / 2; if (lw < 1 || lh < 1) { g_wl_w = 0; return; }
    if (lw * lh != g_wl_w * g_wl_h) { uint8_t *n = realloc(g_wl_buf, (size_t)lw * lh); if (!n) { g_wl_w = 0; return; } g_wl_buf = n; }
    for (int y = 0; y < lh; y++) { const uint8_t *r = buf + (size_t)(2 * y) * w * 4; for (int x = 0; x < lw; x++) { const uint8_t *p = r + 2 * x * 4; g_wl_buf[(size_t)y * lw + x] = (uint8_t)(0.114 * p[0] + 0.587 * p[1] + 0.299 * p[2]); } }
    g_wl_w = lw; g_wl_h = lh;
}
static void lum_publish(void) {   // 持 g_wm：截图线程把这帧换到公开那份（指针互换，不拷）
    if (!g_wl_w) return; uint8_t *t = g_wl_pub; g_wl_pub = g_wl_buf; g_wl_buf = t; int32_t pw = g_pub_w, ph = g_pub_h; g_pub_w = g_wl_w; g_pub_h = g_wl_h; g_wl_w = pw; g_wl_h = ph;
}
static void lum_take(void) {   // 持 g_wm：驾驶线程拷走公开那份
    if (!g_pub_w || !g_wl_pub) return; size_t n = (size_t)g_pub_w * g_pub_h;
    if ((size_t)g_cur_lw * g_cur_lh != n) { uint8_t *b = realloc(g_cur_lum, n); if (!b) return; g_cur_lum = b; }
    memcpy(g_cur_lum, g_wl_pub, n); g_cur_lw = g_pub_w; g_cur_lh = g_pub_h;
}
static float ddiff(const float *a, const float *b) { double s = 0; for (int i = 0; i < NG; i++) s += fabsf(a[i] - b[i]); return (float)(s / NG); }
static float dncc(const float *a, const float *b) {   // 零均值归一化相关（−1..1）：压暗 / 叠一行字时结构仍高，换成另一页时低
    double sa = 0, sb = 0; for (int i = 0; i < NG; i++) { sa += a[i]; sb += b[i]; } sa /= NG; sb /= NG;
    double ab = 0, aa = 0, bb = 0; for (int i = 0; i < NG; i++) { double x = a[i] - sa, y = b[i] - sb; ab += x * y; aa += x * x; bb += y * y; }
    if (aa < 1e-6 || bb < 1e-6) return aa < 1e-6 && bb < 1e-6 ? 1.0f : 0.0f;
    return (float)(ab / sqrt(aa * bb));
}
// 格间标准差（量级 0–127）：< 4 视为整屏纯色（整屏白闪 / 黑场），纯色页 dncc 退化成 1.0、不能当结构证据
//   （11-03 普查：过场白闪→黑「亮度 255→0、结构相关 1.00」被误判成压暗暂停页，+ 记成开关，翻倍等待 150–470 秒）
static float gstd(const float *a) { double s = 0, v = 0; for (int i = 0; i < NG; i++) s += a[i]; s /= NG; for (int i = 0; i < NG; i++) v += (a[i] - s) * (a[i] - s); return (float)sqrt(v / NG); }
// ---- 逻辑速度探测（S2A_AP_SPEED=1；60 帧开 / 关对照 tools/ab_pair.sh fps60 设，判据 tools/fps_speed_judge.py 读两局日志）----
// 量「固定一段时钟里游戏逻辑走了多远」：按时钟推摇杆（先右摇杆转镜头，画面不跟着横移再试左摇杆），推的期间按时钟连拍，
//   量相邻两张整幅的横向位移 ÷ 时钟间隔；起步 0.3 秒后的稳段把位移、时长各自累加，速度 = 位移和 ÷ 时长和（像素 / 秒，按 128 宽缩略图）。
//   按真实时间推进（或已补偿）的游戏开 / 关两局速度相同；按帧推进没补偿的，60 帧局约快一倍。左右各推 SP_N 次，判据取中位
#define SPW 128
#define SPH 72
#define SP_N 3
#define SP_MINS 5   // 一推稳段至少这么多样本才算有效推
// 游戏时钟（纳秒，同 now_ns 口径）：速度 = 位移 ÷ 游戏时间，按游戏自己走的时间量，不按自动玩家线程醒来的墙钟。宿主给了 s2a_ap_game_ns（当前已出帧的游戏时间）/
//   s2a_ap_shot_ns（本线程上一次 nxgal_screenshot 拍到的那帧的游戏时间）就用，没给（真宿主：游戏按真实时间出帧）用 now_ns。
//   11-02 合入线 gate-host 无缓存全套负载 200+：假宿主出帧追不上标称节拍、拍图线程醒得晚，按墙钟量出的帧率比 q 塌到 1、推一下只拍到 4 张，㉜ ㊴ 假红
static uint64_t (*g_game_ns)(void), (*g_shot_ns)(void); static int g_clk_init;
static void clk_init(void) { if (!g_clk_init) { g_game_ns = (uint64_t (*)(void))dlsym(RTLD_DEFAULT, "s2a_ap_game_ns"); g_shot_ns = (uint64_t (*)(void))dlsym(RTLD_DEFAULT, "s2a_ap_shot_ns"); g_clk_init = 1;
    if (!g_game_ns || !g_shot_ns) g_game_ns = g_shot_ns = NULL;   // 两个要么都给要么都不用：混用两种时钟量出的速度没意义
    LOG("逻辑速度探测：时间按%s", g_game_ns ? "宿主游戏时钟（s2a_ap_game_ns / s2a_ap_shot_ns）" : "自动玩家时钟（宿主没给游戏时钟）"); } }
static uint64_t game_ns(void) { clk_init(); return g_game_ns ? g_game_ns() : now_ns(); }
static uint64_t shot_ns(void) { clk_init(); return g_shot_ns ? g_shot_ns() : now_ns(); }   // grab() 之后调
static void game_sleep_us(double us) {   // 等游戏时间走过 us（没给游戏时钟时同 ap_sleep_us）；游戏 30 真秒不出帧就不等了
    uint64_t t1 = game_ns() + (uint64_t)(us * 1000), dl = real_ns() + 30000000000ull; ap_sleep_us(us);
    while (game_ns() < t1 && real_ns() < dl) usleep(2000); }
static void sp_luma(float *out) {   // g_buf（BGRA）→ SPW×SPH 亮度（每格取中心像素）
    for (int y = 0; y < SPH; y++) for (int x = 0; x < SPW; x++) {
        const uint8_t *p = g_buf + ((size_t)((y * 2 + 1) * g_h / (SPH * 2)) * g_w + (size_t)((x * 2 + 1) * g_w / (SPW * 2))) * 4;
        out[y * SPW + x] = (float)(0.114 * p[0] + 0.587 * p[1] + 0.299 * p[2]); }
}
static int sp_shift(const float *a, const float *b, double *best) {   // b 相对 a 的整幅横向位移（像素，±40 内搜；中间一半行、两侧各留 40 列），零均值归一化相关最大者
    int bd = 0; *best = -2;
    for (int d = -40; d <= 40; d++) {
        double sa = 0, sb = 0, n = 0;
        for (int y = SPH / 4; y < SPH * 3 / 4; y++) for (int x = 40; x < SPW - 40; x++) { sa += a[y * SPW + x]; sb += b[y * SPW + x + d]; n++; }
        sa /= n; sb /= n; double ab = 0, aa = 0, bb = 0;
        for (int y = SPH / 4; y < SPH * 3 / 4; y++) for (int x = 40; x < SPW - 40; x++) { double u = a[y * SPW + x] - sa, v = b[y * SPW + x + d] - sb; ab += u * v; aa += u * u; bb += v * v; }
        double c = aa > 1e-6 && bb > 1e-6 ? ab / sqrt(aa * bb) : -1;
        if (c > *best) { *best = c; bd = d; }
    }
    return bd;
}
// 推 key 至少 1.2 秒游戏时间，稳段样本不到 SP_MINS 就接着推（拍图线程醒得慢时按样本数收，封顶 6 秒游戏时间），回稳段速度（像素 / 秒，带方向）；拍不到图回 NAN
static double sp_push(uint32_t key, int *samples) {
    static float a[SPW * SPH], b[SPW * SPH]; double sx = 0, st = 0; int n = 0;
    *samples = 0; if (!grab()) return NAN; sp_luma(a);
    uint64_t t0 = shot_ns(), ta = t0; atomic_store(&g_mask, key);
    while (game_ns() < t0 + 1200000000ull || (n < SP_MINS && game_ns() < t0 + 6000000000ull)) {
        ap_sleep_us(40000); if (!grab()) continue; uint64_t tb = shot_ns(); sp_luma(b); double c; int d = sp_shift(a, b, &c);
        if (ta >= t0 + 300000000ull && c > 0.5) { sx += d; st += (tb - ta) / 1e9; n++; }
        memcpy(a, b, sizeof a); ta = tb;
    }
    atomic_store(&g_mask, 0); ap_sleep_us(500000);
    *samples = n; return st > 0 ? sx / st : NAN;
}
static int speed_probe_once(void); static void settle(double wait_real_s);
static int speed_ab(void);
static int g_ab_retry;   // 1 = 第一轮同局 A/B 帧率涨了却量不出画面运动，局内段跑一阵后再测一轮（见 speed_ab 末尾）
static void speed_probe(void) {
    const char *e = getenv("S2A_AP_SPEED"); if (!e) return;
    if (!strcmp(e, "ab")) { int sg = s2a_ap_seg_open("逻辑速度同局 A/B", 1); g_ab_retry = speed_ab(); s2a_ap_seg_close(sg); return; }
    if (strcmp(e, "1")) return;
    if (speed_probe_once()) return;
    // 两根摇杆都推不动：多半停在局内菜单 / 对话（11-02 异度3 存档读进来停在「休息地点」菜单）。按一下 B 退出、等画面稳定再探一轮
    LOG("逻辑速度探测：两根摇杆都推不动画面，按一下 B 退出菜单再探一轮");
    // B 按住到游戏至少读过一帧（宿主再出 2 帧）：只按墙钟 0.15 秒时，出帧慢的机器上游戏一帧都没采到就松开了，B 等于没按
    { atomic_store(&g_mask, S2A_AP_B); uint64_t f = s2a_ap_frames(), dl = real_ns() + 15000000000ull; ap_sleep_us(150000);
      while (s2a_ap_frames() < f + 2 && real_ns() < dl) usleep(2000); atomic_store(&g_mask, 0); } settle(3.0);
    if (!speed_probe_once()) LOG("逻辑速度探测：按 B 后两根摇杆仍推不动画面，判不出");
}
static const struct { uint32_t l, r; const char *name; } g_sticks[] = {{S2A_AP_RS_LEFT, S2A_AP_RS_RIGHT, "右摇杆"}, {S2A_AP_LS_LEFT, S2A_AP_LS_RIGHT, "左摇杆"}};
static int dcmp(const void *a, const void *b) { double x = *(const double *)a, y = *(const double *)b; return x < y ? -1 : x > y; }
// 用一根摇杆左右各推 SP_N 次：有效推（稳段 ≥ 5 样本、|v| ≥ 3）≥ SP_N 次回 1，*med = 有效推 |v| 中位、*fps = 探测期间出图帧率；tag 进日志行
static int stick_probe(int s, const char *tag, double *med, double *fps) {
    uint64_t f0 = s2a_ap_frames(), t0 = game_ns(); double v[2 * SP_N], good[2 * SP_N]; int ok = 0;
    for (int i = 0; i < 2 * SP_N; i++) { int n; v[i] = sp_push(i % 2 ? g_sticks[s].r : g_sticks[s].l, &n);
        LOG("逻辑速度探测%s：%s%s推 #%d 横移 %.1f 像素/秒（稳段 %d 样本）", tag, g_sticks[s].name, i % 2 ? "右" : "左", i / 2 + 1, v[i], n);
        if (n >= SP_MINS && fabs(v[i]) >= 3) good[ok++] = fabs(v[i]); }
    *fps = (s2a_ap_frames() - f0) / ((game_ns() - t0) / 1e9);
    LOG("逻辑速度探测%s：%s %d / %d 推画面跟着横移，探测期间出图 %.1f 帧/秒", tag, g_sticks[s].name, ok, 2 * SP_N, *fps);
    if (ok < SP_N) return 0;
    qsort(good, (size_t)ok, sizeof good[0], dcmp); *med = ok % 2 ? good[ok / 2] : (good[ok / 2 - 1] + good[ok / 2]) / 2; return 1;
}
static int speed_probe_once(void) {   // 1 = 有一根摇杆推得动画面（读数已打）
    for (int s = 0; s < 2; s++) { double m, f; if (stick_probe(s, "", &m, &f)) return 1; }   // 这根摇杆有响应就够了；没响应（2D 游戏右摇杆不动镜头）再试左摇杆
    return 0;
}
// 同局 A/B（S2A_AP_SPEED=ab，11-02 维护者定普查一局判 60 帧逻辑速度）：MARK 后在「60 帧开 → 回原帧率 → 60 帧开」三段各量一次游戏逻辑驱动的运动速度。
//   「变快」= 游戏世界逻辑推进翻倍。量什么（11-02 三轮正反对照定）：
//   ① 推左摇杆让角色走、② 推右摇杆转镜头，各自量整幅画面位移（左右交替推，推住 0.8 秒转身 + 起步后连拍两张），两种分开判、合起来定（见 speed_ab）：
//   同一款里走路和镜头可以一个按时间、一个按帧（异度3 帧率表补了时间步，镜头仍按帧翻倍），只量一种会漏红；
//   ③ 两根摇杆都推不动画面（菜单 / 长椅）→ 不按键量画面自己的运动（NPC / 动画 / 水面）。
//   量法：按固定真实时间间隔 AB_DT（200 ms）连拍两张，128×72 亮度上按 16×16 块做二维块匹配（横 ±40 / 竖 ±16 像素：转镜头快，±16 在 200 ms 里只量到约 80 像素/秒就封顶，11-02 abmix 镜头 60 帧段被压低；SAD 最小、纹理太弱的块不算），
//   取有效块位移模长的均值 ÷ 间隔 = 像素 / 秒；一段取 AB_N 对去掉两头各 20% 的截尾均值（整像素位移有量化台阶，均值比中位稳）。
//   间隔按真实时间定、与出图帧率无关：按真实时间推进的款两段一样，按帧推进的款 60 帧段约快 q 倍。三段用同一种量法（第一段定）。
//   阶段走宿主 s2a_fps_ab_set（runtime/src/fps.c）：2 = 放开（普查 A/B 模式下 60 帧没开的款也放开测开段）、1 = 回原帧率（降档原因 3：出图间隔退回游戏、
//   帧率表与速度槽按关生效，同玩家关 60 帧）、0 = 测完照常。
//   ρ = 开段速度（两段均值）÷ 关段；q = 开段出图帧率（两段均值）÷ 关段。判法同 tools/fps_speed_judge.py（sp_verdict）。11-02 收紧（维护者：普查 A/B 是按帧推进款的唯一兜底，
//   c1102_v2 有结论的 13 款判不出 12）：判不出拆成三类说明——关段已 ≥ 55 帧（原生 60）、q < 1.15（开 60 帧帧率没涨，无倍速风险）、关段速度 < AB_MIN（量不出）；
//   帧率涨了就一定判：ρ ≤ min(1.25, √q) 绿，更快一律红（原先 1.25 < ρ < q/1.25 判不出、q < 1.6 判不出，开着出包）；ρ < 0.8（开段反而慢，场景不一致）判不出。
//   判不出的款不入账（docs/名单_60帧逻辑速度/），60 帧照默认开。
#define SP_BAND 1.25
#define SP_NATIVE 55.0   // 关段出图已 ≥ 这么多帧：游戏本来就 60，开关不改帧率
#define SP_QMIN 1.15     // 开 / 关帧率比低于它：开 60 帧帧率没涨，速度不会变（八方 / FF7 / 星之卡比这类自己限帧的款）
#define AB_DT_US 200000   // 两张之间的游戏时间（真宿主即真实时间；负载下按墙钟等，假宿主游戏只走了几十毫秒、位移不到 1 像素全是量化误差）：长一点位移大、整像素量化误差小（100 ms 时低速款只移 1–2 格，ρ 在量化上飘）
#define AB_N 15
#define AB_MIN 2.0
#define AB_RETRY_S 20.0   // 第一轮量不出时，局内段随机动作跑多久再测（足球小将开球后 20 秒内已在踢）
// 判一项：fon / foff 开 / 关段出图帧率、ρ 速度比、moff 关段速度 → "绿" / "红" / "判不出"，*why 是括号里的说明（同 tools/fps_speed_judge.py sp_verdict）
const char *sp_verdict(double foff, double q, double rho, double moff, const char **why) {   // 不 static：假宿主 t_autoplay verdict 场景直接测
    if (foff >= SP_NATIVE) { *why = "（原生 60：关段已 ≥ 55 帧，开关不改帧率）"; return "判不出"; }
    if (q < SP_QMIN) { *why = "（开 60 帧帧率没涨：q < 1.15，无倍速风险）"; return "判不出"; }
    if (moff < AB_MIN) { *why = "（画面几乎不动，量不出）"; return "判不出"; }
    if (rho < 1 / SP_BAND) { *why = "（开段反而变慢，两段场景不一致）"; return "判不出"; }
    double top = sqrt(q) < SP_BAND ? sqrt(q) : SP_BAND;
    if (rho <= top) { *why = "（逻辑按真实时间推进）"; return "绿"; }
    *why = "（按帧推进，开 60 帧游戏变快）"; return "红";
}
static double flow_pair(const float *a, const float *b) {   // a → b 的平均块位移（像素，128×72 网格，横 ±40 / 竖 ±16 内）；没有有效块回 NAN
    double sum = 0; int nb = 0;
    for (int by = 8; by + 16 <= SPH - 8; by += 16) for (int bx = 8; bx + 16 <= SPW - 8; bx += 16) {
        double m = 0, v = 0; for (int y = 0; y < 16; y++) for (int x = 0; x < 16; x++) m += a[(by + y) * SPW + bx + x]; m /= 256;
        for (int y = 0; y < 16; y++) for (int x = 0; x < 16; x++) { double d = a[(by + y) * SPW + bx + x] - m; v += d * d; }
        if (v / 256 < 16) continue;   // 纹理太弱（平坦天空 / 纯色），匹配不可信
        double best = 1e18; int bdx = 0, bdy = 0;
        for (int dy = -16; dy <= 16; dy++) for (int dx = -40; dx <= 40; dx++) {
            if (by + dy < 0 || by + dy + 16 > SPH || bx + dx < 0 || bx + dx + 16 > SPW) continue;
            double sad = 0; int y = 0;
            for (; y < 16; y++) { for (int x = 0; x < 16; x++) sad += fabs(a[(by + y) * SPW + bx + x] - b[(by + dy + y) * SPW + bx + dx + x]); if (sad > best) break; }   // 超过当前最好就剪掉
            if (y == 16 && (sad < best || (sad == best && dx * dx + dy * dy < bdx * bdx + bdy * bdy))) { best = sad; bdx = dx; bdy = dy; }   // 只比算完的；同分取位移小的
        }
        sum += sqrt((double)(bdx * bdx + bdy * bdy)); nb++;
    }
    return nb ? sum / nb : NAN;
}
enum { K_STILL, K_WALK, K_CAM, K_N };
static const char *const k_name[K_N] = {"不按键", "推左摇杆走", "推右摇杆转"};
static int motion_probe(const char *tag, int kind, double *speed, double *fps) {   // AB_N 对 → 截尾均值速度（像素 / 秒）；kind：左 / 右摇杆左右交替推住量，或不按键。1 = 拍到足够的对
    static float a[SPW * SPH], b[SPW * SPH]; double v[AB_N]; int n = 0; uint64_t f0 = s2a_ap_frames(), t0 = game_ns();
    uint32_t lm = kind == K_WALK ? S2A_AP_LS_LEFT : S2A_AP_RS_LEFT, rm = kind == K_WALK ? S2A_AP_LS_RIGHT : S2A_AP_RS_RIGHT;
    atomic_store(&g_mask, 0);
    for (int i = 0; i < AB_N; i++) {
        if (kind != K_STILL) { atomic_store(&g_mask, i % 2 ? rm : lm); ap_sleep_us(800000); }   // 推住 0.8 秒（转身 + 起步，塞尔达 0.3 秒同帧率两段差 50%，11-02 第四轮）后再拍
        if (!grab()) { atomic_store(&g_mask, 0); continue; } uint64_t ta = shot_ns(); sp_luma(a);
        // 只有量的这段按游戏时间等；推住 / 间歇是节奏，照墙钟
        game_sleep_us(AB_DT_US); int ok = grab(); uint64_t tb = shot_ns(); atomic_store(&g_mask, 0); if (!ok) continue; sp_luma(b);
        double d = flow_pair(a, b); if (!isnan(d) && tb > ta) v[n++] = d / ((tb - ta) / 1e9);
        ap_sleep_us(kind != K_STILL ? 300000 : 100000);
    }
    *fps = (s2a_ap_frames() - f0) / ((game_ns() - t0) / 1e9);
    if (n < AB_N / 2) { LOG("逻辑速度探测%s：%s拍到有效对 %d / %d，不够", tag, k_name[kind], n, AB_N); return 0; }
    qsort(v, (size_t)n, sizeof v[0], dcmp); int lo = n / 5, hi = n - n / 5; double sum = 0; for (int i = lo; i < hi; i++) sum += v[i]; *speed = sum / (hi - lo);
    LOG("逻辑速度探测%s：%s画面运动 %.1f 像素/秒（%d 对截尾均值，间隔 %d ms），探测期间出图 %.1f 帧/秒", tag, k_name[kind], *speed, n, AB_DT_US / 1000, *fps);
    return 1;
}
// 两根摇杆分开量、分开判（11-02 第六轮：异度3 的 60 帧表补了时间步，走路按时间步、镜头按帧——只量走路会把镜头翻倍的款判成假绿）：
//   开①段先各推一次，画面动得起来（≥ AB_MIN）的那几种在三段都量；都推不动才量不按键。每种各自出 ρ / q 判红 / 绿 / 判不出，
//   合起来：任一种红 → 红；量得到的全绿 → 绿；其余判不出。末行按决定结论的那一种报数（普查 census.py 按末行入账）
// 返回 1 = 帧率涨了（q ≥ SP_QMIN）却量不出 / 拍不到画面运动：MARK 那刻画面静止（开球等待、对话），局内段跑一阵再测更可能量得到
static int speed_ab(void) {
    void (*ab)(int) = (void (*)(int))dlsym(RTLD_DEFAULT, "s2a_fps_ab_set");
    if (!ab) { LOG("逻辑速度同局 A/B：判不出：宿主没有 s2a_fps_ab_set（旧宿主）"); return 0; }
    double m[3][K_N] = {{0}}, f[3][K_N] = {{0}}; int ok[3][K_N] = {{0}}, use[K_N] = {0}, nuse = 0;
    ab(2); settle(2.0);
    for (int k = K_WALK; k <= K_CAM; k++) if ((ok[1][k] = motion_probe("（A/B 开①）", k, &m[1][k], &f[1][k])) && m[1][k] >= AB_MIN) { use[k] = 1; nuse++; }
    if (!nuse) { LOG("逻辑速度同局 A/B：两根摇杆都推不动画面，改量不按键时画面自己的运动");
        if ((ok[1][K_STILL] = motion_probe("（A/B 开①）", K_STILL, &m[1][K_STILL], &f[1][K_STILL]))) { use[K_STILL] = 1; nuse = 1; } }
    if (!nuse) { ab(0); LOG("逻辑速度同局 A/B：判不出：拍不到足够的画面"); return 1; }
    ab(1); settle(2.0); for (int k = 0; k < K_N; k++) if (use[k]) ok[0][k] = motion_probe("（A/B 关）", k, &m[0][k], &f[0][k]);
    ab(2); settle(2.0); for (int k = 0; k < K_N; k++) if (use[k]) ok[2][k] = motion_probe("（A/B 开②）", k, &m[2][k], &f[2][k]);
    ab(0);
    int red = -1, green = -1, ngreen = 0, first = -1; double rho[K_N] = {0}, q[K_N] = {0}, mon[K_N] = {0}, fon[K_N] = {0}; const char *vk[K_N] = {0}, *why[K_N] = {0};
    for (int k = 0; k < K_N; k++) {
        if (!use[k]) continue; if (first < 0) first = k;
        if (!ok[0][k] || !(ok[1][k] || ok[2][k])) { vk[k] = "判不出"; why[k] = "（拍不到足够的画面）"; LOG("逻辑速度分项（%s）：判不出：拍不到足够的画面", k_name[k]); continue; }
        mon[k] = ok[1][k] && ok[2][k] ? (m[1][k] + m[2][k]) / 2 : ok[1][k] ? m[1][k] : m[2][k]; fon[k] = ok[1][k] && ok[2][k] ? (f[1][k] + f[2][k]) / 2 : ok[1][k] ? f[1][k] : f[2][k];
        q[k] = f[0][k] > 0 ? fon[k] / f[0][k] : 0; rho[k] = m[0][k] > 0 ? mon[k] / m[0][k] : 0;
        vk[k] = sp_verdict(f[0][k], q[k], rho[k], m[0][k], &why[k]);
        LOG("逻辑速度分项（%s）：%s：关 %.1f → 开 %.1f 像素/秒、出图 %.1f → %.1f 帧/秒，ρ = %.2f、q = %.2f%s", k_name[k], vk[k], m[0][k], mon[k], f[0][k], fon[k], rho[k], q[k], why[k]);
        if (!strcmp(vk[k], "红") && red < 0) red = k; if (!strcmp(vk[k], "绿")) { ngreen++; if (green < 0) green = k; }
    }
    int k = red >= 0 ? red : ngreen == nuse ? green : first; const char *v = red >= 0 ? "红" : ngreen == nuse ? "绿" : "判不出";
    LOG("逻辑速度同局 A/B：%s：%s画面运动 关 %.1f → 开 %.1f 像素/秒、出图 %.1f → %.1f 帧/秒，ρ = %.2f、q = %.2f%s", v, k_name[k], m[0][k], mon[k], f[0][k], fon[k], rho[k], q[k],
        !strcmp(v, vk[k] ? vk[k] : "") && why[k] ? why[k] : "（各项不一致：有的绿、有的判不出）");
    return !strcmp(v, "判不出") && why[k] && (strstr(why[k], "拍不到") || (q[k] >= SP_QMIN && strstr(why[k], "量不出")));
}
static char g_dir[1024] = ".";   // 上面实时通道处已有前置声明
static void out_dir(void) {   // 小结 / 截图写到：S2A_AUTOPLAY_OUT > 逐帧表 S2A_FRAMES_TSV 所在目录（带路径时）> 文档根（S2A_DOCS，否则 $HOME/Documents，runtime/include/s2a_docs.h）> 当前目录
    const char *e = getenv("S2A_AUTOPLAY_OUT"); if (e && *e) { snprintf(g_dir, sizeof g_dir, "%s", e); return; }
    e = getenv("S2A_FRAMES_TSV"); if (e && *e && strrchr(e, '/')) { snprintf(g_dir, sizeof g_dir, "%.*s", (int)(strrchr(e, '/') - e), e); return; }
    e = getenv("S2A_DOCS"); if (e && *e) { snprintf(g_dir, sizeof g_dir, "%s", e); return; }
    char d[1024]; struct stat st; s2a_docs_root(d, sizeof d); if (!stat(d, &st) && S_ISDIR(st.st_mode)) snprintf(g_dir, sizeof g_dir, "%s", d);
}
// 游戏画面在截图里的矩形（脑锻炼竖持：截图两侧是宿主黑边，点触坐标却按整幅截图换算）：四边往里数整列 / 整行近乎纯黑、两侧宽度相差 ≤ 2% 才认是宿主黑边，写 <截图>.rect「x y w h」
static int px_dark(int x, int y) { const uint8_t *p = g_buf + ((size_t)y * g_w + x) * 4; return p[0] <= 8 && p[1] <= 8 && p[2] <= 8; }
static int col_dark(int x) { for (int y = 0; y < g_h; y += 2) if (!px_dark(x, y)) return 0; return 1; }
static int row_dark(int y) { for (int x = 0; x < g_w; x += 2) if (!px_dark(x, y)) return 0; return 1; }
static void png_rect(const char *path, int ow, int oh) {
    if (!g_buf || g_w < 16 || g_h < 16) return;
    int l = 0, r = 0, t = 0, b = 0;
    while (l < g_w / 3 && col_dark(l)) l++; while (r < g_w / 3 && col_dark(g_w - 1 - r)) r++;
    while (t < g_h / 3 && row_dark(t)) t++; while (b < g_h / 3 && row_dark(g_h - 1 - b)) b++;
    if (abs(l - r) > g_w / 50 || l + r < g_w / 50) l = r = 0;
    if (abs(t - b) > g_h / 50 || t + b < g_h / 50) t = b = 0;
    if (!l && !t) return;
    char rp[1300]; snprintf(rp, sizeof rp, "%s.rect", path); FILE *f = fopen(rp, "w"); if (!f) return;
    fprintf(f, "%d %d %d %d\n", (int)((long)l * ow / g_w), (int)((long)t * oh / g_h), (int)((long)(g_w - l - r) * ow / g_w), (int)((long)(g_h - t - b) * oh / g_h)); fclose(f);
}
static void png_write(const char *path, const char *name) {   // 编码 g_buf（最近一次 grab）写 PNG；长边 > 1280 等比缩到 1280（ap_mark.png 存原尺寸：画幅线量出图 / 露空）
    CGColorSpaceRef cs = CGColorSpaceCreateDeviceRGB();
    CGDataProviderRef dp = CGDataProviderCreateWithData(NULL, g_buf, (size_t)g_w * g_h * 4, NULL);
    CGImageRef im = CGImageCreate(g_w, g_h, 8, 32, (size_t)g_w * 4, cs, kCGImageAlphaNoneSkipFirst | kCGBitmapByteOrder32Little, dp, NULL, false, kCGRenderingIntentDefault);
    int ow = g_w, oh = g_h, keep = !strcmp(name, "ap_mark.png");
    if (im && g_w > 1280 && !keep) {
        ow = 1280; oh = (int)((long)g_h * 1280 / g_w);
        CGContextRef cx = CGBitmapContextCreate(NULL, ow, oh, 8, 0, cs, kCGImageAlphaNoneSkipFirst | kCGBitmapByteOrder32Little);
        if (cx) { CGContextSetInterpolationQuality(cx, kCGInterpolationMedium); CGContextDrawImage(cx, CGRectMake(0, 0, ow, oh), im);
            CGImageRef sm = CGBitmapContextCreateImage(cx); CGContextRelease(cx); if (sm) { CGImageRelease(im); im = sm; } else { ow = g_w; oh = g_h; } }
        else { ow = g_w; oh = g_h; }
    }
    CFURLRef u = CFURLCreateFromFileSystemRepresentation(NULL, (const UInt8 *)path, (CFIndex)strlen(path), false);
    CGImageDestinationRef d = u ? CGImageDestinationCreateWithURL(u, CFSTR("public.png"), 1, NULL) : NULL;
    if (d && im) { CGImageDestinationAddImage(d, im, NULL); CGImageDestinationFinalize(d); LOG("自动玩家：截图 %s（%dx%d）", path, ow, oh); png_rect(path, ow, oh); }
    if (d) CFRelease(d); if (u) CFRelease(u); if (im) CGImageRelease(im); CGDataProviderRelease(dp); CGColorSpaceRelease(cs);
}
static void save_png_now(const char *name) {
    if (!grab()) { LOG("自动玩家：截图 %s 失败（还没出图）", name); return; }
    char path[1200]; snprintf(path, sizeof path, "%s/%s", g_dir, name); png_write(path, name);
}
// 截图工作线程：截图要等出图围栏，显卡卡住时会一直等；驾驶线程只投请求、取结果，永不阻塞
static pthread_mutex_t g_wm = PTHREAD_MUTEX_INITIALIZER; static pthread_cond_t g_wc = PTHREAD_COND_INITIALIZER;
static int g_wreq, g_whave; static uint64_t g_wdig_f, g_taken_f = ~0ull; static char g_wpng[64]; static float g_wdig[NG], g_wdig_e[NG];
static void *shot_worker(void *a) {
    (void)a;
    for (;;) {
        pthread_mutex_lock(&g_wm); while (!g_wreq) pthread_cond_wait(&g_wc, &g_wm); int r = g_wreq; char nm[64]; snprintf(nm, sizeof nm, "%s", g_wpng); pthread_mutex_unlock(&g_wm);
        static float d[NG], e[NG]; uint64_t fr = s2a_ap_frames(); int ok = 0;
        if (r == 1) { if (grab()) { digest_buf(g_buf, g_w, g_h, d); edge_buf(g_buf, g_w, g_h, e); lum_buf(g_buf, g_w, g_h); ok = 1; } } else save_png_now(nm);
        pthread_mutex_lock(&g_wm); if (ok) { memcpy(g_wdig, d, sizeof d); memcpy(g_wdig_e, e, sizeof e); g_wdig_f = fr; g_whave = 1; lum_publish(); } g_wreq = 0; pthread_cond_broadcast(&g_wc); pthread_mutex_unlock(&g_wm);
    }
    return NULL;
}
static void worker_start(void) { pthread_t th; pthread_create(&th, NULL, shot_worker, NULL); pthread_detach(th); }
// 截图请求间隔封顶（11-04 能耗线）：驾驶循环每 2 ms 取一次摘要、截图线程一空就再截，全速连轴转——每张 GPU 读回整帧、逐像素算边缘。
//   饥荒真机 MARK 后窗口 S2A_CPUPROF：这条线程 40% 一核（edge_buf 86.9%），按 [能耗] 行 ≈1.42 W、占整机 4.29 W 的三分之一；玩家包里没有自动玩家，
//   这份开销全进了测试局的整机读数。两次截图请求至少隔 S2A_AP_SHOT_MIN_MS（判据时钟，缺省 100 ms；驾驶的等待窗口都在 0.1–0.5 秒）；0 = 不限（旧行为）
static uint64_t g_shot_min_ns = ~0ull, g_wreq_t, g_shots, g_shots_mark = ~0ull;   // g_shots_mark：进局内段时的截图请求数（收局报局内段请求了几次，应为 0）
static uint64_t shot_min_ns(void) {
    if (g_shot_min_ns == ~0ull) { const char *e = getenv("S2A_AP_SHOT_MIN_MS"); g_shot_min_ns = (uint64_t)(e && *e ? atoll(e) : 100) * 1000000ull; }
    return g_shot_min_ns;
}
static int digest(float out[NG], float oute[NG], uint64_t *fr) {   // 非阻塞：有「新出帧」的摘要（均值 + 细节）就取走并返回 1（同一帧不重复给）；空闲就投下一次请求
    int got = 0; pthread_mutex_lock(&g_wm);
    if (g_whave) { if (g_wdig_f != g_taken_f) { memcpy(out, g_wdig, sizeof g_wdig); memcpy(oute, g_wdig_e, sizeof g_wdig_e); *fr = g_taken_f = g_wdig_f; got = 1; lum_take(); } g_whave = 0; }
    if (!g_wreq && now_ns() - g_wreq_t >= shot_min_ns()) { g_wreq = 1; g_wreq_t = now_ns(); g_shots++; pthread_cond_signal(&g_wc); }
    pthread_mutex_unlock(&g_wm); return got;
}
static double shot_stuck_s(void) { uint64_t t = atomic_load(&g_grab_t0); return t ? (real_ns() - t) / 1e9 : 0; }
static int save_png_wait(const char *name, double wait_s) {   // 投截图请求，最多等 wait_s 真秒；返回 1 = 截图线程已处理完这张
    struct timespec ts; uint64_t dl = real_ns() + (uint64_t)(wait_s * 1e9); pthread_mutex_lock(&g_wm);
    for (;;) { if (!g_wreq) break; clock_gettime(CLOCK_REALTIME, &ts); ts.tv_sec += 1; if (real_ns() > dl) { pthread_mutex_unlock(&g_wm); LOG("自动玩家：截图 %s 放弃（截图线程 %.0f 秒没空出来）", name, wait_s); return 0; } pthread_cond_timedwait(&g_wc, &g_wm, &ts); }
    snprintf(g_wpng, sizeof g_wpng, "%s", name); g_wreq = 2; pthread_cond_signal(&g_wc);
    while (g_wreq == 2 && real_ns() < dl) { clock_gettime(CLOCK_REALTIME, &ts); ts.tv_sec += 1; pthread_cond_timedwait(&g_wc, &g_wm, &ts); }
    int done = g_wreq != 2; pthread_mutex_unlock(&g_wm); return done;
}
static void save_png(const char *name) { save_png_wait(name, 3); }
// 人玩时存档提交的截图（ios/vpad.m 调；自动玩家没在跑时才会调到）：另起线程截、写 PNG
static void *snap_thread(void *a) { char *p = a; if (grab()) png_write(p, "ap_mark.png"); free(p); return NULL; }
void s2a_ap_snapshot(const char *path) { pthread_t th; char *p = strdup(path); if (p && !pthread_create(&th, NULL, snap_thread, p)) pthread_detach(th); else free(p); }

// ---- 宿主读数：1 秒窗口的每帧绘制 / 渲染遍数中位 ----
static int cmpu(const void *a, const void *b) { uint32_t x = *(const uint32_t *)a, y = *(const uint32_t *)b; return x < y ? -1 : x > y; }
static void window_med(uint32_t *draws, uint32_t *passes) {   // 采 1 判据秒（每 50 ms 一样本）
    uint32_t d[20], p[20]; int n = 0;
    for (int i = 0; i < 20; i++) { d[n] = s2a_ap_draws(); p[n] = s2a_ap_passes ? s2a_ap_passes() : 0; n++; ap_sleep_us(50000); }
    qsort(d, n, sizeof *d, cmpu); qsort(p, n, sizeof *p, cmpu); *draws = d[n / 2]; *passes = p[n / 2];
}
static uint32_t g_base_d, g_base_p;   // 开局基线：首帧后 3 秒、每秒一窗、三窗中位
static int scene_level(uint32_t *d, uint32_t *p) {   // 返回 1 = 读数到场景量级（绘制 ≥ 3×max(基线, 8) 或 渲染遍数 ≥ 2×max(基线, 2)）
    window_med(d, p);
    uint32_t nd = 3 * (g_base_d > 8 ? g_base_d : 8), np = 2 * (g_base_p > 2 ? g_base_p : 2);
    return *d >= nd || (s2a_ap_passes && *p >= np);
}

// ---- 键名 ----
typedef struct { uint32_t m; float hold; char n[32]; int16_t tx, ty; uint8_t p2; } vkey;   // tx ≥ 0 = 点触（游戏 1280×720）；p2 = 只按二号手柄
static const struct { const char *n; uint32_t m; } k_tab[] = {
    {"A", S2A_AP_A}, {"B", S2A_AP_B}, {"X", S2A_AP_X}, {"Y", S2A_AP_Y}, {"L", S2A_AP_L}, {"R", S2A_AP_R}, {"ZL", S2A_AP_ZL}, {"ZR", S2A_AP_ZR},
    {"PLUS", S2A_AP_PLUS}, {"+", S2A_AP_PLUS}, {"MINUS", S2A_AP_MINUS}, {"-", S2A_AP_MINUS}, {"SL", S2A_AP_SL}, {"SR", S2A_AP_SR},
    {"UP", S2A_AP_UP}, {"DOWN", S2A_AP_DOWN}, {"LEFT", S2A_AP_LEFT}, {"RIGHT", S2A_AP_RIGHT},
    {"LS_UP", S2A_AP_LS_UP}, {"LS_DOWN", S2A_AP_LS_DOWN}, {"LS_LEFT", S2A_AP_LS_LEFT}, {"LS_RIGHT", S2A_AP_LS_RIGHT},
    {"RS_UP", S2A_AP_RS_UP}, {"RS_DOWN", S2A_AP_RS_DOWN}, {"RS_LEFT", S2A_AP_RS_LEFT}, {"RS_RIGHT", S2A_AP_RS_RIGHT},
    // 模型常写的全称（11-02 怪猎统计同意页：大模型连答 3 次 RIGHT_STICK_DOWN，键表里没有被判「没给出可用键」卡死；它要的就是右摇杆下滚）
    {"LEFT_STICK_UP", S2A_AP_LS_UP}, {"LEFT_STICK_DOWN", S2A_AP_LS_DOWN}, {"LEFT_STICK_LEFT", S2A_AP_LS_LEFT}, {"LEFT_STICK_RIGHT", S2A_AP_LS_RIGHT},
    {"RIGHT_STICK_UP", S2A_AP_RS_UP}, {"RIGHT_STICK_DOWN", S2A_AP_RS_DOWN}, {"RIGHT_STICK_LEFT", S2A_AP_RS_LEFT}, {"RIGHT_STICK_RIGHT", S2A_AP_RS_RIGHT}};
#define STICKS 0x00FF0000u   // 位 16–23：左右摇杆四向伪键（位 24 起是 SL / SR，是按键）
// 一个键串 → vkey：A、A:2（长按秒 ≤ 3）、L|R（同按，系统键 / 摇杆不许组合）、TOUCH:x,y（游戏触点画布：高 720、宽 1280，游戏自己出宽图时随画面比例，见 touch_canvas_w）、2:键（只按二号手柄，不许点触）。返回 0 = 不合法
static int key_parse(const char *tok, vkey *k) {
    if (!strncmp(tok, "2:", 2)) { if (!strncmp(tok + 2, "TOUCH:", 6) || !strncmp(tok + 2, "2:", 2) || !key_parse(tok + 2, k)) return 0; k->p2 = 1; snprintf(k->n, sizeof k->n, "%s", tok); return 1; }
    memset(k, 0, sizeof *k); k->tx = k->ty = -1; snprintf(k->n, sizeof k->n, "%s", tok);
    // 点触坐标是游戏画布：高 720、宽随画面比例（宽屏款 > 1280，ios/vpad.m s2a_vpad_read_touch）
    if (!strncmp(tok, "TOUCH:", 6)) { int x = -1, y = -1; if (sscanf(tok + 6, "%d,%d", &x, &y) != 2 || x < 0 || x >= 4096 || y < 0 || y >= 720) return 0; k->tx = (int16_t)x; k->ty = (int16_t)y; return 1; }
    char t2[32]; snprintf(t2, sizeof t2, "%s", tok); char *c = strchr(t2, ':'); if (c) { *c = 0; k->hold = (float)atof(c + 1); if (k->hold > 3) k->hold = 3; if (k->hold < 0) k->hold = 0; }
    int parts = 0;
    for (char *sv, *q = strtok_r(t2, "|", &sv); q; q = strtok_r(NULL, "|", &sv)) { int h = -1;
        for (int i = 0; i < (int)(sizeof k_tab / sizeof *k_tab); i++) if (!strcmp(q, k_tab[i].n)) { h = i; break; }
        if (h < 0) return 0; parts++;
        if (parts > 1 && ((k_tab[h].m & (S2A_AP_PLUS | S2A_AP_MINUS | STICKS)) || (k->m & (S2A_AP_PLUS | S2A_AP_MINUS | STICKS)))) return 0;
        k->m |= k_tab[h].m; }
    if (!k->m) return 0;
    if (k->hold <= 0) k->hold = k->m & STICKS ? 0.4f : 0.1f;   // 摇杆伪键至少推 0.4 秒才看得出位移
    return 1;
}
// 实时通道 KEY 行（自动玩家没开时）：按下、按住 hold 秒、松开，再空 0.1 秒让游戏看到松开；返回 0 = 键串认不得
static int live_key(const char *keys) {
    vkey k; if (!key_parse(keys, &k) || k.tx >= 0 || k.p2) return 0;
    LOG("自动玩家：实时通道 KEY:%s → 按 %.1f 秒（帧 %llu）", keys, k.hold, (unsigned long long)s2a_ap_frames());
    atomic_store(&g_mask, k.m); usleep((useconds_t)(k.hold * 1e6)); atomic_store(&g_mask, 0); usleep(100000);
    return 1;
}
// 记「试过没用」按完整动作：单键连长按秒数（A 与 A:2 是两个动作）、二号手柄的键留 2: 前缀、点触记 TOUCH；
//   一次答多个键记成一组「DOWN+A」（先挪光标再确认是新动作，不能因 DOWN、A 各自试过就算试过）。
//   11-01 普查「驾驶员连续 3 次没给出回答」6 款全是这条：答案被逐键拆开比、长按被当短按，整个滤空（不是超时 / 解析失败）
static const char *key_base(const char *n, char *buf, size_t cap) {
    if (!strncmp(n, "TOUCH:", 6)) return "TOUCH";
    snprintf(buf, cap, "%s", n); return buf;
}
// 走回头路的边（从第 from 页按 keys 回到第 to 页）记次数：返回这是第几次（11-03 归族 C，第 2 次才拉黑）
static int back_edge(int from, int to, const char *keys) {
    static struct { int from, to, n; char k[64]; } e[128]; static int ne;
    for (int i = 0; i < ne; i++) if (e[i].from == from && e[i].to == to && !strcmp(e[i].k, keys)) return ++e[i].n;
    if (ne < 128) { e[ne].from = from; e[ne].to = to; e[ne].n = 1; snprintf(e[ne].k, sizeof e[ne].k, "%s", keys); ne++; }
    return 1;
}
static void tried_add(char *tried, size_t cap, const vkey *ks, int nk) {
    char k[160] = ""; for (int i = 0; i < nk; i++) { char b[40]; snprintf(k + strlen(k), sizeof k - strlen(k), "%s%s", i ? "+" : "", key_base(ks[i].n, b, sizeof b)); }
    char pat[180], cur[320]; snprintf(pat, sizeof pat, ",%s,", k); snprintf(cur, sizeof cur, ",%s,", tried);
    if (!strstr(cur, pat)) snprintf(tried + strlen(tried), cap - strlen(tried), "%s%s", *tried ? "," : "", k);
}

// ---- 注入一键、按画面放行 ----
static int g_presses, g_presses_changed, g_touch_fail;
static float g_chg1[NG];   // 最近一次按键后第一张「变了」的画面（开关识别用：取消暂停的第一帧就是暂停前那一帧，过场随后接着播）
static float g_cur[NG], g_cur_e[NG]; static uint64_t g_cur_f;   // g_cur_e = 同一帧的细节摘要（edge_buf）   // 最近一张摘要（驾驶线程）
static uint64_t g_last_new_f_t;   // 最近一次看到新出帧的时刻（real_ns）：出图停 60 秒收局
// 局内段（测量窗口：MARK 后采帧率 / 功率那段）只看上屏帧计数推进，不截图（11-04 能耗线 / 维护者定）：局内段要的只是「出图停 60 秒」和提前收局
//   「最近 2 秒有新帧」，帧计数就够；原先每 20 ms poll_digest(0) 让截图线程全速连轴转（GPU 读回整帧 + 逐像素边缘），饥荒真机这一段 40% 一核、≈1.42 W。
//   过半 / 收局的单张存档截图（ap_mid / ap_end）照留
static uint64_t g_tick_f = ~0ull;
static void frame_tick(void) { uint64_t f = s2a_ap_frames(); if (f != g_tick_f) { g_tick_f = f; g_last_new_f_t = real_ns(); } }
static int poll_digest(double wait_real_s) {   // 等到下一张新帧摘要（最多 wait_real_s 真秒）；返回 1 = 拿到并更新 g_cur
    uint64_t dl = real_ns() + (uint64_t)(wait_real_s * 1e9);
    for (;;) { float d[NG], e[NG]; uint64_t f; if (digest(d, e, &f)) { memcpy(g_cur, d, sizeof d); memcpy(g_cur_e, e, sizeof e); g_cur_f = f; g_last_new_f_t = real_ns(); return 1; } if (real_ns() >= dl) return 0; usleep(3000); }
}
static const double CHG = 4.0, STAB = 1.5;   // 页变 / 稳定门槛（32×18 格均差）
// 局部变化：至少 3 格亮度差 ≥ 40 也算画面变了（11-01 双人成行二号「Join」→ 加入：两张卡片 + 一行「Ⓐ Proceed」只改 9 格，整屏均差 1.27 < 4，
//   被记成「按了没变」、A 也一直留在试过没用里；同页静止两帧实测最大单格差 ≤ 19、0 格 ≥ 20，换页 36 格 ≥ 40）
static int dlocal(const float *a, const float *b) { int n = 0; for (int i = 0; i < NG; i++) n += fabsf(a[i] - b[i]) >= 40.0f; return n; }
static int moved(const float *a, const float *b) { return ddiff(a, b) >= CHG || dlocal(a, b) >= 3; }
// 动画格（11-02 幻想水浒标题页：下半屏海浪 79 / 576 格自己在动，同一页两张整屏均差 4.9 ≥ CHG、≥ 40 的格 12 个，按 A 次次判「变了」、页也认不回来，75 下全是 A）：
//   按键前空等一小段采这页的亮度包络，最大最小差 ≥ MOT 的格 = 这页自己在动的格，判「按了有没有变」和「是不是同一页」都扣掉它们；
//   静态格不到 1/8 屏（视频 / 整屏动画）退回整屏判法。同页静止两帧实测单格最大差 ≤ 19，MOT 取 20。
//   （10-31 #1153 按静态交集认页，11-01 AI 驾驶员重构时丢了，这里按现结构接回）
static const float MOT = 20.0f; static uint8_t g_mm[NG], g_me[NG]; static int g_mm_n;   // g_me = 细节自己在变的格（动画背景的纹理），判细节变化时扣掉   // g_mm = 当前页动画格（1 = 动），g_mm_n = 动画格数
static int mm_static_ok(const uint8_t *a, const uint8_t *b) { int n = 0; for (int i = 0; i < NG; i++) n += !(a && a[i]) && !(b && b[i]); return n >= NG / 8; }
static int mm_on(void) { return g_mm_n && mm_static_ok(g_mm, NULL); }
static float ddiff_m(const float *a, const float *b) { if (!mm_on()) return ddiff(a, b); double s = 0; int n = 0; for (int i = 0; i < NG; i++) if (!g_mm[i]) { s += fabsf(a[i] - b[i]); n++; } return (float)(s / n); }
static int moved_m(const float *a, const float *b) {
    if (!mm_on()) return moved(a, b);
    int loc = 0; for (int i = 0; i < NG; i++) loc += !g_mm[i] && fabsf(a[i] - b[i]) >= 40.0f;
    return ddiff_m(a, b) >= CHG || loc >= 3;
}
// 零均值相关只算两边都静止的格（ma / mb 为空 = 不扣）；静态格不到 1/8 屏退回整屏 dncc
static float dncc_m(const float *a, const float *b, const uint8_t *ma, const uint8_t *mb) {
    if (!mm_static_ok(ma, mb)) return dncc(a, b);
    double sa = 0, sb = 0; int n = 0; for (int i = 0; i < NG; i++) if (!(ma && ma[i]) && !(mb && mb[i])) { sa += a[i]; sb += b[i]; n++; } sa /= n; sb /= n;
    double ab = 0, aa = 0, bb = 0; for (int i = 0; i < NG; i++) if (!(ma && ma[i]) && !(mb && mb[i])) { double x = a[i] - sa, y = b[i] - sb; ab += x * y; aa += x * x; bb += y * y; }
    if (aa < 1e-6 || bb < 1e-6) return aa < 1e-6 && bb < 1e-6 ? 1.0f : 0.0f;
    return (float)(ab / sqrt(aa * bb));
}
// 采动画格：包络起点放进 pg（问模型前那张，离现在约 2 秒，慢动画也能采到）+ 空等 wait_real_s 真秒里的每张新帧
static const float EDG = 6.0f;   // 细节摘要格变化门槛（亮度梯度均值；真机 2 像素焦点框进出 40 像素宽的格约变 10）
static void mot_sample(const float *pg, double wait_real_s) {
    float lo[NG], hi[NG], elo[NG], ehi[NG]; memcpy(lo, pg, sizeof lo); memcpy(hi, pg, sizeof hi); memcpy(elo, g_cur_e, sizeof elo); memcpy(ehi, g_cur_e, sizeof ehi);
    for (int i = 0; i < NG; i++) { if (g_cur[i] < lo[i]) lo[i] = g_cur[i]; if (g_cur[i] > hi[i]) hi[i] = g_cur[i]; }
    uint64_t dl = real_ns() + (uint64_t)(wait_real_s * 1e9);
    while (real_ns() < dl) { if (!poll_digest(0.2)) continue; for (int i = 0; i < NG; i++) { if (g_cur[i] < lo[i]) lo[i] = g_cur[i]; if (g_cur[i] > hi[i]) hi[i] = g_cur[i];
        if (g_cur_e[i] < elo[i]) elo[i] = g_cur_e[i]; if (g_cur_e[i] > ehi[i]) ehi[i] = g_cur_e[i]; } }
    g_mm_n = 0; for (int i = 0; i < NG; i++) { g_mm_n += (g_mm[i] = hi[i] - lo[i] >= MOT); g_me[i] = g_mm[i] || ehi[i] - elo[i] >= EDG; }
}
// 只有细节变了（焦点框 / 高亮挪了）：不在动画格里、细节摘要变化 ≥ EDG 的格 ≥ 3 个
static int edge_moved(const float *a, const float *b) { int n = 0; for (int i = 0; i < NG; i++) n += !g_me[i] && fabsf(a[i] - b[i]) >= EDG; return n >= 3; }
// 逐像素判据（11-03 归族 F：泡姆泡姆条款页焦点框浅色细线，DOWN 实际把焦点从 y≈302 挪到 y≈403，细节摘要格变化最大 4.3 < EDG，判「没变」）：
//   按键前取一张半分辨率亮度（每 2 像素取 1），之后的帧逐像素比，扣掉动画格（g_mm / g_me）后亮度差 ≥ 24 的点 ≥ 60 个、且分在 ≥ 3 格（每格 ≥ 8 点）才算变了。
//   静止画面同帧逐像素相同；泡姆泡姆那一下 1280×720 下 ≥ 24 的点 959 个、12 格各 ≥ 50 个
static uint8_t *g_pre_lum; static int32_t g_pre_w, g_pre_h;   // 按键前那一帧（驾驶线程）；当前帧在 g_cur_lum（digest 从截图线程交出的副本）
static void pix_snap(void) {
    if (!g_cur_lw) { g_pre_w = 0; return; }
    uint8_t *n = realloc(g_pre_lum, (size_t)g_cur_lw * g_cur_lh); if (!n) { g_pre_w = 0; return; }
    g_pre_lum = n; memcpy(g_pre_lum, g_cur_lum, (size_t)g_cur_lw * g_cur_lh); g_pre_w = g_cur_lw; g_pre_h = g_cur_lh;
}
static int pix_moved(void) {
    if (!g_pre_w || g_cur_lw != g_pre_w || g_cur_lh != g_pre_h) return 0;
    int cnt[NG] = {0}, tot = 0;
    for (int y = 0; y < g_pre_h; y++) { int gy = y * GH / g_pre_h;
        for (int x = 0; x < g_pre_w; x++) { int c = gy * GW + x * GW / g_pre_w; if (g_mm[c] || g_me[c]) continue;
            int d = (int)g_cur_lum[(size_t)y * g_pre_w + x] - g_pre_lum[(size_t)y * g_pre_w + x]; if (d >= 24 || d <= -24) { cnt[c]++; tot++; } } }
    int cells = 0; for (int i = 0; i < NG; i++) cells += cnt[i] >= 8;
    return tot >= 60 && cells >= 3;
}
// 单测入口（t_autoplay pixmove）：1280×720 浅灰底上一个亮度差 30、2 像素宽的焦点框从 y 302 挪到 403（仿泡姆泡姆条款页）、同帧再给一次、底上只闪一个 3×3 小点；
//   打印「逐像素 / 细节摘要」两种判据各自的结论（期望：挪框 逐像素 1、细节摘要 0；同帧 0 / 0；小点 0 / 0）
static void selftest_frame(uint8_t *f, int w, int h, int fy, int dot) {
    for (int i = 0; i < w * h; i++) { f[4 * i] = f[4 * i + 1] = f[4 * i + 2] = 200; f[4 * i + 3] = 255; }
    for (int y = fy; y < fy + 120; y++) for (int x = 420; x < 832; x++) if (y < fy + 2 || y >= fy + 118 || x < 422 || x >= 830) { uint8_t *p = f + ((size_t)y * w + x) * 4; p[0] = p[1] = p[2] = 230; }
    if (dot) for (int y = 600; y < 603; y++) for (int x = 100; x < 103; x++) { uint8_t *p = f + ((size_t)y * w + x) * 4; p[0] = p[1] = p[2] = 120; }
}
void s2a_ap_pix_selftest(void);
void s2a_ap_pix_selftest(void) {
    const int w = 1280, h = 720; uint8_t *a = malloc((size_t)w * h * 4), *b = malloc((size_t)w * h * 4); if (!a || !b) return;
    float ea[NG], eb[NG];
    const char *nm[] = {"挪框", "同帧", "小点"}; int fy2[] = {403, 302, 302}, dot2[] = {0, 0, 1};
    for (int t = 0; t < 3; t++) {
        selftest_frame(a, w, h, 302, 0); selftest_frame(b, w, h, fy2[t], dot2[t]); memset(g_mm, 0, sizeof g_mm); memset(g_me, 0, sizeof g_me);
        lum_buf(a, w, h); lum_publish(); lum_take(); pix_snap(); edge_buf(a, w, h, ea);
        lum_buf(b, w, h); lum_publish(); lum_take(); edge_buf(b, w, h, eb);
        printf("%s 逐像素 %d 细节摘要 %d\n", nm[t], pix_moved(), edge_moved(eb, ea)); }
    free(a); free(b);
}
// 等画面稳定（连续 3 新帧两两差 < STAB），最多 wait_real_s 真秒；一直在动（影片 / 动画背景）就按最后一张走
static void settle(double wait_real_s) {
    uint64_t dl = real_ns() + (uint64_t)(wait_real_s * 1e9); float last[NG]; memcpy(last, g_cur, sizeof last); int st = 0;
    while (real_ns() < dl) { if (!poll_digest(0.3)) continue; st = ddiff(g_cur, last) < STAB ? st + 1 : 0; memcpy(last, g_cur, sizeof last); if (st >= 3) return; }
}
// 按一键：按住到「新出 ≥ 2 帧且 ≥ hold 秒」再松；松开等新出 2 帧；之后每新帧比按前摘要：变了且连续 3 帧稳定 → 1；连续 30 新帧没变 → 0。墙钟上限 15 真秒
static int inject(const vkey *k, float pre[NG], float *pre_e_out) {   // pre_e_out（可空）= 按前那一刻的细节摘要
    // 按前先刷一张：过场在问模型那几秒还在播，「按前画面」要是按键那一刻的
    poll_digest(0.1); pix_snap(); memcpy(pre, g_cur, sizeof g_cur); float pre_e[NG]; memcpy(pre_e, g_cur_e, sizeof pre_e); if (pre_e_out) memcpy(pre_e_out, pre_e, sizeof pre_e); const uint64_t cap_ns = 15000000000ull; uint64_t t0 = real_ns(), f0 = s2a_ap_frames(); g_presses++;
    if (k->tx >= 0) { tc_set(k->tx, k->ty, 8); while (atomic_load(&g_tc_st) != TC_IDLE && real_ns() - t0 < cap_ns) usleep(5000); }
    else {
        if (k->p2 && atomic_load(&g_pads) < 2) {   // 第一次按二号手柄：先接上第二个手柄，等 HID 改配、游戏看到它连上（新出 ≥ 30 帧）再按
            atomic_store(&g_pads, 2); LOG("自动玩家：接上第二个手柄（驾驶员要单独按二号手柄：%s）", k->n);
            while (s2a_ap_frames() < f0 + 30 && real_ns() - t0 < cap_ns) usleep(5000); f0 = s2a_ap_frames(); }
        _Atomic uint32_t *mk = k->p2 ? &g_mask2 : &g_mask;
        atomic_store(mk, k->m); uint64_t hold_ns = (uint64_t)(k->hold * 1e9);
        while ((s2a_ap_frames() < f0 + 2 || (uint64_t)((real_ns() - t0) * tscale()) < hold_ns) && real_ns() - t0 < cap_ns) usleep(5000);
        atomic_store(mk, 0);
    }
    uint64_t f1 = s2a_ap_frames(); while (s2a_ap_frames() < f1 + 2 && real_ns() - t0 < cap_ns) usleep(5000);
    int changed = 0, stab = 0, same = 0; float last[NG]; memcpy(last, g_cur, sizeof last);
    while (real_ns() - t0 < cap_ns) {
        if (!poll_digest(0.5)) continue;
        if (moved_m(g_cur, pre) || edge_moved(g_cur_e, pre_e) || pix_moved()) { if (!changed) memcpy(g_chg1, g_cur, sizeof g_chg1); changed = 1; stab = ddiff(g_cur, last) < STAB ? stab + 1 : 0; if (stab >= 3) break; }
        else if (!changed) { if (++same >= 30) break; }
        memcpy(last, g_cur, sizeof last);
    }
    // 只有局部变化：0.8 秒后再看一次还在才算（闪烁的「按 A」提示这类自己变的小块，换个相位就回去了）
    if (changed && ddiff_m(g_cur, pre) < CHG) { uint64_t t1 = real_ns() + 800000000ull; while (real_ns() < t1) poll_digest(0.2); if (!moved_m(g_cur, pre) && !edge_moved(g_cur_e, pre_e) && !pix_moved()) changed = 0; }
    int fine = changed && !moved_m(g_cur, pre);   // 只有细节变了（焦点 / 高亮挪了）
    if (changed) g_presses_changed++;
    LOG("自动玩家：按 %s（第 %d 下；按住 %.1f 秒）→ 画面%s（帧 %llu → %llu，%.1f 秒）", k->n, g_presses, k->hold, fine ? "变了（只有细节：焦点 / 高亮挪了）" : changed ? "变了" : "没变", (unsigned long long)f0, (unsigned long long)s2a_ap_frames(), (real_ns() - t0) / 1e9);
    return changed;
}

// ---- 学路线：~/.s2arm/run/s2arm/ap_learn/<程序号>.tsv，每行「页摘要（576 字节十六进制）\t 键串（逗号分隔）」 ----
#define LRN_MAX 96
static struct { float pg[NG]; char keys[200]; int burnt; } g_lrn[LRN_MAX]; static int g_lrn_n, g_lrn_cur, g_lrn_from_file; static char g_lrn_path[1200];
static struct { float pg[NG]; char keys[200]; } g_walk[LRN_MAX]; static int g_walk_n;   // 本局走过的（页，有效键）序列，MARK 时写盘
static int program_id(char out[20]) {   // S2A_IN/exefs/main.npdm：0x70 ACI0 偏移，ACI0+0x10 程序号；没有则 S2A_AP_PROGRAM_ID
    const char *e = getenv("S2A_AP_PROGRAM_ID"); if (e && *e) { snprintf(out, 20, "%.16s", e); return 1; }
    const char *in = getenv("S2A_IN"); if (!in || !*in) return 0;
    char p[1200]; snprintf(p, sizeof p, "%s/exefs/main.npdm", in); FILE *f = fopen(p, "rb"); if (!f) return 0;
    uint8_t hd[0x80]; if (fread(hd, 1, sizeof hd, f) != sizeof hd) { fclose(f); return 0; }
    uint32_t off = (uint32_t)hd[0x70] | (uint32_t)hd[0x71] << 8 | (uint32_t)hd[0x72] << 16 | (uint32_t)hd[0x73] << 24;
    uint8_t aci[0x18]; if (fseek(f, off, SEEK_SET) || fread(aci, 1, sizeof aci, f) != sizeof aci || memcmp(aci, "ACI0", 4)) { fclose(f); return 0; }
    fclose(f); uint64_t id = 0; for (int i = 7; i >= 0; i--) id = id << 8 | aci[0x10 + i]; snprintf(out, 20, "%016llx", (unsigned long long)id); return 1;
}
static void lrn_load(void) {
    char id[20]; if (!program_id(id)) { LOG("自动玩家：学路线关（取不到程序号：没有 S2A_IN/exefs/main.npdm 或 S2A_AP_PROGRAM_ID）"); return; }
    const char *d = getenv("S2A_AP_LEARN_DIR"); char dd[1100]; if (!d || !*d) { snprintf(dd, sizeof dd, "%s/.s2arm/run/s2arm/ap_learn", getenv("HOME") ? getenv("HOME") : "."); d = dd; }
    snprintf(g_lrn_path, sizeof g_lrn_path, "%s/%s.tsv", d, id);
    FILE *f = fopen(g_lrn_path, "r"); if (!f) { LOG("自动玩家：没有学过的路线 %s（首次走通后写）", g_lrn_path); return; }
    char line[1600];
    while (g_lrn_n < LRN_MAX && fgets(line, sizeof line, f)) {
        if (line[0] == '#' || strlen(line) < NG * 2 + 2 || line[NG * 2] != '\t') continue;
        for (int i = 0; i < NG; i++) { unsigned v; if (sscanf(line + 2 * i, "%2x", &v) != 1) { v = 0; } g_lrn[g_lrn_n].pg[i] = (float)v; }
        snprintf(g_lrn[g_lrn_n].keys, sizeof g_lrn[0].keys, "%s", line + NG * 2 + 1); char *nl = strchr(g_lrn[g_lrn_n].keys, '\n'); if (nl) *nl = 0; g_lrn_n++;
    }
    fclose(f); g_lrn_from_file = 1; LOG("自动玩家：学过的路线 %s，%d 步，先回放（页相似 ≥ 0.9 照做不问模型，对不上交回 AI）", g_lrn_path, g_lrn_n);
}
static int lrn_match(const float *pg, float *sim) {   // 从游标起找第一步相似 ≥ 0.9 且没烧掉的；返回步序号或 -1
    for (int i = g_lrn_cur; i < g_lrn_n; i++) { if (g_lrn[i].burnt) continue; float s = dncc(pg, g_lrn[i].pg); if (s >= 0.9f) { *sim = s; return i; } }
    return -1;
}
static void lrn_walk(const float *pg, const char *keys) { if (g_walk_n < LRN_MAX) { memcpy(g_walk[g_walk_n].pg, pg, sizeof g_walk[0].pg); snprintf(g_walk[g_walk_n].keys, sizeof g_walk[0].keys, "%s", keys); g_walk_n++; } }
static int lrn_file_has_mark(void) { return g_lrn_from_file && g_lrn_n > 0 && !strcmp(g_lrn[g_lrn_n - 1].keys, "MARK"); }
static void lrn_save(const float *mark_pg) {   // mark_pg = NULL：没到 MARK，按本局走过的有效步写（不带 MARK 行），下一局回放到前沿再问模型
    if (!*g_lrn_path || !g_walk_n) return;
    if (!mark_pg && (lrn_file_has_mark() || g_walk_n <= g_lrn_n)) return;   // 已有到 MARK 的路线、或已存的比这局走得远：不覆盖
    if (mark_pg) lrn_walk(mark_pg, "MARK");
    char d[1200]; snprintf(d, sizeof d, "%s", g_lrn_path); char *s = strrchr(d, '/'); if (s) { *s = 0; mkdir(d, 0755); }
    char tmp[1300]; snprintf(tmp, sizeof tmp, "%s.%d.tmp", g_lrn_path, (int)getpid());   // 先写临时文件再改名：同款并发局不读到半份
    FILE *f = fopen(tmp, "w"); if (!f) { LOG("【红】自动玩家：学路线写不了 %s", tmp); return; }
    fprintf(f, "# 自动玩家学到的进局路线：每行 32×18 页摘要（十六进制）\\t 键串；到 MARK 写（末行 MARK），没到 MARK 写走到的前沿；回放对不上后重走成功会覆盖\n");
    for (int i = 0; i < g_walk_n; i++) { for (int k = 0; k < NG; k++) { int v = (int)lrintf(g_walk[i].pg[k]); fprintf(f, "%02x", v < 0 ? 0 : v > 255 ? 255 : v); } fprintf(f, "\t%s\n", g_walk[i].keys); }
    fclose(f); rename(tmp, g_lrn_path); LOG("自动玩家：学路线已写 %s（%d 步）", g_lrn_path, g_walk_n);
}

// ---- 视觉驾驶员：截图 → vision.sh → keys / playable / why ----
static double g_last_p_play;   // 最近一问「可操控」的概率（Jev 给；升级后端答是 = 1）
static int g_vis_n;   // 问了几次、累计等模型真秒
// 宿主局时顺延（runtime/src/host_main.c run_timer，S2A_RUN_EXTEND_MAX > 0 时）：到点后按这个数顺延收局，模型等待不占游戏局时
__attribute__((visibility("default"), used)) double s2a_autoplay_wait_s(void) { return g_vis_s; }
// 两种问法，同一份截图 / 题面 / 答案格式（vision.sh 写的 JSON：keys / playable / p_play / why）：
//   本机：起 bash vision.sh <png> <json>（Mac 局）。
//   远程信箱（S2A_VISION_REMOTE=1，iOS 真机局由 tools/dev_run.sh 起、Mac 侧 tools/vision_bridge.sh 接）：真机上没有脚本也没有密钥，
//     截图照写 vision/vNN.png，再写 vision/vNN.req（会话号 + 题面环境）；Mac 侧经 devicectl 拉走、跑同一个 vision.sh，把 vNN.json 推回、最后推 vNN.done（内容 = 会话号）。
//     会话号写在 vision/session（开局清掉上局残留后写），桥只答本会话的请求，自动玩家只认本会话的 done：残留文件两边都不会误认
static int vision_remote(void) { const char *e = getenv("S2A_VISION_REMOTE"); return e && *e == '1'; }
static char g_vis_sess[40];
static void vision_remote_open(void) {   // 自动玩家开局调一次：清上局残留、写会话号
    if (!vision_remote() || g_vis_sess[0]) return;
    char vd[1100], p[1300]; snprintf(vd, sizeof vd, "%s/vision", g_dir); mkdir(vd, 0755);
    DIR *dir = opendir(vd); struct dirent *de;
    while (dir && (de = readdir(dir))) { if (de->d_name[0] == '.') continue; snprintf(p, sizeof p, "%s/%s", vd, de->d_name); unlink(p); }
    if (dir) closedir(dir);
    snprintf(g_vis_sess, sizeof g_vis_sess, "%d-%llu", (int)getpid(), (unsigned long long)real_ns());
    snprintf(p, sizeof p, "%s/session", vd); FILE *f = fopen(p, "w"); if (f) { fprintf(f, "%s\n", g_vis_sess); fclose(f); }
    LOG("自动玩家：驾驶员走远程信箱（%s，会话 %s；Mac 侧 tools/vision_bridge.sh 经 devicectl 答）", vd, g_vis_sess);
}
// 驾驶员一问回「后端不可用」（vision.sh 退出 3 / 答案带 "unavailable"）后记下原因：之后不再问、收局理由带上它（11-12：中转站停用后每问 0.3 秒退 1，被当成「这一问没答」静默重试）
static char g_vis_unavail[600];
#if TARGET_OS_IPHONE
static const char *vision_missing(void) { return g_vis_unavail[0] ? g_vis_unavail : vision_remote() ? NULL : "iOS 上不带视觉脚本，起局没带 S2A_VISION_REMOTE=1（Mac 侧信箱桥）"; }
#else
#include <spawn.h>
#include <sys/wait.h>
extern char **environ;
static const char *vision_sh(void) { const char *sh = getenv("S2A_VISION_SH"); return sh && *sh ? sh : "tests/autoplay/vision.sh"; }
// PATH 上有没有可执行的 name（缺省后端 = 本机 claude CLI 直连）
static int on_path(const char *name) {
    const char *pa = getenv("PATH"); if (!pa) return 0;
    for (const char *p = pa; *p;) { const char *e = strchr(p, ':'); size_t n = e ? (size_t)(e - p) : strlen(p); char f[1200];
        if (n && n < sizeof f - 64) { snprintf(f, sizeof f, "%.*s/%s", (int)n, p, name); if (access(f, X_OK) == 0) return 1; }
        if (!e) break; p = e + 1; }
    return 0;
}
// 可用 = 远程信箱，或脚本在、且缺省脚本的后端在本机起得来：cli（缺省）要 PATH 上有 claude；jev / or 要 OpenRouter 钥匙（单测的假脚本不查）
static const char *vision_missing(void) {
    static char why[1200];
    if (g_vis_unavail[0]) { snprintf(why, sizeof why, "%s", g_vis_unavail); return why; }
    if (vision_remote()) return NULL;
    if (access(vision_sh(), R_OK) != 0) { snprintf(why, sizeof why, "没有 %s", vision_sh()); return why; }
    const char *vsh = getenv("S2A_VISION_SH"), *vbk = getenv("S2A_VISION_BACKEND");
    if (vsh && *vsh) return NULL;
    if (!vbk || !*vbk || !strcmp(vbk, "cli")) { if (!on_path("claude")) { snprintf(why, sizeof why, "本机没有 claude CLI（看屏驾驶员缺省走本机 claude CLI 直连；装 Claude Code 并登录，或设 S2A_VISION_BACKEND=or）"); return why; } }
    else { char k[1100]; snprintf(k, sizeof k, "%s/.s2arm/.secrets/openrouter.key", getenv("HOME") ? getenv("HOME") : ".");
        if (access(k, R_OK) != 0) { snprintf(why, sizeof why, "S2A_VISION_BACKEND=%s 要 OpenRouter 钥匙，没有 %s", vbk, k); return why; } }
    return NULL;
}
// 本机：起脚本等它退出；返回退出状态（-1 = 起不来）
static int vision_run_local(const char *png, const char *js) {
    pid_t pid; char *argv[] = {"bash", (char *)vision_sh(), (char *)png, (char *)js, NULL};
    if (posix_spawnp(&pid, "bash", NULL, NULL, argv, environ) != 0) return -1;
    int stt = 0; waitpid(pid, &stt, 0); return WIFEXITED(stt) ? WEXITSTATUS(stt) : -1;
}
#endif
static int vision_available(void) { return !vision_missing(); }
// 远程信箱：写 req，等本会话的 done（S2A_VISION_REMOTE_WAIT 秒，缺省 180：模型几秒 + devicectl 往返几秒，超时当这次没问成）；返回 0 / -1
static int vision_run_remote(int n, const char *tried, int again) {
    char p[1300], tmp[1300]; snprintf(p, sizeof p, "%s/vision/v%02d.req", g_dir, n); snprintf(tmp, sizeof tmp, "%s.tmp", p);
    FILE *f = fopen(tmp, "w"); if (!f) return -1;
    fprintf(f, "session=%s\ntried=%s\nescalate=%d\ntouchw=%d\n", g_vis_sess, tried, again ? 1 : 0, touch_canvas_w()); fclose(f);
    if (rename(tmp, p)) return -1;   // 整份出现：桥拉到的不会是半个文件
    const char *e = getenv("S2A_VISION_REMOTE_WAIT"); double wait = e && *e ? atof(e) : 180; uint64_t dl = real_ns() + (uint64_t)(wait * 1e9);
    snprintf(p, sizeof p, "%s/vision/v%02d.done", g_dir, n);
    while (real_ns() < dl) {
        FILE *d = fopen(p, "r"); char got[64] = "";
        if (d) { if (!fgets(got, sizeof got, d)) got[0] = 0; fclose(d); got[strcspn(got, "\r\n")] = 0; if (!strcmp(got, g_vis_sess)) return 0; }
        usleep(100000);
    }
    LOG("自动玩家：驾驶员 #%d 远程信箱 %.0f 秒没等到答案（Mac 侧桥没起 / devicectl 不通）", n, wait);
    return -1;
}
// 返回拿到的键数（≥ 0）；-1 = 这次没问成（截图没写成 / 脚本失败 / 信箱超时）；-2 = 不可用
static int g_vis_empty;   // 最近一问没给键的缘由：0 = 给了键 / 失败，1 = 模型答空（等加载 / 过场），2 = 答的全是这页试过的（vision.sh 的 "empty"）
static int vision_ask(const char *tried, int again, vkey *out, int cap, int *playable, char *why, size_t wcap) {
    *playable = 0; why[0] = 0; g_vis_empty = 0; if (!vision_available()) return -2;
    vision_remote_open();
    char vd[1100], png[1200], js[1200], rel[64]; snprintf(vd, sizeof vd, "%s/vision", g_dir); mkdir(vd, 0755);
    snprintf(rel, sizeof rel, "vision/v%02d.png", g_vis_n + 1); snprintf(png, sizeof png, "%s/%s", g_dir, rel);
    if (!save_png_wait(rel, 15) || access(png, R_OK) != 0) { LOG("自动玩家：这步不问驾驶员（截图 %s 15 秒没写成）", rel); return -3; }   // 宿主写盘慢，不是驾驶员失败
    g_vis_n++; snprintf(js, sizeof js, "%s/vision/v%02d.json", g_dir, g_vis_n);
    uint64_t t0 = real_ns(); int rc;
    if (vision_remote()) rc = vision_run_remote(g_vis_n, tried, again);
    else {
#if TARGET_OS_IPHONE
        rc = -1;
#else
        if (*tried) setenv("S2A_VISION_TRIED", tried, 1); else unsetenv("S2A_VISION_TRIED");
        { char tw[16]; snprintf(tw, sizeof tw, "%d", touch_canvas_w()); setenv("S2A_VISION_TOUCH_W", tw, 1); }
        if (again) setenv("S2A_VISION_ESCALATE", "1", 1); else unsetenv("S2A_VISION_ESCALATE");   // 回到问过的同一页还卡着：题面说明、脚本可升级后端
        rc = vision_run_local(png, js);
        if (rc == -1) { LOG("自动玩家：驾驶员 #%d 起不来", g_vis_n); return -1; }
#endif
    }
    double dt = (real_ns() - t0) / 1e9; g_vis_s += dt;
    FILE *fp = fopen(js, "r"); char buf[4096] = ""; size_t nr = fp ? fread(buf, 1, sizeof buf - 1, fp) : 0; if (fp) fclose(fp); buf[nr] = 0;
    char *pl = strstr(buf, "\"playable\""); if (pl) { pl = strchr(pl, ':'); if (pl) { while (*++pl == ' ') {} *playable = !strncmp(pl, "true", 4); } }
    { char *pp = strstr(buf, "\"p_play\""); g_last_p_play = pp && strchr(pp, ':') ? atof(strchr(pp, ':') + 1) : (*playable ? 1.0 : 0.0); }   // Jev 带概率；升级后端只给是 / 否
    { char *em = strstr(buf, "\"empty\""); g_vis_empty = !em ? 0 : strstr(em, "\"tried\"") ? 2 : 1; }
    char *w = strstr(buf, "\"why\""); if (w) { w = strchr(w + 5, '"'); if (w) { snprintf(why, wcap, "%s", w + 1); char *z = strchr(why, '"'); if (z) *z = 0; } }
    if (rc == 3 || strstr(buf, "\"unavailable\"")) {   // 后端起不来（没有 CLI / 没登录 / 没钥匙）：不是这一问没答，红停
        snprintf(g_vis_unavail, sizeof g_vis_unavail, "看屏驾驶员不可用：%s", *why ? why : "vision.sh 退出 3（原因见局目录 vision/*.json.log）");
        LOG("【红】自动玩家：驾驶员 #%d %s", g_vis_n, g_vis_unavail);
        return -2;
    }
    int n = 0; char got[256] = "", drop[128] = "";
    char *k = strstr(buf, "\"keys\""), *e = k ? strchr(k, ']') : NULL;
    for (char *q = k ? strchr(k, '[') : NULL; q && e && q < e && n < cap;) {
        char *a = strchr(q, '"'); if (!a || a > e) break; char *b = strchr(a + 1, '"'); if (!b || b > e) break;
        char tok[32]; size_t L = (size_t)(b - a - 1) < sizeof tok - 1 ? (size_t)(b - a - 1) : sizeof tok - 1; memcpy(tok, a + 1, L); tok[L] = 0; q = b + 1;
        if (!key_parse(tok, &out[n])) { snprintf(drop + strlen(drop), sizeof drop - strlen(drop), "%s ", tok); continue; }
        snprintf(got + strlen(got), sizeof got - strlen(got), "%s%s", n ? " " : "", tok); n++;
    }
    LOG("自动玩家：导航 → 驾驶员 #%d（%s截图 %s，%.1f 秒，退出 %d）→ 按键 [%s]%s%s；可玩 %s；说明：%s", g_vis_n, vision_remote() ? "远程信箱，" : "", rel, dt, rc,
        got, *drop ? "；丢弃不在允许集合的 " : "", drop, *playable ? "是" : "否", why);
    if (rc != 0) return n ? n : -1;
    return n;
}

// 「可操控」先过两道关再进双证（11-01 异度3：过场暂停页（压暗 + PAUSE）被判进局——Jev 可操控概率 0.50 / 0.52，同一步答的键却是 PLUS；
//   读数门挡不住，过场 / 暂停页本身就是全 3D 场景）：① 说可操控却答 + / - = 自相矛盾（真在操控不会去开暂停 / 系统菜单），判否；
//   ② Jev 概率 < 0.8 的可操控交升级后端（直连 claude-sonnet）复核，它也说可操控才算。复核给的键替换本步要按的键
// 返回 0 = 不算可操控，1 = Jev 说可操控，2 = 升级后端说可操控（本问就是升级问的 escalated，或复核确认）
static int gate_playable(int playable, int escalated, vkey *ks, int *nk, const char *tried, char *why, size_t wcap) {
    if (!playable) return 0;
    int sys = 0; for (int i = 0; i < *nk; i++) sys |= (ks[i].m & (S2A_AP_PLUS | S2A_AP_MINUS)) != 0;
    if (sys) { LOG("自动玩家：模型说可操控却答了 + / -（概率 %.2f）：自相矛盾，按没进局处理", g_last_p_play); return 0; }
    if (escalated) return 2;
    if (g_last_p_play >= 0.8) return 1;
    vkey ks2[8]; int pl2 = 0; char why2[400] = ""; double p0 = g_last_p_play; int r2 = vision_ask(tried, 1, ks2, 8, &pl2, why2, sizeof why2);
    int sys2 = 0; for (int i = 0; i < r2; i++) sys2 |= (ks2[i].m & (S2A_AP_PLUS | S2A_AP_MINUS)) != 0;
    LOG("自动玩家：可操控概率 %.2f < 0.8，升级复核 → %s", p0, pl2 && !sys2 ? "确认可操控" : "不是可操控场景");
    if (r2 > 0) { memcpy(ks, ks2, sizeof(vkey) * (size_t)r2); *nk = r2; snprintf(why, wcap, "%s", why2); }
    return pl2 && !sys2 ? 2 : 0;
}

// ---- 主循环 ----
// 页表：每页（32×18 摘要，结构相关 ≥ 0.9 算同一页）一份「试过没用的键」和问过几次。
//   键试过没用 = 按了画面没变，或按了之后回到本局比这页更早到过的页（走回头路：11-01 银河 2 存档页按 R / A 来回绕、模型答到局时用完）。
//   回到问过的页时，这页的 tried 告诉模型别再答、这一问升级后端
#define PAGE_MAX 48
// 页内状态（st 亮度摘要 + ste 细节摘要）：按键变了但还在这页时的摘要，最多记 PAGE_ST 个（满了覆盖最早的）。回到见过的页内状态 = 来回；没见过 = 页内有进展
//   （11-02 普查太鼓 22 页用户协议：每页长得一样、RIGHT 每按都翻到新页，旧规则「同一键第二次停在这页 = 来回」把 RIGHT / ZR 拉黑，卡在 17/22）
//   「见过」与「按了变没变」（inject）同一判据：亮度摘要和细节摘要都没变才算同一状态（11-02 nav1102r 太鼓复判：协议各页只差正文字形，
//    inject 靠细节摘要判出翻页，只比亮度摘要的旧判法把每一页都认成见过，RIGHT 又被拉黑，卡在 3/22）
#define PAGE_ST 6
static struct { float pg[NG], pge[NG]; uint8_t mm[NG], me[NG]; char tried[256], ban[256]; int asks, jev_miss, fast_stay, st_n, in_from, in_n, back_n; vkey in_ks[4]; float st[PAGE_ST][NG], ste[PAGE_ST][NG]; uint8_t *stl[PAGE_ST]; } g_pages[PAGE_MAX]; static int g_page_n;   // jev_miss = 这页上一问是 Jev 答的、没推进
// 认页扣掉动画格：当前采到的（g_mm / g_me）∪ 那页记下的（mm / me）；都没有就是整屏 dncc
//   亮度摘要或细节摘要任一相关 ≥ 0.9 就是同一页：同布局换文字的页（协议各页、问卷各题）亮度相关高、细节相关低，归同一页走页内状态；
//   背景昼夜变色 / 云在飘的菜单亮度相关掉到 0.7 甚至负值、细节（字和框）相关仍 ≥ 0.96（11-02 nav1102r 泰拉瑞亚：标题页被认成第 3 / 9 / 10 / 11 页，
//   标题按 A 进建角色页被当成走回头路拉黑，A / B 来回 80 步；五款 205 张截图两两离线比，仅细节判同的样例都是同页换高亮 / 背景）
static int page_find(const float *pg, const float *pge) { int best = -1; float bs = 0.9f; for (int j = 0; j < g_page_n; j++) {
    float v = fmaxf(dncc_m(pg, g_pages[j].pg, g_mm_n ? g_mm : NULL, g_pages[j].mm), dncc_m(pge, g_pages[j].pge, g_me, g_pages[j].me)); if (v >= bs) { bs = v; best = j; } } return best; }
static int page_id(const float *pg, const float *pge) {
    int j = page_find(pg, pge); if (j >= 0) return j;
    j = g_page_n < PAGE_MAX ? g_page_n++ : PAGE_MAX - 1; memcpy(g_pages[j].pg, pg, sizeof g_pages[j].pg); memcpy(g_pages[j].pge, pge, sizeof g_pages[j].pge); memset(g_pages[j].me, 0, sizeof g_pages[j].me); g_pages[j].tried[0] = g_pages[j].ban[0] = 0; g_pages[j].asks = g_pages[j].jev_miss = g_pages[j].fast_stay = g_pages[j].st_n = g_pages[j].in_n = g_pages[j].back_n = 0; memset(g_pages[j].mm, 0, sizeof g_pages[j].mm); return j;
}
// 页内状态见过没有（d 亮度摘要、e 细节摘要，比较扣掉动画格，同 moved_m / edge_moved）；add = 没见过就记下。返回 1 = 见过
// 逐像素第三道（11-04 归族 B：真女神转生V / 数码宝贝连弹同版式 DLC 通知，只换标题和几个字，32×18 亮度 / 细节摘要都判同一状态，对的键 B / A 被当来回拉黑）：
//   每个页内状态另存一张 1/4 分辨率亮度（半分辨率亮度 2×2 取均值）；比较扣掉动画格，亮度差 ≥ 24 的点 ≥ 15 个且分在 ≥ 2 格（每格 ≥ 4 点）= 不是同一状态。
//   没有亮度帧（单测假宿主不给 / 取不到）退回只比两种摘要
static int g_stq_w, g_stq_h;
static uint8_t *lum_q(const uint8_t *s, int w, int h, int *qw, int *qh) {
    int w2 = w / 2, h2 = h / 2; if (!s || w2 < 1 || h2 < 1) return NULL;
    uint8_t *o = malloc((size_t)w2 * h2); if (!o) return NULL;
    for (int y = 0; y < h2; y++) for (int x = 0; x < w2; x++) o[(size_t)y * w2 + x] = (uint8_t)((s[(size_t)2 * y * w + 2 * x] + s[(size_t)2 * y * w + 2 * x + 1] + s[(size_t)(2 * y + 1) * w + 2 * x] + s[(size_t)(2 * y + 1) * w + 2 * x + 1]) / 4);
    *qw = w2; *qh = h2; return o;
}
static int lum_q_moved(const uint8_t *a, const uint8_t *b, int w, int h) {
    int cnt[NG] = {0}, tot = 0;
    for (int y = 0; y < h; y++) { int gy = y * GH / h;
        for (int x = 0; x < w; x++) { int c = gy * GW + x * GW / w; if (g_mm[c] || g_me[c]) continue;
            int dd = (int)a[(size_t)y * w + x] - b[(size_t)y * w + x]; if (dd >= 24 || dd <= -24) { cnt[c]++; tot++; } } }
    int cells = 0; for (int i = 0; i < NG; i++) cells += cnt[i] >= 4;
    return tot >= 15 && cells >= 2;
}
static int page_st_seen(int pi, const float *d, const float *e, const uint8_t *lum, int lw, int lh, int add) {
    int n = g_pages[pi].st_n < PAGE_ST ? g_pages[pi].st_n : PAGE_ST, qw = 0, qh = 0, seen = 0; uint8_t *q = lum_q(lum, lw, lh, &qw, &qh);
    for (int k = 0; k < n && !seen; k++) if (!moved_m(d, g_pages[pi].st[k]) && !edge_moved(e, g_pages[pi].ste[k])
        && !(q && g_pages[pi].stl[k] && qw == g_stq_w && qh == g_stq_h && lum_q_moved(q, g_pages[pi].stl[k], qw, qh))) seen = 1;
    if (!seen && add) { int k = g_pages[pi].st_n++ % PAGE_ST; memcpy(g_pages[pi].st[k], d, sizeof g_pages[0].st[0]); memcpy(g_pages[pi].ste[k], e, sizeof g_pages[0].ste[0]);
        free(g_pages[pi].stl[k]); g_pages[pi].stl[k] = q; if (q) { g_stq_w = qw; g_stq_h = qh; } return 0; }
    free(q); return seen;
}
// 单测入口（t_autoplay stseen）：1280×720 灰底 200，帧 A 在两格里各有一条 4×30、亮度 240 的亮条（仿弹窗标题字），帧 B 把亮条挪到别处（仿同版式弹窗换了字）。
//   页内状态记 A 后依次问：同帧 A 见过没、换字帧 B 见过没，并打印旧两道摘要（亮度 + 细节）对 A / B 的结论。
//   期望（手算）：同帧 见过 1；换字 见过 0（逐像素第三道：A、B 各有 4 条×60 个半分辨率点 ≥ 24，分在 ≥ 2 格）；旧两道判同 1（亮条只占格的 120 / 1600，格均差 4.5 < 40，不到 3 格）
static void stseen_frame(uint8_t *f, int w, int h, int y0) {
    for (int i = 0; i < w * h; i++) { f[4 * i] = f[4 * i + 1] = f[4 * i + 2] = 200; f[4 * i + 3] = 255; }
    static const int xs[2] = {420, 700};
    for (int k = 0; k < 2; k++) for (int y = y0; y < y0 + 30; y++) for (int x = xs[k]; x < xs[k] + 4; x++) { uint8_t *p = f + ((size_t)y * w + x) * 4; p[0] = p[1] = p[2] = 240; }
}
void s2a_ap_stseen_selftest(void);
void s2a_ap_stseen_selftest(void) {
    const int w = 1280, h = 720; uint8_t *a = malloc((size_t)w * h * 4), *b = malloc((size_t)w * h * 4); if (!a || !b) return;
    float da[NG], db[NG], ea[NG], eb[NG]; memset(g_mm, 0, sizeof g_mm); memset(g_me, 0, sizeof g_me); g_mm_n = 0;
    stseen_frame(a, w, h, 300); stseen_frame(b, w, h, 400);
    digest_buf(a, w, h, da); edge_buf(a, w, h, ea); lum_buf(a, w, h); lum_publish(); lum_take(); uint8_t *la = malloc((size_t)g_cur_lw * g_cur_lh); int lw = g_cur_lw, lh = g_cur_lh; memcpy(la, g_cur_lum, (size_t)lw * lh);
    digest_buf(b, w, h, db); edge_buf(b, w, h, eb); lum_buf(b, w, h); lum_publish(); lum_take();
    g_pages[0].st_n = 0; int first = page_st_seen(0, da, ea, la, lw, lh, 1), same = page_st_seen(0, da, ea, la, lw, lh, 0), swap = page_st_seen(0, db, eb, g_cur_lum, g_cur_lw, g_cur_lh, 0);
    int old_same = !moved_m(db, da) && !edge_moved(eb, ea);
    printf("首帧 见过 %d 同帧 见过 %d 换字 见过 %d 旧两道判同 %d\n", first, same, swap, old_same);
    free(a); free(b); free(la);
}
static double secs(uint64_t t) { return (t - g_t0) / 1e9; }
static double g_mark_delay_s = -1;   // 进局判定到记 MARK 等了多久（真秒）；没到 MARK = -1
// S2A_AP_PADREC=<录手柄 tsv>@<起始帧>：局内段改为回放真机录下的手柄（ios/vpad.m 的 padrec：每行「上屏帧号 \t 按键位 \t 左x \t 左y \t 右x \t 右y \t 毫秒」，
//   「帧号 \t 存档 …」行跳过）。从录像第 <起始帧> 起按 MARK 后的上屏帧数对齐重放：按键位低 16 位同 S2A_AP_*，摇杆超过半程折成方向位（y 正 = 上）。
//   定因要「人走到某处」的现场时不请人操作：拿玩家那局的 padrec 回放（11-02 丝之歌跳台黑屏：维护者 读档后往左走、跳上高台）。返回 1 = 放了
static uint32_t padrec_mask(uint32_t b, int lx, int ly, int rx, int ry) {
    uint32_t m = b & 0xffffu; const int h = 16384;
    if (lx < -h) m |= S2A_AP_LS_LEFT; if (lx > h) m |= S2A_AP_LS_RIGHT; if (ly > h) m |= S2A_AP_LS_UP; if (ly < -h) m |= S2A_AP_LS_DOWN;
    if (rx < -h) m |= S2A_AP_RS_LEFT; if (rx > h) m |= S2A_AP_RS_RIGHT; if (ry > h) m |= S2A_AP_RS_UP; if (ry < -h) m |= S2A_AP_RS_DOWN;
    return m;
}
// S2A_AP_FLASH_REC=<n>（配 S2A_FRAME_REC=<目录>，诊断）：回放手柄期间逐帧看整屏亮度（32×18 摘要均值），比上一帧突升 ≥ 40 就录下一次出图（flash<k>，最多 n 次）。
//   绿屏 / 白屏闪烁这类一两帧的坏画面，定帧录不准哪一次出图（11-06 维护者 手测 GRID 开场绿闪、刺客信条进局白闪：按录像帧号定录 400 / 900 / 1250 全落在好帧上）；
//   要每帧取摘要，同时设 S2A_AP_SHOT_MIN_MS=0
static void flash_watch(void) {
    static int lim = -1, nrec; static float prev = -1; static void (*rec)(const char *);
    if (lim < 0) { const char *e = getenv("S2A_AP_FLASH_REC"); lim = e && *e ? atoi(e) : 0; if (lim > 0) { rec = (void (*)(const char *))dlsym(RTLD_DEFAULT, "nvn_frec_request");
        LOG("自动玩家：闪屏触发录帧 %s（最多 %d 次，整屏亮度比上一帧突升 ≥ 40）", rec ? "开" : "【红】开不了：找不到直连图形层的帧录 nvn_frec_request", lim); } }
    if (lim <= 0 || !rec || nrec >= lim) return;
    float d[NG], e[NG]; uint64_t f; if (!digest(d, e, &f)) return;
    double m = 0; for (int i = 0; i < NG; i++) m += d[i]; m /= NG;
    if (prev >= 0 && m - prev >= 40) { char nm[16]; snprintf(nm, sizeof nm, "flash%d", ++nrec); rec(nm); LOG("自动玩家：闪屏 第 %d 次（帧 %llu，整屏亮度 %.0f → %.0f），录下一次出图为 %s", nrec, (unsigned long long)f, prev, m, nm); }
    prev = (float)m;
}
static int padrec_play(const char *spec, uint64_t t_end) {
    char path[1024]; long s0 = 0; const char *at = strrchr(spec, '@'); size_t n = at ? (size_t)(at - spec) : strlen(spec);
    if (n >= sizeof path) { LOG("【红】自动玩家：S2A_AP_PADREC 路径太长"); return 0; }
    // 相对路径按输出目录解析（同实时通道：iOS = 本次安装的 Documents；11-02 体验线写死旧容器路径，重装后容器换了、打不开）
    if (spec[0] == '/') { memcpy(path, spec, n); path[n] = 0; }
    else { out_dir(); int k = snprintf(path, sizeof path, "%s/", g_dir); if (k < 0 || (size_t)k + n >= sizeof path) { LOG("【红】自动玩家：S2A_AP_PADREC 路径太长"); return 0; } memcpy(path + k, spec, n); path[k + n] = 0; }
    if (at) s0 = atol(at + 1);
    FILE *f = fopen(path, "r"); if (!f) { LOG("【红】自动玩家：S2A_AP_PADREC 打不开 %s", path); return 0; }
    static struct { long f; uint32_t m; } row[65536]; int nr = 0; uint32_t m0 = 0; char line[256];
    while (fgets(line, sizeof line, f) && nr < (int)(sizeof row / sizeof *row)) {
        long fr; char bs[32]; int lx, ly, rx, ry;
        if (line[0] == '#' || sscanf(line, "%ld\t%31s\t%d\t%d\t%d\t%d", &fr, bs, &lx, &ly, &rx, &ry) != 6) continue;   // 存档行第二列不是数、凑不满 6 项
        uint32_t m = padrec_mask((uint32_t)strtoul(bs, NULL, 0), lx, ly, rx, ry);
        if (fr < s0) { m0 = m; continue; }   // 起始帧之前的最后状态：开放时先按住
        row[nr].f = fr - s0; row[nr].m = m; nr++;
    }
    fclose(f);
    if (!nr) { LOG("【红】自动玩家：S2A_AP_PADREC %s 第 %ld 帧之后没有手柄行", path, s0); return 0; }
    uint64_t b = s2a_ap_frames(); atomic_store(&g_mask, m0);
    LOG("自动玩家：局内段回放手柄 %s 自第 %ld 帧起 %d 行（录像 %ld 帧长），起点上屏帧 %llu", path, s0, nr, row[nr - 1].f, (unsigned long long)b);
    for (int i = 0; i < nr; i++) {
        while (s2a_ap_frames() - b < (uint64_t)row[i].f) {
            if (now_ns() >= t_end || (real_ns() - g_last_new_f_t) / 1e9 > 60) { atomic_store(&g_mask, 0); LOG("【红】自动玩家：手柄回放第 %d / %d 行没放完就到点或出图停了", i, nr); return 1; }
            usleep(2000); frame_tick(); flash_watch();
        }
        atomic_store(&g_mask, row[i].m);
    }
    atomic_store(&g_mask, 0); LOG("自动玩家：手柄回放放完（上屏帧 %llu），之后原地不动到局内段结束", (unsigned long long)s2a_ap_frames());
    return 1;
}
// 核实「这一页能玩」（暂停层关掉、回到底下那页之后用）：不按键看 1.5 秒画面不自己动（排除过场，11-01 异度3 过场里 + 也进暂停页），
//   推左摇杆 1.5 秒整屏动了 + 读数到场景量级。返回 1 = 能玩（d / p = 绘制中位 / 遍数）
static int play_check(uint32_t *d, uint32_t *p) {
    float pz[NG], p0[NG]; settle(3.0); memcpy(p0, g_cur, sizeof p0);
    uint64_t ti = real_ns() + (uint64_t)(1.5e9 / tscale()); int idle = 0; while (real_ns() < ti) { poll_digest(0.3); if (moved_m(g_cur, p0)) idle = 1; }
    vkey ls = {S2A_AP_LS_RIGHT, 1.5f, "LS_RIGHT", -1, -1, 0}; memcpy(p0, g_cur, sizeof p0); int mv = !idle && inject(&ls, pz, NULL) && ddiff_m(g_cur, p0) >= CHG; int lvl = scene_level(d, p);
    if (idle) LOG("自动玩家：关掉暂停后不按键画面自己在动（过场 / 动画），不当局内核实");
    if (!(mv && lvl)) LOG("自动玩家：关掉暂停后推左摇杆%s、读数%s到场景量级，不算进局", mv ? "整屏动了" : "整屏没动", lvl ? "" : "未");
    return mv && lvl;
}
static void *ap_main(void *a) {
    (void)a; ap_sleep_us(200000); out_dir(); worker_start();
    // early_s（S2A_AP_EARLY_S，缺省 0 = 关）：MARK 后段全部销号、照常出帧 ≥ early_s 秒就提前收局（普查设 60，tools/census/census.sh）；没到 MARK 不受影响
    const double giveup = envd("S2A_AP_GIVEUP_S", 300), loop_s = envd("S2A_AP_LOOP_S", 120), early_s = envd("S2A_AP_EARLY_S", 0), end_left = envd("S2A_AP_END_LEFT_S", 20), vis_left = envd("S2A_AP_VIS_LEFT_S", 45);
    const int max_steps = (int)envd("S2A_AP_MAX_STEPS", 80);
    const char *stage = "等首帧"; char fin_why[400] = ""; int marked = 0, steps = 0, replayed = 0; uint64_t t_first = 0, t_mark = 0, f_mark = 0;
    // 等首帧（首帧前按键会把游戏弄卡）：出图停 / 墙钟按 run_left 兜底
    g_last_new_f_t = real_ns();
    while (!poll_digest(0.5)) { if (run_left_s() < end_left) { snprintf(fin_why, sizeof fin_why, "导航卡住（离收局只剩 %.0f 秒还没出首帧）", run_left_s()); goto finish; }
        if ((real_ns() - g_last_new_f_t) / 1e9 > 120) { snprintf(fin_why, sizeof fin_why, "120 秒没出首帧"); goto finish; } }
    t_first = now_ns(); LOG("自动玩家：首帧（帧 %llu，%.1f 秒）", (unsigned long long)g_cur_f, secs(t_first));
    // 基线：首帧后 3 秒、每秒一窗
    { uint32_t d[3], p[3]; for (int i = 0; i < 3; i++) window_med(&d[i], &p[i]); qsort(d, 3, sizeof *d, cmpu); qsort(p, 3, sizeof *p, cmpu); g_base_d = d[1]; g_base_p = p[1];
      LOG("自动玩家：开局基线 每帧绘制 %u、渲染遍数 %u（进局要 绘制 ≥ %u 或 遍数 ≥ %u）", g_base_d, g_base_p, 3 * (g_base_d > 8 ? g_base_d : 8), 2 * (g_base_p > 2 ? g_base_p : 2)); }
    // S2A_AP_PADREC_BOOT=<录手柄 tsv>[@<起始帧>]：首帧后先整段回放玩家那局录下的手柄（含导航段，按录像的上屏帧号对齐，误差 = 本局首帧帧号），放完再走常规导航 / MARK。
    //   真机定因要走到「玩家看到坏画面那一处」而自动玩家过不去某页时用（11-06 无人深空：模式页自动玩家过不去，维护者 那局的 padrec 能走进局；配 S2A_FRAME_REC=<帧>,…:<目录> 录坏帧）
    { const char *pb = getenv("S2A_AP_PADREC_BOOT"); if (pb && *pb) { stage = "回放手柄";
        if (!padrec_play(pb, now_ns() + (uint64_t)(run_left_s() * 1e9 * tscale()))) LOG("【红】自动玩家：S2A_AP_PADREC_BOOT 没放成，照常导航"); } }
    lrn_load();
    if (!vision_available()) LOG("【红】自动玩家：视觉测试员不可用（%s）%s", vision_missing(), g_lrn_n ? "，只能回放学过的路线" : "");
    if (!vision_available() && !g_lrn_n) {
        snprintf(fin_why, sizeof fin_why, "导航卡住（没有视觉驾驶员，也没有学过的路线）"); stage = "导航"; goto finish; }
    stage = "导航";
    float pg[NG], pge[NG]; int vis_fail = 0, vis_wait = 0, play_streak = 0, esc_streak = 0, last_pi = -1, last_nk = 0; vkey last_ks[8];   // last_* = 上一步按成功（页变了）的键，下一步到新页时记成那页的进入键（11-04 归族 A / C：环路拦截）
    // 开关键（如过场里的 +）：按 K 进了一页、在那页再按 K 又回到原页 = K 是开关（暂停 / 取消暂停），不是跳过。
    //   11-01 异度3 开场过场 + 只暂停：驾驶员每问都答 +，暂停 / 取消来回，过场只播一半时间，80 步在 393 秒用完；
    //   按「画面在不在自己动」判过场又认不出静止对话镜头（第二局 82 问只等了 2 回）。
    //   认出开关后记它按了几次：奇数 = 是我们按开的（暂停着），再答它就照按（取消暂停）；偶数时再答它 = 想用它跳过，不按、等过场自己播
    //   （10 秒起、每回翻倍、封顶 160 秒，不计步）。别的键（对话框要的 A 等）照常按
    char toggle_key[200] = "", prev_key[200] = ""; int toggle_n = 0, wait_n = 0; float prev_pg[NG]; int have_prev = 0; double wait_s = 0;
    // 暂停层（按事件认，不看压暗 / 模糊）：在 P 页按 + 进了别的页，那一页记作 pause_pg（下一步开始时认出它）；在 pause_pg 上按什么键回到了 P = 关掉暂停、回到按 + 前那一页。
    //   回 P 不算走回头路（11-02 nav1102r 银河2：暂停菜单背景是模糊不是压暗，压暗判据不触发；在暂停菜单按「继续」回游戏被判回头路、「继续」被拉黑，
    //   学过的路线又在游戏画面上重放 +，暂停进进出出到局时用完）；回到 P 后当场核实 P 能不能玩
    int plus_from = -1, plus_pend = 0, pause_pg = -1; uint8_t resume_chk[PAGE_MAX] = {0};   // resume_chk = 这页关暂停后核实过、不能玩，不再核
    settle(3.0);
    for (;;) {
        double nav_s = (now_ns() - t_first) / 1e9 - g_vis_s * tscale() - wait_s;   // 扣掉等模型的时间、等过场自己播的时间（不是导航卡住）
        if ((real_ns() - g_last_new_f_t) / 1e9 > 60 || shot_stuck_s() > 60) { snprintf(fin_why, sizeof fin_why, "出图停 60 秒（最后帧 %llu）", (unsigned long long)g_cur_f); break; }
        if (run_left_s() < end_left) { snprintf(fin_why, sizeof fin_why, "导航卡住（离收局只剩 %.0f 秒没进局）", run_left_s()); break; }
        if (nav_s >= giveup) { snprintf(fin_why, sizeof fin_why, "导航卡住（导航 %.0f 秒没进局，上限 %.0f）", nav_s, giveup); break; }
        if (steps >= max_steps) { snprintf(fin_why, sizeof fin_why, "导航卡住（步数上限 %d 步）", max_steps); break; }
        steps++; memcpy(pg, g_cur, sizeof pg); memcpy(pge, g_cur_e, sizeof pge); int pi = page_id(pg, pge); char *tried = g_pages[pi].tried;
        if (last_nk > 0 && last_nk <= 4 && last_pi >= 0 && last_pi != pi && !g_pages[pi].in_n) { g_pages[pi].in_from = last_pi; g_pages[pi].in_n = last_nk; memcpy(g_pages[pi].in_ks, last_ks, sizeof(vkey) * (size_t)last_nk); }
        if (plus_pend) { pause_pg = pi != plus_from ? pi : -1; plus_pend = 0; }
        vkey ks[8]; int nk = 0, playable = 0, from_replay = 0, asked_esc = 0; char why[400] = "", ans[200] = ""; float sim = 0; int li = lrn_match(pg, &sim);
        if (li >= 0 && !strcmp(g_lrn[li].keys, "MARK")) {   // 学过的进局页：本局读数到场景量级就打 MARK，不到交回 AI
            uint32_t d, p;
            // 学过的进局页也要模型当场确认可操控（过同样两道关）：学的那局若把暂停页误记成进局（11-01 异度3），回放不能把错一路传下去；没有驾驶员时只按读数
            vkey kc[8]; int nc = 0, plc = 0; char wc[400] = ""; int rc = vision_ask("", 0, kc, 8, &plc, wc, sizeof wc);
            int ok = rc == -2 ? 1 : rc >= 0 && gate_playable(plc, 0, kc, &(int){rc}, "", wc, sizeof wc); (void)nc;
            if (!ok) LOG("自动玩家：回放到学过的进局页（页相似 %.2f），但模型当场不认可操控，交回 AI", sim);
            if (ok && scene_level(&d, &p)) { snprintf(fin_why, sizeof fin_why, "回放到学过的进局页（页相似 %.2f）+ 读数到场景量级（绘制中位 %u、遍数 %u；基线 %u / %u）", sim, d, p, g_base_d, g_base_p);
                marked = 1; stage = "局内段"; t_mark = now_ns(); f_mark = s2a_ap_frames(); replayed++; break; }
            g_lrn[li].burnt = 1; if (ok) LOG("自动玩家：回放到学过的进局页（页相似 %.2f）但读数未到场景量级（绘制中位 %u），交回 AI", sim, d); li = -1;
        }
        if (li >= 0) {   // 学过的页：照做不问模型
            char kk[200]; snprintf(kk, sizeof kk, "%s", g_lrn[li].keys);
            for (char *sv, *q = strtok_r(kk, ",", &sv); q && nk < 8; q = strtok_r(NULL, ",", &sv)) if (key_parse(q, &ks[nk])) nk++;
            from_replay = nk > 0; if (from_replay) LOG("自动玩家：第 %d 步 回放学过的第 %d 步（页相似 %.2f）→ %s", steps, li + 1, sim, g_lrn[li].keys);
        }
        if (!from_replay) {
            if (run_left_s() < vis_left) { snprintf(fin_why, sizeof fin_why, "导航卡住（离收局只剩 %.0f 秒，不再问驾驶员）", run_left_s()); break; }
            int again = g_pages[pi].asks++; if (again) LOG("自动玩家：回到问过 %d 次的页（第 %d 页），这页试过没用：%s", again, pi + 1, *tried ? tried : "无");
            // 升级 claude（每问约 9 秒固定开销 + 看图约 8 秒，Jev 中位 1.9 秒）只在这页问过 ≥ 2 次时；问过 1 次先再问 Jev（tried 已排除答过没用的键）。
            //   11-01 读数：434 问里 claude 125 问占等待 82%，其中 51 问是「回到问过 1 次的页」就升级
            // 升级（慢后端）只在「同页问过 ≥ 2 次、且这页上一问是 Jev 答的没推进」时；升级问过下一问回到 Jev（卡住页上 Jev / 升级交替）。
            //   11-01 普查 414 次升级 90% 是同页重复问直接升级；离线重放：Jev 带同样试过没用名单答同一首键、且那一键推进了的 73 次是白升级，升级独有的推进只 32 次（11%）
            // 快档答了、只到了这页的页内新状态（没离开这页）也算「没推进」的一种，连续 3 问就升级（11-04 c1104_r2 泰拉瑞亚角色创建页：图例写「(X) 创建」，
            //   haiku 快档 25 问都答 A（把握 0.85–0.92），每下 A 只改页内状态、算「页内有进展」，上一问没推进的标记一直是 0、从没升级；
            //   同一张截图离线问 3 次：haiku A / A / B，sonnet X / X / PLUS）。协议翻页这类真进展每 4 问多一次升级，代价约 3 秒
            asked_esc = again >= 2 && (g_pages[pi].jev_miss || g_pages[pi].fast_stay >= 3);
            if (asked_esc && !g_pages[pi].jev_miss) LOG("自动玩家：快档在这页连续 %d 问都只到页内新状态、没离开这页，这一问升级", g_pages[pi].fast_stay);
            int r = vision_ask(tried, asked_esc, ks, 8, &playable, why, sizeof why);
            if (r == -2) { if (g_vis_unavail[0]) snprintf(fin_why, sizeof fin_why, "导航卡住（%s）", g_vis_unavail);
                else snprintf(fin_why, sizeof fin_why, "导航卡住（没有视觉驾驶员；回放到第 %d 步对不上）", g_lrn_cur + 1); break; }
            if (r == -3) { ap_sleep_us(2e6); poll_digest(0.5); continue; }   // 截图没写成：过会儿再截，不算驾驶员失败（11-03 归族 A：Overcooked 截图写盘卡住 3 次收局）
            if (r < 0) { if (++vis_fail >= 3) { snprintf(fin_why, sizeof fin_why, "导航卡住（驾驶员连续 3 次没给出回答）"); break; } ap_sleep_us(2e6); poll_digest(0.5); continue; }
            nk = r;
            int gp = gate_playable(playable, asked_esc, ks, &nk, tried, why, sizeof why); playable = gp != 0;
            esc_streak = gp == 2 ? esc_streak + 1 : 0;
            if (playable) {   // 进局双证：模型说可操控 + 读数到场景量级
                uint32_t d, p; int lvl = scene_level(&d, &p); play_streak++;
                if (lvl) { snprintf(fin_why, sizeof fin_why, "模型说可操控 + 读数到场景量级（绘制中位 %u、遍数 %u；基线 %u / %u）", d, p, g_base_d, g_base_p); marked = 1; }
                else if (play_streak >= 3 && d >= 50 && d >= g_base_d) { snprintf(fin_why, sizeof fin_why, "模型连续 %d 步说可操控、绘制中位 %u ≥ 50 且不低于基线 %u（开局即在场景里，基线就是场景量级）", play_streak, d, g_base_d); marked = 1; }
                // 低绘制游戏（11-01 街霸 30 周年合集：初代街霸对战每帧绘制中位 13、基线 8，菜单与对战读数分不开）：读数当不了第二证，
                //   改由升级后端（claude-sonnet）连续 2 问独立确认可操控、且绘制不低于开局基线
                else if (esc_streak >= 2 && d >= g_base_d) { snprintf(fin_why, sizeof fin_why, "升级后端连续 %d 问确认可操控、绘制中位 %u 不低于基线 %u（低绘制游戏，读数分不开菜单与局内）", esc_streak, d, g_base_d); marked = 1; }
                else LOG("自动玩家：模型说可操控但读数未到场景量级（绘制中位 %u、遍数 %u；基线 %u / %u），照键继续", d, p, g_base_d, g_base_p);
                if (marked) { stage = "局内段"; t_mark = now_ns(); f_mark = s2a_ap_frames(); break; }
            } else play_streak = 0;
            // 没键可按不是驾驶员失败（11-03 归族 A：18 款里 11 款以「连续 3 次没给出可用键」收局）：
            //   模型答空 = 让等（加载 / 过场）：等 3 秒再问，连等 10 次（约半分钟以上）还在等就按「全试过」兜底；
            //   答的全是试过的 = 模型想不出别的：代码按固定顺序挑一个这页没试过的动作按（戦国5 环境设定页就缺一下 DOWN），都试过了才算失败
            if (!nk && g_vis_empty == 1 && ++vis_wait <= 10) { LOG("自动玩家：驾驶员说等（第 %d 次），3 秒后再问", vis_wait); ap_sleep_us(3e6); poll_digest(0.5); continue; }
            if (!nk && g_vis_empty) { static const char *fb[] = {"DOWN", "UP", "RIGHT", "LEFT", "PLUS", "A:1.5", "X", "Y", "R", "L", "ZR", "B"};   // + 排在前（11-03 火影协议末页图例「+ 同意」，B 是返回）；B 最后（多是退回上一页）
                for (size_t q = 0; q < sizeof fb / sizeof fb[0] && !nk; q++) { char pat[16], cur[2100]; snprintf(pat, sizeof pat, ",%s,", fb[q]); snprintf(cur, sizeof cur, ",%s,", tried);
                    if (!strstr(cur, pat) && key_parse(fb[q], &ks[0])) { nk = 1; LOG("自动玩家：驾驶员%s，代码兜底按这页没试过的 %s", g_vis_empty == 1 ? "一直说等" : "答的全是试过的键", fb[q]); } } }
            if (!nk) { if (++vis_fail >= 3) { snprintf(fin_why, sizeof fin_why, "导航卡住（驾驶员连续 3 次没给出可用键）"); break; } ap_sleep_us(2e6); poll_digest(0.5); continue; }
            if (!g_vis_empty) vis_wait = 0;   // 兜底按的键不清等待计数（不然每按一个兜底键又要等满 10 次）
            vis_fail = 0;
            for (int i = 0; i < nk; i++) snprintf(ans + strlen(ans), sizeof ans - strlen(ans), "%s%s", i ? "," : "", ks[i].n);
            if (*toggle_key && !strcmp(ans, toggle_key) && !(toggle_n & 1)) {
                double w = 10.0 * (1 << (wait_n < 4 ? wait_n : 4)); wait_n++; steps--;
                LOG("自动玩家：%s 是开关（按了进一页、再按回原页，如暂停），现在没开着，这次不按、等 %.0f 秒让画面自己走（不计步）", ans, w);
                float w0[NG]; memcpy(w0, g_cur, sizeof w0); int still = 1;
                uint64_t t1 = real_ns() + (uint64_t)(w * 1e9 / tscale()); while (real_ns() < t1 && run_left_s() > end_left) { poll_digest(0.5); if (moved(g_cur, w0)) still = 0; }
                // 等了一整段画面一动没动：其实是我们按开着（暂停着），开关计数差了一拍，翻过来，下一问照按把它关掉
                wait_s += w;
                if (still) { toggle_n++; LOG("自动玩家：等的这段画面一动没动，%s 其实开着（暂停着），下一问照按关掉它", ans); }
                continue; }
        }
        if (*toggle_key && !strcmp(ans, toggle_key)) toggle_n++;
        int changed = 0; char keystr[200] = ""; float pre[NG], pre_e[NG];
        // 按键前采这页的动画格（0.6 秒），记进页表（之后认页也扣掉）
        if (nk > 0) { mot_sample(pg, 0.6); for (int q = 0; q < NG; q++) { g_pages[pi].mm[q] |= g_mm[q]; g_pages[pi].me[q] |= g_me[q]; } if (g_mm_n) LOG("自动玩家：这页有 %d / %d 格自己在动（动画背景），判变化与认页扣掉它们", g_mm_n, NG); }
        for (int i = 0; i < nk; i++) { snprintf(keystr + strlen(keystr), sizeof keystr - strlen(keystr), "%s%s", i ? "," : "", ks[i].n);
            int c = inject(&ks[i], pre, pre_e);
            // 点触没换页、还是同一页（指针界面常见「第一下选中 / 高亮、第二下确认」）：同一位置自动补第二下，不再问模型
            //   只亮了一小块（局部变化）也算没换页、照样补第二下
            if (ks[i].tx >= 0 && ddiff_m(g_cur, pre) < CHG && dncc_m(g_cur, pre, g_mm_n ? g_mm : NULL, NULL) >= 0.9f) { LOG("自动玩家：点触（第二下）%d,%d", ks[i].tx, ks[i].ty); float pre2[NG]; c = inject(&ks[i], pre2, NULL) || moved_m(g_cur, pre); }
            // 按键没变：隔 2 秒原样再按一次，两次都没变才算试过没用（11-01 塞尔达读档确认框：页面刚出来时游戏不收键，A 第一次没反应就被永久记成没用，16 种键换完局时用完）
            //   隔的是 2 秒且游戏新出够 2 秒的帧（标称帧率 × 2，最多再等 10 真秒）：页面不收键的窗口是按动画帧算的，低帧率 / 机器忙时 2 真秒出不够帧，
            //   第二下仍落在窗口里、被误记试过没用（11-01 main 单测 ⑫ 在 gate-host 并发负载下红：假宿主 45 帧不收键、自动玩家只等 2 秒）
            //   方向键 / 摇杆不重按：挪一格不是幂等的，高亮小、摘要看不出时第二下把光标挪回原处（11-02 塞尔达智慧的再现读档确认「是 / 否」两项循环：
            //   UP 实际挪到「是」、判没变又按一次回到「否」，后面的 A 也不按，真机自动玩家永远过不了这页；不重按时下一问截图里光标已在「是」，驾驶员答 A）
            if (!c && ks[i].tx < 0 && !(ks[i].m & (S2A_AP_UP | S2A_AP_DOWN | S2A_AP_LEFT | S2A_AP_RIGHT | S2A_AP_LS_LEFT | S2A_AP_LS_UP | S2A_AP_LS_RIGHT | S2A_AP_LS_DOWN | S2A_AP_RS_LEFT | S2A_AP_RS_UP | S2A_AP_RS_RIGHT | S2A_AP_RS_DOWN)) && dncc_m(g_cur, pre, g_mm_n ? g_mm : NULL, NULL) >= 0.9f) { int nf = s2a_ap_nominal_fps(); uint64_t fr0 = s2a_ap_frames(), need = (uint64_t)(2 * (nf > 0 ? nf : 30)), rt0 = real_ns();
                ap_sleep_us(2e6); while (s2a_ap_frames() < fr0 + need && real_ns() - rt0 < 10000000000ull) usleep(5000);
                poll_digest(0.5); LOG("自动玩家：%s 第一次没反应，隔 2 秒再按一次", ks[i].n); float pre2[NG]; c = inject(&ks[i], pre2, NULL) || moved_m(g_cur, pre); }
            if (!c && ks[i].tx >= 0) g_touch_fail++;
            changed |= c; if (changed && i + 1 < nk) settle(2.0);
            // 一组键里方向键 / 摇杆按了没动：后面的键（多是确认）是以挪动成功为前提的，不再按（11-01 银河2 存档页 LEFT 挪不动手形指针，紧跟的 A 把空档确认成新档）
            if (!c && i + 1 < nk && !ks[i].p2 && ks[i].tx < 0 && (ks[i].m & (S2A_AP_UP | S2A_AP_DOWN | S2A_AP_LEFT | S2A_AP_RIGHT | S2A_AP_LS_LEFT | S2A_AP_LS_UP | S2A_AP_LS_RIGHT | S2A_AP_LS_DOWN))) {
                LOG("自动玩家：%s 按了没动，这组后面的键不按（它们以挪动成功为前提）", ks[i].n); break; } }
        // 按 + 进了「前一页压暗 + 叠字」的一页 = 暂停菜单：能开暂停说明前一页已在局内（11-02 普查银河2：序章里 Jev 可操控概率只给 0.02–0.28，
        //   一直答 +，暂停菜单（带金币 / 星星碎片计数）进进出出到局时用完）。再按 + 关掉暂停，先不按键看 1.5 秒（过场会自己动：11-01 异度3 过场里 + 也进压暗暂停页），
//   画面自己不动、推左摇杆 1.5 秒整屏动了 + 读数到场景量级才记进局
        if (changed && nk == 1 && ks[0].m == S2A_AP_PLUS && !ks[0].p2) {
            double mp = 0, mq = 0; for (int q = 0; q < NG; q++) { mp += pre[q]; mq += g_cur[q]; } mp /= NG; mq /= NG; float cc = dncc(g_cur, pre);
            // 整屏纯色（格间标准差 < 4）时 dncc 退化成 1.0，不能作为结构证据：白闪 / 黑场 / 过场纯色帧不是暂停页
            //   （11-03 普查：戦国無双5 / 弹丸论破 / 数码宝贝 / 大富翁11 过场纯色，+ 被记成开关后翻倍等待 150–470 秒）
            if (mq < 0.85 * mp && cc >= 0.5f && gstd(pre) >= 4.0f && gstd(g_cur) >= 4.0f) {
                LOG("自动玩家：按 + 进了前一页压暗叠字的一页（亮度 %.0f → %.0f、结构相关 %.2f），像暂停菜单：关掉暂停、推左摇杆核实前一页能不能玩", mp, mq, cc);
                float pz[NG]; inject(&ks[0], pz, NULL); uint32_t d, p;
                if (play_check(&d, &p)) { snprintf(fin_why, sizeof fin_why, "按 + 进了暂停菜单（前一页压暗叠字）、关掉后推左摇杆整屏动了 + 读数到场景量级（绘制中位 %u、遍数 %u；基线 %u / %u）", d, p, g_base_d, g_base_p);
                    marked = 1; stage = "局内段"; t_mark = now_ns(); f_mark = s2a_ap_frames(); break; }
                // 这一步已把 + 按开又按关：同「开关识别」的结论，记 + 是开关、现在关着（之后没开着时不再按它，等画面自己走）；本步按没变处理
                if (!*toggle_key) { snprintf(toggle_key, sizeof toggle_key, "%s", keystr); toggle_n = 0; LOG("自动玩家：按 %s 进了暂停页、再按 %s 回到原页：%s 是开关（如暂停），之后它没开着时不再按它", keystr, keystr, keystr); }
                changed = 0; } }
        int back = -1;
        // 开关识别：上一步按 K 之前的画面是 P（按键那一刻），按完到了这页；这步再按 K，变了的第一张离 P 的整屏均差不到这页离 P 的一半
        //   （暂停页 = P 压暗 + 叠字，零均值相关仍高、page_find 分不开，按均差远近判；过场在问模型时还在播，P 取按键那一刻、不取步开始那张）
        //   只认 + / -（Switch 惯例：开暂停 / 菜单的键）；A 这类确认键在菜单里进一页再回来是正常导航（11-01 异度3 第三局：标题页 A 被认成开关、一直不按，导航 300 秒放弃）
        // 开关识别追加：「进的页」必须是「按之前那页」的压暗叠字版（亮度 ≤85%、结构相关 ≥0.5、双页格间标准差 ≥4）。
        //   菜单 A / PLUS 在两张不同菜单页之间来回：结构相关通常 < 0.5、或其中一页是纯色 → 不记开关、正常记回头路
        //   （11-03 普查：戦国無双5 / 弹丸论破 / 数码宝贝 / 大富翁11：+ 在两张菜单页来回 / 过场纯色帧，
        //    prev_pg→pg 亮度不降或纯色，gstd 过滤后不再记开关，节省 150–470 秒翻倍等待）
        { double mp2 = 0, mq2 = 0; for (int q = 0; q < NG; q++) { mp2 += prev_pg[q]; mq2 += pg[q]; } mp2 /= NG; mq2 /= NG;
          float cc2 = dncc(pg, prev_pg);
        if (changed && !*toggle_key && have_prev && nk == 1 && (ks[0].m == S2A_AP_PLUS || ks[0].m == S2A_AP_MINUS) && !ks[0].p2
            && !strcmp(keystr, prev_key) && ddiff(pg, prev_pg) >= CHG && 2 * ddiff(g_chg1, prev_pg) < ddiff(pg, prev_pg)
            && mq2 < 0.85 * mp2 && cc2 >= 0.5f && gstd(prev_pg) >= 4.0f && gstd(pg) >= 4.0f) {
            snprintf(toggle_key, sizeof toggle_key, "%s", keystr); toggle_n = 0;
            LOG("自动玩家：按 %s 进了一页、再按 %s 又回到原页：%s 是开关（如暂停），之后它没开着时不再按它", keystr, keystr, keystr); } }
        if (changed) { memcpy(prev_pg, pre, sizeof prev_pg); have_prev = nk == 1; snprintf(prev_key, sizeof prev_key, "%s", keystr); }
        int to = -1;
        // 回头路 = 去了比这页更早第一次到过的页（页号按第一次到达的顺序给）；去往这页之后才到过的页是往前走（11-02 大航海4：标题 A 进开新游戏页、
        //   那页答 B 退回标题，再按 A 又到开新游戏页，原先「到了走过的页」一律算回头，把标题唯一对的 A 拉黑，模型只能去试读档组合到局时用完）
        if (changed) { settle(5.0); to = page_find(g_cur, g_cur_e); if (to >= 0 && to < pi) back = to; }
        if (changed && nk == 1 && ks[0].m == S2A_AP_PLUS && !ks[0].p2 && to != pi) { plus_from = pi; plus_pend = 1; }
        else if (changed && pi == pause_pg && to >= 0 && to == plus_from) {
            LOG("自动玩家：在按 + 进的那页（第 %d 页）按 %s 回到了按 + 前那一页（第 %d 页）= 关掉暂停，不算走回头路", pi + 1, keystr, to + 1); back = -1; pause_pg = -1;
            if (!resume_chk[to]) { uint32_t d, p; resume_chk[to] = 1; LOG("自动玩家：核实第 %d 页能不能玩", to + 1);
                if (play_check(&d, &p)) { snprintf(fin_why, sizeof fin_why, "第 %d 页按 + 进了一页、在那页按 %s 又回到第 %d 页（暂停层开 / 关）、推左摇杆整屏动了 + 读数到场景量级（绘制中位 %u、遍数 %u；基线 %u / %u）", to + 1, keystr, to + 1, d, p, g_base_d, g_base_p);
                    marked = 1; stage = "局内段"; t_mark = now_ns(); f_mark = s2a_ap_frames(); break; } } }
        if (changed) {
            // 还在同一页（页内变了：光标挪了 / 翻页了 / 二号加入了）：到了这页没见过的页内状态 = 有进展，先前试过没用的键在新状态下可能有用了，清掉
            //   （11-01 双人成行二号加入后 A 才能 Proceed；11-02 太鼓多页协议每按 RIGHT 翻到新页）；回到见过的页内状态 = 页内来回、没进展，记成试过没用
            //   （11-01 银河2 存档页星空背景一直在动，R / A 每按都「变了」又回同一页，从没进试过没用，来回 30 多问）
            if (to == pi) { page_st_seen(pi, pre, pre_e, g_pre_lum, g_pre_w, g_pre_h, 1);
                // 来回拉黑记进 ban；「试过没用」只剩 ban：按它又回到了另一个页内状态，先前在别的状态下记的「没反应」不作数
                //   （11-01 怪猎崛起 Spare-host：语言页改选里 DOWN 没反应、A 退出改选被判来回，旧规则 DOWN 仍算试过没用，回到普通状态 A、DOWN 都不能按，32 问卡死）
                if (page_st_seen(pi, g_cur, g_cur_e, g_cur_lum, g_cur_lw, g_cur_lh, 1)) { tried_add(g_pages[pi].ban, sizeof g_pages[0].ban, ks, nk); snprintf(tried, sizeof g_pages[0].tried, "%s", g_pages[pi].ban); changed = 0;
                    LOG("自动玩家：按 %s 回到这页见过的页内状态（页内来回、没进展），记为试过没用（只留来回拉黑的键）：%s", keystr, tried); }
                else { LOG("自动玩家：按 %s 到了这页没见过的页内状态（页内有进展）", keystr);
                    if (*tried) { LOG("自动玩家：页内变了（同一页），这页试过没用的键 %s 清空", tried); *tried = 0; } g_pages[pi].ban[0] = 0; } } }
        if (!from_replay) { g_pages[pi].jev_miss = !asked_esc && !(changed && back < 0); g_pages[pi].fast_stay = !asked_esc && changed && to == pi ? g_pages[pi].fast_stay + 1 : 0; }
        // 走回头路第一次只记一条边、不拉黑（11-03 归族 C：路易吉洋馆 DLC 弹窗按 A 回到塔楼背景、伊苏X「找不到存档」页按 B、JUMP FORCE 捏人页 DOWN+A，
        //   都是这页唯一的出口，第一次回到更早的页就被拉黑，随后同版式的新弹窗认成同一页、继承了黑名单）：同一页同一动作第二次走回同一页才拉黑
        int first_back = changed && back >= 0 && !from_replay && back_edge(pi, back, keystr) < 2;
        last_pi = pi; last_nk = changed && !from_replay && nk <= 8 ? nk : 0; if (last_nk > 0) memcpy(last_ks, ks, sizeof(vkey) * (size_t)last_nk);
        if (first_back) LOG("自动玩家：按 %s 回到走过的第 %d 页（第 1 次，先不拉黑；同一页同一动作再回一次才算回头路）", keystr, back + 1);
        if (changed && back < 0) { lrn_walk(pg, keystr); if (from_replay) { g_lrn_cur = li + 1; replayed++; } }
        else if (!first_back) {
            tried_add(tried, sizeof g_pages[0].tried, ks, nk);
            // 环：这页的出口只回到进它的那一页（选人数页 A → 准备手柄弹窗 → A 回选人数页，11-04 归族 A Snipperclips）：进这页的键也记为那一页试过没用，驾驶员别再答它
            if (back >= 0 && back == g_pages[pi].in_from) g_pages[pi].back_n++;
            // 判环：这页有回到进入页的回头键被拉黑，且按了没变的键 >= 2 个（出口被探光，只剩回头）；还有没试的出口时不判（11-04 ㉚：菜单 B / Y 都回标题、X 才是出路，没变的键 0 个）
            { int nt = 0; for (const char *c = tried; *c; c++) nt += *c == ',' ; nt += *tried != 0; int ef = g_pages[pi].in_from;
              if (ef >= 0 && g_pages[pi].in_n > 0 && g_pages[pi].back_n >= 1 && nt - g_pages[pi].back_n >= 2) {
                tried_add(g_pages[ef].tried, sizeof g_pages[0].tried, g_pages[pi].in_ks, g_pages[pi].in_n); tried_add(g_pages[ef].ban, sizeof g_pages[0].ban, g_pages[pi].in_ks, g_pages[pi].in_n);
                LOG("自动玩家：第 %d 页的出口只回到第 %d 页（环；回头键 %d 个、按了没变的键 %d 个），进这页的键也记为第 %d 页试过没用：%s", pi + 1, ef + 1, g_pages[pi].back_n, nt - g_pages[pi].back_n, ef + 1, g_pages[ef].tried);
                g_pages[pi].in_from = -2; } }
            if (back >= 0) LOG("自动玩家：按 %s 回到走过的第 %d 页（走回头路），记为第 %d 页试过没用：%s", keystr, back + 1, pi + 1, tried);
            else LOG("自动玩家：这页试过没用的键 %s（告诉驾驶员别再答）", tried);
            if (from_replay) { g_lrn[li].burnt = 1; LOG("自动玩家：回放对不上（页相似 %.2f 但按 %s %s），这页交回 AI", sim, keystr, back >= 0 ? "走了回头路" : "画面没变"); }
        }
    }
    if (marked) {
        // 进局判定到了先等画面稳下来再记 MARK 帧、截 ap_mark（11-01 八方2：模型说可操控那一刻游戏还在进区域的整幅模糊过渡，ap_mark 被判画面不过；
        //   丝之歌 MARK 后头 600 帧 45 个慢帧是同一段过渡，混进了帧率窗口）。最多等 5 秒，一直在动（动画场景）就按 5 秒后那一帧
        uint64_t f_judge = s2a_ap_frames(), r0 = real_ns(); settle(5.0); t_mark = now_ns(); f_mark = s2a_ap_frames(); g_mark_delay_s = (real_ns() - r0) / 1e9;   // 上限 5 秒是真墙钟、超时照记 MARK
        LOG("自动玩家：MARK 延后 %.1f 秒（判定在帧 %llu，等画面稳定到帧 %llu；帧率窗口从这里起）", g_mark_delay_s, (unsigned long long)f_judge, (unsigned long long)f_mark);
        LOG("S2A 标记 MARK：帧 %llu", (unsigned long long)f_mark);
        g_shots_mark = g_shots;
        LOG("自动玩家：导航 → 局内段（依据：%s；第 %d 步、按键 %d 下、驾驶员 %d 问、回放 %d 步）", fin_why, steps, g_presses, g_vis_n, replayed);
        if (s2a_ap_audio_mark) s2a_ap_audio_mark(); else LOG("【红】未实现：自动玩家/s2a_ap_audio_mark（声音层没登记稳态窗口，能玩格「有声」记未测）");
        save_png("ap_mark.png"); if (g_vis_n) lrn_save(g_cur);   // 纯回放进局不改学过的路线；问过模型（首次 / 回放中途交回 AI）就按本局走过的重写
        speed_probe();   // S2A_AP_SPEED=1 才跑：MARK 后先按时钟推摇杆量画面横移速度（逻辑速度判据，见 speed_probe）
        // 局内段：随机移动 / 攻击（固定种子，每局同一序列），过半 ap_mid.png、结束 ap_end.png；不调模型
        static const uint32_t acts[] = {S2A_AP_LS_UP, S2A_AP_LS_DOWN, S2A_AP_LS_LEFT, S2A_AP_LS_RIGHT, S2A_AP_LS_UP | S2A_AP_LS_LEFT, S2A_AP_LS_UP | S2A_AP_LS_RIGHT, S2A_AP_LS_DOWN | S2A_AP_LS_LEFT, S2A_AP_LS_DOWN | S2A_AP_LS_RIGHT,
                                        S2A_AP_A, S2A_AP_B, S2A_AP_X, S2A_AP_Y, S2A_AP_ZR, S2A_AP_RS_LEFT, S2A_AP_RS_RIGHT};
        // S2A_AP_HOLD=<键>：局内段全程按住这个键（赛车按住油门才开得出起跑区；11-01 测试设备1 马车8 截比赛两侧要开到第一个弯前）。键名同驾驶员答案（A、ZR …），不收点触 / 二号手柄
        uint32_t hold = 0;
        { const char *h = getenv("S2A_AP_HOLD"); vkey hk;
          if (h && *h) { if (key_parse(h, &hk) && hk.tx < 0 && !hk.p2) { hold = hk.m; LOG("自动玩家：局内段全程按住 %s（S2A_AP_HOLD）", h); }
                         else LOG("【红】自动玩家：S2A_AP_HOLD=%s 不是能按住的键，忽略", h); } }
        uint32_t seed = 20261031; int mid = 0, early = 0; uint64_t t_end = t_mark + (uint64_t)(loop_s * 1e9);
        // 提前收局（S2A_AP_EARLY_S）：照常窗口从 MARK 或最后一个改出帧状态的段（A/B）结束时起算；过半截 ap_mid（没开时同旧：局内段过半）。
        //   判据 = 登记的段全部销号 且 照常出帧 ≥ early_s 秒 且 出图没停（最近 2 秒内有新帧：停着的局留给「出图停 60 秒」/ 普查卡死判据，不判过）
        #define AP_BASE() (seg_perturb_end() > t_mark ? seg_perturb_end() : t_mark)
        #define AP_MID_DUE() (now_ns() >= (early_s > 0 ? AP_BASE() + (uint64_t)(early_s / 2 * 1e9) : t_mark + (uint64_t)(loop_s / 2 * 1e9)))
        #define AP_EARLY_DUE() (early_s > 0 && now_ns() >= AP_BASE() + (uint64_t)(early_s * 1e9) && (real_ns() - g_last_new_f_t) / 1e9 < 2 && !seg_pending(NULL, 0))
        const char *prs = getenv("S2A_AP_PADREC"); int want = prs && *prs, played = want && padrec_play(prs, t_end);
        // 设了回放却没放成（打不开 / 没有手柄行）：局内段也原地不动，不退回随机动作——随机乱走会被当成「回放走偏」（11-02 真机「乱转」实为没放成）
        if (want && !played) LOG("【红】自动玩家：S2A_AP_PADREC 没放成，局内段原地不动（不跑随机动作）");
        while (want && now_ns() < t_end) {   // 回放放完（或没放成）：原地不动，照常过半截图、出图停 60 秒收局
            ap_sleep_us(200000); frame_tick();
            if (!mid && AP_MID_DUE()) { mid = 1; save_png("ap_mid.png"); }
            if ((real_ns() - g_last_new_f_t) / 1e9 > 60) { LOG("自动玩家：局内段出图停 60 秒，提前收局"); break; }
            if (AP_EARLY_DUE()) { early = 1; break; }
        }
        atomic_store(&g_mask, hold);
        // 第一轮同局 A/B 帧率涨了却量不出（MARK 落在静止画面：11-02 足球小将开球等待页 q 2.13、画面 0 像素/秒）：随机动作跑 AB_RETRY_S 秒后再测一轮，
        //   局内踢起来 / 走起来再量；普查按最后一行「逻辑速度同局 A/B」入账（tools/census/census.py fps_ab）。只重测一次，回放局（padrec）不重测
        uint64_t t_retry = now_ns() + (uint64_t)(AB_RETRY_S * 1e9);
        int rseg = !want && g_ab_retry ? s2a_ap_seg_open("逻辑速度同局 A/B 重测", 1) : -1;   // 重测在局内段 AB_RETRY_S 秒后才跑：登记成段，提前收局要等它
        while (!want && !early && now_ns() < t_end) {
            if (g_ab_retry && now_ns() >= t_retry) {
                g_ab_retry = 0; atomic_store(&g_mask, 0);
                LOG("逻辑速度同局 A/B：第一轮帧率涨了却量不出画面运动，局内段跑了 %.0f 秒，重测一轮", AB_RETRY_S); speed_ab(); s2a_ap_seg_close(rseg);
                atomic_store(&g_mask, hold); continue;
            }
            seed = seed * 1103515245u + 12345u; uint32_t m = acts[(seed >> 16) % (sizeof acts / sizeof *acts)];
            seed = seed * 1103515245u + 12345u; double dur = m & (S2A_AP_LS_LEFT | S2A_AP_LS_UP | S2A_AP_LS_RIGHT | S2A_AP_LS_DOWN) ? 0.5 + ((seed >> 16) % 1500) / 1000.0 : 0.15;
            atomic_store(&g_mask, m | hold); uint64_t t1 = now_ns() + (uint64_t)(dur * 1e9); while (now_ns() < t1 && now_ns() < t_end) { ap_sleep_us(20000); frame_tick(); }
            atomic_store(&g_mask, hold); ap_sleep_us(200000);
            if (!mid && AP_MID_DUE()) { mid = 1; save_png("ap_mid.png"); }
            if ((real_ns() - g_last_new_f_t) / 1e9 > 60) { LOG("自动玩家：局内段出图停 60 秒，提前收局"); break; }
            if (AP_EARLY_DUE()) { early = 1; break; }
        }
        atomic_store(&g_mask, 0);
        if (early) LOG("自动玩家：提前收局（S2A_AP_EARLY_S=%g）：MARK 后段全部跑完、照常出帧 %.0f 秒、MARK 后共 %.0f 秒", early_s, (now_ns() - AP_BASE()) / 1e9, (now_ns() - t_mark) / 1e9);
        else { char pn[300]; if (early_s > 0 && seg_pending(pn, sizeof pn)) LOG("自动玩家：局内段到时长，MARK 后段还没跑完：%s", pn);
            LOG("自动玩家：局内段 %.0f 秒跑完", loop_s); }
        #undef AP_BASE
        #undef AP_MID_DUE
        #undef AP_EARLY_DUE
    }
finish:
    atomic_store(&g_mask, 0); atomic_store(&g_mask2, 0); stage = marked ? "收局" : stage;
    save_png(marked ? "ap_end.png" : "ap_stuck.png");
    if (!marked && g_vis_n) lrn_save(NULL);   // 没到 MARK 也存走过的前沿（11-01：银河2 / 异度3 卡住的款永远学不到，每局从头问模型）
    if (!marked) { char w[460]; snprintf(w, sizeof w, "自动玩家没进可玩：%s", fin_why);
        if (s2a_thread_dump) { LOG("自动玩家：线程表（%s）", w); s2a_thread_dump(); } if (s2a_dump_threads) s2a_dump_threads(w); }
    uint64_t t = now_ns(), f = s2a_ap_frames();
    char path[1200]; snprintf(path, sizeof path, "%s/ap_summary.json", g_dir); FILE *o = fopen(path, "w");
    if (o) { fprintf(o, "{\"marked\": %s, \"mark_frame\": %llu, \"start_to_mark_s\": %.1f, \"first_frame_to_mark_s\": %.1f, \"first_frame_s\": %.1f, \"stage\": \"%s\", \"why\": \"%s\",\n"
                     " \"presses\": %d, \"presses_changed\": %d, \"steps\": %d, \"vision_asks\": %d, \"vision_s\": %.1f, \"replayed_steps\": %d, \"mark_delay_s\": %.1f, \"base_draws\": %u, \"base_passes\": %u, \"frames\": %llu, \"wall_s\": %.1f}\n",
                 marked ? "true" : "false", (unsigned long long)f_mark, marked ? secs(t_mark) : -1.0, marked && t_first ? (t_mark - t_first) / 1e9 : -1.0, t_first ? secs(t_first) : -1.0, stage, fin_why,
                 g_presses, g_presses_changed, steps, g_vis_n, g_vis_s, replayed, g_mark_delay_s, g_base_d, g_base_p, (unsigned long long)f, secs(t)); fclose(o); }
    LOG("自动玩家结论：%s；%s；按键 %d 下（翻页 %d）、驾驶员 %d 问（%.0f 秒）、回放 %d 步；点触没反应 %d 次；小结 %s", marked ? "到 MARK" : "没到 MARK", fin_why, g_presses, g_presses_changed, g_vis_n, g_vis_s, replayed, g_touch_fail, path);
    LOG("自动玩家：截图请求 %llu 次，其中局内段 %llu 次（导航期间隔下限 %llu ms，S2A_AP_SHOT_MIN_MS；局内段只看帧计数）", (unsigned long long)g_shots,
        (unsigned long long)(g_shots_mark == ~0ull ? 0 : g_shots - g_shots_mark), (unsigned long long)(shot_min_ns() / 1000000ull));
    s2a_ap_shutdown("自动玩家结束");
    return NULL;
}
