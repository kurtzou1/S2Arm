// 开发机 Mac 局串行锁（11-19 维护者：同一台开发机上几条线同时起 Mac 游戏局，本机负载到 90，量数作废、门禁被拖慢；
//   约定「起局前取量数锁」靠各调用方自觉守不住）。宿主自己在起局前取锁：哪个入口起的 s2arm-host 都一样，拿不到就排队。
//   只在开发机上生效：$HOME/.s2arm/mac_game_lock 存在才取，文件第一行 = 锁文件路径；玩家机器没有这个文件，行为不变。
//   门禁各槽的 HOME 是单独目录（没有这个文件），不受影响。外层已持锁（量数脚本等）设 S2A_MAC_GAME_LOCK_HELD=1 跳过。
//   锁 = flock(2) 独占，持到进程退出（含被杀）由内核放；描述符带 close-on-exec，宿主起的子进程不继承。
#pragma once
#include <fcntl.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/file.h>
#include <time.h>
#include <unistd.h>

// → 0 没配置 / 外层已持 / 工具模式（没取）；1 当场拿到；2 排队后拿到；-1 配置了但锁文件打不开（照常起局，打一行说明）
static inline int s2a_dev_serial_lock(void) {
    if (getenv("S2A_MAC_GAME_LOCK_HELD")) return 0;
    // 宿主工具模式（出包期借游戏自带的代码办事，不起图形、不进游戏）不是 Mac 局，不取：runtime/src/oodle_tool.c DM_OODLE_JOB / DM_OODLE_SERVE（解压）、
    //   runtime/src/glslc_tool.c DM_GLSLC_JOB（离线编 GLSL）。管线归档 / 帧回放真跑渲染、吃 GPU，照旧排队
    //   出包抽取时 nxsh_extract 主进程与各工作进程、shader_split 各起一个工具宿主同时跑，第一个拿锁后在 stdin 上等请求，其余在 flock 上等它 → 互相等死
    //   （0.6.2 候选验收无人深空出 iPhone 包停在「直连抽取 1/81」24 分钟，样本：9 个 s2arm-host 都在 main → flock，持锁那个在 s2a_oodle_tool_maybe → read）
    if (getenv("DM_OODLE_JOB") || getenv("DM_OODLE_SERVE") || getenv("DM_GLSLC_JOB")) return 0;
    const char *home = getenv("HOME");
    if (!home || !*home) return 0;
    char cfg[1024], path[1024] = {0};
    snprintf(cfg, sizeof cfg, "%s/.s2arm/mac_game_lock", home);
    FILE *f = fopen(cfg, "r");
    if (!f) return 0;
    if (!fgets(path, sizeof path, f)) path[0] = 0;
    fclose(f);
    path[strcspn(path, "\r\n")] = 0;
    if (!path[0]) return 0;
    int fd = open(path, O_RDWR | O_CREAT | O_CLOEXEC, 0644);
    if (fd < 0) {
        fprintf(stderr, "[s2a] Mac 局串行锁 %s 打不开，照常起局（不排队）\n", path);
        return -1;
    }
    if (flock(fd, LOCK_EX | LOCK_NB) == 0) return 1;
    time_t t0 = time(NULL);
    fprintf(stderr, "[s2a] 本机已有 Mac 游戏局在跑：排队等 Mac 局串行锁（%s）\n", path);
    while (flock(fd, LOCK_EX) != 0) {}
    fprintf(stderr, "[s2a] 拿到 Mac 局串行锁，等了 %ld 秒\n", (long)(time(NULL) - t0));
    return 2;   // fd 故意不关：持锁到进程退出
}
