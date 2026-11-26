// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 S2Arm contributors

#import "d2r_route.h"
#import "s2a_l10n.h"
#include <dlfcn.h>
#include <string.h>
#include "s2a_docs.h"

static void *backendImage;
static const S2AD2RBackend *activeBackend;

BOOL s2a_d2r_matches(const char *titleID) {
    id configured = [NSBundle.mainBundle objectForInfoDictionaryKey:@"S2AD2RTitleID"];
    return titleID && [configured isKindOfClass:NSString.class] &&
           strcmp(titleID, ((NSString *)configured).UTF8String) == 0;
}

BOOL s2a_d2r_is_active(void) {
    return activeBackend != NULL;
}

static const S2AD2RBackend *load_backend(NSString **reason) {
    if (@available(iOS 26.0, *)) {
        NSURL *url = [NSBundle.mainBundle.privateFrameworksURL
                       URLByAppendingPathComponent:@"S2AD2R.framework/S2AD2R"];
        if (!backendImage) backendImage = dlopen(url.fileSystemRepresentation, RTLD_NOW | RTLD_LOCAL);
        if (!backendImage) {
            const char *error = dlerror();
            NSLog(@"S2Arm D2R framework load: %s", error ?: "unknown");
            *reason = S2AL(@"d2r.load");
            return NULL;
        }
        S2AD2RBackendEntry entry = (S2AD2RBackendEntry)dlsym(backendImage, "s2a_d2r_backend");
        const S2AD2RBackend *backend = entry ? entry() : NULL;
        if (backend && backend->version == S2A_D2R_BACKEND_ABI &&
            backend->prepare && backend->start && backend->focus && backend->stop) return backend;
        *reason = S2AL(@"d2r.abi");
        return NULL;
    }
    *reason = S2AL(@"d2r.os");
    return NULL;
}

BOOL s2a_d2r_open(UIWindow *window, NSString **reason) {
    const S2AD2RBackend *backend = load_backend(reason);
    if (!backend) return NO;
    char path[4096];
    int length = s2a_container_docs(path, sizeof path);
    if (length < 0 || length >= (int)sizeof path) {
        *reason = S2AL(@"d2r.docs");
        return NO;
    }
    NSURL *documents = [NSURL fileURLWithPath:@(path) isDirectory:YES];
    NSString *support = NSSearchPathForDirectoriesInDomains(NSApplicationSupportDirectory, NSUserDomainMask, YES).firstObject;
    NSString *romfs = [documents.path stringByAppendingPathComponent:@"D2R Mobile"];
    NSString *state = [support stringByAppendingPathComponent:@"S2Arm/D2R Mobile"];
    UIViewController *view = backend->prepare(documents, romfs, state, window.bounds, reason);
    if (!view) return NO;
    activeBackend = backend;
    window.rootViewController = view;
    NSLog(@"S2Arm library selected D2R-Mobile backend and mounted the touch view");
    backend->start();
    if (window.windowScene.activationState == UISceneActivationStateForegroundActive) backend->focus(3);
    return YES;
}

void s2a_d2r_focus(int event) {
    if (activeBackend) activeBackend->focus(event);
}

void s2a_d2r_stop(void) {
    if (activeBackend) activeBackend->stop();
}
