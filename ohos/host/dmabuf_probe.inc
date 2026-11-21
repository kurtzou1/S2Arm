// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 S2Arm contributors
// S2A 诊断 DEBUG_S2A_DMABUF_PROBE=1（缺省关，10-30）：验证直连零拷贝的前提——GPU 能访问的内存能不能出现在游戏指定的地址上。
// Maleoon 不支持 VK_EXT_external_memory_host，OPAQUE_FD 也导不出（第一版探针：特性 0、vkGetMemoryFdKHR -2）。这里试另外两条路：
//   A. 普通 vkAllocateMemory + vkMapMemory，再 mremap 把这段映射搬到预留地址（以及 old_size=0 做别名）；
//   B. OH_NativeBuffer（BLOB）取 fd 后 MAP_FIXED 到预留地址，再经 VK_OHOS_external_memory 导入成 VkBuffer。
// 每条路都做双向检查：CPU 经新地址写 → GPU 拷走后比对；GPU 填充 → CPU 经新地址读回比对。探针独立建实例与设备，只打日志。
#include <sys/mman.h>
#include <fcntl.h>
#include <native_buffer/native_buffer.h>

#define DMP_LOG(...) fprintf(stderr, "[S2A dmabuf 探针] " __VA_ARGS__)

typedef struct { int32_t fd, width, stride, height, size, format; uint64_t usage; void *virAddr; } dmp_buffer_handle;

struct dmp_vk {
    VkDevice dev; VkQueue q; VkCommandPool pool; VkPhysicalDeviceMemoryProperties mp;
    uint32_t queue_family; int foreign_enabled; VkPhysicalDevice physical;
    PFN_vkCreateBuffer CreateBuffer; PFN_vkGetBufferMemoryRequirements GetBufferMemoryRequirements;
    PFN_vkAllocateMemory AllocateMemory; PFN_vkBindBufferMemory BindBufferMemory; PFN_vkMapMemory MapMemory;
    PFN_vkAllocateCommandBuffers AllocateCommandBuffers; PFN_vkBeginCommandBuffer BeginCommandBuffer;
    PFN_vkEndCommandBuffer EndCommandBuffer; PFN_vkCmdCopyBuffer CmdCopyBuffer; PFN_vkCmdFillBuffer CmdFillBuffer;
    PFN_vkQueueSubmit QueueSubmit; PFN_vkQueueWaitIdle QueueWaitIdle; PFN_vkCmdPipelineBarrier CmdPipelineBarrier;
    PFN_vkGetNativeBufferPropertiesOHOS GetNativeBufferPropertiesOHOS;
};

static uint32_t dmp_type(struct dmp_vk *v, uint32_t bits, VkMemoryPropertyFlags want) {
    for (uint32_t i = 0; i < v->mp.memoryTypeCount; i++)
        if ((bits >> i & 1) && (v->mp.memoryTypes[i].propertyFlags & want) == want) return i;
    return UINT32_MAX;
}

static void dmp_maps_line(const char *tag, const void *p) {
    FILE *f = fopen("/proc/self/maps", "r"); char line[512];
    if (!f) return;
    while (fgets(line, sizeof line, f)) {
        unsigned long a, b;
        if (sscanf(line, "%lx-%lx", &a, &b) == 2 && (uintptr_t)p >= a && (uintptr_t)p < b) { DMP_LOG("%s maps: %s", tag, line); break; }
    }
    fclose(f);
}

static VkBuffer dmp_plain_buffer(struct dmp_vk *v, VkDeviceSize size, void **map) {
    VkBufferCreateInfo bci = { VK_STRUCTURE_TYPE_BUFFER_CREATE_INFO, NULL, 0, size,
        VK_BUFFER_USAGE_TRANSFER_SRC_BIT | VK_BUFFER_USAGE_TRANSFER_DST_BIT, VK_SHARING_MODE_EXCLUSIVE, 0, NULL };
    VkBuffer b; VkMemoryRequirements req; VkDeviceMemory m;
    v->CreateBuffer(v->dev, &bci, NULL, &b);
    v->GetBufferMemoryRequirements(v->dev, b, &req);
    VkMemoryAllocateInfo mai = { VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO, NULL, req.size,
        dmp_type(v, req.memoryTypeBits, VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT | VK_MEMORY_PROPERTY_HOST_COHERENT_BIT) };
    v->AllocateMemory(v->dev, &mai, NULL, &m);
    v->BindBufferMemory(v->dev, b, m, 0);
    v->MapMemory(v->dev, m, 0, size, 0, map);
    return b;
}

