// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 S2Arm contributors

#import "d2r_backend_api.h"
#import "../s2a_l10n.h"
#import "d2r_save_manager.h"
#import "d2r_saves.h"
static NSString *g_embedded_docs;
static NSURL *g_embedded_save;

// Keep the upstream helpers in the same translation unit as the original front end.
// The unified host owns UIApplicationMain and the window scene.
#define main d2r_unused_standalone_entry
#include "main.m"
#undef main

static void embedded_start(void);

static UIViewController *embedded_prepare_game(NSString *romfs, NSString *sessionRoot, NSURL *save,
                                               CGRect bounds, NSString **reason) {
#if !TARGET_OS_SIMULATOR
    if (g_host_up) {
        *reason = S2AL(@"d2r.reopen");
        return nil;
    }
    id<MTLDevice> device = MTLCreateSystemDefaultDevice();
    if (![device supportsFamily:MTLGPUFamilyMetal4] || !device.supportsBCTextureCompression) {
        *reason = S2AL(@"d2r.gpu");
        return nil;
    }
    NSString *integrityError = pack_check();
    if (integrityError) {
        *reason = integrityError;
        return nil;
    }
    NSString *data = [romfs stringByAppendingPathComponent:@"data"];
    if (!dm_romfs_validate(data.fileSystemRepresentation, g_romfs_why, sizeof g_romfs_why)) {
        *reason = [NSString stringWithFormat:S2AL(@"d2r.resources"), g_romfs_why];
        return nil;
    }
    NSError *error = nil;
    if (![NSFileManager.defaultManager createDirectoryAtPath:[sessionRoot stringByAppendingPathComponent:@"temp"]
                               withIntermediateDirectories:YES attributes:nil error:&error]) {
        *reason = error.localizedDescription;
        return nil;
    }
    g_romfs = [romfs copy];
    g_mode = @"boot";
    g_T[2] = since_start();
#endif
    DmGameVC *controller = [DmGameVC new];
    controller.view = front_ios_view(bounds);
    if (!front_metal_layer()) {
        *reason = S2AL(@"d2r.metal");
        return nil;
    }
    // The simulator only verifies UI wiring. It cannot start the iOS guest.
#if !TARGET_OS_SIMULATOR
    g_embedded_docs = [sessionRoot copy];
    g_embedded_save = save;
#endif
    return controller;
}

static UIViewController *embedded_prepare(NSURL *documents, NSString *romfs, NSString *sessionRoot,
                                          CGRect bounds, NSString **reason) {
#if TARGET_OS_SIMULATOR
    if (![[NSBundle.mainBundle objectForInfoDictionaryKey:@"S2AD2RViewProbe"] boolValue]) {
        *reason = S2AL(@"d2r.simulator");
        return nil;
    }
#endif
    NSError *error = nil;
    NSURL *save = S2AD2ROpenSave(documents, [NSURL fileURLWithPath:sessionRoot isDirectory:YES], &error);
    if (!save) {
        *reason = error.localizedDescription;
        return nil;
    }
    NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
    NSString *manage = @"S2ASaveManageOnOpen.0100726014352000";
    if (![defaults boolForKey:manage])
        return embedded_prepare_game(romfs, sessionRoot, save, bounds, reason);

    [defaults removeObjectForKey:manage];
    return S2AD2RSaveManager(save, ^(UIViewController *manager) {
        UIWindow *window = manager.view.window;
        if (!window) return;
        NSString *message = nil;
        UIViewController *game = embedded_prepare_game(romfs, sessionRoot, save, window.bounds, &message);
        if (!game) {
            UIAlertController *alert = [UIAlertController alertControllerWithTitle:S2AL(@"d2r.title")
                message:message preferredStyle:UIAlertControllerStyleAlert];
            [alert addAction:[UIAlertAction actionWithTitle:S2AL(@"common.ok") style:UIAlertActionStyleDefault handler:nil]];
            [manager presentViewController:alert animated:YES completion:nil];
            return;
        }
        window.rootViewController = game;
        embedded_start();
        if (g_host_up && window.windowScene.activationState == UISceneActivationStateForegroundActive)
            front_ios_focus_event(3);
    });
}

static void embedded_start(void) {
    if (g_host_up || !g_embedded_docs) return;
    struct rlimit limits;
    if (getrlimit(RLIMIT_NOFILE, &limits) == 0) {
        g_nofile_was = (int)limits.rlim_cur;
        rlim_t wanted = limits.rlim_max < 4096 ? limits.rlim_max : 4096;
        if (limits.rlim_cur < wanted) {
            limits.rlim_cur = wanted;
            if (setrlimit(RLIMIT_NOFILE, &limits) != 0) limits.rlim_cur = (rlim_t)g_nofile_was;
        }
        g_nofile_now = (int)limits.rlim_cur;
    }
    NSString *log = [g_embedded_docs stringByAppendingPathComponent:@"boot.txt"];
    g_log = open(log.fileSystemRepresentation, O_WRONLY | O_CREAT | O_TRUNC, 0644);
    if (g_log >= 0) dup2(g_log, STDERR_FILENO);
    g_host_up = 1;
    plog("boot: embedded D2R backend selected by S2Arm");
    setenv("DM_SAVE", g_embedded_save.fileSystemRepresentation, 1);
    plog("boot: S2Arm managed save %s", g_embedded_save.fileSystemRepresentation);
    boot_begin();
    front_ios_lifecycle_install();
    run_boot();
}

static void embedded_focus(int event) {
    if (g_host_up) front_ios_focus_event(event);
}

static void embedded_stop(void) {
    if (g_host_up) dm_host_shutdown("S2Arm scene disconnected");
}

__attribute__((visibility("default")))
const S2AD2RBackend *s2a_d2r_backend(void) {
    static const S2AD2RBackend api = {
        .version = S2A_D2R_BACKEND_ABI,
        .prepare = embedded_prepare,
        .start = embedded_start,
        .focus = embedded_focus,
        .stop = embedded_stop,
    };
    return &api;
}
