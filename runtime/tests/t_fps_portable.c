// Real fps.c writer + fake platform I/O: invalid pointer, valid write, and join.
// No game data. Synchronization is by condition variables, with bounded deadlines.
#include "../src/native.h"
#include <errno.h>
#include <pthread.h>
#include <stdatomic.h>
#include <time.h>
#include <unistd.h>

S2A_TEST_MOD_TABLE(64);
int g_nmod;
const char *s2a_main_build_id(void) { return "1234abcd5678ef00aaaa"; }
void s2a_fps_start(const char *dir);
int s2a_fps_session_stop(void);
int s2a_fps_session_reset(void);
void s2a_fps_set_enabled(int on);

#define TARGET_ADDR 0x12340000ull
// 多级指针链（11-02 补丁包 FPSLocker 转换）：img+0x1028 → CHAIN_A；*(CHAIN_A+8) = CHAIN_B；写 CHAIN_B+0x10。期望写入 61（表里的值），不经别的地址
#define CHAIN_A 0x55550000ull
#define CHAIN_B 0x66660000ull
static int chain_writes; static uint32_t chain_value = 7;
static pthread_mutex_t mu = PTHREAD_MUTEX_INITIALIZER;
static pthread_cond_t cv = PTHREAD_COND_INITIALIZER;
static int invalid_reads, writes, block_write, inside_write, stop_started, stop_returned, condition_reads, guest_writes, wrapped_reads;
static uint32_t value = 30;
static _Atomic int clock_calls;
static unsigned char img[0x4000] __attribute__((aligned(16)));
static void guest_bounds(uint64_t addr, size_t size) {
    uint64_t base = (uintptr_t)img;
    if (addr < base || addr - base > sizeof img - size) { fputs("FAIL invalid guest access\n", stderr); _Exit(87); }
}

