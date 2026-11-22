// source_store 宿主测试：SetShaders 期的真实字节在源内存被复用后仍然稳定；
// 按 key 查与 SetShaders 数组序号无关（VS/FS 分开绑定、数组顺序不同的基础）。
//
// F4.3/F4.2A 修订后的合同（2026-10-27）：
//   * keep 只接受“短 key = SHA-256(control‖code) 前 8 字节”的输入；不符就拒绝，不存可能误命中的条目。
//     同一短 key 已指向别的内容时，该 key 被标成歧义：之后按它的查找一律失败，不覆盖、不取最新。
//   * acquire 返回引用令牌，release 只认令牌；同 key 重新登记后，旧代的 release 不会误放新代。
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <pthread.h>
#include <sched.h>
#include <stdatomic.h>

#include "direct/sha256.h"
#include "direct/source_store.h"

// source_store 的失败日志出口在设备上由 hle_nvn 接到 logcat；宿主测试给空实现。
static int g_source_log_lines;
void s2a_source_log_line(const char *line) { (void)line; g_source_log_lines++; }

static int fails;
#define CHECK(cond, what) do { if (!(cond)) { printf("FAIL: %s\n", what); fails++; } } while (0)

// 生产口径的控制段：键第 2 代先把 [0x790,0x798)、[0x7d0,0x7e8) 落在 control_bytes 内的字节按 0 算（graphics/nvn/gfx/nvn/nvn_key.h）；这里按规则另写一遍，不调被测实现
static const uint8_t *key_control(const void *control, uint32_t control_bytes, uint8_t buf[0x880]) {
    memcpy(buf, control, control_bytes);
    for (uint32_t i = 0x790; i < 0x798 && i < control_bytes; i++) buf[i] = 0;
    for (uint32_t i = 0x7d0; i < 0x7e8 && i < control_bytes; i++) buf[i] = 0;
    return buf;
}
// 生产口径的短 key：SHA-256(control‖code) 的前 8 字节（与前端 keys_hash 同一字节顺序）。
static void make_key(const void *code, uint32_t code_bytes, const void *control, uint32_t control_bytes,
                     uint8_t out[8]) {
    s2a_sha256 c;
    uint8_t md[32];
    s2a_sha256_init(&c);
    uint8_t kc[0x880];
    s2a_sha256_update(&c, key_control(control, control_bytes, kc), control_bytes);
    s2a_sha256_update(&c, code, code_bytes);
    s2a_sha256_final(&c, md);
    memcpy(out, md, 8);
}

static void make_digest(const void *code, uint32_t code_bytes, const void *control, uint32_t control_bytes,
                        uint8_t out[32]) {
    s2a_sha256 c;
    s2a_sha256_init(&c);
    uint8_t kc[0x880];
    s2a_sha256_update(&c, key_control(control, control_bytes, kc), control_bytes);
    s2a_sha256_update(&c, code, code_bytes);
    s2a_sha256_final(&c, out);
}

static uint8_t g_code_a[0x200];   // 原始 code_a 的副本：用例会故意涂掉工作缓冲验证快照自持
static uint8_t g_ctl_a[S2A_SOURCE_CONTROL_BYTES];
static int s2a_source_identity_ok_for_test(const uint8_t key[8]) {
    uint8_t sha[32];
    uint32_t cb = 0, ctlb = 0;
    return s2a_source_identity(key, sha, &cb, &ctlb) == 0;
}

enum { PENDING_STRESS_ROUNDS = 12000 };
static uint8_t pending_patterns[2][S2A_SOURCE_CONTROL_BYTES];
static atomic_int pending_reader_ready;
static int pending_writer_failed, pending_reader_failed;
static unsigned pending_hits;

static void *pending_writer(void *unused) {
    (void)unused;
    while (!atomic_load(&pending_reader_ready)) sched_yield();
    for (unsigned i = 0; i < PENDING_STRESS_ROUNDS; i++) {
        if (s2a_source_hold_pending(90001, 2, pending_patterns[i & 1], S2A_SOURCE_CONTROL_BYTES))
            pending_writer_failed = 1;
        sched_yield();
        s2a_source_drop_pending_stage(90001, 2);
    }
    return NULL;
}

static void *pending_reader(void *unused) {
    (void)unused;
    for (unsigned i = 0; i < PENDING_STRESS_ROUNDS * 2; i++) {
        uint8_t copy[S2A_SOURCE_CONTROL_BYTES];
        uint32_t n = 0;
        if (s2a_source_pending_control_copy(90001, 2, copy, sizeof copy, &n)) {
            pending_hits++;
            if (n != sizeof copy || (memcmp(copy, pending_patterns[0], sizeof copy) &&
                                    memcmp(copy, pending_patterns[1], sizeof copy)))
                pending_reader_failed = 1;
        }
        atomic_store(&pending_reader_ready, 1);
    }
    return NULL;
}

static void pending_stress(void) {
    memset(pending_patterns[0], 0x35, sizeof pending_patterns[0]);
    memset(pending_patterns[1], 0xca, sizeof pending_patterns[1]);
    CHECK(s2a_source_hold_pending(90001, 2, pending_patterns[0], S2A_SOURCE_CONTROL_BYTES) == 0,
          "seed pending stress");
    pthread_t writer, reader;
    int wr = pthread_create(&writer, NULL, pending_writer, NULL);
    int rd = pthread_create(&reader, NULL, pending_reader, NULL);
    CHECK(wr == 0 && rd == 0, "start pending stress threads");
    if (rd != 0) atomic_store(&pending_reader_ready, 1);
    if (wr == 0) CHECK(pthread_join(writer, NULL) == 0, "join pending writer");
    if (rd == 0) CHECK(pthread_join(reader, NULL) == 0, "join pending reader");
    CHECK(!pending_writer_failed && !pending_reader_failed && pending_hits > 0,
          "concurrent pending copies contain one complete pattern");
    s2a_source_drop_pending(90001);
    printf("pending stress: %u writer rounds, %u reader rounds, %u hits\n",
           PENDING_STRESS_ROUNDS, PENDING_STRESS_ROUNDS * 2, pending_hits);
}

