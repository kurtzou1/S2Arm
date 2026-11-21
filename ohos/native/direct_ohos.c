// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 S2Arm contributors
// OHOS seams for the shared NVN frontend that only exist on Apple hosts.
#include <stddef.h>
#include <stdint.h>
#include <string.h>

// hle_nvn.c statistics read this thread's {instructions, cycles} from a libSystem private
// interface. OHOS has no equivalent without perf_event permission: report zeros, never guess.
int thread_selfcounts(int type, void *buf, size_t nbytes) {
    (void)type;
    if (buf && nbytes) memset(buf, 0, nbytes);
    return -1;
}

// The Metal backend's present-thread QoS, printed in a statistics line only.
uint32_t mtl_present_qos(void) { return 0; }

// 销毁纪元：引擎链接时用 --wrap 把这三种销毁调用都转到这里（link_engine.py）。
// 跨帧复用的描述符集引用了视图、采样器、缓冲；句柄被销毁后可能以同值复用，缓存只认纪元未变的。
#include <stdatomic.h>
#include <vulkan/vulkan.h>
_Atomic uint64_t s2a_vk_destroy_epoch;
void __real_vkDestroyImageView(VkDevice, VkImageView, const VkAllocationCallbacks *);
void __real_vkDestroySampler(VkDevice, VkSampler, const VkAllocationCallbacks *);
void __real_vkDestroyBuffer(VkDevice, VkBuffer, const VkAllocationCallbacks *);
void __wrap_vkDestroyImageView(VkDevice d, VkImageView v, const VkAllocationCallbacks *a) {
    if (v) atomic_fetch_add_explicit(&s2a_vk_destroy_epoch, 1, memory_order_relaxed);
    __real_vkDestroyImageView(d, v, a);
}
void __wrap_vkDestroySampler(VkDevice d, VkSampler s, const VkAllocationCallbacks *a) {
    if (s) atomic_fetch_add_explicit(&s2a_vk_destroy_epoch, 1, memory_order_relaxed);
    __real_vkDestroySampler(d, s, a);
}
void __wrap_vkDestroyBuffer(VkDevice d, VkBuffer b, const VkAllocationCallbacks *a) {
    if (b) atomic_fetch_add_explicit(&s2a_vk_destroy_epoch, 1, memory_order_relaxed);
    __real_vkDestroyBuffer(d, b, a);
}
void __real_vkDestroyDescriptorSetLayout(VkDevice, VkDescriptorSetLayout, const VkAllocationCallbacks *);
void __wrap_vkDestroyDescriptorSetLayout(VkDevice d, VkDescriptorSetLayout l, const VkAllocationCallbacks *a) {
    if (l) atomic_fetch_add_explicit(&s2a_vk_destroy_epoch, 1, memory_order_relaxed);
    __real_vkDestroyDescriptorSetLayout(d, l, a);
}

// O-2（同步上游 v0.2.6）：上游直连上屏节拍源 nvn_vsync_android.c 用 AChoreographer，鸿蒙不编。
// 这里按 nvn_vsync_android.h 的契约给“节拍源不可用”：mtl_vk_shim 的 nvn_be_link_* 回退自己的 60Hz 时钟。
int s2a_android_link_active(void) { return 0; }
int s2a_android_link_wait_tick(int vsyncs, uint64_t timeout_ns) { (void)vsyncs; (void)timeout_ns; return 0; }
void s2a_android_link_stop(void) {}
