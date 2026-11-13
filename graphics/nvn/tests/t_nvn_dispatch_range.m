// 计算派发的屏障按读写范围决定（nvn_mtl.m disp_ranges / disp_hits / disp_note）。不开 GPU：只测「范围算得对不对、该不该放屏障」。
// 期望全部手算：存储缓冲槽读 + 写、统一缓冲槽只读；读碰到此前的写、写碰到此前的写或读 → 要屏障；互不相交 → 不要。
#ifndef NVN_PRODUCER_SOURCE
#define NVN_PRODUCER_SOURCE "../gfx/nvn/nvn_mtl.m"
#endif
#include NVN_PRODUCER_SOURCE
static int fails;
static void expect(const char *what, long want, long got) { printf("%s 期望 %ld → 真结果 %ld\n", what, want, got); if (want != got) fails++; }
static NvShader *prog(int n, const nvn_rbind *b) { NvShader *s = [NvShader new]; s->rf.nb = n; s->rf.b = calloc((size_t)n, sizeof *b); memcpy(s->rf.b, b, (size_t)n * sizeof *b); return s; }
static void reset(void) { g_bw_n = g_br_n = 0; g_blit_ops = 0; memset(&S, 0, sizeof S); }
int main(void) { @autoreleasepool {
    unsetenv("DM_NVN_DISPATCH_RANGE");
    disp_rng r;
    // 甲：存储槽 0（0x1000 起 0x100 字节）+ 统一槽 1（0x9000 起 0x40）
    nvn_rbind b1[3] = {{.kind = NVN_RB_SBUFP, .reg = 0}, {.kind = NVN_RB_CBUF, .reg = 1}, {.kind = NVN_RB_SUPPORT}};
    NvShader *A = prog(3, b1);
    reset(); S.ssbo[5][0] = (p_bind_buf){5, 0, 0x1000, 0x100}; S.ubo[5][1] = (p_bind_buf){5, 1, 0x9000, 0x40};
    expect("甲：范围算得出", 1, disp_ranges(A, 0, &r));
    expect("甲：写范围个数", 1, r.nw); expect("甲：读范围个数（存储槽 + 统一槽）", 2, r.nr);
    expect("甲：写范围起", 0x1000, (long)r.wlo[0]); expect("甲：写范围止", 0x1100, (long)r.whi[0]);
    expect("甲：统一槽读范围止", 0x9040, (long)r.rhi[1]);
    expect("前面没有操作：不要屏障", 0, g_blit_ops && disp_hits(&r)); disp_note(&r);
    expect("记下之后：写范围 1 条", 1, g_bw_n); expect("读范围 2 条", 2, g_br_n); expect("操作数 1", 1, g_blit_ops);
    // 乙：另一个发射器，存储槽 0 换到 0x2000（不相交）、同一个统一槽（只读对只读）
    S.ssbo[5][0] = (p_bind_buf){5, 0, 0x2000, 0x100};
    expect("乙：范围算得出", 1, disp_ranges(A, 0, &r)); expect("乙与甲互不相交：不要屏障", 0, disp_hits(&r)); disp_note(&r);
    // 丙：读甲写过的那段（存储槽 0 = 0x1080 起 0x10，落在甲的写范围里）
    S.ssbo[5][0] = (p_bind_buf){5, 0, 0x1080, 0x10};
    expect("丙：范围算得出", 1, disp_ranges(A, 0, &r)); expect("丙碰到甲的写：要屏障", 1, disp_hits(&r));
    // 丁：写别人读过的统一缓冲（存储槽 0 = 0x9020 起 0x10，落在统一槽的读范围里）
    S.ssbo[5][0] = (p_bind_buf){5, 0, 0x9020, 0x10};
    expect("丁：范围算得出", 1, disp_ranges(A, 0, &r)); expect("丁写到此前读过的范围：要屏障", 1, disp_hits(&r));
    // 首尾相接不算相交：0x1100 起
    S.ssbo[5][0] = (p_bind_buf){5, 0, 0x1100, 0x10}; S.ubo[5][1] = (p_bind_buf){5, 1, 0xA000, 0x40};
    expect("首尾相接：范围算得出", 1, disp_ranges(A, 0, &r)); expect("首尾相接不相交：不要屏障", 0, disp_hits(&r));
    // 算不出的情形：一律回 0（照旧每次放屏障）
    expect("间接派发：算不出", 0, disp_ranges(A, 1, &r));
    S.ssbo[5][0] = (p_bind_buf){5, 0, 0x1000, 0};
    expect("存储槽绑了但大小为 0：算不出", 0, disp_ranges(A, 0, &r));
    S.ssbo[5][0] = (p_bind_buf){5, 0, 0, 0};
    expect("存储槽没绑：算得出、没有写范围", 1, disp_ranges(A, 0, &r) && r.nw == 0);
    nvn_rbind bi[2] = {{.kind = NVN_RB_SBUFP, .reg = 0}, {.kind = NVN_RB_IMG, .reg = 0}};
    expect("带图像绑定：算不出", 0, disp_ranges(prog(2, bi), 0, &r));
    nvn_rbind bg[1] = {{.kind = NVN_RB_GMEM}};
    expect("带全局内存绑定：算不出", 0, disp_ranges(prog(1, bg), 0, &r));
    nvn_rbind bu[1] = {{.kind = NVN_RB_SBUFU}};
    expect("带追不到槽的存储缓冲：算不出", 0, disp_ranges(prog(1, bu), 0, &r));
    nvn_rbind bt[1] = {{.kind = NVN_RB_TBUF}};
    expect("带贴图缓冲：算不出", 0, disp_ranges(prog(1, bt), 0, &r));
    expect("没有程序：算不出", 0, disp_ranges(nil, 0, &r));
    nvn_rbind bh[4] = {{.kind = NVN_RB_LB}, {.kind = NVN_RB_DRV0}, {.kind = NVN_RB_DRV2}, {.kind = NVN_RB_TEX}};
    expect("只带宿主自己的表和只读贴图：算得出、没有范围", 1, disp_ranges(prog(4, bh), 0, &r) && r.nw == 0 && r.nr == 0);
    // 表快满：放不下就要屏障
    reset(); S.ssbo[5][0] = (p_bind_buf){5, 0, 0x1000, 0x100}; S.ubo[5][1] = (p_bind_buf){5, 1, 0x9000, 0x40}; disp_ranges(A, 0, &r);
    g_bw_n = BW_MAX; g_blit_ops = 1;
    expect("写范围表已满：要屏障", 1, disp_hits(&r));
    // 关掉开关：一律算不出
    setenv("DM_NVN_DISPATCH_RANGE", "0", 1);
    // 开关只读一次环境变量，这里不再重测（另一进程测）
    if (fails) printf("✗ t_nvn_dispatch_range：%d 项不符\n", fails); else printf("✓ t_nvn_dispatch_range：派发读写范围、相交判断、算不出的各种情形\n");
    return fails != 0; } }
