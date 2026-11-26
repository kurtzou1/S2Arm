// 自动玩家单测假宿主：模拟游戏（标题 → 菜单 → 局内），不碰任何真游戏。用法：t_autoplay <输出目录> <场景>
// 画面 64×36 BGRA：标题 = 横条纹、菜单 = 竖条纹、局内 = 不重复纹理随镜头平移（左右摇杆推镜头）；当前状态名写进 <输出目录>/state，假驾驶员（fake_vision.sh）读它作答。
// 每帧绘制数：标题 / 菜单 20（开局基线），局内 600（场景量级）；lowdraw 场景局内只有 30（读数不到场景量级）。
// 场景：
//   ok      标题 A → 菜单，菜单 A → 局内
//   titlex  标题只认 X（A 没反应）→ 菜单，菜单 A → 局内（造「标题按 X」的学过路线，给 ⑧ 回放对不上用）
//   stuck   标题按什么都不变
//   lowdraw 同 ok，但局内每帧绘制 30
//   pingpong 标题 A → 菜单；菜单 B 退回标题、X 进局（A 没反应）——回到问过的页要带上那次答过的键
//   fwd      同 pingpong，但菜单 B / Y 都退回标题（仿大航海4：开新游戏后的页答错退回标题），X 进局——标题的 A 往前走回已到过的菜单不算回头路、不该被拉黑
//   daynight 同 fwd，但每回到标题页上半屏天空换一次昼夜（亮度渐变方向反过来，字和框不变；仿 11-02 nav1102r 泰拉瑞亚标题页背景昼夜变色）
//   lag      同 ok，但菜单页出现后 45 帧（1.5 秒）内不收键、且这页第一下 A 一定不收（仿塞尔达读档确认框淡入时不认 A）；帧数可用 S2A_TEST_LAG_FRAMES 改
//   anim     同 ok，但局内画面每帧自己平移（一直稳不下来）——进局后等画面稳定要撞 5 秒上限、照记 MARK
//   tap2     标题按键都没反应；点触 (560–720, 300–420) 第一下只亮一小块（选中），第二下才进菜单；菜单 A → 局内
//   pausep   同 ok，但驾驶员在局内只答 +（仿 11-02 普查银河2：Jev 可操控概率低）：局内 + 进暂停（局内画面压暗 + 一行字），暂停里 + 回局内
//   pager    多页用户协议（仿 11-02 普查太鼓 22 页协议）：标题页 5 页长得一样、只有页码块位置不同，RIGHT 翻下一页，最后一页 A → 菜单；菜单 A → 局内
//   pauseb   同 pausep，但暂停页是局内画面模糊（5×5 均值，亮度不降）+ 一行字，暂停里 A（继续）回局内（仿 11-02 nav1102r 银河2 暂停菜单）；局内驾驶员只答 +、暂停里答 A
//   pagetext 同 pager，但各页只差 1 像素细线（奇数坐标，亮度摘要每格隔 4 像素取均值、采不到，只有细节摘要看得见；仿 11-02 nav1102r 太鼓协议各页只差正文字形）
//   stay     标题 R / A 只把一小块翻亮 / 翻暗（页内变了、还在这页，仿银河2 存档页 R / A 来回），X 才进菜单；菜单 A → 局内
//   cut      开场过场（仿异度3）：标题页是每 10 帧换一个镜头的过场，自己播满 900 帧进菜单；+ 只暂停（进 PAUSE 页、过场停在那一帧），再按 + 取消回原帧；菜单 A → 局内
//   atog     标题 A → 菜单；菜单 A 退回标题（像开关，但 A 不是暂停键）、X 进局（仿异度3 标题页 A 被误认成开关）
//   navfail  标题页（仿银河2 手形指针存档页）：方向键不动；A 选中指针下的空档（进 PAUSE，坏结果）；点触 (560–720, 300–420) 进菜单；菜单 A → 局内
//   lang     怪猎崛起首次「语言」页（11-01 Spare-host 卡死现场）：同一页里光标在显示语言时 A 进改选、改选里 A 退回、改选里方向键都没反应；
//            普通状态 DOWN 挪到语音语言、再 DOWN 挪到确定，确定上 A → 菜单；菜单 A → 局内（子状态名写进 state：LANG / EDIT / ROW1 / OK）
//   waves    标题页下半屏每帧自己在动（仿幻想水浒标题海浪），上半屏静止；A 没反应、X 才进菜单；菜单 A → 局内（动画格不扣掉的话 A 次次判「变了」、页也认不回来）
//   speeda   同 ok，但局内镜头按真实时间平移（每秒 30 像素，A 类）；ok 是每帧 1 像素（按帧推进，B 类）。逻辑速度探测（S2A_AP_SPEED=1）用
//   abfix / abrt 同 ok，但局内不按键画面自己平移：abfix 按帧推进（每 2 帧 1 像素）、abrt 按真实时间（每秒 15 像素）。
//   abkick  同 abfix，但第一轮同局 A/B 测完前局内完全静止（11-02 足球小将：MARK 落在开球等待页，第一轮量不出，局内踢起来后重测判红）
//   （同局 A/B：S2A_AP_SPEED=ab 时假宿主给 s2a_fps_ab_set，回原帧率那段帧间隔翻倍；abfix 判红、abrt 判绿；abmix 走路按时间、镜头按帧，合起来判红）
//   speedmenu 同 ok，但进局后先停在局内菜单（摇杆不动镜头），按 B 退出后镜头才跟摇杆（异度3 读档停在休息地点菜单）
//   focus    Minecraft「准备游玩」页（11-02 导航 N4）：焦点框是奇数坐标上的 1 像素细线（摘要每格隔 4 像素取均值，采不到），焦点在「返回」时 A 没反应、
//            DOWN 把焦点挪到「游玩」、焦点在「游玩」上 A → 菜单；菜单 A → 局内（子状态名写进 state：FOCUS0 / FOCUS1）
//   scroll   怪猎「关于用于统计的数据处理」页（11-02）：长文本带滚动条，A 没反应；右摇杆下推滚到底（右下角滚动条块亮起）后 A → 菜单；菜单 A → 局内
//            （子状态名写进 state：SCROLL0 / SCROLL1）
//   yesno    塞尔达智慧的再现读档确认「是 / 否」（11-02 真机）：两项上下循环、高亮画面上看不出（摘要采不到），光标起在「否」；UP / DOWN 换项，
//            光标在「是」上 A → 菜单、在「否」上 A 没反应；菜单 A → 局内（子状态名写进 state：YES0 / YES1）
//   popback  路易吉洋馆 DLC 弹窗（11-03 归族 C）：标题 A → 菜单（弹窗 1）；菜单 A 回到标题（回到更早的页），30 帧后标题上自己又弹出菜单（弹窗 2，同版式）；
//            菜单 A 第二次 → 局内。A 是弹窗唯一的出口，第一次回到标题时不该被拉黑
//   ring     Snipperclips 选人数页 ↔ 准备手柄弹窗的环（11-04 归族 A）：标题 = 选人数页，A → 菜单（弹窗）、X → 局内；菜单 A 回标题。弹窗 A 第 2 次回头路拉黑时，进弹窗的标题 A 也要记为标题试过没用，驾驶员才会改答 X
//   sideways Super Mario Party 横握单只 Joy-Con 提示页（11-03 归族 E）：标题要 SL+SR 同按才进菜单（别的键都没反应）；菜单 A → 局内
//   agree    火影协议末页（11-03）：图例「+ 同意 / B 返回」，标题只认 + 进菜单、B 退回（进 PAUSE，坏结果）；菜单 A → 局内
//   coop     双人成行「Player Two Join」页：一号 A 没反应；接上第二个手柄、二号按 A 只亮一小块（加入，整屏均差够不到页变门槛），之后一号 A 才进菜单；菜单 A → 局内
//   pflash   整屏纯色帧来回（仿 11-03 戦国無双5 / 弹丸论破 / 数码宝贝 / 大富翁11）：TITLE 整屏白（gstd≈0），+ → PAUSE 整屏黑（gstd≈0），+ 回 TITLE；菜单 A → 局内（整屏纯色帧不能记开关）
//   pmenu    PLUS 在两张不同菜单页来回（仿 11-03 过场菜单来回）：TITLE 条纹菜单 → PLUS → MENU 不同条纹、亮度相近 → PLUS 回 TITLE；A 进局（菜单来回不能记开关）
//   cstay    泰拉瑞亚角色创建页（11-04 c1104_r2）：标题 A 每按一次只把一个亮块挪到新位置（页内新状态、不离开这页，14 个位置轮转），X 才进菜单；菜单 A → 局内。
//            快档驾驶员（FAKE_MAP）只答 A、升级后端（FAKE_ESC_MAP）答 X：快档在页内打转时要升级
// 帧间隔 S2A_TEST_FRAME_MS（缺省 33.3），与自动玩家同按 S2A_AP_TIMESCALE 倍率出帧。
#include "autoplay_host.h"
#include <math.h>
#include <pthread.h>
#include <stdarg.h>
#include <stdatomic.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <unistd.h>

