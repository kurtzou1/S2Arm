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
#include <sys/stat.h>
#include <time.h>
#include <unistd.h>
#ifdef __APPLE__
#include <sys/sysctl.h>
#endif

// 持锁进程卡在退出中（11-23：D-WZCF 复现局 pid 21815 GPU 挂死后停在退出路径（ps 状态 ?E），kill -9 无效、内核不放 flock，
//   各线 Mac 局排队 48 分钟超墙钟被杀）：拿锁方排队时看持锁进程（拿锁后写进「<锁>.holder」），连续 S2A_MAC_LOCK_EXIT_STUCK_S 秒（缺省 300）
//   都在退出中 → 把锁轮换成新文件（旧文件改名「<锁>.stuck-<pid>」留证），配置文件第二行给了报警文件就追加一行报警。
//   正常跑着的长局（不在退出中）不轮换：只认「退出中」这一种状态，等多久都照排。单测按宏 S2A_DSL_EXITING 注入状态
static inline int s2a_dsl_exiting(pid_t pid) {   // 进程在退出路径上（P_WEXIT，ps 的 E）→ 1；不在 / 查不到 / 非苹果 → 0
#ifdef __APPLE__
    struct kinfo_proc kp; size_t n = sizeof kp; int mib[4] = {CTL_KERN, KERN_PROC, KERN_PROC_PID, (int)pid};
    memset(&kp, 0, sizeof kp);
    if (sysctl(mib, 4, &kp, &n, NULL, 0) != 0 || n == 0) return 0;
    return (kp.kp_proc.p_flag & P_WEXIT) != 0;
#else
    (void)pid; return 0;
#endif
}
#ifndef S2A_DSL_EXITING
#define S2A_DSL_EXITING(pid) s2a_dsl_exiting(pid)
#endif

static inline pid_t s2a_dsl_holder(const char *path) {
    char hp[1100]; snprintf(hp, sizeof hp, "%s.holder", path);
    FILE *f = fopen(hp, "r"); long v = 0;
    if (f) { if (fscanf(f, "%ld", &v) != 1) v = 0; fclose(f); }
    return (pid_t)v;
}

static inline void s2a_dsl_mark_holder(const char *path) {
    char hp[1100]; snprintf(hp, sizeof hp, "%s.holder", path);
    FILE *f = fopen(hp, "w");
    if (f) { fprintf(f, "%ld\n", (long)getpid()); fclose(f); }
}

// 锁轮换：路径还指着我手里这个文件（同一 inode）才改名，别的排队者先轮换过了就不动；→ 1 轮换了 / 0 没动
static inline int s2a_dsl_rotate(int fd, const char *path, pid_t holder, long secs, const char *alarm) {
    struct stat a, b;
    if (fstat(fd, &a) != 0 || stat(path, &b) != 0 || a.st_ino != b.st_ino || a.st_dev != b.st_dev) return 0;
    char old[1100]; snprintf(old, sizeof old, "%s.stuck-%ld", path, (long)holder);
    if (rename(path, old) != 0) return 0;
    fprintf(stderr, "[s2a] 【红】Mac 局串行锁：持锁 pid %ld 卡在退出中 %ld 秒（GPU 挂死多见，kill -9 无效、只有重启能清），锁已轮换为新文件，旧锁留在 %s\n",
            (long)holder, secs, old);
    if (alarm && *alarm) {
        FILE *f = fopen(alarm, "a");
        if (f) {
            char ts[32]; time_t t = time(NULL); strftime(ts, sizeof ts, "%m-%d %H:%M:%S", localtime(&t));
            fprintf(f, "%s 🔴 Mac 局串行锁：持锁 pid %ld 卡在退出中 %ld 秒（GPU 挂死卡退出），锁已自动轮换，旧锁 %s；该进程只有重启能清\n", ts, (long)holder, secs, old);
            fclose(f);
        }
    }
    return 1;
}

