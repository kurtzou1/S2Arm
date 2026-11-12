// nvn_gpu_* 上屏部分（由 backend_vulkan.c include）：交换链、取图、把源视图贴进取到的图并呈现。
// 不含任何平台调用：窗口 → VkSurfaceKHR 由平台件 nvn_plat_vk_surface_create 给，窗口尺寸由 nvn_plat_window_size 给。
// 呈现用后端自己的内部段：与游戏的段走同一把提交锁，所以在 GPU 上排在此前已提交的段之后；
// 内部段不占时间线上的值，完成后只做资源回收。
#include "nvn_plat_vk.h"
#include "nvn_plat.h"

enum { WSI_MAX_IMAGES = 8 };
struct nvn_gpu_surface_s {
    void *native;
    VkSurfaceKHR surface;
    VkSwapchainKHR swapchain;
    VkFormat format;
    VkExtent2D extent;
    uint32_t nimages;
    VkImage images[WSI_MAX_IMAGES];
    VkSemaphore acquire[WSI_MAX_IMAGES + 1];   // 每次取图用下一把：一把信号量在被对应的呈现段等掉之前不能再交给取图
    VkSemaphore rendered[WSI_MAX_IMAGES];      // 每张图一把：呈现段完成时发，vkQueuePresentKHR 等
    uint32_t acquire_next;
    uint32_t acquire_pending;                   // 位 i：acquire[i] 被取图发过、还没被呈现段等掉
    uint64_t gen;                               // 0 = 已撤销
    int outdated;
    int held;                                   // 取了没呈现、留作下次取图结果的那张（没有就是 -1）
    uint32_t held_sem;
    uint64_t presents;
};
static struct nvn_gpu_surface_s *g_surface;    // 一个后端同时只接一个面

// 取图发过而没被等掉的信号量不能直接销毁（VUID-vkDestroySemaphore-semaphore-05149）：提交一个只等它的空批次把它消费掉
static void wsi_consume_acquired(struct nvn_gpu_surface_s *s) {
    for (uint32_t i = 0; i < WSI_MAX_IMAGES + 1; i++) {
        if (!(s->acquire_pending >> i & 1) || !s->acquire[i]) continue;
        VkFenceCreateInfo fi; memset(&fi, 0, sizeof fi); fi.sType = VK_STRUCTURE_TYPE_FENCE_CREATE_INFO;
        VkFence f = VK_NULL_HANDLE;
        if (vkCreateFence(g.d, &fi, NULL, &f) != VK_SUCCESS) continue;
        VkPipelineStageFlags st = VK_PIPELINE_STAGE_TRANSFER_BIT;
        VkSubmitInfo si; memset(&si, 0, sizeof si);
        si.sType = VK_STRUCTURE_TYPE_SUBMIT_INFO; si.waitSemaphoreCount = 1; si.pWaitSemaphores = &s->acquire[i]; si.pWaitDstStageMask = &st;
        pthread_mutex_lock(&g_submit_mu);
        VkResult r = vkQueueSubmit(g.queue, 1, &si, f);
        pthread_mutex_unlock(&g_submit_mu);
        if (r == VK_SUCCESS) vkWaitForFences(g.d, 1, &f, VK_TRUE, 2000000000ull);
        vkDestroyFence(g.d, f, NULL);
    }
    s->acquire_pending = 0;
    // 最后一次呈现对「呈现信号量」的等待要到队列空了才算结束：之后才能销毁那把信号量
    pthread_mutex_lock(&g_submit_mu);
    vkQueueWaitIdle(g.queue);
    pthread_mutex_unlock(&g_submit_mu);
}

