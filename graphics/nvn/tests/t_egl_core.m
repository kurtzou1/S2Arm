// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 S2Arm contributors
// Khronos EGL 1.5 §§3.3, 3.4.3, 3.5.2, 3.8. Production registration,
// stack wrappers, native host, Widen and Metal; no replacement implementation.
#include "../gfx/gl/gl_int.h"
#include "../graphics_session.h"
#include <pthread.h>
int s2a_test_gl_session_resources(unsigned rounds);

static int checks, failures;
#define CHECK(c) do { checks++; if (!(c)) { failures++; fprintf(stderr, "FAIL line %d: %s\n", __LINE__, #c); } } while (0)
#define API(ret, name, ...) static ret (*name)(__VA_ARGS__)
API(void *, eglGetProcAddress, const char *);
API(EGLDisplay, eglGetDisplay, void *);
API(EGLBoolean, eglInitialize, EGLDisplay, EGLint *, EGLint *);
API(EGLBoolean, eglTerminate, EGLDisplay);
API(EGLint, eglGetError, void);
API(EGLBoolean, eglBindAPI, EGLenum);
API(EGLenum, eglQueryAPI, void);
API(const char *, eglQueryString, EGLDisplay, EGLint);
API(EGLBoolean, eglGetConfigAttrib, EGLDisplay, EGLConfig, EGLint, EGLint *);
API(EGLBoolean, eglGetConfigs, EGLDisplay, EGLConfig *, EGLint, EGLint *);
API(EGLSurface, eglCreatePbufferSurface, EGLDisplay, EGLConfig, const EGLint *);
API(EGLBoolean, eglQuerySurface, EGLDisplay, EGLSurface, EGLint, EGLint *);
API(EGLContext, eglCreateContext, EGLDisplay, EGLConfig, EGLContext, const EGLint *);
API(EGLBoolean, eglDestroyContext, EGLDisplay, EGLContext);
API(EGLBoolean, eglDestroySurface, EGLDisplay, EGLSurface);
API(EGLBoolean, eglMakeCurrent, EGLDisplay, EGLSurface, EGLSurface, EGLContext);
API(EGLBoolean, eglSwapBuffers, EGLDisplay, EGLSurface);
API(EGLBoolean, eglWaitGL, void);
API(EGLBoolean, eglWaitNative, EGLint);
API(EGLBoolean, eglReleaseThread, void);
API(void, glClearColor, GLfloat, GLfloat, GLfloat, GLfloat);
API(void, glClear, GLbitfield);
API(GLenum, glGetError, void);
#undef API

static void *other_thread(void *unused) {
    (void)unused;
    // Return a result, keeping the test counters single-threaded.
    int ok = eglQueryAPI() == 0x30A0 && eglGetError() == 0x3000;
    ok &= !eglBindAPI(0x30A1) && eglGetError() == 0x300C;
    ok &= eglBindAPI(0x30A2) && eglQueryAPI() == 0x30A2;
    ok &= eglReleaseThread() && eglQueryAPI() == 0x30A0;
    return (void *)(uintptr_t)ok;
}

