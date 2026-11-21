// Android provider for the FPS core's platform accessors (runtime/src/fps.c,
// started by native/runtime/runtime.c). Only game data goes through here; the
// key-page slots and the frame-step page are host pages that fps.c stores itself.
#ifndef _GNU_SOURCE
#define _GNU_SOURCE
#endif
#include "../../platform/plat.h"
#include "runtime/tracking/readonly_copy.h"
#include <errno.h>
#include <pthread.h>
#include <stdio.h>
#include <stdlib.h>

int s2a_mem_write32_checked(uint64_t address, uint32_t value);

int plat_mem_read32(uint64_t address, uint32_t *value) {
    if (!value) return EINVAL;
    uint32_t copy;
    int error = s2a_android_copy_guest_readonly(address, &copy, sizeof copy);
    if (error) return error;
    *value = copy;
    return 0;
}

int plat_mem_write32(uint64_t address, uint32_t value) {
#if defined(__OHOS__)
    // OHOS 模块页来自签名载体（私有映射），建不出共享别名；键页由装载器装在宿主内存、fps.c 已 key_rw 改成可写，直接写。
    int s2a_ohos_key_page_store32(uint64_t, uint32_t);
    if (!s2a_ohos_key_page_store32(address, value)) return 0;
#endif
    // 裁定口径：内部不自旋。checked 返回什么就透传什么（正 errno），EAGAIN 由 fps.c 下一帧再试。
    int e = -s2a_mem_write32_checked(address, value);
#if defined(__OHOS__)
    // 游戏视角可写、但私有模块页建不出别名：模块映像内直接写（见 s2a_ohos_module_store32）。
    if (e == EINVAL || e == EOPNOTSUPP) {
        int s2a_ohos_module_store32(uint64_t, uint32_t);
        if (!s2a_ohos_module_store32(address, value)) return 0;
    }
#endif
    return e;
}

// These loads are only used for addresses validated against a live module.
// A direct load retains the normal guest fault/track readback behavior.
uint8_t plat_guest_load8(uint64_t address) {
    return __atomic_load_n((uint8_t *)(uintptr_t)address, __ATOMIC_RELAXED);
}
uint32_t plat_guest_load32(uint64_t address) {
    return __atomic_load_n((uint32_t *)(uintptr_t)address, __ATOMIC_RELAXED);
}
uint64_t plat_guest_load64(uint64_t address) {
    return __atomic_load_n((uint64_t *)(uintptr_t)address, __ATOMIC_RELAXED);
}
void plat_guest_store32(uint64_t address, uint32_t value) {
    // 必须落、落不了报红终止（同前）。EAGAIN 是瞬时竞争不算失败：这一拍让过——写循环 10 Hz、
    // 逐帧/槽位路径都按自己节拍重发；一次性槽写丢了用户再拨一次，总比误杀进程强。内部不自旋。
    int error = plat_mem_write32(address, value);
    if (error == EAGAIN) return;
    if (error) {
        fprintf(stderr, "[fps] 【红】模块地址写入失败 addr=%#llx errno=%d\n",
                (unsigned long long)address, error);
        abort();
    }
}

int plat_thread_name(const char *name) {
    if (!name) return EINVAL;
#if defined(__APPLE__)
    return pthread_setname_np(name);
#else
    return pthread_setname_np(pthread_self(), name);
#endif
}
