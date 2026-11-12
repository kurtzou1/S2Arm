// Real Vulkan entry points and GPU readback, linked with the production host.
// Deliberately leave resources live: session retirement owns their destruction.
#define VK_NO_PROTOTYPES
#include <vulkan/vulkan_core.h>
#include <assert.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include "../../graphics_session.h"

void *dm_vk_lookup(const char *);

#define APIS(X) \
    X(vkCreateInstance) X(vkEnumeratePhysicalDevices) X(vkCreateDevice) X(vkGetDeviceQueue) \
    X(vkCreateBuffer) X(vkGetBufferMemoryRequirements) X(vkAllocateMemory) X(vkBindBufferMemory) X(vkMapMemory) \
    X(vkCreateImage) X(vkGetImageMemoryRequirements) X(vkBindImageMemory) \
    X(vkCreateCommandPool) X(vkAllocateCommandBuffers) X(vkBeginCommandBuffer) X(vkEndCommandBuffer) \
    X(vkCmdClearColorImage) X(vkCmdCopyImageToBuffer) X(vkQueueSubmit) X(vkQueueWaitIdle)
#define DECL(name) static PFN_##name name;
APIS(DECL)
#undef DECL
#define OK(call) assert((call) == VK_SUCCESS)

int s2a_test_vk_session_resources(unsigned rounds) {
    PFN_vkGetInstanceProcAddr get = (PFN_vkGetInstanceProcAddr)dm_vk_lookup("vkGetInstanceProcAddr");
    assert(get);
#define LOAD(name) name = (PFN_##name)get(VK_NULL_HANDLE, #name); assert(name);
    APIS(LOAD)
#undef LOAD
    for (unsigned round = 1; round <= rounds; round++) {
        assert(s2a_graphics_native_begin_session() == 0);
        VkInstance instance;
        VkInstanceCreateInfo ici = {.sType = VK_STRUCTURE_TYPE_INSTANCE_CREATE_INFO};
        OK(vkCreateInstance(&ici, NULL, &instance));
        uint32_t count = 1; VkPhysicalDevice physical;
        OK(vkEnumeratePhysicalDevices(instance, &count, &physical)); assert(count == 1);
        float priority = 1;
        VkDeviceQueueCreateInfo qci = {.sType = VK_STRUCTURE_TYPE_DEVICE_QUEUE_CREATE_INFO, .queueFamilyIndex = 0, .queueCount = 1, .pQueuePriorities = &priority};
        VkDeviceCreateInfo dci = {.sType = VK_STRUCTURE_TYPE_DEVICE_CREATE_INFO, .queueCreateInfoCount = 1, .pQueueCreateInfos = &qci};
        VkDevice device; OK(vkCreateDevice(physical, &dci, NULL, &device));
        VkQueue queue; vkGetDeviceQueue(device, 0, 0, &queue); assert(queue);
        VkBufferCreateInfo bci = {.sType = VK_STRUCTURE_TYPE_BUFFER_CREATE_INFO, .size = 32 * 32 * 4, .usage = VK_BUFFER_USAGE_TRANSFER_DST_BIT};
        VkBuffer buffer; OK(vkCreateBuffer(device, &bci, NULL, &buffer));
        VkMemoryRequirements req; vkGetBufferMemoryRequirements(device, buffer, &req);
        VkMemoryAllocateInfo mai = {.sType = VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO, .allocationSize = req.size, .memoryTypeIndex = 1};
        VkDeviceMemory bmem; OK(vkAllocateMemory(device, &mai, NULL, &bmem)); OK(vkBindBufferMemory(device, buffer, bmem, 0));
        uint8_t *pixels; OK(vkMapMemory(device, bmem, 0, 32 * 32 * 4, 0, (void **)&pixels));
        memset(pixels, 0xcd, 32 * 32 * 4);
        VkImageCreateInfo imci = {.sType = VK_STRUCTURE_TYPE_IMAGE_CREATE_INFO, .imageType = VK_IMAGE_TYPE_2D,
            .format = VK_FORMAT_R8G8B8A8_UNORM, .extent = {32, 32, 1}, .mipLevels = 1, .arrayLayers = 1,
            .samples = VK_SAMPLE_COUNT_1_BIT, .tiling = VK_IMAGE_TILING_OPTIMAL,
            .usage = VK_IMAGE_USAGE_TRANSFER_SRC_BIT | VK_IMAGE_USAGE_TRANSFER_DST_BIT};
        VkImage image; OK(vkCreateImage(device, &imci, NULL, &image));
        vkGetImageMemoryRequirements(device, image, &req); mai.allocationSize = req.size; mai.memoryTypeIndex = 0;
        VkDeviceMemory imem; OK(vkAllocateMemory(device, &mai, NULL, &imem)); OK(vkBindImageMemory(device, image, imem, 0));
        VkCommandPoolCreateInfo pci = {.sType = VK_STRUCTURE_TYPE_COMMAND_POOL_CREATE_INFO, .queueFamilyIndex = 0};
        VkCommandPool pool; OK(vkCreateCommandPool(device, &pci, NULL, &pool));
        VkCommandBufferAllocateInfo cai = {.sType = VK_STRUCTURE_TYPE_COMMAND_BUFFER_ALLOCATE_INFO, .commandPool = pool,
            .level = VK_COMMAND_BUFFER_LEVEL_PRIMARY, .commandBufferCount = 1};
        VkCommandBuffer commands; OK(vkAllocateCommandBuffers(device, &cai, &commands));
        VkCommandBufferBeginInfo begin = {.sType = VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO};
        OK(vkBeginCommandBuffer(commands, &begin));
        int red = round & 1;
        VkClearColorValue clear = {.float32 = {red, 0, 1, 1}};
        VkImageSubresourceRange range = {VK_IMAGE_ASPECT_COLOR_BIT, 0, 1, 0, 1};
        vkCmdClearColorImage(commands, image, VK_IMAGE_LAYOUT_GENERAL, &clear, 1, &range);
        VkBufferImageCopy copy = {.imageSubresource = {VK_IMAGE_ASPECT_COLOR_BIT, 0, 0, 1}, .imageExtent = {32, 32, 1}};
        vkCmdCopyImageToBuffer(commands, image, VK_IMAGE_LAYOUT_GENERAL, buffer, 1, &copy);
        OK(vkEndCommandBuffer(commands));
        VkSubmitInfo submit = {.sType = VK_STRUCTURE_TYPE_SUBMIT_INFO, .commandBufferCount = 1, .pCommandBuffers = &commands};
        OK(vkQueueSubmit(queue, 1, &submit, VK_NULL_HANDLE)); OK(vkQueueWaitIdle(queue));
        for (unsigned i = 0; i < 32 * 32 * 4; i += 4)
            assert(pixels[i] == red * 255 && !pixels[i + 1] && pixels[i + 2] == 255 && pixels[i + 3] == 255);
        assert(s2a_graphics_native_request_stop() == 0);
        assert(s2a_graphics_native_shutdown_session() == 0);
        fprintf(stderr, "[graphics-session] Vulkan %u/%u GPU clear/readback/retirement passed\n", round, rounds);
    }
    return 0;
}

