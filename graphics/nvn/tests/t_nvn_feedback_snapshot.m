// Real Metal functions, production NVN draw/argument encoding/feedback copies,
// and independent GPU readback. No replaced production or host symbols.
// NVN_FEEDBACK_SOURCE permits compiling an exact git-show copy of nvn_mtl.m
// without changing the live source used by another contributor.
#ifndef NVN_FEEDBACK_SOURCE
#define NVN_FEEDBACK_SOURCE "../gfx/nvn/nvn_mtl.m"
#endif
#include NVN_FEEDBACK_SOURCE

static unsigned checks, failures;
#define REQUIRE(c) do { if (!(c)) { fprintf(stderr, "SETUP FAIL %s:%d %s\n", __FILE__, __LINE__, #c); exit(2); } } while (0)
#define CHECK(c, ...) do { checks++; int ok = !!(c); failures += !ok; printf("%s ", ok ? "PASS" : "FAIL"); printf(__VA_ARGS__); putchar('\n'); fflush(stdout); } while (0)

static NSString *const source = @"#include <metal_stdlib>\nusing namespace metal;\n"
"struct Inputs { texture2d<float, access::read> a [[id(0)]]; texture2d<float, access::read> b [[id(1)]]; };\n"
"vertex float4 triangle(uint i [[vertex_id]]) { const float2 p[3] = {float2(-1,-1),float2(3,-1),float2(-1,3)}; return float4(p[i],0,1); }\n"
"struct Result { float4 c [[color(2)]]; };\n"
"fragment Result colors(constant Inputs &t [[buffer(0)]]) { float4 a=t.a.read(uint2(0)), b=t.b.read(uint2(0)); Result o; o.c=float4(a.r,b.r,a.g,1); return o; }\n"
"fragment float4 self_colors(constant Inputs &t [[buffer(0)]]) { float4 a=t.a.read(uint2(0)), b=t.b.read(uint2(0)); return float4(a.r,b.r,a.g,1); }\n";

static NvShader *shader(id<MTLLibrary> library, NSString *name, int stage) {
    NvShader *s = [NvShader new]; s->stage = stage;
    s->fn = [library newFunctionWithName:name]; REQUIRE(s->fn);
    strlcpy(s->key, stage ? "bbbbbbbbbbbbbbbb_b" : "aaaaaaaaaaaaaaaa_b", sizeof s->key);
    s->rf.pos_attr = -1;
    s->rf.has_user = stage ? 2 : 1;
    if (stage) {
        // These two bindings correspond exactly to Inputs' id(0)/id(1),
        // texture2d<float,access::read> and the buffer(0) declaration above.
        s->rf.nb = 2; s->rf.abi = 0;
        s->rf.b = calloc(2, sizeof *s->rf.b); REQUIRE(s->rf.b);
        for (int i = 0; i < 2; i++) s->rf.b[i] = (nvn_rbind){.kind=NVN_RB_TEX, .reg=i, .aid=i, .dtt=MTLTextureType2D};
        s->ae = [s->fn newArgumentEncoderWithBufferIndex:0]; REQUIRE(s->ae);
        s->arg_len = s->ae.encodedLength;
        s->rf.color_known = 1; s->rf.color_mask = [name isEqualToString:@"self_colors"] ? 1 : 1 << 2;
    }
    return s;
}

static void make_texture(tex_t *t, pool_t *pool, size_t offset) {
    memset(t, 0, sizeof *t); t->magic = MAGIC('T','E','X',0); t->serial = nvn_new_serial();
    t->d = (nvn_texdesc){.target=NVN_TEXTURE_TARGET_2D, .format=NVN_FORMAT_RGBA8,
        .flags=NVN_TEXTURE_FLAGS_IMAGE, .width=4, .height=4, .depth=1, .levels=1};
    t->pool=pool; t->off=offset; t->mem=pool->mem+offset;
    nvn_tex_layout(&t->d, &t->L); nvn_be_tex_init(t);
    id<MTLTexture> image=tex_mtl(t); REQUIRE(image);
    REQUIRE(image.pixelFormat == MTLPixelFormatRGBA8Unorm);
}