int plat_mem_read32(uint64_t addr, uint32_t *out) {
    pthread_mutex_lock(&mu);
    if (addr == CHAIN_A + 8 || addr == CHAIN_A + 12 || addr == CHAIN_B + 0x10) {
        *out = addr == CHAIN_A + 8 ? (uint32_t)CHAIN_B : addr == CHAIN_A + 12 ? (uint32_t)(CHAIN_B >> 32) : chain_value;
        pthread_mutex_unlock(&mu); return 0; }
    if (addr != TARGET_ADDR) {
        if (addr == 8) wrapped_reads++;
        invalid_reads++;
        pthread_cond_broadcast(&cv);
        pthread_mutex_unlock(&mu);
        return EFAULT;
    }
    *out = value;
    pthread_mutex_unlock(&mu);
    return 0;
}
int plat_mem_write32(uint64_t addr, uint32_t v) {
    pthread_mutex_lock(&mu);
    if (addr == CHAIN_B + 0x10) { chain_value = v; chain_writes++; pthread_cond_broadcast(&cv); pthread_mutex_unlock(&mu); return 0; }
    if (addr != TARGET_ADDR) { pthread_mutex_unlock(&mu); return EFAULT; }
    inside_write = 1;
    pthread_cond_broadcast(&cv);
    while (block_write) pthread_cond_wait(&cv, &mu);
    value = v; writes++;
    inside_write = 0;
    pthread_cond_broadcast(&cv);
    pthread_mutex_unlock(&mu);
    return 0;
}
uint8_t plat_guest_load8(uint64_t addr) {
    guest_bounds(addr, 1);
    uint8_t v = __atomic_load_n((uint8_t *)(uintptr_t)addr, __ATOMIC_RELAXED);
    pthread_mutex_lock(&mu); condition_reads++; pthread_cond_broadcast(&cv); pthread_mutex_unlock(&mu);
    return v;
}
uint32_t plat_guest_load32(uint64_t addr) { guest_bounds(addr, 4); return __atomic_load_n((uint32_t *)(uintptr_t)addr, __ATOMIC_RELAXED); }
uint64_t plat_guest_load64(uint64_t addr) { guest_bounds(addr, 8); return __atomic_load_n((uint64_t *)(uintptr_t)addr, __ATOMIC_RELAXED); }
void plat_guest_store32(uint64_t addr, uint32_t v) {
    guest_bounds(addr, 4);
    __atomic_store_n((uint32_t *)(uintptr_t)addr, v, __ATOMIC_RELAXED);
    pthread_mutex_lock(&mu); guest_writes++; pthread_cond_broadcast(&cv); pthread_mutex_unlock(&mu);
}
int s2a_key_page_writable(module_t *m) { (void)m; return 0; }
uint64_t plat_now_ns(void) { atomic_fetch_add(&clock_calls, 1); return 1000000000ull; }
int plat_thread_name(const char *name) { (void)name; return 0; }
static struct timespec deadline_ms(int ms) {
    struct timespec t; clock_gettime(CLOCK_REALTIME, &t);
    t.tv_nsec += (long)(ms % 1000) * 1000000; t.tv_sec += ms / 1000 + t.tv_nsec / 1000000000;
    t.tv_nsec %= 1000000000; return t;
}
static void require(int ok, const char *why) { if (!ok) { fprintf(stderr, "FAIL %s\n", why); exit(1); } }
static void wait_flag(int *flag, const char *why) {
    struct timespec end = deadline_ms(3000);
    pthread_mutex_lock(&mu);
    while (!*flag) { int e = pthread_cond_timedwait(&cv, &mu, &end); if (e == ETIMEDOUT) break; require(e == 0, "condition wait"); }
    int got = *flag;
    pthread_mutex_unlock(&mu);
    require(got, why);
}
static void wait_writes_after(int before, const char *why) {
    struct timespec end = deadline_ms(3000);
    pthread_mutex_lock(&mu);
    while (writes <= before) { int e = pthread_cond_timedwait(&cv, &mu, &end); if (e == ETIMEDOUT) break; require(e == 0, "write wait"); }
    int got = writes > before;
    pthread_mutex_unlock(&mu);
    require(got, why);
}
static void *stopper(void *unused) {
    (void)unused;
    pthread_mutex_lock(&mu); stop_started = 1; pthread_cond_broadcast(&cv); pthread_mutex_unlock(&mu);
    require(s2a_fps_session_stop() == 0, "stop succeeds");
    pthread_mutex_lock(&mu); stop_returned = 1; pthread_cond_broadcast(&cv); pthread_mutex_unlock(&mu);
    return NULL;
}
int main(void) {
    require(plat_mem_write32(1, 7) != 0, "invalid write rejected without crashing");
    module_t *m = &g_mod[g_nmod++];
    snprintf(m->name, sizeof m->name, "main"); m->base = img; m->size = sizeof img;
    m->data_off = 0x1000; m->patch_off = 0x2000;
    __atomic_store_n((uint64_t *)(void *)(img + 0x1000), 1, __ATOMIC_RELAXED);
    __atomic_store_n((uint64_t *)(void *)(img + 0x1020), UINT64_MAX - 7, __ATOMIC_RELAXED);
    __atomic_store_n((uint64_t *)(void *)(img + 0x1028), CHAIN_A, __ATOMIC_RELAXED);
    char dir[] = "/tmp/s2a-fps-portable-XXXXXX"; require(mkdtemp(dir) != NULL, "temp dir");
    char path[256]; snprintf(path, sizeof path, "%s/fps.tsv", dir);
    FILE *f = fopen(path, "w"); require(f != NULL, "open table");
    fputs("build 1234abcd5678ef00\nw main 0x1000 i32 60 *0 off 25\nw main 0x1018 i32 77 if main 0x1010 u8 == 1\n"
          "w main 0x1020 i32 99 *0x10\n"
          "w main 0x1028 i32 61 *0x8*0x10\n"
          "w main 0xfffffffffffffffc i32 99\n"
          "w main 0x101c i32 99 if main 0xffffffffffffffff u8 == 1\n", f); fclose(f);
    unsetenv("S2A_FPS_TABLE"); setenv("S2A_FPS60", "1", 1);   /* 玩家开了（11-11 起默认原帧率） */ unsetenv("S2A_FPS_CAP");
    s2a_fps_start(dir);
    wait_flag(&chain_writes, "two-level pointer chain must reach CHAIN_B+0x10");
    pthread_mutex_lock(&mu); require(chain_value == 61, "chain row writes the table value 61"); pthread_mutex_unlock(&mu);
    wait_flag(&invalid_reads, "invalid address must use fake safe read and not crash");
    wait_flag(&condition_reads, "condition must be read");
    require(__atomic_load_n((uint32_t *)(void *)(img + 0x1018), __ATOMIC_RELAXED) == 0,
            "false byte condition must not write");
    __atomic_store_n(img + 0x1010, 1, __ATOMIC_RELAXED);
    wait_flag(&guest_writes, "true byte condition must write");
    require(__atomic_load_n((uint32_t *)(void *)(img + 0x1018), __ATOMIC_RELAXED) == 77,
            "true byte condition writes target");
    require(__atomic_load_n((uint32_t *)(void *)(img + 0x101c), __ATOMIC_RELAXED) == 0,
            "overflowed condition address must not admit its row");
    pthread_mutex_lock(&mu); require(value == 30 && writes == 0, "invalid address must not write"); require(wrapped_reads == 0, "wrapped dereference must not reach memory API"); pthread_mutex_unlock(&mu);
    __atomic_store_n((uint64_t *)(void *)(img + 0x1000), TARGET_ADDR, __ATOMIC_RELAXED);
    wait_flag(&writes, "valid target must be written through platform API");
    pthread_mutex_lock(&mu); require(value == 60, "target value"); value = 40; block_write = 1; pthread_mutex_unlock(&mu);
    wait_flag(&inside_write, "writer must enter the blocked write");
    pthread_t stopper_thread; require(pthread_create(&stopper_thread, NULL, stopper, NULL) == 0, "start stopper");
    wait_flag(&stop_started, "stopper did not start");
    pthread_mutex_lock(&mu);
    struct timespec end = deadline_ms(100);
    while (!stop_returned) { int e = pthread_cond_timedwait(&cv, &mu, &end); if (e == ETIMEDOUT) break; require(e == 0, "stop wait"); }
    require(!stop_returned, "stop must wait for active writer");
    block_write = 0; pthread_cond_broadcast(&cv); pthread_mutex_unlock(&mu);
    wait_flag(&stop_returned, "stop did not join writer");
    require(pthread_join(stopper_thread, NULL) == 0, "join caller");
    // A second session must start its own writer. Turning 60 fps off writes the
    // table's explicit off value (11-02: never the first value read, which was a
    // snapshot from before the game initialised the variable). Stop has returned
    // before the target is reused.
    require(s2a_fps_session_reset() == 0, "reset succeeds");
    pthread_mutex_lock(&mu); value = 12; int before = writes; pthread_mutex_unlock(&mu);
    s2a_fps_start(dir);
    wait_writes_after(before, "restart must create a new writer");
    pthread_mutex_lock(&mu); require(value == 60, "restart target value"); before = writes; pthread_mutex_unlock(&mu);
    s2a_fps_set_enabled(0);
    wait_writes_after(before, "off in restarted session must write the off value");
    pthread_mutex_lock(&mu); require(value == 25, "off writes the table's off value (25), not the value read at start (12)"); pthread_mutex_unlock(&mu);
    require(s2a_fps_session_stop() == 0, "stop succeeds");
    require(s2a_fps_session_reset() == 0, "final reset succeeds");
    unlink(path); rmdir(dir);
    puts("✓ t_fps_portable: safe I/O, two-level pointer chain, and joined stop");
    return 0;
}
