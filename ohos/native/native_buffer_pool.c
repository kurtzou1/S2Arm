// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 S2Arm contributors
#include "native_buffer_pool.h"
#include <vulkan/vulkan_ohos.h>
#include <native_buffer/native_buffer.h>
#include <native_window/external_window.h>
#include <dlfcn.h>
#include <errno.h>
#include <fcntl.h>
#include <limits.h>
#include <linux/dma-buf.h>
#include <stdio.h>
#include <stdlib.h>
#include <sys/ioctl.h>
#include <sys/mman.h>
#include <unistd.h>

struct s2a_ohos_pool {
    VkDevice device;
    VkBuffer buffer;
    VkDeviceMemory memory;
    OH_NativeBuffer *native;
    OHNativeWindowBuffer *window;
    void *native_lib, *window_lib;
    int fd;
    size_t size;
    uint64_t cpu_flags;
    int cpu_active;
    int32_t (*unreference)(OH_NativeBuffer *);
    void (*destroy_window)(OHNativeWindowBuffer *);
};

static int pool_error(char *why, size_t cap, const char *what, int rc) {
    if (why && cap) snprintf(why, cap, "%s (%d)", what, rc);
    return -1;
}

static int pool_sync(struct s2a_ohos_pool *p, uint64_t flags) {
    struct dma_buf_sync sync = { .flags = flags };
    int rc;
    unsigned retries = 0;
    do { rc = ioctl(p->fd, DMA_BUF_IOCTL_SYNC, &sync); }
    while (rc && (errno == EINTR || errno == EAGAIN) && ++retries < 128);
    return rc;
}

int s2a_ohos_pool_cpu_begin(struct s2a_ohos_pool *p, int write) {
    if (!p || p->cpu_active) { errno = EINVAL; return -1; }
    uint64_t flags = write ? DMA_BUF_SYNC_RW : DMA_BUF_SYNC_READ;
    if (pool_sync(p, flags | DMA_BUF_SYNC_START)) return -1;
    p->cpu_flags = flags;
    p->cpu_active = 1;
    return 0;
}

int s2a_ohos_pool_cpu_end(struct s2a_ohos_pool *p) {
    if (!p || !p->cpu_active) { errno = EINVAL; return -1; }
    if (pool_sync(p, p->cpu_flags | DMA_BUF_SYNC_END)) return -1;
    p->cpu_active = 0;
    return 0;
}

int s2a_ohos_pool_destroy(struct s2a_ohos_pool *p) {
    if (!p) return 0;
    // A failed END leaves the epoch active; retain ownership so callers cannot
    // silently submit stale data or free memory they still consider accessible.
    if (p->cpu_active) { errno = EBUSY; return -1; }
    if (p->buffer) vkDestroyBuffer(p->device, p->buffer, NULL);
    if (p->memory) vkFreeMemory(p->device, p->memory, NULL);
    if (p->fd >= 0) close(p->fd);
    if (p->window) p->destroy_window(p->window);
    if (p->native) p->unreference(p->native);
    if (p->window_lib) dlclose(p->window_lib);
    if (p->native_lib) dlclose(p->native_lib);
    free(p);
    return 0;
}

static int g_pool_bda;
void s2a_ohos_pool_set_device_address(int on) { g_pool_bda = on; }
uint64_t s2a_ohos_pool_device_address(const struct s2a_ohos_pool *p) {
    if (!g_pool_bda || !p || !p->buffer) return 0;
    VkBufferDeviceAddressInfo info = { .sType = VK_STRUCTURE_TYPE_BUFFER_DEVICE_ADDRESS_INFO, .buffer = p->buffer };
    return vkGetBufferDeviceAddress(p->device, &info);
}
VkBuffer s2a_ohos_pool_buffer(const struct s2a_ohos_pool *p) {
    return p ? p->buffer : VK_NULL_HANDLE;
}

