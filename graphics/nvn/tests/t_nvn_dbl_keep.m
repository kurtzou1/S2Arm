// 诊断双画（DM_NVN_FB_TILE_CHECK / DM_NVN_FUSE_CHECK）的临时纹理 / 缓冲（11-12：Mac 开片上读检查两局 GPU 缺页）：直接包含生产 nvn_mtl.m。
//   判据（期望值按构造手写，不跑被测实现算）：
//   ① 负对照（旧做法：只 newTexture、不进驻留集）：不在驻留集；丢掉本地引用后对象当场释放（弱引用为空）——这正是 GPU 执行时读到已释放资源的形态
//   ② dbl_keep + dbl_retire（新做法）：纹理、缓冲进了驻留集；丢掉本地引用、keep 被 dbl_retire 清空后仍活着（提交回调块持有）、仍在驻留集；
//      跑提交回调（= GPU 做完）后出驻留集；再放掉回调块、驻留集 commit 后对象释放
#include "../gfx/nvn/nvn_mtl.m"
#include "s2a_t_result.h"

static int bad;
#define VERIFY(c, ...) do { int ok_ = !!(c); if (!ok_) bad++; printf("%s ", ok_ ? "PASS" : "FAIL"); printf(__VA_ARGS__); putchar('\n'); fflush(stdout); } while (0)
#define ARP(expr) ({ int v_; @autoreleasepool { v_ = !!(expr); } v_; })   // 读弱引用会留一个自动释放的强引用：每次读都在自己的池里，才不把对象拖活
static int resident(id r) { pthread_mutex_lock(&g_res_mu); int in = [g_res_objects containsObject:r]; pthread_mutex_unlock(&g_res_mu); return in; }
static id<MTLTexture> mk_tex(void) {
    MTLTextureDescriptor *d = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA8Unorm width:64 height:32 mipmapped:NO];
    d.usage = MTLTextureUsageShaderRead; d.storageMode = MTLStorageModePrivate; return [g_dev newTextureWithDescriptor:d];
}

int main(void) {
    @autoreleasepool {
        char map[] = "/tmp/t_dbl_keep_map_XXXXXX"; int fd = mkstemp(map); if (fd < 0) return 2; close(fd); setenv("DM_NVN_SHMAP", map, 1);
        mtl_init();
        g_commit_blocks = [NSMutableArray array];
        __weak id<MTLTexture> w_old = nil;
        @autoreleasepool { id<MTLTexture> t = mk_tex(); w_old = t; VERIFY(t && !resident(t), "① 负对照：旧做法建的纹理不在驻留集"); }
        VERIFY(ARP(w_old == nil), "① 负对照：旧做法丢掉本地引用后纹理当场释放（GPU 还没执行就没了）");

        __weak id<MTLTexture> wt = nil; __weak id<MTLBuffer> wb = nil;
        @autoreleasepool {
            NSMutableArray *keep = [NSMutableArray array];
            id<MTLTexture> t = mk_tex(); id<MTLBuffer> b = [g_dev newBufferWithLength:4096 options:MTLResourceStorageModeShared];
            wt = t; wb = b;
            dbl_keep(keep, t); dbl_keep(keep, b);
            VERIFY(resident(t) && resident(b), "② dbl_keep：临时纹理与缓冲进了驻留集");
            NSUInteger nb0 = g_commit_blocks.count; dbl_retire(keep);
            VERIFY(keep.count == 0 && g_commit_blocks.count == nb0 + 1, "② dbl_retire：keep 清空，挂了 1 个提交回调块（%lu → %lu）", (unsigned long)nb0, (unsigned long)g_commit_blocks.count);
        }
        VERIFY(ARP(wt != nil && wb != nil && resident(wt) && resident(wb)), "② 丢掉本地引用后仍活着、仍驻留（提交回调块持有到 GPU 做完）");
        @autoreleasepool { for (dispatch_block_t blk in g_commit_blocks) blk(); }   // = 这次提交的 GPU 做完
        VERIFY(ARP(wt != nil && !resident(wt) && !resident(wb)), "② 跑提交回调后出驻留集");
        @autoreleasepool { g_commit_blocks = nil; res_commit(); }   // 驻留集的移出在下一次 commit 生效（生产每次提交都 commit）
        VERIFY(ARP(wt == nil && wb == nil), "② 放掉提交回调块后对象释放（不漏）");
        unlink(map);
    }
    return S2A_T_RESULT("t_nvn_dbl_keep", bad);
}
