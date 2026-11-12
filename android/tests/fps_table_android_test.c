// #48 D2: the real FPS core (runtime/src/fps.c) on the real Android provider
// (native/fps_provider.c). Only the VM boundary is a fixture, and it follows the
// Android module layout (native/module.c): data/bss is shared backing that the
// checked write accepts; the key page is private (the alias is refused,
// -EOPNOTSUPP, as fps_write_integration_test asserts for private pages); any
// address outside the guest image is not guest memory (-EFAULT).
// A pointer-chain `w` row whose target lies outside the guest window must still
// go through the checked write, get its error and log red (review on #437): a
// later change that moved `w` rows to the host store would swallow that write.
// Host test only: no rewritten guest, no GPU, no device frame pacing.
#define S2A_LOGCAP_IMPL   // this test owns s2a_log_out (strong) to read the red lines
#include "../../runtime/src/native.h"
#include <assert.h>
#include <errno.h>
#include <math.h>
#include <stdatomic.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

S2A_TEST_MOD_TABLE(4); int g_nmod;
void s2a_fps_start(const char *dir); int s2a_fps_present_at(uint64_t now); void s2a_fps_set_enabled(int on);
int s2a_fps_session_stop(void); int s2a_fps_session_reset(void); int s2a_fps_available(void);
extern uint8_t *dm_fps_state;

enum { DATA = 0x4000, KEY = 0x8000, PATCH = 0xC000, TARGET = 0x5000, CHAIN = 0x5100 };
static uint8_t img[0x10000] __attribute__((aligned(0x4000)));
// Outside the guest image: the readonly copy still answers for it (it was mapped
// when read), the checked write then finds it gone and returns -EFAULT.
static uint32_t outside[4] = {30, 30, 30, 30};
static _Atomic int shared_writes, refused_writes, outside_writes, outside_efault, red_unwritable;
void s2a_log_out(int fd, const char *p, size_t n) {
    if (memmem(p, n, "【红】帧率表", strlen("【红】帧率表")) && memmem(p, n, "写不进", strlen("写不进"))) atomic_fetch_add(&red_unwritable, 1);
    ssize_t w = write(fd, p, n); (void)w;
}

const char *s2a_main_build_id(void) { return "1234abcd5678ef00aaaa"; }
int s2a_key_page_writable(module_t *m) { assert(m == &g_mod[0]); return 0; }
uint64_t plat_now_ns(void) { return 1000000000ull; }
static int shared(uint64_t a, uint64_t n) { uint64_t b = (uintptr_t)img; return a >= b + DATA && a + n <= b + KEY; }
static int is_outside(uint64_t a, uint64_t n) { uint64_t b = (uintptr_t)outside; return a >= b && a + n <= b + sizeof outside; }
int s2a_android_copy_guest_readonly(uint64_t address, void *out, uint64_t size) {
    if (!shared(address, size) && !is_outside(address, size)) return EFAULT;
    memcpy(out, (void *)(uintptr_t)address, (size_t)size); return 0;
}
int s2a_mem_write32_checked(uint64_t address, uint32_t value) {
    uint64_t b = (uintptr_t)img;
    if (is_outside(address, 4)) {   // reached only through the checked path; never stored
        atomic_fetch_add(&outside_writes, 1); atomic_fetch_add(&outside_efault, 1); (void)value;
        return -EFAULT;
    }
    if (!shared(address, 4)) {
        atomic_fetch_add(&refused_writes, 1);
        return address >= b && address < b + sizeof img ? -EOPNOTSUPP : -EFAULT;
    }
    __atomic_store_n((uint32_t *)(uintptr_t)address, value, __ATOMIC_RELAXED);
    atomic_fetch_add(&shared_writes, 1); return 0;
}

static float slot(int n) { float f; memcpy(&f, img + KEY + n * 8, 4); return f; }
static int32_t target(void) { return __atomic_load_n((int32_t *)(void *)(img + TARGET), __ATOMIC_RELAXED); }
static void wait_target(int32_t want, const char *why) {
    for (int i = 0; i < 300 && target() != want; i++) usleep(10000);
    if (target() != want) { fprintf(stderr, "FAIL %s: %d\n", why, target()); exit(1); }
}
#define CHECK(why, ok) do { if (!(ok)) { fprintf(stderr, "FAIL %s\n", why); exit(1); } } while (0)

