// 补帧与显示链互斥（11-15 #ee56e7 / #1155：补帧开着时出图切到显示链模式，补帧任务照样 nextDrawable → CAMetalLayerInvalidOperation 整个 App 退出；
//   切换前后新旧两路同时交帧 = 频闪）。含生产 nvn_mtl.m 源码（同 t_link_restart.m 写法），假图层只数 nextDrawable 调了几次。期望按语义手写：
//   ① 图层已归显示链（g_link_owns_layer = 1，显示链正在挂）时跑一个补帧任务：nextDrawable 0 次、这一帧的票记完成、在途数回 0。旧实现照取画布 → 1 次以上（红）
//   ② 图层没归显示链：照常取画布（≥ 1 次，假图层返回 nil 就不上屏），在途数回 0——修复没把正常补帧关掉
//   ③ 显示链等的条件：经典出图空闲但还有 1 笔在途补帧 → 还不能挂（1）；在途归零 → 能挂（0）。旧实现只看经典出图 → 在途时也判能挂（红）
//   ⑤ 补帧端到端（11-17 插值并进上屏队列）：屏外画布 1280x720，游戏图黑底上一条 24 像素宽的白竖条每帧右移 32 像素，按 30 帧节拍喂 12 帧。期望按构造手算：
//      第 0 帧没有前一帧不补，其余 11 帧都补（补成 11、配不上 0）、11 次插值都有 GPU 时间读数、全部票记完成；
//      最后一次补出的帧里亮（> 0.8）像素的中心落在前后两帧竖条中心的正中（±8 像素），且两帧竖条原位（不与正中重叠的那段）不亮（< 0.3）——
//      只把两帧混合（零运动矢量）时两处各半亮、没有 > 0.8 的像素（红）。同样再跑一遍每帧右移 96 像素（超出单层搜索的 ±64，两层金字塔才追得上；单层时红）。
//      这两遍判成切镜头 0 次。第三遍：前 8 帧同上（右移 32），第 8 帧起换成一张固定的噪点图（与竖条场景毫不相干）：判成切镜头正好 1 次（第 7→8 帧那一对），补成仍是 11
//      第四遍（11-18）：同第一遍，倒数第二帧的交帧间隔给 1 秒、按规则不补（不补 1、补成 10，那一帧照样编码插值、不上屏，GPU 读数 11 次）；最后一对照样补出中间位置。
//   ⑦ 旧插值器还有在途命令槽时重建：等它做完再出驻留集、放掉；2 秒还不完就留着不放（详见用例处）
//      原先不补的帧不编码，下一对重置 MetalFX 历史，出的是这一帧原图（中心 464）；只去掉重置、不编码，又偏向前一帧（中心 435、前一帧原位全亮）。
//      各帧交帧间隔都由单测给定（一个周期），不看墙钟：满载门禁机上墙钟间隔超 1.25 倍周期会判不补，原先时有时无地红。
//      间隔经生产的时钟缝 FI_NOW_NS（nvn_present_fi.inc）注入：fi_frame 读的就是单测推进的假时钟；原先单测先写 last_in_ns = 墙钟 − 周期，
//      fi_frame 再读一次墙钟，两次之间被抢占（负载高时）间隔就超过 1.25 倍周期、判不补而假红
#include <stdint.h>
static uint64_t fi_test_now(void);
#define FI_NOW_NS() fi_test_now()
#ifndef FI_LINK_SOURCE
#define FI_LINK_SOURCE "../gfx/nvn/nvn_mtl.m"
#endif
#include FI_LINK_SOURCE

static _Atomic uint64_t g_fake_ns;   // ⑤ 的假时钟（0 = 用真钟）
static uint64_t fi_test_now(void) { uint64_t v = atomic_load(&g_fake_ns); return v ? v : now_ns(); }
static unsigned checks, failures;
#define CHECK(c, ...) do { checks++; int ok=!!(c); failures+=!ok; printf("%s ",ok?"PASS":"FAIL"); printf(__VA_ARGS__); putchar('\n'); fflush(stdout); } while(0)

@interface FakeLayer : CAMetalLayer
@property (atomic) int takes;
@end
@implementation FakeLayer
- (id<CAMetalDrawable>)nextDrawable { self.takes++; return nil; }
@end

