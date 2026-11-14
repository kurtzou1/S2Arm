// Host test: production Android mapper + shared loader/relocations + real Apple TSD.
// Authored module bytes contain no executable guest; this is not Bionic execution.
#include "native.h"
#include "loader.h"
#include "s2a_gfx_mode.h"
#include "patch.h"
#include <errno.h>
#include "platform/plat.h"
#include <assert.h>
#include <sys/stat.h>
// Real widen.c is linked; only unrelated patch/screen dependencies are controlled.
int s2a_android_screen_metrics(int *w,int *h) { *w=1920;*h=1080;return 1; }
int s2a_patch_widen_rows(const char *m,int d,const s2a_patch_wrow_t **r) { (void)m;(void)d;(void)r;return -1; }
int s2a_patch_widen_full(int d) { (void)d;return -1; }
const char *s2a_patch_build(void) { return ""; }
int s2a_patch_data_overlap(const char *m,uint64_t o,uint64_t n) { (void)m;(void)o;(void)n;return 0; }
void s2a_patch_count(int k) { (void)k; }
void s2a_patch_note(const char *f,...) { (void)f; }
void s2a_host_write_hook(uint64_t a,uint64_t n) { (void)a;(void)n; }
// 夹具没有直连图形层动态库；APK 内存装载路径按通用模式跑（gpu_drivers.tsv 也不存在）。
int s2a_gfx_mode(void) { return S2A_GFX_GENERIC; }
// Generic Android mode has no direct API interception (plat_android.c).
uint64_t s2a_direct_lookup(const char *name) { (void)name; return 0; }
void *s2a_libc_lookup(const char *name) { (void)name; return NULL; }
void *sw_xstack_wrap(const char *name,void *fn) { (void)name;(void)fn; assert(0); return NULL; }
unsigned s2a_unresolved_count(void);
const char *s2a_main_build_id(void);
struct asset { char filename[64]; unsigned char *bytes; size_t size; int reads, releases; };
static struct asset assets[12]; static int asset_count;
static const char *test_mode;
static void save(const char *dir,const char *name,const char *ext,const void *p,size_t n) {
    (void)dir;
    struct asset *a=&assets[asset_count++];
    assert(asset_count<=12);
    assert(snprintf(a->filename,sizeof a->filename,"%s.%s",name,ext)<(int)sizeof a->filename);
    a->bytes=malloc(n?n:1); assert(a->bytes); memcpy(a->bytes,p,n); a->size=n;
}
static int read_asset(void *context,const char *filename,struct s2a_loader_blob *out) {
    assert(context==assets);
    if (!strcmp(test_mode,"missing-sidecar") && !strcmp(filename,"main.gates.tsv")) return ENOENT;
    if (!strcmp(test_mode,"hash-rejected")) return EBADMSG;
    if (!strcmp(test_mode,"widen-rejected") && !strcmp(filename,"main.widen.tsv")) return EIO;
    if (!strcmp(test_mode,"cpatch-rejected") && !strcmp(filename,"cpatch.tsv")) return EIO;
    for(int i=0;i<asset_count;i++) if(!strcmp(assets[i].filename,filename)) {
        struct asset *a=&assets[i]; assert(a->reads++==0 && a->releases==0);
        *out=(struct s2a_loader_blob){.bytes=a->bytes,.length=a->size,.lease=a};return 0;
    }
    return ENOENT;
}
static void release_asset(void *context,struct s2a_loader_blob *blob) {
    assert(context==assets);
    struct asset *a=blob->lease;
    assert(a>=assets && a<assets+12 && a->reads==1 && a->releases++==0);
    // 立即毒化和释放：后续符号 / 重定位必须只读映射副本。
    memset(a->bytes,0xa5,a->size);free(a->bytes);a->bytes=NULL;*blob=(struct s2a_loader_blob){0};
}
static void module(const char *dir,const char *name,int provider,const char *mode) {
    static unsigned char b[0x14000]; memset(b,0,sizeof b);
    *(uint32_t *)(b+4)=0x100; memcpy(b+0x100,"MOD0",4); *(int32_t *)(b+0x104)=0x8200-0x100;
    Elf64_Sym *syms=(void *)(b+0x8000);
    syms[1]=(Elf64_Sym){.st_name=1,.st_info=0x10,.st_shndx=provider?1:0,.st_value=provider?0x8500:0};
    syms[2]=(Elf64_Sym){.st_name=8,.st_info=0x10,.st_shndx=1,.st_value=0x8600};
    if (!provider && !strcmp(mode,"weak")) syms[1].st_info=0x20;
    memcpy(b+0x8048,provider&&(!strcmp(mode,"missing") || !strcmp(mode,"weak"))?"\0absent\0anchor\0":"\0needed\0anchor\0",15);
    Elf64_Dyn *d=(void *)(b+0x8200);
    d[0]=(Elf64_Dyn){.d_tag=6,.d_un.d_ptr=0x8000}; d[1]=(Elf64_Dyn){.d_tag=5,.d_un.d_ptr=0x8048};
    d[2]=(Elf64_Dyn){.d_tag=7,.d_un.d_ptr=0x8300};d[3]=(Elf64_Dyn){.d_tag=8,.d_un.d_val=24};
    d[4]=(Elf64_Dyn){.d_tag=36,.d_un.d_ptr=0x8380};d[5]=(Elf64_Dyn){.d_tag=35,.d_un.d_val=8};
    Elf64_Rela *r=(void *)(b+0x8300); *r=(Elf64_Rela){.r_offset=0x8400,.r_info=provider?1027:((1ull<<32)|1025),.r_addend=provider?0x8500:0};
    *(uint64_t *)(b+0x8380)=0x8410; *(uint64_t *)(b+0x8410)=0x20;
    save(dir,name,"patched.bin",b,sizeof b);
    char header[1024]; int n=snprintf(header,sizeof header,
        "%s%s# PATCH_OFF\t10000\n# KEY_PAGE_OFF\tc000\n# KEY_PAGE_SIZE\t4000\n# TEXT_END\t4000\n# RO_OFF\t4000\n# DATA_OFF\t8000\n# KEY_K18_IDX\t0\n# KEY_KTLS_IDX\t1\n# KEY_KTLR_IDX\t2\n# KEY_KGATE_IDX\t3\n",
        !strcmp(mode,"apple")?"":!strcmp(mode,"wrong")?"# TARGET\tohos\n":"# TARGET\tandroid\n",
        !strcmp(mode,"missing-abi")?"":!strcmp(mode,"bad-abi")?"# REWRITE_ABI\tandroid-below-sp-v1\n":!strcmp(mode,"duplicate-abi")?"# REWRITE_ABI\tandroid-sp-safe-v1\n# REWRITE_ABI\tandroid-sp-safe-v1\n":"# REWRITE_ABI\tandroid-sp-safe-v1\n");
    if (!strcmp(mode,"widen-overlap")) {
        char *key = strstr(header, "# KEY_K18_IDX\t0\n"); assert(key);
        size_t off = (size_t)(key - header); memmove(header + off + 1, header + off, (size_t)n - off + 1); n++;
        memcpy(header + off, "# KEY_K18_IDX\t16\n", strlen("# KEY_K18_IDX\t16\n"));
    }
    if (!strcmp(mode,"zero-bias") || !strcmp(mode,"nonzero-bias"))
        n += snprintf(header+n,sizeof header-(size_t)n,"# LOAD_BIAS\t%s\n",!strcmp(mode,"zero-bias")?"0":"1000");
    save(dir,name,"fixups.tsv",header,(size_t)n);
    const char *row=!strcmp(mode,"bad-gates")?"garbage\n":!strcmp(mode,"outside-gate")?"20010 svc 30 120\n":!strcmp(mode,"trailing-gate")?"10010 svc 30 120 junk\n":!strcmp(mode,"empty-gates")?"":"10010 svc 30 120\n";
    save(dir,name,"gates.tsv",row,strlen(row));
}
int main(int argc,char **argv) {
    assert(argc==2);const char *mode=argv[1],*dir="not-a-real-directory";test_mode=mode;
    module(dir,"main",0,mode);module(dir,"sdk",1,mode);
    if (!strncmp(mode,"widen",5)) {
        const char *rows = !strcmp(mode,"widen-malformed") ? "1\t0x10\tmovz\t5280a000\n" : "0\t0x10\tmovz\t5280a000\n";
        save(dir,"main","widen.tsv",rows,strlen(rows));
        if (!strcmp(mode,"widen-policy")) {
            const char *enable = "main\t0x10\tmovz\t1\n";
            save(dir,"widen_enable","handheld.tsv",enable,strlen(enable));
            const char *full = "0\n";
            save(dir,"widen_full","handheld.tsv",full,strlen(full));
            setenv("S2A_WIDEN_CAPS","1",1); setenv("S2A_SCREEN_W","2560",1);
            int s2a_widen_full(void); assert(s2a_widen_full() == 1); // pre-admission default must not mask the authenticated table

        }
    }
    if (!strncmp(mode,"cpatch",6)) {   // #48 D2：整包一张社区补丁表，两个模块各一行；main 的那份带数据写入 0x9000：00 → 7f
        const char *table="编号\t模块\t位\t类别\t段名\t许可\t来源\t数据写入\t缺省开\n"
            "gfx:A\tmain\t0\tother-gfx\tA\t\ta.pchtxt\t9000:00:7f\t0\ngfx:S\tsdk\t1\tother-gfx\tS\t\ts.pchtxt\t\t0\n";
        save(dir,"cpatch","tsv",table,strlen(table));
        if (!strcmp(mode,"cpatch-nul")) assets[asset_count-1].bytes[20]=0;
        setenv("S2A_CPATCH_ON","gfx:A,gfx:S",1);   // 两份表里都是缺省关，显式开
    }
    if (!strcmp(mode,"nul-fixups")) assets[1].bytes[3]=0;
    if (!strcmp(mode,"long-fixups")) {free(assets[1].bytes);assets[1].size=300;assets[1].bytes=malloc(300);memset(assets[1].bytes,'a',300);}
    const char *names[]={"main",!strcmp(mode,"duplicate-name")?"main":"sdk"};
    struct s2a_loader_source source={.context=assets,.read=read_asset,.release=release_asset};
    load_modules_from_source(&source,names,2);
    if (!strcmp(mode,"widen") || !strcmp(mode,"widen-policy")) {
        uint64_t *page = (uint64_t *)(g_mod[0].base + g_mod[0].key_page_off);
        assert(page[16] == (!strcmp(mode,"widen-policy") ? 1707u : 1280u));  // source sidecar restores MOVZ #1280 into value slot
        page[1024] = 1;            // rewritten guest hit counter must remain writable
        assert(page[1024] == 1);
        if (!strcmp(mode,"widen-policy")) { int s2a_widen_full(void); assert(s2a_widen_full() == 0); }
    }
    if (!strcmp(mode,"cpatch")) {   // 每个模块按同一张表各写自己的掩码槽 2046，数据写入在统一重定位前落到映射副本
        assert(((uint64_t *)(g_mod[0].base+g_mod[0].key_page_off))[2046]==1);
        assert(((uint64_t *)(g_mod[1].base+g_mod[1].key_page_off))[2046]==2);
        assert(g_mod[0].base[0x9000]==0x7f && g_mod[1].base[0x9000]==0);
    }
    for(int i=0;i<asset_count;i++) assert(assets[i].reads==1 && assets[i].releases==1 && !assets[i].bytes);
    assert(!strcmp(s2a_main_build_id(),""));
    assert(strcmp(mode,"apple") && strcmp(mode,"wrong"));
    assert(g_nmod==2);
    assert(g_mod[0].size==0x14000 && g_mod[0].patch_len==0x4000);
    assert(*(uint64_t *)(g_mod[0].base+0x8410)==(uint64_t)g_mod[0].base+0x20);
    assert(*(uint64_t *)(g_mod[1].base+0x8400)==(uint64_t)g_mod[1].base+0x8500);
    if (!strcmp(mode,"missing")) assert(s2a_unresolved_count()==1);
    else {assert(!s2a_unresolved_count());assert(*(uint64_t *)(g_mod[0].base+0x8400)==(!strcmp(mode,"weak")?0:(uint64_t)g_mod[1].base+0x8500));}
    uint64_t off;assert(!plat_tsd_offset((uint32_t)g_keytls,&off));assert(((uint64_t *)(g_mod[0].base+0xc000))[1]==off);
    if (!strcmp(mode,"duplicate-gate")) gate_register((uint64_t)g_mod[0].base + 0x10010, "svc", 30, (uint64_t)g_mod[0].base + 0x120);
    if (!strcmp(mode,"load-twice")) load_modules_from_source(&source,names,2);
    puts("PASS actual memory-only loader + Android mapper + cross-module RELA/RELR/gates");return 0;
}
