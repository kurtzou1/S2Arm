// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 S2Arm contributors
#pragma once
// Host syntax gate only; core Vulkan declarations come from the real shared headers.
#include <vulkan/vulkan.h>
typedef struct NativeWindow OHNativeWindow;
typedef struct VkSurfaceCreateInfoOHOS {
  VkStructureType sType;
  const void* pNext;
  VkFlags flags;
  OHNativeWindow* window;
} VkSurfaceCreateInfoOHOS;
typedef VkResult(VKAPI_PTR* PFN_vkCreateSurfaceOHOS)(VkInstance, const VkSurfaceCreateInfoOHOS*,
                                                     const VkAllocationCallbacks*, VkSurfaceKHR*);
