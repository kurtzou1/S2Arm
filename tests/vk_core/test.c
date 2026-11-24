// Vulkan 层核心命令补齐（#271 维护方批量）的真 GPU 回归：只经公开 Vulkan 入口（dm_vk_lookup → vkGetInstanceProcAddr），读回按规范手算的值逐字节核对。
// 链直连层 libnvn.a + 宿主替身（graphics/nvn/tests/host_stubs.h），不起宿主。着色器：同目录 GLSL → glslangValidator → 出包工具 vk_shaders.py（Makefile 做）。
// 用法：make -f tests/vk_core/Makefile vk-core-test（末行 ✓ / ✗）
#define VK_NO_PROTOTYPES
#include <dirent.h>
#include <spawn.h>
#include <sys/wait.h>
#include <sys/mman.h>
#include <unistd.h>
#include <vulkan/vulkan_core.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

extern void *dm_vk_lookup(const char *);
extern void dm_vk_indirect_stats(uint64_t *encoders, uint64_t *buffers, uint64_t *bytes);
static int fails, checks;
#define CHECK(c, ...) do { checks++; if (c) printf("  过 " __VA_ARGS__); else { printf("  败 " __VA_ARGS__); fails++; } printf("\n"); } while (0)
#define REQUIRE(x) do { if (!(x)) { printf("✗ t_vk_core：前提不成立 %s:%d: %s\n", __FILE__, __LINE__, #x); exit(1); } } while (0)
#define OK(x) REQUIRE((x) == VK_SUCCESS)
#define APIS(X) \
 X(vkCreateInstance) X(vkEnumeratePhysicalDevices) X(vkCreateDevice) X(vkGetDeviceQueue) X(vkGetDeviceProcAddr) \
 X(vkGetPhysicalDeviceFormatProperties) X(vkGetPhysicalDeviceFormatProperties2) X(vkGetPhysicalDeviceQueueFamilyProperties2) X(vkGetPhysicalDeviceImageFormatProperties2) \
 X(vkGetPhysicalDeviceSparseImageFormatProperties) X(vkGetPhysicalDeviceExternalBufferProperties) X(vkGetDescriptorSetLayoutSupport) X(vkGetDeviceQueue2) \
 X(vkTrimCommandPool) X(vkGetRenderAreaGranularity) \
 X(vkCreateBuffer) X(vkGetBufferMemoryRequirements) X(vkAllocateMemory) X(vkBindBufferMemory) X(vkMapMemory) \
 X(vkCreateImage) X(vkGetImageMemoryRequirements) X(vkBindImageMemory) X(vkCreateImageView) X(vkCreateSampler) X(vkCreateBufferView) \
 X(vkCreateRenderPass) X(vkCreateFramebuffer) X(vkCreateShaderModule) X(vkDestroyShaderModule) X(vkCreatePipelineLayout) X(vkCreateGraphicsPipelines) X(vkCreateComputePipelines) \
 X(vkCreateDescriptorSetLayout) X(vkCreateDescriptorPool) X(vkAllocateDescriptorSets) X(vkUpdateDescriptorSets) \
 X(vkCreateCommandPool) X(vkAllocateCommandBuffers) X(vkBeginCommandBuffer) X(vkEndCommandBuffer) X(vkQueueSubmit) X(vkQueueWaitIdle) \
 X(vkCmdBeginRenderPass) X(vkCmdEndRenderPass) X(vkCmdNextSubpass) X(vkCmdBindPipeline) X(vkCmdBindDescriptorSets) X(vkCmdPushConstants) X(vkCmdSetViewport) X(vkCmdSetScissor) \
 X(vkCmdDraw) X(vkCmdBindVertexBuffers) X(vkCmdCopyBuffer) X(vkCmdCopyBufferToImage) X(vkCmdCopyImage) X(vkCmdCopyImageToBuffer) X(vkCmdPipelineBarrier) X(vkCmdExecuteCommands) \
 X(vkCmdFillBuffer) X(vkCmdUpdateBuffer) X(vkCmdClearColorImage) X(vkCmdClearDepthStencilImage) X(vkCmdClearAttachments) X(vkCmdBlitImage) X(vkCmdResolveImage) \
 X(vkCreateEvent) X(vkGetEventStatus) X(vkSetEvent) X(vkResetEvent) X(vkCmdSetEvent) X(vkCmdResetEvent) X(vkCmdWaitEvents) \
 X(vkCreateQueryPool) X(vkCmdResetQueryPool) X(vkCmdBeginQuery) X(vkCmdEndQuery) X(vkCmdCopyQueryPoolResults) X(vkGetQueryPoolResults) \
 X(vkCmdDispatch) X(vkCmdDispatchIndirect) X(vkCmdSetStencilWriteMask) X(vkCmdSetStencilReference) X(vkCreateSwapchainKHR) X(vkQueuePresentKHR)
#define DECL(n) static PFN_##n n;
APIS(DECL)
static PFN_vkGetInstanceProcAddr gipa;
static VkInstance instance; static VkPhysicalDevice physical; static VkDevice device; static VkQueue queue; static VkCommandPool pool;
enum { W = 32, H = 32 };

typedef struct { VkBuffer b; VkDeviceMemory m; uint8_t *p; } Buf;
static Buf buf(VkDeviceSize size, VkBufferUsageFlags usage) {
    Buf r = {0}; VkBufferCreateInfo bi = {.sType = VK_STRUCTURE_TYPE_BUFFER_CREATE_INFO, .size = size, .usage = usage};
    OK(vkCreateBuffer(device, &bi, NULL, &r.b)); VkMemoryRequirements q; vkGetBufferMemoryRequirements(device, r.b, &q);
    VkMemoryAllocateInfo ai = {.sType = VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO, .allocationSize = q.size, .memoryTypeIndex = 1};
    OK(vkAllocateMemory(device, &ai, NULL, &r.m)); OK(vkBindBufferMemory(device, r.b, r.m, 0));
    void *p; OK(vkMapMemory(device, r.m, 0, size, 0, &p)); r.p = p; memset(r.p, 0xcd, size); return r;
}
static VkImage img(VkFormat f, uint32_t w, uint32_t h, uint32_t layers, VkSampleCountFlagBits samples, VkImageUsageFlags usage) {
    VkImageCreateInfo ci = {.sType = VK_STRUCTURE_TYPE_IMAGE_CREATE_INFO, .imageType = VK_IMAGE_TYPE_2D, .format = f, .extent = {w, h, 1}, .mipLevels = 1, .arrayLayers = layers,
        .samples = samples, .tiling = VK_IMAGE_TILING_OPTIMAL, .usage = usage};
    VkImage r; OK(vkCreateImage(device, &ci, NULL, &r)); VkMemoryRequirements q; vkGetImageMemoryRequirements(device, r, &q);
    VkMemoryAllocateInfo ai = {.sType = VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO, .allocationSize = q.size, .memoryTypeIndex = 0};
    VkDeviceMemory m; OK(vkAllocateMemory(device, &ai, NULL, &m)); OK(vkBindImageMemory(device, r, m, 0)); return r;
}
static VkImageView view(VkImage i, VkFormat f, VkImageAspectFlags aspect) {
    VkImageViewCreateInfo vi = {.sType = VK_STRUCTURE_TYPE_IMAGE_VIEW_CREATE_INFO, .image = i, .viewType = VK_IMAGE_VIEW_TYPE_2D, .format = f, .subresourceRange = {aspect, 0, 1, 0, 1}};
    VkImageView v; OK(vkCreateImageView(device, &vi, NULL, &v)); return v;
}
static VkShaderModule shader(const char *name) {
    char path[1024]; REQUIRE(getenv("T_VK_SPV")); snprintf(path, sizeof path, "%s/%s.spv", getenv("T_VK_SPV"), name);
    FILE *f = fopen(path, "rb");
    if (!f && getenv("T_VK_SPV_RT")) { snprintf(path, sizeof path, "%s/%s.spv", getenv("T_VK_SPV_RT"), name); f = fopen(path, "rb"); }   // 不进离线库的（设备现编回归）
    REQUIRE(f); fseek(f, 0, SEEK_END); long n = ftell(f); rewind(f);
    uint32_t *w = malloc((size_t)n); REQUIRE(w && fread(w, 1, (size_t)n, f) == (size_t)n); fclose(f);
    VkShaderModuleCreateInfo ci = {.sType = VK_STRUCTURE_TYPE_SHADER_MODULE_CREATE_INFO, .codeSize = (size_t)n, .pCode = w};
    VkShaderModule m; OK(vkCreateShaderModule(device, &ci, NULL, &m)); free(w); return m;
}
static VkCommandBuffer begin(VkCommandBufferLevel level) {
    VkCommandBufferAllocateInfo ai = {.sType = VK_STRUCTURE_TYPE_COMMAND_BUFFER_ALLOCATE_INFO, .commandPool = pool, .level = level, .commandBufferCount = 1};
    VkCommandBuffer c; OK(vkAllocateCommandBuffers(device, &ai, &c));
    if (level == VK_COMMAND_BUFFER_LEVEL_PRIMARY) { VkCommandBufferBeginInfo bi = {.sType = VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO}; OK(vkBeginCommandBuffer(c, &bi)); }
    return c;
}
static void submit(VkCommandBuffer c) {
    OK(vkEndCommandBuffer(c)); VkSubmitInfo si = {.sType = VK_STRUCTURE_TYPE_SUBMIT_INFO, .commandBufferCount = 1, .pCommandBuffers = &c};
    OK(vkQueueSubmit(queue, 1, &si, VK_NULL_HANDLE)); OK(vkQueueWaitIdle(queue));
}
static void to_buffer(VkCommandBuffer c, VkImage i, VkImageAspectFlags aspect, uint32_t layer, uint32_t w, uint32_t h, VkBuffer b) {
    VkBufferImageCopy r = {.imageSubresource = {aspect, 0, layer, 1}, .imageExtent = {w, h, 1}}; vkCmdCopyImageToBuffer(c, i, VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL, b, 1, &r);
}
static uint32_t px(const Buf *b, uint32_t w, uint32_t x, uint32_t y) { uint32_t v; memcpy(&v, b->p + ((size_t)y * w + x) * 4, 4); return v; }
static uint64_t passes(void) { uint64_t e, b, n; dm_vk_indirect_stats(&e, &b, &n); return e; }   // 实际建出的 Metal 渲染编码器（切遍再恢复也算一个）
#define RGBA(r, g, b, a) ((uint32_t)(r) | (uint32_t)(g) << 8 | (uint32_t)(b) << 16 | (uint32_t)(a) << 24)

// 单附件渲染遍与「推常量颜色」管线
static VkRenderPass color_pass(VkFormat f, VkAttachmentLoadOp load, VkSampleCountFlagBits samples) {
    VkAttachmentDescription a = {.format = f, .samples = samples, .loadOp = load, .storeOp = VK_ATTACHMENT_STORE_OP_STORE, .stencilLoadOp = VK_ATTACHMENT_LOAD_OP_DONT_CARE,
        .stencilStoreOp = VK_ATTACHMENT_STORE_OP_DONT_CARE, .finalLayout = VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL};
    VkAttachmentReference r = {0, VK_IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL};
    VkSubpassDescription s = {.pipelineBindPoint = VK_PIPELINE_BIND_POINT_GRAPHICS, .colorAttachmentCount = 1, .pColorAttachments = &r};
    VkRenderPassCreateInfo ci = {.sType = VK_STRUCTURE_TYPE_RENDER_PASS_CREATE_INFO, .attachmentCount = 1, .pAttachments = &a, .subpassCount = 1, .pSubpasses = &s};
    VkRenderPass p; OK(vkCreateRenderPass(device, &ci, NULL, &p)); return p;
}
static VkFramebuffer framebuffer(VkRenderPass p, uint32_t n, const VkImageView *v, uint32_t w, uint32_t h) {
    VkFramebufferCreateInfo ci = {.sType = VK_STRUCTURE_TYPE_FRAMEBUFFER_CREATE_INFO, .renderPass = p, .attachmentCount = n, .pAttachments = v, .width = w, .height = h, .layers = 1};
    VkFramebuffer f; OK(vkCreateFramebuffer(device, &ci, NULL, &f)); return f;
}
static VkPipelineLayout layout_of(uint32_t nset, const VkDescriptorSetLayout *sets, uint32_t pc, VkShaderStageFlags pcst) {
    VkPushConstantRange r = {pcst, 0, pc};
    VkPipelineLayoutCreateInfo ci = {.sType = VK_STRUCTURE_TYPE_PIPELINE_LAYOUT_CREATE_INFO, .setLayoutCount = nset, .pSetLayouts = sets, .pushConstantRangeCount = pc ? 1 : 0, .pPushConstantRanges = &r};
    VkPipelineLayout l; OK(vkCreatePipelineLayout(device, &ci, NULL, &l)); return l;
}
static VkResult gfx_pipe_m(VkRenderPass p, uint32_t sub, VkPipelineLayout l, VkShaderModule vert, VkShaderModule frag, VkSampleCountFlagBits samples,
                           const VkPipelineDepthStencilStateCreateInfo *ds, uint32_t ndyn, const VkDynamicState *dyn, VkPipeline *r) {   // 给定模块、回原样结果码（㉑ 要看结果码）
    VkPipelineShaderStageCreateInfo st[] = {{.sType = VK_STRUCTURE_TYPE_PIPELINE_SHADER_STAGE_CREATE_INFO, .stage = VK_SHADER_STAGE_VERTEX_BIT, .module = vert, .pName = "main"},
                                            {.sType = VK_STRUCTURE_TYPE_PIPELINE_SHADER_STAGE_CREATE_INFO, .stage = VK_SHADER_STAGE_FRAGMENT_BIT, .module = frag, .pName = "main"}};
    VkPipelineVertexInputStateCreateInfo vi = {.sType = VK_STRUCTURE_TYPE_PIPELINE_VERTEX_INPUT_STATE_CREATE_INFO};
    VkPipelineInputAssemblyStateCreateInfo ia = {.sType = VK_STRUCTURE_TYPE_PIPELINE_INPUT_ASSEMBLY_STATE_CREATE_INFO, .topology = VK_PRIMITIVE_TOPOLOGY_TRIANGLE_LIST};
    VkViewport vp = {0, 0, W, H, 0, 1}; VkRect2D sc = {{0, 0}, {W, H}};
    VkPipelineViewportStateCreateInfo vs = {.sType = VK_STRUCTURE_TYPE_PIPELINE_VIEWPORT_STATE_CREATE_INFO, .viewportCount = 1, .pViewports = &vp, .scissorCount = 1, .pScissors = &sc};
    VkPipelineRasterizationStateCreateInfo rs = {.sType = VK_STRUCTURE_TYPE_PIPELINE_RASTERIZATION_STATE_CREATE_INFO, .cullMode = VK_CULL_MODE_NONE, .lineWidth = 1};
    VkPipelineMultisampleStateCreateInfo ms = {.sType = VK_STRUCTURE_TYPE_PIPELINE_MULTISAMPLE_STATE_CREATE_INFO, .rasterizationSamples = samples};
    VkPipelineColorBlendAttachmentState ba = {.colorWriteMask = 15};
    VkPipelineColorBlendStateCreateInfo cb = {.sType = VK_STRUCTURE_TYPE_PIPELINE_COLOR_BLEND_STATE_CREATE_INFO, .attachmentCount = 1, .pAttachments = &ba};
    VkPipelineDynamicStateCreateInfo dy = {.sType = VK_STRUCTURE_TYPE_PIPELINE_DYNAMIC_STATE_CREATE_INFO, .dynamicStateCount = ndyn, .pDynamicStates = dyn};
    VkGraphicsPipelineCreateInfo ci = {.sType = VK_STRUCTURE_TYPE_GRAPHICS_PIPELINE_CREATE_INFO, .stageCount = 2, .pStages = st, .pVertexInputState = &vi, .pInputAssemblyState = &ia,
        .pViewportState = &vs, .pRasterizationState = &rs, .pMultisampleState = &ms, .pDepthStencilState = ds, .pColorBlendState = &cb, .pDynamicState = ndyn ? &dy : NULL,
        .layout = l, .renderPass = p, .subpass = sub};
    return vkCreateGraphicsPipelines(device, VK_NULL_HANDLE, 1, &ci, NULL, r);
}
static VkPipeline gfx_pipe(VkRenderPass p, uint32_t sub, VkPipelineLayout l, const char *frag, VkSampleCountFlagBits samples, const VkPipelineDepthStencilStateCreateInfo *ds,
                           uint32_t ndyn, const VkDynamicState *dyn) {
    VkPipeline r; OK(gfx_pipe_m(p, sub, l, shader("tri.vert"), shader(frag), samples, ds, ndyn, dyn, &r)); return r;
}
static void begin_pass(VkCommandBuffer c, VkRenderPass p, VkFramebuffer f, uint32_t nclear, const VkClearValue *cv, VkSubpassContents contents) {
    VkRenderPassBeginInfo bi = {.sType = VK_STRUCTURE_TYPE_RENDER_PASS_BEGIN_INFO, .renderPass = p, .framebuffer = f, .renderArea = {{0, 0}, {W, H}}, .clearValueCount = nclear, .pClearValues = cv};
    vkCmdBeginRenderPass(c, &bi, contents);
}

static void setup(void) {
    gipa = (PFN_vkGetInstanceProcAddr)dm_vk_lookup("vkGetInstanceProcAddr"); REQUIRE(gipa);
    vkCreateInstance = (PFN_vkCreateInstance)gipa(NULL, "vkCreateInstance");
    VkApplicationInfo app = {.sType = VK_STRUCTURE_TYPE_APPLICATION_INFO, .apiVersion = VK_API_VERSION_1_1};
    VkInstanceCreateInfo ici = {.sType = VK_STRUCTURE_TYPE_INSTANCE_CREATE_INFO, .pApplicationInfo = &app}; OK(vkCreateInstance(&ici, NULL, &instance));
#define LOAD(n) n = (PFN_##n)gipa(instance, #n); if (!n) { printf("✗ t_vk_core：取不到 %s\n", #n); exit(1); }
    APIS(LOAD)
#undef LOAD
    uint32_t n = 1; OK(vkEnumeratePhysicalDevices(instance, &n, &physical));
    float pr = 1; VkDeviceQueueCreateInfo qi = {.sType = VK_STRUCTURE_TYPE_DEVICE_QUEUE_CREATE_INFO, .queueCount = 1, .pQueuePriorities = &pr};
    VkDeviceCreateInfo di = {.sType = VK_STRUCTURE_TYPE_DEVICE_CREATE_INFO, .queueCreateInfoCount = 1, .pQueueCreateInfos = &qi}; OK(vkCreateDevice(physical, &di, NULL, &device));
    vkGetDeviceQueue(device, 0, 0, &queue);
    VkCommandPoolCreateInfo pci = {.sType = VK_STRUCTURE_TYPE_COMMAND_POOL_CREATE_INFO}; OK(vkCreateCommandPool(device, &pci, NULL, &pool));
}

