// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 S2Arm contributors
// 游戏内「分配玩家」（#1606 ④）：交互同 Mac 启动器「分配玩家」（launchers/macos/frontend/Sources/NX2Apple/PlayerAssignment.swift）——
//   P1 起依次，在哪只手柄上按一下键就登记成下一位；「完成」写顺序表、「取消」不写，「恢复自动」删表（回到按连接顺序）。
//   表的格式与解析同 Mac（ios/pad_order_file.h）：order = 登记的顺序，dropped = 分配时连着却没登记的（不给玩家位），generation = 上次 + 1。
//   宿主 ios/controller.m planSlots 读这份表分槽，写完调 s2a_ios_pad_order_changed 立即重排。
//   系统手柄按名字 + 同名第几只认（同 Mac，名字不是设备号：同型号两只按连接先后区分），NS2 Pro 按通道玩家 0。键盘在 iOS 上只并进 1P，不列。
//   读按键靠 50 ms 轮询手柄状态，不动 controller.m 装好的回调；面板开着时游戏照常收输入（同 Mac 启动器面板）
#import <UIKit/UIKit.h>
#import <GameController/GameController.h>
#import "s2a_l10n.h"
#import "controller.h"

NSString *s2a_ios_pad_order_path(void);           // controller.m
uint32_t s2a_ios_ble_raw_buttons(int *ready);      // controller.m：NS2 Pro 最近一笔原始按键，ready = 连着
void s2a_ios_pad_order_changed(void);              // controller.m：表写好 / 删掉后重排

enum { kAssignMax = 4 };

@interface S2APlayerAssignController : UITableViewController
@property (nonatomic, copy) void (^closed)(void);
@end

@implementation S2APlayerAssignController {
    NSMutableArray<NSDictionary *> *_order;     // 登记顺序（顺序表 entry）
    NSMutableArray<NSString *> *_labels;        // 每位显示的手柄名
    NSMutableDictionary<NSString *, NSNumber *> *_held;   // 上一轮哪些手柄有键按着（只认「按下」那一下）
    NSTimer *_timer;
}

// 此刻连着的手柄：key（认人用）→ entry / 名字 / 有没有键按着
- (NSArray<NSDictionary *> *)online {
    NSMutableArray *out = [NSMutableArray array];
    NSMutableDictionary<NSString *, NSNumber *> *seen = [NSMutableDictionary dictionary];
    for (GCController *c in GCController.controllers) {
        if (!c.extendedGamepad) continue;
        NSString *name = c.vendorName ?: c.productCategory ?: @"GameController";
        int index = seen[name].intValue; seen[name] = @(index + 1);
        BOOL pressed = NO;
        for (GCControllerButtonInput *b in c.physicalInputProfile.allButtons) if (b.isPressed) { pressed = YES; break; }
        NSString *label = index ? [NSString stringWithFormat:@"%@ (%d)", name, index + 1] : name;
        [out addObject:@{@"key": [NSString stringWithFormat:@"sys|%@|%d", name, index], @"entry": @{@"name": name, @"index": @(index)},
                         @"label": label, @"pressed": @(pressed)}];
    }
    int ready = 0; uint32_t raw = s2a_ios_ble_raw_buttons(&ready);
    if (ready) [out addObject:@{@"key": @"ns2|0", @"entry": @{@"type": @"ns2", @"player": @0}, @"label": S2AL(@"assign.ns2pro"), @"pressed": @(raw != 0)}];
    return out;
}

- (BOOL)registered:(NSDictionary *)entry {
    for (NSDictionary *e in _order) if ([e isEqual:entry]) return YES;
    return NO;
}

- (void)poll {
    for (NSDictionary *d in [self online]) {
        BOOL now = [d[@"pressed"] boolValue], was = [_held[d[@"key"]] boolValue];
        _held[d[@"key"]] = @(now);
        if (!now || was || _order.count >= kAssignMax || [self registered:d[@"entry"]]) continue;
        [_order addObject:d[@"entry"]]; [_labels addObject:d[@"label"]];
        [self.tableView reloadData];
    }
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = S2AL(@"assign.title");
    _order = [NSMutableArray array]; _labels = [NSMutableArray array]; _held = [NSMutableDictionary dictionary];
    for (NSDictionary *d in [self online]) _held[d[@"key"]] = d[@"pressed"];   // 打开时已按着的键不算登记
    self.navigationItem.leftBarButtonItem = [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemCancel target:self action:@selector(cancel)];
    self.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemDone target:self action:@selector(done)];
    __weak S2APlayerAssignController *ws = self;
    _timer = [NSTimer scheduledTimerWithTimeInterval:0.05 repeats:YES block:^(NSTimer *t) { [ws poll]; }];
}