static void clear(tex_t *t, unsigned r, unsigned g, unsigned b) {
    p_clear_tex c={.tex=t, .value_type=CLEAR_TEX_FLOAT, .r={0,0,0,4,4,1}, .mask=15};
    c.c.f[0]=r/255.0f; c.c.f[1]=g/255.0f; c.c.f[2]=b/255.0f; c.c.f[3]=1;
    clear_tex(&c);
}

static void targets(tex_t *a, tex_t *b, tex_t *out) {
    rp_flush();
    memset(&R.rt, 0, sizeof R.rt); R.rt.n=3;
    R.rt.color[0]=a; R.rt.color[1]=b; R.rt.color[2]=out;
    R.has_rt=1; g_pso_dirty=1; args_dirty_all();
}

static void pixels(const char *name, tex_t *t, unsigned r, unsigned g, unsigned b) {
    id<MTLTexture> image=tex_mtl(t); REQUIRE(image);
    // Read the GPU result independently; no production readback/layout decoder.
    id<MTLBuffer> buffer=[g_dev newBufferWithLength:1024 options:MTLResourceStorageModeShared]; REQUIRE(buffer);
    memset(buffer.contents, 0xa5, 1024);
    id<MTLCommandQueue> queue=[g_dev newCommandQueue]; REQUIRE(queue);
    id<MTLCommandBuffer> cb=[queue commandBuffer]; REQUIRE(cb);
    id<MTLBlitCommandEncoder> enc=[cb blitCommandEncoder]; REQUIRE(enc);
    [enc copyFromTexture:image sourceSlice:0 sourceLevel:0 sourceOrigin:MTLOriginMake(0,0,0)
        sourceSize:MTLSizeMake(4,4,1) toBuffer:buffer destinationOffset:0 destinationBytesPerRow:256 destinationBytesPerImage:1024];
    [enc endEncoding]; [cb commit]; [cb waitUntilCompleted]; REQUIRE(cb.status==MTLCommandBufferStatusCompleted);
    const uint8_t *bytes=buffer.contents; unsigned wrong=0;
    unsigned expected[4]={r,g,b,255};
    for(unsigned y=0;y<4;y++) for(unsigned x=0;x<4;x++) for(unsigned c=0;c<4;c++) {
        unsigned actual=bytes[y*256+x*4+c];
        if(actual!=expected[c]) wrong++;
    }
    CHECK(!wrong, "%s: 16 GPU pixels expected=(%u,%u,%u,255), first=(%u,%u,%u,%u), wrong channels=%u",
        name,r,g,b,bytes[0],bytes[1],bytes[2],bytes[3],wrong);
}

static void finish(void) {
    uint64_t fence=nvn_be_sub_commit();
    REQUIRE(nvn_be_wait(fence,10000000000ull)); REQUIRE(!mtl_last_commit_error());
}

static void pending_clear_draw(const p_draw *triangle) {
    struct {
        op_hdr h0; p_clear_color c0;
        op_hdr h1; p_clear_color c1;
        op_hdr hd; p_draw d;
        op_hdr end;
    } commands = {
        .h0={OP_CLEAR_COLOR,sizeof(op_hdr)+sizeof(p_clear_color)},
        .c0={.index=0,.mask=15,.rgba={48/255.0f,80/255.0f,112/255.0f,1}},
        .h1={OP_CLEAR_COLOR,sizeof(op_hdr)+sizeof(p_clear_color)},
        .c1={.index=1,.mask=15,.rgba={176/255.0f,208/255.0f,240/255.0f,1}},
        .hd={OP_DRAW,sizeof(op_hdr)+sizeof(p_draw)},.d=*triangle,
        .end={OP_END,sizeof(op_hdr)}
    };
    nvn_be_exec((const uint8_t *)&commands);
}

// Inspect the actual resource ID encoded by production encode_args, not just
// its choice of feedback branch. These root 2D textures have no aliasing views:
// a sampled resource equal to the attached resource leaves a feedback hazard,
// even when a particular GPU happens to return the expected pixels.
static void binding(const char *name, NvShader *fs, tex_t *attachment, int isolated) {
    REQUIRE(fs->ab_buf && fs->arg_len >= 8);
    uint64_t sampled=0;
    memcpy(&sampled,(const uint8_t *)fs->ab_buf.contents+fs->ab_off,sizeof sampled);
    uint64_t attached=tex_mtl(attachment).gpuResourceID._impl;
    CHECK(sampled && ((sampled!=attached)==isolated),
        "%s: production argument id=%#llx attachment id=%#llx, expected %s",
        name,(unsigned long long)sampled,(unsigned long long)attached,
        isolated ? "different resources" : "original resource (read-only attachment)");
}

