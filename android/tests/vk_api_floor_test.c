// vk_device.c 的支持范围下限：物理设备 apiVersion 低于 1.1（GPU 只支持 Vulkan 1.0）具名拒绝，1.1 及以上放行。
// 被测函数 physical_api_floor（连同 fail）由 vk_api_floor_test.sh 从 vk_device.c 原样摘出（snippet.inc）。期望串按函数约定手写。
#include <vulkan/vulkan.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>
#include "snippet.inc"

static int failures;
static void expect(int ok, const char *what) { if (!ok) { failures++; fprintf(stderr, "FAIL: %s\n", what); } }

int main(void) {
    char why[192];
    strcpy(why, "untouched");
    expect(physical_api_floor(VK_MAKE_API_VERSION(0, 1, 0, 61), why, sizeof why) == -1, "Vulkan 1.0.61 GPU rejected");
    expect(!strcmp(why, "GPU supports only Vulkan 1.0 (apiVersion=1.0.61), outside the supported range (Vulkan 1.1+ required)"),
           "Vulkan 1.0 reason names the GPU version");
    strcpy(why, "untouched");
    expect(physical_api_floor(VK_MAKE_API_VERSION(0, 1, 0, 0), why, sizeof why) == -1, "Vulkan 1.0.0 GPU rejected");
    expect(!strncmp(why, "GPU supports only Vulkan 1.0 (apiVersion=1.0.0)", 47), "Vulkan 1.0.0 reason");
    strcpy(why, "untouched");
    expect(physical_api_floor(VK_MAKE_API_VERSION(0, 1, 1, 0), why, sizeof why) == 0, "Vulkan 1.1.0 GPU accepted");
    expect(!strcmp(why, "untouched"), "accepted GPU leaves the reason alone");
    expect(physical_api_floor(VK_MAKE_API_VERSION(0, 1, 3, 250), why, sizeof why) == 0, "Vulkan 1.3.250 GPU accepted");
    char tiny[8];
    expect(physical_api_floor(VK_MAKE_API_VERSION(0, 1, 0, 61), tiny, sizeof tiny) == -1 && strlen(tiny) == 7, "short buffer truncates");
    if (failures) return 1;
    printf("PASS: vk_api_floor 7 cases\n");
    return 0;
}