static int load(void) {
    const char *missing[] = {"eglQueryString", "eglQueryAPI", "eglGetConfigAttrib", "eglCreatePbufferSurface", "eglWaitNative", "eglWaitGL"};
    eglGetProcAddress = gl_entry("eglGetProcAddress");
    CHECK(eglGetProcAddress != NULL);
    if (!eglGetProcAddress) return 0;
    CHECK(gl_entry("eglGetDisplay") != NULL); // Existing registration positive control.
    CHECK(eglGetProcAddress("eglGetDisplay") == gl_entry("eglGetDisplay"));
    CHECK(!gl_entry("eglNotAnActualEntry") && !eglGetProcAddress("eglNotAnActualEntry"));
    // 扩展别名交核心实现（D-RVTY）：核心吸收的同签名别名 = 核心入口；语义不同的、厂商后缀的、核心也没有的照旧回空
    CHECK(gl_entry("glActiveTexture") && eglGetProcAddress("glActiveTextureARB") == gl_entry("glActiveTexture"));
    CHECK(gl_entry("glBindBuffer") && eglGetProcAddress("glBindBufferARB") == gl_entry("glBindBuffer"));
    CHECK(gl_entry("glBlitFramebuffer") && eglGetProcAddress("glBlitFramebufferEXT") == gl_entry("glBlitFramebuffer"));
    CHECK(gl_entry("glGetProgramiv") && !eglGetProcAddress("glGetProgramivARB"));
    CHECK(gl_entry("glIsProgram") && !eglGetProcAddress("glIsProgramARB"));
    CHECK(!eglGetProcAddress("glBindBufferOffsetNV"));
    CHECK(!eglGetProcAddress("glSyncTextureINTEL"));
    for (unsigned i = 0; i < sizeof missing / sizeof *missing; i++) {
        void *entry = gl_entry(missing[i]);
        fprintf(stderr, "[egl-core] %s: %s\n", missing[i], entry ? "registered" : "NULL");
        CHECK(entry != NULL); CHECK(entry == eglGetProcAddress(missing[i]));
    }
    if (failures) return 0;
#define LOAD(name) name = eglGetProcAddress(#name); CHECK(name != NULL)
    LOAD(eglGetDisplay); LOAD(eglInitialize); LOAD(eglTerminate); LOAD(eglGetError); LOAD(eglBindAPI);
    LOAD(eglQueryAPI); LOAD(eglQueryString); LOAD(eglGetConfigAttrib); LOAD(eglGetConfigs);
    LOAD(eglCreatePbufferSurface); LOAD(eglQuerySurface); LOAD(eglCreateContext); LOAD(eglDestroyContext);
    LOAD(eglDestroySurface); LOAD(eglMakeCurrent); LOAD(eglSwapBuffers); LOAD(eglWaitGL); LOAD(eglWaitNative);
    LOAD(eglReleaseThread); LOAD(glClearColor); LOAD(glClear); LOAD(glGetError);
#undef LOAD
    return !failures;
}