// ① 查询类入口：*2 与 1.0 结果一致、KHR 别名查得到、不支持的如实回 0
static void t_queries(void) {
    VkFormatProperties a; VkFormatProperties2 b = {.sType = VK_STRUCTURE_TYPE_FORMAT_PROPERTIES_2};
    vkGetPhysicalDeviceFormatProperties(physical, VK_FORMAT_R8G8B8A8_UNORM, &a); vkGetPhysicalDeviceFormatProperties2(physical, VK_FORMAT_R8G8B8A8_UNORM, &b);
    CHECK(!memcmp(&a, &b.formatProperties, sizeof a) && a.optimalTilingFeatures, "① FormatProperties2 与 1.0 一致（optimal %#x）", a.optimalTilingFeatures);
    CHECK(gipa(instance, "vkGetPhysicalDeviceFormatProperties2KHR") == (PFN_vkVoidFunction)vkGetPhysicalDeviceFormatProperties2 && gipa(instance, "vkTrimCommandPoolKHR") == (PFN_vkVoidFunction)vkTrimCommandPool,
          "① 已宣告扩展的 KHR 名字查得到（get_physical_device_properties2、maintenance1）");
    {   // ① ASTC 全部 14 种块大小 × UNORM / SRGB（VkFormat 157–184）：都报可采样、都能建 2D 图像（D-2R7S：10x5 原先没映射，建图像回 FORMAT_NOT_SUPPORTED）
        int nosamp = 0, nocreate = 0; VkFormat first_bad = VK_FORMAT_UNDEFINED;
        for (int f = VK_FORMAT_ASTC_4x4_UNORM_BLOCK; f <= VK_FORMAT_ASTC_12x12_SRGB_BLOCK; f++) {
            VkFormatProperties fp; vkGetPhysicalDeviceFormatProperties(physical, (VkFormat)f, &fp);
            if (!(fp.optimalTilingFeatures & VK_FORMAT_FEATURE_SAMPLED_IMAGE_BIT)) { nosamp++; if (!first_bad) first_bad = (VkFormat)f; }
            VkImageCreateInfo ci = {.sType = VK_STRUCTURE_TYPE_IMAGE_CREATE_INFO, .imageType = VK_IMAGE_TYPE_2D, .format = (VkFormat)f, .extent = {60, 60, 1}, .mipLevels = 1, .arrayLayers = 1,
                                    .samples = VK_SAMPLE_COUNT_1_BIT, .tiling = VK_IMAGE_TILING_OPTIMAL, .usage = VK_IMAGE_USAGE_SAMPLED_BIT | VK_IMAGE_USAGE_TRANSFER_DST_BIT};
            VkImage im = VK_NULL_HANDLE; VkResult r = vkCreateImage(device, &ci, NULL, &im);
            if (r != VK_SUCCESS || !im) { nocreate++; if (!first_bad) first_bad = (VkFormat)f; }   // 测试进程结束即回收，不逐个销毁
        }
        CHECK(!nosamp && !nocreate, "① ASTC 28 种格式：不可采样 %d 种、建图像失败 %d 种（应 0、0；第一个不行的 VkFormat %d）", nosamp, nocreate, first_bad);
    }
    uint32_t n = 0; vkGetPhysicalDeviceQueueFamilyProperties2(physical, &n, NULL); VkQueueFamilyProperties2 q = {.sType = VK_STRUCTURE_TYPE_QUEUE_FAMILY_PROPERTIES_2}; uint32_t one = 1;
    vkGetPhysicalDeviceQueueFamilyProperties2(physical, &one, &q);
    CHECK(n == 1 && one == 1 && (q.queueFamilyProperties.queueFlags & VK_QUEUE_COMPUTE_BIT), "① 队列族 1 个、含计算（flags %#x）", q.queueFamilyProperties.queueFlags);
    VkPhysicalDeviceImageFormatInfo2 ii = {.sType = VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_IMAGE_FORMAT_INFO_2, .format = VK_FORMAT_R8G8B8A8_UNORM, .type = VK_IMAGE_TYPE_2D, .tiling = VK_IMAGE_TILING_OPTIMAL, .usage = VK_IMAGE_USAGE_SAMPLED_BIT};
    VkImageFormatProperties2 ip = {.sType = VK_STRUCTURE_TYPE_IMAGE_FORMAT_PROPERTIES_2};
    CHECK(vkGetPhysicalDeviceImageFormatProperties2(physical, &ii, &ip) == VK_SUCCESS && ip.imageFormatProperties.maxExtent.width == 16384, "① ImageFormatProperties2 成功、最大宽 16384");
    uint32_t sp = 7; vkGetPhysicalDeviceSparseImageFormatProperties(physical, VK_FORMAT_R8G8B8A8_UNORM, VK_IMAGE_TYPE_2D, VK_SAMPLE_COUNT_1_BIT, VK_IMAGE_USAGE_SAMPLED_BIT, VK_IMAGE_TILING_OPTIMAL, &sp, NULL);
    VkPhysicalDeviceExternalBufferInfo ebi = {.sType = VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_EXTERNAL_BUFFER_INFO, .usage = VK_BUFFER_USAGE_TRANSFER_SRC_BIT, .handleType = VK_EXTERNAL_MEMORY_HANDLE_TYPE_OPAQUE_FD_BIT};
    VkExternalBufferProperties ebp = {.sType = VK_STRUCTURE_TYPE_EXTERNAL_BUFFER_PROPERTIES}; memset(&ebp.externalMemoryProperties, 0xff, sizeof ebp.externalMemoryProperties);
    vkGetPhysicalDeviceExternalBufferProperties(physical, &ebi, &ebp);
    CHECK(sp == 0 && !ebp.externalMemoryProperties.externalMemoryFeatures, "① 稀疏图像格式 0 个、外部内存无特性（不支持的如实回 0）");
    VkDescriptorSetLayoutBinding lb = {200, VK_DESCRIPTOR_TYPE_UNIFORM_BUFFER, 1, VK_SHADER_STAGE_ALL}, lb2 = {3, VK_DESCRIPTOR_TYPE_UNIFORM_BUFFER, 1, VK_SHADER_STAGE_ALL};
    VkDescriptorSetLayoutCreateInfo lci = {.sType = VK_STRUCTURE_TYPE_DESCRIPTOR_SET_LAYOUT_CREATE_INFO, .bindingCount = 1, .pBindings = &lb};
    VkDescriptorSetLayoutSupport s1 = {.sType = VK_STRUCTURE_TYPE_DESCRIPTOR_SET_LAYOUT_SUPPORT}, s2 = s1;
    vkGetDescriptorSetLayoutSupport(device, &lci, &s1); lci.pBindings = &lb2; vkGetDescriptorSetLayoutSupport(device, &lci, &s2);
    CHECK(!s1.supported && s2.supported, "① 描述符集布局支持：绑定号 200 不支持、3 支持");
    VkDeviceQueueInfo2 qi2 = {.sType = VK_STRUCTURE_TYPE_DEVICE_QUEUE_INFO_2}; VkQueue q2; vkGetDeviceQueue2(device, &qi2, &q2);
    VkExtent2D g; vkGetRenderAreaGranularity(device, VK_NULL_HANDLE, &g);
    CHECK(q2 == queue && g.width == 1 && g.height == 1, "① GetDeviceQueue2 同一队列、渲染区粒度 1×1");
}
// ② 填 / 更新缓冲：字节全同的值走拷贝编码器、不同的走计算内核；更新的数据在录制时拷走
static void t_fill_update(void) {
    Buf b = buf(256, VK_BUFFER_USAGE_TRANSFER_DST_BIT);
    VkCommandBuffer c = begin(VK_COMMAND_BUFFER_LEVEL_PRIMARY);
    uint8_t data[20]; for (int i = 0; i < 20; i++) data[i] = (uint8_t)(100 + i);
    vkCmdFillBuffer(c, b.b, 0, 64, 0x07070707u); vkCmdFillBuffer(c, b.b, 64, 64, 0x01020304u); vkCmdUpdateBuffer(c, b.b, 128, 20, data);
    memset(data, 0, sizeof data);   // 录制后改调用方缓冲不影响
    vkCmdFillBuffer(c, b.b, 192, VK_WHOLE_SIZE, 0xa0b0c0d0u);
    submit(c);
    int ok1 = 1, ok2 = 1, ok3 = 1, ok4 = 1;
    for (int i = 0; i < 64; i++) ok1 &= b.p[i] == 7;
    for (int i = 0; i < 16; i++) { uint32_t v; memcpy(&v, b.p + 64 + i * 4, 4); ok2 &= v == 0x01020304u; }
    for (int i = 0; i < 20; i++) ok3 &= b.p[128 + i] == 100 + i;
    for (int i = 0; i < 16; i++) { uint32_t v; memcpy(&v, b.p + 192 + i * 4, 4); ok4 &= v == 0xa0b0c0d0u; }
    CHECK(ok1 && ok2, "② FillBuffer：字节全同 0x07 / 逐字不同 0x01020304 都写对");
    CHECK(ok3 && b.p[148] == 0xcd, "② UpdateBuffer：20 字节为录制时的数据、后邻字节不变（实测 [0]=%u [148]=%#x）", b.p[128], b.p[148]);
    CHECK(ok4, "② FillBuffer VK_WHOLE_SIZE 到缓冲末尾");
}
// ③ 清图像：颜色只清第 2 层；深度模板只清深度时模板保留
static void t_clear_image(void) {
    VkImage i = img(VK_FORMAT_R8G8B8A8_UNORM, 8, 8, 2, VK_SAMPLE_COUNT_1_BIT, VK_IMAGE_USAGE_TRANSFER_DST_BIT | VK_IMAGE_USAGE_TRANSFER_SRC_BIT);
    Buf l0 = buf(8 * 8 * 4, VK_BUFFER_USAGE_TRANSFER_DST_BIT), l1 = buf(8 * 8 * 4, VK_BUFFER_USAGE_TRANSFER_DST_BIT);
    VkCommandBuffer c = begin(VK_COMMAND_BUFFER_LEVEL_PRIMARY);
    VkClearColorValue red = {.float32 = {1, 0, 0, 1}}, blue = {.float32 = {0, 0, 1, 1}};
    VkImageSubresourceRange all = {VK_IMAGE_ASPECT_COLOR_BIT, 0, 1, 0, 2}, second = {VK_IMAGE_ASPECT_COLOR_BIT, 0, 1, 1, 1};
    vkCmdClearColorImage(c, i, VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL, &red, 1, &all); vkCmdClearColorImage(c, i, VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL, &blue, 1, &second);
    to_buffer(c, i, VK_IMAGE_ASPECT_COLOR_BIT, 0, 8, 8, l0.b); to_buffer(c, i, VK_IMAGE_ASPECT_COLOR_BIT, 1, 8, 8, l1.b);
    submit(c);
    CHECK(px(&l0, 8, 3, 3) == RGBA(255, 0, 0, 255) && px(&l1, 8, 3, 3) == RGBA(0, 0, 255, 255), "③ ClearColorImage：第 1 层红、第 2 层蓝（实测 %#x / %#x）", px(&l0, 8, 3, 3), px(&l1, 8, 3, 3));
    {   // ③b 4 位四通道（诊断#3156b9：B4G4R4A4 原先建不出、游戏拿空图像取内存需求崩）。读回原样 16 位字，期望按 Vulkan 位排布手写：
        //   R4G4B4A4 = R 在 12–15 位、A 在 0–3 位：清 (1,0,0,0) → 0xF000；B4G4R4A4 = B 在 12–15、R 在 4–7：清 (1,0,0,0) → 0x00F0；两者清 (0,0,0,1) → 0x000F
        VkFormat f4[2] = {VK_FORMAT_R4G4B4A4_UNORM_PACK16, VK_FORMAT_B4G4R4A4_UNORM_PACK16}; uint16_t wr[2] = {0xF000, 0x00F0}; uint16_t got[2][2] = {{0}};
        for (int k = 0; k < 2; k++) {
            VkImage q = img(f4[k], 8, 8, 1, VK_SAMPLE_COUNT_1_BIT, VK_IMAGE_USAGE_TRANSFER_DST_BIT | VK_IMAGE_USAGE_TRANSFER_SRC_BIT);
            CHECK(q != VK_NULL_HANDLE, "③b 格式 %d 建得出图像", f4[k]);
            if (!q) continue;
            VkMemoryRequirements mr; vkGetImageMemoryRequirements(device, q, &mr); CHECK(mr.size >= 8 * 8 * 2, "③b 格式 %d 内存需求 %llu ≥ 128", f4[k], (unsigned long long)mr.size);
            VkClearColorValue rr = {.float32 = {1, 0, 0, 0}}, aa = {.float32 = {0, 0, 0, 1}};
            VkImageSubresourceRange one = {VK_IMAGE_ASPECT_COLOR_BIT, 0, 1, 0, 1};
            for (int t = 0; t < 2; t++) {
                Buf o = buf(8 * 8 * 2, VK_BUFFER_USAGE_TRANSFER_DST_BIT); VkCommandBuffer cq = begin(VK_COMMAND_BUFFER_LEVEL_PRIMARY);
                vkCmdClearColorImage(cq, q, VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL, t ? &aa : &rr, 1, &one); to_buffer(cq, q, VK_IMAGE_ASPECT_COLOR_BIT, 0, 8, 8, o.b); submit(cq);
                memcpy(&got[k][t], o.p + (3 * 8 + 3) * 2, 2);
            }
            CHECK(got[k][0] == wr[k] && got[k][1] == 0x000F, "③b 格式 %d 清红读回 %#06x（期望 %#06x）、清 A 读回 %#06x（期望 0x000f）", f4[k], got[k][0], wr[k], got[k][1]);
        }
    }
    VkImage ds = img(VK_FORMAT_D32_SFLOAT_S8_UINT, 8, 8, 1, VK_SAMPLE_COUNT_1_BIT, VK_IMAGE_USAGE_TRANSFER_DST_BIT | VK_IMAGE_USAGE_TRANSFER_SRC_BIT | VK_IMAGE_USAGE_DEPTH_STENCIL_ATTACHMENT_BIT);
    Buf d = buf(8 * 8 * 4, VK_BUFFER_USAGE_TRANSFER_DST_BIT), st = buf(8 * 8, VK_BUFFER_USAGE_TRANSFER_DST_BIT);
    c = begin(VK_COMMAND_BUFFER_LEVEL_PRIMARY);
    VkClearDepthStencilValue v1 = {0.75f, 9}, v2 = {0.25f, 200};
    VkImageSubresourceRange both = {VK_IMAGE_ASPECT_DEPTH_BIT | VK_IMAGE_ASPECT_STENCIL_BIT, 0, 1, 0, 1}, depth = {VK_IMAGE_ASPECT_DEPTH_BIT, 0, 1, 0, 1};
    vkCmdClearDepthStencilImage(c, ds, VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL, &v1, 1, &both); vkCmdClearDepthStencilImage(c, ds, VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL, &v2, 1, &depth);
    VkBufferImageCopy rd = {.imageSubresource = {VK_IMAGE_ASPECT_DEPTH_BIT, 0, 0, 1}, .imageExtent = {8, 8, 1}}, rs = {.imageSubresource = {VK_IMAGE_ASPECT_STENCIL_BIT, 0, 0, 1}, .imageExtent = {8, 8, 1}};
    vkCmdCopyImageToBuffer(c, ds, VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL, d.b, 1, &rd); vkCmdCopyImageToBuffer(c, ds, VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL, st.b, 1, &rs);
    submit(c);
    float z; memcpy(&z, d.p + (5 * 8 + 5) * 4, 4);
    CHECK(z == 0.25f && st.p[5 * 8 + 5] == 9, "③ ClearDepthStencilImage：只清深度 → 深度 0.25、模板保留 9（实测 %g / %u）", z, st.p[5 * 8 + 5]);
}
// ④ 渲染遍里清附件：只清矩形、只多画不多切遍；之后的绘制照常
static void t_clear_attachments(void) {
    VkImage i = img(VK_FORMAT_R8G8B8A8_UNORM, W, H, 1, VK_SAMPLE_COUNT_1_BIT, VK_IMAGE_USAGE_COLOR_ATTACHMENT_BIT | VK_IMAGE_USAGE_TRANSFER_SRC_BIT);
    VkImageView v = view(i, VK_FORMAT_R8G8B8A8_UNORM, VK_IMAGE_ASPECT_COLOR_BIT);
    VkRenderPass p = color_pass(VK_FORMAT_R8G8B8A8_UNORM, VK_ATTACHMENT_LOAD_OP_CLEAR, VK_SAMPLE_COUNT_1_BIT); VkFramebuffer f = framebuffer(p, 1, &v, W, H);
    VkPipelineLayout l = layout_of(0, NULL, 16, VK_SHADER_STAGE_FRAGMENT_BIT); VkPipeline pipe = gfx_pipe(p, 0, l, "color.frag", VK_SAMPLE_COUNT_1_BIT, NULL, 0, NULL);
    Buf out = buf(W * H * 4, VK_BUFFER_USAGE_TRANSFER_DST_BIT);
    VkCommandBuffer c = begin(VK_COMMAND_BUFFER_LEVEL_PRIMARY);
    VkClearValue red = {.color.float32 = {1, 0, 0, 1}}; begin_pass(c, p, f, 1, &red, VK_SUBPASS_CONTENTS_INLINE);
    VkClearAttachment ca = {VK_IMAGE_ASPECT_COLOR_BIT, 0, {.color.float32 = {0, 1, 0, 1}}}; VkClearRect cr = {{{8, 8}, {8, 8}}, 0, 1};
    vkCmdClearAttachments(c, 1, &ca, 1, &cr);
    // 再画一笔全屏蓝：清附件不能留下自己的视口 / 裁剪 / 管线
    vkCmdBindPipeline(c, VK_PIPELINE_BIND_POINT_GRAPHICS, pipe); float blue[4] = {0, 0, 1, 1}; vkCmdPushConstants(c, l, VK_SHADER_STAGE_FRAGMENT_BIT, 0, 16, blue);
    vkCmdDraw(c, 3, 1, 0, 0);
    vkCmdEndRenderPass(c); to_buffer(c, i, VK_IMAGE_ASPECT_COLOR_BIT, 0, W, H, out.b);
    uint64_t p0 = passes(); submit(c); uint64_t dp = passes() - p0;
    // 画的那笔盖满整屏（管线静态视口 / 裁剪 = 全屏），期望整屏蓝；清附件本身的结果由第二个命令缓冲只清不画来验
    CHECK(px(&out, W, 2, 2) == RGBA(0, 0, 255, 255), "④ 清附件之后的绘制照常（全屏蓝，实测 %#x）", px(&out, W, 2, 2));
    c = begin(VK_COMMAND_BUFFER_LEVEL_PRIMARY); begin_pass(c, p, f, 1, &red, VK_SUBPASS_CONTENTS_INLINE); vkCmdClearAttachments(c, 1, &ca, 1, &cr); vkCmdEndRenderPass(c);
    to_buffer(c, i, VK_IMAGE_ASPECT_COLOR_BIT, 0, W, H, out.b); submit(c);
    CHECK(px(&out, W, 10, 10) == RGBA(0, 255, 0, 255) && px(&out, W, 7, 7) == RGBA(255, 0, 0, 255) && px(&out, W, 16, 16) == RGBA(255, 0, 0, 255),
          "④ ClearAttachments 只清 (8,8)–(16,16)：里绿、外红（实测 %#x / %#x / %#x）", px(&out, W, 10, 10), px(&out, W, 7, 7), px(&out, W, 16, 16));
    CHECK(dp == 1, "④ 清附件不切渲染遍：一遍里清 + 画，渲染编码器 +%llu", (unsigned long long)dp);
}
// ⑤ Blit：同尺寸同格式走拷贝；放大 2 倍 + 水平翻转走采样（最近邻）
static void t_blit(void) {
    VkImage a = img(VK_FORMAT_R8G8B8A8_UNORM, 4, 4, 1, VK_SAMPLE_COUNT_1_BIT, VK_IMAGE_USAGE_TRANSFER_DST_BIT | VK_IMAGE_USAGE_TRANSFER_SRC_BIT);
    VkImage b = img(VK_FORMAT_R8G8B8A8_UNORM, 8, 8, 1, VK_SAMPLE_COUNT_1_BIT, VK_IMAGE_USAGE_TRANSFER_DST_BIT | VK_IMAGE_USAGE_TRANSFER_SRC_BIT);
    Buf src = buf(4 * 4 * 4, VK_BUFFER_USAGE_TRANSFER_SRC_BIT), out = buf(8 * 8 * 4, VK_BUFFER_USAGE_TRANSFER_DST_BIT);
    for (uint32_t y = 0; y < 4; y++) for (uint32_t x = 0; x < 4; x++) { uint32_t v = RGBA(x * 60, y * 60, 0, 255); memcpy(src.p + (y * 4 + x) * 4, &v, 4); }
    VkCommandBuffer c = begin(VK_COMMAND_BUFFER_LEVEL_PRIMARY);
    VkBufferImageCopy up = {.imageSubresource = {VK_IMAGE_ASPECT_COLOR_BIT, 0, 0, 1}, .imageExtent = {4, 4, 1}}; vkCmdCopyBufferToImage(c, src.b, a, VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL, 1, &up);
    VkImageBlit same = {{VK_IMAGE_ASPECT_COLOR_BIT, 0, 0, 1}, {{0, 0, 0}, {4, 4, 1}}, {VK_IMAGE_ASPECT_COLOR_BIT, 0, 0, 1}, {{4, 4, 0}, {8, 8, 1}}};
    vkCmdBlitImage(c, a, VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL, b, VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL, 1, &same, VK_FILTER_NEAREST);
    // 源 (0,0)–(4,2) → 目标 (4,0)–(0,4)：x 方向翻转、x / y 各放大
    VkImageBlit scaled = {{VK_IMAGE_ASPECT_COLOR_BIT, 0, 0, 1}, {{0, 0, 0}, {4, 2, 1}}, {VK_IMAGE_ASPECT_COLOR_BIT, 0, 0, 1}, {{4, 0, 0}, {0, 4, 1}}};
    vkCmdBlitImage(c, a, VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL, b, VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL, 1, &scaled, VK_FILTER_NEAREST);
    to_buffer(c, b, VK_IMAGE_ASPECT_COLOR_BIT, 0, 8, 8, out.b); submit(c);
    CHECK(px(&out, 8, 5, 6) == RGBA(60, 120, 0, 255), "⑤ 同尺寸 Blit：目标 (5,6) = 源 (1,2)（实测 %#x）", px(&out, 8, 5, 6));
    // 目标 (0,0)：翻转后对源 x = 3.5 附近 → 源 (3,0)；目标 (3,3)：源 x = 0.5、y = 1.5 → 源 (0,1)
    CHECK(px(&out, 8, 0, 0) == RGBA(180, 0, 0, 255) && px(&out, 8, 3, 3) == RGBA(0, 60, 0, 255), "⑤ 放大 + 翻转 Blit（最近邻）：(0,0) = 源 (3,0)、(3,3) = 源 (0,1)（实测 %#x / %#x）", px(&out, 8, 0, 0), px(&out, 8, 3, 3));
}
// ⑥ 多重采样解析：4 倍采样的附件清成青色，解析到单采样图像
static void t_resolve(void) {
    VkImage m = img(VK_FORMAT_R8G8B8A8_UNORM, W, H, 1, VK_SAMPLE_COUNT_4_BIT, VK_IMAGE_USAGE_COLOR_ATTACHMENT_BIT | VK_IMAGE_USAGE_TRANSFER_SRC_BIT);
    VkImage s = img(VK_FORMAT_R8G8B8A8_UNORM, W, H, 1, VK_SAMPLE_COUNT_1_BIT, VK_IMAGE_USAGE_TRANSFER_DST_BIT | VK_IMAGE_USAGE_TRANSFER_SRC_BIT);
    VkImageView mv = view(m, VK_FORMAT_R8G8B8A8_UNORM, VK_IMAGE_ASPECT_COLOR_BIT);
    VkRenderPass p = color_pass(VK_FORMAT_R8G8B8A8_UNORM, VK_ATTACHMENT_LOAD_OP_CLEAR, VK_SAMPLE_COUNT_4_BIT); VkFramebuffer f = framebuffer(p, 1, &mv, W, H);
    Buf out = buf(W * H * 4, VK_BUFFER_USAGE_TRANSFER_DST_BIT);
    VkCommandBuffer c = begin(VK_COMMAND_BUFFER_LEVEL_PRIMARY); VkClearValue cyan = {.color.float32 = {0, 1, 1, 1}};
    begin_pass(c, p, f, 1, &cyan, VK_SUBPASS_CONTENTS_INLINE); vkCmdEndRenderPass(c);
    VkImageResolve r = {{VK_IMAGE_ASPECT_COLOR_BIT, 0, 0, 1}, {0, 0, 0}, {VK_IMAGE_ASPECT_COLOR_BIT, 0, 0, 1}, {0, 0, 0}, {W, H, 1}};
    vkCmdResolveImage(c, m, VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL, s, VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL, 1, &r);
    to_buffer(c, s, VK_IMAGE_ASPECT_COLOR_BIT, 0, W, H, out.b); submit(c);
    CHECK(px(&out, W, 9, 20) == RGBA(0, 255, 255, 255), "⑥ ResolveImage：解析结果青色（实测 %#x）", px(&out, W, 9, 20));
}
// ⑦ 事件：主机置位 / 复位；命令置位在提交完成后可见
static void t_events(void) {
    VkEventCreateInfo ci = {.sType = VK_STRUCTURE_TYPE_EVENT_CREATE_INFO}; VkEvent e, e2; OK(vkCreateEvent(device, &ci, NULL, &e)); OK(vkCreateEvent(device, &ci, NULL, &e2));
    int a = vkGetEventStatus(device, e) == VK_EVENT_RESET; vkSetEvent(device, e); int b = vkGetEventStatus(device, e) == VK_EVENT_SET; vkResetEvent(device, e); int c0 = vkGetEventStatus(device, e) == VK_EVENT_RESET;
    CHECK(a && b && c0, "⑦ 主机侧：新建为复位、Set 后置位、Reset 后复位");
    VkCommandBuffer c = begin(VK_COMMAND_BUFFER_LEVEL_PRIMARY);
    vkCmdSetEvent(c, e, VK_PIPELINE_STAGE_TRANSFER_BIT); vkCmdWaitEvents(c, 1, &e, VK_PIPELINE_STAGE_TRANSFER_BIT, VK_PIPELINE_STAGE_TRANSFER_BIT, 0, NULL, 0, NULL, 0, NULL);
    vkSetEvent(device, e2); vkCmdResetEvent(c, e2, VK_PIPELINE_STAGE_TRANSFER_BIT);
    submit(c);
    CHECK(vkGetEventStatus(device, e) == VK_EVENT_SET && vkGetEventStatus(device, e2) == VK_EVENT_RESET, "⑦ 命令侧：CmdSetEvent 置位、CmdResetEvent 复位（提交完成后）");
}
// ⑧ 复制查询结果：同一次提交里（GPU 汇总遮挡分段）与下一次提交（主机已有的值），都等于 vkGetQueryPoolResults
static void t_query_copy(void) {
    VkImage i = img(VK_FORMAT_R8G8B8A8_UNORM, W, H, 1, VK_SAMPLE_COUNT_1_BIT, VK_IMAGE_USAGE_COLOR_ATTACHMENT_BIT | VK_IMAGE_USAGE_TRANSFER_SRC_BIT);
    VkImageView v = view(i, VK_FORMAT_R8G8B8A8_UNORM, VK_IMAGE_ASPECT_COLOR_BIT);
    VkRenderPass p = color_pass(VK_FORMAT_R8G8B8A8_UNORM, VK_ATTACHMENT_LOAD_OP_CLEAR, VK_SAMPLE_COUNT_1_BIT); VkFramebuffer f = framebuffer(p, 1, &v, W, H);
    VkPipelineLayout l = layout_of(0, NULL, 16, VK_SHADER_STAGE_FRAGMENT_BIT); VkPipeline pipe = gfx_pipe(p, 0, l, "color.frag", VK_SAMPLE_COUNT_1_BIT, NULL, 0, NULL);
    VkQueryPoolCreateInfo qci = {.sType = VK_STRUCTURE_TYPE_QUERY_POOL_CREATE_INFO, .queryType = VK_QUERY_TYPE_OCCLUSION, .queryCount = 2}; VkQueryPool q;
    OK(vkCreateQueryPool(device, &qci, NULL, &q));
    Buf same = buf(64, VK_BUFFER_USAGE_TRANSFER_DST_BIT), later = buf(64, VK_BUFFER_USAGE_TRANSFER_DST_BIT);
    VkCommandBuffer c = begin(VK_COMMAND_BUFFER_LEVEL_PRIMARY);
    vkCmdResetQueryPool(c, q, 0, 2); VkClearValue k = {.color.float32 = {0, 0, 0, 1}}; begin_pass(c, p, f, 1, &k, VK_SUBPASS_CONTENTS_INLINE);
    vkCmdBindPipeline(c, VK_PIPELINE_BIND_POINT_GRAPHICS, pipe); float wht[4] = {1, 1, 1, 1}; vkCmdPushConstants(c, l, VK_SHADER_STAGE_FRAGMENT_BIT, 0, 16, wht);
    vkCmdBeginQuery(c, q, 0, VK_QUERY_CONTROL_PRECISE_BIT); vkCmdDraw(c, 3, 1, 0, 0); vkCmdEndQuery(c, q, 0);
    vkCmdEndRenderPass(c);
    vkCmdCopyQueryPoolResults(c, q, 0, 2, same.b, 0, 16, VK_QUERY_RESULT_64_BIT | VK_QUERY_RESULT_WITH_AVAILABILITY_BIT);
    submit(c);
    uint64_t got[4]; OK(vkGetQueryPoolResults(device, q, 0, 1, sizeof got, got, 16, VK_QUERY_RESULT_64_BIT | VK_QUERY_RESULT_WITH_AVAILABILITY_BIT));
    uint64_t s0[4]; memcpy(s0, same.p, 32);
    CHECK(got[0] == W * H && s0[0] == got[0] && s0[1] == 1 && s0[3] == 0, "⑧ 同次提交复制：查询 0 = %llu 个样本（期望 %u）、可用 1；查询 1 未写 → 不可用（实测 %llu / %llu / avail1 %llu）",
          (unsigned long long)got[0], W * H, (unsigned long long)s0[0], (unsigned long long)s0[1], (unsigned long long)s0[3]);
    c = begin(VK_COMMAND_BUFFER_LEVEL_PRIMARY); vkCmdCopyQueryPoolResults(c, q, 0, 1, later.b, 4, 8, VK_QUERY_RESULT_WITH_AVAILABILITY_BIT); submit(c);
    uint32_t l0[2]; memcpy(l0, later.p + 4, 8);
    CHECK(l0[0] == W * H && l0[1] == 1 && later.p[0] == 0xcd, "⑧ 下次提交复制（32 位、偏移 4）：%u、可用 %u，偏移前字节不动", l0[0], l0[1]);
}
// ⑨ 计算：派发 4 组 × 64 线程写 i*3+7；间接派发 2 组覆盖前 128 个写 i*3+100
static void t_compute(void) {
    VkDescriptorSetLayoutBinding lb = {0, VK_DESCRIPTOR_TYPE_STORAGE_BUFFER, 1, VK_SHADER_STAGE_COMPUTE_BIT};
    VkDescriptorSetLayoutCreateInfo lci = {.sType = VK_STRUCTURE_TYPE_DESCRIPTOR_SET_LAYOUT_CREATE_INFO, .bindingCount = 1, .pBindings = &lb}; VkDescriptorSetLayout sl;
    OK(vkCreateDescriptorSetLayout(device, &lci, NULL, &sl));
    VkPipelineLayout l = layout_of(1, &sl, 4, VK_SHADER_STAGE_COMPUTE_BIT);
    VkComputePipelineCreateInfo ci = {.sType = VK_STRUCTURE_TYPE_COMPUTE_PIPELINE_CREATE_INFO, .stage = {.sType = VK_STRUCTURE_TYPE_PIPELINE_SHADER_STAGE_CREATE_INFO, .stage = VK_SHADER_STAGE_COMPUTE_BIT,
        .module = shader("fill.comp"), .pName = "main"}, .layout = l};
    VkPipeline pipe; OK(vkCreateComputePipelines(device, VK_NULL_HANDLE, 1, &ci, NULL, &pipe));
    VkDescriptorPoolSize ps = {VK_DESCRIPTOR_TYPE_STORAGE_BUFFER, 1}; VkDescriptorPoolCreateInfo pci = {.sType = VK_STRUCTURE_TYPE_DESCRIPTOR_POOL_CREATE_INFO, .maxSets = 1, .poolSizeCount = 1, .pPoolSizes = &ps};
    VkDescriptorPool dp; OK(vkCreateDescriptorPool(device, &pci, NULL, &dp));
    VkDescriptorSetAllocateInfo ai = {.sType = VK_STRUCTURE_TYPE_DESCRIPTOR_SET_ALLOCATE_INFO, .descriptorPool = dp, .descriptorSetCount = 1, .pSetLayouts = &sl}; VkDescriptorSet set; OK(vkAllocateDescriptorSets(device, &ai, &set));
    Buf b = buf(256 * 4, VK_BUFFER_USAGE_STORAGE_BUFFER_BIT), args = buf(16, VK_BUFFER_USAGE_INDIRECT_BUFFER_BIT); uint32_t a3[3] = {2, 1, 1}; memcpy(args.p, a3, 12);
    VkDescriptorBufferInfo bi = {b.b, 0, VK_WHOLE_SIZE}; VkWriteDescriptorSet w = {.sType = VK_STRUCTURE_TYPE_WRITE_DESCRIPTOR_SET, .dstSet = set, .descriptorCount = 1, .descriptorType = VK_DESCRIPTOR_TYPE_STORAGE_BUFFER, .pBufferInfo = &bi};
    vkUpdateDescriptorSets(device, 1, &w, 0, NULL);
    VkCommandBuffer c = begin(VK_COMMAND_BUFFER_LEVEL_PRIMARY);
    vkCmdBindPipeline(c, VK_PIPELINE_BIND_POINT_COMPUTE, pipe); vkCmdBindDescriptorSets(c, VK_PIPELINE_BIND_POINT_COMPUTE, l, 0, 1, &set, 0, NULL);
    uint32_t add = 7; vkCmdPushConstants(c, l, VK_SHADER_STAGE_COMPUTE_BIT, 0, 4, &add); vkCmdDispatch(c, 4, 1, 1);
    add = 100; vkCmdPushConstants(c, l, VK_SHADER_STAGE_COMPUTE_BIT, 0, 4, &add); vkCmdDispatchIndirect(c, args.b, 0);
    submit(c);
    int ok = 1; for (uint32_t i = 0; i < 256; i++) { uint32_t v; memcpy(&v, b.p + i * 4, 4); ok &= v == i * 3 + (i < 128 ? 100u : 7u); }
    uint32_t v5, v200; memcpy(&v5, b.p + 20, 4); memcpy(&v200, b.p + 800, 4);
    CHECK(ok, "⑨ Dispatch + DispatchIndirect：256 个值全对（[5] = %u 期望 115、[200] = %u 期望 607）", v5, v200);
}
// ⑩ 次级命令缓冲：在渲染遍里执行，画出的颜色出现在主命令缓冲的附件上
// ⑨b 存储图像原子（审计 #1534 P1-66）：4×1 R32_UINT 清 0，256 个调用按 x & 3 各往一个纹素加 1 → 每个纹素 64（手算）。
//   MSL 2.3 时原子落在 SPIRV-Cross 另造的模拟缓冲上（宿主不绑），图像保持 0；3.1 原生原子写进图像。
//   清 → 屏障 → 原子 → 屏障 → 读回，一个命令缓冲里，连做 8 轮（每轮新图像、各自提交）：屏障没落成围栏时 Metal 让拷贝和原子重叠、读回清的值，单轮约一半次数（hle_vk.m fence_barrier）
static void t_image_atomic(void) {
    VkDescriptorSetLayoutBinding lb = {0, VK_DESCRIPTOR_TYPE_STORAGE_IMAGE, 1, VK_SHADER_STAGE_COMPUTE_BIT};
    VkDescriptorSetLayoutCreateInfo lci = {.sType = VK_STRUCTURE_TYPE_DESCRIPTOR_SET_LAYOUT_CREATE_INFO, .bindingCount = 1, .pBindings = &lb}; VkDescriptorSetLayout sl;
    OK(vkCreateDescriptorSetLayout(device, &lci, NULL, &sl));
    VkPipelineLayout l = layout_of(1, &sl, 0, 0);
    VkComputePipelineCreateInfo ci = {.sType = VK_STRUCTURE_TYPE_COMPUTE_PIPELINE_CREATE_INFO, .stage = {.sType = VK_STRUCTURE_TYPE_PIPELINE_SHADER_STAGE_CREATE_INFO, .stage = VK_SHADER_STAGE_COMPUTE_BIT,
        .module = shader("atomic.comp"), .pName = "main"}, .layout = l};
    VkPipeline pipe; OK(vkCreateComputePipelines(device, VK_NULL_HANDLE, 1, &ci, NULL, &pipe));
    enum { ROUNDS = 8 }; int bad = 0; uint32_t r[4] = {0};
    for (int round = 0; round < ROUNDS; round++) {
    VkImage i = img(VK_FORMAT_R32_UINT, 4, 1, 1, VK_SAMPLE_COUNT_1_BIT, VK_IMAGE_USAGE_STORAGE_BIT | VK_IMAGE_USAGE_TRANSFER_DST_BIT | VK_IMAGE_USAGE_TRANSFER_SRC_BIT);
    VkImageView v = view(i, VK_FORMAT_R32_UINT, VK_IMAGE_ASPECT_COLOR_BIT);
    VkDescriptorPoolSize ps = {VK_DESCRIPTOR_TYPE_STORAGE_IMAGE, 1}; VkDescriptorPoolCreateInfo pci = {.sType = VK_STRUCTURE_TYPE_DESCRIPTOR_POOL_CREATE_INFO, .maxSets = 1, .poolSizeCount = 1, .pPoolSizes = &ps};
    VkDescriptorPool dp; OK(vkCreateDescriptorPool(device, &pci, NULL, &dp));
    VkDescriptorSetAllocateInfo ai = {.sType = VK_STRUCTURE_TYPE_DESCRIPTOR_SET_ALLOCATE_INFO, .descriptorPool = dp, .descriptorSetCount = 1, .pSetLayouts = &sl}; VkDescriptorSet set; OK(vkAllocateDescriptorSets(device, &ai, &set));
    VkDescriptorImageInfo ii = {VK_NULL_HANDLE, v, VK_IMAGE_LAYOUT_GENERAL};
    VkWriteDescriptorSet w = {.sType = VK_STRUCTURE_TYPE_WRITE_DESCRIPTOR_SET, .dstSet = set, .descriptorCount = 1, .descriptorType = VK_DESCRIPTOR_TYPE_STORAGE_IMAGE, .pImageInfo = &ii};
    vkUpdateDescriptorSets(device, 1, &w, 0, NULL);
    Buf out = buf(16, VK_BUFFER_USAGE_TRANSFER_DST_BIT);
    VkCommandBuffer c = begin(VK_COMMAND_BUFFER_LEVEL_PRIMARY);
    VkClearColorValue z = {.uint32 = {0, 0, 0, 0}}; VkImageSubresourceRange all = {VK_IMAGE_ASPECT_COLOR_BIT, 0, 1, 0, 1};
    vkCmdClearColorImage(c, i, VK_IMAGE_LAYOUT_GENERAL, &z, 1, &all);
    VkMemoryBarrier mb = {.sType = VK_STRUCTURE_TYPE_MEMORY_BARRIER, .srcAccessMask = VK_ACCESS_TRANSFER_WRITE_BIT, .dstAccessMask = VK_ACCESS_SHADER_READ_BIT | VK_ACCESS_SHADER_WRITE_BIT};
    vkCmdPipelineBarrier(c, VK_PIPELINE_STAGE_TRANSFER_BIT, VK_PIPELINE_STAGE_COMPUTE_SHADER_BIT, 0, 1, &mb, 0, NULL, 0, NULL);   // 清 → 原子（规范要的依赖）
    vkCmdBindPipeline(c, VK_PIPELINE_BIND_POINT_COMPUTE, pipe); vkCmdBindDescriptorSets(c, VK_PIPELINE_BIND_POINT_COMPUTE, l, 0, 1, &set, 0, NULL);
    vkCmdDispatch(c, 4, 1, 1);
    mb.srcAccessMask = VK_ACCESS_SHADER_WRITE_BIT; mb.dstAccessMask = VK_ACCESS_TRANSFER_READ_BIT;
    vkCmdPipelineBarrier(c, VK_PIPELINE_STAGE_COMPUTE_SHADER_BIT, VK_PIPELINE_STAGE_TRANSFER_BIT, 0, 1, &mb, 0, NULL, 0, NULL);   // 原子 → 读回
    to_buffer(c, i, VK_IMAGE_ASPECT_COLOR_BIT, 0, 4, 1, out.b); submit(c);
    uint32_t g[4]; memcpy(g, out.p, 16);
    if (!(g[0] == 64 && g[1] == 64 && g[2] == 64 && g[3] == 64)) { if (!bad++) memcpy(r, g, 16); }
    }
    CHECK(!bad, "⑨b 存储图像原子：清 → 屏障 → 原子 → 屏障 → 读回 %d 轮，每轮 4 个纹素各 64（%d 轮不对，第一轮不对的实测 %u %u %u %u）", ROUNDS, bad, r[0], r[1], r[2], r[3]);
}
static void t_secondary(void) {
    VkImage i = img(VK_FORMAT_R8G8B8A8_UNORM, W, H, 1, VK_SAMPLE_COUNT_1_BIT, VK_IMAGE_USAGE_COLOR_ATTACHMENT_BIT | VK_IMAGE_USAGE_TRANSFER_SRC_BIT);
    VkImageView v = view(i, VK_FORMAT_R8G8B8A8_UNORM, VK_IMAGE_ASPECT_COLOR_BIT);
    VkRenderPass p = color_pass(VK_FORMAT_R8G8B8A8_UNORM, VK_ATTACHMENT_LOAD_OP_CLEAR, VK_SAMPLE_COUNT_1_BIT); VkFramebuffer f = framebuffer(p, 1, &v, W, H);
    VkPipelineLayout l = layout_of(0, NULL, 16, VK_SHADER_STAGE_FRAGMENT_BIT); VkPipeline pipe = gfx_pipe(p, 0, l, "color.frag", VK_SAMPLE_COUNT_1_BIT, NULL, 0, NULL);
    Buf out = buf(W * H * 4, VK_BUFFER_USAGE_TRANSFER_DST_BIT);
    VkCommandBuffer s = begin(VK_COMMAND_BUFFER_LEVEL_SECONDARY);
    VkCommandBufferInheritanceInfo inh = {.sType = VK_STRUCTURE_TYPE_COMMAND_BUFFER_INHERITANCE_INFO, .renderPass = p, .framebuffer = f};
    VkCommandBufferBeginInfo sbi = {.sType = VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO, .flags = VK_COMMAND_BUFFER_USAGE_RENDER_PASS_CONTINUE_BIT, .pInheritanceInfo = &inh};
    OK(vkBeginCommandBuffer(s, &sbi));
    vkCmdBindPipeline(s, VK_PIPELINE_BIND_POINT_GRAPHICS, pipe); float mag[4] = {1, 0, 1, 1}; vkCmdPushConstants(s, l, VK_SHADER_STAGE_FRAGMENT_BIT, 0, 16, mag); vkCmdDraw(s, 3, 1, 0, 0);
    OK(vkEndCommandBuffer(s));
    VkCommandBuffer c = begin(VK_COMMAND_BUFFER_LEVEL_PRIMARY); VkClearValue k = {.color.float32 = {0, 0, 0, 1}};
    begin_pass(c, p, f, 1, &k, VK_SUBPASS_CONTENTS_SECONDARY_COMMAND_BUFFERS); vkCmdExecuteCommands(c, 1, &s); vkCmdEndRenderPass(c);
    to_buffer(c, i, VK_IMAGE_ASPECT_COLOR_BIT, 0, W, H, out.b); submit(c);
    CHECK(px(&out, W, 16, 16) == RGBA(255, 0, 255, 255), "⑩ ExecuteCommands：次级命令缓冲画的品红出现在附件上（实测 %#x）", px(&out, W, 16, 16));
}
// ⑪ 两个子遍：子遍 0 把附件 0 画成黄；子遍 1 把附件 0 当输入附件读、写进附件 1 → 附件 1 也是黄
static void t_subpasses(void) {
    VkImage i0 = img(VK_FORMAT_R8G8B8A8_UNORM, W, H, 1, VK_SAMPLE_COUNT_1_BIT, VK_IMAGE_USAGE_COLOR_ATTACHMENT_BIT | VK_IMAGE_USAGE_INPUT_ATTACHMENT_BIT);
    VkImage i1 = img(VK_FORMAT_R8G8B8A8_UNORM, W, H, 1, VK_SAMPLE_COUNT_1_BIT, VK_IMAGE_USAGE_COLOR_ATTACHMENT_BIT | VK_IMAGE_USAGE_TRANSFER_SRC_BIT);
    VkImageView v[2] = {view(i0, VK_FORMAT_R8G8B8A8_UNORM, VK_IMAGE_ASPECT_COLOR_BIT), view(i1, VK_FORMAT_R8G8B8A8_UNORM, VK_IMAGE_ASPECT_COLOR_BIT)};
    VkAttachmentDescription a[2] = {{.format = VK_FORMAT_R8G8B8A8_UNORM, .samples = VK_SAMPLE_COUNT_1_BIT, .loadOp = VK_ATTACHMENT_LOAD_OP_CLEAR, .storeOp = VK_ATTACHMENT_STORE_OP_DONT_CARE},
                                    {.format = VK_FORMAT_R8G8B8A8_UNORM, .samples = VK_SAMPLE_COUNT_1_BIT, .loadOp = VK_ATTACHMENT_LOAD_OP_DONT_CARE, .storeOp = VK_ATTACHMENT_STORE_OP_STORE}};
    VkAttachmentReference c0 = {0, VK_IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL}, in0 = {0, VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL}, c1 = {1, VK_IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL};
    VkSubpassDescription sp[2] = {{.pipelineBindPoint = VK_PIPELINE_BIND_POINT_GRAPHICS, .colorAttachmentCount = 1, .pColorAttachments = &c0},
                                  {.pipelineBindPoint = VK_PIPELINE_BIND_POINT_GRAPHICS, .inputAttachmentCount = 1, .pInputAttachments = &in0, .colorAttachmentCount = 1, .pColorAttachments = &c1}};
    VkSubpassDependency dep = {0, 1, VK_PIPELINE_STAGE_COLOR_ATTACHMENT_OUTPUT_BIT, VK_PIPELINE_STAGE_FRAGMENT_SHADER_BIT, VK_ACCESS_COLOR_ATTACHMENT_WRITE_BIT, VK_ACCESS_INPUT_ATTACHMENT_READ_BIT, VK_DEPENDENCY_BY_REGION_BIT};
    VkRenderPassCreateInfo rci = {.sType = VK_STRUCTURE_TYPE_RENDER_PASS_CREATE_INFO, .attachmentCount = 2, .pAttachments = a, .subpassCount = 2, .pSubpasses = sp, .dependencyCount = 1, .pDependencies = &dep};
    VkRenderPass p; OK(vkCreateRenderPass(device, &rci, NULL, &p)); VkFramebuffer f = framebuffer(p, 2, v, W, H);
    VkPipelineLayout l0 = layout_of(0, NULL, 16, VK_SHADER_STAGE_FRAGMENT_BIT); VkPipeline p0 = gfx_pipe(p, 0, l0, "color.frag", VK_SAMPLE_COUNT_1_BIT, NULL, 0, NULL);
    VkDescriptorSetLayoutBinding lb = {0, VK_DESCRIPTOR_TYPE_INPUT_ATTACHMENT, 1, VK_SHADER_STAGE_FRAGMENT_BIT};
    VkDescriptorSetLayoutCreateInfo lci = {.sType = VK_STRUCTURE_TYPE_DESCRIPTOR_SET_LAYOUT_CREATE_INFO, .bindingCount = 1, .pBindings = &lb}; VkDescriptorSetLayout sl; OK(vkCreateDescriptorSetLayout(device, &lci, NULL, &sl));
    VkPipelineLayout l1 = layout_of(1, &sl, 0, 0); VkPipeline p1 = gfx_pipe(p, 1, l1, "input.frag", VK_SAMPLE_COUNT_1_BIT, NULL, 0, NULL);
    VkDescriptorPoolSize ps = {VK_DESCRIPTOR_TYPE_INPUT_ATTACHMENT, 1}; VkDescriptorPoolCreateInfo pci = {.sType = VK_STRUCTURE_TYPE_DESCRIPTOR_POOL_CREATE_INFO, .maxSets = 1, .poolSizeCount = 1, .pPoolSizes = &ps};
    VkDescriptorPool dp; OK(vkCreateDescriptorPool(device, &pci, NULL, &dp));
    VkDescriptorSetAllocateInfo ai = {.sType = VK_STRUCTURE_TYPE_DESCRIPTOR_SET_ALLOCATE_INFO, .descriptorPool = dp, .descriptorSetCount = 1, .pSetLayouts = &sl}; VkDescriptorSet set; OK(vkAllocateDescriptorSets(device, &ai, &set));
    VkDescriptorImageInfo ii = {VK_NULL_HANDLE, v[0], VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL};
    VkWriteDescriptorSet w = {.sType = VK_STRUCTURE_TYPE_WRITE_DESCRIPTOR_SET, .dstSet = set, .descriptorCount = 1, .descriptorType = VK_DESCRIPTOR_TYPE_INPUT_ATTACHMENT, .pImageInfo = &ii};
    vkUpdateDescriptorSets(device, 1, &w, 0, NULL);
    Buf out = buf(W * H * 4, VK_BUFFER_USAGE_TRANSFER_DST_BIT);
    VkCommandBuffer c = begin(VK_COMMAND_BUFFER_LEVEL_PRIMARY); VkClearValue k[2] = {{.color.float32 = {0, 0, 0, 1}}, {.color.float32 = {0, 0, 0, 0}}};
    begin_pass(c, p, f, 2, k, VK_SUBPASS_CONTENTS_INLINE);
    vkCmdBindPipeline(c, VK_PIPELINE_BIND_POINT_GRAPHICS, p0); float yel[4] = {1, 1, 0, 1}; vkCmdPushConstants(c, l0, VK_SHADER_STAGE_FRAGMENT_BIT, 0, 16, yel); vkCmdDraw(c, 3, 1, 0, 0);
    vkCmdNextSubpass(c, VK_SUBPASS_CONTENTS_INLINE);
    vkCmdBindPipeline(c, VK_PIPELINE_BIND_POINT_GRAPHICS, p1); vkCmdBindDescriptorSets(c, VK_PIPELINE_BIND_POINT_GRAPHICS, l1, 0, 1, &set, 0, NULL); vkCmdDraw(c, 3, 1, 0, 0);
    vkCmdEndRenderPass(c); to_buffer(c, i1, VK_IMAGE_ASPECT_COLOR_BIT, 0, W, H, out.b);
    uint64_t p0c = passes(); submit(c); uint64_t dp2 = passes() - p0c;
    CHECK(px(&out, W, 11, 27) == RGBA(255, 255, 0, 255), "⑪ NextSubpass + 输入附件：附件 1 = 子遍 0 画的黄（实测 %#x）", px(&out, W, 11, 27));
    CHECK(dp2 == 2, "⑪ 两个子遍 = 两个 Metal 渲染编码器（实测 +%llu）", (unsigned long long)dp2);
}
// ⑫ 动态模板写掩码：模板清 0，画时参考值 0xff、通过即替换、写掩码动态设 0x0f → 模板 = 0x0f
static void t_stencil_masks(void) {
    VkImage c0 = img(VK_FORMAT_R8G8B8A8_UNORM, W, H, 1, VK_SAMPLE_COUNT_1_BIT, VK_IMAGE_USAGE_COLOR_ATTACHMENT_BIT);
    VkImage ds = img(VK_FORMAT_D32_SFLOAT_S8_UINT, W, H, 1, VK_SAMPLE_COUNT_1_BIT, VK_IMAGE_USAGE_DEPTH_STENCIL_ATTACHMENT_BIT | VK_IMAGE_USAGE_TRANSFER_SRC_BIT);
    VkImageView v[2] = {view(c0, VK_FORMAT_R8G8B8A8_UNORM, VK_IMAGE_ASPECT_COLOR_BIT), view(ds, VK_FORMAT_D32_SFLOAT_S8_UINT, VK_IMAGE_ASPECT_DEPTH_BIT | VK_IMAGE_ASPECT_STENCIL_BIT)};
    VkAttachmentDescription a[2] = {{.format = VK_FORMAT_R8G8B8A8_UNORM, .samples = VK_SAMPLE_COUNT_1_BIT, .loadOp = VK_ATTACHMENT_LOAD_OP_CLEAR, .storeOp = VK_ATTACHMENT_STORE_OP_STORE},
        {.format = VK_FORMAT_D32_SFLOAT_S8_UINT, .samples = VK_SAMPLE_COUNT_1_BIT, .loadOp = VK_ATTACHMENT_LOAD_OP_CLEAR, .storeOp = VK_ATTACHMENT_STORE_OP_STORE, .stencilLoadOp = VK_ATTACHMENT_LOAD_OP_CLEAR, .stencilStoreOp = VK_ATTACHMENT_STORE_OP_STORE}};
    VkAttachmentReference cr = {0, VK_IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL}, dr = {1, VK_IMAGE_LAYOUT_DEPTH_STENCIL_ATTACHMENT_OPTIMAL};
    VkSubpassDescription sp = {.pipelineBindPoint = VK_PIPELINE_BIND_POINT_GRAPHICS, .colorAttachmentCount = 1, .pColorAttachments = &cr, .pDepthStencilAttachment = &dr};
    VkRenderPassCreateInfo rci = {.sType = VK_STRUCTURE_TYPE_RENDER_PASS_CREATE_INFO, .attachmentCount = 2, .pAttachments = a, .subpassCount = 1, .pSubpasses = &sp};
    VkRenderPass p; OK(vkCreateRenderPass(device, &rci, NULL, &p)); VkFramebuffer f = framebuffer(p, 2, v, W, H);
    VkStencilOpState so = {VK_STENCIL_OP_KEEP, VK_STENCIL_OP_REPLACE, VK_STENCIL_OP_KEEP, VK_COMPARE_OP_ALWAYS, 0xff, 0xff, 0xff};
    VkPipelineDepthStencilStateCreateInfo dsi = {.sType = VK_STRUCTURE_TYPE_PIPELINE_DEPTH_STENCIL_STATE_CREATE_INFO, .stencilTestEnable = VK_TRUE, .front = so, .back = so};
    VkDynamicState dyn[] = {VK_DYNAMIC_STATE_STENCIL_WRITE_MASK, VK_DYNAMIC_STATE_STENCIL_REFERENCE};
    VkPipelineLayout l = layout_of(0, NULL, 16, VK_SHADER_STAGE_FRAGMENT_BIT); VkPipeline pipe = gfx_pipe(p, 0, l, "color.frag", VK_SAMPLE_COUNT_1_BIT, &dsi, 2, dyn);
    Buf st = buf(W * H, VK_BUFFER_USAGE_TRANSFER_DST_BIT);
    VkCommandBuffer c = begin(VK_COMMAND_BUFFER_LEVEL_PRIMARY); VkClearValue k[2] = {{.color.float32 = {0, 0, 0, 1}}, {.depthStencil = {1, 0}}};
    begin_pass(c, p, f, 2, k, VK_SUBPASS_CONTENTS_INLINE); vkCmdBindPipeline(c, VK_PIPELINE_BIND_POINT_GRAPHICS, pipe);
    vkCmdSetStencilWriteMask(c, VK_STENCIL_FACE_FRONT_AND_BACK, 0x0f); vkCmdSetStencilReference(c, VK_STENCIL_FACE_FRONT_AND_BACK, 0xff);
    float w4[4] = {1, 1, 1, 1}; vkCmdPushConstants(c, l, VK_SHADER_STAGE_FRAGMENT_BIT, 0, 16, w4); vkCmdDraw(c, 3, 1, 0, 0); vkCmdEndRenderPass(c);
    VkBufferImageCopy rs = {.imageSubresource = {VK_IMAGE_ASPECT_STENCIL_BIT, 0, 0, 1}, .imageExtent = {W, H, 1}}; vkCmdCopyImageToBuffer(c, ds, VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL, st.b, 1, &rs);
    submit(c);
    CHECK(st.p[13 * W + 7] == 0x0f, "⑫ 动态模板写掩码 0x0f：参考值 0xff 替换后模板 = 0x0f（实测 %#x）", st.p[13 * W + 7]);
}