static void wsi_destroy_swapchain(struct nvn_gpu_surface_s *s) {
    wsi_consume_acquired(s);
    // 先销毁交换链再销毁信号量：取图发过、还没被呈现段等掉的信号量，要等它所属的交换链没了才算用完
    if (s->swapchain) { vkDestroySwapchainKHR(g.d, s->swapchain, NULL); s->swapchain = VK_NULL_HANDLE; }
    for (uint32_t i = 0; i < WSI_MAX_IMAGES + 1; i++) if (s->acquire[i]) { vkDestroySemaphore(g.d, s->acquire[i], NULL); s->acquire[i] = VK_NULL_HANDLE; }
    for (uint32_t i = 0; i < WSI_MAX_IMAGES; i++) if (s->rendered[i]) { vkDestroySemaphore(g.d, s->rendered[i], NULL); s->rendered[i] = VK_NULL_HANDLE; }
    s->nimages = 0; s->held = -1;
}

// 等内部段与游戏段都执行完：之后销毁交换链 / 信号量才合法。0 = 等到了。
static int wsi_wait_drained(uint64_t timeout_ns) {
    uint64_t deadline = add_sat(now_ns(), timeout_ns);
    int ok = 1;
    pthread_mutex_lock(&g_mu);
    while (g.qhead || g.busy) {
        uint64_t now = now_ns();
        if (now >= deadline) { ok = 0; break; }
        struct timespec ts; deadline_after(&ts, deadline - now);
        pthread_cond_timedwait(&g_cv, &g_mu, &ts);
    }
    pthread_mutex_unlock(&g_mu);
    return ok ? 0 : -1;
}

static void wsi_close_locked(void) {   // nvn_gpu_close 在在途段清空后调（持 g_mu）
    struct nvn_gpu_surface_s *s = g_surface;
    if (!s) return;
    wsi_destroy_swapchain(s);
    if (s->surface) vkDestroySurfaceKHR(g.dev->instance, s->surface, NULL);
    g_surface = NULL;
    free(s);
}

