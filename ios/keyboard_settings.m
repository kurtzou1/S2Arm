// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 S2Arm contributors
// iPad 外接键盘改键页（#1869）：交互同 Mac 启动器改键（launchers/macos/frontend/Sources/NX2Apple/InputSettingsSheet.swift）——
//   点一个按键位后按键盘上的新键录入，Esc 取消；另有「常用键」（Return、Esc、空格、Tab、Shift、Ctrl、Option，同 Mac commonKeys）与「清除键盘按键」；
//   要绑的键已给了别的按键位时先问「改绑这个键？」，确认就解开旧的再绑（存下来的键位没有重复绑定，共用解析器拒收重复）。
//   iPad 在游戏里改：改完当场生效（Mac 在启动器里改、下次起局生效），按款存 schema 1 JSON（同 Mac input.json）。
//   鼠标部分（#1869 PR 2）同 Mac 启动器：每个按键位的「…」里选鼠标键（未绑定 / 左 / 右 / 中 / 侧键 1、2），另有一组「鼠标」——
//   移动鼠标时（转动视角 / 不起作用）、左右 / 上下灵敏度（0.1–10，步长 0.1）、左右 / 上下反过来、停手后视角回正；文案逐字取 Mac 启动器 input.mouse*。
//   页面开着时键盘 / 鼠标不进游戏（keyboard.m 静音）。入口：齿轮菜单第一层，「编辑虚拟按键」旁（vpad.m）
//   「管理键位」组（#1987）：导入 / 导出这一款的键位文件，做法同触屏布局页（vpad_settings.m）——选文件面板只认 JSON，导出先写临时目录再交面板；
//   文件就是按款存的那份 schema 1 JSON（与 Mac 启动器每款的 input.json 同格式），导入只改这一款
//   「设为所有游戏的默认」（#1987 第 2 条，维护方定：立即生效 + 约 5 秒内可撤销）：存取规则在 keyboard_store.m（两层：本款 / App 级 = 所有游戏的默认）。
//   点了就写 App 级，页底出提示条「已设为所有游戏的默认」带「撤销」，撤销把覆盖前的旧默认和这款原来的记录原样写回；开着旁白时提示条一直停到玩家自己关。
//   「恢复默认」回到所有游戏的默认（没设过就是标准键位）；页顶标这款用的是「自定义」还是「默认」，初始状态不标；单款壳不出这一行
#import <UIKit/UIKit.h>
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>
#import "s2a_l10n.h"
#include "keyboard.h"
#include "keyboard_map.h"
#include "mouse_map.h"
#include "settings.h"
#import "keyboard_store.h"

static const int kButtons[] = {0, 1, 2, 3, 6, 7, 8, 9, 4, 5, 10, 11, 13, 15, 12, 14};   // A B X Y L R ZL ZR 按下左右摇杆 + - 十字键上下左右
static const int kSticks[] = {17, 19, 16, 18, 21, 23, 20, 22};                         // 左摇杆上下左右、右摇杆上下左右
static const int kCommonKeys[] = {36, 53, 49, 48, 56, 59, 58};                         // 同 Mac InputSettingsSheet.commonKeys
// 组：0 按键、1 摇杆、2 鼠标、3 管理键位（导入 / 导出）
static const NSInteger kMouseSection = 2, kManageSection = 3;
static const NSTimeInterval kUndoSeconds = 5;   // 「设为所有游戏的默认」提示条停多久（#1987 维护方定约 5 秒；开着旁白时不自动收）

