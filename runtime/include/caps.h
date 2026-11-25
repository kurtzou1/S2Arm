// 包内能力清单（10-28 全能力出包）：--all-caps 出的包带 App.app/s2a_caps.tsv，宿主读它并设环境变量（未设时），效果等同调度器强开。
// 行格式：<能力>\t<值>（# 起注释）。能力：widen（宽屏）、fps60（60 帧）、gyro（陀螺仪）、haptics（马达）、direct（直连）。
// 值：1 = 开，0 = 关（能力不可用时写 0 + 原因）。优先级：启动环境变量（调度器 A/B）> Settings.bundle（用户手动改过的设置）> 本清单 > 宿主缺省
//   （审计 #854 F-caps-beats-settings：设置要先于清单写，否则设置里关 60 帧 / 宽屏不生效）。
#ifndef S2A_CAPS_H
#define S2A_CAPS_H
#include <stdlib.h>

// 读取并应用包内能力清单：iOS 起局时（s2a_ios_load_graphics_settings 里）调一次，dir 传 App 包路径；Mac 宿主装载前按模块目录（产物根）调，安卓按模块目录调。
// 路径：<dir>/s2a_caps.tsv；读不到不报错（不带 --all-caps 的包没有这个文件）。目录由调用方给：起局时模块还没装载，
//   s2a_module_dir() 此刻是空串（10-28 首版按它取目录，iOS 上清单从不生效）。
// widen / fps60 未设对应环境变量就设（widen → S2A_WIDEN_CAPS、fps60 → S2A_FPS60）；调用方先套用户设置再调本函数。
void s2a_caps_apply(const char *dir);
// 进程内重启前调（ios/settings.m s2a_ios_reload_graphics_settings）：撤掉本清单写进进程环境、值没被别处改过的变量，清掉读到的清单值；之后调用方按「设置 → 清单」重放（审计 P1-80）
void s2a_caps_reset(void);
// 本局放开出图间隔的来源（S2A_FPS60=1 且：清单 fps60_display 1，或这款不是速度已验证默认开的款）；开关不在这里套（graphics/nvn/host/game_profile.h DM_GAME_PRESENT_DISPLAY）
int s2a_fps60_display_source(void);
static inline int s2a_caps_own(void) { const char *e = getenv("S2A_CAPS_OWN"); return e && e[0] == '1' && !e[1]; }   // S2A_CAPS_OWN=1：我方 60 帧那一层（帧率表 / 全引擎放开）照旧用，只给内部对照；缺省 0 = 只用社区补丁
// 清单 fps60 行算不算「速度已验证正确、默认开」：值 1 且原因含「游戏原生 60 帧」，或同时含「社区帧率补丁」与「逻辑速度同局 A/B 绿」（11-23 #2120）；
//   旧口径（S2A_CAPS_OWN=1）另认「fps.tsv」「逻辑速度同局 A/B 绿」。宿主（caps.c）与 iOS 设置页缺省显示值共用这一份规则；
//   Mac 启动器（pack/jobs/community.py fps60_default）照抄同一条规则，改要两边同步
int s2a_caps_fps60_verified(const char *val, const char *why);
// 清单 fps60 原因含「逻辑速度同局 A/B 红」= 本构建号开 60 帧游戏会加速（tools/caps_policy.py patch_ab，11-24 #2201）；s2a_caps_fps_fast 是本局读到的那行的结论。
//   档位梯子压回时（ios/app.m、macos/front_mac.m s2a_ios_fps_capped）据此不给「再试 60 帧」：点了游戏就加速，是给玩家一个坏选项
int s2a_caps_fps60_speeds_up(const char *why);
int s2a_caps_fps_fast(void);

#endif