static nvn_gpu_rc wsi_build(struct nvn_gpu_surface_s *s, nvn_gpu_err *err) {
    VkSurfaceCapabilitiesKHR caps;
    if (vkGetPhysicalDeviceSurfaceCapabilitiesKHR(g.phys, s->surface, &caps) != VK_SUCCESS) return fail(err, NVN_GPU_E_REVOKED, "取不到表面能力（窗口已不在）");
    VkSurfaceFormatKHR fmts[64]; uint32_t nf = 64;
    VkResult fr = vkGetPhysicalDeviceSurfaceFormatsKHR(g.phys, s->surface, &nf, fmts);
    if ((fr != VK_SUCCESS && fr != VK_INCOMPLETE) || !nf) return fail(err, NVN_GPU_E_UNSUPPORTED, "表面没有可用格式");
    VkSurfaceFormatKHR pick = fmts[0];
    for (uint32_t i = 0; i < nf; i++) if (fmts[i].colorSpace == VK_COLOR_SPACE_SRGB_NONLINEAR_KHR && (fmts[i].format == VK_FORMAT_R8G8B8A8_UNORM || fmts[i].format == VK_FORMAT_B8G8R8A8_UNORM)) { pick = fmts[i]; break; }
    VkFormatProperties fp; vkGetPhysicalDeviceFormatProperties(g.phys, pick.format, &fp);
    if (!(fp.optimalTilingFeatures & VK_FORMAT_FEATURE_BLIT_DST_BIT) || !(caps.supportedUsageFlags & VK_IMAGE_USAGE_TRANSFER_DST_BIT))
        return fail(err, NVN_GPU_E_UNSUPPORTED, "交换链格式 %d 不能当拷贝目标", (int)pick.format);
    VkExtent2D ext = caps.currentExtent;
    if (ext.width == 0xffffffffu || !ext.width || !ext.height) {   // 表面不报尺寸：问平台要窗口尺寸
        uint32_t w = 0, h = 0;
        if (!nvn_plat_window_size(s->native, &w, &h) || !w || !h) return fail(err, NVN_GPU_E_REVOKED, "窗口没有尺寸");
        ext.width = w; ext.height = h;
    }
    if (ext.width < caps.minImageExtent.width) ext.width = caps.minImageExtent.width;
    if (ext.height < caps.minImageExtent.height) ext.height = caps.minImageExtent.height;
    if (caps.maxImageExtent.width && ext.width > caps.maxImageExtent.width) ext.width = caps.maxImageExtent.width;
    if (caps.maxImageExtent.height && ext.height > caps.maxImageExtent.height) ext.height = caps.maxImageExtent.height;
    uint32_t n = caps.minImageCount + 1; if (n < 3) n = 3;
    if (caps.maxImageCount && n > caps.maxImageCount) n = caps.maxImageCount;
    if (n > WSI_MAX_IMAGES) n = WSI_MAX_IMAGES;
    VkSwapchainCreateInfoKHR ci; memset(&ci, 0, sizeof ci);
    ci.sType = VK_STRUCTURE_TYPE_SWAPCHAIN_CREATE_INFO_KHR;
    ci.surface = s->surface; ci.minImageCount = n; ci.imageFormat = pick.format; ci.imageColorSpace = pick.colorSpace;
    ci.imageExtent = ext; ci.imageArrayLayers = 1; ci.imageUsage = VK_IMAGE_USAGE_TRANSFER_DST_BIT | VK_IMAGE_USAGE_COLOR_ATTACHMENT_BIT;
    ci.imageSharingMode = VK_SHARING_MODE_EXCLUSIVE;
    // 预旋转固定用恒等：把当前旋转当预旋转又不转内容，合成器会再转一次（安卓真机实测过的坑）
    ci.preTransform = (caps.supportedTransforms & VK_SURFACE_TRANSFORM_IDENTITY_BIT_KHR) ? VK_SURFACE_TRANSFORM_IDENTITY_BIT_KHR : caps.currentTransform;
    ci.compositeAlpha = (caps.supportedCompositeAlpha & VK_COMPOSITE_ALPHA_OPAQUE_BIT_KHR) ? VK_COMPOSITE_ALPHA_OPAQUE_BIT_KHR
                      : (caps.supportedCompositeAlpha & VK_COMPOSITE_ALPHA_INHERIT_BIT_KHR) ? VK_COMPOSITE_ALPHA_INHERIT_BIT_KHR
                      : (VkCompositeAlphaFlagBitsKHR)(caps.supportedCompositeAlpha & (~caps.supportedCompositeAlpha + 1));
    ci.presentMode = VK_PRESENT_MODE_FIFO_KHR; ci.clipped = VK_TRUE;
    ci.oldSwapchain = s->swapchain;
    VkSwapchainKHR nsc = VK_NULL_HANDLE;
    VkResult r = vkCreateSwapchainKHR(g.d, &ci, NULL, &nsc);
    VkSwapchainKHR old = s->swapchain; s->swapchain = VK_NULL_HANDLE;
    if (old) vkDestroySwapchainKHR(g.d, old, NULL);
    if (r != VK_SUCCESS) return fail(err, r == VK_ERROR_SURFACE_LOST_KHR || r == VK_ERROR_NATIVE_WINDOW_IN_USE_KHR ? NVN_GPU_E_REVOKED : NVN_GPU_E_UNSUPPORTED, "vkCreateSwapchainKHR 失败（%d）", (int)r);
    s->swapchain = nsc; s->format = pick.format; s->extent = ext;
    uint32_t ni = WSI_MAX_IMAGES;
    VkResult ir = vkGetSwapchainImagesKHR(g.d, nsc, &ni, s->images);
    if ((ir != VK_SUCCESS && ir != VK_INCOMPLETE) || !ni) { wsi_destroy_swapchain(s); return fail(err, NVN_GPU_E_UNSUPPORTED, "取不到交换链图"); }
    s->nimages = ni;
    VkSemaphoreCreateInfo si; memset(&si, 0, sizeof si); si.sType = VK_STRUCTURE_TYPE_SEMAPHORE_CREATE_INFO;
    for (uint32_t i = 0; i < ni + 1; i++) if (!s->acquire[i] && vkCreateSemaphore(g.d, &si, NULL, &s->acquire[i]) != VK_SUCCESS) { wsi_destroy_swapchain(s); return fail(err, NVN_GPU_E_OOM, "信号量创建失败"); }
    for (uint32_t i = 0; i < ni; i++) if (!s->rendered[i] && vkCreateSemaphore(g.d, &si, NULL, &s->rendered[i]) != VK_SUCCESS) { wsi_destroy_swapchain(s); return fail(err, NVN_GPU_E_OOM, "信号量创建失败"); }
    s->held = -1; s->outdated = 0; s->acquire_next = 0; s->acquire_pending = 0;
    return rc(NVN_GPU_OK);
}

