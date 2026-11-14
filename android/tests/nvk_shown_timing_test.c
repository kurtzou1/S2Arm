// Host fixture includes NDK 29 Vulkan declarations, including the driver ABI.
#include <vulkan/vulkan.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#define NVN_PLAT_LOG_INFO 1
static char logline[512];
static void nvn_plat_log(int level, const char *cls, const char *text) {
    (void)level; (void)cls; snprintf(logline, sizeof logline, "%s", text);
}
static uint64_t fake_now;
static uint64_t now_ns(void) { return fake_now; }
#include "backend_vulkan_timing.h"
static unsigned nfail, calls, available;
static struct { VkSwapchainKHR sc; VkPastPresentationTimingGOOGLE value; } queue[64];
#define CHECK(x, msg) do { if (!(x)) { fprintf(stderr, "FAIL: %s\n", msg); nfail++; } } while (0)
static VKAPI_ATTR VkResult VKAPI_CALL past(VkDevice d, VkSwapchainKHR s, uint32_t *n, VkPastPresentationTimingGOOGLE *out) {
    (void)d; calls++;
    uint32_t count = 0, keep = 0; int more = 0;
    for (uint32_t i = 0; i < available; i++) {
        if (queue[i].sc == s && count < *n) out[count++] = queue[i].value;
        else { if (queue[i].sc == s) more = 1; queue[keep++] = queue[i]; }
    }
    available = keep; *n = count;
    return more ? VK_INCOMPLETE : VK_SUCCESS;
}
VKAPI_ATTR PFN_vkVoidFunction VKAPI_CALL vkGetDeviceProcAddr(VkDevice d, const char *name) {
    (void)d;
    return !strcmp(name, "vkGetPastPresentationTimingGOOGLE") ? (PFN_vkVoidFunction)past : NULL;
}
static void queue_record(VkSwapchainKHR sc, uint32_t id, uint64_t t) {
    queue[available].sc = sc;
    queue[available++].value = (VkPastPresentationTimingGOOGLE){.presentID=id, .actualPresentTime=t};
}
int main(void) {
    struct wsi_timing t;
    wsi_timing_init(&t, VK_NULL_HANDLE, 0, 1);
    CHECK(!wsi_timing_id(&t), "disabled sends no ID");
    t.start = 1; wsi_timing_report(&t, 5000000001ull);
    CHECK(strstr(logline, "帧率= ") && strstr(logline, "开关未启用"), "disabled log has empty values and reason");
    wsi_timing_init(&t, VK_NULL_HANDLE, 1, 0);
    CHECK(!wsi_timing_id(&t), "unsupported sends no ID");
    t.start = 1; wsi_timing_report(&t, 5000000001ull);
    CHECK(strstr(logline, "帧率= ") && strstr(logline, "扩展未启用或不支持"), "unsupported log has empty values and reason");
    wsi_timing_init(&t, VK_NULL_HANDLE, 1, 1); t.start = 1000000000ull;
    for (uint32_t i = 1; i <= 20; i++) {
        uint32_t id = wsi_timing_id(&t); CHECK(id == i, "monotonic present ID");
        wsi_timing_submitted(&t, id); queue_record(VK_NULL_HANDLE, id, 1000000000ull + i * 10000000ull);
    }
    fake_now = 2000000000ull; wsi_timing_poll(&t, VK_NULL_HANDLE, VK_NULL_HANDLE);
    CHECK(calls == 2 && available == 0 && t.nsamples == 20 && !t.pending_count,
          "VK_INCOMPLETE consumes partial records exactly once before next batch");
    wsi_timing_report(&t, 6000000000ull);
    CHECK(strstr(logline, "帧率=100.00") && strstr(logline, "间隔P99=10.00ms") && strstr(logline, "样本=20"), "actual sample statistics");
    // 上一窗口末尾那帧的记录在本窗口才回收（真机每窗都有）：只计迟到，本窗口照常出数
    t.start = 6000000000ull;
    uint32_t prev = wsi_timing_id(&t); wsi_timing_submitted(&t, prev); queue_record(VK_NULL_HANDLE, prev, 5990000000ull);
    for (uint32_t i = 1; i <= 20; i++) {
        uint32_t id2 = wsi_timing_id(&t); wsi_timing_submitted(&t, id2); queue_record(VK_NULL_HANDLE, id2, 6000000000ull + i * 10000000ull);
    }
    fake_now = 6500000000ull; wsi_timing_poll(&t, VK_NULL_HANDLE, VK_NULL_HANDLE);
    wsi_timing_report(&t, 11000000000ull);
    CHECK(strstr(logline, "帧率=100.00") && strstr(logline, "样本=20") && strstr(logline, "迟到=1"), "late carry-over record counted, window still reports");
    VkSwapchainKHR old_sc = (VkSwapchainKHR)(uintptr_t)1, new_sc = (VkSwapchainKHR)(uintptr_t)2;
    uint32_t old = wsi_timing_id(&t); wsi_timing_submitted(&t, old);
    queue_record(old_sc, old, 7100000000ull);
    wsi_timing_init(&t, VK_NULL_HANDLE, 1, 1); t.start = 7000000000ull;
    uint32_t fresh = wsi_timing_id(&t); wsi_timing_submitted(&t, fresh);
    queue_record(new_sc, fresh, 7150000000ull);
    fake_now = 7200000000ull; wsi_timing_poll(&t, VK_NULL_HANDLE, new_sc);
    CHECK(!t.invalid && t.nsamples == 1 && !t.pending_count && available == 1 && queue[0].sc == old_sc,
          "new generation polls only its own swapchain");
    queue_record(new_sc, 999, 7160000000ull); // unknown ID on this swapchain must not become a sample
    wsi_timing_poll(&t, VK_NULL_HANDLE, new_sc);
    CHECK(t.invalid == 1 && t.nsamples == 1, "unknown ID rejected");
    wsi_timing_report(&t, 12000000000ull);
    CHECK(strstr(logline, "帧率= ") && strstr(logline, "记录不完整"), "invalid sample reports empty metrics");
    available = 0;
    wsi_timing_init(&t, VK_NULL_HANDLE, 1, 1); t.start = 1;
    uint32_t id = wsi_timing_id(&t); wsi_timing_submitted(&t, id); queue_record(VK_NULL_HANDLE, id, 2);
    fake_now = 3; wsi_timing_poll(&t, VK_NULL_HANDLE, VK_NULL_HANDLE);
    wsi_timing_report(&t, 5000000001ull);
    CHECK(strstr(logline, "帧率= ") && strstr(logline, "样本不足"), "one sample stays empty");
    printf("shown timing: failures=%u\n", nfail);
    return nfail ? 1 : 0;
}
