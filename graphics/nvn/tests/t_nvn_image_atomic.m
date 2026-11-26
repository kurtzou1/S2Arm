// Authored GLSL -> actual SPIR-V / MSL / DshCompiler.Reflect -> production NVN.
// No hand-authored MSL/reflection or substituted production/host symbols.
// Eight lanes: distinct xyz CAS success/failure, one winner, CAS-loop count,
// same-dispatch and next-dispatch ordinary reads; CPU expectations are independent.
#include "../gfx/nvn/nvn_mtl.m"
#include <limits.h>

static unsigned checks, failures;
#define REQUIRE(c) do { if (!(c)) { fprintf(stderr,"SETUP FAIL %s:%d %s\n",__FILE__,__LINE__,#c); exit(2); } } while(0)
#define CHECK(c, ...) do { checks++; int good=!!(c); failures+=!good; printf("%s ",good?"PASS":"FAIL"); printf(__VA_ARGS__); putchar('\n'); fflush(stdout); } while(0)
static NSString *directory;

static NvShader *shader(NSString *label) {
    NSError *error=nil;
    id<MTLLibrary> library=lib_from_file([directory stringByAppendingPathComponent:[label stringByAppendingString:@".metallib"]],&error);
    if (!library) fprintf(stderr,"library: %s\n",error.localizedDescription.UTF8String);
    REQUIRE(library);
    NvShader *s=[NvShader new]; s->stage=5;
    s->fn=[library newFunctionWithName:@"main0"]; REQUIRE(s->fn);
    s->ae=[s->fn newArgumentEncoderWithBufferIndex:0]; REQUIRE(s->ae);
    s->arg_len=s->ae.encodedLength;
    NSData *data=[NSData dataWithContentsOfFile:[directory stringByAppendingPathComponent:[label stringByAppendingString:@".nvn.json"]]];
    REQUIRE(data);
    NSDictionary *json=[NSJSONSerialization JSONObjectWithData:data options:0 error:&error]; REQUIRE(json);
    char err[1024]={0}; int rc=nvn_refl_from_json(json,&s->rf,err,sizeof err);
    printf("REFLECT %s rc=%d nb=%d error=%s\n",label.UTF8String,rc,s->rf.nb,err); REQUIRE(!rc);
    for(int i=0;i<s->rf.nb;i++) {
        nvn_rbind *b=&s->rf.b[i];
        printf("BIND %s kind=%u reg=%u arg_id=%u rw=%u dtt=%u dpf=%u\n",label.UTF8String,b->kind,b->reg,b->aid,b->rw,b->dtt,b->dpf);
        REQUIRE(b->reg<2 && (b->kind==NVN_RB_IMG || b->kind==NVN_RB_IMGA));
        if([label containsString:@"buffer"]) CHECK(b->dtt==MTLTextureTypeTextureBuffer || b->kind==NVN_RB_IMGA,
            "%s reflected buffer dtype=%u",label.UTF8String,b->dtt);
        if(b->reg==1) CHECK(!b->atomic_image,"%s ordinary output has no atomic marker",label.UTF8String);
    }
    int wants_atomic=![label containsString:@"observe"] && ![label isEqualToString:@"buffer"];
    CHECK(!!s->rf.has_atomic_image==wants_atomic,"%s native-atomic reflection present=%d want=%d",label.UTF8String,s->rf.has_atomic_image,wants_atomic);
    return s;
}
static void program(prog_t *p,NvShader *s) {
    memset(p,0,sizeof *p); p->magic=MAGIC('P','R','O','G'); p->serial=nvn_new_serial();
    NvProg *o=[NvProg new]; o->sh[5]=s; serial_put(p->serial,o);
}
static void make_texture(tex_t *t,pool_t *pool,size_t off,int buffer,int output,int sign,int options) {
    memset(t,0,sizeof *t); t->magic=MAGIC('T','E','X',0); t->serial=nvn_new_serial();
    t->d=(nvn_texdesc){.target=buffer?NVN_TEXTURE_TARGET_BUFFER:NVN_TEXTURE_TARGET_3D,
        .format=(options&2)?NVN_FORMAT_RGBA8:sign?NVN_FORMAT_R32I:NVN_FORMAT_R32UI,.flags=(options&1)?0:NVN_TEXTURE_FLAGS_IMAGE,
        .width=buffer||output?64:4,.height=buffer||output?1:4,.depth=buffer||output?1:4,.levels=1};
    t->pool=pool; t->off=off; t->mem=pool->mem+off; nvn_tex_layout(&t->d,&t->L); nvn_be_tex_init(t);
    id<MTLTexture> image=tex_mtl(t); REQUIRE(image);
    printf("TEXTURE buffer=%d output=%d signed=%d type=%lu fmt=%lu usage_getter=%#lx atomic_getter=%d atomic_declared=%d size=%lux%lux%lu\n",
        buffer,output,sign,(unsigned long)image.textureType,
        (unsigned long)image.pixelFormat,(unsigned long)image.usage,!!(image.usage&MTLTextureUsageShaderAtomic),tex_atomic_usage(image),
        (unsigned long)image.width,(unsigned long)image.height,(unsigned long)image.depth);
}
static void read_image(id<MTLTexture> image,uint32_t *words) {
    // Independent Metal copy after production fence: no ReadTexels or guest layout decoder.
    if(image.textureType==MTLTextureTypeTextureBuffer) {
        REQUIRE(image.buffer && image.buffer.contents);
        memcpy(words,(uint8_t *)image.buffer.contents+image.bufferOffset,64*4); return;
    }
    NSUInteger row=256,img=row*image.height;
    id<MTLBuffer> destination=[g_dev newBufferWithLength:img*image.depth options:MTLResourceStorageModeShared]; REQUIRE(destination);
    memset(destination.contents,0xa5,destination.length);
    id<MTLCommandQueue> queue=[g_dev newCommandQueue]; REQUIRE(queue);
    id<MTLCommandBuffer> cb=[queue commandBuffer]; REQUIRE(cb);
    id<MTLBlitCommandEncoder> blit=[cb blitCommandEncoder]; REQUIRE(blit);
    [blit copyFromTexture:image sourceSlice:0 sourceLevel:0 sourceOrigin:MTLOriginMake(0,0,0)
        sourceSize:MTLSizeMake(image.width,image.height,image.depth) toBuffer:destination destinationOffset:0
        destinationBytesPerRow:row destinationBytesPerImage:img];
    [blit endEncoding]; [cb commit]; [cb waitUntilCompleted]; REQUIRE(cb.status==MTLCommandBufferStatusCompleted);
    for(NSUInteger z=0;z<image.depth;z++) for(NSUInteger y=0;y<image.height;y++)
        memcpy(words+(z*image.height+y)*image.width,(uint8_t *)destination.contents+z*img+y*row,image.width*4);
}
static void run_case(int buffer,int sign,int native_buffer,int variant) {
    int alias=variant==1,upgrade=variant==2;
    NSString *label=alias?@"alias3d":buffer?(native_buffer?@"buffer30100":@"buffer"):sign?@"int3d":@"uint3d";
    NSString *observer=alias?@"uint-observe":buffer?@"buffer-observe":sign?@"int-observe":@"uint-observe";
    NvShader *s=shader(label),*o=shader(observer); prog_t p,q; program(&p,s); program(&q,o);
    uint8_t *memory=NULL; REQUIRE(!posix_memalign((void **)&memory,65536,1<<20)); memset(memory,0,1<<20);
    // Lifetime extends until process exit: production pools use no-copy MTLBuffers.
    pool_t *pool=calloc(1,sizeof *pool); REQUIRE(pool);
    *pool=(pool_t){.magic=MAGIC('P','O','O','L'),.flags=NVN_MEMORY_POOL_FLAGS_CPU_NO_ACCESS|NVN_MEMORY_POOL_FLAGS_GPU_CACHED,.mem=memory,.size=1<<20};
    nvn_be_pool_add(memory,1<<20);
    tex_t input,output; nvn_be_sub_begin();
    make_texture(&input,pool,0,buffer,0,alias?0:sign,upgrade);
    make_texture(&output,pool,65536,buffer,1,alias?0:sign,0);
    id<MTLTexture> before=tex_mtl(&input);
    if(upgrade) {
        CHECK(!(before.usage&MTLTextureUsageShaderWrite),"no-IMAGE before dispatch lacks ShaderWrite usage=%#lx",(unsigned long)before.usage);
        p_clear_tex clear={.tex=&input,.value_type=CLEAR_TEX_UINT,.r={0,0,0,4,4,4},.mask=15};
        clear.c.u[0]=0x12345678; clear_tex(&clear);
    }
    nvn_be_reg_tex(1,&input,NULL); nvn_be_reg_tex(2,&output,NULL);
    S.img[5][0]=1; S.img[5][1]=2; args_dirty_all();
    p_dispatch dp={.x=1,.y=1,.z=1}; S.cprog=&p; dispatch(&dp);
    // Same submission, no host wait; production dispatch ordering protects the observer.
    S.cprog=&q; args_dirty_all(); dispatch(&dp);
    uint64_t fence=nvn_be_sub_commit(); REQUIRE(nvn_be_wait(fence,10000000000ull)); REQUIRE(!mtl_last_commit_error());
    id<MTLTexture> after=tex_mtl(&input),out_image=tex_mtl(&output);
    // R32 整数可写缓冲贴图建时就带原子用途（nvn_mtl.m tex_mtl_ 缓冲贴图：没有压缩可丢；重建后不必再升级），三维的照旧只在真用原子时才加
    CHECK(tex_atomic_usage(after)==1,"%s input atomic_declared=%d usage_getter=%#lx",label.UTF8String,tex_atomic_usage(after),(unsigned long)after.usage);
    CHECK(tex_atomic_usage(out_image)==buffer,"%s ordinary output atomic_declared=%d (expected %d: buffer textures carry it from creation) usage_getter=%#lx",label.UTF8String,tex_atomic_usage(out_image),buffer,(unsigned long)out_image.usage);
    if(buffer) {
        CHECK(after.buffer==before.buffer && after.bufferOffset==before.bufferOffset,
            "%s upgrade preserves backing buffer and offset",label.UTF8String);
        CHECK((uint8_t *)after.buffer.contents+after.bufferOffset==input.mem,
            "%s buffer image still aliases actual guest pool",label.UTF8String);
    }
    if(alias) {
        id<MTLTexture> signed_view=(__bridge id<MTLTexture>)g_treg[1].im;
        CHECK((after.usage&MTLTextureUsagePixelFormatView) && signed_view.pixelFormat==MTLPixelFormatR32Sint && signed_view.parentTexture==after,
            "same-slot signed view keeps the unsigned base storage, PFV=%d",!!(after.usage&MTLTextureUsagePixelFormatView));
    }
    if(upgrade) {
        CHECK(after!=before && (after.usage&MTLTextureUsageShaderWrite),"no-IMAGE prescan replaced storage and added ShaderWrite old=%p new=%p usage=%#lx",(__bridge void *)before,(__bridge void *)after,(unsigned long)after.usage);
    }
    uint32_t a[64],b[64]; read_image(tex_mtl(&input),a); read_image(tex_mtl(&output),b);
    unsigned winners=0,permutation=0;
    for(unsigned i=0;i<8;i++) {
        int32_t initial=sign?-100-(int)i:100+(int)i, next=initial+20;
        CHECK(b[4*i]==(uint32_t)initial,"%s lane%u CAS success old got=%d want=%d",label.UTF8String,i,(int32_t)b[4*i],initial);
        CHECK(b[4*i+1]==(uint32_t)next,"%s lane%u CAS failed old got=%d want=%d",label.UTF8String,i,(int32_t)b[4*i+1],next);
        CHECK(b[4*i+2]==(uint32_t)next,"%s lane%u atomic->ordinary read got=%d want=%d",label.UTF8String,i,(int32_t)b[4*i+2],next);
        CHECK(b[32+i]==(uint32_t)next,"%s lane%u next-dispatch ordinary read got=%d want=%d",label.UTF8String,i,(int32_t)b[32+i],next);
        winners+=b[4*i+3]==0; if(b[48+i]<8) permutation|=1u<<b[48+i];
        printf("RAW %s lane%u winner_old=%u increment_old=%u\n",label.UTF8String,i,b[4*i+3],b[48+i]);
    }
    uint32_t winner=a[63]; CHECK(winner>=1 && winner<=8 && winners==1,"%s contention exactly one winner count=%u final=%u",label.UTF8String,winners,winner);
    CHECK(a[62]==8 && permutation==255,"%s CAS accumulation final=%u old-value permutation=%#x",label.UTF8String,a[62],permutation);
    for(unsigned i=0;i<64;i++) {
        unsigned lane=UINT_MAX;
        if(buffer) { if(i<8) lane=i; }
        else { unsigned x=i%4,y=(i/4)%4,z=i/16; if(x<2 && y<2 && z<2) lane=x+2*y+4*z; }
        uint32_t want=i==63?winner:i==62?8:lane!=UINT_MAX?(uint32_t)(sign?-80-(int)lane:120+(int)lane):upgrade?0x12345678:0;
        CHECK(a[i]==want,"%s xyz isolation cell%u got=%d want=%d",label.UTF8String,i,(int32_t)a[i],(int32_t)want);
    }
    for(unsigned i=0;i<64;i++) if(!((i<40)||(i>=48&&i<56)))
        CHECK(b[i]==0,"%s output guard%u got=%u want=0",label.UTF8String,i,b[i]);
    // The creation declaration, not a getter that can omit ShaderAtomic, must
    // keep the next real dispatch from replacing the very same input again.
    uint64_t upgrades_before=g_pfv_upgrades;
    nvn_be_sub_begin(); S.cprog=&p; args_dirty_all(); dispatch(&dp);
    S.cprog=&q; args_dirty_all(); dispatch(&dp);
    fence=nvn_be_sub_commit(); REQUIRE(nvn_be_wait(fence,10000000000ull)); REQUIRE(!mtl_last_commit_error());
    id<MTLTexture> second=tex_mtl(&input);
    CHECK(g_pfv_upgrades==upgrades_before && second==after,
        "%s second dispatch keeps input storage and upgrades=%llu->%llu, atomic_declared=%d usage_getter=%#lx",label.UTF8String,
        (unsigned long long)upgrades_before,(unsigned long long)g_pfv_upgrades,tex_atomic_usage(second),(unsigned long)second.usage);
    read_image(tex_mtl(&output),b);
    for(unsigned i=0;i<8;i++) {
        int32_t initial=sign?-100-(int)i:100+(int)i;
        CHECK(b[4*i]==(uint32_t)initial && b[4*i+1]==(uint32_t)(initial+20) && b[32+i]==(uint32_t)(initial+20),
            "%s second dispatch lane%u CAS success/failure and ordinary observer",label.UTF8String,i);
    }
    if(buffer) {
        // 缓冲贴图被重建（序号淘汰 / 对象收尾后按描述再解析）：11-26 Mac 霍格沃茨之遗 ser 5947（R32Uint 245760 元素，原生 texture_buffer 原子）每次重建都
        //   「升级成可写 + 原子」一次、300 秒 61 次（D-67FG / D-XJNP 一局 3–5 万次）。期望（不跑被测实现）：重建的贴图建时就带够用途，派发不再升级
        serial_del(input.serial); mtl_vc_drop(input.serial); uint64_t u0=g_pfv_upgrades;
        id<MTLTexture> rebuilt=tex_mtl(&input); REQUIRE(rebuilt);
        nvn_be_sub_begin(); S.cprog=&p; args_dirty_all(); dispatch(&dp); S.cprog=&q; args_dirty_all(); dispatch(&dp);
        fence=nvn_be_sub_commit(); REQUIRE(nvn_be_wait(fence,10000000000ull)); REQUIRE(!mtl_last_commit_error());
        CHECK(rebuilt!=second && g_pfv_upgrades==u0 && tex_mtl(&input)==rebuilt,
            "%s rebuilt buffer texture (serial dropped): upgrades expected %llu->%llu, actual ->%llu; storage kept=%d",label.UTF8String,
            (unsigned long long)u0,(unsigned long long)u0,(unsigned long long)g_pfv_upgrades,tex_mtl(&input)==rebuilt);
        read_image(tex_mtl(&output),b);
        for(unsigned i=0;i<8;i++) {
            int32_t initial=sign?-100-(int)i:100+(int)i;
            CHECK(b[4*i]==(uint32_t)initial && b[4*i+1]==(uint32_t)(initial+20) && b[32+i]==(uint32_t)(initial+20),
                "%s rebuilt dispatch lane%u CAS success/failure and ordinary observer",label.UTF8String,i);
        }
    }
}
static void unbound_buffer(int sign) {
    NSString *label=sign?@"unbound-int-buffer":@"unbound-uint-buffer";
    NvShader *s=shader(label); prog_t p; program(&p,s);
    uint8_t *memory=NULL; REQUIRE(!posix_memalign((void **)&memory,65536,1<<20)); memset(memory,0,1<<20);
    pool_t *pool=calloc(1,sizeof *pool); REQUIRE(pool);
    *pool=(pool_t){.magic=MAGIC('P','O','O','L'),.flags=NVN_MEMORY_POOL_FLAGS_CPU_NO_ACCESS|NVN_MEMORY_POOL_FLAGS_GPU_CACHED,.mem=memory,.size=1<<20};
    nvn_be_pool_add(memory,1<<20); tex_t output; nvn_be_sub_begin(); make_texture(&output,pool,0,1,1,0,0);
    nvn_be_reg_tex(2,&output,NULL); S.img[5][0]=0; S.img[5][1]=2; args_dirty_all(); S.cprog=&p;
    p_dispatch dp={.x=1,.y=1,.z=1}; dispatch(&dp);
    uint64_t fence=nvn_be_sub_commit(); REQUIRE(nvn_be_wait(fence,10000000000ull)); REQUIRE(!mtl_last_commit_error());
    uint32_t got[64]; read_image(tex_mtl(&output),got);
    for(unsigned i=0;i<64;i++) CHECK(got[i]==0,"%s null input result/guard%u got=%u want=0",label.UTF8String,i,got[i]);
    id<MTLTexture> sink=dummy_img(MTLTextureTypeTextureBuffer,sign?NVN_DPF_SINT:NVN_DPF_UINT,1);
    CHECK(sink.textureType==MTLTextureTypeTextureBuffer && sink.pixelFormat==(sign?MTLPixelFormatR32Sint:MTLPixelFormatR32Uint) && tex_atomic_usage(sink),
        "%s dummy has buffer type/R32 class, atomic_declared=%d usage_getter=%#lx",label.UTF8String,tex_atomic_usage(sink),(unsigned long)sink.usage);
    id<MTLTexture> out_image=tex_mtl(&output);
    CHECK(tex_atomic_usage(out_image)==1,"%s R32 buffer output carries atomic usage from creation, atomic_declared=%d usage_getter=%#lx",label.UTF8String,tex_atomic_usage(out_image),(unsigned long)out_image.usage);
}