nvn_gpu_rc nvn_gpu_surface_attach(void *native, nvn_gpu_surface *out, nvn_gpu_err *err) {
    if (!out) return fail(err, NVN_GPU_E_ARG, "out 为空");
    *out = NULL;
    if (!g_open || !session_accepting()) return fail(err, NVN_GPU_E_STOPPED, "后端未打开");
    if (g_surface) return fail(err, NVN_GPU_E_ORDER, "已经接着一个面");
    if (!native) return fail(err, NVN_GPU_E_ARG, "窗口为空");
    struct nvn_gpu_surface_s *s = calloc(1, sizeof *s);
    if (!s) return fail(err, NVN_GPU_E_OOM, "面结构分配失败");
    s->native = native; s->held = -1;
    VkResult r = nvn_plat_vk_surface_create(g.dev->instance, native, &s->surface);
    if (r != VK_SUCCESS || !s->surface) { free(s); return fail(err, NVN_GPU_E_UNSUPPORTED, "平台建表面失败（%d）", (int)r); }
    VkBool32 can = VK_FALSE;
    if (vkGetPhysicalDeviceSurfaceSupportKHR(g.phys, g.dev->queue_family, s->surface, &can) != VK_SUCCESS || !can) {
        vkDestroySurfaceKHR(g.dev->instance, s->surface, NULL); free(s);
        return fail(err, NVN_GPU_E_UNSUPPORTED, "图形队列族不能向这个表面呈现");
    }
    nvn_gpu_rc b = wsi_build(s, err);
    if (!nvn_gpu_ok(b)) { vkDestroySurfaceKHR(g.dev->instance, s->surface, NULL); free(s); return b; }
    s->gen = 1;
    g_surface = s; *out = s;
    return rc(NVN_GPU_OK);
}

nvn_gpu_rc nvn_gpu_surface_rebuild(nvn_gpu_surface s, nvn_gpu_err *err) {
    if (!s || !s->gen) return fail(err, NVN_GPU_E_REVOKED, "面已撤销");
    if (wsi_wait_drained(2000000000ull)) return fail(err, NVN_GPU_E_TIMEOUT, "在途的段没有完成，不能换交换链");
    uint64_t gen = s->gen;
    // 取了没等掉的信号量不能复用：新交换链用新的一套；旧的等旧交换链销毁（wsi_build 里）之后再销毁
    wsi_consume_acquired(s);
    VkSemaphore old_acq[WSI_MAX_IMAGES + 1], old_rend[WSI_MAX_IMAGES];
    memcpy(old_acq, s->acquire, sizeof old_acq); memcpy(old_rend, s->rendered, sizeof old_rend);
    memset(s->acquire, 0, sizeof s->acquire); memset(s->rendered, 0, sizeof s->rendered);
    nvn_gpu_rc b = wsi_build(s, err);
    for (uint32_t i = 0; i < WSI_MAX_IMAGES + 1; i++) if (old_acq[i]) vkDestroySemaphore(g.d, old_acq[i], NULL);
    for (uint32_t i = 0; i < WSI_MAX_IMAGES; i++) if (old_rend[i]) vkDestroySemaphore(g.d, old_rend[i], NULL);
    if (!nvn_gpu_ok(b)) { if (b.code == NVN_GPU_E_REVOKED) s->gen = 0; return b; }
    s->gen = gen + 1;
    return rc(NVN_GPU_OK);
}

