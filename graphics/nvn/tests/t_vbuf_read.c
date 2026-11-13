// nvn_vbuf_read_streams：bind_vbufs 只解析顶点着色器输入真取数的流（#618 诊断包：槽 5 绑着不在任何池的 336 字节地址，整局约 420 万次报「读零」）。
// 期望值全部手算自夹具（属性号 → 流号的对照表），不跑被测实现得来。
#include "../gfx/nvn/nvn_vbuf_read.h"
#include <stdio.h>

static int fails, checks;
#define CHECK(c, ...) do { checks++; if (!(c)) { fails++; printf("✗ "); } else printf("✓ "); printf(__VA_ARGS__); putchar('\n'); } while (0)

int main(void) {
    // 当前顶点属性状态：属性 0、1 在流 0，属性 2 在流 1，属性 3 在流 5，属性 4 在流 5 但格式 0，属性 5 流号 20（越界）
    const uint8_t st[6] = {0, 0, 1, 5, 5, 20}, fm[6] = {0x2c, 0x2c, 0x10, 0x2c, 0, 0x2c};
    uint32_t m;

    // ① #618 的形状：着色器只读属性 0 / 1 / 2，流 5 虽绑着地址但没有输入引用它 → 只有流 0、1
    const uint8_t r012[3] = {0, 1, 2};
    m = nvn_vbuf_read_streams(r012, 3, st, fm, 6);
    CHECK(m == 0x3, "只读属性 0/1/2：取数的流 = {0,1}（实得 %#x），流 5 不解析、不报读零", m);

    // ② 着色器读属性 3 → 流 5 也要解析（真读零时照旧报红）
    const uint8_t r23[2] = {2, 3};
    m = nvn_vbuf_read_streams(r23, 2, st, fm, 6);
    CHECK(m == ((1u << 1) | (1u << 5)), "读属性 2/3：流 = {1,5}（实得 %#x）", m);

    // ③ 格式 0 的属性不取数（pso_desc 让它读零缓冲），越界流号不算
    const uint8_t r45[2] = {4, 5};
    m = nvn_vbuf_read_streams(r45, 2, st, fm, 6);
    CHECK(m == 0, "属性 4（格式 0）/ 5（流号 20）：不取任何流（实得 %#x）", m);

    // ④ 属性号 ≥ 当前绑的属性个数：pso_key_fill 不拷它，不取数
    m = nvn_vbuf_read_streams(r23, 2, st, fm, 3);
    CHECK(m == (1u << 1), "只绑 3 个属性时读属性 2/3：流 = {1}（实得 %#x）", m);

    // ⑤ 属性号 ≥ 16 与没有输入的着色器
    const uint8_t r_big[2] = {16, 200};
    m = nvn_vbuf_read_streams(r_big, 2, st, fm, 6);
    CHECK(m == 0, "属性号 16 / 200：不算（实得 %#x）", m);
    m = nvn_vbuf_read_streams(r012, 0, st, fm, 6);
    CHECK(m == 0, "没有顶点输入：不解析任何槽（实得 %#x）", m);

    printf("%s t_vbuf_read：%d 项，%d 处不符\n", fails ? "✗" : "✓", checks, fails);
    return fails != 0;
}
