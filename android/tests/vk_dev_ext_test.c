// vk_device.c 的设备 / 实例扩展查询：如实区分「确实不支持」（0）与「枚举失败、能力未知」（-1）。
// 被测函数由 vk_dev_ext_test.sh 从给定的 vk_device.c 原样摘出（snippet.inc）；替身的 vkEnumerateDeviceExtensionProperties 按场景出错 / 变长。
#include <vulkan/vulkan.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
static int g_mode, g_calls, g_fail_alloc;
static uint32_t g_have = 3;
static const char *g_names[4] = {"VK_KHR_swapchain", "VK_EXT_index_type_uint8", "VK_GOOGLE_display_timing", "VK_KHR_draw_indirect_count"};
enum { OK, FIRST_FAIL, SECOND_FAIL, GROWS, ALWAYS_INCOMPLETE };
static VKAPI_ATTR VkResult VKAPI_CALL fake_enum(VkPhysicalDevice p, const char *layer, uint32_t *n, VkExtensionProperties *out) {
    (void)p; (void)layer; g_calls++;
    if (!out) {
        if (g_mode == FIRST_FAIL) return VK_ERROR_OUT_OF_HOST_MEMORY;
        *n = g_mode == GROWS && g_calls == 1 ? 2 : g_have; return VK_SUCCESS;
    }
    if (g_mode == SECOND_FAIL) { *n = 0; return VK_ERROR_INITIALIZATION_FAILED; }
    uint32_t total = g_mode == ALWAYS_INCOMPLETE ? *n + 1 : g_have;   // 「总是又多一项」：给多少都不够
    uint32_t give = *n < total ? *n : total;
    for (uint32_t i = 0; i < give; i++) { memset(&out[i], 0, sizeof out[i]); snprintf(out[i].extensionName, sizeof out[i].extensionName, "%s", g_names[i % 4]); }
    *n = give;
    return give < total ? VK_INCOMPLETE : VK_SUCCESS;
}
static int g_inst_calls, g_dev_calls;
static VKAPI_ATTR VkResult VKAPI_CALL fake_dev_enum(VkPhysicalDevice p, const char *layer, uint32_t *n, VkExtensionProperties *out) { g_dev_calls++; return fake_enum(p, layer, n, out); }
static VKAPI_ATTR VkResult VKAPI_CALL fake_inst_enum(const char *layer, uint32_t *n, VkExtensionProperties *out) { g_inst_calls++; return fake_enum(VK_NULL_HANDLE, layer, n, out); }
static void *fake_calloc(size_t a, size_t b) { return g_fail_alloc ? NULL : calloc(a, b); }
#define vkEnumerateDeviceExtensionProperties fake_dev_enum
#define vkEnumerateInstanceExtensionProperties fake_inst_enum
#define calloc fake_calloc
#define S2A_DLOG(...) fprintf(stderr, __VA_ARGS__)
#include "snippet.inc"
#undef calloc
static unsigned nfail;
#define CHECK(x, msg) do { if (!(x)) { printf("FAIL: %s\n", msg); nfail++; } } while (0)
static VkPhysicalDevice g_phys;   // 空 = 查实例扩展，非空 = 查设备扩展（两种各跑一遍同样的场景）
static int q(int mode, int fail_alloc, uint32_t have, const char *name) {
    g_mode = mode; g_fail_alloc = fail_alloc; g_have = have; g_calls = 0; g_inst_calls = g_dev_calls = 0;
    char why[96] = ""; int st = extension_state(g_phys, name, why, sizeof why);
    if (g_phys ? g_inst_calls || !g_dev_calls : g_dev_calls || !g_inst_calls) { printf("FAIL: %s query used the wrong enumerator\n", g_phys ? "device" : "instance"); st = 99; }
    printf("  %s mode=%d alloc_fail=%d have=%u %s → %d（%s）\n", g_phys ? "设备" : "实例", mode, fail_alloc, have, name, st, why);
    return st;
}
int main(void) {
  for (int pass = 0; pass < 2; pass++) {
    g_phys = pass ? (VkPhysicalDevice)(uintptr_t)0x1000 : VK_NULL_HANDLE;
    CHECK(q(OK, 0, 3, "VK_GOOGLE_display_timing") == 1, "present extension → 1");
    CHECK(q(OK, 0, 3, "VK_KHR_draw_indirect_count") == 0, "complete list without it → 0 (really unsupported)");
    CHECK(q(FIRST_FAIL, 0, 3, "VK_KHR_swapchain") == -1, "first enumeration fails → -1 (unknown), not 0");
    CHECK(q(OK, 1, 3, "VK_KHR_swapchain") == -1, "allocation fails → -1 (unknown), not 0");
    CHECK(q(SECOND_FAIL, 0, 3, "VK_KHR_swapchain") == -1, "second enumeration fails → -1, result checked");
    CHECK(q(GROWS, 0, 3, "VK_GOOGLE_display_timing") == 1, "list grows between calls (VK_INCOMPLETE) → re-query, third entry found");
    CHECK(q(ALWAYS_INCOMPLETE, 0, 3, "VK_KHR_draw_indirect_count") == -1, "never complete → -1, partial list not used to say absent");
  }
    printf("vk_dev_ext: failures=%u\n", nfail);
    return nfail ? 1 : 0;
}
