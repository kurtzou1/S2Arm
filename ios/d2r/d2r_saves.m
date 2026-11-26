// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 S2Arm contributors

#import "d2r_saves.h"
#import "../s2a_l10n.h"
#include <errno.h>
#include <stdio.h>
#include <string.h>
#include <sys/stat.h>

NSString *const S2AD2RSaveLocation = @"games/0100726014352000/S2A/ryujinx/bis/user/save";

static NSError *save_error(NSString *message) {
    return [NSError errorWithDomain:@"S2AD2RSave" code:1
                            userInfo:@{NSLocalizedDescriptionKey: message}];
}

static BOOL directory_status(NSURL *url, BOOL *exists, NSError **error) {
    struct stat status;
    if (lstat(url.fileSystemRepresentation, &status) == 0) {
        *exists = YES;
        if (S_ISDIR(status.st_mode)) return YES;
        if (error) *error = save_error(S2AL(@"d2r.directory"));
        return NO;
    }
    int code = errno;
    *exists = NO;
    if (code == ENOENT) return YES;
    if (error) *error = [NSError errorWithDomain:NSPOSIXErrorDomain code:code userInfo:nil];
    return NO;
}

static BOOL plain_tree(NSURL *root, NSError **error) {
    __block NSError *failure = nil;
    NSArray *keys = @[NSURLIsSymbolicLinkKey, NSURLIsRegularFileKey, NSURLIsDirectoryKey];
    NSDirectoryEnumerator<NSURL *> *iter = [NSFileManager.defaultManager
        enumeratorAtURL:root includingPropertiesForKeys:keys options:0
           errorHandler:^BOOL(NSURL *url, NSError *reason) {
               (void)url;
               failure = reason;
               return NO;
           }];
    if (!iter) failure = save_error(S2AL(@"d2r.unreadable"));
    for (NSURL *url in iter) {
        NSDictionary *values = [url resourceValuesForKeys:keys error:&failure];
        if (!values) break;
        if ([values[NSURLIsSymbolicLinkKey] boolValue] ||
            (![values[NSURLIsRegularFileKey] boolValue] && ![values[NSURLIsDirectoryKey] boolValue])) {
            failure = save_error(S2AL(@"d2r.special"));
            break;
        }
    }
    if (error) *error = failure;
    return failure == nil;
}

// Copy off to the side and let the filesystem enforce the no-replacement rule.
static BOOL install_directory(NSURL *source, NSURL *destination, NSError **error) {
    NSFileManager *fm = NSFileManager.defaultManager;
    NSURL *parent = destination.URLByDeletingLastPathComponent;
    if (![fm createDirectoryAtURL:parent withIntermediateDirectories:YES attributes:nil error:error])
        return NO;
    NSURL *stage = [parent URLByAppendingPathComponent:
        [@".d2r-save-" stringByAppendingString:NSUUID.UUID.UUIDString] isDirectory:YES];
    if (![fm createDirectoryAtURL:stage withIntermediateDirectories:NO attributes:nil error:error])
        return NO;
    NSURL *copy = [stage URLByAppendingPathComponent:@"payload" isDirectory:YES];
    BOOL ok = source ? [fm copyItemAtURL:source toURL:copy error:error]
                     : [fm createDirectoryAtURL:copy withIntermediateDirectories:NO attributes:nil error:error];
    if (ok && renamex_np(copy.fileSystemRepresentation, destination.fileSystemRepresentation, RENAME_EXCL)) {
        int code = errno;
        if (error) *error = [NSError errorWithDomain:NSPOSIXErrorDomain code:code userInfo:nil];
        ok = NO;
    }
    [fm removeItemAtURL:stage error:nil];
    return ok;
}