// buf 的内存经 cpu（新地址）访问：前半 CPU 写 GPU 读，后半 GPU 写 CPU 读。
static void dmp_roundtrip(struct dmp_vk *v, const char *tag, VkBuffer buf, uint8_t *cpu, VkDeviceSize size, int cached) {
    void *pmap = NULL;
    VkBuffer plain = dmp_plain_buffer(v, size / 2, &pmap);
    for (VkDeviceSize i = 0; i < size / 2; i++) cpu[i] = (uint8_t)(i * 7 + 3);
    VkCommandBufferAllocateInfo cbai = { VK_STRUCTURE_TYPE_COMMAND_BUFFER_ALLOCATE_INFO, NULL, v->pool, VK_COMMAND_BUFFER_LEVEL_PRIMARY, 1 };
    VkCommandBuffer cb; v->AllocateCommandBuffers(v->dev, &cbai, &cb);
    VkCommandBufferBeginInfo bi = { VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO, NULL, VK_COMMAND_BUFFER_USAGE_ONE_TIME_SUBMIT_BIT, NULL };
    v->BeginCommandBuffer(cb, &bi);
    VkBufferCopy cp = { 0, 0, size / 2 };
    v->CmdCopyBuffer(cb, buf, plain, 1, &cp);
    v->CmdFillBuffer(cb, buf, size / 2, size / 2, 0xA5C3E1F7u);
    VkMemoryBarrier mb = { VK_STRUCTURE_TYPE_MEMORY_BARRIER, NULL, VK_ACCESS_TRANSFER_WRITE_BIT, VK_ACCESS_HOST_READ_BIT };
    v->CmdPipelineBarrier(cb, VK_PIPELINE_STAGE_TRANSFER_BIT, VK_PIPELINE_STAGE_HOST_BIT, 0, 1, &mb, 0, NULL, 0, NULL);
    v->EndCommandBuffer(cb);
    VkSubmitInfo si = { VK_STRUCTURE_TYPE_SUBMIT_INFO, NULL, 0, NULL, NULL, 1, &cb, 0, NULL };
    VkResult r = v->QueueSubmit(v->q, 1, &si, VK_NULL_HANDLE);
    v->QueueWaitIdle(v->q);
    int rd = pmap && !memcmp(pmap, cpu, size / 2), wr = 1;
    for (VkDeviceSize i = size / 2; i < size; i += 4) if (*(uint32_t *)(cpu + i) != 0xA5C3E1F7u) { wr = 0; break; }
    DMP_LOG("%s：提交 %d；GPU 读到 CPU 经新地址写的数据 %s；CPU 经新地址读到 GPU 写的数据 %s%s → %s\n", tag, r,
            rd ? "是" : "否", wr ? "是" : "否", cached ? "（非 coherent，未做 invalidate）" : "",
            rd && wr ? "可行" : "不可行");
}

static VkBuffer dmp_storage_buffer(struct dmp_vk *v, VkDeviceSize size, const void *pnext, VkMemoryRequirements *req) {
    VkBufferCreateInfo bci = { VK_STRUCTURE_TYPE_BUFFER_CREATE_INFO, pnext, 0, size,
        VK_BUFFER_USAGE_TRANSFER_SRC_BIT | VK_BUFFER_USAGE_TRANSFER_DST_BIT | VK_BUFFER_USAGE_STORAGE_BUFFER_BIT |
        VK_BUFFER_USAGE_VERTEX_BUFFER_BIT | VK_BUFFER_USAGE_INDEX_BUFFER_BIT | VK_BUFFER_USAGE_UNIFORM_BUFFER_BIT,
        VK_SHARING_MODE_EXCLUSIVE, 0, NULL };
    VkBuffer b = VK_NULL_HANDLE;
    VkResult r = v->CreateBuffer(v->dev, &bci, NULL, &b);
    if (r) { DMP_LOG("vkCreateBuffer %d\n", r); return VK_NULL_HANDLE; }
    v->GetBufferMemoryRequirements(v->dev, b, req);
    return b;
}

