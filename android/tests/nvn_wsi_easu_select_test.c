/* 独立 WSI 选择回归：生产函数原样编译，Vulkan 命令端点替身；不运行驱动。 */
#include <stdint.h>
#include <stdio.h>
#include <string.h>
#include <stdlib.h>
#include <vulkan/vulkan_core.h>
struct nvn_gpu_tex_s { uint32_t w,h; VkImage image; };
struct nvn_gpu_view_s { struct nvn_gpu_tex_s *tex; uint32_t base_level,base_layer; };
struct nvn_gpu_cmd_s { VkCommandBuffer cb; };
struct nvn_gpu_surface_s { VkImage images[1]; VkExtent2D extent; VkFormat format; uint32_t gen; };
typedef struct {struct nvn_gpu_view_s *src;int32_t crop[4],dst[4];uint32_t filter;double at;uint8_t flip_y,_rsv[7];} nvn_gpu_present_desc;
#define REF_VIEW 1
#define NVN_PLAT_LOG_INFO 1
static int checks,failures,cases,easu_calls,clear_calls,barriers,ca_barriers,blits,copies,refs,logs,tick,clear_at,blit_at,present_at,restore_at,attempt_ok;
static VkImageBlit observed_blit;static VkFilter observed_filter;
static const char *label;
#define CHECK(x) do{checks++;if(!(x)){failures++;printf("FAIL %s:%d %s\n",label,__LINE__,#x);}}while(0)
static int nvn_plat_flag(const char *key,int fallback){(void)key;return fallback;}
static void nvn_plat_log(int level,const char *cls,const char *text){(void)level;(void)cls;CHECK(strstr(text,"回落")!=NULL);logs++;}
static void cmd_ref(struct nvn_gpu_cmd_s *c,struct nvn_gpu_view_s *v,int kind){(void)c;(void)v;CHECK(kind==REF_VIEW);refs++;}
static void image_barrier(struct nvn_gpu_cmd_s *c,struct nvn_gpu_tex_s *t,VkImageLayout layout){(void)c;(void)t;if(layout==VK_IMAGE_LAYOUT_GENERAL)restore_at=++tick;else CHECK(layout==VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL);}
static void wsi_swap_barrier(VkCommandBuffer cb,VkImage image,VkImageLayout old,VkImageLayout next,VkAccessFlags src,VkAccessFlags dst,VkPipelineStageFlags a,VkPipelineStageFlags b){(void)cb;(void)image;(void)old;(void)src;(void)dst;(void)a;(void)b;barriers++;tick++;if(next==VK_IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL)ca_barriers++;if(next==VK_IMAGE_LAYOUT_PRESENT_SRC_KHR)present_at=tick;}
VKAPI_ATTR void VKAPI_CALL vkCmdClearColorImage(VkCommandBuffer c,VkImage i,VkImageLayout l,const VkClearColorValue *v,uint32_t n,const VkImageSubresourceRange *r){(void)c;(void)i;CHECK(l==VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL);CHECK(v->float32[0]==0&&v->float32[1]==0&&v->float32[2]==0&&v->float32[3]==1);CHECK(n==1&&r->aspectMask==VK_IMAGE_ASPECT_COLOR_BIT);clear_calls++;clear_at=++tick;}
VKAPI_ATTR void VKAPI_CALL vkCmdBlitImage(VkCommandBuffer c,VkImage src,VkImageLayout sl,VkImage dst,VkImageLayout dl,uint32_t n,const VkImageBlit *r,VkFilter filter){(void)c;(void)src;(void)dst;CHECK(sl==VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL&&dl==VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL&&n==1);observed_blit=*r;observed_filter=filter;blits++;blit_at=++tick;}
VKAPI_ATTR void VKAPI_CALL vkCmdCopyImage(VkCommandBuffer c,VkImage src,VkImageLayout sl,VkImage dst,VkImageLayout dl,uint32_t n,const VkImageCopy *r){(void)c;(void)src;(void)dst;CHECK(sl==VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL&&dl==VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL&&n==1);CHECK(r->extent.width>0&&r->extent.height>0);copies++;tick++;}
struct easu_rects;
static int easu_compose(struct nvn_gpu_cmd_s *c,VkImage image,VkExtent2D extent,uint32_t level,VkFormat fmt,struct nvn_gpu_view_s *sv,const struct easu_rects *rect,int flip,uint32_t generation,int encode);

