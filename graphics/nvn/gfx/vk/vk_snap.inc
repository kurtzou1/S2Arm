// 即时存档：Vulkan 出图层的存 / 取（hle_vk.m 末尾包含）。S2A_SNAP_MODE=0 且不是恢复局时（开关见 runtime/src/snapsw.c，苹果端缺省开）这里的入口都不会被调到，分配器也不进区。
//
// 为什么是「固定地址区」而不是像 GL 那样按名字重建：Vulkan 的每个句柄就是这一层对象的宿主地址（游戏把它们存进自己的内存），对象之间互相指
//   （视图 → 图像、缓冲 → 内存、描述符集 → 布局 / 池……），命令缓冲是嵌着句柄的字节流，vkMapMemory 交出持久映射指针。所以快照开时对象、对象自有的数组、
//   设备内存都放在固定地址区（hle_vk.m vs_alloc / mem_buf，区由 runtime/src/vawin.c 在恢复局按快照原址占好），存档把区里用到的段整段存下，恢复按原址放回：
//   句柄、互指、命令流原样有效。要做的只剩两件：
//   ① 对象里的 Metal 对象（__strong 字段）是旧进程的指针：先清零（不 release），再按各自的建法重建（下面 vs_rebuild）；
//   ② 指向区外宿主数据的指针（格式表 fmt_t*、着色器表 shinfo*、现编条目 rt_ent*）：格式表按下标平移，后两者随重建重取。
//   交给游戏的区外宿主地址（g_pdev / g_device / g_queue、取函数地址）按身份登记，快照引擎换算（runtime/src/snapshot.c handout）。
// 已知限制（这一版）：宽屏放宽是每个进程各自的状态，恢复出来的图像 / 视图按不放宽处理（wid 清 0）；GPU 私有图像内容整张存，超 256 MB 或格式不认的只存描述（下一帧重画）。

#include "../../../../runtime/src/snapfmt.h"
// 交出指针登记：真定义在 runtime/src/snapshot.c（同一个程序里强定义盖过）；这里给空的弱缺省，只链图形库的单测在本文件内就解析掉，
//   不去 libnvn.a 里另一份弱缺省所在的 nvn2_codec.c.o 拉整个成员（它还要 guest_sym 等单测没有的符号）
__attribute__((weak)) void s2a_snap_handout_id(uint64_t v, const char *id) { (void)v; (void)id; }
__attribute__((weak)) void s2a_snap_handout_range(uint64_t lo, uint64_t n, const char *name) { (void)lo; (void)n; (void)name; }
int nvn_snap_tex_save(FILE *f, void *tex) __attribute__((weak)); void *nvn_snap_tex_load(FILE *f) __attribute__((weak));   // 直连层 nvn_snap.inc
// 这几个弱符号的「弱链接[nvntest]」登记写在 hle_vk.m（登记工具只扫 .m / .c）
void vs_ho(const void *p, const char *fmt, const char *arg) {
    if (!p || !s2a_snap_mode || !s2a_snap_mode()) return;
    char id[128]; snprintf(id, sizeof id, fmt, arg); s2a_snap_handout_id((uint64_t)(uintptr_t)p, id);
}
__attribute__((constructor)) static void vs_ranges(void) {   // 静态区的三个句柄：快照引擎按「同名段的新起点 + 段内偏移」换算
    s2a_snap_handout_range((uint64_t)(uintptr_t)&g_pdev, sizeof g_pdev, "vk.pdev");
    s2a_snap_handout_range((uint64_t)(uintptr_t)&g_device, sizeof g_device, "vk.device");
    s2a_snap_handout_range((uint64_t)(uintptr_t)&g_queue, sizeof g_queue, "vk.queue");
}
void *s2a_vk_entry(const char *name) __attribute__((weak_import));   // graphics/nvn/host_adapt.m（交给游戏的 vk* 地址，含切栈桩；登记见 hle_vk.m）
uint64_t vk_snap_resolve(const char *id) {   // 快照引擎：身份 → 本进程的值（不认的回 0）
    if (!strncmp(id, "vk:proc:", 8)) return (uint64_t)(uintptr_t)vk_lookup(id + 8);
    if (!strncmp(id, "vk:export:", 10)) return s2a_vk_entry ? (uint64_t)(uintptr_t)s2a_vk_entry(id + 10) : 0;
    return 0;
}
int vk_snap_used(void) { return g_vs && g_objects; }

