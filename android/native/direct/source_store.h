// SetShaders 期的真实源快照：有界、自有的 code/control 副本 + 真实阶段信息。
// 这是“统一生产链”的输入侧：Draw/Dispatch 时再补齐绑定/附件/纹理池事实，形成编译请求。
// 拿不到完整事实的条目标为待完善源，不强行构造可编译请求。
//
// 生命周期（F4.2）：get_key/get 返回借用指针，只适合立即拷贝/诊断；编译等跨步骤消费者必须用
// acquire/release 取得引用（pin）。活 NVN program 另用它自己的生命周期 pin（pin_key/unpin_ref）：
// program 在 SetShaders 存源时 pin，换 SetShaders / Finalize 时解 pin；被任一种 pin 引用的条目
// 不参与淘汰。release/unpin 后最后一个引用消失才回收；字节预算包含 code + control + c1。
//
// 身份（F4.3 修订，2026-10-27）：捕获时算一次完整 SHA-256（control‖code，与短 stage key 同一摘要），
// 随快照一起保存并在身份编码里复用，短 key 只作候选定位。keep 只接受“短 key 等于该摘要前 8 字节”
// 的输入：同一短 key 指向不同内容时明确拒绝，不覆盖、不取最新，也不伪造等价身份。
#pragma once
#include <stddef.h>
#include <stdint.h>
#include "../../../graphics/nvn/gfx/nvn/nvn_program_pins.h"