// ⑭ 采样器 LOD 偏置（mipLodBias）：两级 mip 纹理，第 0 级 W×H 全红、第 1 级 W/2×H/2 全绿；画进同尺寸目标，隐式 LOD = 0（lod.frag）/ 显式 LOD 0（lodx.frag）、最近邻 mip。
//   期望由规范手算：偏置 1.0 → LOD 1 → 采第 1 级绿；偏置 0 → 采第 0 级红（同一用例对照）。本机 GPU 采样器偏置生效（gal_samp_caps.h 实测，M5 / M4 Pro）走 Metal lodBias，
//   不生效（M3、系统早于 26）或 S2A_SAMP_EMU=1 走着色器模拟（hle_vk.m vk_se_obj：设备上重翻 + vk_lbias.inc 改写 + 偏置表）：两路同一组期望（#800）
static void t_lod_bias(void) {
    VkImageCreateInfo ici = {.sType = VK_STRUCTURE_TYPE_IMAGE_CREATE_INFO, .imageType = VK_IMAGE_TYPE_2D, .format = VK_FORMAT_R8G8B8A8_UNORM, .extent = {W, H, 1}, .mipLevels = 2, .arrayLayers = 1,
        .samples = VK_SAMPLE_COUNT_1_BIT, .tiling = VK_IMAGE_TILING_OPTIMAL, .usage = VK_IMAGE_USAGE_SAMPLED_BIT | VK_IMAGE_USAGE_TRANSFER_DST_BIT};
    VkImage tex; OK(vkCreateImage(device, &ici, NULL, &tex)); VkMemoryRequirements q; vkGetImageMemoryRequirements(device, tex, &q);
    VkMemoryAllocateInfo mai = {.sType = VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO, .allocationSize = q.size, .memoryTypeIndex = 0};
    VkDeviceMemory tm; OK(vkAllocateMemory(device, &mai, NULL, &tm)); OK(vkBindImageMemory(device, tex, tm, 0));
    VkImageViewCreateInfo tvi = {.sType = VK_STRUCTURE_TYPE_IMAGE_VIEW_CREATE_INFO, .image = tex, .viewType = VK_IMAGE_VIEW_TYPE_2D, .format = VK_FORMAT_R8G8B8A8_UNORM, .subresourceRange = {VK_IMAGE_ASPECT_COLOR_BIT, 0, 2, 0, 1}};
    VkImageView tv; OK(vkCreateImageView(device, &tvi, NULL, &tv));
    const size_t n0 = (size_t)W * H, n1 = (size_t)(W / 2) * (H / 2); Buf up = buf((n0 + n1) * 4, VK_BUFFER_USAGE_TRANSFER_SRC_BIT);
    for (size_t i = 0; i < n0; i++) { uint32_t v = RGBA(255, 0, 0, 255); memcpy(up.p + i * 4, &v, 4); }
    for (size_t i = 0; i < n1; i++) { uint32_t v = RGBA(0, 255, 0, 255); memcpy(up.p + (n0 + i) * 4, &v, 4); }
    VkBufferImageCopy rg[2] = {{.bufferOffset = 0, .imageSubresource = {VK_IMAGE_ASPECT_COLOR_BIT, 0, 0, 1}, .imageExtent = {W, H, 1}},
                               {.bufferOffset = n0 * 4, .imageSubresource = {VK_IMAGE_ASPECT_COLOR_BIT, 1, 0, 1}, .imageExtent = {W / 2, H / 2, 1}}};
    VkCommandBuffer c = begin(VK_COMMAND_BUFFER_LEVEL_PRIMARY); vkCmdCopyBufferToImage(c, up.b, tex, VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL, 2, rg); submit(c);
    VkDescriptorSetLayoutBinding lb = {0, VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER, 1, VK_SHADER_STAGE_FRAGMENT_BIT};
    VkDescriptorSetLayoutCreateInfo lci = {.sType = VK_STRUCTURE_TYPE_DESCRIPTOR_SET_LAYOUT_CREATE_INFO, .bindingCount = 1, .pBindings = &lb}; VkDescriptorSetLayout sl; OK(vkCreateDescriptorSetLayout(device, &lci, NULL, &sl));
    VkDescriptorPoolSize ps = {VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER, 4}; VkDescriptorPoolCreateInfo pci = {.sType = VK_STRUCTURE_TYPE_DESCRIPTOR_POOL_CREATE_INFO, .maxSets = 4, .poolSizeCount = 1, .pPoolSizes = &ps};
    VkDescriptorPool dp; OK(vkCreateDescriptorPool(device, &pci, NULL, &dp));
    VkPipelineLayout l = layout_of(1, &sl, 0, 0); VkRenderPass p = color_pass(VK_FORMAT_R8G8B8A8_UNORM, VK_ATTACHMENT_LOAD_OP_CLEAR, VK_SAMPLE_COUNT_1_BIT);
    static const char *const fs[2] = {"lod.frag", "lodx.frag"}, *const fn[2] = {"隐式 LOD", "显式 LOD 0"}; const char *path = getenv("S2A_SAMP_EMU") ? "S2A_SAMP_EMU=1" : "本机能力";
    for (int f2 = 0; f2 < 2; f2++) {
    VkPipeline pl = gfx_pipe(p, 0, l, fs[f2], VK_SAMPLE_COUNT_1_BIT, NULL, 0, NULL);
    const float bias[2] = {1.0f, 0.0f}; uint32_t got[2];
    for (int k = 0; k < 2; k++) {
        VkSamplerCreateInfo sci = {.sType = VK_STRUCTURE_TYPE_SAMPLER_CREATE_INFO, .magFilter = VK_FILTER_NEAREST, .minFilter = VK_FILTER_NEAREST, .mipmapMode = VK_SAMPLER_MIPMAP_MODE_NEAREST,
            .addressModeU = VK_SAMPLER_ADDRESS_MODE_CLAMP_TO_EDGE, .addressModeV = VK_SAMPLER_ADDRESS_MODE_CLAMP_TO_EDGE, .addressModeW = VK_SAMPLER_ADDRESS_MODE_CLAMP_TO_EDGE,
            .mipLodBias = bias[k], .minLod = 0, .maxLod = 1};
        VkSampler s; OK(vkCreateSampler(device, &sci, NULL, &s));
        VkDescriptorSetAllocateInfo ai = {.sType = VK_STRUCTURE_TYPE_DESCRIPTOR_SET_ALLOCATE_INFO, .descriptorPool = dp, .descriptorSetCount = 1, .pSetLayouts = &sl}; VkDescriptorSet set; OK(vkAllocateDescriptorSets(device, &ai, &set));
        VkDescriptorImageInfo ii = {s, tv, VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL};
        VkWriteDescriptorSet w = {.sType = VK_STRUCTURE_TYPE_WRITE_DESCRIPTOR_SET, .dstSet = set, .descriptorCount = 1, .descriptorType = VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER, .pImageInfo = &ii};
        vkUpdateDescriptorSets(device, 1, &w, 0, NULL);
        VkImage ci = img(VK_FORMAT_R8G8B8A8_UNORM, W, H, 1, VK_SAMPLE_COUNT_1_BIT, VK_IMAGE_USAGE_COLOR_ATTACHMENT_BIT | VK_IMAGE_USAGE_TRANSFER_SRC_BIT);
        VkImageView cv = view(ci, VK_FORMAT_R8G8B8A8_UNORM, VK_IMAGE_ASPECT_COLOR_BIT); VkFramebuffer f = framebuffer(p, 1, &cv, W, H);
        Buf out = buf(W * H * 4, VK_BUFFER_USAGE_TRANSFER_DST_BIT); VkClearValue kc = {.color.float32 = {0, 0, 1, 1}};
        c = begin(VK_COMMAND_BUFFER_LEVEL_PRIMARY); begin_pass(c, p, f, 1, &kc, VK_SUBPASS_CONTENTS_INLINE);
        vkCmdBindPipeline(c, VK_PIPELINE_BIND_POINT_GRAPHICS, pl); vkCmdBindDescriptorSets(c, VK_PIPELINE_BIND_POINT_GRAPHICS, l, 0, 1, &set, 0, NULL); vkCmdDraw(c, 3, 1, 0, 0);
        vkCmdEndRenderPass(c); to_buffer(c, ci, VK_IMAGE_ASPECT_COLOR_BIT, 0, W, H, out.b); submit(c);
        got[k] = px(&out, W, W / 2 + 1, H / 2 + 1);
    }
    CHECK(got[1] == RGBA(255, 0, 0, 255), "⑭ %s %s 偏置 0：LOD 0 采第 0 级红（实测 %#x）", path, fn[f2], got[1]);
    CHECK(got[0] == RGBA(0, 255, 0, 255), "⑭ %s %s 偏置 1.0：LOD 1 采第 1 级绿（实测 %#x）", path, fn[f2], got[0]);
    }
}
// ⑬ 设备现编（乙）：rt.frag 不在离线库 → 未命中 +1、后台编好（≤10 秒）、之后建的管线画出现编那支的输出、源码与资源栏落盘持久化。
//    T_VK_RT_WARM=1（同一持久化目录第二次起进程 = 下次开机）：开机预编读回 → 未命中 +0、读持久化 +1，像素同样对
void dm_vk_rt_stats(uint64_t *miss, uint64_t *ok, uint64_t *bad, uint64_t *disk);
uint64_t dm_vk_rt_saved(void);
static void t_runtime(void) {
    uint64_t m0, k0, b0, d0, m, k, b, d; dm_vk_rt_stats(&m0, &k0, &b0, &d0); uint64_t s0 = dm_vk_rt_saved();
    int warm = getenv("T_VK_RT_WARM") != NULL;
    shader("rt.frag"); dm_vk_rt_stats(&m, &k, &b, &d);
    CHECK(m == m0 + !warm, "⑬ %s：未命中 +%llu", warm ? "下次开机（持久化读回）" : "不在离线库的 SPIR-V", (unsigned long long)(m - m0));
    for (int i = 0; i < 1000 && k == k0 && !d && b == b0; i++) { usleep(10000); dm_vk_rt_stats(&m, &k, &b, &d); }
    if (warm) CHECK(d == 1 && k == k0 && b == b0, "⑬ 下次开机：开机预编读持久化 %llu 支（本进程累计）、现翻 +%llu、失败 +%llu", (unsigned long long)d, (unsigned long long)(k - k0), (unsigned long long)(b - b0));
    else CHECK(k == k0 + 1 && b == b0, "⑬ 后台翻译 + 现编：编好 +%llu、失败 +%llu", (unsigned long long)(k - k0), (unsigned long long)(b - b0));
    VkImage i = img(VK_FORMAT_R8G8B8A8_UNORM, W, H, 1, VK_SAMPLE_COUNT_1_BIT, VK_IMAGE_USAGE_COLOR_ATTACHMENT_BIT | VK_IMAGE_USAGE_TRANSFER_SRC_BIT);
    VkImageView v = view(i, VK_FORMAT_R8G8B8A8_UNORM, VK_IMAGE_ASPECT_COLOR_BIT);
    VkRenderPass p = color_pass(VK_FORMAT_R8G8B8A8_UNORM, VK_ATTACHMENT_LOAD_OP_CLEAR, VK_SAMPLE_COUNT_1_BIT); VkFramebuffer f = framebuffer(p, 1, &v, W, H);
    VkPipelineLayout l = layout_of(0, NULL, 16, VK_SHADER_STAGE_FRAGMENT_BIT); VkPipeline pipe = gfx_pipe(p, 0, l, "rt.frag", VK_SAMPLE_COUNT_1_BIT, NULL, 0, NULL);
    Buf out = buf(W * H * 4, VK_BUFFER_USAGE_TRANSFER_DST_BIT);
    VkCommandBuffer c = begin(VK_COMMAND_BUFFER_LEVEL_PRIMARY); VkClearValue black = {.color.float32 = {0, 0, 0, 1}}; begin_pass(c, p, f, 1, &black, VK_SUBPASS_CONTENTS_INLINE);
    vkCmdBindPipeline(c, VK_PIPELINE_BIND_POINT_GRAPHICS, pipe); float col[4] = {1, .5f, .25f, 1}; vkCmdPushConstants(c, l, VK_SHADER_STAGE_FRAGMENT_BIT, 0, 16, col);
    vkCmdDraw(c, 3, 1, 0, 0); vkCmdEndRenderPass(c); to_buffer(c, i, VK_IMAGE_ASPECT_COLOR_BIT, 0, W, H, out.b); submit(c);
    uint32_t q = px(&out, W, 5, 5); int r = q & 0xff, g = q >> 8 & 0xff, bl = q >> 16 & 0xff;
    CHECK(r >= 63 && r <= 65 && g >= 127 && g <= 129 && bl == 255, "⑬ 编好之后建的管线画出现编那支：push (1,.5,.25,1) 的 bgra = (64,128,255)（实测 %d %d %d）", r, g, bl);
    // 「编好」在落盘之前就加：数文件前等后台写完 .row（最多 10 秒；真写不进盘照样数出 < 2 个、判红）
    if (!warm) for (int i = 0; i < 1000 && dm_vk_rt_saved() == s0; i++) usleep(10000);
    char path[1200]; int files = 0; DIR *dp = opendir(getenv("DM_MSL_FALLBACK") ? (snprintf(path, sizeof path, "%s/vk", getenv("DM_MSL_FALLBACK")), path) : "/nonexistent");
    for (struct dirent *e; dp && (e = readdir(dp));) files += strstr(e->d_name, ".row") || strstr(e->d_name, ".metal");
    if (dp) closedir(dp);
    CHECK(files == 2, "⑬ 持久化：<键>.metal 与 <键>.row 落盘（%d 个文件）", files);
    // 落盘的资源栏要完整：rt.frag 声明了推常量（p）、一张组合贴图采样器（c）→ 2 项（空格分隔）
    int nres = 0; char row[2200] = "";
    if (dp && (dp = opendir(path))) {
        for (struct dirent *e; (e = readdir(dp));) if (strstr(e->d_name, ".row")) {
            char rp[1300]; snprintf(rp, sizeof rp, "%s/%s", path, e->d_name); FILE *f = fopen(rp, "r");
            if (f) { if (!fgets(row, sizeof row, f)) row[0] = 0; fclose(f); }
        }
        closedir(dp);
    }
    char *res = strrchr(row, '\t'); if (res) for (char *t = strtok(res + 1, " \n"); t; t = strtok(NULL, " \n")) nres++;
    CHECK(nres == 2, "⑬ 持久化的资源栏 2 项都在（组合贴图采样器 / 推常量；实测 %d 项：%.200s）", nres, row);
    // 游戏 SPIR-V 原样存下（11-05：出包不起局抓着色器，收局并进跑局知识、下次出包离线翻进库）：<键>.spv 恰 1 个，字节 = 测试读进来的 rt.frag.spv
    if (!warm) {
        char sp[1300] = "", want[1100]; int nspv = 0, same = 0;
        if ((dp = opendir(path))) { for (struct dirent *e; (e = readdir(dp));) { size_t l = strlen(e->d_name); if (l == 20 && !strcmp(e->d_name + 16, ".spv")) { nspv++; snprintf(sp, sizeof sp, "%s/%s", path, e->d_name); } } closedir(dp); }
        snprintf(want, sizeof want, "%s/rt.frag.spv", getenv("T_VK_SPV_RT") ? getenv("T_VK_SPV_RT") : "/nonexistent");
        FILE *a = nspv == 1 ? fopen(sp, "rb") : NULL, *w = fopen(want, "rb");
        if (a && w) { same = 1; for (int ca, cw; same;) { ca = fgetc(a); cw = fgetc(w); if (ca != cw) same = 0; if (ca == EOF || cw == EOF) break; } }
        if (a) fclose(a);
        if (w) fclose(w);
        CHECK(nspv == 1 && same, "⑬ 持久化：游戏 SPIR-V 原样存成 <键>.spv（%d 个，字节%s）", nspv, same ? "相同" : "不同或读不到");
    }
}