static void automatic_cases(NvProg *reader, prog_t *reader_p, NvProg *self, prog_t *self_p,
                            tex_t *a, tex_t *b, tex_t *out, const p_draw *triangle) {
    nvn_be_sub_begin(); state_reset(); S.prog=reader_p; S.tex[1][0]=1; S.tex[1][1]=2;
    clear(a,32,64,96); clear(b,160,192,224); clear(out,0,0,0);
    uint64_t before=g_fb_count;
    targets(a,b,out); rp_begin(); REQUIRE(g_enc && !g_fb_dirty[0] && !g_fb_dirty[1]);
    draw(triangle,NULL);
    binding("default non-self-write",reader->sh[1],a,0);
    CHECK(g_fb_count==before,"default non-self-write uses no snapshot");
    finish(); pixels("default non-self-write",out,32,160,64);

    nvn_be_sub_begin(); state_reset(); S.prog=self_p; S.tex[1][0]=1; S.tex[1][1]=2;
    clear(a,32,64,96); clear(b,160,192,224); clear(out,0,0,0);
    targets(a,b,out); rp_begin(); REQUIRE(g_enc && !g_fb_dirty[0]);
    draw(triangle,NULL);
    binding("default self-write dirty=0",self->sh[1],a,1);
    finish(); pixels("default self-write dirty=0",a,32,160,64);

    nvn_be_sub_begin(); state_reset(); S.prog=self_p; S.tex[1][0]=2; S.tex[1][1]=2;
    clear(a,32,64,96); clear(b,160,192,224); clear(out,0,0,0);
    targets(a,b,out); draw(triangle,NULL); // Real writer: A=(B.r,B.r,B.g,1).
    REQUIRE(g_enc && g_fb_dirty[0]);
    S.tex[1][0]=1; args_dirty_all();
    draw(triangle,NULL);
    binding("default self-write dirty=1",self->sh[1],a,1);
    finish(); pixels("default self-write dirty=1",a,160,160,160);
}

static void storage_alias_cases(prog_t *p, tex_t *a, tex_t *b, tex_t *out,
                                pool_t *pool, const p_draw *triangle, int all) {
    // Run in the process-selected policy; do not change cached production flags.
    tex_t alias_a,alias_b;
    make_texture(&alias_a,pool,0); make_texture(&alias_b,pool,65536);
    REQUIRE(alias_a.serial!=a->serial && alias_b.serial!=b->serial);
    REQUIRE(tex_mtl(&alias_a)==tex_mtl(a) && tex_mtl(&alias_b)==tex_mtl(b));
    nvn_be_reg_tex(4,&alias_a,NULL); nvn_be_reg_tex(5,&alias_b,NULL);
    nvn_be_sub_begin(); state_reset(); S.prog=p; S.tex[1][0]=4; S.tex[1][1]=5;
    clear(a,0,0,0); clear(b,0,0,0); clear(out,0,0,0);
    uint64_t copies_before=g_fb_count, hits_before=g_fb_hits;
    targets(a,b,out); pending_clear_draw(triangle); finish();
    pixels("different serials sharing attachment storage see pending clears",out,48,176,80);
    CHECK(g_fb_hits-hits_before==2,"detect both aliased attachments (got %llu)",
        (unsigned long long)(g_fb_hits-hits_before));
    CHECK(g_fb_count-copies_before==(all?2:0),"storage aliases use policy's snapshot count (expected %d, got %llu)",
        all?2:0,(unsigned long long)(g_fb_count-copies_before));

    // Equal dimensions and format do not make disjoint pool ranges alias.
    tex_t independent_a,independent_b;
    make_texture(&independent_a,pool,262144); make_texture(&independent_b,pool,327680);
    nvn_be_reg_tex(6,&independent_a,NULL); nvn_be_reg_tex(7,&independent_b,NULL);
    nvn_be_sub_begin(); state_reset(); S.prog=p; S.tex[1][0]=6; S.tex[1][1]=7;
    clear(&independent_a,32,64,96); clear(&independent_b,160,192,224);
    clear(a,0,0,0); clear(b,0,0,0); clear(out,0,0,0);
    copies_before=g_fb_count;
    targets(a,b,out); pending_clear_draw(triangle); finish();
    pixels("same-shape disjoint storage remains independent",out,32,160,64);
    CHECK(g_fb_count==copies_before,"disjoint storage takes no feedback snapshots (got %llu)",
        (unsigned long long)(g_fb_count-copies_before));
}