uint64_t nvn_gpu_surface_gen(nvn_gpu_surface s) { return s ? s->gen : 0; }

nvn_gpu_rc nvn_gpu_surface_detach(nvn_gpu_surface s, uint64_t timeout_ns, nvn_gpu_err *err) {
    if (!s) return rc(NVN_GPU_OK);
    if (wsi_wait_drained(timeout_ns)) return fail(err, NVN_GPU_E_TIMEOUT, "最后一帧的呈现段没有完成证明");
    wsi_destroy_swapchain(s);
    if (s->surface) vkDestroySurfaceKHR(g.dev->instance, s->surface, NULL);
    if (g_surface == s) g_surface = NULL;
    s->gen = 0;
    free(s);
    return rc(NVN_GPU_OK);
}

nvn_gpu_rc nvn_gpu_drawable_acquire(nvn_gpu_surface s, uint64_t timeout_ns, void *plat_frame, nvn_gpu_drawable *out, nvn_gpu_err *err) {
    (void)plat_frame;
    if (out) memset(out, 0, sizeof *out);
    if (!s || !out) return fail(err, NVN_GPU_E_ARG, "参数为空");
    if (!s->gen) return fail(err, NVN_GPU_E_REVOKED, "面已撤销");
    if (s->outdated || !s->swapchain) return fail(err, NVN_GPU_E_OUTDATED, "交换链已过期，先重建");
    uint32_t idx, sem;
    if (s->held >= 0) { idx = (uint32_t)s->held; sem = s->held_sem; s->held = -1; }   // 上次取了没呈现的那张
    else {
        sem = s->acquire_next;
        VkResult r = vkAcquireNextImageKHR(g.d, s->swapchain, timeout_ns, s->acquire[sem], VK_NULL_HANDLE, &idx);
        if (r == VK_TIMEOUT || r == VK_NOT_READY) return fail(err, NVN_GPU_E_TIMEOUT, "没有空闲的交换链图");
        if (r == VK_ERROR_OUT_OF_DATE_KHR) { s->outdated = 1; return fail(err, NVN_GPU_E_OUTDATED, "交换链已过期"); }
        if (r == VK_ERROR_SURFACE_LOST_KHR) { s->gen = 0; return fail(err, NVN_GPU_E_REVOKED, "表面已丢失"); }
        if (r != VK_SUCCESS && r != VK_SUBOPTIMAL_KHR) return fail(err, r == VK_ERROR_DEVICE_LOST ? NVN_GPU_E_DEVICE : NVN_GPU_E_UNSUPPORTED, "vkAcquireNextImageKHR 失败（%d）", (int)r);
        if (r == VK_SUBOPTIMAL_KHR) s->outdated = 2;   // 这张还能用，呈现之后要重建
        s->acquire_pending |= 1u << sem;
        s->acquire_next = (s->acquire_next + 1) % (s->nimages + 1);
    }
    out->view = NULL; out->w = s->extent.width; out->h = s->extent.height; out->nvn_format = 0; out->gen = s->gen;
    out->token = (uint64_t)idx | (uint64_t)sem << 8 | 1ull << 16;
    return rc(NVN_GPU_OK);
}

void nvn_gpu_drawable_release(nvn_gpu_surface s, const nvn_gpu_drawable *dr) {
    if (!s || !dr || !(dr->token >> 16) || dr->gen != s->gen) return;
    s->held = (int)(dr->token & 0xff); s->held_sem = (uint32_t)(dr->token >> 8 & 0xff);   // 留作下次取图的结果
}