int s2a_ohos_pool_alias(struct s2a_ohos_pool *p, void *reservation,
                       size_t offset, size_t size, void **out) {
    if (out) *out = NULL;
    long page = sysconf(_SC_PAGESIZE);
    if (!p || !out || !size || reservation == MAP_FAILED || (uintptr_t)reservation > UINTPTR_MAX - size ||
        page <= 0 || offset > p->size || size > p->size - offset ||
        ((uintptr_t)reservation % (size_t)page) || offset % (size_t)page || size % (size_t)page) {
        errno = EINVAL; return -1;
    }
    // NULL requests a new mapping; non-NULL must be a reservation owned by the
    // caller, never an arbitrary guest address. No mremap of the driver's view.
    void *mapped = mmap(reservation, size, PROT_READ | PROT_WRITE,
                        MAP_SHARED | (reservation ? MAP_FIXED : 0), p->fd, (off_t)offset);
    if (mapped == MAP_FAILED) return -1;
    *out = mapped;
    return 0;
}

int s2a_ohos_pool_create(VkPhysicalDevice physical, VkDevice device, const VkPhysicalDeviceMemoryProperties *types,
                        size_t size, struct s2a_ohos_pool **out, char *why, size_t cap) {
    if (out) *out = NULL;
    long page = sysconf(_SC_PAGESIZE);
    if (!out || !physical || !device || !types || !size || size > INT_MAX || page <= 0 || size % (size_t)page)
        return pool_error(why, cap, "invalid native pool size/device", EINVAL);
    struct s2a_ohos_pool *p = calloc(1, sizeof *p);
    if (!p) return pool_error(why, cap, "allocate pool owner", ENOMEM);
    p->fd = -1; p->device = device; p->size = size;
    int rc = -1;
    const char *stage = "load public native buffer APIs";
    p->native_lib = dlopen("libnative_buffer.so", RTLD_NOW | RTLD_LOCAL);
    p->window_lib = dlopen("libnative_window.so", RTLD_NOW | RTLD_LOCAL);
    if (!p->native_lib || !p->window_lib) goto fail;
    OH_NativeBuffer *(*alloc)(const OH_NativeBuffer_Config *) = dlsym(p->native_lib, "OH_NativeBuffer_Alloc");
    p->unreference = dlsym(p->native_lib, "OH_NativeBuffer_Unreference");
    OHNativeWindowBuffer *(*make_window)(OH_NativeBuffer *) =
        dlsym(p->window_lib, "OH_NativeWindow_CreateNativeWindowBufferFromNativeBuffer");
    BufferHandle *(*handle)(OHNativeWindowBuffer *) = dlsym(p->window_lib, "OH_NativeWindow_GetBufferHandleFromNative");
    p->destroy_window = dlsym(p->window_lib, "OH_NativeWindow_DestroyNativeWindowBuffer");
    if (!alloc || !p->unreference || !make_window || !handle || !p->destroy_window) goto fail;
    PFN_vkGetNativeBufferPropertiesOHOS properties =
        (PFN_vkGetNativeBufferPropertiesOHOS)vkGetDeviceProcAddr(device, "vkGetNativeBufferPropertiesOHOS");
    if (!properties) { stage = "VK_OHOS_external_memory not enabled"; goto fail; }
    OH_NativeBuffer_Config cfg = { .width = (int32_t)size, .height = 1,
        .format = NATIVEBUFFER_PIXEL_FMT_BLOB,
        .usage = NATIVEBUFFER_USAGE_CPU_READ | NATIVEBUFFER_USAGE_CPU_WRITE | NATIVEBUFFER_USAGE_MEM_DMA |
                 NATIVEBUFFER_USAGE_HW_RENDER | NATIVEBUFFER_USAGE_HW_TEXTURE };
    stage = "allocate BLOB native buffer";
    p->native = alloc(&cfg);
    if (!p->native) goto fail;
    stage = "public native window buffer handle";
    p->window = make_window(p->native);
    if (!p->window) goto fail;
    const BufferHandle *h = handle(p->window);
    if (!h || h->fd < 0 || h->size < 0 || (size_t)h->size < size) goto fail;
    p->fd = fcntl(h->fd, F_DUPFD_CLOEXEC, 0);
    if (p->fd < 0) { rc = errno; goto fail; }
    VkNativeBufferPropertiesOHOS props = { .sType = VK_STRUCTURE_TYPE_NATIVE_BUFFER_PROPERTIES_OHOS };
    stage = "query native buffer Vulkan properties";
    if ((rc = properties(device, p->native, &props)) != VK_SUCCESS) goto fail;
    VkExternalMemoryBufferCreateInfo external = { .sType = VK_STRUCTURE_TYPE_EXTERNAL_MEMORY_BUFFER_CREATE_INFO,
        .handleTypes = VK_EXTERNAL_MEMORY_HANDLE_TYPE_OH_NATIVE_BUFFER_BIT_OHOS };
    VkBufferCreateInfo bi = { .sType = VK_STRUCTURE_TYPE_BUFFER_CREATE_INFO, .pNext = &external, .size = size,
        .usage = VK_BUFFER_USAGE_TRANSFER_SRC_BIT | VK_BUFFER_USAGE_TRANSFER_DST_BIT | VK_BUFFER_USAGE_STORAGE_BUFFER_BIT |
                 VK_BUFFER_USAGE_VERTEX_BUFFER_BIT | VK_BUFFER_USAGE_INDEX_BUFFER_BIT | VK_BUFFER_USAGE_UNIFORM_BUFFER_BIT |
                 VK_BUFFER_USAGE_INDIRECT_BUFFER_BIT | (g_pool_bda ? VK_BUFFER_USAGE_SHADER_DEVICE_ADDRESS_BIT : 0), .sharingMode = VK_SHARING_MODE_EXCLUSIVE };
    VkPhysicalDeviceExternalBufferInfo ei = { .sType = VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_EXTERNAL_BUFFER_INFO,
        .usage = bi.usage, .handleType = VK_EXTERNAL_MEMORY_HANDLE_TYPE_OH_NATIVE_BUFFER_BIT_OHOS };
    VkExternalBufferProperties ep = { .sType = VK_STRUCTURE_TYPE_EXTERNAL_BUFFER_PROPERTIES };
    vkGetPhysicalDeviceExternalBufferProperties(physical, &ei, &ep);
    stage = "external buffer usage importability";
    rc = VK_ERROR_FORMAT_NOT_SUPPORTED;
    if (!(ep.externalMemoryProperties.externalMemoryFeatures & VK_EXTERNAL_MEMORY_FEATURE_IMPORTABLE_BIT) ||
        !(ep.externalMemoryProperties.compatibleHandleTypes & ei.handleType)) goto fail;
    stage = "create external Vulkan buffer";
    if ((rc = vkCreateBuffer(device, &bi, NULL, &p->buffer)) != VK_SUCCESS) goto fail;
    VkMemoryRequirements req;
    vkGetBufferMemoryRequirements(device, p->buffer, &req);
    uint32_t mt = UINT32_MAX;
    for (uint32_t i = 0; i < types->memoryTypeCount; i++)
        if ((props.memoryTypeBits & req.memoryTypeBits & (1u << i)) &&
            (types->memoryTypes[i].propertyFlags & VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT)) { mt = i; break; }
    stage = "native buffer allocation compatibility";
    rc = VK_ERROR_FORMAT_NOT_SUPPORTED;
    if (mt == UINT32_MAX || props.allocationSize < req.size) goto fail;
    VkMemoryDedicatedAllocateInfo dedicated = { .sType = VK_STRUCTURE_TYPE_MEMORY_DEDICATED_ALLOCATE_INFO, .buffer = p->buffer };
    VkImportNativeBufferInfoOHOS import = { .sType = VK_STRUCTURE_TYPE_IMPORT_NATIVE_BUFFER_INFO_OHOS,
        .pNext = &dedicated, .buffer = p->native };
    VkMemoryAllocateFlagsInfo alloc_flags = { .sType = VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_FLAGS_INFO, .pNext = &import,
        .flags = VK_MEMORY_ALLOCATE_DEVICE_ADDRESS_BIT };
    VkMemoryAllocateInfo ai = { .sType = VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO, .pNext = g_pool_bda ? (const void *)&alloc_flags : (const void *)&import,
        .allocationSize = props.allocationSize, .memoryTypeIndex = mt };
    stage = "import native buffer allocation";
    if ((rc = vkAllocateMemory(device, &ai, NULL, &p->memory)) != VK_SUCCESS) goto fail;
    stage = "bind native buffer allocation";
    if ((rc = vkBindBufferMemory(device, p->buffer, p->memory, 0)) != VK_SUCCESS) goto fail;
    *out = p;
    if (why && cap) why[0] = 0;
    return 0;
fail:
    s2a_ohos_pool_destroy(p);
    return pool_error(why, cap, stage, rc);
}