// ⑮ 宽屏按内容判画布（10-30 银河2 EFB）：子进程里换上按脚本行事的假核心（宿主替身里的宽屏入口是弱符号），整套放宽模式。期望手算：
//   W×H 图像建时假核心给原宽 W；晋升后给 W + 14 → 平移 pad = 7。图像按列写「R = 列号」，晋升后的下一次提交重建：按游戏坐标读回的是新贴图左 W 列，
//   第 7 列 R = 0、第 W−1 列 R = W−8；视图向核心重新登记 1 次（父 = 这张图）；晋升前建的帧缓冲清蓝 → 读回第 0 / W−1 列都是蓝（视图换到新存储）。
//   推常量：同一渲染遍里推红、画、推绿、画 → 片元槽交给核心 2 次，内容依次红、绿（同一块 pc 地址，按内容序号判变化）
#include "../../graphics/widen/export/s2a_widen.h"
static int fk_on, fk_promote, fk_done, fk_reviews, fk_binds; static uint32_t fk_img; static float fk_c[4][4];
int s2a_widen_init(int w, int h, uint32_t f) { (void)w; (void)h; (void)f; return fk_on ? S2A_WIDEN_ALL : S2A_WIDEN_OFF; }
float s2a_widen_k(void) { return (W + 14.0f) / W; }
int s2a_widen_texture(uint32_t id, int w, int h, float sc, uint32_t usage) {
    (void)sc; if (!fk_on || w != W || h != H || !(usage & S2A_WIDEN_USE_REBUILD)) return w;
    if (!fk_img) fk_img = id;
    return id == fk_img && fk_done ? W + 14 : w;
}
int s2a_widen_promoted(uint32_t *ids, int cap) { if (!fk_promote || fk_done || cap < 1) return 0; ids[0] = fk_img; fk_done = 1; return 1; }
int s2a_widen_view(uint32_t id, uint32_t parent, int level, int w0) { (void)id; if (parent == fk_img && fk_done) { fk_reviews++; return (W + 14) >> level; } return w0; }
int s2a_widen_map_x(uint32_t tex, int x) { (void)tex; return x; }   // 读回按游戏坐标取左 W 列（读回不换算，hle_vk.m C_COPYI2B）
int s2a_widen_viewport(float x, float w, float h, float sc) { (void)x; (void)w; (void)h; (void)sc; return fk_on; }
void s2a_widen_cbuf_bind(int st, int sl, const void *cpu, uint32_t len) { (void)sl; if (st == 1 && cpu && len >= 16 && fk_binds < 4) memcpy(fk_c[fk_binds++], cpu, 16); }
int s2a_widen_draw(const s2a_widen_draw_in *in, s2a_widen_draw_out *out) { (void)in; memset(out, 0, sizeof *out); out->frag_scale_x = 1; return S2A_WIDEN_KEEP; }
static int fk_tall;   // ⑰：窄屏加高的假核心——能当附件的 W×H 图像放高到 2H
int s2a_widen_tex_h(uint32_t id, int h) { (void)id; return fk_tall && h == H ? 2 * h : h; }
static void t_widen(void) {
    VkImage i = img(VK_FORMAT_R8G8B8A8_UNORM, W, H, 1, VK_SAMPLE_COUNT_1_BIT, VK_IMAGE_USAGE_COLOR_ATTACHMENT_BIT | VK_IMAGE_USAGE_TRANSFER_SRC_BIT | VK_IMAGE_USAGE_TRANSFER_DST_BIT);
    VkImageView v = view(i, VK_FORMAT_R8G8B8A8_UNORM, VK_IMAGE_ASPECT_COLOR_BIT);
    VkRenderPass p = color_pass(VK_FORMAT_R8G8B8A8_UNORM, VK_ATTACHMENT_LOAD_OP_CLEAR, VK_SAMPLE_COUNT_1_BIT); VkFramebuffer f = framebuffer(p, 1, &v, W, H);
    VkPipelineLayout l = layout_of(0, NULL, 16, VK_SHADER_STAGE_FRAGMENT_BIT); VkPipeline pipe = gfx_pipe(p, 0, l, "color.frag", VK_SAMPLE_COUNT_1_BIT, NULL, 0, NULL);
    CHECK(fk_img != 0, "⑮ 能当附件的图像带「可重建」交给核心（贴图号 %u）", fk_img);
    Buf src = buf(W * H * 4, VK_BUFFER_USAGE_TRANSFER_SRC_BIT), out = buf(W * H * 4, VK_BUFFER_USAGE_TRANSFER_DST_BIT);
    for (uint32_t y = 0; y < H; y++) for (uint32_t x = 0; x < W; x++) { uint32_t c = RGBA(x, 0, 0, 255); memcpy(src.p + ((size_t)y * W + x) * 4, &c, 4); }
    VkCommandBuffer c = begin(VK_COMMAND_BUFFER_LEVEL_PRIMARY);
    VkBufferImageCopy r = {.imageSubresource = {VK_IMAGE_ASPECT_COLOR_BIT, 0, 0, 1}, .imageExtent = {W, H, 1}}; vkCmdCopyBufferToImage(c, src.b, i, VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL, 1, &r);
    submit(c);
    fk_promote = 1;   // 核心在这次之前判出画布：下一次提交开头重建
    c = begin(VK_COMMAND_BUFFER_LEVEL_PRIMARY); to_buffer(c, i, VK_IMAGE_ASPECT_COLOR_BIT, 0, W, H, out.b); submit(c);
    CHECK(fk_done && (px(&out, W, 7, 5) & 0xff) == 0 && (px(&out, W, 20, 5) & 0xff) == 13 && (px(&out, W, W - 1, 5) & 0xff) == W - 8,
          "⑮ 重建后旧内容平移 7 列：第 7 / 20 / %u 列 R = 0 / 13 / %u（实测 %u / %u / %u）", W - 1, W - 8, px(&out, W, 7, 5) & 0xff, px(&out, W, 20, 5) & 0xff, px(&out, W, W - 1, 5) & 0xff);
    CHECK(fk_reviews == 1, "⑮ 视图向核心重新登记 1 次（实测 %d）", fk_reviews);
    c = begin(VK_COMMAND_BUFFER_LEVEL_PRIMARY); VkClearValue blue = {.color.float32 = {0, 0, 1, 1}}; begin_pass(c, p, f, 1, &blue, VK_SUBPASS_CONTENTS_INLINE);
    vkCmdBindPipeline(c, VK_PIPELINE_BIND_POINT_GRAPHICS, pipe);
    float red[4] = {1, 0, 0, 1}, green[4] = {0, 1, 0, 1}; fk_binds = 0;
    vkCmdPushConstants(c, l, VK_SHADER_STAGE_FRAGMENT_BIT, 0, 16, red); vkCmdDraw(c, 3, 1, 0, 0);
    vkCmdPushConstants(c, l, VK_SHADER_STAGE_FRAGMENT_BIT, 0, 16, green); vkCmdDraw(c, 3, 1, 0, 0);
    vkCmdEndRenderPass(c); to_buffer(c, i, VK_IMAGE_ASPECT_COLOR_BIT, 0, W, H, out.b); submit(c);
    CHECK(px(&out, W, 0, 5) == RGBA(0, 255, 0, 255) && px(&out, W, W - 1, 5) == RGBA(0, 255, 0, 255),
          "⑮ 晋升前建的帧缓冲画到重建后的存储：第 0 / %u 列都是最后一笔的绿（实测 %#x / %#x）", W - 1, px(&out, W, 0, 5), px(&out, W, W - 1, 5));
    CHECK(fk_binds == 2 && fk_c[0][0] == 1 && fk_c[0][1] == 0 && fk_c[1][0] == 0 && fk_c[1][1] == 1,
          "⑮ 推常量两次变化都交给核心：2 次、依次红 / 绿（实测 %d 次，首 %g,%g 次 %g,%g）", fk_binds, fk_c[0][0], fk_c[0][1], fk_c[1][0], fk_c[1][1]);
}
// ⑰ 窄屏加高（11-02 银河2 Duo 外屏：Vulkan 层原先只取核心给的宽、高照游戏建，拷贝区域只换 x）。假核心把能当附件的 W×H 图像放高到 2H。期望手算：
//   源 = 附件图像（存储 W×2H）：整张清蓝（渲染遍清屏清整张存储），再按游戏坐标把缓冲写进左上 W×H（缓冲拷贝不换算）= 存储 [0, H) 行「R = 行号」、[H, 2H) 行蓝；
//   目标 = 同样的附件图像清绿。拷贝游戏坐标 [H/2, H) 行 → 目标 [0, H/2) 行：按存储高 ÷ 游戏高（2）换算 = 源存储 [H, 2H) 行（蓝）→ 目标存储 [0, H) 行；
//   读回目标按游戏坐标取左上 W×H（读回不换算）= 存储 [0, H) 行 → 第 2 / H−2 行都蓝。只换 x 时（或存储没加高）拷的是源 [H/2, H) 行 → 第 2 行 R = H/2 + 2、第 H−2 行仍绿
static void t_tall(void) {
    VkImageUsageFlags u = VK_IMAGE_USAGE_COLOR_ATTACHMENT_BIT | VK_IMAGE_USAGE_TRANSFER_SRC_BIT | VK_IMAGE_USAGE_TRANSFER_DST_BIT;
    VkImage a = img(VK_FORMAT_R8G8B8A8_UNORM, W, H, 1, VK_SAMPLE_COUNT_1_BIT, u), b = img(VK_FORMAT_R8G8B8A8_UNORM, W, H, 1, VK_SAMPLE_COUNT_1_BIT, u);
    VkImageView va = view(a, VK_FORMAT_R8G8B8A8_UNORM, VK_IMAGE_ASPECT_COLOR_BIT), vb = view(b, VK_FORMAT_R8G8B8A8_UNORM, VK_IMAGE_ASPECT_COLOR_BIT);
    VkRenderPass p = color_pass(VK_FORMAT_R8G8B8A8_UNORM, VK_ATTACHMENT_LOAD_OP_CLEAR, VK_SAMPLE_COUNT_1_BIT);
    VkFramebuffer fa = framebuffer(p, 1, &va, W, H), fb = framebuffer(p, 1, &vb, W, H);
    Buf src = buf(W * H * 4, VK_BUFFER_USAGE_TRANSFER_SRC_BIT), out = buf(W * H * 4, VK_BUFFER_USAGE_TRANSFER_DST_BIT);
    for (uint32_t y = 0; y < H; y++) for (uint32_t x = 0; x < W; x++) { uint32_t c = RGBA(y, 0, 0, 255); memcpy(src.p + ((size_t)y * W + x) * 4, &c, 4); }
    VkCommandBuffer c = begin(VK_COMMAND_BUFFER_LEVEL_PRIMARY); VkClearValue blue = {.color.float32 = {0, 0, 1, 1}}, green = {.color.float32 = {0, 1, 0, 1}};
    begin_pass(c, p, fa, 1, &blue, VK_SUBPASS_CONTENTS_INLINE); vkCmdEndRenderPass(c);
    begin_pass(c, p, fb, 1, &green, VK_SUBPASS_CONTENTS_INLINE); vkCmdEndRenderPass(c);
    VkBufferImageCopy r = {.imageSubresource = {VK_IMAGE_ASPECT_COLOR_BIT, 0, 0, 1}, .imageExtent = {W, H, 1}}; vkCmdCopyBufferToImage(c, src.b, a, VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL, 1, &r);
    VkImageCopy k = {.srcSubresource = {VK_IMAGE_ASPECT_COLOR_BIT, 0, 0, 1}, .srcOffset = {0, H / 2, 0}, .dstSubresource = {VK_IMAGE_ASPECT_COLOR_BIT, 0, 0, 1}, .extent = {W, H / 2, 1}};
    vkCmdCopyImage(c, a, VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL, b, VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL, 1, &k);
    to_buffer(c, b, VK_IMAGE_ASPECT_COLOR_BIT, 0, W, H, out.b); submit(c);
    uint32_t bl = RGBA(0, 0, 255, 255);
    CHECK(px(&out, W, 5, 2) == bl && px(&out, W, 5, H - 2) == bl, "⑰ 加高图像间拷贝按存储高换算 y：目标第 2 / %u 行都蓝 %#x（实测 %#x / %#x）", H - 2, bl, px(&out, W, 5, 2), px(&out, W, 5, H - 2));
    // ⑱ 加高的源整张拷进没加高的普通图像（不能当附件 → 不交核心、存储 W×H）：两边换算后高 2H ≠ H → 缩放拷贝（同 NVN copy_t2t）。手算：目标第 y 行取源存储约第 2y + 1 行，
    //   第 H−2 行 → 源 [H, 2H) 的蓝；第 2 行 → 源第 5 行附近 R = 4–6（线性过滤）。按较矮的拷时只拷源存储上面 H 行：第 H−2 行 R = H−2、不是蓝
    VkImage n = img(VK_FORMAT_R8G8B8A8_UNORM, W, H, 1, VK_SAMPLE_COUNT_1_BIT, VK_IMAGE_USAGE_TRANSFER_SRC_BIT | VK_IMAGE_USAGE_TRANSFER_DST_BIT);
    VkImageCopy all = {.srcSubresource = {VK_IMAGE_ASPECT_COLOR_BIT, 0, 0, 1}, .dstSubresource = {VK_IMAGE_ASPECT_COLOR_BIT, 0, 0, 1}, .extent = {W, H, 1}};
    c = begin(VK_COMMAND_BUFFER_LEVEL_PRIMARY); vkCmdCopyImage(c, a, VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL, n, VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL, 1, &all);
    to_buffer(c, n, VK_IMAGE_ASPECT_COLOR_BIT, 0, W, H, out.b); submit(c);
    uint32_t lo = px(&out, W, 5, H - 2), hi = px(&out, W, 5, 2);
    CHECK(lo == bl && (hi & 0xff) >= 4 && (hi & 0xff) <= 6 && (hi >> 16 & 0xff) == 0, "⑱ 加高 → 没加高的图像拷贝成缩放拷贝：第 %u 行蓝 %#x（实测 %#x）、第 2 行 R 4–6（实测 %#x）", H - 2, bl, lo, hi);
    // ⑲ 遍内清屏区域按存储换算（审计 P1-79：vkCmdClearAttachments 原先按游戏坐标直接用）。a 整张清绿，再在遍内按游戏坐标清 [H/2, H) 行红 → 换算后是存储 [H, 2H) 行。
    //   手算：读回 a（游戏坐标 = 存储 [0, H) 行）第 H−2 行仍绿；再把 a 的游戏 [H/2, H) 行拷进 b 的 [0, H/2) 行（⑰ 已证拷贝按 2 倍换算 = 源存储 [H, 2H) → 目标存储 [0, H)），b 第 2 行红。
    //   不换算时红落在存储 [H/2, H) 行：a 第 H−2 行红、b 第 2 行绿
    {
        VkClearValue gr = {.color.float32 = {0, 1, 0, 1}};
        c = begin(VK_COMMAND_BUFFER_LEVEL_PRIMARY); begin_pass(c, p, fa, 1, &gr, VK_SUBPASS_CONTENTS_INLINE);
        VkClearAttachment ca = {.aspectMask = VK_IMAGE_ASPECT_COLOR_BIT, .colorAttachment = 0, .clearValue.color.float32 = {1, 0, 0, 1}};
        VkClearRect cr = {.rect = {{0, H / 2}, {W, H / 2}}, .baseArrayLayer = 0, .layerCount = 1};
        vkCmdClearAttachments(c, 1, &ca, 1, &cr); vkCmdEndRenderPass(c);
        to_buffer(c, a, VK_IMAGE_ASPECT_COLOR_BIT, 0, W, H, out.b); submit(c);
        uint32_t ga = px(&out, W, 5, H - 2);
        c = begin(VK_COMMAND_BUFFER_LEVEL_PRIMARY); vkCmdCopyImage(c, a, VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL, b, VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL, 1, &k);
        to_buffer(c, b, VK_IMAGE_ASPECT_COLOR_BIT, 0, W, H, out.b); submit(c);
        uint32_t gb = px(&out, W, 5, 2);
        CHECK(ga == RGBA(0, 255, 0, 255) && gb == RGBA(255, 0, 0, 255), "⑲ 遍内清屏区域按存储高换算：a 第 %u 行仍绿（实测 %#x）、清到存储 [H, 2H) 的红经拷贝落到 b 第 2 行（实测 %#x）", H - 2, ga, gb);
    }
}
// ⑯ 审计 1800（P1-22 / P1-45 / P1-46 / P2-3 / P2-4）。甲类（原本越界 / 写错的那部分改对，界内路径不变）：剪裁整块在目标外 → 空剪裁（同通用层 gal_state.m）、
//    等尺寸 Blit 只在两边都在界内时整块拷（同 GL 层 blit_color）、局部解析先解析到暂存再按区域拷回（同 GL 层）、越出内存的填充 / 更新与越出层数的清图像不编码。
//    乙类（改能力位要读数）：照旧回成功，只核计数（hle_vk.m dm_vk_ok_but_bad，下标同 OKB_*）。期望值都按规范手算
//    审计 #1534：P1-45 映射 / 图像视图 / 缓冲视图越界、P1-46 管线建不成改回失败码 + 空句柄（Vulkan 1.1 §11.2.9 / §11.5 / §12.5 / §9.x：越界是非法用法，建不成的那一项交 VK_NULL_HANDLE）；
//    P1-68 拷贝越界：缓冲范围越出不编码、图像矩形夹进两边（同 Blit 等尺寸 clamp_span）夹空不编码；P1-69 renderArea 小于帧缓冲：加载 / 清除 / 存储只动区域内（§7.4）
__attribute__((weak)) uint64_t dm_vk_ok_but_bad(int k) { (void)k; return 0; }   // 实现没有计数时（旧实现）读 0，计数项判败而不是链接失败
enum { K_MAP_TYPE0, K_PRESENT_IDX, K_FEAT_ROBUST, K_FEAT_SSR };
static void t_audit1800(void) {
    // 剪裁：左外（x 范围 [-40,-20)）、上外（y 范围 [-40,-20)）两笔红都不出片元；界内 (4,4) 8×8 一笔绿
    {
        VkImage i = img(VK_FORMAT_R8G8B8A8_UNORM, W, H, 1, VK_SAMPLE_COUNT_1_BIT, VK_IMAGE_USAGE_COLOR_ATTACHMENT_BIT | VK_IMAGE_USAGE_TRANSFER_SRC_BIT);
        VkImageView v = view(i, VK_FORMAT_R8G8B8A8_UNORM, VK_IMAGE_ASPECT_COLOR_BIT);
        VkRenderPass p = color_pass(VK_FORMAT_R8G8B8A8_UNORM, VK_ATTACHMENT_LOAD_OP_CLEAR, VK_SAMPLE_COUNT_1_BIT); VkFramebuffer f = framebuffer(p, 1, &v, W, H);
        VkDynamicState dyn = VK_DYNAMIC_STATE_SCISSOR; VkPipelineLayout l = layout_of(0, NULL, 16, VK_SHADER_STAGE_FRAGMENT_BIT);
        VkPipeline pipe = gfx_pipe(p, 0, l, "color.frag", VK_SAMPLE_COUNT_1_BIT, NULL, 1, &dyn);
        Buf out = buf(W * H * 4, VK_BUFFER_USAGE_TRANSFER_DST_BIT);
        VkCommandBuffer c = begin(VK_COMMAND_BUFFER_LEVEL_PRIMARY); VkClearValue blue = {.color.float32 = {0, 0, 1, 1}};
        begin_pass(c, p, f, 1, &blue, VK_SUBPASS_CONTENTS_INLINE); vkCmdBindPipeline(c, VK_PIPELINE_BIND_POINT_GRAPHICS, pipe);
        float red[4] = {1, 0, 0, 1}, green[4] = {0, 1, 0, 1};
        VkRect2D left = {{-40, 0}, {20, H}}, above = {{0, -40}, {W, 20}}, box = {{4, 4}, {8, 8}};
        vkCmdPushConstants(c, l, VK_SHADER_STAGE_FRAGMENT_BIT, 0, 16, red);
        vkCmdSetScissor(c, 0, 1, &left); vkCmdDraw(c, 3, 1, 0, 0);
        vkCmdSetScissor(c, 0, 1, &above); vkCmdDraw(c, 3, 1, 0, 0);
        vkCmdPushConstants(c, l, VK_SHADER_STAGE_FRAGMENT_BIT, 0, 16, green); vkCmdSetScissor(c, 0, 1, &box); vkCmdDraw(c, 3, 1, 0, 0);
        vkCmdEndRenderPass(c); to_buffer(c, i, VK_IMAGE_ASPECT_COLOR_BIT, 0, W, H, out.b); submit(c);
        CHECK(px(&out, W, 1, 1) == RGBA(0, 0, 255, 255) && px(&out, W, 20, 20) == RGBA(0, 0, 255, 255) && px(&out, W, 31, 2) == RGBA(0, 0, 255, 255) && px(&out, W, 6, 6) == RGBA(0, 255, 0, 255),
              "⑯ P1-22 剪裁整块在目标左外 / 上外：不出片元；界内一笔照画（实测 (1,1) %#x (20,20) %#x (31,2) %#x (6,6) %#x）", px(&out, W, 1, 1), px(&out, W, 20, 20), px(&out, W, 31, 2), px(&out, W, 6, 6));
    }
    // 等尺寸 Blit：源 8×8 像素 (x,y) = (10x, 10y, 0, 255)；目标先清蓝
    {
        VkImage a = img(VK_FORMAT_R8G8B8A8_UNORM, 8, 8, 1, VK_SAMPLE_COUNT_1_BIT, VK_IMAGE_USAGE_TRANSFER_DST_BIT | VK_IMAGE_USAGE_TRANSFER_SRC_BIT);
        VkImage b = img(VK_FORMAT_R8G8B8A8_UNORM, 8, 8, 1, VK_SAMPLE_COUNT_1_BIT, VK_IMAGE_USAGE_TRANSFER_DST_BIT | VK_IMAGE_USAGE_TRANSFER_SRC_BIT);
        Buf src = buf(8 * 8 * 4, VK_BUFFER_USAGE_TRANSFER_SRC_BIT), out = buf(8 * 8 * 4, VK_BUFFER_USAGE_TRANSFER_DST_BIT);
        for (uint32_t y = 0; y < 8; y++) for (uint32_t x = 0; x < 8; x++) { uint32_t v = RGBA(x * 10, y * 10, 0, 255); memcpy(src.p + (y * 8 + x) * 4, &v, 4); }
        VkCommandBuffer c = begin(VK_COMMAND_BUFFER_LEVEL_PRIMARY);
        VkBufferImageCopy up = {.imageSubresource = {VK_IMAGE_ASPECT_COLOR_BIT, 0, 0, 1}, .imageExtent = {8, 8, 1}}; vkCmdCopyBufferToImage(c, src.b, a, VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL, 1, &up);
        VkClearColorValue bl = {.float32 = {0, 0, 1, 1}}; VkImageSubresourceRange all = {VK_IMAGE_ASPECT_COLOR_BIT, 0, 1, 0, 1};
        vkCmdClearColorImage(c, b, VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL, &bl, 1, &all);
        VkImageBlit r[3] = {
            {{VK_IMAGE_ASPECT_COLOR_BIT, 0, 0, 1}, {{0, 0, 0}, {4, 4, 1}}, {VK_IMAGE_ASPECT_COLOR_BIT, 0, 0, 1}, {{-2, -2, 0}, {2, 2, 1}}},   // 目标越出左上：界内 2×2 = 源 (2..3, 2..3)
            {{VK_IMAGE_ASPECT_COLOR_BIT, 0, 0, 1}, {{-2, -2, 0}, {2, 2, 1}}, {VK_IMAGE_ASPECT_COLOR_BIT, 0, 0, 1}, {{4, 4, 0}, {8, 8, 1}}},    // 源越出左上：目标 (6..7) = 源 (0..1)
            {{VK_IMAGE_ASPECT_COLOR_BIT, 0, 0, 1}, {{5, 5, 0}, {7, 7, 1}}, {VK_IMAGE_ASPECT_COLOR_BIT, 0, 0, 1}, {{0, 5, 0}, {2, 7, 1}}}};    // 界内：整块拷（原路径）
        vkCmdBlitImage(c, a, VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL, b, VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL, 3, r, VK_FILTER_NEAREST);
        to_buffer(c, b, VK_IMAGE_ASPECT_COLOR_BIT, 0, 8, 8, out.b); submit(c);
        CHECK(px(&out, 8, 0, 0) == RGBA(20, 20, 0, 255) && px(&out, 8, 1, 1) == RGBA(30, 30, 0, 255) && px(&out, 8, 2, 2) == RGBA(0, 0, 255, 255) && px(&out, 8, 1, 3) == RGBA(0, 0, 255, 255),
              "⑯ P1-22 等尺寸 Blit 目标越出左上：(0,0)/(1,1) = 源 (2,2)/(3,3)，(2,2)/(1,3) 不动（实测 %#x %#x %#x %#x）", px(&out, 8, 0, 0), px(&out, 8, 1, 1), px(&out, 8, 2, 2), px(&out, 8, 1, 3));
        CHECK(px(&out, 8, 6, 6) == RGBA(0, 0, 0, 255) && px(&out, 8, 7, 7) == RGBA(10, 10, 0, 255), "⑯ P1-22 等尺寸 Blit 源越出左上：目标 (6,6)/(7,7) = 源 (0,0)/(1,1)（实测 %#x %#x）", px(&out, 8, 6, 6), px(&out, 8, 7, 7));
        CHECK(px(&out, 8, 0, 5) == RGBA(50, 50, 0, 255) && px(&out, 8, 1, 6) == RGBA(60, 60, 0, 255) && px(&out, 8, 2, 6) == RGBA(0, 0, 255, 255),
              "⑯ P1-22 等尺寸 Blit 界内照旧整块拷：(0,5)/(1,6) = 源 (5,5)/(6,6)、(2,6) 不动（实测 %#x %#x %#x）", px(&out, 8, 0, 5), px(&out, 8, 1, 6), px(&out, 8, 2, 6));
    }
    // 局部解析：4 倍采样 32×32 清青、(16,16) 起 16×16 画红；解析源 (14,14) 4×4 → 目标 (0,0)，源 (20,20) 2×2 → 目标 (10,10)；目标先清蓝，区域外不动
    {
        VkImage m = img(VK_FORMAT_R8G8B8A8_UNORM, W, H, 1, VK_SAMPLE_COUNT_4_BIT, VK_IMAGE_USAGE_COLOR_ATTACHMENT_BIT | VK_IMAGE_USAGE_TRANSFER_SRC_BIT);
        VkImage s = img(VK_FORMAT_R8G8B8A8_UNORM, W, H, 1, VK_SAMPLE_COUNT_1_BIT, VK_IMAGE_USAGE_TRANSFER_DST_BIT | VK_IMAGE_USAGE_TRANSFER_SRC_BIT);
        VkImageView mv = view(m, VK_FORMAT_R8G8B8A8_UNORM, VK_IMAGE_ASPECT_COLOR_BIT);
        VkRenderPass p = color_pass(VK_FORMAT_R8G8B8A8_UNORM, VK_ATTACHMENT_LOAD_OP_CLEAR, VK_SAMPLE_COUNT_4_BIT); VkFramebuffer f = framebuffer(p, 1, &mv, W, H);
        VkDynamicState dyn = VK_DYNAMIC_STATE_SCISSOR; VkPipelineLayout l = layout_of(0, NULL, 16, VK_SHADER_STAGE_FRAGMENT_BIT);
        VkPipeline pipe = gfx_pipe(p, 0, l, "color.frag", VK_SAMPLE_COUNT_4_BIT, NULL, 1, &dyn);
        Buf out = buf(W * H * 4, VK_BUFFER_USAGE_TRANSFER_DST_BIT);
        VkCommandBuffer c = begin(VK_COMMAND_BUFFER_LEVEL_PRIMARY); VkClearValue cyan = {.color.float32 = {0, 1, 1, 1}}; float red[4] = {1, 0, 0, 1};
        VkClearColorValue bl = {.float32 = {0, 0, 1, 1}}; VkImageSubresourceRange all = {VK_IMAGE_ASPECT_COLOR_BIT, 0, 1, 0, 1};
        vkCmdClearColorImage(c, s, VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL, &bl, 1, &all);
        begin_pass(c, p, f, 1, &cyan, VK_SUBPASS_CONTENTS_INLINE); vkCmdBindPipeline(c, VK_PIPELINE_BIND_POINT_GRAPHICS, pipe);
        VkRect2D q = {{16, 16}, {16, 16}}; vkCmdSetScissor(c, 0, 1, &q); vkCmdPushConstants(c, l, VK_SHADER_STAGE_FRAGMENT_BIT, 0, 16, red); vkCmdDraw(c, 3, 1, 0, 0);
        vkCmdEndRenderPass(c);
        VkImageResolve rr[2] = {{{VK_IMAGE_ASPECT_COLOR_BIT, 0, 0, 1}, {14, 14, 0}, {VK_IMAGE_ASPECT_COLOR_BIT, 0, 0, 1}, {0, 0, 0}, {4, 4, 1}},
                                {{VK_IMAGE_ASPECT_COLOR_BIT, 0, 0, 1}, {20, 20, 0}, {VK_IMAGE_ASPECT_COLOR_BIT, 0, 0, 1}, {10, 10, 0}, {2, 2, 1}}};
        vkCmdResolveImage(c, m, VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL, s, VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL, 2, rr);
        to_buffer(c, s, VK_IMAGE_ASPECT_COLOR_BIT, 0, W, H, out.b); submit(c);
        const uint32_t C = RGBA(0, 255, 255, 255), R = RGBA(255, 0, 0, 255), B = RGBA(0, 0, 255, 255);
        CHECK(px(&out, W, 0, 0) == C && px(&out, W, 1, 1) == C && px(&out, W, 2, 2) == R && px(&out, W, 3, 3) == R && px(&out, W, 4, 4) == B && px(&out, W, 0, 3) == C,
              "⑯ P1-22 局部解析：目标 (0,0)/(1,1) 青 = 源 (14,14)/(15,15)，(2,2)/(3,3) 红 = 源 (16,16)/(17,17)，(4,4) 不动（实测 %#x %#x %#x %#x %#x）",
              px(&out, W, 0, 0), px(&out, W, 1, 1), px(&out, W, 2, 2), px(&out, W, 3, 3), px(&out, W, 4, 4));
        CHECK(px(&out, W, 10, 10) == R && px(&out, W, 11, 11) == R && px(&out, W, 12, 12) == B && px(&out, W, 20, 20) == B && px(&out, W, 31, 31) == B,
              "⑯ P1-22 局部解析第二块落在 (10,10) 2×2，区域外 (12,12)/(20,20)/(31,31) 保持蓝（实测 %#x %#x %#x %#x %#x）",
              px(&out, W, 10, 10), px(&out, W, 11, 11), px(&out, W, 12, 12), px(&out, W, 20, 20), px(&out, W, 31, 31));
    }
    // 越界的填充 / 更新不编码（甲）：缓冲 256 字节、内存 256 字节；同一提交里界内的照写。界内但越出缓冲声明大小的（内存还够）照旧写（原行为不变）
    {
        Buf b = buf(256, VK_BUFFER_USAGE_TRANSFER_DST_BIT), b2 = buf(200, VK_BUFFER_USAGE_TRANSFER_DST_BIT);   // b2：声明 200 字节，内存按 256 对齐
        memset(b2.p, 0xcd, 256);
        VkCommandBuffer c = begin(VK_COMMAND_BUFFER_LEVEL_PRIMARY); uint8_t data[8] = {1, 2, 3, 4, 5, 6, 7, 8};
        vkCmdFillBuffer(c, b.b, 512, VK_WHOLE_SIZE, 0x11111111u);   // 偏移超出：其余全部 = 下溢
        vkCmdFillBuffer(c, b.b, 248, 16, 0x01020304u);              // 计算内核那条，越出 8 字节
        vkCmdFillBuffer(c, b.b, 244, 16, 0x22222222u);              // 拷贝编码器那条，越出 4 字节
        vkCmdUpdateBuffer(c, b.b, 252, 8, data);                    // 越出 4 字节
        vkCmdFillBuffer(c, b.b, 0, 16, 0x33333333u);                // 界内
        vkCmdFillBuffer(c, b2.b, 192, 16, 0x44444444u);             // 越出声明 200、在内存 256 内：原行为照写
        submit(c);
        int ok = 1; for (int i = 0; i < 16; i++) ok &= b.p[i] == 0x33;
        int untouched = 1; for (int i = 16; i < 256; i++) untouched &= b.p[i] == 0xcd;
        int ok2 = 1; for (int i = 192; i < 208; i++) ok2 &= b2.p[i] == 0x44;
        CHECK(ok && untouched, "⑯ P1-45 越出内存的填充 ×3 / 更新 ×1 不编码、同提交界内填充照写（实测 [0]=%#x [244]=%#x [248]=%#x [252]=%#x）", b.p[0], b.p[244], b.p[248], b.p[252]);
        CHECK(ok2 && b2.p[208] == 0xcd, "⑯ P1-45 越出缓冲声明大小但在内存内的填充照旧写（实测 [192]=%#x [207]=%#x [208]=%#x）", b2.p[192], b2.p[207], b2.p[208]);
    }
    // 清图像越出层数（甲）：2 层图像清第 1 层起 3 层 → 只清到第 1 层
    {
        VkImage i = img(VK_FORMAT_R8G8B8A8_UNORM, 8, 8, 2, VK_SAMPLE_COUNT_1_BIT, VK_IMAGE_USAGE_TRANSFER_DST_BIT | VK_IMAGE_USAGE_TRANSFER_SRC_BIT);
        Buf l0 = buf(8 * 8 * 4, VK_BUFFER_USAGE_TRANSFER_DST_BIT), l1 = buf(8 * 8 * 4, VK_BUFFER_USAGE_TRANSFER_DST_BIT);
        VkCommandBuffer c = begin(VK_COMMAND_BUFFER_LEVEL_PRIMARY);
        VkClearColorValue bl = {.float32 = {0, 0, 1, 1}}, red = {.float32 = {1, 0, 0, 1}};
        VkImageSubresourceRange all = {VK_IMAGE_ASPECT_COLOR_BIT, 0, 1, 0, 2}, over = {VK_IMAGE_ASPECT_COLOR_BIT, 0, 1, 1, 3};
        vkCmdClearColorImage(c, i, VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL, &bl, 1, &all); vkCmdClearColorImage(c, i, VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL, &red, 1, &over);
        to_buffer(c, i, VK_IMAGE_ASPECT_COLOR_BIT, 0, 8, 8, l0.b); to_buffer(c, i, VK_IMAGE_ASPECT_COLOR_BIT, 1, 8, 8, l1.b); submit(c);
        CHECK(px(&l0, 8, 3, 3) == RGBA(0, 0, 255, 255) && px(&l1, 8, 3, 3) == RGBA(255, 0, 0, 255), "⑯ P1-45 清图像层数越界：第 0 层蓝、第 1 层红（实测 %#x / %#x）", px(&l0, 8, 3, 3), px(&l1, 8, 3, 3));
    }
    // P1-45 映射越界：回 VK_ERROR_MEMORY_MAP_FAILED（vkMapMemory 唯一的映射失败码）；界内 / 类型 0 照旧成功（类型 0 只计数，乙类）
    {
        uint64_t t0 = dm_vk_ok_but_bad(K_MAP_TYPE0);
        VkMemoryAllocateInfo ai = {.sType = VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO, .allocationSize = 256, .memoryTypeIndex = 1}; VkDeviceMemory mm, m0; OK(vkAllocateMemory(device, &ai, NULL, &mm));
        ai.memoryTypeIndex = 0; OK(vkAllocateMemory(device, &ai, NULL, &m0));
        void *pp; VkResult a1 = vkMapMemory(device, mm, 512, VK_WHOLE_SIZE, 0, &pp), a2 = vkMapMemory(device, mm, 0, 512, 0, &pp), a5 = vkMapMemory(device, mm, 16, 0, 0, &pp);   // 偏移出界 / 大小出界 / 大小 0
        VkResult a3 = vkMapMemory(device, mm, 0, 256, 0, &pp), a6 = vkMapMemory(device, mm, 255, VK_WHOLE_SIZE, 0, &pp), a4 = vkMapMemory(device, m0, 0, 256, 0, &pp);
        CHECK(a1 == VK_ERROR_MEMORY_MAP_FAILED && a2 == VK_ERROR_MEMORY_MAP_FAILED && a5 == VK_ERROR_MEMORY_MAP_FAILED && !a3 && !a6 && !a4 && dm_vk_ok_but_bad(K_MAP_TYPE0) - t0 == 1,
              "⑯ P1-45 映射越界 ×3 回映射失败（%d %d %d，期望 %d）、界内 ×2 / 类型 0 回成功（%d %d %d）、类型 0 计数 +%llu（期望 +1）", a1, a2, a5, VK_ERROR_MEMORY_MAP_FAILED, a3, a6, a4,
              (unsigned long long)(dm_vk_ok_but_bad(K_MAP_TYPE0) - t0));
    }
    // P1-46 建不成的管线：回失败码（< 0），那一项交 VK_NULL_HANDLE；同一批里建得成的照交（§10.1 / §9.x：实现尽量建全部，失败的才填空）
    {
        VkRenderPass p = color_pass(VK_FORMAT_R8G8B8A8_UNORM, VK_ATTACHMENT_LOAD_OP_CLEAR, VK_SAMPLE_COUNT_1_BIT); VkPipelineLayout l = layout_of(0, NULL, 16, VK_SHADER_STAGE_FRAGMENT_BIT);
        VkPipelineShaderStageCreateInfo fs = {.sType = VK_STRUCTURE_TYPE_PIPELINE_SHADER_STAGE_CREATE_INFO, .stage = VK_SHADER_STAGE_FRAGMENT_BIT, .module = shader("color.frag"), .pName = "main"};
        VkGraphicsPipelineCreateInfo gci = {.sType = VK_STRUCTURE_TYPE_GRAPHICS_PIPELINE_CREATE_INFO, .stageCount = 1, .pStages = &fs, .layout = l, .renderPass = p};   // 没有顶点着色器
        VkPipeline gp = (VkPipeline)(uintptr_t)1; VkResult e1 = vkCreateGraphicsPipelines(device, VK_NULL_HANDLE, 1, &gci, NULL, &gp);
        VkComputePipelineCreateInfo cci[2] = {{.sType = VK_STRUCTURE_TYPE_COMPUTE_PIPELINE_CREATE_INFO, .stage = {.sType = VK_STRUCTURE_TYPE_PIPELINE_SHADER_STAGE_CREATE_INFO,
            .stage = VK_SHADER_STAGE_COMPUTE_BIT, .module = shader("tri.vert"), .pName = "main"}, .layout = l},   // 不是计算着色器
            {.sType = VK_STRUCTURE_TYPE_COMPUTE_PIPELINE_CREATE_INFO, .stage = {.sType = VK_STRUCTURE_TYPE_PIPELINE_SHADER_STAGE_CREATE_INFO,
            .stage = VK_SHADER_STAGE_COMPUTE_BIT, .module = shader("fill.comp"), .pName = "main"}, .layout = l}};   // 建得成
        VkPipeline cp[2] = {(VkPipeline)(uintptr_t)1, VK_NULL_HANDLE}; VkResult e2 = vkCreateComputePipelines(device, VK_NULL_HANDLE, 2, cci, NULL, cp);
        CHECK(e1 < 0 && e2 < 0 && gp == VK_NULL_HANDLE && cp[0] == VK_NULL_HANDLE && cp[1] != VK_NULL_HANDLE,
              "⑯ P1-46 建不成的图形 / 计算管线回失败码（%d %d，期望 < 0）、那一项交空句柄（%p %p）、同批建得成的照交（%p）", e1, e2, (void *)gp, (void *)cp[0], (void *)cp[1]);
        uint64_t f0 = dm_vk_ok_but_bad(K_FEAT_ROBUST), s0 = dm_vk_ok_but_bad(K_FEAT_SSR);
        float pr = 1; VkDeviceQueueCreateInfo qi = {.sType = VK_STRUCTURE_TYPE_DEVICE_QUEUE_CREATE_INFO, .queueCount = 1, .pQueuePriorities = &pr};
        VkPhysicalDeviceFeatures fe = {.robustBufferAccess = 1, .sampleRateShading = 1};
        VkPhysicalDeviceFeatures2 f2 = {.sType = VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_FEATURES_2, .features = {.robustBufferAccess = 1}};
        VkDeviceCreateInfo di = {.sType = VK_STRUCTURE_TYPE_DEVICE_CREATE_INFO, .queueCreateInfoCount = 1, .pQueueCreateInfos = &qi, .pEnabledFeatures = &fe}; VkDevice d1, d2;
        VkResult h1 = vkCreateDevice(physical, &di, NULL, &d1); di.pEnabledFeatures = NULL; di.pNext = &f2; VkResult h2 = vkCreateDevice(physical, &di, NULL, &d2);
        CHECK(!h1 && !h2 && dm_vk_ok_but_bad(K_FEAT_ROBUST) - f0 == 2 && dm_vk_ok_but_bad(K_FEAT_SSR) - s0 == 1,
              "⑯ P2-3 打开 robustBufferAccess（1.0 结构 + Features2）/ sampleRateShading：照旧成功（%d %d）、计数 +%llu / +%llu（期望 +2 / +1）", h1, h2,
              (unsigned long long)(dm_vk_ok_but_bad(K_FEAT_ROBUST) - f0), (unsigned long long)(dm_vk_ok_but_bad(K_FEAT_SSR) - s0));
        uint64_t x0 = dm_vk_ok_but_bad(K_PRESENT_IDX);
        VkSwapchainCreateInfoKHR sci = {.sType = VK_STRUCTURE_TYPE_SWAPCHAIN_CREATE_INFO_KHR, .minImageCount = 2, .imageFormat = VK_FORMAT_B8G8R8A8_UNORM, .imageExtent = {64, 64},
            .imageArrayLayers = 1, .imageUsage = VK_IMAGE_USAGE_COLOR_ATTACHMENT_BIT, .presentMode = VK_PRESENT_MODE_FIFO_KHR};
        VkSwapchainKHR sc; OK(vkCreateSwapchainKHR(device, &sci, NULL, &sc));
        uint32_t idx = 5; VkResult pres = VK_ERROR_UNKNOWN;
        VkPresentInfoKHR pi = {.sType = VK_STRUCTURE_TYPE_PRESENT_INFO_KHR, .swapchainCount = 1, .pSwapchains = &sc, .pImageIndices = &idx, .pResults = &pres};
        VkResult pr1 = vkQueuePresentKHR(queue, &pi);
        CHECK(!pr1 && !pres && dm_vk_ok_but_bad(K_PRESENT_IDX) - x0 == 1, "⑯ P2-4 呈现下标 5 越出 2 张交换链：照旧回成功（%d / 结果 %d）、计数 +%llu（期望 +1）", pr1, pres,
              (unsigned long long)(dm_vk_ok_but_bad(K_PRESENT_IDX) - x0));
        VkImage i = img(VK_FORMAT_R8G8B8A8_UNORM, 8, 8, 2, VK_SAMPLE_COUNT_1_BIT, VK_IMAGE_USAGE_SAMPLED_BIT);
        VkImageViewCreateInfo vi = {.sType = VK_STRUCTURE_TYPE_IMAGE_VIEW_CREATE_INFO, .image = i, .viewType = VK_IMAGE_VIEW_TYPE_2D_ARRAY, .format = VK_FORMAT_R8G8B8A8_UNORM,
            .subresourceRange = {VK_IMAGE_ASPECT_COLOR_BIT, 1, VK_REMAINING_MIP_LEVELS, 0, 2}};   // 起始级别 1 / 共 1 级：其余级别 = 下溢
        VkImageView v1 = (VkImageView)(uintptr_t)1, v2 = (VkImageView)(uintptr_t)1, v3 = VK_NULL_HANDLE; VkResult b1 = vkCreateImageView(device, &vi, NULL, &v1);
        vi.subresourceRange = (VkImageSubresourceRange){VK_IMAGE_ASPECT_COLOR_BIT, 0, 1, 1, 2}; VkResult b2 = vkCreateImageView(device, &vi, NULL, &v2);   // 层 1+2 / 共 2 层
        vi.subresourceRange = (VkImageSubresourceRange){VK_IMAGE_ASPECT_COLOR_BIT, 0, 1, 1, 1}; vi.viewType = VK_IMAGE_VIEW_TYPE_2D; VkResult b3 = vkCreateImageView(device, &vi, NULL, &v3);   // 界内
        CHECK(b1 < 0 && b2 < 0 && !v1 && !v2 && !b3 && v3, "⑯ P1-45 图像视图范围越界 ×2 回失败码（%d %d，期望 < 0）、交空句柄（%p %p）；界内 ×1 成功（%d %p）", b1, b2, (void *)v1, (void *)v2, b3, (void *)v3);
        // 缓冲视图：缓冲 256 字节、RGBA8（4 字节一像素）。偏移出界 / 偏移 + 范围出界 → 失败码 + 空句柄；整段 / 界内一段 → 成功（§11.2：offset < size、offset + range ≤ size）
        Buf tb = buf(256, VK_BUFFER_USAGE_UNIFORM_TEXEL_BUFFER_BIT);
        VkBufferViewCreateInfo bv = {.sType = VK_STRUCTURE_TYPE_BUFFER_VIEW_CREATE_INFO, .buffer = tb.b, .format = VK_FORMAT_R8G8B8A8_UNORM, .offset = 256, .range = VK_WHOLE_SIZE};
        VkBufferView w1 = (VkBufferView)(uintptr_t)1, w2 = (VkBufferView)(uintptr_t)1, w3 = VK_NULL_HANDLE, w4 = VK_NULL_HANDLE; VkResult c1 = vkCreateBufferView(device, &bv, NULL, &w1);
        bv.offset = 0; bv.range = 512; VkResult c2 = vkCreateBufferView(device, &bv, NULL, &w2);
        bv.range = VK_WHOLE_SIZE; VkResult c3 = vkCreateBufferView(device, &bv, NULL, &w3);
        bv.offset = 128; bv.range = 128; VkResult c4 = vkCreateBufferView(device, &bv, NULL, &w4);
        CHECK(c1 < 0 && c2 < 0 && !w1 && !w2 && !c3 && !c4 && w3 && w4, "⑯ P1-45 缓冲视图越界 ×2 回失败码（%d %d）、交空句柄（%p %p）；整段 / 界内 ×2 成功（%d %d）", c1, c2, (void *)w1, (void *)w2, c3, c4);
    }
    // P1-68 缓冲对缓冲拷贝：源 / 目标各 256 字节（内存 256）。界内 16 字节照拷；源越出、目标越出的两条不编码（目标保持 0xcd）
    {
        Buf a = buf(256, VK_BUFFER_USAGE_TRANSFER_SRC_BIT), b = buf(256, VK_BUFFER_USAGE_TRANSFER_DST_BIT);
        for (int k = 0; k < 256; k++) a.p[k] = (uint8_t)k;
        VkBufferCopy r[3] = {{0, 0, 16}, {248, 32, 16}, {0, 250, 16}};
        VkCommandBuffer c = begin(VK_COMMAND_BUFFER_LEVEL_PRIMARY); vkCmdCopyBuffer(c, a.b, b.b, 3, r); submit(c);
        int ok = 1; for (int k = 0; k < 16; k++) ok &= b.p[k] == k;
        int keep = 1; for (int k = 32; k < 48; k++) keep &= b.p[k] == 0xcd;
        for (int k = 250; k < 256; k++) keep &= b.p[k] == 0xcd;
        CHECK(ok && keep, "⑯ P1-68 缓冲拷贝：界内照拷（[15]=%#x）、源越出 / 目标越出不编码（[32]=%#x [250]=%#x，期望 0xcd）", b.p[15], b.p[32], b.p[250]);
    }
    // P1-68 缓冲到图像 / 图像到缓冲：8×8 RGBA8，缓冲 256 字节 = 整张。图像先清蓝；负原点、矩形出图、缓冲读出界的三条不编码，界内 4×4 照拷
    {
        VkImage i = img(VK_FORMAT_R8G8B8A8_UNORM, 8, 8, 1, VK_SAMPLE_COUNT_1_BIT, VK_IMAGE_USAGE_TRANSFER_DST_BIT | VK_IMAGE_USAGE_TRANSFER_SRC_BIT);
        Buf src = buf(256, VK_BUFFER_USAGE_TRANSFER_SRC_BIT), out = buf(256, VK_BUFFER_USAGE_TRANSFER_DST_BIT), rb = buf(256, VK_BUFFER_USAGE_TRANSFER_DST_BIT);
        for (uint32_t y = 0; y < 8; y++) for (uint32_t x = 0; x < 8; x++) { uint32_t v = RGBA(x * 10, y * 10, 0, 255); memcpy(src.p + (y * 8 + x) * 4, &v, 4); }
        VkCommandBuffer c = begin(VK_COMMAND_BUFFER_LEVEL_PRIMARY);
        VkClearColorValue bl = {.float32 = {0, 0, 1, 1}}; VkImageSubresourceRange all = {VK_IMAGE_ASPECT_COLOR_BIT, 0, 1, 0, 1};
        vkCmdClearColorImage(c, i, VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL, &bl, 1, &all);
        VkBufferImageCopy up[4] = {
            {.bufferRowLength = 8, .imageSubresource = {VK_IMAGE_ASPECT_COLOR_BIT, 0, 0, 1}, .imageOffset = {-2, 0, 0}, .imageExtent = {4, 4, 1}},   // 负原点
            {.bufferRowLength = 8, .imageSubresource = {VK_IMAGE_ASPECT_COLOR_BIT, 0, 0, 1}, .imageOffset = {6, 6, 0}, .imageExtent = {4, 4, 1}},    // 矩形出图
            {.bufferOffset = 128, .imageSubresource = {VK_IMAGE_ASPECT_COLOR_BIT, 0, 0, 1}, .imageOffset = {0, 4, 0}, .imageExtent = {8, 8, 1}},   // 缓冲读 128 + 256 出界（目标也出图）
            {.bufferRowLength = 8, .imageSubresource = {VK_IMAGE_ASPECT_COLOR_BIT, 0, 0, 1}, .imageExtent = {4, 4, 1}}};                          // 界内
        vkCmdCopyBufferToImage(c, src.b, i, VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL, 4, up);
        to_buffer(c, i, VK_IMAGE_ASPECT_COLOR_BIT, 0, 8, 8, out.b);
        VkBufferImageCopy dn[2] = {{.bufferOffset = 224, .imageSubresource = {VK_IMAGE_ASPECT_COLOR_BIT, 0, 0, 1}, .imageExtent = {4, 4, 1}},   // 写 224 + 64 出 256 字节内存
                                   {.imageSubresource = {VK_IMAGE_ASPECT_COLOR_BIT, 0, 0, 1}, .imageOffset = {2, 2, 0}, .imageExtent = {4, 4, 1}}};   // 界内 4×4 = 64 字节
        vkCmdCopyImageToBuffer(c, i, VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL, rb.b, 2, dn); submit(c);
        const uint32_t B = RGBA(0, 0, 255, 255);
        CHECK(px(&out, 8, 0, 0) == RGBA(0, 0, 0, 255) && px(&out, 8, 3, 3) == RGBA(30, 30, 0, 255) && px(&out, 8, 4, 4) == B && px(&out, 8, 7, 7) == B && px(&out, 8, 6, 6) == B && px(&out, 8, 0, 4) == B,
              "⑯ P1-68 缓冲到图像：界内 4×4 照拷（(3,3) %#x）、负原点 / 出图 / 缓冲出界三条不编码（(4,4) %#x (7,7) %#x (0,4) %#x，期望蓝）",
              px(&out, 8, 3, 3), px(&out, 8, 4, 4), px(&out, 8, 7, 7), px(&out, 8, 0, 4));
        CHECK(px(&rb, 4, 0, 0) == RGBA(20, 20, 0, 255) && px(&rb, 4, 2, 2) == B && rb.p[224] == 0xcd && rb.p[255] == 0xcd,
              "⑯ P1-68 图像到缓冲：界内照读（(0,0) %#x 期望源 (2,2)；(2,2) %#x 期望蓝）、缓冲出界那条不编码（[224] %#x [255] %#x 期望 0xcd）", px(&rb, 4, 0, 0), px(&rb, 4, 2, 2), rb.p[224], rb.p[255]);
    }
    // P1-68 等尺寸图像拷贝：源 8×8 (x,y) = (10x, 10y, 0, 255)，目标先清蓝。矩形夹进两边（同 Blit 等尺寸 clamp_span），夹空不编码
    {
        VkImage a = img(VK_FORMAT_R8G8B8A8_UNORM, 8, 8, 1, VK_SAMPLE_COUNT_1_BIT, VK_IMAGE_USAGE_TRANSFER_DST_BIT | VK_IMAGE_USAGE_TRANSFER_SRC_BIT);
        VkImage b = img(VK_FORMAT_R8G8B8A8_UNORM, 8, 8, 1, VK_SAMPLE_COUNT_1_BIT, VK_IMAGE_USAGE_TRANSFER_DST_BIT | VK_IMAGE_USAGE_TRANSFER_SRC_BIT);
        Buf src = buf(256, VK_BUFFER_USAGE_TRANSFER_SRC_BIT), out = buf(256, VK_BUFFER_USAGE_TRANSFER_DST_BIT);
        for (uint32_t y = 0; y < 8; y++) for (uint32_t x = 0; x < 8; x++) { uint32_t v = RGBA(x * 10, y * 10, 0, 255); memcpy(src.p + (y * 8 + x) * 4, &v, 4); }
        VkCommandBuffer c = begin(VK_COMMAND_BUFFER_LEVEL_PRIMARY);
        VkBufferImageCopy up = {.imageSubresource = {VK_IMAGE_ASPECT_COLOR_BIT, 0, 0, 1}, .imageExtent = {8, 8, 1}}; vkCmdCopyBufferToImage(c, src.b, a, VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL, 1, &up);
        VkClearColorValue bl = {.float32 = {0, 0, 1, 1}}; VkImageSubresourceRange all = {VK_IMAGE_ASPECT_COLOR_BIT, 0, 1, 0, 1};
        vkCmdClearColorImage(c, b, VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL, &bl, 1, &all);
        VkImageSubresourceLayers L = {VK_IMAGE_ASPECT_COLOR_BIT, 0, 0, 1};
        VkImageCopy r[4] = {{L, {-2, -2, 0}, L, {0, 0, 0}, {4, 4, 1}},    // 源越出左上：夹成源 (0,0) 2×2 → 目标 (2,2)
                            {L, {0, 6, 0}, L, {6, 0, 0}, {4, 4, 1}},      // 源 / 目标越出右下：夹成 2×2，源 (0,6) → 目标 (6,0)
                            {L, {0, 0, 0}, L, {8, 0, 0}, {2, 2, 1}},      // 目标整块在外：夹空，不编码
                            {L, {5, 5, 0}, L, {0, 6, 0}, {2, 2, 1}}};     // 界内：整块拷
        vkCmdCopyImage(c, a, VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL, b, VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL, 4, r);
        to_buffer(c, b, VK_IMAGE_ASPECT_COLOR_BIT, 0, 8, 8, out.b); submit(c);
        const uint32_t B = RGBA(0, 0, 255, 255);
        CHECK(px(&out, 8, 2, 2) == RGBA(0, 0, 0, 255) && px(&out, 8, 3, 3) == RGBA(10, 10, 0, 255) && px(&out, 8, 1, 1) == B && px(&out, 8, 4, 4) == B,
              "⑯ P1-68 等尺寸图像拷贝源越出左上：目标 (2,2)/(3,3) = 源 (0,0)/(1,1)，(1,1)/(4,4) 不动（实测 %#x %#x %#x %#x）", px(&out, 8, 2, 2), px(&out, 8, 3, 3), px(&out, 8, 1, 1), px(&out, 8, 4, 4));
        CHECK(px(&out, 8, 6, 0) == RGBA(0, 60, 0, 255) && px(&out, 8, 7, 1) == RGBA(10, 70, 0, 255) && px(&out, 8, 5, 0) == B,
              "⑯ P1-68 等尺寸图像拷贝越出右下：目标 (6,0)/(7,1) = 源 (0,6)/(1,7)，(5,0) 不动（实测 %#x %#x %#x）", px(&out, 8, 6, 0), px(&out, 8, 7, 1), px(&out, 8, 5, 0));
        CHECK(px(&out, 8, 0, 6) == RGBA(50, 50, 0, 255) && px(&out, 8, 1, 7) == RGBA(60, 60, 0, 255) && px(&out, 8, 0, 0) == B,
              "⑯ P1-68 等尺寸图像拷贝界内照旧整块拷：(0,6)/(1,7) = 源 (5,5)/(6,6)，(0,0) 不动（实测 %#x %#x %#x）", px(&out, 8, 0, 6), px(&out, 8, 1, 7), px(&out, 8, 0, 0));
    }
    // P1-69 renderArea 小于帧缓冲（§7.4：加载 / 存储 / 解析只作用于区域内的像素）：图像先清蓝；
    //   ① 加载 = 清红、区域 (8,8) 8×8：区域内红、区域外仍蓝；② 加载 = 不在乎、区域 (0,0) 16×16，区域内剪裁画绿：区域内绿、区域外仍是 ① 的结果
    {
        VkImage i = img(VK_FORMAT_R8G8B8A8_UNORM, W, H, 1, VK_SAMPLE_COUNT_1_BIT, VK_IMAGE_USAGE_COLOR_ATTACHMENT_BIT | VK_IMAGE_USAGE_TRANSFER_SRC_BIT | VK_IMAGE_USAGE_TRANSFER_DST_BIT);
        VkImageView v = view(i, VK_FORMAT_R8G8B8A8_UNORM, VK_IMAGE_ASPECT_COLOR_BIT);
        VkRenderPass pc = color_pass(VK_FORMAT_R8G8B8A8_UNORM, VK_ATTACHMENT_LOAD_OP_CLEAR, VK_SAMPLE_COUNT_1_BIT), pd = color_pass(VK_FORMAT_R8G8B8A8_UNORM, VK_ATTACHMENT_LOAD_OP_DONT_CARE, VK_SAMPLE_COUNT_1_BIT);
        VkFramebuffer fc = framebuffer(pc, 1, &v, W, H), fd = framebuffer(pd, 1, &v, W, H);
        VkDynamicState dyn = VK_DYNAMIC_STATE_SCISSOR; VkPipelineLayout l = layout_of(0, NULL, 16, VK_SHADER_STAGE_FRAGMENT_BIT);
        VkPipeline pipe = gfx_pipe(pd, 0, l, "color.frag", VK_SAMPLE_COUNT_1_BIT, NULL, 1, &dyn);
        Buf out = buf(W * H * 4, VK_BUFFER_USAGE_TRANSFER_DST_BIT), out2 = buf(W * H * 4, VK_BUFFER_USAGE_TRANSFER_DST_BIT);
        VkCommandBuffer c = begin(VK_COMMAND_BUFFER_LEVEL_PRIMARY);
        VkClearColorValue bl = {.float32 = {0, 0, 1, 1}}; VkImageSubresourceRange all = {VK_IMAGE_ASPECT_COLOR_BIT, 0, 1, 0, 1};
        vkCmdClearColorImage(c, i, VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL, &bl, 1, &all);
        VkClearValue red = {.color.float32 = {1, 0, 0, 1}};
        VkRenderPassBeginInfo bi = {.sType = VK_STRUCTURE_TYPE_RENDER_PASS_BEGIN_INFO, .renderPass = pc, .framebuffer = fc, .renderArea = {{8, 8}, {8, 8}}, .clearValueCount = 1, .pClearValues = &red};
        vkCmdBeginRenderPass(c, &bi, VK_SUBPASS_CONTENTS_INLINE); vkCmdEndRenderPass(c);
        to_buffer(c, i, VK_IMAGE_ASPECT_COLOR_BIT, 0, W, H, out.b);
        bi.renderPass = pd; bi.framebuffer = fd; bi.renderArea = (VkRect2D){{0, 0}, {16, 16}}; bi.clearValueCount = 0; bi.pClearValues = NULL;
        vkCmdBeginRenderPass(c, &bi, VK_SUBPASS_CONTENTS_INLINE); vkCmdBindPipeline(c, VK_PIPELINE_BIND_POINT_GRAPHICS, pipe);
        float green[4] = {0, 1, 0, 1}; VkRect2D sc = {{0, 0}, {16, 16}}; vkCmdSetScissor(c, 0, 1, &sc);
        vkCmdPushConstants(c, l, VK_SHADER_STAGE_FRAGMENT_BIT, 0, 16, green); vkCmdDraw(c, 3, 1, 0, 0); vkCmdEndRenderPass(c);
        to_buffer(c, i, VK_IMAGE_ASPECT_COLOR_BIT, 0, W, H, out2.b); submit(c);
        const uint32_t R = RGBA(255, 0, 0, 255), B = RGBA(0, 0, 255, 255), G = RGBA(0, 255, 0, 255);
        CHECK(px(&out, W, 8, 8) == R && px(&out, W, 15, 15) == R && px(&out, W, 7, 7) == B && px(&out, W, 16, 16) == B && px(&out, W, 1, 1) == B && px(&out, W, 30, 30) == B,
              "⑯ P1-69 加载清屏只清 renderArea：(8,8)/(15,15) 红，(7,7)/(16,16)/(1,1)/(30,30) 仍蓝（实测 %#x %#x %#x %#x %#x %#x）",
              px(&out, W, 8, 8), px(&out, W, 15, 15), px(&out, W, 7, 7), px(&out, W, 16, 16), px(&out, W, 1, 1), px(&out, W, 30, 30));
        CHECK(px(&out2, W, 1, 1) == G && px(&out2, W, 15, 15) == G && px(&out2, W, 16, 16) == B && px(&out2, W, 20, 10) == B && px(&out2, W, 30, 30) == B,
              "⑯ P1-69 加载不在乎：区域外保留原内容（(16,16)/(20,10)/(30,30) %#x %#x %#x 期望蓝），区域内照画（(1,1)/(15,15) %#x %#x 期望绿）",
              px(&out2, W, 16, 16), px(&out2, W, 20, 10), px(&out2, W, 30, 30), px(&out2, W, 1, 1), px(&out2, W, 15, 15));
    }
    // P1-69 续（审计 #1565）：解析与绘制也只动 renderArea 内。单采样图像 s 先清蓝；4× 多重采样图像 m 先整遍清绿（区域盖满、不解析）；
    //   ③ 子遍 m（加载 = 清红）解析进 s、区域 (8,8) 8×8：s 区域内红（解析结果）、区域外仍蓝（Metal 整张解析会把区域外写成 m 的绿）；
    //   ④ 加载 = 加载、区域 (8,8) 8×8、剪裁整张 (0,0) 32×32 画全屏绿：区域内绿、区域外仍蓝（不按区域夹会整张画绿）
    {
        const VkFormat F = VK_FORMAT_R8G8B8A8_UNORM; const VkImageUsageFlags U = VK_IMAGE_USAGE_COLOR_ATTACHMENT_BIT | VK_IMAGE_USAGE_TRANSFER_SRC_BIT | VK_IMAGE_USAGE_TRANSFER_DST_BIT;
        VkImage m = img(F, W, H, 1, VK_SAMPLE_COUNT_4_BIT, U), si = img(F, W, H, 1, VK_SAMPLE_COUNT_1_BIT, U), di = img(F, W, H, 1, VK_SAMPLE_COUNT_1_BIT, U);
        VkImageView mv = view(m, F, VK_IMAGE_ASPECT_COLOR_BIT), sv = view(si, F, VK_IMAGE_ASPECT_COLOR_BIT), dv = view(di, F, VK_IMAGE_ASPECT_COLOR_BIT);
        VkAttachmentDescription at[2] = {{.format = F, .samples = VK_SAMPLE_COUNT_4_BIT, .loadOp = VK_ATTACHMENT_LOAD_OP_CLEAR, .storeOp = VK_ATTACHMENT_STORE_OP_DONT_CARE,
                                          .stencilLoadOp = VK_ATTACHMENT_LOAD_OP_DONT_CARE, .stencilStoreOp = VK_ATTACHMENT_STORE_OP_DONT_CARE, .finalLayout = VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL},
                                         {.format = F, .samples = VK_SAMPLE_COUNT_1_BIT, .loadOp = VK_ATTACHMENT_LOAD_OP_DONT_CARE, .storeOp = VK_ATTACHMENT_STORE_OP_STORE,
                                          .stencilLoadOp = VK_ATTACHMENT_LOAD_OP_DONT_CARE, .stencilStoreOp = VK_ATTACHMENT_STORE_OP_DONT_CARE, .finalLayout = VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL}};
        VkAttachmentReference cr = {0, VK_IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL}, rr = {1, VK_IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL};
        VkSubpassDescription sd = {.pipelineBindPoint = VK_PIPELINE_BIND_POINT_GRAPHICS, .colorAttachmentCount = 1, .pColorAttachments = &cr, .pResolveAttachments = &rr};
        VkRenderPassCreateInfo rci = {.sType = VK_STRUCTURE_TYPE_RENDER_PASS_CREATE_INFO, .attachmentCount = 2, .pAttachments = at, .subpassCount = 1, .pSubpasses = &sd};
        VkRenderPass pr; OK(vkCreateRenderPass(device, &rci, NULL, &pr));
        VkImageView mvs[2] = {mv, sv}; VkFramebuffer fr = framebuffer(pr, 2, mvs, W, H);
        VkRenderPass pm = color_pass(F, VK_ATTACHMENT_LOAD_OP_CLEAR, VK_SAMPLE_COUNT_4_BIT); VkFramebuffer fm = framebuffer(pm, 1, &mv, W, H);
        VkRenderPass pl = color_pass(F, VK_ATTACHMENT_LOAD_OP_LOAD, VK_SAMPLE_COUNT_1_BIT); VkFramebuffer fl = framebuffer(pl, 1, &dv, W, H);
        VkDynamicState dyn = VK_DYNAMIC_STATE_SCISSOR; VkPipelineLayout l = layout_of(0, NULL, 16, VK_SHADER_STAGE_FRAGMENT_BIT);
        VkPipeline pipe = gfx_pipe(pl, 0, l, "color.frag", VK_SAMPLE_COUNT_1_BIT, NULL, 1, &dyn);
        Buf o3 = buf(W * H * 4, VK_BUFFER_USAGE_TRANSFER_DST_BIT), o4 = buf(W * H * 4, VK_BUFFER_USAGE_TRANSFER_DST_BIT);
        VkCommandBuffer c = begin(VK_COMMAND_BUFFER_LEVEL_PRIMARY);
        VkClearColorValue bl = {.float32 = {0, 0, 1, 1}}; VkImageSubresourceRange all = {VK_IMAGE_ASPECT_COLOR_BIT, 0, 1, 0, 1};
        vkCmdClearColorImage(c, si, VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL, &bl, 1, &all); vkCmdClearColorImage(c, di, VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL, &bl, 1, &all);
        VkClearValue gr = {.color.float32 = {0, 1, 0, 1}}, rd[2] = {{.color.float32 = {1, 0, 0, 1}}, {.color.float32 = {0, 0, 0, 0}}};
        begin_pass(c, pm, fm, 1, &gr, VK_SUBPASS_CONTENTS_INLINE); vkCmdEndRenderPass(c);
        VkRenderPassBeginInfo bi = {.sType = VK_STRUCTURE_TYPE_RENDER_PASS_BEGIN_INFO, .renderPass = pr, .framebuffer = fr, .renderArea = {{8, 8}, {8, 8}}, .clearValueCount = 2, .pClearValues = rd};
        vkCmdBeginRenderPass(c, &bi, VK_SUBPASS_CONTENTS_INLINE); vkCmdEndRenderPass(c);
        to_buffer(c, si, VK_IMAGE_ASPECT_COLOR_BIT, 0, W, H, o3.b);
        bi.renderPass = pl; bi.framebuffer = fl; bi.clearValueCount = 0; bi.pClearValues = NULL;
        vkCmdBeginRenderPass(c, &bi, VK_SUBPASS_CONTENTS_INLINE); vkCmdBindPipeline(c, VK_PIPELINE_BIND_POINT_GRAPHICS, pipe);
        float green[4] = {0, 1, 0, 1}; VkRect2D sc = {{0, 0}, {W, H}}; vkCmdSetScissor(c, 0, 1, &sc);
        vkCmdPushConstants(c, l, VK_SHADER_STAGE_FRAGMENT_BIT, 0, 16, green); vkCmdDraw(c, 3, 1, 0, 0); vkCmdEndRenderPass(c);
        to_buffer(c, di, VK_IMAGE_ASPECT_COLOR_BIT, 0, W, H, o4.b); submit(c);
        const uint32_t R = RGBA(255, 0, 0, 255), B = RGBA(0, 0, 255, 255), G = RGBA(0, 255, 0, 255);
        CHECK(px(&o3, W, 8, 8) == R && px(&o3, W, 15, 15) == R && px(&o3, W, 7, 7) == B && px(&o3, W, 16, 16) == B && px(&o3, W, 1, 1) == B && px(&o3, W, 30, 30) == B,
              "⑯ P1-69 解析只动 renderArea：(8,8)/(15,15) 红，(7,7)/(16,16)/(1,1)/(30,30) 仍蓝（实测 %#x %#x %#x %#x %#x %#x）",
              px(&o3, W, 8, 8), px(&o3, W, 15, 15), px(&o3, W, 7, 7), px(&o3, W, 16, 16), px(&o3, W, 1, 1), px(&o3, W, 30, 30));
        CHECK(px(&o4, W, 8, 8) == G && px(&o4, W, 15, 15) == G && px(&o4, W, 7, 7) == B && px(&o4, W, 16, 16) == B && px(&o4, W, 1, 1) == B && px(&o4, W, 30, 30) == B,
              "⑯ P1-69 绘制按 renderArea 夹：(8,8)/(15,15) 绿，(7,7)/(16,16)/(1,1)/(30,30) 仍蓝（实测 %#x %#x %#x %#x %#x %#x）",
              px(&o4, W, 8, 8), px(&o4, W, 15, 15), px(&o4, W, 7, 7), px(&o4, W, 16, 16), px(&o4, W, 1, 1), px(&o4, W, 30, 30));
    }
}
static void spawn_self(char *const argv0, const char *tag, char *e1, char *e2) {   // 子进程跑一组（Metal 初始化前 posix_spawn 自身，带上额外环境变量）
    extern char **environ; int ne = 0; while (environ[ne]) ne++;
    char **env = malloc((size_t)(ne + 3) * sizeof *env); memcpy(env, environ, (size_t)ne * sizeof *env); env[ne] = e1; env[ne + 1] = e2; env[ne + 2] = NULL;
    pid_t pid; int st = 0; char *av[] = {argv0, NULL};
    if (posix_spawn(&pid, argv0, NULL, NULL, av, env) != 0 || waitpid(pid, &st, 0) < 0 || !WIFEXITED(st) || WEXITSTATUS(st)) { printf("✗ t_vk_core %s 子进程失败（状态 %#x）\n", tag, st); fails++; }
    free(env);
}
// ⑳ 直连就绪判定（s2a_vk_lib_ready，gfxmode 选直连靠它；夹具由 Makefile 用出包工具 vk_shaders.py 现出）：
//   只有表头（--header-only，RomFS 没有 SPIR-V 的款，11-05 Minecraft）→ 1；表头口径号不是本宿主的 → 0；离线库（表有行 + metallib）→ 1；同一张有行的表拿走 metallib → 0
extern int s2a_vk_lib_ready(const char *game_data);
static void t_lib_ready(void) {
    const char *h = getenv("T_GD_HDR"), *a = getenv("T_GD_ABI"), *l = getenv("T_GD_LIB"), *n = getenv("T_GD_NOLIB");
    REQUIRE(h && a && l && n);
    int e0 = s2a_vk_lib_ready(h), e1 = s2a_vk_lib_ready(a), e2 = s2a_vk_lib_ready(l), e3 = s2a_vk_lib_ready(n);
    CHECK(e0 == 1 && e1 == 0 && e2 == 1 && e3 == 0, "⑳ 直连就绪：只有表头 %d（期望 1）、口径不符 %d（期望 0）、表 + 库 %d（期望 1）、有行没库 %d（期望 0）", e0, e1, e2, e3);
}
// ㉑ 管线建在它的着色器现编完成之前（11-05 Minecraft 离线库 0 支：原先顶点着色器在编的整条交空句柄回失败码、片元在编的建成没有片元函数、编好也不补）。
//    期望（手写）：按住后台现编，建三条管线——A 库里的顶点 + 在编的片元 rtp.frag、B 在编的顶点 rtp.vert + 库里的片元 color.frag、C 在编的计算 rtp.comp：
//    三条都回 VK_SUCCESS、句柄非空；建完就销毁模块（Vulkan 允许）；编好之前的绘制 / 派发照安全网跳过（像素是清屏黑、缓冲不动、错误计数 +3）；
//    放开后三支编好，同一批句柄再画：A = push (1,.5,.25,1).gbra → rgba (128,64,255,255)，B = push 原色 (255,128,64,255)，C：v[i] = i * 5 + 9；补建计数 3、补不成 0
void dm_vk_rt_hold(int on); void dm_vk_pend_stats(uint64_t *made, uint64_t *bad); void dm_vk_bad_draws(uint64_t *feat, uint64_t *err);
static uint32_t pend_draw(VkPipeline pipe, VkPipelineLayout l, VkRenderPass p, VkFramebuffer f, VkImage i, Buf *out) {
    VkCommandBuffer c = begin(VK_COMMAND_BUFFER_LEVEL_PRIMARY); VkClearValue black = {.color.float32 = {0, 0, 0, 1}}; begin_pass(c, p, f, 1, &black, VK_SUBPASS_CONTENTS_INLINE);
    vkCmdBindPipeline(c, VK_PIPELINE_BIND_POINT_GRAPHICS, pipe); float col[4] = {1, .5f, .25f, 1}; vkCmdPushConstants(c, l, VK_SHADER_STAGE_FRAGMENT_BIT, 0, 16, col);
    vkCmdDraw(c, 3, 1, 0, 0); vkCmdEndRenderPass(c); to_buffer(c, i, VK_IMAGE_ASPECT_COLOR_BIT, 0, W, H, out->b); submit(c);
    return px(out, W, 5, 5);
}
static void pend_dispatch(VkPipeline pipe, VkPipelineLayout l, VkDescriptorSet set) {
    VkCommandBuffer c = begin(VK_COMMAND_BUFFER_LEVEL_PRIMARY); vkCmdBindPipeline(c, VK_PIPELINE_BIND_POINT_COMPUTE, pipe); vkCmdBindDescriptorSets(c, VK_PIPELINE_BIND_POINT_COMPUTE, l, 0, 1, &set, 0, NULL);
    uint32_t add = 9; vkCmdPushConstants(c, l, VK_SHADER_STAGE_COMPUTE_BIT, 0, 4, &add); vkCmdDispatch(c, 4, 1, 1); submit(c);
}
static void t_rt_pending(void) {
    uint64_t m0, k0, b0, d0, m, k, b, d, f0, e0, f1, e1, pm, pb; dm_vk_rt_stats(&m0, &k0, &b0, &d0);
    dm_vk_rt_hold(1);
    VkImage ia = img(VK_FORMAT_R8G8B8A8_UNORM, W, H, 1, VK_SAMPLE_COUNT_1_BIT, VK_IMAGE_USAGE_COLOR_ATTACHMENT_BIT | VK_IMAGE_USAGE_TRANSFER_SRC_BIT);
    VkImage ib = img(VK_FORMAT_R8G8B8A8_UNORM, W, H, 1, VK_SAMPLE_COUNT_1_BIT, VK_IMAGE_USAGE_COLOR_ATTACHMENT_BIT | VK_IMAGE_USAGE_TRANSFER_SRC_BIT);
    VkImageView va = view(ia, VK_FORMAT_R8G8B8A8_UNORM, VK_IMAGE_ASPECT_COLOR_BIT), vb = view(ib, VK_FORMAT_R8G8B8A8_UNORM, VK_IMAGE_ASPECT_COLOR_BIT);
    VkRenderPass p = color_pass(VK_FORMAT_R8G8B8A8_UNORM, VK_ATTACHMENT_LOAD_OP_CLEAR, VK_SAMPLE_COUNT_1_BIT);
    VkFramebuffer fa = framebuffer(p, 1, &va, W, H), fb = framebuffer(p, 1, &vb, W, H);
    VkPipelineLayout l = layout_of(0, NULL, 16, VK_SHADER_STAGE_FRAGMENT_BIT);
    VkShaderModule rv = shader("rtp.vert"), rf = shader("rtp.frag"), rc = shader("rtp.comp");
    VkPipeline pa = VK_NULL_HANDLE, pbp = VK_NULL_HANDLE, pc = VK_NULL_HANDLE;
    VkResult ra = gfx_pipe_m(p, 0, l, shader("tri.vert"), rf, VK_SAMPLE_COUNT_1_BIT, NULL, 0, NULL, &pa);
    VkResult rb = gfx_pipe_m(p, 0, l, rv, shader("color.frag"), VK_SAMPLE_COUNT_1_BIT, NULL, 0, NULL, &pbp);
    VkDescriptorSetLayoutBinding lb = {0, VK_DESCRIPTOR_TYPE_STORAGE_BUFFER, 1, VK_SHADER_STAGE_COMPUTE_BIT};
    VkDescriptorSetLayoutCreateInfo lci = {.sType = VK_STRUCTURE_TYPE_DESCRIPTOR_SET_LAYOUT_CREATE_INFO, .bindingCount = 1, .pBindings = &lb}; VkDescriptorSetLayout sl; OK(vkCreateDescriptorSetLayout(device, &lci, NULL, &sl));
    VkPipelineLayout lc = layout_of(1, &sl, 4, VK_SHADER_STAGE_COMPUTE_BIT);
    VkComputePipelineCreateInfo cci = {.sType = VK_STRUCTURE_TYPE_COMPUTE_PIPELINE_CREATE_INFO, .stage = {.sType = VK_STRUCTURE_TYPE_PIPELINE_SHADER_STAGE_CREATE_INFO, .stage = VK_SHADER_STAGE_COMPUTE_BIT, .module = rc, .pName = "main"}, .layout = lc};
    VkResult rcc = vkCreateComputePipelines(device, VK_NULL_HANDLE, 1, &cci, NULL, &pc);
    dm_vk_rt_stats(&m, &k, &b, &d);
    CHECK(m == m0 + 3 && k == k0, "㉑ 按住现编：未命中 +%llu（期望 3）、编好 +%llu（期望 0）", (unsigned long long)(m - m0), (unsigned long long)(k - k0));
    CHECK(ra == VK_SUCCESS && pa && rb == VK_SUCCESS && pbp && rcc == VK_SUCCESS && pc, "㉑ 着色器还在编：三条管线都回成功、句柄非空（片元在编 %d/%s、顶点在编 %d/%s、计算在编 %d/%s）",
          ra, pa ? "有" : "空", rb, pbp ? "有" : "空", rcc, pc ? "有" : "空");
    vkDestroyShaderModule(device, rv, NULL); vkDestroyShaderModule(device, rf, NULL); vkDestroyShaderModule(device, rc, NULL);
    VkDescriptorPoolSize ps = {VK_DESCRIPTOR_TYPE_STORAGE_BUFFER, 1}; VkDescriptorPoolCreateInfo pci = {.sType = VK_STRUCTURE_TYPE_DESCRIPTOR_POOL_CREATE_INFO, .maxSets = 1, .poolSizeCount = 1, .pPoolSizes = &ps};
    VkDescriptorPool dp; OK(vkCreateDescriptorPool(device, &pci, NULL, &dp));
    VkDescriptorSetAllocateInfo ai = {.sType = VK_STRUCTURE_TYPE_DESCRIPTOR_SET_ALLOCATE_INFO, .descriptorPool = dp, .descriptorSetCount = 1, .pSetLayouts = &sl}; VkDescriptorSet set; OK(vkAllocateDescriptorSets(device, &ai, &set));
    Buf sb = buf(256 * 4, VK_BUFFER_USAGE_STORAGE_BUFFER_BIT); memset(sb.p, 0, 256 * 4);
    VkDescriptorBufferInfo bi = {sb.b, 0, VK_WHOLE_SIZE}; VkWriteDescriptorSet w = {.sType = VK_STRUCTURE_TYPE_WRITE_DESCRIPTOR_SET, .dstSet = set, .descriptorCount = 1, .descriptorType = VK_DESCRIPTOR_TYPE_STORAGE_BUFFER, .pBufferInfo = &bi};
    vkUpdateDescriptorSets(device, 1, &w, 0, NULL);
    Buf oa = buf(W * H * 4, VK_BUFFER_USAGE_TRANSFER_DST_BIT), ob = buf(W * H * 4, VK_BUFFER_USAGE_TRANSFER_DST_BIT);
    {   // 每条按自己的句柄画（负对照里有的句柄是空的，其余照样核）
        dm_vk_bad_draws(&f0, &e0);
        uint32_t qa = pa ? pend_draw(pa, l, p, fa, ia, &oa) : 1, qb = pbp ? pend_draw(pbp, l, p, fb, ib, &ob) : 1; if (pc) pend_dispatch(pc, lc, set);
        dm_vk_bad_draws(&f1, &e1); uint32_t v5; memcpy(&v5, sb.p + 20, 4);
        CHECK(qa == RGBA(0, 0, 0, 255) && qb == RGBA(0, 0, 0, 255) && v5 == 0 && e1 - e0 == 3, "㉑ 编好之前照安全网跳过：A %#x、B %#x（期望清屏黑 0xff000000）、C [5] = %u（期望 0）、错误计数 +%llu（期望 3）",
              qa, qb, v5, (unsigned long long)(e1 - e0));
    }
    dm_vk_rt_hold(0);
    for (int i = 0; i < 1000 && k < k0 + 3 && b == b0; i++) { usleep(10000); dm_vk_rt_stats(&m, &k, &b, &d); }
    CHECK(k == k0 + 3 && b == b0, "㉑ 放开后三支编好 +%llu（期望 3）、失败 +%llu", (unsigned long long)(k - k0), (unsigned long long)(b - b0));
    {
        uint32_t qa = pa ? pend_draw(pa, l, p, fa, ia, &oa) : 0, qb = pbp ? pend_draw(pbp, l, p, fb, ib, &ob) : 0; if (pc) pend_dispatch(pc, lc, set);
        int ok = 1; for (uint32_t i = 0; i < 256; i++) { uint32_t v; memcpy(&v, sb.p + i * 4, 4); ok &= v == i * 5 + 9; }
        int ar = qa & 0xff, ag = qa >> 8 & 0xff, ab = qa >> 16 & 0xff, br = qb & 0xff, bg = qb >> 8 & 0xff, bb = qb >> 16 & 0xff;
        CHECK(ar >= 127 && ar <= 129 && ag >= 63 && ag <= 65 && ab == 255, "㉑ 片元在编的管线编好后补建、画出现编那支：rgba (128,64,255)（实测 %d %d %d）", ar, ag, ab);
        CHECK(br == 255 && bg >= 127 && bg <= 129 && bb >= 63 && bb <= 65, "㉑ 顶点在编的管线编好后补建、画得出：rgba (255,128,64)（实测 %d %d %d）", br, bg, bb);
        CHECK(ok, "㉑ 计算在编的管线编好后补建：256 个值 = i * 5 + 9");
        dm_vk_pend_stats(&pm, &pb);
        CHECK(pm == 3 && pb == 0, "㉑ 补建成 %llu 条（期望 3）、补不成 %llu 条（期望 0）", (unsigned long long)pm, (unsigned long long)pb);
    }
}
// ㉒ 顶点输入整型符号性（11-05 Minecraft：R16_UINT 喂有符号输入，Metal 拒建「Cannot convert attribute from MTLAttributeFormatUShort to a signed integer type」，
//   那条管线的绘制全丢）。vin.vert 四个输入：a int ← R16_UINT 40000、b int ← R8_UINT 200、c int ← R32_UINT 0x80000005、d uint ← R32_SINT −7，按位写进 RGBA32_UINT。
//   期望手算（真机：按格式零 / 符号扩展进 32 位、着色器按位读）：(40000, 200, 0x80000005, 0xfffffff9)；按有符号读 16 / 8 位会是 0xffff9c40 / 0xffffffc8。
//   修前：管线建不成（回 VK_ERROR_OUT_OF_DEVICE_MEMORY、句柄空）
void dm_vk_vin_stats(uint64_t *ok, uint64_t *bad);
static int vin_draw(VkPipeline pipe, VkPipelineLayout l, VkRenderPass p, VkFramebuffer f, VkImage i, VkBuffer vb, const Buf *out, uint32_t q[4]) {
    VkCommandBuffer c = begin(VK_COMMAND_BUFFER_LEVEL_PRIMARY); VkClearValue cv = {.color.uint32 = {1, 1, 1, 1}};
    begin_pass(c, p, f, 1, &cv, VK_SUBPASS_CONTENTS_INLINE); vkCmdBindPipeline(c, VK_PIPELINE_BIND_POINT_GRAPHICS, pipe); (void)l;
    VkDeviceSize o = 0; vkCmdBindVertexBuffers(c, 0, 1, &vb, &o);
    vkCmdDraw(c, 3, 1, 0, 0); vkCmdEndRenderPass(c); to_buffer(c, i, VK_IMAGE_ASPECT_COLOR_BIT, 0, W, H, out->b); submit(c);
    memcpy(q, out->p + ((size_t)5 * W + 5) * 16, 16); return 1;
}
static void t_vin(void) {
    VkFormat cf = VK_FORMAT_R32G32B32A32_UINT;
    VkImage im = img(cf, W, H, 1, VK_SAMPLE_COUNT_1_BIT, VK_IMAGE_USAGE_COLOR_ATTACHMENT_BIT | VK_IMAGE_USAGE_TRANSFER_SRC_BIT);
    VkImageView v = view(im, cf, VK_IMAGE_ASPECT_COLOR_BIT); VkRenderPass p = color_pass(cf, VK_ATTACHMENT_LOAD_OP_CLEAR, VK_SAMPLE_COUNT_1_BIT);
    VkFramebuffer f = framebuffer(p, 1, &v, W, H); VkPipelineLayout l = layout_of(0, NULL, 0, 0);
    Buf vb = buf(3 * 12, VK_BUFFER_USAGE_VERTEX_BUFFER_BIT), out = buf(W * H * 16, VK_BUFFER_USAGE_TRANSFER_DST_BIT);
    for (int k = 0; k < 3; k++) { uint8_t *e = vb.p + k * 12; uint16_t a = 40000; uint32_t cc = 0x80000005u; int32_t d = -7; memcpy(e, &a, 2); e[2] = 200; e[3] = 0; memcpy(e + 4, &cc, 4); memcpy(e + 8, &d, 4); }
    VkPipelineShaderStageCreateInfo st[] = {{.sType = VK_STRUCTURE_TYPE_PIPELINE_SHADER_STAGE_CREATE_INFO, .stage = VK_SHADER_STAGE_VERTEX_BIT, .module = shader("vin.vert"), .pName = "main"},
                                            {.sType = VK_STRUCTURE_TYPE_PIPELINE_SHADER_STAGE_CREATE_INFO, .stage = VK_SHADER_STAGE_FRAGMENT_BIT, .module = shader("vin.frag"), .pName = "main"}};
    VkVertexInputBindingDescription bd = {0, 12, VK_VERTEX_INPUT_RATE_VERTEX};
    VkVertexInputAttributeDescription ad[] = {{0, 0, VK_FORMAT_R16_UINT, 0}, {1, 0, VK_FORMAT_R8_UINT, 2}, {2, 0, VK_FORMAT_R32_UINT, 4}, {3, 0, VK_FORMAT_R32_SINT, 8}};
    VkPipelineVertexInputStateCreateInfo vi = {.sType = VK_STRUCTURE_TYPE_PIPELINE_VERTEX_INPUT_STATE_CREATE_INFO, .vertexBindingDescriptionCount = 1, .pVertexBindingDescriptions = &bd,
        .vertexAttributeDescriptionCount = 4, .pVertexAttributeDescriptions = ad};
    VkPipelineInputAssemblyStateCreateInfo ia = {.sType = VK_STRUCTURE_TYPE_PIPELINE_INPUT_ASSEMBLY_STATE_CREATE_INFO, .topology = VK_PRIMITIVE_TOPOLOGY_TRIANGLE_LIST};
    VkViewport vp = {0, 0, W, H, 0, 1}; VkRect2D sc = {{0, 0}, {W, H}};
    VkPipelineViewportStateCreateInfo vs = {.sType = VK_STRUCTURE_TYPE_PIPELINE_VIEWPORT_STATE_CREATE_INFO, .viewportCount = 1, .pViewports = &vp, .scissorCount = 1, .pScissors = &sc};
    VkPipelineRasterizationStateCreateInfo rs = {.sType = VK_STRUCTURE_TYPE_PIPELINE_RASTERIZATION_STATE_CREATE_INFO, .cullMode = VK_CULL_MODE_NONE, .lineWidth = 1};
    VkPipelineMultisampleStateCreateInfo ms = {.sType = VK_STRUCTURE_TYPE_PIPELINE_MULTISAMPLE_STATE_CREATE_INFO, .rasterizationSamples = VK_SAMPLE_COUNT_1_BIT};
    VkPipelineColorBlendAttachmentState ba = {.colorWriteMask = 15};
    VkPipelineColorBlendStateCreateInfo cb = {.sType = VK_STRUCTURE_TYPE_PIPELINE_COLOR_BLEND_STATE_CREATE_INFO, .attachmentCount = 1, .pAttachments = &ba};
    VkGraphicsPipelineCreateInfo ci = {.sType = VK_STRUCTURE_TYPE_GRAPHICS_PIPELINE_CREATE_INFO, .stageCount = 2, .pStages = st, .pVertexInputState = &vi, .pInputAssemblyState = &ia,
        .pViewportState = &vs, .pRasterizationState = &rs, .pMultisampleState = &ms, .pColorBlendState = &cb, .layout = l, .renderPass = p};
    uint64_t k0, b0, k1, b1; dm_vk_vin_stats(&k0, &b0);
    VkPipeline pipe = VK_NULL_HANDLE; VkResult r = vkCreateGraphicsPipelines(device, VK_NULL_HANDLE, 1, &ci, NULL, &pipe);
    CHECK(r == VK_SUCCESS && pipe, "㉒ 整型顶点格式与着色器输入符号性不一致：管线回成功、句柄非空（实测 %d、句柄%s）", r, pipe ? "有" : "空");
    if (!pipe) return;
    dm_vk_vin_stats(&k1, &b1);
    for (int i = 0; i < 1000 && k1 == k0 && b1 == b0; i++) { usleep(10000); dm_vk_vin_stats(&k1, &b1); }
    CHECK(k1 == k0 + 1 && b1 == b0, "㉒ 顶点着色器按管线格式重翻现编 1 支（编好 +%llu、失败 +%llu）", (unsigned long long)(k1 - k0), (unsigned long long)(b1 - b0));
    uint32_t q[4] = {0}; vin_draw(pipe, l, p, f, im, vb.b, &out, q);
    CHECK(q[0] == 40000 && q[1] == 200 && q[2] == 0x80000005u && q[3] == 0xfffffff9u, "㉒ 读到的位：(%u, %u, %#x, %#x)（期望 (40000, 200, 0x80000005, 0xfffffff9)）", q[0], q[1], q[2], q[3]);
    VkPipeline p2 = VK_NULL_HANDLE; r = vkCreateGraphicsPipelines(device, VK_NULL_HANDLE, 1, &ci, NULL, &p2); dm_vk_vin_stats(&k1, &b1);
    CHECK(r == VK_SUCCESS && p2 && k1 == k0 + 1, "㉒ 同模块同格式再建一条：不再重翻（编好累计 +%llu，期望 1）、当场建成", (unsigned long long)(k1 - k0));
    if (p2) { uint32_t q2[4] = {0}; vin_draw(p2, l, p, f, im, vb.b, &out, q2); CHECK(!memcmp(q, q2, 16), "㉒ 第二条画出同样的位"); }
}
// ㉓ 换了 set 0 布局多一个绑定的管线、没重绑 set 0（11-05 Minecraft 红行「0.65 is not in the bound set's layout … the set was not rebound with the pipeline」）：
//   布局 LB = {1: UBO}、LA = {0: UBO}。一条命令缓冲里：PB（读 0.1）+ 集 XB（0.1 = 绿）画 → PA（读 0.0）+ 集 XA（0.0 = 红）画 → 再绑 PB、不重绑 set 0 画。
//   期望手算（绑定按绑定号各占一格，绑 XA 只盖 0.0，0.1 留着 XB 的绿）：最后一笔绿 0xff00ff00。修前：0.1 在 XA 里没有、跳过不绑，Metal 0 号缓冲槽留着 PA 那笔的红 → 红
static VkDescriptorSet ubo_set(VkDescriptorSetLayout sl, uint32_t binding, VkBuffer b) {
    VkDescriptorPoolSize ps = {VK_DESCRIPTOR_TYPE_UNIFORM_BUFFER, 1}; VkDescriptorPoolCreateInfo pci = {.sType = VK_STRUCTURE_TYPE_DESCRIPTOR_POOL_CREATE_INFO, .maxSets = 1, .poolSizeCount = 1, .pPoolSizes = &ps};
    VkDescriptorPool dp; OK(vkCreateDescriptorPool(device, &pci, NULL, &dp));
    VkDescriptorSetAllocateInfo ai = {.sType = VK_STRUCTURE_TYPE_DESCRIPTOR_SET_ALLOCATE_INFO, .descriptorPool = dp, .descriptorSetCount = 1, .pSetLayouts = &sl}; VkDescriptorSet set; OK(vkAllocateDescriptorSets(device, &ai, &set));
    VkDescriptorBufferInfo bi = {b, 0, VK_WHOLE_SIZE}; VkWriteDescriptorSet w = {.sType = VK_STRUCTURE_TYPE_WRITE_DESCRIPTOR_SET, .dstSet = set, .dstBinding = binding, .descriptorCount = 1, .descriptorType = VK_DESCRIPTOR_TYPE_UNIFORM_BUFFER, .pBufferInfo = &bi};
    vkUpdateDescriptorSets(device, 1, &w, 0, NULL); return set;
}
static VkDescriptorSetLayout ubo_layout(uint32_t binding) {
    VkDescriptorSetLayoutBinding lb = {binding, VK_DESCRIPTOR_TYPE_UNIFORM_BUFFER, 1, VK_SHADER_STAGE_FRAGMENT_BIT};
    VkDescriptorSetLayoutCreateInfo lci = {.sType = VK_STRUCTURE_TYPE_DESCRIPTOR_SET_LAYOUT_CREATE_INFO, .bindingCount = 1, .pBindings = &lb}; VkDescriptorSetLayout sl; OK(vkCreateDescriptorSetLayout(device, &lci, NULL, &sl)); return sl;
}
static void t_disturbed_set(void) {
    VkFormat f = VK_FORMAT_R8G8B8A8_UNORM;
    VkImage im = img(f, W, H, 1, VK_SAMPLE_COUNT_1_BIT, VK_IMAGE_USAGE_COLOR_ATTACHMENT_BIT | VK_IMAGE_USAGE_TRANSFER_SRC_BIT); VkImageView v = view(im, f, VK_IMAGE_ASPECT_COLOR_BIT);
    VkRenderPass p = color_pass(f, VK_ATTACHMENT_LOAD_OP_CLEAR, VK_SAMPLE_COUNT_1_BIT); VkFramebuffer fb = framebuffer(p, 1, &v, W, H);
    VkDescriptorSetLayout la = ubo_layout(0), lbl = ubo_layout(1); VkPipelineLayout pla = layout_of(1, &la, 0, 0), plb = layout_of(1, &lbl, 0, 0);
    VkPipeline pa = gfx_pipe(p, 0, pla, "ubo0.frag", VK_SAMPLE_COUNT_1_BIT, NULL, 0, NULL), pb = gfx_pipe(p, 0, plb, "ubo1.frag", VK_SAMPLE_COUNT_1_BIT, NULL, 0, NULL);
    Buf red = buf(16, VK_BUFFER_USAGE_UNIFORM_BUFFER_BIT), green = buf(16, VK_BUFFER_USAGE_UNIFORM_BUFFER_BIT), out = buf(W * H * 4, VK_BUFFER_USAGE_TRANSFER_DST_BIT);
    float r4[4] = {1, 0, 0, 1}, g4[4] = {0, 1, 0, 1}; memcpy(red.p, r4, 16); memcpy(green.p, g4, 16);
    VkDescriptorSet xa = ubo_set(la, 0, red.b), xb = ubo_set(lbl, 1, green.b);
    VkCommandBuffer c = begin(VK_COMMAND_BUFFER_LEVEL_PRIMARY); VkClearValue cv = {.color.float32 = {0, 0, 1, 1}};
    begin_pass(c, p, fb, 1, &cv, VK_SUBPASS_CONTENTS_INLINE);
    vkCmdBindPipeline(c, VK_PIPELINE_BIND_POINT_GRAPHICS, pb); vkCmdBindDescriptorSets(c, VK_PIPELINE_BIND_POINT_GRAPHICS, plb, 0, 1, &xb, 0, NULL); vkCmdDraw(c, 3, 1, 0, 0);
    vkCmdBindPipeline(c, VK_PIPELINE_BIND_POINT_GRAPHICS, pa); vkCmdBindDescriptorSets(c, VK_PIPELINE_BIND_POINT_GRAPHICS, pla, 0, 1, &xa, 0, NULL); vkCmdDraw(c, 3, 1, 0, 0);
    vkCmdBindPipeline(c, VK_PIPELINE_BIND_POINT_GRAPHICS, pb); vkCmdDraw(c, 3, 1, 0, 0);
    vkCmdEndRenderPass(c); to_buffer(c, im, VK_IMAGE_ASPECT_COLOR_BIT, 0, W, H, out.b); submit(c);
    uint32_t q = px(&out, W, 5, 5);
    CHECK(q == RGBA(0, 255, 0, 255), "㉓ 没重绑 set 0 的那笔读 0.1：取先前绑在 set 0、有 0.1 的集 XB 的绿（实测 %#x，期望 0xff00ff00；修前 Metal 槽留着上一笔的红 0xff0000ff）", q);
}

