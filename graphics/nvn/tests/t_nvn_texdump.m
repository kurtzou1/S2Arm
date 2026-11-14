// Production render-pass/clear, TEXDUMP and TEXSNAP paths with real Metal GPU work.
// Independently chosen colors distinguish adjacent frames, a gap, and both passes.
#ifndef NVN_TEXDUMP_SOURCE
#define NVN_TEXDUMP_SOURCE "../gfx/nvn/nvn_mtl.m"
#endif
#include NVN_TEXDUMP_SOURCE

static unsigned checks, failures;
#define REQUIRE(c) do { if (!(c)) { fprintf(stderr,"SETUP FAIL %s:%d %s\n",__FILE__,__LINE__,#c); exit(2); } } while (0)
#define CHECK(c, ...) do { checks++; int ok=!!(c); failures+=!ok; printf("%s ",ok?"PASS":"FAIL"); printf(__VA_ARGS__); putchar('\n'); } while (0)
static const uint8_t colors[6][2][4] = {
    {{255,255,255,255},{0,0,0,255}},   // frame 6: 16x16, not the size trigger
    {{255,0,0,255},{0,255,0,255}},     // frame 7
    {{0,0,255,255},{255,255,0,255}},   // frame 8, adjacent
    {{255,255,255,255},{0,0,0,255}},   // frame 9, not selected
    {{255,0,255,255},{0,255,255,255}}, // frame 10, after a gap
    {{255,255,255,255},{0,0,0,255}},   // frame 11 flushes frame 10
};
static char directory[1024];
static tex_t small, large;
static NSMutableArray *copies;
static int replacing, classes;
static id<MTLTexture> int_u, int_s, vol;   // classes mode: integer targets and a 3D texture, filled by the CPU with values chosen here
static void fill_classes(void) {
    MTLTextureDescriptor *d = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA8Uint width:8 height:8 mipmapped:NO];
    int_u = [g_dev newTextureWithDescriptor:d]; d.pixelFormat = MTLPixelFormatRGBA8Sint; int_s = [g_dev newTextureWithDescriptor:d]; REQUIRE(int_u && int_s);
    uint8_t u[64*4], sv[64*4]; for (int i = 0; i < 64; i++) { u[4*i]=7; u[4*i+1]=200; u[4*i+2]=255; u[4*i+3]=9; sv[4*i]=(uint8_t)-128; sv[4*i+1]=0; sv[4*i+2]=127; sv[4*i+3]=1; }
    [int_u replaceRegion:MTLRegionMake2D(0,0,8,8) mipmapLevel:0 withBytes:u bytesPerRow:32];
    [int_s replaceRegion:MTLRegionMake2D(0,0,8,8) mipmapLevel:0 withBytes:sv bytesPerRow:32];
    MTLTextureDescriptor *v = [MTLTextureDescriptor new]; v.textureType = MTLTextureType3D; v.pixelFormat = MTLPixelFormatRGBA8Unorm; v.width = 1; v.height = 1; v.depth = 17;
    vol = [g_dev newTextureWithDescriptor:v]; REQUIRE(vol);
    for (unsigned z = 0; z < 17; z++) { uint8_t c[4] = {(uint8_t)(z*10), (uint8_t)(255-z*10), (uint8_t)z, (uint8_t)(z*5)};
        [vol replaceRegion:MTLRegionMake3D(0,0,z,1,1,1) mipmapLevel:0 slice:0 withBytes:c bytesPerRow:4 bytesPerImage:4]; }
}