// 按键位显示名（同 Mac InputNames.target：A / B / X / Y / L / R / ZL / ZR 各语言相同，其余走文案）
static NSString *target_name(int t) {
    switch (t) {
        case 4: return S2AL(@"kbd.target.LS");
        case 5: return S2AL(@"kbd.target.RS");
        case 10: return S2AL(@"kbd.target.PLUS");
        case 11: return S2AL(@"kbd.target.MINUS");
        case 12: return S2AL(@"kbd.target.LEFT");
        case 13: return S2AL(@"kbd.target.UP");
        case 14: return S2AL(@"kbd.target.RIGHT");
        case 15: return S2AL(@"kbd.target.DOWN");
        case 16: return S2AL(@"kbd.target.LS_LEFT");
        case 17: return S2AL(@"kbd.target.LS_UP");
        case 18: return S2AL(@"kbd.target.LS_RIGHT");
        case 19: return S2AL(@"kbd.target.LS_DOWN");
        case 20: return S2AL(@"kbd.target.RS_LEFT");
        case 21: return S2AL(@"kbd.target.RS_UP");
        case 22: return S2AL(@"kbd.target.RS_RIGHT");
        case 23: return S2AL(@"kbd.target.RS_DOWN");
        default: return @(s2a_input_target_name(t));   // A B X Y L R ZL ZR
    }
}
// 鼠标键名同 Mac InputNames.mouseButton
static NSString *mouse_name(int b) {
    switch (b) {
        case 0: return S2AL(@"kbd.mouseButton.0");
        case 1: return S2AL(@"kbd.mouseButton.1");
        case 2: return S2AL(@"kbd.mouseButton.2");
        case 3: return S2AL(@"kbd.mouseButton.3");
        case 4: return S2AL(@"kbd.mouseButton.4");
        default: return S2AL(@"kbd.unbound");
    }
}
// 键名同 Mac InputNames.key：修饰键前缀 ⇧⌃⌥ + 键帽
static NSString *key_name(s2a_input_key b) {
    if (b.code < 0) return S2AL(@"kbd.unbound");
    static NSDictionary<NSNumber *, NSString *> *keys;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        keys = @{@0:@"A",@1:@"S",@2:@"D",@3:@"F",@4:@"H",@5:@"G",@6:@"Z",@7:@"X",@8:@"C",@9:@"V",@11:@"B",@12:@"Q",@13:@"W",@14:@"E",@15:@"R",@16:@"Y",@17:@"T",
                 @18:@"1",@19:@"2",@20:@"3",@21:@"4",@22:@"6",@23:@"5",@24:@"=",@25:@"9",@26:@"7",@27:@"-",@28:@"8",@29:@"0",@30:@"]",@31:@"O",@32:@"U",@33:@"[",
                 @34:@"I",@35:@"P",@36:@"Return",@37:@"L",@38:@"J",@39:@"'",@40:@"K",@41:@";",@42:@"\\",@43:@",",@44:@"/",@45:@"N",@46:@"M",@47:@".",@48:@"Tab",
                 @50:@"`",@53:@"Esc",@56:@"Shift",@58:@"Option",@59:@"Ctrl",@123:@"←",@124:@"→",@125:@"↓",@126:@"↑"};
    });
    NSString *mods = [NSString stringWithFormat:@"%@%@%@", b.modifiers & 1 ? @"⇧" : @"", b.modifiers & 2 ? @"⌃" : @"", b.modifiers & 4 ? @"⌥" : @""];
    NSString *cap = b.code == 49 ? S2AL(@"kbd.key.space") : b.code == 51 ? S2AL(@"kbd.key.delete") : keys[@(b.code)];
    if (!cap) cap = [NSString stringWithFormat:S2AL(@"kbd.key.code"), @(b.code).stringValue];
    return [mods stringByAppendingString:cap];
}
// 本款那一层 / App 级（= 所有游戏的默认；单款壳为 nil），见 keyboard_store.h
static NSUserDefaults *game_layer(NSUserDefaults *__strong *app) { NSUserDefaults *g = nil, *a = nil; s2a_ios_settings_layers(&g, &a); *app = a; return g; }
static void load_saved(s2a_input_config *out) { NSUserDefaults *app; NSUserDefaults *game = game_layer(&app); s2a_kbd_store_load(game, app, out); }
int s2a_ios_keyboard_customized(void) { return [s2a_ios_settings_defaults() stringForKey:S2AKeyboardMapKey].length > 0; }

// 导入没成：每类原因一句话（解析器的 s2a_input_config_error_message 是英文、给日志用，不上屏）
static NSString *import_error(int code) {
    switch (code) {
        case S2A_KBD_IMPORT_TOO_LARGE: return S2AL(@"kbd.import.err.tooLarge");
        case S2A_INPUT_CONFIG_JSON: return S2AL(@"kbd.import.err.json");
        case S2A_INPUT_CONFIG_SCHEMA: return S2AL(@"kbd.import.err.schema");
        case S2A_INPUT_CONFIG_DUPLICATE: return S2AL(@"kbd.import.err.duplicate");
        case S2A_INPUT_CONFIG_IO: return S2AL(@"kbd.import.err.read");
        default: return S2AL(@"kbd.import.err.invalid");   // 缺字段 / 无效按键位 / 无效绑定 / 超范围
    }
}

// 页底「已设为所有游戏的默认」提示条：没有关闭按钮，旁白的「擦除」手势（双指 Z）关掉它（开着旁白时提示条不自动收）
@interface S2AKbdToast : UIVisualEffectView
@property(nonatomic, copy) void (^escape)(void);
@end
@implementation S2AKbdToast
- (BOOL)accessibilityPerformEscape { if (self.escape) self.escape(); return YES; }
@end