// ㉔ 即时存档（Vulkan 出图层，graphics/nvn/gfx/vk/vk_snap.inc）：子进程里开快照模式（本文件提供快照开关与固定地址区的替身），
//   纹理按坐标写色（R = x*8、G = y*8）、最近邻采样画满 W×H 目标、读回 → 存档（vk_snap_save）→ 同进程按原址放回并重建全部 Metal 对象（vk_snap_restore：先清零旧指针，
//   再按建法重建）→ 用同一批句柄（管线 / 描述符集 / 帧缓冲 / 命令池）再画一遍、读回。期望手算：两次每个像素都等于 RGBA(x*8, y*8, 0, 255)；建管线后模块已销毁
//   （恢复按源码键重建）；映射指针原址原内容（0xcd 填充）；恢复后描述符的纹理不空（来源视图序号对得上）
static int snap_on_flag;
int s2a_snap_mode(void) { return snap_on_flag; }
static uint8_t *snap_ca, *snap_vp; static uint64_t snap_ca_used, snap_vp_used;
void *s2a_cmd_arena_map(uint64_t len) {
    if (!snap_on_flag) return NULL;
    if (!snap_ca) { snap_ca = mmap(NULL, 256ull << 20, PROT_NONE, MAP_PRIVATE | MAP_ANON, -1, 0); REQUIRE(snap_ca != MAP_FAILED); }
    uint64_t n = (len + 16383) & ~16383ull; if (snap_ca_used + n > (256ull << 20)) return NULL;
    void *p = mmap(snap_ca + snap_ca_used, n, PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANON | MAP_FIXED, -1, 0); snap_ca_used += n; return p;
}
int s2a_cmd_arena_has(const void *p, uint64_t n) { return snap_ca && (const uint8_t *)p >= snap_ca && (const uint8_t *)p + n <= snap_ca + (256ull << 20); }
void *s2a_vp_arena_map(uint64_t len) {
    if (!snap_on_flag) return NULL;
    if (!snap_vp) { snap_vp = mmap(NULL, 256ull << 20, PROT_NONE, MAP_PRIVATE | MAP_ANON, -1, 0); REQUIRE(snap_vp != MAP_FAILED); }
    uint64_t n = (len + 16383) & ~16383ull; if (snap_vp_used + n > (256ull << 20)) return NULL; void *p = snap_vp + snap_vp_used; snap_vp_used += n; return p;
}
extern int vk_snap_save(const char *path); extern int vk_snap_restore(const char *path); extern int vk_snap_used(void);
static void snap_draw(VkRenderPass p, VkFramebuffer fb, VkPipeline pl, VkPipelineLayout l, VkDescriptorSet set, VkImage target, Buf *out) {
    VkCommandBuffer c = begin(VK_COMMAND_BUFFER_LEVEL_PRIMARY); VkClearValue cv = {.color = {{0, 0, 1, 1}}};
    begin_pass(c, p, fb, 1, &cv, VK_SUBPASS_CONTENTS_INLINE); vkCmdBindPipeline(c, VK_PIPELINE_BIND_POINT_GRAPHICS, pl);
    vkCmdBindDescriptorSets(c, VK_PIPELINE_BIND_POINT_GRAPHICS, l, 0, 1, &set, 0, NULL); vkCmdDraw(c, 3, 1, 0, 0); vkCmdEndRenderPass(c);
    memset(out->p, 0, (size_t)W * H * 4); to_buffer(c, target, VK_IMAGE_ASPECT_COLOR_BIT, 0, W, H, out->b); submit(c);
}
static int snap_bad(const Buf *b) { int bad = 0; for (uint32_t y = 0; y < H; y++) for (uint32_t x = 0; x < W; x++) bad += px(b, W, x, y) != RGBA(x * 8, y * 8, 0, 255); return bad; }
static void t_snapshot(void) {
    REQUIRE(vk_snap_used());
    VkImage tex = img(VK_FORMAT_R8G8B8A8_UNORM, W, H, 1, VK_SAMPLE_COUNT_1_BIT, VK_IMAGE_USAGE_SAMPLED_BIT | VK_IMAGE_USAGE_TRANSFER_DST_BIT); VkImageView tv = view(tex, VK_FORMAT_R8G8B8A8_UNORM, VK_IMAGE_ASPECT_COLOR_BIT);
    Buf up = buf((size_t)W * H * 4, VK_BUFFER_USAGE_TRANSFER_SRC_BIT);
    for (uint32_t y = 0; y < H; y++) for (uint32_t x = 0; x < W; x++) { uint32_t v = RGBA(x * 8, y * 8, 0, 255); memcpy(up.p + ((size_t)y * W + x) * 4, &v, 4); }
    VkBufferImageCopy rg = {.imageSubresource = {VK_IMAGE_ASPECT_COLOR_BIT, 0, 0, 1}, .imageExtent = {W, H, 1}};
    VkCommandBuffer c = begin(VK_COMMAND_BUFFER_LEVEL_PRIMARY); vkCmdCopyBufferToImage(c, up.b, tex, VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL, 1, &rg); submit(c);
    VkSamplerCreateInfo sci = {.sType = VK_STRUCTURE_TYPE_SAMPLER_CREATE_INFO, .magFilter = VK_FILTER_NEAREST, .minFilter = VK_FILTER_NEAREST, .mipmapMode = VK_SAMPLER_MIPMAP_MODE_NEAREST,
        .addressModeU = VK_SAMPLER_ADDRESS_MODE_CLAMP_TO_EDGE, .addressModeV = VK_SAMPLER_ADDRESS_MODE_CLAMP_TO_EDGE, .addressModeW = VK_SAMPLER_ADDRESS_MODE_CLAMP_TO_EDGE, .maxLod = 0};
    VkSampler smp; OK(vkCreateSampler(device, &sci, NULL, &smp));
    VkDescriptorSetLayoutBinding lb = {0, VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER, 1, VK_SHADER_STAGE_FRAGMENT_BIT};
    VkDescriptorSetLayoutCreateInfo lci = {.sType = VK_STRUCTURE_TYPE_DESCRIPTOR_SET_LAYOUT_CREATE_INFO, .bindingCount = 1, .pBindings = &lb}; VkDescriptorSetLayout sl; OK(vkCreateDescriptorSetLayout(device, &lci, NULL, &sl));
    VkDescriptorPoolSize ps = {VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER, 1}; VkDescriptorPoolCreateInfo pci = {.sType = VK_STRUCTURE_TYPE_DESCRIPTOR_POOL_CREATE_INFO, .maxSets = 1, .poolSizeCount = 1, .pPoolSizes = &ps};
    VkDescriptorPool dp; OK(vkCreateDescriptorPool(device, &pci, NULL, &dp));
    VkDescriptorSetAllocateInfo ai = {.sType = VK_STRUCTURE_TYPE_DESCRIPTOR_SET_ALLOCATE_INFO, .descriptorPool = dp, .descriptorSetCount = 1, .pSetLayouts = &sl}; VkDescriptorSet set; OK(vkAllocateDescriptorSets(device, &ai, &set));
    VkDescriptorImageInfo ii = {smp, tv, VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL};
    VkWriteDescriptorSet w = {.sType = VK_STRUCTURE_TYPE_WRITE_DESCRIPTOR_SET, .dstSet = set, .descriptorCount = 1, .descriptorType = VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER, .pImageInfo = &ii};
    vkUpdateDescriptorSets(device, 1, &w, 0, NULL);
    VkPipelineLayout l = layout_of(1, &sl, 0, 0); VkRenderPass p = color_pass(VK_FORMAT_R8G8B8A8_UNORM, VK_ATTACHMENT_LOAD_OP_CLEAR, VK_SAMPLE_COUNT_1_BIT);
    VkShaderModule vm = shader("tri.vert"), fm = shader("lod.frag"); VkPipeline pl; OK(gfx_pipe_m(p, 0, l, vm, fm, VK_SAMPLE_COUNT_1_BIT, NULL, 0, NULL, &pl));
    vkDestroyShaderModule(device, vm, NULL); vkDestroyShaderModule(device, fm, NULL);   // 游戏常这样：建完管线就销毁模块
    VkImage target = img(VK_FORMAT_R8G8B8A8_UNORM, W, H, 1, VK_SAMPLE_COUNT_1_BIT, VK_IMAGE_USAGE_COLOR_ATTACHMENT_BIT | VK_IMAGE_USAGE_TRANSFER_SRC_BIT);
    VkImageView targv = view(target, VK_FORMAT_R8G8B8A8_UNORM, VK_IMAGE_ASPECT_COLOR_BIT); VkFramebuffer fb = framebuffer(p, 1, &targv, W, H);
    Buf rd = buf((size_t)W * H * 4, VK_BUFFER_USAGE_TRANSFER_DST_BIT); Buf keep = buf(64, VK_BUFFER_USAGE_UNIFORM_BUFFER_BIT); uint8_t *keep_p = keep.p;
    snap_draw(p, fb, pl, l, set, target, &rd); int bad0 = snap_bad(&rd);
    CHECK(bad0 == 0, "㉔ 存档前：%d×%d 个像素都等于 RGBA(x*8, y*8, 0, 255)：期望 0 处不符 → 真结果 %d 处", W, H, bad0);
    char path[256]; snprintf(path, sizeof path, "%s/t_vk_snap.bin", getenv("TMPDIR") ? getenv("TMPDIR") : "/tmp");
    CHECK(vk_snap_save(path) == 0, "㉔ 存档：vk_snap_save 回 0");
    CHECK(vk_snap_restore(path) == 0, "㉔ 恢复：vk_snap_restore 回 0（先清掉全部 Metal 指针、再按建法重建）");
    int same = 1; for (int i = 0; i < 64; i++) same &= keep_p[i] == 0xcd;
    CHECK(same, "㉔ 映射指针原址原内容：64 字节都是 0xcd");
    snap_draw(p, fb, pl, l, set, target, &rd); int bad1 = snap_bad(&rd);
    CHECK(bad1 == 0, "㉔ 恢复后同一批句柄再画：期望 0 处不符 → 真结果 %d 处（中心像素 %#x）", bad1, px(&rd, W, W / 2, H / 2));
    unlink(path);
}
int main(int argc, char **argv) {
    (void)argc;
    if (getenv("T_VK_WIDEN")) { fk_on = 1; setup(); t_widen(); if (fails) { printf("✗ t_vk_core ⑮：%d / %d 项失败\n", fails, checks); return 1; } printf("✓ t_vk_core ⑮：%d 项全过\n", checks); return 0; }
    if (getenv("T_VK_TALL")) { fk_on = fk_tall = 1; setup(); t_tall(); if (fails) { printf("✗ t_vk_core ⑰⑱⑲：%d / %d 项失败\n", fails, checks); return 1; } printf("✓ t_vk_core ⑰⑱⑲：%d 项全过\n", checks); return 0; }
    if (getenv("T_VK_RT_PEND")) { setup(); t_rt_pending(); if (fails) { printf("✗ t_vk_core ㉑：%d / %d 项失败\n", fails, checks); return 1; } printf("✓ t_vk_core ㉑：%d 项全过\n", checks); return 0; }
    if (getenv("T_VK_SNAP")) { snap_on_flag = 1; setup(); t_snapshot(); if (fails) { printf("✗ t_vk_core ㉔：%d / %d 项失败\n", fails, checks); return 1; } printf("✓ t_vk_core ㉔：%d 项全过\n", checks); return 0; }
    if (getenv("T_VK_AUDIT")) { setup(); t_audit1800(); if (fails) { printf("✗ t_vk_core ⑯：%d / %d 项失败\n", fails, checks); return 1; } printf("✓ t_vk_core ⑯：%d 项全过\n", checks); return 0; }
    spawn_self(argv[0], "㉔", "T_VK_SNAP=1", NULL);   // ㉔ 子进程：快照模式在第一次分配对象时定（分配器进固定地址区），整局不变
    spawn_self(argv[0], "⑮", "T_VK_WIDEN=1", NULL);   // ⑮ 在子进程里跑：宽屏模式在第一次建附件图像时定、整局不变
    // ⑯ 在子进程里开 Metal API 校验层跑：越界的剪裁 / 拷贝 / 视图在校验层上当场断言（读回像素未必看得出：无校验层时 Metal 可能悄悄丢掉）
    spawn_self(argv[0], "⑯", "T_VK_AUDIT=1", "MTL_DEBUG_LAYER=1");
    spawn_self(argv[0], "⑰", "T_VK_TALL=1", "MTL_DEBUG_LAYER=1");   // ⑰ 子进程：窄屏加高模式（假核心），开校验层：加高后的剪裁 / 拷贝越界当场断言
    setup();
    t_queries(); t_fill_update(); t_clear_image(); t_clear_attachments(); t_blit(); t_resolve(); t_events(); t_query_copy(); t_compute(); t_image_atomic(); t_secondary(); t_subpasses(); t_stencil_masks(); t_lod_bias(); t_runtime(); t_lib_ready(); t_vin(); t_disturbed_set();
    if (fails) { printf("✗ t_vk_core：%d / %d 项失败\n", fails, checks); return 1; }
    printf("✓ t_vk_core：%d 项全过\n", checks); return 0;
}
