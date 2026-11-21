// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 S2Arm contributors
// OHOS backing for direct-mode physical pools. Serialized by the GPU owner.
// This object owns its allocation, not guest VA. Guest alias migration is a
// separate operation: never replace a live guest mapping merely to register it.
#pragma once
#include <stddef.h>
#include <stdint.h>
#include <vulkan/vulkan.h>

struct s2a_ohos_pool;
int s2a_ohos_pool_create(VkPhysicalDevice physical, VkDevice device, const VkPhysicalDeviceMemoryProperties *types,
                        size_t size, struct s2a_ohos_pool **out, char *why, size_t why_size);
VkBuffer s2a_ohos_pool_buffer(const struct s2a_ohos_pool *pool);
// 之后建的池带 SHADER_DEVICE_ADDRESS；s2a_ohos_pool_device_address 取整池 GPU 地址（没开返回 0）。
void s2a_ohos_pool_set_device_address(int on);
uint64_t s2a_ohos_pool_device_address(const struct s2a_ohos_pool *pool);
// Creates a fresh alias at a caller-owned reservation (NULL allocates a new VA); offset/size must be page
// aligned. The caller owns munmap and must drop all aliases before destroy.
int s2a_ohos_pool_alias(struct s2a_ohos_pool *pool, void *reservation,
                       size_t offset, size_t size, void **out);
// Explicit CPU epochs, after GPU completion and before its next submission.
// DMA_BUF_SYNC does cache maintenance only; it is NOT a GPU fence/barrier.
int s2a_ohos_pool_cpu_begin(struct s2a_ohos_pool *pool, int write);
int s2a_ohos_pool_cpu_end(struct s2a_ohos_pool *pool);
// Only after all referencing GPU work has completed and aliases are unmapped.
int s2a_ohos_pool_destroy(struct s2a_ohos_pool *pool);