// #387: a draw that samples its own pass's depth attachment (NVN: legal, reads memory; Metal: undefined in the same pass). Expected by the rule, not by
// running the implementation: the argument the production encode_args writes for that slot is a different resource from the attached depth texture,
// one more copy is made, and the submission completes without a Metal error. Against the source before the fix the argument is the attachment itself.
static void depth_case(NvProg *reader, prog_t *reader_p, tex_t *depth, tex_t *b, tex_t *out, const p_draw *triangle) {
    nvn_be_sub_begin(); state_reset(); S.prog=reader_p; S.tex[1][0]=4; S.tex[1][1]=2;
    clear(b,160,192,224); clear(out,0,0,0);
    uint64_t copies=g_fb_count, depth_before=g_fb_depth;
    rp_flush(); memset(&R.rt, 0, sizeof R.rt); R.rt.n=3; R.rt.color[2]=out; R.rt.depth=depth;
    R.has_rt=1; g_pso_dirty=1; args_dirty_all();
    rp_begin(); REQUIRE(g_enc);
    draw(triangle,NULL);
    binding("depth attachment sampled in its own pass",reader->sh[1],depth,1);
    CHECK(g_fb_depth-depth_before==1 && g_fb_count-copies==1,"depth attachment sampled in its own pass: one copy (depth copies %llu, all copies %llu)",
        (unsigned long long)(g_fb_depth-depth_before),(unsigned long long)(g_fb_count-copies));
    // The same depth unchanged: a second sampling draw reads the first copy (no new copy, no pass break); after a draw that writes depth the next one copies again
    uint64_t c1=g_fb_depth, r1=g_fb_depth_reuse, passes=g_stat_pass;
    draw(triangle,NULL);
    CHECK(g_fb_depth==c1 && g_fb_depth_reuse-r1==1 && g_stat_pass==passes,"second draw on unchanged depth: reuses the copy (new copies %llu, reuses %llu, passes opened %llu)",
        (unsigned long long)(g_fb_depth-c1),(unsigned long long)(g_fb_depth_reuse-r1),(unsigned long long)(g_stat_pass-passes));
    S.ds.dt=1; S.ds.dw=1; S.ds.df=8; g_pso_dirty=1; draw(triangle,NULL);   // writes depth (and samples it: a fresh copy of the depth before this draw)
    S.ds.dw=0; g_pso_dirty=1; uint64_t c2=g_fb_depth; draw(triangle,NULL);
    CHECK(g_fb_depth-c2==1,"after a depth-writing draw the next sampling draw copies again (new copies %llu)",(unsigned long long)(g_fb_depth-c2));
    // Stencil writes leave the depth plane a depth-view copy holds as it was: with the stencil test on and an op that writes (REPLACE on pass, write mask 0xff),
    //   two more sampling draws still read the copy (a deferred lighting pass: one light volume per draw, stencil on, depth writes off). The old rule copied for each
    uint64_t sc=g_fb_depth, sr=g_fb_depth_reuse, sp=g_stat_pass;
    S.ds.st=1; S.st_wmask[0]=S.st_wmask[1]=0xff; S.ds.zpass_f=S.ds.zpass_b=NVN_STENCIL_OP_REPLACE; g_pso_dirty=1;
    draw(triangle,NULL); draw(triangle,NULL);
    CHECK(g_fb_depth==sc && g_fb_depth_reuse-sr==2 && g_stat_pass==sp,"stencil-writing draws sampling the depth: reuse the depth-view copy (new copies %llu, reuses %llu, passes opened %llu)",
        (unsigned long long)(g_fb_depth-sc),(unsigned long long)(g_fb_depth_reuse-sr),(unsigned long long)(g_stat_pass-sp));
    S.ds.st=0; S.ds.zpass_f=S.ds.zpass_b=NVN_STENCIL_OP_KEEP; g_pso_dirty=1;
    finish(); CHECK(!mtl_last_commit_error(),"depth attachment sampled in its own pass: submission completes without a Metal error");
    // Audit P2-247: a whole-surface depth clear with no pass open is only recorded (R.clear_d, folded into the next pass's load action). A draw sampling that depth in the pass must
    //   see the cleared value, as on the Switch the clear is in memory before the draw runs: the copy is taken after the clear lands. Expected 0.75 (the clear), never the old 0.25
    nvn_be_sub_begin(); state_reset(); S.prog=reader_p; S.tex[1][0]=4; S.tex[1][1]=2;
    rp_flush(); memset(&R.rt, 0, sizeof R.rt); R.rt.n=3; R.rt.color[2]=out; R.rt.depth=depth; R.has_rt=1; g_pso_dirty=1; args_dirty_all();
    R.clear_d=1; R.cd=0.25; rp_flush();   // old content 0.25 in the texture
    dsnap_stale(); R.clear_d=1; R.cd=0.75;   // what OP_CLEAR_DS records with no pass open (full scissor, no stencil)
    uint64_t c3=g_fb_depth; draw(triangle,NULL);
    REQUIRE(g_fb_depth-c3==1 && g_dsnap.use);
    id<MTLTexture> snap=g_dsnap.use; finish();
    id<MTLBuffer> rb=[g_dev newBufferWithLength:16*4 options:MTLResourceStorageModeShared];
    id<MTLCommandQueue> q=[g_dev newCommandQueue]; id<MTLCommandBuffer> cb=[q commandBuffer]; id<MTLBlitCommandEncoder> be=[cb blitCommandEncoder];
    id<MTLTexture> sb=snap.parentTexture ? snap.parentTexture : snap;
    [be copyFromTexture:sb sourceSlice:0 sourceLevel:0 sourceOrigin:MTLOriginMake(0,0,0) sourceSize:MTLSizeMake(4,4,1) toBuffer:rb destinationOffset:0 destinationBytesPerRow:16 destinationBytesPerImage:64 options:MTLBlitOptionDepthFromDepthStencil];
    [be endEncoding]; [cb commit]; [cb waitUntilCompleted];
    float d0=((float *)rb.contents)[0];
    CHECK(d0==0.75f,"pending depth clear then same-pass sampling: the copy holds the cleared depth (read %g, expected 0.75)",d0);
    // Precise dsnap invalidation: unrelated textures / buffer ranges must keep g_dsnap valid, while overlapping ones must stale it
    tex_t d_obj = *depth; d_obj.mem = (uint8_t *)(uintptr_t)0x100000000ull; d_obj.L.size = 0x10000;
    tex_t other = *out;   other.serial = depth->serial + 999; other.mem = (uint8_t *)(uintptr_t)0x200000000ull; other.L.size = 0x10000;
    tex_t alias = *out;   alias.serial = depth->serial + 1000; alias.mem = d_obj.mem + 0x1000; alias.L.size = 0x2000;
    g_dsnap.ser = d_obj.serial; g_dsnap.mem = d_obj.mem; g_dsnap.size = d_obj.L.size; g_dsnap.base = nil; g_dsnap.valid = 1;
    dsnap_stale_tex(&other);
    dsnap_stale_addr((uint64_t)(uintptr_t)other.mem, 0x1000);
    CHECK(g_dsnap.valid == 1, "unrelated texture / buffer range leaves depth snapshot valid");
    dsnap_stale_tex(&alias);
    CHECK(g_dsnap.valid == 0, "overlapping aliased texture stales depth snapshot");
    g_dsnap.valid = 1;
    dsnap_stale_addr((uint64_t)(uintptr_t)(d_obj.mem + 0x800), 64);
    CHECK(g_dsnap.valid == 0, "overlapping buffer write range stales depth snapshot");
    g_dsnap.valid = 1;
    dsnap_stale_tex(&d_obj);
    CHECK(g_dsnap.valid == 0, "same serial texture stales depth snapshot");
    // 换不成 CPU 地址的 GPU 地址（GPU 地址窗口 0xC000000000 起、没映射到任何池：nvn_ga2ca 原样回 GPU 地址）判不了重叠：要按改过算。
    //   旧写法拿 GPU 地址和深度的 CPU 区间比、永远不重叠，快照不作废、之后读到旧深度
    g_dsnap.valid = 1;
    dsnap_stale_addr(0xC000000000ull + 0x3000000000ull, 64);
    CHECK(g_dsnap.valid == 0, "unmapped GPU address write stales depth snapshot (overlap cannot be judged)");

    // UE4 CustomDepth / CustomStencil 同存储别名：模板模式贴图（stencil=1，serial != depth->serial）在同遍被片元采样，
    // 必须识别为同遍深度/模板反馈并建快照；且前笔写入模板后，后笔必须重新快照而不是复用写前旧模板。
    tex_t st_alias = *depth; st_alias.serial = nvn_new_serial(); st_alias.stencil = 1; nvn_be_tex_init(&st_alias);
    nvn_be_reg_tex(8, &st_alias, NULL);
    NSString *stSrc = @"#include <metal_stdlib>\nusing namespace metal;\n"
        "struct StIn { texture2d<float, access::read> st [[id(0)]]; };\n"
        "vertex float4 st_vs(uint i [[vertex_id]]) { const float2 p[3]={float2(-1,-1),float2(3,-1),float2(-1,3)}; return float4(p[i],0,1); }\n"
        "struct StOut { float4 c [[color(2)]]; };\n"
        "fragment StOut st_fs(constant StIn &t [[buffer(0)]]) { uint4 v = as_type<uint4>(t.st.read(uint2(0))); StOut o; o.c = float4(v.y / 255.0f, 0, 0, 1); return o; }\n";
    NSError *stErr = nil; id<MTLLibrary> stLib = [g_dev newLibraryWithSource:stSrc options:nil error:&stErr]; REQUIRE(stLib);
    NvProg *stPr = [NvProg new];
    stPr->sh[0] = shader(stLib, @"st_vs", 0);
    stPr->sh[1] = [NvShader new]; stPr->sh[1]->stage = 1; stPr->sh[1]->fn = [stLib newFunctionWithName:@"st_fs"]; REQUIRE(stPr->sh[1]->fn);
    strlcpy(stPr->sh[1]->key, "dddddddddddddddd_b", sizeof stPr->sh[1]->key);
    stPr->sh[1]->rf.pos_attr = -1; stPr->sh[1]->rf.has_user = 2; stPr->sh[1]->rf.nb = 1; stPr->sh[1]->rf.abi = 0;
    stPr->sh[1]->rf.b = calloc(1, sizeof *stPr->sh[1]->rf.b);
    stPr->sh[1]->rf.b[0] = (nvn_rbind){.kind = NVN_RB_TEX, .reg = 0, .aid = 0, .dtt = MTLTextureType2D};
    stPr->sh[1]->ae = [stPr->sh[1]->fn newArgumentEncoderWithBufferIndex:0]; REQUIRE(stPr->sh[1]->ae);
    stPr->sh[1]->arg_len = stPr->sh[1]->ae.encodedLength;
    stPr->sh[1]->rf.color_known = 1; stPr->sh[1]->rf.color_mask = 1 << 2;
    prog_t st_p = {.magic = MAGIC('P','R','O','G'), .serial = nvn_new_serial()}; serial_put(st_p.serial, stPr);

    nvn_be_sub_begin(); state_reset(); S.prog = &st_p; S.tex[1][0] = 8;
    clear(out, 0, 0, 0);
    rp_flush(); memset(&R.rt, 0, sizeof R.rt); R.rt.n = 3; R.rt.color[2] = out; R.rt.depth = depth; R.has_rt = 1;
    R.clear_d = 1; R.cd = 0.5; R.clear_s = 1; R.cs = 0x55; rp_flush();
    dsnap_stale(); g_pso_dirty = 1; args_dirty_all();
    // 笔 1：首次采样同存储 stencil_alias（写 stencil=0xAA），必须识别并创建 stencil 快照，读取写前值 0x55
    S.ds.st = 1; S.st_wmask[0] = S.st_wmask[1] = 0xff; S.st_ref[0] = S.st_ref[1] = 0xAA;
    S.ds.sf_f = S.ds.sf_b = NVN_STENCIL_FUNC_ALWAYS; S.ds.zpass_f = S.ds.zpass_b = NVN_STENCIL_OP_REPLACE;
    uint64_t fd0 = g_fb_depth, fh0 = g_fb_hits;
    draw(triangle, NULL);
    CHECK(g_fb_depth - fd0 == 1 && g_fb_hits - fh0 == 1 && g_dsnap.valid && g_dsnap.stencil && g_dsnap.dser == depth->serial,
          "同遍深度别名 CustomStencil 采样：命中检测并创建模板快照 (hits +%llu depth +%llu stencil=%d dser=%llu)",
          (unsigned long long)(g_fb_hits - fh0), (unsigned long long)(g_fb_depth - fd0), g_dsnap.stencil, (unsigned long long)g_dsnap.dser);
    // 笔 2：写模板关闭后同遍再次采样 stencil_alias，必须因为笔 1 写了模板而作废重拍、读到新模板 0xAA（~170）
    S.ds.st = 0; S.ds.zpass_f = S.ds.zpass_b = NVN_STENCIL_OP_KEEP; g_pso_dirty = 1;
    uint64_t fd1 = g_fb_depth;
    draw(triangle, NULL);
    CHECK(g_fb_depth - fd1 == 1, "前笔写模板后再次采样模板别名：快照已作废并重拍 (depth +%llu)", (unsigned long long)(g_fb_depth - fd1));
    finish();
    pixels("同遍采样模板别名读到前笔写入后的 0xAA (.g)", out, 0xAA, 0, 0);
}