// 过期字节只按真写记（审计 #743 P1-1 ②，nvn_mtl.m gpw_mark）：CPU_NO_ACCESS 池存储整块填 0x11223344，输入是 IMAGE 旗标的 4×4×4 R32UI。
// 只跑 observer（输入 readonly，反射 rw = 0）：之后同一存储另建 RGBA8 3D 贴图（新 Metal 贴图、取初始内容）读回 64 个字全是图案；
// 跑 uint3d（输入 coherent，有 imageStore 与原子写）：同样另建，64 个字全是 0（被 GPU 写过的字节不当初始内容）。期望按图案手写
static void stale_case(void) {
    NvShader *w=shader(@"uint3d"),*o=shader(@"uint-observe"); prog_t p,q; program(&p,w); program(&q,o);
    uint8_t *memory=NULL; REQUIRE(!posix_memalign((void **)&memory,65536,1<<20));
    for(size_t i=0;i<(1u<<20)/4;i++) ((uint32_t *)memory)[i]=0x11223344u;
    pool_t *pool=calloc(1,sizeof *pool); REQUIRE(pool);
    *pool=(pool_t){.magic=MAGIC('P','O','O','L'),.flags=NVN_MEMORY_POOL_FLAGS_CPU_NO_ACCESS|NVN_MEMORY_POOL_FLAGS_GPU_CACHED,.mem=memory,.size=1<<20};
    nvn_be_pool_add(memory,1<<20);
    for(int writer=0;writer<2;writer++) {
        size_t in_off=writer?262144:0, out_off=in_off+65536;
        tex_t input,output,probe; nvn_be_sub_begin();
        make_texture(&input,pool,in_off,0,0,0,0); make_texture(&output,pool,out_off,0,1,0,0);
        nvn_be_reg_tex(1,&input,NULL); nvn_be_reg_tex(2,&output,NULL); S.img[5][0]=1; S.img[5][1]=2; args_dirty_all();
        p_dispatch dp={.x=1,.y=1,.z=1}; S.cprog=writer?&p:&q; dispatch(&dp);
        uint64_t fence=nvn_be_sub_commit(); REQUIRE(nvn_be_wait(fence,10000000000ull)); REQUIRE(!mtl_last_commit_error());
        nvn_be_sub_begin(); make_texture(&probe,pool,in_off,0,0,0,2);
        fence=nvn_be_sub_commit(); REQUIRE(nvn_be_wait(fence,10000000000ull)); REQUIRE(!mtl_last_commit_error());
        uint32_t got[64]; read_image(tex_mtl(&probe),got); unsigned zero=0,pattern=0;
        for(unsigned i=0;i<64;i++) { zero+=got[i]==0; pattern+=got[i]==0x11223344u; }
        if(writer) CHECK(zero==64,"stale: image-stored input's bytes not taken as a new texture's initial content: zero words %u of 64 (pattern %u)",zero,pattern);
        else CHECK(pattern==64,"stale: input only read by a readonly image is not marked: pattern words %u of 64 (zero %u)",pattern,zero);
    }
}
static int unsupported(void) {
    NvShader *s=shader(@"uint3d"); prog_t p; program(&p,s);
    uint8_t *memory=NULL; REQUIRE(!posix_memalign((void **)&memory,65536,1<<20)); memset(memory,0,1<<20);
    pool_t *pool=calloc(1,sizeof *pool); REQUIRE(pool);
    *pool=(pool_t){.magic=MAGIC('P','O','O','L'),.flags=NVN_MEMORY_POOL_FLAGS_CPU_NO_ACCESS|NVN_MEMORY_POOL_FLAGS_GPU_CACHED,.mem=memory,.size=1<<20};
    nvn_be_pool_add(memory,1<<20); tex_t input,output; nvn_be_sub_begin();
    make_texture(&input,pool,0,0,0,0,2); make_texture(&output,pool,65536,0,1,0,0);
    nvn_be_reg_tex(1,&input,NULL); nvn_be_reg_tex(2,&output,NULL); S.img[5][0]=1; S.img[5][1]=2; args_dirty_all();
    uint32_t previous=g_gp_disp; S.cprog=&p; p_dispatch dp={.x=1,.y=1,.z=1}; dispatch(&dp);
    REQUIRE(g_gp_disp==previous); const void *key=(__bridge const void *)s;
    id pipeline=hm_get_id(&g_cps,&key); REQUIRE(pipeline && pipeline!=NSNull.null);
    uint64_t fence=nvn_be_sub_commit(); REQUIRE(nvn_be_wait(fence,10000000000ull)); REQUIRE(!mtl_last_commit_error());
    uint32_t got[64]; read_image(tex_mtl(&output),got);
    for(unsigned i=0;i<64;i++) REQUIRE(got[i]==0);
    puts("EXPECTED_UNSUPPORTED: command rejected, output untouched; excluded from atomic GPU correctness acceptance");
    return 3;
}
int main(int argc,char **argv) {
    @autoreleasepool {
        setvbuf(stdout,NULL,_IOLBF,0);
        REQUIRE(argc==3);
        alarm(60); directory=[NSString stringWithUTF8String:argv[1]];
        mtl_init(); printf("DEVICE %s backend=Metal%d\n",g_dev.name.UTF8String,g_m3?3:4);
        if(!strcmp(argv[2],"--unsupported-only")) return unsupported();
        int native_buffer=!strcmp(argv[2],"--native-buffer-only");
        if(!strcmp(argv[2],"--stale-only")) stale_case();
        else if(!strcmp(argv[2],"--alias-view-only")) run_case(0,1,0,1);
        else if(!strcmp(argv[2],"--upgrade-only")) run_case(0,0,0,2);
        else if(!strcmp(argv[2],"--unbound-only")) { unbound_buffer(0); unbound_buffer(1); }
        else {
            REQUIRE(!strcmp(argv[2],"--production")||!strcmp(argv[2],"--buffer-only")||native_buffer);
            if(!strcmp(argv[2],"--production")) { run_case(0,0,0,0); run_case(0,1,0,0); }
            run_case(1,0,native_buffer,0);
        }
        nvn_be_drain();
        printf("%s t_nvn_image_atomic: %u checks %u failures; %s, no gameplay proof\n",failures?"✗":"✓",checks,failures,argv[2]);
        return failures!=0;
    }
}