int main(void) { @autoreleasepool {
    setenv("DM_PSO_MANIFEST","off",1); setenv("DM_PSO_ARCHIVE","0",1);
    mtl_init();
    if (@available(macOS 26.0, iOS 26.0, *)) {
        for (int owns = 1; owns >= 0; owns--) {
            FakeLayer *l = [FakeLayer new]; NvPresentFI *f = [NvPresentFI new];
            pthread_mutex_lock(&g_pq_mu); g_link_owns_layer = owns; g_pq_done = 0; pthread_mutex_unlock(&g_pq_mu);
            fi_inflight_add(1);   // 同 fi_frame：派任务前记一笔在途
            fi_crop cr = {0};
            fi_job(f, l, nil, cr, NO, 0, 1, 1.0 / 30, 7, 0, 1);   // good = 0：不补中间帧，直接走上真帧那段
            pthread_mutex_lock(&g_pq_mu); int inflight = g_fi_inflight; uint64_t done = g_pq_done; pthread_mutex_unlock(&g_pq_mu);
            if (owns) CHECK(l.takes == 0 && done >= 7 && inflight == 0, "① 图层已归显示链：补帧任务不取画布（nextDrawable %d 次）、票记完成（%llu）、在途回 0（%d）", l.takes, (unsigned long long)done, inflight);
            else CHECK(l.takes >= 1 && inflight == 0, "② 图层没归显示链：照常取画布（nextDrawable %d 次）、在途回 0（%d）", l.takes, inflight);
        }
    }
    pthread_mutex_lock(&g_pq_mu); g_link_owns_layer = 0; g_classic_busy = 0; g_fi_inflight = 1; int b1 = link_layer_busy(); g_fi_inflight = 0; int b0 = link_layer_busy(); pthread_mutex_unlock(&g_pq_mu);
    CHECK(b1 == 1 && b0 == 0, "③ 显示链等：经典出图空闲、在途补帧 1 笔 → 不能挂（%d）；在途归零 → 能挂（%d）", b1, b0);
    // ④ 显示链跟补帧开关（审计 P1-188）。期望手写：补帧开（g_fi_state 1）、玩家局中关 → 这一帧不补、显示链回到不补帧时的方式（g_link_base 1）；
    //   再开 → 0；整段回退 fi_off → 1；补丁要的 120 Hz 链（2）不动。旧实现关补帧 / 回退后显示链仍是 0（红）
    {
        g_fi_state = 1; g_link_base = 1; g_dm_present_link = 0;
        s2a_fi_set_live(0); int r0 = fi_wanted(); int l0 = g_dm_present_link;
        s2a_fi_set_live(1); int r1 = fi_wanted(); int l1 = g_dm_present_link;
        fi_off("测试：整段回退"); int l2 = g_dm_present_link;
        g_fi_state = 1; g_dm_present_link = 2; s2a_fi_set_live(0); (void)fi_wanted(); int l3 = g_dm_present_link; s2a_fi_set_live(1); g_fi_state = 0; g_dm_present_link = 0;
        CHECK(r0 == 0 && l0 == 1 && r1 == 1 && l1 == 0 && l2 == 1 && l3 == 2, "④ 显示链跟补帧：局中关 → 不补、链 %d（期望 1）；再开 → 补、链 %d（期望 0）；回退 → 链 %d（期望 1）；120 Hz 链不动 → %d（期望 2）", l0, l1, l2, l3);
    }
    // ⑤ 补帧端到端
    if (@available(macOS 26.0, iOS 26.0, *)) if (!g_m3) for (int run = 0; run < 4; run++) {
        const int W = 1280, H = 720, BW = 24, STEP = run == 1 ? 96 : 32, X0 = 100, N = 12, CUT_AT = run == 2 ? 8 : N, LATE_AT = run == 3 ? N - 2 : -1;
        g_fi = nil;   // 每遍从头建（统计从 0 起）
        setenv("DM_PRESENT_FI", "1", 1); g_fi_state = -1; s2a_fi_set_live(1);
        CAMetalLayer *l = [CAMetalLayer layer]; l.device = g_dev; l.pixelFormat = MTLPixelFormatBGRA8Unorm; l.drawableSize = CGSizeMake(W, H); l.framebufferOnly = NO;
        [g_q4 addResidencySet:l.residencySet];
        MTLTextureDescriptor *td = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatBGRA8Unorm width:W height:H mipmapped:NO];
        td.usage = MTLTextureUsageShaderRead; td.storageMode = MTLStorageModeShared;
        id<MTLTexture> srcs[2] = {[g_dev newTextureWithDescriptor:td], [g_dev newTextureWithDescriptor:td]}; res_add(srcs[0]); res_add(srcs[1]); res_commit();
        uint32_t *px = malloc((size_t)W * H * 4); int ok_on = fi_wanted();
        uint64_t ticket0 = 1000 + 100 * (uint64_t)run;
        // 交帧时刻由假时钟给（第 i 帧 = fake0 + i 个周期；第 3 遍 LATE_AT 那帧多给 1 秒），不再按墙钟排节拍
        uint64_t fake = now_ns();
        for (int i = 0; i < N; i++) {
            int x = X0 + STEP * i;
            if (i < CUT_AT) { for (int y = 0; y < H; y++) for (int c = 0; c < W; c++) px[y * W + c] = c >= x && c < x + BW ? 0xFFFFFFFFu : 0xFF000000u; }
            else { uint32_t r = 12345; for (int j = 0; j < W * H; j++) { r = r * 1103515245u + 12345u; uint32_t g = r >> 24; px[j] = 0xFF000000u | g << 16 | g << 8 | g; } }   // 固定种子的噪点：每帧一样
            id<MTLTexture> t = srcs[i & 1];
            {   // 这张源图（两张轮换）上一次被读完才改写，同游戏双缓冲：第 i - 2 帧的票记完成；兜底 30 秒（原 2 秒：负载高时 GPU 慢就假红），等不到按失败记、不挂住
                double tw = clock_gettime_nsec_np(CLOCK_UPTIME_RAW) / 1e9; int stuck = 0;
                pthread_mutex_lock(&g_pq_mu);
                while (i >= 2 && g_pq_done < ticket0 + i - 2) { if (clock_gettime_nsec_np(CLOCK_UPTIME_RAW) / 1e9 - tw > 30) { stuck = 1; break; }
                    struct timespec ts = {0, 20000000}; pthread_mutex_unlock(&g_pq_mu); nanosleep(&ts, NULL); pthread_mutex_lock(&g_pq_mu); }
                pthread_mutex_unlock(&g_pq_mu);
                if (stuck) { CHECK(0, "⑤ 第 %d 遍第 %d 帧：等第 %d 帧的票 30 秒没等到（补帧卡住）", run, i, i - 2); break; }
            }
            [t replaceRegion:MTLRegionMake2D(0, 0, W, H) mipmapLevel:0 withBytes:px bytesPerRow:W * 4];
            // 交帧间隔给定值，不看墙钟（满载机器上墙钟间隔会超规则的 1.25 倍周期、判「来晚了不补」，单测时有时无地红；规则本身由 t_nvn_fi_rule 测）：
            //   每帧正好一个周期；第 3 遍第 LATE_AT 帧给 1 秒，按规则不补
            if (i) fake += i == LATE_AT ? 1000000000ull : 1000000000ull / 30;
            atomic_store(&g_fake_ns, fake);
            int r = fi_frame(t, NULL, l, 1.0 / 30, ticket0 + i);
            atomic_store(&g_fake_ns, 0);
            if (r < 0) break;
        }
        double t0 = clock_gettime_nsec_np(CLOCK_UPTIME_RAW) / 1e9;
        // 等全部票记完成，兜底 30 秒（原 5 秒）
        pthread_mutex_lock(&g_pq_mu); while (g_pq_done < ticket0 + N - 1 && clock_gettime_nsec_np(CLOCK_UPTIME_RAW) / 1e9 - t0 < 30) { struct timespec ts = {0, 50000000}; pthread_mutex_unlock(&g_pq_mu); nanosleep(&ts, NULL); pthread_mutex_lock(&g_pq_mu); }
        uint64_t done = g_pq_done; pthread_mutex_unlock(&g_pq_mu);
        NvPresentFI *f = g_fi;
        // 插值那一槽的完成回调（切镜头标志、GPU 时间）可能晚于真帧那一槽记票：原先固定睡 100 ms，负载高时回调没到就假红。
        //   现在等到有 GPU 读数的插值数 = 编码了插值的帧数（补成 + 按规则不补但照样编码的那帧），兜底 30 秒；等不到下面判红
        for (int w = 0; w < 3000 && f; w++) { pthread_mutex_lock(&g_pq_mu); int all_in = f->gpu_n >= f->made + (run == 3 ? 1u : 0u); pthread_mutex_unlock(&g_pq_mu); if (all_in) break; usleep(10000); }
        pthread_mutex_lock(&g_pq_mu); uint64_t gn = f ? f->gpu_n : 0, cuts = f ? f->cuts : 0; double gsum = f ? f->gpu_sum : 0; pthread_mutex_unlock(&g_pq_mu);
        CHECK(cuts == (run == 2 ? 1u : 0u), "⑤ 第 %d 遍：判成切镜头 %llu 次（期望 %d）", run, (unsigned long long)cuts, run == 2 ? 1 : 0);
        // 补成 + 按规则不补 = N - 1；不补的只有第 3 遍给了 1 秒间隔的那一帧
        CHECK(ok_on && f && f->made + f->declined == (uint64_t)(N - 1) && f->declined == (run == 3 ? 1u : 0u) && f->unpaired == 0 && gn == f->made + (run == 3 ? 1u : 0u) && done >= ticket0 + N - 1,
              "⑤ 每帧右移 %d：补成 %llu + 按规则不补 %llu（期望合计 %d、不补 = 第 3 遍 1 帧其余 0）、配不上 %llu（期望 0）、有 GPU 读数的插值 %llu 次（期望 = 补成，第 3 遍不补的那帧也编码、多 1，平均 %.2f ms）、票记到 %llu（期望 ≥ %llu）",
              STEP, f ? (unsigned long long)f->made : 0, f ? (unsigned long long)f->declined : 0, N - 1, f ? (unsigned long long)f->unpaired : 0, (unsigned long long)gn, gn ? gsum / gn : 0, (unsigned long long)done, (unsigned long long)(ticket0 + N - 1));
        if (f && run != 2) {   // 读回最后一次补出的帧（私有图 → 共享缓冲）；第 3 遍：上一帧按规则不补（照样编码插值、不上屏），这一对照样补出中间位置
            id<MTLBuffer> rb = [g_dev newBufferWithLength:(NSUInteger)W * H * 4 options:MTLResourceStorageModeShared];
            id<MTLCommandBuffer> c = [[g_dev newCommandQueue] commandBuffer]; id<MTLBlitCommandEncoder> b = [c blitCommandEncoder];
            [b copyFromTexture:f->mid_tex sourceSlice:0 sourceLevel:0 sourceOrigin:MTLOriginMake(0, 0, 0) sourceSize:MTLSizeMake(W, H, 1) toBuffer:rb destinationOffset:0 destinationBytesPerRow:W * 4 destinationBytesPerImage:(NSUInteger)W * H * 4];
            [b endEncoding]; [c commit]; [c waitUntilCompleted];
            const uint8_t *m = rb.contents; int y = H / 2; double sx = 0; int nbright = 0; double old_a = 0, old_b = 0;
            int xa = X0 + STEP * (N - 2), xb = X0 + STEP * (N - 1); double want = (xa + xb) / 2.0 + BW / 2.0;
            for (int x = 0; x < W; x++) { double v = m[(y * W + x) * 4 + 1] / 255.0; if (v > 0.8) { sx += x; nbright++; } }
            for (int x = xa; x < xa + 8; x++) old_a = fmax(old_a, m[(y * W + x) * 4 + 1] / 255.0);   // 前一帧竖条最左 8 像素（正中的竖条从 xa + 16 起，不重叠）
            for (int x = xb + BW - 8; x < xb + BW; x++) old_b = fmax(old_b, m[(y * W + x) * 4 + 1] / 255.0);   // 这一帧竖条最右 8 像素
            double cx = nbright ? sx / nbright + 0.5 : -1;
            CHECK(nbright > 0 && fabs(cx - want) <= 8 && old_a < 0.3 && old_b < 0.3, "⑤ 每帧右移 %d，补出的帧：亮像素 %d 个、中心 %.1f（期望 %.1f ± 8）；前一帧竖条原位最亮 %.2f、这一帧竖条原位最亮 %.2f（期望都 < 0.3）",
                  STEP, nbright, cx, want, old_a, old_b);
        }
        free(px); g_fi_state = 0; unsetenv("DM_PRESENT_FI");
        // ⑥ D-YVDD（11-22 #2111）：游戏画面尺寸每帧来回微调 → 插值器每次「画面比例变了、整个重建」。期望：重建 20 次（1280x720 ↔ 1278x718 交替）后
        //   驻留集里的对象数不涨（旧的一套出集、新的一套进集，数目持平）、第一套的输入贴图真的释放（弱引用变空）。修前旧的一套一直挂在驻留集里：数目每次涨一套、弱引用不空
        { CAMetalLayer *l = [CAMetalLayer layer]; l.device = g_dev; l.pixelFormat = MTLPixelFormatBGRA8Unorm; l.drawableSize = CGSizeMake(1280, 720); l.framebufferOnly = NO;
          g_fi = nil; __weak id<MTLTexture> w0 = nil; NSUInteger n0 = 0, n1 = 0;
          @autoreleasepool { NvPresentFI *f0 = fi_get(l, 1280, 720); if (f0) w0 = f0->in_tex[0]; }
          if (!g_fi) printf("SKIP ⑥ 本机做不了 MetalFX 补帧（fi_get 回空），跳过\n");
          else {
              pthread_mutex_lock(&g_res_mu); n0 = g_res_objects.count; pthread_mutex_unlock(&g_res_mu);
              for (int i = 0; i < 20; i++) @autoreleasepool { fi_get(l, i & 1 ? 1280 : 1278, i & 1 ? 720 : 718); }
              res_commit();
              pthread_mutex_lock(&g_res_mu); n1 = g_res_objects.count; pthread_mutex_unlock(&g_res_mu);
              CHECK(g_fi && n1 <= n0 && w0 == nil, "⑥ 画面尺寸来回变、插值器重建 20 次：驻留集对象 %lu → %lu（期望不涨）、第一套输入贴图%s（期望已释放）",
                    (unsigned long)n0, (unsigned long)n1, w0 ? "还活着" : "已释放");
              fi_release(g_fi); g_fi = nil;
          } }
        // ⑦ 11-23（#1449）：重建时旧插值器还有在 GPU 上跑的命令槽。模拟：占住旧对象第 1 槽（同 fi_commit 交出、完成回调还没来），
        //   300 ms 后在别的线程放开。期望：换尺寸重建（fi_get）等到放开才返回（≥ 250 ms），返回时旧输入贴图已出驻留集；
        //   占住一直不放（GPU 挂死）：2 秒后返回、旧输入贴图仍在驻留集、旧对象留着（弱引用不空）。修前当场出集放掉：返回 < 50 ms、贴图已出集（红）
        { CAMetalLayer *l = [CAMetalLayer layer]; l.device = g_dev; l.pixelFormat = MTLPixelFormatBGRA8Unorm; l.drawableSize = CGSizeMake(1280, 720); l.framebufferOnly = NO;
          g_fi = nil; NvPresentFI *f0 = fi_get(l, 1280, 720);
          if (!f0) printf("SKIP ⑦ 本机做不了 MetalFX 补帧（fi_get 回空），跳过\n");
          else {
              id<MTLTexture> old_in = f0->in_tex[0]; dispatch_semaphore_t s1 = f0->slot_free[1];
              dispatch_semaphore_wait(s1, DISPATCH_TIME_FOREVER);
              dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 300 * NSEC_PER_MSEC), dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{ dispatch_semaphore_signal(s1); });
              f0 = nil; uint64_t t0 = now_ns();
              @autoreleasepool { fi_get(l, 1278, 718); }
              double ms = (now_ns() - t0) / 1e6;
              pthread_mutex_lock(&g_res_mu); int still = [g_res_objects containsObject:old_in]; pthread_mutex_unlock(&g_res_mu);
              CHECK(ms >= 250 && !still, "⑦ 旧插值器第 1 槽在途 300 ms：重建等了 %.0f ms（期望 ≥ 250）、旧输入贴图%s驻留集（期望已出）", ms, still ? "仍在" : "已出");
              NvPresentFI *f1 = g_fi; old_in = f1->in_tex[0]; __weak NvPresentFI *w1 = f1; dispatch_semaphore_t s2 = f1->slot_free[1];
              dispatch_semaphore_wait(s2, DISPATCH_TIME_FOREVER); f1 = nil; t0 = now_ns();
              @autoreleasepool { fi_get(l, 1280, 720); }
              ms = (now_ns() - t0) / 1e6;
              pthread_mutex_lock(&g_res_mu); still = [g_res_objects containsObject:old_in]; pthread_mutex_unlock(&g_res_mu);
              CHECK(ms >= 1900 && ms < 5000 && still && w1 != nil, "⑦ 旧插值器第 1 槽一直不完：重建等了 %.0f ms（期望约 2000）、旧输入贴图%s驻留集（期望仍在）、旧对象%s（期望留着）",
                    ms, still ? "仍在" : "已出", w1 ? "留着" : "已放");
              dispatch_semaphore_signal(s2); fi_release(g_fi); g_fi = nil;
          } }
    }
    printf("%s t_fi_link：%u 项，%u 项不符\n", failures ? "✗" : "✓", checks, failures);
    return failures != 0;
} }