int main(int argc, char **argv) {
    int all=argc==2 && !strcmp(argv[1],"--snap-all");
    REQUIRE(argc==1 || all);
    @autoreleasepool {
        char map[]="/tmp/t_feedback_map_XXXXXX"; int fd=mkstemp(map); REQUIRE(fd>=0); close(fd);
        char user[]="/tmp/t_feedback_user_XXXXXX"; fd=mkstemp(user); REQUIRE(fd>=0); close(fd);
        setenv("DM_NVN_SHMAP",map,1); setenv("DM_PSO_USER",user,1);
        if (all) setenv("DM_NVN_FB_SNAP","all",1);
        else unsetenv("DM_NVN_FB_SNAP");
        setenv("DM_PSO_ARCHIVE","0",1); // no shared /tmp pipeline cache; real PSOs still compile
        mtl_init(); printf("BACKEND %s\n",g_m3?"Metal3":"Metal4");
        // Replay's first entry initializes its state. Do so before installing
        // the bindings used by these direct production draw calls.
        const op_hdr empty={OP_END,sizeof(op_hdr)}; nvn_be_exec((const uint8_t *)&empty);
        NSError *error=nil; id<MTLLibrary> library=[g_dev newLibraryWithSource:source options:nil error:&error];
        if(!library) fprintf(stderr,"MSL: %s\n",error.localizedDescription.UTF8String); REQUIRE(library);
        NvProg *program=[NvProg new]; program->sh[0]=shader(library,@"triangle",0); program->sh[1]=shader(library,@"colors",1);
        prog_t p={.magic=MAGIC('P','R','O','G'), .serial=nvn_new_serial()}; serial_put(p.serial,program);
        NvProg *self=[NvProg new]; self->sh[0]=program->sh[0]; self->sh[1]=shader(library,@"self_colors",1);
        // Distinct real shader functions must also have distinct pipeline keys.
        strlcpy(self->sh[1]->key,"cccccccccccccccc_b",sizeof self->sh[1]->key);
        prog_t self_p={.magic=MAGIC('P','R','O','G'), .serial=nvn_new_serial()}; serial_put(self_p.serial,self);
        uint8_t *memory=NULL; REQUIRE(!posix_memalign((void **)&memory,65536,1<<20)); memset(memory,0,1<<20);
        // Production no-copy pool remains alive for the complete GPU lifetime.
        pool_t *pool=calloc(1,sizeof *pool); REQUIRE(pool);
        *pool=(pool_t){.magic=MAGIC('P','O','O','L'), .flags=NVN_MEMORY_POOL_FLAGS_CPU_NO_ACCESS|NVN_MEMORY_POOL_FLAGS_GPU_CACHED, .mem=memory, .size=1<<20};
        nvn_be_pool_add(memory,1<<20);
        tex_t a,b,first,second; make_texture(&a,pool,0); make_texture(&b,pool,65536);
        make_texture(&first,pool,131072); make_texture(&second,pool,196608);
        nvn_be_reg_tex(1,&a,NULL); nvn_be_reg_tex(2,&b,NULL);
        p_draw triangle={.prim=NVN_DRAW_PRIMITIVE_TRIANGLES, .count=3, .instances=1};

        if (!all) {
            automatic_cases(program,&p,self,&self_p,&a,&b,&first,&triangle);
            tex_t depth; memset(&depth,0,sizeof depth); depth.magic=MAGIC('T','E','X',0); depth.serial=nvn_new_serial();
            depth.d=(nvn_texdesc){.target=NVN_TEXTURE_TARGET_2D, .format=NVN_FORMAT_DEPTH32F_STENCIL8, .width=4, .height=4, .depth=1, .levels=1};
            depth.pool=pool; depth.off=262144; depth.mem=pool->mem+262144; nvn_tex_layout(&depth.d,&depth.L); nvn_be_tex_init(&depth);
            REQUIRE(tex_mtl(&depth) && tex_mtl(&depth).pixelFormat==MTLPixelFormatDepth32Float_Stencil8);
            nvn_be_reg_tex(4,&depth,NULL);
            depth_case(program,&p,&depth,&b,&first,&triangle);
        } else {
        nvn_be_sub_begin(); state_reset(); S.prog=&p; S.tex[1][0]=1; S.tex[1][1]=2;
        clear(&a,32,64,96); clear(&b,160,192,224); clear(&first,0,0,0); clear(&second,0,0,0);
        targets(&a,&b,&first); draw(&triangle,NULL);
        // A second real draw in the same submission must copy the new content.
        clear(&a,80,112,144); clear(&b,208,16,48);
        targets(&a,&b,&second); draw(&triangle,NULL); finish();
        pixels("same draw, distinct same-format/size attachments",&first,32,160,64);
        pixels("next draw sees changed source, first result stays intact",&second,80,208,112);

        view_t view={.set_swizzle=1, .swz={NVN_TEXTURE_SWIZZLE_B,NVN_TEXTURE_SWIZZLE_G,NVN_TEXTURE_SWIZZLE_R,NVN_TEXTURE_SWIZZLE_A}};
        nvn_be_reg_tex(3,&a,&view);
        nvn_be_sub_begin(); state_reset(); S.prog=&p; S.tex[1][0]=1; S.tex[1][1]=3;
        clear(&a,32,64,96); clear(&first,0,0,0);
        uint64_t copies_before=g_fb_count;
        targets(&a,&b,&first); draw(&triangle,NULL); finish();
        pixels("same attachment, identity and BGR views",&first,32,96,64);
        CHECK(g_fb_count-copies_before==1,"two views of one subresource issue one copy (got %llu)",
            (unsigned long long)(g_fb_count-copies_before));

        nvn_be_sub_begin(); state_reset(); S.prog=&p; S.tex[1][0]=1; S.tex[1][1]=2;
        clear(&a,0,0,0); clear(&b,0,0,0); clear(&first,0,0,0);
        targets(&a,&b,&first); pending_clear_draw(&triangle); finish();
        pixels("pending ClearColor lands before feedback snapshot",&first,48,176,80);
        }
        storage_alias_cases(&p,&a,&b,&first,pool,&triangle,all);
        // Verify fb_prepare's per-shader fb_tex cache: textured FS caches 2, untextured FS caches 1 and fast-exits
        NvProg *notex=[NvProg new]; notex->sh[0]=program->sh[0]; notex->sh[1]=[NvShader new];
        notex->sh[1]->rf.nb=0; notex->sh[1]->fb_tex=0;
        R.rt.n=1; R.rt.color[0]=&a; R.has_rt=1;
        fb_prepare(notex);
        CHECK(program->sh[1]->fb_tex==2 && notex->sh[1]->fb_tex==1 && g_fb_n==0,
              "fb_prepare fb_tex cache: textured=%u (expect 2), untextured=%u (expect 1)",
              program->sh[1]->fb_tex, notex->sh[1]->fb_tex);
        unlink(map); unlink(user);
    }
    printf("%s t_nvn_feedback_snapshot %s: %u checks, %u failures\n",failures?"✗":"✓",all?"snap-all":"default",checks,failures);
    return failures?1:0;
}
