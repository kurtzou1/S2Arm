// 包内能力清单（10-28 全能力出包）：读 <模块目录>/s2a_caps.tsv，未设对应环境变量时设上。
// 随包表：s2a_caps.tsv（出包组装 pack/ship_ext.py 从产物根拷进 App，runtime/build.mk 按这行自动收清单）
#include "caps.h"
#include "patch.h"
#include "native.h"
#include <stdio.h>
#include <string.h>
#include <stdlib.h>

// 清单里 fps60 / fps60_display 的值（-1 = 没读到）：只记下来，读的时候判（审计 P1-80：原先 fps60_display 写 DM_PRESENT_INTERVAL=display 进进程环境，
//   图形层见到这个变量就不再套 60 帧开关，设置里关 60 帧再进程内重启仍每个显示节拍出一帧；环境变量只留给启动时显式指定的人）
static int g_caps_fps60 = -1, g_caps_fps60_display;
// 本局要不要放开出图间隔的「来源」（不含开关；开关由 s2a_present_fps60_gate 按当局 S2A_FPS60 套）：清单 fps60_display 1（引擎通用全引擎档：没有帧率表 / 社区补丁 / Unity·UE 推导的款），
//   或清单 fps60 0、玩家在设置页手动开了（ios/settings.m 写 S2A_FPS60=1，清单那行因此没改环境）
// 11-11 维护者：出包默认原帧率、60 帧玩家手动开——清单里的 fps60 1 / fps60_display 1（含全引擎档）不再替玩家开 60 帧；
//   本局 60 帧开着（S2A_FPS60=1）时放开出图间隔的来源：清单 fps60_display 1（全引擎档 / 逻辑速度同局 A/B 绿：A/B 就是放开着测的），
//   或这款不是「速度已验证正确、默认开」的款（玩家手动开：配带速度修正的补丁才对，玩家自选）。
//   已验证款里的 fps.tsv（帧率表自己带 present display 行，fps.c 起局设）与游戏原生 60 帧（交换间隔本就不需要放开，caps_policy native60「跟随游戏」）
//   不由清单放开：宿主替它们写的 S2A_FPS60=1 不等于玩家开了，原先放开来源只认玩家开，不能因为默认开就把原生 60 帧的款也改成每个显示节拍一帧
int s2a_fps60_display_source(void) {
    const char *e = getenv("S2A_FPS60");
    return e && !strcmp(e, "1") && (g_caps_fps60_display || g_caps_fps60 != 1);
}

static char g_pkeys[16][32]; static int g_npkeys;
// 本清单自己写进进程环境的变量（名字 + 值）：进程内重启（设置页「立刻重启」，ios/settings.m s2a_ios_reload_graphics_settings）先撤掉、再按「设置 → 清单」重放。
//   审计 P1-80：原先重读只撤设置页自己登记的名字，清单写的 S2A_FPS60=1 留在进程里，玩家在设置里关 60 帧、立刻重启后设置那条「未设才写」写不进，新局照样 60
static struct { const char *name; char val[16]; } g_caps_env[4]; static int g_ncaps_env;
static void caps_setenv(const char *name, const char *v) {
    if (getenv(name) || setenv(name, v, 0)) return;
    if (g_ncaps_env < 4) { g_caps_env[g_ncaps_env].name = name; snprintf(g_caps_env[g_ncaps_env].val, sizeof g_caps_env[0].val, "%s", v); g_ncaps_env++; }
}
void s2a_caps_reset(void) {
    for (int i = 0; i < g_ncaps_env; i++) {   // 只撤值还是自己写的那份：别处（启动环境 / 调度 A/B / 别的模块）改写过的不动
        const char *cur = getenv(g_caps_env[i].name);
        if (cur && !strcmp(cur, g_caps_env[i].val)) unsetenv(g_caps_env[i].name);
    }
    g_ncaps_env = 0; g_caps_fps60 = -1; g_caps_fps60_display = 0; g_npkeys = 0;
}

int s2a_caps_fps60_verified(const char *val, const char *why) {
    return val && val[0] == '1' && why && (strstr(why, "fps.tsv") || strstr(why, "逻辑速度同局 A/B 绿") || strstr(why, "游戏原生 60 帧") || strstr(why, "社区帧率补丁"));
}

