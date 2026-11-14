// 崩溃现场回溯（runtime/src/crash.c s2a_backtrace）：帧指针链里有坏指针时不能在回溯里二次缺页——二次缺页 = 崩溃处理自己 _exit，后面的现场全丢。
//   期望按手搭的帧链直接定：好链 3 帧打 3 行、返回地址照搭的；第 3 帧在不可读页 → 打前 2 帧、进程活着；第 1 帧就在未映射地址 → 0 行
#include "../src/native.h"
#include <fcntl.h>
#include <stdio.h>
#include <string.h>
#include <sys/mman.h>
#include <sys/wait.h>
#include <pthread.h>
#include <stdatomic.h>
#include <unistd.h>
void s2a_crash_install(void);

module_t *module_of(const void *p) { (void)p; return NULL; }
S2A_TEST_MOD_TABLE(64); int g_nmod;   // 装载器的模块表（崩溃原始现场列模块用；本测试不装模块）
// crash.c 取了地址的两个（装载时就要绑定，不能留给动态查找）；回溯路径上不调
int s2a_track_emul_ok(uint64_t a, uint64_t n) { (void)a; (void)n; return 0; }
int s2a_track_store_ok(uint64_t a, uint64_t n) { (void)a; (void)n; return 0; }
// ④ 崩溃路径上会调到的（认领 / 完整报告）：空桩。不配桩时 dyld 在信号处理里懒绑定会死锁
int s2a_far_fault(void *c, uint64_t a, int w) { (void)c; (void)a; (void)w; return 0; }
int s2a_direct_fault(void *a, int w, void *c) { (void)a; (void)w; (void)c; return 0; }
int s2a_track_fault(void *a, int w) { (void)a; (void)w; return 0; }
int s2a_det_watch_fault(uint64_t a, uint64_t b, uint64_t c, uint64_t d) { (void)a; (void)b; (void)c; (void)d; return 0; }
void s2a_touch_thread_init(void) {} void s2a_alias_thread_init(void) {}
void *s2a_tail_map(uint64_t n, int f, int prot) { (void)n; (void)f; (void)prot; return NULL; } void s2a_tail_unmap(void *p, uint64_t n, int f) { (void)p; (void)n; (void)f; }
void s2a_low_holes(uint64_t *t, uint64_t *l) { *t = *l = 0; } void s2a_fd_usage(int *n, uint64_t *s, uint64_t *h) { *n = 0; *s = *h = 0; }
void s2a_lowva_crash_note(void) {} void s2a_vm_low(const char *w) { (void)w; } void s2a_guest_va_report(const char *w) { (void)w; }
void s2a_diag_stamp_report(void) {} void s2a_lockwake_report(void) {} void s2a_svc_count_report(const char *w) { (void)w; }
// ⑤ 用：第二段里拖 200 ms（线程表），让同时崩的另一条线程一定落在第一条还没写完的时候；第二段最后一步写收尾标记，有它 = 第一条的完整报告写到了底
void s2a_thread_dump(void) { usleep(200000); } void s2a_direct_wait_dump(void) {} int s2a_dump_threads(const char *w) { (void)w; return 0; }
void s2a_svc_red_summary(void) { static const char m[] = "[s2a] 报告收尾\n"; ssize_t w = write(g_s2a_logfd, m, sizeof m - 1); (void)w; }
// ⑤ 两条线程到齐再同时读坏地址（macOS 没有 pthread_barrier：原子计数自旋）
static _Atomic int g_gate;
static void gate_wait(void) { atomic_fetch_add(&g_gate, 1); while (atomic_load(&g_gate) < 2) {} }
static void *crash_0x10(void *u) { (void)u; gate_wait(); volatile int *z = (int *)0x10; (void)*z; return NULL; }
static void *crash_0x20(void *u) { (void)u; gate_wait(); volatile int *z = (int *)0x20; (void)*z; return NULL; }
static int bad, n;
static void eq(const char *what, long long want, long long got) { n++; if (want != got) { printf("✗ %s：期望 %lld → 真结果 %lld\n", what, want, got); bad++; } }
// 跑一次回溯、日志落临时文件，数「  #」开头的行
static int frames_logged(uint64_t fp, char *out, size_t cap) {
    char path[] = "/tmp/t_crash_XXXXXX"; int fd = mkstemp(path); int was = g_s2a_logfd; g_s2a_logfd = fd;
    s2a_backtrace(fp);
    g_s2a_logfd = was; lseek(fd, 0, SEEK_SET); ssize_t k = read(fd, out, cap - 1); out[k > 0 ? k : 0] = 0; close(fd); unlink(path);
    int c = 0; for (char *p = out; (p = strstr(p, "  #")); p += 3) c++;
    return c;
}
int main(void) {
    char log[4096];
    static uint64_t st[64] __attribute__((aligned(16)));   // 手搭帧：每帧 {上一帧 fp, 返回地址}，地址递增（同真栈：调用者帧在高处）
    st[0] = (uint64_t)&st[8];  st[1] = 0x1111;
    st[8] = (uint64_t)&st[16]; st[9] = 0x2222;
    st[16] = 0;                st[17] = 0x3333;
    eq("① 好链 3 帧：打 3 行", 3, frames_logged((uint64_t)&st[0], log, sizeof log));
    eq("① 第 2 行返回地址照搭的", 1, strstr(log, "#1 0x2222") != NULL);
    uint8_t *pg = mmap(NULL, 0x4000, PROT_NONE, MAP_PRIVATE | MAP_ANON, -1, 0);
    st[8] = (uint64_t)pg + 0x100;   // 第 2 帧（st[8]）的上一帧指针指进不可读页：第 1、2 帧可读，第 3 帧不可读
    eq("② 第 3 帧在不可读页：打前 2 帧后停、不二次缺页", 2, frames_logged((uint64_t)&st[0], log, sizeof log));
    munmap(pg, 0x4000);
    eq("③ 第 1 帧就在已卸掉的地址：0 行", 0, frames_logged((uint64_t)pg + 0x200, log, sizeof log));
    // ⑥ 指令原文（#368）：手写 5 个指令字，取中间那条前 2 后 2 → 原样 5 个、中间带 [ ]；地址在不可读页 → 「读不到」、不二次缺页
    { void s2a_code_words(uint64_t, int, int, char *, size_t); static uint32_t code[5] = {0xd503201f, 0xaa0003e1, 0xf9000c1f, 0x94000002, 0xd65f03c0};
      char w[256]; s2a_code_words((uint64_t)&code[2], 2, 2, w, sizeof w);
      eq("⑥ 指令原文照写、中间那条带括号", 1, strcmp(w, "d503201f aa0003e1 [f9000c1f] 94000002 d65f03c0") == 0);
      uint8_t *np = mmap(NULL, 0x4000, PROT_NONE, MAP_PRIVATE | MAP_ANON, -1, 0);
      s2a_code_words((uint64_t)np + 0x100, 2, 2, w, sizeof w); eq("⑥ 不可读页：读不到", 1, strcmp(w, "读不到") == 0); munmap(np, 0x4000); }
    // ⑦ 调用点 → 被调的是谁（诊断#59429a：崩在刚调完的函数返回值上，要知道 bl 进的是哪个导入）：手搭一个模块——
    //   site 处 bl 到 PLT 桩（adrp x16 / ldr x17, [x16, #o]），桩指向 GOT 槽，JMPREL 里一条 r_offset = 槽、符号名 nnTestImport。
    //   槽放在桩前 4 页（adrp 页数为负）。期望按构造：目标 = 桩地址、槽 = 构造的槽地址、名字 = nnTestImport；不是 bl → 0；bl 进普通代码 → 槽 0、目标照算
    { uint64_t s2a_call_target(uint64_t, uint64_t *); const char *s2a_import_name(uint64_t);
      uint8_t *img = mmap(NULL, 0x8000, PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANON, -1, 0);
      uint64_t site = (uint64_t)img + 0x100, stub = (uint64_t)img + 0x5000, slot = (uint64_t)img + 0x1008, plain = (uint64_t)img + 0x200;
      int64_t pg = -4;   // (slot 页 − stub 页) / 4096：0x1000 − 0x5000
      *(uint32_t *)site = 0x94000000u | (uint32_t)(((stub - site) / 4) & 0x3FFFFFF);
      *(uint32_t *)(site + 4) = 0x94000000u | (uint32_t)(((plain - (site + 4)) / 4) & 0x3FFFFFF);
      *(uint32_t *)(site + 8) = 0xf9400c00u;   // ldr x0, [x0, #0x18]：不是 bl
      *(uint32_t *)stub = 0x90000010u | (uint32_t)((pg & 3) << 29) | (uint32_t)(((pg >> 2) & 0x7FFFF) << 5);
      *(uint32_t *)(stub + 4) = 0xF9400000u | (uint32_t)((0x008 / 8) << 10) | (16u << 5) | 17u;
      static Elf64_Sym sym[2]; static const char str[] = "\0nnTestImport";
      sym[1].st_name = 1;
      Elf64_Rela *rel = (Elf64_Rela *)(img + 0x6000); rel[0] = (Elf64_Rela){.r_offset = 0x1008, .r_info = ((uint64_t)1 << 32) | 1026, .r_addend = 0};
      static Elf64_Dyn dyn[3]; dyn[0] = (Elf64_Dyn){23, {.d_ptr = 0x6000}}; dyn[1] = (Elf64_Dyn){2, {.d_val = sizeof(Elf64_Rela)}}; dyn[2] = (Elf64_Dyn){0, {0}};
      memset(&g_mod[0], 0, sizeof g_mod[0]); memcpy(g_mod[0].name, "main", 5); g_mod[0].base = img; g_mod[0].size = 0x8000;
      g_mod[0].dyn = dyn; g_mod[0].symtab = sym; g_mod[0].strtab = str; g_nmod = 1;
      uint64_t got = 1, t = s2a_call_target(site, &got);
      eq("⑦ bl 进 PLT 桩：目标 = 桩地址", (long long)stub, (long long)t);
      eq("⑦ 桩的 GOT 槽（adrp 负页数）= 构造的槽", (long long)slot, (long long)got);
      const char *nm = s2a_import_name(got);
      eq("⑦ 槽 → 导入名 nnTestImport", 1, nm && strcmp(nm, "nnTestImport") == 0);
      eq("⑦ 不在重定位表里的槽 → NULL", 1, s2a_import_name(slot + 8) == NULL);
      t = s2a_call_target(site + 4, &got);
      eq("⑦ bl 进普通代码：目标照算", (long long)plain, (long long)t); eq("⑦ bl 进普通代码：没有槽", 0, (long long)got);
      eq("⑦ 不是 bl → 0", 0, (long long)s2a_call_target(site + 8, &got));
      g_nmod = 0; munmap(img, 0x8000); }
    // ④ 两段式：子进程装崩溃处理后读空指针。期望第一段（只用 write）原始现场行（信号 0xb）、寄存器行、帧链行都在，
    //   且排在第二段完整报告（「CRASH 信号」行）之前
    { char path[] = "/tmp/t_crash_raw_XXXXXX"; int fd = mkstemp(path);
      pid_t c = fork();
      if (c == 0) { g_s2a_logfd = fd; s2a_crash_install(); volatile int *z = NULL; (void)*z; _exit(0); }
      int ws = 0; waitpid(c, &ws, 0);
      char out[8192]; lseek(fd, 0, SEEK_SET); ssize_t k = read(fd, out, sizeof out - 1); out[k > 0 ? k : 0] = 0; close(fd); unlink(path);
      eq("④ 子进程没正常退出（崩了）", 1, !(WIFEXITED(ws) && WEXITSTATUS(ws) == 0));
      eq("④ 原始现场行（信号 SIGSEGV = 0xb）", 1, strstr(out, "崩溃原始现场 信号 000000000000000b") != NULL);
      eq("④ 寄存器行、帧链行都在", 1, strstr(out, "[s2a]   x 0") != NULL && strstr(out, "[s2a]   帧链") != NULL);
      char *raw = strstr(out, "崩溃原始现场"), *rich = strstr(out, "CRASH 信号");
      eq("④ 第一段在第二段之前", 1, raw && rich && raw < rich); }
    // ⑤ 两条线程同时崩（1-2-Switch 10-29：第二条崩的线程直接 _exit 整个进程，第一条的现场写到一半，host.log 断在行中间、rc=138）：
    //   子进程两条线程过同一屏障后各读一个坏地址（0x10 / 0x20）。期望两份原始现场都在、第一条的完整报告写到收尾、没有被插断的行、
    //   最后被 SIGSEGV 结束（#141：现场写完重抛默认处置，让 macOS / iOS 出系统崩溃报告；原先 _exit(139) 是正常退出）
    { char path[] = "/tmp/t_crash_two_XXXXXX"; int fd = mkstemp(path);
      pid_t c = fork();
      if (c == 0) {
          g_s2a_logfd = fd; s2a_crash_install();
          static void *(*const crash_at[2])(void *) = {crash_0x10, crash_0x20};
          pthread_t t[2]; for (int i = 0; i < 2; i++) pthread_create(&t[i], NULL, crash_at[i], NULL);
          for (int i = 0; i < 2; i++) pthread_join(t[i], NULL);
          _exit(0);
      }
      int ws = 0; waitpid(c, &ws, 0);
      static char out[65536]; lseek(fd, 0, SEEK_SET); ssize_t k = read(fd, out, sizeof out - 1); out[k > 0 ? k : 0] = 0; close(fd); unlink(path);
      eq("⑤ 现场写完后按默认处置重抛：子进程被 SIGSEGV 结束（系统出崩溃报告）", SIGSEGV, WIFSIGNALED(ws) ? WTERMSIG(ws) : -1);
      eq("⑤ 地址 0x10 那条线程的原始现场在", 1, strstr(out, " 地址 0000000000000010") != NULL);
      eq("⑤ 地址 0x20 那条线程的原始现场在", 1, strstr(out, " 地址 0000000000000020") != NULL);
      int chains = 0; for (char *q = out; (q = strstr(q, "[s2a]   帧链")); q++) chains++;
      eq("⑤ 两条帧链行", 2, chains);
      eq("⑤ 先崩那条的完整报告写到收尾", 1, strstr(out, "[s2a] 报告收尾") != NULL);
      int torn = 0; for (char *l = out; *l; ) { char *e = strchr(l, '\n'); if (!e) { torn++; break; }
          char *a = strstr(l, "[s2a]"); if (a && a < e) { char *b2 = strstr(a + 5, "[s2a]"); if (b2 && b2 < e) torn++; } l = e + 1; }
      eq("⑤ 没有被另一条线程插断的行（一行里两个 [s2a]、或末行没写完）", 0, torn); }
    // ⑥ 出事那块内存（#523 / #815：SIGBUS 只有地址，看不出是只读还是没映射）：子进程往自己设成只读的匿名页写。
    //   期望按构造写死：写（ESR WnR）、落在映射块、当前 r-- / 最大 rwx（匿名映射的最大权限）；块起点就是那一页
    { char path[] = "/tmp/t_crash_ro_XXXXXX"; int fd = mkstemp(path);
      volatile uint8_t *ro = mmap(NULL, 0x4000, PROT_READ, MAP_PRIVATE | MAP_ANON, -1, 0);
      pid_t c = fork();
      if (c == 0) { g_s2a_logfd = fd; s2a_crash_install(); ro[0x10] = 1; _exit(0); }
      int ws = 0; waitpid(c, &ws, 0);
      static char out[65536]; lseek(fd, 0, SEEK_SET); ssize_t k = read(fd, out, sizeof out - 1); out[k > 0 ? k : 0] = 0; close(fd); unlink(path);
      char want[96]; snprintf(want, sizeof want, "出事那块内存：写 %#llx", (unsigned long long)(uintptr_t)(ro + 0x10));
      char blk[64]; snprintf(blk, sizeof blk, "[%#llx, %#llx)", (unsigned long long)(uintptr_t)ro, (unsigned long long)(uintptr_t)(ro + 0x4000));
      eq("⑥ 写只读页：子进程崩了", 1, !(WIFEXITED(ws) && WEXITSTATUS(ws) == 0));
      eq("⑥ 出事那块内存行：写、地址照写的", 1, strstr(out, want) != NULL);
      eq("⑥ 落在映射块、块起止就是那一页", 1, strstr(out, "落在映射块") != NULL && strstr(out, blk) != NULL);
      eq("⑥ 权限 当前 r-- / 最大 rwx", 1, strstr(out, "权限 当前 r-- / 最大 rwx") != NULL);
      munmap((void *)ro, 0x4000); }
    if (bad) { printf("✗ t_crash：%d/%d 项不符\n", bad, n); return 1; }
    printf("✓ t_crash：%d 项崩溃现场全符（回溯好链、坏指针不二次缺页、未映射起点、两段式第一段先落盘、两线程同时崩两份现场都在、调用点反查导入名）\n", n);
    return 0;
}