// → 0 没配置 / 外层已持 / 工具模式（没取）；1 当场拿到；2 排队后拿到；3 持锁进程卡在退出中、轮换锁后拿到；-1 配置了但锁文件打不开（照常起局，打一行说明）
static inline int s2a_dev_serial_lock(void) {
    if (getenv("S2A_MAC_GAME_LOCK_HELD")) return 0;
    // 宿主工具模式（出包期借游戏自带的代码办事，不起图形、不进游戏）不是 Mac 局，不取：runtime/src/oodle_tool.c DM_OODLE_JOB / DM_OODLE_SERVE（解压）、
    //   runtime/src/glslc_tool.c DM_GLSLC_JOB（离线编 GLSL）。管线归档 / 帧回放真跑渲染、吃 GPU，照旧排队
    //   出包抽取时 nxsh_extract 主进程与各工作进程、shader_split 各起一个工具宿主同时跑，第一个拿锁后在 stdin 上等请求，其余在 flock 上等它 → 互相等死
    //   （0.6.2 候选验收无人深空出 iPhone 包停在「直连抽取 1/81」24 分钟，样本：9 个 s2arm-host 都在 main → flock，持锁那个在 s2a_oodle_tool_maybe → read）
    if (getenv("DM_OODLE_JOB") || getenv("DM_OODLE_SERVE") || getenv("DM_GLSLC_JOB")) return 0;
    const char *home = getenv("HOME");
    if (!home || !*home) return 0;
    char cfg[1024], path[1024] = {0}, alarm[1024] = {0};
    snprintf(cfg, sizeof cfg, "%s/.s2arm/mac_game_lock", home);
    FILE *f = fopen(cfg, "r");
    if (!f) return 0;
    if (!fgets(path, sizeof path, f)) path[0] = 0;
    if (!fgets(alarm, sizeof alarm, f)) alarm[0] = 0;   // 第二行（可选）：锁轮换时追加报警的文件（开发机上指维护方收件箱）
    fclose(f);
    path[strcspn(path, "\r\n")] = 0; alarm[strcspn(alarm, "\r\n")] = 0;
    if (!path[0]) return 0;
    int fd = open(path, O_RDWR | O_CREAT | O_CLOEXEC, 0644);
    if (fd < 0) {
        fprintf(stderr, "[s2a] Mac 局串行锁 %s 打不开，照常起局（不排队）\n", path);
        return -1;
    }
    if (flock(fd, LOCK_EX | LOCK_NB) == 0) { s2a_dsl_mark_holder(path); return 1; }
    time_t t0 = time(NULL), seen = 0;
    const char *ev = getenv("S2A_MAC_LOCK_EXIT_STUCK_S");
    long stuck = ev && *ev ? atol(ev) : 300;
    int rotated = 0;
    fprintf(stderr, "[s2a] 本机已有 Mac 游戏局在跑：排队等 Mac 局串行锁（%s）\n", path);
    for (;;) {   // 每秒试一次（不再阻塞在 flock 上：要能看见持锁进程卡在退出中）
        if (flock(fd, LOCK_EX | LOCK_NB) == 0) break;
        pid_t h = s2a_dsl_holder(path);
        if (h > 0 && h != getpid() && S2A_DSL_EXITING(h)) {
            if (!seen) seen = time(NULL);
            if (time(NULL) - seen >= stuck) {
                rotated |= s2a_dsl_rotate(fd, path, h, (long)(time(NULL) - seen), alarm);
                int nfd = open(path, O_RDWR | O_CREAT | O_CLOEXEC, 0644);   // 自己或别的排队者已轮换：换到新文件上排
                if (nfd >= 0) { close(fd); fd = nfd; }
                seen = 0;
                continue;
            }
        } else {
            seen = 0;
        }
        struct timespec ts = {1, 0}; nanosleep(&ts, NULL);
    }
    s2a_dsl_mark_holder(path);
    fprintf(stderr, "[s2a] 拿到 Mac 局串行锁，等了 %ld 秒\n", (long)(time(NULL) - t0));
    return rotated ? 3 : 2;   // fd 故意不关：持锁到进程退出
}