#ifdef __cplusplus
extern "C" {
#endif
#define S2A_SOURCE_MAX_ENTRIES 4096      // 未 pin 条目的容量；淘汰只在这部分里选最旧
#ifndef S2A_SOURCE_MAX_PINNED
#define S2A_SOURCE_MAX_PINNED 16384     // 活 program pin 的额外槽位（硬上限；字节预算另计）
#endif
#define S2A_SOURCE_SLOTS (S2A_SOURCE_MAX_ENTRIES + S2A_SOURCE_MAX_PINNED)
#define S2A_SOURCE_MAX_BYTES (64u * 1024u * 1024u)   // 软预算：只约束可淘汰（未 pin）的条目，超了先淘汰最旧的未 pin 条目
// 字节安全阀：可淘汰的淘汰光了、剩下全是活 program / 编译在用的源时，keep 放宽到这里（防泄漏，正常到不了）；越过它才失败。
//   活 program pin 的条数由游戏自己的活程序数决定（有 S2A_SOURCE_MAX_PINNED 槽位硬上限），不能让 64 MiB 软预算替它们拒收
//   （#1622：5,711 个活程序恰好占满 64 MiB，之后注册的 123 个程序存不进去）。
#ifndef S2A_SOURCE_HARD_BYTES
#define S2A_SOURCE_HARD_BYTES (512u * 1024u * 1024u)
#endif
#define S2A_SOURCE_MAX_CODE (256u * 1024u)
#define S2A_SOURCE_CONTROL_BYTES 0x880u
#define S2A_SOURCE_CONTROL_MIN 0x760u    // 控制段 +0x20 自描述长度（短 control）的最小合法值
// SetShaders 自持的控制段按 (程序序号, 阶段) 存到程序 Finalize（s2a_source_drop_pending）。原先是 256 格的环、满了静默挤掉最旧的：
//   一款游戏进标题 3D 时一次注册几百个程序，先注册、代码区还没映射（键要到 Bind 才补算）的那些被挤掉，Bind 时拿不到控制段，
//   源快照永远存不进去，每笔绘制都报 source_snapshot_missing（#1622：一局 13.5 万次，占 program_unresolved 的 64.6%）。
//   现在跟活程序数走；S2A_SOURCE_PENDING_MAX 只是防泄漏的安全阀（正常远到不了），超了才挤最旧并打红行。
#ifndef S2A_SOURCE_PENDING_MAX
#define S2A_SOURCE_PENDING_MAX 65536u
#endif

struct s2a_source_entry_view {
    const uint8_t *key;      // 8 字节 control 键（完整内容摘要的前 8 字节）
    uint32_t array_index;    // SetShaders 数组序号（阶段身份在 Draw 快照时按真实掩码确定）
    uint32_t code_bytes;
    uint32_t control_bytes;
    const uint8_t *code;
    const uint8_t *control;
    int complete;            // code/control 都完整；0 = 待完善源
    const uint8_t *c1;       // 控制段声明的真实常量段；NULL = 未捕获
    uint32_t c1_bytes;
    // 捕获时算定的完整内容摘要（SHA-256(control‖code)），与短 key 同源；只在 complete 时有效。
    uint8_t content_sha[32];
    // acquire 得到的引用令牌（0 = 借用视图，不能 release）。release 只认这个令牌：
    // 同 key 重新登记会得到新令牌，旧令牌不会被误认成新条目。
    uint64_t ref;
};

// 保存一次 SetShaders 的一个阶段。control_bytes 允许控制段自描述的短长度（0x760..0x880）。
// 超出数量/字节预算时按最旧优先淘汰未 pinned 的条目；可淘汰的没有了（全部 pinned）就不淘汰在用的源，
// 也不拒收它们：字节放宽到 S2A_SOURCE_HARD_BYTES，越过它或槽位满了才准确失败（-1）。
// 短 key 与真实内容摘要前 8 字节不符时同样返回 -1（调用方按缺源处理，不写可能误命中的条目）。
int s2a_source_keep(const uint8_t key[8], uint32_t array_index, const void *code, uint32_t code_bytes,
                    const void *control, uint32_t control_bytes);
// 按 key+nvn_stage 查（回放/补编用）。返回 1 命中并填 view（指针在下次 keep/释放前有效）。
int s2a_source_get(const uint8_t key[8], uint32_t array_index, struct s2a_source_entry_view *out);
// 只按 key 查：同一个 key 就是同一份编译输入（key = sha256(control‖code) 前 8 字节，control 两段易变字段按 0 算，nvn_key.h）。
int s2a_source_get_key(const uint8_t key[8], struct s2a_source_entry_view *out);
// 是否已有一份完整快照（Bind 时用它避免重读可能已失效的 guest control）。
int s2a_source_has(const uint8_t key[8]);
// 生命周期引用：acquire 命中时 pinned，out->ref 是引用令牌；必须用同一令牌 release。
int s2a_source_acquire(const uint8_t key[8], struct s2a_source_entry_view *out);
void s2a_source_release(uint64_t ref);
// Program 生命周期 pin：按 key 找到唯一快照并填 slot/seq/key/sha；返回 0 表示已 pin。
// 解 pin 用 slot+seq 定位，不按 key/sha 扫全表。与 acquire 的编译期引用分开计数。
int s2a_source_pin_key(const uint8_t key[8], struct s2a_source_pin_ref *out);
// 按 slot+seq 解 pin；ref 已失效（淘汰/清空/换代）时是 no-op，返回 -1。
int s2a_source_unpin_ref(const struct s2a_source_pin_ref *ref);
// pin 统计（设备回执用）。evict_skipped 是“扫描中因 program pin 跳过的条目次数”，
// keep_fail_bytes/keep_fail_slots 是字节安全阀 / 槽位分别耗尽导致的 keep 失败次数；
// keep_over_budget 是收下之后总字节仍超过软预算的 keep 次数（可淘汰的没有了、被活 program 占着，放宽收下的）。
struct s2a_source_pin_stats {
    uint32_t pinned_entries;
    uint64_t pins;
    uint64_t pin_calls;
    uint64_t pin_misses;
    uint64_t unpins;
    uint64_t evict_skipped;
    uint64_t keep_fail_bytes;
    uint64_t keep_fail_slots;
    uint64_t keep_over_budget;
};
void s2a_source_pin_stats(struct s2a_source_pin_stats *out);
// 内容/磁盘身份用：唯一命中返回 0 并给出完整摘要与真实长度；缺源返回 -1（调用方准确失败）。
int s2a_source_identity(const uint8_t key[8], uint8_t sha[32], uint32_t *code_bytes, uint32_t *control_bytes);
// 快照内容代际：keep 成功/淘汰/清空时推进。身份备忘用它证明“key→内容”的映射没变，
// 不能拿“上一次也命中”当证明。
uint64_t s2a_source_epoch(void);
// 因短 key 与内容摘要不符被拒绝的 keep 次数（0 是正常基线；非 0 说明调用方 key/长度不自洽）。
uint64_t s2a_source_rejected(void);

// SetShaders 的 control 只在当次调用内有效。代码尚未登记进已映射池、key 还算不出来时，
// 先把 control 存进有界 pending 表；Bind 时再用当时的 code + 这份 control 补算 key。
int s2a_source_hold_pending(uint64_t prog_serial, uint32_t stage, const void *control, uint32_t control_bytes);
// 在锁内拷出 pending control（用于补算 key / keep）；成功返回 1，*n 为拷贝长度。
// 缺项、参数无效或 cap 不足返回 0，不改 dst；n 非 NULL 时失败置 *n = 0（不报告所需长度）。
int s2a_source_pending_control_copy(uint64_t prog_serial, uint32_t stage, void *dst, uint32_t cap, uint32_t *n);
void s2a_source_drop_pending(uint64_t prog_serial);
void s2a_source_drop_pending_stage(uint64_t prog_serial, uint32_t stage);   // 该阶段的源已存进源快照：释放它的自持控制段
uint32_t s2a_source_pending_count(void);   // 现存自持控制段条数（单测 / 诊断用）

void s2a_source_stats(uint32_t *entries, uint32_t *bytes, uint32_t *dropped);
void s2a_source_clear(void);
#ifdef __cplusplus
}
#endif
