// 系统键盘桥接 Mac 玩家前端（约定见 runtime/include/s2a_text_input.h，规则与 iOS 共用 s2a_text_input_rules.h）：
//   游戏要玩家输入文字时，在游戏窗口上挂一个 NSAlert 表单（输入框 + 确定 / 取消），可用系统输入法。
//   不到最短时「确定」置灰；游戏 / 服务线程不在这里等，弹框排到主线程，玩家点了再回调。
#import <AppKit/AppKit.h>
#include <stdatomic.h>
#include "s2a_text_input.h"
#import "s2a_text_input_rules.h"

@interface S2ATextInputMac : NSObject <NSTextFieldDelegate, NSTableViewDataSource, NSTableViewDelegate>
@property(nonatomic) int64_t ident;
@property(nonatomic) s2a_text_input_cb cb;
@property(nonatomic, copy) NSString *mode;
@property(nonatomic) NSInteger min, max;
@property(nonatomic, strong) NSAlert *alert;
@property(nonatomic, strong) NSTextField *field;
@property(nonatomic, weak) NSWindow *host;
@property(nonatomic) BOOL answered;
@property(nonatomic, strong) NSPanel *panel;
@property(nonatomic, copy) NSArray<NSString *> *players;
@property(nonatomic, copy) NSString *initialName, *playerReply;
@property(nonatomic, weak) NSButton *saveButton;
@property(nonatomic, weak) NSTableView *playerTable;
@property(nonatomic, strong) NSTimer *padTimer;
@end

static NSMutableDictionary<NSNumber *, S2ATextInputMac *> *g_inputs;   // 只在主线程读写

@implementation S2ATextInputMac
- (void)finish:(int)status {
    if (self.answered) return;
    self.answered = YES;
    [self.padTimer invalidate];
    [g_inputs removeObjectForKey:@(self.ident)];
    NSString *text = self.playerReply ?: s2a_text_input_clip(self.field.stringValue ?: @"", self.max);
    if (self.cb) self.cb(self.ident, status, status == 1 ? text.UTF8String : NULL);
}
- (void)controlTextDidChange:(NSNotification *)n {
    (void)n;
    NSTextView *editor = (NSTextView *)self.field.currentEditor;
    if (editor.hasMarkedText) return;   // 输入法正在组字：组完再收
    NSString *now = self.field.stringValue ?: @"";
    NSString *fit = s2a_text_input_clip(s2a_text_input_filter(now, self.mode), self.max);
    if (![fit isEqualToString:now]) self.field.stringValue = fit;
    self.saveButton.enabled = [fit stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet].length > 0;
    self.alert.buttons.firstObject.enabled = (NSInteger)fit.length >= self.min;
}
@end

static NSColor *playerCream(void) { return [NSColor colorWithSRGBRed:1 green:.94 blue:.84 alpha:1]; }

@interface S2APlayerRow : NSTableRowView
@end
@implementation S2APlayerRow
- (void)drawSelectionInRect:(NSRect)dirty {
    NSBezierPath *shape = [NSBezierPath bezierPathWithRoundedRect:NSInsetRect(self.bounds, 2, 2) xRadius:7 yRadius:7];
    [[playerCream() colorWithAlphaComponent:.15] setFill];
    [shape fill];
    [[playerCream() colorWithAlphaComponent:.65] setStroke];
    [shape stroke];
}
@end

@interface S2APlayerTable : NSTableView
@end
@implementation S2APlayerTable
- (void)keyDown:(NSEvent *)event {
    if (event.keyCode == 36 || event.keyCode == 76) [NSApp sendAction:self.action to:self.target from:self];
    else [super keyDown:event];
}
@end

static NSString *playerLabel(NSString *zh, NSString *en) {
    const char *lang = getenv("S2A_UI_LANGUAGE");
    NSString *language = lang ? @(lang) : NSLocale.preferredLanguages.firstObject;
    return [language hasPrefix:@"zh"] ? zh : en;
}

static _Atomic uint32_t player_sheet_buttons;
void s2a_mac_player_sheet_sample(uint32_t buttons) { atomic_store(&player_sheet_buttons, buttons); }

@implementation S2ATextInputMac (Players)
- (NSInteger)numberOfRowsInTableView:(NSTableView *)table { return self.players.count + 1; }

- (NSTableRowView *)tableView:(NSTableView *)table rowViewForRow:(NSInteger)row {
    return [S2APlayerRow new];
}

