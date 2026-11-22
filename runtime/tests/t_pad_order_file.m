// 分配玩家顺序表的 JSON 解析（ios/pad_order_file.h，Mac / iOS 宿主共用一份）。期望值手写，不跑被测实现推导。
//   argv[1..] = 要求「用共用解析、不再自带一份」的宿主源文件（macos/front_mac.m、ios/controller.m）
#import <Foundation/Foundation.h>
#include <stdio.h>
#include <string.h>
#include "pad_order_file.h"

static int bad;
static void check(int ok, const char *what) { printf("%s %s\n", ok ? "✓" : "✗", what); if (!ok) bad++; }

static id parse(NSString *text) {
    return [NSJSONSerialization JSONObjectWithData:[text dataUsingEncoding:NSUTF8StringEncoding] options:0 error:nil];
}

int main(int argc, char **argv) {
    @autoreleasepool {
        s2a_pad_order o; long g;

        check(s2a_pad_order_from_json(nil, &o, &g) == 0 && o.count == 0 && o.dropped_count == 0 && g == -1, "读不到文件（nil）：没有表、generation -1");
        check(s2a_pad_order_from_json(parse(@"[1,2]"), &o, &g) == 0 && o.count == 0 && g == -1, "不是字典：没有表");

        id full = parse(@"{\"generation\":7,\"order\":["
            "{\"type\":\"ns2\",\"player\":1},"
            "{\"type\":\"keyboard\"},"
            "{\"name\":\"Xbox Wireless Controller\",\"index\":1},"
            "{\"type\":\"empty\"},"
            "{\"type\":\"gen1\",\"id\":\"98-b6-e9-00-11-22\"},"
            "{\"type\":\"gen1pair\",\"left\":\"L1\",\"right\":\"R1\"}],"
            "\"dropped\":[{\"name\":\"DualSense Wireless Controller\",\"index\":0}]}");
        check(s2a_pad_order_from_json(full, &o, &g) == 1 && g == 7, "完整表：读到、generation 7");
        check(o.count == 6 && o.dropped_count == 1, "order 6 项、dropped 1 项");
        check(o.entry[0].ns2_player == 1 && o.entry[0].name[0] == 0, "P1 = NS2 手柄通道玩家 1（不带名字）");
        check(o.entry[1].ns2_player == S2A_PAD_ORDER_KEYBOARD, "P2 = 键盘");
        check(o.entry[2].ns2_player == -1 && !strcmp(o.entry[2].name, "Xbox Wireless Controller") && o.entry[2].index == 1, "P3 = 系统手柄：名字 + 同名第 2 只（index 1）");
        check(o.entry[3].ns2_player == S2A_PAD_ORDER_EMPTY, "P4 = 空槽占位");
        check(o.entry[4].ns2_player == S2A_PAD_ORDER_GEN1 && !strcmp(o.entry[4].name, "98-b6-e9-00-11-22"), "一代单只：按设备 id");
        check(o.entry[5].ns2_player == S2A_PAD_ORDER_GEN1_PAIR && !strcmp(o.entry[5].name, "L1|R1"), "一代一对：「左 id|右 id」");
        check(o.dropped[0].ns2_player == -1 && !strcmp(o.dropped[0].name, "DualSense Wireless Controller") && o.dropped[0].index == 0, "没分配的：系统手柄名字 + index");

        check(s2a_pad_order_from_json(parse(@"{\"order\":[{\"type\":\"keyboard\"}]}"), &o, &g) == 1 && g == 0 && o.count == 1, "没写 generation：读到、记 0");

        NSMutableString *many = [NSMutableString stringWithString:@"{\"generation\":1,\"order\":["];
        for (int i = 0; i < 10; i++) [many appendFormat:@"%@{\"type\":\"ns2\",\"player\":%d}", i ? @"," : @"", i];
        [many appendString:@"]}"];
        check(s2a_pad_order_from_json(parse(many), &o, &g) == 1 && o.count == S2A_PAD_ORDER_MAX && o.entry[7].ns2_player == 7, "超过 8 项：只收前 8 项");

        check(s2a_pad_order_from_json(parse(@"{\"order\":[{\"type\":\"keyboard\"},3,{\"type\":\"empty\"}]}"), &o, &g) == 1 && o.count == 1,
              "表里混进非字典项：在它之前停（同抽出前 Mac 的写法）");

        // 宿主源码：都用共用解析，不再各自带一份 fill
        for (int i = 1; i < argc; i++) {
            NSString *src = [NSString stringWithContentsOfFile:@(argv[i]) encoding:NSUTF8StringEncoding error:nil] ?: @"";
            char what[256];
            snprintf(what, sizeof what, "%s 用共用解析 s2a_pad_order_from_json、不自带一份", argv[i]);
            check([src containsString:@"s2a_pad_order_from_json("] && ![src containsString:@"void (^fill)("], what);
            // 排位共用 pad.c：先 s2a_pad_order_arrange 去掉没分配的、再 s2a_slot_pin 钉槽，最后才 s2a_slot_plan
            NSRange ar = [src rangeOfString:@"s2a_pad_order_arrange("], pin = [src rangeOfString:@"s2a_slot_pin("], plan = [src rangeOfString:@"= s2a_slot_plan("];
            snprintf(what, sizeof what, "%s 排位顺序：arrange → slot_pin → slot_plan", argv[i]);
            check(ar.location != NSNotFound && pin.location != NSNotFound && plan.location != NSNotFound && ar.location < pin.location && pin.location < plan.location, what);
            if ([src containsString:@"selectSystemLocked"]) {   // iOS：没有表时玩家 1 的判活 / 换手柄照改前（s2a_system_action），按表改派只在有表时走
                snprintf(what, sizeof what, "%s 按表改派玩家 1 只在有表时（g_order_loaded && …）", argv[i]);
                check([src containsString:@"if (g_order_loaded && foreground && current.extendedGamepad && slot0 != current)"], what);
            }
        }
    }
    if (bad) { fprintf(stderr, "✗ t_pad_order_file：%d 项不符\n", bad); return 1; }
    printf("✓ t_pad_order_file：分配玩家顺序表解析（缺省 / 完整表 / 没写 generation / 超 8 项 / 混进非字典项）与宿主源码接线（共用解析、arrange → slot_pin → slot_plan、按表改派玩家 1 只在有表时）全过\n");
    return 0;
}