NSURL *S2AD2ROpenSave(NSURL *documents, NSURL *state, NSError **error) {
    NSFileManager *fm = NSFileManager.defaultManager;
    NSURL *save = [documents URLByAppendingPathComponent:S2AD2RSaveLocation isDirectory:YES];
    NSURL *marker = [state URLByAppendingPathComponent:@"documents-save-v1"];
    BOOL exists;
    if (!directory_status(save, &exists, error)) return nil;
    if ([fm fileExistsAtPath:marker.path]) {
        if (!exists) {
            if (error) *error = save_error(S2AL(@"d2r.missing"));
            return nil;
        }
        return save;
    }
    NSURL *legacy = [state URLByAppendingPathComponent:@"save" isDirectory:YES];
    BOOL oldExists;
    if (!directory_status(legacy, &oldExists, error) ||
        (oldExists && !plain_tree(legacy, error))) return nil;
    if (exists) {
        if (oldExists && (![fm contentsEqualAtPath:legacy.path andPath:save.path] ||
                          !plain_tree(save, error))) {
            if (error) *error = save_error(S2AL(@"d2r.conflict"));
            return nil;
        }
    } else {
        if (!install_directory(oldExists ? legacy : nil, save, error)) return nil;
    }
    if (![fm createDirectoryAtURL:state withIntermediateDirectories:YES attributes:nil error:error] ||
        ![@"1\n" writeToURL:marker atomically:YES encoding:NSUTF8StringEncoding error:error]) return nil;
    return save;
}

static BOOL character_name(NSString *name) {
    return name.length && ![name hasPrefix:@"."] &&
           [name rangeOfCharacterFromSet:[NSCharacterSet characterSetWithCharactersInString:@"/\\:"]].location == NSNotFound;
}

static BOOL valid_character(NSURL *folder, NSString *name) {
    if (!character_name(name)) return NO;
    NSURL *file = [folder URLByAppendingPathComponent:[name stringByAppendingPathExtension:@"d2s"]];
    struct stat status;
    if (lstat(file.fileSystemRepresentation, &status) || !S_ISREG(status.st_mode) ||
        status.st_size < 16 || status.st_size > 16 * 1024 * 1024) return NO;
    NSData *data = [NSData dataWithContentsOfURL:file];
    if (data.length != (NSUInteger)status.st_size) return NO;
    const uint8_t *bytes = data.bytes;
    uint32_t header[4];
    memcpy(header, bytes, sizeof header);
    if (CFSwapInt32LittleToHost(header[0]) != 0xaa55aa55 ||
        CFSwapInt32LittleToHost(header[2]) != data.length) return NO;
    uint32_t sum = 0;
    for (NSUInteger i = 0; i < data.length; ++i)
        sum = ((sum << 1) | (sum >> 31)) + ((i >= 12 && i < 16) ? 0 : bytes[i]);
    return sum == CFSwapInt32LittleToHost(header[3]);
}

NSArray<NSString *> *S2AD2RCharacterNames(NSURL *save, NSError **error) {
    NSArray<NSURL *> *entries = [NSFileManager.defaultManager contentsOfDirectoryAtURL:save
                                                    includingPropertiesForKeys:nil options:0 error:error];
    if (!entries) return nil;
    NSMutableArray<NSString *> *names = [NSMutableArray array];
    for (NSURL *entry in entries) {
        BOOL isDirectory;
        if (directory_status(entry, &isDirectory, NULL) && isDirectory &&
            valid_character(entry, entry.lastPathComponent)) [names addObject:entry.lastPathComponent];
    }
    return [names sortedArrayUsingSelector:@selector(localizedStandardCompare:)];
}

BOOL S2AD2RImportCharacter(NSURL *character, NSURL *save, NSError **error) {
    BOOL exists;
    NSString *name = character.lastPathComponent;
    if (!directory_status(character, &exists, error)) return NO;
    if (!exists || !valid_character(character, name)) {
        if (error) *error = save_error(S2AL(@"d2r.character"));
        return NO;
    }
    if (!plain_tree(character, error)) return NO;
    NSArray<NSString *> *entries = [NSFileManager.defaultManager contentsOfDirectoryAtPath:save.path error:error];
    if (!entries) return NO;
    for (NSString *entry in entries) {
        if ([entry caseInsensitiveCompare:name] != NSOrderedSame) continue;
        if (error) *error = save_error(S2AL(@"d2r.duplicate"));
        return NO;
    }
    return install_directory(character, [save URLByAppendingPathComponent:name isDirectory:YES], error);
}