- (NSView *)tableView:(NSTableView *)table viewForTableColumn:(NSTableColumn *)column row:(NSInteger)row {
    BOOL add = row == (NSInteger)self.players.count;
    NSString *name = add ? playerLabel(@"创建新用户", @"Create new user") : self.players[row];
    NSTextField *label = [NSTextField labelWithString:name];
    label.font = [NSFont systemFontOfSize:14 weight:NSFontWeightSemibold];
    label.lineBreakMode = NSLineBreakByTruncatingTail;
    NSImageView *icon = [NSImageView imageViewWithImage:[NSImage imageWithSystemSymbolName:add ? @"plus.circle" : @"person.crop.circle" accessibilityDescription:nil]];
    icon.contentTintColor = playerCream();
    NSStackView *stack = [NSStackView stackViewWithViews:@[icon, label]];
    stack.spacing = 10;
    stack.edgeInsets = NSEdgeInsetsMake(0, 8, 0, 8);
    stack.distribution = NSStackViewDistributionFill;
    [icon.widthAnchor constraintEqualToConstant:20].active = YES;
    NSTableCellView *cell = [NSTableCellView new];
    stack.translatesAutoresizingMaskIntoConstraints = NO;
    [cell addSubview:stack];
    [NSLayoutConstraint activateConstraints:@[
        [stack.leadingAnchor constraintEqualToAnchor:cell.leadingAnchor],
        [stack.trailingAnchor constraintEqualToAnchor:cell.trailingAnchor],
        [stack.centerYAnchor constraintEqualToAnchor:cell.centerYAnchor]
    ]];
    return cell;
}

- (void)closePlayerSheet:(NSModalResponse)response {
    [self.host endSheet:self.panel returnCode:response];
}

- (void)cancelPlayer:(id)sender { [self closePlayerSheet:NSModalResponseCancel]; }

- (void)savePlayer:(id)sender {
    NSString *name = [self.field.stringValue stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    if (!name.length) return;
    self.playerReply = [@"new:" stringByAppendingString:name];
    [self closePlayerSheet:NSModalResponseOK];
}

- (void)choosePlayer:(NSTableView *)table {
    NSInteger row = table.selectedRow;
    if (row < 0) return;
    if (row == (NSInteger)self.players.count) { [self showPlayerPage:YES]; return; }
    self.playerReply = [@(row) stringValue];
    [self closePlayerSheet:NSModalResponseOK];
}

- (void)showPlayerPage:(BOOL)creating {
    CGFloat width = 360, margin = 20;
    CGFloat bodyHeight = creating ? 30 : MIN(self.players.count + 1, 6) * 38;
    CGFloat height = 112 + bodyHeight;
    [self.panel setContentSize:NSMakeSize(width, height)];
    NSView *surface = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, width, height)];
    surface.wantsLayer = YES;
    surface.layer.backgroundColor = [NSColor colorWithSRGBRed:.10 green:.10 blue:.11 alpha:1].CGColor;
    self.panel.contentView = surface;
    NSString *add = playerLabel(@"创建新用户", @"Create new user");
    NSString *title = creating ? add : playerLabel(@"选择 S2Arm 用户", @"Select S2Arm user");
    self.panel.title = title;
    NSTextField *heading = [NSTextField labelWithString:title];
    heading.font = [NSFont systemFontOfSize:18 weight:NSFontWeightSemibold];
    heading.frame = NSMakeRect(margin, height - 42, width - 2 * margin, 24);
    [surface addSubview:heading];
    NSButton *cancel = [NSButton buttonWithTitle:playerLabel(@"取消", @"Cancel") target:self action:@selector(cancelPlayer:)];
    cancel.keyEquivalent = @"\e";
    cancel.frame = NSMakeRect(margin, 12, 80, 30);
    [surface addSubview:cancel];
    NSRect body = NSMakeRect(margin, 54, width - 2 * margin, bodyHeight);
    if (creating) {
        self.playerTable = nil;
        NSTextField *field = [[NSTextField alloc] initWithFrame:body];
        field.placeholderString = playerLabel(@"用户名称", @"User name");
        field.stringValue = self.initialName;
        field.delegate = self;
        self.field = field;
        [surface addSubview:field];
        NSButton *save = [NSButton buttonWithTitle:playerLabel(@"创建", @"Create") target:self action:@selector(savePlayer:)];
        save.bezelColor = playerCream();
        save.contentTintColor = NSColor.blackColor;
        save.keyEquivalent = @"\r";
        save.frame = NSMakeRect(width - 100, 12, 80, 30);
        [surface addSubview:save];
        self.saveButton = save;
        [self.panel makeFirstResponder:field];
        [field selectText:nil];
    } else {
        NSScrollView *scroll = [[NSScrollView alloc] initWithFrame:body];
        scroll.hasVerticalScroller = YES;
        scroll.drawsBackground = NO;
        NSTableView *table = [[S2APlayerTable alloc] initWithFrame:scroll.bounds];
        NSTableColumn *column = [[NSTableColumn alloc] initWithIdentifier:@"user"];
        column.width = body.size.width;
        [table addTableColumn:column];
        table.columnAutoresizingStyle = NSTableViewLastColumnOnlyAutoresizingStyle;
        table.style = NSTableViewStylePlain;
        table.headerView = nil;
        table.backgroundColor = NSColor.clearColor;
        table.intercellSpacing = NSMakeSize(0, 2);
        table.rowHeight = 36;
        table.allowsEmptySelection = NO;
        table.delegate = self; table.dataSource = self;
        table.target = self; table.action = @selector(choosePlayer:);
        self.playerTable = table;
        scroll.documentView = table;
        [surface addSubview:scroll];
        [table reloadData];
        [table selectRowIndexes:[NSIndexSet indexSetWithIndex:0] byExtendingSelection:NO];
        [self.panel makeFirstResponder:table];
    }
}

