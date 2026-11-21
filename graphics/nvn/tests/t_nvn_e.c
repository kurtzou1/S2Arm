// 完整生产 bootstrap / 真实队列回放；读取调用者自有命令内存核对池编号，不代替 GPU 采样验证。
#include "nvn_protos.h"
#include "nvn_obj.h"
#include <stddef.h>
#include <stdio.h>
#include <stdlib.h>
#include <sys/mman.h>
#include <unistd.h>

extern void *h_nvnBootstrapLoader(const char *name);
extern int mtl_last_commit_error(void);
// 该扩展尚无生成原型；Wonder 1.2.1 SDK 0x469e60 保存 x4 指针，w1/w2/w3 分别为 stage/first/count。
typedef void (*bind_deferred_fn)(NVNcommandBuffer *, NVNshaderStage, int, int, const NVNtextureHandle *);
static bind_deferred_fn bind_deferred;
static const char *phase = "准备";
static unsigned checks, submissions;
#define CHECK(expr) do { checks++; if (!(expr)) { \
    fprintf(stderr, "FAIL [%s] %s:%d：%s\n", phase, __FILE__, __LINE__, #expr); exit(1); \
} } while (0)
static void *load(const char *name) {
    void *entry = h_nvnBootstrapLoader(name); CHECK(entry != NULL); return entry;
}
#define API(name) ((NVNT_##name)load(#name))
typedef struct { NVNmemoryPool object; void *bytes; size_t size; } memory;
typedef struct { NVNcommandBuffer object; memory *storage; } command;
static NVNdevice device;
static NVNqueue queue;
static NVNtexture texture;
static NVNsampler sampler;
static NVNtexturePool texture_pools[3];
static NVNsamplerPool sampler_pools[3];
static memory memories[24]; static unsigned nmemories;
static command commands[12]; static unsigned ncommands;
static size_t page_size;