enum { W = 64, H = 36 };
enum { TITLE, MENU, GAME, PAUSE };
static const char *k_state[] = {"TITLE", "MENU", "GAME", "PAUSE"};
static _Atomic uint64_t g_frames, g_state_f; static _Atomic int g_state, g_cam, g_done, g_hl, g_tvis;   // g_tvis：进标题页的次数（daynight 换昼夜）
static FILE *g_log; static pthread_mutex_t g_lm = PTHREAD_MUTEX_INITIALIZER;
static char g_dir[1024]; static const char *g_scn; static double g_ts = 1;

uint64_t s2a_ap_frames(void) { return atomic_load(&g_frames); }
// 游戏时钟（自动玩家 dlsym 取，见 autoplay.c game_ns）：每出一帧加这帧的标称间隔（判据时钟纳秒，回原帧率段翻倍），不看墙钟——机器忙时出帧慢，游戏时间跟着慢，
//   逻辑速度用例（㉛㉜㉞㉟㊴）量的位移 ÷ 时间、帧数 ÷ 时间都按游戏自己的时间算，不随负载变。g_fm 罩住一帧的推进（帧号 + 时钟 + 画面状态）和截图，截图拿到的时钟正好是画面那一帧的
static _Atomic uint64_t g_gns; static pthread_mutex_t g_fm = PTHREAD_MUTEX_INITIALIZER; static _Thread_local uint64_t t_shot_ns;
uint64_t s2a_ap_game_ns(void) { return atomic_load(&g_gns); }
uint64_t s2a_ap_shot_ns(void) { return t_shot_ns; }
uint32_t s2a_ap_draws(void) { int st = atomic_load(&g_state); return st == GAME ? (!strcmp(g_scn, "lowdraw") ? 30 : 600) : 20; }
int s2a_ap_nominal_fps(void) { return 30; }
static _Atomic int g_cut_waited;   // cut：自动玩家已做出「+ 是开关、现在没开着，这次不按、等」的决定（⑲ 要看的那一步）
static _Atomic int g_pb_judged;    // popback：自动玩家已判完「菜单 A 回到了走过的标题页」（㊸ 要看的那一步）
void s2a_ap_log(const char *fmt, ...) {
    if (strstr(fmt, "这次不按")) atomic_store(&g_cut_waited, 1);
    if (strstr(fmt, "回到走过的第")) atomic_store(&g_pb_judged, 1);
    va_list a; va_start(a, fmt); pthread_mutex_lock(&g_lm); vfprintf(g_log, fmt, a); fputc('\n', g_log); fflush(g_log); pthread_mutex_unlock(&g_lm); va_end(a);
}
static _Atomic int g_marked;   // 自动玩家打了 MARK（声音层稳态窗口钩子就在 MARK 那一刻调）：之后的局内帧记 S2A_AP_HOLD 用例的按键事件
// S2A_TEST_AUDIO_SEG_S=<判据秒>：照声音层契约（services/S2A.Services/AudioPeak.cs）把稳态窗口登记成 MARK 后段，到时打峰值行、销号（提前收局用例 ㊿）
static void *audio_win(void *a) { int id = (int)(intptr_t)a; usleep((useconds_t)(atof(getenv("S2A_TEST_AUDIO_SEG_S")) * 1e6 / g_ts));
    s2a_ap_log("[声] 稳态窗口：输出峰值 0.500（帧 %llu）", (unsigned long long)atomic_load(&g_frames)); s2a_ap_seg_close(id); return NULL; }