- (void)presentPlayers:(NSDictionary *)args host:(NSWindow *)host {
    self.host = host;
    self.players = args[@"localPlayers"];
    self.initialName = args[@"initial"] ?: @"";
    self.panel = [[NSPanel alloc] initWithContentRect:NSZeroRect styleMask:NSWindowStyleMaskTitled backing:NSBackingStoreBuffered defer:NO];
    self.panel.titleVisibility = NSWindowTitleHidden;
    self.panel.titlebarAppearsTransparent = YES;
    self.panel.appearance = [NSAppearance appearanceNamed:NSAppearanceNameDarkAqua];
    [self showPlayerPage:!self.players.count];
    __block uint32_t previous = atomic_load(&player_sheet_buttons);
    self.padTimer = [NSTimer scheduledTimerWithTimeInterval:1.0/60 repeats:YES block:^(NSTimer *timer) {
        uint32_t buttons = atomic_load(&player_sheet_buttons);
        uint32_t pressed = buttons & ~previous;
        previous = buttons;
        if (!self.panel.isKeyWindow) return;
        NSTableView *table = self.playerTable;
        if (pressed & 2) [self cancelPlayer:nil];
        else if (pressed & 1) {
            if (table) [self choosePlayer:table];
            else if (self.saveButton.enabled) [self savePlayer:nil];
        } else if (table && (pressed & ((1u << 13) | (1u << 15)))) {
            NSInteger delta = (pressed & (1u << 13)) ? -1 : 1;
            NSInteger row = MAX(0, MIN(table.numberOfRows - 1, table.selectedRow + delta));
            [table selectRowIndexes:[NSIndexSet indexSetWithIndex:row] byExtendingSelection:NO];
            [table scrollRowToVisible:row];
        }
    }];
    [host beginSheet:self.panel completionHandler:^(NSModalResponse response) {
        [self finish:response == NSModalResponseOK ? 1 : 0];
    }];
}
@end

static void present(S2ATextInputMac *in, NSDictionary *a) {
    NSWindow *w = NSApp.keyWindow ?: NSApp.mainWindow ?: NSApp.windows.firstObject;
    if (a[@"localPlayers"]) {
        if (w) [in presentPlayers:a host:w];
        else [in finish:0];
        return;
    }
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
        [in.padTimer invalidate];
        in.answered = YES;   // 调用方自己按取消处理，不再回调
        [g_inputs removeObjectForKey:@(id)];
        if (in.panel.sheetParent) [in.host endSheet:in.panel returnCode:NSModalResponseAbort];
        else if (in.host && in.alert.window.sheetParent) [in.host endSheet:in.alert.window returnCode:NSModalResponseAbort];
        else if (NSApp.modalWindow == in.alert.window) [NSApp abortModal];
    });
}

// 游戏窗口判失焦用（#279，macos/front_mac.m，规则在 runtime/include/s2a_mac_focus.h）：w 是不是登记中、还没答复的系统输入框。只在主线程调
int s2a_text_input_mac_is_input_window(NSWindow *w) {
    if (!w) return 0;
    for (S2ATextInputMac *in in g_inputs.allValues) if (!in.answered && (in.alert.window == w || in.panel == w)) return 1;
    return 0;
}

// 启动即登记到公用分发（runtime/src/text_input.c）
__attribute__((constructor)) static void provide_text_input(void) { s2a_text_input_provide(begin_input, cancel_input); }
