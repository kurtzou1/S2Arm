#pragma once
#import <Foundation/Foundation.h>

// Both Apple hosts update just the launcher roster, retaining its active player.
static inline int s2a_store_local_player(NSUserDefaults *defaults, const char *uid, const char *name, const char *folder) {
    @autoreleasepool {
        if (!defaults || !uid || !name || !folder) return 0;
        NSMutableArray *rows = [[defaults arrayForKey:@"S2ALocalPlayers"] mutableCopy] ?: [NSMutableArray array];
        for (NSDictionary *row in rows) {
            if ([row isKindOfClass:NSDictionary.class] && [row[@"uid"] isEqual:@(uid)])
                return [row[@"name"] isEqual:@(name)] && [row[@"folder"] isEqual:@(folder)];
        }
        if (![rows count]) [rows addObject:@{@"uid": @"", @"name": @"", @"folder": @"SaveData"}];
        [rows addObject:@{@"uid": @(uid), @"name": @(name), @"folder": @(folder)}];
        [defaults setObject:rows forKey:@"S2ALocalPlayers"];
        return [defaults synchronize];
    }
}