void s2a_ap_audio_mark(void) { atomic_store(&g_marked, 1); s2a_ap_log("[声] 稳态窗口开始");
    const char *e = getenv("S2A_TEST_AUDIO_SEG_S"); pthread_t t;
    if (e && atof(e) > 0) { pthread_create(&t, NULL, audio_win, (void *)(intptr_t)s2a_ap_seg_open("声音稳态窗口", 0)); pthread_detach(t); } }
void s2a_ap_shutdown(const char *why) { s2a_ap_log("收局：%s", why); atomic_store(&g_done, 1); }
static uint8_t noise(int x, int y) { uint32_t h = (uint32_t)(x * 374761393 + y * 668265263); h = (h ^ (h >> 13)) * 1274126177u; return (uint8_t)(40 + (h >> 24) % 180); }
static uint8_t blur5(int x, int y) { int s = 0; for (int dy = -2; dy <= 2; dy++) for (int dx = -2; dx <= 2; dx++) s += noise(x + dx, y + dy); return (uint8_t)(s / 25); }   // pauseb 暂停页：局内画面模糊
int32_t nxgal_screenshot(void *out, int32_t cap, int32_t *w, int32_t *h) {
    *w = W; *h = H; if (!out) return W * H * 4; if (cap < W * H * 4) return 0;
    if (!strcmp(g_scn, "noshot")) return 0;   // 出图在涨、截图一直拿不到（取图请求丢了）
    pthread_mutex_lock(&g_fm); t_shot_ns = atomic_load(&g_gns);
    int st = atomic_load(&g_state), cam = atomic_load(&g_cam); uint8_t *p = out;
    for (int y = 0; y < H; y++) for (int x = 0; x < W; x++) {
        if (!strcmp(g_scn, "scroll") && st == TITLE) {   // 横条纹正文 + 滚到底后右下角滚动条块（8×8）亮起
            uint8_t *q = p + (y * W + x) * 4; q[0] = q[1] = q[2] = atomic_load(&g_hl) && x >= 56 && y >= 28 ? 255 : (y / 3) % 2 ? 200 : 40; q[3] = 255; continue; }
        if (!strcmp(g_scn, "focus") && st == TITLE) {   // 灰底 + 当前焦点那个框的 1 像素边（坐标全是奇数）
            int hl = atomic_load(&g_hl), bx0 = hl ? 39 : 9, bx1 = hl ? 55 : 19, by0 = hl ? 23 : 9, by1 = hl ? 29 : 13;
            int edge = ((x == bx0 || x == bx1) && y >= by0 && y <= by1) || ((y == by0 || y == by1) && x >= bx0 && x <= bx1);
            uint8_t *q = p + (y * W + x) * 4; q[0] = q[1] = q[2] = edge ? 255 : 100; q[3] = 255; continue; }
        uint8_t v = !strcmp(g_scn, "pflash") && st == TITLE ? 255 : !strcmp(g_scn, "pflash") && st == PAUSE ? 0 : !strcmp(g_scn, "pmenu") && st == MENU && atomic_load(&g_hl) == 2 ? (uint8_t)((y / 2) % 2 ? 180 : 60) : !strcmp(g_scn, "pmenu") && st == MENU ? (uint8_t)((x / 4) % 2 ? 190 : 50) : !strcmp(g_scn, "pauseb") && st == PAUSE ? (uint8_t)(blur5(x + cam, y) / 2 + (y >= 16 && y < 20 && x >= 20 && x < 44 ? 120 : 64)) : !strcmp(g_scn, "waves") && st == TITLE && y >= H / 2 ? noise(x + (int)atomic_load(&g_frames), y) : !strcmp(g_scn, "cut") && (st == TITLE || st == PAUSE) ? (uint8_t)(noise(x + cam, y) / (st == PAUSE ? 3 : 1)) : !strcmp(g_scn, "pausep") && st == PAUSE ? (uint8_t)(noise(x + cam, y) / 3 + (y >= 16 && y < 20 && x >= 20 && x < 44 ? 120 : 0)) : st == TITLE && !strcmp(g_scn, "lang") && atomic_load(&g_hl) && x >= 30 && x < 34 && y >= 8 + 6 * atomic_load(&g_hl) && y < 12 + 6 * atomic_load(&g_hl) ? 255 :
            st == TITLE && !strcmp(g_scn, "cstay") ? (x >= 4 * (atomic_load(&g_hl) % 14) && x < 4 * (atomic_load(&g_hl) % 14) + 4 && y >= 16 && y < 20 ? 255 : (y / 3) % 2 ? 200 : 40) :
            st == TITLE && !strcmp(g_scn, "daynight") && y < H / 2 ? (uint8_t)(atomic_load(&g_tvis) % 2 ? y * 8 : 255 - y * 8) :
            st == TITLE && !strcmp(g_scn, "pager") ? (x >= 8 + 10 * atomic_load(&g_hl) && x < 12 + 10 * atomic_load(&g_hl) && y >= 16 && y < 20 ? 255 : (y / 3) % 2 ? 200 : 40) :
            st == TITLE && !strcmp(g_scn, "pagetext") ? (x == 9 + 10 * atomic_load(&g_hl) && y >= 9 && y <= 27 ? 255 : 100) :
            st == TITLE && atomic_load(&g_hl) && strcmp(g_scn, "yesno") && x >= 30 && x < 34 && y >= 16 && y < 20 ? 255 : st == TITLE ? ((y / 3) % 2 ? 200 : 40) : st == MENU ? ((x / 4) % 2 ? 190 : 50) : noise(x + cam, y);
        uint8_t *q = p + (y * W + x) * 4; q[0] = q[1] = q[2] = v; q[3] = 255; }
    pthread_mutex_unlock(&g_fm); return W * H * 4;
}
// 帧录接口（真宿主在 graphics/nvn nvn_frame_rec.inc）：假宿主收到就把当前画面落成 <输出目录>/rec_<名>.bgra（64×36）
void nvn_frec_request(const char *name) {
    char p[1200]; snprintf(p, sizeof p, "%s/rec_%s.bgra", g_dir, name); static uint8_t buf[W * H * 4]; int32_t w, h;
    nxgal_screenshot(buf, sizeof buf, &w, &h); FILE *f = fopen(p, "wb"); if (f) { fwrite(buf, 1, sizeof buf, f); fclose(f); }
    s2a_ap_log("[游戏] 帧录 %s", name);
}
// 逐笔日志 / 截图接口（真宿主在 graphics/nvn nvn_mtl.m）：假宿主记一行、截图落成 <路径>（BGRA 原样）
void dm_gfx_passdump_next(long n) { s2a_ap_log("[游戏] 逐笔 下 %ld 帧", n); }
void dm_gfx_shot_at(long k, const char *path) {
    static uint8_t buf[W * H * 4]; int32_t w, h; nxgal_screenshot(buf, sizeof buf, &w, &h); FILE *f = fopen(path, "wb"); if (f) { fwrite(buf, 1, sizeof buf, f); fclose(f); }
    s2a_ap_log("[游戏] 截图 第 %ld 帧后 %s", k, path);
}
static void set_state(int st) {
    if (st == TITLE) atomic_fetch_add(&g_tvis, 1);
    atomic_store(&g_state, st); atomic_store(&g_state_f, atomic_load(&g_frames)); char p[1100], t[1100]; snprintf(p, sizeof p, "%s/state", g_dir); snprintf(t, sizeof t, "%s/state.tmp", g_dir);
    FILE *f = fopen(t, "w"); if (f) { fprintf(f, "%s\n", k_state[st]); fclose(f); rename(t, p); }
    s2a_ap_log("[游戏] 进 %s 帧 %llu", k_state[st], (unsigned long long)atomic_load(&g_frames));
}
// lang 场景：标题页子状态（g_hl：0 光标在显示语言、1 改选中、2 光标在语音语言、3 光标在确定）写进 state 给假驾驶员认
static void set_sub(int hl) {
    static const char *names[] = {"LANG", "EDIT", "ROW1", "OK"}; atomic_store(&g_hl, hl); char p[1100], t[1100];
    snprintf(p, sizeof p, "%s/state", g_dir); snprintf(t, sizeof t, "%s/state.tmp", g_dir);
    FILE *f = fopen(t, "w"); if (f) { fprintf(f, "%s\n", names[hl]); fclose(f); rename(t, p); }
    s2a_ap_log("[游戏] 语言页 → %s", names[hl]);
}
// focus 场景：焦点在「返回」（0）/「游玩」（1）写进 state 给假驾驶员认
static void set_focus(int hl) {
    atomic_store(&g_hl, hl); char p[1100], t[1100]; snprintf(p, sizeof p, "%s/state", g_dir); snprintf(t, sizeof t, "%s/state.tmp", g_dir);
    FILE *f = fopen(t, "w"); if (f) { fprintf(f, "FOCUS%d\n", hl); fclose(f); rename(t, p); }
    s2a_ap_log("[游戏] 准备游玩页焦点 → %s", hl ? "游玩" : "返回");
}
// yesno 场景：光标在「否」（0）/「是」（1）写进 state 给假驾驶员认；画面不画高亮
static void set_yes(int hl) {
    atomic_store(&g_hl, hl); char p[1100], t[1100]; snprintf(p, sizeof p, "%s/state", g_dir); snprintf(t, sizeof t, "%s/state.tmp", g_dir);
    FILE *f = fopen(t, "w"); if (f) { fprintf(f, "YES%d\n", hl); fclose(f); rename(t, p); }
    s2a_ap_log("[游戏] 读档确认光标 → %s", hl ? "是" : "否");
}
static void set_scroll(int hl) {   // scroll 场景：0 = 还没滚到底、1 = 滚到底
    atomic_store(&g_hl, hl); char p[1100], t[1100]; snprintf(p, sizeof p, "%s/state", g_dir); snprintf(t, sizeof t, "%s/state.tmp", g_dir);
    FILE *f = fopen(t, "w"); if (f) { fprintf(f, "SCROLL%d\n", hl); fclose(f); rename(t, p); }
    s2a_ap_log("[游戏] 统计同意页 → %s", hl ? "滚到底" : "没滚到底");
}
static _Atomic uint64_t g_game_f, g_game_a, g_game_k;   // g_game_k：局内按着任意键的帧数（回放没放成时局内段原地不动 → 只剩进局那下 A 的尾巴）
static _Atomic uint64_t g_pm_a, g_pm_oa;   // MARK 后局内 A 按着的帧 / 别的键按着而 A 松开的帧（S2A_AP_HOLD 用例按按键事件判，不随出帧快慢变）
// 同局 A/B（S2A_AP_SPEED=ab）：宿主 runtime/src/fps.c 的 s2a_fps_ab_set 替身——阶段 1 回原帧率 = 帧间隔从 S2A_TEST_FRAME_MS 翻倍（60 → 30 帧），2 / 0 = 原间隔
static _Atomic int g_ab_orig, g_ab_done;   // g_ab_done：同局 A/B 测完过一轮（abkick 开球后才动）
void s2a_fps_ab_set(int phase) { atomic_store(&g_ab_orig, phase == 1); if (!phase) atomic_store(&g_ab_done, 1); s2a_ap_log("[游戏] 同局 A/B：%s（帧 %llu）", phase == 1 ? "回原帧率（帧间隔翻倍）" : phase == 2 ? "放开 60 帧" : "测完照常", (unsigned long long)atomic_load(&g_frames)); }
static int g_lag_dropped;   // lag 场景：菜单页第一下 A 已被丢弃
static void *game(void *a) {
    (void)a; uint32_t prev = 0; const char *e = getenv("S2A_TEST_FRAME_MS"); double frame_us = e && atof(e) > 0 ? atof(e) * 1000 : 33333;
    const char *lf = getenv("S2A_TEST_LAG_FRAMES"); const long lag_frames = lf && atol(lf) > 0 ? atol(lf) : 45;
    // 按绝对时刻出帧：相对 usleep 每帧睡过头的调度延迟会累加，机器忙时 60 帧档只出到 29 帧、30 / 60 两局帧率拉不开，逻辑速度用例判不出
    //   （11-02 gate-host 负载 200+ 无缓存全套 ㉛㉞㉟ 红：出图 18.9 → 29.4 帧/秒）；迟了下一帧立刻出补回，落后超过 10 帧才从现在重新起算
    struct timespec ts0; clock_gettime(CLOCK_MONOTONIC, &ts0); double next_us = ts0.tv_sec * 1e6 + ts0.tv_nsec / 1e3;
    int locked = 0;   // 一帧的推进在 g_fm 里（下面的 continue 回到循环头解锁）
    while (!atomic_load(&g_done)) {
        if (locked) { pthread_mutex_unlock(&g_fm); locked = 0; }
        double fu = (atomic_load(&g_ab_orig) ? 2 * frame_us : frame_us) / g_ts; struct timespec tn; clock_gettime(CLOCK_MONOTONIC, &tn);
        double now_us = tn.tv_sec * 1e6 + tn.tv_nsec / 1e3; next_us += fu; if (now_us - next_us > 10 * fu) next_us = now_us;
        if (next_us > now_us) usleep((useconds_t)(next_us - now_us));
        pthread_mutex_lock(&g_fm); locked = 1; atomic_fetch_add(&g_frames, 1); atomic_fetch_add(&g_gns, (uint64_t)llround(fu * g_ts * 1000));
        uint32_t k = s2a_autoplay_keys(), down = k & ~prev; prev = k; int st = atomic_load(&g_state);
        if (st == GAME) { static uint64_t run; atomic_fetch_add(&g_game_f, 1); run = k & S2A_AP_A ? run + 1 : 0; if (run > atomic_load(&g_game_a)) atomic_store(&g_game_a, run); if (k) atomic_fetch_add(&g_game_k, 1);
                          if (atomic_load(&g_marked)) { if (k & S2A_AP_A) atomic_fetch_add(&g_pm_a, 1); else if (k) atomic_fetch_add(&g_pm_oa, 1); } }   // 局内最长连续按住 A 的帧数（S2A_AP_HOLD 用例）
        if (!strcmp(g_scn, "stuck")) continue;
        { int32_t xy[2]; uint32_t at; static int was; int now = s2a_autoplay_touch(xy, &at);   // 点触按触点起沿认
          if (now && !was && st == TITLE && !strcmp(g_scn, "navfail") && xy[0] >= 560 && xy[0] < 720 && xy[1] >= 300 && xy[1] < 420) set_state(MENU);
          if (now && !was && st == TITLE && !strcmp(g_scn, "tap2") && xy[0] >= 560 && xy[0] < 720 && xy[1] >= 300 && xy[1] < 420) {
              if (!atomic_load(&g_hl)) { atomic_store(&g_hl, 1); s2a_ap_log("[游戏] 点触选中"); } else { atomic_store(&g_hl, 0); set_state(MENU); } }
          was = now && !(at & 2); }
        int pp = !strcmp(g_scn, "pingpong"), fw = !strcmp(g_scn, "fwd") || !strcmp(g_scn, "daynight");
        if (st == TITLE && !strcmp(g_scn, "tap2")) continue;
        if (st == TITLE && !strcmp(g_scn, "navfail")) { if (down & S2A_AP_A) set_state(PAUSE); continue; }
        if (!strcmp(g_scn, "atog")) { if (st == TITLE && (down & S2A_AP_A)) set_state(MENU); else if (st == MENU && (down & S2A_AP_A)) set_state(TITLE); else if (st == MENU && (down & S2A_AP_X)) set_state(GAME);
            if (st != GAME) continue; }
        if (!strcmp(g_scn, "cut") && (st == TITLE || st == PAUSE)) { static int played;
            if (down & S2A_AP_PLUS) { set_state(st == TITLE ? PAUSE : TITLE); continue; }
            if (st == TITLE && ++played % 10 == 0) atomic_fetch_add(&g_cam, 7);
            // 过场播满 900 帧且自动玩家已经走过一次「这次不按、等」才进菜单（#383：原先只按帧数，机器忙时自动玩家问到第二次之前过场已播完，
            //   ⑲ 看不到等待那一步、偶发不通）；按事件同步，不按墙钟。自动玩家始终没走到那一步时 20 倍帧数兜底进菜单，⑲ 照实判不通、不卡死
            if ((played >= 900 && atomic_load(&g_cut_waited)) || played >= 900 * 20) set_state(MENU);
            continue; }
        if (st == TITLE && !strcmp(g_scn, "lang")) { int hl = atomic_load(&g_hl);
            if (hl == 0) { if (down & S2A_AP_A) set_sub(1); else if (down & S2A_AP_DOWN) set_sub(2); }
            else if (hl == 1) { if (down & S2A_AP_A) set_sub(0); }   // 改选里方向键都没反应
            else if (hl == 2) { if (down & S2A_AP_DOWN) set_sub(3); else if (down & S2A_AP_UP) set_sub(0); }
            else if (down & S2A_AP_A) { atomic_store(&g_hl, 0); set_state(MENU); }
            continue; }
        if (st == TITLE && !strcmp(g_scn, "scroll")) { int hl = atomic_load(&g_hl);
            if (!hl && (down & S2A_AP_RS_DOWN)) set_scroll(1); else if (hl && (down & S2A_AP_A)) { atomic_store(&g_hl, 0); set_state(MENU); }
            continue; }
        if (st == TITLE && !strcmp(g_scn, "focus")) { int hl = atomic_load(&g_hl);
            if (!hl && (down & S2A_AP_DOWN)) set_focus(1); else if (hl && (down & S2A_AP_UP)) set_focus(0); else if (hl && (down & S2A_AP_A)) { atomic_store(&g_hl, 0); set_state(MENU); }
            continue; }
        if (st == TITLE && !strcmp(g_scn, "yesno")) { int hl = atomic_load(&g_hl);
            if (down & (S2A_AP_UP | S2A_AP_DOWN | S2A_AP_LS_UP | S2A_AP_LS_DOWN)) set_yes(!hl); else if (hl && (down & S2A_AP_A)) { atomic_store(&g_hl, 0); set_state(MENU); }
            continue; }
        if (!strcmp(g_scn, "ring") && st != GAME) {
            if (st == TITLE) { if (down & S2A_AP_A) set_state(MENU); else if (down & S2A_AP_X) set_state(GAME); }
            else if (down & S2A_AP_A) set_state(TITLE);
            continue; }
        if (!strcmp(g_scn, "popback") && st != GAME) { int hl = atomic_load(&g_hl);
            // 回标题 30 帧且自动玩家已判完这次回头才弹第二个弹窗（原先只按帧数，机器忙时自动玩家按完 A 还没认页第二个弹窗已弹出，认成菜单页内来回、
            //   A 被拉黑，㊸ 菜单问答「A 无 无 …」）；按事件同步，不按墙钟。自动玩家始终没判到回头时 20 倍帧数兜底弹出，㊸ 照实判不通、不卡死
            uint64_t pf = atomic_load(&g_frames) - atomic_load(&g_state_f);
            if (st == TITLE && hl == 1 && ((pf >= 30 && atomic_load(&g_pb_judged)) || pf >= 30 * 20)) { atomic_store(&g_hl, 2); s2a_ap_log("[游戏] 又弹出一个同版式弹窗"); set_state(MENU); }
            else if (st == TITLE && !hl && (down & S2A_AP_A)) set_state(MENU);
            else if (st == MENU && (down & S2A_AP_A)) { if (hl == 0) { atomic_store(&g_hl, 1); set_state(TITLE); } else if (hl == 2) set_state(GAME); }
            continue; }
        if (st == TITLE && !strcmp(g_scn, "sideways")) { if ((k & S2A_AP_SL) == S2A_AP_SL && (k & S2A_AP_SR) == S2A_AP_SR) set_state(MENU); continue; }
        if (st == TITLE && !strcmp(g_scn, "agree")) { if (down & S2A_AP_PLUS) set_state(MENU); else if (down & S2A_AP_B) set_state(PAUSE); continue; }
        if (st == TITLE && !strcmp(g_scn, "cstay")) { if (down & S2A_AP_A) { atomic_fetch_add(&g_hl, 1); s2a_ap_log("[游戏] 角色创建页：A 挪亮块（第 %d 下）", atomic_load(&g_hl)); } else if (down & S2A_AP_X) set_state(MENU); continue; }
        if (st == TITLE && !strcmp(g_scn, "waves")) { if (down & S2A_AP_X) set_state(MENU); continue; }
        if (st == TITLE && (!strcmp(g_scn, "pager") || !strcmp(g_scn, "pagetext"))) { int hl = atomic_load(&g_hl);
            if ((down & S2A_AP_RIGHT) && hl < 4) { atomic_store(&g_hl, hl + 1); s2a_ap_log("[游戏] 协议翻到第 %d / 5 页", hl + 2); }
            else if ((down & S2A_AP_A) && hl == 4) { atomic_store(&g_hl, 0); set_state(MENU); }
            continue; }
        if (st == TITLE && !strcmp(g_scn, "stay")) { if (down & (S2A_AP_R | S2A_AP_A)) atomic_store(&g_hl, !atomic_load(&g_hl)); else if (down & S2A_AP_X) set_state(MENU); continue; }
        { static uint32_t prev2; uint32_t k2 = s2a_autoplay_keys2(), down2 = k2 & ~prev2; prev2 = k2;
          if (!strcmp(g_scn, "coop") && st == TITLE) {
              if ((down2 & S2A_AP_A) && s2a_autoplay_pads() >= 2 && !atomic_load(&g_hl)) { atomic_store(&g_hl, 1); s2a_ap_log("[游戏] 二号加入"); }
              else if ((down & S2A_AP_A) && atomic_load(&g_hl)) { atomic_store(&g_hl, 0); set_state(MENU); }
              continue; } }
        if (st == TITLE && (down & (!strcmp(g_scn, "titlex") ? S2A_AP_X : S2A_AP_A))) set_state(MENU);
        else if ((pp || fw) && st == MENU && (down & (fw ? (S2A_AP_B | S2A_AP_Y) : S2A_AP_B))) set_state(TITLE);
        // lag：菜单出现后 lag_frames 帧内不收键，且这页第一下 A 一定不收（11-01：原先只按帧窗口算，机器忙时自动玩家问完驾驶员才按，第一下已落在窗口外直接生效，
        //   「第一次没反应」那条路没走到、⑫ 假红；第二下要等够帧这一条由 lagslow 守）
        else if (st == MENU && !strcmp(g_scn, "lag") && (down & S2A_AP_A) && (!g_lag_dropped || atomic_load(&g_frames) < atomic_load(&g_state_f) + (uint64_t)lag_frames)) {
            if (!g_lag_dropped) { g_lag_dropped = 1; s2a_ap_log("[游戏] 菜单不收键：第一下 A（帧 %llu）", (unsigned long long)atomic_load(&g_frames)); }
            continue; }
        else if (st == MENU && (down & (pp || fw ? S2A_AP_X : S2A_AP_A))) set_state(GAME);
        else if (!strcmp(g_scn, "pausep") && (st == GAME || st == PAUSE) && (down & S2A_AP_PLUS)) set_state(st == GAME ? PAUSE : GAME);
        else if (!strcmp(g_scn, "pauseb") && ((st == GAME && (down & S2A_AP_PLUS)) || (st == PAUSE && (down & (S2A_AP_PLUS | S2A_AP_A))))) set_state(st == GAME ? PAUSE : GAME);
        // pflash：整屏纯色帧来回（仿 11-03 戦国無双5 / 弹丸论破 / 数码宝贝 / 大富翁11）：
        //   TITLE（整屏白，gstd≈0）→ PLUS → PAUSE（整屏黑，gstd≈0）→ PLUS → TITLE（白）…
        //   压暗判据：亮度 255→0、dncc=1.0（纯色退化），旧代码误判「+ 是开关」；新代码 gstd<4 过滤
        //   菜单 A → 局内；整屏纯色帧不能记开关
        else if (!strcmp(g_scn, "pflash") && st == TITLE && (down & S2A_AP_PLUS)) set_state(PAUSE);
        else if (!strcmp(g_scn, "pflash") && st == PAUSE && (down & S2A_AP_PLUS)) set_state(TITLE);
        else if (!strcmp(g_scn, "pflash") && st == TITLE && (down & S2A_AP_A)) { atomic_store(&g_hl, 0); set_state(MENU); }
        // pmenu：PLUS 在两张不同菜单页（亮度相近、gstd≥4）来回（仿 11-03 普查：某款菜单 A↔设置页）：
        //   TITLE（条纹菜单 g_hl=0） ↔ PLUS ↔ MENU（条纹菜单 g_hl=2，亮度相近），
        //   MENU(g_hl=2) 上 B/X 没反应（两个没变），PLUS 走回 TITLE = 旧代码通用开关识别触发；新代码要求压暗 + gstd 才记开关
        //   TITLE A → MENU(g_hl=0) → A → 局内
        else if (!strcmp(g_scn, "pmenu") && st == TITLE && (down & S2A_AP_A)) set_state(MENU);
        else if (!strcmp(g_scn, "pmenu") && st == MENU && atomic_load(&g_hl) == 2 && (down & S2A_AP_PLUS)) { atomic_store(&g_hl, 0); set_state(TITLE); }
        else if (!strcmp(g_scn, "pmenu") && st == TITLE && (down & S2A_AP_PLUS)) { atomic_store(&g_hl, 2); set_state(MENU); }
        else if (!strcmp(g_scn, "pmenu") && st == MENU && !(atomic_load(&g_hl) == 2) && (down & S2A_AP_A)) set_state(GAME);
        else if (st == GAME && !strcmp(g_scn, "anim")) atomic_fetch_add(&g_cam, 1);
        else if (st == GAME && !strcmp(g_scn, "abfix")) { static uint64_t n; if (++n % 2 == 0) atomic_fetch_add(&g_cam, 1); }   // 不按键世界自己动、按帧推进：每 2 帧移 1 像素
        else if (st == GAME && !strcmp(g_scn, "abkick")) { static uint64_t n; if (atomic_load(&g_ab_done) && ++n % 2 == 0) atomic_fetch_add(&g_cam, 1); }   // 摇杆同 abfix 不动镜头   // 开球前静止（足球小将 MARK 落在开球等待页），第一轮 A/B 测完后同 abfix
        else if (st == GAME && !strcmp(g_scn, "abrt")) {   // 不按键世界自己动、按真实时间推进：每秒 15 像素（与帧间隔无关）
            static double acc; acc += (atomic_load(&g_ab_orig) ? 2 * frame_us : frame_us) / 1e6 * 15; atomic_store(&g_cam, (int)lround(acc)); }
        else if (st == GAME && !strcmp(g_scn, "abmix")) {   // 走路按真实时间（左摇杆每秒 30 像素）、镜头按帧（右摇杆每帧 1 像素）：同局 A/B 走路绿、镜头红，合起来红
            static double acc; double step = (atomic_load(&g_ab_orig) ? 2 * frame_us : frame_us) / 33333.0;
            if (k & S2A_AP_LS_RIGHT) acc += step; if (k & S2A_AP_LS_LEFT) acc -= step; if (k & S2A_AP_RS_RIGHT) acc += 1; if (k & S2A_AP_RS_LEFT) acc -= 1;
            atomic_store(&g_cam, (int)lround(acc)); }
        else if (st == GAME && !strcmp(g_scn, "speedmenu") && !atomic_load(&g_hl)) { if (down & S2A_AP_B) atomic_store(&g_hl, 1); }   // 局内先停在菜单：摇杆不动镜头，B 退出后同 ok
        else if (st == GAME && !strcmp(g_scn, "speedmenu")) { if (k & (S2A_AP_LS_RIGHT | S2A_AP_RS_RIGHT)) atomic_fetch_add(&g_cam, 1); if (k & (S2A_AP_LS_LEFT | S2A_AP_RS_LEFT)) atomic_fetch_sub(&g_cam, 1); }
        else if (st == GAME && !strcmp(g_scn, "speeda")) {   // 按真实时间推进（A 类）：镜头每秒移 30 像素，不论帧间隔；ok 场景是按帧推进（B 类，每帧 1 像素）
            static double acc; double step = (atomic_load(&g_ab_orig) ? 2 * frame_us : frame_us) / 33333.0;
            if (k & (S2A_AP_LS_RIGHT | S2A_AP_RS_RIGHT)) acc += step; if (k & (S2A_AP_LS_LEFT | S2A_AP_RS_LEFT)) acc -= step;
            atomic_store(&g_cam, (int)lround(acc)); }
        else if (st == GAME) { if (k & (S2A_AP_LS_RIGHT | S2A_AP_RS_RIGHT)) atomic_fetch_add(&g_cam, 1); if (k & (S2A_AP_LS_LEFT | S2A_AP_RS_LEFT)) atomic_fetch_sub(&g_cam, 1); }
    }
    if (locked) pthread_mutex_unlock(&g_fm);
    return NULL;
}
const char *sp_verdict(double foff, double q, double rho, double moff, const char **why);   // autoplay.c 同局 A/B 判一项
const char *sp_ab_decide(double m[3][3], double f[3][3], int ok[3][3], const int use[3], int *kk, double rho[3], double q[3], double mon[3], double fon[3], const char *vk[3], const char *why[3]);   // autoplay.c 同局 A/B 合并（项：0 不按键、1 走、2 转镜头）
int main(int argc, char **argv) {
    if (argc < 3) { fprintf(stderr, "用法：t_autoplay <输出目录> <场景>\n"); return 2; }
    if (!strcmp(argv[2], "pixmove")) { void s2a_ap_pix_selftest(void); s2a_ap_pix_selftest(); return 0; }   // 逐像素判据纯函数（不起游戏）：期望在 autoplay_test.sh 手写
    if (!strcmp(argv[2], "stseen")) { void s2a_ap_stseen_selftest(void); s2a_ap_stseen_selftest(); return 0; }   // 页内状态逐像素第三道纯函数（不起游戏）：期望在 autoplay_test.sh 手写
    if (!strcmp(argv[2], "verdict")) {   // 判据纯函数（不起游戏）：每行「关段帧率 q ρ 关段速度 → 结论 说明」，期望在 autoplay_test.sh 手写
        static const double c[][4] = {{60, 1.0, 1.0, 30}, {30, 1.05, 1.6, 30}, {30, 2.0, 1.0, 0.5}, {30, 2.0, 0.5, 30}, {30, 2.0, 1.2, 30}, {30, 2.0, 1.4, 30},
                                      {30, 1.5, 1.2, 30}, {30, 1.5, 1.3, 30}, {30, 2.0, 2.0, 30}, {30, 2.0, 3.0, 30}, {30, 2.0, 3.01, 30}, {30, 2.0, 4.17, 17.8}};
        for (size_t i = 0; i < sizeof c / sizeof c[0]; i++) { const char *w = ""; const char *v = sp_verdict(c[i][0], c[i][1], c[i][2], c[i][3], &w); printf("%zu %s %s\n", i, v, w); }
        return 0; }
    if (!strcmp(argv[2], "abdecide")) {   // 同局 A/B 合并纯函数，喂 11-23 两款真实读数（[段 关 / 开① / 开②][项 不按键 / 走 / 转镜头]），期望在 autoplay_test.sh 手写
        static const double D[2][2][3][3] = {   // [款][0 速度 / 1 帧率][段][项]
            {{{0, 52.5, 80.9}, {0, 112.8, 121.4}, {0, 116.1, 87.5}}, {{0, 30, 30}, {0, 60, 60}, {0, 60, 33}}},   // 0：01007EF00011E000（开②转镜头只有 33 帧）
            {{{0, 17.8, 124.9}, {0, 84.3, 113.8}, {0, 64.1, 108.9}}, {{0, 30, 30}, {0, 60, 60}, {0, 60, 60}}}};  // 1：0100F2C0115B6000（攀爬中量「走」）
        for (int g = 0; g < 2; g++) {
            double m[3][3], f[3][3], rho[3], q[3], mon[3], fon[3]; int ok[3][3], use[3] = {0, 1, 1}, k; const char *vk[3], *why[3];
            for (int p = 0; p < 3; p++) for (int j = 0; j < 3; j++) { m[p][j] = D[g][0][p][j]; f[p][j] = D[g][1][p][j]; ok[p][j] = j > 0; }
            const char *v = sp_ab_decide(m, f, ok, use, &k, rho, q, mon, fon, vk, why);
            printf("%d %s 定于项%d｜走 %s ρ %.2f q %.2f｜转 %s ρ %.2f q %.2f\n", g, v, k, vk[1], rho[1], q[1], vk[2], rho[2], q[2]);
        }
        return 0; }
    snprintf(g_dir, sizeof g_dir, "%s", argv[1]); g_scn = argv[2];
    char p[1100]; snprintf(p, sizeof p, "%s/host.log", g_dir); g_log = fopen(p, "w"); if (!g_log) return 2;
    setenv("S2A_AUTOPLAY_OUT", g_dir, 1); snprintf(p, sizeof p, "%s/state", g_dir); setenv("S2A_T_STATE", p, 1);
    const char *ts = getenv("S2A_AP_TIMESCALE"); if (ts && atof(ts) > 0) g_ts = atof(ts);
    set_state(TITLE); if (!strcmp(g_scn, "lang")) set_sub(0); if (!strcmp(g_scn, "focus")) set_focus(0); if (!strcmp(g_scn, "scroll")) set_scroll(0); if (!strcmp(g_scn, "yesno")) set_yes(0);
    pthread_t th; pthread_create(&th, NULL, game, NULL);
    while (atomic_load(&g_frames) < 1) usleep(1000);
    if (!s2a_autoplay_on()) {   // 自动玩家没开：设了实时通道就只跑通道（S2A_T_LIVE_S 秒后收），否则收
        const char *ls = getenv("S2A_T_LIVE_S"); if (!getenv("S2A_AP_LIVE") || !ls) { s2a_ap_log("自动玩家没开"); return 1; }
        usleep((useconds_t)(atof(ls) * 1e6)); s2a_ap_log("[游戏] 只开实时通道：%s 秒到", ls); return 0; }
    while (!atomic_load(&g_done)) usleep(20000);
    pthread_join(th, NULL);
    { char m[96]; snprintf(m, sizeof m, "[游戏] 局内 %llu 帧，A 最长连按 %llu 帧", (unsigned long long)atomic_load(&g_game_f), (unsigned long long)atomic_load(&g_game_a)); s2a_ap_log("%s", m); s2a_ap_log("[游戏] 局内有键 %llu 帧", (unsigned long long)atomic_load(&g_game_k));
      s2a_ap_log("[游戏] MARK 后局内 A 按着 %llu 帧，别的键按着而 A 松开 %llu 帧", (unsigned long long)atomic_load(&g_pm_a), (unsigned long long)atomic_load(&g_pm_oa)); }
    return 0;
}