// ---------- 建法（快照开时记进区） ----------
enum { VS_MAXST = 8, VS_MAXVB = 32, VS_MAXVA = 32, VS_MAXVP = 16, VS_MAXCBA = 8, VS_MAXDY = 64 };
typedef struct {
    uint32_t kind;   // 1 图形 / 2 计算
    VkGraphicsPipelineCreateInfo ci; VkPipelineShaderStageCreateInfo st[VS_MAXST]; char key[VS_MAXST][17];
    VkPipelineVertexInputStateCreateInfo vi; VkVertexInputBindingDescription vb[VS_MAXVB]; VkVertexInputAttributeDescription va[VS_MAXVA];
    VkPipelineInputAssemblyStateCreateInfo ia; VkPipelineViewportStateCreateInfo vp; VkViewport vps[VS_MAXVP]; VkRect2D scs[VS_MAXVP];
    VkPipelineRasterizationStateCreateInfo rs; VkPipelineMultisampleStateCreateInfo ms; VkSampleMask smask[2];
    VkPipelineDepthStencilStateCreateInfo ds; VkPipelineColorBlendStateCreateInfo cb; VkPipelineColorBlendAttachmentState cba[VS_MAXCBA];
    VkPipelineDynamicStateCreateInfo dy; VkDynamicState dys[VS_MAXDY];
    char ckey[17]; VkPipelineLayout clayout;   // 计算管线
} vs_recipe;
#define VS_CP(dst, src) do { if (src) { (dst) = *(src); (dst).pNext = NULL; } } while (0)
static void *vs_pipe_recipe(const VkGraphicsPipelineCreateInfo *ci) {
    if (ci->stageCount > VS_MAXST || (ci->pVertexInputState && (ci->pVertexInputState->vertexBindingDescriptionCount > VS_MAXVB || ci->pVertexInputState->vertexAttributeDescriptionCount > VS_MAXVA))
        || (ci->pViewportState && (ci->pViewportState->viewportCount > VS_MAXVP || ci->pViewportState->scissorCount > VS_MAXVP))
        || (ci->pColorBlendState && ci->pColorBlendState->attachmentCount > VS_MAXCBA) || (ci->pDynamicState && ci->pDynamicState->dynamicStateCount > VS_MAXDY)) {
        static int once; if (!once++) LOG("[vk] 【红】 即时存档：管线创建信息超出建法表容量（阶段 / 顶点输入 / 视口 / 混合 / 动态状态），这条管线恢复后建不回");
        return NULL;
    }
    vs_recipe *r = vs_alloc(sizeof *r); r->kind = 1; r->ci = *ci; r->ci.pNext = NULL; r->ci.basePipelineHandle = VK_NULL_HANDLE;
    for (uint32_t s = 0; s < ci->stageCount; s++) { r->st[s] = ci->pStages[s]; r->st[s].pNext = NULL; r->st[s].pName = "main"; r->st[s].pSpecializationInfo = NULL;
        memcpy(r->key[s], ci->pStages[s].module->key, 17); r->st[s].module = VK_NULL_HANDLE; }
    if (ci->pVertexInputState) { VS_CP(r->vi, ci->pVertexInputState);
        memcpy(r->vb, ci->pVertexInputState->pVertexBindingDescriptions, ci->pVertexInputState->vertexBindingDescriptionCount * sizeof *r->vb);
        memcpy(r->va, ci->pVertexInputState->pVertexAttributeDescriptions, ci->pVertexInputState->vertexAttributeDescriptionCount * sizeof *r->va); }
    VS_CP(r->ia, ci->pInputAssemblyState);
    if (ci->pViewportState) { VS_CP(r->vp, ci->pViewportState);
        if (ci->pViewportState->pViewports) memcpy(r->vps, ci->pViewportState->pViewports, ci->pViewportState->viewportCount * sizeof *r->vps);
        if (ci->pViewportState->pScissors) memcpy(r->scs, ci->pViewportState->pScissors, ci->pViewportState->scissorCount * sizeof *r->scs); }
    VS_CP(r->rs, ci->pRasterizationState);
    if (ci->pMultisampleState) { VS_CP(r->ms, ci->pMultisampleState); if (ci->pMultisampleState->pSampleMask) memcpy(r->smask, ci->pMultisampleState->pSampleMask, sizeof r->smask); }
    VS_CP(r->ds, ci->pDepthStencilState);
    if (ci->pColorBlendState) { VS_CP(r->cb, ci->pColorBlendState); memcpy(r->cba, ci->pColorBlendState->pAttachments, ci->pColorBlendState->attachmentCount * sizeof *r->cba); }
    if (ci->pDynamicState) { VS_CP(r->dy, ci->pDynamicState); memcpy(r->dys, ci->pDynamicState->pDynamicStates, ci->pDynamicState->dynamicStateCount * sizeof *r->dys); }
    return r;
}
static void *vs_cpipe_recipe(VkShaderModule m, VkPipelineLayout layout) { vs_recipe *r = vs_alloc(sizeof *r); r->kind = 2; memcpy(r->ckey, m->key, 17); r->clayout = layout; return r; }
// 恢复：把建法里的指针接回本结构里的数组（区原址放回，数组地址不变；这一步只为写清楚哪些是有效的），并按键临时建模块
static VkShaderModule vs_temp_module(const char *key) {
    const vs_spv *e = vs_spv_find(key); if (!e) return NULL;
    VkShaderModule m = zalloc(sizeof *m); mod_fill(m, e->code, e->size); return m;
}
static void vs_drop_module(VkShaderModule m) { if (!m) return; m->fn = m->fn_d = nil; m->spv = nil; free(m); }
static int vs_pipe_rebuild(VkPipeline p) {
    vs_recipe *r = p->recipe; if (!r) return 0;
    if (r->kind == 2) { VkShaderModule m = vs_temp_module(r->ckey); if (!m) return 0; cpipe_fill(p, m, r->clayout); vs_drop_module(m); return p->cps != nil || p->pend_c != NULL; }
    VkGraphicsPipelineCreateInfo ci = r->ci; VkShaderModule tm[VS_MAXST] = {0}; int ok = 1;
    for (uint32_t s = 0; s < ci.stageCount; s++) { tm[s] = vs_temp_module(r->key[s]); r->st[s].module = tm[s]; ok &= tm[s] != NULL; }
    ci.pStages = r->st;
    ci.pVertexInputState = r->ci.pVertexInputState ? &r->vi : NULL; if (ci.pVertexInputState) { r->vi.pVertexBindingDescriptions = r->vb; r->vi.pVertexAttributeDescriptions = r->va; }
    ci.pInputAssemblyState = r->ci.pInputAssemblyState ? &r->ia : NULL;
    ci.pViewportState = r->ci.pViewportState ? &r->vp : NULL; if (ci.pViewportState) { r->vp.pViewports = r->vp.pViewports ? r->vps : NULL; r->vp.pScissors = r->vp.pScissors ? r->scs : NULL; }
    ci.pRasterizationState = r->ci.pRasterizationState ? &r->rs : NULL;
    ci.pMultisampleState = r->ci.pMultisampleState ? &r->ms : NULL; if (ci.pMultisampleState && r->ms.pSampleMask) r->ms.pSampleMask = r->smask;
    ci.pDepthStencilState = r->ci.pDepthStencilState ? &r->ds : NULL;
    ci.pColorBlendState = r->ci.pColorBlendState ? &r->cb : NULL; if (ci.pColorBlendState) r->cb.pAttachments = r->cba;
    ci.pDynamicState = r->ci.pDynamicState ? &r->dy : NULL; if (ci.pDynamicState) r->dy.pDynamicStates = r->dys;
    if (ok) pipe_fill(p, &ci);
    for (uint32_t s = 0; s < ci.stageCount; s++) { vs_drop_module(tm[s]); r->st[s].module = VK_NULL_HANDLE; }
    return ok && (p->pso != nil || p->pend_pd != nil);
}

