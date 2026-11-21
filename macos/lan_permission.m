// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 S2Arm contributors
// 本地联机·同一 Wi-Fi 的 Mac 适配（共用 iOS 那份 Bonjour 发现 ios/ldn_lan.m，Mac 宿主原先只链了 host_main.c 的空实现，Mac 与 iPhone 互相搜不到）。
//   ① s2a_lan_permission_then：直接开始。macOS 的「本地网络」授权框由系统按宿主 Info.plist 的 NSLocalNetworkUsageDescription 弹（pack/jobs/build.py compile_host），
//      不另弹说明框，也不替系统说「已授权」。
//   ② s2a_lan_permission_failed：发布本机中继或浏览失败 → 日志报红；每次启动最多提示一次（无人值守局只写日志），说清去哪里查本地网络权限和防火墙。
#import <AppKit/AppKit.h>
#include "../runtime/src/native.h"
#include "../runtime/include/s2a_unattended.h"

int s2a_ui_zh(void);   // front_mac.m：界面跟系统首选语言，中文出中文，其余英文

void s2a_lan_permission_then(int dev_mode, void (^go)(void)) {
    (void)dev_mode;
    go();
}

void s2a_lan_permission_failed(const char *what, NSDictionary *error) {
    NSInteger code = [error[NSNetServicesErrorCode] integerValue];
    NSInteger domain = [error[NSNetServicesErrorDomain] integerValue];
    LOG("【红】Mac 局域网：%s失败（domain=%ld code=%ld）", what, (long)domain, (long)code);
    static BOOL shown;
    if (shown || s2a_unattended()) return;
    NSWindow *window = NSApp.keyWindow;
    if (!window || window.attachedSheet) return;
    shown = YES;
    BOOL zh = s2a_ui_zh();
    NSAlert *alert = [NSAlert new];
    alert.messageText = zh ? @"本地联机找不到其他设备" : @"Local multiplayer can't find other devices";
    alert.informativeText = zh
        ? [NSString stringWithFormat:@"发布或查找同一 Wi-Fi 上的房间没有成功（错误 %ld / %ld）。请确认两台设备连着同一个 Wi-Fi，在「系统设置 › 隐私与安全性 › 本地网络」里允许 S2Arm Game，并确认防火墙允许它接受传入连接。改好后重新打开游戏，再进本地联机。", (long)domain, (long)code]
        : [NSString stringWithFormat:@"Publishing or finding rooms on the same Wi-Fi did not work (error %ld / %ld). Make sure both devices are on the same Wi-Fi, allow S2Arm Game under System Settings › Privacy & Security › Local Network, and make sure the firewall allows its incoming connections. Then reopen the game and enter local multiplayer again.", (long)domain, (long)code];
    [alert addButtonWithTitle:zh ? @"知道了" : @"OK"];
    [alert beginSheetModalForWindow:window completionHandler:nil];
}