static void texture(tex_t *t, unsigned side) {
    memset(t,0,sizeof *t); t->magic=MAGIC('T','E','X',0); t->serial=nvn_new_serial();
    t->d=(nvn_texdesc){.target=NVN_TEXTURE_TARGET_2D,.format=NVN_FORMAT_RGBA8,.width=side,.height=side,.depth=1,.levels=1};
    nvn_tex_layout(&t->d,&t->L); nvn_be_tex_init(t); REQUIRE(tex_mtl(t));
}
static void frame(unsigned f) {
    nvn_be_set_frame(f); nvn_be_sub_begin(); state_reset();
    tex_t *t=f==6?&large:&small;
    for (unsigned pass=0;pass<2;pass++) {
        const uint8_t *c=colors[f-6][pass];
        const struct { op_hdr set; p_set_rt_c rt; const tex_t *color0; uint8_t snap[sizeof(tex_t)]; op_hdr clear; p_clear_color color; op_hdr end; } commands={   // 紧凑 SET_RT（nvn_obj.h p_set_rt_c）
            .set={OP_SET_RT,sizeof(op_hdr)+sizeof(p_set_rt_c)+8+sizeof(tex_t)}, .rt={.n=1,.cmask=1}, .color0=t,
            .clear={OP_CLEAR_COLOR,sizeof(op_hdr)+sizeof(p_clear_color)},
            .color={.index=0,.mask=15,.rgba={c[0]/255.0f,c[1]/255.0f,c[2]/255.0f,1}}, .end={OP_END,sizeof(op_hdr)},
        };
        nvn_be_exec((const uint8_t *)&commands); rp_flush();
    }
    if (replacing && f==7) {
        for (NSArray *e in g_td_list) if (e.count>4) [copies addObject:e[0]];
        REQUIRE(rp_begin_ex(0));   // a real load/store pass remains open when the request is replaced
        CHECK(copies.count==2 && g_cb && g_enc,"override starts with two real snapshots and an open unsubmitted render encoder");
        char path[1200]; snprintf(path,sizeof path,"%s/capture-%%d.png",directory); dm_gfx_texdump_next(path);
        CHECK(!g_enc,"override finishes the old encoder before switching the collection");
        unsigned resident=0; for (id copy in copies) resident += [g_res_objects containsObject:copy];
        CHECK(resident==2,"overridden snapshots stay resident until their GPU submission completes");
        rp_flush();
    }
    if (classes && f==7) {   // as the bind site would note them during the selected frame
        [g_td_list addObject:@[int_u, @901, @0, @0]]; [g_td_list addObject:@[int_s, @902, @0, @0]];
        td_note_3d(vol, 903); td_note_3d(vol, 903);
        CHECK(g_td_3d.count==1,"a 3D texture sampled twice in the frame is noted once");
    }
    uint64_t fence=nvn_be_sub_commit(); REQUIRE(nvn_be_wait(fence,10000000000ull)); REQUIRE(!mtl_last_commit_error());
    defer_drain();
    // Keep references only to inspect the real residency ledger after the next frame dumps them.
    for (NSArray *e in g_td_list) if (e.count>4 && ![copies containsObject:e[0]]) [copies addObject:e[0]];
    id<MTLTexture> image=tex_mtl(t);
    id<MTLBuffer> read=[g_dev newBufferWithLength:image.width*image.height*4 options:MTLResourceStorageModeShared]; REQUIRE(read);
    id<MTLCommandBuffer> cb=q_cb(); id<MTLBlitCommandEncoder> b=[cb blitCommandEncoder];
    [b copyFromTexture:image sourceSlice:0 sourceLevel:0 sourceOrigin:MTLOriginMake(0,0,0) sourceSize:MTLSizeMake(image.width,image.height,1)
        toBuffer:read destinationOffset:0 destinationBytesPerRow:image.width*4 destinationBytesPerImage:image.width*image.height*4];
    [b endEncoding]; [cb commit]; [cb waitUntilCompleted]; REQUIRE(cb.status==MTLCommandBufferStatusCompleted);
    unsigned bad=0; for (unsigned i=0;i<image.width*image.height;i++) bad+=memcmp((uint8_t *)read.contents+4*i,colors[f-6][1],4)!=0;
    CHECK(!bad,"guest frame %u final GPU texture retains the second pass (%u wrong pixels)",f,bad);
}
static void png(const char *name, const uint8_t *want) {
    char path[1200]; snprintf(path,sizeof path,"%s/%s",directory,name);
    CFURLRef url=CFURLCreateFromFileSystemRepresentation(NULL,(const uint8_t *)path,strlen(path),false);
    CGImageSourceRef source=CGImageSourceCreateWithURL(url,NULL); CFRelease(url);
    CHECK(source!=NULL,"PNG exists: %s",name); if (!source) return;
    CGImageRef image=CGImageSourceCreateImageAtIndex(source,0,NULL); CFRelease(source); REQUIRE(image);
    CHECK(CGImageGetWidth(image)==8 && CGImageGetHeight(image)==8,"PNG dimensions: %s",name);
    uint8_t bytes[8*8*4]; CGColorSpaceRef cs=CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
    CGContextRef context=CGBitmapContextCreate(bytes,8,8,8,8*4,cs,(CGBitmapInfo)kCGImageAlphaNoneSkipLast); CGColorSpaceRelease(cs); REQUIRE(context);
    CGContextDrawImage(context,CGRectMake(0,0,8,8),image); CGContextRelease(context); CGImageRelease(image);
    unsigned bad=0; for (unsigned i=0;i<64;i++) bad+=memcmp(bytes+4*i,want,3)!=0;
    CHECK(!bad,"PNG exact RGB: %s (%u wrong pixels)",name,bad);
}
// any size: returns RGB at (x, y), or -1 when missing
static int pixels(const char *name, unsigned *w, unsigned *h, uint8_t *out, size_t cap) {
    char path[1200]; snprintf(path,sizeof path,"%s/%s",directory,name);
    CFURLRef url=CFURLCreateFromFileSystemRepresentation(NULL,(const uint8_t *)path,strlen(path),false);
    CGImageSourceRef source=CGImageSourceCreateWithURL(url,NULL); CFRelease(url); if (!source) return -1;
    CGImageRef image=CGImageSourceCreateImageAtIndex(source,0,NULL); CFRelease(source); REQUIRE(image);
    *w=(unsigned)CGImageGetWidth(image); *h=(unsigned)CGImageGetHeight(image); REQUIRE((size_t)*w**h*4<=cap);
    CGColorSpaceRef cs=CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
    CGContextRef context=CGBitmapContextCreate(out,*w,*h,8,*w*4,cs,(CGBitmapInfo)kCGImageAlphaNoneSkipLast); CGColorSpaceRelease(cs); REQUIRE(context);
    CGContextDrawImage(context,CGRectMake(0,0,*w,*h),image); CGContextRelease(context); CGImageRelease(image); return 0;
}
static void classes_saved(void) {
    uint8_t px[64*64*4]; unsigned w=0,h=0; char name[256];
    static const uint8_t want_u[3]={7,200,255}, want_s[3]={0,128,255};   // uint: the value itself; sint: value + 128
    const struct { unsigned ser; const uint8_t *want; } flat[2]={{901,want_u},{902,want_s}};
    for (int k=0;k<2;k++) { snprintf(name,sizeof name,"capture-%u.png",flat[k].ser*100);
        int got=!pixels(name,&w,&h,px,sizeof px); unsigned bad=0; if (got) for (unsigned i=0;i<w*h;i++) bad+=memcmp(px+4*i,flat[k].want,3)!=0;
        CHECK(got && w==8 && h==8 && !bad,"integer target %s shows its values, not black (%u wrong pixels)",name,bad); }
    // 1x1x17: 16 slices per row, 2 rows; slice z at (z %% 16, z / 16); the 15 cells after slice 16 are the filler (64, 0, 64)
    for (int a=0;a<2;a++) { snprintf(name,sizeof name,"capture-0_v3d_903_%s.png",a?"a":"rgb");
        int got=!pixels(name,&w,&h,px,sizeof px); unsigned bad=0;
        if (got && w==16 && h==2) for (unsigned y=0;y<2;y++) for (unsigned x=0;x<16;x++) { unsigned z=y*16+x; uint8_t e[3];
            if (z>=17) { e[0]=64; e[1]=0; e[2]=64; } else if (a) e[0]=e[1]=e[2]=(uint8_t)(z*5); else { e[0]=(uint8_t)(z*10); e[1]=(uint8_t)(255-z*10); e[2]=(uint8_t)z; }
            const uint8_t *p=px+4*(y*16+x); bad+=abs(p[0]-e[0])>1 || abs(p[1]-e[1])>1 || abs(p[2]-e[2])>1; }
        CHECK(got && w==16 && h==2 && !bad,"3D atlas %s: 16x2, every slice in its cell (%u wrong cells)",name,bad); }
}
static void raw(const char *name, const uint8_t *want, int texture_raw) {
    char path[1200], header[128]; snprintf(path,sizeof path,"%s/%s",directory,name);
    FILE *file=fopen(path,"rb"); CHECK(file!=NULL,"RAW exists: %s",name); if (!file) return;
    REQUIRE(fgets(header,sizeof header,file)); unsigned long w=0,h=0,d=0,fmt=0,row=0;
    int fields=texture_raw?sscanf(header,"%lu %lu %lu %lu %lu",&w,&h,&d,&fmt,&row):sscanf(header,"%lu %lu %lu %lu",&w,&h,&fmt,&row);
    CHECK(fields==(texture_raw?5:4) && w==8 && h==8 && (!texture_raw || d==1) && fmt==70 && row==32,"RAW frame/serial layout: %s",name);
    uint8_t bytes[8*8*4]; size_t n=fread(bytes,1,sizeof bytes,file); int end=fgetc(file); fclose(file);
    unsigned bad=0; for (unsigned i=0;i<n/4;i++) bad+=memcmp(bytes+4*i,want,4)!=0;
    CHECK(n==sizeof bytes && end==EOF && !bad,"RAW exact RGBA: %s (%u wrong pixels)",name,bad);
}
static void saved(unsigned f, int multi) {
    char suffix[48]="", name[256]; if (multi) snprintf(suffix,sizeof suffix,"_f%u",f);
    snprintf(name,sizeof name,"capture-%llu%s.png",(unsigned long long)small.serial*100,suffix); png(name,colors[f-6][1]);
    snprintf(name,sizeof name,"capture-%llu%s.png.raw",(unsigned long long)small.serial*100,suffix); raw(name,colors[f-6][1],0);
    snprintf(name,sizeof name,"capture-%llu%s.png.raw",(unsigned long long)small.serial,suffix); raw(name,colors[f-6][1],1);
    for (unsigned pass=0;pass<2;pass++) {
        snprintf(name,sizeof name,"capture-0%s_s%03u_%llu_0.png",suffix,pass,(unsigned long long)small.serial); png(name,colors[f-6][pass]);
        snprintf(name,sizeof name,"capture-%llu%s.png_s%03u.raw",(unsigned long long)small.serial*100,suffix,pass); raw(name,colors[f-6][pass],0);
    }
}
int main(int argc, char **argv) { @autoreleasepool {
    if (argc!=3) { fprintf(stderr,"usage: %s off|single|size|multi|replace|classes <existing output parent>\n",argv[0]); return 2; }
    int multi=!strcmp(argv[1],"multi"), off=!strcmp(argv[1],"off"), size=!strcmp(argv[1],"size");
    replacing=!strcmp(argv[1],"replace"); classes=!strcmp(argv[1],"classes"); REQUIRE(multi || off || size || replacing || classes || !strcmp(argv[1],"single"));
    snprintf(directory,sizeof directory,"%s/texdump_%s_XXXXXX",argv[2],argv[1]); REQUIRE(mkdtemp(directory));
    char config[1200]; snprintf(config,sizeof config,"%s:%s/capture-%%d.png",multi || replacing?"10,7,8,8":size?"size=8x8":"7",directory);
    if (off) unsetenv("DM_NVN_TEXDUMP"); else setenv("DM_NVN_TEXDUMP",config,1);
    setenv("DM_NVN_TEXSNAP","0,1",1); setenv("DM_NVN_SNAPRAW","1",1);
    nvn_be_sub_begin(); texture(&small,8); texture(&large,16); if (classes) fill_classes();
    uint64_t initial=nvn_be_sub_commit(); REQUIRE(nvn_be_wait(initial,10000000000ull)); REQUIRE(!mtl_last_commit_error());
    copies=[NSMutableArray array];
    char serial[48]; snprintf(serial,sizeof serial,"%llu",(unsigned long long)small.serial); setenv("DM_NVN_TEXRAW",serial,1);
    for (unsigned f=6;f<=11;f++) frame(f);
    if (!off) { saved(replacing?8:7,multi); if (multi) { saved(8,1); saved(10,1); } }
    if (classes) classes_saved();
    NSArray *files=[[NSFileManager defaultManager] contentsOfDirectoryAtPath:@(directory) error:nil]; REQUIRE(files);
    unsigned want_files=off?0:multi?21:classes?13:7;   // classes: + 2 integer targets (PNG + SNAPRAW bytes) + 3D rgb / alpha
    CHECK(files.count==want_files,"%s: exactly %u files, no unselected-frame output or overwrites (got %lu)",argv[1],want_files,(unsigned long)files.count);
    CHECK(!g_td_3d.count,"no 3D texture retained after the dump");
    CHECK(copies.count==(off?0:multi?6:replacing?4:2),"%s: independent snapshots for each selected frame/pass (%lu)",argv[1],(unsigned long)copies.count);
    for (id copy in copies) CHECK(![g_res_objects containsObject:copy],"diagnostic copy leaves residency after GPU completion and export");
    CHECK(!g_td_list.count,"no completed frame retained in the dump list");
    for (unsigned i=0;i<8;i++) CHECK(g_ts_att[i]==nil,"snapshot source slot %u released",i);
    CHECK([g_res_objects containsObject:tex_mtl(&small)] && [g_res_objects containsObject:tex_mtl(&large)],"both game textures remain resident");
    if (!getenv("NVN_TEXDUMP_KEEP")) REQUIRE([[NSFileManager defaultManager] removeItemAtPath:@(directory) error:nil]);
    else printf("ARTIFACTS %s\n",directory);
    printf("%s t_nvn_texdump %s: %u checks, %u failures\n",failures?"✗":"✓",argv[1],checks,failures);
    return failures?1:0;
} }
