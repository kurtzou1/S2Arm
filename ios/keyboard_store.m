// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 S2Arm contributors
// 外接键盘键位的两层存取（#1987），规则见 keyboard_store.h
#import "keyboard_store.h"
#include "keyboard_map.h"

static NSString *const kKey = @"S2AKeyboardMap";   // 同 keyboard.h S2AKeyboardMapKey（那份头带 dispatch / UIKit 声明，这里只要键名）
static NSString *const kOffKey = @"S2AMouseOff";   // 同 keyboard.h S2AMouseOffKey（#2072）

static NSString *json_of(const s2a_input_config *c) {
    char json[4096]; int n = s2a_kbd_config_json(c, json, sizeof json);
    return n > 0 ? [[NSString alloc] initWithBytes:json length:(NSUInteger)n encoding:NSUTF8StringEncoding] : nil;
}
static int parse(NSString *s, s2a_input_config *out) {
    NSData *data = [s dataUsingEncoding:NSUTF8StringEncoding];
    return data.length && s2a_input_config_parse(data.bytes, data.length, out) == S2A_INPUT_CONFIG_OK;
}
static NSString *string_in(NSUserDefaults *d) { id v = [d objectForKey:kKey]; return [v isKindOfClass:NSString.class] && [v length] ? v : nil; }
static NSNumber *off_in(NSUserDefaults *d) { id v = [d objectForKey:kOffKey]; return [v isKindOfClass:NSNumber.class] ? v : nil; }
static int app_off(NSUserDefaults *app) { return app ? off_in(app).boolValue : 0; }   // 生效的缺省里关没关鼠标：App 级，没有 / 单款壳 = 打开

void s2a_kbd_store_effective_default(NSUserDefaults *app, s2a_input_config *out) {
    if (!app || !parse(string_in(app), out)) s2a_kbd_default(out);
}
void s2a_kbd_store_load(NSUserDefaults *game, NSUserDefaults *app, s2a_input_config *out) {
    NSString *s = string_in(game) ?: string_in(app);
    if (!parse(s, out)) s2a_kbd_default(out);
}
int s2a_kbd_store_mouse_off(NSUserDefaults *game, NSUserDefaults *app) {
    NSNumber *own = off_in(game);
    return own ? own.boolValue : app_off(app);
}
S2AKbdSource s2a_kbd_store_source(NSUserDefaults *game, NSUserDefaults *app) {
    if (string_in(game) || off_in(game)) return S2AKbdSourceCustom;
    return app && (string_in(app) || off_in(app)) ? S2AKbdSourceDefault : S2AKbdSourceStandard;
}
void s2a_kbd_store_save(NSUserDefaults *game, NSUserDefaults *app, const s2a_input_config *map, int mouse_off) {
    s2a_input_config def; s2a_kbd_store_effective_default(app, &def);
    NSString *json = json_of(map), *base = json_of(&def);
    if (!json || [json isEqualToString:base]) [game removeObjectForKey:kKey];
    else [game setObject:json forKey:kKey];
    if (!mouse_off == !app_off(app)) [game removeObjectForKey:kOffKey];   // 和默认一样：跟着默认走
    else [game setBool:mouse_off != 0 forKey:kOffKey];                   // 默认关掉时这款打开，也要单独存一个「打开」
}
void s2a_kbd_store_restore(NSUserDefaults *game) { [game removeObjectForKey:kKey]; [game removeObjectForKey:kOffKey]; }
NSDictionary *s2a_kbd_store_set_default(NSUserDefaults *game, NSUserDefaults *app, const s2a_input_config *map, int mouse_off) {
    if (!app) return nil;
    NSDictionary *snapshot = @{@"app": [app objectForKey:kKey] ?: NSNull.null, @"game": [game objectForKey:kKey] ?: NSNull.null,
                               @"appOff": [app objectForKey:kOffKey] ?: NSNull.null, @"gameOff": [game objectForKey:kOffKey] ?: NSNull.null};
    s2a_input_config ipad; s2a_kbd_default(&ipad);
    NSString *json = json_of(map);
    if (!json || [json isEqualToString:json_of(&ipad)]) [app removeObjectForKey:kKey];   // 设成和 iPad 缺省一样 = 没设过，不留一份等于缺省的记录
    else [app setObject:json forKey:kKey];
    if (mouse_off) [app setBool:YES forKey:kOffKey]; else [app removeObjectForKey:kOffKey];   // 打开 = iPad 缺省，同上不留记录
    [game removeObjectForKey:kKey]; [game removeObjectForKey:kOffKey];   // 这一款现在就是默认：跟着默认走
    return snapshot;
}
static void put_back(NSUserDefaults *d, NSString *key, id value) {
    if (value && value != NSNull.null) [d setObject:value forKey:key]; else [d removeObjectForKey:key];
}
void s2a_kbd_store_undo(NSUserDefaults *game, NSUserDefaults *app, NSDictionary *snapshot) {
    if (!app || !snapshot) return;
    put_back(app, kKey, snapshot[@"app"]); put_back(game, kKey, snapshot[@"game"]);
    put_back(app, kOffKey, snapshot[@"appOff"]); put_back(game, kOffKey, snapshot[@"gameOff"]);
}
