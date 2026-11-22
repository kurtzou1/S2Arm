// 客体内存文件后备溢出模式（vawin.c s2a_guest_commit / s2a_guest_zero / s2a_guest_in_file，11-16，docs/坑记录.md「文件后备改溢出模式」）。
// 设计（期望全按它手推，不跑被测实现）：窗口按 32 MB 分块；块在第一次放开前（s2a_guest_commit）定后备、定了不变：
//   已定为匿名的累计 < 预算 → 匿名；否则还是匿名占位的段换成文件（同偏移 = 地址 − 窗口基址）。预算 = 剩余 − 余量 − 宿主开销，S2A_GUEST_FILE_ANON_BUDGET_MB 显式给。
//   本测预算 64 MB：头两个定下的块匿名（累计 0 → 32 → 64），之后的块进文件。
// 判「在不在文件里」直接看后备文件：窗口里写的字节 pread 后备文件同偏移读得到 = 文件后备；读回 0（稀疏空洞）而内存里非 0 = 匿名。另看实占：匿名计实占、文件映射脏页不计
//   ① 预算纯函数：剩余 6141 − 余量 512 − 宿主 2048 = 3581 MB（D-JETP 那台）；剩余 2000 不够 → 0；显式 "0" → 0、"100" → 100 MB
//   ② 判开后窗口仍是匿名占位：fd ≥ 0，没放开过的地址 in_file = 0
//   ③ 块 A 第一次放开（累计 0 < 64）→ 匿名：写入文件里读不到、实占涨 ≥ 24 MB；in_file 0；还页 s2a_guest_zero 回 0（调用方换匿名占位）
//   ④ 跨块放开 [B+16, B+48) MB（块 B、C 一次调）：B（累计 32 < 64）→ 匿名，C（累计 64 ≥ 64）→ 文件：B 写入文件里读不到、C 写入文件里读得到；
//      in_file(C) 1、in_file(B) 0、跨 B/C 的 in_file 0
//   ⑤ 文件块整块写 32 MB：实占涨 < 8 MB
//   ⑥ 文件块还页：s2a_guest_zero(C 前 16 MB) 回 1；重新放开读回全 0；状态仍是文件（in_file 1，再写进去文件里读得到）；还页段外的 C 后半内容不变
//   ⑦ 跨块还页 [B+16, C+16) MB（匿名段 + 文件段）：回 1；两段重新放开都读回 0；C 仍在文件里（写入文件里读得到）、B 仍匿名（写入文件里读不到）
//   ⑧ 换文件不抹已有内容：块 D 定之前先在里面直接映射一段有内容的匿名可写页（同装载器映射模块数据），预算已用完 → D 进文件；那段内容还在、仍不在文件里，D 别处写入在文件里
//   ⑨ 挖区（S2A_GUEST_FILE_CARVE=1）：整块落在挖区里的块预算已用完也是匿名（写入文件里读不到）；in_file 0
//   ⑩ 窗口重置（s2a_window_session_reset）后块状态清回未定、累计清零：原是文件的块 C 再放开 → 匿名（累计 0 < 64）
//   ⑪ iOS 下一局预算（s2a_guest_next_budget，只用实测量）：显式最优先；上局死掉 → 0；有记录 → B + (Hmin − 余量) − 32 MB，限 [0, 剩余 − 余量]；首局 → 剩余 − 余量 − 4096。
//      D-JETP（剩余 6141、余量 512）：首局 6141 − 512 − 4096 = 1533；设那局 Hmin 2600 → 第二局 1533 + 2088 − 32 = 3589；
//      收紧 3589 + (300 − 512) − 32 = 3345；下限 100 + (0 − 512) − 32 < 0 → 0；上限 5000 + 3488 − 32 = 8456 > 6141 − 512 = 5629 → 5629；
//      12 GB 机（剩余 8189）首局 8189 − 512 − 4096 = 3581；剩余 4000 首局不够 → 0；上局整段（B 0）Hmin 3000 → 3000 − 512 − 32 = 2456
//      11-22 往上抬要证据（上局够长 long_run，每局最多抬 1024；被收掉那局预算 − 1024 作天花板 ceil）：上面往上抬的几条按够长局算——
//      第二局 1533 + 2056 > 一步 → 1533 + 1024 = 2557；上限那条 5000 + 1024 = 6024 仍夹到 5629；整段回升 0 + 1024 = 1024。
//      短局：1533 / 2600 → 持平 1533；3589 / 300 → 照样收紧 3345。一台 iPhone（剩余 8188）：上局 61 秒、预算 3521、剩余最小 6012 →
//      旧算法 3521 + 6012 − 544 = 8989 夹到 7676（真机日志就是 7676）；新：短局持平 3521；同读数够长 → 4545。
//      天花板：6000 / 4000 够长、剩余 8188、ceil 6652 → min(7024, 7676, 6652) = 6652；首局估计 3580 遇 ceil 2000 → 2000
//   ⑫ 预算记录（同 mem_peak_anon 目录 anon_budget）：心跳值 3000 → 记「64 3000」；3500 不更小不写；2600 → 「64 2600」；
//      据此起局 = 64 + (2600 − 512) − 32 = 2120（按上局实测）；上局死掉 → 0 且记录删掉；再起局没记录 → 首局 1533；S2A_GUEST_FILE_OVERFLOW_HOST_MB=3000 → 6141 − 512 − 3000 = 2629
#include "../src/native.h"
#include <sys/mman.h>
#include <mach/mach.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
__attribute__((constructor(100))) static void need(void) {   // 先于 vawin.c 的构造函数（101）
    setenv("S2A_WIN_NEED_MB", "63488", 1); setenv("S2A_GUEST_FILE", "1", 1); setenv("S2A_GUEST_FILE_MIN_FREE_MB", "1", 1); setenv("S2A_GUEST_FILE_ANON_BUDGET_MB", "64", 1);
    unsetenv("S2A_GUEST_FILE_CARVE");
}
uint64_t s2a_guest_anon_budget(const char *e, uint64_t room, uint64_t margin, uint64_t host);
uint64_t s2a_guest_next_budget(const char *e, uint64_t room, uint64_t margin, uint64_t first_host, int died, int have, uint64_t prev_b, uint64_t hmin, int long_run, uint64_t ceil, int *src);
uint64_t s2a_guest_overflow_budget_ios(const char *e, uint64_t room, uint64_t margin, int died, int *src, uint64_t *pb, uint64_t *ph);
int s2a_guest_budget_rec_read(uint64_t *b, uint64_t *hmin); void s2a_guest_budget_note(uint64_t avail);
void s2a_guest_commit(uint64_t a, uint64_t n); void s2a_guest_file_carve(uint64_t a, uint64_t n); int s2a_window_session_reset(void); void s2a_guest_backing_log(void); void s2a_guest_backing_sum(uint64_t sum[4]); void s2a_window_trim(uint64_t size);
static long long fp(void) { task_vm_info_data_t i; mach_msg_type_number_t c = TASK_VM_INFO_COUNT; task_info(mach_task_self(), TASK_VM_INFO, (task_info_t)&i, &c); return (long long)i.phys_footprint; }
static int bad; static uint64_t b;
#define CHECK(c, ...) do { if (c) { printf("✓ "); } else { printf("✗ "); bad++; } printf(__VA_ARGS__); putchar('\n'); fflush(stdout); } while (0)
#define MB (1ull << 20)
// 地址 p 处的一字节在后备文件同偏移读出来是什么
static int file_byte(uint64_t p) { uint8_t c = 0; return pread(s2a_guest_fd(), &c, 1, (off_t)(p - b)) == 1 ? c : -1; }
// 放开 [p, p + n) 并写 v，返回写完后文件同偏移是否读到 v（1 = 在文件里）
static int open_write(uint64_t p, uint64_t n, uint8_t v) {
    s2a_guest_commit(p, n);
    if (mprotect((void *)(uintptr_t)p, n, PROT_READ | PROT_WRITE)) { printf("✗ 放开 %#llx +%llu MB 失败\n", (unsigned long long)p, (unsigned long long)(n / MB)); bad++; return -1; }
    for (uint64_t o = 0; o < n; o += 4096) ((uint8_t *)(uintptr_t)p)[o] = v;
    return file_byte(p) == v && file_byte(p + n - 4096) == v;
}
static size_t nonzero(uint64_t p, uint64_t n) { size_t k = 0; for (uint64_t o = 0; o < n; o += 4096) k += ((uint8_t *)(uintptr_t)p)[o] != 0; return k; }
#define GCH (32ull << 20)   // 同 vawin.c GCHUNK
int main(void) {
    CHECK(s2a_guest_anon_budget(NULL, 6141 * MB, 512 * MB, 2048 * MB) == 3581 * MB, "① 预算 = 6141 − 512 − 2048 = 3581 MB（得 %llu）", (unsigned long long)(s2a_guest_anon_budget(NULL, 6141 * MB, 512 * MB, 2048 * MB) / MB));
    CHECK(s2a_guest_anon_budget(NULL, 2000 * MB, 512 * MB, 2048 * MB) == 0, "① 剩余 2000 MB 不够余量 + 宿主：预算 0（整段进文件）");
    CHECK(s2a_guest_anon_budget(NULL, 0, 512 * MB, 2048 * MB) == 0, "① 剩余未知（0）：预算 0");
    CHECK(s2a_guest_anon_budget("0", 9000 * MB, 512 * MB, 2048 * MB) == 0 && s2a_guest_anon_budget("100", 0, 512 * MB, 2048 * MB) == 100 * MB, "① 显式 \"0\" → 0、\"100\" → 100 MB");
    if (!s2a_window_ok()) { printf("✗ t_guest_file_overflow：窗口没占到\n"); return 1; }
    uint64_t n; s2a_window_get(&b, &n);
    const uint64_t A = b + (4ull << 30), B = A + 32 * MB, C = B + 32 * MB, D = b + (5ull << 30), K = b + (8ull << 30);
    CHECK(s2a_guest_fd() >= 0, "② 接上后备文件（fd %d）", s2a_guest_fd());
    CHECK(s2a_guest_in_file(A, 16384) == 0 && s2a_guest_in_file(b + (20ull << 30), 16384) == 0, "② 判开后窗口仍是匿名占位：没放开过的地址不在文件里");
    {   // ③
        long long f0 = fp(); int inf = open_write(A, 32 * MB, 0x11); long long df = fp() - f0;
        CHECK(inf == 0, "③ 块 A（累计 0 < 64）→ 匿名：写入后备文件里读不到（文件字节 %d）", file_byte(A));
        CHECK(df >= (24ll << 20), "③ 块 A 写 32 MB：实占 +%lld KB（匿名计实占，期望 ≥ 24576 KB）", df >> 10);
        CHECK(s2a_guest_in_file(A, 16384) == 0, "③ in_file(A) = 0");
        CHECK(s2a_guest_zero(A, MB) == 0, "③ 匿名块还页回 0（调用方照旧换匿名占位）");
    }
    {   // ④
        s2a_guest_commit(B + 16 * MB, 32 * MB);
        int inB = open_write(B, 32 * MB, 0x22), inC = open_write(C, 32 * MB, 0x33);
        CHECK(inB == 0, "④ 跨块放开：块 B（累计 32 < 64）→ 匿名（文件字节 %d）", file_byte(B));
        CHECK(inC == 1, "④ 跨块放开：块 C（累计 64 ≥ 64）→ 文件（文件字节 %#x，期望 0x33）", file_byte(C));
        CHECK(s2a_guest_in_file(C, 32 * MB) == 1 && s2a_guest_in_file(B, 16384) == 0 && s2a_guest_in_file(C - 16384, 32768) == 0, "④ in_file：C 1、B 0、跨 B/C 0");
    }
    {   // ⑤
        long long f0 = fp(); for (uint64_t o = 0; o < 32 * MB; o += 64) ((uint8_t *)(uintptr_t)C)[o] = (uint8_t)(o >> 6) | 1; long long df = fp() - f0;
        CHECK(df < (8ll << 20), "⑤ 文件块写满 32 MB：实占 +%lld KB（期望 < 8192 KB）", df >> 10);
    }
    {   // ⑥
        uint8_t keep = ((uint8_t *)(uintptr_t)C)[16 * MB + 64];
        CHECK(s2a_guest_zero(C, 16 * MB) == 1, "⑥ 文件块还页 16 MB 回 1（打洞 + 重映射）");
        s2a_guest_commit(C, 16 * MB);
        CHECK(!mprotect((void *)(uintptr_t)C, 16 * MB, PROT_READ | PROT_WRITE) && nonzero(C, 16 * MB) == 0, "⑥ 还过的段重新放开读回全 0（非 0 %zu 处）", nonzero(C, 16 * MB));
        CHECK(((uint8_t *)(uintptr_t)C)[16 * MB + 64] == keep && keep == (uint8_t)(((16 * MB + 64) >> 6) | 1), "⑥ 还页段外的 C 后半内容不变（%#x）", keep);
        ((uint8_t *)(uintptr_t)C)[4096] = 0x5c;
        CHECK(s2a_guest_in_file(C, 16 * MB) == 1 && file_byte(C + 4096) == 0x5c, "⑥ 还页后仍是文件块：in_file 1、写入文件里读得到（%#x）", file_byte(C + 4096));
    }
    {   // ⑦
        CHECK(s2a_guest_zero(B + 16 * MB, 32 * MB) == 1, "⑦ 跨块还页（匿名段 + 文件段）回 1");
        s2a_guest_commit(B + 16 * MB, 32 * MB);
        CHECK(!mprotect((void *)(uintptr_t)(B + 16 * MB), 32 * MB, PROT_READ | PROT_WRITE) && nonzero(B + 16 * MB, 32 * MB) == 0, "⑦ 两段重新放开读回全 0（非 0 %zu 处）", nonzero(B + 16 * MB, 32 * MB));
        ((uint8_t *)(uintptr_t)(B + 20 * MB))[0] = 0x44; ((uint8_t *)(uintptr_t)(C + 4 * MB))[0] = 0x55;
        CHECK(file_byte(B + 20 * MB) == 0 && file_byte(C + 4 * MB) == 0x55 && s2a_guest_in_file(C, 32 * MB) == 1, "⑦ B 仍匿名（文件字节 %d）、C 仍是文件（文件字节 %#x）", file_byte(B + 20 * MB), file_byte(C + 4 * MB));
    }
    {   // ⑧
        uint8_t *m = (uint8_t *)(uintptr_t)(D + 8 * MB);
        if (mmap(m, MB, PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANON | MAP_FIXED, -1, 0) != m) CHECK(0, "⑧ 造现场：块 D 里映射匿名可写页失败");
        else {
            memset(m, 0x77, MB);
            int inD = open_write(D, 4 * MB, 0x66);
            CHECK(inD == 1, "⑧ 预算已用完：块 D → 文件（文件字节 %#x）", file_byte(D));
            CHECK(m[0] == 0x77 && m[MB - 1] == 0x77 && file_byte(D + 8 * MB) == 0, "⑧ 换文件不抹已有内容：那段还是 %#x、不在文件里（文件字节 %d）", m[0], file_byte(D + 8 * MB));
        }
    }
    {   // ⑨
        setenv("S2A_GUEST_FILE_CARVE", "1", 1); s2a_guest_file_carve(K, 128 * MB); unsetenv("S2A_GUEST_FILE_CARVE");
        int inK = open_write(K + 32 * MB, 32 * MB, 0x99);
        CHECK(inK == 0 && s2a_guest_in_file(K + 32 * MB, 16384) == 0, "⑨ 挖区里的块预算用完也是匿名（文件字节 %d）、in_file 0", file_byte(K + 32 * MB));
    }
    s2a_guest_backing_log();
    {   // ⑩
        int rc = s2a_window_session_reset();
        CHECK(rc == 0, "⑩ 窗口重置返回 %d（期望 0）", rc);
        CHECK(file_byte(C + 4096) == 0 && file_byte(D) == 0, "⑩ 重置时后备文件已打洞：旧内容（0x5c / 0x66）读不到（文件字节 %d / %d）", file_byte(C + 4096), file_byte(D));
        int inC = open_write(C, 32 * MB, 0xab);
        CHECK(inC == 0 && s2a_guest_in_file(C, 16384) == 0, "⑩ 重置后块状态清回未定、累计清零：原文件块 C 再放开 → 匿名（文件字节 %d）", file_byte(C));
    }
    {   // ⑪
        int src = -1; const uint64_t M = 512 * MB, H = 4096 * MB;
#define NB(e, room, died, have, pb, ph) s2a_guest_next_budget(e, (room) * MB, M, H, died, have, (pb) * MB, (ph) * MB, 1, 0, &src)
#define NB2(room, have, pb, ph, lr, ceil) s2a_guest_next_budget(NULL, (room) * MB, M, H, 0, have, (pb) * MB, (ph) * MB, lr, (ceil) * MB, &src)
        uint64_t v;
        v = NB("100", 6141, 1, 1, 1533, 2600); CHECK(v == 100 * MB && src == 0, "⑪ 显式 100 最优先（哪怕上局死掉）：%llu MB", (unsigned long long)(v / MB));
        v = NB(NULL, 6141, 1, 1, 1533, 2600); CHECK(v == 0 && src == 1, "⑪ 上局死掉 → 0（整段进文件）：%llu MB", (unsigned long long)(v / MB));
        v = NB(NULL, 6141, 0, 0, 0, 0); CHECK(v == 1533 * MB && src == 3, "⑪ D-JETP 首局 6141 − 512 − 4096 = 1533：%llu MB", (unsigned long long)(v / MB));
        v = NB(NULL, 6141, 0, 1, 1533, 2600); CHECK(v == 2557 * MB && src == 2, "⑪ D-JETP 第二局（Hmin 2600、够长）1533 + 2056 超一步 → 1533 + 1024 = 2557：%llu MB", (unsigned long long)(v / MB));
        v = NB(NULL, 6141, 0, 1, 3589, 300); CHECK(v == 3345 * MB, "⑪ Hmin 300 < 余量 收紧 3589 − 212 − 32 = 3345：%llu MB", (unsigned long long)(v / MB));
        v = NB(NULL, 6141, 0, 1, 100, 0); CHECK(v == 0, "⑪ 下限 0：%llu MB", (unsigned long long)(v / MB));
        v = NB(NULL, 6141, 0, 1, 5000, 4000); CHECK(v == 5629 * MB, "⑪ 上限 剩余 − 余量 = 5629：%llu MB", (unsigned long long)(v / MB));
        v = NB(NULL, 8189, 0, 0, 0, 0); CHECK(v == 3581 * MB, "⑪ 12 GB 机首局 8189 − 512 − 4096 = 3581：%llu MB", (unsigned long long)(v / MB));
        v = NB(NULL, 4000, 0, 0, 0, 0); CHECK(v == 0, "⑪ 剩余 4000 首局不够 → 0：%llu MB", (unsigned long long)(v / MB));
        v = NB(NULL, 6141, 0, 1, 0, 3000); CHECK(v == 1024 * MB && src == 2, "⑪ 上局整段（B 0、Hmin 3000、够长）回升 2456 超一步 → 1024：%llu MB", (unsigned long long)(v / MB));
        v = NB2(6141, 1, 1533, 2600, 0, 0); CHECK(v == 1533 * MB, "⑪ 短局 1533 / 2600 只许持平：%llu MB（期望 1533）", (unsigned long long)(v / MB));
        v = NB2(6141, 1, 3589, 300, 0, 0); CHECK(v == 3345 * MB, "⑪ 短局照样收紧 3345：%llu MB", (unsigned long long)(v / MB));
        v = NB2(8188, 1, 3521, 6012, 0, 0); CHECK(v == 3521 * MB, "⑪ 一台 iPhone 上局 61 秒（3521 / 6012）：%llu MB（期望 3521，旧算法 7676）", (unsigned long long)(v / MB));
        v = NB2(8188, 1, 3521, 6012, 1, 0); CHECK(v == 4545 * MB, "⑪ 同读数够长局：3521 + 1024 = %llu MB（期望 4545）", (unsigned long long)(v / MB));
        v = NB2(8188, 1, 6000, 4000, 1, 6652); CHECK(v == 6652 * MB, "⑪ 天花板 6652：%llu MB（期望 6652）", (unsigned long long)(v / MB));
        v = NB2(8188, 0, 0, 0, 0, 2000); CHECK(v == 2000 * MB && src == 3, "⑪ 首局估计 3580 遇天花板 2000：%llu MB", (unsigned long long)(v / MB));
#undef NB
#undef NB2
    }
    {   // ⑫
        char d[] = "/tmp/t_gfo_recXXXXXX", pk[300], rp[300];
        if (!mkdtemp(d)) CHECK(0, "⑫ 建临时目录失败");
        else {
            snprintf(pk, sizeof pk, "%s/mem_peak_anon", d); snprintf(rp, sizeof rp, "%s/anon_budget", d); setenv("S2A_GUEST_MEM_PEAK", pk, 1); unsetenv("S2A_GUEST_FILE_OVERFLOW_HOST_MB");
            uint64_t rb = 0, rh = 0; int src = -1, ok;
            s2a_guest_budget_note(3000 * MB); ok = s2a_guest_budget_rec_read(&rb, &rh);
            CHECK(ok && rb == 64 * MB && rh == 3000 * MB, "⑫ 心跳 3000 → 记录「%llu %llu」（期望 64 3000）", (unsigned long long)(rb / MB), (unsigned long long)(rh / MB));
            s2a_guest_budget_note(3500 * MB); ok = s2a_guest_budget_rec_read(&rb, &rh);
            CHECK(ok && rh == 3000 * MB, "⑫ 心跳 3500 不更小：记录仍 %llu", (unsigned long long)(rh / MB));
            s2a_guest_budget_note(2600 * MB); ok = s2a_guest_budget_rec_read(&rb, &rh);
            CHECK(ok && rb == 64 * MB && rh == 2600 * MB, "⑫ 心跳 2600 → 记录「%llu %llu」（期望 64 2600）", (unsigned long long)(rb / MB), (unsigned long long)(rh / MB));
            uint64_t pb, ph, v = s2a_guest_overflow_budget_ios(NULL, 6141 * MB, 512 * MB, 0, &src, &pb, &ph);
            CHECK(v == 64 * MB && src == 2 && pb == 64 * MB && ph == 2600 * MB, "⑫ 起局按上局实测：64 + 2088 − 32 = 2120 往上抬，但上局只 3 次心跳（短局）→ 持平 64（得 %llu MB，来源 %d）", (unsigned long long)(v / MB), src);
            v = s2a_guest_overflow_budget_ios(NULL, 6141 * MB, 512 * MB, 1, &src, &pb, &ph);
            CHECK(v == 0 && src == 1 && access(rp, F_OK) != 0, "⑫ 上局死掉 → 0、记录已删（得 %llu MB，记录%s）", (unsigned long long)(v / MB), access(rp, F_OK) ? "没了" : "还在");
            v = s2a_guest_overflow_budget_ios(NULL, 6141 * MB, 512 * MB, 0, &src, &pb, &ph);
            CHECK(v == 1533 * MB && src == 3, "⑫ 没记录 → 首局估计 1533（得 %llu MB，来源 %d）", (unsigned long long)(v / MB), src);
            setenv("S2A_GUEST_FILE_OVERFLOW_HOST_MB", "3000", 1); v = s2a_guest_overflow_budget_ios(NULL, 6141 * MB, 512 * MB, 0, &src, &pb, &ph); unsetenv("S2A_GUEST_FILE_OVERFLOW_HOST_MB");
            CHECK(v == 2629 * MB, "⑫ S2A_GUEST_FILE_OVERFLOW_HOST_MB=3000 → 2629（得 %llu MB）", (unsigned long long)(v / MB));
            {   // ⑫b 两局上限不同（11-16 真机：8189 → 6141）：上局起局剩余 8189、预算 3581、剩余最小 4835；这局剩余 6141 → 剩余最小按差 2048 扣成 2787，
                //   预算 3581 + 2787 − 512 − 32 = 5824，夹到 6141 − 512 = 5629；这局剩余 8189 → 不扣：3581 + 4835 − 512 − 32 = 7872，夹到 7677
                FILE *f = fopen(rp, "w"); fprintf(f, "3581 4835 8189\n"); fclose(f);   // 旧三项记录：当短局
                uint64_t v1 = s2a_guest_overflow_budget_ios(NULL, 6141 * MB, 512 * MB, 0, &src, &pb, &ph);
                CHECK(v1 == 3581 * MB && ph == 2787 * MB, "⑫b 旧三项记录（当短局）上限低 2048：剩余最小扣成 %llu（期望 2787）、预算 %llu（期望持平 3581）", (unsigned long long)(ph / MB), (unsigned long long)(v1 / MB));
                f = fopen(rp, "w"); fprintf(f, "3581 4835 8189 30 0\n"); fclose(f);
                v1 = s2a_guest_overflow_budget_ios(NULL, 6141 * MB, 512 * MB, 0, &src, &pb, &ph);
                CHECK(v1 == 4605 * MB && ph == 2787 * MB, "⑫b 够长局上限低 2048：剩余最小扣成 %llu（期望 2787）、预算 %llu（期望 5824 超一步 → 4605）", (unsigned long long)(ph / MB), (unsigned long long)(v1 / MB));
                f = fopen(rp, "w"); fprintf(f, "1000 3000 8189 30 0\n"); fclose(f);
                v1 = s2a_guest_overflow_budget_ios(NULL, 6141 * MB, 512 * MB, 0, &src, &pb, &ph);
                CHECK(v1 == 1000 * MB + 952 * MB - 512 * MB - 32 * MB && ph == 952 * MB, "⑫b 不夹时：1000 + (3000 − 2048) − 512 − 32 = 1408（得 %llu）", (unsigned long long)(v1 / MB));
                f = fopen(rp, "w"); fprintf(f, "1000 3000 6141 30 0\n"); fclose(f);
                v1 = s2a_guest_overflow_budget_ios(NULL, 8189 * MB, 512 * MB, 0, &src, &pb, &ph);
                CHECK(v1 == 2024 * MB && ph == 3000 * MB, "⑫b 上限高了不加：1000 + 3000 − 512 − 32 = 3456 超一步 → 2024（得 %llu）", (unsigned long long)(v1 / MB));
                s2a_guest_budget_note(1234 * MB); unsigned long long x = 0, y = 0, z = 0; f = fopen(rp, "r"); int n3 = f ? fscanf(f, "%llu %llu %llu", &x, &y, &z) : 0; if (f) fclose(f);
                CHECK(n3 == 3 && z == 8189, "⑫b 记录第三项写这局起局剩余 %llu（期望 8189）", z);
            }
            {   // ⑫c 天花板与次数（11-22）：上局「7676 6012 8188 6 0」被系统收掉 → 这局 0、记录换成「0 0 8188 0 6652」（7676 − 1024）；
                //   下一局（没死）读到 0 / 0 → 0；够长局「6000 4000 8188 30 6652」→ 6000 + 3456 − 32 超一步 7024，夹到天花板 6652；
                //   心跳第 30 次（剩余没更小）照写一笔，第四项 = 30
                unsigned long long r[5] = {0}; int n5; FILE *f;
                f = fopen(rp, "w"); fprintf(f, "7676 6012 8188 6 0\n"); fclose(f);
                uint64_t v1 = s2a_guest_overflow_budget_ios(NULL, 8188 * MB, 512 * MB, 1, &src, &pb, &ph);
                f = fopen(rp, "r"); n5 = f ? fscanf(f, "%llu %llu %llu %llu %llu", &r[0], &r[1], &r[2], &r[3], &r[4]) : 0; if (f) fclose(f);
                CHECK(v1 == 0 && src == 1 && n5 == 5 && r[0] == 0 && r[1] == 0 && r[2] == 8188 && r[3] == 0 && r[4] == 6652,
                      "⑫c 被收掉：预算 %llu（期望 0）、记录「%llu %llu %llu %llu %llu」（期望 0 0 8188 0 6652）", (unsigned long long)(v1 / MB), r[0], r[1], r[2], r[3], r[4]);
                v1 = s2a_guest_overflow_budget_ios(NULL, 8188 * MB, 512 * MB, 0, &src, &pb, &ph);
                CHECK(v1 == 0 && src == 2, "⑫c 死后下一局读到 0 / 0：%llu（期望 0）", (unsigned long long)(v1 / MB));
                f = fopen(rp, "w"); fprintf(f, "6000 4000 8188 30 6652\n"); fclose(f);
                v1 = s2a_guest_overflow_budget_ios(NULL, 8188 * MB, 512 * MB, 0, &src, &pb, &ph);
                CHECK(v1 == 6652 * MB, "⑫c 够长局夹到天花板：%llu（期望 6652）", (unsigned long long)(v1 / MB));
                for (int i = 0; i < 30; i++) s2a_guest_budget_note(9000 * MB);
                f = fopen(rp, "r"); n5 = f ? fscanf(f, "%llu %llu %llu %llu %llu", &r[0], &r[1], &r[2], &r[3], &r[4]) : 0; if (f) fclose(f);
                CHECK(n5 == 5 && r[3] == 30 && r[4] == 6652, "⑫c 第 30 次心跳记一笔：第四项 %llu（期望 30）、天花板 %llu（期望 6652）", r[3], r[4]);
            }
            unlink(rp); rmdir(d); unsetenv("S2A_GUEST_MEM_PEAK");
        }
    }
    {   // ⑬ 窗口收尾只缩窗口、块表不缩（11-16 真机：心跳合计成了 2^64 附近）：收尾后各状态合计必须正好等于收尾后的窗口大小
        uint64_t b0, z0; s2a_window_get(&b0, &z0); uint64_t keep = (z0 / 2) & ~(uint64_t)(GCH - 1) ;
        s2a_window_trim(keep + GCH / 2);   // 收在半块处：最后一块只剩半块
        uint64_t b1, z1, sm[4]; s2a_window_get(&b1, &z1); s2a_guest_backing_sum(sm);
        CHECK(z1 == keep + GCH / 2 && sm[0] + sm[1] + sm[2] + sm[3] == z1, "⑬ 收尾后合计 %llu MB = 窗口 %llu MB（收尾前 %llu MB）",
              (unsigned long long)((sm[0] + sm[1] + sm[2] + sm[3]) >> 20), (unsigned long long)(z1 >> 20), (unsigned long long)(z0 >> 20));
    }
    printf("%s t_guest_file_overflow：%d 项不符\n", bad ? "✗" : "✓", bad);
    return bad != 0;
}
