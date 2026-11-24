// macos/pad_activity.h：手柄输入算「用户在场」的判据（#2159）。期望值按头文件注释的规则手算：
//   第一拍只记基准；按键变化 / 摇杆挪动超过 1/8 满幅算动作；声明后 5 秒内不再声明；静止抖动不算
#include <stdio.h>
#include "pad_activity.h"

static int fails;
static void check(const char *what, int got, int want) {
    if (got != want) { fails++; fprintf(stderr, "红：%s 得 %d，期望 %d\n", what, got, want); }
}

int main(void) {
    s2a_pad_activity a; memset(&a, 0, sizeof a);
    uint32_t b[8] = {0}; int32_t st[8][4] = {{0}};
    const uint64_t S = 1000000;
    b[0] = 1;   // 起局时手柄上已经按着键：第一拍只记基准
    check("第一拍", s2a_pad_activity_tick(&a, 8, b, st, 100 * S), 0);
    check("没变化", s2a_pad_activity_tick(&a, 8, b, st, 100 * S + 16000), 0);
    b[0] = 0;
    check("松开按键", s2a_pad_activity_tick(&a, 8, b, st, 101 * S), 1);
    b[0] = 4;
    check("5 秒内再按", s2a_pad_activity_tick(&a, 8, b, st, 103 * S), 0);
    b[0] = 0;
    check("满 5 秒后再按", s2a_pad_activity_tick(&a, 8, b, st, 106 * S + 1), 1);
    st[0][0] = 1000;   // 静止手柄的读数抖动（< 4096）
    check("摇杆抖动", s2a_pad_activity_tick(&a, 8, b, st, 120 * S), 0);
    st[0][0] = 6000;   // 离基准 6000 > 4096
    check("推摇杆", s2a_pad_activity_tick(&a, 8, b, st, 121 * S), 1);
    // 慢推：每拍只挪 3000，相对上次记下的基准累计过线才算
    st[0][1] = 3000;
    check("慢推第一步", s2a_pad_activity_tick(&a, 8, b, st, 130 * S), 0);
    st[0][1] = 6000;
    check("慢推累计过线", s2a_pad_activity_tick(&a, 8, b, st, 131 * S), 1);
    b[3] = 1u << 10;   // 第 4 位玩家按「+」
    check("别的槽按键", s2a_pad_activity_tick(&a, 8, b, st, 140 * S), 1);
    check("之后静止", s2a_pad_activity_tick(&a, 8, b, st, 150 * S), 0);
    // 只看传进来的槽数：第 6 槽变了但只传 4 槽
    b[5] = 1;
    check("槽数以外不看", s2a_pad_activity_tick(&a, 4, b, st, 160 * S), 0);
    if (fails) { printf("✗ t_pad_activity：%d 项不通\n", fails); return 1; }
    puts("✓ t_pad_activity：12 项全过");
    return 0;
}