// A. 普通 GPU 内存：vkMapMemory 后 mremap 搬到预留地址 / 做别名
static void dmp_route_mremap(struct dmp_vk *v, VkMemoryPropertyFlags want, const char *name) {
    const VkDeviceSize size = 1u << 20;
    VkMemoryRequirements req;
    VkBuffer b = dmp_storage_buffer(v, size, NULL, &req);
    if (!b) return;
    uint32_t mt = dmp_type(v, req.memoryTypeBits, want);
    if (mt == UINT32_MAX) { DMP_LOG("A[%s]：没有这种内存类型\n", name); return; }
    VkMemoryAllocateInfo mai = { VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO, NULL, req.size, mt };
    VkDeviceMemory m; void *p = NULL;
    if (v->AllocateMemory(v->dev, &mai, NULL, &m) || v->BindBufferMemory(v->dev, b, m, 0) || v->MapMemory(v->dev, m, 0, size, 0, &p) || !p) {
        DMP_LOG("A[%s]：分配/映射失败\n", name); return;
    }
    char tag[64]; snprintf(tag, sizeof tag, "A[%s] vkMapMemory 视图", name);
    dmp_maps_line(tag, p);
    // 别名：old_size=0 只对共享、非 PFNMAP 映射有效
    void *alias = mremap(p, 0, size, MREMAP_MAYMOVE);
    if (alias == MAP_FAILED) DMP_LOG("A[%s]：mremap 别名失败 errno=%d（%s）\n", name, errno, strerror(errno));
    else {
        ((volatile uint8_t *)p)[123] = 0x5a;
        DMP_LOG("A[%s]：mremap 别名成功 %p，别名看到原映射的写 %s\n", name, alias, ((volatile uint8_t *)alias)[123] == 0x5a ? "是" : "否");
        snprintf(tag, sizeof tag, "A[%s] 别名经新地址", name);
        dmp_roundtrip(v, tag, b, alias, size, !(v->mp.memoryTypes[mt].propertyFlags & VK_MEMORY_PROPERTY_HOST_COHERENT_BIT));
    }
    // 整段搬到预留地址
    uint8_t *reserve = mmap(NULL, size, PROT_NONE, MAP_PRIVATE | MAP_ANONYMOUS, -1, 0);
    void *moved = mremap(p, size, size, MREMAP_MAYMOVE | MREMAP_FIXED, reserve);
    if (moved == MAP_FAILED) { DMP_LOG("A[%s]：mremap 搬到预留地址失败 errno=%d（%s）\n", name, errno, strerror(errno)); return; }
    DMP_LOG("A[%s]：mremap 搬到预留地址成功 %p\n", name, moved);
    snprintf(tag, sizeof tag, "A[%s] 搬家后", name);
    dmp_roundtrip(v, tag, b, moved, size, !(v->mp.memoryTypes[mt].propertyFlags & VK_MEMORY_PROPERTY_HOST_COHERENT_BIT));
}