// 块压缩贴图的上传（#542）：8×8 的 BC1，四个纯色块（红 绿 / 蓝 白），缓冲 → 图像 → 贴到 RGBA8 图 → 读回。
// 期望手算：BC1 纯色块 = 两个端点同色、索引全 0 → 整块就是端点色；565 的 31 / 63 展开成 255。
// 两种环境各跑一遍：DM_TEST_NO_BC=1（图像建成解压格式、上传时在 CPU 上解）做完整的上传 → 贴到 RGBA8 → 读回 → 对期望；
// 原生（显卡认 BC）只验上传照常执行——这一层没有把压缩图贴到普通图的实现，压缩图的像素读不回来。
static PFN_vkCmdCopyBufferToImage bc_CopyBufferToImage; static PFN_vkCmdBlitImage bc_BlitImage;
// 一种格式一个纯色块。kind 决定块怎么拼（见 bc_case_block），v 是拼块用的数，want 是贴到 RGBA8 之后的期望。手算依据：
//   BC1：两个 565 端点同色、索引全 0 → 整块是端点色（31 / 63 展开成 255）。
//   BC2：前 8 字节每像素 4 位不透明度，值 a → a×17；后 8 字节同 BC1。
//   BC3：不透明度两个端点同值、索引全 0 → 就是端点值；后 8 字节同 BC1。
//   BC4 / BC5：每通道两个端点同值、索引全 0 → 端点值；有符号的 127 = 1.0 → 255，−127 = −1.0 → 夹成 0。
//   BC7 模式 6：第 6 位是模式位；7 位端点 + 1 位共用低位 → 8 位值 = 端点×2 + 低位；两端点相同、索引全 0。
//   BC6H 模式 3（低 5 位 = 3）：10 位端点不带差分。无符号 1023 → 0xFFFF → ×31÷64 = 0x7BFF（最大的有限半精度数）→ 夹成 255；
//     有符号 511 → 0x7FFF → ×31÷32 = 0x7BFF → 255；0 → 0。不透明度恒为 1。
// sRGB 的格式只用 0 和 255（两种编码下相同；BC7 sRGB 的 1 换成线性后不到半级，读成 0）。
struct bc_case { const char *name; VkFormat format; int kind; int v[5]; uint8_t want[4]; };
enum { BK_BC1, BK_BC2, BK_BC3, BK_BC4, BK_BC5, BK_BC6, BK_BC7 };
static const struct bc_case bc_cases[] = {
    {"BC1 RGB", VK_FORMAT_BC1_RGB_UNORM_BLOCK, BK_BC1, {0xF800}, {255, 0, 0, 255}},
    {"BC1 RGBA", VK_FORMAT_BC1_RGBA_UNORM_BLOCK, BK_BC1, {0x07E0}, {0, 255, 0, 255}},
    {"BC1 RGB sRGB", VK_FORMAT_BC1_RGB_SRGB_BLOCK, BK_BC1, {0x001F}, {0, 0, 255, 255}},
    {"BC1 RGBA sRGB", VK_FORMAT_BC1_RGBA_SRGB_BLOCK, BK_BC1, {0xF81F}, {255, 0, 255, 255}},
    {"BC2", VK_FORMAT_BC2_UNORM_BLOCK, BK_BC2, {0x001F, 8}, {0, 0, 255, 136}},
    {"BC2 sRGB", VK_FORMAT_BC2_SRGB_BLOCK, BK_BC2, {0xF800, 3}, {255, 0, 0, 51}},
    {"BC3", VK_FORMAT_BC3_UNORM_BLOCK, BK_BC3, {0x07E0, 100}, {0, 255, 0, 100}},
    {"BC3 sRGB", VK_FORMAT_BC3_SRGB_BLOCK, BK_BC3, {0xFFE0, 200}, {255, 255, 0, 200}},
    {"BC4", VK_FORMAT_BC4_UNORM_BLOCK, BK_BC4, {200}, {200, 0, 0, 255}},
    {"BC4 有符号", VK_FORMAT_BC4_SNORM_BLOCK, BK_BC4, {127}, {255, 0, 0, 255}},
    {"BC5", VK_FORMAT_BC5_UNORM_BLOCK, BK_BC5, {50, 60}, {50, 60, 0, 255}},
    {"BC5 有符号", VK_FORMAT_BC5_SNORM_BLOCK, BK_BC5, {0x81, 127}, {0, 255, 0, 255}},
    {"BC6H 无符号", VK_FORMAT_BC6H_UFLOAT_BLOCK, BK_BC6, {1023, 0, 1023}, {255, 0, 255, 255}},
    {"BC6H 有符号", VK_FORMAT_BC6H_SFLOAT_BLOCK, BK_BC6, {0, 511, 511}, {0, 255, 255, 255}},
    {"BC7", VK_FORMAT_BC7_UNORM_BLOCK, BK_BC7, {127, 0, 64, 100, 0}, {254, 0, 128, 200}},
    {"BC7 sRGB", VK_FORMAT_BC7_SRGB_BLOCK, BK_BC7, {127, 0, 0, 127, 1}, {255, 0, 0, 255}},
    {NULL, 0, 0, {0}, {0}},
};
static void bc_put(uint8_t *b, int pos, int n, unsigned v) { for (int i = 0; i < n; i++) if (v >> i & 1) b[(pos + i) / 8] |= (uint8_t)(1u << ((pos + i) % 8)); }   // 低位在前
static void bc_case_block(const struct bc_case *k, uint8_t *b) {   // b 已清零
    uint16_t c = (uint16_t)k->v[0];
    switch (k->kind) {
    case BK_BC1: memcpy(b, &c, 2); memcpy(b + 2, &c, 2); break;
    case BK_BC2: memset(b, k->v[1] * 17, 8); memcpy(b + 8, &c, 2); memcpy(b + 10, &c, 2); break;
    case BK_BC3: b[0] = b[1] = (uint8_t)k->v[1]; memcpy(b + 8, &c, 2); memcpy(b + 10, &c, 2); break;
    case BK_BC4: b[0] = b[1] = (uint8_t)k->v[0]; break;
    case BK_BC5: b[0] = b[1] = (uint8_t)k->v[0]; b[8] = b[9] = (uint8_t)k->v[1]; break;
    case BK_BC6: bc_put(b, 0, 5, 3); for (int e = 0; e < 2; e++) for (int ch = 0; ch < 3; ch++) bc_put(b, 5 + e * 30 + ch * 10, 10, (unsigned)k->v[ch]); break;
    case BK_BC7: bc_put(b, 6, 1, 1); for (int ch = 0; ch < 4; ch++) for (int e = 0; e < 2; e++) bc_put(b, 7 + ch * 14 + e * 7, 7, (unsigned)k->v[ch]); bc_put(b, 63, 2, k->v[4] ? 3 : 0); break;
    }
}
int s2a_test_vk_bc(void) {
    PFN_vkGetInstanceProcAddr get = (PFN_vkGetInstanceProcAddr)dm_vk_lookup("vkGetInstanceProcAddr");
    assert(get);
#define LOAD(name) name = (PFN_##name)get(VK_NULL_HANDLE, #name); assert(name);
    APIS(LOAD)
#undef LOAD
    bc_CopyBufferToImage = (PFN_vkCmdCopyBufferToImage)get(VK_NULL_HANDLE, "vkCmdCopyBufferToImage"); assert(bc_CopyBufferToImage);
    bc_BlitImage = (PFN_vkCmdBlitImage)get(VK_NULL_HANDLE, "vkCmdBlitImage"); assert(bc_BlitImage);
    assert(s2a_graphics_native_begin_session() == 0);
    VkInstance instance; VkInstanceCreateInfo ici = {.sType = VK_STRUCTURE_TYPE_INSTANCE_CREATE_INFO};
    OK(vkCreateInstance(&ici, NULL, &instance));
    uint32_t count = 1; VkPhysicalDevice physical; OK(vkEnumeratePhysicalDevices(instance, &count, &physical)); assert(count == 1);
    float priority = 1;
    VkDeviceQueueCreateInfo qci = {.sType = VK_STRUCTURE_TYPE_DEVICE_QUEUE_CREATE_INFO, .queueFamilyIndex = 0, .queueCount = 1, .pQueuePriorities = &priority};
    VkDeviceCreateInfo dci = {.sType = VK_STRUCTURE_TYPE_DEVICE_CREATE_INFO, .queueCreateInfoCount = 1, .pQueueCreateInfos = &qci};
    VkDevice device; OK(vkCreateDevice(physical, &dci, NULL, &device));
    VkQueue queue; vkGetDeviceQueue(device, 0, 0, &queue); assert(queue);
    VkMemoryRequirements req; VkMemoryAllocateInfo mai = {.sType = VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO, .memoryTypeIndex = 1};
    // 源缓冲：4 个 BC1 块，按块行排（每块行 2 块 × 8 字节）
    VkBufferCreateInfo bci = {.sType = VK_STRUCTURE_TYPE_BUFFER_CREATE_INFO, .size = 32, .usage = VK_BUFFER_USAGE_TRANSFER_SRC_BIT};
    VkBuffer src; OK(vkCreateBuffer(device, &bci, NULL, &src)); vkGetBufferMemoryRequirements(device, src, &req); mai.allocationSize = req.size;
    VkDeviceMemory smem; OK(vkAllocateMemory(device, &mai, NULL, &smem)); OK(vkBindBufferMemory(device, src, smem, 0));
    uint8_t *blocks; OK(vkMapMemory(device, smem, 0, 32, 0, (void **)&blocks));
    static const uint16_t end565[4] = {0xF800, 0x07E0, 0x001F, 0xFFFF};   // 红 绿 蓝 白
    for (int b = 0; b < 4; b++) { memcpy(blocks + b * 8, &end565[b], 2); memcpy(blocks + b * 8 + 2, &end565[b], 2); memset(blocks + b * 8 + 4, 0, 4); }
    // 读回缓冲
    bci.size = 8 * 8 * 4; bci.usage = VK_BUFFER_USAGE_TRANSFER_DST_BIT;
    VkBuffer dst; OK(vkCreateBuffer(device, &bci, NULL, &dst)); vkGetBufferMemoryRequirements(device, dst, &req); mai.allocationSize = req.size;
    VkDeviceMemory dmem; OK(vkAllocateMemory(device, &mai, NULL, &dmem)); OK(vkBindBufferMemory(device, dst, dmem, 0));
    uint8_t *px; OK(vkMapMemory(device, dmem, 0, 8 * 8 * 4, 0, (void **)&px)); memset(px, 0xcd, 8 * 8 * 4);
    VkImageCreateInfo imci = {.sType = VK_STRUCTURE_TYPE_IMAGE_CREATE_INFO, .imageType = VK_IMAGE_TYPE_2D, .format = VK_FORMAT_BC1_RGBA_UNORM_BLOCK, .extent = {8, 8, 1},
        .mipLevels = 1, .arrayLayers = 1, .samples = VK_SAMPLE_COUNT_1_BIT, .tiling = VK_IMAGE_TILING_OPTIMAL,
        .usage = VK_IMAGE_USAGE_SAMPLED_BIT | VK_IMAGE_USAGE_TRANSFER_SRC_BIT | VK_IMAGE_USAGE_TRANSFER_DST_BIT};
    VkImage bc; OK(vkCreateImage(device, &imci, NULL, &bc)); vkGetImageMemoryRequirements(device, bc, &req); mai.allocationSize = req.size; mai.memoryTypeIndex = 0;
    VkDeviceMemory m1; OK(vkAllocateMemory(device, &mai, NULL, &m1)); OK(vkBindImageMemory(device, bc, m1, 0));
    imci.format = VK_FORMAT_R8G8B8A8_UNORM; imci.usage = VK_IMAGE_USAGE_COLOR_ATTACHMENT_BIT | VK_IMAGE_USAGE_TRANSFER_SRC_BIT | VK_IMAGE_USAGE_TRANSFER_DST_BIT;
    VkImage plain; OK(vkCreateImage(device, &imci, NULL, &plain)); vkGetImageMemoryRequirements(device, plain, &req); mai.allocationSize = req.size;
    VkDeviceMemory m2; OK(vkAllocateMemory(device, &mai, NULL, &m2)); OK(vkBindImageMemory(device, plain, m2, 0));
    VkCommandPoolCreateInfo pci = {.sType = VK_STRUCTURE_TYPE_COMMAND_POOL_CREATE_INFO, .queueFamilyIndex = 0};
    VkCommandPool pool; OK(vkCreateCommandPool(device, &pci, NULL, &pool));
    VkCommandBufferAllocateInfo cai = {.sType = VK_STRUCTURE_TYPE_COMMAND_BUFFER_ALLOCATE_INFO, .commandPool = pool, .level = VK_COMMAND_BUFFER_LEVEL_PRIMARY, .commandBufferCount = 1};
    VkCommandBuffer cb; OK(vkAllocateCommandBuffers(device, &cai, &cb));
    VkCommandBufferBeginInfo begin = {.sType = VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO};
    OK(vkBeginCommandBuffer(cb, &begin));
    VkBufferImageCopy up = {.imageSubresource = {VK_IMAGE_ASPECT_COLOR_BIT, 0, 0, 1}, .imageExtent = {8, 8, 1}};
    bc_CopyBufferToImage(cb, src, bc, VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL, 1, &up);
    const int nobc = getenv("DM_TEST_NO_BC") != NULL;
    if (nobc) {
    VkImageBlit bl = {.srcSubresource = {VK_IMAGE_ASPECT_COLOR_BIT, 0, 0, 1}, .srcOffsets = {{0, 0, 0}, {8, 8, 1}}, .dstSubresource = {VK_IMAGE_ASPECT_COLOR_BIT, 0, 0, 1}, .dstOffsets = {{0, 0, 0}, {8, 8, 1}}};
    bc_BlitImage(cb, bc, VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL, plain, VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL, 1, &bl, VK_FILTER_NEAREST);
    VkBufferImageCopy down = {.imageSubresource = {VK_IMAGE_ASPECT_COLOR_BIT, 0, 0, 1}, .imageExtent = {8, 8, 1}};
    vkCmdCopyImageToBuffer(cb, plain, VK_IMAGE_LAYOUT_GENERAL, dst, 1, &down);
    }
    OK(vkEndCommandBuffer(cb));
    VkSubmitInfo submit = {.sType = VK_STRUCTURE_TYPE_SUBMIT_INFO, .commandBufferCount = 1, .pCommandBuffers = &cb};
    OK(vkQueueSubmit(queue, 1, &submit, VK_NULL_HANDLE)); OK(vkQueueWaitIdle(queue));
    static const uint8_t want[4][4] = {{255, 0, 0, 255}, {0, 255, 0, 255}, {0, 0, 255, 255}, {255, 255, 255, 255}};
    int bad = 0;
    for (int y = 0; nobc && y < 8; y++) for (int x = 0; x < 8; x++) { const uint8_t *p = px + (y * 8 + x) * 4, *w = want[(y / 4) * 2 + x / 4]; if (memcmp(p, w, 4)) { if (!bad++) fprintf(stderr, "[graphics-session] BC1 (%d,%d) = %u %u %u %u，期望 %u %u %u %u\n", x, y, p[0], p[1], p[2], p[3], w[0], w[1], w[2], w[3]); } }
    // 其余格式（BC1–BC7 的 16 个 Vulkan 格式号）：每种一张 4×4、一个纯色块，同一条通路读回 16 个像素。
    // 块的字节和期望都按格式规范手算，写在 bc_cases 里；贴到 RGBA8 时没有的通道读成 0、没有的不透明度读成 255，超出 0–1 的夹住。
    int fbad = 0, nfmt = 0;
    for (const struct bc_case *k = bc_cases; k->name; k++, nfmt++) {
        memset(blocks, 0, 32); bc_case_block(k, blocks); memset(px, 0xcd, 64);
        imci.format = k->format; imci.extent = (VkExtent3D){4, 4, 1}; imci.usage = VK_IMAGE_USAGE_SAMPLED_BIT | VK_IMAGE_USAGE_TRANSFER_SRC_BIT | VK_IMAGE_USAGE_TRANSFER_DST_BIT;
        VkImage img; OK(vkCreateImage(device, &imci, NULL, &img)); vkGetImageMemoryRequirements(device, img, &req); mai.allocationSize = req.size;
        VkDeviceMemory im; OK(vkAllocateMemory(device, &mai, NULL, &im)); OK(vkBindImageMemory(device, img, im, 0));
        VkCommandBuffer c2; OK(vkAllocateCommandBuffers(device, &cai, &c2)); OK(vkBeginCommandBuffer(c2, &begin));
        VkBufferImageCopy u2 = {.imageSubresource = {VK_IMAGE_ASPECT_COLOR_BIT, 0, 0, 1}, .imageExtent = {4, 4, 1}};
        bc_CopyBufferToImage(c2, src, img, VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL, 1, &u2);
        if (nobc) {
            VkImageBlit b2 = {.srcSubresource = {VK_IMAGE_ASPECT_COLOR_BIT, 0, 0, 1}, .srcOffsets = {{0, 0, 0}, {4, 4, 1}}, .dstSubresource = {VK_IMAGE_ASPECT_COLOR_BIT, 0, 0, 1}, .dstOffsets = {{0, 0, 0}, {4, 4, 1}}};
            bc_BlitImage(c2, img, VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL, plain, VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL, 1, &b2, VK_FILTER_NEAREST);
            VkBufferImageCopy d2 = {.imageSubresource = {VK_IMAGE_ASPECT_COLOR_BIT, 0, 0, 1}, .imageExtent = {4, 4, 1}};
            vkCmdCopyImageToBuffer(c2, plain, VK_IMAGE_LAYOUT_GENERAL, dst, 1, &d2);
        }
        OK(vkEndCommandBuffer(c2));
        VkSubmitInfo s2 = {.sType = VK_STRUCTURE_TYPE_SUBMIT_INFO, .commandBufferCount = 1, .pCommandBuffers = &c2};
        OK(vkQueueSubmit(queue, 1, &s2, VK_NULL_HANDLE)); OK(vkQueueWaitIdle(queue));
        int kb = 0;
        for (int i = 0; nobc && i < 16; i++) if (memcmp(px + i * 4, k->want, 4)) { if (!kb++) fprintf(stderr, "[graphics-session] %s 像素 %d = %u %u %u %u，期望 %u %u %u %u\n", k->name, i, px[i * 4], px[i * 4 + 1], px[i * 4 + 2], px[i * 4 + 3], k->want[0], k->want[1], k->want[2], k->want[3]); }
        if (kb) fbad++;
    }
    bad += fbad;
    assert(s2a_graphics_native_request_stop() == 0);
    assert(s2a_graphics_native_shutdown_session() == 0);
    if (nobc) fprintf(stderr, "[graphics-session] Vulkan BC 各格式上传（DM_TEST_NO_BC）%s：%d 种格式各读回 16 个像素，不符的格式 %d 种\n", fbad ? "红" : "通过", nfmt, fbad);
    else fprintf(stderr, "[graphics-session] Vulkan BC 各格式上传（原生 BC）通过：%d 种格式的上传命令执行完成（不比像素）\n", nfmt);
    if (nobc) fprintf(stderr, "[graphics-session] Vulkan BC1 上传（DM_TEST_NO_BC：解压格式 + CPU 解码）%s：读回 64 个像素，不符 %d 个\n", bad ? "红" : "通过", bad);
    else fprintf(stderr, "[graphics-session] Vulkan BC1 上传（原生 BC）通过：上传命令执行完成（压缩图读不回像素，不比）\n");
    return bad ? 1 : 0;
}
