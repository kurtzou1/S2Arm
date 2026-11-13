// 系统键盘桥接 Mac 玩家前端（约定见 runtime/include/s2a_text_input.h，规则与 iOS 共用 s2a_text_input_rules.h）：
//   游戏要玩家输入文字时，在游戏窗口上挂一个 NSAlert 表单（输入框 + 确定 / 取消），可用系统输入法。
//   不到最短时「确定」置灰；游戏 / 服务线程不在这里等，弹框排到主线程，玩家点了再回调。
#import <AppKit/AppKit.h>
#include "s2a_text_input.h"
#import "s2a_text_input_rules.h"

@interface S2ATextInputMac : NSObject <NSTextFieldDelegate>
@property(nonatomic) int64_t ident;
@property(nonatomic) s2a_text_input_cb cb;
@property(nonatomic, copy) NSString *mode;
@property(nonatomic) NSInteger min, max;
@property(nonatomic, strong) NSAlert *alert;
@property(nonatomic, strong) NSTextField *field;
@property(nonatomic, weak) NSWindow *host;
@property(nonatomic) BOOL answered;
@end

static NSMutableDictionary<NSNumber *, S2ATextInputMac *> *g_inputs;   // 只在主线程读写

@implementation S2ATextInputMac
- (void)finish:(int)status {
    if (self.answered) return;
    self.answered = YES;
    [g_inputs removeObjectForKey:@(self.ident)];
    NSString *text = s2a_text_input_clip(self.field.stringValue ?: @"", self.max);
    if (self.cb) self.cb(self.ident, status, status == 1 ? text.UTF8String : NULL);
}
- (void)controlTextDidChange:(NSNotification *)n {
    (void)n;
    NSTextView *editor = (NSTextView *)self.field.currentEditor;
    if (editor.hasMarkedText) return;   // 输入法正在组字：组完再收
    NSString *now = self.field.stringValue ?: @"";
    NSString *fit = s2a_text_input_clip(s2a_text_input_filter(now, self.mode), self.max);
    if (![fit isEqualToString:now]) self.field.stringValue = fit;
    self.alert.buttons.firstObject.enabled = (NSInteger)fit.length >= self.min;
}
@end

static void present(S2ATextInputMac *in, NSDictionary *a) {
    NSWindow *w = NSApp.keyWindow ?: NSApp.mainWindow ?: NSApp.windows.firstObject;
    NSAlert *alert = [NSAlert new];
    alert.messageText = [a[@"header"] length] ? a[@"header"] : @"输入";
    NSMutableArray *lines = [NSMutableArray array];
    if ([a[@"subtitle"] length]) [lines addObject:a[@"subtitle"]];
    if (in.min > 1 || in.max > 0) [lines addObject:in.max > 0 ? [NSString stringWithFormat:@"%ld–%ld 个字", (long)MAX(in.min, 0), (long)in.max] : [NSString stringWithFormat:@"至少 %ld 个字", (long)in.min]];
    alert.informativeText = [lines componentsJoinedByString:@"\n"];
    [alert addButtonWithTitle:[a[@"submit"] length] ? a[@"submit"] : @"确定"];
    [alert addButtonWithTitle:@"取消"];
    NSTextField *f = [[NSTextField alloc] initWithFrame:NSMakeRect(0, 0, 260, 24)];
    f.stringValue = s2a_text_input_clip(s2a_text_input_filter(a[@"initial"] ?: @"", in.mode), in.max);
    f.placeholderString = [a[@"guide"] length] ? a[@"guide"] : nil;
    f.delegate = in;
    alert.accessoryView = f;
    in.alert = alert; in.field = f; in.host = w;
    alert.buttons.firstObject.enabled = (NSInteger)f.stringValue.length >= in.min;
    void (^done)(NSModalResponse) = ^(NSModalResponse r) { [in finish:r == NSAlertFirstButtonReturn ? 1 : 0]; };
    if (w) {
        [alert beginSheetModalForWindow:w completionHandler:done];
    } else {
        done([alert runModal]);
    }
    [alert.window makeFirstResponder:f];
}

static int begin_input(int64_t id, const char *json, s2a_text_input_cb cb) {
    if (!s2a_text_input_interactive() || !json || !cb) return 0;
    NSDictionary *a = [NSJSONSerialization JSONObjectWithData:[NSData dataWithBytes:json length:strlen(json)] options:0 error:nil];
    if (![a isKindOfClass:NSDictionary.class]) return 0;
    S2ATextInputMac *in = [S2ATextInputMac new];
    in.ident = id; in.cb = cb; in.mode = [a[@"mode"] isKindOfClass:NSString.class] ? a[@"mode"] : @"full";
    in.min = [a[@"min"] integerValue]; in.max = [a[@"max"] integerValue];
    dispatch_async(dispatch_get_main_queue(), ^{
        if (!g_inputs) g_inputs = [NSMutableDictionary dictionary];
        g_inputs[@(id)] = in;
        present(in, a);
    });
    return 1;
}

static void cancel_input(int64_t id) {
    dispatch_async(dispatch_get_main_queue(), ^{
        S2ATextInputMac *in = g_inputs[@(id)];
        if (!in) return;
        in.answered = YES;   // 调用方自己按取消处理，不再回调
        [g_inputs removeObjectForKey:@(id)];
        if (in.host && in.alert.window.sheetParent) [in.host endSheet:in.alert.window returnCode:NSModalResponseAbort];
        else if (NSApp.modalWindow == in.alert.window) [NSApp abortModal];
    });
}

// 游戏窗口判失焦用（#279，macos/front_mac.m，规则在 runtime/include/s2a_mac_focus.h）：w 是不是登记中、还没答复的系统输入框。只在主线程调
int s2a_text_input_mac_is_input_window(NSWindow *w) {
    if (!w) return 0;
    for (S2ATextInputMac *in in g_inputs.allValues) if (!in.answered && in.alert.window == w) return 1;
    return 0;
}

// 启动即登记到公用分发（runtime/src/text_input.c）
__attribute__((constructor)) static void provide_text_input(void) { s2a_text_input_provide(begin_input, cancel_input); }