static void wsi_swap_barrier(VkCommandBuffer cb, VkImage img, VkImageLayout from, VkImageLayout to, VkAccessFlags sa, VkAccessFlags da, VkPipelineStageFlags ss, VkPipelineStageFlags ds) {
    VkImageMemoryBarrier b; memset(&b, 0, sizeof b);
    b.sType = VK_STRUCTURE_TYPE_IMAGE_MEMORY_BARRIER; b.oldLayout = from; b.newLayout = to;
    b.srcQueueFamilyIndex = b.dstQueueFamilyIndex = VK_QUEUE_FAMILY_IGNORED; b.image = img;
    b.subresourceRange = (VkImageSubresourceRange){VK_IMAGE_ASPECT_COLOR_BIT, 0, 1, 0, 1};
    b.srcAccessMask = sa; b.dstAccessMask = da;
    vkCmdPipelineBarrier(cb, ss, ds, 0, 0, NULL, 0, NULL, 1, &b);
}

nvn_gpu_rc nvn_gpu_present(nvn_gpu_surface s, const nvn_gpu_drawable *dr, const nvn_gpu_present_desc *d, uint64_t ticket,
                           nvn_gpu_presented_fn presented, void *user, nvn_gpu_err *err) {
    nvn_gpu_err local; if (!err) err = &local;
    nvn_gpu_rc out = rc(NVN_GPU_OK);
    nvn_gpu_shown shown = {ticket, NVN_GPU_SHOWN_DROPPED, 0.0};
    nvn_gpu_cmd ch = NULL;
    if (!s || !dr || !d || !d->src || !d->src->tex) { out = fail(err, NVN_GPU_E_ARG, "present 参数为空"); goto done; }
    if (!s->gen) { out = fail(err, NVN_GPU_E_REVOKED, "面已撤销"); goto done; }
    if (dr->gen != s->gen || !(dr->token >> 16)) { out = fail(err, NVN_GPU_E_OUTDATED, "drawable 不属于当前交换链"); goto done; }
    uint32_t idx = (uint32_t)(dr->token & 0xff), sem = (uint32_t)(dr->token >> 8 & 0xff);
    struct nvn_gpu_tex_s *st = d->src->tex;
    VkFormatProperties fp; vkGetPhysicalDeviceFormatProperties(g.phys, st->format, &fp);
    if (!(fp.optimalTilingFeatures & VK_FORMAT_FEATURE_BLIT_SRC_BIT) || st->samples > 1) {
        s->held = (int)idx; s->held_sem = sem;
        out = fail(err, NVN_GPU_E_UNSUPPORTED, "上屏源格式 0x%x 不能当缩放拷贝的源（或是多重采样）", st->nvn_format); goto done;
    }
    out = nvn_gpu_cmd_begin(NULL, &ch, err);
    if (!nvn_gpu_ok(out)) { s->held = (int)idx; s->held_sem = sem; goto done; }
    struct nvn_gpu_cmd_s *c = ch;
    cmd_ref(c, d->src, REF_VIEW);   // 源视图活到呈现段完成（它同时让贴图活着）：后端记录用的是 image，调用方录完就 release 视图也不能把 image 提前拆掉
    image_barrier(c, st, VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL);
    wsi_swap_barrier(c->cb, s->images[idx], VK_IMAGE_LAYOUT_UNDEFINED, VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL, 0, VK_ACCESS_TRANSFER_WRITE_BIT,
                     VK_PIPELINE_STAGE_TRANSFER_BIT, VK_PIPELINE_STAGE_TRANSFER_BIT);
    VkClearColorValue black; memset(&black, 0, sizeof black); black.float32[3] = 1.0f;
    { static int bars = -1; if (bars < 0) bars = nvn_plat_flag("nvk_bars", 0);   // 调试：黑边改成品红，截图上一眼分清「没呈现」和「呈现了一张黑图」
      if (bars) { black.float32[0] = 1.0f; black.float32[2] = 1.0f; } }
    VkImageSubresourceRange whole = {VK_IMAGE_ASPECT_COLOR_BIT, 0, 1, 0, 1};
    vkCmdClearColorImage(c->cb, s->images[idx], VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL, &black, 1, &whole);   // 目标矩形外是黑的
    wsi_swap_barrier(c->cb, s->images[idx], VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL, VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL, VK_ACCESS_TRANSFER_WRITE_BIT, VK_ACCESS_TRANSFER_WRITE_BIT,
                     VK_PIPELINE_STAGE_TRANSFER_BIT, VK_PIPELINE_STAGE_TRANSFER_BIT);   // 清与贴是对同一张图的两次写：之间要有屏障
    // 源：crop（宽高为 0 = 整个视图的首级）；目标：dst（宽高为 0 = 整张交换链图）。裁到各自范围内。
    uint32_t lw = st->w >> d->src->base_level, lh = st->h >> d->src->base_level; if (!lw) lw = 1; if (!lh) lh = 1;
    int32_t sx = d->crop[0], sy = d->crop[1], sw = d->crop[2], sh = d->crop[3];
    if (sw <= 0 || sh <= 0) { sx = 0; sy = 0; sw = (int32_t)lw; sh = (int32_t)lh; }
    int32_t dx = d->dst[0], dy = d->dst[1], dw = d->dst[2], dh = d->dst[3];
    if (dw <= 0 || dh <= 0) { dx = 0; dy = 0; dw = (int32_t)s->extent.width; dh = (int32_t)s->extent.height; }
    int ok = sx >= 0 && sy >= 0 && (uint32_t)(sx + sw) <= lw && (uint32_t)(sy + sh) <= lh && dx >= 0 && dy >= 0 && (uint32_t)(dx + dw) <= s->extent.width && (uint32_t)(dy + dh) <= s->extent.height;
    if (ok) {
        VkImageBlit bl; memset(&bl, 0, sizeof bl);
        bl.srcSubresource = (VkImageSubresourceLayers){VK_IMAGE_ASPECT_COLOR_BIT, d->src->base_level, d->src->base_layer, 1};
        bl.srcOffsets[0] = (VkOffset3D){sx, d->flip_y ? sy + sh : sy, 0}; bl.srcOffsets[1] = (VkOffset3D){sx + sw, d->flip_y ? sy : sy + sh, 1};   // flip_y：两个 y 对调，贴出来上下翻转
        bl.dstSubresource = (VkImageSubresourceLayers){VK_IMAGE_ASPECT_COLOR_BIT, 0, 0, 1};
        bl.dstOffsets[0] = (VkOffset3D){dx, dy, 0}; bl.dstOffsets[1] = (VkOffset3D){dx + dw, dy + dh, 1};
        VkFilter filt = d->filter && (fp.optimalTilingFeatures & VK_FORMAT_FEATURE_SAMPLED_IMAGE_FILTER_LINEAR_BIT) ? VK_FILTER_LINEAR : VK_FILTER_NEAREST;
        vkCmdBlitImage(c->cb, st->image, VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL, s->images[idx], VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL, 1, &bl, filt);
    }
    wsi_swap_barrier(c->cb, s->images[idx], VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL, VK_IMAGE_LAYOUT_PRESENT_SRC_KHR, VK_ACCESS_TRANSFER_WRITE_BIT, 0,
                     VK_PIPELINE_STAGE_TRANSFER_BIT, VK_PIPELINE_STAGE_BOTTOM_OF_PIPE_BIT);
    image_barrier(c, st, VK_IMAGE_LAYOUT_GENERAL);   // 源图转回常驻布局（见 backend_vulkan.c「图像布局」：别的段一律按 GENERAL 用它）
    // 内部段：摘出活动表，自己提交（等取图信号量、发呈现信号量），交给完成线程只做回收
    pthread_mutex_lock(&g_mu);
    { struct nvn_gpu_cmd_s **pp = &g.live; while (*pp && *pp != c) pp = &(*pp)->live_next; if (*pp) *pp = c->live_next; }
    pthread_mutex_unlock(&g_mu);
    struct vk_segment *seg = calloc(1, sizeof *seg);
    VkFence fence = VK_NULL_HANDLE;
    VkFenceCreateInfo fi; memset(&fi, 0, sizeof fi); fi.sType = VK_STRUCTURE_TYPE_FENCE_CREATE_INFO;
    VkResult r = !ok ? VK_ERROR_UNKNOWN : !seg ? VK_ERROR_OUT_OF_HOST_MEMORY : vkEndCommandBuffer(c->cb);
    if (r == VK_SUCCESS) r = vkCreateFence(g.d, &fi, NULL, &fence);
    pthread_mutex_lock(&g_submit_mu);
    if (r == VK_SUCCESS) {
        VkPipelineStageFlags wait_stage = VK_PIPELINE_STAGE_TRANSFER_BIT;
        VkSubmitInfo si; memset(&si, 0, sizeof si);
        VkCommandBuffer cbs[2];
        si.sType = VK_STRUCTURE_TYPE_SUBMIT_INFO; si.commandBufferCount = submit_cbs(c, cbs); si.pCommandBuffers = cbs;
        si.waitSemaphoreCount = 1; si.pWaitSemaphores = &s->acquire[sem]; si.pWaitDstStageMask = &wait_stage;
        si.signalSemaphoreCount = 1; si.pSignalSemaphores = &s->rendered[idx];
        r = si.commandBufferCount ? vkQueueSubmit(g.queue, 1, &si, fence) : VK_ERROR_OUT_OF_HOST_MEMORY;
    }
    if (r != VK_SUCCESS) {
        pthread_mutex_unlock(&g_submit_mu);
        if (fence) vkDestroyFence(g.d, fence, NULL);
        free(seg);
        finish_cmd(c, 0);   // 回滚这一段记下的布局变化
        s->held = (int)idx; s->held_sem = sem;
        out = fail(err, !ok ? NVN_GPU_E_ARG : r == VK_ERROR_DEVICE_LOST ? NVN_GPU_E_DEVICE : NVN_GPU_E_OOM, !ok ? "上屏矩形越界" : "呈现段提交失败（%d）", (int)r);
        goto done;
    }
    s->acquire_pending &= ~(1u << sem);   // 这把信号量已交给呈现段去等
    seg->cmd = c; seg->cb = c->cb; seg->fence = fence; seg->submitted = 1; seg->executed = 1; seg->internal = 1;
    enqueue_segment(&g, seg);
    VkPresentInfoKHR pi; memset(&pi, 0, sizeof pi);
    pi.sType = VK_STRUCTURE_TYPE_PRESENT_INFO_KHR; pi.waitSemaphoreCount = 1; pi.pWaitSemaphores = &s->rendered[idx];
    pi.swapchainCount = 1; pi.pSwapchains = &s->swapchain; pi.pImageIndices = &idx;
    r = vkQueuePresentKHR(g.queue, &pi);
    pthread_mutex_unlock(&g_submit_mu);
    s->presents++;
    if (r == VK_SUCCESS || r == VK_SUBOPTIMAL_KHR) {
        shown.status = NVN_GPU_SHOWN_UNKNOWN;   // 交给了呈现引擎，但没有实际上屏时刻（没有 CAP_SHOWN_TIME）
        if (r == VK_SUBOPTIMAL_KHR || s->outdated == 2) s->outdated = 1;
    } else if (r == VK_ERROR_OUT_OF_DATE_KHR) { s->outdated = 1; out = fail(err, NVN_GPU_E_OUTDATED, "呈现时交换链已过期"); }
    else if (r == VK_ERROR_SURFACE_LOST_KHR) { s->gen = 0; out = fail(err, NVN_GPU_E_REVOKED, "表面已丢失"); }
    else out = fail(err, r == VK_ERROR_DEVICE_LOST ? NVN_GPU_E_DEVICE : NVN_GPU_E_UNSUPPORTED, "vkQueuePresentKHR 失败（%d）", (int)r);
done:
    if (presented) { g_in_callback++; presented(user, &shown); g_in_callback--; }
    return out;
}
