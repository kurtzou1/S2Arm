// SPDX-License-Identifier: Apache-2.0
// 游戏屏障对通道外的计算派发生效（#978）：真 rp_dispatch / rp_buf / Vulkan 后端，lavapipe + 同步校验。
// 后端传输往存储缓冲前 64 个字写 i*3（同 T2B / 池镜像同步走的后端传输：只在开头带屏障）→ 游戏屏障 → 派发 B 读它、
// 把 2 倍写到后 64 个字；读回期望 i*6。第二个参数 none：不发游戏屏障（检测器负控：同步校验必须报写后读冒险）。
// 生产者不用计算派发：容器里的校验层看不出计算着色器对存储缓冲的写（派发写 → 派发读、无屏障也报 0 条，坑记录有读数），测不出缺屏障。
// 游戏屏障的记账（rp_pass_barrier / rp_pass_take_barrier）在这里是同语义的替身：OP_BARRIER → rp_pass.c 的接线在宿主用例 t_dispatch_barrier 里测。
#include "rp_exec.h"
#include "rp_state.h"
#include "rp_res.h"
#include "rp_shader.h"
#include "nvn_unimpl.h"
#include "nvn_dirty.h"
#include "nvn_refl.h"
#include "vk_device.h"
#include "nvn_plat_vk.h"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdalign.h>
static nvn_gpu_err err;
#define REQUIRE(x) do { if(!(x)){fprintf(stderr,"assertion failed line %d: %s rc=%d why=%s\n",__LINE__,#x,err.rc.code,err.why);exit(2);} } while(0)
#define GPU(x) REQUIRE(nvn_gpu_ok(x))
const char *const *nvn_plat_vk_instance_exts(uint32_t *n){*n=0;return NULL;}
VkResult nvn_plat_vk_surface_create(VkInstance i,void *w,VkSurfaceKHR *s){(void)i;(void)w;*s=VK_NULL_HANDLE;return VK_ERROR_EXTENSION_NOT_PRESENT;}
int nvn_plat_window_size(void *w,uint32_t *x,uint32_t *y){(void)w;(void)x;(void)y;return 0;}
void nvn_plat_safepoint(void){}
int nvn_plat_flag(const char *n,int d){(void)n;return d;}
void nvn_plat_log(int l,const char *c,const char *s){(void)l;fprintf(stderr,"[%s] %s\n",c?c:"",s?s:"");}
static void done(void *u,const nvn_gpu_done *d){(void)u;(void)d;}
void rp_buf_reset(void);
static nvn_gpu_shader shader(const char *dir,const char *name,const nvn_gpu_layout *layout){
 char path[1024];REQUIRE(snprintf(path,sizeof path,"%s/%s.spv",dir,name)<(int)sizeof path);
 FILE *f=fopen(path,"rb");REQUIRE(f);REQUIRE(!fseek(f,0,SEEK_END));long n=ftell(f);REQUIRE(n>0);rewind(f);
 void *data=malloc((size_t)n);REQUIRE(data);REQUIRE(fread(data,1,(size_t)n,f)==(size_t)n);fclose(f);
 nvn_gpu_shader_src s={0};s.stage=NVN_GPU_SH_CS;s.kind=NVN_GPU_BLOB_SPIRV;s.entry="main";s.blob=data;s.bytes=(size_t)n;s.layout=layout;
 nvn_gpu_shader h=NULL;GPU(nvn_gpu_shader_load(&s,&h,&err));free(data);return h;
}
// 受控替身：程序来源、通道、池登记。镜像分配、GPU 写区间排除、地址解析、派发与 Vulkan 都是真的。
int g_s2a_logfd=2,s2a_nvn_rast_flip;
static alignas(4096) unsigned char guest[4096];
static struct rp_prog prog;static uint32_t pending;
int rp_shader_resolve_compute(const struct rp_prog **o){*o=&prog;return 0;}
int rp_shader_resolve(const struct rp_shader_req *q,const struct rp_prog **o){(void)q;*o=NULL;return -1;}
void rp_pass_barrier(uint32_t bits){pending|=bits;}
uint32_t rp_pass_take_barrier(void){uint32_t b=pending;pending=0;return b;}
uint64_t nvn_ga2ca(uint64_t a){return a;}
int nvn_dpool_base(const void *p,int t){(void)p;(void)t;return 0;}
const prog_t *nvn_prog_snap_get(uint64_t s,uint8_t k[6][8],uint8_t *o,uint8_t t[6]){(void)s;(void)k;(void)o;(void)t;return NULL;}
int rp_depth_zero(void){return 0;}int rp_origin_lower_left(void){return 1;}
void rp_perf_add(int i,uint64_t n){(void)i;(void)n;}uint64_t rp_seg_serial(void){return 1;}
uint64_t rp_sub_serial(void){return 1;}uint64_t rp_sub_fence(void){return 1;}
int rp_fence_done(uint64_t f){(void)f;return 1;}
static nvn_gpu_cmd active;
nvn_gpu_cmd rp_xfer_cmd(uint64_t *last){*last=1;return active;}
void rp_occl_draw(nvn_gpu_cmd c){(void)c;}
// GPU 写回登记：同 rp_exec.c 交给 rp_buf 的排除表；收尾不回写游戏内存
static uint64_t wkey[4],wid[4];static int nw;
int rp_post_gpu_write(uint64_t a,uint64_t n){if(nw>=4){return 0;}wid[nw]=rp_buf_gpu_write_note(a,n,&wkey[nw]);if(!wid[nw]){return 0;}nw++;return 1;}
int rp_pool_find(uint64_t a,uint64_t n,const uint8_t **m,uint64_t *s){uint64_t base=(uint64_t)(uintptr_t)guest;if(a<base||n>sizeof guest||a-base>sizeof guest-n)return 0;if(m)*m=guest;if(s)*s=sizeof guest;return 1;}
// 受写跟踪、游戏之后没再写的池：首次解析直接写进镜像，之后的解析走快路，不录同步拷贝。
// 这样传输写和派发 B 之间除了游戏屏障没有别的屏障（同步拷贝的后端实现开头带全屏障，会把缺的那道盖掉），测的就是它。
size_t nvn_dirty_page_size(void){return 4096;}uint64_t nvn_dirty_now(void){return 1;}
uint64_t nvn_dirty_mapping_generation(void){return 1;}int nvn_dirty_tracking_unreliable(void){return 0;}
const void *nvn_dirty_span(const void *a,size_t n){(void)n;return a;}
long nvn_dirty_page_gens(const void *s,const void *a,size_t l,uint64_t *g,size_t n){(void)s;(void)a;(void)l;for(size_t i=0;i<n;i++){g[i]=1;}return (long)n;}
void nvn_dirty_protect(const void *a,size_t n){(void)a;(void)n;}
void rp_view_pin_begin(void){}void rp_view_pin_end(void){}
nvn_gpu_view rp_view_by_id(int i,nvn_gpu_cmd c,const tex_t **t){(void)i;(void)c;(void)t;return NULL;}
nvn_gpu_view rp_view_by_id_decl(int i,uint8_t t,uint8_t k,int e,nvn_gpu_cmd c,const tex_t **o){(void)i;(void)t;(void)k;(void)e;(void)c;(void)o;return NULL;}
nvn_gpu_samp rp_samp_by_id(int i){(void)i;return NULL;}
int rp_tex_snap_by_id(int i,tex_t *t,view_t *v,int *h){(void)i;(void)t;(void)v;(void)h;return 0;}
uint64_t rp_tex_reg_gen(void){return 1;}uint64_t rp_tex_fact_sig(const uint64_t *h,int n,int b,int c){(void)h;(void)n;(void)b;(void)c;return 0;}
void rp_tex_mark_gpu_written(const tex_t *t){(void)t;}int rp_tex_debug_state(uint64_t s){(void)s;return 0;}
nvn_gpu_tex rp_tex_backend_by_serial(uint64_t s){(void)s;return NULL;}
static p_set_rt target;
const p_set_rt *rp_pass_target(void){return &target;}int rp_pass_slot_attached(int i){(void)i;return 0;}
void rp_pass_slot_size(int i,uint32_t *w,uint32_t *h){(void)i;*w=*h=1;}void rp_pass_note_draw(int d){(void)d;}
int rp_pass_parked(void){return 0;}void rp_pass_prepare_draw(nvn_gpu_cmd c){(void)c;}void rp_pass_land_reads(nvn_gpu_cmd c,const tex_t *const *ts,int n){(void)c;(void)ts;(void)n;}
int rp_pass_begin(nvn_gpu_cmd c){(void)c;return 0;}void rp_pass_flush(nvn_gpu_cmd c){(void)c;}
int main(int argc,char **argv){
 if(argc!=3){return 2;}
 const int with=strcmp(argv[2],"none")!=0;
 struct s2a_vk_device d;char why[256];if(s2a_vk_device_create(&d,why,sizeof why)){fprintf(stderr,"%s\n",why);return 2;}
 printf("device: %s (%s)\n",d.properties.deviceName,d.driver_name);
 nvn_gpu_open_desc od={0};od.host_device=&d;od.app_label="replay-dispatch-barrier";GPU(nvn_gpu_open(&od,&err));
 memset(&prog,0,sizeof prog);prog.is_compute=1;prog.nent[0]=1;
 nvn_gpu_layout_ent *e=&prog.ent[0][0];e->cls=NVN_GPU_RES_SSBO;e->src_kind=NVN_RB_SBUFP;e->src_reg=0;e->src_reg2=UINT16_MAX;e->access=NVN_GPU_ACC_RW;e->count=1;e->stages=1u<<NVN_GPU_SH_CS;
 nvn_gpu_layout lay={0};lay.ent=e;lay.nent=1;prog.sh[0]=shader(argv[1],"bar_double.comp",&lay);
 memset(guest,0,sizeof guest);
 rp_state_reset();rp_draw_reset();nvn_unimpl_reset();
 rp_S.ssbo[5][0].addr=(uint64_t)(uintptr_t)guest;rp_S.ssbo[5][0].size=512;
 GPU(nvn_gpu_cmd_begin(NULL,&active,&err));
 nvn_gpu_buf mirror=NULL;uint64_t off=0;REQUIRE(rp_buf_resolve(active,(uint64_t)(uintptr_t)guest,512,&mirror,&off));   // 镜像句柄：派发绑的是同一份
 uint32_t init[64];for(uint32_t i=0;i<64;i++){init[i]=i*3;}
 nvn_gpu_buf_write(active,mirror,off,init,sizeof init);                                    // 传输写
 if(with)rp_pass_barrier(NVN_BARRIER_ORDER_PRIMITIVES_BIT|NVN_BARRIER_INVALIDATE_SHADER_BIT);   // 游戏的 OP_BARRIER
 p_dispatch dp={0};dp.x=dp.y=dp.z=1;rp_dispatch(active,&dp,NULL);                          // B：读传输写的
 REQUIRE(nvn_unimpl_kinds()==0);
 GPU(nvn_gpu_cmd_commit(active,1,done,NULL,&err));GPU(nvn_gpu_fence_wait(1,5000000000ull,&err));
 const uint32_t *w=(const uint32_t*)(const void*)((const uint8_t*)nvn_gpu_buf_cpu(mirror)+off);unsigned bad=0;
 for(uint32_t i=0;i<64;i++){if(w[i]!=i*3){bad++;}if(w[64+i]!=i*6){bad++;}}
 printf("dispatch-barrier mode=%s readback w[64+i]==i*6 mismatches=%u (w[65]=%u w[127]=%u)\n",with?"barrier":"none",bad,w[65],w[127]);
 for(int k=0;k<nw;k++)rp_buf_gpu_write_land(wkey[k],wid[k],0);
 rp_draw_reset();rp_buf_reset();nvn_gpu_shader_release(prog.sh[0]);
 GPU(nvn_gpu_close(5000000000ull,&err));REQUIRE(!s2a_vk_device_destroy(&d,1));
 return bad?1:0;
}