// B. OH_NativeBuffer：取 fd、MAP_FIXED 到预留地址、导入 Vulkan
static void dmp_route_native(struct dmp_vk *v) {
    void *nb = dlopen("libnative_buffer.so", RTLD_NOW | RTLD_LOCAL);
    if (!nb) { DMP_LOG("B：dlopen libnative_buffer.so 失败 %s\n", dlerror()); return; }
    OH_NativeBuffer *(*alloc)(const OH_NativeBuffer_Config *) = dlsym(nb, "OH_NativeBuffer_Alloc");
    int32_t (*map)(OH_NativeBuffer *, void **) = dlsym(nb, "OH_NativeBuffer_Map");
    dmp_buffer_handle *(*handle)(const OH_NativeBuffer *) = dlsym(nb, "OH_NativeBuffer_GetBufferHandle");
    DMP_LOG("B：Alloc %p Map %p GetBufferHandle %p\n", (void *)alloc, (void *)map, (void *)handle);
    if (!alloc) return;
    const int32_t size = 1 << 20;
    OH_NativeBuffer_Config cfg = { size, 1, NATIVEBUFFER_PIXEL_FMT_BLOB,
        NATIVEBUFFER_USAGE_CPU_READ | NATIVEBUFFER_USAGE_CPU_WRITE | NATIVEBUFFER_USAGE_MEM_DMA |
        NATIVEBUFFER_USAGE_HW_RENDER | NATIVEBUFFER_USAGE_HW_TEXTURE, 0 };
    OH_NativeBuffer *buf = alloc(&cfg);
    if (!buf) { cfg.usage = NATIVEBUFFER_USAGE_CPU_READ | NATIVEBUFFER_USAGE_CPU_WRITE | NATIVEBUFFER_USAGE_MEM_DMA; buf = alloc(&cfg); }
    if (!buf) { DMP_LOG("B：OH_NativeBuffer_Alloc(BLOB %d) 失败\n", size); return; }
    void *va = NULL; int32_t mr = map ? map(buf, &va) : -1;
    DMP_LOG("B：分配成功 usage=0x%x，Map %d → %p\n", cfg.usage, mr, va);
    if (va) dmp_maps_line("B NativeBuffer_Map 视图", va);
    int fd = -1;
    if (handle) {
        dmp_buffer_handle *h = handle(buf);
        if (h) {
            fd = h->fd;
            char link[256] = "", path[64]; snprintf(path, sizeof path, "/proc/self/fd/%d", fd);
            ssize_t ln = readlink(path, link, sizeof link - 1); if (ln > 0) link[ln] = 0;
            DMP_LOG("B：BufferHandle fd=%d → %s，size=%d stride=%d\n", fd, link, h->size, h->stride);
        }
    }
    uint8_t *fixed = NULL;
    if (fd >= 0) {
        uint8_t *reserve = mmap(NULL, size, PROT_NONE, MAP_PRIVATE | MAP_ANONYMOUS, -1, 0);
        fixed = mmap(reserve, size, PROT_READ | PROT_WRITE, MAP_SHARED | MAP_FIXED, fd, 0);
        if (fixed == MAP_FAILED) { DMP_LOG("B：MAP_FIXED 映射 fd 失败 errno=%d（%s）\n", errno, strerror(errno)); fixed = NULL; }
        else {
            DMP_LOG("B：MAP_FIXED 到预留地址成功 %p\n", (void *)fixed);
            uint8_t *fixed2 = mmap(NULL, size, PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0);
            if (fixed2 != MAP_FAILED) { fixed[77] = 0x3c; DMP_LOG("B：同一 fd 第二个映射看到写入 %s\n", fixed2[77] == 0x3c ? "是" : "否"); }
        }
    }
    if (!fixed && va) {
        uint8_t *reserve = mmap(NULL, size, PROT_NONE, MAP_PRIVATE | MAP_ANONYMOUS, -1, 0);
        void *moved = mremap(va, size, size, MREMAP_MAYMOVE | MREMAP_FIXED, reserve);
        if (moved == MAP_FAILED) DMP_LOG("B：mremap 搬 Map 视图失败 errno=%d（%s）\n", errno, strerror(errno));
        else { fixed = moved; DMP_LOG("B：mremap 搬 Map 视图成功 %p\n", moved); }
    }
    if (!v->GetNativeBufferPropertiesOHOS) { DMP_LOG("B：没有 vkGetNativeBufferPropertiesOHOS（扩展未启用）\n"); return; }
    VkNativeBufferPropertiesOHOS props = { VK_STRUCTURE_TYPE_NATIVE_BUFFER_PROPERTIES_OHOS };
    VkResult r = v->GetNativeBufferPropertiesOHOS(v->dev, buf, &props);
    DMP_LOG("B：NativeBuffer 属性 %d：大小 %llu 类型掩码 0x%x\n", r, (unsigned long long)props.allocationSize, props.memoryTypeBits);
    if (r || !fixed) return;
    VkExternalMemoryBufferCreateInfo emb = { VK_STRUCTURE_TYPE_EXTERNAL_MEMORY_BUFFER_CREATE_INFO, NULL, VK_EXTERNAL_MEMORY_HANDLE_TYPE_OH_NATIVE_BUFFER_BIT_OHOS };
    VkMemoryRequirements req;
    VkBuffer b = dmp_storage_buffer(v, size, &emb, &req);
    if (!b) { emb.handleTypes = VK_EXTERNAL_MEMORY_HANDLE_TYPE_OHOS_NATIVE_BUFFER_BIT_OHOS; b = dmp_storage_buffer(v, size, &emb, &req); }
    if (!b) return;
    uint32_t mt = UINT32_MAX;
    for (uint32_t i = 0; i < v->mp.memoryTypeCount; i++) if (props.memoryTypeBits & req.memoryTypeBits & (1u << i)) { mt = i; break; }
    VkMemoryDedicatedAllocateInfo ded = { VK_STRUCTURE_TYPE_MEMORY_DEDICATED_ALLOCATE_INFO, NULL, VK_NULL_HANDLE, b };
    VkImportNativeBufferInfoOHOS imp = { VK_STRUCTURE_TYPE_IMPORT_NATIVE_BUFFER_INFO_OHOS, &ded, buf };
    VkMemoryAllocateInfo mai = { VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO, &imp, props.allocationSize, mt };
    VkDeviceMemory m;
    r = mt == UINT32_MAX ? VK_ERROR_FORMAT_NOT_SUPPORTED : v->AllocateMemory(v->dev, &mai, NULL, &m);
    if (r && mt != UINT32_MAX) { imp.pNext = NULL; r = v->AllocateMemory(v->dev, &mai, NULL, &m); DMP_LOG("B：带专用分配导入失败，不带重试 %d\n", r); }
    if (r) { DMP_LOG("B：导入 vkAllocateMemory 失败 %d（类型 %u，缓冲要求掩码 0x%x）\n", r, mt, req.memoryTypeBits); return; }
    if ((r = v->BindBufferMemory(v->dev, b, m, 0))) { DMP_LOG("B：绑定失败 %d\n", r); return; }
    DMP_LOG("B：导入成功，类型 %u 属性 0x%x\n", mt, v->mp.memoryTypes[mt].propertyFlags);
    dmp_roundtrip(v, "B NativeBuffer 经预留地址", b, fixed, size,
                  !(v->mp.memoryTypes[mt].propertyFlags & VK_MEMORY_PROPERTY_HOST_COHERENT_BIT));
}