int main(void) {
    module_t *m = &g_mod[g_nmod++];
    snprintf(m->name, sizeof m->name, "main"); m->base = img; m->size = sizeof img;
    m->ro_off = 0x2000; m->data_off = DATA; m->key_page_off = KEY; m->key_page_size = 0x4000; m->patch_off = PATCH;
    __atomic_store_n((int32_t *)(void *)(img + TARGET), 30, __ATOMIC_RELAXED);
    uint64_t chain = (uintptr_t)outside; memcpy(img + CHAIN, &chain, 8);
    char dir[] = "/tmp/s2a-fps-android-XXXXXX"; CHECK("temp dir", mkdtemp(dir) != NULL);
    char path[256]; snprintf(path, sizeof path, "%s/fps.tsv", dir);
    FILE *f = fopen(path, "w"); CHECK("open table", f != NULL);
    fputs("build 1234abcd5678ef00\n"
          "slot 2041 f32 2 1\n"                  // key-page slot read by rewritten code
          "speed 2040 0.5 2.0 2043\n"            // per-frame step slot + seconds slot, frame-step page
          "w main 0x5000 i32 60 off 30\n"        // game data variable: guest-memory write
          "w main 0x5100 i32 61 *0\n", f);       // pointer chain to a target outside the window
    fclose(f);
    unsetenv("S2A_FPS_TABLE"); unsetenv("S2A_FSTEP"); unsetenv("DM_PRESENT_INTERVAL");
    // 24a353e2 起 60 帧默认关、只有 S2A_FPS60=1 才开（runtime/src/fps.c fps_on_at_start）；本例测的是「开」这一侧
    setenv("S2A_FPS60", "1", 1);
    setenv("S2A_FPS_CAP", "0", 1);

    s2a_fps_start(dir);   // before the fix this aborts: the key-page slot write went through the checked guest write
    CHECK("table published", s2a_fps_available());
    CHECK("on: slot 2041 = 2 (rewritten code never reads 0)", lroundf(slot(2041)) == 2);
    CHECK("on: step slot starts at 1.0", lroundf(slot(2040) * 100) == 100);
    CHECK("on: seconds slot = 1/30", lroundf(slot(2043) * 3000) == 100);
    CHECK("frame-step page attached", dm_fps_state != NULL);
    float tgt; memcpy(&tgt, dm_fps_state, 4); CHECK("frame-step target 60", lroundf(tgt) == 60);
    uint64_t t = 5000000000ull; s2a_fps_present_at(t); s2a_fps_present_at(t += 16666667);
    CHECK("16.7 ms frame: step slot 0.5", lroundf(slot(2040) * 100) == 50);
    wait_target(60, "writer thread writes the game variable through the checked VM write");
    for (int i = 0; i < 300 && !atomic_load(&red_unwritable); i++) usleep(10000);
    CHECK("outside-window w row went through the checked write", atomic_load(&outside_writes) > 0);
    CHECK("outside-window w row got -EFAULT", atomic_load(&outside_efault) == atomic_load(&outside_writes));
    CHECK("outside-window w row logged red (not swallowed)", atomic_load(&red_unwritable) == 1);
    CHECK("outside-window target unchanged", outside[0] == 30);

    s2a_fps_set_enabled(0);
    CHECK("off: slot 2041 = off value 1", lroundf(slot(2041)) == 1);
    CHECK("off: step slot back to 1.0", lroundf(slot(2040) * 100) == 100);
    memcpy(&tgt, dm_fps_state, 4); CHECK("off: frame-step target 0", tgt == 0.0f);
    wait_target(30, "off writes the table's off value");

    CHECK("stop joins the writer", s2a_fps_session_stop() == 0);
    CHECK("reset", s2a_fps_session_reset() == 0);
    CHECK("guest data reached through the checked write", atomic_load(&shared_writes) > 0);
    CHECK("no host-page write was sent to the guest VM", atomic_load(&refused_writes) == 0);
    unlink(path); rmdir(dir);
    printf("fps table on the Android provider: key-page slots, step slot and frame-step page are host stores; "
           "game data goes through the checked write (%d writes)\n", atomic_load(&shared_writes));
    return 0;
}