int main(void) { @autoreleasepool {
    if (!load()) { fprintf(stderr, "[egl-core] %d checks, %d failures\n", checks, failures); return 1; }
    CHECK(s2a_graphics_native_begin_session() == 0);
    EGLDisplay d = eglGetDisplay(NULL); EGLint value = -1, major = 0, minor = 0;
    CHECK(!eglQueryString(d, 0x3053) && eglGetError() == 0x3001); // Uninitialized.
    CHECK(eglQueryString(NULL, 0x3055) && !*eglQueryString(NULL, 0x3055)); // No client extensions.
    CHECK(!eglQueryString((void *)2, 0x3053) && eglGetError() == 0x3008);
    CHECK(eglInitialize(d, &major, &minor));
    char version[16]; snprintf(version, sizeof version, "%d.%d", major, minor);
    CHECK(!strncmp(eglQueryString(d, 0x3054), version, strlen(version)));
    CHECK(!strcmp(eglQueryString(d, 0x308D), "OpenGL OpenGL_ES"));
    CHECK(strstr(eglQueryString(d, 0x3055), "EGL_KHR_create_context"));   // #2057：SDL 要 ES 3 上下文先查它
    CHECK(!eglQueryString(d, 0xDEAD) && eglGetError() == 0x300C);
    CHECK(eglQueryAPI() == 0x30A0 && eglBindAPI(0x30A2));
    CHECK(!eglBindAPI(0x30A1)); // Pending main-thread error survives another thread.
    pthread_t thread; void *result = NULL; CHECK(!pthread_create(&thread, NULL, other_thread, NULL));
    CHECK(!pthread_join(thread, &result) && (uintptr_t)result == 1);
    CHECK(eglQueryAPI() == 0x30A2 && eglGetError() == 0x300C && eglGetError() == 0x3000);
    EGLConfig cfg = NULL; EGLint count = 0;
    CHECK(eglGetConfigs(d, &cfg, 1, &count) && count == 1 && cfg);
    const EGLint attrs[][2] = {{0x3020,32},{0x3021,8},{0x3022,8},{0x3023,8},{0x3024,8},{0x3025,32},{0x3026,8},{0x3027,0x3051},{0x3031,0},{0x3032,0},{0x3033,5},{0x3039,0},{0x303A,0},{0x3040,0x4C},{0x3042,0}};
    for (unsigned i = 0; i < sizeof attrs / sizeof *attrs; i++) CHECK(eglGetConfigAttrib(d, cfg, attrs[i][0], &value) && value == attrs[i][1]);
    value = -17;
    CHECK(!eglGetConfigAttrib(d, cfg, 0xDEAD, &value) && value == -17 && eglGetError() == 0x3004);
    CHECK(!eglGetConfigAttrib(d, (void *)2, 0x3025, &value) && eglGetError() == 0x3005);
    CHECK(!eglGetConfigAttrib(d, cfg, 0x3025, NULL) && eglGetError() == 0x300C);
    CHECK(!eglCreatePbufferSurface(d, (void *)2, NULL) && eglGetError() == 0x3005);
    EGLint invalid[] = {0x3057,-1,0x3038};
    CHECK(!eglCreatePbufferSurface(d, cfg, invalid) && eglGetError() == 0x300C);
    EGLint unknown[] = {0xDEAD,1,0x3038};
    CHECK(!eglCreatePbufferSurface(d, cfg, unknown) && eglGetError() == 0x3004);
    EGLint texture[] = {0x3080,0x305E,0x3081,0x305F,0x3038};
    CHECK(!eglCreatePbufferSurface(d, cfg, texture) && eglGetError() == 0x3009);
    CHECK(!eglWaitNative(0xDEAD) && eglGetError() == 0x300C);
    CHECK(eglWaitNative(0x305B) && eglWaitGL()); // No current context is a specified no-op.
    CHECK(eglBindAPI(0x30A0));
    {   // 上下文属性（#2057）：版本不超出 ES 3.2 就建；超出回 EGL_BAD_MATCH；认不出的属性 / 标志位回 EGL_BAD_ATTRIBUTE
        EGLint es30[] = {0x3098,3,0x30FB,0,0x30FC,1,0x31BD,0x31BE,0x3038}, es33[] = {0x3098,3,0x30FB,3,0x3038}, es4[] = {0x3098,4,0x3038};
        EGLint bad_attr[] = {0xDEAD,1,0x3038}, bad_flags[] = {0x30FC,8,0x3038}, bad_reset[] = {0x31BD,7,0x3038};
        EGLContext ok = eglCreateContext(d, cfg, NULL, es30); CHECK(ok); CHECK(eglDestroyContext(d, ok));
        CHECK(!eglCreateContext(d, cfg, NULL, es33) && eglGetError() == 0x3009);
        CHECK(!eglCreateContext(d, cfg, NULL, es4) && eglGetError() == 0x3009);
        CHECK(!eglCreateContext(d, cfg, NULL, bad_attr) && eglGetError() == 0x3004);
        CHECK(!eglCreateContext(d, cfg, NULL, bad_flags) && eglGetError() == 0x3004);
        CHECK(!eglCreateContext(d, cfg, NULL, bad_reset) && eglGetError() == 0x3004);
        CHECK(eglBindAPI(0x30A2));   // 桌面 GL：4.5 核心配置档建得了，4.6 / 配置档 0 不行
        EGLint gl45[] = {0x3098,4,0x30FB,5,0x30FD,1,0x3038}, gl46[] = {0x3098,4,0x30FB,6,0x3038}, gl_noprof[] = {0x30FD,0,0x3038};
        ok = eglCreateContext(d, cfg, NULL, gl45); CHECK(ok); CHECK(eglDestroyContext(d, ok));
        CHECK(!eglCreateContext(d, cfg, NULL, gl46) && eglGetError() == 0x3009);
        CHECK(!eglCreateContext(d, cfg, NULL, gl_noprof) && eglGetError() == 0x3004);
        CHECK(eglBindAPI(0x30A0)); }
    EGLContext c = eglCreateContext(d, cfg, NULL, NULL); CHECK(c);
    EGLint size[] = {0x3057,37,0x3056,19,0x3038};
    EGLSurface s = eglCreatePbufferSurface(d, cfg, size); CHECK(s);
    CHECK(eglQuerySurface(d, s, 0x3057, &value) && value == 37);
    CHECK(eglQuerySurface(d, s, 0x3056, &value) && value == 19);
    CHECK(eglMakeCurrent(d, s, s, c));
    CHECK(!eglMakeCurrent(d, s, NULL, c) && eglGetError() == 0x3009);
    CHECK(gl_surface_color().width == 37 && gl_surface_color().height == 19);
    CHECK(gl_surface_depth().pixelFormat == MTLPixelFormatDepth32Float_Stencil8);
    CHECK(!gl_surface_front());
    uint64_t frames = atomic_load(&gl_n_frames);
    id<MTLTexture> color = gl_surface_color();
    glClearColor(1, 0.25f, 0.5f, 1); glClear(0x4000 | 0x0100 | 0x0400);
    // Read via the production GL queue. No glFinish/readback wait after eglWaitGL:
    // bypassing its commit/wait leaves the event unsignaled and bytes unwritten.
    const NSUInteger row = 256, bytes = row * 19;
    id<MTLBuffer> pixels = [gl_dev newBufferWithLength:bytes options:MTLResourceStorageModeShared]; CHECK(pixels);
    id<MTLBlitCommandEncoder> blit = gl_blit_enc();
    [blit copyFromTexture:color sourceSlice:0 sourceLevel:0 sourceOrigin:MTLOriginMake(0,0,0) sourceSize:MTLSizeMake(37,19,1) toBuffer:pixels destinationOffset:0 destinationBytesPerRow:row destinationBytesPerImage:bytes];
    uint64_t pending = gl_seq_ref();
    CHECK(eglBindAPI(0x30A2)); // eglWaitGL still waits the ES context, preserving this API.
    CHECK(eglWaitGL() && eglQueryAPI() == 0x30A2 && gl_ev.signaledValue >= pending);
    int bad_pixels = 0; uint8_t *data = pixels.contents;
    for (int y = 0; y < 19; y++) for (int x = 0; x < 37; x++) {
        uint8_t *p = data + y * row + x * 4;
        if (p[0] != 255 || abs(p[1]-64) > 1 || abs(p[2]-128) > 1 || p[3] != 255) bad_pixels++;
    }
    CHECK(!bad_pixels); fprintf(stderr, "[egl-core] pbuffer 37x19: %d/703 incorrect pixels\n", bad_pixels);
    CHECK(eglWaitNative(0x305B));
    CHECK(eglSwapBuffers(d, s) && gl_surface_color() == color && atomic_load(&gl_n_frames) == frames);
    CHECK(glGetError() == 0 && eglGetError() == 0x3000);
    // Destroying a current surface defers release until this thread unbinds it.
    __weak id<MTLTexture> weak_color = color; color = nil;
    CHECK(eglDestroySurface(d, s) && weak_color != nil);
    CHECK(eglMakeCurrent(d, NULL, NULL, NULL) && eglDestroyContext(d, c));
    CHECK(eglReleaseThread() && eglQueryAPI() == 0x30A0);
    EGLSurface zero = eglCreatePbufferSurface(d, cfg, NULL); CHECK(zero);
    CHECK(eglQuerySurface(d, zero, 0x3057, &value) && value == 0);
    CHECK(eglQuerySurface(d, zero, 0x3056, &value) && value == 0);
    CHECK(eglBindAPI(0x30A2));
    EGLContext desktop = eglCreateContext(d, cfg, NULL, NULL); CHECK(desktop);
    CHECK(eglMakeCurrent(d, zero, zero, desktop));
    uint64_t desktop_pending = gl_seq_ref();
    CHECK(eglWaitGL() && gl_seq_ref() == desktop_pending && eglQueryAPI() == 0x30A2);
    CHECK(eglMakeCurrent(d, NULL, NULL, NULL) && eglDestroyContext(d, desktop));
    CHECK(eglDestroySurface(d, zero));
    EGLint largest[] = {0x3057,32768,0x3056,1,0x3058,1,0x3038};
    EGLSurface reduced = eglCreatePbufferSurface(d, cfg, largest); CHECK(reduced);
    CHECK(eglQuerySurface(d, reduced, 0x3057, &value) && value <= 16384 && value > 0);
    CHECK(eglQuerySurface(d, reduced, 0x3058, &value) && value == 1);
    CHECK(eglDestroySurface(d, reduced));
    CHECK(eglTerminate(d));
    CHECK(s2a_graphics_native_request_stop() == 0);
    CHECK(s2a_graphics_native_shutdown_session() == 0);
    CHECK(s2a_test_gl_session_resources(10) == 0);
    fprintf(stderr, "[egl-core] %d checks, %d failures\n", checks, failures);
    return failures ? 1 : 0;
}}