#include "nvn_wsi_easu_production.inc"
static int easu_compose(struct nvn_gpu_cmd_s *c,VkImage image,VkExtent2D extent,uint32_t level,VkFormat fmt,struct nvn_gpu_view_s *sv,const struct easu_rects *rect,int flip,uint32_t generation,int encode){
 (void)c;(void)image;(void)extent;(void)level;(void)fmt;(void)sv;(void)flip;(void)generation;(void)encode;
 CHECK(rect->sw>0&&rect->sh>0&&rect->dw>0&&rect->dh>0);easu_calls++;return attempt_ok;
}
struct scenario {const char *name;int sw,sh,dw,dh,eligible,succeeds,want_attempt,mip,flip,encode,defaults,linear,invalid;};
int main(void){
 const struct scenario scenarios[]={
 {"same",64,32,64,32,1,1,0,0,0,0,0,1,0},
 {"integers-2x3",32,16,64,48,1,1,0,0,0,0,0,1,0},
 {"default-full-same",64,32,64,32,1,1,0,0,0,0,1,1,0},
 {"mip-flip-encode-same",32,16,32,16,1,1,0,1,1,1,1,1,0},
 {"fractional",64,32,96,48,1,1,1,0,0,0,0,1,0},
 {"mixed-fractional",64,32,128,48,1,1,1,0,0,0,0,1,0},
 {"downscale-preserved",64,32,48,24,1,1,1,0,0,0,0,1,0},
 {"fractional-failure",64,32,96,48,1,0,1,0,1,0,0,1,0},
 {"fractional-encode-failure",64,32,96,48,1,0,1,0,0,1,0,1,0},
 {"not-eligible",64,32,96,48,0,1,0,0,0,0,0,1,0},
 {"nearest-fallback",64,32,64,32,1,1,0,0,0,0,0,0,0},
 {"ordinary-outside-rect",64,32,96,48,1,0,0,0,0,0,0,1,1}};
 for(unsigned i=0;i<sizeof scenarios/sizeof scenarios[0];i++){
 const struct scenario *q=&scenarios[i];label=q->name;cases++;
 easu_calls=clear_calls=barriers=ca_barriers=blits=copies=refs=logs=tick=clear_at=blit_at=present_at=restore_at=0;attempt_ok=q->succeeds;
 struct nvn_gpu_tex_s t={.w=(uint32_t)q->sw<<q->mip,.h=(uint32_t)q->sh<<q->mip,.image=(VkImage)(uintptr_t)1};
 struct nvn_gpu_view_s v={.tex=&t,.base_level=q->mip,.base_layer=2};
 struct nvn_gpu_cmd_s c={0};struct nvn_gpu_surface_s s={.images={(VkImage)(uintptr_t)2},.extent={q->dw,q->dh},.format=VK_FORMAT_R8G8B8A8_UNORM,.gen=1};
 nvn_gpu_present_desc d={.src=&v,.crop={0,0,q->sw,q->sh},.dst={0,0,q->dw,q->dh},.filter=1,.flip_y=q->flip};
 if(q->invalid)d.crop[0]=1;
 if(q->defaults){memset(d.crop,0,sizeof d.crop);memset(d.dst,0,sizeof d.dst);}
 VkFormatProperties fp={.optimalTilingFeatures=q->linear?VK_FORMAT_FEATURE_SAMPLED_IMAGE_FILTER_LINEAR_BIT:0};
 int upscaled=-1;int ok=wsi_compose_selected(&c,&s,0,&t,&d,&fp,q->encode,(VkImage)(uintptr_t)(q->encode?3:2),q->eligible,&upscaled);
 int success=q->want_attempt&&q->succeeds;int fallback=!success;
 CHECK(ok==!q->invalid);CHECK(upscaled==success);CHECK(easu_calls==q->want_attempt);
 int provisional=q->want_attempt||q->invalid;
 CHECK(logs==((q->want_attempt&&!q->succeeds)||q->invalid));CHECK(ca_barriers==provisional);
 CHECK(clear_calls==provisional+fallback);CHECK(blits==(fallback&&!q->invalid));CHECK(refs==fallback);
 CHECK(copies==(fallback&&q->encode));CHECK(present_at>0);
 CHECK(barriers==(provisional?(success?3:2):0)+(fallback?(q->encode?5:3):0));
 if(fallback&&!q->invalid){CHECK(clear_at<blit_at&&blit_at<present_at&&present_at<restore_at);
 CHECK(observed_blit.srcSubresource.mipLevel==(uint32_t)q->mip);CHECK(observed_blit.srcSubresource.baseArrayLayer==2);
 CHECK(observed_blit.srcOffsets[0].y==(q->flip?q->sh:0));CHECK(observed_blit.srcOffsets[1].y==(q->flip?0:q->sh));
 CHECK(observed_blit.srcOffsets[1].x==q->sw);CHECK(observed_blit.dstOffsets[1].x==q->dw&&observed_blit.dstOffsets[1].y==q->dh);
 CHECK(observed_filter==(q->linear?VK_FILTER_LINEAR:VK_FILTER_NEAREST));}
 printf("CASE %s attempts=%d clear=%d blit=%d copy=%d failure_log=%d upscaled=%d\n",label,easu_calls,clear_calls,blits,copies,logs,upscaled);
 }
 printf("TOTAL cases=%d checks=%d failures=%d\n",cases,checks,failures);return failures?1:0;
}
