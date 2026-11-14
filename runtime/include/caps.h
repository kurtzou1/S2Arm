// 包内能力清单（10-28 全能力出包）：--all-caps 出的包带 App.app/s2a_caps.tsv，宿主读它并设环境变量（未设时），效果等同调度器强开。
// 行格式：<能力>\t<值>（# 起注释）。能力：widen（宽屏）、fps60（60 帧）、gyro（陀螺仪）、haptics（马达）、direct（直连）。
// 值：1 = 开，0 = 关（能力不可用时写 0 + 原因）。优先级：启动环境变量（调度器 A/B）> Settings.bundle（用户手动改过的设置）> 本清单 > 宿主缺省
//   （审计 #854 F-caps-beats-settings：设置要先于清单写，否则设置里关 60 帧 / 宽屏不生效）。
#ifndef S2A_CAPS_H
#define S2A_CAPS_H

// 读取并应用包内能力清单：iOS 起局时（s2a_ios_load_graphics_settings 里）调一次，dir 传 App 包路径；Mac 宿主装载前按模块目录（产物根）调，安卓按模块目录调。
// 路径：<dir>/s2a_caps.tsv；读不到不报错（不带 --all-caps 的包没有这个文件）。目录由调用方给：起局时模块还没装载，
//   s2a_module_dir() 此刻是空串（10-28 首版按它取目录，iOS 上清单从不生效）。
// widen / fps60 未设对应环境变量就设（widen → S2A_WIDEN_CAPS、fps60 → S2A_FPS60）；调用方先套用户设置再调本函数。
void s2a_caps_apply(const char *dir);
// 进程内重启前调（ios/settings.m s2a_ios_reload_graphics_settings）：撤掉本清单写进进程环境、值没被别处改过的变量，清掉读到的清单值；之后调用方按「设置 → 清单」重放（审计 P1-80）
void s2a_caps_reset(void);
// 本局放开出图间隔的来源（S2A_FPS60=1 且：清单 fps60_display 1，或这款不是速度已验证默认开的款）；开关不在这里套（graphics/nvn/host/game_profile.h DM_GAME_PRESENT_DISPLAY）
int s2a_fps60_display_source(void);
// 清单 fps60 行算不算「速度已验证正确、默认开」（11-11；11-13 加社区帧率补丁：版本精确命中才进得了包）：值 1 且原因含「fps.tsv」「逻辑速度同局 A/B 绿」「社区帧率补丁」「游戏原生 60 帧」之一。
//   宿主（caps.c）与 iOS 设置页缺省显示值共用这一份规则；Mac 启动器（pack/jobs/community.py）照抄同三个字样，改字样要两边同步（现四个字样）
int s2a_caps_fps60_verified(const char *val, const char *why);

#endif