static memory *new_memory(size_t size) {
    CHECK(nmemories < sizeof memories / sizeof *memories);
    memory *m = &memories[nmemories++]; m->size = (size + page_size - 1) & ~(page_size - 1);
    CHECK(posix_memalign(&m->bytes, page_size, m->size) == 0); memset(m->bytes, 0, m->size);
    NVNmemoryPoolBuilder builder = {{0}};
    API(nvnMemoryPoolBuilderSetDefaults)(&builder);
    API(nvnMemoryPoolBuilderSetDevice)(&builder, &device);
    API(nvnMemoryPoolBuilderSetFlags)(&builder, NVN_MEMORY_POOL_FLAGS_CPU_UNCACHED | NVN_MEMORY_POOL_FLAGS_GPU_CACHED);
    API(nvnMemoryPoolBuilderSetStorage)(&builder, m->bytes, m->size);
    CHECK(API(nvnMemoryPoolInitialize)(&m->object, &builder)); return m;
}
static command *new_command(void) {
    CHECK(ncommands < sizeof commands / sizeof *commands);
    command *c = &commands[ncommands++]; c->storage = new_memory(65536);
    CHECK(API(nvnCommandBufferInitialize)(&c->object, &device));
    API(nvnCommandBufferAddCommandMemory)(&c->object, &c->storage->object, 0, c->storage->size);
    return c;
}
static void set_pools(command *c, unsigned i) {
    API(nvnCommandBufferSetTexturePool)(&c->object, &texture_pools[i]);
    API(nvnCommandBufferSetSamplerPool)(&c->object, &sampler_pools[i]);
}
static NVNtextureHandle handle(int tid, int sid) {
    NVNtextureHandle h = API(nvnDeviceGetTextureHandle)(&device, tid, sid);
    CHECK((uint64_t)h == ((uint64_t)(unsigned)tid | (uint64_t)(unsigned)sid << 20)); return h;
}
// 记录在录制自己的宿主块里（hle_nvn.c 命令缓冲），不在游戏给的命令内存：绑定后写指针 cur 正好落在这条记录尾后，记录长度按格式独立算
static p_bind_handles *record_bind(command *c, int first, int n, const NVNtextureHandle *source, int deferred) {
    if (deferred) bind_deferred(&c->object, NVN_SHADER_STAGE_FRAGMENT, first, n, source);
    else API(nvnCommandBufferBindTextures)(&c->object, NVN_SHADER_STAGE_FRAGMENT, first, n, source);
    size_t size = sizeof(op_hdr) + offsetof(p_bind_handles, h) + 8 * (size_t)n + (deferred ? 8 : 0);
    op_hdr *header = (op_hdr *)(((const cmd_t *)&c->object)->cur - size);
    CHECK(header->op == OP_BIND_TEX);
    CHECK(header->size == size);
    p_bind_handles *r = (p_bind_handles *)(header + 1);
    CHECK(r->stage == NVN_SHADER_STAGE_FRAGMENT && r->first == first && r->n == n);
    CHECK(r->defer == deferred); return r;
}
static void check_handles(const p_bind_handles *r, const NVNtextureHandle *source, int tbase, int sbase) {
    for (int i = 0; i < r->n; i++) {
        // 独立按两个池的本地编号计算；不调用生产 remap / dpool_base / bind_rec。
        uint64_t tid = (uint64_t)source[i] & 0xfffff, sid = (uint64_t)source[i] >> 20;
        uint64_t expected_tid = tid + (unsigned)tbase;   // 纹理 ID 0 也是池里的一项（11-02 牧场物语深度缓冲注册在 ID 0；t_nvn_tex_id0）
        uint64_t expected_sid = sid ? sid + (unsigned)sbase : 0;
        CHECK((r->h[i] & 0xfffff) == expected_tid);
        CHECK((r->h[i] >> 20) == expected_sid);
    }
}
static void submit(NVNcommandHandle h) {
    API(nvnQueueSubmitCommands)(&queue, 1, &h); API(nvnQueueFinish)(&queue);
    CHECK(mtl_last_commit_error() == 0); submissions++;
}
static void setup(void) {
    page_size = (size_t)getpagesize();
    bind_deferred = (bind_deferred_fn)load("nvnCommandBufferBindTexturesDeferred");
    NVNdeviceBuilder db = {{0}}; API(nvnDeviceBuilderSetDefaults)(&db);
    CHECK(API(nvnDeviceInitialize)(&device, &db));
    int separate_textures = 0, separate_samplers = 0;
    API(nvnDeviceGetInteger)(&device, NVN_DEVICE_INFO_SEPARATE_TEXTURE_BINDINGS_PER_STAGE, &separate_textures);
    API(nvnDeviceGetInteger)(&device, NVN_DEVICE_INFO_SEPARATE_SAMPLER_BINDINGS_PER_STAGE, &separate_samplers);
    CHECK(separate_textures == 128 && separate_samplers == 32);  // 没有加载游戏驱动时采用默认绑定上限。
    NVNqueueBuilder qb = {{0}}; API(nvnQueueBuilderSetDefaults)(&qb);
    API(nvnQueueBuilderSetDevice)(&qb, &device); CHECK(API(nvnQueueInitialize)(&queue, &qb));
    NVNtextureBuilder tb = {{0}}; API(nvnTextureBuilderSetDefaults)(&tb);
    API(nvnTextureBuilderSetDevice)(&tb, &device);
    API(nvnTextureBuilderSetSize2D)(&tb, 8, 8); API(nvnTextureBuilderSetFormat)(&tb, NVN_FORMAT_RGBA8);
    memory *pixels = new_memory(API(nvnTextureBuilderGetStorageSize)(&tb));
    API(nvnTextureBuilderSetStorage)(&tb, &pixels->object, 0); CHECK(API(nvnTextureInitialize)(&texture, &tb));
    NVNsamplerBuilder sb = {{0}}; API(nvnSamplerBuilderSetDefaults)(&sb);
    API(nvnSamplerBuilderSetDevice)(&sb, &device); CHECK(API(nvnSamplerInitialize)(&sampler, &sb));
    int tsize, ssize, treserved, sreserved;
    API(nvnDeviceGetInteger)(&device, NVN_DEVICE_INFO_TEXTURE_DESCRIPTOR_SIZE, &tsize);
    API(nvnDeviceGetInteger)(&device, NVN_DEVICE_INFO_SAMPLER_DESCRIPTOR_SIZE, &ssize);
    API(nvnDeviceGetInteger)(&device, NVN_DEVICE_INFO_RESERVED_TEXTURE_DESCRIPTORS, &treserved);
    API(nvnDeviceGetInteger)(&device, NVN_DEVICE_INFO_RESERVED_SAMPLER_DESCRIPTORS, &sreserved);
    CHECK(tsize > 0 && ssize > 0 && treserved <= 256 && sreserved <= 256);
    const int tn[] = {512, 768, 512}, sn[] = {768, 512, 512};
    // 每个大小都为 256 的倍数；创建顺序给出 texture base 0/512/1280，sampler base 0/768/1280。
    for (unsigned i = 0; i < 3; i++) {
        memory *t = new_memory((size_t)tn[i] * (unsigned)tsize), *s = new_memory((size_t)sn[i] * (unsigned)ssize);
        CHECK(API(nvnTexturePoolInitialize)(&texture_pools[i], &t->object, 0, tn[i]));
        CHECK(API(nvnSamplerPoolInitialize)(&sampler_pools[i], &s->object, 0, sn[i]));
        for (int id = 256; id < 288; id++) {
            API(nvnTexturePoolRegisterTexture)(&texture_pools[i], id, &texture, NULL);
            API(nvnSamplerPoolRegisterSampler)(&sampler_pools[i], id, &sampler);
        }
    }
}
static void protected_source(unsigned pool) {
    phase = pool ? "不同 texture/sampler base，录制后改源及后续换池" : "首池零 base，录制期不可读源";
    NVNtextureHandle *source = mmap(NULL, page_size, PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANON, -1, 0);
    CHECK(source != MAP_FAILED);
    const NVNtextureHandle before[] = {handle(256, 256), handle(257, 257), handle(258, 258), handle(259, 259)};
    const NVNtextureHandle after[] = {0, handle(257, 0), handle(0, 258), handle(259, 260)};
    memcpy(source, before, sizeof before);
    command *c = new_command(); API(nvnCommandBufferBeginRecording)(&c->object); set_pools(c, pool);
    CHECK(mprotect(source, page_size, PROT_NONE) == 0);
    p_bind_handles *r = record_bind(c, 0, 4, source, 1);
    set_pools(c, 2); // 改变同一 CB 后续池状态，不改变已经记录的两类 base。
    NVNcommandHandle h = API(nvnCommandBufferEndRecording)(&c->object);
    CHECK(mprotect(source, page_size, PROT_READ | PROT_WRITE) == 0);
    memcpy(source, after, sizeof after); submit(h);
    check_handles(r, after, pool ? 512 : 0, pool ? 768 : 0);
    CHECK(memcmp(source, after, sizeof after) == 0);
    submit(h); check_handles(r, after, pool ? 512 : 0, pool ? 768 : 0);
    memcpy(source, before, sizeof before); submit(h);
    check_handles(r, before, pool ? 512 : 0, pool ? 768 : 0);
    CHECK(memcmp(source, before, sizeof before) == 0);
    CHECK(munmap(source, page_size) == 0);
    printf("%s：通过\n", phase); fflush(stdout);
}
static void immediate_and_max(void) {
    phase = "普通立即绑定保留快照，Deferred n=32 到 combined slot 127";
    NVNtextureHandle source[32], original[32];
    for (int i = 0; i < 32; i++) source[i] = handle(256 + i, 287 - i);
    memcpy(original, source, sizeof original);
    command *c = new_command(); API(nvnCommandBufferBeginRecording)(&c->object); set_pools(c, 1);
    p_bind_handles *immediate = record_bind(c, 0, 32, source, 0);
    p_bind_handles *deferred = record_bind(c, 96, 32, source, 1);
    NVNcommandHandle h = API(nvnCommandBufferEndRecording)(&c->object);
    for (int i = 0; i < 32; i++) source[i] = original[31 - i];
    submit(h); check_handles(immediate, original, 512, 768); check_handles(deferred, source, 512, 768);
    submit(h); check_handles(immediate, original, 512, 768); check_handles(deferred, source, 512, 768);
    printf("%s：通过\n", phase); fflush(stdout);
}
static void empty_bind(void) {
    phase = "n=0 不读取不可读源，尾部不覆盖下条记录";
    void *source = mmap(NULL, page_size, PROT_NONE, MAP_PRIVATE | MAP_ANON, -1, 0); CHECK(source != MAP_FAILED);
    command *c = new_command(); API(nvnCommandBufferBeginRecording)(&c->object); set_pools(c, 1);
    p_bind_handles *r = record_bind(c, 0, 0, source, 1);
    API(nvnCommandBufferBindTexture)(&c->object, NVN_SHADER_STAGE_FRAGMENT, 127, handle(256, 256));
    NVNcommandHandle h = API(nvnCommandBufferEndRecording)(&c->object);
    unsigned char snapshot[80]; CHECK(sizeof snapshot <= c->storage->size);
    memcpy(snapshot, r, sizeof snapshot); submit(h); CHECK(memcmp(snapshot, r, sizeof snapshot) == 0);
    CHECK(munmap(source, page_size) == 0);
    printf("%s：通过\n", phase); fflush(stdout);
}
// 从句柄起找第一条绑定贴图记录（跟着 JUMP 换块；记录 = 头 + 载荷，size 含头）
static unsigned oom_calls;
static void oom_cb(NVNcommandBuffer *c, NVNcommandBufferMemoryEvent e, size_t need, void *data) { (void)c; (void)e; (void)need; (void)data; oom_calls++; }
static p_bind_handles *find_bind(NVNcommandHandle handle) {
    unsigned char *q = (unsigned char *)(uintptr_t)handle;
    for (unsigned k = 0; q && k < 100000; k++) {
        op_hdr *h = (op_hdr *)q; CHECK(h->size >= sizeof *h);
        if (h->op == OP_BIND_TEX) return (p_bind_handles *)(h + 1);
        if (h->op == OP_END) break;
        if (h->op == OP_JUMP) { memcpy(&q, q + 8, 8); continue; }
        q += h->size;
    }
    CHECK(!"录制里没有绑定贴图记录");
    return NULL;
}
static void nested_commands(void) {
    phase = "CallCommands / CopyCommands 保留子记录 base 和延迟源";
    NVNtextureHandle source[2] = {handle(256, 257), handle(258, 259)};
    command *child = new_command(); API(nvnCommandBufferBeginRecording)(&child->object); set_pools(child, 1);
    p_bind_handles *r = record_bind(child, 4, 2, source, 1);
    NVNcommandHandle hc = API(nvnCommandBufferEndRecording)(&child->object);
    for (unsigned copy = 0; copy < 2; copy++) {
        command *parent = new_command(); API(nvnCommandBufferBeginRecording)(&parent->object); set_pools(parent, 2);
        if (copy) API(nvnCommandBufferCopyCommands)(&parent->object, 1, &hc);
        else API(nvnCommandBufferCallCommands)(&parent->object, 1, &hc);
        set_pools(parent, 0);
        NVNcommandHandle hp = API(nvnCommandBufferEndRecording)(&parent->object);
        source[0] = handle(260 + (int)copy, 262 + (int)copy);
        source[1] = handle(264 + (int)copy, 266 + (int)copy);
        // Copy：记录在拷贝那一刻抄进父缓冲，回放改写的是父缓冲里那份；Call：回放的是子录制本身（缺口族 41）
        p_bind_handles *rp = copy ? find_bind(hp) : r;
        submit(hp); check_handles(rp, source, 512, 768);
        submit(hp); check_handles(rp, source, 512, 768);
    }
    printf("%s：通过\n", phase); fflush(stdout);
    phase = "CopyCommands 之后子录制的命令内存被复用：父缓冲照样回放拷贝时的记录";
    {
        NVNtextureHandle src[2] = {handle(270, 271), handle(272, 273)};
        command *ch = new_command(); API(nvnCommandBufferBeginRecording)(&ch->object); set_pools(ch, 1);
        record_bind(ch, 4, 2, src, 1);
        NVNcommandHandle h1 = API(nvnCommandBufferEndRecording)(&ch->object);
        command *parent = new_command(); API(nvnCommandBufferBeginRecording)(&parent->object); set_pools(parent, 2);
        API(nvnCommandBufferCopyCommands)(&parent->object, 1, &h1);
        NVNcommandHandle hp = API(nvnCommandBufferEndRecording)(&parent->object);
        memset(ch->storage->bytes, 0, ch->storage->size);   // 游戏拷贝完就把子录制那块内存另作他用（这里清零：旧实现记的是跳到这里的 CALL，回放读到空记录）
        p_bind_handles *rp = find_bind(hp);
        submit(hp); check_handles(rp, src, 512, 768);
    }
    printf("%s：通过\n", phase); fflush(stdout);
    phase = "CopyCommands 抄的记录超出目标命令内存（设备字节口径）：不回调游戏，宿主借窗口接着录（马里奥网球 Aces）";
    {
        NVNtextureHandle src[2] = {handle(280, 281), handle(282, 283)};
        command *ch = new_command(); API(nvnCommandBufferBeginRecording)(&ch->object); set_pools(ch, 1);
        for (int i = 0; i < 40; i++) record_bind(ch, 4, 2, src, 1);
        NVNcommandHandle h1 = API(nvnCommandBufferEndRecording)(&ch->object);
        // 设备字节：换池两条不占命令内存（真机驱动写控制内存令牌，hle_nvn.c DEV_CTL，11-06 Outlast 2）、延迟绑定 2 个按记录大小 8+24+16+8 = 56、END 0（驱动的 EndRecording 只写控制内存）
        size_t child = API(nvnCommandBufferGetCommandMemoryUsed)(&ch->object);
        CHECK(child == 40 * 56);
        command *parent = new_command();
        API(nvnCommandBufferSetMemoryCallback)(&parent->object, oom_cb);
        API(nvnCommandBufferAddCommandMemory)(&parent->object, &parent->storage->object, 0, 256);   // 游戏给目标的空间小于源录制的已用量
        API(nvnCommandBufferBeginRecording)(&parent->object); set_pools(parent, 2);
        oom_calls = 0;
        API(nvnCommandBufferCopyCommands)(&parent->object, 1, &h1);
        CHECK(oom_calls == 0);   // 改前：拷贝途中回调游戏（网球的回调对拷贝目标走空指针）
        NVNcommandHandle hp = API(nvnCommandBufferEndRecording)(&parent->object);
        CHECK(oom_calls == 0);   // END 落在借来的窗口里，同样不该回调
        // 拷贝 = 源录制除 END 外的全部命令（32 + child 远超 256）：借窗口不占游戏内存，已用 = 游戏给的 256、剩余 0（审计 #1534 P1-99：已用不超过大小；旧实现 32 + child）
        CHECK(API(nvnCommandBufferGetCommandMemoryUsed)(&parent->object) == 256);
        CHECK(API(nvnCommandBufferGetCommandMemoryFree)(&parent->object) == 0);
        submit(hp); check_handles(find_bind(hp), src, 512, 768);
    }
    printf("%s：通过\n", phase); fflush(stdout);
    phase = "PSO 定长命令内存：六种状态绑定按设备命令下限计（UE4 PSO CommandMemory OOM，11-14 D-HSQE）";
    {   // 期望手算：每条状态绑定 8 设备字节（hle_nvn.c DEV_STATE），六条 48 ≤ 游戏给的 64 → 不回调、已用 48。改前按宿主记录 40 字节一条，第二条就超 64 → 回调
        command *pso = new_command();
        API(nvnCommandBufferSetMemoryCallback)(&pso->object, oom_cb);
        API(nvnCommandBufferAddCommandMemory)(&pso->object, &pso->storage->object, 0, 64);
        NVNblendState bs; NVNcolorState cs; NVNchannelMaskState cm; NVNmultisampleState ms; NVNpolygonState ps; NVNdepthStencilState ds;
        memset(&bs, 0, sizeof bs); memset(&cs, 0, sizeof cs); memset(&cm, 0, sizeof cm); memset(&ms, 0, sizeof ms); memset(&ps, 0, sizeof ps); memset(&ds, 0, sizeof ds);
        oom_calls = 0;
        API(nvnCommandBufferBeginRecording)(&pso->object);
        API(nvnCommandBufferBindBlendState)(&pso->object, &bs); API(nvnCommandBufferBindColorState)(&pso->object, &cs);
        API(nvnCommandBufferBindChannelMaskState)(&pso->object, &cm); API(nvnCommandBufferBindMultisampleState)(&pso->object, &ms);
        API(nvnCommandBufferBindPolygonState)(&pso->object, &ps); API(nvnCommandBufferBindDepthStencilState)(&pso->object, &ds);
        size_t used = API(nvnCommandBufferGetCommandMemoryUsed)(&pso->object);
        if (oom_calls || used != 48) printf("PSO 状态绑定：回调 %d 次、已用 %zu（期望 0 次、48）\n", oom_calls, used);
        CHECK(oom_calls == 0 && used == 48);
        API(nvnCommandBufferEndRecording)(&pso->object);
    }
    printf("%s：通过\n", phase); fflush(stdout);
}
int main(void) {
    setup(); protected_source(0); protected_source(1); immediate_and_max(); empty_bind(); nested_commands();
    API(nvnQueueFinish)(&queue);
    for (unsigned i = 0; i < ncommands; i++) API(nvnCommandBufferFinalize)(&commands[i].object);
    for (unsigned i = 0; i < 3; i++) {
        API(nvnTexturePoolFinalize)(&texture_pools[i]); API(nvnSamplerPoolFinalize)(&sampler_pools[i]);
    }
    API(nvnSamplerFinalize)(&sampler); API(nvnTextureFinalize)(&texture);
    for (unsigned i = 0; i < nmemories; i++) { API(nvnMemoryPoolFinalize)(&memories[i].object); free(memories[i].bytes); }
    API(nvnQueueFinalize)(&queue); API(nvnDeviceFinalize)(&device);
    printf("NVN E：%u 条真实 API / 回放断言，%u 次提交（不含 GPU 采样判据）\n", checks, submissions);
    return 0;
}
