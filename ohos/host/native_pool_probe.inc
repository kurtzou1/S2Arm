// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 S2Arm contributors
// Exercises the real backing owner without mapping over guest memory. Mode 2
// stops before the game, so measurements and allocation failures are isolated.
#include "../native/native_buffer_pool.h"

#include <time.h>
static uint64_t dmp_now_ns(void) { struct timespec t; clock_gettime(CLOCK_MONOTONIC, &t); return (uint64_t)t.tv_sec * 1000000000ull + (uint64_t)t.tv_nsec; }
// sync=0 skips DMA_BUF cache ioctls (measures whether the driver mapping is IO-coherent in practice;
// a mismatch there is reported, not treated as a wrapper failure). One PASS does not prove coherence.
static int dmp_pool_case(struct dmp_vk *v, size_t size, unsigned rounds, int sync) {
    uint64_t sync_ns = 0, sync_max = 0, sync_n = 0, cpu_ns = 0, gpu_ns = 0, t0;
    unsigned mismatches = 0;
#define DMP_TIMED(call) (t0 = dmp_now_ns(), _dmp_rc = (call), t0 = dmp_now_ns() - t0, sync_ns += t0, sync_n++, sync_max = t0 > sync_max ? t0 : sync_max, _dmp_rc)
    int _dmp_rc;
    struct s2a_ohos_pool *pool = NULL;
    char why[256];
    void *base = NULL, *alias = NULL, *readback = NULL;
    VkBuffer staging = VK_NULL_HANDLE;
    VkDeviceMemory staging_memory = VK_NULL_HANDLE;
    VkCommandBuffer cmd = VK_NULL_HANDLE;
    VkFence fence = VK_NULL_HANDLE;
    size_t half = size / 2;
    int ok = 0, pending = 0;
    VkResult vr = VK_SUCCESS;
    if (s2a_ohos_pool_create(v->physical, v->dev, &v->mp, size, &pool, why, sizeof why)) {
        DMP_LOG("pool bytes=%zu create failed: %s\n", size, why); return 0;
    }
    void *reserve = mmap(NULL, size, PROT_NONE, MAP_PRIVATE | MAP_ANONYMOUS, -1, 0);
    if (reserve == MAP_FAILED) goto cleanup;
    if (s2a_ohos_pool_alias(pool, reserve, 0, size, &base)) { munmap(reserve, size); goto cleanup; }
    if (s2a_ohos_pool_alias(pool, NULL, half, half, &alias)) goto cleanup;
    // Reject bad ranges before mmap; verify the end boundary, not only offset 0.
    void *bad = NULL;
    if (!s2a_ohos_pool_alias(pool, NULL, size, half, &bad) || bad) goto cleanup;
    errno = 0;
    VkBufferCreateInfo bi = { .sType = VK_STRUCTURE_TYPE_BUFFER_CREATE_INFO, .size = half,
        .usage = VK_BUFFER_USAGE_TRANSFER_DST_BIT, .sharingMode = VK_SHARING_MODE_EXCLUSIVE };
    if ((vr = vkCreateBuffer(v->dev, &bi, NULL, &staging))) goto cleanup;
    VkMemoryRequirements req;
    vkGetBufferMemoryRequirements(v->dev, staging, &req);
    uint32_t type = dmp_type(v, req.memoryTypeBits, VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT | VK_MEMORY_PROPERTY_HOST_COHERENT_BIT);
    if (type == UINT32_MAX) goto cleanup;
    VkMemoryAllocateInfo ai = { .sType = VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO, .allocationSize = req.size, .memoryTypeIndex = type };
    if ((vr = vkAllocateMemory(v->dev, &ai, NULL, &staging_memory)) ||
        (vr = vkBindBufferMemory(v->dev, staging, staging_memory, 0)) ||
        (vr = vkMapMemory(v->dev, staging_memory, 0, half, 0, &readback))) goto cleanup;
    VkCommandBufferAllocateInfo cai = { .sType = VK_STRUCTURE_TYPE_COMMAND_BUFFER_ALLOCATE_INFO,
        .commandPool = v->pool, .level = VK_COMMAND_BUFFER_LEVEL_PRIMARY, .commandBufferCount = 1 };
    VkFenceCreateInfo fi = { .sType = VK_STRUCTURE_TYPE_FENCE_CREATE_INFO };
    if ((vr = vkAllocateCommandBuffers(v->dev, &cai, &cmd)) || (vr = vkCreateFence(v->dev, &fi, NULL, &fence))) goto cleanup;
    for (unsigned round = 0; round < rounds; round++) {
        uint32_t seed = 0x13579bdfu ^ (round * 0x1020305u);
        uint32_t fill = seed ^ 0xfeedc0deu;
        if (sync && DMP_TIMED(s2a_ohos_pool_cpu_begin(pool, 1))) goto cleanup;
        if (sync && round == 0 && (!s2a_ohos_pool_cpu_begin(pool, 1) || errno != EINVAL)) goto cleanup;
        errno = 0;
        uint32_t *words = base;
        uint64_t c0 = dmp_now_ns();
        for (size_t j = 0; j < half / 4; j++) words[j] = seed ^ (uint32_t)(j * 17);
        // Offset alias writes must hit only the second half of the backing.
        ((uint32_t *)alias)[half / 4 - 1] = ~fill;
        cpu_ns += dmp_now_ns() - c0;
        if (words[size / 4 - 1] != ~fill) { if (sync) s2a_ohos_pool_cpu_end(pool); goto cleanup; }
        if (sync && DMP_TIMED(s2a_ohos_pool_cpu_end(pool))) goto cleanup;
        VkCommandBufferBeginInfo begin = { .sType = VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO,
            .flags = VK_COMMAND_BUFFER_USAGE_ONE_TIME_SUBMIT_BIT };
        if ((vr = vkResetCommandBuffer(cmd, 0)) || (vr = vkBeginCommandBuffer(cmd, &begin))) goto cleanup;
        // fd/mmap is platform external access, not vkMapMemory. Cache ioctls
        // alone do not transfer Vulkan ownership. Acquire after CPU END.
        VkBufferMemoryBarrier acquire = { .sType = VK_STRUCTURE_TYPE_BUFFER_MEMORY_BARRIER,
            .dstAccessMask = VK_ACCESS_TRANSFER_READ_BIT | VK_ACCESS_TRANSFER_WRITE_BIT,
            .srcQueueFamilyIndex = VK_QUEUE_FAMILY_FOREIGN_EXT, .dstQueueFamilyIndex = v->queue_family,
            .buffer = s2a_ohos_pool_buffer(pool), .size = VK_WHOLE_SIZE };
        vkCmdPipelineBarrier(cmd, VK_PIPELINE_STAGE_TOP_OF_PIPE_BIT, VK_PIPELINE_STAGE_TRANSFER_BIT, 0, 0, NULL, 1, &acquire, 0, NULL);
        VkBufferCopy copy = { .size = half };
        vkCmdCopyBuffer(cmd, s2a_ohos_pool_buffer(pool), staging, 1, &copy);
        vkCmdFillBuffer(cmd, s2a_ohos_pool_buffer(pool), half, half, fill);
        VkMemoryBarrier release = { .sType = VK_STRUCTURE_TYPE_MEMORY_BARRIER,
            .srcAccessMask = VK_ACCESS_TRANSFER_WRITE_BIT, .dstAccessMask = VK_ACCESS_HOST_READ_BIT };
        vkCmdPipelineBarrier(cmd, VK_PIPELINE_STAGE_TRANSFER_BIT, VK_PIPELINE_STAGE_HOST_BIT, 0, 1, &release, 0, NULL, 0, NULL);
        VkBufferMemoryBarrier external_release = { .sType = VK_STRUCTURE_TYPE_BUFFER_MEMORY_BARRIER,
            .srcAccessMask = VK_ACCESS_TRANSFER_READ_BIT | VK_ACCESS_TRANSFER_WRITE_BIT,
            .srcQueueFamilyIndex = v->queue_family, .dstQueueFamilyIndex = VK_QUEUE_FAMILY_FOREIGN_EXT,
            .buffer = s2a_ohos_pool_buffer(pool), .size = VK_WHOLE_SIZE };
        vkCmdPipelineBarrier(cmd, VK_PIPELINE_STAGE_TRANSFER_BIT, VK_PIPELINE_STAGE_BOTTOM_OF_PIPE_BIT,
                             0, 0, NULL, 1, &external_release, 0, NULL);
        if ((vr = vkEndCommandBuffer(cmd)) || (vr = vkResetFences(v->dev, 1, &fence))) goto cleanup;
        VkSubmitInfo submit = { .sType = VK_STRUCTURE_TYPE_SUBMIT_INFO, .commandBufferCount = 1, .pCommandBuffers = &cmd };
        uint64_t g0 = dmp_now_ns();
        if ((vr = vkQueueSubmit(v->q, 1, &submit, fence))) goto cleanup;
        pending = 1;
        if ((vr = vkWaitForFences(v->dev, 1, &fence, VK_TRUE, 5000000000ull))) goto cleanup;
        pending = 0;
        gpu_ns += dmp_now_ns() - g0;
        if (sync && DMP_TIMED(s2a_ohos_pool_cpu_begin(pool, 0))) goto cleanup;
        int match = 1;
        for (size_t j = 0; j < half / 4; j++) {
            if (((uint32_t *)readback)[j] != (seed ^ (uint32_t)(j * 17)) ||
                words[j] != (seed ^ (uint32_t)(j * 17)) ||
                words[half / 4 + j] != fill || ((uint32_t *)alias)[j] != fill) { match = 0; break; }
        }
        if (sync && DMP_TIMED(s2a_ohos_pool_cpu_end(pool))) goto cleanup;
        if (!match) {
            if (sync) { DMP_LOG("pool bytes=%zu round=%u data mismatch\n", size, round); goto cleanup; }
            mismatches++;
        }
    }
    ok = 1;
cleanup:;
    int saved_errno = ok || vr != VK_SUCCESS ? 0 : errno;
    // A timeout is not completion. Keep all submitted objects until process exit.
    if (pending) {
        DMP_LOG("pool bytes=%zu result=FAIL vk=%d pending=1; resources retained\n", size, vr);
        return 0;
    }
    if (fence) vkDestroyFence(v->dev, fence, NULL);
    if (cmd) vkFreeCommandBuffers(v->dev, v->pool, 1, &cmd);
    if (readback) vkUnmapMemory(v->dev, staging_memory);
    if (staging) vkDestroyBuffer(v->dev, staging, NULL);
    if (staging_memory) vkFreeMemory(v->dev, staging_memory, NULL);
    if (alias && munmap(alias, half)) { saved_errno = errno; ok = 0; }
    if (base && munmap(base, size)) { saved_errno = errno; ok = 0; }
    if (s2a_ohos_pool_destroy(pool)) { DMP_LOG("pool CPU epoch retained after failed cache sync\n"); ok = 0; }
    DMP_LOG("pool bytes=%zu rounds=%u sync=%d result=%s vk=%d errno=%d pending=0 nosync_mismatch_rounds=%u; "
            "ioctl n=%llu avg=%.1fus max=%.1fus; cpu_write avg=%.2fms; gpu_copy+fill+wait avg=%.2fms\n",
            size, rounds, sync, ok ? "PASS" : "FAIL", vr, saved_errno, mismatches,
            (unsigned long long)sync_n, sync_n ? sync_ns / 1000.0 / sync_n : 0.0, sync_max / 1000.0,
            rounds ? cpu_ns / 1e6 / rounds : 0.0, rounds ? gpu_ns / 1e6 / rounds : 0.0);
#undef DMP_TIMED
    return ok;
}