int main(void) {
    pending_stress();
    enum { CODE_BYTES = 0x200 };
    static uint8_t code_a[CODE_BYTES], code_b[CODE_BYTES], ctl_a[S2A_SOURCE_CONTROL_BYTES], ctl_b[S2A_SOURCE_CONTROL_BYTES];
    for (int i = 0; i < CODE_BYTES; i++) code_a[i] = (uint8_t)(i * 7 + 1);
    memcpy(g_code_a, code_a, CODE_BYTES);
    for (int i = 0; i < CODE_BYTES; i++) code_b[i] = (uint8_t)(i * 13 + 5);
    for (unsigned i = 0; i < S2A_SOURCE_CONTROL_BYTES; i++) { ctl_a[i] = (uint8_t)(i * 3u); ctl_b[i] = (uint8_t)(0xffu - i); }
    // 让控制段 +0x704 的 code 长度字段与真实 code 一致（与实际生产者同样按真实值存）。
    uint32_t n = CODE_BYTES;
    memcpy(ctl_a + 0x704, &n, 4);
    memcpy(ctl_b + 0x704, &n, 4);
    // c1 的真实范围：+0x700 起点 / +0x704 终点，偏移相对 code 起点（tail = code + control）。
    // 取 code 尾部 0x40 字节 + control 开头 0x40 字节，验证跨界切片。
    uint32_t c1_begin = CODE_BYTES - 0x40, c1_end = CODE_BYTES + 0x40;
    memcpy(ctl_a + 0x700, &c1_begin, 4); memcpy(ctl_a + 0x704, &c1_end, 4);
    memcpy(ctl_b + 0x700, &c1_begin, 4); memcpy(ctl_b + 0x704, &c1_end, 4);
    memcpy(g_ctl_a, ctl_a, sizeof g_ctl_a);
    uint8_t key_a[8], key_b[8], sha_a[32], sha_b[32];
    make_key(code_a, CODE_BYTES, ctl_a, S2A_SOURCE_CONTROL_BYTES, key_a);
    make_key(code_b, CODE_BYTES, ctl_b, S2A_SOURCE_CONTROL_BYTES, key_b);
    make_digest(code_a, CODE_BYTES, ctl_a, S2A_SOURCE_CONTROL_BYTES, sha_a);
    make_digest(code_b, CODE_BYTES, ctl_b, S2A_SOURCE_CONTROL_BYTES, sha_b);
    CHECK(memcmp(key_a, sha_a, 8) == 0, "test key derives from the same digest as production");
    CHECK(memcmp(key_a, key_b, 8) != 0, "fixtures have distinct keys");

    // 真实 SetShaders 顺序：FS 在数组前面、VS 在后面。
    CHECK(s2a_source_keep(key_b, 0, code_b, CODE_BYTES, ctl_b, S2A_SOURCE_CONTROL_BYTES) == 0, "keep fs at index 0");
    CHECK(s2a_source_keep(key_a, 1, code_a, CODE_BYTES, ctl_a, S2A_SOURCE_CONTROL_BYTES) == 0, "keep vs at index 1");

    // 源内存被复用（游戏在 SetShaders 返回后重写同一块内存）：快照必须不受影响。
    memset(code_a, 0xaa, sizeof code_a);
    memset(code_b, 0xbb, sizeof code_b);
    memset(ctl_a, 0xcc, sizeof ctl_a);
    memset(ctl_b, 0xdd, sizeof ctl_b);

    struct s2a_source_entry_view v;
    memset(&v, 0, sizeof v);
    CHECK(s2a_source_get_key(key_a, &v) == 1, "find vs by key");
    CHECK(v.c1 && v.c1_bytes == 0x80, "c1 uses the control-declared real range (0x80 bytes)");
    if (v.c1 && v.c1_bytes == 0x80) {
        int c1_ok = 1;
        for (unsigned i = 0; i < 0x40; i++) {
            if (v.c1[i] != (uint8_t)((CODE_BYTES - 0x40 + i) * 7 + 1)) c1_ok = 0;
            if (v.c1[0x40 + i] != (uint8_t)(i * 3u)) c1_ok = 0;   // control 开头，跳过被 0x700/0x704 覆盖的字节
        }
        CHECK(c1_ok, "c1 spans code tail and control head with the declared offsets");
    }
    CHECK(v.complete && v.code_bytes == CODE_BYTES && v.control_bytes == S2A_SOURCE_CONTROL_BYTES, "vs complete");
    CHECK(v.array_index == 1, "vs keeps its real SetShaders index");
    CHECK(memcmp(v.content_sha, sha_a, 32) == 0, "capture-time full digest is exposed unchanged");
    CHECK(v.ref == 0, "a borrowed view carries no reference token");
    CHECK(memcmp(v.code, code_a, CODE_BYTES) != 0, "vs snapshot is not the scribbled buffer");
    int good = 1;
    for (int i = 0; i < CODE_BYTES; i++) if (v.code[i] != (uint8_t)(i * 7 + 1)) good = 0;
    CHECK(good, "vs code bytes stable after the source buffer was reused");
    good = 1;
    for (unsigned i = 0; i < S2A_SOURCE_CONTROL_BYTES; i++) {
        if (i >= 0x700 && i < 0x708) continue;   // c1 起点/终点字段（测试里被真实值覆盖）
        if (v.control[i] != (uint8_t)(i * 3u)) good = 0;
    }
    CHECK(good, "vs control bytes stable after the source buffer was reused");

    memset(&v, 0, sizeof v);
    CHECK(s2a_source_get_key(key_b, &v) == 1, "find fs by key");
    CHECK(v.array_index == 0, "fs keeps its real SetShaders index");
    good = 1;
    for (int i = 0; i < CODE_BYTES; i++) if (v.code[i] != (uint8_t)(i * 13 + 5)) good = 0;
    CHECK(good, "fs code bytes stable");

    // 合并后的阶段顺序（vs 在前）与 SetShaders 数组序号不同：按 key 查仍然命中。
    memset(&v, 0, sizeof v);
    CHECK(s2a_source_get_key(key_a, &v) == 1, "vs found regardless of merged stage order");
    memset(&v, 0, sizeof v);
    CHECK(s2a_source_get(key_a, 1, &v) == 1, "get(key, real index) hits");
    CHECK(s2a_source_get(key_a, 0, &v) == 0, "get(key, wrong index) does not fabricate a stage");

    uint32_t entries = 0, bytes = 0, dropped = 0;
    s2a_source_stats(&entries, &bytes, &dropped);
    CHECK(entries == 2, "two snapshots retained");
    CHECK(bytes == 2u * (CODE_BYTES + S2A_SOURCE_CONTROL_BYTES + 0x80u),
          "byte budget counts code + control + c1 for both snapshots");

    // ---- 身份接口：完整摘要 + 真实长度，缺源准确失败 ----
    {
        uint8_t sha[32];
        uint32_t cb = 0, ctlb = 0;
        CHECK(s2a_source_identity(key_a, sha, &cb, &ctlb) == 0, "identity available for a unique key");
        CHECK(!memcmp(sha, sha_a, 32) && cb == CODE_BYTES && ctlb == S2A_SOURCE_CONTROL_BYTES,
              "identity returns the captured digest and real lengths");
        uint8_t missing[8] = { 0xde, 0xad, 0xbe, 0xef, 9, 9, 9, 9 };
        CHECK(s2a_source_identity(missing, sha, &cb, &ctlb) != 0, "missing source has no identity");
    }

    // ---- 内容代际：只表示 key→内容 映射的变化，不能被“同内容重登记”刷掉 ----
    {
        uint8_t ctl_clean[S2A_SOURCE_CONTROL_BYTES];
        memset(ctl_clean, 0x2b, sizeof ctl_clean);
        memcpy(ctl_clean + 0x700, &c1_begin, 4);
        memcpy(ctl_clean + 0x704, &c1_end, 4);
        make_key(g_code_a, CODE_BYTES, ctl_clean, S2A_SOURCE_CONTROL_BYTES, key_a);
        make_digest(g_code_a, CODE_BYTES, ctl_clean, S2A_SOURCE_CONTROL_BYTES, sha_a);
        s2a_source_clear();
        CHECK(s2a_source_keep(key_a, 1, g_code_a, CODE_BYTES, ctl_clean, S2A_SOURCE_CONTROL_BYTES) == 0,
              "register content for the epoch checks");
        uint64_t e0 = s2a_source_epoch();
        CHECK(s2a_source_keep(key_a, 1, g_code_a, CODE_BYTES, ctl_clean, S2A_SOURCE_CONTROL_BYTES) == 0,
              "same-content re-registration succeeds");
        CHECK(s2a_source_epoch() == e0, "same-content re-registration does not advance the source epoch");
        uint8_t fresh[8];
        static uint8_t ctl_fresh[S2A_SOURCE_CONTROL_BYTES];
        memset(ctl_fresh, 0x37, sizeof ctl_fresh);
        memcpy(ctl_fresh + 0x700, &c1_begin, 4);
        memcpy(ctl_fresh + 0x704, &c1_end, 4);
        make_key(code_b, CODE_BYTES, ctl_fresh, S2A_SOURCE_CONTROL_BYTES, fresh);
        CHECK(s2a_source_keep(fresh, 0, code_b, CODE_BYTES, ctl_fresh, S2A_SOURCE_CONTROL_BYTES) == 0,
              "new key registers");
        CHECK(s2a_source_epoch() > e0, "a new key->content mapping advances the source epoch");
        s2a_source_clear();
    }

    // ---- 反例：同一拼接摘要、不同 control/code 切分必须按不同内容处理 ----
    {
        // control 0x850 + code 0x130 与 control 0x880 + code 0x100 的拼接字节可以完全相同，
        // 但请求体（两个 base64 字段）不同。短 key 只能定位，不能证明内容相同。
        static uint8_t split_code[0x130], split_ctl[0x880];
        for (unsigned i = 0; i < sizeof split_code; i++) split_code[i] = (uint8_t)(0x60u + i * 3u);
        memset(split_ctl, 0x22, 0x850);
        memcpy(split_ctl + 0x850, split_code, 0x30);      // 后 0x30 字节来自 code 的前缀
        uint32_t ncode = sizeof split_code;
        memcpy(split_ctl + 0x700, &c1_begin, 4);
        memcpy(split_ctl + 0x704, &c1_end, 4);
        uint8_t split_key[8];
        // 两段拼接 = ctl[0..0x850) ‖ code[0..0x130)，与 ctl[0..0x880) ‖ code[0x30..0x130) 相同。
        make_key(split_code, sizeof split_code, split_ctl, 0x850, split_key);
        s2a_source_clear();
        CHECK(s2a_source_keep(split_key, 0, split_code, sizeof split_code, split_ctl, 0x850) == 0,
              "first split is stored");
        CHECK(s2a_source_keep(split_key, 0, split_code + 0x30, sizeof split_code - 0x30, split_ctl, 0x880) != 0,
              "same concatenated digest with a different control/code split is rejected");
        uint8_t ident_sha[32];
        uint32_t cb = 0, ctlb = 0;
        CHECK(s2a_source_identity(split_key, ident_sha, &cb, &ctlb) != 0,
              "an ambiguous split leaves no usable content identity");
        // 歧义 key 不能靠“重新登记原始内容”复活：那会清掉 ambiguous 标记却不推进代际。
        CHECK(s2a_source_keep(split_key, 0, split_code, sizeof split_code, split_ctl, 0x850) != 0,
              "re-registering the original content cannot revive an ambiguous key");
        CHECK(s2a_source_identity(split_key, ident_sha, &cb, &ctlb) != 0,
              "the ambiguous key stays unresolvable after a rejected revival attempt");
        (void)ncode;
        s2a_source_clear();
    }

    // ---- 淘汰推进内容代际：P1 不能绕过“完整路径应报缺源” ----
    {
        s2a_source_clear();
        // 先放一条“会被淘汰”的小条目。
        uint8_t old_key[8], old_ctl[S2A_SOURCE_CONTROL_BYTES];
        memset(old_ctl, 0x44, sizeof old_ctl);
        memcpy(old_ctl + 0x700, &c1_begin, 4);
        memcpy(old_ctl + 0x704, &c1_end, 4);
        make_key(g_code_a, CODE_BYTES, old_ctl, S2A_SOURCE_CONTROL_BYTES, old_key);
        CHECK(s2a_source_keep(old_key, 0, g_code_a, CODE_BYTES, old_ctl, S2A_SOURCE_CONTROL_BYTES) == 0,
              "store the oldest entry");
        static uint8_t huge[256u * 1024u];
        static uint8_t hctl[300][S2A_SOURCE_CONTROL_BYTES];
        memset(huge, 0x6b, sizeof huge);
        uint64_t e_before = s2a_source_epoch();
        int n = 0;
        for (; n < 300; n++) {
            memset(hctl[n], (uint8_t)(0xa0 + n), sizeof hctl[n]);
            memcpy(hctl[n] + 0x700, &c1_begin, 4);
            memcpy(hctl[n] + 0x704, &c1_end, 4);
            uint8_t k[8];
            make_key(huge, sizeof huge, hctl[n], S2A_SOURCE_CONTROL_BYTES, k);
            if (s2a_source_keep(k, 1, huge, sizeof huge, hctl[n], S2A_SOURCE_CONTROL_BYTES) != 0) break;
        }
        CHECK(n > 240, "fill the store close to its byte budget");
        CHECK(s2a_source_epoch() > e_before, "eviction advances the source epoch");
        CHECK(s2a_source_identity(old_key, (uint8_t[32]){0}, NULL, NULL) != 0,
              "the evicted key is no longer resolvable (memo must not outlive it)");
        s2a_source_clear();
    }

    // ---- 反例：短 key 与内容不符不得进入存储 ----
    {
        // 先让 key_a 真的指向 A 的内容，否则这里只是在测“缺源”，测不到歧义。
        make_key(g_code_a, CODE_BYTES, g_ctl_a, S2A_SOURCE_CONTROL_BYTES, key_a);
        s2a_source_clear();
        CHECK(s2a_source_keep(key_a, 1, g_code_a, CODE_BYTES, g_ctl_a, S2A_SOURCE_CONTROL_BYTES) == 0,
              "register A before forcing a same-key conflict");
        CHECK(s2a_source_identity_ok_for_test(key_a), "A is resolvable before the conflict");
        uint64_t rejected_before = s2a_source_rejected();
        // 用 A 的 key 登记 B 的内容（强制“同短 key 不同内容”）。
        CHECK(s2a_source_keep(key_a, 1, code_b, CODE_BYTES, ctl_b, S2A_SOURCE_CONTROL_BYTES) != 0,
              "keep rejects a short key that is not this content's digest prefix");
        CHECK(s2a_source_rejected() == rejected_before + 1, "rejection is counted");
        // 该 key 已经指向别的内容：之后按它查找必须失败，不能“取最新”也不能继续返回 A。
        memset(&v, 0, sizeof v);
        CHECK(s2a_source_get_key(key_a, &v) == 0, "ambiguous key is no longer resolvable (no silent reuse)");
        CHECK(s2a_source_acquire(key_a, &v) == 0, "ambiguous key cannot be pinned either");
        uint8_t sha[32];
        uint32_t cb = 0, ctlb = 0;
        CHECK(s2a_source_identity(key_a, sha, &cb, &ctlb) != 0, "ambiguous key has no content identity");
        // 冲突登记推进源代际：P1 备忘不能沿用冲突前的条目。
        CHECK(s2a_source_epoch() > 0, "source epoch advances on a conflicting registration");
    }

    // ---- F4.2 生命周期：引用期间不淘汰/不释放；release 只认 acquire 的令牌 ----
    for (int i = 0; i < CODE_BYTES; i++) code_a[i] = (uint8_t)(i * 7 + 1);
    memcpy(g_code_a, code_a, CODE_BYTES);
    for (int i = 0; i < CODE_BYTES; i++) code_b[i] = (uint8_t)(i * 13 + 5);
    for (unsigned i = 0; i < S2A_SOURCE_CONTROL_BYTES; i++) { ctl_a[i] = (uint8_t)(i * 3u); ctl_b[i] = (uint8_t)(0xffu - i); }
    memcpy(ctl_a + 0x700, &c1_begin, 4);
    memcpy(ctl_a + 0x704, &c1_end, 4);
    memcpy(ctl_b + 0x700, &c1_begin, 4);
    memcpy(ctl_b + 0x704, &c1_end, 4);
    make_key(code_a, CODE_BYTES, ctl_a, S2A_SOURCE_CONTROL_BYTES, key_a);
    make_key(code_b, CODE_BYTES, ctl_b, S2A_SOURCE_CONTROL_BYTES, key_b);
    make_digest(code_a, CODE_BYTES, ctl_a, S2A_SOURCE_CONTROL_BYTES, sha_a);
    s2a_source_clear();
    CHECK(s2a_source_keep(key_a, 1, code_a, CODE_BYTES, ctl_a, S2A_SOURCE_CONTROL_BYTES) == 0, "keep pinned source");
    struct s2a_source_entry_view held;
    memset(&held, 0, sizeof held);
    CHECK(s2a_source_acquire(key_a, &held) == 1, "acquire pins the snapshot");
    CHECK(held.ref != 0, "acquire returns a generation token");
    CHECK(held.code && held.control, "pinned view exposes the bytes");
    uint64_t token_old = held.ref;
    // 同 key、同内容再次登记（游戏每帧重新 SetShaders 的常见形态）：旧条目被引用的那份不能被顶掉。
    CHECK(s2a_source_keep(key_a, 1, code_a, CODE_BYTES, ctl_a, S2A_SOURCE_CONTROL_BYTES) == 0,
          "re-register the same content under the same key");
    memset(&v, 0, sizeof v);
    CHECK(s2a_source_acquire(key_a, &v) == 1 && v.ref != token_old, "new registration gets its own token");
    uint64_t token_new = v.ref;
    s2a_source_clear();
    CHECK(s2a_source_get_key(key_a, &v) == 0, "cleared snapshot is no longer findable");
    CHECK(s2a_source_acquire(key_a, &v) == 0, "cleared snapshot cannot be acquired again");
    good = 1;
    for (int i = 0; i < CODE_BYTES; i++) if (held.code[i] != (uint8_t)(i * 7 + 1)) good = 0;
    CHECK(good, "pinned bytes stay valid across clear()");
    s2a_source_keep(key_b, 0, code_b, CODE_BYTES, ctl_b, S2A_SOURCE_CONTROL_BYTES);
    s2a_source_stats(&entries, &bytes, &dropped);
    CHECK(bytes >= CODE_BYTES + S2A_SOURCE_CONTROL_BYTES, "retired pinned bytes are still accounted");
    uint32_t bytes_before = bytes;
    // 反例（旧实现按 key 找最新条目）：释放旧令牌必须回收当初 acquire 的那一代，而不是最新那代。
    s2a_source_release(token_old);
    s2a_source_stats(&entries, &bytes, &dropped);
    CHECK(bytes == bytes_before - (CODE_BYTES + S2A_SOURCE_CONTROL_BYTES + 0x80u),
          "release(token) frees the acquired generation, not the newest one");
    // 新代仍然被引用：它的字节不能随旧的释放一起回收。
    CHECK(s2a_source_get_key(key_b, &v) == 1, "the second registration is still owned by its own pin");
    s2a_source_release(token_new);
    s2a_source_stats(&entries, &bytes, &dropped);
    CHECK(bytes < bytes_before - (CODE_BYTES + S2A_SOURCE_CONTROL_BYTES + 0x80u),
          "releasing the second token frees the re-registered generation");
    // 重复释放同一令牌不得多减引用或释放别人。
    s2a_source_release(token_new);
    s2a_source_stats(&entries, &bytes, &dropped);
    CHECK(entries >= 1, "double release does not corrupt the store");

    // 引用中的条目不参与字节淘汰：塞满预算后仍能读回。
    s2a_source_clear();
    static uint8_t big[256u * 1024u];
    memset(big, 0x5a, sizeof big);
    uint8_t key_pin[8] = { 0xde, 0xad, 0xbe, 0xef, 1, 2, 3, 4 };
    uint8_t ctl_big[S2A_SOURCE_CONTROL_BYTES];
    memset(ctl_big, 0x21, sizeof ctl_big);
    memcpy(ctl_big + 0x700, &c1_begin, 4);
    memcpy(ctl_big + 0x704, &c1_end, 4);
    make_key(code_a, CODE_BYTES, ctl_big, S2A_SOURCE_CONTROL_BYTES, key_pin);
    CHECK(s2a_source_keep(key_pin, 0, code_a, CODE_BYTES, ctl_big, S2A_SOURCE_CONTROL_BYTES) == 0,
          "keep the pinned oldest");
    CHECK(s2a_source_acquire(key_pin, &held) == 1, "pin the oldest entry");
    uint8_t keys[300][8];
    static uint8_t bigctl[300][S2A_SOURCE_CONTROL_BYTES];
    for (int i = 0; i < 300; i++) {
        memset(bigctl[i], (uint8_t)(i * 5), S2A_SOURCE_CONTROL_BYTES);
        memcpy(bigctl[i] + 0x700, &c1_begin, 4);
        memcpy(bigctl[i] + 0x704, &c1_end, 4);
        make_key(big, sizeof big, bigctl[i], S2A_SOURCE_CONTROL_BYTES, keys[i]);
        if (s2a_source_keep(keys[i], 1, big, sizeof big, bigctl[i], S2A_SOURCE_CONTROL_BYTES) != 0) break;
    }
    memset(&v, 0, sizeof v);
    CHECK(s2a_source_get_key(key_pin, &v) == 1 && v.code && !memcmp(v.code, code_a, CODE_BYTES),
          "pinned oldest survives byte-budget eviction");
    s2a_source_stats(&entries, &bytes, &dropped);
    CHECK(bytes <= S2A_SOURCE_MAX_BYTES, "budget stays bounded while a pin is held");
    s2a_source_release(held.ref);
    s2a_source_clear();

    // ---- program 生命周期 pin：活 program 引用的源不参与淘汰；解 pin 后可淘汰 ----
    {
        s2a_source_clear();
        // 先存一条小条目并 pin（模拟 nvnProgramSetShaders 存源时的 pin）。
        uint8_t ctl_pin[S2A_SOURCE_CONTROL_BYTES];
        memset(ctl_pin, 0x2e, sizeof ctl_pin);
        memcpy(ctl_pin + 0x700, &c1_begin, 4);
        memcpy(ctl_pin + 0x704, &c1_end, 4);
        uint8_t key_pin2[8], sha_pin[32];
        struct s2a_source_pin_ref pin_ref;
        make_key(g_code_a, CODE_BYTES, ctl_pin, S2A_SOURCE_CONTROL_BYTES, key_pin2);
        make_digest(g_code_a, CODE_BYTES, ctl_pin, S2A_SOURCE_CONTROL_BYTES, sha_pin);
        CHECK(s2a_source_keep(key_pin2, 0, g_code_a, CODE_BYTES, ctl_pin, S2A_SOURCE_CONTROL_BYTES) == 0,
              "keep a source before the program pin");
        CHECK(s2a_source_pin_key(key_pin2, &pin_ref) == 0 && !memcmp(pin_ref.sha, sha_pin, 32),
              "program pin returns the full content_sha identity");
        // 同一 program 再次 SetShaders 同一内容：复用被 pin 的条目，不替换字节、不产生新代。
        CHECK(s2a_source_keep(key_pin2, 0, g_code_a, CODE_BYTES, ctl_pin, S2A_SOURCE_CONTROL_BYTES) == 0,
              "re-registering the same content while program-pinned succeeds");
        {
            struct s2a_source_pin_stats again;
            s2a_source_pin_stats(&again);
            CHECK(again.pinned_entries == 1 && again.pins == 1, "re-registration keeps exactly one program pin");
        }
        // 用 256 KB 大条目把 64 MiB 字节预算填爆：被 pin 的小条目必须留下。
        static uint8_t pin_fill[300][8];
        static uint8_t pin_fill_ctl[300][S2A_SOURCE_CONTROL_BYTES];
        int filled = 0;
        for (; filled < 300; filled++) {
            memset(pin_fill_ctl[filled], (uint8_t)(0x80 + filled), S2A_SOURCE_CONTROL_BYTES);
            memcpy(pin_fill_ctl[filled] + 0x700, &c1_begin, 4);
            memcpy(pin_fill_ctl[filled] + 0x704, &c1_end, 4);
            make_key(big, sizeof big, pin_fill_ctl[filled], S2A_SOURCE_CONTROL_BYTES, pin_fill[filled]);
            if (s2a_source_keep(pin_fill[filled], 1, big, sizeof big, pin_fill_ctl[filled],
                                S2A_SOURCE_CONTROL_BYTES) != 0) break;
        }
        CHECK(filled > 240, "fill past the byte budget with a program pin held");
        struct s2a_source_pin_stats ps;
        s2a_source_pin_stats(&ps);
        CHECK(ps.pinned_entries == 1 && ps.pins == 1, "exactly the program-pinned source is reported pinned");
        CHECK(ps.evict_skipped > 0, "eviction skipped the pinned entry");
        CHECK(ps.keep_over_budget == 0, "evictable entries exist: the soft budget holds, nothing is let through over it");
        CHECK(s2a_source_identity(key_pin2, (uint8_t[32]){0}, NULL, NULL) == 0,
              "a program-pinned source survives byte-budget eviction");
        // 模拟 program 销毁/换 SetShaders：解 pin 后该条目回到可淘汰集合。
        s2a_source_unpin_ref(&pin_ref);
        s2a_source_pin_stats(&ps);
        CHECK(ps.pinned_entries == 0 && ps.pins == 0, "unpin clears the program pin");
        uint8_t extra_key[8], extra_ctl[S2A_SOURCE_CONTROL_BYTES];
        memset(extra_ctl, 0x91, sizeof extra_ctl);
        memcpy(extra_ctl + 0x700, &c1_begin, 4);
        memcpy(extra_ctl + 0x704, &c1_end, 4);
        make_key(big, sizeof big, extra_ctl, S2A_SOURCE_CONTROL_BYTES, extra_key);
        CHECK(s2a_source_keep(extra_key, 1, big, sizeof big, extra_ctl, S2A_SOURCE_CONTROL_BYTES) == 0,
              "after unpin the store can evict again");
        CHECK(s2a_source_identity(key_pin2, (uint8_t[32]){0}, NULL, NULL) != 0,
              "the unpinned source is the oldest and gets evicted");
        s2a_source_clear();
    }

    // ---- 源条数超过未 pin 容量（MAX_ENTRIES）且全部被活 program pin：
    //      pin 走额外槽位、不淘汰被引用者；总槽位也满后 keep 准确失败。 ----
    {
        s2a_source_clear();
        enum { TOTAL = S2A_SOURCE_MAX_ENTRIES + S2A_SOURCE_MAX_PINNED };
        static uint8_t tiny_ctl[TOTAL][S2A_SOURCE_CONTROL_MIN];
        static uint8_t tiny_key[TOTAL][8];
        static struct s2a_source_pin_ref tiny_ref[TOTAL];
        uint8_t tiny_code = 0x5a;
        int stored = 0;
        for (; stored < TOTAL; stored++) {
            memset(tiny_ctl[stored], 0x33, sizeof tiny_ctl[stored]);
            uint32_t unique = (uint32_t)stored;
            memcpy(tiny_ctl[stored] + 0x10, &unique, 4);   // 每条内容不同，避免同一短 key 重复
            uint32_t ncode = 1;
            memcpy(tiny_ctl[stored] + 0x704, &ncode, 4);   // code 长度字段（c1 范围保持 0 → 无 c1）
            make_key(&tiny_code, 1, tiny_ctl[stored], sizeof tiny_ctl[stored], tiny_key[stored]);
            if (s2a_source_keep(tiny_key[stored], (uint32_t)(stored % 6), &tiny_code, 1,
                                tiny_ctl[stored], sizeof tiny_ctl[stored]) != 0) break;
            if (s2a_source_pin_key(tiny_key[stored], &tiny_ref[stored]) != 0) break;
        }
        CHECK(stored == TOTAL, "fill the unpinned cap and the pinned extra slots, pinning each");
        struct s2a_source_pin_stats ps;
        uint8_t overflow_key[8], overflow_ctl[S2A_SOURCE_CONTROL_MIN], overflow_code = 0x7e;
        memset(overflow_ctl, 0xd1, sizeof overflow_ctl);
        uint32_t ncode = 1;
        memcpy(overflow_ctl + 0x704, &ncode, 4);
        make_key(&overflow_code, 1, overflow_ctl, sizeof overflow_ctl, overflow_key);
        CHECK(s2a_source_keep(overflow_key, 1, &overflow_code, 1, overflow_ctl, sizeof overflow_ctl) != 0,
              "all slots pinned: keep fails instead of evicting a live program's source");
        CHECK(s2a_source_identity(tiny_key[0], (uint8_t[32]){0}, NULL, NULL) == 0,
              "the oldest pinned entry is still intact after the failed keep");
        s2a_source_pin_stats(&ps);
        CHECK(ps.pinned_entries == TOTAL && ps.pins == TOTAL,
              "all live-program pins are accounted beyond the unpinned cap");
        CHECK(ps.keep_fail_slots >= 1 && g_source_log_lines >= 1,
              "slot exhaustion is attributed and logs a failure reason");
        CHECK(ps.pin_misses == 0, "no pin failed while filling the store");
        // 模拟 program 销毁：只解最旧一条，下一次 keep 必须能淘汰它。
        s2a_source_unpin_ref(&tiny_ref[0]);
        CHECK(s2a_source_keep(overflow_key, 1, &overflow_code, 1, overflow_ctl, sizeof overflow_ctl) == 0,
              "after one program is destroyed its source becomes evictable");
        CHECK(s2a_source_identity(tiny_key[0], (uint8_t[32]){0}, NULL, NULL) != 0,
              "the destroyed program's source was the eviction victim");
        // 清理：clear 会 retire 仍被 pin 的条目，再逐条解 pin 回收。
        s2a_source_clear();
        for (int i = 1; i < stored; i++) s2a_source_unpin_ref(&tiny_ref[i]);
        s2a_source_pin_stats(&ps);
        CHECK(ps.pins == 0 && ps.pinned_entries == 0, "all program pins released");
    }

    // ---- 字节预算只约束可淘汰的条目（#1622）：活 program 把软预算占满后，新来的源仍收，直到字节安全阀 ----
    //      原先 keep 在「可淘汰的没有了」时直接失败：一款游戏进标题 3D 时 5,711 个活程序恰好占满 64 MiB，
    //      之后注册的 123 个程序存不进去（每笔用到它们的绘制都报 source_snapshot_missing）。
    {
        s2a_source_clear();
        enum { OV_MAX = (int)(S2A_SOURCE_HARD_BYTES / (200u * 1024u)) + 16 };
        static uint8_t ov_ctl[OV_MAX][S2A_SOURCE_CONTROL_BYTES];
        static uint8_t ov_key[OV_MAX][8];
        static struct s2a_source_pin_ref ov_ref[OV_MAX];
        struct s2a_source_pin_stats ps0, ps;
        s2a_source_pin_stats(&ps0);
        uint32_t en = 0, by = 0, dr0 = 0, dr = 0;
        s2a_source_stats(&en, &by, &dr0);
        int logs0 = g_source_log_lines, logs_mid = -1, stored = 0, first_over = -1;
        for (; stored < OV_MAX; stored++) {   // 每条 256 KiB code：存一条、立刻 pin 一条（同 nvnProgramSetShaders 存源即 pin）
            memset(ov_ctl[stored], (uint8_t)(0x40 + stored), S2A_SOURCE_CONTROL_BYTES);
            uint32_t uniq = (uint32_t)stored;
            memcpy(ov_ctl[stored] + 0x10, &uniq, 4);   // 每条内容不同，不被同内容复用
            memcpy(ov_ctl[stored] + 0x700, &c1_begin, 4);
            memcpy(ov_ctl[stored] + 0x704, &c1_end, 4);
            make_key(big, sizeof big, ov_ctl[stored], S2A_SOURCE_CONTROL_BYTES, ov_key[stored]);
            if (s2a_source_keep(ov_key[stored], 1, big, sizeof big, ov_ctl[stored], S2A_SOURCE_CONTROL_BYTES) != 0) break;
            if (s2a_source_pin_key(ov_key[stored], &ov_ref[stored]) != 0) break;
            s2a_source_stats(&en, &by, &dr);
            if (first_over < 0 && by > S2A_SOURCE_MAX_BYTES) first_over = stored;
            if (first_over >= 0 && stored == first_over + 4) logs_mid = g_source_log_lines;   // 越过软预算后又收了几条，仍未到安全阀
        }
        s2a_source_stats(&en, &by, &dr);
        s2a_source_pin_stats(&ps);
        CHECK(logs_mid == logs0 + 1, "crossing the soft budget is logged exactly once, not per keep");
        CHECK(first_over > 0 && stored > first_over + 4, "program-pinned sources keep being accepted past the soft byte budget");
        CHECK(by > S2A_SOURCE_MAX_BYTES && by <= S2A_SOURCE_HARD_BYTES, "total bytes sit between the soft budget and the hard cap");
        CHECK(stored < OV_MAX, "the hard byte cap stops the fill once pinned bytes reach it");
        CHECK(ps.keep_fail_bytes == ps0.keep_fail_bytes + 1, "the one keep refused at the hard cap is counted as a byte failure");
        CHECK(ps.keep_over_budget > ps0.keep_over_budget && g_source_log_lines > logs0, "going past the soft budget is counted and logged");
        CHECK(dr == dr0, "nothing was evicted: every entry is held by a live program");
        CHECK(s2a_source_identity(ov_key[0], (uint8_t[32]){0}, NULL, NULL) == 0 &&
              s2a_source_identity(ov_key[stored - 1], (uint8_t[32]){0}, NULL, NULL) == 0,
              "the first and the last pinned sources are both resolvable");
        // 程序都销毁了：它们的源回到可淘汰集合，下一次 keep 把总量压回软预算以内。
        for (int i = 0; i < stored; i++) s2a_source_unpin_ref(&ov_ref[i]);
        uint8_t nk[8], nctl[S2A_SOURCE_CONTROL_BYTES];
        memset(nctl, 0x7c, sizeof nctl);
        memcpy(nctl + 0x700, &c1_begin, 4);
        memcpy(nctl + 0x704, &c1_end, 4);
        make_key(code_a, CODE_BYTES, nctl, S2A_SOURCE_CONTROL_BYTES, nk);
        CHECK(s2a_source_keep(nk, 0, code_a, CODE_BYTES, nctl, S2A_SOURCE_CONTROL_BYTES) == 0,
              "after the programs are gone a new source is stored");
        s2a_source_stats(&en, &by, &dr);
        CHECK(by <= S2A_SOURCE_MAX_BYTES && dr > dr0, "once nothing is pinned the store is evicted back under the soft budget");
        s2a_source_clear();
    }

    // 短 control（+0x20 自描述）：0x850 合法，0x700 不完整。
    static uint8_t short_ctl[0x850];
    memset(short_ctl, 0x11, sizeof short_ctl);
    uint32_t own = 0x850;
    memcpy(short_ctl + 0x20, &own, 4);
    memcpy(short_ctl + 0x700, &c1_begin, 4);
    memcpy(short_ctl + 0x704, &c1_end, 4);
    uint8_t key_short[8];
    make_key(code_a, CODE_BYTES, short_ctl, 0x850, key_short);
    CHECK(s2a_source_keep(key_short, 0, code_a, CODE_BYTES, short_ctl, 0x850) == 0, "short control is accepted");
    memset(&v, 0, sizeof v);
    CHECK(s2a_source_get_key(key_short, &v) == 1 && v.control_bytes == 0x850, "short control keeps its own length");
    CHECK(v.c1 && v.c1_bytes == 0x80, "short control still yields the declared c1 range");
    uint8_t key_short_bad[8];
    make_key(code_a, CODE_BYTES, short_ctl, 0x700, key_short_bad);
    CHECK(s2a_source_keep(key_short_bad, 0, code_a, CODE_BYTES, short_ctl, 0x700) != 0,
          "too-short control is rejected");

    // pending control：SetShaders 自持，Bind 取回同一份；存到程序 Finalize（drop_pending）为止，不按条数挤掉（#1622）。
    uint8_t pc[S2A_SOURCE_CONTROL_BYTES];
    uint32_t pn = 0;
    uint32_t n0 = s2a_source_pending_count();
    CHECK(s2a_source_hold_pending(4242, 1, ctl_a, S2A_SOURCE_CONTROL_BYTES) == 0, "hold pending control");
    CHECK(s2a_source_pending_control_copy(4242, 1, pc, sizeof pc, &pn) == 1 && pn == S2A_SOURCE_CONTROL_BYTES &&
          !memcmp(pc, ctl_a, pn), "pending control returns the same bytes");
    CHECK(s2a_source_pending_control_copy(4242, 0, pc, sizeof pc, &pn) == 0 && pn == 0, "pending control is per stage");
    memset(pc, 0xa5, sizeof pc);
    pn = 99;
    CHECK(s2a_source_pending_control_copy(4242, 1, pc, sizeof pc - 1, &pn) == 0 && pn == 0,
          "insufficient capacity fails without reporting a length");
    int untouched = 1;
    for (unsigned i = 0; i < sizeof pc; i++) if (pc[i] != 0xa5) untouched = 0;
    CHECK(untouched, "insufficient capacity leaves destination and bytes beyond cap untouched");
    CHECK(s2a_source_pending_control_copy(4242, 1, NULL, sizeof pc, &pn) == 0 && pn == 0,
          "null destination rejected");
    CHECK(s2a_source_pending_control_copy(4242, 1, pc, sizeof pc, NULL) == 0, "null length rejected");
    CHECK(s2a_source_pending_control_copy(4242, 6, pc, sizeof pc, &pn) == 0 && pn == 0,
          "invalid pending stage rejected");
    // 一次注册 3000 个程序 × 2 阶段（旧实现 256 格环：最早的 4242 和 1000..2743 早被挤掉）→ 全部还在
    for (int i = 0; i < 3000; i++) {
        s2a_source_hold_pending((uint64_t)(1000 + i), 0, ctl_a, S2A_SOURCE_CONTROL_BYTES);
        s2a_source_hold_pending((uint64_t)(1000 + i), 4, ctl_b, S2A_SOURCE_CONTROL_BYTES);
    }
    CHECK(s2a_source_pending_control_copy(4242, 1, pc, sizeof pc, &pn) == 1 && !memcmp(pc, ctl_a, pn), "earliest pending survives 6000 later holds");
    CHECK(s2a_source_pending_control_copy(1000, 4, pc, sizeof pc, &pn) == 1 && !memcmp(pc, ctl_b, pn), "first of the burst still retrievable per stage");
    CHECK(s2a_source_pending_count() == n0 + 1 + 6000, "pending count = live program stages");
    // 同程序同阶段重设：换内容、不增条数
    CHECK(s2a_source_hold_pending(1000, 0, ctl_b, S2A_SOURCE_CONTROL_BYTES) == 0 && s2a_source_pending_control_copy(1000, 0, pc, sizeof pc, &pn) == 1 &&
          !memcmp(pc, ctl_b, pn) && s2a_source_pending_count() == n0 + 1 + 6000, "re-hold replaces in place");
    // Finalize：该程序全部阶段一起释放，别的程序不受影响
    s2a_source_drop_pending(1000);
    CHECK(s2a_source_pending_control_copy(1000, 0, pc, sizeof pc, &pn) == 0 && s2a_source_pending_control_copy(1000, 4, pc, sizeof pc, &pn) == 0, "drop pending frees all stages");
    CHECK(s2a_source_pending_control_copy(1001, 4, pc, sizeof pc, &pn) == 1 && s2a_source_pending_count() == n0 + 1 + 5998, "drop pending leaves other programs");
    for (int i = 1; i < 3000; i++) s2a_source_drop_pending((uint64_t)(1000 + i));
    s2a_source_drop_pending(4242);
    CHECK(s2a_source_pending_count() == n0, "all pending released after finalize");

    // 源已存进源快照的阶段：释放它的自持控制段，同程序的其他阶段不受影响（反复重设同一程序对象不再累积到安全阀）
    {
        uint32_t m0 = s2a_source_pending_count();
        CHECK(s2a_source_hold_pending(7777, 0, ctl_a, S2A_SOURCE_CONTROL_BYTES) == 0 &&
              s2a_source_hold_pending(7777, 4, ctl_b, S2A_SOURCE_CONTROL_BYTES) == 0, "hold two stages");
        s2a_source_drop_pending_stage(7777, 0);
        CHECK(s2a_source_pending_control_copy(7777, 0, pc, sizeof pc, &pn) == 0, "kept stage control released");
        CHECK(s2a_source_pending_control_copy(7777, 4, pc, sizeof pc, &pn) == 1 && !memcmp(pc, ctl_b, pn), "other stage of the same program stays");
        CHECK(s2a_source_pending_count() == m0 + 1, "count drops by one");
        s2a_source_drop_pending_stage(7777, 0);   // 重复释放无副作用
        s2a_source_drop_pending_stage(7777, 9);   // 越界阶段忽略
        CHECK(s2a_source_pending_count() == m0 + 1, "repeat / out-of-range drop is a no-op");
        s2a_source_drop_pending(7777);
        CHECK(s2a_source_pending_count() == m0, "finalize releases the rest");
    }

    // 键第 2 代（nvn_key.h）：内容摘要按「两段易变字段置零」的控制段算。期望值由 Python hashlib 按规则手算：
    //   控制段 0x880 字节 ctl[i] = (i*7+3) & 0xff、+0x20 = 0x880、+0x704 = 0x40；代码 0x40 字节 code[i] = (i*13+5) & 0xff、前 4 字节 78 56 34 12
    //   第 2 代 sha256 = e0d0ef6990987e99758d5ed2782b06f462ea133d633ee9cd30825916a90b9ec5，第 1 代键（不置零）= 404d87c7549fd09c
    //   反证：source_store.c 不置零 → 第 2 代键被拒、第 1 代键被收（下两项红）
    {
        static uint8_t kv_ctl[0x880], kv_ctl2[0x880], kv_code[0x40];
        for (unsigned i = 0; i < sizeof kv_ctl; i++) kv_ctl[i] = (uint8_t)(i * 7 + 3);
        for (unsigned i = 0; i < sizeof kv_code; i++) kv_code[i] = (uint8_t)(i * 13 + 5);
        memcpy(kv_code, "\x78\x56\x34\x12", 4);
        uint32_t own = 0x880, nc = 0x40; memcpy(kv_ctl + 0x20, &own, 4); memcpy(kv_ctl + 0x704, &nc, 4);
        memcpy(kv_ctl2, kv_ctl, sizeof kv_ctl); kv_ctl2[0x793] ^= 0x5a; kv_ctl2[0x7e7] ^= 0xa5;   // 只差两段
        static const uint8_t v2[8] = {0xe0, 0xd0, 0xef, 0x69, 0x90, 0x98, 0x7e, 0x99}, v1[8] = {0x40, 0x4d, 0x87, 0xc7, 0x54, 0x9f, 0xd0, 0x9c};
        static const uint8_t sha_v2[32] = {0xe0, 0xd0, 0xef, 0x69, 0x90, 0x98, 0x7e, 0x99, 0x75, 0x8d, 0x5e, 0xd2, 0x78, 0x2b, 0x06, 0xf4,
                                           0x62, 0xea, 0x13, 0x3d, 0x63, 0x3e, 0xe9, 0xcd, 0x30, 0x82, 0x59, 0x16, 0xa9, 0x0b, 0x9e, 0xc5};
        CHECK(s2a_source_keep(v1, 0, kv_code, sizeof kv_code, kv_ctl, sizeof kv_ctl) != 0, "key v2: generation-1 key rejected");
        CHECK(s2a_source_keep(v2, 0, kv_code, sizeof kv_code, kv_ctl, sizeof kv_ctl) == 0, "key v2: generation-2 key kept");
        uint8_t sha[32]; uint32_t cb = 0, ctlb = 0;
        CHECK(s2a_source_identity(v2, sha, &cb, &ctlb) == 0 && !memcmp(sha, sha_v2, 32), "key v2: content digest = hand-computed zeroed digest");
        CHECK(s2a_source_keep(v2, 0, kv_code, sizeof kv_code, kv_ctl2, sizeof kv_ctl2) == 0 && s2a_source_identity_ok_for_test(v2),
              "key v2: a control differing only in the volatile spans is the same source (not ambiguous)");
    }

    if (fails) { printf("direct source store test: %d FAILED\n", fails); return 1; }
    printf("direct source store test: ok\n");
    return 0;
}