#include "native_pool_probe.inc"

static void *dmabuf_probe_thread(void *arg) {
    (void)arg;
    void *lib = dlopen("libvulkan.so", RTLD_NOW | RTLD_LOCAL);
    if (!lib) { DMP_LOG("dlopen libvulkan.so 失败：%s\n", dlerror()); return NULL; }
    PFN_vkGetInstanceProcAddr gipa = (PFN_vkGetInstanceProcAddr)dlsym(lib, "vkGetInstanceProcAddr");
    if (!gipa) { DMP_LOG("FAIL missing vkGetInstanceProcAddr\n"); return NULL; }
    VkInstance inst = VK_NULL_HANDLE;
    PFN_vkCreateInstance vkCreateInstance_ = (PFN_vkCreateInstance)gipa(NULL, "vkCreateInstance");
    if (!vkCreateInstance_) { DMP_LOG("FAIL missing vkCreateInstance\n"); return NULL; }
    VkApplicationInfo app = { VK_STRUCTURE_TYPE_APPLICATION_INFO, NULL, "s2a-dmabuf-probe", 1, "s2a", 1, VK_API_VERSION_1_1 };
    VkInstanceCreateInfo ici = { VK_STRUCTURE_TYPE_INSTANCE_CREATE_INFO, NULL, 0, &app, 0, NULL, 0, NULL };
    VkResult r = vkCreateInstance_(&ici, NULL, &inst);
    if (r) { DMP_LOG("vkCreateInstance %d\n", r); return NULL; }
#define GI(name) PFN_##name name = (PFN_##name)gipa(inst, #name)
    GI(vkEnumeratePhysicalDevices); GI(vkGetPhysicalDeviceMemoryProperties); GI(vkCreateDevice); GI(vkGetDeviceProcAddr);
    GI(vkGetPhysicalDeviceQueueFamilyProperties); GI(vkEnumerateDeviceExtensionProperties);
#undef GI
    if (!vkEnumeratePhysicalDevices || !vkGetPhysicalDeviceMemoryProperties || !vkCreateDevice || !vkGetDeviceProcAddr ||
        !vkGetPhysicalDeviceQueueFamilyProperties || !vkEnumerateDeviceExtensionProperties) {
        DMP_LOG("FAIL missing Vulkan instance entry points\n"); return NULL;
    }
    uint32_t n = 1; VkPhysicalDevice pd;
    r = vkEnumeratePhysicalDevices(inst, &n, &pd);
    if (!n || (r != VK_SUCCESS && r != VK_INCOMPLETE)) { DMP_LOG("FAIL physical device enumeration %d\n", r); return NULL; }
    struct dmp_vk v; memset(&v, 0, sizeof v);
    v.physical = pd;
    vkGetPhysicalDeviceMemoryProperties(pd, &v.mp);
    for (uint32_t i = 0; i < v.mp.memoryTypeCount; i++)
        DMP_LOG("内存类型 %u：属性 0x%x 堆 %u\n", i, v.mp.memoryTypes[i].propertyFlags, v.mp.memoryTypes[i].heapIndex);
    uint32_t en = 0;
    if ((r = vkEnumerateDeviceExtensionProperties(pd, NULL, &en, NULL)) || !en) { DMP_LOG("FAIL device extensions %d\n", r); return NULL; }
    VkExtensionProperties *ep = calloc(en, sizeof *ep);
    if (!ep || (r = vkEnumerateDeviceExtensionProperties(pd, NULL, &en, ep))) { DMP_LOG("FAIL enumerate device extensions %d\n", r); return NULL; }
    const char *want[] = { "VK_OHOS_external_memory", "VK_KHR_external_memory", "VK_EXT_queue_family_foreign", "VK_KHR_dedicated_allocation", "VK_KHR_get_memory_requirements2" };
    const char *exts[5]; uint32_t ec = 0;
    for (uint32_t w = 0; w < 5; w++)
        for (uint32_t i = 0; i < en; i++) if (!strcmp(ep[i].extensionName, want[w])) {
            exts[ec++] = want[w];
            if (!strcmp(want[w], "VK_EXT_queue_family_foreign")) v.foreign_enabled = 1;
            break;
        }
    DMP_LOG("启用扩展 %u 个（含 VK_OHOS_external_memory：%s）\n", ec, ec && !strcmp(exts[0], want[0]) ? "是" : "否");
    uint32_t qn = 0;
    vkGetPhysicalDeviceQueueFamilyProperties(pd, &qn, NULL);
    if (!qn) { DMP_LOG("FAIL no queue families\n"); return NULL; }
    VkQueueFamilyProperties *qf = calloc(qn, sizeof *qf);
    if (!qf) { DMP_LOG("FAIL queue family allocation\n"); return NULL; }
    vkGetPhysicalDeviceQueueFamilyProperties(pd, &qn, qf);
    uint32_t qfi = UINT32_MAX;
    for (uint32_t i = 0; i < qn; i++) if (qf[i].queueCount && (qf[i].queueFlags & VK_QUEUE_GRAPHICS_BIT)) { qfi = i; break; }
    free(qf);
    if (qfi == UINT32_MAX) { DMP_LOG("FAIL no graphics queue\n"); return NULL; }
    float prio = 1.0f;
    v.queue_family = qfi;
    VkDeviceQueueCreateInfo qci = { VK_STRUCTURE_TYPE_DEVICE_QUEUE_CREATE_INFO, NULL, 0, qfi, 1, &prio };
    VkDeviceCreateInfo dci = { VK_STRUCTURE_TYPE_DEVICE_CREATE_INFO, NULL, 0, 1, &qci, 0, NULL, ec, exts, NULL };
    if ((r = vkCreateDevice(pd, &dci, NULL, &v.dev))) { DMP_LOG("vkCreateDevice %d\n", r); return NULL; }
#define GD(field, name) v.field = (PFN_##name)vkGetDeviceProcAddr(v.dev, #name)
    GD(CreateBuffer, vkCreateBuffer); GD(GetBufferMemoryRequirements, vkGetBufferMemoryRequirements);
    GD(AllocateMemory, vkAllocateMemory); GD(BindBufferMemory, vkBindBufferMemory); GD(MapMemory, vkMapMemory);
    GD(AllocateCommandBuffers, vkAllocateCommandBuffers); GD(BeginCommandBuffer, vkBeginCommandBuffer);
    GD(EndCommandBuffer, vkEndCommandBuffer); GD(CmdCopyBuffer, vkCmdCopyBuffer); GD(CmdFillBuffer, vkCmdFillBuffer);
    GD(QueueSubmit, vkQueueSubmit); GD(QueueWaitIdle, vkQueueWaitIdle); GD(CmdPipelineBarrier, vkCmdPipelineBarrier);
    GD(GetNativeBufferPropertiesOHOS, vkGetNativeBufferPropertiesOHOS);
#undef GD
    PFN_vkGetDeviceQueue gq = (PFN_vkGetDeviceQueue)vkGetDeviceProcAddr(v.dev, "vkGetDeviceQueue");
    PFN_vkCreateCommandPool ccp = (PFN_vkCreateCommandPool)vkGetDeviceProcAddr(v.dev, "vkCreateCommandPool");
    if (!gq || !ccp) { DMP_LOG("FAIL missing queue/command pool entry points\n"); return NULL; }
    gq(v.dev, qfi, 0, &v.q);
    VkCommandPoolCreateInfo cpci = { VK_STRUCTURE_TYPE_COMMAND_POOL_CREATE_INFO, NULL, VK_COMMAND_POOL_CREATE_RESET_COMMAND_BUFFER_BIT, qfi };
    if ((r = ccp(v.dev, &cpci, NULL, &v.pool))) { DMP_LOG("vkCreateCommandPool %d\n", r); return NULL; }

    const char *mode = getenv("DEBUG_S2A_DMABUF_PROBE");
    if (mode && atoi(mode) == 2) {
        int ok = v.foreign_enabled && dmp_pool_case(&v, 1u << 20, 16, 1) && dmp_pool_case(&v, 16u << 20, 32, 1) && dmp_pool_case(&v, 64u << 20, 32, 1);
        if (ok) { dmp_pool_case(&v, 16u << 20, 32, 0); dmp_pool_case(&v, 64u << 20, 16, 0); dmp_pool_size_probe(&v); }
        DMP_LOG("native pool repeated test %s (guest not started)\n", ok ? "PASS" : "FAIL");
        free(ep);
        if (ok) {
            vkDestroyCommandPool(v.dev, v.pool, NULL);
            vkDestroyDevice(v.dev, NULL);
            vkDestroyInstance(inst, NULL);
            dlclose(lib);
        } // Failed/uncertain completion retains the isolated device until exit.
        return NULL;
    }
    dmp_route_mremap(&v, VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT | VK_MEMORY_PROPERTY_HOST_COHERENT_BIT, "coherent");
    dmp_route_mremap(&v, VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT | VK_MEMORY_PROPERTY_HOST_CACHED_BIT, "cached");
    dmp_route_native(&v);
    int fh = open("/dev/dma_heap/system", O_RDONLY | O_CLOEXEC);
    DMP_LOG("C：/dev/dma_heap/system 打开 %s errno=%d\n", fh >= 0 ? "成功" : "失败", fh >= 0 ? 0 : errno);
    if (fh >= 0) close(fh);
    DMP_LOG("探针结束\n");
    return NULL;
}