// Largest single BLOB allocation that imports; create/destroy only.
static void dmp_pool_size_probe(struct dmp_vk *v) {
    static const size_t sizes[] = { 128u << 20, 256u << 20, 512u << 20, 1024u << 20 };
    for (unsigned i = 0; i < sizeof sizes / sizeof sizes[0]; i++) {
        struct s2a_ohos_pool *pool = NULL; char why[256] = "";
        uint64_t t = dmp_now_ns();
        int rc = s2a_ohos_pool_create(v->physical, v->dev, &v->mp, sizes[i], &pool, why, sizeof why);
        t = dmp_now_ns() - t;
        uint64_t s0 = 0, s1 = 0;
        if (!rc) {
            uint64_t a = dmp_now_ns(); int b = s2a_ohos_pool_cpu_begin(pool, 1); s0 = dmp_now_ns() - a;
            a = dmp_now_ns(); int e = b ? -1 : s2a_ohos_pool_cpu_end(pool); s1 = dmp_now_ns() - a;
            if (b || e) DMP_LOG("size probe bytes=%zu sync begin=%d end=%d errno=%d\n", sizes[i], b, e, errno);
            s2a_ohos_pool_destroy(pool);
        }
        DMP_LOG("size probe bytes=%zu create=%s (%s) create_ms=%.1f whole_sync_begin_us=%.1f end_us=%.1f\n",
                sizes[i], rc ? "FAIL" : "OK", rc ? why : "-", t / 1e6, s0 / 1e3, s1 / 1e3);
        if (rc) break;
    }
}