@interface S2AKeyboardSettings : UITableViewController <UIDocumentPickerDelegate>
@property(nonatomic, copy) void (^closed)(void);
@end
@implementation S2AKeyboardSettings {
    s2a_input_config _map;
    int _recording;   // 在录的按键位；-1 = 没在录
    NSURL *_exportDirectory;   // 导出时写文件的临时目录（面板关掉就删）
    BOOL _importing;           // 选文件面板这次是导入（否则是导出）
    NSDictionary *_undoSnapshot;   // 「设为所有游戏的默认」覆盖前的旧值（撤销用；提示条关掉就丢）
    UIView *_toast;                // 页底提示条「已设为所有游戏的默认」+「撤销」
    NSTimer *_toastTimer;
}
- (instancetype)init {
    if (!(self = [super initWithStyle:UITableViewStyleInsetGrouped])) return nil;
    load_saved(&_map); _recording = -1;
    self.title = S2AL(@"kbd.title");
    self.navigationItem.leftBarButtonItem = [[UIBarButtonItem alloc] initWithTitle:S2AL(@"common.done") style:UIBarButtonItemStyleDone target:self action:@selector(done)];
    self.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc] initWithTitle:S2AL(@"kbd.restoreDefault") style:UIBarButtonItemStylePlain target:self action:@selector(restoreDefault)];
    self.navigationItem.rightBarButtonItem.accessibilityIdentifier = @"kbd.restoreDefault";
    return self;
}
- (void)viewWillAppear:(BOOL)animated { [super viewWillAppear:animated]; s2a_ios_keyboard_set_muted(1); [self updateSource]; }
- (void)viewDidDisappear:(BOOL)animated {
    [super viewDidDisappear:animated];
    if (self.navigationController.isBeingDismissed || !self.navigationController.presentingViewController) {
        s2a_ios_keyboard_record(NULL);
        [self dismissToast];
        if (self.closed) self.closed();
        self.closed = nil;
        s2a_ios_keyboard_set_muted(0);   // 虚拟按键先复位（closed），键盘再接着发
    }
}
- (void)done { [self.navigationController dismissViewControllerAnimated:YES completion:nil]; }
- (int)targetAt:(NSIndexPath *)path { return path.section == 0 ? kButtons[path.row] : kSticks[path.row]; }
- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView { return 4; }
- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    return section == 0 ? 16 : section == 1 ? 8 : section == kMouseSection ? 6 : [self hasAllGames] ? 3 : 2;
}
- (NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section {
    return section == 0 ? S2AL(@"kbd.section.buttons") : section == 1 ? S2AL(@"kbd.section.sticks") : section == kMouseSection ? S2AL(@"kbd.mouse") : S2AL(@"kbd.section.manage");
}
- (NSString *)tableView:(UITableView *)tableView titleForFooterInSection:(NSInteger)section {
    return section == 1 ? S2AL(@"kbd.footer") : section == kMouseSection ? S2AL(@"kbd.mouse.note") : section == kManageSection ? ([self hasAllGames] ? S2AL(@"kbd.manage.noteAll") : S2AL(@"kbd.manage.note")) : nil;
}
- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)path {
    if (path.section == kMouseSection) return [self mouseCell:path.row];
    if (path.section == kManageSection) return [self manageCell:path.row];
    int target = [self targetAt:path];
    UITableViewCell *cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleValue1 reuseIdentifier:nil];
    [self configure:cell target:target];
    cell.accessibilityIdentifier = [@"kbd.target." stringByAppendingString:@(s2a_input_target_name(target))];
    // 常用键 / 清除（同 Mac 选中按键位后的「常用键」下拉与「清除键盘按键」）
    __weak S2AKeyboardSettings *weakSelf = self;
    NSMutableArray<UIMenuElement *> *common = [NSMutableArray array];
    for (size_t i = 0; i < sizeof kCommonKeys / sizeof *kCommonKeys; i++) {
        s2a_input_key key = {kCommonKeys[i], 0};
        [common addObject:[UIAction actionWithTitle:key_name(key) image:nil identifier:nil handler:^(UIAction *a) { (void)a; [weakSelf bind:key to:target]; }]];
    }
    UIAction *clear = [UIAction actionWithTitle:S2AL(@"kbd.clear") image:[UIImage systemImageNamed:@"xmark.circle"] identifier:nil handler:^(UIAction *a) {
        (void)a; S2AKeyboardSettings *page = weakSelf; if (!page) return;
        [page stopRecording]; s2a_kbd_clear_target(&page->_map, target); [page save];   // 键盘、鼠标一起清（#2071）
    }];
    clear.attributes = UIMenuElementAttributesDestructive;
    // 鼠标键（同 Mac 启动器每个按键位的「鼠标」下拉：未绑定 + 0–4）
    NSMutableArray<UIMenuElement *> *mouse = [NSMutableArray array];
    for (int b = -1; b < S2A_MOUSE_BUTTONS; b++) {
        UIAction *pick = [UIAction actionWithTitle:mouse_name(b) image:nil identifier:nil handler:^(UIAction *a) { (void)a; [weakSelf bindMouse:b to:target]; }];
        if (_map.mouse[target] == b) pick.state = UIMenuElementStateOn;
        [mouse addObject:pick];
    }
    UIButton *more = [UIButton buttonWithType:UIButtonTypeSystem];
    [more setImage:[UIImage systemImageNamed:@"ellipsis.circle"] forState:UIControlStateNormal];
    more.menu = [UIMenu menuWithChildren:@[[UIMenu menuWithTitle:S2AL(@"kbd.common") image:[UIImage systemImageNamed:@"keyboard"] identifier:nil options:0 children:common],
                                           [UIMenu menuWithTitle:S2AL(@"kbd.mouse") image:[UIImage systemImageNamed:@"computermouse"] identifier:nil options:0 children:mouse], clear]];
    more.showsMenuAsPrimaryAction = YES;
    more.accessibilityLabel = S2AL(@"kbd.common");
    [more sizeToFit];
    cell.accessoryView = more;
    return cell;
}
// 一行的文字：按键位名 + 现在的键（在录时显示「请按新键，Esc 取消」）
- (void)configure:(UITableViewCell *)cell target:(int)target {
    UIListContentConfiguration *c = [UIListContentConfiguration valueCellConfiguration];
    c.text = target_name(target);
    BOOL recording = _recording == target;
    NSString *keys = key_name(_map.keyboard[target]);
    if (_map.mouse[target] >= 0) keys = [NSString stringWithFormat:@"%@ · %@", keys, mouse_name(_map.mouse[target])];   // 同时绑了鼠标键：一起显示
    c.secondaryText = recording ? S2AL(@"kbd.record") : keys;
    if (recording) c.secondaryTextProperties.color = self.view.tintColor;
    cell.contentConfiguration = c;
}
// 键位变了：只就地改看得见的行的文字，不整表重建（行高是估算的，整表重建会让列表跳一截；真机 11-21 用「…」菜单改键后整体下移约两行）
- (void)refreshVisibleRows {
    for (NSIndexPath *path in self.tableView.indexPathsForVisibleRows) {
        UITableViewCell *cell = [self.tableView cellForRowAtIndexPath:path];
        if (!cell || path.section == kManageSection) continue;   // 「管理键位」两行是固定文字，没有可刷新的
        if (path.section == kMouseSection) [self configureMouse:cell row:path.row];
        else [self configure:cell target:[self targetAt:path]];
        if (path.section < kMouseSection) {   // 「…」菜单里鼠标键的勾跟着换
            UIButton *more = (UIButton *)cell.accessoryView;
            UIMenu *menu = more.menu; NSMutableArray *children = [menu.children mutableCopy];
            if (children.count == 3) {
                int target = [self targetAt:path];
                UIMenu *m = children[1]; NSArray *picks = m.children;
                for (NSUInteger i = 0; i < picks.count; i++) ((UIAction *)picks[i]).state = _map.mouse[target] == (int)i - 1 ? UIMenuElementStateOn : UIMenuElementStateOff;
                more.menu = [menu menuByReplacingChildren:children];
            }
        }
    }
}
// ---- 「鼠标」组（同 Mac 启动器 mouseOptions 卡片）：0 移动鼠标时、1 左右灵敏度、2 上下灵敏度、3 左右反过来、4 上下反过来、5 停手后视角回正 ----
- (UITableViewCell *)mouseCell:(NSInteger)row {
    UITableViewCell *cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleValue1 reuseIdentifier:nil];
    cell.selectionStyle = UITableViewCellSelectionStyleNone;
    __weak S2AKeyboardSettings *weakSelf = self;
    if (row == 0) {
        UIButton *mode = [UIButton buttonWithType:UIButtonTypeSystem];
        mode.showsMenuAsPrimaryAction = YES; mode.changesSelectionAsPrimaryAction = YES;
        UIAction *camera = [UIAction actionWithTitle:S2AL(@"kbd.mouse.mode.camera") image:nil identifier:nil handler:^(UIAction *a) { (void)a; [weakSelf setMouseCamera:1]; }];
        UIAction *off = [UIAction actionWithTitle:S2AL(@"kbd.mouse.mode.off") image:nil identifier:nil handler:^(UIAction *a) { (void)a; [weakSelf setMouseCamera:0]; }];
        (_map.mouse_camera ? camera : off).state = UIMenuElementStateOn;
        mode.menu = [UIMenu menuWithChildren:@[camera, off]];
        [mode sizeToFit];
        cell.accessoryView = mode;
    } else if (row <= 2) {
        UISlider *slider = [UISlider new];
        slider.minimumValue = 0.1f; slider.maximumValue = 10; slider.tag = row;
        slider.value = (float)(row == 1 ? _map.sensitivity_x : _map.sensitivity_y);
        [slider addTarget:self action:@selector(sensitivityMoved:) forControlEvents:UIControlEventValueChanged];
        [slider addTarget:self action:@selector(sensitivityDone:) forControlEvents:UIControlEventTouchUpInside | UIControlEventTouchUpOutside | UIControlEventTouchCancel];
        slider.frame = CGRectMake(0, 0, 180, 32);
        cell.accessoryView = slider;
    } else {
        UISwitch *toggle = [UISwitch new]; toggle.tag = row;
        toggle.on = row == 3 ? _map.invert_x : row == 4 ? _map.invert_y : _map.recenter;
        [toggle addTarget:self action:@selector(toggleChanged:) forControlEvents:UIControlEventValueChanged];
        cell.accessoryView = toggle;
    }
    [self configureMouse:cell row:row];
    return cell;
}
- (void)configureMouse:(UITableViewCell *)cell row:(NSInteger)row {
    UIListContentConfiguration *c = [UIListContentConfiguration valueCellConfiguration];
    switch (row) {
        case 0: c.text = S2AL(@"kbd.mouse.mode"); break;
        case 1: c.text = S2AL(@"kbd.mouse.sensX"); c.secondaryText = [NSString stringWithFormat:@"%.1f", _map.sensitivity_x]; break;
        case 2: c.text = S2AL(@"kbd.mouse.sensY"); c.secondaryText = [NSString stringWithFormat:@"%.1f", _map.sensitivity_y]; break;
        case 3: c.text = S2AL(@"kbd.mouse.invertX"); break;
        case 4: c.text = S2AL(@"kbd.mouse.invertY"); break;
        default: c.text = S2AL(@"kbd.mouse.recenter"); break;
    }
    cell.contentConfiguration = c;
    if (row == 0) { UIButton *mode = (UIButton *)cell.accessoryView; [mode setTitle:_map.mouse_camera ? S2AL(@"kbd.mouse.mode.camera") : S2AL(@"kbd.mouse.mode.off") forState:UIControlStateNormal]; [mode sizeToFit]; }
    else if (row <= 2) ((UISlider *)cell.accessoryView).value = (float)(row == 1 ? _map.sensitivity_x : _map.sensitivity_y);
    else ((UISwitch *)cell.accessoryView).on = row == 3 ? _map.invert_x : row == 4 ? _map.invert_y : _map.recenter;
}
- (void)setMouseCamera:(int)on { [self stopRecording]; _map.mouse_camera = on; [self save]; }
// 灵敏度：拖动时按 0.1 一档只改读数，松手再存（同 Mac 启动器 step 0.1）
- (void)sensitivityMoved:(UISlider *)slider {
    double v = MAX(0.1, MIN(10, round(slider.value * 10) / 10));
    if (slider.tag == 1) _map.sensitivity_x = v; else _map.sensitivity_y = v;
    UITableViewCell *cell = [self.tableView cellForRowAtIndexPath:[NSIndexPath indexPathForRow:slider.tag inSection:kMouseSection]];
    UIListContentConfiguration *c = (UIListContentConfiguration *)cell.contentConfiguration;
    c.secondaryText = [NSString stringWithFormat:@"%.1f", v]; cell.contentConfiguration = c;
}
- (void)sensitivityDone:(UISlider *)slider { [self sensitivityMoved:slider]; [self stopRecording]; [self save]; }
- (void)toggleChanged:(UISwitch *)toggle {
    [self stopRecording];
    if (toggle.tag == 3) _map.invert_x = toggle.on; else if (toggle.tag == 4) _map.invert_y = toggle.on; else _map.recenter = toggle.on;
    [self save];
}
// 绑鼠标键：别的按键位已经用了这个键就先问（同 Mac 启动器 bind("mouse", …)）
- (void)bindMouse:(int)button to:(int)target {
    [self stopRecording];
    int holder = -1;
    if (button >= 0) for (int t = 0; t < S2A_INPUT_TARGET_COUNT; t++) if (t != target && _map.mouse[t] == button) holder = t;
    if (holder < 0) { _map.mouse[target] = button; [self save]; return; }
    NSString *body = [NSString stringWithFormat:S2AL(@"kbd.rebind.body"), target_name(holder), target_name(target), mouse_name(button)];
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:S2AL(@"kbd.rebind.title") message:body preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:S2AL(@"common.cancel") style:UIAlertActionStyleCancel handler:nil]];
    __weak S2AKeyboardSettings *weakSelf = self;
    [alert addAction:[UIAlertAction actionWithTitle:S2AL(@"kbd.rebind.confirm") style:UIAlertActionStyleDefault handler:^(UIAlertAction *a) {
        (void)a; S2AKeyboardSettings *page = weakSelf; if (!page) return;
        page->_map.mouse[holder] = -1; page->_map.mouse[target] = button; [page save];
    }]];
    [self presentViewController:alert animated:YES completion:nil];
}
// 点按键位：开始录（再点一次同一行取消）
- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)path {
    [tableView deselectRowAtIndexPath:path animated:YES];
    if (path.section == kMouseSection) return;   // 鼠标组用行内的开关 / 滑块 / 菜单
    if (path.section == kManageSection) { [self stopRecording]; if (path.row == 0) [self importKeys]; else if (path.row == 1) [self exportKeys]; else [self setAllGamesDefault]; return; }
    int target = [self targetAt:path];
    if (_recording == target) { [self stopRecording]; return; }
    [self stopRecording];
    _recording = target;
    [self refreshVisibleRows];
    __weak S2AKeyboardSettings *weakSelf = self;
    s2a_ios_keyboard_record(^(int code, unsigned modifiers) {
        S2AKeyboardSettings *page = weakSelf;
        if (!page || page->_recording != target) return;
        [page stopRecording];
        if (code >= 0) [page bind:(s2a_input_key){code, modifiers} to:target];   // Esc = 取消
    });
}
- (void)stopRecording {
    if (_recording < 0) return;
    _recording = -1;
    s2a_ios_keyboard_record(NULL);
    [self refreshVisibleRows];
}
// 绑键：别的按键位已经用了这个键就先问（同 Mac「改绑这个键？」）
- (void)bind:(s2a_input_key)key to:(int)target {
    [self stopRecording];
    int holder = -1;
    for (int t = 0; t < S2A_INPUT_TARGET_COUNT; t++)
        if (t != target && _map.keyboard[t].code == key.code && _map.keyboard[t].modifiers == key.modifiers) holder = t;
    if (holder < 0) { _map.keyboard[target] = key; [self save]; return; }
    NSString *body = [NSString stringWithFormat:S2AL(@"kbd.rebind.body"), target_name(holder), target_name(target), key_name(key)];
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:S2AL(@"kbd.rebind.title") message:body preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:S2AL(@"common.cancel") style:UIAlertActionStyleCancel handler:nil]];
    __weak S2AKeyboardSettings *weakSelf = self;
    [alert addAction:[UIAlertAction actionWithTitle:S2AL(@"kbd.rebind.confirm") style:UIAlertActionStyleDefault handler:^(UIAlertAction *a) {
        (void)a; S2AKeyboardSettings *page = weakSelf; if (!page) return;
        page->_map.keyboard[holder] = (s2a_input_key){-1, 0};
        page->_map.keyboard[target] = key;
        [page save];
    }]];
    [self presentViewController:alert animated:YES completion:nil];
}
// ---- 「管理键位」组：0 导入键位…、1 导出当前键位…、2 设为所有游戏的默认（多款容器才有） ----
- (UITableViewCell *)manageCell:(NSInteger)row {
    UITableViewCell *cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:nil];
    UIListContentConfiguration *c = [UIListContentConfiguration cellConfiguration];
    c.text = row == 0 ? S2AL(@"kbd.import") : row == 1 ? S2AL(@"kbd.export") : S2AL(@"kbd.setDefault");   // 文案键写字面量（ios_l10n_test 按字面量核对）
    c.textProperties.color = self.view.tintColor;
    c.image = [UIImage systemImageNamed:row == 0 ? @"square.and.arrow.down" : row == 1 ? @"square.and.arrow.up" : @"square.stack.3d.up"];
    cell.contentConfiguration = c;
    cell.accessibilityIdentifier = row == 0 ? @"kbd.import" : row == 1 ? @"kbd.export" : @"kbd.setDefault";
    return cell;
}
// 有没有「所有游戏」：多款容器选了游戏才有；单款壳 / 没选游戏（输入工作台）只有这一款，不出「设为所有游戏的默认」
- (BOOL)hasAllGames { NSUserDefaults *app; game_layer(&app); return app != nil; }
// 页顶标这款用的是哪一套：自定义 / 默认；初始状态（标准键位）不标
- (void)updateSource {
    NSUserDefaults *app; NSUserDefaults *game = game_layer(&app);
    S2AKbdSource source = s2a_kbd_store_source(game, app);
    NSString *text = source == S2AKbdSourceCustom ? S2AL(@"kbd.source.custom") : source == S2AKbdSourceDefault ? S2AL(@"kbd.source.default") : nil;
    if (!text) { self.tableView.tableHeaderView = nil; return; }
    UIView *box = [[UIView alloc] initWithFrame:CGRectMake(0, 0, MAX(self.tableView.bounds.size.width, 1), 36)];
    UILabel *label = [[UILabel alloc] initWithFrame:CGRectInset(box.bounds, 20, 6)];
    label.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    label.font = [UIFont preferredFontForTextStyle:UIFontTextStyleFootnote]; label.adjustsFontForContentSizeCategory = YES;
    label.textColor = UIColor.secondaryLabelColor; label.text = text;
    [box addSubview:label];
    box.accessibilityIdentifier = @"kbd.source";
    self.tableView.tableHeaderView = box;
}
// 设为所有游戏的默认：立即生效，页底提示条带「撤销」（#1987 维护方定）
- (void)setAllGamesDefault {
    NSUserDefaults *app; NSUserDefaults *game = game_layer(&app);
    if (!app) return;
    NSDictionary *snapshot = s2a_kbd_store_set_default(game, app, &_map);
    [self reloadFromStore];
    [self showUndo:snapshot];
}
- (void)undoAllGamesDefault {
    NSUserDefaults *app; NSUserDefaults *game = game_layer(&app);
    s2a_kbd_store_undo(game, app, _undoSnapshot);
    [self dismissToast];
    [self reloadFromStore];
}
// 存储变了（设默认 / 撤销 / 恢复默认）：重读这一款生效的键位，当场生效
- (void)reloadFromStore {
    [self stopRecording];
    load_saved(&_map);
    s2a_ios_keyboard_reload();
    [self refreshVisibleRows];
    [self updateSource];
}
- (void)showUndo:(NSDictionary *)snapshot {
    [self dismissToast];
    _undoSnapshot = snapshot;
    UIView *host = self.navigationController.view ?: self.view;
    UIColor *tint = self.view.tintColor;
    S2AKbdToast *toast = [[S2AKbdToast alloc] initWithEffect:[UIBlurEffect effectWithStyle:UIBlurEffectStyleSystemThickMaterial]];
    toast.layer.cornerRadius = 14; toast.clipsToBounds = YES;
    toast.translatesAutoresizingMaskIntoConstraints = NO; toast.accessibilityIdentifier = @"kbd.default.toast";
    __weak S2AKeyboardSettings *weakSelf = self;
    toast.escape = ^{ [weakSelf dismissToast]; };   // 没有关闭按钮：旁白用户用「擦除」手势（双指 Z）关
    UILabel *label = [UILabel new];
    label.text = S2AL(@"kbd.default.done"); label.numberOfLines = 2;   // 一行短句（同系统底部提示）；只在字号调得很大、一行放不下时折第二行
    label.font = [UIFont preferredFontForTextStyle:UIFontTextStyleSubheadline]; label.adjustsFontForContentSizeCategory = YES;
    // 「撤销」：浅蓝底 + 一层深一点的蓝，kUndoSeconds 内从右往左缩到零（看得出还剩多久能撤销），到点提示条收起
    UIButton *undo = [UIButton buttonWithType:UIButtonTypeSystem];
    UIButtonConfiguration *cfg = [UIButtonConfiguration plainButtonConfiguration];
    cfg.title = S2AL(@"kbd.default.undo");
    cfg.baseForegroundColor = tint;
    cfg.contentInsets = NSDirectionalEdgeInsetsMake(6, 12, 6, 12);
    cfg.titleTextAttributesTransformer = ^NSDictionary<NSAttributedStringKey, id> *(NSDictionary<NSAttributedStringKey, id> *attrs) {
        NSMutableDictionary *m = [attrs mutableCopy]; m[NSFontAttributeName] = [UIFont preferredFontForTextStyle:UIFontTextStyleHeadline]; return m;
    };
    undo.configuration = cfg;
    undo.backgroundColor = [tint colorWithAlphaComponent:0.14];
    undo.layer.cornerRadius = 10; undo.clipsToBounds = YES;
    undo.accessibilityIdentifier = @"kbd.default.undo";
    [undo addTarget:self action:@selector(undoAllGamesDefault) forControlEvents:UIControlEventTouchUpInside];
    [undo setContentCompressionResistancePriority:UILayoutPriorityRequired forAxis:UILayoutConstraintAxisHorizontal];
    [undo setContentHuggingPriority:UILayoutPriorityRequired forAxis:UILayoutConstraintAxisHorizontal];   // 按字宽，不吃一行里多出来的宽度
    UIStackView *row = [[UIStackView alloc] initWithArrangedSubviews:@[label, undo]];
    row.spacing = 16; row.alignment = UIStackViewAlignmentCenter; row.translatesAutoresizingMaskIntoConstraints = NO;
    // 文字先占满一行要的宽度（原先压缩优先级低，多行标签被挤成窄条、折成三行）；比整条的宽度上限（必须满足）低一级，放不下才折行
    [label setContentCompressionResistancePriority:UILayoutPriorityRequired - 1 forAxis:UILayoutConstraintAxisHorizontal];
    [label setContentHuggingPriority:UILayoutPriorityRequired - 1 forAxis:UILayoutConstraintAxisHorizontal];
    [toast.contentView addSubview:row];
    [host addSubview:toast];
    UILayoutGuide *safe = host.safeAreaLayoutGuide;
    [NSLayoutConstraint activateConstraints:@[
        [row.leadingAnchor constraintEqualToAnchor:toast.contentView.leadingAnchor constant:18],
        [row.trailingAnchor constraintEqualToAnchor:toast.contentView.trailingAnchor constant:-10],
        [row.topAnchor constraintEqualToAnchor:toast.contentView.topAnchor constant:10],
        [row.bottomAnchor constraintEqualToAnchor:toast.contentView.bottomAnchor constant:-10],
        [toast.centerXAnchor constraintEqualToAnchor:safe.centerXAnchor],
        [toast.bottomAnchor constraintEqualToAnchor:safe.bottomAnchor constant:-16],
        [toast.widthAnchor constraintLessThanOrEqualToAnchor:safe.widthAnchor constant:-32],
        [toast.widthAnchor constraintLessThanOrEqualToConstant:520],
    ]];
    [host layoutIfNeeded];   // 拿到「撤销」的实际大小，再铺那层蓝
    BOOL countdown = !UIAccessibilityIsVoiceOverRunning();   // 开着旁白：不自动收，那层蓝铺满不缩
    CGSize size = undo.bounds.size;
    CALayer *fill = [CALayer layer];
    fill.backgroundColor = [tint colorWithAlphaComponent:0.38].CGColor;
    fill.anchorPoint = CGPointMake(0, 0.5);   // 左边钉住，宽度缩 = 从右往左缩
    fill.position = CGPointMake(0, size.height / 2);
    fill.bounds = CGRectMake(0, 0, countdown ? 0 : size.width, size.height);
    [undo.layer insertSublayer:fill atIndex:0];
    if (countdown) {
        CABasicAnimation *shrink = [CABasicAnimation animationWithKeyPath:@"bounds.size.width"];
        shrink.fromValue = @(size.width); shrink.toValue = @0; shrink.duration = kUndoSeconds;
        [fill addAnimation:shrink forKey:@"countdown"];
    }
    _toast = toast;
    // 约 5 秒后自己收起；开着旁白时不自动收，停到玩家点「撤销」、用擦除手势关、或接着改键位（读完之前不该消失）
    if (countdown) _toastTimer = [NSTimer scheduledTimerWithTimeInterval:kUndoSeconds target:self selector:@selector(dismissToast) userInfo:nil repeats:NO];
    UIAccessibilityPostNotification(UIAccessibilityScreenChangedNotification, label);
}
- (void)dismissToast {
    [_toastTimer invalidate]; _toastTimer = nil;
    [_toast removeFromSuperview]; _toast = nil;
    _undoSnapshot = nil;
}
- (void)showImportError:(NSString *)reason {
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:S2AL(@"kbd.import.err.title") message:reason preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:S2AL(@"common.ok") style:UIAlertActionStyleDefault handler:nil]];
    [self presentViewController:alert animated:YES completion:nil];
}
- (void)importKeys {
    _importing = YES;
    UIDocumentPickerViewController *picker = [[UIDocumentPickerViewController alloc] initForOpeningContentTypes:@[UTTypeJSON] asCopy:YES];
    picker.delegate = self; picker.allowsMultipleSelection = NO;
    [self presentViewController:picker animated:YES completion:nil];
}
- (void)cleanExport {
    if (_exportDirectory) [NSFileManager.defaultManager removeItemAtURL:_exportDirectory error:nil];
    _exportDirectory = nil;
}
// 导出：这一款现在的键位（没改过就是缺省）写成文件，先放临时目录，再交选文件面板存到玩家选的位置
- (void)exportKeys {
    [self cleanExport]; _importing = NO;
    char json[4096]; int n = s2a_kbd_config_json(&_map, json, sizeof json);
    _exportDirectory = [NSURL fileURLWithPath:[NSTemporaryDirectory() stringByAppendingPathComponent:[@"s2arm-keys-" stringByAppendingString:NSUUID.UUID.UUIDString]] isDirectory:YES];
    const char *gid = getenv("S2A_LAUNCH_GAME_ID");
    NSString *name = gid && *gid ? [NSString stringWithFormat:@"%@ %s.json", S2AL(@"kbd.export.fileName"), gid] : [S2AL(@"kbd.export.fileName") stringByAppendingString:@".json"];
    NSURL *url = [_exportDirectory URLByAppendingPathComponent:name];
    NSError *error;
    if (n <= 0 || ![NSFileManager.defaultManager createDirectoryAtURL:_exportDirectory withIntermediateDirectories:NO attributes:nil error:&error]
        || ![[NSData dataWithBytes:json length:(NSUInteger)n] writeToURL:url options:NSDataWritingAtomic error:&error]) {
        [self cleanExport];
        UIAlertController *alert = [UIAlertController alertControllerWithTitle:S2AL(@"kbd.export.err.title") message:error.localizedDescription preferredStyle:UIAlertControllerStyleAlert];
        [alert addAction:[UIAlertAction actionWithTitle:S2AL(@"common.ok") style:UIAlertActionStyleDefault handler:nil]];
        [self presentViewController:alert animated:YES completion:nil];
        return;
    }
    UIDocumentPickerViewController *picker = [[UIDocumentPickerViewController alloc] initForExportingURLs:@[url] asCopy:YES];
    picker.delegate = self; [self presentViewController:picker animated:YES completion:nil];
}
- (void)documentPicker:(UIDocumentPickerViewController *)controller didPickDocumentsAtURLs:(NSArray<NSURL *> *)urls {
    if (!_importing) { [self cleanExport]; return; }
    NSURL *url = urls.firstObject; if (!url) return;
    BOOL scoped = [url startAccessingSecurityScopedResource];
    NSDictionary *attributes = [NSFileManager.defaultManager attributesOfItemAtPath:url.path error:nil];
    // 先看大小再读：超过上限的文件不整个读进内存（s2a_kbd_import 也会再查一次）
    NSData *data = [attributes[NSFileType] isEqualToString:NSFileTypeRegular] && [attributes fileSize] <= S2A_KBD_IMPORT_MAX_BYTES
        ? [NSData dataWithContentsOfURL:url options:0 error:nil] : nil;
    BOOL tooLarge = [attributes[NSFileType] isEqualToString:NSFileTypeRegular] && [attributes fileSize] > S2A_KBD_IMPORT_MAX_BYTES;
    if (scoped) [url stopAccessingSecurityScopedResource];
    if (!data) { [self showImportError:import_error(tooLarge ? S2A_KBD_IMPORT_TOO_LARGE : S2A_INPUT_CONFIG_IO)]; return; }
    s2a_input_config imported = _map;
    int r = s2a_kbd_import(data.bytes, data.length, &imported);
    if (r != S2A_KBD_IMPORT_OK) { [self showImportError:import_error(r)]; return; }
    _map = imported;
    [self save];   // 只写这一款，当场生效
}
- (void)documentPickerWasCancelled:(UIDocumentPickerViewController *)controller { [self cleanExport]; }
// 恢复默认：删掉这款的记录，回到所有游戏的默认（没设过就是标准键位）
- (void)restoreDefault {
    [self dismissToast];   // 接着改了：撤销不能再把这次的改动一起撤掉
    NSUserDefaults *app; NSUserDefaults *game = game_layer(&app); (void)app;
    s2a_kbd_store_restore(game);
    [self reloadFromStore];
}
// 存：和生效的缺省（所有游戏的默认，没设过是 iPad 缺省）相同就删掉这款的记录（以后跟着默认走）；否则按款存 schema 1 JSON。存完当场生效
- (void)save {
    [self dismissToast];   // 接着改了键位：撤销快照里没有这次的改动，提示条收起（不然撤销会把它一起抹掉）
    NSUserDefaults *app; NSUserDefaults *game = game_layer(&app);
    s2a_kbd_store_save(game, app, &_map);
    s2a_ios_keyboard_reload();
    [self refreshVisibleRows];
    [self updateSource];
}
@end

UIViewController *s2a_ios_keyboard_settings(void (^closed)(void)) {
    S2AKeyboardSettings *page = [S2AKeyboardSettings new];
    page.closed = closed;
    UINavigationController *navigation = [[UINavigationController alloc] initWithRootViewController:page];
    navigation.modalInPresentation = YES;
    return navigation;
}