// 一行能力：src = "能力清单" / "补丁" / "补丁例外"
static void apply_cap(const char *cap, const char *v, const char *why, const char *src) {
        // 值：1 = 开、0 = 显式关（发布包：fps60 / 满屏缺省开，强信号才写 0，pack/gen_caps.sh → tools/caps_policy.py）；别的值不认、跳过。已设的环境变量优先、不覆盖：
        //   启动环境（调度 A/B）与用户设置（ios/settings.m 先于本函数写）都压过清单（审计 #854 F-caps-beats-settings：清单先写，设置里关 60 帧 / 宽屏不生效）
        // widen → S2A_WIDEN_CAPS（1 = 满屏开、不看 verified.tsv 名单；0 = 按 16:9），排在用户宽屏设置之后（widen.c widen_verified）；
        //   不借判定局专用的 S2A_WIDEN_VERIFIED（它压过设置，审计 #854）
        if (!strcmp(cap, "widen") && !getenv("S2A_WIDEN_CAPS")) {
            caps_setenv("S2A_WIDEN_CAPS", v);
            LOG("%s：满屏%s（S2A_WIDEN_CAPS=%s）原因：%s", src, v[0] == '1' ? "开" : "关", v, why);
        }
        // fps60 → S2A_FPS60（1 = 开；0 = 关，回原帧率，见 fps.c fps_on_at_start）
        else if (!strcmp(cap, "fps60")) {
            // 11-11 维护者：出包默认游戏原本的帧率、60 帧玩家手动开；例外是速度已验证正确的款保留默认 60：清单原因来自我方帧率表（fps.tsv，正确帧步）、
            //   普查同局 A/B 逻辑速度绿、或游戏原生 60 帧（放开出图间隔不会变快）。老包的清单原因里就写着来源，所以新壳认得出、不用重出包。
            //   全引擎档 / Unity·UE 推导不算：清单写 1 也不替玩家开。
            //   社区帧率补丁算（11-13 维护者「版本精确命中的默认打上」）：补丁要逐字节核对上这个构建的原字节才编得进包，进了包就是精确命中，自带速度修正
            int verified = s2a_caps_fps60_verified(v, why);
            g_caps_fps60 = verified;
            if (verified && !getenv("S2A_FPS60")) caps_setenv("S2A_FPS60", "1");
            const char *e = getenv("S2A_FPS60"); int on = e && !strcmp(e, "1");
            LOG("%s：60 帧清单值 %s（原因：%s）——%s，本局 60 帧%s", src, v, why, verified ? "速度已验证正确，默认开" : "不替玩家开",
                on ? (verified ? "开" : "开（玩家开了）") : "关（游戏原本帧率）");
            // 普查同局 A/B 模式（S2A_FPS_AB=1，tools/census 设）：60 帧没开的款也要能在自动玩家测开段时放开出图间隔——设 DM_PRESENT_INTERVAL=display，
            //   平时由 fps.c 降档原因 3 退回游戏间隔（整局仍是原帧率），只在 A/B 开段（s2a_fps_ab_set 2）放开。60 帧开着的款不动（照包里的来源走）
            const char *ab = getenv("S2A_FPS_AB");
            if (ab && !strcmp(ab, "1") && !getenv("DM_PRESENT_INTERVAL")) { caps_setenv("DM_PRESENT_INTERVAL", "display"); LOG("%s：普查同局 A/B 模式，60 帧没开的款放开出图间隔待测（平时仍按原帧率，见 fps.c 降档原因 3）", src); }
        }
        // fps60_display 1（引擎通用全引擎档，pack/gen_caps.sh）：只记下来，图形层每局按 60 帧开关读时判（s2a_fps60_display_source + game_profile.h）
        else if (!strcmp(cap, "fps60_display")) {
            g_caps_fps60_display = v[0] == '1';   // 只记下：60 帧开着时才算放开来源（s2a_fps60_display_source）
            if (g_caps_fps60_display) LOG("%s：清单写了放开出图间隔（原因：%s）——60 帧开着时放开", src, why);
        }
        // gyro / haptics / direct：Settings.bundle 已缺省开，无需环境变量
        // （direct 由出包期 S2A_DUAL 决定，手柄 / 马达 / 陀螺仪 / 快捷菜单代码内置）
}
// 补丁（runtime/src/patch.c）提到的键：包内清单同键那行不再生效（补丁整键取补丁值，设计稿 12.7）
static int patch_has(const char *cap) { for (int i = 0; i < g_npkeys; i++) if (!strcmp(g_pkeys[i], cap)) return 1; return 0; }
static void patch_cap(const char *cap, const char *val, const char *why, int except) {
    if (patch_has(cap)) return;   // [except] 先到：同键 [caps] 不能压过强信号
    if (g_npkeys < 16) snprintf(g_pkeys[g_npkeys++], sizeof g_pkeys[0], "%s", cap);
    apply_cap(cap, val, why, except ? "补丁例外" : "补丁");
}

void s2a_caps_apply(const char *dir) {
    if (!dir || !dir[0]) return;
    g_npkeys = 0;
    if (s2a_patch_open(dir)) s2a_patch_caps_each(patch_cap);   // 补丁先于包内清单：玩家设置 / 启动环境（已写）> [except] > 补丁 [caps] > 包内清单
    char path[1100]; snprintf(path, sizeof path, "%s/s2a_caps.tsv", dir);
    FILE *f = fopen(path, "r");
    if (!f) return;   // 文件不存在：正常（不带 --all-caps 的包）

    char line[256];
    while (fgets(line, sizeof line, f)) {
        char *h = strchr(line, '#'), why[160] = "";
        if (h) { *h = 0; snprintf(why, sizeof why, "%s", h + 1 + (h[1] == ' ')); why[strcspn(why, "\r\n")] = 0; }   // 去注释；注释是原因（gen_caps：来源 / 强信号），打进日志供普查记表
        char cap[64], val[64];
        if (sscanf(line, "%63s %63s", cap, val) != 2) continue;
        if (strcmp(val, "1") && strcmp(val, "0")) continue;
        if (patch_has(cap)) { LOG("能力清单：%s 由补丁定，包内这行（%s）不用", cap, val); continue; }
        apply_cap(cap, val[0] == '1' ? "1" : "0", why, "能力清单");
    }
    fclose(f);
}