// ---------- 存 ----------
#define VS_FILE_MAGIC 0x31534B56u   // "VKS1"
typedef struct { uint32_t magic, ver, nseg, nmem, nmemobj, nimg; uint64_t vs, objects, instances, spv, fmts; } vs_hdr;
static int vs_w(FILE *f, const void *p, size_t n) { return fwrite(p, 1, n, f) == n; }
static int vs_r(FILE *f, void *p, size_t n) { return fread(p, 1, n, f) == n; }
int vk_snap_save(const char *path) {
    if (!vk_snap_used()) return 0;
    h_vkQueueWaitIdle(&g_queue);   // 排空：已提交的都做完（冻结后游戏线程不会再提交）
    FILE *f = fopen(path, "wb"); if (!f) return -1;
    pthread_mutex_lock(&g_object_mu); pthread_mutex_lock(&g_vs_mu);
    // 设备内存对象：旧的内容地址（恢复时按它 bytesNoCopy 包回）；GPU 私有图像：按图像地址存描述 + 内容
    uint32_t nmo = 0, nim = 0; for (vk_object *o = g_objects; o; o = o->next) { if (o->kind == O_MEMORY && ((VkDeviceMemory)o->ptr)->buf) nmo++; if (o->kind == O_IMAGE && ((VkImage)o->ptr)->tex && !((VkImage)o->ptr)->pitch) nim++; }
    vs_hdr h = {VS_FILE_MAGIC, 1, g_vs->nseg, g_vs_nmem, nmo, nim, (uint64_t)(uintptr_t)g_vs, (uint64_t)(uintptr_t)g_objects, (uint64_t)(uintptr_t)g_instances, (uint64_t)(uintptr_t)g_vs_spv, (uint64_t)(uintptr_t)g_fmts};
    int ok = vs_w(f, &h, sizeof h); uint64_t bytes = 0;
    for (uint32_t i = 0; ok && i < g_vs->nseg; i++) { ok = vs_w(f, &g_vs->seg[i], sizeof g_vs->seg[i]) && vs_w(f, (void *)(uintptr_t)g_vs->seg[i].at, g_vs->seg[i].len); bytes += g_vs->seg[i].len; }
    for (uint32_t i = 0; ok && i < g_vs_nmem; i++) { ok = vs_w(f, &g_vs_mem[i], sizeof g_vs_mem[i]) && vs_w(f, (void *)(uintptr_t)g_vs_mem[i].at, g_vs_mem[i].len); bytes += g_vs_mem[i].len; }
    for (vk_object *o = g_objects; ok && o; o = o->next) if (o->kind == O_MEMORY && ((VkDeviceMemory)o->ptr)->buf) {
        VkDeviceMemory m = o->ptr; uint64_t r[3] = {(uint64_t)(uintptr_t)m, (uint64_t)(uintptr_t)m->buf.contents, m->buf.length}; ok = vs_w(f, r, sizeof r); }
    int nnot = 0;
    for (vk_object *o = g_objects; ok && o; o = o->next) if (o->kind == O_IMAGE && ((VkImage)o->ptr)->tex && !((VkImage)o->ptr)->pitch) {
        VkImage im = o->ptr; uint64_t a = (uint64_t)(uintptr_t)im; ok = vs_w(f, &a, 8); int k = ok && nvn_snap_tex_save ? nvn_snap_tex_save(f, (__bridge void *)im->tex) : -1; ok = k >= 0; nnot += k == 0; }
    pthread_mutex_unlock(&g_vs_mu); pthread_mutex_unlock(&g_object_mu);
    ok &= fclose(f) == 0;
    LOG("[vk] %s即时存档：Vulkan 出图层 区段 %u 段、设备内存 %u 段，共 %.1f MB；设备内存对象 %u 个、GPU 私有图像 %u 张（只存描述 %d 张）", ok ? "" : "【红】 ", h.nseg, h.nmem, bytes / 1048576.0, nmo, nim, nnot);
    return ok ? 0 : -1;
}

