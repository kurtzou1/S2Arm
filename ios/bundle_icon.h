// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 S2Arm contributors
// 包里 AppIcon 的文件名（加载页 / 出错页没有资源包 icon.jpg 时退回用它，ios/loadpage.m game_icon）：只靠 Foundation，单测 runtime/tests/t_bundle_icon.m。
//   Info.plist 的 CFBundleIcons 两种形状：iPhone / iPad 包（pack/app_bundle.py）CFBundlePrimaryIcon = {CFBundleIconFiles: [名字…]}，取最后一个；
//   Apple TV 包（pack/tv_icon.py 合进的资源目录产物）CFBundlePrimaryIcon = 品牌资源名（字符串），直接用它。
//   别的形状（缺键、类型不对）回 nil，不抛异常（原先按字典连取两层，Apple TV 上对字符串取下标抛 NSInvalidArgumentException，点开始即闪退）
#pragma once
#import <Foundation/Foundation.h>
static inline NSString *s2a_bundle_icon_name(id icons) {
    id primary = [icons isKindOfClass:NSDictionary.class] ? ((NSDictionary *)icons)[@"CFBundlePrimaryIcon"] : nil;
    if ([primary isKindOfClass:NSString.class]) return [(NSString *)primary length] ? primary : nil;
    id files = [primary isKindOfClass:NSDictionary.class] ? ((NSDictionary *)primary)[@"CFBundleIconFiles"] : nil;
    id name = [files isKindOfClass:NSArray.class] ? [(NSArray *)files lastObject] : nil;
    return [name isKindOfClass:NSString.class] && [(NSString *)name length] ? name : nil;
}
