// 无人值守局（自动化 / 开发工具起的局）：执行器（tools/dev_run.sh 等）起局一律带 S2A_AUTOPLAY=1，玩家从主屏点开不带任何环境变量。
//   这类局里给玩家的问询界面（直连安全网提示页、「把上次的诊断发给我们？」、本地网络说明）不弹：日志本来由工具拉回，弹了只会挡住整局。
//   同一条规则只在这里一份：runtime/src/dguard.c、runtime/src/host_main.c、ios/diag.m、ios/lan_permission.m 都调它
#pragma once
#include <stdlib.h>
#include <string.h>
// S2A_UNATTENDED=1：自动玩家关着、由工具按实时通道（S2A_AP_LIVE）逐键驱动的局也是无人值守（11-12：手推按键进场景，真机上点不掉「把上次的诊断发给我们？」）
static inline int s2a_unattended(void) {
    const char *u = getenv("S2A_UNATTENDED"); if (u && !strcmp(u, "1")) return 1;
    const char *a = getenv("S2A_AUTOPLAY");
    return a && *a && strcmp(a, "0") != 0;
}