- (void)finish {
    [_timer invalidate]; _timer = nil;
    void (^closed)(void) = self.closed;
    [self.navigationController dismissViewControllerAnimated:YES completion:^{ if (closed) closed(); }];
}

- (void)cancel { [self finish]; }

- (void)done {
    if (!_order.count) { [self finish]; return; }   // 一位都没登记：不写，照旧
    NSString *path = s2a_ios_pad_order_path();
    NSDictionary *old = [NSJSONSerialization JSONObjectWithData:[NSData dataWithContentsOfFile:path] ?: [NSData data] options:0 error:nil];
    long generation = [old isKindOfClass:NSDictionary.class] && [old[@"generation"] respondsToSelector:@selector(longValue)] ? [old[@"generation"] longValue] : 0;
    NSMutableArray *dropped = [NSMutableArray array];
    for (NSDictionary *d in [self online]) if (![self registered:d[@"entry"]]) [dropped addObject:d[@"entry"]];
    NSData *data = [NSJSONSerialization dataWithJSONObject:@{@"generation": @(generation + 1), @"order": _order, @"dropped": dropped} options:0 error:nil];
    [NSFileManager.defaultManager createDirectoryAtPath:path.stringByDeletingLastPathComponent withIntermediateDirectories:YES attributes:nil error:nil];
    if (![data writeToFile:path atomically:YES]) {
        UIAlertController *a = [UIAlertController alertControllerWithTitle:S2AL(@"assign.saveFailed") message:nil preferredStyle:UIAlertControllerStyleAlert];
        [a addAction:[UIAlertAction actionWithTitle:S2AL(@"assign.ok") style:UIAlertActionStyleDefault handler:nil]];
        [self presentViewController:a animated:YES completion:nil];
        return;
    }
    NSLog(@"[S2A] 分配玩家：登记 %lu 位，没分配 %lu 只，第 %ld 次", (unsigned long)_order.count, (unsigned long)dropped.count, generation + 1);
    s2a_ios_pad_order_changed();
    [self finish];
}

- (void)restart { [_order removeAllObjects]; [_labels removeAllObjects]; [self.tableView reloadData]; }

- (void)automatic {
    [NSFileManager.defaultManager removeItemAtPath:s2a_ios_pad_order_path() error:nil];
    s2a_ios_pad_order_changed();
    [self finish];
}

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView { return 2; }
- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section { return section == 0 ? kAssignMax : 2; }
- (NSString *)tableView:(UITableView *)tableView titleForFooterInSection:(NSInteger)section { return section == 0 ? S2AL(@"assign.hint") : nil; }

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    UITableViewCell *cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleValue1 reuseIdentifier:nil];
    if (indexPath.section == 0) {
        NSInteger i = indexPath.row;
        cell.textLabel.text = [NSString stringWithFormat:@"P%ld", (long)i + 1];
        cell.detailTextLabel.text = i < (NSInteger)_labels.count ? _labels[i] : i == (NSInteger)_labels.count ? S2AL(@"assign.waiting") : nil;
        cell.selectionStyle = UITableViewCellSelectionStyleNone;
    } else {
        cell.textLabel.text = indexPath.row == 0 ? S2AL(@"assign.restart") : S2AL(@"assign.automatic");
        cell.textLabel.textColor = self.view.tintColor;
    }
    return cell;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    if (indexPath.section != 1) return;
    if (indexPath.row == 0) [self restart]; else [self automatic];
}
@end

// 齿轮菜单入口（vpad.m）：连着两只以上手柄，或已经分配过，才列
BOOL s2a_ios_player_assign_wanted(void) {
    int pads = 0, ready = 0;
    for (GCController *c in GCController.controllers) if (c.extendedGamepad) pads++;
    s2a_ios_ble_raw_buttons(&ready);
    return pads + ready >= 2 || [NSFileManager.defaultManager fileExistsAtPath:s2a_ios_pad_order_path()];
}

UIViewController *s2a_ios_player_assign(void (^closed)(void)) {
    S2APlayerAssignController *root = [[S2APlayerAssignController alloc] initWithStyle:UITableViewStyleInsetGrouped];
    root.closed = closed;
    UINavigationController *nav = [[UINavigationController alloc] initWithRootViewController:root];
    nav.modalInPresentation = YES;
    return nav;
}