// ---------- 取 ----------
#define VS_ZERO(field) memset((void *)&(field), 0, sizeof(field))   // 清掉旧进程的 Metal 指针（不 release）
// ---------- 布局转换：换版本后宿主结构布局变了 ----------
// 区按原址放回，句柄（= 对象地址）、对象互指、命令流里嵌的句柄都只认地址：对象就地按新布局转，地址不变，什么指针都不用改。
//   块能用的字节：尺寸档块 16 << cls；整段切的大块按记下的 size 向上取 16 KB。对象分配时另留 VS_ROOM（hle_vk.m），长一点也放得下；
//   新布局放不下原块的（长得太多）不转、黄字点名，照常继续（校验不过不拒绝）
static uint64_t vs_cap(const void *p) {
    const vs_blk *b = (const vs_blk *)p - 1;
    return b->magic != VS_MAGIC ? 0 : b->cls < VS_NCLS ? 16ull << b->cls : (b->size + 16383) & ~16383ull;
}
typedef struct { snap_conv *e; uint8_t *tmp; uint32_t ok, room; } vs_cv;
static vs_cv vs_cv_get(const char *name) { vs_cv c = {snap_conv_get(name), NULL, 0, 0}; if (c.e) c.tmp = malloc(c.e->o->size ? c.e->o->size : 1); return c; }
static void vs_cv_one(vs_cv *c, void *p, uint64_t count) {   // p 起 count 个（对象 count = 1；对象自有数组按块里记的长度算个数）
    if (!c->e || !c->tmp || !p || !vs_has(p) || !count) return;
    vs_blk *b = (vs_blk *)p - 1;
    if (count > 1) { uint8_t *t = realloc(c->tmp, (size_t)(count * c->e->o->size)); if (!t) { c->room++; return; } c->tmp = t; }
    if (snap_conv_inplace(c->e, p, count, vs_cap(p), c->tmp)) { b->size = count * c->e->c->size; c->ok++; } else c->room++;
}
static void vs_cv_done(vs_cv *c, const char *name) {
    if (!c->e) return;
    LOG("[vk] %s即时存档恢复：「%s」布局变了，区里就地按新布局转 %u 个%s", c->room ? "【黄】" : "", name, c->ok, c->room ? "；原块放不下新布局、没转的见下一行" : "");
    if (c->room) LOG("[vk] 【黄】 即时存档恢复：「%s」%u 个原块放不下新布局（新 %u 字节），没转，照常继续", name, c->room, c->e->c->size);
    free(c->tmp);
}
static const char *vs_kind_name(object_kind k) {
    switch (k) {
        case O_MEMORY: return "vk.memory"; case O_BUFFER_VIEW: return "vk.bview"; case O_IMAGE: return "vk.image"; case O_IMAGE_VIEW: return "vk.view";
        case O_SAMPLER: return "vk.sampler"; case O_SHADER: return "vk.module"; case O_PIPELINE: return "vk.pipeline"; case O_LAYOUT: return "vk.layout";
        case O_SET: return "vk.set"; case O_COMMAND: return "vk.cmd"; case O_QUERY: return "vk.query"; case O_SWAPCHAIN: return "vk.swap";
        case O_BUFFER: return "vk.buffer"; case O_RENDERPASS: return "vk.rpass"; case O_FRAMEBUFFER: return "vk.fb";
        default: return NULL;   // O_PLAIN（信号量、池、模板等没登记布局指纹的）/ O_FENCE
    }
}
static void vs_conv_objects(void) {
    static const char *const others[] = {"vk.vs_meta", "vk.vs_blk", "vk.instance"};   // 分配器自己的账 / 实例链：不在对象表里，这一版不转
    for (size_t i = 0; i < sizeof others / sizeof *others; i++) if (snap_conv_get(others[i])) LOG("[vk] 【黄】 即时存档恢复：「%s」布局变了，这一版不转，照常继续", others[i]);
    // ① 对象表节点本身：布局变了先按旧布局的 next 走完整条链记下节点，再逐个就地转（转完才能按新布局走）
    vs_cv cn = vs_cv_get("vk.object");
    if (cn.e) { const snap_fld *nx = sl_find(cn.e->o, "next");
        if (!nx || nx->size != 8) LOG("[vk] 【黄】 即时存档恢复：「vk.object」旧布局里找不到 next，对象表没转");
        else { size_t cap = 0, n = 0; void **v = NULL;
            for (uint8_t *o = (uint8_t *)g_objects; o; ) { if (n == cap && !(v = realloc(v, (cap = cap ? cap * 2 : 1024) * sizeof *v))) break; v[n++] = o; uint64_t q; memcpy(&q, o + nx->off, 8); o = (uint8_t *)(uintptr_t)q; }
            for (size_t i = 0; i < n; i++) vs_cv_one(&cn, v[i], 1);
            free(v); } }
    vs_cv_done(&cn, "vk.object");
    // ② 各种对象：按种类认布局；③ 对象自有的数组 / 建法：描述符集的描述符数组、管线的建法
    vs_cv cv[O_FRAMEBUFFER + 1]; int any = 0;
    for (int k = 0; k <= O_FRAMEBUFFER; k++) { const char *nm = vs_kind_name((object_kind)k); cv[k] = nm ? vs_cv_get(nm) : (vs_cv){0}; any |= cv[k].e != NULL; }
    vs_cv cd = vs_cv_get("vk.desc"), cr = vs_cv_get("vk.recipe");
    if (!any && !cd.e && !cr.e) return;
    for (vk_object *o = g_objects; o; o = o->next) {
        if (o->kind <= O_FRAMEBUFFER) vs_cv_one(&cv[o->kind], o->ptr, 1);
        if (o->kind == O_SET && cd.e) { VkDescriptorSet st = o->ptr; if (st->d && vs_has(st->d)) vs_cv_one(&cd, st->d, ((vs_blk *)st->d - 1)->size / cd.e->o->size); }
        if (o->kind == O_PIPELINE && cr.e) vs_cv_one(&cr, ((VkPipeline)o->ptr)->recipe, 1);
    }
    for (int k = 0; k <= O_FRAMEBUFFER; k++) vs_cv_done(&cv[k], vs_kind_name((object_kind)k));
    vs_cv_done(&cd, "vk.desc"); vs_cv_done(&cr, "vk.recipe");
}
static vk_object *vs_node(const void *ptr, uint64_t seq) { for (vk_object *o = g_objects; o; o = o->next) if (o->ptr == ptr) return o->seq == seq ? o : NULL; return NULL; }
int vk_snap_restore(const char *path) {
    FILE *f = fopen(path, "rb"); if (!f) return -1;
    dev_init();
    vs_hdr h; if (!vs_r(f, &h, sizeof h) || h.magic != VS_FILE_MAGIC || h.ver > 1) { fclose(f); LOG("[vk] 【红】 即时存档恢复：Vulkan 快照段头不认"); return -1; }
    int ok = 1; uint64_t bytes = 0;
    for (uint32_t i = 0; ok && i < h.nseg + h.nmem; i++) {   // 区段与设备内存段：按原址开可写、读回内容
        struct { uint64_t at, len; } sg; ok = vs_r(f, &sg, sizeof sg);
        if (ok && mmap((void *)(uintptr_t)sg.at, sg.len, PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANON | MAP_FIXED, -1, 0) != (void *)(uintptr_t)sg.at) { LOG("[vk] 【红】 即时存档恢复：%#llx 开不了可写", (unsigned long long)sg.at); ok = 0; }
        ok = ok && vs_r(f, (void *)(uintptr_t)sg.at, sg.len); bytes += sg.len;
        if (ok && i >= h.nseg) vs_note_mem((void *)(uintptr_t)sg.at, sg.len);
    }
    if (!ok) { fclose(f); return -1; }
    g_vs = (vs_meta *)(uintptr_t)h.vs; g_vs_on = 1; g_objects = (vk_object *)(uintptr_t)h.objects; g_instances = (VkInstance)(uintptr_t)h.instances; g_vs_spv = (vs_spv *)(uintptr_t)h.spv;
    vs_conv_objects();   // ⓪ 布局变了的对象先就地按新布局转（下面全按新布局读写）
    intptr_t fdelta = (intptr_t)(uintptr_t)g_fmts - (intptr_t)h.fmts;
    // ① 清掉全部对象里的 Metal 指针、平移格式表指针、实例的锁重建
    for (VkInstance i = g_instances; i; i = i->session_next) { pthread_mutex_init(&i->debug_mu, NULL); pthread_cond_init(&i->debug_cv, NULL); }
    for (vk_object *o = g_objects; o; o = o->next) switch (o->kind) {
        case O_MEMORY: { VkDeviceMemory m = o->ptr; VS_ZERO(m->buf); atomic_store(&m->raw, NULL); break; }
        case O_BUFFER_VIEW: { VkBufferView v = o->ptr; VS_ZERO(v->tex); if (v->f) v->f = (const fmt_t *)((intptr_t)v->f + fdelta); break; }
        case O_IMAGE: { VkImage im = o->ptr; VS_ZERO(im->tex); if (im->f) im->f = (const fmt_t *)((intptr_t)im->f + fdelta); im->wid = 0; break; }
        case O_IMAGE_VIEW: { VkImageView v = o->ptr; VS_ZERO(v->tex); v->wid = 0; break; }
        case O_SAMPLER: VS_ZERO(((VkSampler)o->ptr)->s); break;
        case O_SHADER: { VkShaderModule m = o->ptr; VS_ZERO(m->fn); VS_ZERO(m->fn_d); VS_ZERO(m->spv); m->si = NULL; m->rt = NULL; break; }
        case O_PIPELINE: { VkPipeline p = o->ptr; VS_ZERO(p->pso); VS_ZERO(p->dss); VS_ZERO(p->dsd); VS_ZERO(p->dss_dyn); VS_ZERO(p->cps); VS_ZERO(p->se_spv); VS_ZERO(p->se_pd);
            VS_ZERO(p->pso_se); VS_ZERO(p->cps_se); VS_ZERO(p->pend_pd); VS_ZERO(p->pend_spv); p->vs = p->fs = p->cs = NULL; p->pend_v = p->pend_f = p->pend_c = NULL; p->se_state = 0; break; }
        case O_SET: { VkDescriptorSet s = o->ptr; for (uint32_t k = 0; s->L && k < umax(1, s->L->total); k++) { VS_ZERO(s->d[k].buf); VS_ZERO(s->d[k].tex); VS_ZERO(s->d[k].smp); } break; }
        case O_FENCE: { VkFence fe = o->ptr; if (atomic_load(&fe->val) != FENCE_NONE) atomic_store(&fe->val, 0); break; }
        case O_QUERY: { VkQueryPool q = o->ptr; memset(q->ticket, 0, umax(1, q->n) * sizeof *q->ticket); break; }
        case O_SWAPCHAIN: memset(((VkSwapchainKHR)o->ptr)->ticket, 0, sizeof ((VkSwapchainKHR)o->ptr)->ticket); break;
        default: break;
    }
    // ② 按建法重建（先内存与图像，视图 / 描述符靠它们）
    uint32_t nmem = 0, nimg = 0, nbad = 0;
    for (uint32_t i = 0; ok && i < h.nmemobj; i++) { uint64_t r[3]; ok = vs_r(f, r, sizeof r); if (!ok) break;
        VkDeviceMemory m = (VkDeviceMemory)(uintptr_t)r[0];
        m->buf = (__bridge_transfer id<MTLBuffer>)mtl_nocopy_buf((void *)(uintptr_t)r[1], r[2]);   // 同一记账入口（#1827）
        if (m->buf) { atomic_store_explicit(&m->raw, (__bridge void *)m->buf, memory_order_release); nmem++; } else nbad++; }
    for (uint32_t i = 0; ok && i < h.nimg; i++) { uint64_t a; ok = vs_r(f, &a, 8) && nvn_snap_tex_load; if (!ok) break;
        void *t = nvn_snap_tex_load(f); if (!t) { ok = 0; break; } VkImage im = (VkImage)(uintptr_t)a; im->tex = (__bridge_transfer id<MTLTexture>)t; nimg++;
        if (im->swap) im->serial = mtl_ext_tex((__bridge void *)im->tex); }
    fclose(f);
    if (!ok) { LOG("[vk] 【红】 即时存档恢复：Vulkan 快照读不全"); return -1; }
    uint32_t nview = 0, nsmp = 0, nmod = 0, npipe = 0, nset = 0, npbad = 0;
    for (vk_object *o = g_objects; o; o = o->next) if (o->kind == O_IMAGE) { VkImage im = o->ptr;   // 线性图像：从它绑的内存缓冲派生
        if (im->pitch && im->lmem && h_vkBindImageMemory(&g_device, im, im->lmem, im->loff)) nbad++; }
    for (vk_object *o = g_objects; o; o = o->next) switch (o->kind) {
        case O_IMAGE_VIEW: { VkImageView v = o->ptr; if (v->img && v->img->tex) { v->tex = wd_rederive(v); nview++; } else nbad++; break; }
        case O_SAMPLER: samp_fill(o->ptr, &((VkSampler)o->ptr)->ci); nsmp++; break;
        case O_SHADER: { VkShaderModule m = o->ptr; const vs_spv *e = vs_spv_find(m->key); if (e) { mod_fill(m, e->code, e->size); nmod++; } else nbad++; break; }
        default: break;
    }
    for (vk_object *o = g_objects; o; o = o->next) if (o->kind == O_PIPELINE) { if (vs_pipe_rebuild(o->ptr)) npipe++; else npbad++; }
    for (vk_object *o = g_objects; o; o = o->next) if (o->kind == O_SET) { VkDescriptorSet s = o->ptr; nset++;
        for (uint32_t k = 0; s->L && k < umax(1, s->L->total); k++) { desc_t *e = &s->d[k]; vk_object *nt = e->src_t ? vs_node(e->src_t, e->seq_t) : NULL, *ns = e->src_s ? vs_node(e->src_s, e->seq_s) : NULL;
            if (ns) e->smp = ((VkSampler)ns->ptr)->s;
            if (nt) switch (nt->kind) {
                case O_IMAGE_VIEW: e->tex = ((VkImageView)nt->ptr)->tex; e->wid = 0; break;
                case O_BUFFER_VIEW: e->tex = bview_tex(nt->ptr); break;
                default: { VkBuffer b = nt->ptr; e->buf = b->mem ? mem_buf(b->mem) : nil; break; }   // 缓冲（O_PLAIN）：偏移 e->off 原样
            } } }
    LOG("[vk] %s即时存档恢复：Vulkan 出图层 段内容 %.1f MB；设备内存 %u、GPU 图像 %u、视图 %u、采样器 %u、模块 %u、管线 %u（建不回 %u）、描述符集 %u；其他没接回 %u",
        npbad || nbad ? "【黄】 " : "", bytes / 1048576.0, nmem, nimg, nview, nsmp, nmod, npipe, npbad, nset, nbad);
    return 0;
}
// 本层按整块存的结构的布局指纹（区原址放回 = 整块按旧布局用：布局变了恢复拒绝，见 snapfmt.h）
void vk_snap_fps(snap_fp_cb cb) {
    cb("vk.image", SNAP_FP_TYPE(struct VkImage_T)); cb("vk.view", SNAP_FP_TYPE(struct VkImageView_T)); cb("vk.memory", SNAP_FP_TYPE(struct VkDeviceMemory_T));
    cb("vk.buffer", SNAP_FP_TYPE(struct VkBuffer_T)); cb("vk.bview", SNAP_FP_TYPE(struct VkBufferView_T)); cb("vk.sampler", SNAP_FP_TYPE(struct VkSampler_T));
    cb("vk.module", SNAP_FP_TYPE(struct VkShaderModule_T)); cb("vk.pipeline", SNAP_FP_TYPE(struct VkPipeline_T)); cb("vk.set", SNAP_FP_TYPE(struct VkDescriptorSet_T));
    cb("vk.desc", SNAP_FP_TYPE(desc_t)); cb("vk.layout", SNAP_FP_TYPE(struct VkDescriptorSetLayout_T)); cb("vk.cmd", SNAP_FP_TYPE(struct VkCommandBuffer_T));
    cb("vk.rpass", SNAP_FP_TYPE(struct VkRenderPass_T)); cb("vk.fb", SNAP_FP_TYPE(struct VkFramebuffer_T)); cb("vk.swap", SNAP_FP_TYPE(struct VkSwapchainKHR_T));
    cb("vk.query", SNAP_FP_TYPE(struct VkQueryPool_T)); cb("vk.instance", SNAP_FP_TYPE(struct VkInstance_T)); cb("vk.object", SNAP_FP_TYPE(vk_object));
    cb("vk.vs_meta", SNAP_FP_TYPE(vs_meta)); cb("vk.vs_blk", SNAP_FP_TYPE(vs_blk)); cb("vk.recipe", SNAP_FP_TYPE(vs_recipe));
}
