// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 S2Arm contributors
#include "nvn_plat_vk.h"
#include "plat_ohos.h"
#include <vulkan/vulkan_ohos.h>
#include <pthread.h>

const char* const* nvn_plat_vk_instance_exts(uint32_t* n) {
  static const char* const extensions[] = {"VK_KHR_surface", "VK_OHOS_surface"};
  if (n)
    *n = 2;
  return extensions;
}

VkResult nvn_plat_vk_surface_create(VkInstance instance, void* native, VkSurfaceKHR* out) {
  if (out)
    *out = VK_NULL_HANDLE;
  if (!instance || !native || !out)
    return VK_ERROR_INITIALIZATION_FAILED;
  PFN_vkCreateSurfaceOHOS create =
      (PFN_vkCreateSurfaceOHOS)vkGetInstanceProcAddr(instance, "vkCreateSurfaceOHOS");
  if (!create)
    return VK_ERROR_EXTENSION_NOT_PRESENT;
  VkSurfaceCreateInfoOHOS ci = {0};
  ci.sType = VK_STRUCTURE_TYPE_SURFACE_CREATE_INFO_OHOS;
  ci.window = (OHNativeWindow*)native;
  VkResult result = create(instance, &ci, NULL, out);
  if (result != VK_SUCCESS)
    *out = VK_NULL_HANDLE;
  return result;
}

static pthread_mutex_t window_lock = PTHREAD_MUTEX_INITIALIZER;
static void* window;
static uint32_t window_width, window_height;
void nvn_ohos_set_window(void* native, uint32_t width, uint32_t height) {
  pthread_mutex_lock(&window_lock);
  window = native;
  window_width = width;
  window_height = height;
  pthread_mutex_unlock(&window_lock);
}
int nvn_plat_window_size(void* native, uint32_t* w, uint32_t* h) {
  if (w)
    *w = 0;
  if (h)
    *h = 0;
  pthread_mutex_lock(&window_lock);
  int ok = native && native == window && window_width && window_height;
  if (ok) {
    if (w)
      *w = window_width;
    if (h)
      *h = window_height;
  }
  pthread_mutex_unlock(&window_lock);
  return ok;
}
