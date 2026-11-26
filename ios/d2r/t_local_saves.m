// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 S2Arm contributors

#import "d2r_saves.h"
#include <assert.h>

static NSURL *child(NSURL *root, NSString *name) {
    return [root URLByAppendingPathComponent:name];
}

static void make_directory(NSURL *url) {
    assert([NSFileManager.defaultManager createDirectoryAtURL:url withIntermediateDirectories:YES
                                                    attributes:nil error:nil]);
}

static void make_role(NSURL *url) {
    make_directory(url);
    // Synthetic header only. The game is never started with this fixture.
    uint32_t fields[] = {CFSwapInt32HostToLittle(0xaa55aa55), 0, CFSwapInt32HostToLittle(16), 0};
    uint32_t checksum = 0;
    const uint8_t *bytes = (const uint8_t *)fields;
    for (size_t i = 0; i < sizeof fields; ++i)
        checksum = ((checksum << 1) | (checksum >> 31)) + bytes[i];
    fields[3] = CFSwapInt32HostToLittle(checksum);
    NSString *name = [url.lastPathComponent stringByAppendingPathExtension:@"d2s"];
    assert([[NSData dataWithBytes:fields length:sizeof fields] writeToURL:child(url, name) atomically:YES]);
}

int main(void) {
    @autoreleasepool {
        NSFileManager *fm = NSFileManager.defaultManager;
        NSURL *root = [fm.temporaryDirectory URLByAppendingPathComponent:NSUUID.UUID.UUIDString];
        NSURL *documents = child(root, @"Documents");
        NSURL *state = child(root, @"Support");
        NSURL *legacy = child(state, @"save");
        make_role(child(legacy, @"First"));
        NSURL *stash = child(legacy, @"shared");
        assert([@"synthetic shared save" writeToURL:stash atomically:YES encoding:NSUTF8StringEncoding error:nil]);

        NSError *error = nil;
        NSURL *save = S2AD2ROpenSave(documents, state, &error);
        assert(save && !error);
        assert([fm contentsEqualAtPath:save.path andPath:legacy.path]);
        NSURL *source = child(root, @"input/Second");
        make_role(source);
        assert(S2AD2RImportCharacter(source, save, &error));
        NSArray *expected = @[@"First", @"Second"];
        assert([S2AD2RCharacterNames(save, &error) isEqualToArray:expected]);
        assert(!S2AD2RImportCharacter(source, save, &error));
        assert([fm contentsEqualAtPath:stash.path andPath:child(save, @"shared").path]);
        assert(![fm fileExistsAtPath:child(legacy, @"Second").path]);
        assert([S2AD2ROpenSave(documents, state, nil) isEqual:save]);
        assert([fm moveItemAtURL:save toURL:child(root, @"moved") error:nil]);
        assert(!S2AD2ROpenSave(documents, state, &error));
        assert(![fm fileExistsAtPath:save.path]);

        make_role(child(save, @"Independent"));
        assert([fm removeItemAtURL:child(state, @"documents-save-v1") error:nil]);
        assert(!S2AD2ROpenSave(documents, state, &error));
        assert([fm fileExistsAtPath:child(save, @"Independent/Independent.d2s").path]);
        assert([fm fileExistsAtPath:child(legacy, @"First/First.d2s").path]);
        assert([fm removeItemAtURL:root error:nil]);
        puts("D2R local save tests passed");
    }
}
