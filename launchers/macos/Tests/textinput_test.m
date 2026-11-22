// 系统键盘桥接 Mac 端单测（macos/textinput_mac.m + 公用分发 runtime/src/text_input.c）：真起 AppKit 窗口，
//   经 s2a_host_text_input 弹表单，程序代替玩家填字 / 点按钮，核回调。期望按约定手写（runtime/include/s2a_text_input.h、s2a_text_input_rules.h）：
//   ① 全键盘：填「李雷Lee」点确定 → 回调 status 1、文本「李雷Lee」，且只回调一次
//   ② 数字模式最长 3：填「12ab345」→ 输入框收成「123」，点确定回「123」
//   ③ 最短 4：初始「ab」时确定置灰；填到「abcd」后可点
//   ④ 取消 → status 0、文本空
//   ⑤ 外部收框（s2a_host_text_input_cancel）→ 表单关、不回调
//   ⑥ 无人值守（S2A_AUTOPLAY=1）不弹、返回 0；验收开关 S2A_TEXT_INPUT_UI=1 照弹
#import <AppKit/AppKit.h>
#include <stdio.h>
#include <stdlib.h>
#include "../../../runtime/src/text_input.c"
#import "../../../macos/textinput_mac.m"

static int bad;
static void ck(int ok, const char *what) { printf("%s %s\n", ok ? "通" : "不通", what); if (!ok) bad++; }

static int g_calls, g_status; static char g_text[256];
static void cb(int64_t id, int status, const char *text) { (void)id; g_calls++; g_status = status; snprintf(g_text, sizeof g_text, "%s", text ? text : ""); }

static NSWindow *g_win;
static void spin(double s) { [[NSRunLoop mainRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:s]]; }
static NSAlert *sheet_alert(void) {
    for (int i = 0; i < 40 && !g_win.attachedSheet; i++) spin(0.05);
    for (S2ATextInputMac *in in g_inputs.allValues) if (in.alert.window == g_win.attachedSheet) return in.alert;
    return nil;
}
static NSTextField *field(NSAlert *a) { return (NSTextField *)a.accessoryView; }
static void type_into(NSAlert *a, NSString *s) {
    field(a).stringValue = s;
    [field(a).delegate controlTextDidChange:[NSNotification notificationWithName:NSControlTextDidChangeNotification object:field(a)]];
}
static void begin(int64_t id, const char *json) { g_calls = 0; g_status = -1; g_text[0] = 0; ck(s2a_host_text_input(id, json, cb) == 1, "发起返回 1（已排上弹框）"); spin(0.2); }

int main(void) {
    @autoreleasepool {
        [NSApplication sharedApplication]; [NSApp setActivationPolicy:NSApplicationActivationPolicyAccessory];
        g_win = [[NSWindow alloc] initWithContentRect:NSMakeRect(0, 0, 480, 270) styleMask:NSWindowStyleMaskTitled backing:NSBackingStoreBuffered defer:NO];
        [g_win makeKeyAndOrderFront:nil]; spin(0.2);
        unsetenv("S2A_AUTOPLAY"); unsetenv("S2A_TEXT_INPUT_UI");

        begin(1, "{\"header\":\"车手名\",\"mode\":\"full\",\"min\":1,\"max\":14}");
        NSAlert *a = sheet_alert(); ck(a != nil, "① 表单挂在窗口上");
        ck([a.messageText isEqualToString:@"车手名"], "① 标题用游戏给的");
        type_into(a, @"李雷Lee"); [a.buttons.firstObject performClick:nil]; spin(0.3);
        ck(g_calls == 1 && g_status == 1 && !strcmp(g_text, "李雷Lee"), "① 确定回「李雷Lee」、只回一次");

        begin(2, "{\"mode\":\"numeric\",\"min\":1,\"max\":3}");
        a = sheet_alert(); type_into(a, @"12ab345");
        ck([field(a).stringValue isEqualToString:@"123"], "② 数字模式滤掉字母、截到最长 3");
        [a.buttons.firstObject performClick:nil]; spin(0.3);
        ck(g_status == 1 && !strcmp(g_text, "123"), "② 确定回「123」");

        begin(3, "{\"initial\":\"ab\",\"mode\":\"full\",\"min\":4,\"max\":8}");
        a = sheet_alert(); ck(!a.buttons.firstObject.enabled, "③ 不到最短 4 时确定置灰");
        type_into(a, @"abcd"); ck(a.buttons.firstObject.enabled, "③ 够 4 个字后确定可点");
        [a.buttons[1] performClick:nil]; spin(0.3);
        ck(g_calls == 1 && g_status == 0 && g_text[0] == 0, "④ 取消回 status 0、文本空");

        begin(4, "{\"mode\":\"full\",\"min\":0,\"max\":8}");
        a = sheet_alert(); ck(a != nil, "⑤ 第四个表单挂上");
        s2a_host_text_input_cancel(4); spin(0.5);
        ck(g_win.attachedSheet == nil && g_calls == 0, "⑤ 外部收框：表单关、不回调");

        const char *roster = "{\"localPlayers\":[\"小明\",\"小林\"],\"initial\":\"Player3\",\"min\":1,\"max\":32}";
        begin(7, roster);
        S2ATextInputMac *picker = g_inputs[@7];
        ck(picker.playerTable.numberOfRows == 3 && !picker.field, "两个用户各占一行，末尾是创建");
        [picker.playerTable selectRowIndexes:[NSIndexSet indexSetWithIndex:1] byExtendingSelection:NO];
        [NSApp sendAction:picker.playerTable.action to:picker.playerTable.target from:picker.playerTable];
        spin(.3);
        ck(g_calls == 1 && g_status == 1 && !strcmp(g_text, "1"), "选中第二行直接返回对应用户");

        begin(8, roster);
        picker = g_inputs[@8];
        [picker.playerTable selectRowIndexes:[NSIndexSet indexSetWithIndex:2] byExtendingSelection:NO];
        [picker choosePlayer:picker.playerTable];
        ck(picker.field != nil && !picker.playerTable, "创建行进入命名表单");
        picker.field.stringValue = @"新队友";
        [picker.saveButton performClick:nil]; spin(.3);
        ck(g_calls == 1 && !strcmp(g_text, "new:新队友"), "新建返回填写的中文名字");

        begin(9, "{\"localPlayers\":[],\"initial\":\"Player2\",\"min\":1,\"max\":32}");
        picker = g_inputs[@9];
        ck(!picker.playerTable && [picker.field.stringValue isEqual:@"Player2"], "直接创建时打开名字输入框");
        [picker cancelPlayer:nil]; spin(.3);
        ck(g_calls == 1 && g_status == 0, "取消新建不产生用户");
        setenv("S2A_AUTOPLAY", "1", 1);
        ck(s2a_host_text_input(5, "{\"mode\":\"full\"}", cb) == 0, "⑥ 无人值守不弹、返回 0");
        setenv("S2A_TEXT_INPUT_UI", "1", 1);
        ck(s2a_host_text_input(6, "{\"mode\":\"full\"}", cb) == 1, "⑥ 验收开关照弹");
        spin(0.2); s2a_host_text_input_cancel(6); spin(0.3);
    }
    printf(bad ? "textinput_mac 单测有不通\n" : "textinput_mac 单测全过\n");
    return bad ? 1 : 0;
}
